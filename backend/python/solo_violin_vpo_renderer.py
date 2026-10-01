"""V3.1 -> VPO Performance Orchestra adapter and isolated A/B tooling."""
from pathlib import Path
import json
import re
import shutil
import subprocess
import tempfile

import numpy as np
import pretty_midi
import soundfile as sf


def validate_vpo_sfz(sfz_path, pitches):
    """Verify the actual patch and every referenced WAV before rendering."""
    path = Path(sfz_path).resolve()
    source = path.read_text(encoding='utf-8-sig', errors='replace')
    samples = re.findall(r'\bsample\s*=\s*([^\s]+)', source)
    missing = [str((path.parent / item.replace('\\', '/')).resolve())
               for item in samples
               if not (path.parent / item.replace('\\', '/')).resolve().is_file()]
    if not samples or missing:
        raise ValueError(f'VPO patch has {len(missing)} missing sample paths.')
    # Each region's key or explicit range is adjacent to its sample opcode.
    # SFZ group settings are not needed for the used 60..79 range here.
    covered = set()
    for line in source.splitlines():
        if '<region>' not in line or 'sample=' not in line:
            continue
        key = re.search(r'\bkey\s*=\s*(\d+)', line)
        low = re.search(r'\blokey\s*=\s*(\d+)', line)
        high = re.search(r'\bhikey\s*=\s*(\d+)', line)
        if key or low or high:
            nominal = int(key.group(1)) if key else None
            left = int(low.group(1)) if low else nominal
            right = int(high.group(1)) if high else nominal
            if left is not None and right is not None:
                covered.update(range(left, right + 1))
    uncovered = sorted(set(pitches) - covered)
    if uncovered:
        raise ValueError(f'VPO patch lacks sample regions for pitches {uncovered}.')
    return {
        'sfz': str(path), 'sample_references': len(samples),
        'sample_folder': str((path.parent / '..' / 'libs' / 'NoBudgetOrch' /
                              'SoloViolin').resolve()),
        'missing_samples': missing, 'uncovered_pitches': uncovered,
        'sfz_controls': {
            'modulation_cc1_gain': 'gain_cc1=34' in source,
            'velocity_attack': 'ampeg_vel2attack=-2' in source,
            'velocity_staccato_crossfade': 'xfin_lovel=63' in source,
            'staccato_round_robin': 'seq_length=2' in source,
            'velocity_release': 'ampeg_vel2release=-1.0' in source,
            'sample_randomization': 'pitch_random=12' in source and
                                    'delay_random=0.012' in source,
            'cc11_expression_declared': bool(re.search(r'\b\w+_cc11\s*=', source)),
            'keyswitches_declared': 'sw_lokey' in source,
        },
    }


def _vpo_velocity(event):
    """Key velocity chooses VPO articulation; CC1 owns phrase dynamics."""
    articulation = event['articulation']
    value = int(event['velocity'])
    if articulation in ('legato', 'sustain', 'phrase_end'):
        return max(42, min(60, round(48 + (value - 70) * .35)))
    if articulation == 'accented':
        return max(92, min(112, round(98 + (value - 75) * .45)))
    if articulation == 'rearticulated':
        return max(78, min(103, round(86 + (value - 75) * .4)))
    return max(65, min(98, round(76 + (value - 75) * .45)))


def events_to_vpo_midi(events, output_midi_path):
    midi = pretty_midi.PrettyMIDI(initial_tempo=120)
    violin = pretty_midi.Instrument(program=0, name='VPO 1st solo violin PERF')
    # The chosen SFZ declares set_cc1=64 and gain_cc1=34. It does not
    # declare CC11 modulation, so transfer the existing expression contour
    # onto CC1 instead of writing ineffectual CC11 messages.
    violin.control_changes.append(pretty_midi.ControlChange(1, 64, 0))
    for index, event in enumerate(events):
        start = float(event['onset'])
        end = start + float(event['duration'])
        next_start = (float(events[index + 1]['onset'])
                      if index + 1 < len(events) else float('inf'))
        violin.notes.append(pretty_midi.Note(
            velocity=_vpo_velocity(event), pitch=int(event['pitch']),
            start=start, end=end))
        limit = min(end, next_start - .006)
        for fraction, level in event['expression_curve']:
            if limit < start:
                break
            time = min(limit, start + float(fraction) * float(event['duration']))
            violin.control_changes.append(pretty_midi.ControlChange(
                1, max(1, min(127, round(float(level) * 110))), time))
        # sfizz handles MIDI pitch bend. The exact patch has no controllable
        # vibrato LFO across this melody's range, so carry V3.1's delayed
        # pitch-bend vibrato; do not add extra articulation notes.
        if event['vibrato_delay'] is not None:
            from math import pi, sin
            onset = start + float(event['vibrato_delay'])
            stop = min(end - .030, next_start - .018)
            time = onset
            while time < stop:
                development = min(1.0, (time - onset) / .18)
                cents = float(event['vibrato_depth_cents']) * development
                bend = round(sin(2 * pi * float(event['vibrato_rate']) *
                                 (time - onset)) * cents / 200 * 8192)
                violin.pitch_bends.append(pretty_midi.PitchBend(bend, time))
                time += .02
            if stop > onset:
                violin.pitch_bends.append(pretty_midi.PitchBend(0, stop))
    violin.control_changes.sort(key=lambda cc: cc.time)
    violin.pitch_bends.sort(key=lambda bend: bend.time)
    midi.instruments.append(violin)
    midi.write(str(output_midi_path))
    return midi


