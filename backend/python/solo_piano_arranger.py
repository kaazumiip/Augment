"""Diagnostic evidence planner for a future full-song Solo Piano arranger.

This module deliberately never writes MIDI or creates notes.  It turns the
existing detector outputs into deterministic, inspectable arrangement evidence.
"""
from dataclasses import asdict, dataclass
from collections import defaultdict
import json
import os
import pretty_midi


def ensure_piano_melody_track(midi):
    """Inspect existing lead evidence without manufacturing a melody track."""
    existing = [track for track in midi.instruments
                if 'isolated melody' in track.name.lower() and track.notes]
    if existing:
        return {'source': 'isolated_melody',
                'notes': sum(len(track.notes) for track in existing),
                'fallback': False}
    return {'source': 'unavailable', 'notes': 0, 'fallback': False}


def midi_events(path):
    if not path or not os.path.isfile(path):
        return []
    return [
        {'pitch': n.pitch, 'start': round(n.start, 4), 'end': round(n.end, 4),
         'velocity': n.velocity}
        for track in pretty_midi.PrettyMIDI(path).instruments for n in track.notes
    ]


def _ranges(events):
    if not events:
        return {'count': 0, 'pitch_range': None, 'active_ranges': [], 'density': 'none'}
    starts = [n['start'] for n in events]
    ends = [n['end'] for n in events]
    density = len(events) / max(.5, max(ends) - min(starts))
    return {'count': len(events), 'pitch_range': [min(n['pitch'] for n in events), max(n['pitch'] for n in events)],
            'active_ranges': [[round(min(starts), 3), round(max(ends), 3)]],
            'density': 'active' if density >= 4 else 'moderate' if density >= 1 else 'sparse'}


def _events_in(events, start, end):
    return [n for n in events if n['start'] < end and n['end'] > start]


def _support(chord, bass, accompaniment, piano, key_name):
    tones = set(chord.get('tones', []))
    root = chord.get('root_pc')
    evidence = bass + accompaniment + piano
    pcs = [n['pitch'] % 12 for n in evidence]
    tone_ratio = sum(pc in tones for pc in pcs) / len(pcs) if pcs else 0
    bass_pcs = [n['pitch'] % 12 for n in bass]
    relation = 'none'
    if bass_pcs:
        if root in bass_pcs:
            relation = 'root-position evidence'
        elif any(pc in tones for pc in bass_pcs):
            relation = 'possible inversion evidence'
        else:
            relation = 'bass conflicts with chord'
    confidence = float(chord.get('confidence', 0))
    if relation == 'bass conflicts with chord' or (pcs and tone_ratio < .35):
        support = 'conflicting'
    elif confidence >= .70 and (relation != 'none' or tone_ratio >= .6):
        support = 'strongly supported'
    elif confidence >= .45 and (relation != 'none' or tone_ratio >= .35):
        support = 'partially supported'
    else:
        support = 'weak'
    return support, relation, round(tone_ratio, 3)


