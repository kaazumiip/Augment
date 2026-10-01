"""Conservative, source-guided Solo Guitar arrangement helpers.

This module intentionally works from the shared analysis already produced for
an upload.  It does not claim to isolate an original guitar part: it turns a
lead line, bass evidence, and the existing chord grid into a small playable
guitar texture.
"""

from __future__ import annotations

import json
from collections import Counter
from dataclasses import dataclass
from itertools import combinations, product

import pretty_midi


GUITAR_LOW = 40  # E2
GUITAR_HIGH = 88
MAX_VOICES = 4
MAX_SIMULTANEOUS_SPAN = 24
STANDARD_TUNING = (40, 45, 50, 55, 59, 64)  # strings 6 through 1
MAX_FRET = 24
MAX_FRET_SPAN = 10


@dataclass(frozen=True)
class GuitarShape:
    """A concrete, partial Guitar grip in standard-tuning string order.

    ``layout`` is six entries for strings 6 through 1.  ``None`` means muted;
    zero is an intentionally open string.  This is the canonical source for
    both V9 performance events and TAB technical data.
    """

    id: str
    root_pc: int
    quality: str
    layout: tuple
    position: float
    barre_fret: int | None
    left_hand: tuple
    bass_string: int
    template_name: str = 'custom'

    @property
    def voiced(self):
        return tuple(
            (6 - index, fret, STANDARD_TUNING[index] + fret)
            for index, fret in enumerate(self.layout) if fret is not None
        )


@dataclass(frozen=True)
class GuitarPerformanceEvent:
    """The single physical Guitar event consumed by MIDI, TAB and Digitar.

    The arranger persists these values as JSON-compatible dictionaries.  The
    class is deliberately small and immutable so validation can reject an
    impossible physical performance before another output format sees it.
    """

    time: float
    duration: float
    pitch: int
    string: int
    fret: int
    shape_id: str
    chord: str
    left_hand_finger: str | None
    right_hand_finger: str
    role: str
    action: str
    strum_direction: str | None
    articulation: str
    velocity: int
    let_ring: bool


def validate_guitar_performance_events(events):
    """Validate canonical Guitar events without changing their music."""
    errors = []
    valid_lh = {None, '0/open', '1', '2', '3', '4', 'T', '1/barre', '3/barre'}
    active_by_string = {string: [] for string in range(1, 7)}
    for index, event in enumerate(sorted(events, key=lambda item: (item['start'], item['string']))):
        string, fret, pitch = int(event['string']), int(event['fret']), int(event['pitch'])
        if not 1 <= string <= 6:
            errors.append(f'event {index}: invalid string {string}')
        if not 0 <= fret <= MAX_FRET:
            errors.append(f'event {index}: invalid fret {fret}')
        if 1 <= string <= 6 and STANDARD_TUNING[6 - string] + fret != pitch:
            errors.append(f'event {index}: pitch/string/fret mismatch')
        if event.get('left_hand_finger') not in valid_lh:
            errors.append(f"event {index}: invalid left-hand finger {event.get('left_hand_finger')}")
        if not 1 <= int(event.get('velocity', 0)) <= 127:
            errors.append(f'event {index}: invalid velocity')
        if 1 <= string <= 6:
            for prior in active_by_string[string]:
                if prior['end'] > event['start'] + .001:
                    errors.append(f'event {index}: same-string overlap')
                    break
            active_by_string[string].append(event)
    return {'valid': not errors, 'errors': errors, 'event_count': len(events)}


def guitar_string_frets(pitches, unavailable_strings=(), previous_position=None):
    """Return a compact distinct-string fingering, or ``None`` if impossible.

    The arranger uses this before accepting support tones, so it does not
    create Piano-like chord stacks that only look valid by MIDI pitch span.
    Returned pairs are ``(string, fret)`` where string 6 is low E and string
    1 is high E.  Melody is intentionally retained if it is playable alone.
    """
    pitches = tuple(sorted(set(int(pitch) for pitch in pitches)))
    if not pitches or len(pitches) > MAX_VOICES:
        return None
    unavailable_strings = set(unavailable_strings)
    options = []
    for pitch in pitches:
        choices = [(6 - index, pitch - open_pitch)
                   for index, open_pitch in enumerate(STANDARD_TUNING)
                   if 0 <= pitch - open_pitch <= MAX_FRET and
                   6 - index not in unavailable_strings]
        if not choices:
            return None
        options.append(choices)
    candidates = []
    for selection in product(*options):
        strings = [item[0] for item in selection]
        frets = [item[1] for item in selection]
        if len(strings) != len(set(strings)):
            continue
        if max(frets) - min(frets) > MAX_FRET_SPAN:
            continue
        candidates.append(selection)
    if not candidates:
        return None
    def rank(item):
        frets = [fret for _, fret in item]
        position = sum(frets) / len(frets)
        movement = (abs(position - previous_position)
                    if previous_position is not None else 0.0)
        return (
            movement,
            max(frets) - min(frets),
            max(frets),
            tuple(string for string, _ in item),
        )

    return min(candidates, key=rank)


def _select_playable_support(melody_pitch, candidates, max_support,
                             previous_position=None):
    """Choose one compact Guitar shape while preserving the melody on top."""
    candidates = list(dict.fromkeys(
        int(pitch) for pitch in candidates if pitch < melody_pitch))
    for count in range(min(max_support, len(candidates)), 0, -1):
        choices = []
        for support in combinations(candidates, count):
            pitches = sorted((*support, int(melody_pitch)))
            if max(pitches) - min(pitches) > MAX_SIMULTANEOUS_SPAN:
                continue
            fingering = guitar_string_frets(
                pitches, previous_position=previous_position)
            if fingering is None:
                continue
            frets = [fret for _, fret in fingering]
            position = sum(frets) / len(frets)
            choices.append((
                abs(position - previous_position)
                if previous_position is not None else 0.0,
                max(frets) - min(frets),
                max(frets),
                support,
                fingering,
            ))
        if choices:
            selected = min(choices)
            return list(selected[3]), selected[4]
    return [], None


def midi_notes(path):
    """Read a stable, de-duplicated note list from a MIDI artifact."""
    midi = pretty_midi.PrettyMIDI(path)
    seen, result = set(), []
    for track in midi.instruments:
        for item in track.notes:
            if item.end - item.start < .075 or not GUITAR_LOW <= item.pitch <= GUITAR_HIGH:
                continue
            identity = (round(item.start, 3), round(item.end, 3), item.pitch)
            if identity in seen:
                continue
            seen.add(identity)
            result.append(pretty_midi.Note(
                velocity=int(item.velocity), pitch=int(item.pitch),
                start=float(item.start), end=float(item.end),
            ))
    return sorted(result, key=lambda item: (item.start, item.pitch, item.end))


def select_guitar_lead(candidate_path, output_path):
    """Choose a coherent upper guitar line from polyphonic source evidence."""
    candidates = midi_notes(candidate_path)
    selected, previous_pitch, cursor = [], None, -1.0
    index = 0
    while index < len(candidates):
        onset = candidates[index].start
        group = []
        while index < len(candidates) and candidates[index].start <= onset + .055:
            group.append(candidates[index])
            index += 1
        # Solo Guitar lead normally lives above the bass/root and below the
        # very top fretboard limit.  This favours a musical line, not merely
        # the loudest low accompaniment component.
        highest = max(item.pitch for item in group)
        def rank(item):
            register = (1.25 if 60 <= item.pitch <= 78 else
                        .70 if 55 <= item.pitch < 60 else
                        .45 if 79 <= item.pitch <= 84 else -.35)
            # A top-note is useful evidence, not a command. Large unprepared
            # leaps are usually a voice switch or overtone rather than a hook.
            top = .42 if item.pitch == highest else .18
            leap = 0 if previous_pitch is None else abs(item.pitch - previous_pitch)
            continuity = 0.0 if previous_pitch is None else max(-1.1, .62 - leap * .09)
            leap_penalty = -.55 if leap > 12 else (-.18 if leap > 8 else 0)
            return register + top + continuity + leap_penalty + min(.3, (item.end - item.start) / .4) + item.velocity / 500.0
        item = max(group, key=rank)
        # Keep phrase rhythm but reject machine-gun residual activations.
        if item.start < cursor + .13:
            continue
        selected.append(pretty_midi.Note(
            velocity=max(72, min(106, item.velocity)), pitch=item.pitch,
            start=item.start, end=max(item.start + .09, item.end),
        ))
        previous_pitch, cursor = item.pitch, item.start
    midi = pretty_midi.PrettyMIDI()
    track = pretty_midi.Instrument(program=24, name='Solo Guitar lead')
    track.notes = selected
    midi.instruments.append(track)
    midi.write(output_path)
    return selected


def merge_guitar_melody(verified, fallback, duration, same_source=False):
    """Fill only defensible interior vocal rests with an instrumental hook.

    ``other.wav`` is useful when a song truly has no vocal lead, but it often
    contains bass, guitar and reverb during an instrumental introduction. It
    must not manufacture a false melody before/after a verified vocal phrase.
    """
    base = _monophonic_melody(verified)
    additions = []
    for item in _monophonic_melody(fallback):
        if same_source and base:
            # Basic Pitch on the isolated vocal is secondary onset evidence.
            # Recover an independent attack when pYIN missed it, including a
            # repeated attack hidden under an overlong pYIN tail. Require its
            # pitch to agree with the local vocal contour to avoid harmonics.
            if item.pitch < 55 or item.pitch > 82 or item.end - item.start < .09:
                continue
            if any(abs(existing.start - item.start) <= .085 for existing in base + additions):
                continue
            nearby = min(base, key=lambda existing: min(
                abs(existing.start - item.start), abs(existing.end - item.start)))
            if abs(nearby.pitch - item.pitch) > 7:
                continue
            additions.append(item)
            continue
        # With a verified vocal line, only bridge a rest that is bounded by
        # genuine vocal material. Never turn an intro/outro accompaniment
        # into a made-up lead line.
        if base and (item.start < base[0].start or item.end > base[-1].end):
            continue
        # Reject the low accompaniment register and extremely brief residual
        # activations. This does not affect instrumental-only songs, where
        # ``verified`` is empty and the existing fallback remains available.
        if base and (item.pitch < 55 or item.pitch > 82 or item.end - item.start < .12):
            continue
        if any(existing.start < item.end and existing.end > item.start for existing in base):
            continue
        before = max((existing.end for existing in base if existing.end <= item.start), default=0.0)
        after = min((existing.start for existing in base if existing.start >= item.end), default=duration)
        # Only an actual vocal rest may receive an instrumental hook.
        if after - before < .55:
            continue
        if additions and item.start - additions[-1].start < .16:
            continue
        additions.append(item)
    return _monophonic_melody(base + additions), additions


def _monophonic_melody(notes):
    """Keep the supplied lead identity, resolving only simultaneous candidates."""
    result = []
    for item in sorted(notes, key=lambda note: (note.start, -note.pitch, -note.velocity)):
        if result and item.start < result[-1].end - .012:
            # A pYIN lead should already be one line.  If a fallback supplied
            # a small onset cluster, the highest clear note is the guitar lead.
            if abs(item.start - result[-1].start) <= .045:
                if item.pitch <= result[-1].pitch:
                    continue
                result.pop()
            else:
                # A distinct attack must survive an overestimated prior tail.
                result[-1].end = item.start
        result.append(pretty_midi.Note(
            velocity=max(72, min(108, item.velocity)), pitch=item.pitch,
            start=item.start, end=max(item.start + .09, item.end),
        ))
    return result


def _pitch_for_pc(pc, low, high, prefer_low=True):
    candidates = [pitch for pitch in range(low, high + 1) if pitch % 12 == pc]
    if not candidates:
        return None
    return candidates[0] if prefer_low else candidates[-1]


def _chord_pitches(section, melody_pitch=None, bass_pitch=None):
    """Return a compact, guitar-like root/colour voicing below a melody."""
    root_pc = int(section.get('root_pc', 0)) % 12
    quality = section.get('quality', 'major')
    third = (root_pc + (3 if quality == 'minor' else 4)) % 12
    fifth = (root_pc + 7) % 12
    section_tones = {int(value) % 12 for value in section.get('tones', ())}
    seventh_pc = None
    for candidate in ((root_pc + 10) % 12, (root_pc + 11) % 12):
        if candidate in section_tones:
            seventh_pc = candidate
            break
    # Bass is supporting evidence, not permission to rewrite the detected
    # chord. Use it only when it agrees with the chord root; otherwise retain
    # the chord-grid root for a coherent Guitar voicing.
    root = (bass_pitch if bass_pitch is not None and bass_pitch % 12 == root_pc
            else _pitch_for_pc(root_pc, 40, 52))
    if root is None:
        return []
    # Keep the low guitar foundation within a plausible hand span of the
    # melody.  High melody notes get a compact mid-register support instead of
    # an impossible E2-to-C6 piano stack.
    while melody_pitch is not None and melody_pitch - root > MAX_SIMULTANEOUS_SPAN:
        root += 12
    # A noisy bass candidate can land on or above the melody. Fall back to a
    # real Guitar root below that exact melody attack instead of discarding a
    # usable partial voicing.
    if melody_pitch is not None and (root >= melody_pitch or melody_pitch - root > MAX_SIMULTANEOUS_SPAN):
        root = _pitch_for_pc(
            root_pc, max(GUITAR_LOW, melody_pitch - MAX_SIMULTANEOUS_SPAN),
            min(55, melody_pitch - 3),
        )
    if root is None:
        return []
    tones = [root]
    # Root first for bass-enabled shapes; colour tones follow so callers can
    # deliberately omit the root without losing all accompaniment.
    for pc in (fifth, third, seventh_pc):
        if pc is None:
            continue
        # B2 and G2 are normal, playable support tones on Guitar. The old
        # lower bound of 48 removed them, leaving low-register melodies with
        # only a root and making trustworthy harmony silently disappear.
        candidates = [pitch for pitch in range(max(root + 3, 43), 73) if pitch % 12 == pc]
        if melody_pitch is not None:
            candidates = [pitch for pitch in candidates if pitch < melody_pitch]
        if candidates:
            tones.append(candidates[-1])
    # Exact melody pitches are never doubled inside the accompaniment.
    return list(dict.fromkeys(pitch for pitch in tones if melody_pitch != pitch))


def _nearest_bass(notes, start, end):
    candidates = [item for item in notes if item.start < end and item.end > start]
    if not candidates:
        return None
    selected = min(candidates, key=lambda item: (abs(item.start - start), item.pitch))
    pitch = selected.pitch
    while pitch < 40:
        pitch += 12
    while pitch > 55:
        pitch -= 12
    return pitch if 40 <= pitch <= 55 else None


