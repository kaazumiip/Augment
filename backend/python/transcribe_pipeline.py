"""Audio -> separated stems -> MIDI -> playable MusicXML.

The pipeline deliberately keeps one shared analysis object for every output
part. This prevents each stem from acquiring a different tempo or tonal grid.
"""
import argparse
from bisect import bisect_right
import json
import math
import os
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from copy import deepcopy
from string import ascii_uppercase
from dataclasses import dataclass, field

import music21
import pretty_midi
from music21 import articulations, beam, chord, clef, dynamics, expressions, instrument, key, layout, meter, note, spanner, stream, tempo


INSTRUMENTS = {
    "Violin": (55, 103, 2), "Flute": (60, 96, False),
    "Saxophone": (49, 80, False), "Trumpet": (54, 82, False),
    "Clarinet": (50, 90, False), "Guitar": (40, 88, 6),
    "Electric Guitar": (40, 88, 6), "Bass Guitar": (28, 67, 4),
    "Ukulele": (60, 84, 4), "Cello": (36, 84, 2),
    "Piano": (21, 108, 10), "Synthesizer": (21, 108, 10),
    "Organ": (21, 108, 10),
    "Drums": (35, 81, 8),
}
ROLES = {"melody": "vocals", "lead": "vocals", "bass": "bass",
         "harmony": "other", "chords": "other", "drums": "drums"}


def _piano_transcriber_name():
    """Return the explicitly selected Piano backend; Basic Pitch stays default."""
    return os.environ.get('AUGMENT_PIANO_TRANSCRIBER', 'basic_pitch').strip().lower()


def _is_successful_bytedance_solo_piano(mode, instrument_name, stats):
    """Whether a part must retain ByteDance's transcription events verbatim.

    This deliberately keys off the successful result marker rather than the
    environment flag alone.  A requested ByteDance model that fell back to
    Basic Pitch must continue through the historical Piano pipeline.
    """
    return (
        mode == 'solo' and
        instrument_name == 'Piano' and
        stats.get('method') == 'bytedance_piano_experimental'
    )


def _transcribe_piano_bytedance(audio_path, midi_path):
    """Offline-capable Piano-only ByteDance transcription with native CC64.

    The model is intentionally optional. A missing package/checkpoint raises a
    clear RuntimeError so the caller can safely retain the existing Basic Pitch
    route. No Basic Pitch setting or non-Piano path is affected.
    """
    checkpoint = os.environ.get('AUGMENT_BYTEDANCE_PIANO_CHECKPOINT', '').strip()
    if not checkpoint or not os.path.isfile(checkpoint):
        raise RuntimeError('ByteDance Piano checkpoint is unavailable; set AUGMENT_BYTEDANCE_PIANO_CHECKPOINT.')
    try:
        import librosa
        import torch
        from piano_transcription_inference import PianoTranscription
    except ImportError as exc:
        raise RuntimeError('ByteDance Piano dependencies are unavailable; install piano-transcription-inference.') from exc
    device = 'cuda' if torch.cuda.is_available() else 'cpu'
    audio, _ = librosa.load(audio_path, sr=16000, mono=True)
    started = time.perf_counter()
    transcriber = PianoTranscription(device=device, checkpoint_path=checkpoint)
    result = transcriber.transcribe(audio, midi_path)
    performance = pretty_midi.PrettyMIDI(midi_path)
    notes = [note for track in performance.instruments for note in track.notes]
    pedals = [change for track in performance.instruments for change in track.control_changes
              if change.number == 64]
    return {
        'method': 'bytedance_piano_experimental',
        'processing_seconds': round(time.perf_counter() - started, 3),
        'device': device,
        'notes': len(notes),
        'predicted_cc64_events': len(pedals),
        'predicted_pedal_events': len(result.get('est_pedal_events', [])),
        'preserve_predicted_pedal': bool(pedals),
    }

# Do not silently change the production piano detector.  The experimental
# profile is evaluated separately through AUGMENT_PIANO_BASIC_PITCH_PROFILE or
# an explicit transcribe_stem() argument before it can become the default.
PIANO_BASIC_PITCH_PROFILES = {
    'current': {
        'onset_threshold': 0.50,
        'frame_threshold': 0.30,
        'minimum_note_length': 90,
    },
    'experimental': {
        'onset_threshold': 0.42,
        'frame_threshold': 0.26,
        'minimum_note_length': 55,
    },
}

# Held-out isolated-instrument evaluation shows that skyline selection and
# pYIN replacement remove genuine Basic Pitch attacks for these instruments.
# They deliberately retain the existing confidence/duration filter and range
# fitting; all other instruments keep the historical candidate-selection path.
FILTERED_BASIC_PITCH_INSTRUMENTS = frozenset({
    'Cello', 'Violin', 'Trumpet', 'Saxophone',
})


def _uses_filtered_basic_pitch_candidate(instrument_name, polyphonic):
    """Whether an evaluated instrument must stop before skyline/pYIN."""
    return not polyphonic and instrument_name in FILTERED_BASIC_PITCH_INSTRUMENTS
TUNINGS = {
    "Guitar": [40, 45, 50, 55, 59, 64],
    "Electric Guitar": [40, 45, 50, 55, 59, 64],
    "Bass Guitar": [28, 33, 38, 43],
    "Ukulele": [67, 60, 64, 69],
}

_MAJOR_KEY_NAMES = ('C', 'D-', 'D', 'E-', 'E', 'F',
                    'G-', 'G', 'A-', 'A', 'B-', 'B')
_MINOR_KEY_NAMES = ('C', 'C#', 'D', 'E-', 'E', 'F',
                    'F#', 'G', 'G#', 'A', 'B-', 'B')


def _preferred_key_name(pitch_class, mode):
    """Use the common enharmonic spelling with the smaller key signature."""
    names = _MINOR_KEY_NAMES if mode == 'minor' else _MAJOR_KEY_NAMES
    return names[int(pitch_class) % 12]


@dataclass
class Grid:
    bpm: float
    time_signature: str
    key_name: str
    key_mode: str = "major"
    beat_times: tuple = ()
    tempo_map: tuple = ()
    key_sections: tuple = ()
    chord_sections: tuple = ()

    @property
    def display_key(self):
        return f"{self.key_name} {self.key_mode}"

    def seconds_to_quarter(self, seconds):
        """Map audio time to musical beats while retaining local tempo drift."""
        if self.tempo_map:
            # Invert the same piecewise tempo map used by playback. Raw beat
            # detections and a smoothed playback map are different clocks.
            points = dict((float(p['offset']), float(p['bpm'])) for p in self.tempo_map)
            points.setdefault(0.0, float(self.bpm))
            elapsed = 0.0
            offset, bpm = 0.0, points[0.0]
            for next_offset, next_bpm in sorted(points.items()):
                if next_offset <= offset:
                    continue
                span = (next_offset - offset) * 60.0 / bpm
                if seconds <= elapsed + span:
                    return offset + (seconds - elapsed) * bpm / 60.0
                elapsed += span
                offset, bpm = next_offset, next_bpm
            return offset + (seconds - elapsed) * bpm / 60.0
        if len(self.beat_times) < 2:
            return seconds * self.bpm / 60.0
        first = self.beat_times[0]
        base = first * self.bpm / 60.0
        if seconds <= first:
            return seconds * self.bpm / 60.0
        index = bisect_right(self.beat_times, seconds) - 1
        if index >= len(self.beat_times) - 1:
            return base + index + (seconds - self.beat_times[index]) * self.bpm / 60.0
        left, right = self.beat_times[index], self.beat_times[index + 1]
        fraction = (seconds - left) / max(right - left, 1e-6)
        return base + index + fraction


def _tempo_map_from_beats(beat_times, fallback_bpm):
    """Build a compact, smoothed tempo map without reacting to single bad beats."""
    import numpy as np
    if len(beat_times) < 5:
        return ({'offset': 0.0, 'bpm': round(float(fallback_bpm), 2)},)
    bpms = 60.0 / np.maximum(np.diff(np.asarray(beat_times)), 1e-3)
    bpms = np.clip(bpms, 40.0, 240.0)
    smoothed = np.asarray([
        float(np.median(bpms[max(0, i - 2):min(len(bpms), i + 3)]))
        for i in range(len(bpms))
    ])
    points = [{'offset': 0.0, 'bpm': round(float(fallback_bpm), 2)}]
    last = float(fallback_bpm)
    for index in range(0, len(smoothed), 4):
        local = float(np.median(smoothed[index:index + 4]))
        if abs(local - last) / max(last, 1.0) >= 0.07:
            points.append({'offset': round(float(index), 3), 'bpm': round(local, 2)})
            last = local
    return tuple(points)


def _tonal_candidate(profile):
    """Return key/mode and a useful best-vs-runner-up confidence margin."""
    import numpy as np
    major = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
    minor = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])
    values = []
    for tonic in range(12):
        values.append((float(np.corrcoef(profile, np.roll(major, tonic))[0, 1]), tonic, 'major'))
        values.append((float(np.corrcoef(profile, np.roll(minor, tonic))[0, 1]), tonic, 'minor'))
    values.sort(reverse=True)
    score, tonic, mode = values[0]
    return tonic, mode, round(max(0.0, score - values[1][0]), 3)


def _chord_candidate(profile, extended=False):
    """Infer a conservative major/minor triad from a local chroma profile."""
    import numpy as np
    scores = []
    total = max(float(np.sum(profile)), 1e-9)
    normalized = np.asarray(profile) / total
    templates = [('major', (0, 4, 7)), ('minor', (0, 3, 7))]
    if extended:
        templates += [('dom7', (0, 4, 7, 10)), ('maj7', (0, 4, 7, 11)),
                      ('min7', (0, 3, 7, 10)), ('sus2', (0, 2, 7)),
                      ('sus4', (0, 5, 7)), ('dim', (0, 3, 6))]
    for root in range(12):
        for quality, intervals in templates:
            tones = tuple((root + interval) % 12 for interval in intervals)
            score = float(sum(normalized[t] for t in tones))
            if extended:
                score -= .035 * max(0, len(tones) - 3)
                score += .02 * float(normalized[root])
            scores.append((score, root, quality, tones))
    scores.sort(reverse=True)
    score, root, quality, tones = scores[0]
    confidence = max(0.0, score - scores[1][0])
    return root, quality, tones, round(confidence, 3)


