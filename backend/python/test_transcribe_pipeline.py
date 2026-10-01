import os
import json
import tempfile
import unittest
import xml.etree.ElementTree as ET
from unittest.mock import patch

import numpy as np
import pretty_midi
from music21 import chord, clef, converter, duration, meter, note, stream

from transcribe_pipeline import (
    Grid,
    _chord_window_beats,
    _detect_time_signature,
    _build_band_score,
    _clean_lead_contour,
    _compact_band_keyboard_events,
    _correct_isolated_violin_octaves,
    _fit_midi_candidates_to_range,
    _fill_vocal_gaps_with_instrumental,
    _instrument_specific_stem,
    _band_source_for_part,
    _merge_bass_support_into_piano,
    _piano_score_from_midi,
    _prefer_pyin_lead,
    _require_complete_band,
    _normalize_musicxml_durations,
    _normalize_musicxml_voice_numbers,
    _write_musicxml,
    _part_voice_settings,
    _is_successful_bytedance_solo_piano,
    _piano_transcriber_name,
    _uses_filtered_basic_pitch_candidate,
    _preferred_key_name,
    _polyphonic_score_from_midi,
    _role_source_fallback,
    _fixed_time_pitch_similarity,
    _gate_inactive_passages,
    _snap_to_detected_scale,
    _simplify_violin_techniques,
    apply_isolated_lead_to_piano,
    _melody_rest_sections,
    _recover_instrumental_sections,
    _select_solo_violin_line,
    build_pipeline,
    midi_to_musicxml,
)
from solo_guitar_arranger import (
    arrange_solo_guitar, guitar_string_frets, merge_guitar_melody,
    select_guitar_lead, _v9_shape_candidates,
)


def _write_midi(path, tracks):
    midi = pretty_midi.PrettyMIDI(initial_tempo=120)
    for name, notes in tracks:
        instrument = pretty_midi.Instrument(program=0, name=name)
        instrument.notes.extend(
            pretty_midi.Note(velocity=velocity, pitch=pitch, start=start, end=end)
            for pitch, start, end, velocity in notes
        )
        midi.instruments.append(instrument)
    midi.write(path)


