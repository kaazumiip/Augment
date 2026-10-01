"""Conservative Solo Flute pitch corrections from two vocal detectors.

This does not invent missing notes or alter performance/notation timing.
"""
import json
from copy import deepcopy

import numpy as np


def correct_consensus_pitches(events, candidates, times, pitches, probabilities, energy):
    notes = sorted(deepcopy(events), key=lambda n: n['start'])
    floor = max(.003, float(np.percentile(energy, 90)) * .06)
    rounded = np.rint(np.where(np.isfinite(pitches), pitches, -1000)).astype(int)
    changes = []
    for index, event in enumerate(notes):
        duration = event['end'] - event['start']
        options = []
        for candidate in candidates:
            overlap = min(event['end'], candidate['end']) - max(event['start'], candidate['start'])
            if overlap < duration * .65 or candidate['confidence'] < .60:
                continue
            target = candidate['pitch']
            while target < 60:
                target += 12
            while target > 96:
                target -= 12
            if target == event['pitch']:
                continue
            start = max(event['start'], candidate['start'])
            end = min(event['end'], candidate['end'])
            mask = (times >= start + .015) & (times < end - .015)
            active = mask & np.isfinite(pitches) & (energy >= floor)
            matches = active & (rounded == candidate['pitch'])
            agreement = float(matches.sum() / max(1, active.sum()))
            probability = float(np.median(probabilities[matches])) if matches.any() else 0.
            if (matches.sum() < 4 or active.sum() / max(1, mask.sum()) < .75 or
                    agreement < .85 or probability < .50):
                continue
            octave_change = abs(target - event['pitch']) == 12
            original_support = max([
                c['confidence'] for c in candidates
                if (c['pitch'] == event['pitch'] if octave_change else
                    c['pitch'] % 12 == event['pitch'] % 12)
                and min(event['end'], c['end']) - max(event['start'], c['start']) >= duration * .65
            ] or [0.])
            if candidate['confidence'] < original_support + .15:
                continue
            neighbors = notes[max(0, index - 1):index] + notes[index + 1:index + 2]
            if not neighbors or min(abs(target - n['pitch']) for n in neighbors) > 7:
                continue
            if max(abs(target - n['pitch']) for n in neighbors) > 12:
                continue
            if (len(neighbors) == 2 and neighbors[0]['pitch'] == neighbors[1]['pitch']
                    and abs(target - neighbors[0]['pitch']) > 4):
                continue
            options.append(dict(start=event['start'], end=event['end'],
                old_pitch=event['pitch'], new_pitch=int(target),
                basic_pitch_confidence=float(candidate['confidence']),
                original_basic_pitch_support=float(original_support),
                pyin_probability=probability, agreement=agreement,
                source='source-stem Basic Pitch + independent pYIN'))
        if options:
            best = max(options, key=lambda c: c['basic_pitch_confidence'] * c['pyin_probability'])
            event['pitch'] = best['new_pitch']
            changes.append(best)
    return notes, changes


def apply_flute_melody_accuracy(midi, audio_path, detector_path):
    """Correct in place only after all evidence checks succeed.

    Raw Basic Pitch hypotheses are reused; no second model inference is needed.
    """
    import librosa
    with open(detector_path, encoding='utf-8') as handle:
        raw = json.load(handle)['events']
    candidates = [dict(start=n['onset_seconds'], end=n['offset_seconds'],
                       pitch=n['pitch'], confidence=n['confidence']) for n in raw]
    source_notes = sorted((n for inst in midi.instruments for n in inst.notes),
                          key=lambda n: (n.start, n.pitch))
    events = [dict(start=n.start, end=n.end, pitch=n.pitch, velocity=n.velocity)
              for n in source_notes]
    stats = dict(version='flute_consensus_pitch_v1', enabled=True,
                 notes_before=len(events), notes_after=len(events),
                 notes_added=0, notes_removed=0, corrections=[])
    if not events or not any(c['confidence'] >= .60 for c in candidates):
        return stats
    audio, sr = librosa.load(audio_path, sr=22050, mono=True)
    if not len(audio):
        return stats
    f0, _, probability = librosa.pyin(audio,
        fmin=librosa.midi_to_hz(48), fmax=librosa.midi_to_hz(84),
        sr=sr, frame_length=2048, hop_length=256)
    energy = librosa.feature.rms(y=audio, frame_length=2048, hop_length=256)[0]
    times = librosa.frames_to_time(np.arange(len(f0)), sr=sr, hop_length=256)
    corrected, changes = correct_consensus_pitches(events, candidates, times,
        librosa.hz_to_midi(f0), np.nan_to_num(probability), energy)
    # Do not touch velocities, onsets, releases, CCs, pitch bends or note count.
    for source, candidate in zip(source_notes, corrected):
        source.pitch = candidate['pitch']
    stats['corrections'] = changes
    return stats
