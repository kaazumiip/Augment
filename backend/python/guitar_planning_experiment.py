"""General, opt-in Guitar beat hierarchy and economical grip experiment.

This module is never selected by the normal application route.  It operates
on existing song analysis and never contains a song title or fixed chord map.
"""

from collections import Counter

import numpy as np

from solo_guitar_arranger import (
    _v9_shape_candidates, _v9_transition_cost, _v10_melody_location,
    STANDARD_TUNING, MAX_FRET,
)
from transcribe_pipeline import Grid


def choose_economical_shape(section, previous, melody, upcoming):
    candidates = _v9_shape_candidates(section)
    if not candidates:
        return previous, True, 0.0, 0

    def score(shape):
        transition, anchors = _v9_transition_cost(previous, shape)
        present = sum(_v10_melody_location(shape, note.pitch) is not None
                      for note in melody)
        future = sum(_v10_melody_location(shape, note.pitch) is not None
                     for note in upcoming if note not in melody)
        top = sum(any(string >= 4 and pitch < note.pitch
                      for string, _, pitch in shape.voiced)
                  for note in melody
                  if _v10_melody_location(shape, note.pitch) is not None)
        opens = sum(fret == 0 for fret in shape.layout)
        # Melody access remains the hard musical priority. Economy is a
        # tie-break among genuinely usable held grips, not a low-fret quota.
        return (present * 8 + top * 3 + min(3, future) * 1.6 +
                opens * 1.2 + anchors * 1.3 - transition * 2.1 -
                max(0, shape.position - 4) * .65,
                present, top, future, opens, anchors, -transition)

    best = max(candidates, key=score)
    transition, anchors = _v9_transition_cost(previous, best)
    return best, previous is not None and best.id == previous.id, transition, anchors


def _local_melody_access(shape, pitch):
    if _v10_melody_location(shape, pitch) is not None:
        return 1.0
    for index in range(3, 6):
        fret = int(pitch) - STANDARD_TUNING[index]
        held = shape.layout[index]
        if (held is not None and 0 <= fret <= MAX_FRET and
                max(0, shape.position - 1) <= fret <= shape.position + 3 and
                abs(fret - held) <= 4):
            return .65  # practical one-finger melody extension
    return 0.0


def plan_economical_shapes(moments):
    """Short-sequence dynamic program over established real Guitar grips."""
    candidates = [_v9_shape_candidates(moment.chord_section) for moment in moments]
    if not candidates or any(not row for row in candidates):
        return None
    scores = []
    paths = []
    for index, (moment, row) in enumerate(zip(moments, candidates)):
        current_scores, current_paths = [], []
        notes = [note for note in moment.melody_notes
                 if moment.start <= note.start < moment.end]
        for shape in row:
            access = sum(_local_melody_access(shape, note.pitch) for note in notes)
            opens = sum(fret == 0 for fret in shape.layout)
            natural_palette = sum(string in (2, 3, 4) for string, _, _ in shape.voiced)
            local = (access * 7 + opens * 1.65 + natural_palette * .25 -
                     max(0, shape.position - 4) * .6)
            if index == 0:
                current_scores.append(local)
                current_paths.append([shape])
                continue
            options = []
            for prior_index, prior in enumerate(candidates[index - 1]):
                transition, anchors = _v9_transition_cost(prior, shape)
                # A familiar grip held across a chord region is rewarded;
                # an open-position move can be worthwhile if later bars also
                # benefit, because this search sees the whole short section.
                cost = max(0, transition) * 1.45 - anchors * .3
                options.append((scores[-1][prior_index] + local - cost,
                                prior_index))
            best, prior_index = max(options)
            current_scores.append(best)
            current_paths.append(paths[-1][prior_index] + [shape])
        scores.append(current_scores)
        paths.append(current_paths)
    return paths[-1][max(range(len(scores[-1])), key=lambda i: scores[-1][i])]


