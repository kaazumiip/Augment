import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np
import pretty_midi
from solo_flute_melody_accuracy import correct_consensus_pitches, apply_flute_melody_accuracy


class FluteAccuracyTests(unittest.TestCase):
    def setUp(self):
        self.events = [dict(start=0., end=.3, pitch=72, velocity=80),
                       dict(start=.3, end=.6, pitch=84, velocity=82),
                       dict(start=.6, end=.9, pitch=72, velocity=81)]
        self.candidates = [dict(start=.3, end=.6, pitch=72, confidence=.9)]
        self.times = np.arange(0., .9, .01)

    def test_supported_octave_correction_preserves_identity(self):
        corrected, changes = correct_consensus_pitches(self.events, self.candidates,
            self.times, np.full(len(self.times), 72.), np.full(len(self.times), .9),
            np.full(len(self.times), .2))
        self.assertEqual([n['pitch'] for n in corrected], [72, 72, 72])
        self.assertEqual(self.events[1]['pitch'], 84)
        self.assertEqual(len(changes), 1)
        self.assertEqual([(n['start'], n['end'], n['velocity']) for n in corrected],
                         [(n['start'], n['end'], n['velocity']) for n in self.events])
        json.dumps(changes)

    def test_disagreement_and_weak_source_do_not_change_notes(self):
        for confidence, tracked_pitch in [(.9, 67.), (.4, 72.)]:
            candidates=[dict(start=.3,end=.6,pitch=72,confidence=confidence)]
            corrected, changes=correct_consensus_pitches(self.events,candidates,self.times,
                np.full(len(self.times),tracked_pitch),np.full(len(self.times),.9),
                np.full(len(self.times),.2))
            self.assertEqual(corrected,self.events)
            self.assertFalse(changes)

    def test_production_adapter_keeps_notes_ccs_and_timing(self):
        import librosa
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'detector.json'
            path.write_text(json.dumps({'events':[dict(pitch=72,onset_seconds=.3,
                offset_seconds=.6,confidence=.9)]}))
            midi=pretty_midi.PrettyMIDI()
            track=pretty_midi.Instrument(73)
            for n in self.events:
                track.notes.append(pretty_midi.Note(n['velocity'],n['pitch'],n['start'],n['end']))
            track.control_changes=[pretty_midi.ControlChange(11,90,.2)]
            track.pitch_bends=[pretty_midi.PitchBend(25,.4)]
            midi.instruments=[track]
            expected=[(n.start,n.end,n.velocity) for n in track.notes]
            f0=librosa.midi_to_hz(np.full(len(self.times),72.))
            with patch('librosa.load',return_value=(np.ones(22050),22050)), \
                 patch('librosa.pyin',return_value=(f0,np.ones(len(f0),dtype=bool),np.full(len(f0),.9))), \
                 patch('librosa.feature.rms',return_value=np.full((1,len(f0)),.2)), \
                 patch('librosa.frames_to_time',return_value=self.times):
                stats=apply_flute_melody_accuracy(midi,'unused.wav',str(path))
            self.assertEqual([n.pitch for n in track.notes],[72,72,72])
            self.assertEqual([(n.start,n.end,n.velocity) for n in track.notes],expected)
            self.assertEqual([(c.number,c.value,c.time) for c in track.control_changes],[(11,90,.2)])
            self.assertEqual([(b.pitch,b.time) for b in track.pitch_bends],[(25,.4)])
            self.assertEqual(stats['notes_added'],0)
            self.assertEqual(stats['notes_removed'],0)
            json.dumps(stats)


if __name__=='__main__': unittest.main()
