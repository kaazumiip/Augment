import os
import io
import json
import importlib
import uuid
import subprocess
import tempfile
import shutil
import traceback
import glob
import time
from flask import Flask, request, jsonify, send_file
from flask.json.provider import DefaultJSONProvider
from werkzeug.utils import secure_filename
import music21
from music21 import converter, instrument, tempo, key, meter, note, chord, stream, clef, repeat
import librosa
import numpy as np

_FLUIDSYNTH_DLL_HANDLES = []
_FLUIDSYNTH_BINDING = None
_FLUIDSYNTH_IMPORT_ERROR = None


def _load_fluidsynth_binding():
    """Load pyFluidSynth against the DLL shipped with the backend on Windows."""
    global _FLUIDSYNTH_BINDING, _FLUIDSYNTH_IMPORT_ERROR
    if _FLUIDSYNTH_BINDING is not None:
        return _FLUIDSYNTH_BINDING
    if _FLUIDSYNTH_IMPORT_ERROR is not None:
        raise RuntimeError(_FLUIDSYNTH_IMPORT_ERROR)

    module_dir = os.path.abspath(os.path.dirname(__file__))
    runtime_dirs = [module_dir]
    configured_dir = os.environ.get('AUGMENT_FLUIDSYNTH_DLL_DIR')
    if configured_dir:
        runtime_dirs.append(configured_dir)
    runtime_dirs.extend(glob.glob(os.path.join(
        module_dir, 'runtime', 'fluidsynth', '*', 'bin')))
    original_add_dll_directory = getattr(os, 'add_dll_directory', None)
    try:
        if os.name == 'nt':
            path_entries = os.environ.get('PATH', '').split(os.pathsep)
            missing_dirs = [
                directory for directory in runtime_dirs
                if directory and os.path.isdir(directory) and
                directory.lower() not in {entry.lower() for entry in path_entries}
            ]
            if missing_dirs:
                os.environ['PATH'] = os.pathsep.join(missing_dirs + [
                    os.environ.get('PATH', ''),
                ])
            if original_add_dll_directory is not None:
                for directory in runtime_dirs:
                    if directory and os.path.isdir(directory):
                        _FLUIDSYNTH_DLL_HANDLES.append(
                            original_add_dll_directory(directory))

                def safe_add_dll_directory(path):
                    try:
                        handle = original_add_dll_directory(path)
                        _FLUIDSYNTH_DLL_HANDLES.append(handle)
                        return handle
                    except FileNotFoundError:
                        return None

                os.add_dll_directory = safe_add_dll_directory
        _FLUIDSYNTH_BINDING = importlib.import_module('fluidsynth')
        return _FLUIDSYNTH_BINDING
    except Exception as exc:
        _FLUIDSYNTH_IMPORT_ERROR = str(exc)
        raise
    finally:
        if original_add_dll_directory is not None:
            os.add_dll_directory = original_add_dll_directory


# Newer pretty_midi versions import the optional binding eagerly, so prepare
# the packaged Windows runtime before importing pretty_midi itself.
try:
    _load_fluidsynth_binding()
except (ImportError, OSError, RuntimeError):
    pass

import pretty_midi
from scipy.io import wavfile

class MusicalJSONProvider(DefaultJSONProvider):
    """Serialize analysis scalars without changing musical result values."""

    @staticmethod
    def default(value):
        if isinstance(value, np.generic):
            return value.item()
        if isinstance(value, np.ndarray):
            return value.tolist()
        return DefaultJSONProvider.default(value)


app = Flask(__name__)
app.json = MusicalJSONProvider(app)

UPLOAD_FOLDER = os.path.join(os.path.abspath(os.path.dirname(__file__)), 'uploads')
OUTPUT_FOLDER = os.path.join(os.path.abspath(os.path.dirname(__file__)), 'output')
os.makedirs(UPLOAD_FOLDER, exist_ok=True)
os.makedirs(OUTPUT_FOLDER, exist_ok=True)
print(f'[init] OUTPUT_FOLDER={OUTPUT_FOLDER}')
print(f'[init] OUTPUT_FOLDER exists={os.path.exists(OUTPUT_FOLDER)}, files={os.listdir(OUTPUT_FOLDER)}')

ALLOWED_EXTENSIONS = {
    'mid', 'midi', 'musicxml', 'xml', 'mxl', 'krn', 'abc',
    'mp3', 'wav', 'm4a', 'flac', 'ogg',
    'mp4', 'mov', 'mkv', 'webm', 'avi', '3gp',
}
VIDEO_EXTENSIONS = {'.mp4', '.mov', '.mkv', '.webm', '.avi', '.3gp'}


def _find_musescore():
    env_path = os.environ.get('MUSESCORE_PATH')
    if env_path and os.path.isfile(env_path):
        return env_path
    candidates = [
        'C:/Program Files/MuseScore 4/bin/MuseScore4.exe',
        'C:/Program Files/MuseScore 3/bin/MuseScore3.exe',
        '/usr/bin/musescore4',
        '/usr/bin/musescore3',
        '/usr/bin/musescore',
        '/usr/local/bin/musescore4',
        '/usr/local/bin/musescore3',
        '/Applications/MuseScore 4.app/Contents/MacOS/mscore',
        '/Applications/MuseScore 3.app/Contents/MacOS/mscore',
    ]
    for path in candidates:
        if os.path.isfile(path):
            return path
    return 'mscore'


MUSESCORE_PATH = _find_musescore()


def _find_lilypond():
    env_path = os.environ.get('LILYPOND_PATH')
    if env_path and os.path.isfile(env_path):
        return env_path
    candidates = [
        'lilypond',
        'C:/Program Files/LilyPond/usr/bin/lilypond.exe',
        'C:/Program Files (x86)/LilyPond/usr/bin/lilypond.exe',
    ]
    import glob as globmod
    winget_paths = globmod.glob('C:/Users/*/AppData/Local/Microsoft/WinGet/Packages/LilyPond.LilyPond_*/lilypond-*/bin/lilypond.exe')
    candidates.extend(winget_paths)
    candidates.extend([
        '/usr/bin/lilypond',
        '/usr/local/bin/lilypond',
        '/Applications/LilyPond.app/Contents/Resources/bin/lilypond',
    ])
    for path in candidates:
        try:
            result = subprocess.run([path, '--version'], capture_output=True, timeout=5)
            if result.returncode == 0:
                return path
        except (FileNotFoundError, subprocess.TimeoutExpired):
            continue
    return None


LILYPOND_PATH = _find_lilypond()


def _run_musescore_export(musicxml_path, output_path, timeout_seconds=45):
    """Export a score and terminate only the MuseScore child we created."""
    if not MUSESCORE_PATH:
        return False, 'MuseScore is unavailable.'
    process = subprocess.Popen(
        [MUSESCORE_PATH, '-o', output_path, musicxml_path],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0),
    )
    started, ready_at = time.monotonic(), None
    try:
        while time.monotonic() - started < timeout_seconds:
            ready = os.path.isfile(output_path) and os.path.getsize(output_path) > 0
            if ready:
                ready_at = ready_at or time.monotonic()
                if process.poll() is not None or time.monotonic() - ready_at >= 1.0:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()
                    return True, ''
            elif process.poll() is not None:
                _, stderr = process.communicate()
                return False, stderr.decode(errors='replace')[-500:]
            time.sleep(.1)
        return False, f'MuseScore timed out after {timeout_seconds} seconds.'
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def render_musicxml_to_png(musicxml_path, output_prefix):
    if not MUSESCORE_PATH:
        return None, False
    try:
        png_path = output_prefix + '.png'
        _, png_error = _run_musescore_export(musicxml_path, png_path)

        if not os.path.exists(png_path):
            for suffix in ['-1.png', '-page1.png']:
                fallback = output_prefix + suffix
                if os.path.exists(fallback):
                    os.rename(fallback, png_path)
                    break

        pdf_path = output_prefix + '.pdf'
        if not os.path.exists(pdf_path):
            _run_musescore_export(musicxml_path, pdf_path)
            for suffix in ['-1.pdf', '-page1.pdf']:
                fallback_pdf = output_prefix + suffix
                if os.path.exists(fallback_pdf):
                    os.rename(fallback_pdf, pdf_path)
                    break

        if os.path.exists(png_path):
            return png_path, True
        print(f'MuseScore stderr: {png_error}')
        return None, False
    except Exception as e:
        print(f'MuseScore render error: {e}')
        return None, False


def render_musicxml_to_pdf(musicxml_path, pdf_path):
    if not MUSESCORE_PATH:
        return False
    try:
        _, export_error = _run_musescore_export(musicxml_path, pdf_path)
        if not os.path.exists(pdf_path):
            base = os.path.splitext(pdf_path)[0]
            for suffix in ('-1.pdf', '-page1.pdf'):
                fallback = base + suffix
                if os.path.exists(fallback):
                    os.replace(fallback, pdf_path)
                    break
        if not os.path.exists(pdf_path):
            print(f'PDF render stderr: {export_error}')
        return os.path.exists(pdf_path)
    except Exception as error:
        print(f'PDF render error: {error}')
        return False


def _prepare_pdf_artifact(musicxml_path, output_folder=OUTPUT_FOLDER):
    """Render a PDF and only advertise it when a non-empty file exists."""
    musicxml_name = os.path.basename(musicxml_path)
    pdf_name = os.path.splitext(musicxml_name)[0] + '.pdf'
    pdf_path = os.path.join(output_folder, pdf_name)
    available = (
        os.path.exists(pdf_path) and os.path.getsize(pdf_path) > 0
    ) or render_musicxml_to_pdf(musicxml_path, pdf_path)
    available = bool(
        available and os.path.exists(pdf_path) and os.path.getsize(pdf_path) > 0
    )
    return (pdf_name if available else None), available


def render_system_images(musicxml_path, output_prefix, uid):
    # Returning an empty list immediately. Rendering individual systems using MuseScore 
    # sequentially takes a massive amount of time (leading to HTTP timeouts) and is 
    # not used by the Flutter frontend (which renders via OSMD or the full page sheet image).
    return []


INSTRUMENT_CLEF = {
    'Violin': 'treble',
    'Guitar': 'treble_8',
    'Bass Guitar': 'bass',
    'Electric Guitar': 'treble_8',
    'Cello': 'bass',
    'Ukulele': 'treble',
    'Piano': 'treble',
    'Synthesizer': 'treble',
    'Organ': 'treble',
    'Drums': 'percussion',
    'Saxophone': 'treble',
    'Trumpet': 'treble',
    'Flute': 'treble',
    'Clarinet': 'treble',
}


def _generate_ly_from_score(score, ly_path):
    lines = [
        '\\version "2.24"',
        '',
        '\\header {',
        '  title = ""',
        '  tagline = ##f',
        '}',
        '',
    ]

    for part in score.parts:
        part_name = part.partName or 'Staff'
        part_name = part_name.replace('"', '')
        lines.append(f'\\new Staff {{')
        lines.append(f'  \\set Staff.instrumentName = "{part_name}"')

        key_sigs = list(_safe_flatten(part).getElementsByClass(key.Key))
        if key_sigs:
            k = key_sigs[0]
            mode_str = ' \\major' if k.mode == 'major' else ' \\minor'
            tonic_name = k.tonic.name
            step = tonic_name[0].lower()
            acc = tonic_name[1:] if len(tonic_name) > 1 else ''
            ly_acc = ''
            if '#' in acc:
                ly_acc = 'is' * acc.count('#')
            elif 'b' in acc.lower() or '-' in acc:
                count = acc.count('b') + acc.count('-')
                ly_acc = 'es' * count
            lines.append(f'  \\key {step}{ly_acc}{mode_str}')

        clefs = list(_safe_flatten(part).getElementsByClass(clef.Clef))
        if clefs:
            clef_name = clefs[0].sign.lower()
            if clef_name == 'g':
                clef_name = 'treble'
            elif clef_name == 'f':
                clef_name = 'bass'
            elif clef_name == 'c':
                clef_name = 'alto'
            lines.append(f'  \\clef "{clef_name}"')
        else:
            clef_fallback = INSTRUMENT_CLEF.get(part_name, 'treble')
            lines.append(f'  \\clef "{clef_fallback}"')

        time_sigs = list(_safe_flatten(part).getElementsByClass(meter.TimeSignature))
        if time_sigs:
            ts = time_sigs[0]
            lines.append(f'  \\time {ts.numerator}/{ts.denominator}')

        measures = list(part.getElementsByClass(stream.Measure))
        if not measures:
            measures = [part]

        for measure in measures:
            voices_in_measure = list(measure.voices)
            if len(voices_in_measure) > 1:
                for el in voices_in_measure[0].notesAndRests:
                    _ly_note_to_lines(el, lines)
            else:
                for el in _safe_flatten(measure).notesAndRests:
                    _ly_note_to_lines(el, lines)
            lines.append(f'  \\bar "|"')

        lines.append('}')

    with open(ly_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))


def _ly_note_to_lines(el, lines):
    if isinstance(el, note.Rest):
        dur = el.quarterLength
        ly_dur = _quarter_to_ly(dur)
        lines.append(f'  r{ly_dur}')
    elif isinstance(el, chord.Chord):
        dur = el.quarterLength
        ly_dur = _quarter_to_ly(dur)
        pitches = ' '.join(_pitch_name_to_ly(p) for p in el.pitches)
        lines.append(f'  < {pitches} >{ly_dur}')
    elif isinstance(el, note.Note):
        dur = el.quarterLength
        ly_dur = _quarter_to_ly(dur)
        ly_pitch = _pitch_name_to_ly(el.pitch)
        lines.append(f'  {ly_pitch}{ly_dur}')


def _quarter_to_ly(quarter_length):
    mapping = {
        0.25: '16', 0.5: '8', 0.75: '8.', 1.0: '4',
        1.5: '4.', 2.0: '2', 3.0: '2.', 4.0: '1',
    }
    closest = min(mapping.keys(), key=lambda x: abs(x - quarter_length))
    if abs(closest - quarter_length) < 0.01:
        return mapping[closest]
    if quarter_length >= 4.0:
        return '1'
    if quarter_length >= 2.0:
        return '2'
    if quarter_length >= 1.0:
        return '4'
    if quarter_length >= 0.5:
        return '8'
    return '16'


def _octave_to_ly(octave):
    # LilyPond: c = C3, c' = C4, c'' = C5, c, = C2, c,, = C1
    # Commas for down, apostrophes for up — standard LilyPond syntax
    if octave >= 4:
        return "'" * (octave - 3)
    elif octave == 3:
        return ''
    else:
        return "," * (3 - octave)


def _pitch_name_to_ly(p):
    """Convert a music21 Pitch to a LilyPond note name (e.g. F#4 -> fis'4)."""
    step = p.name[0].lower()  # C,D,E,F,G,A,B -> c,d,e,f,g,a,b
    accidental = p.name[1:] if len(p.name) > 1 else ''

    # Convert accidental: music21 uses '#' and 'b'/'-' for sharps/flats
    ly_acc = ''
    if '#' in accidental:
        ly_acc = 'is' * accidental.count('#')
    elif 'b' in accidental.lower() or '-' in accidental:
        count = accidental.count('b') + accidental.count('-')
        ly_acc = 'es' * count

    octave = _octave_to_ly(p.octave)
    return f"{step}{ly_acc}{octave}"


def allowed_file(filename):
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in ALLOWED_EXTENSIONS


def _extract_audio_from_video(video_path, output_path):
    """Convert a device video to a mono WAV suitable for Demucs and Basic Pitch."""
    result = subprocess.run(
        ['ffmpeg', '-y', '-i', video_path, '-vn', '-ac', '1', '-ar', '44100', output_path],
        capture_output=True,
        text=True,
        timeout=600,
    )
    if result.returncode != 0 or not os.path.exists(output_path):
        detail = result.stderr.strip().splitlines()[-1] if result.stderr else 'FFmpeg could not extract audio.'
        raise ValueError(f'Video audio extraction failed: {detail}')


INSTRUMENT_MAP = {
    'Violin': instrument.Violin(),
    'Guitar': instrument.Guitar(),
    'Bass Guitar': instrument.ElectricBass(),
    'Electric Guitar': instrument.ElectricGuitar(),
    'Cello': instrument.Violoncello(),
    'Ukulele': instrument.Ukulele(),
    'Piano': instrument.Piano(),
    'Synthesizer': instrument.Piano(),
    'Organ': instrument.Organ(),
    'Drums': instrument.UnpitchedPercussion(),
    'Saxophone': instrument.Saxophone(),
    'Trumpet': instrument.Trumpet(),
    'Flute': instrument.Flute(),
    'Clarinet': instrument.Clarinet(),
}


def pitch_to_midi(pitch_name):
    note_map = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11}
    clean = pitch_name.replace('-', '').replace('#', '#').replace('b', 'b')
    base = clean[0]
    is_sharp = '#' in clean
    is_flat = 'b' in clean
    octave_str = [c for c in clean[1:] if c.isdigit()]
    octave = int(octave_str[0]) if octave_str else 4
    midi_num = note_map.get(base, 0) + (octave + 1) * 12
    if is_sharp:
        midi_num += 1
    elif is_flat:
        midi_num -= 1
    return midi_num


_INSTRUMENT_TUNINGS = {
    'Guitar':          ['E2', 'A2', 'D3', 'G3', 'B3', 'E4'],
    'Electric Guitar': ['E2', 'A2', 'D3', 'G3', 'B3', 'E4'],
    'Bass Guitar':     ['E1', 'A1', 'D2', 'G2'],
    'Ukulele':         ['G4', 'C4', 'E4', 'A4'],
}

_STRING_INSTRUMENTS = set(_INSTRUMENT_TUNINGS.keys())


