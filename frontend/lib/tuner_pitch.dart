import 'dart:math' as math;

class ChromaticPitch {
  const ChromaticPitch({
    required this.midi,
    required this.frequency,
    required this.cents,
  });

  final int midi;
  final double frequency;
  final double cents;
}

/// Publishes a pitch only after several close, consecutive measurements.
/// This filters short noises and unstable microphone estimates before they can
/// move a tuner needle.
class StablePitchGate {
  StablePitchGate({this.requiredReadings = 4, this.maxSpreadCents = 32});

  final int requiredReadings;
  final double maxSpreadCents;
  final List<double> _readings = [];

  double? add(double hz) {
    if (!hz.isFinite || hz <= 0) {
      reset();
      return null;
    }
    _readings.add(hz);
    while (_readings.length > requiredReadings) {
      _readings.removeAt(0);
    }
    if (_readings.length < requiredReadings) return null;

    final sorted = [..._readings]..sort();
    final median =
        (sorted[requiredReadings ~/ 2] + sorted[(requiredReadings - 1) ~/ 2]) /
            2;
    final stable = _readings.every((value) {
      final cents = 1200 * math.log(value / median) / math.ln2;
      return cents.abs() <= maxSpreadCents;
    });
    return stable ? median : null;
  }

  void reset() => _readings.clear();
}

ChromaticPitch? chromaticPitchFor(
  double hz, {
  required int minMidi,
  required int maxMidi,
}) {
  if (!hz.isFinite || hz <= 0 || minMidi > maxMidi) return null;
  final midi = (69 + 12 * math.log(hz / 440) / math.ln2).round();
  if (midi < minMidi || midi > maxMidi) return null;
  final target = midiFrequency(midi);
  return ChromaticPitch(
    midi: midi,
    frequency: target,
    cents: 1200 * math.log(hz / target) / math.ln2,
  );
}

double midiFrequency(int midi) =>
    440 * math.pow(2, (midi - 69) / 12).toDouble();

String midiNoteName(
  int midi, {
  bool preferFlats = false,
  int transpositionSemitones = 0,
}) {
  const sharps = [
    'C',
    'C#',
    'D',
    'D#',
    'E',
    'F',
    'F#',
    'G',
    'G#',
    'A',
    'A#',
    'B',
  ];
  const flats = [
    'C',
    'Db',
    'D',
    'Eb',
    'E',
    'F',
    'Gb',
    'G',
    'Ab',
    'A',
    'Bb',
    'B',
  ];
  final shifted = midi + transpositionSemitones;
  final pitchClass = ((shifted % 12) + 12) % 12;
  final octave = shifted ~/ 12 - 1;
  return '${(preferFlats ? flats : sharps)[pitchClass]}$octave';
}
