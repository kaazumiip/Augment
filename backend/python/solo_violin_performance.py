"""Experimental, renderer-independent expression for a frozen solo Violin line.

This module never selects notes or changes their pitch. The clean V3 MIDI and
MusicXML remain the musical and notation sources for the V3.1 A/B experiment.
"""
from dataclasses import asdict, dataclass
from math import pi, sin

import pretty_midi


@dataclass(frozen=True)
class ViolinPerformanceEvent:
    note_index: int
    pitch: int
    source_onset: float
    source_duration: float
    onset: float
    duration: float
    velocity: int
    phrase_id: int
    articulation: str
    bow_direction: str
    bow_intensity: float
    legato_from_previous: bool
    vibrato_delay: float | None
    vibrato_rate: float | None
    vibrato_depth_cents: float | None
    expression_curve: tuple[tuple[float, float], ...]
    release_style: str


def plan_violin_v3_1(source_notes):
    """Return a deterministic bow/phrase plan for the *existing* V3 notes."""
    notes = sorted(source_notes, key=lambda n: (n.start, n.pitch))
    if not notes:
        return [], {'phrase_count': 0}
    phrases, current = [], []
    for index, note in enumerate(notes):
        if current and note.start - notes[current[-1]].end >= .16:
            phrases.append(current)
            current = []
        current.append(index)
    if current:
        phrases.append(current)

    result = []
    bow = 'down'
    legato_count = bow_changes = repeated_count = 0
    vibrato_values = []
    phrase_end_adjustments = []
    for phrase_id, indices in enumerate(phrases):
        peak_local = max(range(len(indices)),
                         key=lambda j: (notes[indices[j]].pitch,
                                        notes[indices[j]].end - notes[indices[j]].start))
        for local, index in enumerate(indices):
            note = notes[index]
            previous = notes[index - 1] if index else None
            following = notes[index + 1] if index + 1 < len(notes) else None
            phrase_start = local == 0
            phrase_end = local == len(indices) - 1
            gap_before = note.start - previous.end if previous else 1.0
            gap_after = following.start - note.end if following else 1.0
            repeated = (previous is not None and not phrase_start and
                        previous.pitch == note.pitch and gap_before <= .07)
            legato = (previous is not None and not phrase_start and
                      previous.pitch != note.pitch and gap_before <= .065 and
                      abs(previous.pitch - note.pitch) <= 7 and
                      note.end - note.start >= .12)
            if repeated:
                repeated_count += 1
            if legato:
                legato_count += 1
            if index and not legato:
                bow = 'up' if bow == 'down' else 'down'
                bow_changes += 1

            source_duration = note.end - note.start
            # Avoid independent note jitter. Tiny displacements mark only a
            # phrase entrance or a long-note arrival; rhythm stays intact.
            shift = (.003 if phrase_start else
                     -.002 if local == peak_local and source_duration >= .55
                     else 0.0)
            onset = max(0.0, note.start + shift)
            end = note.end
            if phrase_end:
                end -= min(.032, source_duration * .055)
                phrase_end_adjustments.append(round(shift, 4))
            elif following is not None:
                if note.pitch == following.pitch and gap_after <= .07:
                    # Same pitch must have a distinct bow attack.
                    end = min(end, following.start - .016)
                elif gap_after <= .065 and abs(note.pitch - following.pitch) <= 7:
                    # Hold nearly to the next attack. The SoundFont's release
                    # carries acoustic overlap, while MIDI remains strictly
                    # monophonic (no second simultaneous musical note).
                    end = max(end, following.start - .001)
                elif gap_after <= .065:
                    end = min(end, following.start - .006)
            if following is not None:
                following_shift = (.003 if local + 1 == len(indices) else
                                   -.002 if local + 1 == peak_local and
                                   following.end - following.start >= .55 else 0.0)
                end = min(end, following.start + following_shift - .001)
            end = max(onset + .020, end)
            duration = end - onset

            progress = local / max(1, len(indices) - 1)
            phrase_arc = 3.0 * sin(pi * progress) if len(indices) >= 3 else 0.0
            peak_boost = 3 if local == peak_local and len(indices) >= 3 else 0
            long_boost = 2 if source_duration >= .7 else 0
            register = (2 if note.pitch < 65 else -2 if note.pitch >= 79 else 0)
            attack = (3 if phrase_start else 1 if repeated and
                      local <= peak_local else -1 if repeated else 0)
            release = -2 if phrase_end else 0
            # Retain the source's relative accents, but reduce the range of
            # detector velocities rather than amplifying its outliers.
            velocity = round(75 + (note.velocity - 75) * .52 + phrase_arc +
                             peak_boost + long_boost + register + attack + release)
            velocity = max(62, min(98, velocity))
            if phrase_start:
                articulation = 'accented'
            elif repeated:
                articulation = 'rearticulated'
            elif phrase_end:
                articulation = 'phrase_end'
            elif legato:
                articulation = 'legato'
            elif source_duration >= .48:
                articulation = 'sustain'
            else:
                articulation = 'detached'

            important_sustain = source_duration >= .50 and (
                local == peak_local or source_duration >= .70 or phrase_end)
            vibrato = (source_duration >= .62 or important_sustain) and not repeated
            if vibrato:
                delay = min(.27, max(.16, source_duration * .29))
                rate = 4.8 + (.35 if local == peak_local else 0) + (
                    .15 if note.pitch >= 76 else 0)
                depth = 14.0 + (5.0 if local == peak_local else 0.0) + (
                    3.0 if source_duration >= .82 else 0.0)
                vibrato_values.append((delay, rate, depth))
            else:
                delay = rate = depth = None
            intensity = min(1.0, max(.38, .68 + (velocity - 75) * .009))
            if duration >= .32:
                crest = min(1.0, intensity + (.09 if local == peak_local else .055))
                curve = ((0.0, intensity * (.89 if legato else .95)),
                         (.22, intensity), (.62, crest),
                         (1.0, crest * (.83 if phrase_end else .94)))
            else:
                curve = ((0.0, intensity * (.92 if legato else 1.0)),
                         (1.0, intensity * (.88 if phrase_end else .96)))
            result.append(ViolinPerformanceEvent(
                note_index=index, pitch=note.pitch,
                source_onset=note.start, source_duration=source_duration,
                onset=onset, duration=duration, velocity=velocity,
                phrase_id=phrase_id, articulation=articulation,
                bow_direction=bow, bow_intensity=round(intensity, 3),
                legato_from_previous=bool(legato),
                vibrato_delay=delay, vibrato_rate=rate,
                vibrato_depth_cents=depth,
                expression_curve=curve,
                release_style=('breath' if phrase_end else
                               'separate' if repeated else
                               'connected' if legato else 'natural'),
            ))

    deltas = [abs(e.onset - e.source_onset) for e in result]
    phrase_release = [round(e.source_onset + e.source_duration -
                            (e.onset + e.duration), 4)
                      for e in result if e.release_style == 'breath']
    return result, {
        'note_count_before': len(notes), 'note_count_after': len(result),
        'added_notes': 0, 'removed_notes': 0, 'pitch_changes': 0,
        'phrase_count': len(phrases), 'legato_transitions': legato_count,
        'bow_changes': bow_changes,
        'repeated_note_rearticulations': repeated_count,
        'sustained_notes_receiving_vibrato': len(vibrato_values),
        'average_vibrato_delay_seconds': round(sum(v[0] for v in vibrato_values) /
                                               max(1, len(vibrato_values)), 3),
        'average_vibrato_rate_hz': round(sum(v[1] for v in vibrato_values) /
                                         max(1, len(vibrato_values)), 3),
        'average_vibrato_depth_cents': round(sum(v[2] for v in vibrato_values) /
                                              max(1, len(vibrato_values)), 3),
        'phrase_crescendos': sum(len(p) >= 3 for p in phrases),
        'phrase_decrescendos': sum(len(p) >= 3 for p in phrases),
        'phrase_end_timing_adjustments_seconds': phrase_end_adjustments,
        'phrase_end_release_adjustments_seconds': phrase_release,
        'maximum_timing_deviation_seconds': round(max(deltas), 4),
        'maximum_simultaneous_selected_notes': 1,
    }


