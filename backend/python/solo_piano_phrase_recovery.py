"""Isolated Piano melody experiment. Does not run in production.

Candidate confidence must come from local source evidence, not whole-song
spectral agreement. Existing notes (including accompaniment) are immutable.
"""
from copy import deepcopy


def recover_consensus_short_notes(melody, candidates):
    """Experimental short-note repair corroborated by pYIN and Basic Pitch.

    Only an erroneous overlapping lead release may change; accompaniment is
    outside this function. Never split a note on pitch confidence alone.
    """
    result = sorted(deepcopy(melody), key=lambda n: n['start'])
    decisions = []
    for c in sorted(candidates, key=lambda n: n['start']):
        if c.get('source') != 'vocals' or c.get('confidence', 0) < .8:
            continue
        matches = c.get('basic_pitch_matches', [])
        matches = [m for m in matches if m['pitch'] == c['pitch']
                   and m['confidence'] >= .55 and abs(m['start']-c['start']) <= .06
                   and min(m['end'],c['end'])-max(m['start'],c['start']) >= .055]
        if not matches or not .055 <= c['end']-c['start'] <= .16:
            continue
        if any(n['pitch']==c['pitch'] and n['start']<c['end'] and n['end']>c['start'] for n in result):
            continue
        before = max((n for n in result if n['start']<c['start']), key=lambda n:n['start'],default=None)
        after = min((n for n in result if n['start']>=c['end']),key=lambda n:n['start'],default=None)
        if before is None or after is None:
            continue
        if (abs(before['pitch']-c['pitch'])>7 or abs(after['pitch']-c['pitch'])>7
                or after['start']-c['end']>.35
                or c['start']-before['end']>.20):
            continue
        if before['pitch']==after['pitch'] and abs(c['pitch']-before['pitch'])>2:
            continue
        original_end = before['end']
        if original_end > c['start']:
            if c['start']-before['start']<.055 or original_end-c['start']>.4:
                continue
            before['end']=c['start']
        elif not c.get('onset_supported', False):
            continue
        added = {k:c[k] for k in ('start','end','pitch')}
        added['velocity']=min(before['velocity'],after['velocity'])
        result.append(added)
        result.sort(key=lambda n:n['start'])
        decisions.append({'added':added,'preceding_original_end':original_end,
                          'preceding_new_end':before['end'],
                          'evidence': 'pYIN pitch run plus independent Basic Pitch attack',
                          'pyin_confidence':c['confidence'],'basic_pitch':matches})
    return result, decisions


def collect_local_candidates(sources, octave_shift=0):
    """Use unsmoothed, locally confident pitch runs, not a global acceptance score.

    This optional experiment deliberately keeps raw repeated pitches as one
    run; onset evidence is mandatory before any same-pitch reattack is added.
    """
    import librosa
    import numpy as np
    candidates = []
    for source, path in sources.items():
        audio, sr = librosa.load(path, sr=22050, mono=True)
        f0, _, probability = librosa.pyin(audio, sr=sr, hop_length=512,
            fmin=librosa.midi_to_hz(35), fmax=librosa.midi_to_hz(101))
        pitches = np.rint(librosa.hz_to_midi(np.where(np.isfinite(f0), f0, 1))).astype(int)
        valid = np.isfinite(f0) & (probability >= .60)
        onset_times = librosa.onset.onset_detect(y=audio, sr=sr, hop_length=512, units='time')
        index = 0
        while index < len(f0):
            if not valid[index]:
                index += 1
                continue
            end = index + 1
            while end < len(f0) and valid[end] and pitches[end] == pitches[index]:
                end += 1
            start_seconds, end_seconds = index * 512 / sr, end * 512 / sr
            if end - index >= 3 and end_seconds - start_seconds >= .055:
                confidence = float(np.mean(probability[index:end]))
                candidates.append(dict(start=start_seconds, end=end_seconds,
                    pitch=int(pitches[index]) + octave_shift, source=source,
                    confidence=confidence, velocity=max(72, min(100, round(confidence * 127))),
                    onset_supported=bool(np.any(np.abs(onset_times-start_seconds) <= .06))))
            index = end
    return candidates