def render_vpo_performance(events, output_path, sfz_path, sfizz_render_path,
                           sample_rate=44100):
    """Render any V3.1 plan, preserving its note onsets, durations and pitches."""
    if not events:
        raise ValueError('No Violin V3.1 performance events to render.')
    validate_vpo_sfz(sfz_path, [int(event['pitch']) for event in events])
    renderer = Path(sfizz_render_path).resolve()
    if not renderer.is_file():
        raise FileNotFoundError(f'sfizz renderer not found: {renderer}')
    with tempfile.TemporaryDirectory(prefix='augment_violin_vpo_') as temp:
        midi_path = Path(temp) / 'performance.mid'
        raw_wav = Path(temp) / 'performance.wav'
        midi = events_to_vpo_midi(events, midi_path)
        rendered = sorted(midi.instruments[0].notes,
                          key=lambda note: (note.start, note.pitch))
        planned = sorted(events, key=lambda event: (
            float(event['onset']), int(event['pitch'])))
        if (len(rendered) != len(planned) or any(
                note.pitch != int(event['pitch']) or
                abs(note.start - float(event['onset'])) > .001 or
                abs(note.end - note.start - float(event['duration'])) > .001
                for note, event in zip(rendered, planned))):
            raise AssertionError('VPO conversion changed a V3.1 note.')
        result = subprocess.run(
            [str(renderer), '--sfz', str(Path(sfz_path).resolve()),
             '--midi', str(midi_path), '--wav', str(raw_wav),
             '-s', str(sample_rate)],
            capture_output=True, text=True, timeout=300, check=False,
        )
        if result.returncode or not raw_wav.is_file():
            raise RuntimeError(
                f'sfizz_render failed: {result.stdout}\n{result.stderr}')
        audio, rate = sf.read(raw_wav, always_2d=True)
        peak = float(np.max(np.abs(audio))) if len(audio) else 0.0
        if peak <= 0:
            raise RuntimeError('VPO rendered silence.')
        # Fixed gain from the A/B match; preserve relative phrase dynamics.
        gain = min(12.212, .95 / peak)
        sf.write(output_path, audio * gain, rate, subtype='PCM_16')
        return True, len(audio) / rate


