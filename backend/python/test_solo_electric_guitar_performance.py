import json
import tempfile
import unittest
from pathlib import Path

import pretty_midi
from solo_electric_guitar_performance import apply_clean_electric_performance


class CleanElectricTests(unittest.TestCase):
    def test_protected_lead_and_dense_support(self):
        events = [dict(pitch=64 + i, start=i * .15, end=i * .15 + .12,
                       duration=.12, velocity=65, role='melody', string=1,
                       fret=i, ring_until=i * .15 + .12)
                  for i in range(3)]
        events.append(dict(pitch=48, start=0, end=1.5, duration=1.5,
                           velocity=90, role='bass', string=5, fret=3,
                           ring_until=1.5))
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder, 'electric.mid')
            midi = pretty_midi.PrettyMIDI()
            track = pretty_midi.Instrument(24)
            track.notes = [pretty_midi.Note(e['velocity'], e['pitch'],
                                            e['start'], e['end']) for e in events]
            midi.instruments.append(track)
            midi.write(str(path))
            sidecar = Path(str(path) + '.fingering.json')
            sidecar.write_text(json.dumps({'events': events}))
            report = apply_clean_electric_performance(path)
            result = json.loads(sidecar.read_text())['events']
            for before, after in zip(events, result):
                for field in ('pitch', 'start', 'string', 'fret'):
                    self.assertEqual(before[field], after[field])
                if before['role'] == 'melody':
                    self.assertEqual(before['end'], after['end'])
                    self.assertGreater(after['velocity'], result[-1]['velocity'])
            self.assertEqual(len(result), len(events))
            self.assertEqual(report['electric_support_releases'], 1)
            self.assertEqual(pretty_midi.PrettyMIDI(str(path)).instruments[0].program, 27)


if __name__ == '__main__':
    unittest.main()
