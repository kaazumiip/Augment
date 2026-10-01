"""Band playback retains source attacks and renderer failures remain recoverable."""
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import app
import pretty_midi


class BandPlaybackTests(unittest.TestCase):
    def test_exact_band_midi_attacks(self):
        with tempfile.TemporaryDirectory() as folder:
            path = str(Path(folder) / 'notes.mid')
            midi = pretty_midi.PrettyMIDI(initial_tempo=120)
            track = pretty_midi.Instrument(73)
            track.notes = [pretty_midi.Note(70+i, 72, i*.04, i*.04+.03)
                           for i in range(5)]
            midi.instruments = [track]
            midi.write(path)
            stored = pretty_midi.PrettyMIDI(path).instruments[0].notes
            events = app._extract_performance_notes(
                path, 'Flute', 120, preserve_band_performance=True)
            self.assertEqual(len(events), 5)
            for i, event in enumerate(events):
                self.assertAlmostEqual(event['offset']*.5, stored[i].start, places=8)
                self.assertAlmostEqual(event['duration']*.5,
                                       stored[i].end-stored[i].start, places=8)
                self.assertEqual(event['velocity'], 70+i)

    def test_band_violin_failure_falls_back_without_losing_notes(self):
        part = dict(instrument='Violin', is_band=True,
                    notes=[dict(offset=0., duration=.2, pitches=['C5'], velocity=80)])
        with patch.object(app, '_render_solo_violin_vpo',
                          side_effect=AssertionError('conversion failed')), \
             patch.object(app, 'parts_to_wav', return_value=(True, .1)) as fallback:
            self.assertEqual(app._render_band_part_audio(part, 'unused.wav', 120),
                             (True, .1))
            self.assertEqual(fallback.call_args.args[0], [part])


if __name__ == '__main__':
    unittest.main()
