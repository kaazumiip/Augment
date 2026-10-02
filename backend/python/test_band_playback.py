"""Band playback retains source attacks and renderer failures remain recoverable."""
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import app
import pretty_midi
import numpy as np
from scipy.io import wavfile
from band_performance import violin_performance_events


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
             patch.object(app, '_render_solo_violin_v3_1', return_value=(True, .1)) as fallback:
            self.assertEqual(app._render_band_part_audio(part, 'unused.wav', 120),
                             (True, .1))
            self.assertTrue(fallback.called)
            self.assertIn('Solo phrasing', part['renderer_used'])

    def test_violin_uses_solo_expression_without_changing_band_identity(self):
        notes=[dict(offset=i*.5,duration=.5,pitches=['C5' if i<2 else 'D5'],velocity=85)
               for i in range(4)]
        planned, events, diagnostics=violin_performance_events(notes,60)
        self.assertEqual(len(events),4)
        for source, event in zip(notes,events):
            self.assertEqual(event['onset'],source['offset'])
            self.assertEqual(event['duration'],source['duration'])
            self.assertEqual(event['pitch'],pretty_midi.note_name_to_number(source['pitches'][0]))
        self.assertGreater(diagnostics['phrase_count'],0)
        self.assertGreater(len(events[0]['expression_curve']),2)
        self.assertTrue(any(e['articulation']=='rearticulated' for e in events))

    def test_stereo_does_not_cancel_out_of_phase_violin(self):
        with tempfile.TemporaryDirectory() as folder:
            source=str(Path(folder)/'stereo.wav')
            target=str(Path(folder)/'mixed.wav')
            samples=np.column_stack((np.full(4410,10000,dtype=np.int16),
                                     np.full(4410,-10000,dtype=np.int16)))
            wavfile.write(source,44100,samples)
            success,duration=app._mix_band_part_audio(
                [dict(path=source,success=True,role='melody')],target)
            self.assertTrue(success)
            rate,output=wavfile.read(target)
            self.assertEqual(output.shape,samples.shape)
            self.assertGreater(np.max(np.abs(output)),0)
            self.assertTrue(np.all(output[:,0]>0))
            self.assertTrue(np.all(output[:,1]<0))


if __name__ == '__main__':
    unittest.main()
