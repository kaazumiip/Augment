import unittest
import ast,os
from pathlib import Path
import pretty_midi
from piano_local_melody_evidence import supported_vocal_notes

class LocalEvidenceTests(unittest.TestCase):
    def test_accepted_primary_bypasses_recovery(self):
        tree=ast.parse(Path(__file__).with_name('transcribe_pipeline.py').read_text(encoding='utf-8'))
        function=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='_select_supported_piano_lead')
        namespace={'os':os}
        exec(compile(ast.Module(body=[function],type_ignores=[]),'selector_test','exec'),namespace)
        stats={'alignment_confidence':.517,'notes':28}
        source,result,accepted=namespace[function.name]('vocals.wav','nonexistent.mid',stats,'nonexistent')
        self.assertTrue(accepted)
        self.assertIs(result,stats)
        self.assertEqual(stats,{'alignment_confidence':.517,'notes':28})
    def test_supported_phrase_preserves_attacks(self):
        notes=[pretty_midi.Note(80,60+i%2,i*.2,i*.2+.15) for i in range(5)]
        runs=[{'pitch':n.pitch,'start':n.start,'end':n.end,'confidence':.8} for n in notes]
        kept=supported_vocal_notes(notes,runs)
        self.assertEqual([(n.pitch,n.start,n.end) for n in notes],[(n.pitch,n.start,n.end) for n in kept])
    def test_wrong_pitch_and_low_confidence_rejected(self):
        notes=[pretty_midi.Note(80,60,i*.2,i*.2+.15) for i in range(5)]
        for pitch,confidence in [(61,.9),(60,.4)]:
            runs=[{'pitch':pitch,'start':n.start,'end':n.end,'confidence':confidence} for n in notes]
            self.assertEqual(supported_vocal_notes(notes,runs),[])
    def test_isolated_notes_do_not_establish_phrase(self):
        notes=[pretty_midi.Note(80,60,i*2,i*2+.15) for i in range(5)]
        runs=[{'pitch':60,'start':n.start,'end':n.end,'confidence':.9} for n in notes]
        self.assertEqual(supported_vocal_notes(notes,runs),[])
    def test_local_spectral_phrase_survives_pyin_dropout(self):
        notes=[pretty_midi.Note(80,60+i%3,i*.2,i*.2+.15) for i in range(5)]
        scores={(n.pitch,n.start,n.end):.65 for n in notes}
        self.assertEqual(len(supported_vocal_notes(notes,[],scores)),5)
    def test_weak_spectral_evidence_is_not_forced(self):
        notes=[pretty_midi.Note(80,60,i*.2,i*.2+.15) for i in range(5)]
        scores={(n.pitch,n.start,n.end):.2 for n in notes}
        self.assertEqual(supported_vocal_notes(notes,[],scores),[])