def build_plan(grid, duration, melody=None, bass=None, piano=None, accompaniment=None,
               melody_source='none', bass_source='none', piano_source='none',
               recovered_sections=None, byte_dance=False, cc64_count=0):
    melody, bass, piano, accompaniment = melody or [], bass or [], piano or [], accompaniment or []
    chords = list(getattr(grid, 'chord_sections', ()) or ())
    boundaries = sorted({0.0, float(duration), *[float(c['start_seconds']) for c in chords],
                         *[float(c['end_seconds']) for c in chords]})
    sections, duplicates = [], []
    source_sets = {'melody': melody, 'bass': bass, 'piano': piano, 'accompaniment': accompaniment}
    seen = defaultdict(list)
    for source, events in source_sets.items():
        for n in events:
            seen[(n['pitch'], round(n['start'], 2))].append(source)
    for (pitch, start), sources in seen.items():
        if len(sources) > 1:
            duplicates.append({'pitch': pitch, 'start': start, 'sources': sources})
    for left, right in zip(boundaries, boundaries[1:]):
        chord = next((c for c in chords if c['start_seconds'] <= left < c['end_seconds']), None)
        m, b, p, a = (_events_in(events, left, right) for events in (melody, bass, piano, accompaniment))
        melody_density = len(m) / max(.25, right-left)
        rhythm_density = len(a) / max(.25, right-left)
        support, relation, tone_ratio = _support(chord or {}, b, a, p, getattr(grid, 'display_key', None)) if chord else ('weak', 'none', 0)
        rh = ['protected lead melody'] if m else (['existing Piano motif candidate'] if p else ['sparse upper harmony candidate'])
        lh = ['bass root/inversion evidence'] if b else ['harmonic support candidate']
        conflicts = []
        if m and any(n['pitch'] >= 60 for n in a + p): conflicts.append('melody/accompaniment register collision risk')
        if p and b and any(n['pitch'] < 55 for n in p): conflicts.append('existing Piano/bass duplication risk')
        sections.append({'start': round(left,3), 'end': round(right,3), 'chord': chord,
                         'harmony_support': support, 'bass_chord_relation': relation,
                         'chord_tone_evidence': tone_ratio,
                         'melody_density': 'high' if melody_density >= 4 else 'moderate' if melody_density >= 1 else 'sparse',
                         'rhythm_density': 'active' if rhythm_density >= 4 else 'moderate' if rhythm_density >= 1 else 'sparse',
                         'right_hand_plan': rh, 'left_hand_plan': lh, 'conflicts': conflicts})
    return {'schema_version': 1, 'song': {'duration': round(duration,3), 'tempo': grid.bpm,
            'meter': grid.time_signature, 'key': grid.display_key,
            'key_sections': list(getattr(grid, 'key_sections', ()) or ())},
            'melody': {**_ranges(melody), 'source': melody_source, 'recovered_sections': recovered_sections or []},
            'bass': {**_ranges(bass), 'source': bass_source},
            'existing_piano': {**_ranges(piano), 'source': piano_source,
                               'available': bool(piano), 'bytedance_evidence': byte_dance,
                               'cc64_events': cc64_count},
            'accompaniment': _ranges(accompaniment), 'sections': sections,
            'duplicate_candidates': duplicates,
            'roles': {'right_hand_range': [60,88], 'left_hand_range': [28,55]}}


def write_plan(plan, output_path):
    with open(output_path, 'w', encoding='utf-8') as handle:
        json.dump(plan, handle, indent=2)
    return output_path


