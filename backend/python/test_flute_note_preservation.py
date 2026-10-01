import tempfile
import unittest
from pathlib import Path

import pretty_midi
from music21 import converter
from transcribe_pipeline import Grid, _flute_score_from_midi, midi_to_musicxml


class FluteNotePreservationTests(unittest.TestCase):
    def test_short_repeated_and_chromatic_attacks_survive_export(self):
        with tempfile.TemporaryDirectory() as folder:
            midi_path = str(Path(folder) / 'flute.mid')
            xml_path = str(Path(folder) / 'flute.musicxml')
            midi = pretty_midi.PrettyMIDI(initial_tempo=120)
            track = pretty_midi.Instrument(73)
            expected = [72, 73, 73, 76, 84]
            for index, pitch in enumerate(expected):
                track.notes.append(pretty_midi.Note(
                    80, pitch, index * .04, index * .04 + .12))
            midi.instruments.append(track)
            midi.write(midi_path)
            grid = Grid(120, '4/4', 'C', 'major')
            score = _flute_score_from_midi(midi_path, grid)
            self.assertEqual([n.pitch.midi for n in score.recurse().notes], expected)
            midi_to_musicxml(midi_path, xml_path, 'Flute', grid, 'melody')
            attacks = [n for n in converter.parse(xml_path).recurse().notes
                       if n.tie is None or n.tie.type == 'start']
            self.assertEqual([n.pitch.midi for n in attacks], expected)


if __name__ == '__main__':
    unittest.main()
