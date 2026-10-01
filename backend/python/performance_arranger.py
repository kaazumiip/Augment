"""Conservative source-note arrangements; no inferred replacement pitches.

This layer selects playable accompaniment from detected notes. It cannot
establish that the source transcription itself is correct.
"""
from dataclasses import dataclass
import pretty_midi


@dataclass(frozen=True)
class Policy:
    family: str
    voices: int
    span: int
    accompaniment_gain: float


POLICIES = {
    'Piano': Policy('keyboard', 4, 24, .88),
    'Organ': Policy('keyboard', 4, 24, .85),
    'Synthesizer': Policy('keyboard', 4, 24, .85),
    'Guitar': Policy('plucked', 4, 24, .9),
    'Electric Guitar': Policy('plucked', 4, 24, .88),
    'Ukulele': Policy('plucked', 3, 12, .9),
    'Violin': Policy('bowed', 1, 0, .88),
    'Cello': Policy('bowed', 1, 0, .92),
    'Bass Guitar': Policy('bass', 1, 0, .95),
    'Flute': Policy('wind', 1, 0, .82),
    'Clarinet': Policy('wind', 1, 0, .85),
    'Saxophone': Policy('wind', 1, 0, .85),
    'Trumpet': Policy('wind', 1, 0, .8),
    'Drums': Policy('percussion', 8, 127, 1.0),
}


def lead_intervals(midi):
    return [(n.start, n.end) for track in midi.instruments for n in track.notes]


def phrase_windows(activity, gap=0.6):
    """Group lead activity into phrases without filling the source rests."""
    phrases = []
    for start, end in sorted(set(activity)):
        if phrases and start - phrases[-1][1] <= gap:
            phrases[-1][1] = max(end, phrases[-1][1])
            phrases[-1][2] += 1
        else:
            phrases.append([start, end, 1])
    return phrases


def arrange(midi, instrument, role, lead_activity=(), solo=False):
    """Preserve lead/bass rhythm; thin accompaniment at detected attacks.

    Never invent entrances, impose a rhythmic pattern, or shift detected
    pitches to a guessed chord. Voice leading chooses among source pitches.
    """
    policy = POLICIES[instrument]
    protected = set()
    local_lead = []
    keyboard_solo = solo and policy.family == 'keyboard'
    for track in midi.instruments:
        if 'isolated melody' in track.name.lower():
            protected.update(id(n) for n in track.notes)
            local_lead.extend((n.start, n.end) for n in track.notes)
    # Solo arrangements without a designated melody are too ambiguous to thin.
    preserve_all = (role in ('melody', 'lead') and not keyboard_solo) or (
        keyboard_solo and not protected) or policy.family == 'percussion'
    before = sum(len(t.notes) for t in midi.instruments)
    if preserve_all:
        return {'version': 1, 'family': policy.family, 'notes_before': before,
                'notes_after': before, 'protected_melody': True}
    activity = tuple(lead_activity) + tuple(local_lead)
    phrases = phrase_windows(activity)
    candidates = sorted((n for t in midi.instruments for n in t.notes
                         if id(n) not in protected), key=lambda n: (n.start, n.pitch))
    groups = []
    for n in candidates:
        # 20 ms clusters only; preserve intentional arpeggio entrances.
        if groups and n.start - groups[-1][0].start <= .02:
            groups[-1].append(n)
        else:
            groups.append([n])
    retained = set(protected)
    previous = []
    previous_end = None
    previous_gain = None
    for group in groups:
        start = group[0].start
        if previous_end is not None and start - previous_end > .8:
            previous = []
            previous_gain = None
        lead_present = any(a <= start < b for a, b in activity)
        phrase = next((p for p in phrases if p[0] <= start < p[1]), None)
        busy = phrase is not None and phrase[2] / max(.5, phrase[1] - phrase[0]) > 3
        limit = policy.voices
        if role == 'bass':
            limit = 1
        elif lead_present and limit > 2:
            limit -= 1
        if busy and limit > 2:
            limit -= 1
        # Retain the lowest source tone as a bass anchor in chordal parts.
        anchor = min(group, key=lambda n: n.pitch)
        chosen = [anchor] if limit > 1 or role == 'bass' else []
        def rank(n):
            distance = min((abs(n.pitch - pitch) for pitch in previous), default=0)
            return n.velocity - min(distance, 24) * 1.5
        for n in sorted(group, key=rank, reverse=True):
            if len(chosen) >= limit:
                break
            if n in chosen or any(x.pitch == n.pitch for x in chosen):
                continue
            if chosen and max(abs(n.pitch - x.pitch) for x in chosen) > policy.span:
                continue
            chosen.append(n)
        # Keyboard transcription already contains the performed voicing.
        # Expression must not silently turn it into a reduced arrangement.
        if policy.family == 'keyboard':
            chosen = list(group)
        target_gain = policy.accompaniment_gain * (
            .84 if busy and role != 'bass' else
            .9 if phrase is not None and role != 'bass' else 1)
        # Move gently between phrase levels instead of pumping on each note.
        gain = (target_gain if previous_gain is None else
                previous_gain + max(-.04, min(.04, target_gain - previous_gain)))
        for n in chosen:
            retained.add(id(n))
            # Allow supporting lines more presence in genuine lead rests.
            # Piano left-hand support is balanced once during playback;
            # do not attenuate it here and then again in the renderer.
            note_gain = 1.0 if policy.family == 'keyboard' and n.pitch < 60 else gain
            n.velocity = max(25, min(110, round(n.velocity * note_gain)))
        previous = [n.pitch for n in chosen]
        previous_end = max(n.end for n in group)
        previous_gain = gain
    for track in midi.instruments:
        track.notes = [n for n in track.notes if id(n) in retained]
    after = sum(len(t.notes) for t in midi.instruments)
    return {'version': 2, 'family': policy.family, 'notes_before': before,
            'notes_after': after, 'notes_removed': before - after,
            'protected_melody_notes': len(protected),
            'timing_preserved': True, 'source_pitches_only': True,
            'lead_phrases': len(phrases)}
