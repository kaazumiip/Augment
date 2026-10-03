import unittest
from unittest.mock import Mock
import pretty_midi
from piano_noteoff_renderer import owned_note_events,has_same_key_overlap,render_piano_safe

class NoteOffTests(unittest.TestCase):
    def track(self,notes):
        t=pretty_midi.Instrument(0)
        t.notes=[pretty_midi.Note(80,p,s,e) for p,s,e in notes]
        return t
    def test_old_release_does_not_release_new_attack(self):
        t=self.track([(60,0,.3),(60,.2,.6)])
        events=list(owned_note_events(t))
        self.assertIn((.3,'obsolete note off',60,0),events)
        self.assertIn((.6,'note off',60,0),events)
    def test_nested_and_triple_repeats(self):
        t=self.track([(60,0,1),(60,.2,.8),(60,.4,.6)])
        self.assertEqual([e[0] for e in owned_note_events(t) if e[1]=='note off'],[.6])
    def test_different_keys_keep_overlap(self):
        t=self.track([(60,0,.3),(64,.2,.6)])
        self.assertFalse(has_same_key_overlap(t))
        self.assertEqual(sum(e[1]=='note off' for e in owned_note_events(t)),2)
    def test_touching_repeats_have_off_before_on(self):
        t=self.track([(60,0,.2),(60,.2,.4)])
        self.assertFalse(has_same_key_overlap(t))
        self.assertEqual([e[1] for e in owned_note_events(t) if e[0]==.2],['note off','note on'])
    def test_cc_and_midi_unchanged(self):
        t=self.track([(60,0,.3),(60,.2,.6)])
        t.control_changes=[pretty_midi.ControlChange(64,88,.1),pretty_midi.ControlChange(64,0,.5)]
        original=[vars(n).copy() for n in t.notes]
        events=list(owned_note_events(t))
        self.assertEqual([vars(n) for n in t.notes],original)
        self.assertEqual([e for e in events if e[1]=='control change'],[(.1,'control change',64,88),(.5,'control change',64,0)])
    def test_no_collision_uses_exact_original_renderer(self):
        midi=Mock();midi.instruments=[self.track([(60,0,.2),(64,.1,.3)])]
        midi.fluidsynth.return_value='original'
        self.assertEqual(render_piano_safe(midi,'font',44100,{0}),'original')
        midi.fluidsynth.assert_called_once_with(fs=44100,sf2_path='font')

if __name__=='__main__':unittest.main()
