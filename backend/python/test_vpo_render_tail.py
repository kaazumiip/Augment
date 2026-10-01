"""Renderer regression: bound SFZ release without touching musical messages."""
import tempfile
import unittest
from pathlib import Path
import mido
from solo_violin_vpo_renderer import _bound_render_tail


class RenderTailTest(unittest.TestCase):
    def test_musical_messages_unchanged(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'test.mid'
            midi = mido.MidiFile(ticks_per_beat=480)
            track = mido.MidiTrack()
            midi.tracks.append(track)
            track.extend([
                mido.MetaMessage('set_tempo', tempo=500000),
                mido.Message('note_on', note=69, velocity=80, time=480),
                mido.Message('control_change', control=1, value=64, time=120),
                mido.Message('note_off', note=69, time=360),
                mido.MetaMessage('end_of_track', time=1)])
            midi.save(path)
            before = [str(m) for m in mido.MidiFile(path).tracks[0]
                      if m.type != 'end_of_track']
            _bound_render_tail(path)
            after = mido.MidiFile(path)
            self.assertEqual(before, [str(m) for m in after.tracks[0]
                                     if m.type != 'end_of_track'][:-1])
            self.assertEqual(after.tracks[0][-2].control, 120)
            self.assertAlmostEqual(after.length, 5.0010416667)


if __name__ == '__main__':
    unittest.main()
