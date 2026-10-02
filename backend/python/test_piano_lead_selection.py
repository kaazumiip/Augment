import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import pretty_midi
from transcribe_pipeline import _select_supported_piano_lead


class PianoLeadSelectionTests(unittest.TestCase):
    def write(self, path, pitch):
        midi = pretty_midi.PrettyMIDI()
        track = pretty_midi.Instrument(0)
        track.notes = [pretty_midi.Note(80, pitch, 0, .5)]
        midi.instruments.append(track)
        midi.write(path)

    def test_good_primary_is_unchanged_and_does_not_run_extra_models(self):
        with patch('transcribe_pipeline.transcribe_stem') as transcribe:
            stats = {'alignment_confidence': .7}
            source, actual, accepted = _select_supported_piano_lead('vocals.wav', 'lead.mid', stats, '.')
            self.assertTrue(accepted)
            self.assertIs(actual, stats)
            self.assertEqual(source, 'vocals.wav')
            transcribe.assert_not_called()

    def run_case(self, scores):
        with tempfile.TemporaryDirectory() as directory:
            for name in ('vocals.wav', *scores):
                # Paths only: all source/model activity is mocked.
                open(os.path.join(directory, name), 'wb').close()
            target = os.path.join(directory, 'lead.mid')
            self.write(target, 84)
            before = Path(target).read_bytes()
            def transcribe(source, output, **kwargs):
                self.assertFalse(kwargs['polyphonic'])
                self.write(output, 74 if source.endswith('other.wav') else 76)
                return {'notes': 1}
            with patch('transcribe_pipeline._audio_rms', return_value=.02), \
                 patch('transcribe_pipeline.transcribe_stem', side_effect=transcribe), \
                 patch('transcribe_pipeline.validate_transcription',
                       side_effect=lambda s, m: {'alignment_confidence': scores[os.path.basename(s)]}):
                source, stats, accepted = _select_supported_piano_lead(
                    os.path.join(directory, 'vocals.wav'), target,
                    {'alignment_confidence': .091}, directory)
            self.assertFalse(any('.candidate.mid' in f for f in os.listdir(directory)))
            return source, stats, accepted, before == Path(target).read_bytes(), pretty_midi.PrettyMIDI(target).instruments[0].notes[0].pitch

    def test_weak_vocals_select_best_supported_instrumental_source(self):
        source, stats, accepted, unchanged, pitch = self.run_case({'other.wav': .65, 'piano.wav': .81})
        self.assertTrue(accepted)
        self.assertEqual(os.path.basename(source), 'piano.wav')
        self.assertEqual(pitch, 76)
        self.assertEqual(len(stats['source_selection']['candidates']), 3)

    def test_weak_candidates_do_not_become_a_protected_melody(self):
        source, stats, accepted, unchanged, pitch = self.run_case({'other.wav': .25, 'piano.wav': .19})
        self.assertFalse(accepted)
        self.assertTrue(unchanged)
        self.assertTrue(stats['rejected_as_unreliable_lead'])
        self.assertIsNone(stats['source_selection']['selected_source'])

    def test_supported_guitar_stem_can_supply_piano_lead(self):
        source, stats, accepted, unchanged, pitch = self.run_case(
            {'other.wav': .25, 'piano.wav': .19, 'guitar.wav': .72})
        self.assertTrue(accepted)
        self.assertEqual(os.path.basename(source), 'guitar.wav')
        self.assertEqual(stats['source_selection']['selected_source'], 'guitar.wav')

    def test_weak_guitar_stem_does_not_force_a_lead(self):
        source, stats, accepted, unchanged, pitch = self.run_case(
            {'other.wav': .25, 'piano.wav': .19, 'guitar.wav': .30})
        self.assertFalse(accepted)
        self.assertTrue(unchanged)


if __name__ == '__main__':
    unittest.main()
