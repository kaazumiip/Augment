"""Electric-only clean picked performance; no invented bends or sample switches."""
import json
from pathlib import Path

import pretty_midi


def apply_clean_electric_performance(midi_path):
    """Keep every pitch/attack/fingering, balance backing and control its ringing.

    Melody durations remain protected. Accompaniment damping is limited to
    crowded gestures, rather than globally shortening every guitar note.
    """
    path = Path(str(midi_path) + '.fingering.json')
    plan = json.loads(path.read_text(encoding='utf-8'))
    events = plan['events']
    melody = sorted((e for e in events if e['role'] == 'melody'),
                    key=lambda e: e['start'])
    changed_velocity = changed_release = 0
    for event in events:
        if event['role'] == 'melody':
            # A clean electric solo needs the lead above the chord bed.
            velocity = min(112, max(78, event['velocity']))
            event['electric_articulation'] = 'picked_lead'
        else:
            velocity = max(32, min(76, round(event['velocity'] * .86)))
            event['electric_articulation'] = 'picked_support'
            nearby = [n for n in melody
                      if event['start'] - .02 <= n['start'] < event['start'] + .65]
            if len(nearby) >= 3:
                # Leave at least a quarter second of support; do not turn
                # sparse or lyrical passages into universally staccato notes.
                end = min(event['end'], event['start'] + .45)
                if end < event['end']:
                    event['end'] = end
                    event['duration'] = end - event['start']
                    event['ring_until'] = end
                    event['let_ring'] = False
                    event['mute_reason'] = 'electric_dense_lead_damping'
                    changed_release += 1
        changed_velocity += velocity != event['velocity']
        event['velocity'] = velocity
    midi = pretty_midi.PrettyMIDI(str(midi_path))
    if len(midi.instruments) != 1 or len(midi.instruments[0].notes) != len(events):
        raise ValueError('Electric performance requires a matching canonical guitar plan')
    track = midi.instruments[0]
    track.program = 27
    track.name = 'Solo Electric Guitar clean picked performance'
    track.notes = [pretty_midi.Note(e['velocity'], e['pitch'], e['start'], e['end'])
                   for e in events]
    midi.write(str(midi_path))
    path.write_text(json.dumps(plan, indent=2), encoding='utf-8')
    performance_path = Path(str(midi_path) + '.performance_plan.json')
    if performance_path.exists():
        performance = json.loads(performance_path.read_text(encoding='utf-8'))
        performance['events'] = events
        performance['electric_performance'] = 'clean_picked_v1'
        performance_path.write_text(json.dumps(performance, indent=2), encoding='utf-8')
    return {'electric_guitar_version': 'clean_picked_v1',
            'electric_velocity_adjustments': int(changed_velocity),
            'electric_support_releases': changed_release,
            'electric_notes_added': 0, 'electric_notes_removed': 0}