def pitch_to_frets(pitches, instrument_name):
    tuning = _INSTRUMENT_TUNINGS.get(instrument_name)
    if not tuning:
        return None
    string_count = len(tuning)
    tuning_midi = [pitch_to_midi(p) for p in tuning]
    result = [None] * string_count
    used_strings = set()
    for pitch_name in pitches:
        midi = pitch_to_midi(pitch_name)
        best_string = None
        best_fret = 999
        for s in range(string_count):
            fret = midi - tuning_midi[s]
            if 0 <= fret <= 12 and s not in used_strings and fret < best_fret:
                best_fret = fret
                best_string = s
        if best_string is not None:
            result[best_string] = best_fret
            used_strings.add(best_string)
        else:
            best_string = None
            best_fret = 999
            for s in range(string_count):
                fret = midi - tuning_midi[s]
                if 0 <= fret <= 24 and s not in used_strings and fret < best_fret:
                    best_fret = fret
                    best_string = s
            if best_string is not None:
                result[best_string] = best_fret
                used_strings.add(best_string)
    return result


def _detect_strumming_pattern(notes_data, tempo_bpm, time_signature):
    if not notes_data:
        return None
    beats_per_bar = 4
    try:
        parts = time_signature.split('/')
        if len(parts) == 2:
            beats_per_bar = int(parts[0])
    except Exception:
        pass
    seconds_per_beat = 60.0 / tempo_bpm
    total_time = max(
        n['offset'] * seconds_per_beat + n['duration'] * seconds_per_beat
        for n in notes_data
    )
    if total_time <= 0:
        return None
    subdivisions = 8
    sub_duration = seconds_per_beat / (subdivisions / 2)
    grid = []
    t = 0.0
    while t < total_time + sub_duration:
        grid.append(t)
        t += sub_duration
    strum_events = [''] * len(grid)
    for n in notes_data:
        start_t = n['offset'] * seconds_per_beat
        closest_sub = min(range(len(grid)), key=lambda i: abs(grid[i] - start_t))
        beat_pos = (start_t / seconds_per_beat) % beats_per_bar
        sub_in_beat = closest_sub % subdivisions
        if sub_in_beat < subdivisions // 2:
            strum_events[closest_sub] = 'D'
        else:
            strum_events[closest_sub] = 'U'
    pattern_subs = []
    pattern_len_beats = min(beats_per_bar, 4)
    pattern_len_subs = pattern_len_beats * (subdivisions // 2)
    for i in range(min(pattern_len_subs, len(strum_events))):
        pattern_subs.append(strum_events[i] if strum_events[i] else ' ')
    pattern_str = ' '.join(s for s in pattern_subs if s).strip()
    if not pattern_str:
        pattern_str = 'D D D D'
    return {
        'pattern': pattern_str,
        'beats_per_pattern': pattern_len_beats,
    }


def _safe_flatten(part):
    try:
        return part.flatten()
    except Exception:
        from music21 import stream as stream_mod
        flat = stream_mod.Stream()
        for el in part.recurse():
            if not isinstance(el, instrument.Instrument):
                flat.append(el)
        return flat


def _remove_instruments_from_part(part):
    to_remove = []
    for el in part.recurse():
        if isinstance(el, instrument.Instrument):
            to_remove.append(el)
    for el in to_remove:
        try:
            part.remove(el)
        except Exception:
            pass


def _element_tie_type(element):
    """Return a common tie type for a note or every pitch in a chord."""
    if isinstance(element, note.Note):
        return getattr(element.tie, 'type', None)
    if isinstance(element, chord.Chord):
        tie_types = {
            getattr(chord_note.tie, 'type', None)
            for chord_note in element.notes
        }
        if len(tie_types) == 1:
            return next(iter(tie_types))
    return None


def _append_or_merge_tied_event(events, active_ties, entry, tie_type):
    """Keep engraving ties from becoming repeated playback attacks."""
    key = tuple(entry['pitches'])
    if tie_type in {'continue', 'stop'} and key in active_ties:
        previous = active_ties[key]
        previous['duration'] = max(
            previous['duration'],
            entry['offset'] + entry['duration'] - previous['offset'],
        )
        if tie_type == 'stop':
            active_ties.pop(key, None)
        return previous, False

    events.append(entry)
    if tie_type == 'start':
        active_ties[key] = entry
    return entry, True


def _extract_notes_data(score, instrument_name=None):
    notes_data = []
    is_string = instrument_name in _STRING_INSTRUMENTS
    score_parts = list(score.parts)
    if is_string:
        # Guitar/ukulele MusicXML intentionally contains standard notation and
        # a mirrored TAB staff.  Playback must render only the notation staff;
        # otherwise every event is sounded twice and the accompaniment masks
        # the lead in Band mode.
        notation_parts = [
            part for part in score_parts
            if not part.recurse().getElementsByClass(clef.TabClef)
        ]
        if notation_parts:
            score_parts = notation_parts
    for part_index, part in enumerate(score_parts):
        active_ties = {}
        part_name = (part.partName or '').lower()
        if instrument_name in {'Piano', 'Synthesizer', 'Organ'} and len(score_parts) > 1:
            role = 'piano_melody' if part_index == 0 else 'piano_bass'
        else:
            role = ('piano_melody' if 'right hand' in part_name else
                    'piano_bass' if 'left hand' in part_name else None)
        flat = _safe_flatten(part)
        for element in flat.notes:
            if isinstance(element, note.Note):
                entry = {
                    'pitches': [element.nameWithOctave],
                    'duration': float(element.duration.quarterLength),
                    'offset': float(element.offset),
                    'velocity': element.volume.velocity or 80,
                    'role': role,
                }
                if is_string:
                    entry['frets'] = pitch_to_frets([element.nameWithOctave], instrument_name)
                _append_or_merge_tied_event(
                    notes_data, active_ties, entry, _element_tie_type(element))
            elif isinstance(element, chord.Chord):
                pitches = [p.nameWithOctave for p in element.pitches]
                entry = {
                    'pitches': pitches,
                    'duration': float(element.duration.quarterLength),
                    'offset': float(element.offset),
                    'velocity': element.volume.velocity or 80,
                    'role': role,
                }
                if is_string:
                    entry['frets'] = pitch_to_frets(pitches, instrument_name)
                _append_or_merge_tied_event(
                    notes_data, active_ties, entry, _element_tie_type(element))
    notes_data.sort(key=lambda n: n['offset'])
    return notes_data


def _extract_performance_notes(midi_path, instrument_name, tempo_bpm,
                               preserve_piano_performance=False,
                               preserve_violin_performance=False,
                               preserve_band_performance=False):
    """Use every arranged MIDI note for audio, independent of engraving."""
    performance = pretty_midi.PrettyMIDI(midi_path)
    raw = [
        midi_note
        for track in performance.instruments
        for midi_note in track.notes
        if midi_note.end > midi_note.start
    ]
    if not raw:
        return []

    raw.sort(key=lambda midi_note: (midi_note.start, midi_note.pitch))
    if preserve_band_performance or instrument_name in {'Guitar', 'Electric Guitar', 'Flute', 'Saxophone'} or (
            instrument_name == 'Piano' and preserve_piano_performance) or (
            instrument_name == 'Violin' and preserve_violin_performance):
        seconds_per_quarter = 60.0 / max(1.0, float(tempo_bpm))
        return [{
            'pitches': [pretty_midi.note_number_to_name(item.pitch)],
            'offset': item.start / seconds_per_quarter,
            'duration': (item.end - item.start) / seconds_per_quarter,
            'velocity': item.velocity,
            'preserve_guitar_performance': instrument_name in {'Guitar', 'Electric Guitar'},
            'preserve_piano_performance': preserve_piano_performance,
            'preserve_violin_performance': preserve_violin_performance,
            'preserve_band_performance': preserve_band_performance,
        } for item in raw]
    groups = []
    for midi_note in raw:
        # Chord tones can be detected a few milliseconds apart. Group their
        # attack for natural playback, but retain every pitch and duration.
        if groups and midi_note.start - groups[-1][0].start <= 0.018:
            groups[-1].append(midi_note)
        else:
            groups.append([midi_note])

    seconds_per_quarter = 60.0 / max(1.0, float(tempo_bpm))
    events = []
    for group in groups:
        if instrument_name in {'Piano', 'Synthesizer', 'Organ'}:
            hands = {
                'piano_melody': [item for item in group if item.pitch >= 60],
                'piano_bass': [item for item in group if item.pitch < 60],
            }
            if not hands['piano_melody'] and hands['piano_bass']:
                promoted = max(hands['piano_bass'], key=lambda item: item.pitch)
                hands['piano_bass'].remove(promoted)
                hands['piano_melody'].append(promoted)
        else:
            hands = {None: group}

        for role, notes_for_hand in hands.items():
            if not notes_for_hand:
                continue
            start = min(item.start for item in notes_for_hand)
            end = max(item.end for item in notes_for_hand)
            events.append({
                'pitches': [pretty_midi.note_number_to_name(item.pitch)
                            for item in notes_for_hand],
                'offset': start / seconds_per_quarter,
                'duration': max(0.0625, (end - start) / seconds_per_quarter),
                'velocity': max(item.velocity for item in notes_for_hand),
                'role': role,
            })
    events.sort(key=lambda item: item['offset'])
    return events


def _extract_piano_pedal_events(midi_path):
    """Return already-predicted CC64 events without deriving any new pedal."""
    performance = pretty_midi.PrettyMIDI(midi_path)
    events = [
        {'time': float(change.time), 'value': int(change.value)}
        for track in performance.instruments
        for change in track.control_changes
        if change.number == 64
    ]
    return sorted(events, key=lambda event: event['time'])


def _attach_playback_techniques(notes_data, techniques, tempo_bpm):
    """Attach contour-detected vibrato to the nearest rendered lead note."""
    if not techniques or not notes_data:
        return notes_data
    seconds_per_beat = 60.0 / tempo_bpm
    for vibrato in techniques.get('vibrato', []):
        target = min(
            notes_data,
            key=lambda item: abs(item['offset'] * seconds_per_beat - vibrato['start']),
        )
        if abs(target['offset'] * seconds_per_beat - vibrato['start']) <= 0.14:
            target['vibrato'] = {
                'depth': float(vibrato.get('depth', 0.16)),
                'rate': float(vibrato.get('rate', 5.5)),
            }
    return notes_data


def _detect_score_info(score):
    tempo_bpm = 120
    key_signature = 'C'
    time_signature = '4/4'
    try:
        for part in score.parts:
            flat = _safe_flatten(part)
            t_marks = flat.getElementsByClass(tempo.MetronomeMark)
            if t_marks:
                tempo_bpm = int(t_marks[0].number)
                break
    except Exception:
        pass
    try:
        for part in score.parts:
            flat = _safe_flatten(part)
            k_elements = flat.getElementsByClass(key.Key)
            if k_elements:
                key_signature = k_elements[0].nameWithOctave.replace(k_elements[0].nameWithOctave[-1], '').strip() or k_elements[0].tonic.name
                break
    except Exception:
        pass
    try:
        for part in score.parts:
            flat = _safe_flatten(part)
            m_elements = flat.getElementsByClass(meter.TimeSignature)
            if m_elements:
                time_signature = m_elements[0].ratioString
                break
    except Exception:
        pass
    return tempo_bpm, key_signature, time_signature


_PLAYBACK_PROGRAMS = {
    'Piano': 0,
    'Guitar': 24,
    'Electric Guitar': 27,
    'Bass Guitar': 33,
    'Ukulele': 24,
    'Violin': 40,
    'Cello': 42,
    'Saxophone': 65,
    'Trumpet': 56,
    'Flute': 73,
    'Clarinet': 71,
    'Organ': 16,
    'Synthesizer': 80,
}

_SOUNDFONT_FILENAMES = (
    # MuseScore General is a maintained, compact General MIDI soundfont.
    'MuseScore_General.sf3',
    'FluidR3_GM.sf2',
)
_PIANO_SOUNDFONT_FILENAME = 'Stein Grand Piano.SF2'
_GUITAR_SOUNDFONT_FILENAME = 'Custom Classical Guitar.sf2'
_VIOLIN_SOUNDFONT_FILENAME = 'Violin Real 2026.SF2'
_SAXOPHONE_SOUNDFONT_FILENAME = 'Tenor Saxophone.SF2'

def _find_soundfont(instrument_names=()):
    """Resolve instrument-specific SoundFonts without changing other playback."""
    soundfont_dir = os.path.join(os.path.dirname(__file__), 'soundfonts')
    if set(instrument_names) == {'Piano'}:
        piano_candidates = [
            os.environ.get('AUGMENT_PIANO_SOUNDFONT_PATH'),
            os.path.join(soundfont_dir, _PIANO_SOUNDFONT_FILENAME),
        ]
        for candidate in piano_candidates:
            if candidate and os.path.isfile(candidate):
                return candidate
        # Do not quietly substitute General MIDI for the approved Piano voice.
        return None
    if set(instrument_names) == {'Guitar'}:
        guitar_candidates = [
            os.environ.get('AUGMENT_GUITAR_SOUNDFONT_PATH'),
            os.path.join(soundfont_dir, _GUITAR_SOUNDFONT_FILENAME),
        ]
        for candidate in guitar_candidates:
            if candidate and os.path.isfile(candidate):
                return candidate
    if set(instrument_names) == {'Violin'}:
        violin_candidates = [
            os.environ.get('AUGMENT_VIOLIN_SOUNDFONT_PATH'),
            os.path.join(soundfont_dir, _VIOLIN_SOUNDFONT_FILENAME),
        ]
        for candidate in violin_candidates:
            if candidate and os.path.isfile(candidate):
                return candidate
    if set(instrument_names) == {'Saxophone'}:
        saxophone_candidates = [
            os.environ.get('AUGMENT_SAXOPHONE_SOUNDFONT_PATH'),
            os.path.join(soundfont_dir, _SAXOPHONE_SOUNDFONT_FILENAME),
        ]
        for candidate in saxophone_candidates:
            if candidate and os.path.isfile(candidate):
                return candidate
    candidates = [
        os.environ.get('SOUNDFONT_PATH'),
        *(os.path.join(soundfont_dir, filename) for filename in _SOUNDFONT_FILENAMES),
        *(os.path.join('C:/soundfonts', filename) for filename in _SOUNDFONT_FILENAMES),
    ]
    for candidate in candidates:
        if candidate and os.path.isfile(candidate):
            return candidate
    return None


def _instrument_name_for_part(part, fallback='Piano'):
    part_name = (part.partName or '').split(' (', 1)[0]
    if part_name in _PLAYBACK_PROGRAMS:
        return part_name
    try:
        detected = part.getInstrument(returnDefault=True).instrumentName
        if detected in _PLAYBACK_PROGRAMS:
            return detected
    except Exception:
        pass
    return fallback


def _tempo_map(score, default_bpm=120):
    points = [(0.0, float(default_bpm))]
    for mark in score.recurse().getElementsByClass(tempo.MetronomeMark):
        if mark.number:
            try:
                points.append((float(mark.getOffsetInHierarchy(score)), float(mark.number)))
            except Exception:
                points.append((float(mark.offset), float(mark.number)))
    return sorted({(round(offset, 6), bpm) for offset, bpm in points})


def _seconds_for_offset(offset, tempo_points):
    seconds = 0.0
    previous_offset, previous_bpm = tempo_points[0]
    for point_offset, point_bpm in tempo_points[1:]:
        if offset <= point_offset:
            return seconds + (offset - previous_offset) * 60.0 / previous_bpm
        seconds += (point_offset - previous_offset) * 60.0 / previous_bpm
        previous_offset, previous_bpm = point_offset, point_bpm
    return seconds + (offset - previous_offset) * 60.0 / previous_bpm


def _performance_duration(element, score, tempo_points):
    try:
        start_offset = float(element.getOffsetInHierarchy(score))
    except Exception:
        start_offset = float(element.offset)
    end_offset = start_offset + float(element.duration.quarterLength)
    return max(0.05, _seconds_for_offset(end_offset, tempo_points) - _seconds_for_offset(start_offset, tempo_points))


def score_to_wav(score, output_path, fallback_instrument='Piano', default_bpm=120):
    """Turn engraved MusicXML into a timed, expressive multi-part performance."""
    try:
        performance_score = repeat.Expander(score).process()
    except Exception:
        performance_score = score
    tempo_points = _tempo_map(performance_score, default_bpm)
    performance_parts = []
    cursor_events = []
    for part in performance_score.parts:
        instrument_name = _instrument_name_for_part(part, fallback_instrument)
        is_melody_part = 'melody' in (part.partName or '').lower()
        is_single_string_solo = (
            instrument_name in {'Violin', 'Cello'} and
            len(performance_score.parts) == 1
        )
        is_continuous_lead = is_melody_part or is_single_string_solo
        is_piano_right_hand = (
            instrument_name == 'Piano' and
            'right hand' in (part.partName or '').lower()
        )
        is_piano_left_hand = (
            instrument_name == 'Piano' and
            'left hand' in (part.partName or '').lower()
        )
        is_connected_line = is_continuous_lead or is_piano_right_hand
        sustain_tails = {
            'Violin': 0.40, 'Cello': 0.36, 'Flute': 0.18,
            'Clarinet': 0.17, 'Saxophone': 0.15, 'Trumpet': 0.12,
        }
        rendered_notes = []
        active_ties = {}
        flat = _safe_flatten(part)
        for element in flat.notes:
            try:
                offset = float(element.getOffsetInHierarchy(performance_score))
            except Exception:
                offset = float(element.offset)
            start_seconds = _seconds_for_offset(offset, tempo_points)
            duration_seconds = _performance_duration(element, performance_score, tempo_points)
            # Keep the recognizable right-hand line clearly above the bass in
            # the generated playback. This affects audio only, not notation.
            # Keep both hands audible. The left hand needs to support the
            # arrangement, while the right hand remains the clear lead.
            detected_velocity = int(element.volume.velocity or 80)
            if is_piano_right_hand:
                velocity = max(76, min(120, round(detected_velocity * 1.08)))
            elif is_piano_left_hand:
                velocity = max(44, min(88, round(detected_velocity * 0.76)))
            else:
                velocity = max(42, min(112, detected_velocity))
            articulation_names = {a.__class__.__name__ for a in getattr(element, 'articulations', [])}
            if 'Staccato' in articulation_names:
                duration_seconds *= 0.55
            elif 'Staccatissimo' in articulation_names:
                duration_seconds *= 0.35
            elif 'Tenuto' in articulation_names:
                duration_seconds *= 1.05
            try:
                slurred = any('Slur' in spanner.classes for spanner in element.getSpannerSites())
            except Exception:
                slurred = False
            if not is_connected_line and not slurred and 'Tenuto' not in articulation_names:
                duration_seconds *= 0.98
            # The lead transcription is a continuous line. A tiny overlap
            # prevents quantization from creating audible gaps between notes.
            if is_connected_line and 'Staccato' not in articulation_names:
                duration_seconds += 0.025
            if (is_piano_right_hand and
                    'Staccato' not in articulation_names):
                # Piano melody needs audible pedal-like decay. This is audio
                # only, so the engraved rhythm remains exact while held notes
                # can ring naturally beneath the next attack.
                duration_seconds += min(
                    0.78 if duration_seconds >= 0.75 else 0.30,
                    max(0.16, duration_seconds * 0.46),
                )
            elif (instrument_name in sustain_tails and
                  'Staccato' not in articulation_names and
                  duration_seconds >= 0.30):
                # Bowed strings and winds need time to release their tone.
                # The tail lives only in generated audio, preserving notation.
                duration_seconds += min(
                    sustain_tails[instrument_name], duration_seconds * 0.24)
            if 'Accent' in articulation_names or 'StrongAccent' in articulation_names:
                velocity = 105
            if any(f.__class__.__name__ == 'Fermata' for f in getattr(element, 'expressions', [])):
                duration_seconds *= 1.5
            pitches = ([element.nameWithOctave] if isinstance(element, note.Note)
                       else [pitch.nameWithOctave for pitch in element.pitches])
            event = {
                'offset': start_seconds,
                'duration': duration_seconds,
                'pitches': pitches,
                'velocity': velocity,
                # The melody is lifted through level and resonance, not a
                # permanent octave stack that can sound like duplicate chords.
                'octave_doubling': False,
            }
            playback_event, was_added = _append_or_merge_tied_event(
                rendered_notes, active_ties, event, _element_tie_type(element))
            if was_added:
                cursor_events.append({
                    'time': start_seconds,
                    'score_offset': offset,
                    'duration': duration_seconds,
                    'pitches': pitches,
                    '_source_event': playback_event,
                })
            else:
                for cursor_event in reversed(cursor_events):
                    if cursor_event.get('_source_event') is playback_event:
                        cursor_event['duration'] = playback_event['duration']
                        break
        if rendered_notes:
            if is_connected_line:
                # Basic pitch tracking and notation quantization can leave a
                # tiny artificial silence between connected bowed notes. Make
                # those joins overlap softly, but never cross a real rest.
                rendered_notes.sort(key=lambda event: event['offset'])
                for index, current in enumerate(rendered_notes[:-1]):
                    following = rendered_notes[index + 1]
                    current_end = current['offset'] + current['duration']
                    gap = following['offset'] - current_end
                    max_bridge_gap = 0.18 if is_continuous_lead else 0.07
                    can_bridge = -0.02 <= gap <= max_bridge_gap
                    if instrument_name == 'Violin':
                        # The written score can contain short gaps from
                        # quantization.  Join only a small, stepwise,
                        # non-repeated Violin transition; a rest, leap, or
                        # repeated bow attack must remain audible.
                        violin_gap = max(0.0, gap)
                        legato_bridge = _violin_legato_transition(
                            current, following, violin_gap)
                        rearticulation_join = (
                            not legato_bridge and
                            _violin_short_transition(current, following, violin_gap))
                        can_bridge = legato_bridge or rearticulation_join
                    if can_bridge:
                        if instrument_name == 'Violin' and not legato_bridge:
                            # End exactly at the next attack: distinct bow
                            # articulation, no artificial digital silence.
                            current['duration'] += gap
                        else:
                            current['duration'] += gap + (0.045 if instrument_name == 'Violin' else 0.035)
            performance_parts.append({
                'instrument': instrument_name,
                'notes': rendered_notes,
                'role': 'piano_melody' if is_piano_right_hand else (
                    'piano_bass' if is_piano_left_hand else (
                        'lead' if is_continuous_lead else None)),
                'volume': 110 if is_piano_right_hand else (84 if is_piano_left_hand else 100),
                'reverb': 92 if is_piano_right_hand else (68 if is_piano_left_hand else 56),
            })
    if not performance_parts:
        return False, 0.0, []

    for cursor_event in cursor_events:
        cursor_event.pop('_source_event', None)

    # Keep sustained left-hand harmony present, but duck it whenever it would
    # mask an active right-hand melody. This is audio mixing only; the score
    # retains the exact notes and durations it generated.
    melody_events = [
        event for part in performance_parts if part.get('role') == 'piano_melody'
        for event in part['notes']
    ]
    if melody_events:
        for bass_part in (part for part in performance_parts
                          if part.get('role') == 'piano_bass'):
            for bass_event in bass_part['notes']:
                bass_start = bass_event['offset']
                bass_end = bass_start + bass_event['duration']
                overlaps_melody = any(
                    melody['offset'] < bass_end and
                    melody['offset'] + melody['duration'] > bass_start
                    for melody in melody_events
                )
                if overlaps_melody:
                    # Light ducking keeps the lead clear without making the
                    # accompaniment disappear whenever it overlaps a melody.
                    bass_event['velocity'] = min(int(bass_event['velocity']), 52)
    # These offsets are already seconds, so render them at 60 BPM (one quarter = one second).
    success, duration = parts_to_wav(performance_parts, output_path, tempo_bpm=60)
    return success, duration, sorted(cursor_events, key=lambda event: event['time'])


def _synthesize_fallback(notes_data, sample_rate, tempo_bpm, instrument_name, total_seconds):
    """Keep playback available when FluidSynth or a soundfont is unavailable."""
    timbres = {
        'Violin': [(1, 1.0), (2, 0.42), (3, 0.18), (4, 0.08)],
        'Cello': [(1, 1.0), (2, 0.50), (3, 0.22)],
        'Flute': [(1, 1.0), (2, 0.10)],
        'Guitar': [(1, 1.0), (2, 0.35), (3, 0.16)],
        'Ukulele': [(1, 1.0), (2, 0.28), (3, 0.10)],
        'Trumpet': [(1, 1.0), (2, 0.55), (3, 0.22)],
        'Saxophone': [(1, 1.0), (2, 0.58), (3, 0.25), (4, 0.09), (5, 0.04)],
    }
    partials = timbres.get(instrument_name, [(1, 1.0), (2, 0.20)])
    audio = np.zeros(int((total_seconds + 0.5) * sample_rate), dtype=np.float64)
    seconds_per_beat = 60.0 / tempo_bpm
    plucked = instrument_name in {'Guitar', 'Electric Guitar', 'Ukulele', 'Bass Guitar'}
    bowed = instrument_name in {'Violin', 'Cello'}
    release_seconds = 0.14 if bowed else (0.08 if instrument_name in {
        'Flute', 'Clarinet', 'Saxophone', 'Trumpet'
    } else 0.04)
    for event in notes_data:
        sax_plan = event.get('_sax_performance') if instrument_name == 'Saxophone' else None
        start = sax_plan['start'] if sax_plan else event['offset'] * seconds_per_beat
        duration_seconds = (sax_plan['duration'] if sax_plan else
                            max(0.08, event['duration'] * seconds_per_beat))
        start_index = int(start * sample_rate)
        length = min(int(duration_seconds * sample_rate), len(audio) - start_index)
        if length <= 0:
            continue
        time = np.arange(length) / sample_rate
        envelope = np.minimum(time / 0.025, 1.0)
        envelope *= np.minimum((duration_seconds - time) / release_seconds, 1.0).clip(0, 1)
        if plucked:
            envelope *= np.exp(-3.2 * time / duration_seconds)
        pitch_values = [(pitch_to_midi(pitch_name), 1.0)
                        for pitch_name in event['pitches']]
        if event.get('octave_doubling'):
            octave_layer = [
                (midi_pitch + 12, 0.34)
                for midi_pitch, _ in pitch_values
                if midi_pitch <= 84
            ]
            pitch_values.extend(octave_layer)
        for midi_pitch, level_scale in pitch_values:
            frequency = 440.0 * 2 ** ((midi_pitch - 69) / 12)
            if (instrument_name == 'Saxophone' and sax_plan and
                    sax_plan['vibrato'] and duration_seconds >= 0.28):
                vibrato_rate = 4.8 + (midi_pitch % 4) * 0.22
                vibrato_ratio = 2 ** (14 / 1200) - 1
                vibrato_time = np.maximum(0, time - duration_seconds * 0.42)
                phase = (2 * np.pi * frequency * time +
                         (frequency * vibrato_ratio / vibrato_rate) *
                         np.sin(2 * np.pi * vibrato_rate * vibrato_time) *
                         (time >= duration_seconds * 0.42))
                wave = sum(level * np.sin(harmonic * phase)
                           for harmonic, level in partials)
            elif instrument_name == 'Cello' and duration_seconds >= 0.28:
                # A small, natural pitch modulation gives the fallback bowed
                # cello voice life even when FluidSynth is unavailable. Keep
                # violin pitch fixed: its exposed lead register makes even a
                # small synthetic bend sound noticeably out of tune.
                vibrato_rate = 5.1
                vibrato_ratio = 2 ** (12 / 1200) - 1
                phase = (2 * np.pi * frequency * time +
                         (frequency * vibrato_ratio / vibrato_rate) *
                         np.sin(2 * np.pi * vibrato_rate * time))
                wave = sum(level * np.sin(harmonic * phase)
                           for harmonic, level in partials)
            else:
                wave = sum(level * np.sin(2 * np.pi * harmonic * frequency * time)
                           for harmonic, level in partials)
            audio[start_index:start_index + length] += 0.20 * level_scale * envelope * wave
    return audio


def _add_instrument_resonance(audio, sample_rate, instrument_names):
    """Give sustained instruments a small, instrument-appropriate room tail."""
    profiles = {
        'Violin': ((31, 0.16), (59, 0.10), (97, 0.06), (151, 0.035)),
        'Cello': ((37, 0.16), (71, 0.10), (119, 0.06), (181, 0.035)),
        'Flute': ((29, 0.075), (61, 0.045), (109, 0.025)),
        'Clarinet': ((33, 0.07), (69, 0.04), (113, 0.022)),
        'Saxophone': ((35, 0.065), (73, 0.04), (127, 0.02)),
        'Trumpet': ((27, 0.06), (53, 0.035), (89, 0.018)),
        'Guitar': ((19, 0.045), (43, 0.026), (79, 0.012)),
        'Electric Guitar': ((21, 0.05), (47, 0.03), (91, 0.016)),
        'Ukulele': ((17, 0.035), (39, 0.02)),
        'Bass Guitar': ((31, 0.035), (67, 0.018)),
    }
    active_profile = next(
        (profiles[name] for name in instrument_names if name in profiles), None)
    if active_profile is None:
        return audio
    resonant = audio.astype(np.float64, copy=True)
    for milliseconds, level in active_profile:
        delay = max(1, int(sample_rate * milliseconds / 1000))
        if delay < len(audio):
            resonant[delay:] += audio[:-delay] * level
    return resonant


def _band_playback_part(instrument_name, role, notes, tempo_map=None, tempo_bpm=120,
                        pedal_events=None):
    """Apply a predictable role-aware balance to a generated band part."""
    normalized_role = (role or 'harmony').lower()
    levels = {
        'melody': (118, 48), 'lead': (118, 48),
        'harmony': (88, 42), 'chords': (88, 42),
        'bass': (96, 36),
        'drums': (88, 34), 'rhythm': (88, 34),
    }
    volume, reverb = levels.get(normalized_role, (80, 50))
    for event in notes:
        event['arrangement_role'] = normalized_role
    if tempo_map:
        points = sorted({float(point['offset']): float(point['bpm'])
                         for point in tempo_map}.items())
        if points[0][0] > 0:
            points.insert(0, (0.0, float(tempo_bpm)))
        timed_notes = []
        for event in notes:
            start = _seconds_for_offset(event['offset'], points)
            end = _seconds_for_offset(event['offset'] + event['duration'], points)
            timed_notes.append({**event, 'offset': start * tempo_bpm / 60.0,
                                'duration': (end - start) * tempo_bpm / 60.0})
        notes = timed_notes
    return {
        'instrument': instrument_name,
        'notes': notes,
        'role': normalized_role,
        'volume': volume,
        'reverb': reverb,
        'pedal_events': list(pedal_events or []),
    }


def _render_solo_violin_v3_1(midi_path, output_path, sample_rate=44100):
    """Render the selected V3 notes with their V3.1 performance MIDI intact."""
    source = pretty_midi.PrettyMIDI(midi_path)
    notes = [note for track in source.instruments for note in track.notes]
    if not notes:
        raise ValueError('Violin V3.1 performance MIDI contains no notes.')
    soundfont_path = _find_soundfont({'Violin'})
    if not soundfont_path:
        raise FileNotFoundError('Violin Real 2026.SF2 is unavailable.')
    _load_fluidsynth_binding()
    audio = source.fluidsynth(fs=sample_rate, sf2_path=soundfont_path)
    if audio is None or not len(audio):
        raise RuntimeError('Violin V3.1 SoundFont rendered no audio.')
    audio = _add_instrument_resonance(
        np.asarray(audio, dtype=np.float64), sample_rate, {'Violin'})
    peak = float(np.max(np.abs(audio)))
    if peak <= 0:
        raise RuntimeError('Violin V3.1 SoundFont rendered silence.')
    audio = audio / peak * .85
    wavfile.write(output_path, sample_rate, (audio * 32767).astype(np.int16))
    return True, len(audio) / sample_rate


def _render_solo_violin_vpo(plan_path, output_path, sample_rate=44100):
    """Use the same V3.1 events as the SF2 A/B, now with the VPO patch."""
    import json
    from solo_violin_vpo_renderer import render_vpo_performance

    module_dir = os.path.dirname(__file__)
    sfz_path = os.environ.get('AUGMENT_VIOLIN_VPO_SFZ_PATH') or os.path.join(
        module_dir, 'resources', 'vpo', 'Virtual-Playing-Orchestra3',
        'Strings', '1st-violin-SOLO-PERF.sfz')
    renderer_path = (os.environ.get('AUGMENT_SFIZZ_RENDER_PATH') or
                     shutil.which('sfizz_render') or os.path.join(
                         module_dir, 'runtime', 'sfizz', 'bin',
                         'sfizz_render.exe' if os.name == 'nt' else
                         'sfizz_render'))
    with open(plan_path, encoding='utf-8') as handle:
        events = json.load(handle)['events']
    return render_vpo_performance(
        events, output_path, sfz_path, renderer_path, sample_rate)


def _render_production_solo_violin(plan_path, midi_path, output_path):
    try:
        generated, duration = _render_solo_violin_vpo(plan_path, output_path)
        return generated, duration, 'VPO Performance Orchestra (sfizz)'
    except Exception as exc:
        print(f'[violin_vpo] Render unavailable; using V3.1 SF2 fallback: {exc}',
              flush=True)
        generated, duration = _render_solo_violin_v3_1(midi_path, output_path)
        return generated, duration, 'Violin Real 2026.SF2 (fallback)'


def _saxophone_performance_plan(notes, seconds_per_beat):
    """Create restrained, repeatable live-sax phrasing for a monophonic lead."""
    plans = []
    ordered = sorted(notes, key=lambda event: event['offset'])
    for index, event in enumerate(ordered):
        start = float(event['offset']) * seconds_per_beat
        duration = max(1e-6, float(event['duration']) * seconds_per_beat)
        previous = ordered[index - 1] if index else None
        following = ordered[index + 1] if index + 1 < len(ordered) else None
        previous_end = ((previous['offset'] + previous['duration']) * seconds_per_beat
                        if previous else None)
        following_start = (following['offset'] * seconds_per_beat
                           if following else None)
        gap_before = start - previous_end if previous_end is not None else 1.0
        gap_after = (following_start - (start + duration)
                     if following_start is not None else 1.0)
        phrase_start = previous is None or gap_before >= 0.16
        phrase_end = following is None or gap_after >= 0.18
        pitch = pitch_to_midi(event['pitches'][0]) if event.get('pitches') else 60
        previous_pitch = (pitch_to_midi(previous['pitches'][0])
                          if previous and previous.get('pitches') else pitch)
        leap = abs(pitch - previous_pitch)
        rendered_duration = duration
        # Preserve tongue attacks/rests rather than inventing index-based effects.
        if following_start is not None:
            rendered_duration = min(duration, max(1e-6, following_start-start))
        ghost = False
        plan = {
            'start': start,
            'duration': rendered_duration,
            'velocity_delta': 4 if phrase_start else 0,
            'phrase_start': phrase_start,
            'phrase_end': phrase_end,
            'ghost': ghost,
            'vibrato': False,
            'scoop': False,
            'fall': False,
            'growl': False,
            'pitch': pitch,
        }
        event['_sax_performance'] = plan
        plans.append(plan)
    return plans


def _add_saxophone_midi_expression(inst, plan):
    """Encode one sax plan with breath-like swells and sparse pitch gestures."""
    start, end = plan['start'], plan['start'] + plan['duration']
    if plan['duration'] >= 0.34:
        inst.control_changes.extend([
            pretty_midi.ControlChange(11, 88 if plan['phrase_start'] else 96, start),
            pretty_midi.ControlChange(11, 111, start + plan['duration'] * 0.58),
            pretty_midi.ControlChange(11, 98, end),
        ])
    if plan['growl']:
        inst.control_changes.extend([
            pretty_midi.ControlChange(1, 22, start + 0.06),
            pretty_midi.ControlChange(1, 0, end),
        ])
    if plan['scoop']:
        inst.pitch_bends.extend([
            pretty_midi.PitchBend(-900, start),
            pretty_midi.PitchBend(-320, start + 0.035),
            pretty_midi.PitchBend(0, start + 0.075),
        ])
    if plan['vibrato']:
        vibrato_start = start + plan['duration'] * 0.42
        rate = 4.8 + (plan['pitch'] % 4) * 0.22
        depth = 360 + (plan['pitch'] % 3) * 80
        time = vibrato_start
        while time < end - 0.035:
            inst.pitch_bends.append(pretty_midi.PitchBend(
                int(np.sin(2 * np.pi * rate * (time - vibrato_start)) * depth), time))
            time += 0.025
        inst.pitch_bends.append(pretty_midi.PitchBend(0, min(time, end)))
    if plan['fall']:
        fall_start = max(start, end - 0.12)
        inst.pitch_bends.extend([
            pretty_midi.PitchBend(0, fall_start),
            pretty_midi.PitchBend(-700, fall_start + 0.065),
            pretty_midi.PitchBend(-1350, end - 0.006),
            pretty_midi.PitchBend(0, end),
        ])


def _piano_pedal_windows(notes, seconds_per_beat):
    """Use accompaniment entrances to pedal without chopping melodic runs."""
    accompaniment = [event for event in notes if event.get('role') == 'piano_bass']
    if accompaniment:
        notes = accompaniment
    grouped = {}
    for event in notes:
        start = float(event['offset']) * seconds_per_beat
        end = start + float(event['duration']) * seconds_per_beat
        grouped[start] = max(grouped.get(start, end), end)
    starts = sorted(grouped)
    windows = []
    for index, start in enumerate(starts):
        end = min(grouped[start] + 0.12, start + 0.8)
        if index + 1 < len(starts):
            end = min(end, starts[index + 1] - 0.015)
        if end - start >= 0.08:
            windows.append((start + 0.015, end))
    return windows


def _piano_cc64_events(part, seconds_per_beat):
    """Prefer model-predicted CC64; otherwise retain the legacy heuristic."""
    predicted = part.get('pedal_events') or []
    if predicted:
        return [(max(0.0, float(event['time'])),
                 max(0, min(127, int(event['value'])))) for event in predicted]
    events = [(0.0, 0)]
    for down, up in _piano_pedal_windows(part['notes'], seconds_per_beat):
        events.extend([(down, 80), (up, 0)])
    return events


def _piano_hand_velocity(event):
    """Preserve hand balance even when the whole Solo part is called melody."""
    velocity = int(event.get('velocity', 80))
    if event.get('role') == 'piano_bass':
        density = max(1, len(event.get('pitches', [])))
        return max(40, min(90, round(velocity / density ** 0.1)))
    if event.get('role') == 'piano_melody':
        return max(55, min(112, round(velocity * 1.08)))
    return None


_EXPRESSIVE_LEAD_INSTRUMENTS = {
    'Violin', 'Cello', 'Flute', 'Clarinet', 'Saxophone', 'Trumpet',
}
_PLUCKED_INSTRUMENTS = {'Guitar', 'Electric Guitar', 'Ukulele', 'Bass Guitar'}


def _is_monophonic_line(notes):
    """Return true only when MIDI-wide controllers are safe for this part.

    Pitch bend and CC11 apply to an entire MIDI channel/instrument.  Applying
    them to a chord would bend or swell every note together, so expressive
    controller data is deliberately limited to a single, non-overlapping line.
    """
    ordered = sorted(notes, key=lambda event: float(event.get('offset', 0)))
    last_end = -1.0
    for event in ordered:
        if len(event.get('pitches', [])) != 1:
            return False
        start = float(event.get('offset', 0))
        end = start + max(0.01, float(event.get('duration', 0)))
        if start < last_end - 0.025:
            return False
        last_end = max(last_end, end)
    return bool(ordered)


def _violin_short_transition(current, following, gap_seconds):
    """Return true when a tiny notation gap should not become audible silence."""
    if not (0.0 <= gap_seconds <= 0.060):
        return False
    current_pitches = current.get('pitches', [])
    following_pitches = following.get('pitches', [])
    if len(current_pitches) != 1 or len(following_pitches) != 1:
        return False
    return (float(current.get('duration', 0.0)) >= 0.12 and
            float(following.get('duration', 0.0)) >= 0.12)


def _violin_legato_transition(current, following, gap_seconds):
    """Return true only for a clearly connected solo-Violin transition.

    This is playback-only.  It deliberately does not treat repeated attacks,
    large leaps, very short detached notes, or an actual rest as legato.  Those
    are all meaningful musical distinctions in a generated solo line.
    """
    if not _violin_short_transition(current, following, gap_seconds):
        return False
    current_pitches = current['pitches']
    following_pitches = following['pitches']
    current_pitch = pitch_to_midi(current_pitches[0])
    following_pitch = pitch_to_midi(following_pitches[0])
    if current_pitch == following_pitch:
        return False  # Retain the bow re-articulation of repeated notes.
    if abs(following_pitch - current_pitch) > 7:
        return False  # Do not make a large melodic leap sound artificially tied.
    return True


def _lead_performance_plan(instrument_name, notes, seconds_per_beat):
    """Create repeatable phrasing for a monophonic bowed or wind lead.

    This adds small, musical variation to attack level, connected-note timing,
    CC11 expression and late vibrato.  It does not alter the written score or
    invent pitches.  The pattern is deterministic, so the same generated sheet
    always renders the same audio.
    """
    plans = []
    ordered = sorted(enumerate(notes), key=lambda item: float(item[1]['offset']))
    for phrase_index, (event_index, event) in enumerate(ordered):
        start = float(event['offset']) * seconds_per_beat
        source_duration = float(event['duration']) * seconds_per_beat
        duration = (max(1e-6, source_duration) if instrument_name == 'Flute'
                    else max(0.09, source_duration))
        previous = ordered[phrase_index - 1][1] if phrase_index else None
        following = (ordered[phrase_index + 1][1]
                     if phrase_index + 1 < len(ordered) else None)
        previous_end = ((float(previous['offset']) + float(previous['duration'])) *
                        seconds_per_beat if previous else None)
        following_start = (float(following['offset']) * seconds_per_beat
                           if following else None)
        gap_before = start - previous_end if previous_end is not None else 1.0
        gap_after = (following_start - (start + duration)
                     if following_start is not None else 1.0)
        phrase_start = previous is None or gap_before >= 0.14
        phrase_end = following is None or gap_after >= 0.16
        if instrument_name == 'Violin':
            # The first note after a genuine rest can still lead directly into
            # the next note.  Phrase-start status should shape its attack, not
            # force an artificial hole before a clear stepwise continuation.
            connected = (not phrase_end and
                         _violin_legato_transition(event, following, gap_after))
            rearticulate = (not phrase_end and not connected and
                             _violin_short_transition(event, following, gap_after))
        else:
            connected = not phrase_start and not phrase_end and gap_after <= 0.08
            rearticulate = False
        pitch = pitch_to_midi(event['pitches'][0])
        # A tiny attack displacement avoids machine-perfect repeated attacks;
        # it stays well below normal transcription/notation resolution.
        attack_offset = (0.0 if instrument_name == 'Flute' else
                         0.004 if phrase_start else ((phrase_index % 3) - 1) * 0.0015)
        following_phrase_start = following is not None and gap_after >= 0.14
        following_attack_offset = (
            0.004 if following_phrase_start else
            (((phrase_index + 1) % 3) - 1) * 0.0015
        )
        rendered_duration = duration
        if instrument_name == 'Flute':
            # A short tongue attack or a real rest must not become legato
            # merely because the next note is nearby. Preserve MIDI releases.
            rendered_duration = duration
        elif phrase_end:
            rendered_duration = max(0.075, duration - min(0.055, duration * 0.10))
        elif connected:
            # A bowed transition needs a small true overlap.  The previous
            # cap could leave a 10–25 ms hole after deterministic attack
            # offsets, which is audible with a sampled Violin release.
            bridge = (min(0.040, max(0.0, gap_after + 0.015))
                      if instrument_name == 'Violin'
                      else min(0.022, max(0.0, gap_after + 0.010)))
            if instrument_name == 'Violin':
                bridge = min(0.040, max(
                    0.0, gap_after + following_attack_offset - attack_offset + 0.015))
            rendered_duration += bridge
        elif rearticulate:
            # A repeated pitch or a large leap still needs its own bow attack,
            # but a tiny transcription/quantization gap should not create
            # silence before that attack.
            rendered_duration += max(
                0.0, gap_after + following_attack_offset - attack_offset)
        plan = {
            'event_index': event_index,
            'start': start + attack_offset,
            'duration': rendered_duration,
            'velocity_delta': (5 if phrase_start else 0) + (-3, 1, 3, -1)[phrase_index % 4],
            'phrase_start': phrase_start,
            'phrase_end': phrase_end,
            'connected': connected,
            'rearticulate': rearticulate,
            'pitch': pitch,
            'vibrato': (instrument_name in {'Violin', 'Cello'} and
                        rendered_duration >= 0.34 and not phrase_start) or
                       (instrument_name in {'Flute', 'Clarinet', 'Trumpet'} and
                        rendered_duration >= 0.55 and not phrase_start),
        }
        plans.append(plan)
    return {plan['event_index']: plan for plan in plans}


def _add_lead_midi_expression(inst, instrument_name, plan):
    """Write safe MIDI expression for one planned lead note."""
    start = plan['start']
    end = start + plan['duration']
    if plan['duration'] >= 0.18:
        # Expression (CC11) gives a gentle bow/breath contour while preserving
        # CC7 as the part's overall mix level.
        attack = 86 if plan['phrase_start'] else 94
        crest = 108 if instrument_name in {'Violin', 'Cello'} else 104
        release = 91 if plan['phrase_end'] else 98
        inst.control_changes.extend([
            pretty_midi.ControlChange(11, attack, start),
            pretty_midi.ControlChange(11, crest, start + plan['duration'] * 0.48),
            pretty_midi.ControlChange(11, release, end),
        ])
    if not plan['vibrato']:
        return
    vibrato_start = start + plan['duration'] * 0.42
    rate = 5.0 if instrument_name in {'Violin', 'Cello'} else 4.7
    depth = 250 if instrument_name in {'Violin', 'Cello'} else 165
    time = vibrato_start
    while time < end - 0.03:
        inst.pitch_bends.append(pretty_midi.PitchBend(
            int(np.sin(2 * np.pi * rate * (time - vibrato_start)) * depth), time))
        time += 0.03
    inst.pitch_bends.append(pretty_midi.PitchBend(0, min(time, end)))


def parts_to_wav(parts, output_path, sample_rate=44100, tempo_bpm=120):
    """Render one or more score parts with their correct GM programs."""
    if not parts:
        return False, 0.0
    seconds_per_beat = 60.0 / tempo_bpm
    all_notes = [event for part in parts for event in part['notes']]
    if not all_notes:
        return False, 0.0
    max_time = max(event['offset'] * seconds_per_beat + event['duration'] * seconds_per_beat
                   for event in all_notes)
    if max_time <= 0:
        return False, 0.0
    instrument_names = {part['instrument'] for part in parts}
    soundfont_path = _find_soundfont(instrument_names)
    # Custom Classical Guitar exposes its playable preset at program 0 rather
    # than General MIDI program 24. This is limited to a Guitar-only render;
    # mixed arrangements continue using the General MIDI SoundFont and program.
    use_custom_classical_guitar = (
        instrument_names == {'Guitar'} and
        soundfont_path and
        os.path.basename(soundfont_path).lower() ==
        _GUITAR_SOUNDFONT_FILENAME.lower()
    )
    # The selected Real Violin SoundFont stores its solo preset at program 0
    # instead of General MIDI Violin program 40. Mixed arrangements retain the
    # General MIDI font and program assignments.
    use_custom_violin = (
        instrument_names == {'Violin'} and
        soundfont_path and
        os.path.basename(soundfont_path).lower() ==
        _VIOLIN_SOUNDFONT_FILENAME.lower()
    )
    # The supplied Tenor Saxophone font is stored at program 66 (GM tenor
    # sax), while Augment's generic Saxophone mapping uses program 65.
    use_tenor_saxophone = (
        instrument_names == {'Saxophone'} and
        soundfont_path and
        os.path.basename(soundfont_path).lower() ==
        _SAXOPHONE_SOUNDFONT_FILENAME.lower()
    )

    midi_obj = pretty_midi.PrettyMIDI(initial_tempo=tempo_bpm)
    for part in parts:
        instrument_name = part['instrument']
        arrangement_role = (part.get('role') or '').lower()
        inst = pretty_midi.Instrument(
            name=instrument_name,
            program=(0 if (
                (use_custom_classical_guitar and instrument_name == 'Guitar') or
                (use_custom_violin and instrument_name == 'Violin')
            ) else (66 if use_tenor_saxophone and instrument_name == 'Saxophone'
                    else _PLAYBACK_PROGRAMS.get(instrument_name, 0))),
            is_drum=instrument_name == 'Drums',
        )
        midi_obj.instruments.append(inst)
        # General MIDI volume and reverb sends are respected by FluidSynth and
        # let piano hands occupy different depth in the same performance.
        inst.control_changes.append(pretty_midi.ControlChange(
            number=7, value=int(part.get('volume', 100)), time=0,
        ))
        inst.control_changes.append(pretty_midi.ControlChange(
            number=91, value=int(part.get('reverb', 56)), time=0,
        ))
        expressive_sax = (
            instrument_name == 'Saxophone' and
            arrangement_role in {'melody', 'lead'}
        )
        sax_plans = (_saxophone_performance_plan(part['notes'], seconds_per_beat)
                     if expressive_sax else None)
        expressive_lead = (
            instrument_name in _EXPRESSIVE_LEAD_INSTRUMENTS and
            not expressive_sax and
            (arrangement_role in {'melody', 'lead'} or _is_monophonic_line(part['notes']))
        )
        lead_plans = (_lead_performance_plan(
            instrument_name, part['notes'], seconds_per_beat)
            if expressive_lead else {})
        for event_index, event in enumerate(part['notes']):
            if (event.get('preserve_band_performance') or
                    (instrument_name in {'Guitar', 'Electric Guitar'} and event.get('preserve_guitar_performance')) or
                    (instrument_name == 'Piano' and event.get('preserve_piano_performance'))):
                # Canonical Guitar MIDI already contains its physical strokes,
                # ringing durations and role dynamics. Do not re-strum it.
                start = float(event['offset']) * seconds_per_beat
                end = start + float(event['duration']) * seconds_per_beat
                for pitch_name in event['pitches']:
                    inst.notes.append(pretty_midi.Note(
                        velocity=int(event['velocity']), pitch=pitch_to_midi(pitch_name),
                        start=start, end=end,
                    ))
                continue
            sax_plan = sax_plans[event_index] if sax_plans else None
            lead_plan = lead_plans.get(event_index)
            start_time = (sax_plan['start'] if sax_plan else
                          lead_plan['start'] if lead_plan else
                          event['offset'] * seconds_per_beat)
            duration_seconds = (sax_plan['duration'] if sax_plan else
                                lead_plan['duration'] if lead_plan else
                                max(0.1, event['duration'] * seconds_per_beat))
            detected_velocity = int(event.get('velocity', 80))
            event_role = event.get('arrangement_role') or arrangement_role
            piano_velocity = (_piano_hand_velocity(event)
                              if instrument_name == 'Piano' else None)
            if piano_velocity is not None:
                event_velocity = piano_velocity
            elif event_role in {'melody', 'lead'}:
                event_velocity = max(78, min(120, round(detected_velocity * 1.15)))
            elif event_role in {'harmony', 'chords'}:
                event_velocity = max(34, min(96, round(detected_velocity * 0.85)))
            elif event_role == 'bass':
                event_velocity = max(40, min(100, round(detected_velocity * 0.92)))
            elif event_role in {'drums', 'rhythm'}:
                event_velocity = max(38, min(92, round(detected_velocity * 0.82)))
            elif event.get('role') == 'piano_melody':
                event_velocity = max(76, min(120, round(detected_velocity * 1.08)))
            elif event.get('role') == 'piano_bass':
                event_velocity = max(44, min(88, round(detected_velocity * 0.76)))
            else:
                event_velocity = max(42, min(112, detected_velocity))
            if sax_plan:
                event_velocity = max(
                    42, min(120, event_velocity + sax_plan['velocity_delta']))
            elif lead_plan:
                event_velocity = max(
                    38, min(120, event_velocity + lead_plan['velocity_delta']))
            # Chord attacks on a plucked instrument are never perfectly
            # simultaneous in real performance. Spread them by a few
            # milliseconds without changing the notated chord or its rhythm.
            chord_pitches = list(event['pitches'])
            if expressive_sax:
                # A solo saxophone cannot sound a detected chord stack.
                chord_pitches = chord_pitches[:1]
            if instrument_name in _PLUCKED_INSTRUMENTS and len(chord_pitches) > 1:
                chord_pitches.sort(key=pitch_to_midi)
                chord_pitches = [
                    (pitch_name, index * 0.008)
                    for index, pitch_name in enumerate(chord_pitches)
                ]
            else:
                chord_pitches = [(pitch_name, 0.0) for pitch_name in chord_pitches]
            for pitch_name, note_offset in chord_pitches:
                midi_pitch = max(0, min(127, pitch_to_midi(pitch_name)))
                inst.notes.append(pretty_midi.Note(
                    velocity=event_velocity,
                    pitch=midi_pitch,
                    start=start_time + note_offset,
                    end=start_time + note_offset + duration_seconds,
                ))
                # A restrained octave double gives the right-hand melody a
                # higher, clearer presence while keeping the written score
                # and its original melody unchanged.
                if event.get('octave_doubling') and midi_pitch <= 84 and not expressive_sax:
                    inst.notes.append(pretty_midi.Note(
                        velocity=max(30, int(event.get('velocity', 80) * 0.34)),
                        pitch=midi_pitch + 12,
                        start=start_time,
                        end=start_time + duration_seconds,
                    ))
            # FluidSynth receives pitch bends through MIDI. This is limited to
            # detected, sustained lead notes so normal notes remain stable.
            if sax_plan:
                _add_saxophone_midi_expression(inst, sax_plan)
            elif lead_plan:
                _add_lead_midi_expression(inst, instrument_name, lead_plan)
            vibrato = (None if lead_plan or instrument_name in {'Violin', 'Saxophone'}
                       else event.get('vibrato'))
            if (vibrato is None and instrument_name == 'Cello' and
                    duration_seconds >= 0.45):
                # Sustained bowed strings sound unnaturally static without a
                # small amount of movement, even when the source contour did
                # not provide a reliable vibrato measurement.
                vibrato = {'depth': 0.10, 'rate': 5.2}
            if vibrato and not inst.is_drum:
                depth = min(0.45, max(0.04, float(vibrato.get('depth', 0.16))))
                rate = min(9.0, max(3.5, float(vibrato.get('rate', 5.5))))
                step = 0.025
                time = start_time
                while time < start_time + duration_seconds:
                    bend = int(np.sin(2 * np.pi * rate * (time - start_time)) * depth / 2.0 * 8192)
                    inst.pitch_bends.append(pretty_midi.PitchBend(pitch=bend, time=time))
                    time += step
                inst.pitch_bends.append(pretty_midi.PitchBend(pitch=0, time=start_time + duration_seconds))

    for part, rendered_instrument in zip(parts, midi_obj.instruments):
        if part['instrument'] == 'Piano':
            rendered_instrument.control_changes.extend([
                pretty_midi.ControlChange(number=64, value=value, time=time)
                for time, value in _piano_cc64_events(part, seconds_per_beat)
            ])
        rendered_instrument.control_changes.sort(key=lambda event: event.time)
        rendered_instrument.pitch_bends.sort(key=lambda event: event.time)
    try:
        if not soundfont_path:
            raise FileNotFoundError(
                'No General MIDI soundfont was found. Set SOUNDFONT_PATH or add '
                'MuseScore_General.sf3 to backend/python/soundfonts.'
            )
        # Import the binding through our Windows-safe loader before pretty_midi
        # performs its own lazy import.
        _load_fluidsynth_binding()
        audio = midi_obj.fluidsynth(fs=sample_rate, sf2_path=soundfont_path)
        if audio is not None and len(audio):
            print(f'[playback] FluidSynth rendered {instrument_names} with {soundfont_path}', flush=True)
    except Exception as exc:
        if instrument_names in ({'Guitar'}, {'Piano'}):
            raise RuntimeError(
                f'{next(iter(instrument_names))} SoundFont playback failed for {soundfont_path}: {exc}'
            ) from exc
        print(f'[playback] FluidSynth SoundFont render unavailable, using fallback voice: {exc}')
        audio = None
    if audio is None or len(audio) == 0:
        if instrument_names in ({'Guitar'}, {'Piano'}):
            raise RuntimeError(f'{next(iter(instrument_names))} SoundFont produced no audio: {soundfont_path}')
        # Keep single-part playback usable even while the SoundFont is configured.
        primary = parts[0]
        audio = _synthesize_fallback(primary['notes'], sample_rate, tempo_bpm, primary['instrument'], max_time)

    audio = audio.astype(np.float64)
    # Piano resonance comes from held melody notes and the MIDI reverb send.
    # Do not layer short delayed copies here: those can sound like duplicate
    # chords instead of one continuous piano decay.
    audio = _add_instrument_resonance(audio, sample_rate, instrument_names)
    peak = np.max(np.abs(audio))
    if peak > 0:
        audio = audio / peak * 0.85
    audio_int16 = (audio * 32767).astype(np.int16)
    wavfile.write(output_path, sample_rate, audio_int16)
    return True, float(max_time)


def notes_to_wav(notes_data, output_path, sample_rate=44100, tempo_bpm=120, instrument_name='Piano'):
    return parts_to_wav(
        [{'instrument': instrument_name, 'notes': notes_data}],
        output_path,
        sample_rate=sample_rate,
        tempo_bpm=tempo_bpm,
    )


def _render_band_part_audio(render_part, output_path, tempo_bpm):
    """Best-effort isolated playback; notation generation must remain usable."""
    try:
        if render_part['instrument'] == 'Violin' and render_part.get('is_band'):
            from band_performance import violin_performance_events
            from solo_violin_performance import violin_events_to_midi
            planned, events, diagnostics = violin_performance_events(
                render_part['notes'], tempo_bpm)
            render_part['performance_diagnostics'] = diagnostics
            with tempfile.TemporaryDirectory(prefix='augment_band_violin_') as folder:
                try:
                    plan = os.path.join(folder, 'band_violin.json')
                    with open(plan, 'w', encoding='utf-8') as handle:
                        json.dump({'events': events}, handle)
                    rendered = _render_solo_violin_vpo(plan, output_path)
                    if not rendered[0]:
                        raise RuntimeError('VPO did not produce audio')
                    render_part['renderer_used'] = 'VPO Performance Orchestra (sfizz) / Solo phrasing'
                    return rendered
                except Exception as exc:
                    print(f'[band_violin] VPO unavailable; using Solo SF2 fallback: {exc}', flush=True)
                    midi_path = os.path.join(folder, 'band_violin.mid')
                    violin_events_to_midi(planned, midi_path)
                    rendered = _render_solo_violin_v3_1(midi_path, output_path)
                    render_part['renderer_used'] = 'Violin Real 2026.SF2 / Solo phrasing (fallback)'
                    return rendered
        render_part['renderer_used'] = 'FluidSynth / instrument SoundFont'
        return parts_to_wav(
            [render_part], output_path, tempo_bpm=tempo_bpm)
    except Exception as exc:
        print(f'[audio_pipeline] Part playback render failed: {exc}')
        return False, 0.0


def _mix_band_part_audio(rendered_parts, output_path, sample_rate=44100):
    """Mix isolated Band renders so every part keeps its Solo SoundFont.

    Rendering the whole band in one FluidSynth instance forces every channel
    through one shared SoundFont.  Isolated renders let Piano keep Stein Grand,
    Guitar keep Custom Classical Guitar, Violin use VPO when available, and other
    instruments retain their configured voice.  This mixer only balances the
    already-rendered audio; it does not alter MIDI notes or timing.
    """
    if not rendered_parts:
        return False, 0.0
    role_gain = {
        'melody': 1.0, 'lead': 1.0,
        'harmony': 0.70, 'chords': 0.70,
        'bass': 0.78,
        'drums': 0.66, 'rhythm': 0.66,
    }
    decoded = []
    for item in rendered_parts:
        path = item['path']
        if not item.get('success') or not os.path.isfile(path):
            return False, 0.0
        rate, samples = wavfile.read(path)
        if int(rate) != int(sample_rate):
            return False, 0.0
        source_dtype = samples.dtype
        samples = samples.astype(np.float64)
        if samples.ndim == 1:
            samples = np.column_stack((samples, samples))
        elif samples.ndim == 2 and samples.shape[1] == 1:
            samples = np.repeat(samples, 2, axis=1)
        elif samples.ndim != 2 or samples.shape[1] != 2:
            return False, 0.0
        if np.issubdtype(source_dtype, np.integer):
            samples /= float(np.iinfo(source_dtype).max)
        # Match perceived level without boosting quiet/noisy stems indefinitely.
        window = max(1, int(sample_rate * .4))
        powers = [float(np.sqrt(np.mean(samples[i:i + window] ** 2)))
                  for i in range(0, len(samples), window) if len(samples[i:i + window])]
        active_level = float(np.percentile(powers, 85)) if powers else 0.
        calibration = (max(.65, min(1.25, .12 / active_level))
                       if active_level > .01 else 1.)
        decoded.append((samples, role_gain.get(item.get('role', ''), 0.72) * calibration))
    maximum_length = max(len(samples) for samples, _ in decoded)
    mix = np.zeros((maximum_length, 2), dtype=np.float64)
    for samples, gain in decoded:
        mix[:len(samples)] += samples * gain
    peak = float(np.max(np.abs(mix))) if len(mix) else 0.0
    if peak <= 0:
        return False, 0.0
    if peak > 0.92:
        mix *= 0.92 / peak
    wavfile.write(output_path, sample_rate, (mix * 32767).astype(np.int16))
    print(
        f'[band_playback] Mixed {len(decoded)} isolated Solo-SoundFont renders '
        f'into {output_path}',
        flush=True,
    )
    return True, maximum_length / float(sample_rate)


def _combined_band_playback_events(render_parts, tempo_bpm):
    """Build one cursor timeline from every audible Band part.

    ``_band_playback_part`` has already folded tempo-map changes into its
    quarter offsets. Converting those offsets back to seconds gives Flutter
    the same timing used by the rendered WAV. Simultaneous attacks from
    separate parts become one full-score cursor event.
    """
    seconds_per_beat = 60.0 / max(1.0, float(tempo_bpm or 120.0))
    attacks = {}
    for part in render_parts or []:
        for event in part.get('notes', []):
            start = max(0.0, float(event.get('offset', 0.0)))
            duration = max(0.0, float(event.get('duration', 0.0)))
            # Keep real staggered attacks while merging notes that genuinely
            # begin together in separate instruments.
            key = round(start * seconds_per_beat, 3)
            combined = attacks.setdefault(key, {
                'time': key,
                'offset': start,
                'duration': duration,
                'pitches': [],
            })
            combined['duration'] = max(combined['duration'], duration)
            for pitch_name in event.get('pitches', []):
                if pitch_name not in combined['pitches']:
                    combined['pitches'].append(pitch_name)
    return [attacks[key] for key in sorted(attacks)]


def midi_to_instrument(midi_program):
    program_map = {
        0: 'Piano', 24: 'Guitar', 32: 'Guitar',
        33: 'Bass Guitar', 30: 'Electric Guitar',
        40: 'Violin', 42: 'Cello', 25: 'Guitar',
        64: 'Saxophone', 56: 'Trumpet', 73: 'Flute',
        71: 'Clarinet',
    }
    return program_map.get(midi_program, 'Piano')


def _fix_durations_for_musicxml(score):
    from music21 import duration
    # Cap note/rest durations in-place. This preserves measure and voice hierarchy.
    # 4.0 quarter lengths (whole note) is standard and safe for MusicXML export.
    try:
        for el in score.recurse().notesAndRests:
            if el.duration is not None and el.duration.quarterLength > 4.0:
                el.duration = duration.Duration(4.0)
    except Exception as e:
        print(f"Error fixing durations: {e}")
    return score


def _safe_write_musicxml(score, output_path):
    try:
        _fix_durations_for_musicxml(score)
        score.write('musicxml', fp=output_path)
        return True
    except Exception as e:
        print(f'MusicXML write failed, retrying with aggressive fix: {e}')
        from music21 import duration
        try:
            # Aggressive cap: reduce any duration longer than 2.0 to 2.0 in-place
            for el in score.recurse().notesAndRests:
                if el.duration is not None and el.duration.quarterLength > 2.0:
                    el.duration = duration.Duration(2.0)
            score.write('musicxml', fp=output_path)
            return True
        except Exception as e2:
            print(f'MusicXML write still failed: {e2}')
            return False


@app.route('/api/health', methods=['GET'])
def health():
    return jsonify({'status': 'ok', 'message': 'Sheet music API is running',
                    'flute_melody_accuracy': 'flute_consensus_pitch_v1',
                    'flute_short_releases': 'source_duration_v1',
                    'saxophone_performance': 'source_faithful_monophonic_v1',
                    'band_performance': 'source_coordinated_v1',
                    'generation_json': 'numpy_native_v1',
                    'electric_guitar_performance': 'physical_performance_v1',
                    'band_violin_playback': 'solo_phrasing_stereo_v1'})


_VOICE_RANGES = [
    # These are listening references, not a gender label. Lower voices can
    # belong to anyone, so every group includes a woman artist where useful.
    ('Bass', 40, 64, ['Avi Kaplan', 'Tracy Chapman']),
    ('Baritone', 45, 69, ['Hozier', 'Annie Lennox']),
    ('Tenor', 48, 72, ['Bruno Mars', 'Sade']),
    ('Contralto', 52, 76, ['Tracy Chapman', 'Annie Lennox']),
    ('Mezzo-soprano', 57, 81, ['Adele', 'Lady Gaga']),
    ('Soprano', 60, 84, ['Ariana Grande', 'Whitney Houston']),
]


def _voice_note_name(midi_value):
    return music21.pitch.Pitch(midi=int(round(midi_value))).nameWithOctave


def _classify_voice_range(low_midi, high_midi):
    observed_span = max(1.0, high_midi - low_midi)
    scored = []
    for name, range_low, range_high, artists in _VOICE_RANGES:
        overlap = max(0.0, min(high_midi, range_high) - max(low_midi, range_low))
        coverage = overlap / observed_span
        reference_coverage = overlap / max(1.0, range_high - range_low)
        center_distance = abs(((low_midi + high_midi) / 2) - ((range_low + range_high) / 2))
        score = coverage * 0.68 + reference_coverage * 0.22 - center_distance * 0.008
        scored.append((score, name, artists))
    scored.sort(reverse=True, key=lambda item: item[0])
    primary = scored[0]
    secondary = scored[1]
    blended = secondary[0] >= primary[0] - 0.09 and secondary[0] > 0.28
    label = f'{primary[1]} / {secondary[1]} mix' if blended else primary[1]
    artists = list(dict.fromkeys(primary[2] + (secondary[2] if blended else [])))[:4]
    return label, artists, secondary[1] if blended else None, primary[1]


@app.route('/api/voice/analyze', methods=['POST'])
def analyze_voice_range():
    """Estimate a sung range from a short low-to-high microphone recording."""
    uploaded = request.files.get('file')
    if uploaded is None or not uploaded.filename:
        return jsonify({'error': 'Please record a short vocal sample first.'}), 400
    path = os.path.join(UPLOAD_FOLDER, f'voice_{uuid.uuid4().hex}.wav')
    try:
        uploaded.save(path)
        # A short voice-range glide does not need full music-production sample
        # rate. 16 kHz plus a wider hop keeps the result responsive on the
        # local backend while preserving the vocal fundamental accurately.
        audio, sample_rate = librosa.load(path, sr=16000, mono=True)
        audio = audio[:sample_rate * 15]
        if len(audio) < sample_rate * 2:
            return jsonify({'error': 'Sing for at least a few seconds, from low to high.'}), 400
        peak = float(np.max(np.abs(audio)))
        if peak < 0.003:
            return jsonify({'error': 'We could not hear your voice. Move closer to the microphone and try again.'}), 422
        # Phone recordings can be very quiet. Normalising here improves pitch
        # confidence without changing the actual pitch contour.
        audio = audio / peak
        f0, voiced, probabilities = librosa.pyin(
            audio,
            fmin=librosa.note_to_hz('E2'),
            fmax=librosa.note_to_hz('C6'),
            sr=sample_rate,
            frame_length=2048,
            hop_length=512,
            fill_na=np.nan,
        )
        confidence = np.nan_to_num(probabilities, nan=0.0)
        rms = librosa.feature.rms(
            y=audio, frame_length=2048, hop_length=512
        )[0]
        # A range test is deliberately a moving low-to-high glide, not a
        # sustained-note test. Keep quieter, lower-confidence voiced frames
        # when they have real vocal energy, rather than rejecting them as
        # "not steady".
        energy_floor = max(0.012, float(np.percentile(rms, 35)) * 0.30)
        valid = f0[
            np.isfinite(f0) &
            (confidence >= 0.12) &
            (rms >= energy_floor)
        ]
        # pYIN can be cautious with breathy voices and phone microphones.
        # YIN is less selective, so use it only as a fallback before showing
        # an error to the singer.
        if len(valid) < 8:
            fallback_f0 = librosa.yin(
                audio,
                fmin=librosa.note_to_hz('E2'),
                fmax=librosa.note_to_hz('C6'),
                sr=sample_rate,
                frame_length=2048,
                hop_length=512,
            )
            fallback_midi = librosa.hz_to_midi(fallback_f0)
            valid = fallback_f0[
                np.isfinite(fallback_f0) &
                (rms >= energy_floor) &
                (fallback_midi >= 40) &
                (fallback_midi <= 84)
            ]
        if len(valid) < 8:
            return jsonify({'error': 'We could not find enough sung notes. Try a clear low-to-high hum for a few seconds.'}), 422
        midi_values = librosa.hz_to_midi(valid)
        # Percentiles reject microphone pops and one-frame octave mistakes.
        low_midi = float(np.percentile(midi_values, 5))
        high_midi = float(np.percentile(midi_values, 95))
        if high_midi - low_midi < 1.5:
            return jsonify({'error': 'Sing a wider glide from your lowest comfortable note to your highest.'}), 422
        classification, artists, blend_with, primary_range = _classify_voice_range(low_midi, high_midi)
        return jsonify({
            'classification': classification,
            'primary_range': primary_range,
            'secondary_range': blend_with,
            'blend_with': blend_with,
            'low_midi': round(low_midi, 1),
            'high_midi': round(high_midi, 1),
            'low_note': _voice_note_name(low_midi),
            'high_note': _voice_note_name(high_midi),
            'artists': artists,
            'frame_count': int(len(valid)),
        })
    except Exception as error:
        print(f'[voice_range] Analysis failed: {error}')
        return jsonify({'error': 'Could not analyze this vocal recording.'}), 500
    finally:
        if os.path.exists(path):
            os.remove(path)


@app.route('/api/debug/files', methods=['GET'])
def debug_files():
    files = os.listdir(OUTPUT_FOLDER) if os.path.exists(OUTPUT_FOLDER) else []
    return jsonify({
        'output_folder': OUTPUT_FOLDER,
        'exists': os.path.exists(OUTPUT_FOLDER),
        'file_count': len(files),
        'files': sorted(files)
    })


@app.route('/api/sheet/generate', methods=['POST'])
def generate_sheet():
    if 'file' not in request.files:
        return jsonify({'error': 'No file provided'}), 400

    file = request.files['file']
    instrument_name = request.form.get('instrument', 'Piano')

    if file.filename == '':
        return jsonify({'error': 'No file selected'}), 400

    if not allowed_file(file.filename):
        return jsonify({'error': f'File type not allowed. Allowed: {", ".join(ALLOWED_EXTENSIONS)}'}), 400

    try:
        filename = secure_filename(file.filename)
        unique_id = str(uuid.uuid4())[:8]
        upload_path = os.path.join(UPLOAD_FOLDER, f'{unique_id}_{filename}')
        file.save(upload_path)
        extension = os.path.splitext(filename)[1].lower()
        pipeline_input_path = upload_path
        extracted_audio_path = None
        if extension in VIDEO_EXTENSIONS:
            extracted_audio_path = os.path.join(UPLOAD_FOLDER, f'{unique_id}_video_audio.wav')
            _extract_audio_from_video(upload_path, extracted_audio_path)
            pipeline_input_path = extracted_audio_path

        # Audio uploads use the full Demucs/Basic Pitch pipeline. Existing
        # MIDI and MusicXML uploads continue through the lightweight path below.
        if extension in {'.mp3', '.wav', '.m4a', '.flac', '.ogg'} or extension in VIDEO_EXTENSIONS:
            from transcribe_pipeline import build_pipeline
            mode = request.form.get('mode', 'solo').lower()
            config_text = request.form.get('instruments', '')
            if config_text:
                import json
                configs = json.loads(config_text)
            else:
                requested_role = request.form.get('role')
                # The normal upload flow produces one playable solo line.
                # Band mode can still explicitly request harmony/chord parts.
                default_role = 'melody'
                configs = [{'instrument': instrument_name, 'role': requested_role or default_role}]
            pipeline_dir = os.path.join(OUTPUT_FOLDER, unique_id)
            manifest = build_pipeline(
                pipeline_input_path,
                pipeline_dir,
                mode,
                configs,
                title=request.form.get('title'),
                artist=request.form.get('artist', 'Generated by Augment'),
                time_signature=request.form.get('time_signature'),
            )
            response_parts = []
            for part in manifest['parts']:
                target = os.path.join(OUTPUT_FOLDER, os.path.basename(part['musicxml']))
                shutil.copy2(part['musicxml'], target)
                target_name = os.path.basename(target)
                part_pdf_file, part_pdf_available = _prepare_pdf_artifact(target)
                response_parts.append({
                    **part,
                    'musicxml': target_name,
                    'output_file': target_name,
                    'pdf_file': part_pdf_file,
                    'pdf_available': part_pdf_available,
                })
            combined_file = None
            combined_pdf_file = None
            combined_pdf_available = False
            if manifest.get('combined_musicxml'):
                combined_target = os.path.join(OUTPUT_FOLDER, os.path.basename(manifest['combined_musicxml']))
                shutil.copy2(manifest['combined_musicxml'], combined_target)
                combined_file = os.path.basename(combined_target)
                combined_pdf_file = os.path.splitext(combined_file)[0] + '.pdf'
                combined_pdf_available = render_musicxml_to_pdf(
                    combined_target,
                    os.path.join(OUTPUT_FOLDER, combined_pdf_file),
                )
            string_part = next((part for part in response_parts if part.get('strumming_pattern')), None)
            primary_part = response_parts[0]
            primary_stats = primary_part.get('stats', {})
            lead_stats = primary_stats.get('isolated_lead', {})
            quality_score = lead_stats.get(
                'alignment_confidence', primary_stats.get('alignment_confidence'))
            quality = ('review' if quality_score is not None and quality_score < 0.45
                       else 'good' if quality_score is not None else 'unverified')
            audio_filename = f'{unique_id}_{"Band" if mode == "band" else primary_part["instrument"].replace(" ", "_")}.wav'
            audio_path = os.path.join(OUTPUT_FOLDER, audio_filename)
            audio_generated = False
            audio_duration = 0.0
            playback_events = []
            try:
                render_parts = []
                rendered_band_parts = []
                primary_notes = []
                for part in response_parts:
                    performance_midi = part.get('_performance_midi_path')
                    predicted_pedal = []
                    if performance_midi and os.path.isfile(performance_midi):
                        part_notes = _extract_performance_notes(
                            performance_midi, part['instrument'], manifest['tempo'],
                            preserve_piano_performance=bool(
                                part.get('_preserve_piano_performance')),
                            preserve_violin_performance=bool(
                                part.get('_preserve_violin_performance')),
                            preserve_band_performance=mode == 'band')
                        if part['instrument'] == 'Piano':
                            predicted_pedal = _extract_piano_pedal_events(performance_midi)
                    else:
                        # Older/interrupted jobs have no performance MIDI.
                        # Their engraved MusicXML remains a safe fallback.
                        part_score = converter.parse(
                            os.path.join(OUTPUT_FOLDER, part['output_file']))
                        part_notes = _extract_notes_data(
                            part_score, part['instrument'])
                    part['playback_events'] = part_notes
                    # Vocal contour is useful as a notation hint, but copying
                    # it to violin MIDI pitch bends makes the lead wander and
                    # can bend the following note on the same channel.
                    if part['instrument'] not in {'Violin', 'Electric Guitar'}:
                        _attach_playback_techniques(
                            part_notes,
                            part.get('techniques'),
                            manifest['tempo'],
                        )
                    render_part = _band_playback_part(
                        part['instrument'], part.get('role'), part_notes,
                        (None if (mode == 'band' or part['instrument'] in {'Electric Guitar', 'Flute', 'Saxophone'} or part.get('_preserve_piano_performance') or
                                  part.get('_preserve_violin_performance')) else
                         manifest.get('tempo_map')),
                        manifest['tempo'], predicted_pedal,
                    )
                    render_parts.append(render_part)
                    if mode == 'band':
                        render_part['is_band'] = True
                        safe_part_id = secure_filename(str(part.get('id') or part['instrument']))
                        part_audio_filename = f'{unique_id}_{safe_part_id}.wav'
                        part_audio_path = os.path.join(
                            OUTPUT_FOLDER, part_audio_filename)
                        part_audio_generated, part_audio_duration = _render_band_part_audio(
                            render_part,
                            part_audio_path,
                            manifest['tempo'],
                        )
                        part['playback_renderer'] = render_part.get('renderer_used')
                        rendered_band_parts.append({
                            'path': part_audio_path,
                            'role': part.get('role', 'harmony'),
                            'success': part_audio_generated,
                        })
                        part['audio_file'] = (
                            part_audio_filename if part_audio_generated else None)
                        part['audio_available'] = part_audio_generated
                        part['audio_duration'] = part_audio_duration
                    if part is primary_part:
                        primary_notes = part_notes
                playback_events = (
                    _combined_band_playback_events(
                        render_parts, manifest['tempo'])
                    if mode == 'band' else primary_notes
                )
                if mode == 'band':
                    audio_generated, audio_duration = _mix_band_part_audio(
                        rendered_band_parts, audio_path)
                    if not audio_generated:
                        print(
                            '[band_playback] Isolated part mix incomplete; '
                            'using the existing shared-SoundFont renderer.',
                            flush=True,
                        )
                        audio_generated, audio_duration = parts_to_wav(
                            render_parts,
                            audio_path,
                            tempo_bpm=manifest['tempo'],
                        )
                else:
                    violin_midi = primary_part.get('_performance_midi_path')
                    violin_plan = primary_part.get('_violin_performance_plan_path')
                    if (mode == 'solo' and primary_part['instrument'] == 'Violin'
                            and primary_part.get('_preserve_violin_performance')
                            and violin_midi and violin_plan):
                        (audio_generated, audio_duration,
                         primary_part['playback_renderer']) = (
                            _render_production_solo_violin(
                                violin_plan, violin_midi, audio_path))
                    else:
                        audio_generated, audio_duration = parts_to_wav(
                            render_parts, audio_path,
                            tempo_bpm=manifest['tempo'])
            except Exception as exc:
                print(f'[audio_pipeline] Playback render failed: {exc}')
            for part in response_parts:
                # The temporary path is for server rendering only.
                part.pop('_performance_midi_path', None)
                part.pop('_preserve_piano_performance', None)
                part.pop('_preserve_violin_performance', None)
                part.pop('_violin_performance_plan_path', None)
            os.remove(upload_path)
            if extracted_audio_path and os.path.exists(extracted_audio_path):
                os.remove(extracted_audio_path)
            return jsonify({
                'success': True, 'mode': mode, 'parts': response_parts,
                # Preserve the existing Flutter single-sheet response contract.
                'instrument': 'Band' if mode == 'band' else primary_part['instrument'],
                'output_file': combined_file if mode == 'band' and combined_file else primary_part['output_file'],
                'pdf_file': (combined_pdf_file if mode == 'band' and combined_file
                             else primary_part.get('pdf_file')),
                'pdf_available': (combined_pdf_available if mode == 'band' and combined_file
                                  else primary_part.get('pdf_available', False)),
                'total_notes': sum(part.get('stats', {}).get('notes', 0) for part in response_parts),
                'audio_file': audio_filename if audio_generated else None,
                'audio_available': audio_generated,
                'audio_duration': audio_duration,
                'playback_events': playback_events,
                'combined_musicxml': combined_file,
                'strumming_pattern': string_part.get('strumming_pattern') if string_part else None,
                'tempo': manifest['tempo'], 'key_signature': manifest['key'],
                'time_signature': manifest['time_signature'], 'warnings': manifest['warnings'],
                'tempo_map': manifest.get('tempo_map', []),
                'key_sections': manifest.get('key_sections', []),
                'chord_sections': manifest.get('chord_sections', []),
                'source_strategy': primary_part.get('source_strategy'),
                'source_stem': primary_part.get('source_stem'),
                'transcription_quality': quality,
                'alignment_confidence': quality_score,
                'message': f'{mode.title()} audio transcription complete'
            })

        score = converter.parse(upload_path)
        tempo_bpm, key_sig, time_sig = _detect_score_info(score)

        # MIDI uploads can contain chords but still import as one staff. Rebuild
        # Piano as a brace-connected treble/bass system while retaining every
        # timeline event; non-piano imports keep their established behavior.
        if instrument_name in ('Piano', 'Synthesizer', 'Organ'):
            from transcribe_pipeline import Grid, _piano_score_from_midi
            source_midi_path = os.path.join(UPLOAD_FOLDER, f'{unique_id}_source.mid')
            score.write('midi', fp=source_midi_path)
            detected_key = next(iter(score.recurse().getElementsByClass(key.Key)), None)
            grid = Grid(
                tempo_bpm, time_sig,
                detected_key.tonic.name if detected_key else key_sig,
                detected_key.mode if detected_key and detected_key.mode else 'major',
            )
            score = _piano_score_from_midi(source_midi_path, grid)
            if os.path.exists(source_midi_path):
                os.remove(source_midi_path)

        for part in score.parts:
            _remove_instruments_from_part(part)
            inst = INSTRUMENT_MAP.get(instrument_name, instrument.Piano())
            part.insert(0, inst)

        # Imported notation can contain pitches outside the selected
        # instrument's physical range. Apply the same final safety pass used
        # by generated scores before writing or rendering playback.
        from transcribe_pipeline import _fit_to_instrument
        _fit_to_instrument(score, instrument_name)

        existing_tempos = []
        for part in score.parts:
            flat = _safe_flatten(part)
            existing_tempos = list(flat.getElementsByClass(tempo.MetronomeMark))
            if existing_tempos:
                break
        if existing_tempos:
            existing_tempos[0].number = tempo_bpm
        else:
            score.insert(0, tempo.MetronomeMark(number=tempo_bpm))

        output_filename = f'{unique_id}_{instrument_name.replace(" ", "_")}.musicxml'
        output_path = os.path.join(OUTPUT_FOLDER, output_filename)
        write_ok = _safe_write_musicxml(score, output_path)
        if write_ok and instrument_name in _STRING_INSTRUMENTS:
            from transcribe_pipeline import add_tablature_markup
            add_tablature_markup(output_path, instrument_name)
        print(f'[generate_sheet] MusicXML write: ok={write_ok}, path={output_path}, exists={os.path.exists(output_path)}')

        if not write_ok or not os.path.exists(output_path):
            try:
                tmp_path = output_path + '.tmp'
                score.write('musicxml', fp=tmp_path)
                if os.path.exists(tmp_path):
                    os.replace(tmp_path, output_path)
                    write_ok = True
                    print(f'[generate_sheet] Fallback write succeeded: {output_path}')
            except Exception as e:
                print(f'[generate_sheet] Fallback write failed: {e}')

        name_prefix = f'{unique_id}_{instrument_name.replace(" ", "_")}'
        sheet_prefix = os.path.join(OUTPUT_FOLDER, f'{name_prefix}_sheet')
        render_musicxml_to_png(output_path, sheet_prefix)

        sheet_image_filename = f'{name_prefix}.png'
        sheet_pdf_filename = f'{name_prefix}.pdf'
        png_generated = False
        pdf_generated = False
        for src, dst in [
            (sheet_prefix + '.png', sheet_image_filename),
            (sheet_prefix + '-1.png', sheet_image_filename),
            (sheet_prefix + '.pdf', sheet_pdf_filename),
            (sheet_prefix + '-1.pdf', sheet_pdf_filename),
        ]:
            if os.path.exists(src):
                dst_path = os.path.join(OUTPUT_FOLDER, dst)
                if os.path.abspath(src) != os.path.abspath(dst_path):
                    os.rename(src, dst_path)
                if dst.endswith('.png'):
                    png_generated = True
                else:
                    pdf_generated = True

        system_images = render_system_images(output_path, sheet_prefix, unique_id)

        notes_data = _extract_notes_data(score, instrument_name)

        strumming_pattern = None
        tuning = None
        string_count = 0
        if instrument_name in _STRING_INSTRUMENTS:
            tuning = _INSTRUMENT_TUNINGS[instrument_name]
            string_count = len(tuning)
            strumming_pattern = _detect_strumming_pattern(notes_data, tempo_bpm, time_sig)

        audio_filename = f'{unique_id}_{instrument_name.replace(" ", "_")}.wav'
        audio_path = os.path.join(OUTPUT_FOLDER, audio_filename)
        audio_generated = False
        audio_duration = 0.0
        playback_events = []
        try:
            audio_generated, audio_duration, playback_events = score_to_wav(
                score, audio_path, fallback_instrument=instrument_name, default_bpm=tempo_bpm
            )
        except Exception:
            audio_generated = False
            audio_duration = 0.0

        os.remove(upload_path)

        musicxml_available = os.path.exists(output_path) and os.path.getsize(output_path) > 0
        print(f'[generate_sheet] musicxml_available={musicxml_available}, file={output_path}')

        response_data = {
            'success': True,
            'instrument': instrument_name,
            'output_file': output_filename,
            'musicxml_available': musicxml_available,
            'sheet_image': sheet_image_filename if png_generated else None,
            'sheet_image_available': png_generated,
            'system_images': system_images,
            'pdf_file': sheet_pdf_filename if pdf_generated else None,
            'pdf_available': pdf_generated,
            'audio_file': audio_filename if audio_generated else None,
            'audio_available': audio_generated,
            'audio_duration': audio_duration,
            'total_notes': len(notes_data),
            'playback_events': playback_events,
            'tempo': tempo_bpm,
            'key_signature': key_sig,
            'time_signature': time_sig,
            'message': f'Sheet music generated for {instrument_name}'
        }
        if tuning:
            response_data['tuning'] = tuning
            response_data['string_count'] = string_count
            response_data['strumming_pattern'] = strumming_pattern

        return jsonify(response_data)

    except ValueError as e:
        print(f'[generate_sheet] Invalid request: {e}')
        return jsonify({'error': str(e)}), 400
    except Exception as e:
        print(f'[generate_sheet] Generation failed: {e}')
        traceback.print_exc()
        return jsonify({'error': str(e)}), 500


def _harmonize_piano_bass(midi_data, audio_path):
    """Legacy compatibility hook; never rewrite detector pitches heuristically.

    A chroma/harmony guess cannot prove that an individually detected bass note
    is wrong.  The previous implementation changed correct notes in validation
    audio, so legacy conversion now preserves the detector's pitch events.
    """
    return midi_data


def _clean_piano_polyphony(midi_data):
    """Remove duplicate detector notes and limit noisy chord stacks."""
    notes = sorted(
        [note for inst in midi_data.instruments for note in inst.notes],
        key=lambda note: (note.start, note.pitch, -note.velocity),
    )
    merged = []
    latest_for_pitch = {}
    for source in notes:
        previous = latest_for_pitch.get(source.pitch)
        # Basic Pitch can estimate a long release for a short piano key press.
        # Only merge events that are effectively the *same* onset, never a
        # later same-pitch re-attack that merely overlaps that long release.
        if previous and abs(source.start - previous.start) <= .025:
            previous.end = max(previous.end, source.end)
            previous.velocity = max(previous.velocity, source.velocity)
            continue
        merged.append(source)
        latest_for_pitch[source.pitch] = source

    cleaned = []
    group = []
    for source in merged:
        if group and source.start - group[0].start > .055:
            lower = sorted((note for note in group if note.pitch < 60),
                           key=lambda note: (note.pitch, -note.velocity))[:2]
            upper = sorted((note for note in group if note.pitch >= 60),
                           key=lambda note: (-note.pitch, -note.velocity))[:4]
            cleaned.extend(lower + upper)
            group = []
        group.append(source)
    if group:
        lower = sorted((note for note in group if note.pitch < 60),
                       key=lambda note: (note.pitch, -note.velocity))[:2]
        upper = sorted((note for note in group if note.pitch >= 60),
                       key=lambda note: (-note.pitch, -note.velocity))[:4]
        cleaned.extend(lower + upper)

    piano = pretty_midi.Instrument(program=0, name='Piano')
    piano.notes = sorted(cleaned, key=lambda note: (note.start, note.pitch))
    midi_data.instruments = [piano]


def audio_to_midi(audio_path, output_midi_path, instrument_name='Piano'):
    try:
        from basic_pitch.inference import predict
        print("[audio_to_midi] Using Spotify Basic Pitch neural network for transcription...")
        
        # Run inference using the neural network
        _, midi_data, _ = predict(audio_path)
        
        # Determine polyphony/monophony (Only Piano, Synthesizer, and Organ are polyphonic)
        is_polyphonic = instrument_name in ['Piano', 'Synthesizer', 'Organ']
        
        # Define physical pitch ranges
        min_pitch, max_pitch = 0, 127
        if instrument_name in ['Bass Guitar', 'Cello']:
            min_pitch, max_pitch = 28, 60
        elif instrument_name in ['Violin', 'Flute']:
            min_pitch, max_pitch = 55, 100
        elif instrument_name in ['Guitar', 'Electric Guitar']:
            min_pitch, max_pitch = 40, 88
            
        # Adjust instrumentation and apply constraints
        for inst in midi_data.instruments:
            inst.is_drum = False
            inst.program = 0  # Acoustic Grand Piano
            
            # 1. Transpose out-of-range notes to keep them on staff
            for note in inst.notes:
                while note.pitch < min_pitch:
                    note.pitch += 12
                while note.pitch > max_pitch:
                    note.pitch -= 12
                    
            # 2. Filter to monophonic if instrument is monophonic
            if not is_polyphonic:
                sorted_notes = sorted(inst.notes, key=lambda x: x.start)
                monophonic_notes = []
                for note in sorted_notes:
                    if not monophonic_notes:
                        monophonic_notes.append(note)
                        continue
                    last_note = monophonic_notes[-1]
                    if note.start < last_note.end:
                        if note.velocity > last_note.velocity:
                            if note.start == last_note.start:
                                monophonic_notes[-1] = note
                            else:
                                last_note.end = note.start
                                monophonic_notes.append(note)
                        else:
                            if note.end > last_note.end:
                                note.start = last_note.end
                                monophonic_notes.append(note)
                    else:
                        monophonic_notes.append(note)
                inst.notes = monophonic_notes

        if is_polyphonic:
            _clean_piano_polyphony(midi_data)
            _harmonize_piano_bass(midi_data, audio_path)
            
        midi_data.write(output_midi_path)
        print("[audio_to_midi] Neural network transcription successful.")
        return output_midi_path
    except Exception as e:
        print(f"[audio_to_midi] Basic Pitch error: {e}. Falling back to DSP method...")
        
        y, sr = librosa.load(audio_path, sr=22050, mono=True)
        hop_length = 512

        is_polyphonic = instrument_name in ['Piano', 'Synthesizer', 'Organ']

        # Try to run pyin for monophonic pitch detection to get exact octaves and notes
        f0 = None
        if not is_polyphonic:
            try:
                print("[audio_to_midi] Running librosa.pyin for accurate monophonic pitch tracking...")
                if instrument_name in ['Bass Guitar', 'Cello']:
                    fmin = librosa.note_to_hz('E1')
                    fmax = librosa.note_to_hz('C4')
                elif instrument_name in ['Guitar', 'Electric Guitar', 'Ukulele']:
                    fmin = librosa.note_to_hz('E2')
                    fmax = librosa.note_to_hz('B5')
                else:
                    fmin = librosa.note_to_hz('G3')
                    fmax = librosa.note_to_hz('E7')  # Treble (Violin)
                
                f0, _, _ = librosa.pyin(
                    y,
                    fmin=fmin,
                    fmax=fmax,
                    sr=sr,
                    fill_na=None,
                    hop_length=hop_length
                )
            except Exception as pyin_err:
                print(f"[audio_to_midi] pYIN analysis failed: {pyin_err}")

        # Get chroma energy
        chroma = librosa.feature.chroma_cqt(y=y, sr=sr, hop_length=hop_length, n_octaves=6)
        times = librosa.frames_to_time(np.arange(chroma.shape[1]), sr=sr, hop_length=hop_length)

        # Detect note onsets to segment the audio
        onset_frames = librosa.onset.onset_detect(y=y, sr=sr, hop_length=hop_length, backtrack=True)
        onset_times = librosa.frames_to_time(onset_frames, sr=sr, hop_length=hop_length)
        
        # Pad boundaries
        if len(onset_times) == 0:
            onset_times = np.array([0.0])
        if onset_times[0] > 0.1:
            onset_times = np.concatenate(([0.0], onset_times))
        onset_times = np.concatenate((onset_times, [times[-1]]))
        
        midi = pretty_midi.PrettyMIDI()
        piano = pretty_midi.Instrument(name='Piano', program=0)
        midi.instruments.append(piano)

        # Place notes cleanly within onset-defined segments
        for idx in range(len(onset_times) - 1):
            start_t = onset_times[idx]
            end_t = onset_times[idx + 1]
            
            # Enforce a minimum note duration to keep sheet music readable
            if end_t - start_t < 0.15:
                continue
                
            start_frame = int(librosa.time_to_frames(start_t, sr=sr, hop_length=hop_length))
            end_frame = int(librosa.time_to_frames(end_t, sr=sr, hop_length=hop_length))
            if start_frame >= end_frame:
                continue
                
            segment_chroma = np.mean(chroma[:, start_frame:end_frame], axis=1)
            max_val = np.max(segment_chroma)
            
            # Noise / Rest filter
            if max_val < 0.35:
                continue
                
            if is_polyphonic:
                # Polyphonic: pick at most 2 notes above a threshold to avoid dense overlapping chords
                top_indices = np.argsort(segment_chroma)[-2:]
                for pitch_idx in top_indices:
                    if segment_chroma[pitch_idx] > 0.4:
                        # Map base octave appropriately for polyphonic fallback
                        base_midi = 60 if instrument_name not in ['Organ'] else 48
                        n = pretty_midi.Note(
                            velocity=80,
                            pitch=pitch_idx + base_midi,
                            start=start_t,
                            end=end_t
                        )
                        piano.notes.append(n)
            else:
                # Monophonic (Violin, etc.): attempt using pyin for exact octave & note mapping
                used_pyin = False
                if f0 is not None:
                    segment_f0 = f0[start_frame:end_frame]
                    # Filter out NaNs
                    voiced_segment = segment_f0[~np.isnan(segment_f0)]
                    
                    if len(voiced_segment) > 0 and len(voiced_segment) / (end_frame - start_frame) > 0.25:
                        median_f0 = np.median(voiced_segment)
                        midi_pitch = int(round(librosa.hz_to_midi(median_f0)))
                        n = pretty_midi.Note(
                            velocity=80,
                            pitch=midi_pitch,
                            start=start_t,
                            end=end_t
                        )
                        piano.notes.append(n)
                        used_pyin = True
                
                # Fallback to Chroma if pyin was unavailable or did not detect a voiced pitch
                if not used_pyin:
                    best_pitch_idx = np.argmax(segment_chroma)
                    if instrument_name in ['Bass Guitar', 'Cello']:
                        base_midi = 36  # C2
                    elif instrument_name in ['Guitar', 'Electric Guitar', 'Ukulele']:
                        base_midi = 48  # C3
                    else:
                        base_midi = 60  # C4
                        
                    n = pretty_midi.Note(
                        velocity=80,
                        pitch=best_pitch_idx + base_midi,
                        start=start_t,
                        end=end_t
                    )
                    piano.notes.append(n)

        if is_polyphonic:
            _clean_piano_polyphony(midi)
            _harmonize_piano_bass(midi, audio_path)
        midi.write(output_midi_path)
        return output_midi_path


def audio_to_solo_midi(audio_path, output_midi_path, instrument_name):
    """Select the most faithful isolated lead before engraving a solo part."""
    from transcribe_pipeline import run_demucs, transcribe_stem, validate_transcription
    work_dir = tempfile.mkdtemp(prefix='augment_solo_')
    try:
        stems_dir = run_demucs(audio_path, work_dir)
        candidates = []
        for stem_name, prefer_pyin in (('vocals', True), ('other', False)):
            stem_path = os.path.join(stems_dir, f'{stem_name}.wav')
            if not os.path.exists(stem_path):
                continue
            candidate_path = os.path.join(work_dir, f'{stem_name}_lead.mid')
            try:
                stats = transcribe_stem(
                    stem_path, candidate_path, polyphonic=False, prefer_pyin=prefer_pyin,
                )
                stats.update(validate_transcription(stem_path, candidate_path))
                candidates.append((stats.get('alignment_confidence') or 0.0, candidate_path, stats, stem_name))
            except (OSError, ValueError, RuntimeError) as exc:
                print(f'[solo] {stem_name} candidate rejected: {exc}')
        if not candidates:
            raise ValueError('No reliable vocal or lead-instrument stem was found.')
        # A small vocal preference avoids turning accompaniment into a violin
        # melody when both isolated candidates are similarly plausible.
        confidence, candidate_path, stats, stem_name = max(
            candidates,
            key=lambda candidate: candidate[0] + (0.08 if candidate[3] == 'vocals' else 0.0),
        )
        if instrument_name == 'Flute' and stem_name == 'vocals':
            from solo_flute_melody_accuracy import apply_flute_melody_accuracy
            selected = pretty_midi.PrettyMIDI(candidate_path)
            try:
                stats['flute_melody_accuracy'] = apply_flute_melody_accuracy(
                    selected, os.path.join(stems_dir, 'vocals.wav'),
                    candidate_path + '.detector.json')
                selected.write(candidate_path)
            except (OSError, ValueError, RuntimeError) as exc:
                stats['flute_melody_accuracy'] = {
                    'enabled': True, 'applied': False, 'warning': str(exc)}
        shutil.copy2(candidate_path, output_midi_path)
        stats['selected_stem'] = stem_name
        if confidence < 0.45:
            stats['warning'] = (
                'Low melody alignment: this score is a draft and should be reviewed before performing.'
            )
        return output_midi_path, stats
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)