def render_vpo_ab(event_json_path, sfz_path, sfizz_render_path,
                  output_directory, current_sf2_wav):
    output = Path(output_directory).resolve()
    output.mkdir(parents=True, exist_ok=True)
    payload = json.loads(Path(event_json_path).read_text(encoding='utf-8'))
    events = payload['events']
    if len(events) != 58:
        raise ValueError(f'Expected frozen 58-note V3.1 plan, found {len(events)}.')
    patch = validate_vpo_sfz(sfz_path, [int(item['pitch']) for item in events])
    vpo_midi_path = output / 'Violin_V3_1_VPO.mid'
    vpo_wav_path = output / 'Violin_V3_1_VPO.wav'
    sf2_wav_path = output / 'Violin_V3_1_Current_SF2.wav'
    events_to_vpo_midi(events, vpo_midi_path)
    shutil.copy2(current_sf2_wav, sf2_wav_path)
    command = [str(Path(sfizz_render_path).resolve()), '--sfz',
               str(Path(sfz_path).resolve()), '--midi', str(vpo_midi_path),
               '--wav', str(vpo_wav_path), '-s', '44100', '-v']
    result = subprocess.run(command, capture_output=True, text=True,
                            timeout=120, check=False)
    if result.returncode or not vpo_wav_path.is_file():
        raise RuntimeError(f'sfizz_render failed: {result.stdout}\n{result.stderr}')
    # VPO's patch carries substantial static attenuation. A single global
    # gain match makes the two timbres listenable at comparable level without
    # changing any articulation, phrase shape or relative note dynamics.
    current_audio, current_rate = sf.read(sf2_wav_path, always_2d=True)
    vpo_audio, vpo_rate = sf.read(vpo_wav_path, always_2d=True)
    if current_rate != vpo_rate:
        raise RuntimeError('A/B render sample rates differ.')
    common = min(len(current_audio), len(vpo_audio))
    current_rms = float(np.sqrt(np.mean(current_audio[:common] ** 2)))
    raw_vpo_rms = float(np.sqrt(np.mean(vpo_audio[:common] ** 2)))
    if raw_vpo_rms < 1e-8:
        raise RuntimeError('VPO rendered silence.')
    gain = min(current_rms / raw_vpo_rms,
               .95 / max(1e-9, float(np.max(np.abs(vpo_audio)))))
    sf.write(vpo_wav_path, vpo_audio * gain, vpo_rate, subtype='PCM_16')
    tail_samples = max(1, round(.3 * vpo_rate))
    tail_rms = float(np.sqrt(np.mean((vpo_audio[-tail_samples:] * gain) ** 2)))
    rendered_midi = pretty_midi.PrettyMIDI(str(vpo_midi_path))
    rendered_notes = sorted(rendered_midi.instruments[0].notes,
                            key=lambda n: n.start)
    current_midi_path = Path(event_json_path).with_suffix('.mid')
    current_midi = pretty_midi.PrettyMIDI(str(current_midi_path))
    current_notes = sorted((note for track in current_midi.instruments
                            for note in track.notes), key=lambda n: n.start)
    if len(current_notes) != len(rendered_notes):
        raise AssertionError('A/B note counts differ.')
    onset_delta = max(abs(a.start - b.start)
                      for a, b in zip(current_notes, rendered_notes))
    duration_delta = max(abs((a.end - a.start) - (b.end - b.start))
                         for a, b in zip(current_notes, rendered_notes))
    pitch_changes = sum(a.pitch != b.pitch for a, b in
                        zip(current_notes, rendered_notes))
    if pitch_changes or onset_delta > .001 or duration_delta > .001:
        raise AssertionError('The VPO MIDI changed a frozen V3.1 musical event.')
    report = {
        'sfz_patch': patch, 'renderer': str(Path(sfizz_render_path).resolve()),
        'renderer_version': 'sfizz 1.2.3 win64',
        'renderer_setup': 'Portable official sfizz release extracted into this A/B output folder; no system-wide install.',
        'renderer_exit_code': result.returncode,
        'renderer_stdout': result.stdout.strip(),
        'renderer_stderr': result.stderr.strip(),
        'note_count_current_sf2': len(current_notes),
        'note_count_vpo_midi': len(rendered_notes),
        'added_notes': 0, 'removed_notes': 0,
        'changed_pitches': pitch_changes,
        'maximum_midi_onset_conversion_difference_seconds': round(onset_delta, 4),
        'maximum_midi_duration_conversion_difference_seconds': round(duration_delta, 4),
        'acoustic_onset_caveat': 'The original SFZ declares delay_random=0.012; sampled attacks may move by up to its built-in random delay even though MIDI onsets are identical.',
        'level_match': {
            'current_sf2_rms': round(current_rms, 5),
            'vpo_raw_rms': round(raw_vpo_rms, 5),
            'single_global_gain': round(gain, 3),
            'vpo_matched_rms': round(raw_vpo_rms * gain, 5),
        },
        'final_300ms_rms': round(tail_rms, 6),
        'stuck_sustain_detected_at_file_end': tail_rms > raw_vpo_rms * gain * .1,
        'controls_mapped': {
            'note_velocity': 'V3.1 articulation selects VPO velocity attack/staccato blend',
            'phrase_dynamics': 'V3.1 expression curve mapped to declared gain_cc1',
            'sustain_detached_accents': 'existing durations and velocity articulation bands',
            'vibrato': 'V3.1 delayed pitch-bend events through sfizz',
        },
        'articulations_in_exact_patch': [
            'velocity-shaped sustain/normal bow attack',
            'high-velocity accent and spiccato/staccato crossfade',
            'two-way staccato round robin',
        ],
        'controls_not_directly_reproduced': [
            'bow direction: patch round robin is not an explicit up/down selector',
            'true legato switching: no legato transition samples or opcode',
            'CC11: not declared in this SFZ; expression mapped to CC1',
            'release style as a separate switch: only V3.1 note length and '
            'VPO velocity-dependent release envelope',
            'keyswitch articulation: this exact non-KS patch uses velocity instead',
        ],
        'original_samples_modified': False,
        'production_renderer_changed': False,
        'lost_or_stuck_note_check': (
            'All 58 MIDI note-on/off pairs are present and every pitch has a '
            'resolved sample region; sfizz exited successfully. Audio attack '
            'audibility for every individual note cannot be proved from the '
            'mixed WAV alone.'
        ),
    }
    (output / 'Violin_V3_1_VPO_Report.json').write_text(
        json.dumps(report, indent=2), encoding='utf-8')
    return report