class AccompanimentTimingTests(unittest.TestCase):
    def test_band_role_source_wins_for_melody_and_bass(self):
        with tempfile.TemporaryDirectory() as directory:
            for stem in ('guitar', 'piano', 'other'):
                open(os.path.join(directory, stem + '.wav'), 'wb').close()
            with patch('transcribe_pipeline._audio_rms', return_value=.1):
                self.assertEqual(
                    _band_source_for_part('Guitar', 'melody', directory),
                    ('vocals', None),
                )
                self.assertEqual(
                    _band_source_for_part('Piano', 'bass', directory),
                    ('bass', None),
                )
                self.assertEqual(
                    _band_source_for_part('Guitar', 'harmony', directory),
                    ('guitar', 'guitar'),
                )

    def test_guitar_distinct_attacks_survive_overlong_tails(self):
        from solo_guitar_arranger import _monophonic_melody
        source = [pretty_midi.Note(90, 64, 0, 2),
                  pretty_midi.Note(85, 64, .5, 1),
                  pretty_midi.Note(88, 67, 1.2, 1.8)]
        selected = _monophonic_melody(source)
        self.assertEqual([(n.pitch, n.start) for n in selected],
                         [(64, 0), (64, .5), (67, 1.2)])
        self.assertEqual(selected[0].end, .5)
        self.assertEqual(source[0].end, 2)

    def test_guitar_recovers_agreeing_vocal_attacks_from_second_detector(self):
        verified = [pretty_midi.Note(90, 64, 0, 1.1),
                    pretty_midi.Note(90, 67, 1.5, 2.0)]
        candidates = [pretty_midi.Note(82, 64, .5, .9),
                      pretty_midi.Note(82, 65, 1.15, 1.4),
                      pretty_midi.Note(82, 79, 1.25, 1.45)]
        merged, added = merge_guitar_melody(
            verified, candidates, 2.0, same_source=True)
        self.assertEqual([note.pitch for note in added], [64, 65])
        self.assertEqual([round(note.start, 2) for note in merged],
                         [0, .5, 1.15, 1.5])

    def test_v9_guitar_shapes_start_from_established_fingerings(self):
        """V9 must retain familiar grips, not synthesize arbitrary frets."""
        cases = [
            (0, 'major', (None, 3, 2, 0, 1, 0), 'C_open'),
            (2, 'major', (None, None, 0, 2, 3, 2), 'D_open'),
            (4, 'minor', (0, 2, 2, 0, 0, 0), 'Em_open'),
            (5, 'major', (1, 3, 3, 2, 1, 1), 'F_E_form'),
        ]
        for root_pc, quality, layout, name in cases:
            candidates = _v9_shape_candidates({
                'root_pc': root_pc, 'quality': quality,
            })
            chosen = next((shape for shape in candidates if shape.layout == layout), None)
            self.assertIsNotNone(chosen)
            self.assertEqual(chosen.template_name, name)
            self.assertEqual(len(chosen.left_hand), 6)
            self.assertTrue(any(finger for finger in chosen.left_hand if finger))

    def test_solo_guitar_fallback_does_not_invent_intro_before_verified_vocal(self):
        verified = [pretty_midi.Note(95, 72, 2.0, 2.5)]
        fallback = [
            pretty_midi.Note(82, 65, .0, .35),
            pretty_midi.Note(82, 67, .35, .7),
            pretty_midi.Note(82, 74, 2.1, 2.4),
        ]
        merged, additions = merge_guitar_melody(verified, fallback, 3.0)
        self.assertEqual([item.pitch for item in merged], [72])
        self.assertEqual(additions, [])

    def test_solo_guitar_fallback_can_fill_a_bounded_verified_vocal_rest(self):
        verified = [
            pretty_midi.Note(95, 64, 0.0, .35),
            pretty_midi.Note(95, 67, 1.5, 1.9),
        ]
        fallback = [pretty_midi.Note(82, 65, .7, 1.05)]
        merged, additions = merge_guitar_melody(verified, fallback, 2.5)
        self.assertEqual([item.pitch for item in merged], [64, 65, 67])
        self.assertEqual([item.pitch for item in additions], [65])

    def test_solo_guitar_arrangement_keeps_melody_and_adds_playable_harmony(self):
        with tempfile.TemporaryDirectory() as directory:
            target = os.path.join(directory, 'guitar.mid')
            grid = Grid(120, '4/4', 'C', 'major', chord_sections=(
                {'start_seconds': 0.0, 'end_seconds': 2.0, 'root_pc': 0,
                 'quality': 'major', 'tones': [0, 4, 7], 'confidence': .35},
                {'start_seconds': 2.0, 'end_seconds': 4.0, 'root_pc': 7,
                 'quality': 'major', 'tones': [7, 11, 2], 'confidence': .35},
            ))
            melody = [
                pretty_midi.Note(95, 64, .0, .45),
                pretty_midi.Note(88, 67, .5, .95),
                pretty_midi.Note(94, 69, 2.0, 2.5),
            ]
            bass = [pretty_midi.Note(72, 36, .0, .8), pretty_midi.Note(72, 31, 2.0, 2.7)]
            stats = arrange_solo_guitar(melody, bass, grid, target)
            rendered = pretty_midi.PrettyMIDI(target)
            notes = [item for track in rendered.instruments for item in track.notes]
            self.assertEqual(stats['melody_notes'], 3)
            self.assertGreater(stats['accompaniment_notes'], 0)
            self.assertGreater(stats['bass_support_notes'], 0)
            self.assertGreater(stats['max_simultaneous_notes'], 1)
            self.assertLessEqual(stats['max_simultaneous_notes'], 4)
            self.assertLessEqual(stats['largest_simultaneous_pitch_span'], 24)
            self.assertEqual(stats['duplicate_pitch_onsets'], 0)
            self.assertTrue(all(40 <= item.pitch <= 88 for item in notes))
            # A physical stroke may spread its string contacts by a few
            # milliseconds while remaining one chord+melody gesture.
            second_attack = [item.pitch for item in notes
                             if abs(item.start - 2.0) <= .07]
            # Section two deliberately excludes the bass/root. It must still
            # retain useful third/fifth colour instead of becoming melody-only.
            self.assertGreaterEqual(len(second_attack), 2)
            self.assertIn(69, second_attack)

    def test_solo_guitar_assigns_distinct_strings_for_a_real_voicing(self):
        # C3, G3, E4: a compact playable C-major shape, not a Piano stack.
        fingering = guitar_string_frets([48, 55, 64])
        self.assertIsNotNone(fingering)
        self.assertEqual(len({string for string, _ in fingering}), 3)
        self.assertTrue(all(0 <= fret <= 24 for _, fret in fingering))

    def test_solo_guitar_rejects_same_string_only_chord(self):
        # These high adjacent pitches only fit on the high-E string.
        self.assertIsNone(guitar_string_frets([84, 85, 86]))

    def test_solo_guitar_confident_harmony_supports_a_real_melody_phrase(self):
        with tempfile.TemporaryDirectory() as directory:
            target = os.path.join(directory, 'guitar_chord.mid')
            grid = Grid(120, '4/4', 'C', 'major', chord_sections=(
                {'start_seconds': 0.0, 'end_seconds': 2.0, 'root_pc': 0,
                 'quality': 'major', 'tones': [0, 4, 7], 'confidence': .35},
            ))
            stats = arrange_solo_guitar(
                [pretty_midi.Note(96, 64, .35, 1.0)], [], grid, target)
            notes = [item for track in pretty_midi.PrettyMIDI(target).instruments
                     for item in track.notes]
            self.assertTrue(any(item.pitch == 64 and abs(item.start - .35) <= .001
                                for item in notes))
            # A moving melody may be supported around its attack instead of
            # receiving a block chord on every note.
            self.assertGreater(stats['accompaniment_notes'], 0)

    def test_solo_guitar_low_melody_keeps_playable_root_fifth_support(self):
        with tempfile.TemporaryDirectory() as directory:
            target = os.path.join(directory, 'low_guitar_chord.mid')
            grid = Grid(120, '4/4', 'E', 'minor', chord_sections=(
                {'start_seconds': 0.0, 'end_seconds': 2.0, 'root_pc': 4,
                 'quality': 'minor', 'tones': [4, 7, 11], 'confidence': .35},
            ))
            arrange_solo_guitar(
                [pretty_midi.Note(96, 55, .25, .95)], [], grid, target)
            notes = [item for track in pretty_midi.PrettyMIDI(target).instruments
                     for item in track.notes if abs(item.start - .25) <= .001]
            self.assertEqual(sorted(item.pitch for item in notes), [40, 47, 55])

    def test_solo_guitar_keeps_a_valid_chord_attack_before_a_fast_next_melody(self):
        with tempfile.TemporaryDirectory() as directory:
            target = os.path.join(directory, 'fast_melody_guitar.mid')
            grid = Grid(120, '4/4', 'E', 'minor', chord_sections=(
                {'start_seconds': 0.0, 'end_seconds': 2.0, 'root_pc': 4,
                 'quality': 'minor', 'tones': [4, 7, 11], 'confidence': .35},
            ))
            arrange_solo_guitar([
                pretty_midi.Note(96, 55, .25, .78),
                pretty_midi.Note(96, 57, .55, 1.05),
                pretty_midi.Note(96, 59, .82, 1.25),
            ], [], grid, target)
            notes = [item for track in pretty_midi.PrettyMIDI(target).instruments
                     for item in track.notes]
            first_attack = [item for item in notes if abs(item.start - .25) <= .001]
            self.assertGreaterEqual(len(first_attack), 2)
            self.assertTrue(any(item.pitch != 55 for item in first_attack))

    def test_solo_guitar_busy_strong_chord_uses_root_fifth_not_octave_double(self):
        with tempfile.TemporaryDirectory() as directory:
            target = os.path.join(directory, 'busy_guitar.mid')
            grid = Grid(120, '4/4', 'E', 'minor', chord_sections=(
                {'start_seconds': 0.0, 'end_seconds': 1.8, 'root_pc': 4,
                 'quality': 'minor', 'tones': [4, 7, 11], 'confidence': .20},
            ))
            arrange_solo_guitar([
                pretty_midi.Note(96, 55, .20, .43),
                pretty_midi.Note(96, 57, .48, .70),
                pretty_midi.Note(96, 59, .76, .98),
            ], [pretty_midi.Note(70, 43, .0, 1.0)], grid, target)
            notes = [item for track in pretty_midi.PrettyMIDI(target).instruments
                     for item in track.notes if abs(item.start - .20) <= .001]
            pitches = sorted(item.pitch for item in notes)
            self.assertEqual(pitches, [40, 47, 55])

    def test_solo_guitar_caps_sustained_melody_plus_later_support_at_four_voices(self):
        with tempfile.TemporaryDirectory() as directory:
            target = os.path.join(directory, 'cap.mid')
            grid = Grid(120, '4/4', 'C', 'major', chord_sections=(
                {'start_seconds': 0.0, 'end_seconds': 2.0, 'root_pc': 0,
                 'quality': 'major', 'tones': [0, 4, 7], 'confidence': .4},
            ))
            stats = arrange_solo_guitar(
                [pretty_midi.Note(100, 76, .08, 1.7)], [], grid, target)
            self.assertLessEqual(stats['max_simultaneous_notes'], 4)

    def test_solo_guitar_uses_large_gap_but_not_short_gap_for_safe_texture(self):
        with tempfile.TemporaryDirectory() as directory:
            grid = Grid(100, '4/4', 'C', 'major', chord_sections=(
                {'start_seconds': 0.0, 'end_seconds': 3.0, 'root_pc': 0,
                 'quality': 'major', 'tones': [0, 4, 7], 'confidence': .3},
            ))
            target = os.path.join(directory, 'gap.mid')
            stats = arrange_solo_guitar([
                pretty_midi.Note(95, 72, 0, .35), pretty_midi.Note(95, 74, 1.1, 1.4),
                pretty_midi.Note(95, 76, 1.52, 1.8),
            ], [], grid, target)
            self.assertGreaterEqual(stats['safe_gap_texture_events'], 1)
            self.assertLessEqual(stats['max_simultaneous_notes'], 4)
            self.assertLessEqual(stats['largest_simultaneous_pitch_span'], 24)

    def test_guitar_melody_role_notation_preserves_a_chord_attack(self):
        with tempfile.TemporaryDirectory() as directory:
            midi_path = os.path.join(directory, 'guitar.mid')
            xml_path = os.path.join(directory, 'guitar.musicxml')
            _write_midi(midi_path, [('Guitar', [
                (48, 0.0, .6, 60), (55, 0.0, .6, 62), (64, 0.0, .6, 95),
                (67, .72, 1.1, 90),
            ])])
            grid = Grid(120, '4/4', 'C', 'major')
            midi_to_musicxml(midi_path, xml_path, 'Guitar', grid, 'melody')
            exported = converter.parse(xml_path)
            chords = list(exported.recurse().getElementsByClass(chord.Chord))
            self.assertTrue(any(len(item.pitches) >= 2 for item in chords))

    def test_solo_guitar_weak_harmony_stays_sparse_and_needs_no_guitar_source(self):
        with tempfile.TemporaryDirectory() as directory:
            target = os.path.join(directory, 'sparse.mid')
            grid = Grid(96, '3/4', 'A', 'minor', chord_sections=(
                {'start_seconds': 0.0, 'end_seconds': 1.875, 'root_pc': 9,
                 'quality': 'minor', 'tones': [9, 0, 4], 'confidence': .02},
            ))
            stats = arrange_solo_guitar(
                [pretty_midi.Note(92, 76, .2, .7)], [], grid, target)
            self.assertEqual(stats['melody_notes'], 1)
            self.assertLessEqual(stats['max_simultaneous_notes'], 3)
            self.assertEqual(stats['duplicate_pitch_onsets'], 0)

    def test_solo_guitar_upper_line_rejects_low_accompaniment_at_same_attack(self):
        with tempfile.TemporaryDirectory() as directory:
            source = os.path.join(directory, 'source.mid')
            target = os.path.join(directory, 'lead.mid')
            _write_midi(source, [('Other', [
                (43, 0.0, .4, 90), (55, 0.0, .4, 88), (67, 0.0, .4, 74),
                (45, .5, .9, 88), (57, .5, .9, 80), (69, .5, .9, 72),
            ])])
            lead = select_guitar_lead(source, target)
            self.assertEqual([item.pitch for item in lead], [67, 69])
    def test_solo_violin_line_selection_is_monophonic(self):
        with tempfile.TemporaryDirectory() as directory:
            source = os.path.join(directory, 'source.mid')
            target = os.path.join(directory, 'target.mid')
            _write_midi(source, [('Candidates', [
                (60, 0.0, 1.0, 75), (72, 0.0, .4, 95),
                (74, .45, .9, 88), (65, .45, 1.2, 70),
            ])])
            selected = _select_solo_violin_line(source, target)
            self.assertTrue(selected)
            self.assertTrue(all(
                left.end <= right.start + .025
                for left, right in zip(selected, selected[1:])
            ))
    def test_chord_windows_follow_simple_meter(self):
        self.assertEqual(_chord_window_beats('4/4'), 4)
        self.assertEqual(_chord_window_beats('3/4'), 3)

    def test_chord_windows_follow_compound_meter_pulses(self):
        self.assertEqual(_chord_window_beats('6/8'), 2)

    def test_piano_transcriber_defaults_to_basic_pitch_and_flag_is_explicit(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(_piano_transcriber_name(), 'basic_pitch')
        with patch.dict(os.environ, {'AUGMENT_PIANO_TRANSCRIBER': 'bytedance'}):
            self.assertEqual(_piano_transcriber_name(), 'bytedance')

    def test_successful_bytedance_event_preservation_is_strictly_piano_solo_only(self):
        successful = {'method': 'bytedance_piano_experimental'}
        self.assertTrue(_is_successful_bytedance_solo_piano('solo', 'Piano', successful))
        self.assertFalse(_is_successful_bytedance_solo_piano(
            'band', 'Piano', successful))
        self.assertFalse(_is_successful_bytedance_solo_piano(
            'solo', 'Violin', successful))
        self.assertFalse(_is_successful_bytedance_solo_piano(
            'solo', 'Piano', {'method': 'basic_pitch_fallback'}))

    def test_bytedance_solo_piano_keeps_raw_notes_and_cc64_through_pipeline(self):
        def write_bytedance(_audio_path, midi_path):
            midi = pretty_midi.PrettyMIDI(initial_tempo=120)
            piano = pretty_midi.Instrument(program=0, name='Piano')
            piano.notes = [
                pretty_midi.Note(39, 48, 0.0, 1.0),
                pretty_midi.Note(97, 72, 0.4, 1.6),
            ]
            piano.control_changes = [
                pretty_midi.ControlChange(64, 127, 0.1),
                pretty_midi.ControlChange(64, 0, 1.5),
            ]
            midi.instruments.append(piano)
            midi.write(midi_path)
            return {'method': 'bytedance_piano_experimental', 'notes': 2,
                    'predicted_cc64_events': 2, 'preserve_predicted_pedal': True}

        with tempfile.TemporaryDirectory() as directory:
            audio_path = os.path.join(directory, 'upload.wav')
            open(audio_path, 'wb').close()
            stem_dir = os.path.join(directory, 'stems')
            os.makedirs(stem_dir)
            open(os.path.join(stem_dir, 'other.wav'), 'wb').close()
            grid = Grid(120, '4/4', 'C', 'major')
            audit = {'overfull_measures': [], 'missing_attack_count': 0}
            with patch.dict(os.environ, {'AUGMENT_PIANO_TRANSCRIBER': 'bytedance'}), \
                    patch('transcribe_pipeline.analyze_grid', return_value=grid), \
                    patch('transcribe_pipeline.run_demucs', return_value=stem_dir), \
                    patch('transcribe_pipeline._transcribe_piano_bytedance', side_effect=write_bytedance), \
                    patch('transcribe_pipeline.transcribe_stem') as legacy_transcribe, \
                    patch('transcribe_pipeline._merge_bass_support_into_piano') as merge_bass, \
                    patch('transcribe_pipeline.apply_isolated_lead_to_piano') as apply_lead, \
                    patch('transcribe_pipeline._write_debug_artifacts', return_value=None), \
                    patch('transcribe_pipeline.midi_to_musicxml'), \
                    patch('score_validation.audit_score', return_value=audit), \
                    patch('performance_arranger.arrange') as arranger:
                result = build_pipeline(
                    audio_path, os.path.join(directory, 'output'), 'solo',
                    [{'instrument': 'Piano', 'role': 'melody'}],
                )['parts'][0]

            legacy_transcribe.assert_not_called()
            merge_bass.assert_not_called()
            apply_lead.assert_not_called()
            arranger.assert_not_called()
            self.assertEqual(
                result['stats']['legacy_piano_support_bypassed'],
                ('_merge_bass_support_into_piano', 'apply_isolated_lead_to_piano'),
            )
            self.assertEqual(
                result['arrangement']['bypassed'],
                'bytedance_solo_piano_event_preservation',
            )
            raw = pretty_midi.PrettyMIDI(
                os.path.splitext(result['musicxml'])[0] + '.mid')
            final = pretty_midi.PrettyMIDI(result['_performance_midi_path'])
            raw_notes = [(n.pitch, n.start, n.end, n.velocity)
                         for track in raw.instruments for n in track.notes]
            final_notes = [(n.pitch, n.start, n.end, n.velocity)
                           for track in final.instruments for n in track.notes]
            raw_cc64 = [(c.time, c.value) for track in raw.instruments
                         for c in track.control_changes if c.number == 64]
            final_cc64 = [(c.time, c.value) for track in final.instruments
                           for c in track.control_changes if c.number == 64]
            self.assertEqual(raw_notes, final_notes)
            self.assertEqual(raw_cc64, final_cc64)
            self.assertNotIn('solo_piano_version', result['arrangement'])
            self.assertTrue(result['_preserve_piano_performance'])

    def test_bytedance_failure_retains_legacy_basic_pitch_piano_support(self):
        import soundfile as sf

        def write_basic_pitch(_audio_path, midi_path, **_kwargs):
            _write_midi(midi_path, [('Basic Pitch', [(60, 0.0, 1.0, 80)])])
            return {'method': 'basic_pitch'}

        with tempfile.TemporaryDirectory() as directory:
            audio_path = os.path.join(directory, 'upload.wav')
            open(audio_path, 'wb').close()
            stem_dir = os.path.join(directory, 'stems')
            os.makedirs(stem_dir)
            for stem in ('other', 'bass', 'vocals'):
                sf.write(os.path.join(stem_dir, f'{stem}.wav'), np.full(800, .1), 8000)
            grid = Grid(120, '4/4', 'C', 'major')
            audit = {'overfull_measures': [], 'missing_attack_count': 0}
            with patch.dict(os.environ, {'AUGMENT_PIANO_TRANSCRIBER': 'bytedance'}), \
                    patch('transcribe_pipeline.analyze_grid', return_value=grid), \
                    patch('transcribe_pipeline.run_demucs', return_value=stem_dir), \
                    patch('transcribe_pipeline._transcribe_piano_bytedance',
                          side_effect=RuntimeError('checkpoint unavailable')), \
                    patch('transcribe_pipeline.transcribe_stem', side_effect=write_basic_pitch), \
                    patch('transcribe_pipeline.validate_transcription',
                          return_value={'alignment_confidence': .7}), \
                    patch('transcribe_pipeline._recover_instrumental_sections', return_value=[]), \
                    patch('transcribe_pipeline._merge_bass_support_into_piano', return_value=1) as merge_bass, \
                    patch('transcribe_pipeline.apply_isolated_lead_to_piano', return_value=1) as apply_lead, \
                    patch('transcribe_pipeline._write_debug_artifacts', return_value=None), \
                    patch('transcribe_pipeline.midi_to_musicxml'), \
                    patch('score_validation.audit_score', return_value=audit):
                result = build_pipeline(
                    audio_path, os.path.join(directory, 'output'), 'solo',
                    [{'instrument': 'Piano', 'role': 'melody'}],
                )['parts'][0]

            self.assertEqual(result['stats']['method'], 'basic_pitch_fallback')
            self.assertNotIn('legacy_piano_support_bypassed', result['stats'])
            merge_bass.assert_called_once()
            apply_lead.assert_called_once()
            self.assertNotIn('solo_piano_version', result['arrangement'])
            self.assertEqual(result['arrangement']['piano_route'],
                             'detected_performance_preserved')
            raw = pretty_midi.PrettyMIDI(
                os.path.splitext(result['musicxml'])[0] + '.mid')
            final = pretty_midi.PrettyMIDI(result['_performance_midi_path'])
            identity = lambda midi: sorted(
                (n.pitch, n.start, n.end, n.velocity)
                for track in midi.instruments for n in track.notes)
            self.assertEqual(identity(raw), identity(final))
            self.assertFalse(any('isolated melody' in track.name.lower()
                                 for track in final.instruments))

    def test_solo_piano_v2_2_uses_clean_v2_score_and_expressive_midi(self):
        import soundfile as sf

        def write_piano(_audio_path, midi_path, **_kwargs):
            _write_midi(midi_path, [
                ('Piano accompaniment', [
                    (48, 0, .8, 68), (60, 0, .8, 65),
                    (50, .9, 1.7, 68), (62, .9, 1.7, 65)]),
                ('Isolated melody', [
                    (72, 0, .5, 85), (74, .9, 1.5, 85)]),
            ])
            return {'method': 'basic_pitch', 'notes': 6}

        with tempfile.TemporaryDirectory() as directory:
            audio_path = os.path.join(directory, 'upload.wav')
            sf.write(audio_path, np.full(16000, .1), 8000)
            stem_dir = os.path.join(directory, 'stems')
            os.makedirs(stem_dir)
            for stem in ('other', 'bass', 'vocals'):
                sf.write(os.path.join(stem_dir, f'{stem}.wav'),
                         np.full(800, .1), 8000)
            grid = Grid(120, '4/4', 'C', 'major', chord_sections=(
                {'start_seconds': 0, 'end_seconds': 2, 'root_pc': 0,
                 'quality': 'major', 'tones': [0, 4, 7], 'confidence': .8},))
            audit = {'overfull_measures': [], 'missing_attack_count': 0}
            with patch.dict(os.environ, {'AUGMENT_PIANO_TRANSCRIBER': 'basic_pitch'}), \
                    patch('transcribe_pipeline.analyze_grid', return_value=grid), \
                    patch('transcribe_pipeline.run_demucs', return_value=stem_dir), \
                    patch('transcribe_pipeline.transcribe_stem', side_effect=write_piano), \
                    patch('transcribe_pipeline._merge_bass_support_into_piano', return_value=0), \
                    patch('transcribe_pipeline._add_missing_chord_bass_to_piano', return_value=0), \
                    patch('transcribe_pipeline.apply_isolated_lead_to_piano', return_value=0), \
                    patch('transcribe_pipeline.validate_transcription', return_value={}), \
                    patch('transcribe_pipeline._recover_instrumental_sections', return_value=[]), \
                    patch('transcribe_pipeline._write_debug_artifacts', return_value=None), \
                    patch('transcribe_pipeline.midi_to_musicxml') as export, \
                    patch('score_validation.audit_score', return_value=audit):
                result = build_pipeline(
                    audio_path, os.path.join(directory, 'output'), 'solo',
                    [{'instrument': 'Piano', 'role': 'melody'}],
                )['parts'][0]
            self.assertEqual(result['arrangement']['solo_piano_version'], '2.2')
            self.assertTrue(result['_preserve_piano_performance'])
            self.assertTrue(export.call_args.args[0].endswith('.piano_v2_score.mid'))
            self.assertTrue(result['_performance_midi_path'].endswith(
                '.piano_v2_2_performance.mid'))
            clean = pretty_midi.PrettyMIDI(export.call_args.args[0])
            played = pretty_midi.PrettyMIDI(result['_performance_midi_path'])
            self.assertEqual(
                [(track.name, sorted(n.pitch for n in track.notes))
                 for track in clean.instruments],
                [(track.name, sorted(n.pitch for n in track.notes))
                 for track in played.instruments],
            )
            self.assertTrue(any(cc.number == 64
                                for track in played.instruments
                                for cc in track.control_changes))

    def test_evidence_supported_instruments_keep_filtered_basic_pitch(self):
        for name in ('Cello', 'Violin', 'Trumpet', 'Saxophone'):
            self.assertTrue(_uses_filtered_basic_pitch_candidate(name, False))

    def test_other_instruments_keep_existing_candidate_selection(self):
        for name in ('Flute', 'Clarinet', 'Piano', 'Guitar', 'Electric Guitar',
                     'Ukulele', 'Bass Guitar', 'Drums', 'Synthesizer', 'Organ'):
            self.assertFalse(_uses_filtered_basic_pitch_candidate(name, False))
        self.assertFalse(_uses_filtered_basic_pitch_candidate('Violin', True))

    def test_musicxml_export_remaps_non_positive_voice_identifiers(self):
        with tempfile.TemporaryDirectory() as directory:
            xml_path = os.path.join(directory, 'voices.musicxml')
            with open(xml_path, 'w', encoding='utf-8') as handle:
                handle.write('''<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="4.0"><part-list><score-part id="P1"><part-name>Test</part-name></score-part></part-list><part id="P1"><measure number="1"><attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time><staves>2</staves></attributes><note><rest/><duration>4</duration><voice>0</voice><type>whole</type><staff>1</staff></note><backup><duration>4</duration></backup><note><rest/><duration>4</duration><voice>1</voice><type>whole</type><staff>2</staff></note></measure></part></score-partwise>''')
            _normalize_musicxml_voice_numbers(xml_path)
            with open(xml_path, encoding='utf-8') as handle:
                contents = handle.read()
            self.assertNotIn('<voice>0</voice>', contents)
            self.assertIn('<voice>2</voice>', contents)
            self.assertIn('<voice>1</voice>', contents)

    def test_rest_sections_preserve_overlapping_lead_and_short_rests(self):
        notes = [pretty_midi.Note(80, 60, 4, 8), pretty_midi.Note(80, 62, 5, 6),
                 pretty_midi.Note(80, 64, 9, 10)]
        self.assertEqual(_melody_rest_sections(notes, 14), [(0, 4), (10, 14)])

    def test_section_recovery_keeps_original_notes_and_rejects_uncertainty(self):
        from unittest.mock import patch
        import soundfile as sf
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, 'lead.mid')
            sf.write(os.path.join(directory, 'other.wav'), np.ones(8000*8)*.01, 8000)
            def transcribe(audio, target, *args, **kwargs):
                _write_midi(target, [('Candidate', [(65, .5, 1, 80)])])
                return {}
            for confidence, count in [(None, 1), (.4, 1), (.8, 2)]:
                _write_midi(path, [('Lead', [(72, 4, 8, 90)])])
                with patch('transcribe_pipeline.transcribe_stem', side_effect=transcribe), patch(
                        'transcribe_pipeline.validate_transcription', return_value={'alignment_confidence': confidence}), patch(
                        'transcribe_pipeline._melody_contour_instability', return_value=0):
                    report = _recover_instrumental_sections(path, directory, (40, 96))
                notes = [n for t in pretty_midi.PrettyMIDI(path).instruments for n in t.notes]
                self.assertEqual(len(notes), count)
                self.assertTrue(any(n.pitch == 72 and n.start == 4 and n.end == 8 for n in notes))
                self.assertEqual(report[0]['notes_added'], count-1)

    def test_band_export_preserves_delayed_first_attack(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, 'delayed.mid')
            xml = os.path.join(directory, 'delayed.musicxml')
            _write_midi(path, [('Piano', [(72, 5.125, 6, 80), (48, 5.25, 7, 65)])])
            midi_to_musicxml(path, xml, 'Piano', Grid(120, '4/4', 'C', 'major'), 'harmony', band_mode=True)
            score = converter.parse(xml)
            first = next(iter(score.parts[0].recurse().notes))
            self.assertEqual(float(first.getOffsetInHierarchy(score.parts[0])), 10.25)

    def test_polyphonic_holds_are_not_retriggered_or_pruned(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, 'holds.mid')
            _write_midi(path, [('Piano', [(p, 0, 2, 75) for p in (48, 52, 55, 60, 64)] + [(72, .5, .8, 85)])])
            score = _polyphonic_score_from_midi(path, Grid(120, '4/4', 'C', 'major'))
            events = list(score.recurse().notes)
            self.assertEqual(sum(len(n.pitches) for n in events), 6)
            held = next(n for n in events if len(n.pitches) == 5)
            self.assertEqual(held.duration.quarterLength, 4)

    def test_role_fallback_considers_instrumental_sources(self):
        from unittest.mock import patch
        with patch('transcribe_pipeline.os.path.exists', return_value=True), patch(
                'transcribe_pipeline._audio_rms', side_effect=[.001, .02, .08, .01]):
            self.assertEqual(_role_source_fallback('vocals', 'stems'), 'piano')
        with patch('transcribe_pipeline.os.path.exists', return_value=True), patch(
                'transcribe_pipeline._audio_rms', side_effect=[.03, .02, .08, .01]):
            self.assertEqual(_role_source_fallback('vocals', 'stems'), 'vocals')

    def test_piano_export_reduces_impossible_simultaneous_stack(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, 'complete.mid')
            _write_midi(path, [('Isolated melody', [(72, 0, .04, 25), (74, .04, .2, 70)]),
                               ('Piano', [(p, 0, .5, 60) for p in (36, 48, 55, 59, 60, 64, 67)])])
            score = _piano_score_from_midi(path, Grid(120, '4/4', 'C', 'major'))
            pitches = [p.midi for event in score.recurse().notes for p in event.pitches]
            # The sheet prints a compact voicing; the complete chord remains
            # in the separate MIDI performance used for audio playback.
            self.assertEqual(sorted(pitches), [36, 48, 60, 72, 74])
            self.assertLessEqual(
                max(len(list(part.recurse().getElementsByClass(stream.Voice)))
                    for part in score.parts),
                2,
            )

    def test_piano_notation_uses_sixteenth_grid_and_at_most_two_voices(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, 'noisy.mid')
            _write_midi(path, [('Piano', [
                (60 + index % 8, index * .04, index * .04 + .42, 72)
                for index in range(20)
            ])])

            score = _piano_score_from_midi(
                path, Grid(120, '4/4', 'C', 'major'))

            for part in score.parts:
                self.assertLessEqual(
                    len(list(part.recurse().getElementsByClass(stream.Voice))), 2)
                for event in part.recurse().notes:
                    self.assertAlmostEqual(
                        float(event.offset) * 4,
                        round(float(event.offset) * 4),
                    )
                    self.assertGreaterEqual(float(event.quarterLength), 0.25)

    def test_piano_held_note_survives_next_attack_and_export(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, 'held.mid')
            xml = os.path.join(directory, 'held.musicxml')
            _write_midi(path, [('Isolated melody', [
                (64, 0, 2, 90), (67, .5, 1, 90),
            ]), ('Piano', [(48, 0, 2, 80), (50, .5, 1, 80)])])
            midi_to_musicxml(path, xml, 'Piano', Grid(120, '4/4', 'C'), 'melody')
            score = converter.parse(xml)
            held = [n for n in score.parts[0].recurse().notes if 64 in [p.midi for p in n.pitches]]
            self.assertAlmostEqual(sum(float(n.quarterLength) for n in held), 4)
            for part in score.parts:
                for measure in part.getElementsByClass(stream.Measure):
                    self.assertLessEqual(float(measure.highestTime), 4)

    def test_note_positions_use_playback_clock_despite_raw_beat_drift(self):
        grid = Grid(120, '4/4', 'C', beat_times=(0.2, 0.8, 1.4, 2.0),
                    tempo_map=({'offset': 0, 'bpm': 120},
                               {'offset': 4, 'bpm': 60}))
        self.assertAlmostEqual(grid.seconds_to_quarter(1), 2)
        self.assertAlmostEqual(grid.seconds_to_quarter(2), 4)
        self.assertAlmostEqual(grid.seconds_to_quarter(3), 5)

    def test_piano_release_overlaps_do_not_expand_bars(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, 'overlaps.mid')
            xml = os.path.join(directory, 'overlaps.musicxml')
            _write_midi(path, [('Piano', [
                (48 + i % 5, i * .25, i * .25 + .4, 80)
                for i in range(32)
            ]), ('Isolated melody', [
                (64 + i % 4, i * .25, i * .25 + .3, 90)
                for i in range(32)
            ])])
            midi_to_musicxml(path, xml, 'Piano', Grid(120, '4/4', 'C'), 'melody')
            score = converter.parse(xml)
            for part in score.parts:
                for measure in part.getElementsByClass(stream.Measure):
                    self.assertLessEqual(float(measure.highestTime), 4)

    def test_quiet_piano_decay_and_stereo_phase_do_not_remove_attack(self):
        import soundfile as sf
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, 'piano.mid')
            audio_path = os.path.join(directory, 'piano.wav')
            _write_midi(path, [('Piano', [(60, 0, 1, 80), (64, 1.5, 1.8, 80)])])
            audio = np.zeros((2000, 2))
            audio[:80, 0] = 0.1
            audio[:80, 1] = -0.1
            sf.write(audio_path, audio, 1000)
            stats = _gate_inactive_passages(path, audio_path)
            notes = pretty_midi.PrettyMIDI(path).instruments[0].notes
            self.assertEqual([n.pitch for n in notes], [60])
            self.assertEqual(stats['inactive_notes_removed'], 1)

    def test_validation_penalizes_wrong_octave_and_late_entry(self):
        source = np.zeros((36, 20))
        source[12, :10] = 1
        octave = np.zeros_like(source)
        octave[24, :10] = 1
        late = np.zeros_like(source)
        late[12, 10:] = 1
        self.assertEqual(_fixed_time_pitch_similarity(source, source)['alignment_confidence'], 1)
        self.assertEqual(_fixed_time_pitch_similarity(source, octave)['alignment_confidence'], 0)
        result = _fixed_time_pitch_similarity(source, late)
        self.assertEqual(result['alignment_confidence'], 0)
        self.assertEqual(result['missing_activity_fraction'], 1)

    def test_band_piano_and_conductor_preserve_pitch_activity(self):
        with tempfile.TemporaryDirectory() as directory:
            midi_path = os.path.join(directory, 'piano.mid')
            xml_path = os.path.join(directory, 'piano.musicxml')
            _write_midi(midi_path, [('Piano', [
                (48, 0, 1, 80), (64, 0.25, 0.75, 75), (67, 1.5, 2, 70),
            ])])
            grid = Grid(120, '4/4', 'C')
            midi_to_musicxml(midi_path, xml_path, 'Piano', grid, 'harmony', band_mode=True)
            individual = converter.parse(xml_path)
            combined = _build_band_score([{'instrument': 'Piano', 'role': 'harmony',
                                          'musicxml': xml_path}], grid)
            combined_path = os.path.join(directory, 'band.musicxml')
            _write_musicxml(combined, combined_path)
            conductor = converter.parse(combined_path)
            def activity(score):
                result = set()
                for part in score.parts:
                    for event in part.recurse().notes:
                        start = float(event.getOffsetInHierarchy(part))
                        for tick in range(round(start * 8), round((start + float(event.quarterLength)) * 8)):
                            result.update((tick, pitch.midi) for pitch in event.pitches)
                return result
            self.assertEqual(activity(individual), activity(conductor))

    def test_repeated_notes_preserve_silence_and_separate_attacks(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, 'rests.mid')
            _write_midi(path, [('Guitar', [
                (60, 0, 0.25, 80), (60, 1, 1.25, 80),
                (60, 1.25, 1.5, 80),
            ])])
            score = _polyphonic_score_from_midi(path, Grid(120, '4/4', 'C'))
            self.assertEqual(
                [(float(n.offset), float(n.quarterLength))
                 for n in score.parts[0].notes],
                [(0.0, 0.5), (2.0, 0.5), (2.5, 0.5)],
            )


