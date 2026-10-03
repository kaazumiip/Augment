"""Source-faithful ensemble coordination; never generates replacement melodies."""
import numpy as np
import pretty_midi


def violin_performance_events(notes, tempo_bpm):
    """Use approved Solo bow/expression decisions on the existing Band line.

    Preserve Band canonical pitches, attack times and releases so its cursor
    and notation stay aligned. No source-note selection or additions here.
    """
    from dataclasses import replace
    from solo_violin_performance import plan_violin_v3_1, event_dicts
    seconds_per_beat = 60.0 / tempo_bpm
    source = sorted((pretty_midi.Note(
        int(event['velocity']), pretty_midi.note_name_to_number(pitch),
        float(event['offset']) * seconds_per_beat,
        (float(event['offset']) + float(event['duration'])) * seconds_per_beat)
        for event in notes for pitch in event['pitches']),
        key=lambda note: (note.start, note.pitch))
    planned, diagnostics = plan_violin_v3_1(source)
    planned = [replace(event, onset=event.source_onset,
                       duration=event.source_duration) for event in planned]
    return planned, event_dicts(planned), diagnostics


def coordinate_band(parts):
    """Balance overlapping parts without changing any pitch, attack or release."""
    leads = [(n.start, n.end, n.pitch) for result, midi, _ in parts
             if result['role'] in ('lead', 'melody')
             for track in midi.instruments for n in track.notes]
    reports = {}
    for result, midi, _ in parts:
        changed = duplicates = 0
        if result['role'] in ('harmony', 'chords'):
            for track in midi.instruments:
                for event in track.notes:
                    active = [pitch for start, end, pitch in leads
                              if start < event.end and end > event.start]
                    gain = 1.
                    if active:
                        gain = .92
                        if event.pitch in active:
                            gain = .80
                            duplicates += 1
                        if sum(a <= event.start < b for a, b, _ in leads) > 1:
                            gain *= .94
                    if gain < 1:
                        event.velocity = max(25, round(event.velocity * gain))
                        changed += 1
        reports[result['id']] = dict(version='band_coordination_v1',
            harmony_notes_balanced=changed, melody_doubles_softened=duplicates,
            notes_added=0, notes_removed=0, pitches_changed=0, timing_changed=0)
    rock_reports = coordinate_rock_lineup(parts)
    for part_id, report in rock_reports.items():
        reports[part_id]['rock'] = report
    return reports


def coordinate_rock_lineup(parts):
    """Balance the existing Rock preset without inventing notes or grooves.

    Preset labels are not sent to Python, so activate only for the exact
    electric lead / acoustic harmony / cello bass / drums configuration.
    Custom lineups matching this configuration receive the same treatment.
    """
    signature = sorted((result.get('instrument'),
                        'melody' if result['role'] == 'lead' else result['role'])
                       for result, _, _ in parts)
    if signature != sorted([('Electric Guitar', 'melody'), ('Guitar', 'harmony'),
                            ('Cello', 'bass'), ('Drums', 'drums')]):
        return {}
    lead = [n for result, midi, _ in parts if result['instrument'] == 'Electric Guitar'
            for track in midi.instruments for n in track.notes]
    if not lead:
        return {}
    reports = {}
    for result, midi, _ in parts:
        changed = 0
        for track in midi.instruments:
            for note in track.notes:
                old = note.velocity
                active = [n for n in lead if n.start < note.end and n.end > note.start]
                if result['instrument'] == 'Electric Guitar':
                    # Preserve relative lead accents, including quiet phrases.
                    note.velocity = min(116, max(1, round(old * 1.10)))
                elif active:
                    if result['instrument'] == 'Guitar':
                        # Same-register chord backing masks the electric lead.
                        close = any(abs(n.pitch - note.pitch) <= 7 for n in active)
                        note.velocity = max(1, round(old * (.80 if close else .90)))
                    elif result['instrument'] == 'Cello':
                        note.velocity = max(1, round(old * .92))
                    elif result['instrument'] == 'Drums':
                        # Only soften hats/cymbals; retain kick/snare accents.
                        if note.pitch in {42, 44, 46, 49, 51, 52, 55, 57, 59}:
                            note.velocity = max(1, round(old * .88))
                changed += old != note.velocity
        reports[result['id']] = dict(version='rock_balance_v1',
            velocities_changed=changed, notes_added=0, notes_removed=0,
            pitches_changed=0, timing_changed=0)
    return reports


def transcribe_layered_drums(audio_path, midi_path):
    """Detect independent low/mid/high attacks, permitting simultaneous hits.

    This is spectral evidence, not a learned kit transcription. Cymbal/tom
    identity remains uncertain; it does not synthesize genre-specific loops.
    """
    import librosa
    audio, sr = librosa.load(audio_path, sr=22050, mono=True)
    if not len(audio) or float(np.sqrt(np.mean(audio ** 2))) < 1e-4:
        raise ValueError('Drum stem is too quiet to transcribe')
    hop = 256
    power = np.abs(librosa.stft(audio, n_fft=1024, hop_length=hop)) ** 2
    frequencies = librosa.fft_frequencies(sr=sr, n_fft=1024)
    bands = [(30, 180, 36), (180, 3500, 38), (5000, 11025, 42)]
    energies = [power[(frequencies >= lo) & (frequencies < hi)].sum(axis=0)
                for lo, hi, _ in bands]
    total = power.sum(axis=0) + 1e-12
    midi = pretty_midi.PrettyMIDI()
    track = pretty_midi.Instrument(0, is_drum=True)
    counts = {}
    for index, (_, _, pitch) in enumerate(bands):
        energy = energies[index]
        flux = np.maximum(0, np.diff(np.log1p(energy), prepend=0.))
        peak = float(np.max(flux))
        if peak <= 1e-6:
            continue
        frames = librosa.onset.onset_detect(onset_envelope=flux / peak, sr=sr,
            hop_length=hop, units='frames', backtrack=False, wait=2, delta=.12)
        for frame in frames:
            right = min(len(total), int(frame) + 3)
            left = max(0, int(frame) - 1)
            fraction = float(energy[left:right].sum() / total[left:right].sum())
            if fraction < (.18 if index == 0 else .12 if index == 1 else .08):
                continue
            # Avoid assigning a bass drum's mid harmonics as a separate snare.
            if index == 1 and energies[0][left:right].sum() > energy[left:right].sum() * 1.5:
                continue
            strength = float(flux[frame] / peak)
            onset = float(librosa.frames_to_time(frame, sr=sr, hop_length=hop))
            track.notes.append(pretty_midi.Note(
                max(40, min(115, round(48 + strength * 62))), pitch,
                onset, onset + (.06 if index == 2 else .10)))
            counts[str(pitch)] = counts.get(str(pitch), 0) + 1
    if not track.notes:
        raise ValueError('No independently supported drum attacks detected')
    track.notes.sort(key=lambda n: (n.start, n.pitch))
    midi.instruments = [track]
    midi.write(midi_path)
    return dict(notes=len(track.notes), method='layered_percussion_onsets',
                hit_counts=counts, kit_identity='spectral_estimate',
                simultaneous_hits_allowed=True)
