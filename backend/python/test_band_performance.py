import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np
import pretty_midi
from music21 import converter
from scipy.io import wavfile
from band_performance import coordinate_band, transcribe_layered_drums
from transcribe_pipeline import (Grid, _monophonic, _chord_candidate,
    _band_notation_subdivision, midi_to_musicxml, _build_band_score, _write_musicxml)
from score_validation import audit_score


def midi_with(notes, program=73):
    midi=pretty_midi.PrettyMIDI(initial_tempo=120)
    track=pretty_midi.Instrument(program)
    track.notes=[pretty_midi.Note(v,p,s,e) for p,s,e,v in notes]
    midi.instruments=[track]
    return midi


class BandPerformanceTests(unittest.TestCase):
    def test_viewer_grid_never_requires_microscopic_rest_glyphs(self):
        with tempfile.TemporaryDirectory() as folder:
            path = str(Path(folder) / 'dense.mid')
            midi_with([(60+i%5,i*.003,i*.003+.05,80)
                       for i in range(20)]).write(path)
            grid = Grid(120,'4/4','C','major')
            self.assertLessEqual(_band_notation_subdivision(path,grid),32)

    def test_band_repeated_attacks_survive_overlapping_releases(self):
        midi=midi_with([(72,0,.2,80),(72,.1,.3,80),(74,.2,.4,82)])
        selected=_monophonic(midi,preserve_attacks=True)
        self.assertEqual([(n.pitch,n.start) for n in selected.instruments[0].notes],
                         [(72,0),(72,.1),(74,.2)])
        self.assertEqual(selected.instruments[0].notes[0].end,.1)

    def test_solo_monophonic_default_is_unchanged(self):
        midi=midi_with([(72,0,.2,80),(72,.1,.3,80)])
        self.assertEqual(len(_monophonic(midi).instruments[0].notes),1)

    def test_coordination_preserves_lead_and_all_note_identities(self):
        lead=midi_with([(72,0,.4,85)])
        harmony=midi_with([(72,0,.4,85),(64,0,.4,80)],0)
        before=[(n.pitch,n.start,n.end) for n in harmony.instruments[0].notes]
        report=coordinate_band([
            ({'id':'lead','role':'melody'},lead,''),
            ({'id':'harmony','role':'harmony'},harmony,'')])
        self.assertEqual(lead.instruments[0].notes[0].velocity,85)
        self.assertEqual([(n.pitch,n.start,n.end) for n in harmony.instruments[0].notes],before)
        self.assertLess(harmony.instruments[0].notes[0].velocity,harmony.instruments[0].notes[1].velocity)
        self.assertEqual(report['harmony']['notes_removed'],0)

    def test_extended_chords_do_not_replace_solo_triad_detection(self):
        for quality,tones in [('maj7',[0,4,7,11]),('dom7',[0,4,7,10]),
                              ('sus2',[0,2,7]),('dim',[0,3,6])]:
            profile=np.zeros(12)
            profile[tones]=1
            profile[0]=1.5
            self.assertEqual(_chord_candidate(profile,extended=True)[1],quality)
            self.assertIn(_chord_candidate(profile)[1],['major','minor'])

    def test_fast_attack_scores_and_combined_score_preserve_all_notes(self):
        with tempfile.TemporaryDirectory() as folder:
            results=[]
            for signature in ['4/4','3/4','6/8']:
                grid=Grid(120,signature,'C','major')
                mid=str(Path(folder)/'source.mid')
                xml=str(Path(folder)/'part.musicxml')
                source=midi_with([(p,i*.04,i*.04+.03,80)
                                 for i,p in enumerate([72,73,73,76,84])])
                source.write(mid)
                midi_to_musicxml(mid,xml,'Flute',grid,'melody',band_mode=True)
                report=audit_score(xml,mid,grid)
                self.assertEqual(report['missing_attack_count'],0)
                self.assertFalse(report['overfull_measures'])
                parts=[dict(instrument='Flute',role='melody',musicxml=xml,
                    notation_subdivision=_band_notation_subdivision(mid,grid))]
                combined=_build_band_score(parts,grid)
                combined_path=str(Path(folder)/'combined.musicxml')
                _write_musicxml(combined,combined_path,
                    subdivision=combined._augment_notation_subdivision)
                self.assertEqual(audit_score(combined_path,mid,grid)['missing_attack_count'],0)

    def test_triplet_attacks_keep_triplet_notation(self):
        with tempfile.TemporaryDirectory() as folder:
            mid=str(Path(folder)/'source.mid')
            xml=str(Path(folder)/'part.musicxml')
            source=midi_with([(60+i%5,i/6,i/6+.12,80) for i in range(18)])
            source.write(mid)
            grid=Grid(120,'4/4','C','major')
            self.assertEqual(_band_notation_subdivision(mid,grid),12)
            midi_to_musicxml(mid,xml,'Piano',grid,'harmony',band_mode=True)
            self.assertEqual(audit_score(xml,mid,grid)['missing_attack_count'],0)
            self.assertIn('time-modification',Path(xml).read_text())

    def test_layered_drums_allow_a_kick_and_hat_at_the_same_time(self):
        with tempfile.TemporaryDirectory() as folder:
            import scipy.signal
            sr=22050
            rng=np.random.default_rng(123)
            audio=np.zeros(sr*2)
            count=int(sr*.16)
            t=np.arange(count)/sr
            kick=np.sin(2*np.pi*60*t)*np.exp(-t*25)
            hat=scipy.signal.sosfilt(scipy.signal.butter(4,6000,fs=sr,
                btype='highpass',output='sos'),rng.normal(size=count))*np.exp(-t*40)
            for onset in [.3,.8,1.3]:
                start=int(onset*sr)
                audio[start:start+count]+=kick+hat*.5
            path=str(Path(folder)/'drums.wav')
            mid=str(Path(folder)/'drums.mid')
            wavfile.write(path,sr,audio.astype(np.float32))
            report=transcribe_layered_drums(path,mid)
            notes=pretty_midi.PrettyMIDI(mid).instruments[0].notes
            self.assertTrue(any(a.pitch==36 and b.pitch==42 and abs(a.start-b.start)<.04
                                for a in notes for b in notes))
            self.assertTrue(report['simultaneous_hits_allowed'])


if __name__=='__main__': unittest.main()