def violin_events_to_midi(events, output_path, program=0, volume=118, reverb=48):
    """Translate only supported event properties into common MIDI controls."""
    midi = pretty_midi.PrettyMIDI(initial_tempo=120)
    violin = pretty_midi.Instrument(program=program, name='Violin V3.1 performance')
    violin.control_changes.extend([
        pretty_midi.ControlChange(7, volume, 0),
        pretty_midi.ControlChange(91, reverb, 0),
    ])
    for index, event in enumerate(events):
        next_onset = events[index + 1].onset if index + 1 < len(events) else 1e9
        end = event.onset + event.duration
        violin.notes.append(pretty_midi.Note(
            velocity=event.velocity, pitch=event.pitch,
            start=event.onset, end=end))
        # CC11 is channel-wide: finish the current shape before the next
        # attack, including at a 12-ms connected transition.
        expression_limit = min(end, next_onset - .006)
        if expression_limit > event.onset:
            for fraction, level in event.expression_curve:
                time = min(expression_limit, event.onset +
                           fraction * event.duration)
                violin.control_changes.append(pretty_midi.ControlChange(
                    11, max(1, min(127, round(level * 110))), time))
        if event.vibrato_delay is None:
            continue
        vibrato_start = event.onset + event.vibrato_delay
        vibrato_end = min(end - .030, next_onset - .018)
        time = vibrato_start
        while time < vibrato_end:
            development = min(1.0, (time - vibrato_start) / .18)
            depth = event.vibrato_depth_cents * development
            bend = round(sin(2 * pi * event.vibrato_rate *
                             (time - vibrato_start)) * depth / 200 * 8192)
            violin.pitch_bends.append(pretty_midi.PitchBend(bend, time))
            time += .02
        if vibrato_end > vibrato_start:
            violin.pitch_bends.append(pretty_midi.PitchBend(0, vibrato_end))
    violin.control_changes.sort(key=lambda cc: cc.time)
    violin.pitch_bends.sort(key=lambda bend: bend.time)
    midi.instruments.append(violin)
    midi.write(output_path)
    return midi


def event_dicts(events):
    return [asdict(event) for event in events]
