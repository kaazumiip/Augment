import tempfile
import unittest
from pathlib import Path

import app
import pretty_midi
from transcribe_pipeline import Grid, _monophonic, _flute_score_from_midi


class FluteShortReleaseTests(unittest.TestCase):
    def test_playback_keeps_short_duration_and_rest(self):
        events = [dict(offset=0., duration=.08, pitches=['C5'], velocity=80),
                  dict(offset=.5, duration=.4, pitches=['D5'], velocity=80)]
        plan = app._lead_performance_plan('Flute', events, .5)
        self.assertAlmostEqual(plan[0]['duration'], .04)
        self.assertEqual(plan[0]['start'], 0.)
        self.assertAlmostEqual(plan[1]['start'], .25)

    def test_selection_preserves_separate_repeated_attacks_and_gap(self):
        midi = pretty_midi.PrettyMIDI()
        track = pretty_midi.Instrument(73)
        track.notes = [pretty_midi.Note(80,72,0,.1),
                       pretty_midi.Note(80,72,.16,.26)]
        midi.instruments = [track]
        result = _monophonic(midi, preserve_releases=True)
        self.assertEqual(len(result.instruments[0].notes), 2)
        self.assertEqual(result.instruments[0].notes[0].end, .1)

    def test_isolated_short_note_notation_and_extraction(self):
        with tempfile.TemporaryDirectory() as folder:
            midi = pretty_midi.PrettyMIDI(initial_tempo=60)
            track = pretty_midi.Instrument(73)
            track.notes = [pretty_midi.Note(80,72,0,.04)]
            midi.instruments = [track]
            path = str(Path(folder) / 'short.mid')
            midi.write(path)
            stored = pretty_midi.PrettyMIDI(path).instruments[0].notes[0]
            events = app._extract_performance_notes(path, 'Flute', 60)
            self.assertAlmostEqual(events[0]['duration'], stored.end-stored.start)
            score = _flute_score_from_midi(path, Grid(60,'4/4','C','major'))
            written = list(score.recurse().notes)[0]
            self.assertLess(abs(float(written.quarterLength)-.04), .02)


if __name__ == '__main__':
    unittest.main()
