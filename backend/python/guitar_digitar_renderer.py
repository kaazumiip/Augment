"""Experimental physical Guitar renderer for Augment canonical events.

This is intentionally a renderer, not an arranger.  It follows the
Karplus--Strong plucked-string model demonstrated in Real Python's Digitar
tutorial, but receives Augment's already chosen string, fret, timing, stroke
and ringing decisions.  Therefore the rendered sound cannot change the TAB.
"""

from __future__ import annotations

import hashlib
from pathlib import Path

import numpy as np
from scipy.io import wavfile


STANDARD_TUNING = (40, 45, 50, 55, 59, 64)  # Guitar strings 6 through 1


def _midi_hz(midi):
    return 440.0 * (2.0 ** ((int(midi) - 69) / 12.0))


def _event_seed(event):
    value = f"{event['string']}:{event['fret']}:{event['start']:.6f}:{event['action']}"
    return int(hashlib.sha256(value.encode('utf-8')).hexdigest()[:8], 16)


def _karplus_strong(frequency, seconds, velocity, sample_rate, seed, action):
    """Generate one deterministic, damped vibrating-string waveform."""
    length = max(1, int(seconds * sample_rate))
    delay = max(2, int(sample_rate / max(20.0, frequency)))
    rng = np.random.default_rng(seed)
    # A stroke has a slightly softer, broader excitation than a finger pluck.
    excitation = rng.uniform(-1.0, 1.0, delay)
    if action == 'strum':
        excitation = np.convolve(excitation, np.ones(3) / 3, mode='same')
    elif action == 'pinch':
        excitation *= 1.08
    damping = 0.994 if frequency < 150 else 0.991
    buffer = excitation.copy()
    output = np.empty(length, dtype=np.float32)
    cursor = 0
    for index in range(length):
        current = buffer[cursor]
        next_cursor = (cursor + 1) % delay
        # Karplus--Strong feedback low-pass: neighbouring samples blend and
        # decay, which removes high frequencies naturally over time.
        buffer[cursor] = damping * .5 * (buffer[cursor] + buffer[next_cursor])
        output[index] = current
        cursor = next_cursor
    attack = min(length, max(8, int(sample_rate * .006)))
    output[:attack] *= np.linspace(.25, 1.0, attack, dtype=np.float32)
    release = min(length, max(16, int(sample_rate * .025)))
    output[-release:] *= np.linspace(1.0, .08, release, dtype=np.float32)
    return output * (max(1, min(127, int(velocity))) / 127.0)


def validate_event_pitch(event):
    string, fret = int(event['string']), int(event['fret'])
    if not 1 <= string <= 6:
        raise ValueError(f"invalid Guitar string: {string}")
    if fret < 0 or fret > 24:
        raise ValueError(f"invalid Guitar fret: {fret}")
    expected = STANDARD_TUNING[6 - string] + fret
    if int(event['pitch']) != expected:
        raise ValueError(
            f"canonical event pitch {event['pitch']} conflicts with "
            f"string {string} fret {fret} ({expected})"
        )


def render_digitar_events(events, output_path, sample_rate=44100):
    """Render canonical Guitar events using independent physical strings.

    Event duration/ring_until determines how long that individual string
    rings.  Later events on other strings are simply mixed in; they never
    globally silence the Guitar.
    """
    events = sorted(events, key=lambda event: (event['start'], event['string']))
    if not events:
        raise ValueError('cannot render an empty Guitar performance')
    for event in events:
        validate_event_pitch(event)
    end_time = max(float(event.get('ring_until', event['end'])) for event in events)
    mix = np.zeros(int((end_time + .12) * sample_rate) + 1, dtype=np.float32)
    for event in events:
        start = max(0, int(round(float(event['start']) * sample_rate)))
        ring_end = max(float(event['end']), float(event.get('ring_until', event['end'])))
        duration = max(.045, ring_end - float(event['start']))
        frequency = _midi_hz(STANDARD_TUNING[6 - int(event['string'])] + int(event['fret']))
        wave = _karplus_strong(
            frequency, duration, event['velocity'], sample_rate,
            _event_seed(event), event.get('action', 'pluck'),
        )
        stop = min(len(mix), start + len(wave))
        mix[start:stop] += wave[:stop - start]
    peak = float(np.max(np.abs(mix))) or 1.0
    # A conservative ceiling prevents clipping while leaving relative melody,
    # chord, bass and inner velocities untouched.
    pcm = np.int16(np.clip(mix / peak * .88, -1.0, 1.0) * 32767)
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    wavfile.write(output_path, sample_rate, pcm)
    return {
        'renderer': 'augmented_karplus_strong_digitar',
        'sample_rate': sample_rate,
        'events_rendered': len(events),
        'duration_seconds': round(len(mix) / sample_rate, 3),
        'output_path': str(output_path),
    }
