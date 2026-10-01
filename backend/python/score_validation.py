"""Check exported notation against the arranged MIDI, not against ground truth."""
import music21
import pretty_midi


def audit_score(xml_path, midi_path, grid):
    score = music21.converter.parse(xml_path)
    events = []
    overfull = []
    for index, part in enumerate(score.parts):
        if part.recurse().getElementsByClass(music21.clef.TabClef):
            continue
        for measure in part.getElementsByClass(music21.stream.Measure):
            if float(measure.highestTime) > float(measure.barDuration.quarterLength) + 1e-6:
                overfull.append({'part': index + 1, 'measure': measure.number})
        for event in part.recurse().notes:
            # Voice offsets are local to a measure/Voice.  Resolve through the
            # complete score so a chord in Voice 2 of measure N compares to
            # the same absolute musical time as the performance MIDI.
            start = float(event.getOffsetInHierarchy(score))
            members = event.notes if isinstance(event, music21.chord.Chord) else (event,)
            for member in members:
                # A tied continuation sustains a note; it is not a new attack.
                pitch = getattr(member, 'pitch', None)
                if pitch is not None and getattr(member.tie, 'type', None) not in ('continue', 'stop'):
                    events.append((pitch.midi, start))
    midi = pretty_midi.PrettyMIDI(midi_path)
    lead = [n for t in midi.instruments if 'isolated melody' in t.name.lower()
            for n in t.notes]
    references = lead or [n for t in midi.instruments if not t.is_drum for n in t.notes]
    remaining = list(events)
    missing = []
    for note in references:
        target = grid.seconds_to_quarter(note.start)
        matches = [(abs(start - target), i) for i, (pitch, start) in enumerate(remaining)
                   if pitch == note.pitch and abs(start - target) <= .125 + 1e-6]
        if matches:
            _, index = min(matches)
            remaining.pop(index)
        else:
            missing.append({'pitch': note.pitch, 'seconds': round(note.start, 3)})
    return {'reference': 'arranged_midi', 'scope': 'isolated_melody' if lead else 'all_pitched_notes',
            'expected_attacks': len(references), 'matched_attacks': len(references) - len(missing),
            'missing_attacks': missing[:30], 'missing_attack_count': len(missing),
            'overfull_measures': overfull, 'score_beats': float(score.highestTime)}
