import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import pretty_midi

from app import _extract_performance_notes
from transcribe_pipeline import Grid, _transcribe_solo_guitar_cover, midi_to_musicxml


class ElectricPerformanceTests(unittest.TestCase):
    def test_physical_arrangement_and_tab_keep_the_same_melody(self):
        notes = [pretty_midi.Note(85, p, i*.5, i*.5+.35)
                 for i, p in enumerate([64, 67, 69, 67, 64, 65, 67, 64])]
        def transcription(source, target, *args, **kwargs):
            midi = pretty_midi.PrettyMIDI(initial_tempo=120)
            track = pretty_midi.Instrument(0)
            track.notes = notes
            midi.instruments.append(track)
            midi.write(str(target))
            return {'notes': len(notes)}
        grid = Grid(120, '4/4', 'C', chord_sections=({
            'start_seconds': 0, 'end_seconds': 4,
            'root_pc': 0, 'quality': 'major', 'confidence': .9},))
        with tempfile.TemporaryDirectory() as folder:
            Path(folder, 'vocals.wav').touch()
            Path(folder, 'other.wav').touch()
            with patch('transcribe_pipeline._audio_rms', return_value=.1), \
                 patch('transcribe_pipeline._transcribe_vocal_melody', side_effect=transcription), \
                 patch('transcribe_pipeline.transcribe_stem', side_effect=transcription), \
                 patch('transcribe_pipeline.validate_transcription', return_value={}):
                path = str(Path(folder, 'electric.mid'))
                report = _transcribe_solo_guitar_cover(folder, path, 4, grid,
                                                     'Electric Guitar')
            midi = pretty_midi.PrettyMIDI(path)
            self.assertEqual(midi.instruments[0].program, 27)
            plan = json.loads(Path(path+'.fingering.json').read_text())
            melody = [e for e in plan['events'] if e['role'] == 'melody']
            self.assertEqual([e['pitch'] for e in melody], [n.pitch for n in notes])
            self.assertTrue(report['canonical_performance_validation']['valid'])
            self.assertTrue(any(e['role'] != 'melody' for e in plan['events']))
            playback = _extract_performance_notes(path, 'Electric Guitar', 120)
            self.assertEqual(len(playback), len(midi.instruments[0].notes))
            self.assertTrue(all(e['preserve_guitar_performance'] for e in playback))
            xml = str(Path(folder, 'electric.musicxml'))
            midi_to_musicxml(path, xml, 'Electric Guitar', grid, 'melody')
            content = Path(xml).read_text()
            self.assertIn('<fret>', content)
            self.assertIn('<string>', content)


if __name__ == '__main__':
    unittest.main()
