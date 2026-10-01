"""Regression coverage for short lead recovery and exported melody identity."""
import hashlib
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np
import pretty_midi
from music21 import converter

from transcribe_pipeline import (
    Grid, _recover_short_piano_lead, midi_to_musicxml,
    _transcribe_vocal_melody,
)
from score_validation import audit_score


class PianoShortMelodyTests(unittest.TestCase):
    def recover(self, pitch=74, confidence=.9, next_start=.30):
        track = pretty_midi.Instrument(0, name='Isolated melody')
        track.notes = [pretty_midi.Note(85, 72, 0, .20),
                       pretty_midi.Note(85, 76, next_start, next_start + .2)]
        times = np.arange(0, next_start + .3, .01)
        pitches = np.full(len(times), np.nan)
        probabilities = np.zeros(len(times))
        mask = (times >= .20) & (times < .28)
        pitches[mask] = pitch
        probabilities[mask] = confidence
        identities = [(n.pitch, n.start, n.end, n.velocity) for n in track.notes]
        recovered = _recover_short_piano_lead(
            track, times, pitches, probabilities, np.isfinite(pitches))
        return track, recovered, identities

    def test_supported_short_run_added_without_changing_existing_notes(self):
        track, recovered, identities = self.recover()
        self.assertEqual(len(recovered), 1)
        self.assertEqual(recovered[0]['pitch'], 74)
        self.assertAlmostEqual(recovered[0]['end']-recovered[0]['start'], .08)
        self.assertEqual([(n.pitch,n.start,n.end,n.velocity) for n in track.notes
                          if n.pitch != 74], identities)

    def test_octave_spike_uncertain_pitch_and_real_rest_are_preserved(self):
        for options in ({'pitch': 86}, {'confidence': .4}, {'next_start': 1.0},
                        {'pitch': 72}):
            track, recovered, identities = self.recover(**options)
            self.assertEqual(recovered, [])
            self.assertEqual([(n.pitch,n.start,n.end,n.velocity) for n in track.notes], identities)

    def test_short_pitch_smoothed_into_preceding_hold_is_recovered(self):
        times = np.arange(0, .8, .01)
        pitches = np.where(times < .40,72.,np.where(times < .48,74.,76.))
        track = pretty_midi.Instrument(0)
        track.notes = [pretty_midi.Note(85,72,0,.52),pretty_midi.Note(85,76,.52,.8)]
        recovered = _recover_short_piano_lead(
            track,times,pitches,np.full(len(times),.9),np.ones(len(times),dtype=bool))
        self.assertEqual(len(recovered),1)
        self.assertTrue(recovered[0]['preceding_release_corrected'])
        self.assertAlmostEqual(track.notes[0].end,.40)
        self.assertEqual([n.pitch for n in track.notes],[72,74,76])
        self.assertAlmostEqual(track.notes[-1].start,.52)

    def test_piano_opt_in_recovers_detector_short_run_other_instruments_unchanged(self):
        import librosa
        pitches = np.array([72]*20+[74]*4+[76]*20)
        f0 = librosa.midi_to_hz(pitches)
        probabilities = np.full(len(f0),.9)
        voiced = np.ones(len(f0),dtype=bool)
        with tempfile.TemporaryDirectory() as folder, \
                patch('librosa.load',return_value=(np.full(512*44,.1),22050)), \
                patch('librosa.pyin',return_value=(f0,voiced,probabilities)):
            baseline = _transcribe_vocal_melody('source.wav',os.path.join(folder,'old.mid'))
            improved = _transcribe_vocal_melody('source.wav',os.path.join(folder,'new.mid'),
                                                recover_short_piano=True)
            self.assertEqual(baseline['notes'],2)
            self.assertEqual(improved['notes'],3)
            self.assertEqual(improved['short_piano_notes_recovered'][0]['pitch'],74)

    def test_fast_and_repeated_lead_attacks_survive_musicxml_export(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, 'source.mid')
            xml = os.path.join(folder, 'score.musicxml')
            midi = pretty_midi.PrettyMIDI(initial_tempo=172)
            lead = pretty_midi.Instrument(0, name='Isolated melody')
            # Separate same-pitch attacks and a short ascending run under chords.
            lead.notes = [pretty_midi.Note(85, pitch, onset, onset+.07)
                          for pitch,onset in [(72,.10),(72,.19),(74,.28),(76,.37),
                                              (77,.46),(76,.55),(74,.64)]]
            support = pretty_midi.Instrument(0, name='Piano right hand support')
            support.notes = [pretty_midi.Note(65, pitch, onset, onset+.6)
                             for onset in (0,.15,.30,.45,.60)
                             for pitch in (60,64,67)]
            midi.instruments = [lead, support]
            midi.write(path)
            before = hashlib.sha256(Path(path).read_bytes()).hexdigest()
            grid = Grid(172, '4/4', 'C', 'major')
            midi_to_musicxml(path, xml, 'Piano', grid, 'melody')
            audit = audit_score(xml, path, grid)
            self.assertEqual(audit['expected_attacks'], 7)
            self.assertEqual(audit['missing_attack_count'], 0)
            self.assertEqual(audit['overfull_measures'], [])
            written = converter.parse(xml)
            self.assertGreaterEqual(sum(1 for n in written.recurse().notes
                                       if getattr(getattr(n,'pitch',None),'midi',None)==72), 2)
            self.assertEqual(hashlib.sha256(Path(path).read_bytes()).hexdigest(),before)


if __name__ == '__main__':
    unittest.main()