def _meter_pulses(time_signature):
    """Return the natural fingerstyle pulse count for one harmony window."""
    try:
        beats, unit = (int(value) for value in str(time_signature).split('/', 1))
    except (TypeError, ValueError):
        return 4
    # Compound meters are felt in dotted-note pulses, not as a flat row of
    # eighth notes.  This gives 6/8 two pulses and 12/8 four pulses.
    if unit == 8 and beats >= 6 and beats % 3 == 0:
        return max(2, beats // 3)
    return max(2, min(6, beats))


def _supported_harmony(section, sections, index):
    """Use the existing conservative chord evidence in one place."""
    confidence = float(section.get('confidence', 0.0))
    signature = (section.get('root_pc'), section.get('quality'))
    neighbours = [
        (sections[item].get('root_pc'), sections[item].get('quality'))
        for item in (index - 1, index + 1)
        if 0 <= item < len(sections)
    ]
    return confidence >= .075 or (signature in neighbours and confidence >= .020)


def _guitar_shape(section, bass_notes, start, end, previous_position=None):
    """Choose a compact held chord shape for one harmony region.

    This is deliberately a *shape* rather than a set of one-off support
    notes.  The picker below can therefore keep a thumb/finger pattern going
    through a measure and only revoice when the harmony changes.
    """
    raw = _chord_pitches(section, bass_pitch=_nearest_bass(bass_notes, start, end))
    if not raw:
        return [], None
    root = raw[0]
    # A detected bass stem may supply the root an octave above the Guitar's
    # thumb register (for example F3 instead of F2).  Keep that evidence for
    # pitch class only; a fingerstyle bass pulse belongs on the lowest
    # playable octave so it remains distinct from the inner strings.
    while root - 12 >= GUITAR_LOW:
        root -= 12
    # _chord_pitches intentionally chooses colour tones below a prospective
    # melody, so without one they can be high.  Bring them into the current
    # hand position before testing a real fretting.
    colours = []
    for pitch in raw[1:]:
        while pitch - 12 >= root + 3:
            pitch -= 12
        while pitch < root + 3:
            pitch += 12
        if pitch <= 64 and pitch not in colours:
            colours.append(pitch)
    candidates = []
    for size in range(min(3, len(colours) + 1), 1, -1):
        for extra in combinations(colours, size - 1):
            shape = [root, *sorted(extra)]
            fingering = guitar_string_frets(shape, previous_position=previous_position)
            if fingering is None:
                continue
            position = sum(fret for _, fret in fingering) / len(fingering)
            candidates.append((
                abs(position - previous_position) if previous_position is not None else 0.0,
                max(fret for _, fret in fingering) - min(fret for _, fret in fingering),
                -len(shape), shape, fingering, position,
            ))
    if not candidates:
        return ([root], guitar_string_frets([root], previous_position=previous_position))
    selected = min(candidates)
    return list(selected[3]), selected[5]


def _assign_event_fingerings(events, grid):
    """Assign each final attack to real strings without changing its pitch."""
    by_attack = {}
    for event in events:
        by_attack.setdefault(round(event['start'], 3), []).append(event)
    assigned = []
    previous_position = None
    for onset, attack in sorted(by_attack.items()):
        active = [event for event in assigned
                  if event['end'] > onset + .001]
        occupied = {event['string'] for event in active}

        def choose(group):
            return guitar_string_frets(
                [event['pitch'] for event in group],
                unavailable_strings=occupied,
                previous_position=previous_position,
            )

        kept = list(attack)
        fingering = choose(kept)
        if fingering is None:
            # A held support tone may release at the next real attack, exactly
            # as a guitarist lifts that finger to play the new shape. Melody
            # attacks and pitches remain untouched.
            for held in sorted(
                    (event for event in active if event['role'] != 'melody'),
                    key=lambda event: (event['role'] == 'bass', event['start'])):
                held['end'] = min(held['end'], onset)
                occupied.discard(held['string'])
                fingering = choose(kept)
                if fingering is not None:
                    break
        while fingering is None:
            removable = next((event for event in reversed(kept)
                              if event['role'] != 'melody'), None)
            if removable is None:
                break
            kept.remove(removable)
            fingering = choose(kept)
        if fingering is None:
            # Every single Guitar-range melody pitch has at least one valid
            # string. This guard is only for malformed external input.
            continue
        pitch_positions = {
            pitch: position for pitch, position in
            zip(sorted(event['pitch'] for event in kept), fingering)
        }
        for event in kept:
            event['string'], event['fret'] = pitch_positions[event['pitch']]
            # The readable score snaps attacks to an eighth-note lattice.
            # Persist that same key so TAB can reuse this exact fingering
            # after music21's notation quantization.
            event['start_quarter'] = round(
                float(grid.seconds_to_quarter(event['start'])) * 8) / 8
            assigned.append(event)
        previous_position = sum(fret for _, fret in fingering) / len(fingering)
    return sorted(assigned, key=lambda event: (event['start'], event['pitch']))


def _arrange_solo_guitar_v8(melody_notes, bass_notes, grid, output_path,
                             verified_melody_notes=0, fallback_melody_notes=0):
    """Write one conservative Solo Guitar MIDI arrangement.

    Melody is protected as the upper voice. Confident harmony is attached to
    selected melody attacks as small Guitar voicings rather than as unrelated
    chord-window attacks, so the result sounds like one guitarist playing a
    melody with support instead of two sequential MIDI lines.
    """
    melody = _monophonic_melody(melody_notes)
    events = []
    roles = Counter()

    def add(pitch, start, end, velocity, role):
        if not GUITAR_LOW <= pitch <= GUITAR_HIGH or end <= start + .04:
            return
        # Do not create a duplicate pitch at one musical attack.
        if any(existing['pitch'] == pitch and abs(existing['start'] - start) <= .025
               for existing in events):
            return
        events.append({'pitch': int(pitch), 'start': float(start), 'end': float(end),
                       'velocity': int(max(30, min(112, velocity))), 'role': role})
        roles[role] += 1

    for item in melody:
        add(item.pitch, item.start, item.end, max(82, item.velocity), 'melody')

    sections = list(getattr(grid, 'chord_sections', ()) or ())
    tempo = max(40.0, float(getattr(grid, 'bpm', 120.0)))
    beat_seconds = 60.0 / tempo
    # V6: build from a held Guitar chord shape and a continuous picking
    # pattern.  This deliberately replaces the old "melody first, then fill
    # a few empty spaces" strategy.  The detected melody remains untouched;
    # it replaces a finger's upper-pattern attack whenever it arrives.
    try:
        meter_beats, meter_unit = (
            int(value) for value in str(getattr(grid, 'time_signature', '4/4')).split('/', 1))
    except (TypeError, ValueError):
        meter_beats, meter_unit = 4, 4
    if meter_unit == 8 and meter_beats == 6:
        pattern = ('bass', 'inner', 'upper', 'bass', 'inner', 'upper')
    elif meter_beats == 3:
        pattern = ('bass', 'inner', 'upper')
    else:
        pattern = ('bass', 'inner', 'upper', 'inner')

    fingerstyle_events = 0
    inserted_gap_textures = 0
    previous_position = None
    arrangement_regions = []
    for section_index, section in enumerate(sections):
        start, end = float(section['start_seconds']), float(section['end_seconds'])
        if end - start < .35 or not _supported_harmony(section, sections, section_index):
            continue
        shape, position = _guitar_shape(
            section, bass_notes, start, end, previous_position)
        if len(shape) < 2:
            continue
        previous_position = position
        section_melody = [item for item in melody if item.start < end and item.end > start]
        # Chord-analysis windows are approximate tonal labels; they are not a
        # rhythmic clock.  The old V6 code divided each label window equally,
        # which put fingerpicking attacks between the actual uploaded-song
        # beats.  Always use the beat tracker for the Guitar's thumb/finger
        # pulse and retain the window only as the current chord-shape state.
        beat_slots = [float(beat) for beat in getattr(grid, 'beat_times', ())
                      if start - .12 <= float(beat) < end - .025]
        if not beat_slots:
            beat_slots = [start + pulse * ((end - start) / len(pattern))
                          for pulse in range(len(pattern))]
        region = {
            'start': round(start, 3), 'end': round(end, 3),
            'chord': '%s:%s' % (section.get('root_pc'), section.get('quality', 'major')),
            'shape': list(shape), 'position': round(position, 2) if position is not None else None,
            'pattern': list(pattern), 'slot_times': [round(value, 3) for value in beat_slots],
            'bass': 0, 'inner': 0, 'melody_integrated': 0,
        }
        # First establish the rhythm from the shape.  A busy lead only
        # suppresses finger notes, never the restrained thumb pulse.
        for pulse, onset in enumerate(beat_slots):
            action = pattern[pulse % len(pattern)]
            next_onset = (beat_slots[pulse + 1]
                          if pulse + 1 < len(beat_slots) else end)
            slot = max(.10, next_onset - onset)
            close_attack = next((item for item in section_melody
                                 if abs(item.start - onset) <= min(.095, slot * .22)), None)
            active = next((item for item in section_melody
                           if item.start <= onset < item.end), None)
            if action == 'bass':
                # Alternate root and the lowest available colour tone, while
                # retaining a clear downbeat root at each chord shape.
                pitch = shape[0] if pulse == 0 or len(shape) < 3 else shape[1]
                next_melody = next((item.start for item in section_melody
                                    if onset + .04 < item.start < onset + slot), None)
                # Release a thumb note just before a real lead attack when
                # the new chord pinch needs that low string.  This is a
                # fingering hand-off, not a deletion of the bass pulse.
                bass_end = min(end - .02, onset + slot * .92)
                if next_melody is not None:
                    bass_end = min(bass_end, next_melody - .018)
                add(pitch, onset, bass_end, 58, 'bass')
                fingerstyle_events += 1
                region['bass'] += 1
                continue
            # Melody owns upper attacks. The held shape continues via the
            # thumb and later fingers instead of stopping the whole measure.
            if action == 'upper' and close_attack is not None:
                continue
            candidates = [pitch for pitch in shape[1:]
                          if active is None or pitch < active.pitch]
            if not candidates:
                continue
            pitch = candidates[-1] if action == 'upper' else candidates[0]
            role = 'arpeggio' if action == 'upper' else 'inner_harmony'
            add(pitch, onset, min(end - .02, onset + slot * .84),
                55 if role == 'arpeggio' else 53, role)
            fingerstyle_events += 1
            region['inner'] += 1
            if active is None and close_attack is None:
                inserted_gap_textures += 1

        # Integrate every melody attack with the *current held shape*, rather
        # than waiting for a later empty space. Short/busy notes get an inner
        # dyad; longer/phrase-opening notes can receive bass plus inner tone.
        for item in section_melody:
            if not (start <= item.start < end):
                continue
            long_note = item.end - item.start >= slot * 1.15
            # A low lead can safely carry root+fifth as a compact pinch; it
            # is still the highest note and reads as Guitar, not a piano
            # stack.  Higher/busier melody stays a light dyad.
            max_support = 2 if (item.pitch <= 59 or
                                (long_note and item.start - start <= slot * .30)) else 1
            support, _ = _select_playable_support(
                item.pitch, shape, max_support,
                previous_position=position,
            )
            for pitch in support:
                role = 'bass' if pitch == shape[0] else 'accompaniment'
                add(pitch, item.start,
                    min(end - .02, item.end, item.start + max(slot * .86, .16)),
                    58 if role == 'bass' else 56, role)
            if support:
                region['melody_integrated'] += 1
        arrangement_regions.append(region)

    # Enforce at most four notes and a 24-semitone spread at any attack.  This
    # only removes accompaniment; the melody has priority.
    grouped = {}
    for event in events:
        grouped.setdefault(round(event['start'] / .025) * .025, []).append(event)
    retained = []
    for group in grouped.values():
        melody_group = [item for item in group if item['role'] == 'melody']
        support = [item for item in group if item['role'] != 'melody']
        selected = list(melody_group)
        for item in sorted(support, key=lambda value: (value['role'] != 'bass', value['pitch'])):
            proposed = selected + [item]
            pitches = [value['pitch'] for value in proposed]
            if (len(proposed) <= MAX_VOICES and
                    max(pitches) - min(pitches) <= MAX_SIMULTANEOUS_SPAN and
                    guitar_string_frets(pitches) is not None):
                selected.append(item)
        retained.extend(selected)
    # A sustained melody can still overlap a later accompaniment attack, so a
    # per-onset cap alone is insufficient.  Apply the same Guitar limit across
    # the complete timeline, always retaining the protected melody first.
    timeline_retained = []
    for item in sorted(retained, key=lambda value: (
            value['start'], value['role'] != 'melody', value['pitch'])):
        active = [value for value in timeline_retained if value['end'] > item['start'] + .001]
        proposed = active + [item]
        pitches = [value['pitch'] for value in proposed]
        if item['role'] == 'melody' and (
                len(proposed) > MAX_VOICES or max(pitches) - min(pitches) > MAX_SIMULTANEOUS_SPAN):
            # The melody wins a collision. Remove only accompaniment already
            # ringing at this instant, preferring to keep the bass anchor.
            removable = sorted(
                [value for value in active if value['role'] != 'melody'],
                key=lambda value: (value['role'] == 'bass', value['start']),
            )
            while removable and (len(proposed) > MAX_VOICES or
                                 max(value['pitch'] for value in proposed) - min(value['pitch'] for value in proposed) > MAX_SIMULTANEOUS_SPAN):
                removed = removable.pop(0)
                # Keep an already-played, valid chord attack when the next
                # melody note arrives early. Shorten its release to that new
                # attack instead of deleting the support event entirely; the
                # latter made rapid instrumental melodies erase every real
                # simultaneous Guitar voicing from the final MIDI.
                if removed['start'] + .06 < item['start']:
                    removed['end'] = min(removed['end'], item['start'])
                    if removed['end'] > removed['start'] + .04:
                        proposed.remove(removed)
                        continue
                timeline_retained.remove(removed)
                proposed.remove(removed)
            pitches = [value['pitch'] for value in proposed]
        if item['role'] != 'melody' and (
                len(proposed) > MAX_VOICES or max(pitches) - min(pitches) > MAX_SIMULTANEOUS_SPAN):
            continue
        timeline_retained.append(item)
    events = _assign_event_fingerings(timeline_retained, grid)
    final_roles = Counter(item['role'] for item in events)

    midi = pretty_midi.PrettyMIDI(initial_tempo=tempo)
    track = pretty_midi.Instrument(program=24, name='Solo Guitar arrangement')
    for item in events:
        track.notes.append(pretty_midi.Note(
            velocity=item['velocity'], pitch=item['pitch'],
            start=item['start'], end=item['end'],
        ))
    midi.instruments.append(track)
    midi.write(output_path)
    fingering_path = output_path + '.fingering.json'
    with open(fingering_path, 'w', encoding='utf-8') as handle:
        json.dump({
            'tuning': list(STANDARD_TUNING),
            'events': [{
                'start_seconds': round(item['start'], 6),
                'start_quarter': item['start_quarter'],
                'pitch': item['pitch'],
                'string': item['string'],
                'fret': item['fret'],
            } for item in events],
        }, handle, indent=2)
    arrangement_report_path = output_path + '.arrangement.json'
    with open(arrangement_report_path, 'w', encoding='utf-8') as handle:
        json.dump({
            'model': 'shape_first_continuous_fingerstyle',
            'meter': str(getattr(grid, 'time_signature', '4/4')),
            'regions': arrangement_regions,
        }, handle, indent=2)

    active = 0
    max_simultaneous = 0
    for time, kind in sorted(
            [(item['start'], 1) for item in events] + [(item['end'], -1) for item in events],
            key=lambda value: (value[0], value[1])):
        active += kind
        max_simultaneous = max(max_simultaneous, active)
    attacks = {}
    for item in events:
        attacks.setdefault(round(item['start'], 3), []).append(item['pitch'])
    voicings = [pitches for pitches in attacks.values() if len(pitches) > 1]
    return {
        'notes': len(events), 'melody_notes': final_roles['melody'],
        'verified_vocal_melody_notes': min(verified_melody_notes, final_roles['melody']),
        'fallback_melody_notes': min(fallback_melody_notes,
                                     max(0, final_roles['melody'] - verified_melody_notes)),
        'accompaniment_notes': final_roles['accompaniment'] + final_roles['arpeggio'],
        'bass_support_notes': final_roles['bass'], 'arpeggio_notes': final_roles['arpeggio'],
        'inner_harmony_events': final_roles['inner_harmony'],
        'fingerstyle_pattern_events': fingerstyle_events,
        'melody_pinch_events': sum(
            1 for pitches in voicings
            if len(pitches) > 1
        ),
        'safe_gap_texture_events': inserted_gap_textures,
        'simultaneous_note_events': len(voicings), 'max_simultaneous_notes': max_simultaneous,
        'pitch_range': ([min(item['pitch'] for item in events), max(item['pitch'] for item in events)]
                        if events else []),
        'voicing_count': len(voicings),
        'average_voicing_size': round(sum(len(item) for item in voicings) / len(voicings), 2) if voicings else 0,
        'duplicate_pitch_onsets': sum(len(pitches) - len(set(pitches)) for pitches in attacks.values()),
        'largest_simultaneous_pitch_span': max((max(pitches) - min(pitches) for pitches in voicings), default=0),
        'string_fret_coverage': len(events),
        'string_collisions': sum(
            len(items) - len({item['string'] for item in items})
            for items in (
                [event for event in events
                 if round(event['start'], 3) == attack]
                for attack in attacks
            )
        ),
        '_fingering_path': fingering_path,
        '_arrangement_report_path': arrangement_report_path,
        'sections': {'melody_only': sum(1 for section in sections if not any(item['start'] >= section['start_seconds'] and item['start'] < section['end_seconds'] and item['role'] != 'melody' for item in events)),
                     'melody_dyad_or_chord': sum(1 for section in sections if any(item['start'] >= section['start_seconds'] and item['start'] < section['end_seconds'] and item['role'] == 'accompaniment' for item in events)),
                     'arpeggio_or_broken_chord': sum(1 for section in sections if any(item['start'] >= section['start_seconds'] and item['start'] < section['end_seconds'] and item['role'] == 'arpeggio' for item in events)),
                     'bass_plus_melody': sum(1 for section in sections if any(item['start'] >= section['start_seconds'] and item['start'] < section['end_seconds'] and item['role'] == 'bass' for item in events) and any(item.start < section['end_seconds'] and item.end > section['start_seconds'] for item in melody))},
    }


# ---------------------------------------------------------------------------
# V9: canonical shape-first performance planning.  The V8 implementation
# above remains intentionally intact for comparison artifacts; this exported
# function supersedes it for fresh Solo Guitar requests.

def _v9_tones(section):
    root = int(section.get('root_pc', 0)) % 12
    quality = section.get('quality', 'major')
    third = (root + (3 if quality == 'minor' else 4)) % 12
    return root, quality, {root, third, (root + 7) % 12}


# These are established beginner/intermediate Guitar grips, expressed from
# string 6 to string 1.  V9 begins from one of these grips; it never invents
# a new six-string combination merely because its pitches spell a chord.
# ``None`` is muted, 0 is open, and LH entries are actual hand assignments.
_V9_OPEN_SHAPES = {
    # root pitch class, quality: (name, six-string fret layout, LH fingers, barre)
    (0, 'major'): ('C_open', (None, 3, 2, 0, 1, 0), (None, 'ring', 'middle', 'open', 'index', 'open'), None),
    (2, 'major'): ('D_open', (None, None, 0, 2, 3, 2), (None, None, 'open', 'index', 'ring', 'middle'), None),
    (4, 'major'): ('E_open', (0, 2, 2, 1, 0, 0), ('open', 'middle', 'ring', 'index', 'open', 'open'), None),
    (5, 'major'): ('F_E_form', (1, 3, 3, 2, 1, 1), ('index/barre', 'ring', 'pinky', 'middle', 'index/barre', 'index/barre'), 1),
    (7, 'major'): ('G_open', (3, 2, 0, 0, 0, 3), ('middle', 'index', 'open', 'open', 'open', 'ring'), None),
    (9, 'major'): ('A_open', (None, 0, 2, 2, 2, 0), (None, 'open', 'index', 'middle', 'ring', 'open'), None),
    (0, 'minor'): ('Cm_A_form', (None, 3, 5, 5, 4, 3), (None, 'index/barre', 'ring', 'pinky', 'middle', 'index/barre'), 3),
    (2, 'minor'): ('Dm_open', (None, None, 0, 2, 3, 1), (None, None, 'open', 'middle', 'ring', 'index'), None),
    (4, 'minor'): ('Em_open', (0, 2, 2, 0, 0, 0), ('open', 'middle', 'ring', 'open', 'open', 'open'), None),
    (5, 'minor'): ('Fm_E_form', (1, 3, 3, 1, 1, 1), ('index/barre', 'ring', 'pinky', 'index/barre', 'index/barre', 'index/barre'), 1),
    (7, 'minor'): ('Gm_E_form', (3, 5, 5, 3, 3, 3), ('index/barre', 'ring', 'pinky', 'index/barre', 'index/barre', 'index/barre'), 3),
    (9, 'minor'): ('Am_open', (None, 0, 2, 2, 1, 0), (None, 'open', 'middle', 'ring', 'index', 'open'), None),
}


def _v9_barre_shape(root, quality, family):
    """Return a recognised E- or A-form movable barre chord, if practical."""
    if family == 'E':
        fret = (root - 4) % 12
        if fret == 0:
            return None
        layout = ((fret, fret + 2, fret + 2, fret + 1, fret, fret)
                  if quality == 'major' else
                  (fret, fret + 2, fret + 2, fret, fret, fret))
        fingers = (('index/barre', 'ring', 'pinky', 'middle', 'index/barre', 'index/barre')
                   if quality == 'major' else
                   ('index/barre', 'ring', 'pinky', 'index/barre', 'index/barre', 'index/barre'))
        return (f'{root}:{quality}:E_form_{fret}', layout, fingers, fret)
    fret = (root - 9) % 12
    if fret == 0:
        return None
    layout = ((None, fret, fret + 2, fret + 2, fret + 2, fret)
              if quality == 'major' else
              (None, fret, fret + 2, fret + 2, fret + 1, fret))
    # A-form major grips use the ring finger as the familiar mini-barre over
    # strings 4--2.  They are not three independent notes played by one
    # imaginary extra finger.
    fingers = ((None, 'index/barre', 'ring/barre', 'ring/barre', 'ring/barre', 'index/barre')
               if quality == 'major' else
               (None, 'index/barre', 'ring', 'pinky', 'middle', 'index/barre'))
    return (f'{root}:{quality}:A_form_{fret}', layout, fingers, fret)


def _v9_shape_candidates(section, previous=None):
    """Return only explicit real-world chord grips and their partial forms."""
    root, quality, _ = _v9_tones(section)
    templates = []
    open_shape = _V9_OPEN_SHAPES.get((root, quality))
    if open_shape:
        templates.append(open_shape)
    for family in ('E', 'A'):
        movable = _v9_barre_shape(root, quality, family)
        if movable is not None and max(fret for fret in movable[1] if fret is not None) <= MAX_FRET:
            templates.append(movable)

    shapes, seen = [], set()
    for name, layout, left_hand, barre in templates:
        # Full grip plus musically normal partial variants.  Variants only
        # mute existing strings; they never manufacture a new fingering.
        variants = [tuple(layout)]
        for muted in ((0,), (0, 1), (5,), (0, 5)):
            partial = list(layout)
            for index in muted:
                partial[index] = None
            if sum(fret is not None for fret in partial) >= 3:
                variants.append(tuple(partial))
        for variant_index, active_layout in enumerate(variants):
            key = tuple(active_layout)
            if key in seen:
                continue
            seen.add(key)
            fretted = [fret for fret in active_layout if fret not in (None, 0)]
            if fretted and max(fretted) - min(fretted) > 4:
                continue
            bass_index = next((i for i, fret in enumerate(active_layout) if fret is not None), None)
            if bass_index is None:
                continue
            shapes.append(GuitarShape(
                id=f'{name}:{"full" if variant_index == 0 else "partial" + str(variant_index)}',
                root_pc=root, quality=quality, layout=active_layout,
                position=float(barre if barre is not None else (min(fretted) if fretted else 0)),
                barre_fret=barre,
                left_hand=tuple(left_hand[i] if active_layout[i] is not None else None for i in range(6)),
                bass_string=6 - bass_index, template_name=name,
            ))
    return shapes


def _v9_melody_location(shape, pitch):
    """Find a melody note in a real grip or a very small local variation."""
    options = []
    for index, open_pitch in enumerate(STANDARD_TUNING):
        fret = int(pitch) - open_pitch
        if not 0 <= fret <= MAX_FRET:
            continue
        # Exact shape pitches are best.  A melody variant must stay on an
        # upper string and no more than two frets from the held shape on that
        # string; this avoids treating a distant arbitrary pitch as the same
        # left-hand chord position.
        shape_fret = shape.layout[index]
        near_shape = (shape_fret == fret or
                      (index >= 3 and shape_fret is not None and
                       abs(fret - shape_fret) <= 2))
        if near_shape:
            string = 6 - index
            score = (0 if shape_fret == fret else 1,
                     0 if string <= 3 else 1,
                     abs(fret - shape.position), string)
            options.append((score, string, fret))
    if not options:
        return None
    _, string, fret = min(options)
    return string, fret


def _v9_transition_cost(previous, current):
    if previous is None:
        return 0.0, 0
    movement = abs(current.position - previous.position)
    anchors = sum(
        1 for before, after in zip(previous.layout, current.layout)
        if before is not None and before == after
    )
    return movement - anchors * .55, anchors


def _v9_pick_pattern(grid, section_melody, start, end):
    density = sum(start <= item.start < end for item in section_melody)
    try:
        beats, unit = (int(v) for v in str(grid.time_signature).split('/', 1))
    except (TypeError, ValueError):
        beats, unit = 4, 4
    if unit == 8 and beats in (6, 12):
        return ('P', 'I', 'M', 'P', 'I', 'A') if density < 5 else ('P', 'I', 'P', 'M')
    if beats == 3:
        return ('P', 'I', 'M') if density < 4 else ('P', 'I')
    return ('P', 'I', 'M', 'A') if density < 5 else ('P', 'I', 'P', 'M')


def _arrange_solo_guitar_v9(melody_notes, bass_notes, grid, output_path,
                             verified_melody_notes=0, fallback_melody_notes=0):
    """Build a V9 Guitar performance plan before writing MIDI or TAB data."""
    melody = _monophonic_melody(melody_notes)
    sections = list(getattr(grid, 'chord_sections', ()) or ())
    tempo = max(40.0, float(getattr(grid, 'bpm', 120.0)))
    events, shape_plan, previous_shape = [], [], None

    def add(pitch, start, end, velocity, role, shape, string, fret, lh, rh):
        if not GUITAR_LOW <= pitch <= GUITAR_HIGH or end <= start + .04:
            return
        # A canonical Guitar event may not overlap a different note on its
        # string.  Different strings are allowed to ring naturally.
        if any(prior['pitch'] == pitch and abs(prior['start'] - start) <= .02
               for prior in events):
            return
        for prior in reversed(events):
            if prior['string'] == string and prior['end'] > start + .001:
                prior['end'] = min(prior['end'], start)
        events.append({
            'time': float(start), 'start': float(start), 'start_seconds': float(start), 'end': float(end),
            'duration': float(end - start), 'pitch': int(pitch), 'string': int(string),
            'fret': int(fret), 'shape_id': shape.id, 'left_hand_finger': lh,
            'right_hand_finger': rh, 'role': role, 'velocity': int(velocity),
            'start_quarter': round(float(grid.seconds_to_quarter(start)) * 8) / 8,
        })

    for index, section in enumerate(sections):
        start, end = float(section['start_seconds']), float(section['end_seconds'])
        if end - start < .35 or not _supported_harmony(section, sections, index):
            continue
        section_melody = [item for item in melody if item.start < end and item.end > start]
        candidates = _v9_shape_candidates(section, previous_shape)
        if not candidates:
            continue
        def score(shape):
            transition, anchors = _v9_transition_cost(previous_shape, shape)
            accessible = sum(_v9_melody_location(shape, item.pitch) is not None
                             for item in section_melody)
            return (accessible * 4 + anchors * .8 - transition,
                    accessible, anchors)
        shape = max(candidates, key=score)
        transition, anchors = _v9_transition_cost(previous_shape, shape)
        previous_shape = shape
        pattern = _v9_pick_pattern(grid, section_melody, start, end)
        beat_slots = [float(beat) for beat in getattr(grid, 'beat_times', ())
                      if start - .12 <= float(beat) < end - .025]
        if not beat_slots:
            beat_slots = [start + pulse * ((end - start) / len(pattern))
                          for pulse in range(len(pattern))]
        voiced = {string: (fret, pitch) for string, fret, pitch in shape.voiced}
        upper = [string for string in sorted(voiced) if string <= 3]
        inner = [string for string in sorted(voiced) if 3 <= string <= 4]
        plan_row = {
            'start': round(start, 3), 'end': round(end, 3),
            'chord': f'{shape.root_pc}:{shape.quality}', 'shape_id': shape.id,
            'layout_6_to_1': ['x' if fret is None else fret for fret in shape.layout],
            'position': shape.position, 'barre_fret': shape.barre_fret,
            'template_name': shape.template_name,
            'left_hand': list(shape.left_hand), 'bass_string': shape.bass_string,
            'pattern': list(pattern), 'transition_cost': round(transition, 2),
            'anchored_fingers': anchors, 'melody_shape_changes': 0,
        }
        for pulse, onset in enumerate(beat_slots):
            rh = pattern[pulse % len(pattern)]
            next_onset = beat_slots[pulse + 1] if pulse + 1 < len(beat_slots) else end
            duration = min(end - .02, onset + max(.12, (next_onset - onset) * .92))
            nearby_melody = next((item for item in section_melody
                                  if abs(item.start - onset) <= .09), None)
            if rh == 'P':
                string = shape.bass_string
            elif rh == 'I':
                string = (inner[0] if inner else (upper[0] if upper else shape.bass_string))
            elif rh == 'M':
                string = (upper[0] if upper else (inner[-1] if inner else shape.bass_string))
            else:
                string = (upper[-1] if upper else (inner[-1] if inner else shape.bass_string))
            if rh != 'P' and nearby_melody is not None:
                continue  # Melody replaces the scheduled finger attack.
            fret, pitch = voiced[string]
            add(pitch, onset, duration, 57 if rh == 'P' else 53,
                'bass' if rh == 'P' else 'inner', shape, string, fret,
                shape.left_hand[6 - string], rh)
        # Integrate melody using the active shape or a nearby shape variation.
        for item in section_melody:
            if not start <= item.start < end:
                continue
            location = _v9_melody_location(shape, item.pitch)
            if location is None:
                plan_row['melody_shape_changes'] += 1
                # The source melody remains protected, but this is marked as
                # an actual temporary position change rather than pretending
                # it belongs to the current grip.
                options = [(6 - i, item.pitch - open_pitch)
                           for i, open_pitch in enumerate(STANDARD_TUNING)
                           if 0 <= item.pitch - open_pitch <= MAX_FRET and i >= 3]
                if not options:
                    continue
                string, fret = min(options, key=lambda x: (abs(x[1] - shape.position), x[0]))
                lh = 'melody shift'
            else:
                string, fret = location
                lh = shape.left_hand[6 - string] if shape.layout[6 - string] == fret else 'melody variation'
            add(item.pitch, item.start, min(item.end, end - .01), max(78, item.velocity),
                'melody', shape, string, fret, lh, 'A' if string == 1 else ('M' if string == 2 else 'I'))
            # The active chord grip supplies a nearby inner-string pinch at
            # the melody attack whenever a distinct string is available.
            # Prefer the chord's colour/fifth below the melody, rather than
            # merely the first lower string (which is often another root).
            inner_options = [voice for voice in shape.voiced
                             if voice[0] != string and voice[2] < item.pitch and
                             item.pitch - voice[2] <= MAX_SIMULTANEOUS_SPAN]
            non_root = [voice for voice in inner_options
                        if voice[2] % 12 != shape.root_pc]
            inner_voice = max(non_root or inner_options,
                              key=lambda voice: voice[2], default=None)
            if inner_voice is not None:
                voice_string, voice_fret, voice_pitch = inner_voice
                add(voice_pitch, item.start, min(item.end, item.start + .30), 55,
                    'inner', shape, voice_string, voice_fret,
                    shape.left_hand[6 - voice_string], 'I')
            # Long melody can carry a bass+melody pinch from the held shape.
            if ((item.end - item.start >= .42 or item.pitch <= 59) and
                    string != shape.bass_string):
                bass_fret, bass_pitch = voiced[shape.bass_string]
                if item.pitch - bass_pitch <= MAX_SIMULTANEOUS_SPAN:
                    add(bass_pitch, item.start, min(item.end, item.start + .34), 58,
                        'pinch_bass', shape, shape.bass_string, bass_fret,
                        shape.left_hand[6 - shape.bass_string], 'P')
        shape_plan.append(plan_row)

    # Harmony may be intentionally rejected in a low-confidence region. The
    # protected lead must still remain a complete, playable Guitar melody.
    melody_shape = GuitarShape('melody-only', 0, 'none',
        (None, None, None, None, None, None), 0.0, None,
        (None, None, None, None, None, None), 6)
    for item in melody:
        if any(event['pitch'] == item.pitch and abs(event['start'] - item.start) <= .02
               for event in events):
            continue
        options = [(6 - index, item.pitch - open_pitch)
                   for index, open_pitch in enumerate(STANDARD_TUNING)
                   if 0 <= item.pitch - open_pitch <= MAX_FRET]
        if not options:
            continue
        string, fret = min(options, key=lambda value: (value[0] > 3, value[1]))
        add(item.pitch, item.start, item.end, max(78, item.velocity), 'melody',
            melody_shape, string, fret, 'melody only',
            'A' if string == 1 else ('M' if string == 2 else 'I'))

    # Do not run V8's independent fingering pass. Filter only invalid/fully
    # superseded events while retaining their already-planned string/fret data.
    events = [event for event in events if event['end'] > event['start'] + .04]
    events.sort(key=lambda event: (event['start'], event['string'], event['pitch']))
    midi = pretty_midi.PrettyMIDI(initial_tempo=tempo)
    track = pretty_midi.Instrument(program=24, name='Solo Guitar V9 arrangement')
    for event in events:
        track.notes.append(pretty_midi.Note(velocity=int(event['velocity']),
            pitch=event['pitch'], start=event['start'], end=event['end']))
    midi.instruments.append(track)
    midi.write(output_path)

    fingering_path = output_path + '.fingering.json'
    with open(fingering_path, 'w', encoding='utf-8') as handle:
        json.dump({'tuning': list(STANDARD_TUNING), 'events': events}, handle, indent=2)
    plan_path = output_path + '.performance_plan.json'
    with open(plan_path, 'w', encoding='utf-8') as handle:
        json.dump({'model': 'v9_shape_performance_plan', 'shapes': shape_plan,
                   'events': events}, handle, indent=2)

    roles = Counter(event['role'] for event in events)
    attacks = {}
    for event in events:
        attacks.setdefault(round(event['start'], 3), []).append(event)
    # A stroke has deliberately staggered physical string contacts, but is
    # still one musical chord gesture.  Keep both views so diagnostics do
    # not mislabel a real down/up stroke as a monophonic passage.
    gesture_groups = {}
    for event in events:
        gesture_groups.setdefault(event.get('gesture_id'), []).append(event)
    repeated_changes = 0
    latest = {}
    for event in events:
        old = latest.get(event['pitch'])
        if old and event['start'] - old['start'] < 6 and (old['string'], old['fret']) != (event['string'], event['fret']):
            repeated_changes += 1
        latest[event['pitch']] = event
    movements = [abs(shape_plan[i]['position'] - shape_plan[i - 1]['position'])
                 for i in range(1, len(shape_plan))]
    collisions = sum(len(group) - len({event['string'] for event in group})
                     for group in attacks.values())
    return {
        'notes': len(events), 'melody_notes': roles['melody'],
        'verified_vocal_melody_notes': min(verified_melody_notes, roles['melody']),
        'fallback_melody_notes': min(fallback_melody_notes, max(0, roles['melody'] - verified_melody_notes)),
        'bass_support_notes': roles['bass'] + roles['pinch_bass'],
        'accompaniment_notes': roles['inner'], 'arpeggio_notes': 0,
        'inner_harmony_events': roles['inner'], 'fingerstyle_pattern_events': roles['bass'] + roles['inner'],
        'melody_pinch_events': roles['pinch_bass'],
        # V9's continuous shape pattern is also what fills genuine melody
        # gaps; retain this compatibility metric for the existing audit.
        'safe_gap_texture_events': roles['inner'],
        'simultaneous_note_events': sum(1 for group in gesture_groups.values() if len(group) > 1),
        'max_simultaneous_notes': max((len(group) for group in gesture_groups.values()), default=0),
        'pitch_range': ([min(event['pitch'] for event in events), max(event['pitch'] for event in events)] if events else []),
        'voicing_count': sum(1 for group in attacks.values() if len(group) > 1),
        'average_voicing_size': round(sum(len(group) for group in attacks.values() if len(group) > 1) / max(1, sum(1 for group in attacks.values() if len(group) > 1)), 2),
        'duplicate_pitch_onsets': sum(len(group) - len({event['pitch'] for event in group}) for group in attacks.values()),
        'largest_simultaneous_pitch_span': max((max(event['pitch'] for event in group) - min(event['pitch'] for event in group) for group in attacks.values() if len(group) > 1), default=0),
        'string_fret_coverage': len(events), 'string_collisions': collisions,
        'repeated_pitch_string_changes': repeated_changes,
        'shape_transition_average': round(sum(movements) / len(movements), 2) if movements else 0,
        'shape_transition_max': max(movements, default=0),
        'anchored_finger_retention': sum(shape['anchored_fingers'] for shape in shape_plan),
        'melody_shape_changes': sum(shape['melody_shape_changes'] for shape in shape_plan),
        '_fingering_path': fingering_path, '_performance_plan_path': plan_path,
        'sections': {'shape_regions': len(shape_plan)},
    }


# V12 unified arranger -------------------------------------------------------
# Analysis remains independent (melody, chords, bass evidence and beat grid),
# but no analysis stream is ever turned into a separate Guitar part.  A
# MusicalMoment is resolved directly into one or more physical gestures.

@dataclass(frozen=True)
class MusicalMoment:
    start: float
    end: float
    melody_notes: tuple
    chord_section: dict
    bass_information: tuple
    beat_strength: float
    phrase_position: str
    density: int


def _unified_phrase_position(melody, item):
    index = melody.index(item)
    previous = melody[index - 1] if index else None
    following = melody[index + 1] if index + 1 < len(melody) else None
    if previous is None or item.start - previous.end >= .32:
        return 'start'
    if following is None or following.start - item.end >= .32:
        return 'end'
    return 'middle'


def _unified_moments(melody, bass_notes, grid):
    """Turn analysis streams into contexts, never pre-arranged Guitar parts."""
    sections = list(getattr(grid, 'chord_sections', ()) or ())
    result = []
    for index, section in enumerate(sections):
        start = float(section.get('start_seconds', 0.0))
        end = float(section.get('end_seconds', start))
        if end <= start + .08:
            continue
        notes = tuple(item for item in melody if item.start < end and item.end > start)
        bass = tuple(item for item in bass_notes if start <= item.start < end)
        beats = [float(beat) for beat in getattr(grid, 'beat_times', ())
                 if start - .04 <= float(beat) < end - .02]
        result.append(MusicalMoment(
            start=start, end=end, melody_notes=notes, chord_section=section,
            bass_information=bass,
            beat_strength=1.0 if beats and abs(beats[0] - start) < .14 else .55,
            phrase_position=(_unified_phrase_position(melody, notes[0]) if notes else 'gap'),
            density=len(notes),
        ))
    return result


def _unified_voice_pool(shape, melody_pitch=None, melody_string=None):
    """Select a compact palette from the actual held chord shape."""
    voices = list(shape.voiced)
    if melody_pitch is not None:
        voices = [voice for voice in voices
                  if voice[0] != melody_string and voice[2] < melody_pitch and
                  melody_pitch - voice[2] <= MAX_SIMULTANEOUS_SPAN]
    bass = [voice for voice in voices if voice[0] >= 4]
    inner = [voice for voice in voices if voice[0] in (2, 3, 4)]
    upper = [voice for voice in voices if voice[0] in (1, 2, 3)]
    return bass, inner, upper


def _unified_recovery_tones(shape, pitch, melody_string, melody_fret,
                            start, events):
    """Find supporting strings in the held real grip, not new MIDI pitches."""
    active_melody_strings = {
        event['string'] for event in events
        if event['role'] == 'melody' and event['start'] < start and
        event['end'] > start + .001
    }
    candidates = []
    rejected = Counter()
    for string, fret, tone in shape.voiced:
        if string == melody_string or string in active_melody_strings:
            rejected['string_conflict'] += 1
            continue
        if tone >= pitch or pitch - tone > MAX_SIMULTANEOUS_SPAN:
            rejected['melody_register'] += 1
            continue
        fretted = [value for value in (fret, melody_fret) if value > 0]
        if fretted and max(fretted) - min(fretted) > 4:
            rejected['fret_span_limit'] += 1
            continue
        interval = (tone - shape.root_pc) % 12
        colour = 0 if interval in (3, 4) else 1 if interval == 7 else 2
        rank = (colour, 0 if string in (2, 3, 4) else 1,
                abs(fret - shape.position), -tone)
        candidates.append((rank, (string, fret, tone,
                                  shape.left_hand[6 - string],
                                  'bass' if string >= 5 else 'inner')))
    candidates.sort(key=lambda entry: entry[0])
    return [voice for _, voice in candidates], rejected


def _unified_phrase_shape_recovery(base, section, previous, melody):
    """Change a grip only when a short melody window gains real support."""
    notes = [item for item in melody if item.end - item.start >= .26]
    if len(notes) < 3:
        return base, 0

    def coverage(shape):
        count = 0
        for item in notes:
            location = _v11_protected_melody_location(
                shape, item.pitch, item.start, [])
            if location is None:
                continue
            string, fret, _ = location
            tones, _ = _unified_recovery_tones(
                shape, item.pitch, string, fret, item.start, [])
            count += bool(tones)
        return count

    baseline = coverage(base)
    if baseline >= max(2, len(notes) * .5):
        return base, 0
    choices = []
    for candidate in _v9_shape_candidates(section):
        if candidate.id == base.id:
            continue
        transition, anchors = _v9_transition_cost(previous, candidate)
        gain = coverage(candidate) - baseline
        movement = abs(candidate.position - base.position)
        # A larger position change is justified only for a whole phrase of
        # otherwise unsupported high melody, never for a single passing note.
        if (movement > 8 or transition > 8 or
                (movement > 4 and gain < 3)):
            continue
        if gain >= 2:
            choices.append((gain, anchors, -transition, candidate))
    if not choices:
        return base, 0
    best = max(choices, key=lambda item: item[:3])
    return best[3], best[0]


def _unified_safe_held_shape_carry(moments, index, shape):
    """Permit a quiet partial grip across one weak but unchanged chord cell."""
    if shape is None or index < 2:
        return False
    current = moments[index].chord_section
    before = [moments[index - step].chord_section for step in (1, 2)]
    signature = (current.get('root_pc'), current.get('quality'))
    return (signature == (shape.root_pc, shape.quality) and
            all(signature == (item.get('root_pc'), item.get('quality')) and
                float(item.get('confidence', 0)) >= .045 for item in before) and
            float(current.get('confidence', 0)) >= .005)


def arrange_solo_guitar(melody_notes, bass_notes, grid, output_path,
                        verified_melody_notes=0, fallback_melody_notes=0,
                        enable_partial_recovery=True,
                        experimental_planning=False):
    """Create one coherent Guitar performance from unified musical moments.

    This intentionally does not call the legacy V10 scheduler.  Each emitted
    event belongs to a gesture selected from the chord shape, melody and bass
    *information together*.  The source bass is only consulted to choose an
    inversion/arrival; it is never copied as a separate bass track.
    """
    melody = _monophonic_melody(melody_notes)
    tempo = max(40.0, float(getattr(grid, 'bpm', 120.0)))
    moments = _unified_moments(melody, bass_notes, grid)
    planned_shapes = None
    if experimental_planning:
        from guitar_planning_experiment import plan_economical_shapes
        planned_shapes = plan_economical_shapes(moments)
    events, plan, decisions = [], [], []
    rejected_voicings = Counter()
    phrase_lookahead_recoveries = 0
    previous_shape = None
    next_gesture_id = 1

    def rh_for(string):
        return 'P' if string >= 4 else ('I' if string == 3 else ('M' if string == 2 else 'A'))

    def add_event(pitch, start, end, velocity, shape, string, fret, lh, role,
                  gesture_id, gesture_type, direction=None, action='pluck'):
        if not GUITAR_LOW <= int(pitch) <= GUITAR_HIGH or end <= start + .045:
            return False
        # Same-string reuse is a physical release, not a reason to delete a
        # protected melody.  A new support note yields to an existing melody.
        for prior in list(events):
            if prior['string'] != string or prior['end'] <= start + .001:
                continue
            if prior['role'] == 'melody' and role != 'melody':
                return False
            if prior['start'] < start:
                prior['end'] = prior['ring_until'] = round(start, 6)
                prior['duration'] = round(prior['end'] - prior['start'], 6)
                prior['let_ring'] = False
                prior['mute_reason'] = 'same_string_reuse'
            elif role == 'melody' and prior['role'] != 'melody':
                events.remove(prior)
            else:
                return False
        if any(event['pitch'] == int(pitch) and abs(event['start'] - start) < .008
               for event in events):
            return False
        events.append({
            'time': round(start, 6), 'start': round(start, 6),
            'start_seconds': round(start, 6), 'end': round(end, 6),
            'duration': round(end - start, 6), 'pitch': int(pitch),
            'velocity': int(max(1, min(127, velocity))), 'string': int(string),
            'fret': int(fret), 'shape_id': shape.id,
            'left_hand_finger': _v10_finger_number(lh),
            'right_hand_finger': rh_for(string), 'role': role,
            'gesture_id': gesture_id, 'gesture_type': gesture_type,
            'stroke_direction': direction, 'action': action,
            'articulation': 'strum' if action == 'strum' else 'finger_pluck',
            'let_ring': True, 'ring_until': round(end, 6), 'mute_reason': None,
            'chord': f'{shape.root_pc}:{shape.quality}',
            'start_quarter': round(float(grid.seconds_to_quarter(start)) * 8) / 8,
        })
        return True

    def emit_gesture(moment, shape, voices, gesture_type, melody_item=None,
                     direction=None, reason=''):
        """Emit one physical action; all constituent notes share its ID."""
        nonlocal next_gesture_id
        if not voices:
            return 0
        gesture_id = next_gesture_id
        next_gesture_id += 1
        base = melody_item.start if melody_item else moment.start
        ordered = list(voices)
        if direction == 'down':
            ordered.sort(key=lambda voice: voice[0], reverse=True)  # 6 -> 1
        elif direction == 'up':
            ordered.sort(key=lambda voice: voice[0])                 # 1 -> 6
        emitted = 0
        emitted_roles = []
        melody_index = next((i for i, voice in enumerate(ordered)
                             if voice[4] == 'melody'), 0)
        if direction and melody_item is not None:
            base = max(moment.start, melody_item.start - melody_index * .014)
        for index, (string, fret, pitch, lh, role) in enumerate(ordered):
            attack = base + (index * .014 if direction else 0.0)
            if role == 'melody' and melody_item is not None:
                # The identity note keeps its analysed onset even inside a stroke.
                attack = melody_item.start
                length = max(.10, min(moment.end - .01, melody_item.end) - attack)
                velocity = max(92, min(112, melody_item.velocity + 7))
            else:
                length = .48 if direction else .34
                if gesture_type in {
                        'PARTIAL_CHORD_MELODY', 'DYAD_MELODY',
                        'ONE_SAFE_HARMONY_TONE', 'ALTERNATE_SHAPE_RECOVERY'}:
                    # Recovery tones belong to the held grip: let them ring
                    # beneath a following lead attack until a physical reuse
                    # or the next harmony boundary releases them.
                    length = .75
                length = min(length, max(.10, moment.end - attack - .01))
                velocity = 70 if role == 'bass' else (63 if role == 'inner' else 60)
            accepted = add_event(
                pitch, attack, attack + length, velocity, shape, string, fret, lh,
                role, gesture_id, gesture_type, direction,
                'strum' if direction else ('pinch' if gesture_type == 'PINCH' else 'pluck'))
            emitted += int(accepted)
            if accepted:
                emitted_roles.append(role)
        if emitted:
            actual_type = (gesture_type if not melody_item or
                           gesture_type == 'MELODY_OVER_RINGING_HARMONY' or
                           any(role != 'melody' for role in emitted_roles)
                           else 'SINGLE_MELODY_PLUCK')
            decisions.append({
                'time': round(base, 3), 'shape': shape.id,
                'gesture_id': gesture_id, 'gesture': actual_type,
                'direction': direction,
                'reason': ('string_conflict' if melody_item and
                           actual_type == 'SINGLE_MELODY_PLUCK' and
                           gesture_type != 'SINGLE_MELODY_PLUCK' else reason),
                'strings': [voice[0] for voice in ordered],
                'emitted_roles': emitted_roles,
            })
        return emitted

    for moment_index, moment in enumerate(moments):
        usable = _v10_harmony_is_usable(
            moment.chord_section, [item.chord_section for item in moments],
            moment_index, previous_shape)
        limited_carry = (not usable and enable_partial_recovery and
                         _unified_safe_held_shape_carry(
                             moments, moment_index, previous_shape))
        if experimental_planning and planned_shapes is not None:
            shape = planned_shapes[moment_index]
            transition, anchors = _v9_transition_cost(previous_shape, shape)
            carried = previous_shape is not None and previous_shape.id == shape.id
        elif experimental_planning:
            from guitar_planning_experiment import choose_economical_shape
            upcoming = [note for later in moments[moment_index:moment_index + 2]
                        for note in later.melody_notes
                        if note.start >= moment.start]
            shape, carried, transition, anchors = choose_economical_shape(
                moment.chord_section, previous_shape,
                list(moment.melody_notes), upcoming)
        else:
            shape, carried, transition, anchors = _v10_choose_shape(
                moment.chord_section, previous_shape, list(moment.melody_notes))
        if shape is None:
            continue
        if not usable and previous_shape is not None and not experimental_planning:
            shape, carried, transition, anchors = previous_shape, True, 0.0, 0
        elif not usable and previous_shape is not None and experimental_planning:
            if (shape.root_pc, shape.quality) != (previous_shape.root_pc,
                                                  previous_shape.quality):
                shape, carried, transition, anchors = previous_shape, True, 0.0, 0
        texture_usable = usable or (experimental_planning and
            previous_shape is not None and
            (shape.root_pc, shape.quality) ==
            (moment.chord_section.get('root_pc'), moment.chord_section.get('quality')) and
            float(moment.chord_section.get('confidence', 0)) >= .012)
        recovered_notes = 0
        if usable and shape is not None and enable_partial_recovery and not experimental_planning:
            recovered_shape, recovered_notes = _unified_phrase_shape_recovery(
                shape, moment.chord_section, previous_shape,
                [item for item in moment.melody_notes
                 if moment.start <= item.start < moment.end])
            if recovered_notes:
                shape = recovered_shape
                transition, anchors = _v9_transition_cost(previous_shape, shape)
                carried = previous_shape is not None and shape.id == previous_shape.id
                phrase_lookahead_recoveries += recovered_notes
        previous_shape = shape
        voiced = {string: (fret, pitch) for string, fret, pitch in shape.voiced}
        shape_row = {
            'start': round(moment.start, 3), 'end': round(moment.end, 3),
            'chord': f'{shape.root_pc}:{shape.quality}', 'shape_id': shape.id,
            'layout_6_to_1': ['x' if value is None else value for value in shape.layout],
            'left_hand_1_to_4': [_v10_finger_number(value) for value in shape.left_hand],
            'hand_position': shape.position, 'barre_fret': shape.barre_fret,
            'carried_previous_shape': carried, 'transition_cost': round(transition, 2),
            'phrase_lookahead_recovered_notes': recovered_notes if usable else 0,
            'anchored_fingers': anchors, 'source_bass_considered': [
                {'time': round(note.start, 3), 'pitch': note.pitch}
                for note in moment.bass_information[:2]],
            'gestures': [], 'melody_variations': [],
            'alternate_shape_recoveries': [],
        }
        chord_changed = moment_index == 0 or not carried
        # A chord onset without melody is one chord gesture, never a later
        # merge of independently generated bass/chord notes.
        near_arrival = next((item for item in moment.melody_notes
                             if item.start <= moment.start + .11), None)
        if usable and chord_changed and near_arrival is None:
            bass, inner, upper = _unified_voice_pool(shape)
            selected = (bass[:1] + sorted(inner, key=lambda voice: voice[2])[-2:] +
                        sorted(upper, key=lambda voice: voice[2])[-1:])
            voices = [(s, f, p, shape.left_hand[6 - s], 'bass' if s >= 4 else 'inner')
                      for s, f, p in selected]
            emit_gesture(moment, shape, voices, 'FULL_CHORD_STRUM',
                         direction='down' if moment_index % 2 == 0 else 'up',
                         reason='harmonic_arrival')

        for item in moment.melody_notes:
            if not moment.start <= item.start < moment.end:
                continue
            location = _v11_protected_melody_location(shape, item.pitch, item.start, events)
            if location is None:
                continue
            melody_string, melody_fret, variation = location
            melody_voice = (melody_string, melody_fret, item.pitch,
                            shape.left_hand[6 - melody_string] if variation == 'shape'
                            else ('open' if melody_fret == 0 else None), 'melody')
            bass, inner, upper = _unified_voice_pool(shape, item.pitch, melody_string)
            phrase = _unified_phrase_position(melody, item)
            long_or_arrival = item.end - item.start >= .36 or phrase == 'start' or chord_changed
            prior_melody = max((note for note in melody if note.end <= item.start + .01),
                               key=lambda note: note.end, default=None)
            next_melody = min((note for note in melody if note.start >= item.end - .01),
                              key=lambda note: note.start, default=None)
            gap_before = (item.start - prior_melody.end if prior_melody else 1.0)
            gap_after = (next_melody.start - item.end if next_melody else 1.0)
            beat_times = [float(beat) for beat in getattr(grid, 'beat_times', ())]
            # A short melody note may still belong to a strong harmonic beat.
            # It gets a *partial* held-shape colour only when there is enough
            # physical room around it; rapid runs remain clean single notes.
            strong_beat = (abs(item.start - moment.start) <= .085 or
                           any(abs(item.start - beat) <= .085 for beat in beat_times))
            partial_arrival = (strong_beat and gap_before >= .10 and
                               gap_after >= .10)
            # This is the central unified decision: chord/bass support is
            # selected only as part of the same physical melody gesture.
            support = []
            if experimental_planning and texture_usable:
                # A held grip supplies middle-string colour between meaningful
                # bass arrivals. The musical beat comes from the experiment's
                # hierarchy; do not manufacture an independent bass track.
                beat_seconds = 60.0 / max(40.0, float(grid.bpm))
                recent_bass = any(event['role'] == 'bass' and
                                  item.start - beat_seconds * .82 < event['start'] <= item.start
                                  for event in events)
                structural = chord_changed or phrase == 'start' or (
                    strong_beat and gap_before >= .15)
                root = next((voice for voice in sorted(bass, key=lambda voice: voice[2])
                             if voice[2] % 12 == shape.root_pc), None)
                if structural and not recent_bass and root is not None:
                    support.append(root)
                if long_or_arrival or partial_arrival or moment.density <= 4:
                    colour = [voice for voice in inner
                              if voice[2] % 12 != shape.root_pc]
                    if not colour:
                        colour = inner
                    for voice in sorted(colour, key=lambda value: value[2], reverse=True):
                        if voice[0] != melody_string and voice not in support:
                            support.append(voice)
                        if len(support) >= (3 if structural and moment.density <= 3 else 2):
                            break
            elif usable and long_or_arrival:
                root = next((voice for voice in sorted(bass, key=lambda voice: voice[2])
                             if voice[2] % 12 == shape.root_pc), None)
                fifth = next((voice for voice in sorted(bass + inner, key=lambda voice: voice[2])
                              if voice[2] % 12 == (shape.root_pc + 7) % 12), None)
                if root is not None:
                    support.append(root)
                # A low melody needs the familiar root/fifth shell, rather
                # than an octave/root stack that hides its contour.
                if item.pitch <= 59 and fifth is not None:
                    support.append(fifth)
                else:
                    colour = [voice for voice in inner
                              if voice[2] % 12 != shape.root_pc]
                    support.extend(sorted(colour, key=lambda voice: voice[2], reverse=True)[:2])
                    if not colour and fifth is not None:
                        support.append(fifth)
            elif usable and (moment.density <= 3 or partial_arrival or phrase != 'middle'):
                candidate = max(inner or upper, key=lambda voice: voice[2], default=None)
                if candidate is not None:
                    support.append(candidate)
            voices = [(s, f, p, shape.left_hand[6 - s],
                       ('bass' if s >= 4 else 'inner') if not experimental_planning
                       else ('bass' if root is not None and (s, f, p) == root and
                             structural else 'inner'))
                      for s, f, p in support] + [melody_voice]
            # Avoid duplicate strings in a partial shape before physical emission.
            unique = {}
            for voice in voices:
                unique[voice[0]] = voice
            voices = list(unique.values())
            recovery_kind = None
            recovery_reason = 'melody_integrated_into_held_shape'
            if len(voices) == 1 and enable_partial_recovery:
                held_pcs = {pitch % 12 for _, _, pitch in shape.voiced}
                ringing = [event for event in events
                           if event['role'] != 'melody' and
                           event['start'] < item.start and
                           event['end'] > item.start + .04 and
                           event['string'] != melody_string and
                           event['pitch'] < item.pitch and
                           event['pitch'] % 12 in held_pcs]
                important = (long_or_arrival or partial_arrival or
                             (strong_beat and moment.density <= 5))
                if (usable or limited_carry) and important and not ringing:
                    options, rejected = _unified_recovery_tones(
                        shape, item.pitch, melody_string, melody_fret,
                        item.start, events)
                    rejected_voicings.update(rejected)
                    if options:
                        # A strong, spacious arrival can imply a partial
                        # three-string grip. Otherwise a dyad is enough.
                        count = (2 if (usable and long_or_arrival and moment.density <= 4
                                       and len(options) >= 2) else 1)
                        voices = options[:count] + [melody_voice]
                        recovery_kind = ('PARTIAL_CHORD_MELODY' if count == 2
                                         else 'DYAD_MELODY' if variation == 'shape'
                                         else 'ONE_SAFE_HARMONY_TONE')
                        recovery_reason = ('stable_held_chord_carry'
                                           if limited_carry else
                                           'held_shape_partial_recovery')
                    else:
                        # Only a nearby established grip may replace the
                        # current one. Never search the whole fretboard for
                        # an arbitrary chord pitch after melody selection.
                        alternatives = []
                        for candidate in (_v9_shape_candidates(moment.chord_section)
                                          if usable else []):
                            if candidate.id == shape.id or (
                                    abs(candidate.position - shape.position) > 4):
                                continue
                            cost, common = _v9_transition_cost(shape, candidate)
                            if cost > 4:
                                rejected_voicings['transition_cost'] += 1
                                continue
                            location = _v10_melody_location(candidate, item.pitch)
                            if location is None:
                                rejected_voicings['melody_register'] += 1
                                continue
                            alt_string, alt_fret, alt_variation = location
                            tones, failures = _unified_recovery_tones(
                                candidate, item.pitch, alt_string, alt_fret,
                                item.start, events)
                            rejected_voicings.update(failures)
                            if tones:
                                alternatives.append((common, -cost,
                                                     len(tones), candidate,
                                                     location, tones))
                        if alternatives:
                            _, _, _, shape, location, tones = max(
                                alternatives, key=lambda choice: choice[:3])
                            melody_string, melody_fret, variation = location
                            melody_voice = (
                                melody_string, melody_fret, item.pitch,
                                shape.left_hand[6 - melody_string]
                                if variation == 'shape' else
                                ('open' if melody_fret == 0 else None), 'melody')
                            voices = tones[:1] + [melody_voice]
                            recovery_kind = 'ALTERNATE_SHAPE_RECOVERY'
                            recovery_reason = 'nearby_real_grip_recovery'
                            shape_row['alternate_shape_recoveries'].append({
                                'time': round(item.start, 3),
                                'pitch': item.pitch, 'shape_id': shape.id,
                                'layout_6_to_1': [
                                    'x' if value is None else value
                                    for value in shape.layout],
                            })
                            previous_shape = shape
                        else:
                            recovery_reason = (rejected.most_common(1)[0][0]
                                               if rejected else 'no_playable_shape')
                elif ringing:
                    recovery_kind = 'MELODY_OVER_RINGING_HARMONY'
                    recovery_reason = 'compatible_previous_string_ringing'
                elif not usable:
                    recovery_reason = 'low_confidence_chord'
                elif moment.density > 5 and not important:
                    recovery_reason = 'dense_melody'
                else:
                    recovery_reason = 'intentional_texture_reduction'
            if recovery_kind is not None:
                kind, direction = recovery_kind, None
            elif len(voices) >= 3:
                # Low melody shell voicings are a pinch: their strings are
                # intentionally one action at the melody arrival. Higher
                # melody-top grips can retain a light physical downstroke.
                kind, direction = 'MELODY_TOP_CHORD', (None if item.pitch <= 59 else 'down')
            elif len(voices) == 2:
                kind, direction = 'MELODY_TOP_PARTIAL', None
            else:
                kind, direction = 'SINGLE_MELODY_PLUCK', None
            emit_gesture(moment, shape, voices, kind, item, direction,
                         reason=recovery_reason)
            if variation != 'shape':
                shape_row['melody_variations'].append({
                    'time': round(item.start, 3), 'pitch': item.pitch,
                    'string': melody_string, 'fret': melody_fret, 'reason': variation})

        # Fill a genuine phrase/melody gap only from the held shape. The
        # selected note is a continuation gesture, not an accompaniment part.
        if texture_usable:
            melody_times = sorted((item.start for item in moment.melody_notes))
            pulse_times = _v10_slots(grid, moment.start, moment.end, 4)
            for pulse in pulse_times:
                if any(abs(pulse - onset) < .13 for onset in melody_times):
                    continue
                next_melody = min((item.start for item in moment.melody_notes if item.start > pulse),
                                  default=moment.end)
                if next_melody - pulse < .18:
                    continue
                _, inner, upper = _unified_voice_pool(shape)
                choice = max(inner or upper, key=lambda voice: voice[2], default=None)
                if choice is None:
                    continue
                s, f, p = choice
                emit_gesture(moment, shape, [(s, f, p, shape.left_hand[6 - s], 'inner')],
                             'FINGERSTYLE_PATTERN', reason='held_shape_gap_continuation')
        shape_row['gestures'] = [item for item in decisions
                                 if moment.start - .03 <= item['time'] < moment.end]
        plan.append(shape_row)

    # Last-resort protected melody handling occurs as a Guitar gesture too;
    # it is never post-hoc MIDI/fret reassignment.
    fallback_shape = GuitarShape('protected-melody', 0, 'none', (None,) * 6,
                                 0.0, None, (None,) * 6, 6, 'protected_melody')
    for item in melody:
        if any(event['role'] == 'melody' and event['pitch'] == item.pitch and
               abs(event['start'] - item.start) < .008 for event in events):
            continue
        candidates = [(6 - index, item.pitch - open_pitch)
                      for index, open_pitch in enumerate(STANDARD_TUNING)
                      if 0 <= item.pitch - open_pitch <= MAX_FRET]
        if not candidates:
            continue
        string, fret = min(candidates, key=lambda value: (value[0] > 3, value[1]))
        fallback_moment = MusicalMoment(item.start, item.end, (item,), {}, (), 1, 'fallback', 1)
        emit_gesture(fallback_moment, fallback_shape,
                     [(string, fret, item.pitch, 'open' if fret == 0 else None, 'melody')],
                     'SINGLE_MELODY_PLUCK', item, reason='protected_melody_fallback')

    events = [event for event in events if event['end'] > event['start'] + .045]
    events.sort(key=lambda event: (event['start'], event['string'], event['pitch']))
    validation = validate_guitar_performance_events(events)
    if not validation['valid']:
        raise ValueError('Invalid unified Guitar performance: ' + '; '.join(validation['errors'][:5]))
    midi = pretty_midi.PrettyMIDI(initial_tempo=tempo)
    track = pretty_midi.Instrument(program=24, name='Solo Guitar unified performance')
    track.notes.extend(pretty_midi.Note(velocity=event['velocity'], pitch=event['pitch'],
                                        start=event['start'], end=event['end'])
                       for event in events)
    midi.instruments.append(track)
    midi.write(output_path)
    fingering_path = output_path + '.fingering.json'
    plan_path = output_path + '.performance_plan.json'
    with open(fingering_path, 'w', encoding='utf-8') as handle:
        json.dump({'schema': 'augment.guitar-performance.v12',
                   'tuning': list(STANDARD_TUNING), 'events': events}, handle, indent=2)
    with open(plan_path, 'w', encoding='utf-8') as handle:
        json.dump({'model': 'unified_guitar_moments_v12', 'moments': [
            {'start': round(moment.start, 3), 'end': round(moment.end, 3),
             'melody': [note.pitch for note in moment.melody_notes],
             'chord': {'root_pc': moment.chord_section.get('root_pc'),
                       'quality': moment.chord_section.get('quality')},
             'bass_information': [note.pitch for note in moment.bass_information],
             'density': moment.density, 'phrase_position': moment.phrase_position}
            for moment in moments], 'shapes': plan, 'decisions': decisions,
            'events': events}, handle, indent=2)
    roles = Counter(event['role'] for event in events)
    gestures = {}
    for event in events:
        gestures.setdefault(event['gesture_id'], []).append(event)
    movements = [abs(right['hand_position'] - left['hand_position'])
                 for left, right in zip(plan, plan[1:])]
    attacks = {}
    for event in events:
        attacks.setdefault(round(event['start'], 3), []).append(event)
    # Inner notes that are emitted as part of a melody-top gesture may carry
    # through the following small gap via let-ring. Count those as safe gap
    # texture too; the metric describes audible support, not only re-plucks.
    safe_gap_events = (sum(1 for decision in decisions
                            if decision['gesture'] == 'FINGERSTYLE_PATTERN') +
                       roles['inner'])
    simultaneous = [group for group in gestures.values() if len(group) > 1]
    melody_gestures = sorted((decision for decision in decisions
                              if 'melody' in decision.get('emitted_roles', ())),
                             key=lambda decision: decision['time'])
    gesture_counts = Counter(item['gesture'] for item in melody_gestures)
    fallback_runs, current_run = [], 0
    for decision in melody_gestures:
        if decision['gesture'] == 'SINGLE_MELODY_PLUCK':
            current_run += 1
        elif current_run:
            fallback_runs.append(current_run)
            current_run = 0
    if current_run:
        fallback_runs.append(current_run)
    harmonic_support = sum(
        decision['gesture'] != 'SINGLE_MELODY_PLUCK'
        for decision in melody_gestures)
    fallback_causes = Counter(
        decision['reason'] for decision in melody_gestures
        if decision['gesture'] == 'SINGLE_MELODY_PLUCK')
    melody_total = max(1, len(melody_gestures))
    return {
        'notes': len(events), 'melody_notes': roles['melody'],
        'protected_melody_input_notes': len(melody),
        'verified_vocal_melody_notes': min(verified_melody_notes, roles['melody']),
        'fallback_melody_notes': min(fallback_melody_notes,
                                     max(0, roles['melody'] - verified_melody_notes)),
        'bass_support_notes': roles['bass'], 'accompaniment_notes': roles['inner'],
        'safe_gap_texture_events': safe_gap_events,
        'max_simultaneous_notes': max((len(group) for group in gestures.values()), default=0),
        'simultaneous_note_events': len(simultaneous),
        'largest_simultaneous_pitch_span': max((max(event['pitch'] for event in group) -
                                                 min(event['pitch'] for event in group)
                                                 for group in simultaneous), default=0),
        'duplicate_pitch_onsets': sum(len(group) - len({event['pitch'] for event in group})
                                       for group in attacks.values()),
        'total_gestures': len(gestures),
        'melody_top_full_chords': sum(1 for value in decisions if value['gesture'] == 'MELODY_TOP_CHORD'),
        'melody_top_partial_chords': sum(1 for value in decisions if value['gesture'] == 'MELODY_TOP_PARTIAL'),
        'full_strums': sum(1 for value in decisions if value['gesture'] == 'FULL_CHORD_STRUM'),
        'partial_strums': 0,
        'single_melody_plucks': sum(1 for value in decisions if value['gesture'] == 'SINGLE_MELODY_PLUCK'),
        'arpeggios': sum(1 for value in decisions if value['gesture'] == 'FINGERSTYLE_PATTERN'),
        'pinches': sum(1 for value in decisions if value['gesture'] == 'PINCH'),
        'intentional_bass_only_events': 0,
        'let_ring_gestures': sum(1 for group in gestures.values()
                                 if any(event['let_ring'] for event in group)),
        'average_notes_per_gesture': round(len(events) / max(1, len(gestures)), 2),
        'average_held_shape_duration': round(sum(row['end'] - row['start'] for row in plan) / max(1, len(plan)), 3),
        'shape_transition_average': round(sum(movements) / max(1, len(movements)), 2),
        'same_shape_retained_while_melody_moved': sum(
            1 for row in plan if row['carried_previous_shape'] and row['melody_variations']),
        'melody_texture_diagnostics': {
            'full_melody_top_chord_percent': round(
                100 * gesture_counts['MELODY_TOP_CHORD'] / melody_total, 1),
            'partial_chord_melody_percent': round(
                100 * gesture_counts['PARTIAL_CHORD_MELODY'] / melody_total, 1),
            'dyad_melody_percent': round(
                100 * (gesture_counts['DYAD_MELODY'] +
                       gesture_counts['MELODY_TOP_PARTIAL']) / melody_total, 1),
            'melody_over_ringing_percent': round(
                100 * gesture_counts['MELODY_OVER_RINGING_HARMONY'] /
                melody_total, 1),
            'alternate_shape_recovery_percent': round(
                100 * gesture_counts['ALTERNATE_SHAPE_RECOVERY'] /
                melody_total, 1),
            'one_safe_tone_percent': round(
                100 * gesture_counts['ONE_SAFE_HARMONY_TONE'] /
                melody_total, 1),
            'true_single_fallback_percent': round(
                100 * gesture_counts['SINGLE_MELODY_PLUCK'] /
                melody_total, 1),
            'longest_single_fallback_run': max(fallback_runs, default=0),
            'average_single_fallback_run': round(
                sum(fallback_runs) / max(1, len(fallback_runs)), 2),
            'melody_with_harmonic_support_percent': round(
                100 * harmonic_support / melody_total, 1),
            'rejected_voicing_options': dict(rejected_voicings),
            'phrase_lookahead_recovered_notes': phrase_lookahead_recoveries,
            'single_fallback_causes': dict(fallback_causes),
            'melody_gesture_count': len(melody_gestures),
        },
        'canonical_performance_validation': validation,
        'sections': {'shape_regions': len(plan)},
        'arranger_decisions': decisions[:50],
        '_fingering_path': fingering_path, '_performance_plan_path': plan_path,
    }


# ---------------------------------------------------------------------------
# V10: physical, continuous fingerstyle performance.  V8 and V9 remain above
# as preserved comparison implementations.  This layer plans a held left-hand
# shape before it creates a single pluck, and all output formats consume the
# resulting canonical event list directly.

def _v10_finger_number(value):
    """Keep the canonical event unambiguous: 1=index through 4=pinky."""
    if not value:
        return None
    text = str(value).lower()
    if text in {'melody only', 'melody variation'}:
        return None
    if text == 'open':
        return '0/open'
    if 'index' in text:
        return '1/barre' if 'barre' in text else '1'
    if 'middle' in text:
        return '2'
    if 'ring' in text:
        return '3/barre' if 'barre' in text else '3'
    if 'pinky' in text:
        return '4'
    return str(value)


def _v101_pattern(grid, density, has_long_melody, phrase_phase=0):
    """Choose one coherent, meter-aware right-hand gesture for a whole bar.

    Slots deliberately name their function, rather than treating every empty
    pulse as a request for a thumb note.  The low voice therefore establishes
    the bar and the fingers carry most of the continuing texture.
    """
    try:
        beats, unit = (int(value) for value in str(grid.time_signature).split('/', 1))
    except (TypeError, ValueError):
        beats, unit = 4, 4
    # A sparse line gives fingers room for a complete rolling texture. Dense
    # lines keep only the harmonic-arrival thumb pulse and let melody replace
    # upper slots.  Closely related patterns rotate by phrase, not per note.
    if unit == 8 and beats in (6, 12):
        return (('root_bass', 'inner_i', 'upper_m', 'inner_m', 'fifth_bass', 'upper_a')
                if density <= 1 or (density <= 2 and has_long_melody) else
                ('root_bass', 'inner_i', 'upper_m', 'inner_m'))
    if beats == 3:
        return (('root_bass', 'inner_i', 'upper_m', 'inner_m', 'fifth_bass', 'upper_a')
                if density <= 1 or (density <= 2 and has_long_melody) else
                ('root_bass', 'inner_i', 'upper_m', 'inner_m'))
    if density <= 1 or (density <= 2 and has_long_melody):
        # Alternate bass across related bars, instead of forcing both root
        # and fifth into every measure.  This is the normal thumb behaviour
        # for a moderate fingerstyle phrase.
        if phrase_phase % 2:
            return ('root_bass', 'inner_i', 'upper_m', 'inner_m',
                    'fifth_bass', 'inner_i', 'upper_a', 'inner_m')
        return ('root_bass', 'inner_i', 'upper_m', 'inner_m',
                'upper_a', 'inner_i', 'upper_m', 'inner_m')
    # Busy melodic bars retain a single clear low arrival, followed by a
    # related upper-string gesture instead of a second unnecessary bass hit.
    return ('root_bass', 'inner_i', 'upper_m', 'inner_m')


def _v101_bass_voice(shape, voiced, bass_strings, function):
    """Select root/fifth bass from the held shape, never randomly by string."""
    choices = [(string, fret, pitch) for string, (fret, pitch) in voiced.items()
               if string in bass_strings]
    if not choices:
        return None, 'none'
    target = shape.root_pc if function == 'root' else (shape.root_pc + 7) % 12
    matching = [voice for voice in choices if voice[2] % 12 == target]
    if matching:
        return max(matching, key=lambda voice: voice[0]), function
    root = [voice for voice in choices if voice[2] % 12 == shape.root_pc]
    if root:
        return max(root, key=lambda voice: voice[0]), 'root_fallback'
    return max(choices, key=lambda voice: voice[0]), 'inversion'


def _v103_stroke_voices(shape, voiced, direction, excluded_strings=()):
    """Return a compact real stroke from the currently held chord grip.

    The strings and pitches come directly from ``shape.voiced``.  This is a
    physical stroke of a single held grip, never a collection of unrelated
    chord tones chosen after MIDI generation.
    """
    excluded = set(excluded_strings)
    ordered = sorted((string for string in voiced if string not in excluded),
                     reverse=(direction == 'down'))
    if len(ordered) < 2:
        return []
    # A useful accompaniment stroke is compact: retain the bass when present
    # and the nearest three colour/upper strings, rather than hitting all six
    # strings for every chord label.
    if direction == 'down':
        bass = [string for string in ordered if string >= 4][:1]
        upper = [string for string in ordered if string < 4][-3:]
        selected = bass + upper
        return sorted(dict.fromkeys(selected), reverse=True)
    return ordered[:4]


def _v10_slots(grid, start, end, pattern_length):
    """Create meter-aligned picking slots, adding subdivisions only as needed."""
    beats = [float(beat) for beat in getattr(grid, 'beat_times', ())
             if start - .03 <= float(beat) < end - .02]
    if len(beats) < 2:
        # The fallback follows the known chord window instead of arbitrary
        # note gaps, so it remains deterministic and meter-relative.
        return [start + (end - start) * index / pattern_length
                for index in range(pattern_length)]
    slots = list(beats)
    # A fingerstyle pattern normally has more movement than one attack per
    # beat. Interleave only stable half-beat pulses, never random offsets.
    if pattern_length > len(slots):
        extended = beats + [end]
        slots = [time for left, right in zip(extended, extended[1:])
                 for time in (left, left + (right - left) * .5)
                 if time < end - .02]
    return sorted(set(round(time, 6) for time in slots))


def _v10_melody_location(shape, pitch):
    """Use a held grip first, then an explicitly small upper-string variant."""
    exact = _v9_melody_location(shape, pitch)
    if exact is not None:
        return (*exact, 'shape')
    choices = []
    for index in range(3, 6):  # strings 3, 2, 1 only for a lead variation
        fret = int(pitch) - STANDARD_TUNING[index]
        held = shape.layout[index]
        if 0 <= fret <= MAX_FRET and held is not None and abs(fret - held) <= 2:
            choices.append((abs(fret - held), 6 - index, fret))
    if choices:
        _, string, fret = min(choices)
        return string, fret, 'one_finger_variation'
    return None


def _v11_protected_melody_location(shape, pitch, start, events):
    """Choose a playable melodic string without choking an earlier melody.

    This happens during arrangement, while the hand shape is known.  It is
    not a later MIDI-to-TAB reassignment.  Exact/near shape positions remain
    preferred; another valid Guitar string is used only to preserve a real
    overlapping lead attack.
    """
    preferred = _v10_melody_location(shape, pitch)
    candidates = []
    if preferred is not None:
        string, fret, kind = preferred
        # Keep candidate scores structurally identical so the deduplication
        # below can choose the nearest physical option deterministically.
        candidates.append(((0, 0, 0, string), string, fret, kind))
    for index, open_pitch in enumerate(STANDARD_TUNING):
        string, fret = 6 - index, int(pitch) - open_pitch
        if not 0 <= fret <= MAX_FRET:
            continue
        held = shape.layout[index]
        near = held is not None and abs(fret - held) <= 2
        score = (0 if held == fret else 1 if near else 4,
                 0 if string <= 3 else 1,
                 abs(fret - shape.position), string)
        kind = 'shape' if held == fret else ('one_finger_variation' if near else 'protected_melody_string')
        candidates.append((score, string, fret, kind))
    deduped = {}
    for score, string, fret, kind in candidates:
        deduped[(string, fret)] = min((score, kind), deduped.get((string, fret), (score, kind)))
    active_strings = {event['string'] for event in events
                      if event['role'] == 'melody' and event['end'] > start + .001}
    options = [(score, string, fret, kind) for (string, fret), (score, kind) in deduped.items()
               if string not in active_strings]
    if not options:
        options = [(score, string, fret, kind) for (string, fret), (score, kind) in deduped.items()]
    if not options:
        return None
    _, string, fret, kind = min(options, key=lambda item: item[0])
    return string, fret, kind


def _v10_choose_shape(section, previous, section_melody):
    candidates = _v9_shape_candidates(section)
    if not candidates:
        return previous, True, 0.0, 0
    def score(shape):
        transition, anchors = _v9_transition_cost(previous, shape)
        accessible = sum(_v10_melody_location(shape, item.pitch) is not None
                         for item in section_melody)
        # Prefer grips that can put the detected lead above usable lower
        # chord tones.  This is more important than merely finding the
        # melody pitch somewhere on the fretboard.
        melody_top_access = sum(
            _v10_melody_location(shape, item.pitch) is not None and
            any(string >= 4 and pitch < item.pitch for string, _, pitch in shape.voiced)
            for item in section_melody)
        open_strings = sum(fret == 0 for fret in shape.layout)
        bass_access = 1 if shape.bass_string >= 4 else 0
        # A move is accepted only when melody/harmony access buys something.
        return (melody_top_access * 8 + accessible * 3 + anchors * 1.2 +
                open_strings * .25 + bass_access - transition * 1.5,
                melody_top_access, accessible, anchors)
    best = max(candidates, key=score)
    transition, anchors = _v9_transition_cost(previous, best)
    return best, False, transition, anchors


def _v10_harmony_is_usable(section, sections, index, previous_shape):
    """Use low-confidence labels conservatively without dropping the groove."""
    confidence = float(section.get('confidence', 0.0))
    if confidence >= .035:
        return True
    signature = (section.get('root_pc'), section.get('quality'))
    neighbours = [(sections[i].get('root_pc'), sections[i].get('quality'))
                  for i in (index - 1, index + 1) if 0 <= i < len(sections)]
    # Repeated weak evidence can establish a shape; a completely uncertain
    # change carries the prior shape rather than inventing a new chord.
    return confidence >= .012 and signature in neighbours


def _v10_background_is_supported(section, sections, index):
    """Return true only when harmony is strong enough to *sound*.

    A carried GuitarShape is useful as a physical position for a protected
    melody, but it is not proof that the audio contains that chord.  Earlier
    versions treated a carried shape as permission to keep strumming and
    arpeggiating through low-confidence sections.  That turned a weak chord
    guess into unrelated background notes and a crowded TAB staff.
    """
    confidence = float(section.get('confidence', 0.0))
    if confidence >= .045:
        return True
    signature = (section.get('root_pc'), section.get('quality'))
    neighbours = [sections[i] for i in (index - 1, index + 1)
                  if 0 <= i < len(sections)]
    # Repeated evidence may support a quiet accompaniment, but only when two
    # adjacent windows agree and neither is merely detector noise.
    return any(
        signature == (item.get('root_pc'), item.get('quality')) and
        confidence >= .025 and float(item.get('confidence', 0.0)) >= .025
        for item in neighbours
    )


def _v10_isolated_bass_location(pitch, previous_string=None):
    """Choose a low, playable string for an independently detected bass note."""
    choices = [
        (6 - index, int(pitch - open_pitch))
        for index, open_pitch in enumerate(STANDARD_TUNING)
        if 6 - index >= 4 and 0 <= pitch - open_pitch <= MAX_FRET
    ]
    if not choices:
        return None
    # Keep a bass line on the lower strings and avoid needless string jumps.
    return min(choices, key=lambda item: (
        0 if previous_string is not None and item[0] == previous_string else 1,
        item[1], -item[0],
    ))


def _v10_supported_source_bass(bass_notes, grid, start, end, melody_notes):
    """Return sparse, beat-aligned bass evidence for an uncertain chord region.

    This is deliberately not harmony reconstruction: it carries only notes
    that were detected in the isolated bass stem.  Limiting it to two clear
    beat arrivals prevents the old continuous-thumb problem while avoiding an
    empty Guitar part when chord confidence is too weak for accompaniment.
    """
    beats = [float(beat) for beat in getattr(grid, 'beat_times', ())
             if start - .06 <= float(beat) < end - .02]
    result = []
    for item in sorted(bass_notes, key=lambda note: (note.start, note.pitch)):
        if not start <= item.start < end or not 40 <= item.pitch <= 55:
            continue
        if beats and min(abs(item.start - beat) for beat in beats) > .11:
            continue
        if any(abs(item.start - melody.start) <= .075 for melody in melody_notes):
            continue
        if result and item.start - result[-1].start < .42:
            continue
        result.append(item)
        if len(result) == 2:
            break
    return result


def _arrange_solo_guitar_v10_legacy(melody_notes, bass_notes, grid, output_path,
                                    verified_melody_notes=0, fallback_melody_notes=0):
    """Create the V10 canonical physical fingerstyle Guitar performance."""
    melody = _monophonic_melody(melody_notes)
    sections = list(getattr(grid, 'chord_sections', ()) or ())
    tempo = max(40.0, float(getattr(grid, 'bpm', 120.0)))
    events, shape_plan, previous_shape = [], [], None
    state = {'previous_bass_string': None, 'previous_melody_string': None,
             'next_gesture_id': 1}

    def add(pitch, start, end, velocity, role, shape, string, fret, lh, rh,
            articulation='finger_pluck', mute_reason=None, position_reason=None,
            stroke_direction=None, gesture_id=None, action=None, gesture_level=None):
        if not GUITAR_LOW <= pitch <= GUITAR_HIGH or end <= start + .04:
            return
        if any(event['pitch'] == pitch and abs(event['start'] - start) <= .012
               for event in events):
            return
        # Resolve conflicts by time, not insertion order: accompaniment is
        # planned before melody and may already contain future attacks.
        conflicts = [prior for prior in events if prior['string'] == string
                     and prior['start'] < end and prior['end'] > start]
        if role != 'melody':
            if any(prior['role'] == 'melody' and prior['start'] <= start
                   for prior in conflicts):
                return
            end = min([end] + [prior['start'] for prior in conflicts
                              if prior['start'] >= start])
            if end <= start + .04:
                return
        else:
            end = min([end] + [prior['start'] for prior in conflicts
                              if prior['role'] == 'melody' and prior['start'] > start])
            if end <= start + .04:
                return
            events[:] = [prior for prior in events if not (
                prior in conflicts and prior['role'] != 'melody'
                and start <= prior['start'] < end)]
        for prior in reversed(events):
            if (prior['string'] == string and prior['start'] < start
                    and prior['end'] > start + .001):
                # The accepted lead is a protected performance voice.  A
                # later accompaniment slot may not silently choke it merely
                # because the pattern happened to choose the same string.
                # In that situation the physical guitarist omits/revoices
                # the support pluck; a later melody attack, however, can
                # naturally release the earlier string.
                if prior['role'] == 'melody' and role != 'melody':
                    return
                prior['end'] = start
                prior['ring_until'] = start
                prior['mute_reason'] = 'same_string_reuse'
                prior['let_ring'] = False
        if gesture_id is None:
            gesture_id = state['next_gesture_id']
            state['next_gesture_id'] += 1
        events.append({
            'time': round(float(start), 6), 'start': round(float(start), 6),
            'start_seconds': round(float(start), 6), 'end': round(float(end), 6),
            'duration': round(float(end - start), 6), 'pitch': int(pitch),
            'string': int(string), 'fret': int(fret), 'shape_id': shape.id,
            'left_hand_finger': _v10_finger_number(lh),
            'right_hand_finger': rh, 'role': role, 'velocity': int(velocity),
            'articulation': articulation, 'ring_until': round(float(end), 6),
            'mute_reason': mute_reason,
            'stroke_direction': stroke_direction,
            'gesture_id': int(gesture_id),
            'gesture_level': gesture_level,
            'chord': f'{shape.root_pc}:{shape.quality}',
            'action': (action or ('strum' if role.startswith('strum_') else
                       ('pinch' if role.startswith('pinch_') else 'pluck'))),
            'let_ring': mute_reason is None,
            'position_reason': position_reason or f'held_{shape.template_name}_position_{shape.position:g}',
            'start_quarter': round(float(grid.seconds_to_quarter(start)) * 8) / 8,
        })

    for index, section in enumerate(sections):
        start, end = float(section['start_seconds']), float(section['end_seconds'])
        if end - start < .28:
            continue
        section_melody = [item for item in melody if item.start < end and item.end > start]
        usable = _v10_harmony_is_usable(section, sections, index, previous_shape)
        background_supported = _v10_background_is_supported(section, sections, index)
        prior_shape_id = previous_shape.id if previous_shape is not None else None
        if usable or previous_shape is None:
            shape, carried, transition, anchors = _v10_choose_shape(section, previous_shape, section_melody)
        else:
            shape, carried, transition, anchors = previous_shape, True, 0.0, 0
        if shape is None:
            continue
        previous_shape = shape
        density = len(section_melody)
        long_melody = any(item.end - item.start >= .40 for item in section_melody)
        pattern = _v101_pattern(grid, density, long_melody, index)
        slots = _v10_slots(grid, start, end, len(pattern))
        voiced = {string: (fret, pitch) for string, fret, pitch in shape.voiced}
        bass_strings = [string for string in sorted(voiced, reverse=True) if string >= 4]
        # These pools encode a normal fingerstyle allocation from the active
        # chord shape: I has string 3 (then 4), M has string 2 (then 3), and
        # A has string 1 (then 2).  They are not a post-hoc fret search.
        i_strings = [string for string in (3, 4) if string in voiced]
        m_strings = [string for string in (2, 3) if string in voiced]
        a_strings = [string for string in (1, 2) if string in voiced]
        inner_strings = sorted(set(i_strings + m_strings), reverse=True)
        upper_strings = sorted(set(m_strings + a_strings))
        row = {
            'start': round(start, 3), 'end': round(end, 3),
            'chord': f'{shape.root_pc}:{shape.quality}', 'confidence': round(float(section.get('confidence', 0)), 3),
            'shape_id': shape.id, 'template_name': shape.template_name,
            'layout_6_to_1': ['x' if fret is None else fret for fret in shape.layout],
            'left_hand_1_to_4': [_v10_finger_number(value) for value in shape.left_hand],
            'barre_fret': shape.barre_fret, 'hand_position': shape.position,
            'bass_string': shape.bass_string,
            'allowed_ringing_strings': [string for string in voiced],
            'pattern_roles': list(pattern), 'picking_pattern': ' → '.join(pattern),
            'carried_previous_shape': carried,
            'background_supported': background_supported,
            'transition_cost': round(transition, 2), 'anchored_fingers': anchors,
            'melody_variations': [],
            'strokes': [],
        }
        # If chord recognition is not strong enough to create an arrangement
        # texture, use sparse low notes detected from ``bass.wav`` rather
        # than filling the silence with a carried guessed chord.
        if not background_supported:
            for bass_item in _v10_supported_source_bass(
                    bass_notes, grid, start, end, section_melody):
                location = _v10_isolated_bass_location(
                    bass_item.pitch, state['previous_bass_string'])
                if location is None:
                    continue
                bass_string, bass_fret = location
                layout = [None] * 6
                layout[6 - bass_string] = bass_fret
                bass_shape = GuitarShape(
                    f'isolated-bass:{bass_item.pitch}:{bass_string}:{bass_fret}',
                    bass_item.pitch % 12, 'isolated', tuple(layout), float(bass_fret),
                    None, (None,) * 6, bass_string, 'isolated_bass_evidence')
                next_bass = min(
                    (candidate.start for candidate in bass_notes
                     if candidate.start > bass_item.start + .04),
                    default=end)
                bass_end = min(end - .01, next_bass - .01,
                               bass_item.start + max(.22, min(.70, bass_item.end - bass_item.start)))
                if bass_end <= bass_item.start + .04:
                    continue
                add(bass_item.pitch, bass_item.start, bass_end, 64,
                    'source_bass', bass_shape, bass_string, bass_fret, None, 'P',
                    'isolated_bass_evidence',
                    position_reason='isolated_bass_stem_beat_aligned')
                state['previous_bass_string'] = bass_string
                row.setdefault('source_bass_events', []).append({
                    'time': round(bass_item.start, 3), 'pitch': bass_item.pitch,
                    'string': bass_string, 'fret': bass_fret,
                })
        # Establish a new harmony with a real multi-string stroke.  The
        # melody takes the top string when it attacks at this same arrival;
        # the remaining strings form the chord underneath it.
        shape_changed = prior_shape_id is None or shape.id != prior_shape_id
        arrival_melody = next((item for item in section_melody
                               if start <= item.start <= start + .40), None)
        # When a melody arrives with a chord change, its later melody-top
        # gesture owns the whole stroke. Do not emit a separate foundation
        # strum first and then try to layer the singer onto it.
        if background_supported and (
                (shape_changed and arrival_melody is None) or
                (not section_melody and index % 4 == 0)):
            melody_string = None
            if arrival_melody is not None:
                location = _v10_melody_location(shape, arrival_melody.pitch)
                if location is not None:
                    melody_string = location[0]
            direction = 'down' if index % 2 == 0 else 'up'
            stroke_strings = _v103_stroke_voices(
                shape, voiced, direction,
                (melody_string,) if melody_string is not None else ())
            for stroke_index, string in enumerate(stroke_strings):
                fret, pitch = voiced[string]
                rh = 'P' if string >= 4 else ('I' if string == 3 else ('M' if string == 2 else 'A'))
                stroke_start = start + stroke_index * .018
                add(pitch, stroke_start, min(end - .015, stroke_start + .52),
                    66 if rh == 'P' else 61,
                    f'strum_{direction}', shape, string, fret,
                    shape.left_hand[6 - string], rh,
                    f'{direction}_stroke',
                    position_reason=f'held_{shape.template_name}_position_{shape.position:g}_chord_stroke',
                    stroke_direction=direction)
            if stroke_strings:
                row['strokes'].append({
                    'time': round(start, 3), 'direction': direction,
                    'strings': stroke_strings,
                    'melody_top_string': melody_string,
                })
        # This bar's selected picking gesture is performed from the held
        # shape.  A thumb only appears at its planned root/fifth arrival;
        # the intervening texture belongs to I/M/A.
        bass_emitted = 0
        for pulse, onset in (enumerate(slots) if background_supported else ()):
            role = pattern[pulse % len(pattern)]
            next_onset = slots[pulse + 1] if pulse + 1 < len(slots) else end
            nearby_melody = next((item for item in section_melody
                                  if abs(item.start - onset) <= .075), None)
            # A protected lead arrival is constructed below as one physical
            # chord gesture. Pattern slots may continue in actual gaps, but
            # cannot make an independent bass/inner attack at that same
            # musical moment.
            if nearby_melody is not None:
                continue
            bass_kind = None
            if role in ('root_bass', 'fifth_bass') and bass_strings:
                # V11.2: the thumb grounds a new harmony/phrase; it is not
                # a separate low-note layer underneath every melody attack.
                if bass_emitted or pulse != 0:
                    continue
                voice, bass_kind = _v101_bass_voice(
                    shape, voiced, bass_strings,
                    'root' if role == 'root_bass' else 'fifth')
                if voice is None:
                    continue
                string, fret, pitch = voice
                state['previous_bass_string'] = string
                rh, velocity, event_role = 'P', 65 if bass_kind.startswith('root') else 61, 'bass'
                bass_emitted += 1
            elif role == 'inner_i' and i_strings and not (nearby_melody and nearby_melody.pitch <= 59):
                string = i_strings[pulse % len(i_strings)]
                fret, pitch = voiced[string]
                rh, velocity, event_role = 'I', 56, 'inner'
            elif role == 'inner_m' and m_strings and not (nearby_melody and nearby_melody.pitch <= 59):
                string = m_strings[pulse % len(m_strings)]
                fret, pitch = voiced[string]
                rh, velocity, event_role = 'M', 58, 'inner'
            elif role == 'upper_m' and m_strings and nearby_melody is None:
                string = m_strings[pulse % len(m_strings)]
                fret, pitch = voiced[string]
                rh, velocity, event_role = 'M', 60, 'upper'
            elif role == 'upper_a' and a_strings and nearby_melody is None:
                string = a_strings[pulse % len(a_strings)]
                fret, pitch = voiced[string]
                rh, velocity, event_role = 'A', 59, 'upper'
            else:
                continue
            interval = max(.12, next_onset - onset)
            # Harmony rings across later plucks on different strings; the
            # canonical same-string conflict rule below still mutes it when
            # a real physical reuse requires that release.
            multiplier = 1.8 if event_role != 'bass' else 1.2
            duration = min(end - .015, onset + max(.18, interval * multiplier))
            add(pitch, onset, duration, velocity, event_role, shape, string, fret,
                shape.left_hand[6 - string], rh,
                'thumb_bass' if event_role == 'bass' else 'arpeggio',
                position_reason=(f'held_{shape.template_name}_position_{shape.position:g}_{bass_kind}'
                                 if bass_kind else None))

        for melody_index, item in enumerate(section_melody):
            if not start <= item.start < end:
                continue
            # Melody locations are selected while the held shape is being
            # planned.  The V11 helper first keeps an existing chord grip,
            # then tries a one-finger local variation, and finally uses a
            # valid nearby Guitar position.  It is deliberately *not* a
            # later MIDI-to-fret reassignment.
            location = _v11_protected_melody_location(shape, item.pitch, item.start, events)
            if location is None:
                # A valid Guitar-range melody is protected; only genuinely
                # unplayable pitches (outside the six-string fretboard) can
                # be absent from the canonical performance.
                continue
            else:
                string, fret, variation = location
                lh = (shape.left_hand[6 - string] if variation == 'shape'
                      else ('0/open' if fret == 0 else None))
            state['previous_melody_string'] = string
            melody_end = min(item.end, end - .01)
            # A scheduled shape tone may happen to have the exact same MIDI
            # pitch and onset as the melody.  The melody owns that attack;
            # remove the support copy before inserting its canonical upper
            # voice instead of silently dropping the detected melody.
            events[:] = [event for event in events if not (
                event['role'] != 'melody' and event['pitch'] == item.pitch and
                abs(event['start'] - item.start) <= .012)]
            # V11.1: a melody arrival is first treated as one physical Guitar
            # gesture.  Bass, inner chord tones and the protected top melody
            # share one gesture_id; the few millisecond offsets are merely
            # the path of one stroke across the strings, not independent
            # musical parts.
            beat = int(round(grid.seconds_to_quarter(item.start)))
            # A chord-analysis window is not automatically a musical phrase.
            # Find neighbours in the complete lead so a continuing melody
            # does not receive a new full chord at every bar boundary.
            previous_item = max(
                (candidate for candidate in melody
                 if candidate is not item and candidate.end <= item.start + .01),
                key=lambda candidate: candidate.end, default=None)
            next_item = min(
                (candidate for candidate in melody
                 if candidate is not item and candidate.start >= item.end - .01),
                key=lambda candidate: candidate.start, default=None)
            phrase_start = previous_item is None or item.start - previous_item.end >= .35
            phrase_end = next_item is None or next_item.start - item.end >= .35
            contour_peak = ((previous_item is not None and next_item is not None and
                             item.pitch >= previous_item.pitch + 2 and item.pitch >= next_item.pitch + 2) or
                            (previous_item is not None and next_item is None and item.pitch > previous_item.pitch))
            # A = full melody-top chord at a harmonic/phrase arrival.
            # B = small upper partial stroke while the prior harmony rings.
            # C = exposed melody (the default for a moving phrase).
            # A moving melody needs room. A full chord is reserved for a
            # genuine phrase/harmony arrival or a held downbeat, rather than
            # being attached to the first melody note of every short window.
            level_a = ((phrase_start and item.end - item.start >= .22) or
                       (shape_changed and abs(item.start - start) <= .10 and
                        item.end - item.start >= .35) or
                       (beat % 4 == 0 and item.end - item.start >= .55))
            level_b = (not level_a and density <= 2 and
                       (item.end - item.start >= .58 or contour_peak or phrase_end))
            # Never turn an uncertain harmony label into a chord under the
            # protected melody.  The melody remains intact; only support is
            # withheld until the audio provides sufficient harmonic evidence.
            gesture_eligible = background_supported and (level_a or level_b)
            voices = [(string, fret, item.pitch, lh, 'melody',
                       'A' if string == 1 else ('M' if string == 2 else 'I'), 92)]
            if gesture_eligible:
                # Only a Level-A arrival takes a new bass note.  Level-B
                # strokes deliberately let the previous low chord ring.
                bass_voice = next((voice for voice in sorted(shape.voiced, key=lambda voice: voice[2])
                                   if level_a and voice[0] != string and voice[0] >= 4 and
                                   item.pitch - voice[2] <= MAX_SIMULTANEOUS_SPAN), None)
                if bass_voice is not None:
                    bass_string, bass_fret, bass_pitch = bass_voice
                    voices.append((bass_string, bass_fret, bass_pitch,
                                   shape.left_hand[6 - bass_string], 'gesture_bass', 'P', 69))
                inner_voices = [voice for voice in shape.voiced
                                if voice[0] != string and voice[0] != (bass_voice[0] if bass_voice else None)
                                and voice[2] < item.pitch and item.pitch - voice[2] <= MAX_SIMULTANEOUS_SPAN]
                for inner_string, inner_fret, inner_pitch in sorted(inner_voices, key=lambda voice: voice[2], reverse=True)[:(2 if level_a else 1)]:
                    voices.append((inner_string, inner_fret, inner_pitch,
                                   shape.left_hand[6 - inner_string], 'gesture_inner',
                                   'I' if inner_string >= 3 else ('M' if inner_string == 2 else 'A'), 60))
            # Do not leave a separately scheduled bass/arpeggio attack beside
            # a unified chord+melody gesture at the same musical instant.
            if len(voices) >= 2:
                events[:] = [event for event in events if not (
                    event['role'] != 'melody' and
                    abs(event['start'] - item.start) <= .10)]
                gesture_id = state['next_gesture_id']
                state['next_gesture_id'] += 1
                direction = 'up' if string <= 3 else 'down'
                ordered = sorted(voices, key=lambda voice: voice[0], reverse=(direction == 'down'))
                melody_index = next(index for index, voice in enumerate(ordered) if voice[4] == 'melody')
                stroke_base = item.start - melody_index * .018
                if stroke_base < start:
                    direction, ordered, melody_index = 'up', sorted(voices, key=lambda voice: voice[0]), 0
                    stroke_base = item.start
                for stroke_index, (voice_string, voice_fret, voice_pitch, voice_lh, voice_role, voice_rh, voice_velocity) in enumerate(ordered):
                    stroke_start = stroke_base + stroke_index * .018
                    stroke_end = min(end - .01, max(melody_end, stroke_start + .42))
                    add(voice_pitch, stroke_start, stroke_end,
                        max(96, min(112, item.velocity + 8)) if voice_role == 'melody' else voice_velocity,
                        'melody' if voice_role == 'melody' else voice_role,
                        shape, voice_string, voice_fret, voice_lh, voice_rh,
                        f'{direction}_melody_top_stroke',
                        position_reason=(f'gesture_melody_{variation}_from_{shape.template_name}_position_{shape.position:g}'),
                        stroke_direction=direction, gesture_id=gesture_id, action='strum',
                        gesture_level='A_full_melody_top_chord' if level_a else 'B_partial_melody_top_stroke')
                row['strokes'].append({'time': round(stroke_base, 3), 'direction': direction,
                                       'strings': [voice[0] for voice in ordered],
                                       'melody_top_string': string, 'gesture_id': gesture_id})
            else:
                add(item.pitch, item.start, melody_end, max(98, min(112, item.velocity + 8)),
                    'melody', shape, string, fret, lh,
                    'A' if string == 1 else ('M' if string == 2 else 'I'),
                    'melody_note', position_reason=(
                        f'melody_{variation}_from_{shape.template_name}_position_{shape.position:g}'),
                    gesture_level='C_exposed_melody')
            if variation != 'shape':
                row['melody_variations'].append({
                    'time': round(item.start, 3), 'pitch': item.pitch,
                    'string': string, 'fret': fret, 'reason': variation,
                })
            # Strong/held melody can create a real thumb+melody pinch. Its
            # notes come from this exact held shape and retain separate strings.
            # Pinches are accents at an arrival or a genuinely held melody,
            # not an automatic low-note response to every melody pitch.
            if background_supported and len(voices) < 2 and ((item.start - start <= .25 and density <= 3) or
                    item.end - item.start >= .65) and bass_strings:
                bass_string = next((candidate for candidate in bass_strings if candidate != string), None)
                if bass_string is not None:
                    bass_fret, bass_pitch = voiced[bass_string]
                    if item.pitch - bass_pitch <= MAX_SIMULTANEOUS_SPAN:
                        add(bass_pitch, item.start, min(item.end, item.start + .42), 72,
                            'pinch_bass', shape, bass_string, bass_fret,
                            shape.left_hand[6 - bass_string], 'P', 'bass_melody_pinch')
            # Sparse/held melody additionally gets a light chord colour on a
            # distinct middle string; busy phrases are not cluttered.
            if (background_supported and len(voices) < 2 and density <= 3 and
                    (item.end - item.start >= .28 or item.pitch <= 59)):
                choices = [(s, f, p) for s, f, p in shape.voiced
                           if s != string and p < item.pitch and item.pitch - p <= MAX_SIMULTANEOUS_SPAN and
                           (s in inner_strings or item.pitch <= 59)]
                non_root_choices = [voice for voice in choices if voice[2] % 12 != shape.root_pc]
                choices = non_root_choices or choices
                if choices:
                    voice_string, voice_fret, voice_pitch = max(choices, key=lambda voice: voice[2])
                    add(voice_pitch, item.start, min(item.end, item.start + .36), 60,
                        'pinch_inner', shape, voice_string, voice_fret,
                        shape.left_hand[6 - voice_string], 'I', 'chord_pinch')
        shape_plan.append(row)

    # A melody with no usable harmonic region remains performable, but this
    # fallback is deliberately an explicit melody-only state, not a hidden
    # global fretboard reassignment after the performance was built.
    melody_shape = GuitarShape('melody-only', 0, 'none', (None,) * 6, 0.0,
                               None, (None,) * 6, 6, 'melody-only')
    for item in melody:
        if any(event['role'] == 'melody' and event['pitch'] == item.pitch and
               abs(event['start'] - item.start) <= .012 for event in events):
            continue
        location = _v11_protected_melody_location(melody_shape, item.pitch, item.start, events)
        if location is None:
            continue
        string, fret, _ = location
        events[:] = [event for event in events if not (
            event['role'] != 'melody' and event['pitch'] == item.pitch and
            abs(event['start'] - item.start) <= .012)]
        add(item.pitch, item.start, item.end, max(84, item.velocity), 'melody', melody_shape,
            string, fret, ('0/open' if fret == 0 else None), 'A' if string == 1 else ('M' if string == 2 else 'I'),
            'melody_note')

    events = [event for event in events if event['end'] > event['start'] + .04]
    for event in events:
        event['duration'] = round(event['end'] - event['start'], 6)
        event['ring_until'] = round(event['end'], 6)
    events.sort(key=lambda event: (event['start'], event['string'], event['pitch']))
    midi = pretty_midi.PrettyMIDI(initial_tempo=tempo)
    track = pretty_midi.Instrument(program=24, name='Solo Guitar V10.3 chord stroke fingerstyle')
    track.notes.extend(pretty_midi.Note(velocity=int(event['velocity']), pitch=event['pitch'],
                                        start=event['start'], end=event['end']) for event in events)
    midi.instruments.append(track)
    midi.write(output_path)

    fingering_path, plan_path = output_path + '.fingering.json', output_path + '.performance_plan.json'
    with open(fingering_path, 'w', encoding='utf-8') as handle:
        json.dump({'tuning': list(STANDARD_TUNING), 'events': events}, handle, indent=2)
    with open(plan_path, 'w', encoding='utf-8') as handle:
        json.dump({'model': 'v10_3_chord_stroke_fingerstyle', 'shapes': shape_plan,
                   'events': events}, handle, indent=2)

    roles = Counter(event['role'] for event in events)
    fingers = Counter(event['right_hand_finger'] for event in events)
    bass_functions = Counter(
        ('fifth' if str(event.get('position_reason', '')).endswith('_fifth') else
         'root' if ('_root' in str(event.get('position_reason', ''))) else
         'pinch' if event['role'] == 'pinch_bass' else 'inversion')
        for event in events if event['role'] in ('bass', 'pinch_bass')
    )
    attacks = {}
    for event in events:
        attacks.setdefault(round(event['start'], 3), []).append(event)
    # One stroke intentionally has millisecond-separated string attacks.
    # Group its canonical events by gesture as the musical chord view.
    gesture_groups = {}
    for event in events:
        gesture_groups.setdefault(event.get('gesture_id'), []).append(event)
    total_melody_time = sum(max(.0, item.end - item.start) for item in melody)
    accompaniment_under_melody = sum(
        min(event['end'], item.end) - max(event['start'], item.start)
        for event in events if event['role'] != 'melody'
        for item in melody if event['start'] < item.end and event['end'] > item.start
    )
    changes, last_pitch = 0, {}
    for event in events:
        prior = last_pitch.get(event['pitch'])
        if prior and event['start'] - prior['start'] < 6 and (prior['string'], prior['fret']) != (event['string'], event['fret']):
            changes += 1
        last_pitch[event['pitch']] = event
    movements = [abs(shape_plan[i]['hand_position'] - shape_plan[i - 1]['hand_position'])
                 for i in range(1, len(shape_plan))]
    high = [event for event in events if event['fret'] >= 12]
    collisions = sum(len(group) - len({event['string'] for event in group}) for group in attacks.values())
    ring_conflicts = sum(1 for event in events if event.get('mute_reason') == 'same_string_reuse')
    physical_validation = validate_guitar_performance_events(events)
    # Use merged spans for diagnostic ratios, so a pinch does not inflate the
    # apparent amount of accompaniment merely by sounding two strings at once.
    def merged_length(intervals):
        merged = []
        for left, right in sorted((left, right) for left, right in intervals if right > left):
            if not merged or left > merged[-1][1]:
                merged.append([left, right])
            else:
                merged[-1][1] = max(merged[-1][1], right)
        return sum(right - left for left, right in merged)
    song_end = max((event['end'] for event in events), default=0.0)
    melody_spans = [(item.start, item.end) for item in melody]
    melody_merged = []
    for left, right in sorted(melody_spans):
        if not melody_merged or left > melody_merged[-1][1]:
            melody_merged.append([left, right])
        else:
            melody_merged[-1][1] = max(melody_merged[-1][1], right)
    gaps, cursor = [], 0.0
    for left, right in melody_merged:
        if left > cursor:
            gaps.append((cursor, left))
        cursor = max(cursor, right)
    if cursor < song_end:
        gaps.append((cursor, song_end))
    accompaniment = [event for event in events if event['role'] != 'melody']
    gap_support = []
    for event in accompaniment:
        for left, right in gaps:
            overlap_left, overlap_right = max(left, event['start']), min(right, event['end'])
            if overlap_right > overlap_left:
                gap_support.append((overlap_left, overlap_right))
    attack_times = sorted(attacks)
    average_attack_silence = (sum(right - left for left, right in zip(attack_times, attack_times[1:])) /
                              max(1, len(attack_times) - 1))
    ringing_events = sum(1 for event in events if any(
        other is not event and other['string'] != event['string'] and
        event['start'] < other['end'] and other['start'] < event['end']
        for other in events
    ))
    return {
        'notes': len(events), 'melody_notes': roles['melody'],
        # ``melody`` is the already-selected monophonic lead used by the
        # arranger.  Keep the upstream candidate count separately: using it
        # as the protected-melody denominator made a correct 105/105 lead
        # look like a false 105/320 loss.
        'protected_melody_input_notes': len(melody),
        'upstream_melody_candidate_notes': len(melody_notes),
        'verified_vocal_melody_notes': min(verified_melody_notes, roles['melody']),
        'fallback_melody_notes': min(fallback_melody_notes, max(0, roles['melody'] - verified_melody_notes)),
        'bass_support_notes': (roles['bass'] + roles['source_bass'] +
                               roles['pinch_bass'] + roles['gesture_bass']),
        'accompaniment_notes': roles['inner'] + roles['upper'] + roles['pinch_inner'] + roles['gesture_inner'],
        'arpeggio_notes': roles['inner'] + roles['upper'] + roles['gesture_inner'],
        'inner_harmony_events': roles['inner'] + roles['pinch_inner'] + roles['gesture_inner'],
        'fingerstyle_pattern_events': roles['bass'] + roles['inner'] + roles['upper'] + roles['gesture_bass'] + roles['gesture_inner'],
        'melody_pinch_events': roles['pinch_bass'] + roles['pinch_inner'],
        'safe_gap_texture_events': roles['inner'] + roles['upper'] + roles['pinch_inner'],
        'simultaneous_note_events': sum(1 for group in gesture_groups.values() if len(group) > 1),
        'max_simultaneous_notes': max((len(group) for group in gesture_groups.values()), default=0),
        'pitch_range': ([min(event['pitch'] for event in events), max(event['pitch'] for event in events)] if events else []),
        'voicing_count': sum(1 for group in attacks.values() if len(group) > 1),
        'average_voicing_size': round(sum(len(group) for group in attacks.values() if len(group) > 1) / max(1, sum(1 for group in attacks.values() if len(group) > 1)), 2),
        'duplicate_pitch_onsets': sum(len(group) - len({event['pitch'] for event in group}) for group in attacks.values()),
        'largest_simultaneous_pitch_span': max((max(event['pitch'] for event in group) - min(event['pitch'] for event in group) for group in attacks.values() if len(group) > 1), default=0),
        'string_fret_coverage': len(events), 'string_collisions': collisions,
        'repeated_pitch_string_changes': changes,
        'shape_transition_average': round(sum(movements) / len(movements), 2) if movements else 0,
        'shape_transition_max': max(movements, default=0),
        'anchored_finger_retention': sum(shape['anchored_fingers'] for shape in shape_plan),
        'melody_shape_changes': sum(len(shape['melody_variations']) for shape in shape_plan),
        'accompaniment_under_melody_ratio': round(min(1.0, accompaniment_under_melody / max(.001, total_melody_time)), 3),
        'open_string_events': sum(event['fret'] == 0 for event in events),
        'high_fret_events': len(high), 'high_fret_events_detail': high,
        'ringing_note_conflicts': ring_conflicts,
        'canonical_performance_validation': physical_validation,
        'downstroke_events': roles['strum_down'],
        'upstroke_events': roles['strum_up'],
        'stroke_attacks': sum(1 for group in attacks.values()
                              if any(event['role'].startswith('strum_') for event in group)),
        'accompaniment_during_melody_gaps_ratio': round(
            min(1.0, merged_length(gap_support) / max(.001, sum(right - left for left, right in gaps))), 3),
        'average_silence_between_attacks_seconds': round(average_attack_silence, 3),
        'dyad_attacks': sum(1 for group in attacks.values() if len(group) == 2),
        'triad_attacks': sum(1 for group in attacks.values() if len(group) == 3),
        'ringing_overlap_event_ratio': round(ringing_events / max(1, len(events)), 3),
        'right_hand_distribution': dict(fingers),
        'bass_function_distribution': dict(bass_functions),
        'pattern_change_count': sum(
            1 for earlier, later in zip(shape_plan, shape_plan[1:])
            if earlier['picking_pattern'] != later['picking_pattern']),
        'average_pattern_bars': round(len(shape_plan) / max(1, sum(
            1 for earlier, later in zip(shape_plan, shape_plan[1:])
            if earlier['picking_pattern'] != later['picking_pattern']) + 1), 2),
        'bass_attacks_per_bar': round((roles['bass'] + roles['pinch_bass']) / max(1, len(shape_plan)), 2),
        '_fingering_path': fingering_path, '_performance_plan_path': plan_path,
        'sections': {'shape_regions': len(shape_plan)},
    }