def _chord_window_beats(time_signature):
    """Return beat-tracker pulses per bar for chord analysis.

    The beat tracker follows quarter-note pulses for simple meters and
    dotted-quarter pulses for compound x/8 meters.  This keeps a 3/4 song at
    three pulses per bar instead of averaging a four-beat chord window across
    two harmony changes.
    """
    try:
        numerator, denominator = (int(value) for value in time_signature.split('/', 1))
    except (AttributeError, TypeError, ValueError):
        return 4
    if denominator == 8 and numerator >= 6 and numerator % 3 == 0:
        return max(1, numerator // 3)
    return max(1, numerator)


def _detect_time_signature(onset_env, beat_frames):
    """Infer simple, compound, and odd meter from beat-accent periodicity."""
    import numpy as np

    valid_frames = [int(frame) for frame in beat_frames
                    if 0 <= int(frame) < len(onset_env)]
    strengths = np.asarray([float(onset_env[frame]) for frame in valid_frames])
    if len(strengths) < 6 or float(np.std(strengths)) < 1e-7:
        return '4/4', 0.0
    strengths = (strengths - float(np.mean(strengths))) / max(float(np.std(strengths)), 1e-7)

    scores = {}
    # Longer accent cycles are usually phrase structure (for example, three
    # 4/4 bars), not a literal 12/4 measure. Compound 9/8 and 12/8 are still
    # represented through three or four dotted-quarter pulses below.
    for pulse_count in range(2, 8):
        if len(strengths) < pulse_count * 3:
            continue
        phase_scores = []
        for phase in range(pulse_count):
            mask = np.arange(len(strengths)) % pulse_count == phase
            accented, remaining = strengths[mask], strengths[~mask]
            if len(accented) < 3 or not len(remaining):
                continue
            standard_error = np.sqrt(
                np.var(accented) / len(accented) +
                np.var(remaining) / len(remaining) + 1e-6
            )
            phase_scores.append(
                (float(np.mean(accented)) - float(np.mean(remaining))) /
                max(float(standard_error), 0.18)
            )
        if phase_scores:
            # Longer cycles need stronger evidence because they can overfit a
            # handful of unusually loud beats.
            scores[pulse_count] = max(phase_scores) - max(0, pulse_count - 4) * 0.08
    if not scores:
        return '4/4', 0.0
    scores[4] = scores.get(4, 0.0) + 0.14
    scores[3] = scores.get(3, 0.0) + 0.05
    pulse_count = max(scores, key=scores.get)
    ordered_scores = sorted(scores.values(), reverse=True)
    confidence = ordered_scores[0] - ordered_scores[1] if len(ordered_scores) > 1 else 0.0

    # A beat tracker follows dotted-quarter pulses in compound meter. Compare
    # onset energy at thirds of each tracked beat against the halfway point.
    thirds, halves = [], []
    for left, right in zip(valid_frames, valid_frames[1:]):
        width = right - left
        if width < 6:
            continue
        thirds.extend((onset_env[left + width // 3], onset_env[left + 2 * width // 3]))
        halves.append(onset_env[left + width // 2])
    compound = (
        pulse_count in (2, 3, 4) and thirds and halves and
        float(np.mean(thirds)) > float(np.mean(halves)) * 1.12
    )
    if compound:
        return f'{pulse_count * 3}/8', round(float(confidence), 3)
    return f'{pulse_count}/4', round(float(confidence), 3)


def run_demucs(audio_path, output_dir, extended=False):
    """Separate the mix, using instrument-specific stems for Band mode."""
    requested_model = 'htdemucs_6s' if extended else 'htdemucs'
    try:
        subprocess.run([
            sys.executable, "-m", "demucs.separate", "-n", requested_model,
            "-o", output_dir, audio_path,
        ], check=True)
    except subprocess.CalledProcessError:
        if not extended:
            raise
        requested_model = 'htdemucs'
        subprocess.run([
            sys.executable, "-m", "demucs.separate", "-n", requested_model,
            "-o", output_dir, audio_path,
        ], check=True)
    song = os.path.splitext(os.path.basename(audio_path))[0]
    preferred_path = os.path.join(output_dir, requested_model, song)
    candidates = [preferred_path] + [
        os.path.join(output_dir, model, song)
        for model in os.listdir(output_dir)
        if model != requested_model
    ]
    for path in candidates:
        if os.path.isfile(os.path.join(path, "vocals.wav")):
            return path
    raise FileNotFoundError(f"Demucs stems not found under {output_dir}")


def _instrument_specific_stem(name, stem_dir):
    """Return a confidently present stem for instruments Demucs can isolate."""
    stem_name = {
        'Piano': 'piano', 'Synthesizer': 'piano', 'Organ': 'piano',
        'Guitar': 'guitar', 'Electric Guitar': 'guitar', 'Ukulele': 'guitar',
    }.get(name)
    if not stem_name:
        return None
    path = os.path.join(stem_dir, f'{stem_name}.wav')
    if not os.path.exists(path):
        return None
    other_path = os.path.join(stem_dir, 'other.wav')
    energy = _audio_rms(path)
    other_energy = _audio_rms(other_path) if os.path.exists(other_path) else 0.0
    # Six-source separation always creates the file, even when the instrument
    # is absent. Require useful energy before treating it as a real source.
    if energy < max(0.0015, other_energy * 0.025):
        return None
    return stem_name


def _band_source_for_part(name, role, stem_dir):
    """Choose a Band source by musical role before instrument identity.

    A selected Band instrument is the *performer* of the assigned role, not
    proof that the uploaded song already contains that instrument.  Melody
    must therefore follow vocals/lead, bass must follow the bass stem, and
    drums must follow drums.  Only harmony/chord players may prefer a clearly
    present matching Piano/Guitar stem.
    """
    normalized_role = str(role or 'harmony').lower()
    role_stem = ROLES.get(normalized_role, normalized_role)
    matched = None
    if normalized_role in ('harmony', 'chords'):
        matched = _instrument_specific_stem(name, stem_dir)
    return matched or role_stem, matched


def _audio_rms(path):
    """Measure stem energy without loading an entire song into memory."""
    import numpy as np
    import soundfile as sf

    energy = 0.0
    samples = 0
    for block in sf.blocks(path, blocksize=65536, always_2d=True):
        energy += float(np.sum(block * block))
        samples += block.size
    return (energy / samples) ** 0.5 if samples else 0.0


def _role_source_fallback(stem, stem_dir):
    """Avoid transcribing a near-empty role stem as an instrumental part.

    This selects a role source, not a claim of instrument recognition.
    """
    if stem not in ('vocals', 'bass'):
        return stem
    candidates = {name: _audio_rms(os.path.join(stem_dir, name + '.wav'))
                  for name in (stem, 'other', 'piano', 'guitar')
                  if os.path.exists(os.path.join(stem_dir, name + '.wav'))}
    if not candidates:
        return stem
    strongest = max(candidates, key=candidates.get)
    if candidates.get(stem, 0) < max(.002, candidates[strongest] * .05):
        return strongest
    return stem


def analyze_grid(audio_path, extended_harmony=False):
    """Detect a shared tempo, meter and major/minor key from the original mix."""
    import librosa
    import numpy as np
    y, sr = librosa.load(audio_path, sr=22050, mono=True)
    onset_env = librosa.onset.onset_strength(y=y, sr=sr)
    bpm, beat_frames = librosa.beat.beat_track(y=y, sr=sr)
    bpm = float(bpm[0] if hasattr(bpm, "__len__") else bpm) or 120.0
    while bpm < 55:
        bpm *= 2
    while bpm > 200:
        bpm /= 2
    # Keep the pulse selected by the beat tracker. Reinterpreting it as
    # half-time or double-time changes playback feel even when mathematically
    # equivalent notation could be produced at either tempo.
    beat_times = tuple(float(value) for value in librosa.frames_to_time(beat_frames, sr=sr))
    signature, _ = _detect_time_signature(onset_env, beat_frames)
    chroma = librosa.feature.chroma_cqt(y=y, sr=sr)
    profile = chroma.mean(axis=1)
    profile /= max(float(profile.sum()), 1e-9)
    tonic, key_mode, key_confidence = _tonal_candidate(profile)
    key_name = _preferred_key_name(tonic, key_mode)
    tempo_map = _tempo_map_from_beats(beat_times, bpm)

    # Analyze tonal context in phrase-sized windows. A single global key is
    # retained for compatibility, while sections prevent accompaniment parts
    # from being forced through one key/chord for an entire song.
    duration = len(y) / sr
    phrase_seconds = max(4.0, 16.0 * 60.0 / bpm)
    key_sections, chord_sections = [], []
    for start in np.arange(0.0, duration, phrase_seconds):
        end = min(duration, float(start + phrase_seconds))
        left = int(librosa.time_to_frames(start, sr=sr))
        right = max(left + 1, int(librosa.time_to_frames(end, sr=sr)))
        local = chroma[:, left:right].mean(axis=1)
        if float(local.sum()) <= 1e-9:
            continue
        local /= float(local.sum())
        local_tonic, local_mode, local_conf = _tonal_candidate(local)
        key_sections.append({
            'start_seconds': round(float(start), 3), 'end_seconds': round(end, 3),
            'offset': round(float(start * bpm / 60.0), 3),
            'key': _preferred_key_name(local_tonic, local_mode),
            'mode': local_mode, 'confidence': local_conf,
        })
    # Chords change faster than keys. Analyse one detected bar at a time.
    # The previous fixed four-beat window incorrectly averaged 3/4 bars with
    # the following harmony.
    chord_seconds = max(1.0, _chord_window_beats(signature) * 60.0 / bpm)
    for start in np.arange(0.0, duration, chord_seconds):
        end = min(duration, float(start + chord_seconds))
        left = int(librosa.time_to_frames(start, sr=sr))
        right = max(left + 1, int(librosa.time_to_frames(end, sr=sr)))
        local = chroma[:, left:right].mean(axis=1)
        if float(local.sum()) <= 1e-9:
            continue
        root, quality, tones, chord_conf = _chord_candidate(local, extended=extended_harmony)
        chord_sections.append({
            'start_seconds': round(float(start), 3), 'end_seconds': round(end, 3),
            'root_pc': root, 'quality': quality, 'tones': list(tones),
            'confidence': chord_conf,
        })
    if key_sections:
        key_sections[0]['global_confidence'] = key_confidence
    return Grid(
        round(bpm, 2), signature, key_name, key_mode, beat_times,
        tempo_map, tuple(key_sections), tuple(chord_sections),
    )


def _monophonic(midi, preserve_attacks=False, preserve_releases=False):
    """Keep one continuous lead line without discarding overlapping onsets.

    Neural transcription often overlaps adjacent notes by a few milliseconds.
    The old approach dropped every later overlap, which made melodies sound
    sparse. This skyline pass selects one active note for each time segment,
    then joins adjacent matching segments into a playable single voice.
    """
    candidates = [
        n for inst in midi.instruments for n in inst.notes
        if n.velocity >= 35 and n.end - n.start >= 0.07
    ]
    if preserve_attacks:
        groups = []
        for event in sorted(candidates, key=lambda n: (n.start, n.pitch)):
            if groups and event.start - groups[-1][0].start <= .02:
                groups[-1].append(event)
            else:
                groups.append([event])
        selected = []
        for group in groups:
            previous = selected[-1].pitch if selected else None
            source = min(group, key=lambda n: (
                abs(n.pitch - previous) > 14 if previous is not None else False,
                -n.velocity,
                abs(n.pitch - previous) if previous is not None else 0))
            if selected and selected[-1].end > source.start:
                selected[-1].end = source.start
            selected.append(pretty_midi.Note(source.velocity, source.pitch, source.start, source.end))
        solo = pretty_midi.Instrument(40, name='Band selected melody')
        solo.notes = selected
        midi.instruments = [solo]
        return midi
    boundaries = sorted({time for n in candidates for time in (n.start, n.end)})
    result = []
    previous_pitch = None
    previous_source = None
    for start, end in zip(boundaries, boundaries[1:]):
        if end - start < 0.025:
            continue
        active = [n for n in candidates if n.start < end and n.end > start]
        if not active:
            continue
        def rank(current):
            if previous_pitch is None:
                return (-current.velocity, -current.pitch)
            interval = abs(current.pitch - previous_pitch)
            return (interval > 14, interval, -current.velocity, -current.pitch)
        selected = min(active, key=rank)
        if (result and result[-1].pitch == selected.pitch and
                start - result[-1].end <= 0.06 and
                (not (preserve_attacks or preserve_releases) or selected is previous_source)):
            result[-1].end = end
        else:
            result.append(pretty_midi.Note(
                velocity=selected.velocity,
                pitch=selected.pitch,
                start=start,
                end=end,
            ))
        previous_pitch = selected.pitch
        previous_source = selected

    # Neural note boundaries often contain a few milliseconds of silence even
    # within one sustained phrase. Close only tiny gaps so the melody remains
    # readable while avoiding artificial ties across real rests.
    for previous, following in zip(result, result[1:]):
        gap = following.start - previous.end
        if not preserve_releases and 0 < gap <= 0.14:
            previous.end = following.start
    solo = pretty_midi.Instrument(program=40, name="Solo melody")
    solo.notes = result
    midi.instruments = [solo]
    return midi


def _clean_lead_contour(midi_path, pitch_range):
    """Remove only isolated lead-tracker errors using neighbour look-ahead.

    Consecutive downward notes are retained as a real phrase. A middle note is
    changed only when both neighbours agree and it is either an octave alias
    or an extremely brief, remote pitch likely leaked from accompaniment.
    """
    midi = pretty_midi.PrettyMIDI(midi_path)
    notes = sorted(
        (event for track in midi.instruments for event in track.notes),
        key=lambda event: (event.start, event.pitch),
    )
    if len(notes) < 3:
        return {'octave_corrections': 0, 'rejected_lead_spikes': 0}
    low, high = pitch_range
    octave_corrections = 0
    rejected = set()
    for index in range(1, len(notes) - 1):
        previous, current, following = notes[index - 1:index + 2]
        if (abs(previous.pitch - following.pitch) > 3 or
                current.start - previous.end > 0.20 or
                following.start - current.end > 0.20):
            continue
        original_distance = (
            abs(current.pitch - previous.pitch) +
            abs(current.pitch - following.pitch)
        )
        octave_candidates = [
            pitch for pitch in (current.pitch - 12, current.pitch + 12)
            if low <= pitch <= high
        ]
        if octave_candidates:
            replacement = min(
                octave_candidates,
                key=lambda pitch: abs(pitch - previous.pitch) + abs(pitch - following.pitch),
            )
            replacement_distance = (
                abs(replacement - previous.pitch) +
                abs(replacement - following.pitch)
            )
            if original_distance >= 22 and replacement_distance <= 6:
                current.pitch = replacement
                octave_corrections += 1
                continue
        # Reject only a very short isolated spike. Longer lower notes and a
        # sequence of descending pitches are musical evidence and stay intact.
        if current.end - current.start <= 0.22 and original_distance >= 16:
            rejected.add(id(current))
            previous.end = max(previous.end, min(following.start, current.end))
    if rejected:
        for track in midi.instruments:
            track.notes = [event for event in track.notes if id(event) not in rejected]
    midi.write(midi_path)
    return {
        'octave_corrections': octave_corrections,
        'rejected_lead_spikes': len(rejected),
    }


def _melody_contour_instability(midi):
    """Measure implausible jumps in a monophonic melody candidate."""
    events = sorted(
        (event for track in midi.instruments for event in track.notes),
        key=lambda event: (event.start, event.end),
    )
    if len(events) < 2:
        return 1.0
    penalty = 0.0
    for previous, current in zip(events, events[1:]):
        leap = abs(current.pitch - previous.pitch)
        if leap > 7:
            penalty += 1.0
        if leap > 12:
            penalty += 1.0
    return penalty / (len(events) - 1)


def _prefer_pyin_lead(pyin_alignment, basic_alignment, margin=0.07,
                      pyin_instability=None, basic_instability=None):
    """Prefer a stable lead unless the alternate is both cleaner and closer."""
    if (pyin_instability is not None and basic_instability is not None and
            basic_alignment >= pyin_alignment and
            basic_instability + 0.025 < pyin_instability):
        return False
    return pyin_alignment + margin >= basic_alignment


def _fit_midi_candidates_to_range(midi, pitch_range):
    """Prepare candidates for contour selection without importing bass lines."""
    if not pitch_range:
        return 0
    low, high = pitch_range
    removed = 0
    for track in midi.instruments:
        fitted = []
        for event in track.notes:
            pitch = event.pitch
            # Permit one neighbouring octave so a genuine melody crossing an
            # instrument boundary can be arranged into range. Notes farther
            # away are a different voice (usually bass/accompaniment).
            if pitch < low - 12 or pitch > high + 12:
                removed += 1
                continue
            while pitch < low:
                pitch += 12
            while pitch > high:
                pitch -= 12
            event.pitch = pitch
            fitted.append(event)
        track.notes = fitted
    return removed


def _recover_short_piano_lead(track, times, pitches, probabilities, valid):
    """Recover short stable pitch runs only inside an established lead phrase.

    Raw pitch evidence, rather than interpolated silence, must support every
    recovered frame. No new attacks are inferred
    from an unchanged pitch: repeated-note recovery needs separate onset data.
    """
    import numpy as np
    from scipy.ndimage import median_filter

    notes = sorted(track.notes, key=lambda n: n.start)
    if len(notes) < 2 or len(times) < 2:
        return []
    step = float(times[1] - times[0])
    finite = np.isfinite(pitches)
    rounded = np.rint(np.where(finite, pitches, -1000)).astype(int)
    stable = median_filter(rounded, size=3)
    evidence = finite & valid & (probabilities >= .60) & (rounded == stable)
    runs = []
    start = 0
    while start < len(times):
        if not evidence[start]:
            start += 1
            continue
        end = start + 1
        while end < len(times) and evidence[end] and stable[end] == stable[start]:
            end += 1
        duration = (end - start) * step
        if end - start >= 3 and .055 <= duration < .16:
            runs.append((float(times[start]), float(times[end - 1] + step),
                         int(stable[start]), float(np.mean(probabilities[start:end]))))
        start = end
    recovered = []
    # A seven-frame smoother can extend the preceding note over a short pitch
    # change. Recover that change only when confident raw frames establish the
    # preceding AND following pitches. Correct just the erroneous held release.
    for onset, release, pitch_value, confidence in runs:
        held = next((n for n in notes if n.start < onset < n.end
                     and n.pitch != pitch_value), None)
        following = next((n for n in notes if n.start >= release), None)
        if held is None or following is None or following.start - release > .10:
            continue
        if held.end > following.start or held.end - onset > .20:
            continue
        if any(n.pitch == pitch_value and n.start < release and n.end > onset for n in notes):
            continue
        before_mask = (times >= onset - .07) & (times < onset)
        after_mask = (times >= release) & (times < release + .07)
        def supports(mask, pitch):
            indices = np.flatnonzero(mask & evidence)
            return len(indices) >= 2 and np.mean(stable[indices] == pitch) >= .8
        if not (supports(before_mask, held.pitch) and supports(after_mask, following.pitch)):
            continue
        if abs(pitch_value - held.pitch) > 5 or abs(pitch_value - following.pitch) > 5:
            continue
        if held.pitch == following.pitch and abs(pitch_value - held.pitch) > 4:
            continue
        if onset - held.start < .055:
            continue
        held.end = onset
        track.notes.append(pretty_midi.Note(
            velocity=max(55, min(110, round(confidence * 127))),
            pitch=pitch_value, start=onset, end=release))
        recovered.append({'start': onset, 'end': release, 'pitch': pitch_value,
                          'confidence': confidence, 'source': 'supported_pyin_frames',
                          'preceding_release_corrected': True})
    for previous, following in zip(notes, notes[1:]):
        # Longer gaps can be real phrase rests; this pass only repairs a fast
        # run between known notes, with supported evidence connecting both sides.
        if not .055 <= following.start - previous.end <= .60:
            continue
        path = [r for r in runs if r[0] >= previous.end and r[1] <= following.start]
        if not path:
            continue
        chain = [(previous.start, previous.end, previous.pitch, 1.)] + path + [
            (following.start, following.end, following.pitch, 1.)]
        if any(b[0] - a[1] > .075 or abs(b[2] - a[2]) > 7
               for a, b in zip(chain, chain[1:])):
            continue
        for index, run in enumerate(path, 1):
            if any(abs(r['start'] - run[0]) < 1e-6 for r in recovered):
                continue
            before, after = chain[index - 1], chain[index + 1]
            if run[2] == before[2] or run[2] == after[2]:
                continue
            # A short upward/downward spike returning to its starting pitch
            # needs stronger evidence than this recovery pass can provide.
            if before[2] == after[2] and abs(run[2] - before[2]) > 4:
                continue
            onset, release, pitch_value, confidence = run
            track.notes.append(pretty_midi.Note(
                velocity=max(55, min(110, round(confidence * 127))),
                pitch=pitch_value, start=onset, end=release))
            recovered.append({'start': onset, 'end': release, 'pitch': pitch_value,
                              'confidence': confidence, 'source': 'supported_pyin_frames'})
    track.notes.sort(key=lambda n: (n.start, n.pitch))
    return recovered


def _transcribe_vocal_melody(audio_path, midi_path, pitch_range=None,
                             harmonic_focus=False, recover_short_piano=False):
    """Track one dominant lead line with pYIN before score cleanup."""
    import librosa
    import numpy as np
    from scipy.ndimage import median_filter

    y, sr = librosa.load(audio_path, sr=22050, mono=True)
    pitch_audio = (librosa.effects.harmonic(y, margin=2.0)
                   if harmonic_focus else y)
    hop = 512
    low_midi, high_midi = pitch_range or (40, 84)
    f0, voiced, probabilities = librosa.pyin(
        pitch_audio,
        fmin=librosa.midi_to_hz(max(21, low_midi - 5)),
        fmax=librosa.midi_to_hz(min(108, high_midi + 5)),
        sr=sr,
        hop_length=hop,
    )
    rms = librosa.feature.rms(y=y, frame_length=2048, hop_length=hop)[0]
    frame_count = min(len(f0), len(rms))
    f0, probabilities, rms = f0[:frame_count], probabilities[:frame_count], rms[:frame_count]
    # Keep confident pitch frames, plus softer pitched frames that still have
    # clear vocal energy. This recovers breathy violin melody notes without
    # admitting low-energy stem leakage as new notes.
    energy_floor = max(float(np.percentile(rms, 30)) * 0.65, 0.002)
    pitched = ~np.isnan(f0)
    valid = pitched & (
        (probabilities >= 0.50) |
        ((probabilities >= 0.34) & (rms >= energy_floor))
    )
    # pYIN can briefly lose a sustained pitch at consonants or during soft
    # vibrato. Fill only short, energetic gaps enclosed by reliable melody.
    gap_start = None
    maximum_gap_frames = max(1, round(0.23 * sr / hop))
    for index, is_valid in enumerate(valid):
        if not is_valid and gap_start is None:
            gap_start = index
        elif is_valid and gap_start is not None:
            gap_length = index - gap_start
            bounded = gap_start > 0 and valid[gap_start - 1]
            energetic = float(np.mean(rms[gap_start:index])) >= energy_floor
            if bounded and energetic and gap_length <= maximum_gap_frames:
                valid[gap_start:index] = True
            gap_start = None
    if int(valid.sum()) < 12:
        raise ValueError('Vocal pitch tracker found too little reliable signal')
    midi_values = np.full(len(f0), np.nan)
    pitch_known = valid & pitched
    midi_values[pitch_known] = librosa.hz_to_midi(f0[pitch_known])
    # Median filtering keeps vibrato from turning into many artificial notes.
    known = np.flatnonzero(pitch_known)
    filled = np.interp(np.arange(len(midi_values)), known, midi_values[known])
    smoothed = median_filter(filled, size=7)
    times = librosa.frames_to_time(np.arange(len(f0)), sr=sr, hop_length=hop)
    output = pretty_midi.PrettyMIDI()
    track = pretty_midi.Instrument(program=40, name='Vocal melody')
    start = None
    current_pitch = None
    confidence_values = []
    silence_start = None
    for index, time in enumerate(times):
        if not valid[index]:
            if start is not None and silence_start is None:
                silence_start = float(time)
            # Brief unvoiced frames happen inside breathy phrases and vibrato.
            if start is not None and time - silence_start < 0.23:
                continue
            if start is not None and silence_start - start >= 0.14:
                track.notes.append(pretty_midi.Note(
                    velocity=max(55, min(110, int(np.mean(confidence_values) * 127))),
                    pitch=current_pitch, start=start, end=silence_start,
                ))
            start, current_pitch, confidence_values, silence_start = None, None, [], None
            continue
        silence_start = None
        pitch_value = int(round(smoothed[index]))
        # A new note must persist for at least three analysis frames; brief
        # pitch changes are treated as vibrato or a slide on the same note.
        if start is None:
            start, current_pitch = float(time), pitch_value
        elif pitch_value != current_pitch and index + 2 < len(times):
            upcoming = smoothed[index:index + 3]
            if np.all(np.abs(upcoming - pitch_value) < 0.5):
                if time - start >= 0.14:
                    track.notes.append(pretty_midi.Note(
                        velocity=max(55, min(110, int(np.mean(confidence_values) * 127))),
                        pitch=current_pitch, start=start, end=float(time),
                    ))
                start, current_pitch, confidence_values = float(time), pitch_value, []
        confidence_values.append(float(np.nan_to_num(
            probabilities[index], nan=0.40)))
    if start is not None and times[-1] - start >= 0.14:
        track.notes.append(pretty_midi.Note(
            velocity=max(55, min(110, int(np.mean(confidence_values) * 127))),
            pitch=current_pitch, start=start, end=float(times[-1]),
        ))
    if not track.notes:
        raise ValueError('Vocal pitch tracker did not produce playable notes')
    recovered = []
    if recover_short_piano:
        raw_pitch = np.full(len(f0), np.nan)
        raw_pitch[pitched] = librosa.hz_to_midi(f0[pitched])
        recovered = _recover_short_piano_lead(
            track, times, raw_pitch, np.nan_to_num(probabilities), valid)
    output.instruments.append(track)
    output.write(midi_path)
    return {'notes': len(track.notes), 'method': 'pyin',
            **({'short_piano_notes_recovered': recovered} if recover_short_piano else {})}


def _basic_pitch_profile(instrument_name, requested_profile=None, polyphonic=False):
    """Return a named detector profile without widening other instruments."""
    if instrument_name not in ('Piano', 'Synthesizer', 'Organ'):
        return 'current', {
            'onset_threshold': 0.50 if polyphonic else 0.58,
            'frame_threshold': 0.30,
            'minimum_note_length': 90,
        }
    profile_name = (requested_profile or
                    os.environ.get('AUGMENT_PIANO_BASIC_PITCH_PROFILE', 'current')).lower()
    if profile_name not in PIANO_BASIC_PITCH_PROFILES:
        profile_name = 'current'
    return profile_name, dict(PIANO_BASIC_PITCH_PROFILES[profile_name])


def _write_detector_debug_artifact(midi_path, note_events, profile_name):
    """Persist raw Basic Pitch events only when transcription debugging is on."""
    if os.environ.get('AUGMENT_DEBUG_TRANSCRIPTION') != '1':
        return None
    rows = []
    for event in sorted(note_events, key=lambda value: (value[0], value[2])):
        onset, offset, pitch, confidence = event[:4]
        rows.append({
            'pitch': int(pitch),
            'onset_seconds': round(float(onset), 6),
            'offset_seconds': round(float(offset), 6),
            'duration_seconds': round(float(offset - onset), 6),
            # Basic Pitch encodes its event confidence into MIDI velocity.
            # The raw model confidence is retained separately below.
            'velocity': max(1, min(127, round(float(confidence) * 127))),
            'confidence': round(float(confidence), 6),
        })
    path = midi_path + '.detector.json'
    with open(path, 'w', encoding='utf-8') as handle:
        json.dump({
            'profile': profile_name,
            'event_count': len(rows),
            'events': rows,
        }, handle, indent=2)
    return path


def transcribe_stem(audio_path, midi_path, polyphonic, prefer_pyin=False,
                    melody_range=None, harmonic_focus=False, instrument_name=None,
                    detector_profile=None, recover_short_piano=False,
                    preserve_attacks=False):
    """Basic Pitch transcription, with a confidence/no-signal guard."""
    import numpy as np
    import librosa
    y, _ = librosa.load(audio_path, sr=22050, mono=True)
    rms = float(np.sqrt(np.mean(y * y))) if len(y) else 0.0
    if rms < 1e-4:
        raise ValueError(f"Stem is too quiet to transcribe: {audio_path}")
    pyin_path = None
    pyin_stats = None
    use_filtered_basic_pitch = _uses_filtered_basic_pitch_candidate(
        instrument_name, polyphonic)
    if prefer_pyin and not polyphonic and not use_filtered_basic_pitch:
        try:
            pyin_path = midi_path + '.pyin.mid'
            pyin_stats = _transcribe_vocal_melody(
                audio_path, pyin_path, pitch_range=melody_range,
                harmonic_focus=harmonic_focus,
                recover_short_piano=recover_short_piano,
            )
        except (ValueError, RuntimeError):
            pyin_path, pyin_stats = None, None
    from basic_pitch.inference import predict
    # Solo parts favour precision over recall. Basic Pitch's residual-note
    # recovery is helpful for chords, but creates many false melody notes.
    high_recall_vocal = prefer_pyin and not polyphonic
    profile_name, profile = _basic_pitch_profile(
        instrument_name, detector_profile, polyphonic)
    # Keep the existing non-piano behavior. Only Piano/Synthesizer/Organ may
    # opt into the measured experimental profile.
    if instrument_name not in ('Piano', 'Synthesizer', 'Organ'):
        profile.update({
            'onset_threshold': 0.42 if high_recall_vocal else 0.58,
            'frame_threshold': 0.18 if high_recall_vocal else 0.30,
            'minimum_note_length': 80 if high_recall_vocal else 120,
        })
    _, midi, note_events = predict(
        audio_path,
        # Vocal stems often have soft consonants and breathy note attacks.
        # These settings recover them, then the monophonic cleanup removes
        # overlaps before notation is made.
        onset_threshold=profile['onset_threshold'],
        frame_threshold=profile['frame_threshold'],
        minimum_note_length=profile['minimum_note_length'],
        multiple_pitch_bends=False,
        melodia_trick=polyphonic,
    )
    raw_notes = sum(len(inst.notes) for inst in midi.instruments)
    detector_debug_path = _write_detector_debug_artifact(
        midi_path, note_events, profile_name)
    if not polyphonic:
        for inst in midi.instruments:
            inst.notes = [
                n for n in inst.notes
                if n.velocity >= 38 and n.end - n.start >= 0.08
            ]
        rejected_out_of_voice = _fit_midi_candidates_to_range(
            midi, melody_range,
        )
    else:
        rejected_out_of_voice = 0
    notes = sum((len(i.notes) for i in midi.instruments), 0)
    confidence = float(np.mean([event[3] for event in note_events])) if note_events else None
    if notes == 0:
        raise ValueError(f"No confident notes detected in {audio_path}")
    if not polyphonic and not use_filtered_basic_pitch:
        midi = _monophonic(midi, preserve_attacks=preserve_attacks,
                           preserve_releases=instrument_name in {'Flute', 'Saxophone'})
    midi.write(midi_path)
    selected_note_count = sum(len(i.notes) for i in midi.instruments)
    basic_stats = {
        "notes": selected_note_count, "raw_notes": raw_notes, "rms": rms,
        "confidence": confidence, "method": "basic_pitch",
        "rejected_out_of_voice": rejected_out_of_voice,
        "detector_profile": profile_name,
        "candidate_policy": (
            'filtered_basic_pitch' if use_filtered_basic_pitch else 'existing'),
    }

    if pyin_path and pyin_stats:
        try:
            pyin_midi = pretty_midi.PrettyMIDI(pyin_path)
            pyin_rejected = _fit_midi_candidates_to_range(
                pyin_midi, melody_range,
            )
            pyin_midi.write(pyin_path)
            pyin_stats['rejected_out_of_voice'] = pyin_rejected
            pyin_stats['notes'] = sum(
                len(track.notes) for track in pyin_midi.instruments
            )
            pyin_validation = validate_transcription(audio_path, pyin_path)
            basic_validation = validate_transcription(audio_path, midi_path)
            pyin_alignment = pyin_validation.get('alignment_confidence') or 0.0
            basic_alignment = basic_validation.get('alignment_confidence') or 0.0
            pyin_instability = _melody_contour_instability(pyin_midi)
            basic_instability = _melody_contour_instability(midi)
            # Spectral alignment can favour busy transcriptions because
            # extra harmonics can match the source even when they are not the
            # sung tune. Prefer pYIN's continuous lead unless Basic Pitch is
            # materially better, not merely a few hundredths higher.
            selection_margin = 0.14 if harmonic_focus else 0.07
            use_pyin = _prefer_pyin_lead(
                pyin_alignment, basic_alignment, margin=selection_margin,
                pyin_instability=pyin_instability,
                basic_instability=basic_instability,
            )
            selected_stats = pyin_stats if use_pyin else basic_stats
            selected_validation = pyin_validation if use_pyin else basic_validation
            selected_stats.update(selected_validation)
            if use_pyin:
                shutil.copy2(pyin_path, midi_path)
            selected_stats.update({
                'rms': rms,
                'alignment_confidence': (
                    pyin_alignment if use_pyin else basic_alignment),
                'candidates': {'pyin': pyin_alignment, 'basic_pitch': basic_alignment},
                'candidate_contour_instability': {
                    'pyin': round(pyin_instability, 4),
                    'basic_pitch': round(basic_instability, 4),
                },
                'method': 'pyin' if use_pyin else 'basic_pitch',
                'selection_margin': selection_margin,
            })
            if selected_validation.get('warning'):
                selected_stats['warning'] = selected_validation['warning']
            os.remove(pyin_path)
            return selected_stats
        except (OSError, RuntimeError, ValueError):
            if os.path.exists(pyin_path):
                os.remove(pyin_path)
    return basic_stats


def transcribe_drum_stem(audio_path, midi_path, layered=False):
    """Create a compact GM percussion track from a separated drum stem."""
    import librosa
    import numpy as np
    if layered:
        from band_performance import transcribe_layered_drums
        return transcribe_layered_drums(audio_path, midi_path)

    y, sr = librosa.load(audio_path, sr=22050, mono=True)
    if not len(y) or float(np.sqrt(np.mean(y * y))) < 1e-4:
        raise ValueError(f"Drum stem is too quiet to transcribe: {audio_path}")
    hop = 256
    onset_env = librosa.onset.onset_strength(y=y, sr=sr, hop_length=hop)
    frames = librosa.onset.onset_detect(
        onset_envelope=onset_env, sr=sr, hop_length=hop,
        backtrack=False, units='frames', wait=2, delta=0.12,
    )
    centroid = librosa.feature.spectral_centroid(y=y, sr=sr, hop_length=hop)[0]
    output = pretty_midi.PrettyMIDI()
    track = pretty_midi.Instrument(program=0, is_drum=True, name='Drums')
    for frame in frames:
        frame = min(int(frame), len(centroid) - 1)
        brightness = float(centroid[frame])
        pitch = 36 if brightness < 1400 else (42 if brightness > 4200 else 38)
        start = float(librosa.frames_to_time(frame, sr=sr, hop_length=hop))
        strength = float(onset_env[min(frame, len(onset_env) - 1)])
        velocity = max(45, min(120, int(55 + strength * 14)))
        track.notes.append(pretty_midi.Note(
            velocity=velocity, pitch=pitch, start=start, end=start + 0.10,
        ))
    if not track.notes:
        raise ValueError('No confident drum hits detected')
    output.instruments.append(track)
    output.write(midi_path)
    return {'notes': len(track.notes), 'method': 'percussion-onsets'}


def _part_voice_settings(name, role, piano_arrangement=False):
    """Return detector settings that match what the instrument can play."""
    chordal_instrument = name in (
        'Piano', 'Synthesizer', 'Organ',
        'Guitar', 'Electric Guitar', 'Ukulele',
    )
    monophonic_harmony = role in ('harmony', 'chords') and not chordal_instrument
    return {
        'polyphonic': piano_arrangement or (
            chordal_instrument and role in ('harmony', 'chords')
        ),
        'prefer_pyin': not piano_arrangement and (
            role in ('melody', 'lead') or monophonic_harmony
        ),
    }


def _write_debug_artifacts(stem_path, midi_path, output_dir, label):
    """Save listenable checkpoints when debugging a bad melody extraction."""
    if os.environ.get('AUGMENT_DEBUG_TRANSCRIPTION') != '1':
        return {}
    from scipy.io import wavfile
    import numpy as np

    debug_dir = os.path.join(output_dir, 'debug')
    os.makedirs(debug_dir, exist_ok=True)
    stem_copy = os.path.join(debug_dir, f'{label}_01_isolated_stem.wav')
    raw_midi = os.path.join(debug_dir, f'{label}_02_raw_melody.mid')
    raw_preview = os.path.join(debug_dir, f'{label}_02_raw_melody.wav')
    detector_events = midi_path + '.detector.json'
    shutil.copy2(stem_path, stem_copy)
    shutil.copy2(midi_path, raw_midi)
    melody = pretty_midi.PrettyMIDI(midi_path)
    preview = melody.synthesize(fs=22050)
    peak = float(np.max(np.abs(preview))) if len(preview) else 0.0
    if peak > 0:
        preview = preview / peak * 0.85
    wavfile.write(raw_preview, 22050, (preview * 32767).astype(np.int16))
    print(f'[debug] Listen in order: {stem_copy} then {raw_preview}')
    artifacts = {
        'isolated_stem': stem_copy,
        'raw_melody_midi': raw_midi,
        'raw_melody_preview': raw_preview,
    }
    if os.path.exists(detector_events):
        artifacts['detector_events'] = detector_events
    return artifacts


def _fill_vocal_gaps_with_instrumental(vocal_midi_path, instrumental_midi_path):
    """Keep the vocal lead, then continue it through genuine vocal rests."""
    vocal = pretty_midi.PrettyMIDI(vocal_midi_path)
    instrumental = pretty_midi.PrettyMIDI(instrumental_midi_path)
    lead = sorted(
        [item for part in vocal.instruments for item in part.notes],
        key=lambda item: item.start,
    )
    fallback = sorted(
        [item for part in instrumental.instruments for item in part.notes],
        key=lambda item: item.start,
    )
    if not lead or not fallback:
        return 0

    additions = []
    for candidate in fallback:
        if any(item.start < candidate.end - 0.03 and
               item.end > candidate.start + 0.03 for item in lead):
            continue
        previous = next((item for item in reversed(lead) if item.end <= candidate.start + 0.03), None)
        following = next((item for item in lead if item.start >= candidate.end - 0.03), None)
        gap_start = previous.end if previous else 0.0
        gap_end = following.start if following else candidate.end
        if gap_end - gap_start < 0.28:
            continue
        # Do not turn accompaniment into the lead just because it fills a
        # silence. A usable bridge must connect to at least one surrounding
        # melody note without an implausible octave-sized jump.
        nearby_intervals = []
        if previous is not None:
            nearby_intervals.append(abs(candidate.pitch - previous.pitch))
        if following is not None:
            nearby_intervals.append(abs(candidate.pitch - following.pitch))
        if nearby_intervals and min(nearby_intervals) > 12:
            continue
        start = max(candidate.start, gap_start)
        end = min(candidate.end, gap_end)
        if end - start >= 0.10:
            additions.append(pretty_midi.Note(
                velocity=candidate.velocity,
                pitch=candidate.pitch,
                start=start,
                end=end,
            ))
            lead.append(additions[-1])
            lead.sort(key=lambda item: item.start)

    if not additions:
        return 0
    merged = pretty_midi.PrettyMIDI()
    track = pretty_midi.Instrument(program=40, name='Combined lead melody')
    track.notes = sorted(lead, key=lambda item: item.start)
    merged.instruments.append(track)
    merged.write(vocal_midi_path)
    return len(additions)


def _melody_rest_sections(notes, duration, minimum=3.0):
    """Find long rests without treating overlapping lead notes as silence."""
    sections, cursor = [], 0.0
    for event in sorted(notes, key=lambda n: n.start):
        if event.start - cursor >= minimum:
            sections.append((cursor, event.start))
        cursor = max(cursor, event.end)
    if duration - cursor >= minimum:
        sections.append((cursor, duration))
    return sections


def _recover_instrumental_sections(lead_path, stem_dir, pitch_range):
    """Audition instrumental candidates only in long lead rests.

    Spectral agreement is a heuristic, not proof of melodic identity. Keep
    decisions in metadata so recovered sections can be reviewed.
    """
    import tempfile
    import soundfile as sf
    import numpy as np
    lead = pretty_midi.PrettyMIDI(lead_path)
    existing = [n for t in lead.instruments for n in t.notes]
    sources = [os.path.join(stem_dir, s + '.wav')
               for s in ('piano', 'other', 'guitar')]
    sources = [p for p in sources if os.path.exists(p)]
    if not sources or not existing:
        return []
    duration = min(sf.info(p).duration for p in sources)
    decisions = []
    recovered = pretty_midi.Instrument(0, name='Instrumental melody recovery')
    for start, end in _melody_rest_sections(existing, duration):
        candidates = []
        with tempfile.TemporaryDirectory(prefix='augment_melody_') as temporary:
            for index, source in enumerate(sources):
                with sf.SoundFile(source) as audio:
                    audio.seek(int(start * audio.samplerate))
                    samples = audio.read(int((end-start)*audio.samplerate), always_2d=True)
                    sr = audio.samplerate
                if not samples.size or float(np.sqrt(np.mean(samples**2))) < .0008:
                    continue
                wav = os.path.join(temporary, f'{index}.wav')
                mid = os.path.join(temporary, f'{index}.mid')
                sf.write(wav, samples, sr, subtype='FLOAT')
                try:
                    transcribe_stem(wav, mid, False, prefer_pyin=True, melody_range=pitch_range)
                    validation = validate_transcription(wav, mid)
                    confidence = validation.get('alignment_confidence')
                    candidate = pretty_midi.PrettyMIDI(mid)
                    instability = _melody_contour_instability(candidate)
                    if confidence is not None and confidence >= .55 and instability <= .2:
                        candidates.append((confidence, source, candidate))
                except (ValueError, RuntimeError, OSError):
                    continue
            decision = {'start_seconds': start, 'end_seconds': end, 'notes_added': 0,
                        'status': 'no_confident_candidate'}
            if candidates:
                confidence, source, candidate = max(candidates, key=lambda c: c[0])
                for track in candidate.instruments:
                    for n in track.notes:
                        absolute_start = start + n.start
                        absolute_end = min(end, start + n.end)
                        if absolute_end > absolute_start:
                            recovered.notes.append(pretty_midi.Note(n.velocity, n.pitch, absolute_start, absolute_end))
                            decision['notes_added'] += 1
                decision.update(status='review_recovered_section', source=os.path.basename(source),
                                alignment_confidence=confidence)
            decisions.append(decision)
    if recovered.notes:
        lead.instruments.append(recovered)
        lead.write(lead_path)
    return decisions


def apply_isolated_lead_to_piano(arrangement_midi_path, lead_midi_path):
    """Add the separated lead without deleting overlapping piano figures."""
    arrangement = pretty_midi.PrettyMIDI(arrangement_midi_path)
    lead_midi = pretty_midi.PrettyMIDI(lead_midi_path)
    lead_notes = [item for part in lead_midi.instruments for item in part.notes]
    if not lead_notes:
        return 0

    lead_notes.sort(key=lambda item: item.start)
    accompaniment = [
        item for part in arrangement.instruments for item in part.notes
    ]
    combined = pretty_midi.PrettyMIDI(initial_tempo=120)
    accompaniment_track = pretty_midi.Instrument(program=0, name='Piano accompaniment')
    for item in accompaniment:
        accompaniment_track.notes.append(pretty_midi.Note(
            velocity=item.velocity,
            pitch=item.pitch,
            start=item.start,
            end=item.end,
        ))
    # Move the entire lead phrase together. Per-note octave mapping creates a
    # false octave jump whenever a low vocal crosses middle C.
    ordered_pitches = sorted(item.pitch for item in lead_notes)
    centre_pitch = ordered_pitches[len(ordered_pitches) // 2]
    octave_shift = 0
    while centre_pitch + octave_shift < 60:
        octave_shift += 12
    while centre_pitch + octave_shift > 88:
        octave_shift -= 12
    lead_track = pretty_midi.Instrument(program=0, name='Isolated melody')
    for item in lead_notes:
        pitch_value = item.pitch + octave_shift
        # Extremely wide vocal ranges are uncommon, but keep any outlier on
        # the piano instead of dropping it.
        while pitch_value < 48:
            pitch_value += 12
        while pitch_value > 100:
            pitch_value -= 12
        lead_track.notes.append(pretty_midi.Note(
            velocity=max(72, item.velocity),
            pitch=pitch_value,
            start=item.start,
            end=item.end,
        ))
    accompaniment_track.notes.sort(key=lambda item: (item.start, item.pitch))
    lead_track.notes.sort(key=lambda item: (item.start, item.pitch))
    combined.instruments.extend((accompaniment_track, lead_track))
    combined.write(arrangement_midi_path)
    return len(lead_notes)


def _merge_bass_support_into_piano(arrangement_midi_path, bass_midi_path):
    """Add separated bass only where the piano arrangement lacks low support."""
    arrangement = pretty_midi.PrettyMIDI(arrangement_midi_path)
    bass = pretty_midi.PrettyMIDI(bass_midi_path)
    existing_low = [
        event for track in arrangement.instruments for event in track.notes
        if event.pitch < 55
    ]
    added = []
    for event in sorted(
            (item for track in bass.instruments for item in track.notes),
            key=lambda item: item.start):
        if event.end - event.start < 0.10:
            continue
        overlaps = any(
            current.start < event.end and current.end > event.start
            for current in existing_low
        )
        if overlaps:
            continue
        pitch_value = event.pitch
        while pitch_value > 52:
            pitch_value -= 12
        while pitch_value < 28:
            pitch_value += 12
        copied = pretty_midi.Note(
            velocity=max(48, min(82, event.velocity)), pitch=pitch_value,
            start=event.start, end=event.end,
        )
        added.append(copied)
        existing_low.append(copied)
    if not added:
        return 0
    track = pretty_midi.Instrument(program=0, name='Separated bass support')
    track.notes = added
    arrangement.instruments.append(track)
    arrangement.write(arrangement_midi_path)
    return len(added)


def _add_missing_chord_bass_to_piano(arrangement_midi_path, grid):
    """Add a sparse playable left hand only where the arrangement has none.

    This is deliberately conservative: detected accompaniment and isolated
    bass remain the first choice.  A chord root/fifth/octave is used only for
    a chord window that has no low-register note at all, so this cannot turn a
    full arrangement into a dense duplicate transcription.
    """
    arrangement = pretty_midi.PrettyMIDI(arrangement_midi_path)
    existing_low = [
        note for track in arrangement.instruments for note in track.notes
        if note.pitch < 55
    ]
    support = pretty_midi.Instrument(program=0, name='Chord bass fallback')
    for section in getattr(grid, 'chord_sections', ()):
        start = float(section['start_seconds'])
        end = float(section['end_seconds'])
        if end - start < .10:
            continue
        if any(note.start < end and note.end > start for note in existing_low):
            continue
        root = int(section['root_pc'])
        root_pitch = 36 + root
        while root_pitch < 28:
            root_pitch += 12
        while root_pitch > 48:
            root_pitch -= 12
        fifth_pitch = root_pitch + 7
        if fifth_pitch > 55:
            fifth_pitch -= 12
        duration = min(end - start, max(.22, (end - start) * .88))
        for pitch, velocity in ((root_pitch, 72), (fifth_pitch, 55), (root_pitch + 12, 50)):
            if 28 <= pitch <= 60:
                note = pretty_midi.Note(velocity=velocity, pitch=pitch,
                                        start=start, end=start + duration)
                support.notes.append(note)
                existing_low.append(note)
    if not support.notes:
        return 0
    arrangement.instruments.append(support)
    arrangement.write(arrangement_midi_path)
    return len(support.notes)


def _select_supported_piano_lead(lead_source, lead_midi_path, lead_stats, stem_dir):
    """Keep a good primary lead; challenge weak/leaking stems for Solo Piano.

    Loudness is not proof of a vocal melody. Compare alternate separated
    contours only when the primary is poorly aligned. Never invent a lead if
    every candidate is weak. This policy is local to Solo Piano.
    """
    primary_score = lead_stats.get('alignment_confidence')
    if primary_score is not None and primary_score >= .45:
        return lead_source, lead_stats, True
    # Whole-stem spectral similarity includes harmonics and accompaniment
    # leakage. A marginal vocal score must not erase locally corroborated
    # phrases. This fallback never applies to other instruments or stems.
    if (os.path.basename(lead_source) == 'vocals.wav' and
            primary_score is not None and .30 <= primary_score < .45):
        from piano_local_melody_evidence import recover_locally_supported_vocal
        local = recover_locally_supported_vocal(lead_source, lead_midi_path)
        lead_stats['local_vocal_evidence'] = local
        if local['accepted']:
            lead_stats['notes'] = local['supported_notes']
            lead_stats['source_selection'] = {
                'policy': 'locally_validated_vocal_phrases',
                'selected_source': 'vocals.wav',
            }
            return lead_source, lead_stats, True
    candidates = [{'source': os.path.basename(lead_source),
                   'alignment_confidence': primary_score, 'accepted': False}]
    best = None
    temporary = []
    try:
        # Instrumental lead evidence can live in the separated guitar stem,
        # even when the requested output instrument is Piano. Source identity
        # is not the target instrument; retain the same evidence requirements.
        for filename in ('other.wav', 'piano.wav', 'guitar.wav'):
            source = os.path.join(stem_dir, filename)
            if source == lead_source or not os.path.exists(source):
                continue
            if _audio_rms(source) < .002:
                candidates.append({'source': filename, 'accepted': False,
                                   'reason': 'insufficient audio activity'})
                continue
            target = lead_midi_path + '.' + filename + '.candidate.mid'
            temporary.append(target)
            try:
                stats = transcribe_stem(source, target, polyphonic=False,
                                       prefer_pyin=True, melody_range=(40, 96),
                                       recover_short_piano=True)
                stats.update(validate_transcription(source, target))
                confidence = stats.get('alignment_confidence')
                accepted = (confidence is not None and confidence >= .45 and
                            _usable_instrumental_lead(target, stats) and
                            any(t.notes for t in pretty_midi.PrettyMIDI(target).instruments))
                candidates.append({'source': filename,
                                   'alignment_confidence': confidence,
                                   'accepted': bool(accepted)})
                if accepted and (best is None or confidence > best[0]):
                    best = (confidence, source, target, stats)
            except (OSError, ValueError, RuntimeError) as exc:
                candidates.append({'source': filename, 'accepted': False,
                                   'reason': str(exc)})
        selection = {'policy': 'validated_piano_lead_sources',
                     'primary_source': os.path.basename(lead_source),
                     'candidates': candidates}
        if best is not None:
            _, source, target, stats = best
            shutil.copyfile(target, lead_midi_path)
            selection['selected_source'] = os.path.basename(source)
            stats['source_selection'] = selection
            return source, stats, True
        selection['selected_source'] = None
        lead_stats['source_selection'] = selection
        lead_stats['rejected_as_unreliable_lead'] = True
        return lead_source, lead_stats, False
    finally:
        for target in temporary:
            if os.path.exists(target):
                os.remove(target)


def _usable_instrumental_lead(lead_midi_path, lead_stats):
    """Reject a low, poorly aligned accompaniment contour as a fake melody."""
    if lead_stats.get('alignment_confidence') is None:
        return True
    midi = pretty_midi.PrettyMIDI(lead_midi_path)
    notes = [note for track in midi.instruments for note in track.notes]
    if not notes:
        return False
    pitches = sorted(note.pitch for note in notes)
    median_pitch = pitches[len(pitches) // 2]
    upper_fraction = sum(note.pitch >= 55 for note in notes) / len(notes)
    return not (lead_stats['alignment_confidence'] < .45 and
                median_pitch < 60 and upper_fraction < .50)


def _select_solo_violin_line(candidate_midi_path, output_midi_path, min_pitch=55):
    """Choose one coherent, playable melodic line from Violin candidates.

    This is intentionally local to Solo Violin covers.  It does not alter the
    filtered-Basic-Pitch candidate policy used by Band Mode or other strings.
    """
    candidate = pretty_midi.PrettyMIDI(candidate_midi_path)
    events = sorted(
        (note for track in candidate.instruments for note in track.notes
         if note.end - note.start >= 0.075 and min_pitch <= note.pitch <= 103),
        key=lambda note: (note.start, note.pitch),
    )
    if not events:
        output = pretty_midi.PrettyMIDI()
        track = pretty_midi.Instrument(program=40, name='Solo Violin melody')
        output.instruments.append(track)
        output.write(output_midi_path)
        return []

    selected = []
    previous_pitch = None
    last_onset = -1.0
    index = 0

    while index < len(events):
        onset = events[index].start
        group = []
        while index < len(events) and events[index].start <= onset + 0.055:
            group.append(events[index])
            index += 1

        max_p = max(n.pitch for n in group)
        min_p = min(n.pitch for n in group)

        def score(n):
            if max_p == min_p:
                top_bonus = 0.50
            elif n.pitch == max_p:
                top_bonus = 0.95
            else:
                top_bonus = 0.40 * (n.pitch - min_p) / (max_p - min_p)

            # Core singing register preference for violin (D4 to D6)
            if 62 <= n.pitch <= 86:
                reg_score = 1.15
            elif 60 <= n.pitch < 62:
                reg_score = 0.70
            elif 58 <= n.pitch < 60:
                reg_score = 0.20
            elif 55 <= n.pitch < 58:
                reg_score = -0.40
            elif 86 < n.pitch <= 93:
                reg_score = 0.65
            else:
                reg_score = 0.20

            if previous_pitch is None:
                continuity = 0.0
            else:
                leap = abs(n.pitch - previous_pitch)
                if leap == 0:
                    continuity = 0.40
                elif 1 <= leap <= 2:
                    continuity = 0.75
                elif 3 <= leap <= 5:
                    continuity = 0.50
                elif 6 <= leap <= 7:
                    continuity = 0.35
                elif leap == 12:
                    continuity = 0.25
                elif 8 <= leap <= 11:
                    continuity = 0.0
                else:
                    continuity = -min(1.20, (leap - 12) * 0.12)
                if previous_pitch >= 62 and n.pitch < 60:
                    continuity -= 0.85

            vel_score = (n.velocity / 127.0) * 0.40
            dur_score = min(1.0, (n.end - n.start) / 0.35) * 0.25

            return top_bonus + reg_score + continuity + vel_score + dur_score

        chosen = max(group, key=score)

        if last_onset >= 0 and chosen.start < last_onset + 0.085:
            continue

        selected.append(pretty_midi.Note(
            velocity=max(54, min(108, chosen.velocity)),
            pitch=chosen.pitch,
            start=chosen.start,
            end=chosen.end,
        ))
        previous_pitch = chosen.pitch
        last_onset = chosen.start

    # Monophony and phrase-aware legato duration shaping
    if selected:
        for i in range(len(selected) - 1):
            curr_n = selected[i]
            next_n = selected[i + 1]
            raw_gap = next_n.start - curr_n.end

            if raw_gap < 0:
                curr_n.end = max(curr_n.start + 0.06, next_n.start - 0.015)
            elif raw_gap <= 0.32:
                curr_n.end = max(curr_n.start + 0.06, next_n.start - 0.015)
            else:
                natural_ring = min(0.12, raw_gap * 0.25)
                curr_n.end = min(curr_n.end + natural_ring, next_n.start - 0.08)

        last_n = selected[-1]
        last_n.end = min(last_n.end + 0.15, last_n.start + 2.5)

        # Musical velocity contour along phrases
        phrases = []
        curr_phrase = [selected[0]]
        for i in range(1, len(selected)):
            gap = selected[i].start - selected[i - 1].end
            if gap > 0.05:
                phrases.append(curr_phrase)
                curr_phrase = [selected[i]]
            else:
                curr_phrase.append(selected[i])
        phrases.append(curr_phrase)

        for phrase in phrases:
            if len(phrase) == 1:
                phrase[0].velocity = max(68, min(102, phrase[0].velocity))
                continue
            max_pitch = max(n.pitch for n in phrase)
            for j, note in enumerate(phrase):
                vel = note.velocity
                if j == 0:
                    vel = max(vel, 74)
                if note.pitch == max_pitch:
                    vel += 6
                elif j == len(phrase) - 1 and (note.end - note.start >= 0.25):
                    vel -= 5
                note.velocity = max(56, min(108, vel))

    output = pretty_midi.PrettyMIDI()
    track = pretty_midi.Instrument(program=40, name='Solo Violin melody')
    track.notes = selected
    output.instruments.append(track)
    output.write(output_midi_path)
    return selected


def _append_violin_gap_candidates(vocal_midi_path, candidate_midi_path, duration):
    """Use a selected instrumental hook only in genuine vocal rests."""
    vocal = pretty_midi.PrettyMIDI(vocal_midi_path)
    base = sorted((note for track in vocal.instruments for note in track.notes),
                  key=lambda note: note.start)
    candidates = sorted((note for track in pretty_midi.PrettyMIDI(candidate_midi_path).instruments
                         for note in track.notes), key=lambda note: note.start)
    additions = []
    for note in candidates:
        if any(existing.start < note.end and existing.end > note.start for existing in base):
            continue
        before = max((item.end for item in base if item.end <= note.start), default=0.0)
        after = min((item.start for item in base if item.start >= note.end), default=duration)
        if after - before < 0.35:
            continue
        additions.append(note)
        base.append(note)
        base.sort(key=lambda item: item.start)

    # Re-enforce monophony and legato connections across all merged events
    if base:
        for i in range(len(base) - 1):
            raw_gap = base[i + 1].start - base[i].end
            if raw_gap < 0:
                base[i].end = max(base[i].start + 0.06, base[i + 1].start - 0.015)
            elif raw_gap <= 0.32:
                base[i].end = max(base[i].start + 0.06, base[i + 1].start - 0.015)

    output = pretty_midi.PrettyMIDI()
    track = pretty_midi.Instrument(program=40, name='Solo Violin melody')
    track.notes = sorted(base, key=lambda item: item.start)
    output.instruments.append(track)
    output.write(vocal_midi_path)
    return len(additions)


def _restrain_violin_outline(midi_path):
    """Refine a source-derived hook line by removing isolated noise blips."""
    midi = pretty_midi.PrettyMIDI(midi_path)
    notes = sorted((note for track in midi.instruments for note in track.notes),
                   key=lambda note: note.start)
    kept = []
    for i, note in enumerate(notes):
        dur = note.end - note.start
        has_prev = (i > 0 and note.start - notes[i - 1].end <= 1.2)
        has_next = (i + 1 < len(notes) and notes[i + 1].start - note.end <= 1.2)
        if not has_prev and not has_next and dur < 0.12 and note.velocity < 62:
            continue
        if note.pitch < 58 and dur < 0.15:
            continue
        kept.append(note)

    # Maintain monophony across kept notes
    if kept:
        for i in range(len(kept) - 1):
            if kept[i].end > kept[i + 1].start - 0.015:
                kept[i].end = max(kept[i].start + 0.06, kept[i + 1].start - 0.015)

    output = pretty_midi.PrettyMIDI()
    track = pretty_midi.Instrument(program=40, name='Restrained instrumental outline')
    track.notes = kept
    output.instruments.append(track)
    output.write(midi_path)
    return len(kept)


def _lift_violin_outline_to_register(midi_path, target_low=60):
    """Move one selected phrase by octaves, never note-by-note."""
    midi = pretty_midi.PrettyMIDI(midi_path)
    notes = [note for track in midi.instruments for note in track.notes]
    if not notes:
        return 0
    ordered = sorted(note.pitch for note in notes)
    median = ordered[len(ordered) // 2]
    shift = 0
    while median + shift < target_low:
        shift += 12
    while median + shift > 84:
        shift -= 12
    for note in notes:
        note.pitch = max(55, min(103, note.pitch + shift))
    midi.write(midi_path)
    return shift


def _transcribe_solo_violin_cover(stem_dir, midi_path, duration):
    """Build a single-line Solo Violin cover from verified lead evidence."""
    import tempfile
    vocals_path = os.path.join(stem_dir, 'vocals.wav')
    other_path = os.path.join(stem_dir, 'other.wav')
    vocal_notes, vocal_stats, source = [], {}, None
    with tempfile.TemporaryDirectory(prefix='augment_solo_violin_') as temp:
        vocal_midi = os.path.join(temp, 'vocal.mid')
        if os.path.exists(vocals_path) and _audio_rms(vocals_path) >= .002:
            try:
                vocal_stats = _transcribe_vocal_melody(vocals_path, vocal_midi, (55, 96))
                vocal_stats.update(validate_transcription(vocals_path, vocal_midi))
                vocal_notes = _select_solo_violin_line(vocal_midi, midi_path, min_pitch=55)
                source = 'vocals'
            except (OSError, RuntimeError, ValueError):
                vocal_notes = []
        candidate_audio = other_path if os.path.exists(other_path) else None
        candidate_midi = os.path.join(temp, 'instrumental_raw.mid')
        selected_candidate = os.path.join(temp, 'instrumental_line.mid')
        candidate_stats, candidate_notes, candidate_ok, candidate_median = {}, [], False, 0
        if candidate_audio and _audio_rms(candidate_audio) >= .002:
            try:
                candidate_stats = transcribe_stem(
                    candidate_audio, candidate_midi, polyphonic=False,
                    prefer_pyin=False, melody_range=(55, 96), instrument_name='Violin')
                candidate_notes = _select_solo_violin_line(candidate_midi, selected_candidate, min_pitch=60)
                if len(candidate_notes) < 8:
                    candidate_notes = _select_solo_violin_line(candidate_midi, selected_candidate, min_pitch=55)
                candidate_stats.update(validate_transcription(candidate_audio, selected_candidate))
                pitches = sorted(note.pitch for note in candidate_notes)
                candidate_median = pitches[len(pitches) // 2] if pitches else 0
                candidate_ok = bool(candidate_notes and candidate_median >= 60 and
                                    (candidate_stats.get('alignment_confidence') or 0) >= .20)
            except (OSError, RuntimeError, ValueError):
                candidate_notes = []
        outline_used = False
        if vocal_notes and not candidate_ok and candidate_notes and candidate_median >= 60:
            # The upload has a verified vocal only late in the clip. During
            # its long rests, retain a top-line outline from the source
            # instead of either silence or a dense accompaniment copy.
            _restrain_violin_outline(selected_candidate)
            candidate_ok, outline_used = True, True
        elif (not vocal_notes and candidate_notes and
              (candidate_stats.get('alignment_confidence') or 0) >= .20):
            # Instrumental songs do not have a verified vocal to anchor the
            # cover. Preserve the source-derived melodic contour in violin register.
            _restrain_violin_outline(selected_candidate)
            _lift_violin_outline_to_register(selected_candidate)
            candidate_ok, outline_used = True, True
        elif candidate_ok:
            _restrain_violin_outline(selected_candidate)
            if not vocal_notes:
                _lift_violin_outline_to_register(selected_candidate)
            outline_used = True

        if vocal_notes:
            # Re-open the selected vocal line and fill only its long rests.
            additions = (_append_violin_gap_candidates(midi_path, selected_candidate, duration)
                         if candidate_ok else 0)
            method, primary_source = 'verified_vocal_plus_hook', source
        elif candidate_ok:
            shutil.copy2(selected_candidate, midi_path)
            additions, method, primary_source = len(candidate_notes), 'instrumental_hook', 'other'
        else:
            # No defensible lead is preferable to transcribing accompaniment
            # as a fake violin solo.
            pretty_midi.PrettyMIDI().write(midi_path)
            additions, method, primary_source = 0, 'no_reliable_lead', 'none'
    final = pretty_midi.PrettyMIDI(midi_path)
    notes = [note for track in final.instruments for note in track.notes]
    if not notes:
        raise ValueError('No defensible Solo Violin melody was found.')
    return {
        'notes': len(notes), 'raw_notes': candidate_stats.get('raw_notes', len(candidate_notes)),
        'method': method, 'source_stem': primary_source,
        'source_strategy': 'solo_violin_cover', 'voice_type': 'monophonic',
        'vocal_candidate': vocal_stats, 'instrumental_candidate': candidate_stats,
        'instrumental_notes_added': additions,
        'restrained_instrumental_outline': outline_used,
        'alignment_confidence': (vocal_stats.get('alignment_confidence') if vocal_notes
                                 else candidate_stats.get('alignment_confidence')),
    }


def _transcribe_solo_guitar_cover(stem_dir, midi_path, duration, grid, instrument_name='Guitar'):
    """Arrange shared song evidence into one playable Solo Guitar cover.

    Unlike Band Guitar, the separated guitar stem is optional evidence only.
    A vocal/top-line plus the analysed harmony and bass are sufficient for a
    guitar cover of a song that originally contains no guitar.
    """
    import tempfile
    from solo_guitar_arranger import (
        arrange_solo_guitar, midi_notes, select_guitar_lead, merge_guitar_melody,
    )

    vocals_path = os.path.join(stem_dir, 'vocals.wav')
    other_path = os.path.join(stem_dir, 'other.wav')
    bass_path = os.path.join(stem_dir, 'bass.wav')
    lead_notes, fallback_notes, bass_notes = [], [], []
    lead_stats, bass_stats = {}, {}
    lead_source = 'none'
    with tempfile.TemporaryDirectory(prefix='augment_solo_guitar_') as temp:
        lead_midi = os.path.join(temp, 'lead.mid')
        # A healthy separated vocal is the strongest melody evidence.  In an
        # instrumental song, the top-line candidate comes from `other`, never
        # from a presumed original guitar stem.
        source = vocals_path
        if (not os.path.exists(source) or _audio_rms(source) < max(
                .002, _audio_rms(other_path) * .035 if os.path.exists(other_path) else .002)):
            source = other_path
        if source and os.path.exists(source) and _audio_rms(source) >= .002:
            try:
                lead_stats = _transcribe_vocal_melody(source, lead_midi, (52, 88))
                lead_stats.update(validate_transcription(source, lead_midi))
                lead_notes = midi_notes(lead_midi)
                lead_source = os.path.basename(source)
            except (OSError, RuntimeError, ValueError):
                lead_notes = []
        # Recover missed vocal attacks from a second detector on the same
        # isolated vocal. For instrumental material, retain the upper-line
        # fallback from `other.wav`.
        fallback_source = (vocals_path if lead_notes and source == vocals_path
                           else other_path)
        if os.path.exists(fallback_source) and _audio_rms(fallback_source) >= .002:
            # pYIN can legitimately find no line in a non-vocal arrangement.
            # Use existing polyphonic Basic Pitch evidence, but select a stable
            # upper guitar line rather than accepting its low accompaniment as
            # a fake melody.
            try:
                raw_lead_midi = os.path.join(temp, 'lead_raw.mid')
                transcribe_stem(fallback_source, raw_lead_midi, polyphonic=True,
                                prefer_pyin=False, melody_range=(52, 88),
                                instrument_name='Guitar')
                fallback_midi = os.path.join(temp, 'fallback_lead.mid')
                fallback_notes = select_guitar_lead(raw_lead_midi, fallback_midi)
                if lead_notes:
                    lead_notes, added = merge_guitar_melody(
                        lead_notes, fallback_notes, duration,
                        same_source=fallback_source == vocals_path)
                    fallback_notes = added
                    lead_source = ('vocals.wav (pYIN + Basic Pitch attack recovery)'
                                   if fallback_source == vocals_path else
                                   'vocals.wav + other.wav instrumental rests')
                else:
                    lead_notes = fallback_notes
                    lead_source = 'other.wav (Basic Pitch upper-line fallback)'
            except (OSError, RuntimeError, ValueError):
                # Optional instrumental evidence must not erase a valid lead.
                pass
        bass_midi = os.path.join(temp, 'bass.mid')
        if os.path.exists(bass_path) and _audio_rms(bass_path) >= .001:
            try:
                bass_stats = transcribe_stem(bass_path, bass_midi, polyphonic=False,
                                             prefer_pyin=True, melody_range=(40, 55),
                                             instrument_name='Bass Guitar')
                bass_notes = midi_notes(bass_midi)
            except (OSError, RuntimeError, ValueError):
                bass_notes = []
        verified_count = len(lead_notes) - len(fallback_notes) if 'vocals.wav' in lead_source else 0
        arrangement = arrange_solo_guitar(
            lead_notes, bass_notes, grid, midi_path,
            verified_melody_notes=verified_count,
            fallback_melody_notes=len(fallback_notes),
        )
        if instrument_name == 'Electric Guitar':
            # Reuse the validated physical performance, not the classical
            # sample source. Program changes never alter canonical events.
            electric_midi = pretty_midi.PrettyMIDI(midi_path)
            for track in electric_midi.instruments:
                track.program = 27
                track.name = 'Solo Electric Guitar unified performance'
            electric_midi.write(midi_path)
            arrangement['electric_guitar_version'] = 'physical_performance_v1'
    if not arrangement['notes']:
        raise ValueError('No defensible Solo Guitar material was found.')
    return {
        **arrangement,
        'method': 'solo_guitar_unified_arrangement_v12',
        'source_strategy': 'full_song_solo_arrangement',
        'source_stem': lead_source,
        'lead_source': lead_source,
        'lead_candidate': lead_stats,
        'bass_candidate': bass_stats,
        'input_lead_notes': len(lead_notes),
        'fallback_melody_candidates': len(fallback_notes),
        'input_bass_notes': len(bass_notes),
        'duration_seconds': round(float(duration), 3),
    }


def _fit_to_instrument(score, name):
    low, high, simultaneous_max = INSTRUMENTS.get(name, INSTRUMENTS["Piano"])
    # Woodwind and brass parts remain monophonic. Guitar and ukulele can keep
    # a complete playable chord, which is essential for tabs and strumming.
    if simultaneous_max is False:
        simultaneous_max = 1
    for el in list(score.recurse().notes):
        pitches = list(el.pitches) if isinstance(el, chord.Chord) else [el.pitch]
        fitted = []
        for p in pitches:
            midi = p.midi
            while midi < low: midi += 12
            while midi > high: midi -= 12
            fitted.append(music21.pitch.Pitch(midi=midi))
        fitted = sorted(fitted, key=lambda p: p.midi)[-simultaneous_max:]
        if isinstance(el, chord.Chord):
            if len(fitted) == 1: el.activeSite.replace(el, note.Note(fitted[0], quarterLength=el.quarterLength))
            else: el.pitches = fitted
        else:
            el.pitch = fitted[0]


def _key_for_grid(grid):
    return key.Key(grid.key_name, grid.key_mode)


def _concert_instrument(name):
    """Return an instrument label that does not transpose concert-pitch data."""
    selected = instrument.fromString(name)
    selected.transposition = None
    return selected


def _snap_to_detected_scale(midi_value, grid, previous_pitch=None):
    """Preserve detected chromatic pitches; the global key is notation metadata."""
    return midi_value


def detect_lead_techniques(audio_path, midi_path):
    """Detect conservative vibrato and glissando candidates from lead F0.

    The detector deliberately prefers no marking over a false marking. It is
    intended for isolated melody stems, where a pitch contour is meaningful.
    """
    import librosa
    import numpy as np
    from scipy.ndimage import median_filter

    melody = pretty_midi.PrettyMIDI(midi_path)
    notes = sorted((n for inst in melody.instruments for n in inst.notes), key=lambda n: n.start)
    if not notes:
        return {"vibrato": [], "glissando": []}
    y, sr = librosa.load(audio_path, sr=22050, mono=True)
    hop = 256
    # YIN is much faster than a second full pYIN pass. Energy gating removes
    # silent/reverberant frames before the technique heuristics inspect them.
    f0 = librosa.yin(
        y,
        fmin=librosa.note_to_hz('G2'),
        fmax=librosa.note_to_hz('C7'),
        sr=sr,
        hop_length=hop,
        frame_length=1024,
    )
    times = librosa.frames_to_time(np.arange(len(f0)), sr=sr, hop_length=hop)
    rms = librosa.feature.rms(y=y, frame_length=1024, hop_length=hop)[0]
    energy_floor = max(0.002, float(np.percentile(rms, 30)) * 0.55)
    pitch_track = np.where(rms >= energy_floor, librosa.hz_to_midi(f0), np.nan)
    techniques = {"vibrato": [], "glissando": []}

    for current in notes:
        if current.end - current.start < 0.45:
            continue
        mask = (times >= current.start + 0.08) & (times <= current.end - 0.08) & np.isfinite(pitch_track)
        values = pitch_track[mask]
        if len(values) < 16:
            continue
        baseline = median_filter(values, size=min(31, max(5, len(values) // 2 * 2 + 1)))
        residual = values - baseline
        depth = float(np.std(residual))
        crossings = np.count_nonzero(np.diff(np.signbit(residual - np.median(residual))))
        rate = crossings * sr / (2 * hop * len(values))
        if 0.07 <= depth <= 0.45 and 3.5 <= rate <= 9.0:
            techniques["vibrato"].append({"start": current.start, "depth": round(depth, 3), "rate": round(rate, 2)})

    for first, second in zip(notes, notes[1:]):
        gap = second.start - first.end
        interval = second.pitch - first.pitch
        if not (-0.05 <= gap <= 0.09 and 2 <= abs(interval) <= 12):
            continue
        mask = (times >= first.end - 0.09) & (times <= second.start + 0.09) & np.isfinite(pitch_track)
        values = pitch_track[mask]
        if len(values) < 5:
            continue
        direction = 1 if interval > 0 else -1
        movement = np.diff(median_filter(values, size=3)) * direction
        progress = (values[-1] - values[0]) * direction
        if progress >= abs(interval) * 0.55 and np.mean(movement >= -0.16) >= 0.70:
            techniques["glissando"].append({"start": first.start, "end": second.start})
    return techniques


def _simplify_violin_techniques(techniques):
    """Turn a vocal contour into sparse, playable violin expression marks."""
    if not techniques:
        return {"vibrato": [], "glissando": []}
    vibrato = []
    last_vibrato = -99.0
    for event in techniques.get('vibrato', []):
        start = float(event.get('start', 0.0))
        if start - last_vibrato < 2.0:
            continue
        vibrato.append({
            **event,
            'depth': round(min(0.18, max(0.07, float(event.get('depth', 0.12)))), 3),
            'rate': round(min(6.5, max(4.0, float(event.get('rate', 5.2)))), 2),
        })
        last_vibrato = start
    glissando = []
    last_glissando = -99.0
    for event in techniques.get('glissando', []):
        start = float(event.get('start', 0.0))
        end = float(event.get('end', start))
        if end <= start or end - start > 0.8 or start - last_glissando < 6.0:
            continue
        glissando.append(event)
        last_glissando = start
    return {'vibrato': vibrato, 'glissando': glissando}


def _apply_detected_techniques(part, techniques, grid):
    """Add detected lead techniques as readable MusicXML directions."""
    if not techniques:
        return
    timed_notes = []
    for current in part.recurse().notes:
        try:
            offset = float(current.getOffsetInHierarchy(part))
        except Exception:
            offset = float(current.offset)
        timed_notes.append((offset * 60.0 / grid.bpm, offset, current))
    for event in techniques.get("vibrato", []):
        target = min(timed_notes, key=lambda item: abs(item[0] - event["start"]), default=None)
        if target and abs(target[0] - event["start"]) <= 0.14:
            part.insert(target[1], expressions.TextExpression("vib."))
    for event in techniques.get("glissando", []):
        first = min(timed_notes, key=lambda item: abs(item[0] - event["start"]), default=None)
        second = min(timed_notes, key=lambda item: abs(item[0] - event["end"]), default=None)
        if first and second and first[2] is not second[2]:
            part.insert(first[1], expressions.TextExpression("gliss."))
            try:
                part.insert(first[1], spanner.Glissando(first[2], second[2]))
            except Exception:
                pass


def _add_phrase_slurs(part):
    """Add short legato phrases using score-global, not measure-local, time."""
    timed_notes = []
    for current in part.recurse().notes:
        try:
            offset = float(current.getOffsetInHierarchy(part))
        except Exception:
            offset = float(current.offset)
        timed_notes.append((offset, current))
    timed_notes.sort(key=lambda item: item[0])

    def add_phrase(phrase, start_offset):
        if len(phrase) >= 2:
            # A four-note maximum keeps the engraving readable and avoids
            # giant spans that can break WebView-based MusicXML renderers.
            part.insert(start_offset, spanner.Slur(phrase))

    phrase = []
    phrase_start = 0.0
    previous_end = None
    previous_pitch = None
    for offset, current in timed_notes:
        gap = float('inf') if previous_end is None else offset - previous_end
        melody_pitch = (current.pitches[-1].midi if isinstance(current, chord.Chord)
                        else current.pitch.midi)
        interval = float('inf') if previous_pitch is None else abs(melody_pitch - previous_pitch)
        if phrase and (gap > 0.12 or interval > 7 or len(phrase) >= 4):
            add_phrase(phrase, phrase_start)
            phrase = []
        if not phrase:
            phrase_start = offset
        phrase.append(current)
        previous_end = offset + float(current.duration.quarterLength)
        previous_pitch = melody_pitch
    add_phrase(phrase, phrase_start)


def _add_score_formatting(score, part, title, artist, grid):
    """Add restrained, readable performance and engraving markings."""
    score.metadata = music21.metadata.Metadata()
    score.metadata.title = title
    score.metadata.composer = artist
    notes = list(part.recurse().notes)
    part_instruments = [
        (getattr(item, 'instrumentName', '') or '').lower()
        for item in part.recurse().getElementsByClass(instrument.Instrument)
    ]
    part_label = (part.partName or '').lower()
    is_bowed_string = (
        'violin' in part_label or 'cello' in part_label or
        any(name in {'violin', 'cello'} for name in part_instruments)
    )
    if notes:
        part.insert(0, dynamics.Dynamic('mf'))
        for index, current in enumerate(notes):
            velocity = current.volume.velocity or 80
            following = notes[index + 1] if index + 1 < len(notes) else None
            gap = (following.offset - (current.offset + current.duration.quarterLength)) if following else 1.0
            # A transcription has no reliable bowing information. Be cautious
            # with staccato: it makes playback sound detached when a stem has
            # small detection gaps between legato notes.
            if (not is_bowed_string and current.duration.quarterLength <= 0.25 and gap >= 0.25):
                current.articulations.append(articulations.Staccato())
            if velocity >= 105:
                current.articulations.append(articulations.Accent())
        # Phrase-level dynamics are only added when the detected confidence
        # makes a clear change, avoiding arbitrary markings on noisy audio.
        for start in range(0, len(notes) - 6, 7):
            first = notes[start].volume.velocity or 80
            last = notes[min(start + 6, len(notes) - 1)].volume.velocity or 80
            if last - first >= 18:
                part.insert(notes[start].offset, expressions.TextExpression('cresc.'))
            elif first - last >= 18:
                part.insert(notes[start].offset, expressions.TextExpression('dim.'))
    measures = list(part.getElementsByClass(stream.Measure))
    # Piano scores read best as compact grand-staff systems, like the supplied
    # reference score, rather than very long continuous rows.
    system_interval = 4 if ('piano' in part_label or len(score.parts) > 1) else 8
    for index, measure_obj in enumerate(measures):
        if index and index % system_interval == 0:
            letter = ascii_uppercase[(index // system_interval - 1) % len(ascii_uppercase)]
            measure_obj.insert(0, expressions.RehearsalMark(letter))
            measure_obj.insert(0, layout.SystemLayout(isNew=True))
        if index and index % 32 == 0:
            measure_obj.insert(0, layout.PageLayout(isNew=True))


def _add_musicxml_credits(xml_path, title=None, artist=None):
    """Add visible title, artist and footer credits for MusicXML renderers."""
    tree = ET.parse(xml_path)
    root = tree.getroot()
    namespace = root.tag.split('}')[0] + '}' if '}' in root.tag else ''
    if title:
        credit = ET.SubElement(root, f'{namespace}credit', page='1')
        ET.SubElement(credit, f'{namespace}credit-type').text = 'title'
        words = ET.SubElement(credit, f'{namespace}credit-words', **{
            'default-x': '610', 'default-y': '1350', 'font-size': '24',
            'justify': 'center', 'halign': 'center',
        })
        words.text = title
    if artist:
        credit = ET.SubElement(root, f'{namespace}credit', page='1')
        ET.SubElement(credit, f'{namespace}credit-type').text = 'composer'
        words = ET.SubElement(credit, f'{namespace}credit-words', **{
            'default-x': '1100', 'default-y': '1280', 'font-size': '12',
            'justify': 'right', 'halign': 'right',
        })
        words.text = artist
    credit = ET.SubElement(root, f'{namespace}credit', page='1')
    ET.SubElement(credit, f'{namespace}credit-type').text = 'footer'
    words = ET.SubElement(credit, f'{namespace}credit-words', **{
        'default-x': '10', 'default-y': '-160', 'font-size': '8', 'justify': 'left', 'valign': 'bottom',
    })
    words.text = 'Generated by Augment | Page 1'
    tree.write(xml_path, encoding='utf-8', xml_declaration=True)


def _flute_score_from_midi(midi_path, grid, instrument_name='Flute'):
    """Engrave the selected solo line without reselecting or losing attacks."""
    midi = pretty_midi.PrettyMIDI(midi_path)
    sources = sorted((n for inst in midi.instruments for n in inst.notes),
                     key=lambda n: (n.start, n.pitch))
    if not sources:
        raise ValueError(f"The {instrument_name} melody has no usable notes")
    # A finer grid is needed only when separate attacks would otherwise merge.
    subdivision = 8
    while True:
        starts = [round(grid.seconds_to_quarter(n.start) * subdivision) /
                  subdivision for n in sources]
        short_durations_fit = all(
            abs(max(1.0 / subdivision, round(
                (grid.seconds_to_quarter(n.end) - grid.seconds_to_quarter(n.start))
                * subdivision) / subdivision) -
                (grid.seconds_to_quarter(n.end) - grid.seconds_to_quarter(n.start)))
            * 60.0 / grid.bpm <= .02 for n in sources
            if n.end - n.start < .20)
        if all(b > a for a, b in zip(starts, starts[1:])) and (
                short_durations_fit or subdivision >= 64):
            break
        if subdivision >= 64:
            raise ValueError(f"{instrument_name} melody contains unresolved simultaneous attacks")
        subdivision *= 2
    step = 1.0 / subdivision
    part = stream.Part()
    for index, source in enumerate(sources):
        start = starts[index]
        end = max(start + step,
                  round(grid.seconds_to_quarter(source.end) * subdivision) /
                  subdivision)
        if index + 1 < len(sources):
            # Written releases may shorten for monophony; playback is untouched.
            end = min(end, starts[index + 1])
        written = note.Note(source.pitch, quarterLength=end - start)
        written.volume.velocity = source.velocity
        part.insert(start, written)
    score = stream.Score([part])
    score._augment_notation_subdivision = subdivision
    return score


def _solo_score_from_midi(midi_path, name, grid):
    """Convert seconds to beat-grid positions before notation is created."""
    midi = pretty_midi.PrettyMIDI(midi_path)
    notes = [n for inst in midi.instruments for n in inst.notes]
    if not notes:
        raise ValueError("The isolated melody has no usable notes")
    grouped = {}
    for midi_note in notes:
        # Preserve expressive timing to a 32nd-note grid instead of forcing
        # every onset onto a rigid 16th-note position.
        start = round(grid.seconds_to_quarter(midi_note.start) * 8) / 8
        end = round(grid.seconds_to_quarter(midi_note.end) * 8) / 8
        if end - start < 0.25:
            end = start + 0.25
        grouped.setdefault(start, []).append((midi_note, end))
    low, high, _ = INSTRUMENTS.get(name, INSTRUMENTS["Violin"])
    part = stream.Part()
    previous_pitch = None
    previous_end = 0.0
    previous_note = None
    for start in sorted(grouped):
        # Prefer a strong candidate that moves naturally from the prior note.
        options = grouped[start]
        def rank(option):
            candidate = option[0].pitch
            if previous_pitch is None:
                return (-option[0].velocity, -candidate)
            interval = abs(candidate - previous_pitch)
            return (interval > 12, interval, -option[0].velocity)
        source, end = min(options, key=rank)
        pitch_value = source.pitch
        while pitch_value < low: pitch_value += 12
        while pitch_value > high: pitch_value -= 12
        pitch_value = _snap_to_detected_scale(pitch_value, grid, previous_pitch)
        # Correct only obvious octave aliases. Wide leaps can be genuine lead
        # melody, especially in orchestral and cinematic material, so retain
        # them rather than silently dropping the note.
        if previous_pitch is not None and abs(pitch_value - previous_pitch) > 19:
            alternatives = [pitch_value - 12, pitch_value + 12]
            valid = [p for p in alternatives if low <= p <= high]
            if valid:
                closest = min(valid, key=lambda p: abs(p - previous_pitch))
                if abs(closest - previous_pitch) + 5 < abs(pitch_value - previous_pitch):
                    pitch_value = closest
        start = max(start, previous_end)
        if end <= start:
            continue
        # Separate detector events represent separate attacks, even when the
        # pitch repeats. Do not turn repeated melody notes into a sustain.
        previous_note = note.Note(pitch_value, quarterLength=max(0.125, end - start))
        previous_note.volume.velocity = source.velocity
        part.insert(start, previous_note)
        previous_pitch, previous_end = pitch_value, end
    if not list(part.recurse().notes):
        raise ValueError("Melody cleanup removed all unreliable notes")
    if name == "Violin":
        _correct_isolated_violin_octaves(part)
    score = stream.Score()
    score.insert(0, part)
    return score


def _correct_isolated_violin_octaves(part):
    """Correct isolated octave aliases without flattening real violin leaps.

    Pitch trackers occasionally jump an otherwise continuous phrase up or
    down one octave for a single note.  Only correct a middle note when both
    neighbours agree with one another, preserving sustained register changes
    and intentional octave leaps.
    """
    notes = [event for event in part.recurse().notes
             if isinstance(event, note.Note)]
    corrected = 0
    for previous, current, following in zip(notes, notes[1:], notes[2:]):
        if abs(previous.pitch.midi - following.pitch.midi) > 3:
            continue
        candidates = [current.pitch.midi - 12, current.pitch.midi + 12]
        candidates = [pitch for pitch in candidates if 55 <= pitch <= 103]
        if not candidates:
            continue
        replacement = min(candidates, key=lambda pitch: (
            abs(pitch - previous.pitch.midi) + abs(pitch - following.pitch.midi)
        ))
        original_distance = (
            abs(current.pitch.midi - previous.pitch.midi) +
            abs(current.pitch.midi - following.pitch.midi)
        )
        replacement_distance = (
            abs(replacement - previous.pitch.midi) +
            abs(replacement - following.pitch.midi)
        )
        if original_distance >= 22 and replacement_distance <= 6:
            current.pitch.midi = replacement
            corrected += 1
    return corrected


def _add_violin_double_stops(part, grid):
    """Add sparse, key-aware supporting notes to a violin melody.

    The generated solo line has no reliable chord track of its own, so the
    detected key supplies the harmonic context.  This deliberately favours
    lower diatonic thirds, sixths and octaves and only colours structurally
    useful melody notes.  The melody pitch and its duration are never changed.
    """
    melody_notes = [event for event in part.recurse().notes
                    if isinstance(event, note.Note)]
    if len(melody_notes) < 2:
        return 0

    try:
        scale_pitch_classes = {
            scale_pitch.pitchClass
            for scale_pitch in _key_for_grid(grid).getScale().getPitches('G3', 'E7')
        }
    except Exception:
        scale_pitch_classes = set(range(12))

    try:
        beats_per_bar = float(meter.TimeSignature(grid.time_signature).barDuration.quarterLength)
    except Exception:
        beats_per_bar = 4.0

    added = 0
    last_double_stop_offset = -99.0
    maximum_double_stops = max(1, len(melody_notes) // 20)
    minimum_spacing = max(3.0, min(beats_per_bar, 4.0))
    for index, melody in enumerate(melody_notes):
        if added >= maximum_double_stops:
            break
        offset = float(melody.offset)
        duration = float(melody.quarterLength)
        next_offset = (float(melody_notes[index + 1].offset)
                       if index + 1 < len(melody_notes) else None)
        phrase_end = next_offset is None or next_offset - (offset + duration) >= 0.25
        downbeat = abs((offset % beats_per_bar)) < 0.06

        # Long notes carry most of the harmonic colour.  A shorter note can
        # receive a double stop only when it lands on a strong structural beat.
        if not (duration >= 1.25 or
                (duration >= 0.75 and phrase_end and downbeat)):
            continue
        if offset - last_double_stop_offset < minimum_spacing:
            continue

        melody_midi = melody.pitch.midi
        # A lower third is most natural; a sixth or octave is a fallback when
        # the third falls outside the detected scale or violin's low register.
        support_candidates = [
            melody_midi - interval for interval in (3, 4, 8, 9, 12)
        ]
        support_midi = next((candidate for candidate in support_candidates
                             if 55 <= candidate <= 96
                             and candidate % 12 in scale_pitch_classes), None)
        if support_midi is None or not 55 <= melody_midi <= 103:
            continue

        double_stop = chord.Chord(
            [support_midi, melody_midi],
            quarterLength=melody.quarterLength,
        )
        if melody.volume.velocity is not None:
            double_stop.volume.velocity = melody.volume.velocity
        double_stop.articulations = deepcopy(melody.articulations)
        double_stop.expressions = deepcopy(melody.expressions)
        double_stop.tie = deepcopy(melody.tie)
        part.replace(melody, double_stop)
        last_double_stop_offset = offset
        added += 1
    return added


def _piano_score_from_midi(midi_path, grid):
    """Create readable piano notation from a detailed detector performance.

    Detector MIDI is intentionally richer than conventional engraving: chord
    tones have slightly different attacks/releases and residual overtones can
    become tiny overlapping notes.  Collapse that performance detail into
    stable chords and at most two voices per staff.  The source MIDI remains the
    playback authority; this function is the notation reduction.
    """
    midi = pretty_midi.PrettyMIDI(midi_path)
    source_notes = [n for source in midi.instruments for n in source.notes
                    if n.velocity > 0 and n.end > n.start]
    if not source_notes:
        raise ValueError("The piano transcription has no usable notes")

    lead_note_ids = {
        id(source_note)
        for source in midi.instruments
        if 'isolated melody' in source.name.lower()
        for source_note in source.notes
    }
    raw_events = []
    protected_lead = sorted(
        (n for n in source_notes if id(n) in lead_note_ids),
        key=lambda n: (n.start, n.pitch))
    # Start at a sixteenth grid, but use an eighth grid for dense detector
    # output. A transcription may contain a correct musical contour plus a
    # second layer of tiny re-attacks; printing every one creates the jagged,
    # scattered-looking notation seen on narrow phone screens. Playback keeps
    # the original MIDI, so this is intentionally an engraving-only choice.
    raw_density_span = max(
        1.0, max(note.end for note in source_notes) * grid.bpm / 60.0,
    )
    # Chord tones are one attack, not several rhythmic events. Count distinct
    # attacks so a rich but stable chord does not trigger the dense reduction.
    attack_starts = sorted(note.start for note in source_notes)
    attack_count = sum(
        1 for index, start in enumerate(attack_starts)
        if index == 0 or start - attack_starts[index - 1] > 0.080
    )
    raw_density = attack_count / raw_density_span
    dense_notation = raw_density > 3.2
    subdivision = 2 if dense_notation else 4
    minimum_written_duration = 1.0 / subdivision
    for source in source_notes:
        is_lead = id(source) in lead_note_ids
        if is_lead:
            # Melody has its own voice below. It must not be clustered with
            # accompaniment, reduced to a chord, or lose a repeated attack.
            continue
        if not is_lead and (source.velocity < 42 or source.end - source.start < 0.11):
            continue
        if is_lead and source.end - source.start < 0.035:
            continue
        raw_start = grid.seconds_to_quarter(source.start)
        raw_end = grid.seconds_to_quarter(source.end)
        raw_events.append((raw_start, raw_end, source))
    if not raw_events and not protected_lead:
        raise ValueError("The piano transcription has no confident notation events")

    # Notes in one piano chord commonly arrive from the detector a few
    # milliseconds apart. Cluster those raw onsets first, then quantize the
    # whole cluster once; quantizing each note independently can turn one
    # chord into an unintended arpeggio.
    raw_events.sort(key=lambda item: item[0])
    onset_clusters = []
    for raw_start, raw_end, source in raw_events:
        if (onset_clusters and
                source.start - onset_clusters[-1][0][2].start <= 0.080 and
                not any(id(source) in lead_note_ids and id(item[2]) in lead_note_ids
                        for item in onset_clusters[-1])):
            onset_clusters[-1].append((raw_start, raw_end, source))
        else:
            onset_clusters.append([(raw_start, raw_end, source)])

    events = []
    for cluster in onset_clusters:
        starts = sorted(item[0] for item in cluster)
        shared_start = starts[len(starts) // 2]
        start = round(shared_start * subdivision) / subdivision
        for _, raw_end, source in cluster:
            end = round(raw_end * subdivision) / subdivision
            end = max(start + minimum_written_duration, end)
            events.append((start, end, source))

    # Detector output often gives chord tones slightly different release times.
    # Group by shared onset so a chord is written and played once, rather than
    # as several overlapping voices.
    grouped = {}
    for start, end, source in events:
        grouped.setdefault(start, []).append((end, source))

    right_hand, left_hand = stream.PartStaff(), stream.PartStaff()
    right_hand.partName, left_hand.partName = 'Piano Right Hand', 'Piano Left Hand'
    right_hand.insert(0, instrument.Piano())
    left_hand.insert(0, instrument.Piano())
    for staff_part, staff_clef in ((right_hand, clef.TrebleClef()), (left_hand, clef.BassClef())):
        staff_part.insert(0, staff_clef)
        staff_part.insert(0, tempo.MetronomeMark(number=grid.bpm))
        staff_part.insert(0, meter.TimeSignature(grid.time_signature))
        try:
            staff_part.insert(0, _key_for_grid(grid))
        except Exception:
            pass

    hand_events = {right_hand: [], left_hand: []}
    for start, event_notes in sorted(grouped.items()):
        assigned = {right_hand: [], left_hand: []}
        for end, source in event_notes:
            destination = (right_hand if id(source) in lead_note_ids or
                           source.pitch >= 60 else left_hand)
            assigned[destination].append((end, source))

        # In an entirely low passage, keep the top line visible in treble
        # instead of leaving the right hand empty and changing the split for
        # every following chord.
        if not protected_lead and not assigned[right_hand] and assigned[left_hand]:
            promoted = max(assigned[left_hand], key=lambda item: item[1].pitch)
            assigned[left_hand].remove(promoted)
            assigned[right_hand].append(promoted)

        for destination, sources in assigned.items():
            if sources:
                # Keep the printed chord compact. A transcription can hear
                # many resonance/duplicate tones, but a dense four-note stack
                # on every attack is difficult to read on a phone. Playback
                # keeps the complete arranged MIDI; this only reduces the
                # engraving to a practical piano voicing.
                # A dyad in the right hand and one supporting bass note read
                # cleanly at phone scale. The detailed chord texture stays in
                # the performance MIDI used by the audio renderer.
                max_printed_tones = (
                    2 if destination is right_hand else 1
                ) if dense_notation else (
                    3 if destination is right_hand else 2
                )
                if destination is right_hand and protected_lead:
                    nearby_lead = sum(
                        abs(grid.seconds_to_quarter(n.start) - start) <= .125
                        for n in protected_lead)
                    max_printed_tones = max(1, max_printed_tones - nearby_lead)
                ranked = sorted(
                    sources,
                    key=lambda item: (
                        id(item[1]) in lead_note_ids,
                        item[1].velocity,
                        item[0] - start,
                    ),
                    reverse=True,
                )[:max_printed_tones]
                ranked.sort(key=lambda item: item[1].pitch)
                releases = sorted(end for end, _ in ranked)
                common_end = releases[len(releases) // 2]
                has_lead = any(id(source) in lead_note_ids for _, source in ranked)
                hand_events[destination].append({
                    'start': start,
                    'end': common_end,
                    'sources': [source for _, source in ranked],
                    'has_lead': has_lead,
                })

    for destination, events_for_hand in hand_events.items():
        voices = []
        for index, record in enumerate(events_for_hand):
            start = record['start']
            end = max(start + minimum_written_duration, record['end'])
            next_start = (events_for_hand[index + 1]['start']
                          if index + 1 < len(events_for_hand) else None)
            # Accompaniment releases are performance/pedal information, not
            # extra notation voices. End them at the next written attack.
            if next_start is not None and not record['has_lead']:
                end = min(end, max(start + minimum_written_duration, next_start))
            pitches = sorted({source.pitch for source in record['sources']})
            event = (note.Note(pitches[0], quarterLength=end - start)
                     if len(pitches) == 1 else
                     chord.Chord(pitches, quarterLength=end - start))
            event.volume.velocity = max(source.velocity for source in record['sources'])

            slot = next((voice for voice in voices if voice['end'] <= start), None)
            if slot is None and len(voices) < 2:
                slot = {
                    'stream': stream.Voice(id=len(voices) + 1),
                    'end': 0.0,
                    'last_event': None,
                    'last_start': 0.0,
                }
                voices.append(slot)
            if slot is None:
                # Never create a third engraving voice. Shorten the earliest
                # sustaining event at this new attack while retaining both
                # note onsets and a minimum sixteenth duration.
                slot = min(voices, key=lambda voice: voice['end'])
                previous = slot['last_event']
                shortened = max(minimum_written_duration, start - slot['last_start'])
                previous.duration = music21.duration.Duration(shortened)
                slot['end'] = start
            slot['stream'].insert(start, event)
            slot['end'] = end
            slot['last_event'] = event
            slot['last_start'] = start
        if len(voices) == 1:
            for event in list(voices[0]['stream'].notes):
                destination.insert(event.offset, event)
        else:
            for voice in voices:
                destination.insert(0, voice['stream'])

    score = stream.Score()
    if protected_lead:
        # Place the complete protected melody above the existing support.
        # Use a finer rhythmic grid than the accompaniment reduction. Releases
        # are clipped for engraving only; performance MIDI remains untouched.
        if not right_hand.getElementsByClass(stream.Voice):
            support_voice = stream.Voice(id=2)
            for item in list(right_hand.notes):
                offset = item.offset
                right_hand.remove(item)
                support_voice.insert(offset, item)
            if support_voice.notes:
                right_hand.insert(0, support_voice)
        else:
            for index, voice in enumerate(right_hand.getElementsByClass(stream.Voice), 2):
                voice.id = index
        lead_voices = []
        lead_starts = [round(grid.seconds_to_quarter(n.start) * 8) / 8
                       for n in protected_lead]
        for index, source in enumerate(protected_lead):
            start = lead_starts[index]
            end = max(start + .125, round(grid.seconds_to_quarter(source.end) * 8) / 8)
            if (index + 1 < len(lead_starts) and lead_starts[index + 1] > start
                    and protected_lead[index + 1].pitch == source.pitch):
                end = min(end, lead_starts[index + 1])
            written = note.Note(source.pitch, quarterLength=end - start)
            written.volume.velocity = source.velocity
            written.stemDirection = 'up'
            slot = next((v for v in lead_voices if v['end'] <= start), None)
            if slot is None:
                slot = {'stream': stream.Voice(id=f'lead{len(lead_voices)+1}'), 'end': 0.}
                lead_voices.append(slot)
            slot['stream'].insert(start, written)
            slot['end'] = end
        for slot in lead_voices:
            right_hand.insert(0, slot['stream'])
    score.insert(0, right_hand)
    score.insert(0, left_hand)
    group = layout.StaffGroup([right_hand, left_hand], name='Piano', symbol='brace', barTogether=True)
    score.insert(0, group)
    return score


def _normalize_musicxml_durations(score, subdivision=8):
    """Snap performed durations to an engravable grid before MusicXML export.

    Detection and playback may retain small release overlaps (for example
    0.16 quarter notes), but music notation requires durations that can be
    represented by conventional notes, dots, ties, or rests.
    """
    step = 1.0 / subdivision
    for element in score.recurse().notesAndRests:
        try:
            offset = float(element.offset)
            element.offset = round(offset / step) * step
        except (TypeError, ValueError):
            pass
        try:
            value = float(element.duration.quarterLength)
        except (TypeError, ValueError):
            value = step
        snapped = max(step, round(value / step) * step)
        element.duration = music21.duration.Duration(snapped)
    return score


def _snap_quarter_offset(value, subdivision=8):
    step = 1.0 / subdivision
    return round(float(value) / step) * step


def _insert_timeline_marker(part, quarter_offset, marker):
    """Insert tempo/key metadata into an existing measure when necessary."""
    offset = _snap_quarter_offset(quarter_offset)
    measures = list(part.getElementsByClass(stream.Measure))
    if not measures:
        part.insert(offset, marker)
        return True
    musical_end = max(
        (float(event.getOffsetInHierarchy(part)) +
         float(event.duration.quarterLength)
         for event in part.recurse().notesAndRests),
        default=0.0,
    )
    if offset > musical_end + 0.125:
        return False
    selected = None
    for measure_item in measures:
        measure_start = float(measure_item.offset)
        measure_end = measure_start + float(measure_item.barDuration.quarterLength)
        if measure_start <= offset < measure_end:
            selected = measure_item
            break
    if selected is None:
        selected = measures[-1]
    selected.insert(max(0.0, offset - float(selected.offset)), marker)
    return True


def _sanitize_musicxml_export(score, subdivision=8):
    """Remove micro-fragments Music21 can create at measure boundaries.

    ``makeNotation`` may split an otherwise quantized note using a tiny float
    remainder (for example 1/512 quarterLength, rendered as a 2048th note).
    Such a remainder is inaudible and MusicXML cannot express it. Snap all
    nested voice offsets/durations one last time and discard only generated
    rests shorter than the notation grid.
    """
    step = 1.0 / subdivision
    for container in list(score.recurse().getElementsByClass((stream.Measure, stream.Voice))):
        # Directions and signatures also participate in MusicXML's cursor.
        # An off-grid key change can make the exporter synthesize a microscopic
        # rest even when every visible note is already quantized.
        for element in container:
            if isinstance(element, (stream.Stream, note.GeneralNote)):
                continue
            try:
                element.offset = _snap_quarter_offset(element.offset, subdivision)
            except (TypeError, ValueError):
                pass
        for event in list(container.notesAndRests):
            try:
                duration_value = float(event.duration.quarterLength)
            except (TypeError, ValueError):
                duration_value = 0.0
            if isinstance(event, note.Rest) and duration_value < step - 1e-9:
                container.remove(event)
                continue
            try:
                event.offset = round(float(event.offset) / step) * step
            except (TypeError, ValueError):
                pass
            event.duration = music21.duration.Duration(
                max(step, round(duration_value / step) * step)
            )
    _normalize_musicxml_durations(score, subdivision=subdivision)
    # MIDI-derived notation in this pipeline is intentionally quantized to a
    # straight eighth-note grid. Tuplets found here are therefore conversion
    # residue, not authored triplets. Some Music21 versions retain an old
    # Tuplet.durationNormal (such as 1/512) after the containing rest has been
    # rounded, and the MusicXML exporter then fails on that hidden value.
    for event in score.recurse().notesAndRests:
        value = max(step, round(float(event.duration.quarterLength) / step) * step)
        clean_duration = music21.duration.Duration(value)
        if subdivision % 3 != 0:
            clean_duration.tuplets = ()
        event.duration = clean_duration
    _rebuild_meter_beams(score)
    return score


def _rebuild_meter_beams(score):
    """Recreate beams after the final rhythmic snap, measure by measure.

    ``makeNotation`` assigns beams before the last exporter-safety pass.  If a
    detector duration is subsequently rounded, its old beam object can connect
    notes which no longer share a beat group.  Clearing that stale metadata and
    invoking Music21's meter-aware beamer on each individual voice keeps beams
    inside their proper beat and bar boundaries.
    """
    for measure_item in score.recurse().getElementsByClass(stream.Measure):
        voice_streams = list(measure_item.voices) or [measure_item]
        for voice_stream in voice_streams:
            for event in voice_stream.notes:
                event.beams = beam.Beams()
            try:
                voice_stream.makeBeams(inPlace=True, setStemDirections=False)
            except Exception:
                # A partial final bar or a third-party score missing a local
                # time signature is still readable with flags rather than a
                # malformed cross-bar beam.
                for event in voice_stream.notes:
                    event.beams = beam.Beams()


def _debug_notation_events(score):
    """Print canonical engraving events when AUGMENT_NOTATION_DEBUG=1."""
    if os.environ.get('AUGMENT_NOTATION_DEBUG') != '1':
        return
    for part_index, notation_part in enumerate(score.parts or [score], start=1):
        for measure_item in notation_part.recurse().getElementsByClass(stream.Measure):
            voice_streams = list(measure_item.voices) or [measure_item]
            for voice_index, voice_stream in enumerate(voice_streams, start=1):
                for event in voice_stream.notes:
                    pitches = (','.join(p.nameWithOctave for p in event.pitches)
                               if isinstance(event, chord.Chord)
                               else event.pitch.nameWithOctave)
                    print(
                        '[notation] '
                        f'part={part_index} measure={measure_item.number} '
                        f'voice={voice_index} staff={getattr(event, "staff", "?")} '
                        f'pitch={pitches} start_beat={float(event.offset):.3f} '
                        f'duration={float(event.duration.quarterLength):.3f}'
                    )


def _write_musicxml(score, path, subdivision=8):
    """Write an export-safe score after final notation-generated cleanup."""
    _sanitize_musicxml_export(score, subdivision=subdivision)
    _debug_notation_events(score)
    try:
        written_path = score.write('musicxml', fp=path)
    except music21.musicxml.xmlObjects.MusicXMLExportException:
        # The exporter may run another notation pass and introduce a new
        # microscopic boundary fragment. A second cleanup is deterministic
        # and preserves all events at eighth-note-or-longer resolution.
        _sanitize_musicxml_export(score, subdivision=subdivision)
        # The score already has measures, ties, rests and beams. Running
        # makeNotation again inside the exporter can recreate the same
        # inexpressible percussion rest after our cleanup. Export the cleaned
        # notation as-is on retry; canonical MIDI is never touched.
        written_path = score.write('musicxml', fp=path, makeNotation=False)
    _normalize_musicxml_voice_numbers(path)
    return written_path


def _normalize_musicxml_voice_numbers(xml_path):
    """Give every exported MusicXML voice a positive, distinct identifier.

    Music21 can serialize direct timeline events as ``<voice>0</voice>`` when
    they coexist with explicit ``Voice`` streams.  MuseScore 4 crashes while
    importing that otherwise readable multi-voice structure.  Voice labels
    identify independent engraving streams; remapping only a non-positive
    label does not alter pitches, timing, durations, staff assignment, ties,
    or performance MIDI.
    """
    import xml.etree.ElementTree as ET

    tree = ET.parse(xml_path)
    root = tree.getroot()
    # Music21 currently writes an un-namespaced score, but tolerate namespaced
    # MusicXML so this export safeguard works for other writers too.
    namespace = ''
    if root.tag.startswith('{'):
        namespace = root.tag[1:root.tag.index('}')]
        ET.register_namespace('', namespace)

    def tag(name):
        return f'{{{namespace}}}{name}' if namespace else name

    changed = False
    for part in root.findall(tag('part')):
        labels = [
            (voice.text or '').strip()
            for voice in part.iter(tag('voice'))
        ]
        used_positive = {
            int(label) for label in labels
            if label.isdigit() and int(label) > 0
        }
        staff_numbers = {
            (staff.text or '').strip()
            for staff in part.iter(tag('staff'))
            if (staff.text or '').strip()
        }
        # A lone Music21 ``voice 0`` imports in MuseScore. The failure is the
        # mixed 0/1/2 case in a grand staff, so avoid changing a harmless
        # single-staff stream or its Music21 round-trip.
        if not used_positive or len(staff_numbers) < 2:
            continue
        replacements = {}
        next_label = 1
        for voice in part.iter(tag('voice')):
            label = (voice.text or '').strip()
            try:
                is_non_positive = int(label) <= 0
            except ValueError:
                is_non_positive = False
            if not is_non_positive:
                continue
            if label not in replacements:
                while next_label in used_positive:
                    next_label += 1
                replacements[label] = str(next_label)
                used_positive.add(next_label)
            voice.text = replacements[label]
            changed = True
    if changed:
        tree.write(xml_path, encoding='utf-8', xml_declaration=True)


def validate_transcription(source_stem, midi_path):
    """Compare rendered symbolic melody to its source stem and report confidence.

    This is a quality signal, not a claim of perfect ground truth: commercial
    stems retain reverb and leakage, so a low score asks for review instead of
    silently presenting a bad transcription as certain.
    """
    import librosa
    import numpy as np
    try:
        source, sr = librosa.load(source_stem, sr=22050, mono=True)
        midi = pretty_midi.PrettyMIDI(midi_path)
        rendered = midi.synthesize(fs=sr)
        if len(source) < sr or len(rendered) < sr:
            return {"alignment_confidence": 0.0, "warning": "Audio is too short to validate."}
        # Quiet separated-stem sections can create NaNs in CQT spectra. They
        # are silence, not a reason to discard a valid vocal candidate.
        source_chroma = np.nan_to_num(
            np.abs(librosa.cqt(y=source, sr=sr, hop_length=512)), nan=0.0, posinf=0.0, neginf=0.0,
        )
        rendered_chroma = np.nan_to_num(
            np.abs(librosa.cqt(y=rendered, sr=sr, hop_length=512)), nan=0.0, posinf=0.0, neginf=0.0,
        )
        if not source_chroma.any() or not rendered_chroma.any():
            return {"alignment_confidence": 0.0, "warning": "Not enough pitched audio to validate."}
        # Keep original time positions and octave bins, with explicit silence
        # masks so quiet frames cannot create undefined cosine similarity.
        result = _fixed_time_pitch_similarity(source_chroma, rendered_chroma)
        confidence = result['alignment_confidence']
        if confidence < 0.45:
            result["warning"] = "Low melody alignment; review this section before performing it."
        return result
    except Exception as exc:
        return {"alignment_confidence": None, "warning": f"Validation unavailable: {exc}"}


def _fixed_time_pitch_similarity(source, rendered):
    """Compare octave-resolved spectra at identical times, including silence.

    This is spectral agreement, not a calibrated note-accuracy percentage.
    Padding retains missing introductions and endings instead of aligning them
    away with dynamic time warping.
    """
    import numpy as np
    length = max(source.shape[1], rendered.shape[1])
    source = np.pad(source, ((0, 0), (0, length - source.shape[1])))
    rendered = np.pad(rendered, ((0, 0), (0, length - rendered.shape[1])))
    source_norm = np.linalg.norm(source, axis=0)
    rendered_norm = np.linalg.norm(rendered, axis=0)
    source_active = source_norm > max(1e-9, float(source_norm.max()) * 0.01)
    rendered_active = rendered_norm > max(1e-9, float(rendered_norm.max()) * 0.01)
    union = source_active | rendered_active
    both = source_active & rendered_active
    similarity = np.zeros(length)
    similarity[both] = np.sum(source[:, both] * rendered[:, both], axis=0) / (
        source_norm[both] * rendered_norm[both])
    return {
        'alignment_confidence': round(float(similarity[union].mean()), 3) if union.any() else 0.0,
        'validation_method': 'fixed_time_octave_spectrum_v1',
        'missing_activity_fraction': round(float(np.sum(source_active & ~rendered_active)) /
                                           max(1, int(source_active.sum())), 3),
        'extra_activity_fraction': round(float(np.sum(rendered_active & ~source_active)) /
                                         max(1, int(rendered_active.sum())), 3),
    }


def _polyphonic_score_from_midi(midi_path, grid, subdivision=8, preserve_duplicates=False):
    """Preserve each detected attack and release in independent voices."""
    midi = pretty_midi.PrettyMIDI(midi_path)
    grouped = {}
    for track in midi.instruments:
        for event in track.notes:
            start = _snap_quarter_offset(grid.seconds_to_quarter(event.start), subdivision)
            end = max(start + 1.0 / subdivision,
                      _snap_quarter_offset(grid.seconds_to_quarter(event.end), subdivision))
            # Keep nearby repeated pitches in separate voices, even when
            # quantization places their attacks at the same written offset.
            group = grouped.setdefault((start, end), [])
            if preserve_duplicates and any(n.pitch == event.pitch for n in group):
                grouped.setdefault((start, end, len(grouped)), []).append(event)
            else:
                group.append(event)
    part = stream.Part()
    voices = []
    for identity, sources in sorted(grouped.items()):
        start, end = identity[:2]
        pitches = sorted(set(n.pitch for n in sources))
        event = (note.Note(pitches[0], quarterLength=end-start) if len(pitches) == 1
                 else chord.Chord(pitches, quarterLength=end-start))
        event.volume.velocity = max(n.velocity for n in sources)
        slot = next((v for v in voices if v[1] <= start), None)
        if slot is None:
            slot = [stream.Voice(id=len(voices)+1), 0]
            voices.append(slot)
        slot[0].insert(start, event)
        slot[1] = end
    for voice, _ in voices:
        if len(voices) == 1:
            for event in list(voice.notes):
                part.insert(event.offset, event)
        else:
            part.insert(0, voice)
    score = stream.Score([part])
    score._augment_notation_subdivision = subdivision
    return score


def _band_notation_subdivision(midi_path, grid):
    midi = pretty_midi.PrettyMIDI(midi_path)
    attacks = sorted({n.start for track in midi.instruments for n in track.notes})
    quarters = [grid.seconds_to_quarter(t) for t in attacks]
    triplet_hits = sum(abs(q - round(q * 3) / 3) < .02 and
                       abs(q - round(q * 4) / 4) > .03 for q in quarters)
    subdivision = 12 if triplet_hits >= max(4, len(quarters) * .25) else 8
    # OSMD cannot initialize the microscopic rest fragments generated by
    # finer grids. Keep every attack (including collisions in separate
    # voices), but never require smaller than a written 128th/tuplet glyph.
    maximum = 24 if subdivision == 12 else 32
    while subdivision < maximum and any(
            round(grid.seconds_to_quarter(a) * subdivision) ==
            round(grid.seconds_to_quarter(b) * subdivision)
            for a, b in zip(attacks, attacks[1:])):
        subdivision *= 2
    return subdivision


def _normalize_guitar_voice_ids(score):
    """Use MusicXML's positive voice identifiers for Solo Guitar voices.

    Music21 can turn the first independent voice into ``<voice>0</voice>``
    during ``makeNotation``.  Its own parser accepts that value, but
    MuseScore rejects the complete score once a Guitar measure has multiple
    voices.  Voice IDs identify concurrent streams only; renumbering them in
    each measure leaves every pitch, onset, duration, chord and tie intact.
    """
    for measure_item in score.recurse().getElementsByClass(stream.Measure):
        for index, voice_stream in enumerate(measure_item.voices, start=1):
            voice_stream.id = str(index)


def midi_to_musicxml(midi_path, xml_path, name, grid, role, title=None, artist='Generated by Augment', techniques=None, band_mode=False):
    """Quantize and annotate a part using the shared grid, then check range."""
    is_piano = name in ("Piano", "Synthesizer", "Organ") and not band_mode
    if name == 'Drums':
        score = music21.converter.parse(midi_path)
        score.quantize((4, 8, 16), processOffsets=True, processDurations=True, inPlace=True)
    elif is_piano:
        score = _piano_score_from_midi(midi_path, grid)
    elif band_mode and name != 'Drums':
        subdivision = _band_notation_subdivision(midi_path, grid)
        score = _polyphonic_score_from_midi(midi_path, grid,
            subdivision=subdivision, preserve_duplicates=True)
    elif name in {'Flute', 'Saxophone'} and not band_mode and role in ('melody', 'lead'):
        score = _flute_score_from_midi(midi_path, grid, instrument_name=name)
    elif role in ("melody", "lead", "bass") and name not in {'Guitar', 'Electric Guitar'}:
        score = _solo_score_from_midi(midi_path, name, grid)
    else:
        score = _polyphonic_score_from_midi(midi_path, grid)
    notation_subdivision = getattr(score, '_augment_notation_subdivision', 8)
    minimum_duration = 1.0 / notation_subdivision
    for el in score.recurse().notesAndRests:
        if el.duration.quarterLength < minimum_duration:
            el.duration = music21.duration.Duration(minimum_duration)
    if name != 'Drums':
        _fit_to_instrument(score, name)
    _normalize_musicxml_durations(score, subdivision=notation_subdivision)
    part = score.parts[0] if score.parts else score
    if name == 'Drums':
        part.partName = 'Drums (rhythm)'
        percussion_instrument = instrument.UnpitchedPercussion()
        part.insert(0, percussion_instrument)
        for existing_clef in list(part.recurse().getElementsByClass(clef.Clef)):
            if existing_clef.activeSite is not None:
                existing_clef.activeSite.remove(existing_clef)
        part.insert(0, clef.PercussionClef())
        part.insert(0, tempo.MetronomeMark(number=grid.bpm))
        part.insert(0, meter.TimeSignature(grid.time_signature))
        for pitched in list(part.recurse().getElementsByClass(note.Note)):
            drum_note = note.Unpitched()
            drum_note.duration = deepcopy(pitched.duration)
            drum_note.volume.velocity = pitched.volume.velocity
            midi_pitch = int(pitched.pitch.midi)
            drum_note.displayStep = 'F' if midi_pitch == 36 else ('C' if midi_pitch == 38 else 'G')
            drum_note.displayOctave = 4 if midi_pitch != 42 else 5
            drum_note.storedInstrument = percussion_instrument
            if pitched.activeSite is not None:
                pitched.activeSite.replace(pitched, drum_note)
        for drum_note in part.recurse().getElementsByClass(note.Unpitched):
            drum_note.storedInstrument = percussion_instrument
    elif not is_piano:
        part.partName = f"{name} ({role})"
        part.insert(0, _concert_instrument(name))
        part.insert(0, tempo.MetronomeMark(number=grid.bpm))
        part.insert(0, meter.TimeSignature(grid.time_signature))
        try: part.insert(0, _key_for_grid(grid))
        except Exception: pass
        # Do not invent violin double stops for generated band parts.  A key
        # signature alone cannot identify the song's chord at each moment;
        # guessed harmony notes made the Classical preset sound out of tune
        # and cluttered an otherwise monophonic violin staff.
    # Retain genuine local tempo movement and confident key changes. The
    # initial mark/signature above remains the backward-compatible default.
    for notation_part in (score.parts if is_piano else [part]):
        for point in grid.tempo_map[1:]:
            _insert_timeline_marker(
                notation_part, point['offset'],
                tempo.MetronomeMark(number=point['bpm']),
            )
        key_sections = list(grid.key_sections)
        for index, section in enumerate(key_sections[1:], start=1):
            following = (key_sections[index + 1]
                         if index + 1 < len(key_sections) else None)
            # A local chroma window can briefly prefer a neighbouring key.
            # Engrave a modulation only when it is confident and persists into
            # the following phrase; one-window guesses created signatures at
            # the far right of otherwise ordinary measures.
            persistent = (
                following is not None and
                following.get('key') == section.get('key') and
                following.get('mode') == section.get('mode') and
                following.get('confidence', 0.0) >= 0.08
            )
            if section.get('confidence', 0.0) >= 0.08 and persistent:
                try:
                    _insert_timeline_marker(
                        notation_part,
                        grid.seconds_to_quarter(section['start_seconds']),
                        key.Key(section['key'], section['mode']),
                    )
                except Exception:
                    pass
    # Put the direct timeline events into real measures before engraving.
    # Without this, music21 can export them as voice 0; OSMD and MuseScore
    # then render the bars as empty even though the MusicXML contains notes.
    for notation_part in (score.parts if is_piano else [part]):
        # MIDI import already returns measured parts for polyphonic guitar,
        # keyboard and drums. Measuring those streams a second time treats
        # complete Measure objects as timed events and can expand a four-minute
        # song to more than sixteen minutes.
        if not notation_part.getElementsByClass(stream.Measure):
            notation_part.makeMeasures(inPlace=True)
    if not is_piano and role in ("melody", "lead", "bass"):
        _add_phrase_slurs(part)
        _apply_detected_techniques(part, techniques, grid)
    # Turn the cleaned beat-grid events into readable bars, rests and ties.
    score.makeNotation(inPlace=True)
    if name in {'Guitar', 'Electric Guitar'}:
        _normalize_guitar_voice_ids(score)
    _normalize_musicxml_durations(score, subdivision=notation_subdivision)
    _add_score_formatting(
        score,
        part,
        title or (f"{name} Solo Transcription" if role in ("melody", "lead") else f"{name} Part"),
        artist,
        grid,
    )
    # A late first attack is not evidence of a pickup bar. Preserve leading
    # rests on the shared audio timeline rather than shortening measure one.
    _write_musicxml(score, xml_path, subdivision=notation_subdivision)
    if name in TUNINGS:
        fingering_path = None
        if name in {'Guitar', 'Electric Guitar'}:
            # Solo Guitar persists the exact string/fret assignment selected
            # by the arranger beside its source MIDI.  The performance
            # renderer appends ``.arranged.mid`` without changing attacks, so
            # resolve that sidecar rather than inventing a second fingering at
            # notation time.
            candidates = [midi_path + '.fingering.json']
            if midi_path.endswith('.arranged.mid'):
                candidates.insert(
                    0,
                    midi_path[:-len('.arranged.mid')] + '.mid.fingering.json',
                )
            fingering_path = next(
                (candidate for candidate in candidates
                 if os.path.isfile(candidate)),
                None,
            )
        add_tablature_markup(
            xml_path, name, fingering_path=fingering_path,
            strict_canonical=(name in {'Guitar', 'Electric Guitar'} and fingering_path is not None),
        )
    _add_musicxml_credits(xml_path, title=title, artist=artist)


def _compact_band_keyboard_events(source_score):
    """Reduce a detailed grand staff to readable one-staff band comping."""
    source_events = []
    for source_part in source_score.parts or [source_score]:
        for event in source_part.recurse().notes:
            try:
                start = float(event.getOffsetInHierarchy(source_part))
            except Exception:
                start = float(event.offset)
            duration = max(0.125, float(event.duration.quarterLength))
            pitches = (list(event.pitches) if isinstance(event, chord.Chord)
                       else [event.pitch])
            source_events.append((start, start + duration, pitches,
                                  event.volume.velocity or 72))
    if not source_events:
        return []
    score_end = max(end for _, end, _, _ in source_events)
    reduced = []
    beat = 0.0
    while beat < score_end:
        active = [entry for entry in source_events
                  if entry[0] < beat + 0.5 and entry[1] > beat]
        if active:
            weighted = {}
            for _, _, pitches, velocity in active:
                for source_pitch in pitches:
                    midi = int(source_pitch.midi)
                    while midi < 48:
                        midi += 12
                    while midi > 84:
                        midi -= 12
                    weighted[midi] = max(weighted.get(midi, 0), int(velocity))
            candidates = sorted(weighted)
            if len(candidates) > 3:
                # Retain a compact low/middle/high voicing instead of stacking
                # both complete hands onto a single conductor staff.
                candidates = [
                    candidates[0], candidates[len(candidates) // 2], candidates[-1]
                ]
            pitches = tuple(dict.fromkeys(candidates))
            if pitches:
                velocity = max(weighted[pitch] for pitch in pitches)
                reduced.append((beat, pitches, min(88, velocity)))
        beat += 1.0
    return reduced


def _band_staff_from_part(result, grid):
    """Rebuild one clean concert-pitch staff for one configured band part."""
    source_score = music21.converter.parse(result['musicxml'])
    destination = stream.Part()
    label = result.get('display_name') or result['instrument']
    destination.partName = label
    destination.partAbbreviation = label[:12]
    selected_instrument = (_concert_instrument(result['instrument'])
                           if result['instrument'] != 'Drums'
                           else instrument.UnpitchedPercussion())
    selected_instrument.instrumentName = label
    selected_instrument.instrumentAbbreviation = label[:12]
    destination.insert(0, selected_instrument)
    # Full Band is a view of the performance, not a new comping arrangement.
    compact_keyboard = False
    destination.insert(0, clef.PercussionClef() if result['instrument'] == 'Drums'
                       else (clef.TrebleClef() if compact_keyboard
                             else clef.bestClef(source_score, recurse=True)))
    destination.insert(0, tempo.MetronomeMark(number=grid.bpm))
    destination.insert(0, meter.TimeSignature(grid.time_signature))
    try:
        destination.insert(0, _key_for_grid(grid))
    except Exception:
        pass

    if compact_keyboard:
        for offset, pitches, velocity in _compact_band_keyboard_events(source_score):
            copied = (note.Note(pitches[0], quarterLength=0.75)
                      if len(pitches) == 1
                      else chord.Chord(pitches, quarterLength=0.75))
            copied.volume.velocity = velocity
            destination.insert(offset, copied)
    else:
        source_parts = list(source_score.parts) or [source_score]
        # Fretted-instrument exports contain a second TAB representation of
        # the same performance.  TAB is useful in the individual part, but it
        # must not be copied back into the conductor staff as another voice:
        # doing so duplicates every note and can make MusicXML readers advance
        # the staff by roughly twice its real duration.
        notation_parts = [
            source_part for source_part in source_parts
            if not source_part.recurse().getElementsByClass(clef.TabClef)
        ]
        if notation_parts:
            source_parts = notation_parts
        seen_events = set()
        for source_part in source_parts:
            for event in source_part.recurse().notes:
                try:
                    offset = float(event.getOffsetInHierarchy(source_part))
                except Exception:
                    offset = float(event.offset)
                if isinstance(event, chord.Chord):
                    pitch_identity = tuple(sorted(p.midi for p in event.pitches))
                elif isinstance(event, note.Note):
                    pitch_identity = (event.pitch.midi,)
                else:
                    pitch_identity = (getattr(event, 'displayName', repr(event)),)
                identity = (
                    round(offset, 6),
                    round(float(event.duration.quarterLength), 6),
                    pitch_identity,
                )
                if identity in seen_events:
                    continue
                seen_events.add(identity)
                copied = deepcopy(event)
                if isinstance(copied, note.Unpitched):
                    copied.storedInstrument = selected_instrument
                destination.insert(offset, copied)
    # Flattening source voices must not turn overlapping holds into an
    # overfull sequential measure. Reallocate independent conductor voices.
    # Identical written attacks/releases belong to one chord, not a separate
    # stem/rest lane per pitch. Keep different holds and tie states separate.
    pitched_groups = {}
    for event in list(destination.notes):
        if not isinstance(event, (note.Note, chord.Chord)):
            continue
        event_notes = list(event.notes) if isinstance(event, chord.Chord) else [event]
        tie_states = tuple(sorted({getattr(n.tie, 'type', None) or ''
                                   for n in event_notes}))
        key = (event.offset, event.duration.quarterLength, tie_states)
        pitched_groups.setdefault(key, []).append(event)
    for (offset, _, _), group in pitched_groups.items():
        if len(group) < 2:
            continue
        members = [deepcopy(n) for event in group
                   for n in (event.notes if isinstance(event, chord.Chord) else [event])]
        # Do not merge genuine unisons from independent voices.
        if len({n.pitch.midi for n in members}) != len(members):
            continue
        combined_chord = chord.Chord(members)
        combined_chord.duration = deepcopy(group[0].duration)
        for event in group:
            destination.remove(event)
        destination.insert(offset, combined_chord)
    events = sorted(list(destination.notes), key=lambda n: float(n.offset))
    voices = []
    for event in events:
        offset = float(event.offset)
        destination.remove(event)
        slot = next((v for v in voices if v[1] <= offset), None)
        if slot is None:
            slot = [stream.Voice(id=len(voices) + 1), 0]
            voices.append(slot)
        slot[0].insert(offset, event)
        slot[1] = offset + float(event.duration.quarterLength)
    for voice, _ in voices:
        destination.insert(0, voice)
    _normalize_musicxml_durations(
        destination, subdivision=result.get('notation_subdivision', 8))
    return destination


def _build_band_score(results, grid, title=None, artist=None):
    """Create an orchestra-style score with one ordered staff per selection."""
    staves = [_band_staff_from_part(result, grid) for result in results]
    bar_length = float(meter.TimeSignature(
        grid.time_signature).barDuration.quarterLength)
    latest_end = max(
        (float(event.getOffsetInHierarchy(staff)) +
         float(event.duration.quarterLength)
         for staff in staves for event in staff.recurse().notes),
        default=bar_length,
    )
    score_end = max(bar_length, math.ceil(latest_end / bar_length) * bar_length)
    for staff in staves:
        for point in grid.tempo_map[1:]:
            _insert_timeline_marker(
                staff, point['offset'], tempo.MetronomeMark(number=point['bpm']))
        staff_end = max(
            (float(event.getOffsetInHierarchy(staff)) +
             float(event.duration.quarterLength)
             for event in staff.recurse().notes),
            default=0.0,
        )
        if staff_end < score_end:
            staff.insert(staff_end, note.Rest(quarterLength=score_end - staff_end))
        subdivisions = [result.get('notation_subdivision', 8) for result in results]
        # An LCM of straight and triplet grids can create sub-128th rests
        # between voices. Use a readable common engraving grid instead;
        # the canonical performance MIDI is not changed.
        subdivision = (min(24, math.lcm(*subdivisions))
                       if any(value % 3 == 0 for value in subdivisions)
                       else min(32, max(subdivisions)))
        _normalize_musicxml_durations(staff, subdivision=subdivision)
        staff.makeMeasures(inPlace=True)
        staff.makeNotation(inPlace=True)
        _normalize_musicxml_durations(staff, subdivision=subdivision)
    combined = stream.Score()
    combined._augment_notation_subdivision = subdivision
    for staff in staves:
        # Score parts are concurrent players, not sequential musical events.
        # append() advances the insertion cursor and previously placed Guitar
        # after Violin and Cello after Guitar in the Full Band timeline.
        combined.insert(0, staff)
    combined.insert(0, layout.StaffGroup(
        staves, name='Band', abbreviation='Band', symbol='bracket',
        barTogether=True,
    ))
    combined.metadata = music21.metadata.Metadata()
    combined.metadata.title = title or 'Full Band Score'
    combined.metadata.composer = artist or 'Arranged by Augment'
    return combined


def _xml_pitch_midi(note_element):
    namespace = note_element.tag.split('}')[0] + '}' if note_element.tag.startswith('{') else ''
    tag = lambda name: f'{namespace}{name}'
    pitch = note_element.find(tag('pitch'))
    if pitch is None:
        return None
    steps = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
    step = pitch.findtext(tag('step'))
    octave = pitch.findtext(tag('octave'))
    if step not in steps or octave is None:
        return None
    alter = int(float(pitch.findtext(tag('alter'), "0")))
    return steps[step] + (int(octave) + 1) * 12 + alter


def add_tablature_markup(xml_path, instrument_name, fingering_path=None,
                         strict_canonical=False):
    """Add a synchronized TAB part without changing standard-staff timing.

    The previous two-staff implementation flattened every voice behind one
    synthetic ``backup``. Polyphonic Guitar measures then acquired displaced
    attacks. A separate TAB part can reuse the exact original MusicXML stream
    (including its real voices/backups) while adding only clef and technical
    string/fret information.
    """
    tree = ET.parse(xml_path)
    document_root = tree.getroot()
    tuning = TUNINGS[instrument_name]
    namespace = (document_root.tag.split('}')[0] + '}'
                 if document_root.tag.startswith('{') else '')
    tag = lambda name: f'{namespace}{name}'
    part_list = document_root.find(tag('part-list'))
    source_part = document_root.find(tag('part'))
    if part_list is None or source_part is None:
        return
    if any((item.findtext(tag('part-name')) or '').endswith(' TAB')
           for item in part_list.findall(tag('score-part'))):
        return

    source_id = source_part.get('id') or 'P1'
    tab_id = source_id + '_TAB'
    source_definition = next(
        (item for item in part_list.findall(tag('score-part'))
         if item.get('id') == source_id), None)
    if source_definition is None:
        return
    tab_definition = deepcopy(source_definition)
    tab_definition.set('id', tab_id)
    part_name = tab_definition.find(tag('part-name'))
    if part_name is None:
        part_name = ET.SubElement(tab_definition, tag('part-name'))
    part_name.text = f'{instrument_name} TAB'
    abbreviation = tab_definition.find(tag('part-abbreviation'))
    if abbreviation is not None:
        abbreviation.text = 'TAB'
    definition_index = list(part_list).index(source_definition)
    part_list.insert(definition_index + 1, tab_definition)

    tab_part = deepcopy(source_part)
    tab_part.set('id', tab_id)
    source_index = list(document_root).index(source_part)
    document_root.insert(source_index + 1, tab_part)

    saved_fingerings = {}
    saved_fingering_events = []
    if fingering_path and os.path.isfile(fingering_path):
        try:
            with open(fingering_path, encoding='utf-8') as handle:
                payload = json.load(handle)
            for event in payload.get('events', ()): 
                key = (round(float(event['start_quarter']) * 8) / 8,
                       int(event['pitch']))
                position = (int(event['string']), int(event['fret']))
                saved_fingerings.setdefault(key, []).append(position)
                saved_fingering_events.append({
                    'start_quarter': key[0], 'pitch': key[1],
                    'position': position, 'used': False,
                })
        except (OSError, ValueError, KeyError, TypeError):
            saved_fingerings = {}

    divisions = 1
    beats, beat_type = 4, 4
    measure_start = 0.0
    timed_notes = []
    for measure_obj in tab_part.findall(tag('measure')):
        attributes = measure_obj.find(tag('attributes'))
        if attributes is not None:
            divisions = int(attributes.findtext(tag('divisions'), divisions))
            time_element = attributes.find(tag('time'))
            if time_element is not None:
                beats = int(time_element.findtext(tag('beats'), beats))
                beat_type = int(time_element.findtext(tag('beat-type'), beat_type))
            for old in list(attributes.findall(tag('clef'))):
                attributes.remove(old)
            for old in list(attributes.findall(tag('staff-details'))):
                attributes.remove(old)
            details = ET.SubElement(attributes, tag('staff-details'))
            ET.SubElement(details, tag('staff-lines')).text = str(len(tuning))
            for line_number, open_midi in enumerate(reversed(tuning), 1):
                tuning_element = ET.SubElement(
                    details, tag('staff-tuning'), line=str(line_number))
                pitch_value = music21.pitch.Pitch(midi=open_midi)
                ET.SubElement(tuning_element, tag('tuning-step')).text = pitch_value.step
                ET.SubElement(tuning_element, tag('tuning-octave')).text = str(pitch_value.octave)
            tab_clef = ET.SubElement(attributes, tag('clef'))
            ET.SubElement(tab_clef, tag('sign')).text = 'TAB'
            ET.SubElement(tab_clef, tag('line')).text = '5'

        cursor = 0
        previous_onset = 0
        for child in list(measure_obj):
            duration = int(float(child.findtext(tag('duration'), '0')))
            if child.tag == tag('backup'):
                cursor -= duration
            elif child.tag == tag('forward'):
                cursor += duration
            elif child.tag == tag('note'):
                for staff in list(child.findall(tag('staff'))):
                    child.remove(staff)
                chord_member = child.find(tag('chord')) is not None
                onset = previous_onset if chord_member else cursor
                if not chord_member:
                    previous_onset = onset
                    cursor += duration
                pitch_midi = _xml_pitch_midi(child)
                if pitch_midi is not None:
                    timed_notes.append((
                        round((measure_start + onset / max(1, divisions)) * 8) / 8,
                        pitch_midi,
                        child,
                    ))
        measure_start += beats * 4.0 / beat_type

    from solo_guitar_arranger import guitar_string_frets
    groups = {}
    for onset, pitch_midi, note_element in timed_notes:
        groups.setdefault(onset, []).append((pitch_midi, note_element))
    previous_position = None
    for onset, note_group in sorted(groups.items()):
        pitches = sorted({pitch for pitch, _ in note_group})
        chosen = []
        valid_saved = True
        used_strings = set()
        for pitch_midi in pitches:
            positions = saved_fingerings.get((onset, pitch_midi), [])
            position = positions.pop(0) if positions else None
            if position is not None:
                matched = next((event for event in saved_fingering_events
                                if not event['used'] and event['pitch'] == pitch_midi and
                                event['start_quarter'] == onset and
                                event['position'] == position), None)
                if matched is not None:
                    matched['used'] = True
            if position is None and saved_fingering_events:
                # The score may quantize a source attack by one small grid
                # step.  Match the nearest same-pitch canonical event within
                # the existing notation tolerance; never calculate a new
                # fret/string pair from the MIDI pitch.
                candidates = [event for event in saved_fingering_events
                              if not event['used'] and event['pitch'] == pitch_midi and
                              abs(event['start_quarter'] - onset) <= .126 and
                              event['position'][0] not in used_strings]
                if candidates:
                    selected = min(candidates,
                                   key=lambda event: abs(event['start_quarter'] - onset))
                    position = selected['position']
                    selected['used'] = True
            if position is None or position[0] in used_strings:
                valid_saved = False
                break
            chosen.append(position)
            used_strings.add(position[0])
        if not valid_saved and not strict_canonical:
            chosen = guitar_string_frets(
                pitches, previous_position=previous_position) or []
        elif not valid_saved:
            # A canonical Guitar export must never silently create a second
            # MIDI-to-fret interpretation during TAB conversion.
            chosen = []
        pitch_to_position = dict(zip(pitches, chosen))
        if chosen:
            previous_position = sum(fret for _, fret in chosen) / len(chosen)
        for pitch_midi, note_element in note_group:
            position = pitch_to_position.get(pitch_midi)
            if position is None:
                continue
            string_number, fret = position
            notations = note_element.find(tag('notations'))
            if notations is None:
                notations = ET.SubElement(note_element, tag('notations'))
            technical = notations.find(tag('technical'))
            if technical is None:
                technical = ET.SubElement(notations, tag('technical'))
            for old in list(technical.findall(tag('string'))):
                technical.remove(old)
            for old in list(technical.findall(tag('fret'))):
                technical.remove(old)
            ET.SubElement(technical, tag('string')).text = str(string_number)
            ET.SubElement(technical, tag('fret')).text = str(fret)

    tree.write(xml_path, encoding='utf-8', xml_declaration=True)


def detect_strumming_pattern(midi_path, grid):
    """Infer a readable eight-subdivision down/up pattern from note onsets."""
    score = music21.converter.parse(midi_path)
    onsets = sorted({round(float(n.offset), 3) for n in score.recurse().notes})
    if not onsets:
        return None
    beat = 60.0 / grid.bpm
    symbols = []
    for step in range(8):
        target = step * 0.5
        found = any(abs((offset % 4) - target) < 0.18 for offset in onsets)
        symbols.append(("D" if step % 2 == 0 else "U") if found else "-")
    return {"pattern": " ".join(symbols), "subdivision": "1 & 2 & 3 & 4 &", "tempo": grid.bpm}


def _require_complete_band(configs, results, warnings):
    """Reject a nominal band result when any requested player was dropped."""
    if len(results) == len(configs):
        return
    generated_ids = {part['id'] for part in results}
    missing = [str(cfg.get('display_name') or cfg['instrument'])
               for index, cfg in enumerate(configs)
               if str(cfg.get('id') or f'part_{index + 1}') not in generated_ids]
    raise RuntimeError(
        "Band generation was incomplete; no playable part was produced for: "
        + ", ".join(missing)
        + (". " + "; ".join(warnings) if warnings else "")
    )


def _gate_inactive_passages(midi_path, source_path, measure_seconds=0.1):
    """Silence notes where the selected source is effectively absent.

    Demucs always emits every stem, including near-silent leakage. Comparing
    local RMS with that stem's own noise floor prevents a violin/counter-line
    from appearing during a piano-only passage merely because a fallback stem
    contains faint bleed.
    """
    import numpy as np
    import soundfile as sf
    audio, sr = sf.read(source_path, always_2d=True)
    # Measure channel energy before averaging: opposite stereo phases should
    # not cancel a real instrument into apparent silence.
    channel_energy = np.mean(audio ** 2, axis=1)
    window = max(1, int(sr * measure_seconds))
    levels = np.asarray([
        float(np.sqrt(np.mean(channel_energy[i:i + window])))
        for i in range(0, len(channel_energy), window)
    ])
    if not len(levels):
        return {'inactive_notes_removed': 0, 'active_sections': []}
    high = float(np.percentile(levels, 85))
    floor = float(np.percentile(levels, 15))
    threshold = max(0.0008, min(high * 0.09, floor * 2.5 if floor else high * 0.09))
    active = levels >= threshold
    # Preserve quiet gaps; surrounding activity does not prove a note exists
    # during a rest. Short windows avoid accepting two seconds of leakage.
    midi = pretty_midi.PrettyMIDI(midi_path)
    removed = 0
    for inst in midi.instruments:
        kept = []
        for event in inst.notes:
            index = min(len(active) - 1, max(0, int(((event.start + event.end) / 2) / measure_seconds)))
            onset_index = max(0, int(event.start / measure_seconds))
            onset_end = min(len(active), int(min(event.end, event.start + 0.1) / measure_seconds) + 1)
            # A piano attack can be strong while its sustained midpoint is
            # quiet. Retain supported attacks without filling rests elsewhere.
            onset_active = bool(active[onset_index:onset_end].any())
            if onset_active or active[index]:
                kept.append(event)
            else:
                removed += 1
        inst.notes = kept
    midi.write(midi_path)
    sections = [
        {'start_seconds': round(i * measure_seconds, 3),
         'end_seconds': round((i + 1) * measure_seconds, 3),
         'active': bool(value),
         'confidence': round(min(1.0, float(levels[i] / max(threshold, 1e-9))), 3)}
        for i, value in enumerate(active)
    ]
    return {'inactive_notes_removed': removed, 'active_sections': sections}


def _validate_part_harmony(midi_path, role, grid):
    """Conservatively correct sustained accompaniment notes against chords."""
    if role not in ('harmony', 'chords', 'bass') or not grid.chord_sections:
        return {'harmonic_notes_checked': 0, 'harmonic_notes_corrected': 0}
    midi = pretty_midi.PrettyMIDI(midi_path)
    checked = corrected = 0
    for inst in midi.instruments:
        for event in inst.notes:
            if event.end - event.start < 0.22:
                continue
            section = next((item for item in grid.chord_sections
                            if item['start_seconds'] <= event.start < item['end_seconds']), None)
            if not section or section['confidence'] < 0.06:
                continue
            checked += 1
            allowed = set(section['tones'])
            if role == 'bass':
                allowed = {section['root_pc'], (section['root_pc'] + 7) % 12}
            if event.pitch % 12 in allowed:
                continue
            choices = [delta for delta in (-2, -1, 1, 2)
                       if (event.pitch + delta) % 12 in allowed]
            if choices:
                event.pitch = max(0, min(127, event.pitch + min(choices, key=abs)))
                corrected += 1
    midi.write(midi_path)
    return {'harmonic_notes_checked': checked, 'harmonic_notes_corrected': corrected}


def build_pipeline(audio_path, output_dir, mode="solo", instruments_config=None,
                   title=None, artist='Generated by Augment', time_signature=None):
    """Run Solo or Band mode. Band config: [{instrument, role}, ...]."""
    if mode not in ("solo", "band"):
        raise ValueError("mode must be solo or band")
    configs = instruments_config or [{"instrument": "Violin", "role": "melody"}]
    if not isinstance(configs, list) or not configs:
        raise ValueError("instruments must be a non-empty list")
    if mode == "solo":
        configs = [configs[0]]
    if mode == "band" and not 2 <= len(configs) <= 4:
        raise ValueError("Band mode requires 2 to 4 instruments")

    supported_roles = set(ROLES)
    seen_ids = set()
    for part_index, cfg in enumerate(configs):
        if not isinstance(cfg, dict):
            raise ValueError(f"Band part {part_index + 1} must be an object")
        name = cfg.get("instrument")
        role = str(cfg.get("role", "melody")).lower()
        part_id = str(cfg.get("id") or f"part_{part_index + 1}")
        if name not in INSTRUMENTS:
            raise ValueError(f"Unsupported instrument: {name}")
        if role not in supported_roles:
            raise ValueError(f"Unsupported role for {name}: {role}")
        if (name == "Drums") != (role == "drums"):
            raise ValueError("The Rhythm role can only be assigned to Drums")
        if part_id in seen_ids:
            raise ValueError(f"Duplicate band part id: {part_id}")
        seen_ids.add(part_id)

    os.makedirs(output_dir, exist_ok=True)
    song = os.path.splitext(os.path.basename(audio_path))[0]
    grid = analyze_grid(audio_path, extended_harmony=True) if mode == 'band' else analyze_grid(audio_path)
    if time_signature:
        try:
            validated_signature = meter.TimeSignature(str(time_signature)).ratioString
        except Exception as exc:
            raise ValueError(f'Invalid time signature: {time_signature}') from exc
        grid.time_signature = validated_signature
    # A recognizable solo arrangement needs an isolated lead source. Without
    # this, notes from drums, chords, and bass can be mistaken for the melody.
    solo_name = configs[0]['instrument'] if configs else ''
    extended_separation = (
        mode == 'band' or solo_name in ('Piano', 'Synthesizer', 'Organ', 'Guitar')
    )
    stem_dir = run_demucs(
        audio_path, os.path.join(output_dir, "demucs"),
        extended=extended_separation,
    )
    results, warnings = [], []
    for part_index, cfg in enumerate(configs):
        name, role = cfg["instrument"], cfg.get("role", "melody").lower()
        part_id = str(cfg.get('id') or f'part_{part_index + 1}')
        safe_part_id = ''.join(ch if ch.isalnum() or ch in '-_' else '_' for ch in part_id)
        stem = ROLES.get(role, role)
        # A piano arrangement must hear melody, harmony and bass together.
        # Feeding it the isolated vocal stem would necessarily discard the
        # accompaniment before transcription even begins.
        piano_arrangement = name in ("Piano", "Synthesizer", "Organ") and mode == "solo"
        solo_violin_cover = name == 'Violin' and mode == 'solo'
        solo_guitar_cover = name in {'Guitar', 'Electric Guitar'} and mode == 'solo'
        if mode == 'band':
            stem, matched_stem = _band_source_for_part(name, role, stem_dir)
        else:
            matched_stem = (_instrument_specific_stem(name, stem_dir)
                            if piano_arrangement else None)
        source_strategy = ('solo_arrangement' if piano_arrangement else
                           'matched_instrument' if matched_stem else
                           'role_fallback' if mode == 'band' else 'isolated_melody')
        if matched_stem:
            stem = matched_stem
        if piano_arrangement:
            # Do not turn the complete mix (especially drums and vocal
            # overtones) into thousands of false piano notes. Prefer a
            # detected piano stem, with "other" as an arrangement fallback.
            stem = matched_stem or 'other'
        stem_path = os.path.join(stem_dir, f"{stem}.wav")
        if not matched_stem and not piano_arrangement:
            fallback = _role_source_fallback(stem, stem_dir)
            if fallback != stem:
                warnings.append(f'{name}: weak {stem} source; using {fallback} for the {role} role, not verified instrument isolation.')
                stem = fallback
                stem_path = os.path.join(stem_dir, f'{stem}.wav')
                source_strategy = 'role_fallback'
        if not os.path.exists(stem_path): warnings.append(f"Missing stem: {stem}"); continue
        if stem == 'vocals':
            other_path = os.path.join(stem_dir, 'other.wav')
            if os.path.exists(other_path):
                vocal_rms = _audio_rms(stem_path)
                other_rms = _audio_rms(other_path)
                # Instrumental tracks often have an empty vocals stem. In that
                # case the lead lives in Demucs' "other" stem, not in silence.
                if vocal_rms < max(0.002, other_rms * 0.035):
                    print(
                        f'[melody_source] Vocals are quiet ({vocal_rms:.5f}); '
                        f'using instrumental stem ({other_rms:.5f}).'
                    )
                    stem = 'other'
                    stem_path = other_path
        artifact_stem = f"{song}_{part_index + 1}_{safe_part_id}_{name.replace(' ', '_')}"
        midi_path = os.path.join(output_dir, f"{artifact_stem}.mid")
        xml_path = os.path.join(output_dir, f"{artifact_stem}.musicxml")
        plan_debug = (piano_arrangement and
                      os.environ.get('AUGMENT_SOLO_PIANO_PLAN_DEBUG') == '1')
        plan_sources = {'primary': [], 'lead': [], 'bass': [], 'guitar': [],
                        'primary_stem': stem, 'lead_stem': None, 'bass_stem': None}
        try:
            use_bytedance_piano = (
                name == 'Piano' and mode == 'solo' and
                _piano_transcriber_name() == 'bytedance'
            )
            if name == 'Drums' or role == 'drums':
                stats = transcribe_drum_stem(stem_path, midi_path, layered=mode == 'band')
                stats['source_stem'] = stem
                stats['source_strategy'] = source_strategy
            elif solo_violin_cover:
                import soundfile as sf
                stats = _transcribe_solo_violin_cover(
                    stem_dir, midi_path, sf.info(audio_path).duration)
            elif solo_guitar_cover:
                import soundfile as sf
                stats = _transcribe_solo_guitar_cover(
                    stem_dir, midi_path, sf.info(audio_path).duration, grid,
                    instrument_name=name)
            elif use_bytedance_piano:
                try:
                    # Use the uploaded Piano recording, not an unrelated
                    # separated stem. The model emits its own CC64 events.
                    stats = _transcribe_piano_bytedance(audio_path, midi_path)
                    stats['source_stem'] = 'uploaded_audio'
                    stats['source_strategy'] = 'piano_specific_model'
                except RuntimeError as exc:
                    warnings.append(f'Piano/ByteDance: {exc} Falling back to Basic Pitch.')
                    use_bytedance_piano = False
                    voice_settings = _part_voice_settings(name, role, piano_arrangement)
                    stats = transcribe_stem(
                        stem_path, midi_path, polyphonic=voice_settings['polyphonic'],
                        prefer_pyin=voice_settings['prefer_pyin'],
                        melody_range=INSTRUMENTS[name][:2], instrument_name=name,
                    )
                    stats['method'] = 'basic_pitch_fallback'
                    stats['source_stem'] = stem
                    stats['source_strategy'] = source_strategy
            else:
                voice_settings = _part_voice_settings(
                    name, role, piano_arrangement,
                )
                stats = transcribe_stem(
                    stem_path,
                    midi_path,
                    # A flute, violin, cello, or horn cannot perform the full
                    # polyphonic "other" stem. Give those instruments one
                    # continuous counter-line; reserve chord stacks for
                    # genuinely chordal keyboards.
                    polyphonic=voice_settings['polyphonic'],
                    prefer_pyin=voice_settings['prefer_pyin'],
                    melody_range=INSTRUMENTS.get(name, INSTRUMENTS["Violin"])[:2],
                    harmonic_focus=(name == 'Violin' and role in ('melody', 'lead')),
                    instrument_name=name,
                    preserve_attacks=mode == 'band',
                )
                stats['source_stem'] = stem
                stats['source_strategy'] = source_strategy
                stats['voice_type'] = (
                    'chordal' if voice_settings['polyphonic']
                    else 'monophonic'
                )
                if (role in ('melody', 'lead') and not voice_settings['polyphonic'] and
                        not solo_violin_cover and not solo_guitar_cover):
                    stats.update(_clean_lead_contour(
                        midi_path,
                        INSTRUMENTS.get(name, INSTRUMENTS['Violin'])[:2],
                    ))
            if plan_debug:
                from solo_piano_arranger import midi_events
                plan_sources['primary'] = midi_events(midi_path)
            if piano_arrangement:
                stats['source_stem'] = 'uploaded_audio' if use_bytedance_piano else stem
                stats['source_strategy'] = (
                    'piano_specific_model' if use_bytedance_piano else 'solo_arrangement')
                if _is_successful_bytedance_solo_piano(mode, name, stats):
                    # ByteDance already provides the complete polyphonic Piano
                    # performance and its own CC64.  These legacy stages were
                    # designed to supplement a weak Basic Pitch arrangement;
                    # running either would inject a second transcription.
                    stats['legacy_piano_support_bypassed'] = (
                        '_merge_bass_support_into_piano',
                        'apply_isolated_lead_to_piano',
                    )
                else:
                    bass_path = os.path.join(stem_dir, 'bass.wav')
                    bass_midi_path = midi_path + '.bass.mid'
                    try:
                        if os.path.exists(bass_path) and _audio_rms(bass_path) >= 0.001:
                            bass_stats = transcribe_stem(
                                bass_path, bass_midi_path, polyphonic=False,
                                prefer_pyin=True,
                                melody_range=INSTRUMENTS['Bass Guitar'][:2],
                            )
                            if plan_debug:
                                plan_sources['bass'] = midi_events(bass_midi_path)
                                plan_sources['bass_stem'] = 'bass.wav'
                            bass_added = _merge_bass_support_into_piano(
                                midi_path, bass_midi_path,
                            )
                            stats['isolated_bass'] = {
                                **bass_stats, 'applied_notes': bass_added,
                            }
                    except (OSError, ValueError, RuntimeError) as exc:
                        warnings.append(f'{name}/bass: separated support unavailable ({exc})')
                    finally:
                        if os.path.exists(bass_midi_path):
                            os.remove(bass_midi_path)
                    # Keep a simple playable left hand only when neither the
                    # source accompaniment nor isolated bass supplied one.
                    # This does not replace detected bass or rewrite chords.
                    stats['chord_bass_fallback_notes'] = _add_missing_chord_bass_to_piano(
                        midi_path, grid)
                    vocals_path = os.path.join(stem_dir, 'vocals.wav')
                    other_path = os.path.join(stem_dir, 'other.wav')
                    lead_source = vocals_path
                    if (not os.path.exists(vocals_path) or
                            _audio_rms(vocals_path) < max(
                                0.002,
                                _audio_rms(other_path) * .035 if os.path.exists(other_path) else .002,
                            )):
                        lead_source = other_path
                    lead_midi_path = midi_path + '.lead.mid'
                    try:
                        lead_stats = transcribe_stem(
                            lead_source,
                            lead_midi_path,
                            polyphonic=False,
                            prefer_pyin=True,
                            melody_range=(40, 96),
                            recover_short_piano=name == 'Piano',
                        )
                        if plan_debug:
                            plan_sources['lead'] = midi_events(lead_midi_path)
                            plan_sources['lead_stem'] = os.path.basename(lead_source)
                        lead_validation = validate_transcription(lead_source, lead_midi_path)
                        lead_stats.update(lead_validation)
                        lead_source, lead_stats, supported_lead = _select_supported_piano_lead(
                            lead_source, lead_midi_path, lead_stats, stem_dir)
                        if plan_debug:
                            plan_sources['lead'] = midi_events(lead_midi_path) if supported_lead else []
                            plan_sources['lead_stem'] = os.path.basename(lead_source) if supported_lead else None
                        source_is_vocal = os.path.basename(lead_source) == 'vocals.wav'
                        if not supported_lead or (not source_is_vocal and not _usable_instrumental_lead(
                                lead_midi_path, lead_stats)):
                            # A quiet, low-register, poorly aligned `other`
                            # contour is accompaniment/bass leakage, not a
                            # defensible right-hand melody.
                            recovered_sections, applied_notes = [], 0
                            warnings.append(f'{name}/melody: no reliable lead contour; preserving source notes without guessing a protected melody.')
                        else:
                            recovered_sections = _recover_instrumental_sections(
                                lead_midi_path, stem_dir, (40, 96))
                            if recovered_sections:
                                warnings.append(f'{name}: instrumental melody sections evaluated; review recovered or unresolved passages.')
                            applied_notes = apply_isolated_lead_to_piano(
                                midi_path, lead_midi_path,
                            )
                        lead_stats['instrumental_sections'] = recovered_sections
                        stats['isolated_lead'] = {
                            **lead_stats,
                            'source': os.path.basename(lead_source),
                            'applied_notes': applied_notes,
                        }
                        if lead_stats.get('warning'):
                            warnings.append(f"{name}/melody: {lead_stats['warning']}")
                    except (OSError, ValueError, RuntimeError) as exc:
                        warnings.append(
                            f'{name}/melody: isolated lead unavailable; using full-mix top line ({exc})'
                        )
                    finally:
                        if os.path.exists(lead_midi_path):
                            os.remove(lead_midi_path)
            debug_artifacts = _write_debug_artifacts(
                stem_path, midi_path, output_dir, f'{song}_{name.replace(" ", "_")}',
            )
            if plan_debug:
                # Diagnostic-only: inspect the exact existing source material.
                # It neither writes nor alters performance MIDI.
                from solo_piano_arranger import build_plan, write_plan
                import soundfile as sf
                genuine_piano = matched_stem == 'piano'
                piano_events = plan_sources['primary'] if genuine_piano else []
                accompaniment_events = [] if genuine_piano else plan_sources['primary']
                plan = build_plan(
                    grid, sf.info(audio_path).duration,
                    melody=plan_sources['lead'], bass=plan_sources['bass'], piano=piano_events,
                    accompaniment=accompaniment_events,
                    melody_source=plan_sources['lead_stem'] or 'none',
                    bass_source=plan_sources['bass_stem'] or 'none',
                    piano_source='piano.wav' if genuine_piano else None,
                    byte_dance=bool(genuine_piano and use_bytedance_piano),
                    cc64_count=0,
                )
                plan['sources'] = {
                    'lead': {'source': plan_sources['lead_stem'], 'events': plan_sources['lead']},
                    'bass': {'source': plan_sources['bass_stem'], 'events': plan_sources['bass']},
                    'primary_accompaniment': {'source': f"{plan_sources['primary_stem']}.wav", 'events': accompaniment_events},
                    'existing_piano': {'source': 'piano.wav' if genuine_piano else None, 'events': piano_events},
                    'guitar': {'source': None, 'events': []},
                    'bytedance_piano': {'available': bool(genuine_piano and use_bytedance_piano), 'events': []},
                }
                debug_artifacts['solo_piano_arrangement_plan'] = write_plan(
                    plan, os.path.join(output_dir, f'{song}_{name}_arrangement_plan.json'))
            if not piano_arrangement and role in ("melody", "lead", "bass"):
                stats.update(validate_transcription(stem_path, midi_path))
            # Keep the vocal tune during sung phrases, then use a monophonic
            # instrumental candidate to carry the line through vocal rests.
            # This preserves hooks and interludes instead of leaving blanks.
            hybrid_lead = False
            fill_instrumental_gaps = (
                mode == 'band' and
                os.environ.get('AUGMENT_FILL_MELODY_GAPS', '1') != '0'
            )
            if (fill_instrumental_gaps and not piano_arrangement and stem == "vocals" and
                    role in ("melody", "lead")):
                other_stem = os.path.join(stem_dir, "other.wav")
                candidate_midi = midi_path + ".other.mid"
                if os.path.exists(other_stem):
                    try:
                        candidate_stats = transcribe_stem(
                            other_stem,
                            candidate_midi,
                            polyphonic=False,
                            prefer_pyin=True,
                            melody_range=INSTRUMENTS.get(name, INSTRUMENTS["Violin"])[:2],
                        )
                        candidate_stats.update(validate_transcription(other_stem, candidate_midi))
                        candidate_alignment = candidate_stats.get(
                            'alignment_confidence')
                        stats['instrumental_gap_alignment'] = candidate_alignment
                        # A weak candidate is usually accompaniment leakage,
                        # not a real intro/fill melody. Unknown validation is
                        # still allowed so offline validation does not silence
                        # an otherwise confident transcription.
                        filled_notes = 0
                        if candidate_alignment is None or candidate_alignment >= 0.45:
                            filled_notes = _fill_vocal_gaps_with_instrumental(
                                midi_path, candidate_midi,
                            )
                        hybrid_lead = filled_notes > 0
                        stats['instrumental_gap_notes'] = filled_notes
                        if os.path.exists(candidate_midi):
                            os.remove(candidate_midi)
                    except (OSError, ValueError, RuntimeError):
                        if os.path.exists(candidate_midi):
                            os.remove(candidate_midi)
            if mode == 'band' and not hybrid_lead:
                stats.update(_gate_inactive_passages(midi_path, stem_path))
                # Chord guesses from a mixed recording are not ground truth.
                # Preserve transcribed passing tones and inversions.
            alignment = stats.get('alignment_confidence')
            if alignment is not None and alignment < 0.45 and not solo_guitar_cover:
                stats['source_strategy'] = 'uncertain'
            technique_source = audio_path if hybrid_lead else stem_path
            techniques = (detect_lead_techniques(technique_source, midi_path)
                          if not piano_arrangement and role in ("melody", "lead") else None)
            if name == 'Violin' and role in ('melody', 'lead'):
                techniques = _simplify_violin_techniques(techniques)
            result = {
                "id": part_id, "instrument": name, "role": role,
                "display_name": cfg.get('display_name') or name,
                "musicxml": xml_path, "stats": stats,
                "techniques": techniques,
                "source_stem": stats.get('source_stem', stem),
                "source_strategy": stats.get('source_strategy', source_strategy),
                "instrument_presence": "unverified" if matched_stem else "role_assignment",
                "confidence": stats.get('alignment_confidence'),
                "activity_sections": stats.get('active_sections', []),
            }
            if debug_artifacts:
                result['debug'] = debug_artifacts
            if name in TUNINGS:
                result["tuning"] = TUNINGS[name]
                result["string_count"] = len(TUNINGS[name])
                result["strumming_pattern"] = detect_strumming_pattern(midi_path, grid)
            results.append(result)
            if mode == 'band' and matched_stem:
                warnings.append(
                    f'{name}: using the separated {stem} source; instrument presence '
                    'is not independently verified and may contain other instruments.')
            if stats.get("warning"):
                warnings.append(f"{name}/{role}: {stats['warning']}")
        except (OSError, ValueError, RuntimeError) as exc:
            warnings.append(f"{name}/{role}: {exc}")
    if not results:
        raise RuntimeError("No playable parts were generated. " + "; ".join(warnings))
    if mode == "band":
        _require_complete_band(configs, results, warnings)
    # Arrange only after every source has been transcribed: accompaniment
    # must see the same lead activity regardless of the user's row order.
    from performance_arranger import arrange, lead_intervals
    arrangements = []
    band_lead_activity = []
    for result in results:
        source_midi = os.path.splitext(result['musicxml'])[0] + '.mid'
        performance = pretty_midi.PrettyMIDI(source_midi)
        arrangements.append((result, performance, source_midi))
        if result['role'] in ('melody', 'lead'):
            band_lead_activity.extend(lead_intervals(performance))
    for result, performance, source_midi in arrangements:
        if mode == 'band':
            # Arrange the detected players before ensemble balancing; the
            # coordinator operates jointly after this preparation pass below.
            result['arrangement'] = arrange(performance, result['instrument'],
                result['role'], lead_activity=band_lead_activity, solo=False)
    if mode == 'band':
        from band_performance import coordinate_band
        coordination = coordinate_band(arrangements)
        for result, _, _ in arrangements:
            result['arrangement']['ensemble'] = coordination[result['id']]
        if not band_lead_activity:
            warnings.append('Band has no designated lead activity; melody audibility cannot be verified.')
    for result, performance, source_midi in arrangements:
        if _is_successful_bytedance_solo_piano(
                mode, result['instrument'], result['stats']):
            # The keyboard arranger keeps notes and timing in a solo Piano
            # part, but it still rescales velocities.  ByteDance velocities
            # are model output, so preserve the entire Piano event stream
            # verbatim for the experimental path.
            note_count = sum(len(track.notes) for track in performance.instruments)
            result['arrangement'] = {
                'version': 0,
                'family': 'keyboard',
                'notes_before': note_count,
                'notes_after': note_count,
                'bypassed': 'bytedance_solo_piano_event_preservation',
                'timing_preserved': True,
                'velocity_preserved': True,
                'native_cc64_preserved': True,
            }
        elif mode != 'band':
            result['arrangement'] = arrange(
                performance, result['instrument'], result['role'],
                lead_activity=band_lead_activity if mode == 'band' else (),
                solo=mode == 'solo',
            )
        # Keep raw transcription available for comparison and future retries.
        arranged_path = os.path.splitext(source_midi)[0] + '.arranged.mid'
        performance.write(arranged_path)
        if (mode == 'solo' and result['instrument'] == 'Flute' and
                result['source_stem'] in ('vocals', 'vocals.wav')):
            # Preserve the approved arrangement; correct only pitches jointly
            # supported by the source stem's two independent detectors.
            from solo_flute_melody_accuracy import apply_flute_melody_accuracy
            detector_path = source_midi + '.detector.json'
            source_stem_path = os.path.join(stem_dir, 'vocals.wav')
            try:
                result['stats']['flute_melody_accuracy'] = apply_flute_melody_accuracy(
                    performance, source_stem_path, detector_path)
                performance.write(arranged_path)
            except (OSError, ValueError, RuntimeError) as exc:
                result['stats']['flute_melody_accuracy'] = {
                    'enabled': True, 'applied': False, 'warning': str(exc)}
                warnings.append('Flute: extra melody evidence unavailable; preserving selected notes.')
        # Keep the full arranged performance separate from the engraved
        # MusicXML. Engraving deliberately merges close attacks and releases
        # to make the staff readable; audio playback must retain every note.
        score_midi_path = arranged_path
        performance_midi_path = arranged_path
        if mode == 'solo' and result['instrument'] == 'Violin':
            # V3 remains the engraving/note-selection source. V3.1 performs
            # those exact notes without feeding bow timing back into notation.
            from solo_violin_performance import (
                event_dicts, plan_violin_v3_1, violin_events_to_midi,
            )
            selected_notes = sorted(
                (note for track in performance.instruments
                 for note in track.notes),
                key=lambda note: (note.start, note.pitch),
            )
            violin_events, violin_report = plan_violin_v3_1(selected_notes)
            if (len(violin_events) != len(selected_notes) or
                    any(event.pitch != source.pitch for event, source in
                        zip(violin_events, selected_notes))):
                raise ValueError('Violin V3.1 changed the selected V3 notes.')
            performance_midi_path = (
                os.path.splitext(source_midi)[0] + '.violin_v3_1_performance.mid')
            violin_events_to_midi(violin_events, performance_midi_path)
            violin_plan_path = (
                os.path.splitext(source_midi)[0] + '.violin_v3_1_plan.json')
            with open(violin_plan_path, 'w', encoding='utf-8') as handle:
                json.dump({'events': event_dicts(violin_events),
                           'metrics': violin_report}, handle, indent=2)
            result['arrangement']['solo_violin_version'] = '3.1'
            result['arrangement']['violin_v3_1'] = violin_report
            result['_preserve_violin_performance'] = True
            result['_violin_performance_plan_path'] = violin_plan_path
        if (mode == 'solo' and result['instrument'] == 'Piano' and
                not _is_successful_bytedance_solo_piano(
                    mode, result['instrument'], result['stats']) and
                any('isolated melody' in track.name.lower() and track.notes
                    for track in performance.instruments)):
            # The accepted V2 arrangement is the *notation* source. V2.1 and
            # V2.2 only perform those same notes; microtiming and pedal must
            # never leak into the engraved grand staff.
            from solo_piano_arranger import (
                arrange_pianist_v2, perform_pianist_v2_1,
                perform_pianist_v2_2,
            )
            stem = os.path.splitext(source_midi)[0]
            score_midi_path = stem + '.piano_v2_score.mid'
            v2_1_path = stem + '.piano_v2_1_performance.mid'
            performance_midi_path = stem + '.piano_v2_2_performance.mid'
            v2_report = arrange_pianist_v2(arranged_path, score_midi_path, grid)
            perform_pianist_v2_1(score_midi_path, v2_1_path, grid)
            v2_2_report = perform_pianist_v2_2(
                score_midi_path, v2_1_path, performance_midi_path, grid)
            result['arrangement']['solo_piano_version'] = '2.2'
            result['arrangement']['piano_v2'] = v2_report
            result['arrangement']['piano_v2_2'] = v2_2_report
            result['_preserve_piano_performance'] = True
        elif mode == 'solo' and result['instrument'] == 'Piano':
            result['arrangement']['piano_route'] = 'detected_performance_preserved'
            result['_preserve_piano_performance'] = True
            if not _is_successful_bytedance_solo_piano(
                    mode, result['instrument'], result['stats']):
                warnings.append(
                    'Piano: reliable isolated melody unavailable; preserving '
                    'detected notes instead of guessing the highest-note lead.')
        result['_performance_midi_path'] = performance_midi_path
        if mode == 'band':
            result['notation_subdivision'] = _band_notation_subdivision(score_midi_path, grid)
        midi_to_musicxml(
            score_midi_path, result['musicxml'], result['instrument'], grid,
            result['role'], title=title or song, artist=artist,
            techniques=result.get('techniques'), band_mode=mode == 'band',
        )
        if result['instrument'] in TUNINGS:
            result['strumming_pattern'] = detect_strumming_pattern(arranged_path, grid)
        from score_validation import audit_score
        result['score_validation'] = audit_score(result['musicxml'], score_midi_path, grid)
        audit = result['score_validation']
        if audit['overfull_measures']:
            warnings.append(f"{result['instrument']}: exported score contains overfull measures.")
        if audit['missing_attack_count']:
            warnings.append(
                f"{result['instrument']}: {audit['missing_attack_count']} arranged note attacks "
                'were not matched in the exported score; review notation.')
    combined_path = None
    if mode == "band" and len(results) > 1:
        combined = _build_band_score(
            results, grid, title=title or f'{song} - Full Band Score',
            artist=artist,
        )
        combined_path = os.path.join(output_dir, f"{song}_band.musicxml")
        _write_musicxml(combined, combined_path,
            subdivision=getattr(combined, '_augment_notation_subdivision', 8))
    manifest = {"mode": mode, "tempo": grid.bpm, "time_signature": grid.time_signature,
                "key": grid.display_key, "parts": results, "combined_musicxml": combined_path,
                "tempo_map": list(grid.tempo_map),
                "key_sections": list(grid.key_sections),
                "chord_sections": list(grid.chord_sections),
                "warnings": warnings}
    with open(os.path.join(output_dir, f"{song}_manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
    return manifest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output_dir", default="./output_pipeline")
    parser.add_argument("--mode", choices=["solo", "band"], default="solo")
    parser.add_argument("--instrument", default="Violin")
    parser.add_argument("--role", default="melody")
    parser.add_argument("--config", help="JSON file containing band [{instrument, role}, ...]")
    parser.add_argument("--title")
    parser.add_argument("--artist", default="Generated by Augment")
    parser.add_argument("--time-signature", help="Optional meter override, for example 7/8")
    args = parser.parse_args()
    config = json.load(open(args.config, encoding="utf-8")) if args.config else [{"instrument": args.instrument, "role": args.role}]
    print(json.dumps(build_pipeline(
        args.input, args.output_dir, args.mode, config, args.title, args.artist,
        args.time_signature,
    ), indent=2))


if __name__ == "__main__": main()
