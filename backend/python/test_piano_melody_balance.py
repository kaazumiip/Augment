import unittest
import pretty_midi
from solo_piano_arranger import balance_protected_piano_melody


class PianoMelodyBalanceTests(unittest.TestCase):
    def test_held_lead_ducks_support_without_changing_music(self):
        midi = pretty_midi.PrettyMIDI()
        lead = pretty_midi.Instrument(0, name='Isolated melody')
        lead.notes = [pretty_midi.Note(75, 72, 0, 3)]
        support = pretty_midi.Instrument(0, name='Piano right hand support')
        support.notes = [pretty_midi.Note(68, 64, 1, 2),
                         pretty_midi.Note(68, 65, 4, 5)]
        support.control_changes = [pretty_midi.ControlChange(64, 88, 0)]
        midi.instruments = [lead, support]
        before = [(n.pitch, n.start, n.end) for t in midi.instruments for n in t.notes]
        report = balance_protected_piano_melody(midi)
        self.assertEqual(report['support_notes_softened'], 1)
        self.assertEqual(support.notes[0].velocity, 53)
        self.assertEqual(support.notes[1].velocity, 68)
        self.assertEqual(lead.notes[0].velocity, 75)
        self.assertEqual(before, [(n.pitch, n.start, n.end) for t in midi.instruments for n in t.notes])
        self.assertEqual(support.control_changes[0].value, 88)

    def test_unlabelled_detection_is_not_guessed(self):
        midi = pretty_midi.PrettyMIDI()
        track = pretty_midi.Instrument(0, name='Detected piano')
        track.notes = [pretty_midi.Note(90, 80, 0, 1)]
        midi.instruments = [track]
        self.assertEqual(balance_protected_piano_melody(midi)['support_notes_softened'], 0)
        self.assertEqual(track.notes[0].velocity, 90)


if __name__ == '__main__':
    unittest.main()
