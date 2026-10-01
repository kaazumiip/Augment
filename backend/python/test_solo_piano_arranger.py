import os
import tempfile
import unittest
import pretty_midi
from transcribe_pipeline import Grid
from solo_piano_arranger import (
    arrange_pianist_v2,
    build_plan,
    perform_pianist_v2_1,
    perform_pianist_v2_2,
    ensure_piano_melody_track,
)


class SoloPianoPlanTests(unittest.TestCase):
    def test_same_source_attack_is_not_cloned_into_both_hands(self):
        # Different overlap-register pitches and genuine repeated onsets:
        # no song name, absolute timestamp or pitch-specific exception.
        for pitch in (52, 55, 58, 59):
            with self.subTest(pitch=pitch), tempfile.TemporaryDirectory() as directory:
                source = os.path.join(directory, 'source.mid')
                target = os.path.join(directory, 'result.mid')
                midi = pretty_midi.PrettyMIDI(initial_tempo=100)
                support = pretty_midi.Instrument(0, name='Piano accompaniment')
                support.notes = [pretty_midi.Note(63, pitch, start, start + .1)
                                 for start in (.2, .25, 1.5)]
                melody = pretty_midi.Instrument(0, name='Isolated melody')
                melody.notes = [pretty_midi.Note(94, 76, 2, 2.5)]
                midi.instruments.extend([support, melody])
                midi.write(source)
                stats = arrange_pianist_v2(source, target, self.grid)
                output = pretty_midi.PrettyMIDI(target)
                attacks = [n for t in output.instruments for n in t.notes
                           if n.pitch == pitch]
                self.assertEqual(len(attacks), 3)
                self.assertEqual(stats['prevented_cross_hand_duplicates'], 3)
                self.assertEqual([round(n.start, 2) for n in attacks], [.2, .25, 1.5])
                self.assertTrue(all(n.velocity == 63 for n in attacks))
                lead = next(t for t in output.instruments if t.name == 'Isolated melody')
                self.assertEqual(len(lead.notes), 1)
                self.assertEqual(lead.notes[0].pitch, 76)

    def test_missing_lead_never_fabricates_highest_note_melody(self):
        midi = pretty_midi.PrettyMIDI()
        track = pretty_midi.Instrument(0, name='Detected Piano')
        track.notes = [pretty_midi.Note(70, pitch, time, time + .4)
                       for pitch, time in [(48, 0), (72, 0), (50, 1), (74, 1)]]
        midi.instruments.append(track)
        before = sorted((n.pitch, n.start, n.end, n.velocity) for n in track.notes)
        report = ensure_piano_melody_track(midi)
        after = sorted((n.pitch, n.start, n.end, n.velocity)
                       for t in midi.instruments for n in t.notes)
        self.assertEqual(before, after)
        self.assertEqual(report['source'], 'unavailable')
        self.assertFalse(report['fallback'])
        self.assertEqual(len(midi.instruments), 1)
        self.assertEqual(midi.instruments[0].name, 'Detected Piano')
        self.assertFalse(ensure_piano_melody_track(midi)['fallback'])

    def setUp(self):
        self.grid = Grid(100, '4/4', 'C', 'major', chord_sections=(
            {'start_seconds': 0, 'end_seconds': 4, 'root_pc': 0,
             'quality': 'major', 'tones': [0,4,7], 'confidence': .8},))
        self.melody = [{'pitch': 72, 'start': 0, 'end': .5, 'velocity': 90}]

    def test_no_piano_song_has_complete_plan(self):
        plan = build_plan(self.grid, 4, melody=self.melody,
            bass=[{'pitch':36,'start':0,'end':1,'velocity':70}], accompaniment=[])
        self.assertFalse(plan['existing_piano']['available'])
        self.assertEqual(plan['sections'][0]['bass_chord_relation'], 'root-position evidence')

    def test_inversion_conflict_and_low_confidence_are_reported(self):
        inversion = build_plan(self.grid, 4, bass=[{'pitch':40,'start':0,'end':1,'velocity':70}])
        self.assertEqual(inversion['sections'][0]['bass_chord_relation'], 'possible inversion evidence')
        conflict = build_plan(self.grid, 4, bass=[{'pitch':42,'start':0,'end':1,'velocity':70}])
        self.assertEqual(conflict['sections'][0]['harmony_support'], 'conflicting')

    def test_duplicates_dense_melody_and_piano_bass_risk(self):
        dense = self.melody * 17
        piano = [{'pitch':36,'start':0,'end':1,'velocity':80}, *self.melody]
        plan = build_plan(self.grid,4,melody=dense,bass=[{'pitch':36,'start':0,'end':1,'velocity':70}],piano=piano)
        self.assertTrue(plan['duplicate_candidates'])
        self.assertEqual(plan['sections'][0]['melody_density'], 'high')
        self.assertIn('existing Piano/bass duplication risk', plan['sections'][0]['conflicts'])

    def test_plan_does_not_mutate_source_events(self):
        source = [dict(self.melody[0])]
        build_plan(self.grid,4,melody=source)
        self.assertEqual(source[0]['pitch'],72)

    def test_v2_preserves_protected_melody_and_uses_only_source_pitches(self):
        with tempfile.TemporaryDirectory() as directory:
            source = os.path.join(directory, 'v1.mid')
            target = os.path.join(directory, 'v2.mid')
            baseline = pretty_midi.PrettyMIDI(initial_tempo=100)
            accompaniment = pretty_midi.Instrument(program=0, name='Piano accompaniment')
            accompaniment.notes = [
                pretty_midi.Note(70, 36, 0, .8),
                pretty_midi.Note(65, 48, 0, .8),
                pretty_midi.Note(60, 55, .5, 1.1),
                pretty_midi.Note(64, 60, .5, 1.1),
            ]
            melody = pretty_midi.Instrument(program=0, name='Isolated melody')
            melody.notes = [
                pretty_midi.Note(100, 72, 0, .5),
                pretty_midi.Note(96, 74, .7, 1.2),
            ]
            baseline.instruments.extend([accompaniment, melody])
            baseline.write(source)

            stats = arrange_pianist_v2(source, target, self.grid)
            rendered = pretty_midi.PrettyMIDI(target)
            rendered_melody = next(track for track in rendered.instruments
                                   if track.name == 'Isolated melody').notes
            self.assertEqual([note.pitch for note in rendered_melody], [72, 74])
            for actual, expected in zip(rendered_melody, [(0.0, .5), (.7, 1.2)]):
                self.assertAlmostEqual(actual.start, expected[0], places=2)
                self.assertAlmostEqual(actual.end, expected[1], places=2)
            source_pitches = {36, 48, 55, 60, 72, 74}
            self.assertTrue(all(note.pitch in source_pitches
                                for track in rendered.instruments
                                for note in track.notes))
            self.assertEqual(stats['melody_notes_changed'], 0)
            self.assertEqual(stats['protected_melody_retained'], 2)

    def test_v2_1_changes_expression_not_v2_musical_content(self):
        with tempfile.TemporaryDirectory() as directory:
            source = os.path.join(directory, 'v2.mid')
            target = os.path.join(directory, 'v2_1.mid')
            midi = pretty_midi.PrettyMIDI(initial_tempo=100)
            left = pretty_midi.Instrument(program=0, name='Piano left hand')
            right = pretty_midi.Instrument(program=0, name='Piano right hand support')
            melody = pretty_midi.Instrument(program=0, name='Isolated melody')
            left.notes = [pretty_midi.Note(65, 36, 0, .8)]
            right.notes = [pretty_midi.Note(62, 60, 0, .8)]
            melody.notes = [
                pretty_midi.Note(90, 72, 0, .5),
                pretty_midi.Note(88, 74, .55, 1.1),
            ]
            midi.instruments.extend([left, right, melody])
            midi.write(source)

            stats = perform_pianist_v2_1(source, target, self.grid)
            performed = pretty_midi.PrettyMIDI(target)
            self.assertEqual(stats['v2_note_count'], stats['v2_1_note_count'])
            self.assertEqual(stats['pitch_changes'], 0)
            self.assertEqual(stats['notes_added'], 0)
            self.assertEqual(stats['notes_removed'], 0)
            self.assertEqual(
                [[note.pitch for note in track.notes] for track in performed.instruments],
                [[36], [60], [72, 74]],
            )
            self.assertTrue(any(change.number == 64
                                for change in performed.instruments[0].control_changes))

    def test_v2_2_preserves_notes_hands_and_clears_pedal_before_change(self):
        with tempfile.TemporaryDirectory() as directory:
            source = os.path.join(directory, 'v2.mid')
            previous = os.path.join(directory, 'v2_1.mid')
            target = os.path.join(directory, 'v2_2.mid')
            midi = pretty_midi.PrettyMIDI(initial_tempo=100)
            left = pretty_midi.Instrument(program=0, name='Piano left hand')
            right = pretty_midi.Instrument(program=0, name='Piano right hand support')
            melody = pretty_midi.Instrument(program=0, name='Isolated melody')
            left.notes = [pretty_midi.Note(60, 36, 0, .7),
                          pretty_midi.Note(60, 43, 2, 2.7)]
            right.notes = [pretty_midi.Note(60, 60, 0, .7),
                           pretty_midi.Note(60, 64, 2, 2.7)]
            melody.notes = [pretty_midi.Note(82, 72, 0, .5),
                            pretty_midi.Note(82, 72, .6, 1.1),
                            pretty_midi.Note(82, 74, 2, 2.6)]
            midi.instruments.extend([left, right, melody])
            midi.write(source)
            grid = Grid(100, '4/4', 'C', 'major', chord_sections=(
                {'start_seconds': 0, 'end_seconds': 2, 'root_pc': 0,
                 'quality': 'major', 'tones': [0, 4, 7], 'confidence': .8},
                {'start_seconds': 2, 'end_seconds': 4, 'root_pc': 7,
                 'quality': 'major', 'tones': [7, 11, 2], 'confidence': .8},))
            perform_pianist_v2_1(source, previous, grid)
            report = perform_pianist_v2_2(source, previous, target, grid)
            result = pretty_midi.PrettyMIDI(target)
            for original, performed in zip(midi.instruments, result.instruments):
                self.assertEqual(original.name, performed.name)
                self.assertEqual(sorted(n.pitch for n in original.notes),
                                 sorted(n.pitch for n in performed.notes))
            self.assertEqual(report['notes_added'], 0)
            self.assertEqual(report['notes_removed'], 0)
            self.assertLessEqual(report['maximum_timing_deviation_seconds'], .012)
            pedal = [cc for cc in result.instruments[0].control_changes
                     if cc.number == 64]
            self.assertTrue(any(cc.value == 0 and cc.time < 2 and cc.time > 1.9
                                for cc in pedal))