@app.route('/api/sheet/generate-youtube', methods=['POST'])
def generate_from_youtube():
    data = request.get_json()
    if not data or not data.get('url'):
        return jsonify({'error': 'No YouTube URL provided'}), 400

    youtube_url = data['url']
    instrument_name = data.get('instrument', 'Piano')
    unique_id = str(uuid.uuid4())[:8]
    audio_path = None
    midi_path = None

    try:
        audio_path = os.path.join(UPLOAD_FOLDER, f'{unique_id}_audio.mp3')

        try:
            import yt_dlp
            ydl_opts = {
                'format': 'bestaudio/best',
                'postprocessors': [{
                    'key': 'FFmpegExtractAudio',
                    'preferredcodec': 'mp3',
                    'preferredquality': '192',
                }],
                'outtmpl': audio_path.replace('.mp3', '.%(ext)s'),
                'playlist_items': '1',
                'quiet': True,
                'no_warnings': True,
                'http_headers': {
                    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
                },
            }
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                ydl.download([youtube_url])
        except ImportError:
            result = subprocess.run([
                'python', '-m', 'yt_dlp', '-x', '--audio-format', 'mp3',
                '--playlist-items', '1',
                '--user-agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
                '-o', audio_path,
                youtube_url
            ], capture_output=True, timeout=600)
            if result.returncode != 0:
                error_msg = result.stderr.decode('utf-8', errors='replace') if result.stderr else 'Download failed'
                return jsonify({'error': f'YouTube download failed: {error_msg[:500]}'}), 500

        midi_path = os.path.join(UPLOAD_FOLDER, f'{unique_id}_converted.mid')
        actual_audio = audio_path
        if not os.path.exists(actual_audio):
            for f in os.listdir(UPLOAD_FOLDER):
                if f.startswith(f'{unique_id}_audio') and f.endswith(('.wav', '.mp3', '.m4a', '.ogg', '.opus', '.webm')):
                    actual_audio = os.path.join(UPLOAD_FOLDER, f)
                    break

        if not os.path.exists(actual_audio):
            return jsonify({'error': 'Failed to download audio from YouTube'}), 500

        requested_mode = str(data.get('mode', 'solo')).lower()
        if requested_mode in ('solo', 'band'):
            from transcribe_pipeline import build_pipeline
            configs = data.get('instruments') or []
            if isinstance(configs, str):
                configs = json.loads(configs)
            if requested_mode == 'solo':
                configs = [{'instrument': instrument_name, 'role': 'melody'}]
            pipeline_dir = os.path.join(OUTPUT_FOLDER, unique_id)
            manifest = build_pipeline(
                actual_audio,
                pipeline_dir,
                requested_mode,
                configs,
                title=data.get('title'),
                artist=data.get('artist', 'Generated by Augment'),
                time_signature=data.get('time_signature'),
            )
            response_parts = []
            render_parts = []
            rendered_band_parts = []
            for part_data in manifest['parts']:
                target = os.path.join(
                    OUTPUT_FOLDER, os.path.basename(part_data['musicxml']))
                shutil.copy2(part_data['musicxml'], target)
                part_pdf_file, part_pdf_available = _prepare_pdf_artifact(target)
                response_part = {
                    **part_data,
                    'musicxml': os.path.basename(target),
                    'output_file': os.path.basename(target),
                    'pdf_file': part_pdf_file,
                    'pdf_available': part_pdf_available,
                }
                response_parts.append(response_part)
                performance_midi = part_data.get('_performance_midi_path')
                if ((requested_mode == 'band' or part_data['instrument'] in {'Electric Guitar', 'Flute', 'Saxophone'} or part_data.get('_preserve_violin_performance')) and
                        performance_midi and os.path.isfile(performance_midi)):
                    part_notes = _extract_performance_notes(
                        performance_midi, part_data['instrument'],
                        manifest['tempo'],
                        preserve_violin_performance=bool(part_data.get('_preserve_violin_performance')),
                        preserve_band_performance=requested_mode == 'band')
                else:
                    part_score = converter.parse(target)
                    part_notes = _extract_notes_data(
                        part_score, part_data['instrument'])
                response_part['playback_events'] = part_notes
                render_part = _band_playback_part(
                    part_data['instrument'], part_data.get('role'), part_notes,
                    (None if requested_mode == 'band' or part_data['instrument'] in {'Electric Guitar', 'Flute', 'Saxophone'} or part_data.get('_preserve_violin_performance') else
                     manifest.get('tempo_map')), manifest['tempo'],
                )
                render_parts.append(render_part)
                render_part['is_band'] = requested_mode == 'band'
                safe_part_id = secure_filename(str(
                    part_data.get('id') or part_data['instrument']))
                part_audio_filename = f'{unique_id}_{safe_part_id}.wav'
                part_audio_generated, part_audio_duration = _render_band_part_audio(
                    render_part,
                    os.path.join(OUTPUT_FOLDER, part_audio_filename),
                    manifest['tempo'],
                )
                rendered_band_parts.append({
                    'path': os.path.join(OUTPUT_FOLDER, part_audio_filename),
                    'role': part_data.get('role', 'harmony'),
                    'success': part_audio_generated,
                })
                response_part['playback_renderer'] = render_part.get('renderer_used')
                response_part['audio_file'] = (
                    part_audio_filename if part_audio_generated else None)
                response_part['audio_available'] = part_audio_generated
                response_part['audio_duration'] = part_audio_duration
            combined_target = None
            combined_pdf_file = None
            combined_pdf_available = False
            if manifest.get('combined_musicxml'):
                combined_target = os.path.join(
                    OUTPUT_FOLDER,
                    os.path.basename(manifest['combined_musicxml']),
                )
                shutil.copy2(manifest['combined_musicxml'], combined_target)
                combined_pdf_file = (
                    os.path.splitext(os.path.basename(combined_target))[0] + '.pdf')
                combined_pdf_available = render_musicxml_to_pdf(
                    combined_target,
                    os.path.join(OUTPUT_FOLDER, combined_pdf_file),
                )
            audio_filename = f'{unique_id}_{"Band" if requested_mode == "band" else instrument_name}.wav'
            audio_path = os.path.join(OUTPUT_FOLDER, audio_filename)
            if requested_mode == 'band':
                audio_generated, audio_duration = _mix_band_part_audio(
                    rendered_band_parts, audio_path)
                if not audio_generated:
                    audio_generated, audio_duration = parts_to_wav(
                        render_parts, audio_path, tempo_bpm=manifest['tempo'])
            else:
                violin_midi = response_parts[0].get('_performance_midi_path')
                violin_plan = response_parts[0].get('_violin_performance_plan_path')
                if (instrument_name == 'Violin' and
                        response_parts[0].get('_preserve_violin_performance') and
                        violin_midi and violin_plan):
                    (audio_generated, audio_duration,
                     response_parts[0]['playback_renderer']) = (
                        _render_production_solo_violin(
                            violin_plan, violin_midi, audio_path))
                else:
                    audio_generated, audio_duration = parts_to_wav(
                        render_parts, audio_path, tempo_bpm=manifest['tempo'])
            for response_part in response_parts:
                response_part.pop('_performance_midi_path', None)
                response_part.pop('_preserve_piano_performance', None)
                response_part.pop('_preserve_violin_performance', None)
                response_part.pop('_violin_performance_plan_path', None)
            primary = response_parts[0]
            return jsonify({
                'success': True,
                'mode': requested_mode,
                'instrument': 'Band' if requested_mode == 'band' else instrument_name,
                'parts': response_parts,
                'combined_musicxml': (
                    os.path.basename(combined_target) if combined_target else None),
                'output_file': (
                    os.path.basename(combined_target)
                    if combined_target else primary['output_file']),
                'pdf_file': (combined_pdf_file if combined_target
                             else primary.get('pdf_file')),
                'pdf_available': (combined_pdf_available if combined_target
                                  else primary.get('pdf_available', False)),
                'total_notes': sum(
                    part.get('stats', {}).get('notes', 0)
                    for part in response_parts),
                'audio_file': audio_filename if audio_generated else None,
                'audio_available': audio_generated,
                'audio_duration': audio_duration,
                'playback_events': (
                    _combined_band_playback_events(
                        render_parts, manifest['tempo'])
                    if requested_mode == 'band'
                    else render_parts[0]['notes']
                ),
                'tempo': manifest['tempo'],
                'key_signature': manifest['key'],
                'time_signature': manifest['time_signature'],
                'tempo_map': manifest.get('tempo_map', []),
                'key_sections': manifest.get('key_sections', []),
                'chord_sections': manifest.get('chord_sections', []),
                'warnings': manifest['warnings'],
                'transcription_quality': (
                    'review' if any(
                        part.get('source_strategy') == 'uncertain'
                        for part in response_parts) else 'good'),
                'message': f'{requested_mode.title()} audio transcription complete',
            })

        # Piano is an arrangement, not a single lead: retain the full mix so
        # simultaneous melody, harmony and bass can be written across a grand staff.
        if instrument_name in ('Piano', 'Synthesizer', 'Organ'):
            midi_path = audio_to_midi(actual_audio, midi_path, instrument_name)
            transcription_stats = {'mode': 'polyphonic piano arrangement'}
        else:
            # A violin/flute/etc. needs one isolated lead line, not a direct
            # transcription of the whole song mix.
            midi_path, transcription_stats = audio_to_solo_midi(actual_audio, midi_path, instrument_name)

        from transcribe_pipeline import (
            analyze_grid, _add_musicxml_credits, _add_phrase_slurs,
            _add_score_formatting, _add_violin_double_stops, _piano_score_from_midi,
            _solo_score_from_midi, _fit_to_instrument,
        )
        shared_grid = analyze_grid(actual_audio)
        if data.get('time_signature'):
            shared_grid.time_signature = meter.TimeSignature(
                str(data['time_signature'])).ratioString
        is_piano = instrument_name in ('Piano', 'Synthesizer', 'Organ')
        score = (_piano_score_from_midi(midi_path, shared_grid) if is_piano
                 else _solo_score_from_midi(midi_path, instrument_name, shared_grid))

        for part in score.parts:
            if not is_piano:
                _remove_instruments_from_part(part)
                inst = INSTRUMENT_MAP.get(instrument_name, instrument.Piano())
                part.insert(0, inst)
                part.insert(0, tempo.MetronomeMark(number=shared_grid.bpm))
                part.insert(0, meter.TimeSignature(shared_grid.time_signature))
                try:
                    part.insert(0, key.Key(shared_grid.key_name, shared_grid.key_mode))
                except Exception:
                    pass
                if instrument_name == 'Violin':
                    _add_violin_double_stops(part, shared_grid)

        _fit_to_instrument(score, instrument_name)

        tempo_bpm = shared_grid.bpm
        key_sig = shared_grid.display_key
        time_sig = shared_grid.time_signature
        # Create complete measures before exporting or calculating playback.
        if is_piano:
            for piano_staff in score.parts:
                piano_staff.makeMeasures(inPlace=True)
        score.makeNotation(inPlace=True)
        for formatted_part in score.parts:
            if not is_piano:
                _add_phrase_slurs(formatted_part)
            _add_score_formatting(
                score,
                formatted_part,
                data.get('title', 'YouTube Solo Transcription'),
                data.get('artist', 'Generated by Augment'),
                shared_grid,
            )

        existing_tempos = []
        for part in score.parts:
            flat = _safe_flatten(part)
            existing_tempos = list(flat.getElementsByClass(tempo.MetronomeMark))
            if existing_tempos:
                break
        if existing_tempos:
            existing_tempos[0].number = tempo_bpm
        else:
            score.insert(0, tempo.MetronomeMark(number=tempo_bpm))

        output_filename = f'{unique_id}_{instrument_name.replace(" ", "_")}.musicxml'
        output_path = os.path.join(OUTPUT_FOLDER, output_filename)
        write_ok = _safe_write_musicxml(score, output_path)
        print(f'[generate_from_youtube] MusicXML write: ok={write_ok}, path={output_path}, exists={os.path.exists(output_path)}')

        if not write_ok or not os.path.exists(output_path):
            try:
                tmp_path = output_path + '.tmp'
                score.write('musicxml', fp=tmp_path)
                if os.path.exists(tmp_path):
                    os.replace(tmp_path, output_path)
                    write_ok = True
                    print(f'[generate_from_youtube] Fallback write succeeded: {output_path}')
            except Exception as e:
                print(f'[generate_from_youtube] Fallback write failed: {e}')
        if write_ok and os.path.exists(output_path):
            if instrument_name in _STRING_INSTRUMENTS:
                from transcribe_pipeline import add_tablature_markup
                add_tablature_markup(output_path, instrument_name)
            _add_musicxml_credits(
                output_path,
                title=data.get('title', 'YouTube Solo Transcription'),
                artist=data.get('artist', 'Generated by Augment'),
            )

        name_prefix = f'{unique_id}_{instrument_name.replace(" ", "_")}'
        sheet_prefix = os.path.join(OUTPUT_FOLDER, f'{name_prefix}_sheet')
        render_musicxml_to_png(output_path, sheet_prefix)

        sheet_image_filename = f'{name_prefix}.png'
        sheet_pdf_filename = f'{name_prefix}.pdf'
        png_generated = False
        pdf_generated = False
        for src, dst in [
            (sheet_prefix + '.png', sheet_image_filename),
            (sheet_prefix + '-1.png', sheet_image_filename),
            (sheet_prefix + '.pdf', sheet_pdf_filename),
            (sheet_prefix + '-1.pdf', sheet_pdf_filename),
        ]:
            if os.path.exists(src):
                dst_path = os.path.join(OUTPUT_FOLDER, dst)
                if os.path.abspath(src) != os.path.abspath(dst_path):
                    os.rename(src, dst_path)
                if dst.endswith('.png'):
                    png_generated = True
                else:
                    pdf_generated = True

        system_images = render_system_images(output_path, sheet_prefix, unique_id)

        notes_data = _extract_notes_data(score, instrument_name)

        strumming_pattern = None
        tuning = None
        string_count = 0
        if instrument_name in _STRING_INSTRUMENTS:
            tuning = _INSTRUMENT_TUNINGS[instrument_name]
            string_count = len(tuning)
            strumming_pattern = _detect_strumming_pattern(notes_data, tempo_bpm, time_sig)

        audio_filename = f'{unique_id}_{instrument_name.replace(" ", "_")}.wav'
        audio_out_path = os.path.join(OUTPUT_FOLDER, audio_filename)
        audio_generated = False
        audio_duration = 0.0
        playback_events = []
        try:
            audio_generated, audio_duration, playback_events = score_to_wav(
                score, audio_out_path, fallback_instrument=instrument_name, default_bpm=tempo_bpm
            )
        except Exception:
            audio_generated = False
            audio_duration = 0.0

        for f in [actual_audio, midi_path]:
            if os.path.exists(f):
                os.remove(f)

        musicxml_available = os.path.exists(output_path) and os.path.getsize(output_path) > 0
        print(f'[generate_from_youtube] musicxml_available={musicxml_available}, file={output_path}')

        response_data = {
            'success': True,
            'instrument': instrument_name,
            'source': 'youtube',
            'output_file': output_filename,
            'musicxml_available': musicxml_available,
            'sheet_image': sheet_image_filename if png_generated else None,
            'sheet_image_available': png_generated,
            'system_images': system_images,
            'pdf_file': sheet_pdf_filename if pdf_generated else None,
            'pdf_available': pdf_generated,
            'audio_file': audio_filename if audio_generated else None,
            'audio_available': audio_generated,
            'audio_duration': audio_duration,
            'total_notes': len(notes_data),
            'playback_events': playback_events,
            'tempo': tempo_bpm,
            'transcription': transcription_stats,
            'warnings': [transcription_stats['warning']] if transcription_stats.get('warning') else [],
            'key_signature': key_sig,
            'time_signature': time_sig,
            'message': f'Sheet music generated from YouTube for {instrument_name}'
        }
        if tuning:
            response_data['tuning'] = tuning
            response_data['string_count'] = string_count
            response_data['strumming_pattern'] = strumming_pattern

        return jsonify(response_data)

    except ValueError as e:
        for f in [audio_path, midi_path]:
            if f and os.path.exists(f):
                os.remove(f)
        return jsonify({'error': str(e)}), 400
    except Exception as e:
        for f in [audio_path, midi_path]:
            if f and os.path.exists(f):
                os.remove(f)
        return jsonify({'error': str(e)}), 500