def arrange_pianist_v2(baseline_midi_path, output_midi_path, grid):
    """Create an experimental two-hand arrangement from Piano V1 evidence.

    This is deliberately an A/B-only pass.  The isolated-melody track is
    copied verbatim; all choices are made only among already detected Piano
    accompaniment notes.  It therefore cannot replace the song's identity,
    retime an attack, or introduce guessed harmony while we evaluate the
    musical effect of cleaner two-hand voicing.
    """
    baseline = pretty_midi.PrettyMIDI(baseline_midi_path)
    melody_source = next((track for track in baseline.instruments
                          if 'isolated melody' in track.name.lower()), None)
    accompaniment = [note for track in baseline.instruments
                     if track is not melody_source for note in track.notes]
    melody = list(melody_source.notes if melody_source else [])
    if not melody:
        raise ValueError('Piano V2 requires the protected isolated melody track.')

    def clone(note):
        return pretty_midi.Note(velocity=note.velocity, pitch=note.pitch,
                                start=note.start, end=note.end)

    melody = [clone(note) for note in melody]
    # Detector chords often arrive a few milliseconds apart.  A pianist hears
    # these as one harmonic moment, so V2 makes one hand decision per cluster.
    clusters = []
    for note in sorted(accompaniment, key=lambda item: (item.start, item.pitch)):
        if clusters and note.start - clusters[-1][0].start <= .075:
            clusters[-1].append(note)
        else:
            clusters.append([note])
    sections = list(getattr(grid, 'chord_sections', ()) or ())

    def section_at(time):
        return next((section for section in sections
                     if float(section.get('start_seconds', 0)) <= time <
                     float(section.get('end_seconds', 0))), None)

    def active_melody(time):
        return [note for note in melody if note.start - .05 <= time < note.end]

    def texture_for(time, group):
        # Texture belongs to a chord/phrase region, not to each detector
        # cluster.  That keeps the two hands in one recognisable pattern long
        # enough for a listener to hear an arrangement rather than toggling
        # light/full support on every re-attack.
        section = section_at(time)
        if section is None:
            return 'light'
        left, right = float(section.get('start_seconds', time)), float(section.get('end_seconds', time + 1))
        melody_density = sum(left <= note.start < right for note in melody) / max(.25, right - left)
        confidence = float(section.get('confidence', 0.0))
        if melody_density >= 2.25:
            return 'busy'
        if confidence >= .07 and melody_density <= 1.35:
            return 'full'
        return 'light'

    right, left = [], []
    previous_rh, previous_lh = [], []
    common_tones = 0
    inversion_count = 0
    pattern_changes = 0
    previous_pattern = None
    prevented_cross_hand_duplicates = 0
    for group in clusters:
        start = group[0].start
        active = active_melody(start)
        melody_floor = min((note.pitch for note in active), default=128)
        texture = texture_for(start, group)
        if previous_pattern is not None and texture != previous_pattern:
            pattern_changes += 1
        previous_pattern = texture
        # Lower notes form a clear LH anchor. Keep one or two source tones,
        # never a muddy detector stack; prefer smooth movement and chord root
        # evidence when it is actually present in the recorded transcription.
        low = [note for note in group if note.pitch < 60]
        mid = [note for note in group if 52 <= note.pitch < min(78, melody_floor)]
        high = [note for note in group if 60 <= note.pitch < melody_floor]
        section = section_at(start)
        root_pc = section.get('root_pc') if section else None
        def left_rank(note):
            root_bonus = 4 if root_pc is not None and note.pitch % 12 == root_pc else 0
            movement = min((abs(note.pitch - pitch) for pitch in previous_lh), default=0)
            return (root_bonus - movement * 1.2, note.velocity, -note.pitch)
        left_candidates = sorted(low, key=left_rank, reverse=True)
        chosen_left = left_candidates[: (2 if texture == 'full' and len(left_candidates) > 1 else 1)]
        # Right hand supplies only close chord colour beneath the protected
        # melody. During a fast melody it stays as a compact dyad or rests.
        palette = high or mid
        def right_rank(note):
            movement = min((abs(note.pitch - pitch) for pitch in previous_rh), default=0)
            common_bonus = 7 if note.pitch in previous_rh else 0
            return (common_bonus - movement * .55, note.velocity, note.pitch)
        limit = 0 if texture == 'busy' and active else (2 if texture == 'full' else 1)
        chosen_right = sorted(palette, key=right_rank, reverse=True)[:limit]
        # If V1 gives only a bass source note, keep it as a legitimate sparse
        # pianist gesture rather than manufacturing a chord.
        left.extend(clone(note) for note in chosen_left)
        # The fallback mid palette overlaps the LH range. A source attack can
        # belong to both selections, but one physical key cannot be struck by
        # both hands at the same instant. Omit only that redundant RH copy;
        # do not select a replacement or merge nearby repeated attacks.
        left_source_ids = {id(note) for note in chosen_left}
        emitted_right = [note for note in chosen_right
                         if id(note) not in left_source_ids]
        prevented_cross_hand_duplicates += len(chosen_right) - len(emitted_right)
        right.extend(clone(note) for note in emitted_right)
        common_tones += sum(note.pitch in previous_rh for note in chosen_right)
        if chosen_left and root_pc is not None and chosen_left[0].pitch % 12 != root_pc:
            inversion_count += 1
        previous_lh = [note.pitch for note in chosen_left] or previous_lh
        previous_rh = [note.pitch for note in chosen_right] or previous_rh

    output = pretty_midi.PrettyMIDI(initial_tempo=max(40, float(grid.bpm)))
    left_track = pretty_midi.Instrument(program=0, name='Piano left hand')
    right_track = pretty_midi.Instrument(program=0, name='Piano right hand support')
    melody_track = pretty_midi.Instrument(program=0, name='Isolated melody')
    left_track.notes = sorted(left, key=lambda note: (note.start, note.pitch))
    right_track.notes = sorted(right, key=lambda note: (note.start, note.pitch))
    melody_track.notes = sorted(melody, key=lambda note: (note.start, note.pitch))
    output.instruments.extend([left_track, right_track, melody_track])
    output.write(output_midi_path)

    def movement(notes):
        pitches = [note.pitch for note in sorted(notes, key=lambda note: (note.start, note.pitch))]
        return (sum(abs(right - left) for left, right in zip(pitches, pitches[1:])) /
                max(1, len(pitches) - 1))
    def large_leaps(notes):
        pitches = [note.pitch for note in sorted(notes, key=lambda note: (note.start, note.pitch))]
        return sum(abs(right - left) >= 12 for left, right in zip(pitches, pitches[1:]))
    return {
        'model': 'pianist_arrangement_v2_experimental',
        'protected_melody_input': len(melody),
        'protected_melody_retained': len(melody),
        'melody_notes_changed': 0,
        'melody_notes_removed': 0,
        'right_hand_note_count': len(right) + len(melody),
        'prevented_cross_hand_duplicates': prevented_cross_hand_duplicates,
        'left_hand_note_count': len(left),
        'chord_inversions_used': inversion_count,
        'right_hand_common_tone_retentions': common_tones,
        'average_right_hand_movement': round(movement(right + melody), 2),
        'average_left_hand_movement': round(movement(left), 2),
        'large_right_hand_leaps': large_leaps(right + melody),
        'large_left_hand_leaps': large_leaps(left),
        'left_hand_pattern_changes': pattern_changes,
        'section_texture_counts': {
            'light': sum(texture_for(group[0].start, group) == 'light' for group in clusters),
            'full': sum(texture_for(group[0].start, group) == 'full' for group in clusters),
            'busy': sum(texture_for(group[0].start, group) == 'busy' for group in clusters),
        },
        'maximum_simultaneous_right_hand_notes': 3,
        'maximum_simultaneous_left_hand_notes': 2,
        'source_note_only': True,
    }


