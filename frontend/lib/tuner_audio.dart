import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

import 'tuner_detector.dart';

abstract class TunerAudioSource {
  Stream<double?> get pitches;
  Future<void> start();
  Future<void> stop();
  Future<void> dispose();
}

class TunerAudioException implements Exception {
  const TunerAudioException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One recorder per page. Operations are serialized and cancelled starts cannot
/// publish audio after a pause, navigation or a newer recording session.
class MicrophoneTunerAudio implements TunerAudioSource {
  final _pitches = StreamController<double?>.broadcast();
  AudioRecorder? _recorder;
  StreamSubscription<dynamic>? _audio;
  StreamSubscription<RecordState>? _state;
  Future<void> _operations = Future<void>.value();
  int _generation = 0;
  bool _disposed = false;
  bool _running = false;
  bool _detecting = false;
  TunerPcmDecoder _decoder = TunerPcmDecoder();

  @override
  Stream<double?> get pitches => _pitches.stream;

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _operations.then((_) => operation());
    _operations = next.catchError((Object _) {});
    return next;
  }

  @override
  Future<void> start() {
    final generation = ++_generation;
    return _serialize(() async {
      if (_disposed || generation != _generation) return;
      try {
        await _stopRecorder();
        final recorder = _recorder ??= AudioRecorder();
        if (!await recorder.hasPermission()) {
          throw const TunerAudioException(
            'Microphone access is off. Allow it in app or browser settings, then retry.',
          );
        }
        if (_disposed || generation != _generation) return;
        if (!await recorder.isEncoderSupported(AudioEncoder.pcm16bits)) {
          throw const TunerAudioException(
            'Live tuning is not supported by this microphone or browser.',
          );
        }
        _decoder = TunerPcmDecoder();
        await recorder.setOnConfigChanged((config) {
          if (generation != _generation) return;
          _decoder = TunerPcmDecoder(
            sampleRate: config.sampleRate,
            channels: config.numChannels,
          );
        });
        if (_disposed || generation != _generation) return;
        _state = recorder.onStateChanged().listen((state) {
          if (_running && state != RecordState.record) {
            _fail(
                generation,
                const TunerAudioException(
                  'Microphone interrupted. Tap Retry to continue tuning.',
                ));
          }
        }, onError: (Object error) => _fail(generation, error));
        final stream = await recorder.startStream(const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 44100,
          numChannels: 1,
          androidConfig: AndroidRecordConfig(
            audioSource: AndroidAudioSource.mic,
            manageBluetooth: false,
          ),
        ));
        if (_disposed || generation != _generation) {
          await _stopRecorder();
          return;
        }
        _running = true;
        _audio = stream.listen(
            (bytes) {
              if (!_running || generation != _generation) return;
              final windows = _decoder.add(bytes);
              // Keep latency bounded: don't queue old audio behind pitch work.
              if (windows.isNotEmpty && !_detecting) {
                unawaited(_detect(windows.last, generation));
              }
            },
            onError: (Object error) => _fail(generation, error),
            onDone: () {
              if (_running) {
                _fail(
                    generation,
                    const TunerAudioException(
                      'Microphone stopped. Tap Retry to continue tuning.',
                    ));
              }
            });
      } on MissingPluginException {
        await _stopAfterFailure();
        throw const TunerAudioException(
          'Live tuning is unavailable in this build. Install a build with microphone support.',
        );
      } catch (_) {
        await _stopAfterFailure();
        rethrow;
      }
    });
  }

  Future<void> _detect(PitchWindow window, int generation) async {
    _detecting = true;
    try {
      final hz = await compute(detectTunerFrequency, window);
      if (!_disposed && _running && generation == _generation) {
        _pitches.add(hz);
      }
    } catch (error) {
      _fail(generation, error);
    } finally {
      _detecting = false;
    }
  }

  void _fail(int generation, Object error) {
    if (_disposed || generation != _generation) return;
    _running = false;
    _pitches.addError(error);
  }

  Future<void> _stopAfterFailure() async {
    try {
      await _stopRecorder();
    } catch (_) {
      // Preserve the original start error while still attempting disposal later.
    }
  }

  Future<void> _stopRecorder() async {
    _running = false;
    await _audio?.cancel();
    _audio = null;
    await _state?.cancel();
    _state = null;
    await _recorder?.stop();
  }

  @override
  Future<void> stop() {
    ++_generation;
    return _serialize(_stopRecorder);
  }

  @override
  Future<void> dispose() {
    _disposed = true;
    ++_generation;
    return _serialize(() async {
      try {
        await _stopRecorder();
      } finally {
        try {
          await _recorder?.dispose();
        } finally {
          _recorder = null;
          await _pitches.close();
        }
      }
    });
  }
}