@app.route('/api/sheet/download/<filename>', methods=['GET'])
def download_sheet(filename):
    try:
        file_path = os.path.join(OUTPUT_FOLDER, filename)
        # Build a PDF on demand for older jobs that only rendered MusicXML.
        if not os.path.exists(file_path) and filename.lower().endswith('.pdf'):
            xml_path = os.path.join(
                OUTPUT_FOLDER, os.path.splitext(filename)[0] + '.musicxml'
            )
            if os.path.exists(xml_path):
                render_musicxml_to_pdf(xml_path, file_path)
        print(f'[download] filename={filename}, file_path={file_path}, exists={os.path.exists(file_path)}')
        if os.path.exists(file_path):
            ext = os.path.splitext(filename)[1].lower()
            mime_map = {
                '.wav': 'audio/wav',
                '.mp3': 'audio/mpeg',
                '.png': 'image/png',
                '.pdf': 'application/pdf',
                '.musicxml': 'application/xml',
                '.xml': 'application/xml',
            }
            mimetype = mime_map.get(ext, 'application/octet-stream')
            return send_file(
                file_path,
                mimetype=mimetype,
                as_attachment=True,
                download_name=secure_filename(filename),
            )
        print(f'[download] File NOT found: {file_path}')
        print(f'[download] OUTPUT_FOLDER contents: {os.listdir(OUTPUT_FOLDER)}')
        return jsonify({'error': 'File not found'}), 404
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/sheet/render-edited', methods=['POST'])
def render_edited_sheet():
    """Render user-edited MusicXML without re-running transcription.

    Editing a note in the studio changes the written score first.  This route
    then builds a fresh playback WAV from that exact MusicXML, so notation and
    sound cannot drift apart.
    """
    try:
        payload = request.get_json(silent=True) or {}
        musicxml_content = payload.get('musicxml_content')
        if not isinstance(musicxml_content, str) or len(musicxml_content) < 100:
            return jsonify({'error': 'Edited MusicXML is required.'}), 400
        if len(musicxml_content.encode('utf-8')) > 3_000_000:
            return jsonify({'error': 'Edited MusicXML is too large.'}), 413

        instrument_name = str(payload.get('instrument') or 'Piano')
        if instrument_name not in INSTRUMENT_MAP:
            instrument_name = 'Piano'
        requested_name = secure_filename(str(payload.get('output_file') or ''))
        if not requested_name.lower().endswith(('.musicxml', '.xml')):
            requested_name = f'edited_{uuid.uuid4().hex[:10]}.musicxml'
        output_path = os.path.join(OUTPUT_FOLDER, requested_name)

        score = converter.parseData(musicxml_content, format='musicxml')
        tempo_bpm, key_sig, time_sig = _detect_score_info(score)
        with open(output_path, 'w', encoding='utf-8', newline='') as edited_file:
            edited_file.write(musicxml_content)

        stem = os.path.splitext(requested_name)[0]
        audio_filename = f'{stem}_edited.wav'
        audio_path = os.path.join(OUTPUT_FOLDER, audio_filename)
        audio_generated, audio_duration, playback_events = score_to_wav(
            score,
            audio_path,
            fallback_instrument=instrument_name,
            default_bpm=tempo_bpm,
        )
        notes_data = _extract_notes_data(score, instrument_name)
        sheet_prefix = os.path.join(OUTPUT_FOLDER, f'{stem}_edited_sheet')
        sheet_image_path, png_generated = render_musicxml_to_png(
            output_path, sheet_prefix)
        sheet_image_filename = (os.path.basename(sheet_image_path)
                                if png_generated and sheet_image_path else None)
        sheet_pdf_path = sheet_prefix + '.pdf'
        pdf_generated = os.path.isfile(sheet_pdf_path)
        sheet_pdf_filename = (os.path.basename(sheet_pdf_path)
                              if pdf_generated else None)
        return jsonify({
            'success': True,
            'instrument': instrument_name,
            'output_file': requested_name,
            'musicxml_available': True,
            'audio_file': audio_filename if audio_generated else None,
            'audio_available': audio_generated,
            'audio_duration': audio_duration,
            'playback_events': playback_events,
            'total_notes': len(notes_data),
            'tempo': tempo_bpm,
            'key_signature': key_sig,
            'time_signature': time_sig,
            'sheet_image': sheet_image_filename if png_generated else None,
            'sheet_image_available': png_generated,
            'pdf_file': sheet_pdf_filename if pdf_generated else None,
            'pdf_available': pdf_generated,
        })
    except Exception as exc:
        print(f'[render_edited_sheet] Failed: {exc}')
        traceback.print_exc()
        return jsonify({'error': 'Could not render the edited sheet.'}), 400