def choose_beat_hierarchy(grid, audio_path, melody_events, bass_events):
    """Score pulse, half, and double interpretations without song presets."""
    import librosa

    y, sr = librosa.load(str(audio_path), sr=22050, mono=True)
    hop = 512
    onset = librosa.onset.onset_strength(y=y, sr=sr, hop_length=hop)
    pulse = np.asarray(grid.beat_times, dtype=float)
    values = np.interp(pulse, np.arange(len(onset)) * hop / sr, onset)
    parity = int(np.argmax([values[::2].mean(), values[1::2].mean()])) if len(values) > 3 else 0
    contrast = float(abs(values[::2].mean() - values[1::2].mean()) /
                     max(.001, values.mean())) if len(values) > 3 else 0.0
    melody = [(float(e['start']), int(e['velocity'])) for e in melody_events]
    bass = [float(e['start']) for e in bass_events]
    chord_changes = [float(right['start_seconds'])
                     for left, right in zip(grid.chord_sections, grid.chord_sections[1:])
                     if (left['root_pc'], left['quality']) !=
                        (right['root_pc'], right['quality'])]
    phrase_starts = [melody[0][0]] if melody else []
    phrase_starts += [right[0] for left, right in zip(melody, melody[1:])
                      if right[0] - left[0] > .75]

    def near(times, beat_times, tolerance):
        if not times or not len(beat_times):
            return 0.0
        return sum(min(abs(time - beat) for beat in beat_times) <= tolerance
                   for time in times) / len(times)

    rows = []
    for factor in (.5, 1.0, 2.0):
        bpm = float(grid.bpm) * factor
        if factor == .5:
            beats = pulse[parity::2]
        elif factor == 2.0:
            beats = np.sort(np.r_[pulse, (pulse[:-1] + pulse[1:]) / 2])
        else:
            beats = pulse
        interval = 60 / bpm
        # Score distinct sources. The reference's BPM is intentionally absent.
        chord_alignment = near(chord_changes, beats, min(.1, interval * .18))
        melody_alignment = near([time for time, velocity in melody if velocity >= 95],
                                beats, min(.095, interval * .16))
        bass_alignment = near(bass, beats, min(.1, interval * .18))
        phrase_alignment = near(phrase_starts, beats, min(.12, interval * .22))
        if factor == .5:
            pulse_hierarchy = min(1.0, contrast * 2.0)
        elif factor == 1.0:
            pulse_hierarchy = .35
        else:
            pulse_hierarchy = 0.0
        # Penalize extreme notation tempos, but let enough independent
        # alignment evidence override the prior when a song truly needs it.
        tempo_prior = (0.7 if 65 <= bpm <= 145 else
                       0.1 if 55 <= bpm <= 180 else -1.3)
        score = (1.3 * chord_alignment + .7 * melody_alignment +
                 .5 * bass_alignment + .5 * phrase_alignment +
                 pulse_hierarchy + tempo_prior)
        rows.append({'factor': factor, 'bpm': round(bpm, 2),
                     'score': round(score, 3),
                     'evidence': {'pulse_alternation': round(pulse_hierarchy, 3),
                                  'chord_change_alignment': round(chord_alignment, 3),
                                  'melody_accent_alignment': round(melody_alignment, 3),
                                  'bass_alignment': round(bass_alignment, 3),
                                  'phrase_start_alignment': round(phrase_alignment, 3),
                                  'tempo_prior': tempo_prior},
                     'beat_times': tuple(float(value) for value in beats)})
    winner = max(rows, key=lambda row: row['score'])
    revised = Grid(winner['bpm'], grid.time_signature, grid.key_name,
                   grid.key_mode, winner['beat_times'], (),
                   grid.key_sections, grid.chord_sections)
    report = {'detected_pulse_bpm': grid.bpm,
              'musical_bpm': winner['bpm'],
              'meter': grid.time_signature,
              'pulse_parity_contrast': round(contrast, 3),
              'candidate_scores': [{k: v for k, v in row.items() if k != 'beat_times'}
                                   for row in rows],
              'selected_factor': winner['factor'],
              'strong_beats_seconds': [round(value, 3)
                                       for value in winner['beat_times'][::4]][:12]}
    return revised, report


def planning_diagnostics(plan, hierarchy):
    events, shapes = plan['events'], plan['shapes']
    beat_times = hierarchy.beat_times
    strong = beat_times[::4]
    def strength(time):
        if any(abs(time - beat) <= .09 for beat in strong):
            return 'strong'
        if any(abs(time - beat) <= .09 for beat in beat_times):
            return 'weak'
        return 'subdivision'
    gestures = {}
    for event in events:
        gestures.setdefault(event['gesture_id'], []).append(event)
    melody_groups = [group for group in gestures.values()
                     if any(event['role'] == 'melody' for event in group)]
    positions = [float(shape['hand_position']) for shape in shapes]
    shifts = [abs(right - left) for left, right in zip(positions, positions[1:])]
    roles = Counter(event['role'] for event in events)
    return {
        'events': len(events), 'melody': roles['melody'],
        'bass': roles['bass'], 'inner': roles['inner'],
        'string_usage': {str(string): sum(e['string'] == string for e in events)
                         for string in range(1, 7)},
        'middle_upper_support_events': sum(e['role'] != 'melody' and
                                            e['string'] in (1, 2, 3, 4)
                                            for e in events),
        'melody_beat_strength': dict(Counter(strength(e['start']) for e in events
                                              if e['role'] == 'melody')),
        'chord_change_strength': dict(Counter(strength(right['start'])
            for left, right in zip(shapes, shapes[1:])
            if left['chord'] != right['chord'])),
        'melody_with_harmonic_support_percent': round(100 * sum(
            len(group) > 1 for group in melody_groups) /
            max(1, len(melody_groups)), 1),
        'open_string_events': sum(event['fret'] == 0 for event in events),
        'position_regions': {'low_0_4': sum(p <= 4 for p in positions),
                             'mid_5_8': sum(5 <= p <= 8 for p in positions),
                             'high_9_plus': sum(p >= 9 for p in positions)},
        'average_position': round(sum(positions) / max(1, len(positions)), 2),
        'position_shifts': sum(value > 0 for value in shifts),
        'large_jumps_over_4_frets': sum(value > 4 for value in shifts),
        'held_grip_regions': sum(shape['carried_previous_shape'] for shape in shapes),
        'shape_sequence': [{'chord': shape['chord'],
                            'shape': shape['shape_id'],
                            'position': shape['hand_position'],
                            'layout_6_to_1': shape['layout_6_to_1']}
                           for shape in shapes],
        'full_chords': sum(len(group) >= 4 for group in gestures.values()),
        'partial_chords': sum(len(group) == 3 for group in gestures.values()),
        'dyads': sum(len(group) == 2 for group in gestures.values()),
        'bass_melody_gestures': sum({'bass', 'melody'} <=
                                   {e['role'] for e in group}
                                   for group in gestures.values()),
        'melody_only_gestures': sum(len(group) == 1 and group[0]['role'] == 'melody'
                                    for group in gestures.values()),
        'ringing_harmony_gestures': sum(any(e['role'] != 'melody' and
                                            e.get('let_ring') for e in group)
                                        for group in gestures.values()),
    }