def recover_performance_midi(input_path, output_path, candidates):
    """Apply only to an explicitly labelled melody; preserve all other tracks.

    Do not infer melody from pitch or velocity in flattened saved playback.
    Callers must supply independently validated local candidate evidence.
    """
    import pretty_midi
    midi = pretty_midi.PrettyMIDI(input_path)
    leads = [t for t in midi.instruments if 'isolated melody' in t.name.lower()]
    if len(leads) != 1:
        raise ValueError('One explicitly labelled isolated melody track is required')
    lead = leads[0]
    melody = [dict(start=n.start, end=n.end, pitch=n.pitch, velocity=n.velocity)
              for n in lead.notes]
    _, report = recover_supported_phrases(melody, candidates)
    for n in report['added_notes']:
        lead.notes.append(pretty_midi.Note(
            velocity=int(n['velocity']), pitch=int(n['pitch']),
            start=float(n['start']), end=float(n['end'])))
    lead.notes.sort(key=lambda n: (n.start, n.pitch))
    midi.write(output_path)
    report['accompaniment_changed'] = 0
    report['pedal_changes'] = 0
    return report


def recover_supported_phrases(melody, candidates):
    """Return original melody plus supported, two-sided fallback sequences.

    Each candidate has start/end/pitch/source/confidence/onset_supported.
    No pitch, onset, release, velocity or annotation of an existing note changes.
    Uncertain rests and same-pitch reattacks without onset evidence remain rests.
    """
    existing = sorted(deepcopy(melody), key=lambda n: (n['start'], n['pitch']))
    additions, decisions = [], []
    for before, after in zip(existing, existing[1:]):
        start, end = before['end'], after['start']
        if not .18 <= end - start <= 3.0:
            continue
        options = []
        sources = sorted({n.get('source', '') for n in candidates})
        for source in sources:
            path = sorted((deepcopy(n) for n in candidates
                           if n.get('source') == source
                           and n['start'] >= start and n['end'] <= end),
                          key=lambda n: n['start'])
            # One uncertain isolated note is not a recovered phrase.
            if len(path) < 2:
                continue
            chain = [before] + path + [after]
            if any(n['end'] - n['start'] < .055 or
                   not 40 <= n['pitch'] <= 96 or
                   n.get('confidence', 0) < .60 for n in path):
                continue
            if sum(n['confidence'] for n in path) / len(path) < .75:
                continue
            if any(b['start'] < a['end'] or b['start'] - a['end'] > .15
                   or abs(b['pitch'] - a['pitch']) > 7
                   for a, b in zip(chain, chain[1:])):
                continue
            if any(a['pitch'] == b['pitch'] and not b.get('onset_supported', False)
                   for a, b in zip(chain, chain[1:]) if b is not after):
                continue
            if any(a['pitch'] == c['pitch'] and abs(b['pitch'] - a['pitch']) > 4
                   for a, b, c in zip(chain, chain[1:], chain[2:])):
                continue
            options.append((sum(n['confidence'] for n in path) / len(path), source, path))
        decision = {'start': start, 'end': end, 'added': 0,
                    'status': 'preserved_uncertain_gap'}
        if options:
            confidence, source, path = max(options, key=lambda item: item[0])
            additions.extend(path)
            decision.update(status='supported_phrase', added=len(path),
                            source=source, confidence=confidence,
                            previous_pitch=before['pitch'], next_pitch=after['pitch'],
                            reason='local evidence and continuous two-sided phrase path')
        decisions.append(decision)
    return sorted(existing + additions, key=lambda n: (n['start'], n['pitch'])), {
        'before': len(existing), 'after': len(existing) + len(additions),
        'added_notes': additions, 'decisions': decisions,
        'existing_notes_changed': 0, 'existing_notes_removed': 0,
    }