@app.route('/api/sheet/preview-note', methods=['POST'])
def preview_edited_note():
    """Return one edited note rendered with Augment's normal SoundFont path."""
    temp_path = None
    try:
        payload = request.get_json(silent=True) or {}
        pitch_name = str(payload.get('pitch') or '').strip()
        instrument_name = str(payload.get('instrument') or 'Piano')
        if instrument_name not in INSTRUMENT_MAP:
            instrument_name = 'Piano'
        parsed_pitch = music21.pitch.Pitch(pitch_name)
        if parsed_pitch.midi < 0 or parsed_pitch.midi > 127:
            raise ValueError('Pitch is outside the MIDI range.')
        duration = float(payload.get('duration') or 0.70)
        duration = min(1.8, max(0.18, duration))
        descriptor, temp_path = tempfile.mkstemp(
            prefix='augment_note_preview_', suffix='.wav', dir=OUTPUT_FOLDER)
        os.close(descriptor)
        generated, _ = parts_to_wav(
            [{
                'instrument': instrument_name,
                'role': 'melody',
                'notes': [{
                    'pitches': [parsed_pitch.nameWithOctave],
                    'offset': 0.0,
                    'duration': duration * 2,
                    'velocity': 88,
                    'arrangement_role': 'melody',
                }],
            }],
            temp_path,
            sample_rate=44100,
            tempo_bpm=120,
        )
        if not generated or not os.path.isfile(temp_path):
            raise RuntimeError('The note preview could not be rendered.')
        with open(temp_path, 'rb') as preview_file:
            audio_bytes = preview_file.read()
        return send_file(
            io.BytesIO(audio_bytes),
            mimetype='audio/wav',
            download_name='note-preview.wav',
        )
    except Exception as exc:
        print(f'[preview_edited_note] Failed: {exc}')
        return jsonify({'error': 'Could not render note preview.'}), 400
    finally:
        if temp_path and os.path.isfile(temp_path):
            try:
                os.remove(temp_path)
            except OSError:
                pass


@app.route('/api/sheet/preview/<filename>', methods=['GET'])
def preview_sheet(filename):
    try:
        file_path = os.path.join(OUTPUT_FOLDER, secure_filename(filename))
        if os.path.exists(file_path):
            return send_file(file_path, mimetype='application/xml')
        return jsonify({'error': 'File not found'}), 404
    except Exception as e:
        return jsonify({'error': str(e)}), 500


if __name__ == '__main__':
    # The reloader scans ML modules and can trigger optional-import failures.
    # Keep health and job-status requests responsive while a long model task
    # is running for another request.
    app.run(debug=False, host='0.0.0.0', port=5000, threaded=True)