class TranscriptionPipelineTests(unittest.TestCase):
    def test_piano_bass_support_only_fills_missing_low_passages(self):
        with tempfile.TemporaryDirectory() as directory:
            arrangement_path = os.path.join(directory, 'piano.mid')
            bass_path = os.path.join(directory, 'bass.mid')
            _write_midi(arrangement_path, [('Piano', [
                (48, 0.0, 1.0, 70), (64, 0.0, 1.0, 75),
                (67, 2.0, 3.0, 75),
            ])])
            _write_midi(bass_path, [('Bass', [
                (36, 0.0, 1.0, 70), (38, 2.0, 3.0, 70),
            ])])

            added = _merge_bass_support_into_piano(
                arrangement_path, bass_path)
            result = pretty_midi.PrettyMIDI(arrangement_path)
            pitches = [event.pitch for track in result.instruments
                       for event in track.notes]

            self.assertEqual(added, 1)
            self.assertIn(38, pitches)
            self.assertNotIn(36, pitches)

    def test_matching_piano_stem_is_used_when_present(self):
        with tempfile.TemporaryDirectory() as directory:
            import soundfile as sf
            sr = 8000
            sf.write(os.path.join(directory, 'piano.wav'),
                     np.full(sr, 0.04, dtype=np.float32), sr)
            sf.write(os.path.join(directory, 'other.wav'),
                     np.full(sr, 0.10, dtype=np.float32), sr)

            self.assertEqual(
                _instrument_specific_stem('Piano', directory), 'piano')
            self.assertIsNone(
                _instrument_specific_stem('Violin', directory))

    def test_quiet_placeholder_piano_stem_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            import soundfile as sf
            sr = 8000
            sf.write(os.path.join(directory, 'piano.wav'),
                     np.full(sr, 0.0002, dtype=np.float32), sr)
            sf.write(os.path.join(directory, 'other.wav'),
                     np.full(sr, 0.10, dtype=np.float32), sr)

            self.assertIsNone(
                _instrument_specific_stem('Piano', directory))

    def test_instrumental_intro_is_added_before_vocal_lead(self):
        with tempfile.TemporaryDirectory() as directory:
            vocal_path = os.path.join(directory, 'vocal.mid')
            instrumental_path = os.path.join(directory, 'instrumental.mid')
            _write_midi(vocal_path, [('Vocal', [(69, 2.0, 3.0, 90)])])
            _write_midi(instrumental_path, [('Instrument', [
                (65, 0.0, 0.8, 78), (67, 0.9, 1.7, 80),
                (60, 2.1, 2.5, 80),  # overlaps vocal and must not replace it
            ])])

            added = _fill_vocal_gaps_with_instrumental(
                vocal_path, instrumental_path)
            result = pretty_midi.PrettyMIDI(vocal_path)
            notes = [event for track in result.instruments for event in track.notes]

            self.assertEqual(added, 2)
            self.assertEqual([event.pitch for event in notes], [65, 67, 69])

    def test_band_keyboard_reduction_avoids_collapsed_grand_staff_clusters(self):
        right = stream.Part()
        left = stream.Part()
        right.insert(0, chord.Chord(['C5', 'E5', 'G5'], quarterLength=2))
        left.insert(0, chord.Chord(['C2', 'G2', 'C3'], quarterLength=2))
        right.insert(1, chord.Chord(['D5', 'F5', 'A5'], quarterLength=1))
        score = stream.Score([right, left])

        events = _compact_band_keyboard_events(score)

        self.assertTrue(events)
        self.assertTrue(all(len(pitches) <= 3 for _, pitches, _ in events))
        self.assertTrue(all(offset == round(offset) for offset, _, _ in events))
        self.assertTrue(all(
            48 <= pitch <= 84
            for _, pitches, _ in events for pitch in pitches
        ))

    def test_band_config_is_validated_before_expensive_audio_processing(self):
        invalid_configs = [
            [{'id': 'one', 'instrument': 'Kazoo', 'role': 'melody'},
             {'id': 'two', 'instrument': 'Piano', 'role': 'harmony'}],
            [{'id': 'one', 'instrument': 'Violin', 'role': 'drums'},
             {'id': 'two', 'instrument': 'Piano', 'role': 'harmony'}],
            [{'id': 'same', 'instrument': 'Violin', 'role': 'melody'},
             {'id': 'same', 'instrument': 'Piano', 'role': 'harmony'}],
        ]
        for configs in invalid_configs:
            with self.subTest(configs=configs), self.assertRaises(ValueError):
                build_pipeline('missing.wav', 'unused-output', 'band', configs)

    def test_incomplete_band_result_is_rejected_with_missing_player_name(self):
        configs = [
            {'id': 'lead', 'instrument': 'Violin', 'role': 'melody'},
            {'id': 'bass', 'instrument': 'Bass Guitar', 'role': 'bass'},
        ]
        with self.assertRaisesRegex(RuntimeError, 'Bass Guitar'):
            _require_complete_band(
                configs,
                [{'id': 'lead', 'instrument': 'Violin'}],
                ['Bass Guitar/bass: no notes'],
            )

    def test_range_filter_rejects_other_voices_before_contour_selection(self):
        midi = pretty_midi.PrettyMIDI()
        track = pretty_midi.Instrument(program=0)
        track.notes = [
            pretty_midi.Note(90, 29, 0.0, 0.5),  # bass leakage
            pretty_midi.Note(90, 55, 0.5, 1.0),  # one octave below flute
            pretty_midi.Note(90, 67, 1.0, 1.5),  # playable flute candidate
        ]
        midi.instruments.append(track)

        removed = _fit_midi_candidates_to_range(midi, (60, 96))

        self.assertEqual(removed, 1)
        self.assertEqual([event.pitch for event in track.notes], [67, 67])

    def test_lead_cleanup_preserves_real_descending_phrase(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, 'descending.mid')
            _write_midi(path, [('Lead', [
                (76, 0.0, 0.4, 90), (72, 0.4, 0.8, 90),
                (69, 0.8, 1.2, 90), (65, 1.2, 1.6, 90),
            ])])
            stats = _clean_lead_contour(path, (55, 100))
            pitches = [n.pitch for i in pretty_midi.PrettyMIDI(path).instruments for n in i.notes]
            self.assertEqual(pitches, [76, 72, 69, 65])
            self.assertEqual(stats['rejected_lead_spikes'], 0)

    def test_lead_cleanup_corrects_isolated_octave_alias(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, 'octave.mid')
            _write_midi(path, [('Lead', [
                (69, 0.0, 0.4, 90), (81, 0.4, 0.8, 90), (70, 0.8, 1.2, 90),
            ])])
            stats = _clean_lead_contour(path, (55, 100))
            pitches = [n.pitch for i in pretty_midi.PrettyMIDI(path).instruments for n in i.notes]
            self.assertEqual(pitches, [69, 69, 70])
            self.assertEqual(stats['octave_corrections'], 1)

    def test_violin_expression_is_sparse_and_centered(self):
        techniques = {
            'vibrato': [
                {'start': 1.0, 'depth': 0.41, 'rate': 8.0},
                {'start': 1.8, 'depth': 0.30, 'rate': 7.5},
                {'start': 4.0, 'depth': 0.05, 'rate': 3.0},
            ],
            'glissando': [
                {'start': 2.0, 'end': 2.5},
                {'start': 3.0, 'end': 3.4},
                {'start': 9.0, 'end': 10.2},
                {'start': 12.0, 'end': 12.5},
            ],
        }
        cleaned = _simplify_violin_techniques(techniques)
        self.assertEqual(len(cleaned['vibrato']), 2)
        self.assertLessEqual(max(v['depth'] for v in cleaned['vibrato']), 0.18)
        self.assertEqual(cleaned['glissando'], [
            {'start': 2.0, 'end': 2.5},
            {'start': 12.0, 'end': 12.5},
        ])

    def test_band_harmony_respects_instrument_polyphony(self):
        flute = _part_voice_settings('Flute', 'harmony')
        piano = _part_voice_settings('Piano', 'harmony')

        self.assertFalse(flute['polyphonic'])
        self.assertTrue(flute['prefer_pyin'])
        self.assertTrue(piano['polyphonic'])
        self.assertFalse(piano['prefer_pyin'])

    def test_corrects_only_isolated_violin_octave_alias(self):
        part = stream.Part()
        for offset, pitch in enumerate((69, 71, 84, 72, 74)):
            part.insert(offset, note.Note(pitch, quarterLength=1))

        corrected = _correct_isolated_violin_octaves(part)

        self.assertEqual(corrected, 1)
        self.assertEqual(
            [event.pitch.midi for event in part.recurse().notes],
            [69, 71, 72, 72, 74],
        )

    def test_keeps_sustained_violin_register_change(self):
        part = stream.Part()
        for offset, pitch in enumerate((69, 71, 83, 84, 86)):
            part.insert(offset, note.Note(pitch, quarterLength=1))

        corrected = _correct_isolated_violin_octaves(part)

        self.assertEqual(corrected, 0)
        self.assertEqual(
            [event.pitch.midi for event in part.recurse().notes],
            [69, 71, 83, 84, 86],
        )

    def test_continuous_lead_wins_small_alignment_difference(self):
        self.assertTrue(_prefer_pyin_lead(0.723, 0.782))
        self.assertFalse(_prefer_pyin_lead(0.60, 0.82))

    def test_detects_odd_five_beat_meter(self):
        beat_frames = np.arange(0, 60 * 12, 12)
        onset_env = np.full(int(beat_frames[-1] + 13), 0.2)
        for index, frame in enumerate(beat_frames):
            onset_env[frame] = 5.0 if index % 5 == 0 else 1.0

        signature, confidence = _detect_time_signature(onset_env, beat_frames)

        self.assertEqual(signature, '5/4')
        self.assertGreater(confidence, 0)

    def test_detects_compound_six_eight_meter(self):
        beat_frames = np.arange(0, 48 * 12, 12)
        onset_env = np.full(int(beat_frames[-1] + 13), 0.2)
        for index, frame in enumerate(beat_frames):
            onset_env[frame] = 5.0 if index % 2 == 0 else 1.0
        for left, right in zip(beat_frames, beat_frames[1:]):
            width = int(right - left)
            onset_env[int(left + width // 3)] = 2.4
            onset_env[int(left + 2 * width // 3)] = 2.2
            onset_env[int(left + width // 2)] = 0.3

        signature, _ = _detect_time_signature(onset_env, beat_frames)

        self.assertEqual(signature, '6/8')

    def test_grid_uses_local_beat_positions(self):
        grid = Grid(120, '4/4', 'C', 'major', (0.0, 0.5, 1.1, 1.6))

        self.assertAlmostEqual(grid.seconds_to_quarter(0.25), 0.5)
        self.assertAlmostEqual(grid.seconds_to_quarter(0.8), 1.5)
        self.assertAlmostEqual(grid.seconds_to_quarter(1.6), 3.0)

    def test_chromatic_pitch_is_not_forced_into_global_key(self):
        grid = Grid(120, '4/4', 'C', 'major')

        self.assertEqual(_snap_to_detected_scale(66, grid, 65), 66)

    def test_isolated_piano_lead_replaces_overlapping_upper_mix_notes(self):
        with tempfile.TemporaryDirectory() as directory:
            arrangement_path = os.path.join(directory, 'arrangement.mid')
            lead_path = os.path.join(directory, 'lead.mid')
            _write_midi(arrangement_path, [('Full mix', [
                (48, 0.0, 1.0, 82),
                (67, 0.0, 1.0, 88),
                (72, 1.2, 1.8, 84),
            ])])
            _write_midi(lead_path, [('Lead', [(64, 0.0, 1.0, 95)])])

            applied = apply_isolated_lead_to_piano(arrangement_path, lead_path)
            result = pretty_midi.PrettyMIDI(arrangement_path)
            tracks = {track.name: track for track in result.instruments}

            self.assertEqual(applied, 1)
            self.assertEqual([item.pitch for item in tracks['Isolated melody'].notes], [64])
            accompaniment_pitches = [
                item.pitch for item in tracks['Piano accompaniment'].notes
            ]
            self.assertIn(48, accompaniment_pitches)
            self.assertIn(72, accompaniment_pitches)
            self.assertIn(67, accompaniment_pitches)

    def test_piano_score_keeps_lead_and_restrained_left_hand_chord(self):
        with tempfile.TemporaryDirectory() as directory:
            midi_path = os.path.join(directory, 'piano.mid')
            _write_midi(midi_path, [
                ('Piano accompaniment', [
                    (48, 0.0, 1.0, 84),
                    (52, 0.0, 1.0, 80),
                    (55, 0.0, 1.0, 78),
                    (58, 0.0, 1.0, 35),
                ]),
                ('Isolated melody', [(64, 0.0, 1.0, 96)]),
            ])

            score = _piano_score_from_midi(
                midi_path, Grid(120, '4/4', 'C', 'major'))
            all_parts = {
                part.partName: list(part.recurse().notes) for part in score.parts
            }

            self.assertEqual(
                [event.pitch.midi for event in all_parts['Piano Right Hand']], [64])
            left_event = all_parts['Piano Left Hand'][0]
            self.assertIsInstance(left_event, (note.Note, chord.Chord))
            self.assertEqual(len(left_event.pitches), 2)
            self.assertEqual(max(pitch.midi for pitch in left_event.pitches), 52)

    def test_piano_fallback_promotes_highest_detected_note(self):
        with tempfile.TemporaryDirectory() as directory:
            midi_path = os.path.join(directory, 'instrumental.mid')
            _write_midi(midi_path, [('Full mix', [
                (37, 0.0, 1.0, 88),
                (57, 0.0, 1.0, 82),
            ])])

            score = _piano_score_from_midi(
                midi_path, Grid(120, '4/4', 'C', 'major'))
            parts = {
                part.partName: list(part.recurse().notes) for part in score.parts
            }

            self.assertEqual(
                parts['Piano Right Hand'][0].pitch.midi,
                57,
            )

    def test_drum_midi_exports_an_unpitched_percussion_staff(self):
        with tempfile.TemporaryDirectory() as directory:
            midi_path = os.path.join(directory, 'drums.mid')
            xml_path = os.path.join(directory, 'drums.musicxml')
            midi = pretty_midi.PrettyMIDI(initial_tempo=120)
            drums = pretty_midi.Instrument(program=0, is_drum=True, name='Drums')
            drums.notes.extend([
                pretty_midi.Note(velocity=100, pitch=36, start=0, end=.1),
                pretty_midi.Note(velocity=90, pitch=38, start=.5, end=.6),
                pretty_midi.Note(velocity=75, pitch=42, start=1, end=1.1),
            ])
            midi.instruments.append(drums)
            midi.write(midi_path)

            midi_to_musicxml(
                midi_path, xml_path, 'Drums',
                Grid(120, '4/4', 'C', 'major'), 'drums')
            with open(xml_path, encoding='utf-8') as exported:
                musicxml = exported.read()

            self.assertIn('<sign>percussion</sign>', musicxml)
            self.assertIn('<unpitched>', musicxml)

    def test_performance_overlaps_are_normalized_for_musicxml(self):
        with tempfile.TemporaryDirectory() as directory:
            xml_path = os.path.join(directory, 'normalized.musicxml')
            part = stream.Part()
            part.insert(0, meter.TimeSignature('4/4'))
            part.append(note.Note('C4', quarterLength=.41))
            part.append(note.Note('E4', quarterLength=.66))
            part.append(note.Note('G4', quarterLength=.16))
            score = stream.Score([part])

            _normalize_musicxml_durations(score)
            part.makeMeasures(inPlace=True)
            score.makeNotation(inPlace=True)
            _normalize_musicxml_durations(score)
            score.write('musicxml', fp=xml_path)

            self.assertTrue(os.path.exists(xml_path))
            for event in score.recurse().notesAndRests:
                self.assertAlmostEqual(
                    float(event.duration.quarterLength) * 8,
                    round(float(event.duration.quarterLength) * 8),
                )

    def test_export_removes_inexpressible_boundary_remainder(self):
        with tempfile.TemporaryDirectory() as directory:
            output_path = os.path.join(directory, 'cello_boundary.musicxml')
            part = stream.Part()
            part.partName = 'Cello (bass)'
            measure = stream.Measure(number=53)
            measure.insert(0, meter.TimeSignature('4/4'))
            measure.insert(0, note.Note('C3', quarterLength=4))
            measure.insert(3.998046875, note.Rest(quarterLength=0.001953125))
            part.append(measure)
            score = stream.Score([part])

            _write_musicxml(score, output_path)

            self.assertTrue(os.path.exists(output_path))
            self.assertFalse(any(
                float(event.duration.quarterLength) < 0.125
                for event in score.recurse().notesAndRests
            ))

    def test_export_removes_stale_2048th_tuplet_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            output_path = os.path.join(directory, 'cello_tuplet.musicxml')
            part = stream.Part()
            part.partName = 'Cello (bass)'
            measure = stream.Measure(number=53)
            broken = note.Rest(quarterLength=0.5)
            stale_tuplet = duration.Tuplet(3, 2)
            stale_tuplet.durationNormal = duration.Duration(1 / 512)
            broken.duration.appendTuplet(stale_tuplet)
            measure.insert(0, broken)
            part.append(measure)
            score = stream.Score([part])

            _write_musicxml(score, output_path)

            self.assertTrue(os.path.exists(output_path))
            self.assertTrue(all(
                not event.duration.tuplets
                for event in score.recurse().notesAndRests
            ))

    def test_export_snaps_off_grid_key_change_without_tiny_rest(self):
        from music21 import key
        with tempfile.TemporaryDirectory() as directory:
            output_path = os.path.join(directory, 'off_grid_key.musicxml')
            part = stream.Part()
            measure = stream.Measure(number=53)
            measure.insert(93667 / 65335, key.Key('C', 'major'))
            measure.insert(3.875, note.Note('F3', quarterLength=0.125))
            part.append(measure)
            score = stream.Score([part])

            _write_musicxml(score, output_path)

            self.assertTrue(os.path.exists(output_path))
            key_change = next(iter(score.recurse().getElementsByClass(key.Key)))
            self.assertAlmostEqual(float(key_change.offset) * 8,
                                   round(float(key_change.offset) * 8))

    def test_band_score_has_one_ordered_staff_per_configured_part(self):
        with tempfile.TemporaryDirectory() as directory:
            results = []
            configs = [
                ('Guitar', 'Guitar 1', 'melody', 'C4'),
                ('Guitar', 'Guitar 2', 'harmony', 'E4'),
                ('Bass Guitar', 'Bass Guitar', 'bass', 'C2'),
                ('Violin', 'Violin', 'harmony', 'G4'),
            ]
            for index, (instrument_name, display_name, role, pitch) in enumerate(configs):
                source_path = os.path.join(directory, f'part_{index}.musicxml')
                source_part = stream.Part()
                source_part.append(note.Note(pitch, quarterLength=1))
                stream.Score([source_part]).write('musicxml', fp=source_path)
                results.append({
                    'instrument': instrument_name,
                    'display_name': display_name,
                    'role': role,
                    'musicxml': source_path,
                })

            combined = _build_band_score(
                results, Grid(120, '4/4', 'C', 'major'),
                title='Example - Full Band Score', artist='Test Arranger')
            output_path = os.path.join(directory, 'band.musicxml')
            combined.write('musicxml', fp=output_path)

            self.assertEqual(len(combined.parts), 4)
            self.assertEqual(
                [part.partName for part in combined.parts],
                ['Guitar 1', 'Guitar 2', 'Bass Guitar', 'Violin'],
            )
            self.assertTrue(all(float(part.offset) == 0.0
                                for part in combined.parts))
            self.assertLessEqual(float(combined.highestTime), 4.0)
            with open(output_path, encoding='utf-8') as exported:
                musicxml = exported.read()
            self.assertIn('<group-symbol>bracket</group-symbol>', musicxml)
            self.assertIn('<group-barline>yes</group-barline>', musicxml)
            self.assertIn('<part-name>Guitar 1</part-name>', musicxml)
            self.assertIn('Example - Full Band Score', musicxml)

    def test_polyphonic_guitar_is_not_measured_twice(self):
        with tempfile.TemporaryDirectory() as directory:
            midi_path = os.path.join(directory, 'guitar.mid')
            xml_path = os.path.join(directory, 'guitar.musicxml')
            _write_midi(midi_path, [('Guitar', [
                (52, 0.0, 1.0, 80), (55, 0.0, 1.0, 80),
                (59, 0.0, 1.0, 80), (53, 3.0, 4.0, 80),
            ])])

            midi_to_musicxml(
                midi_path, xml_path, 'Guitar',
                Grid(120, '4/4', 'C', 'major'), 'harmony')
            exported = stream.Score()
            from music21 import converter
            exported = converter.parse(xml_path)

            self.assertLessEqual(float(exported.highestTime), 9.0)

    def test_polyphonic_guitar_keeps_absolute_attack_times_with_synchronized_tab(self):
        with tempfile.TemporaryDirectory() as directory:
            midi_path = os.path.join(directory, 'guitar.mid')
            xml_path = os.path.join(directory, 'guitar.musicxml')
            _write_midi(midi_path, [('Guitar', [
                # A sustained bass note and staggered upper attacks require
                # distinct notation voices.  The 3.0 attack must not become
                # a later cursor position in the exported standard staff.
                (40, 0.0, 2.0, 80), (55, 0.0, 0.5, 80),
                (59, 0.25, 0.625, 80), (64, 1.5, 1.875, 80),
            ])])
            grid = Grid(120, '4/4', 'C', 'major')
            midi_to_musicxml(midi_path, xml_path, 'Guitar', grid, 'melody')
            exported = converter.parse(xml_path)
            attacks = []
            standard_part = exported.parts[0]
            for event in standard_part.recurse().notes:
                pitches = event.pitches if isinstance(event, chord.Chord) else (event.pitch,)
                for pitch_item in pitches:
                    attacks.append((int(pitch_item.midi),
                                    float(event.getOffsetInHierarchy(standard_part))))
            self.assertIn((64, 3.0), attacks)
            with open(xml_path, encoding='utf-8') as handle:
                source = handle.read()
            self.assertIn('<sign>TAB</sign>', source)
            self.assertIn('<staff-lines>6</staff-lines>', source)
            self.assertIn('<string>', source)
            self.assertIn('<fret>', source)
            self.assertNotIn('<voice>0</voice>', source)

            # The separate TAB part reuses every original voice/backup and
            # therefore has exactly the same absolute attacks as the standard
            # part, including staggered/arpeggiated events and bar boundaries.
            self.assertEqual(len(exported.parts), 2)
            def part_attacks(part):
                result = []
                for event in part.recurse().notes:
                    pitches = (event.pitches if isinstance(event, chord.Chord)
                               else (event.pitch,))
                    onset = round(float(event.getOffsetInHierarchy(part)), 6)
                    result.extend((int(value.midi), onset) for value in pitches)
                return sorted(result)
            self.assertEqual(part_attacks(exported.parts[0]),
                             part_attacks(exported.parts[1]))

            root = ET.parse(xml_path).getroot()
            tab_parts = [part for part in root.findall('part')
                         if part.get('id', '').endswith('_TAB')]
            self.assertEqual(len(tab_parts), 1)
            technical_notes = [item for item in tab_parts[0].iter('note')
                               if item.find('./notations/technical/string') is not None
                               and item.find('./notations/technical/fret') is not None]
            self.assertEqual(len(technical_notes), 4)

    def test_guitar_tab_uses_the_arrangers_canonical_string_and_fret(self):
        """TAB must display the actual Guitar fingering, never a new guess."""
        with tempfile.TemporaryDirectory() as directory:
            midi_path = os.path.join(directory, 'canonical_guitar.mid')
            xml_path = os.path.join(directory, 'canonical_guitar.musicxml')
            _write_midi(midi_path, [('Guitar', [
                (52, 0.0, 1.0, 80),  # string 4, fret 2
                (55, 0.0, 1.0, 80),  # string 3, open
                (60, 0.0, 1.0, 80),  # string 2, fret 1
            ])])
            with open(midi_path + '.fingering.json', 'w', encoding='utf-8') as handle:
                json.dump({'events': [
                    {'start_quarter': 0.0, 'pitch': 52, 'string': 4, 'fret': 2},
                    {'start_quarter': 0.0, 'pitch': 55, 'string': 3, 'fret': 0},
                    {'start_quarter': 0.0, 'pitch': 60, 'string': 2, 'fret': 1},
                ]}, handle)
            midi_to_musicxml(midi_path, xml_path, 'Guitar',
                             Grid(120, '4/4', 'C', 'major'), 'melody')
            root = ET.parse(xml_path).getroot()
            tab_part = next(part for part in root.findall('part')
                            if part.get('id', '').endswith('_TAB'))
            positions = {}
            for item in tab_part.iter('note'):
                pitch = item.find('pitch')
                technical = item.find('./notations/technical')
                if pitch is None or technical is None:
                    continue
                step = pitch.findtext('step')
                octave = pitch.findtext('octave')
                if step is None or octave is None:
                    continue
                semitones = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11}
                midi_pitch = (int(octave) + 1) * 12 + semitones[step] + int(pitch.findtext('alter', '0'))
                positions[midi_pitch] = (int(technical.findtext('string')),
                                         int(technical.findtext('fret')))
            self.assertEqual(positions, {52: (4, 2), 55: (3, 0), 60: (2, 1)})

    def test_band_score_does_not_copy_guitar_tab_as_an_extra_voice(self):
        with tempfile.TemporaryDirectory() as directory:
            source_path = os.path.join(directory, 'guitar_with_tab.musicxml')
            standard = stream.Part()
            standard.partName = 'Guitar'
            standard.insert(0, clef.TrebleClef())
            standard.insert(0, chord.Chord(['C4', 'E4'], quarterLength=4))
            tablature = stream.Part()
            tablature.partName = 'Guitar TAB'
            tablature.insert(0, clef.TabClef())
            tablature.insert(0, chord.Chord(['C4', 'E4'], quarterLength=4))
            source = stream.Score()
            source.insert(0, standard)
            source.insert(0, tablature)
            source.write('musicxml', fp=source_path)

            combined = _build_band_score([{
                'instrument': 'Guitar',
                'display_name': 'Guitar',
                'role': 'harmony',
                'musicxml': source_path,
            }], Grid(120, '4/4', 'C', 'major'))
            output_path = os.path.join(directory, 'band.musicxml')
            _write_musicxml(combined, output_path)
            reparsed = converter.parse(output_path)

            self.assertEqual(len(reparsed.parts), 1)
            self.assertLessEqual(float(reparsed.parts[0].highestTime), 4.0)
            self.assertEqual(len(reparsed.parts[0].recurse().notes), 1)

    def test_unstable_pyin_loses_to_better_aligned_stable_lead(self):
        self.assertFalse(_prefer_pyin_lead(
            0.754, 0.775, margin=0.14,
            pyin_instability=0.135,
            basic_instability=0.041,
        ))

    def test_major_key_uses_readable_enharmonic_spelling(self):
        self.assertEqual(_preferred_key_name(1, 'major'), 'D-')
        self.assertEqual(_preferred_key_name(6, 'major'), 'G-')

    def test_transposing_instruments_export_in_concert_pitch(self):
        with tempfile.TemporaryDirectory() as directory:
            midi_path = os.path.join(directory, 'trumpet.mid')
            xml_path = os.path.join(directory, 'trumpet.musicxml')
            _write_midi(midi_path, [('Trumpet', [(60, 0, 1, 90)])])

            midi_to_musicxml(
                midi_path, xml_path, 'Trumpet',
                Grid(120, '4/4', 'C', 'major'), 'melody')
            with open(xml_path, encoding='utf-8') as exported:
                musicxml = exported.read()

            self.assertNotIn('<transpose>', musicxml)
            self.assertIn('<step>C</step>', musicxml)


if __name__ == '__main__':
    unittest.main()
