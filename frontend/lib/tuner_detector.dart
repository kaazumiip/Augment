import 'dart:math' as math;
import 'dart:typed_data';

/// One mono PCM window, with the actual capture rate (not an assumed rate).
class PitchWindow {
  const PitchWindow(this.samples, this.sampleRate);
  final Float64List samples;
  final int sampleRate;
}

/// YIN with a constant comparison window and sub-sample lag interpolation.
/// Returns null for silence, noise or pitches outside 35–2200 Hz.
double? detectTunerFrequency(PitchWindow window) {
  final input = window.samples;
  if (window.sampleRate < 8000 || input.length < 512) return null;
  final stride = math.max(1, window.sampleRate ~/ 22050);
  final size = input.length ~/ stride;
  final rate = window.sampleRate / stride;
  final values = Float64List(size);
  var mean = 0.0;
  for (var i = 0; i < size; i++) {
    // Average before decimating to reduce high-frequency aliasing.
    var sample = 0.0;
    for (var j = 0; j < stride; j++) {
      sample += input[i * stride + j];
    }
    values[i] = sample / stride;
    mean += values[i];
  }
  mean /= size;
  var energy = 0.0;
  for (var i = 0; i < size; i++) {
    values[i] -= mean;
    energy += values[i] * values[i];
  }
  // Reject the room-noise floor before looking for a stable periodic signal.
  if (!energy.isFinite || energy / size < 0.00025) return null;
  final minLag = math.max(2, (rate / 2200).floor());
  final maxLag = math.min(size ~/ 2, (rate / 35).ceil());
  if (maxLag <= minLag) return null;
  final comparisonSize = size - maxLag;
  final normalized = Float64List(maxLag + 1)..[0] = 1;
  var runningTotal = 0.0;
  for (var lag = 1; lag <= maxLag; lag++) {
    var sum = 0.0;
    for (var i = 0; i < comparisonSize; i++) {
      final delta = values[i] - values[i + lag];
      sum += delta * delta;
    }
    runningTotal += sum;
    normalized[lag] = runningTotal > 0 ? sum * lag / runningTotal : 1;
  }
  var bestLag = -1;
  for (var lag = minLag; lag < maxLag; lag++) {
    if (normalized[lag] < .16) {
      while (lag < maxLag && normalized[lag + 1] < normalized[lag]) {
        lag++;
      }
      bestLag = lag;
      break;
    }
  }
  if (bestLag < 0) return null;
  if (normalized[bestLag] > 0.17) return null;
  var refined = bestLag.toDouble();
  if (bestLag > minLag && bestLag < maxLag) {
    final left = normalized[bestLag - 1];
    final center = normalized[bestLag];
    final right = normalized[bestLag + 1];
    final denominator = left - 2 * center + right;
    if (denominator.abs() > 1e-9) {
      refined += (.5 * (left - right) / denominator).clamp(-1.0, 1.0);
    }
  }
  final hz = rate / refined;
  return hz >= 35 && hz <= 2200 ? hz : null;
}

/// Handles arbitrary byte/chunk boundaries, interleaved channels and rate changes.
class TunerPcmDecoder {
  TunerPcmDecoder({this.sampleRate = 44100, this.channels = 1});
  final int sampleRate;
  final int channels;
  final List<int> _pending = [];

  List<PitchWindow> add(Uint8List bytes) {
    if (channels < 1 || sampleRate < 8000) return const [];
    _pending.addAll(bytes);
    var sampleCount = 1024;
    while (sampleCount < sampleRate * .085) {
      sampleCount *= 2;
    }
    final windowBytes = sampleCount * channels * 2;
    final windows = <PitchWindow>[];
    var offset = 0;
    while (_pending.length - offset >= windowBytes) {
      final samples = Float64List(sampleCount);
      for (var i = 0; i < sampleCount; i++) {
        var mixed = 0.0;
        for (var channel = 0; channel < channels; channel++) {
          final index = offset + (i * channels + channel) * 2;
          final value = _pending[index] | (_pending[index + 1] << 8);
          mixed += (value >= 32768 ? value - 65536 : value) / 32768;
        }
        samples[i] = mixed / channels;
      }
      windows.add(PitchWindow(samples, sampleRate));
      offset += windowBytes;
    }
    if (offset > 0) _pending.removeRange(0, offset);
    return windows;
  }
}
