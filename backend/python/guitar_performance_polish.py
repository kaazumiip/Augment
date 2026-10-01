"""V1.1 listening-only Guitar phrasing over the frozen V1 event stream."""

from collections import Counter, defaultdict


def _moment(time, moments):
    return next((row for row in moments
                 if row['start'] - .001 <= time < row['end'] + .001),
                moments[-1] if moments else {})


def polish_guitar_performance(canonical, v1_events, moments):
    """Create V1.1 MIDI properties without touching any canonical field."""
    assert len(canonical) == len(v1_events)
    result = [dict(event) for event in v1_events]
    groups = defaultdict(list)
    for index, event in enumerate(result):
        groups[event['gesture_id']].append(index)
    ordered_groups = sorted(groups.values(), key=lambda indices:
                            min(result[index]['score_onset'] for index in indices))

    # Existing phrase-position labels, not an invented time-grid, establish
    # the span. Melody contour chooses a musical high point within that span.
    phrases, current = [], []
    previous_moment = None
    previous_label = None
    for indices in ordered_groups:
        first = min(result[index]['score_onset'] for index in indices)
        active_moment = _moment(first, moments)
        label = active_moment.get('phrase_position', 'middle')
        changed_moment = active_moment is not previous_moment
        if changed_moment and current and (label == 'start' or
                                           previous_label in ('end', 'cadence')):
            phrases.append(current)
            current = []
        current.append(indices)
        previous_moment, previous_label = active_moment, label
    if current:
        phrases.append(current)
    phrase_index = {}
    for phrase_number, phrase in enumerate(phrases):
        melody_contour = [max((result[i]['pitch'] for i in indices
                               if result[i]['role'] == 'melody'), default=-1)
                          for indices in phrase]
        peak = max(range(len(phrase)), key=lambda i: melody_contour[i])
        for position, indices in enumerate(phrase):
            phrase_index[indices[0]] = (phrase_number, position, len(phrase), peak)

    gesture_counts = Counter()
    spread_values = []
    phrase_velocities = defaultdict(list)
    phrase_melody_velocities = defaultdict(list)
    continued_cross_gesture = 0
    repeat_treatments = 0
    release_adjustments = 0
    previous_kind = None
    previous_melody = None
    previous_chord = None
    for indices in ordered_groups:
        group = [result[i] for i in indices]
        score_start = min(e['score_onset'] for e in group)
        moment = _moment(score_start, moments)
        chord = moment.get('chord')
        change = previous_chord is not None and chord != previous_chord
        density = int(moment.get('density', 0))
        phrase_number, position, count, peak = phrase_index[indices[0]]
        melody = next((e for e in group if e['role'] == 'melody'), None)
        strong = any(abs(float(e.get('start_quarter', .37)) -
                         round(float(e.get('start_quarter', .37)))) < .06
                     for e in group)
        original_roll = any(e.get('stroke_direction') for e in group)
        if len(group) == 1:
            kind = 'exposed_melody' if melody else 'support_pluck'
        elif len(group) == 2 and {'bass', 'melody'} <= {e['role'] for e in group}:
            kind = 'bass_upper_pinch'
        elif len(group) <= 3 and melody and not change:
            kind = 'near_simultaneous_pluck'
        elif original_roll and (change or position == peak) and strong and density < 6:
            kind = 'full_roll' if len(group) >= 4 else 'subtle_roll'
        elif original_roll and previous_kind in ('full_roll', 'subtle_roll'):
            kind = 'light_brush'
        elif original_roll:
            kind = 'subtle_roll' if len(group) >= 3 else 'near_simultaneous_pluck'
        else:
            kind = 'fingerstyle_pinch'
        gesture_counts[kind] += 1

        # A smooth deterministic phrase arc is shared by all voices in the
        # gesture. Local melody contour only modifies that shared curve.
        rise = position / max(1, peak)
        fall = (count - 1 - position) / max(1, count - 1 - peak)
        arc = min(rise, fall)
        phrase_gain = round(-2 + 5 * max(0, arc))
        if position == count - 1:
            phrase_gain -= 1
        if change and strong:
            phrase_gain += 1
        repeated_melody = (melody is not None and previous_melody is not None and
                           melody['pitch'] == previous_melody)
        if repeated_melody:
            repeat_treatments += 1
        earliest = min(e['score_onset'] for e in group)
        latest = max(e['score_onset'] for e in group)
        span = max(.00001, latest - earliest)
        for event in group:
            role = event['role']
            # Existing score rolls are not rewritten. V1.1 can only move an
            # individual attack within the same <=18 ms physical window.
            fraction = (event['score_onset'] - earliest) / span
            if kind == 'full_roll':
                offset = .004 + fraction * .014
            elif kind == 'subtle_roll':
                offset = .004 - fraction * .012
            elif kind == 'light_brush':
                offset = .006 - fraction * .014
            elif kind == 'bass_upper_pinch':
                offset = 0 if role == 'bass' else .004
            elif kind in ('near_simultaneous_pluck', 'fingerstyle_pinch'):
                offset = .004 - fraction * .012
            else:
                offset = 0
            event['performance_onset'] = round(event['score_onset'] + offset, 6)
            balance = (1 if role == 'melody' else -2 if role == 'inner' else -2)
            if role == 'melody' and event['pitch'] >= 69 and len(group) > 1:
                balance += 1
            if role == 'bass' and event['pitch'] < 48:
                balance -= 1
            if role == 'melody' and repeated_melody:
                balance += 1 if strong else -1
            if role == 'melody' and len(group) == 1 and density <= 3:
                balance += 1 if strong else -1
            event['performance_velocity'] = max(1, min(127,
                int(event['performance_velocity']) + phrase_gain + balance))
            event['performance_gesture'] = kind
            phrase_velocities[phrase_number].append(event['performance_velocity'])
            if role == 'melody':
                phrase_melody_velocities[phrase_number].append(event['performance_velocity'])
            original_duration = event['performance_duration']
            if event.get('let_ring') and not event.get('mute_reason'):
                # Ring only within the already intended score duration plus
                # a tiny, context-dependent tail; do not fill phrase rests.
                extra = .035 if density <= 2 else .012 if density <= 4 else 0
                if position == count - 1:
                    extra = 0
                event['performance_duration'] = round(original_duration + extra, 6)
                release_adjustments += int(extra > 0)
        spread_values.append(max(result[i]['performance_onset'] for i in indices) -
                             min(result[i]['performance_onset'] for i in indices))
        previous_kind = kind
        previous_chord = chord
        if melody:
            previous_melody = melody['pitch']

    # Held strings continue across other-string attacks. Same-string reuse and
    # incompatible harmonic boundaries remain strict physical limits.
    by_string = defaultdict(list)
    for index, event in enumerate(result):
        by_string[event['string']].append(index)
    same_string_cuts = 0
    for indices in by_string.values():
        indices.sort(key=lambda i: result[i]['performance_onset'])
        for left, right in zip(indices, indices[1:]):
            event = result[left]
            limit = result[right]['performance_onset'] - .001
            if event['performance_onset'] + event['performance_duration'] > limit:
                event['performance_duration'] = round(max(.001,
                    limit - event['performance_onset']), 6)
                same_string_cuts += 1
    harmony_cuts = 0
    for event in result:
        end = event['performance_onset'] + event['performance_duration']
        initial_chord = _moment(event['score_onset'], moments).get('chord')
        boundary = next((float(row['start']) for row in moments
                         if event['performance_onset'] + .01 < row['start'] < end and
                         row.get('chord') != initial_chord), None)
        if boundary is not None:
            event['performance_duration'] = round(max(.001, boundary - .008 -
                                                       event['performance_onset']), 6)
            harmony_cuts += 1
    for event in result:
        if event['performance_duration'] <= 0:
            raise ValueError('Nonpositive Guitar performance duration')
        end = event['performance_onset'] + event['performance_duration']
        if any(other['gesture_id'] != event['gesture_id'] and
               event['performance_onset'] < other['performance_onset'] < end and
               other['string'] != event['string'] for other in result):
            continued_cross_gesture += 1
    return result, {
        'gesture_types': dict(gesture_counts),
        'downward_rolls': gesture_counts['full_roll'] + gesture_counts['subtle_roll'],
        'average_spread_ms': round(1000 * sum(spread_values) /
                                   max(1, len(spread_values)), 2),
        'max_spread_ms': round(1000 * max(spread_values, default=0), 2),
        'max_onset_deviation_ms': round(1000 * max((abs(e['performance_onset'] -
            e['score_onset']) for e in result), default=0), 2),
        'cross_gesture_ringing_notes': continued_cross_gesture,
        'unnecessary_retriggers_avoided': 0,
        'repeated_melody_reattacks_shaped': repeat_treatments,
        'release_adjustments': release_adjustments,
        'same_string_cuts': same_string_cuts,
        'harmony_change_cuts': harmony_cuts,
        'phrase_velocity_ranges': {str(k): [min(v), max(v)]
                                   for k, v in phrase_velocities.items()},
        'phrase_melody_velocity_ranges': {str(k): [min(v), max(v)]
                                          for k, v in phrase_melody_velocities.items()},
        'role_velocity': {role: round(sum(e['performance_velocity'] for e in result
                                          if e['role'] == role) /
                                      max(1, sum(e['role'] == role for e in result)), 1)
                          for role in ('melody', 'inner', 'bass')},
    }
