import unittest
import app
import pretty_midi
from transcribe_pipeline import _monophonic, _part_voice_settings


class SaxophonePerformanceTests(unittest.TestCase):
    def test_short_notes_and_rests_are_not_extended(self):
        events = [dict(offset=i*.3, duration=.08, pitches=['C5'], velocity=80)
                  for i in range(10)]
        plans = app._saxophone_performance_plan(events, .5)
        for i, plan in enumerate(plans):
            self.assertAlmostEqual(plan['start'], i*.15)
            self.assertAlmostEqual(plan['duration'], .04)
            self.assertFalse(any(plan[x] for x in ('ghost','scoop','fall','growl','vibrato')))

    def test_overlaps_are_clipped_not_retriggered_or_extended(self):
        events = [dict(offset=0, duration=1, pitches=['C5'], velocity=80),
                  dict(offset=.2, duration=.1, pitches=['D5'], velocity=80)]
        plans = app._saxophone_performance_plan(events, .5)
        self.assertAlmostEqual(plans[0]['duration'], .1)
        self.assertAlmostEqual(plans[1]['duration'], .05)

    def test_monophonic_selection_keeps_repeated_attacks(self):
        midi = pretty_midi.PrettyMIDI()
        track = pretty_midi.Instrument(66)
        track.notes = [pretty_midi.Note(80,72,0,.1), pretty_midi.Note(80,72,.16,.26)]
        midi.instruments = [track]
        result = _monophonic(midi, preserve_releases=True)
        self.assertEqual(len(result.instruments[0].notes), 2)
        self.assertEqual(result.instruments[0].notes[0].end, .1)
        self.assertFalse(_part_voice_settings('Saxophone','melody')['polyphonic'])


if __name__ == '__main__':
    unittest.main()