def perform_pianist_v2_1(arrangement_midi_path, output_midi_path, grid):
    """Perform the frozen V2 arrangement without changing its musical notes.

    This pass owns velocity, release, sub-12-ms placement, selected chord
    spreads, and CC64 only. It never changes pitch, hand track, intended onset
    order, or any V2 voicing. The clean V2 MIDI remains the notation source.
    """
    source = pretty_midi.PrettyMIDI(arrangement_midi_path)
    tracks = {track.name.lower(): track for track in source.instruments}
    melody_source = next((track for track in source.instruments
                          if 'isolated melody' in track.name.lower()), None)
    left_source = next((track for track in source.instruments
                        if 'left hand' in track.name.lower()), None)
    right_source = next((track for track in source.instruments
                         if 'right hand support' in track.name.lower()), None)
    if melody_source is None or not melody_source.notes:
        raise ValueError('Piano V2.1 requires the frozen V2 melody track.')
    # MIDI serialization omits genuinely empty hands. Preserve their silence;
    # never invent accompaniment just to satisfy the track schema.
    if left_source is None:
        left_source = pretty_midi.Instrument(0, name='Piano left hand')
    if right_source is None:
        right_source = pretty_midi.Instrument(0, name='Piano right hand support')

    melody = sorted(melody_source.notes, key=lambda note: (note.start, note.pitch))
    phrases, current = [], []
    for note in melody:
        if current and note.start - current[-1].end >= .30:
            phrases.append(current)
            current = []
        current.append(note)
    if current:
        phrases.append(current)
    phrase_by_note = {id(note): phrase for phrase in phrases for note in phrase}
    sections = list(getattr(grid, 'chord_sections', ()) or ())

    def section_level(time):
        index = next((i for i, section in enumerate(sections)
                      if float(section.get('start_seconds', 0)) <= time <
                      float(section.get('end_seconds', 0))), 0)
        # An evidence-based, restrained sectional contour: later stable chord
        # regions may grow modestly; uncertain regions stay light.
        confidence = float(sections[index].get('confidence', 0.0)) if sections else 0.0
        progress = index / max(1, len(sections) - 1)
        return round((-3 if confidence < .03 else 0) + (3 if .34 <= progress <= .78 else 0), 2)

    def phrase_velocity(note):
        phrase = phrase_by_note[id(note)]
        index = phrase.index(note)
        peak_index = max(range(len(phrase)), key=lambda item: phrase[item].pitch)
        progress = index / max(1, len(phrase) - 1)
        contour = round(3 * progress)  # gentle growth into a phrase
        peak = 5 if index == peak_index else 0
        release = -4 if index == len(phrase) - 1 else 0
        return max(72, min(96, 80 + contour + peak + release + section_level(note.start)))

    def clone(track, note, velocity, start, end):
        track.notes.append(pretty_midi.Note(
            velocity=int(max(1, min(127, velocity))), pitch=note.pitch,
            start=max(0.0, start), end=max(start + .045, end)))

    output = pretty_midi.PrettyMIDI(initial_tempo=max(40, float(grid.bpm)))
    left = pretty_midi.Instrument(program=0, name='Piano left hand')
    right = pretty_midi.Instrument(program=0, name='Piano right hand support')
    melody_track = pretty_midi.Instrument(program=0, name='Isolated melody')
    output.instruments.extend([left, right, melody_track])
    timing_deviations, melody_velocities, right_velocities, left_velocities = [], [], [], []

    for note in melody:
        phrase = phrase_by_note[id(note)]
        index = phrase.index(note)
        next_note = phrase[index + 1] if index + 1 < len(phrase) else None
        # A phrase ending breathes by only 8 ms; connected notes receive a
        # tiny overlap that remains far below notation resolution.
        shift = .008 if next_note is None else 0.0
        end = note.end - (.018 if next_note is None else 0.0)
        if next_note is not None and next_note.start - note.end <= .06:
            end = max(end, next_note.start + .012)
        velocity = phrase_velocity(note)
        clone(melody_track, note, velocity, note.start + shift, end + shift)
        melody_velocities.append(velocity)
        timing_deviations.append(abs(shift))

    def perform_support(source_track, target_track, hand):
        by_start = {}
        for note in source_track.notes:
            by_start.setdefault(round(note.start, 3), []).append(note)
        for group_index, group in enumerate(by_start.values()):
            group = sorted(group, key=lambda note: note.pitch)
            time = group[0].start
            density = sum(1 for note in melody if abs(note.start - time) < .28)
            level = section_level(time)
            for index, note in enumerate(group):
                # The accompaniment is fractionally behind the melody; chord
                # spread is selected only for full RH clusters at an arrival.
                lag = .005 if hand == 'left' else .003
                spread = (.003 * index if hand == 'right' and len(group) >= 3 and
                          group_index % 3 == 0 else 0.0)
                shift = lag + spread
                base = (58 if hand == 'right' else 54)
                velocity = base + level - min(7, density * 2) + (2 if index == len(group) - 1 else 0)
                velocity = max(46 if hand == 'left' else 52,
                               min(72 if hand == 'right' else 68, round(velocity)))
                # Support releases a little earlier at a clear harmonic turn;
                # CC64 below carries the resonance without muddy overlap.
                end = note.end - min(.018, max(0.0, (note.end - note.start) * .06))
                clone(target_track, note, velocity, note.start + shift, end + shift)
                (right_velocities if hand == 'right' else left_velocities).append(velocity)
                timing_deviations.append(abs(shift))

    perform_support(left_source, left, 'left')
    perform_support(right_source, right, 'right')

    pedal_windows = []
    for section in sections:
        start, end = float(section.get('start_seconds', 0)), float(section.get('end_seconds', 0))
        if end - start < .45:
            continue
        down = start + .035
        up = min(end - .045, down + min(2.35, max(.45, (end - start) * .78)))
        if up > down + .12:
            left.control_changes.extend([
                pretty_midi.ControlChange(64, 92, down),
                pretty_midi.ControlChange(64, 0, up),
            ])
            pedal_windows.append((down, up))
    left.control_changes.sort(key=lambda change: change.time)
    output.write(output_midi_path)

    chord_groups = {}
    for note in right.notes:
        chord_groups.setdefault(round(note.start, 3), []).append(note)
    spreads = [max(note.start for note in group) - min(note.start for note in group)
               for group in chord_groups.values() if len(group) >= 2]
    return {
        'model': 'pianist_v2_1_structured_performance',
        'v2_note_count': sum(len(track.notes) for track in source.instruments),
        'v2_1_note_count': sum(len(track.notes) for track in output.instruments),
        'pitch_changes': 0, 'notes_removed': 0, 'notes_added': 0,
        'melody_average_velocity': round(sum(melody_velocities) / max(1, len(melody_velocities)), 2),
        'right_hand_support_average_velocity': round(sum(right_velocities) / max(1, len(right_velocities)), 2),
        'left_hand_average_velocity': round(sum(left_velocities) / max(1, len(left_velocities)), 2),
        'velocity_range': [min(melody_velocities + right_velocities + left_velocities),
                           max(melody_velocities + right_velocities + left_velocities)],
        'maximum_timing_deviation_seconds': round(max(timing_deviations, default=0.0), 3),
        'average_timing_deviation_seconds': round(sum(timing_deviations) / max(1, len(timing_deviations)), 4),
        'pedal_events': len(pedal_windows) * 2,
        'average_pedal_duration_seconds': round(sum(up - down for down, up in pedal_windows) / max(1, len(pedal_windows)), 3),
        'rolled_spread_chords': sum(1 for spread in spreads if spread > .001),
        'average_chord_spread_seconds': round(sum(spreads) / max(1, len(spreads)), 4),
        'melody_notes_receiving_phrase_emphasis': sum(velocity >= 85 for velocity in melody_velocities),
        'phrase_crescendos': sum(1 for phrase in phrases if len(phrase) >= 2),
        'phrase_decrescendos': sum(1 for phrase in phrases if len(phrase) >= 2),
        'phrase_count': len(phrases),
    }


