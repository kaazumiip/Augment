"""Isolated, deterministic performance interpretation of canonical Guitar events.

The returned notes are MIDI-only.  The input list and score/TAB sidecars are
never mutated; score timing is intentionally distinct from performed timing.
"""

from collections import Counter, defaultdict


def _moment_at(time, moments):
    return next((row for row in moments
                 if row['start'] - .001 <= time < row['end'] + .001),
                moments[-1] if moments else {})


def _gesture_type(group):
    roles = {event['role'] for event in group}
    if len(group) == 1:
        return 'melody_pluck' if 'melody' in roles else 'support_pluck'
    if any(event.get('stroke_direction') for event in group):
        return 'downward_roll' if group[0].get('stroke_direction') == 'down' else 'upward_roll'
    if 'melody' in roles and 'bass' in roles:
        return 'bass_melody_pinch'
    if 'melody' in roles and 'inner' in roles:
        return 'melody_harmony_pluck'
    return 'fingerstyle_chord' if len(group) >= 3 else 'support_dyad'


def perform_guitar_events(canonical, moments=()):
    """Return performed copies plus an audit; pitch/string/fret are untouched."""
    source = sorted(canonical, key=lambda e: (float(e['start']), int(e['string'])))
    groups = defaultdict(list)
    for index, event in enumerate(source):
        groups[event.get('gesture_id', index)].append((index, event))
    performed = [None] * len(source)
    classifications = Counter()
    spreads = []
    phrase_levels = defaultdict(list)
    section_levels = defaultdict(list)
    for members in groups.values():
        group = [event for _, event in members]
        kind = _gesture_type(group)
        classifications[kind] += 1
        first = min(float(event['start']) for event in group)
        moment = _moment_at(first, moments)
        density = int(moment.get('density', 0))
        phrase = moment.get('phrase_position', 'middle')
        # Only data already present in the arrangement governs expression.
        phrase_gain = {'start': -2, 'middle': 1, 'end': -3,
                       'cadence': -2}.get(phrase, 0)
        density_gain = 2 if density >= 5 else (-1 if density <= 1 else 0)
        spread = 0.0
        if len(group) > 1:
            if kind.endswith('roll'):
                spread = .012 if density < 5 else .007
            elif kind == 'bass_melody_pinch':
                spread = .006 if density < 5 else .003
            else:
                spread = .003 if density < 5 else .0015
        ordered = sorted(members, key=lambda pair: (
            -int(pair[1]['string']) if kind == 'downward_roll' else
            int(pair[1]['string']) if kind == 'upward_roll' else
            (0 if pair[1]['role'] == 'bass' else 1 if pair[1]['role'] == 'inner' else 2)))
        # Existing canonical strum offsets are score material here.  Add only
        # a small physical difference, never a random beat displacement.
        for order, (index, event) in enumerate(ordered):
            role = event['role']
            offset = min(.018, order * spread)
            if kind in ('melody_harmony_pluck', 'fingerstyle_chord',
                        'support_dyad'):
                offset = min(.006, order * spread)
            velocity = int(event['velocity'])
            role_adjust = {'melody': 2, 'inner': -2, 'bass': -5}.get(role, 0)
            if role == 'bass' and int(event['pitch']) < 48:
                role_adjust -= 2
            if role == 'melody' and int(event['pitch']) >= 69:
                role_adjust += 2
            velocity = max(1, min(127, velocity + role_adjust +
                                  phrase_gain + density_gain))
            start = float(event['start']) + offset
            end = float(event['end'])
            # Sparse held grips resonate; dense notes stay articulate.  Do
            # not extend through a known physical/chord mute.
            if event.get('let_ring') and not event.get('mute_reason'):
                end += .045 if density <= 2 else (.015 if density <= 4 else 0)
                if phrase == 'end':
                    end += .055
            performed[index] = dict(event,
                score_onset=float(event['start']),
                score_duration=float(event['end']) - float(event['start']),
                performance_onset=round(start, 6),
                performance_duration=round(max(.046, end - start), 6),
                performance_velocity=velocity,
                performance_gesture=kind)
            phrase_levels[phrase].append(velocity)
            section_levels[f'density_{density}'].append(velocity)
        spreads.append(max(performed[index]['performance_onset'] for index, _ in members) -
                       min(performed[index]['performance_onset'] for index, _ in members))

    shortened_same_string = 0
    shortened_harmony = 0
    by_string = defaultdict(list)
    for index, event in enumerate(performed):
        by_string[int(event['string'])].append(index)
    for indices in by_string.values():
        indices.sort(key=lambda index: performed[index]['performance_onset'])
        for current, following in zip(indices, indices[1:]):
            event, next_event = performed[current], performed[following]
            limit = next_event['performance_onset'] - .001
            old_end = event['performance_onset'] + event['performance_duration']
            if old_end > limit:
                event['performance_duration'] = round(max(.001, limit - event['performance_onset']), 6)
                shortened_same_string += 1
    # Other strings may ring, except an incompatible chord change in the
    # saved harmonic plan.  This does not introduce any new attacks.
    boundaries = sorted((float(row['start']), row.get('chord')) for row in moments)
    for event in performed:
        end = event['performance_onset'] + event['performance_duration']
        boundary = next((time for time, chord in boundaries
                         if event['performance_onset'] + .01 < time < end and
                         chord != _moment_at(event['score_onset'], moments).get('chord')),
                        None)
        if boundary is not None:
            event['performance_duration'] = round(max(.001, boundary - .008 -
                                                       event['performance_onset']), 6)
            shortened_harmony += 1
    repeated = sum(1 for indices in by_string.values()
                   for left, right in zip(indices, indices[1:])
                   if performed[left]['pitch'] == performed[right]['pitch'])
    return performed, {
        'gesture_types': dict(classifications),
        'gestures_with_timing_spread': sum(value > .0005 for value in spreads),
        'average_spread_ms': round(1000 * sum(spreads) / max(1, len(spreads)), 2),
        'max_spread_ms': round(1000 * max(spreads, default=0), 2),
        'max_onset_deviation_ms': round(1000 * max(
            (abs(event['performance_onset'] - event['score_onset'])
             for event in performed), default=0), 2),
        'role_velocity': {role: round(sum(e['performance_velocity'] for e in performed
                                          if e['role'] == role) /
                                      max(1, sum(e['role'] == role for e in performed)), 1)
                          for role in ('melody', 'inner', 'bass')},
        'ringing_notes': sum(bool(e.get('let_ring')) for e in performed),
        'shortened_same_string': shortened_same_string,
        'shortened_harmony_change': shortened_harmony,
        'repeated_note_reattacks': repeated,
        'phrase_velocity_ranges': {key: [min(values), max(values)]
                                   for key, values in phrase_levels.items()},
        'density_velocity_ranges': {key: [min(values), max(values)]
                                    for key, values in section_levels.items()},
    }