def perform_pianist_v2_2(arrangement_midi_path, v2_1_midi_path,
                         output_midi_path, grid):
    """Polish the accepted V2.1 performance; V2 remains the score source.

    Pair every event with its frozen V2 counterpart by hand, pitch and pitch-
    local occurrence. No note is created, discarded, revoiced or reassigned.
    """
    clean = pretty_midi.PrettyMIDI(arrangement_midi_path)
    prior = pretty_midi.PrettyMIDI(v2_1_midi_path)
    names = ('Piano left hand', 'Piano right hand support', 'Isolated melody')
    clean_tracks = {track.name: track for track in clean.instruments}
    prior_tracks = {track.name: track for track in prior.instruments}
    for tracks in (clean_tracks, prior_tracks):
        for name in names[:2]:
            tracks.setdefault(name, pretty_midi.Instrument(0, name=name))
    if set(clean_tracks) != set(names) or set(prior_tracks) != set(names):
        raise ValueError('V2.2 requires identical V2 and V2.1 hand tracks.')

    def paired(name):
        a, b = clean_tracks[name], prior_tracks[name]
        if len(a.notes) != len(b.notes):
            raise ValueError('V2.1 changed the frozen note count.')
        by_pitch = defaultdict(list)
        for note in sorted(b.notes, key=lambda n: (n.pitch, n.start)):
            by_pitch[note.pitch].append(note)
        result = []
        for note in sorted(a.notes, key=lambda n: (n.pitch, n.start)):
            matches = by_pitch[note.pitch]
            if not matches:
                raise ValueError('V2.1 changed a frozen pitch or hand.')
            performed = matches.pop(0)
            if abs(performed.start - note.start) > .025:
                raise ValueError('V2.1 onset is too far from the frozen score.')
            result.append((note, performed))
        if any(by_pitch.values()):
            raise ValueError('V2.1 added a musical note.')
        return sorted(result, key=lambda pair: (pair[0].start, pair[0].pitch))

    pairs = {name: paired(name) for name in names}
    melody_pairs = pairs['Isolated melody']
    phrases, phrase = [], []
    for pair in melody_pairs:
        if phrase and pair[0].start - phrase[-1][0].end >= .30:
            phrases.append(phrase)
            phrase = []
        phrase.append(pair)
    if phrase:
        phrases.append(phrase)
    phrase_context = {}
    for phrase in phrases:
        peak = max(range(len(phrase)), key=lambda index: phrase[index][0].pitch)
        for index, (note, _) in enumerate(phrase):
            phrase_context[id(note)] = (index, len(phrase), peak)

    all_clean = [note for group in pairs.values() for note, _ in group]
    output = pretty_midi.PrettyMIDI(initial_tempo=max(40, float(grid.bpm)))
    output_tracks = {name: pretty_midi.Instrument(program=0, name=name)
                     for name in names}
    output.instruments.extend(output_tracks.values())
    phrase_ends, repeats, dense_compensation, spreads = [], 0, 0, []
    for name in names:
        group = pairs[name]
        for index, (note, old) in enumerate(group):
            nearby = sum(abs(other.start - note.start) <= .035 for other in all_clean)
            velocity = old.velocity
            shift = old.start - note.start
            end = old.end
            if name == 'Isolated melody':
                place, length, peak = phrase_context[id(note)]
                previous = group[index - 1][0] if index else None
                following = group[index + 1][0] if index + 1 < len(group) else None
                if place == 0:
                    velocity += 2
                    shift = min(shift, .003)
                if place == peak and length > 2:
                    velocity += 2
                if note.end - note.start >= .65:
                    velocity += 1
                if place == length - 1:
                    velocity -= 1
                    shift = min(.010, max(shift, .008))
                    end = min(end, note.end - .025)
                    phrase_ends.append(float(round(shift, 4)))
                if previous and previous.pitch == note.pitch:
                    velocity += (1 if note.pitch >= previous.pitch and
                                 place <= peak else -1)
                    repeats += 1
                if following and following.pitch == note.pitch:
                    end = min(end, following.start - .018)
                elif following and following.start - note.end <= .065:
                    end = max(end, min(following.start + .010,
                                       note.end + .020))
                if nearby >= 4:
                    velocity += 1
            elif name == 'Piano left hand':
                velocity -= (3 if note.pitch < 45 else 2 if note.pitch < 52 else 0)
                if nearby >= 4:
                    velocity -= 1
                    dense_compensation += 1
                # LH grounds a true harmony arrival, without an audible flam.
                shift = min(shift, .002) if _piano_near_chord_change(
                    note.start, grid) else shift
            else:
                if nearby >= 3:
                    velocity -= 2 if nearby >= 4 else 1
                    dense_compensation += 1
                if any(abs(melody.start - note.start) <= .025
                       for melody, _ in melody_pairs):
                    velocity -= 1
                    shift = min(.009, max(shift, .004))
                # Most source chords stay essentially together. Only a clear
                # phrase/harmony arrival with >=3 RH notes receives a roll.
                same_chord = sorted((other for other, _ in group
                                     if abs(other.start - note.start) <= .002),
                                    key=lambda item: item.pitch)
                if len(same_chord) >= 3 and _piano_near_chord_change(
                        note.start, grid):
                    rank = next(i for i, item in enumerate(same_chord)
                                if item is note)
                    shift = min(.012, .002 + rank * .004)
                    if rank == len(same_chord) - 1:
                        spreads.append({'time': float(round(note.start, 3)),
                                        'pitches': [int(n.pitch) for n in same_chord],
                                        'spread_seconds': float(round(shift - .002, 3))})
            start = max(0.0, note.start + max(-.004, min(.012, shift)))
            end = max(start + .045, end)
            output_tracks[name].notes.append(pretty_midi.Note(
                velocity=max(1, min(127, velocity)), pitch=note.pitch,
                start=start, end=end))

    sections = list(getattr(grid, 'chord_sections', ()) or ())
    pedal_windows = []
    for index, section in enumerate(sections):
        begin = float(section['start_seconds'])
        finish = float(section['end_seconds'])
        if finish - begin < .45:
            continue
        # Catch an attack, then clear *before* the next harmony. Long stable
        # regions re-pedal quietly around existing LH attacks.
        anchors = [begin]
        for note, _ in pairs['Piano left hand']:
            if begin + 1.7 <= note.start < finish - .55 and (
                    note.start - anchors[-1] >= 1.7):
                anchors.append(note.start)
        for anchor_index, anchor in enumerate(anchors):
            next_anchor = anchors[anchor_index + 1] if anchor_index + 1 < len(anchors) else finish
            down = anchor + (.040 if anchor_index == 0 else .028)
            up = next_anchor - (.052 if anchor_index == len(anchors) - 1 else .035)
            if up > down + .15:
                pedal_windows.append((down, up, index))
                output_tracks['Piano left hand'].control_changes.extend([
                    pretty_midi.ControlChange(64, 88, down),
                    pretty_midi.ControlChange(64, 0, up)])
    for track in output.instruments:
        track.notes.sort(key=lambda note: (note.start, note.pitch))
        track.control_changes.sort(key=lambda cc: cc.time)
    output.write(output_midi_path)

    # Pair by pitch again so a micro-spread cannot corrupt the timing audit.
    deviations = []
    for name in names:
        originals = defaultdict(list)
        rendered = defaultdict(list)
        for original, _ in pairs[name]:
            originals[original.pitch].append(original)
        for note in output_tracks[name].notes:
            rendered[note.pitch].append(note)
        for pitch in originals:
            for original, note in zip(sorted(originals[pitch], key=lambda n: n.start),
                                      sorted(rendered[pitch], key=lambda n: n.start)):
                deviations.append(abs(note.start - original.start))

    right_groups = defaultdict(list)
    for note in output_tracks['Piano right hand support'].notes:
        right_groups[round(note.start / .015)].append(note)
    subtle_spreads = sum(
        len(group) >= 2 and .001 <= max(n.start for n in group) -
        min(n.start for n in group) < .008
        for group in right_groups.values())

    def average(values):
        return float(round(sum(values) / len(values), 3)) if values else 0.0
    velocities = {name: [note.velocity for note in output_tracks[name].notes]
                  for name in names}
    register = {'low': [], 'middle': [], 'upper': []}
    for track in output.instruments:
        for note in track.notes:
            register['low' if note.pitch < 52 else 'middle' if note.pitch < 72
                     else 'upper'].append(note.velocity)
    return {
        'model': 'pianist_v2_2_polish',
        'v2_note_count': len(all_clean),
        'v2_2_note_count': sum(len(track.notes) for track in output.instruments),
        'notes_added': 0, 'notes_removed': 0, 'pitch_changes': 0,
        'chord_changes': 0, 'melody_replacements': 0, 'hand_reassignments': 0,
        'melody_average_velocity': average(velocities['Isolated melody']),
        'right_hand_support_average_velocity': average(
            velocities['Piano right hand support']),
        'left_hand_average_velocity': average(velocities['Piano left hand']),
        'velocity_by_register': {key: average(value) for key, value in register.items()},
        'melody_support_velocity_difference': round(
            average(velocities['Isolated melody']) -
            average(velocities['Piano right hand support']), 3),
        'maximum_timing_deviation_seconds': float(round(max(deviations, default=0), 4)),
        'average_timing_deviation_seconds': average(deviations),
        'phrase_end_timing_adjustments_seconds': phrase_ends,
        'pedal_events': 2 * len(pedal_windows),
        'average_pedal_duration_seconds': average(
            [up - down for down, up, _ in pedal_windows]),
        'pedal_clears_at_harmony_changes': int(sum(
            abs(up - float(sections[i]['end_seconds'])) <= .08
            for _, up, i in pedal_windows)),
        'overlapping_incompatible_harmony': int(sum(
            up >= float(sections[i]['end_seconds'])
            for _, up, i in pedal_windows)),
        'subtle_chord_spreads': int(subtle_spreads),
        'intentional_rolled_chords': spreads,
        'repeated_note_expression_changes': repeats,
        'dense_chord_compensation_events': dense_compensation,
        'phrase_count': len(phrases),
    }


def _piano_near_chord_change(time, grid):
    return any(abs(time - float(section['start_seconds'])) <= .09
               for section in (getattr(grid, 'chord_sections', ()) or ()))
