// Run explicitly with flutter run -t tool/tuner_device_smoke.dart -d DEVICE.
// No audio is saved. Capture stops automatically after this short smoke test.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:augment_app/tuner_audio.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final status = ValueNotifier<String>('Checking tuner microphone...');
  runApp(MaterialApp(
      home: Scaffold(
          body: Center(
              child: ValueListenableBuilder<String>(
    valueListenable: status,
    builder: (context, value, _) => Text(value, textAlign: TextAlign.center),
  )))));
  await Future<void>.delayed(const Duration(seconds: 1));
  final source = MicrophoneTunerAudio();
  var frames = 0;
  Object? streamError;
  final subscription = source.pitches.listen((hz) {
    frames++;
  }, onError: (Object error) {
    streamError = error;
  });
  try {
    await source.start().timeout(const Duration(seconds: 15));
    await Future<void>.delayed(const Duration(seconds: 3));
    await source.stop();
    final firstFrames = frames;
    if (firstFrames == 0) throw StateError('No PCM analysis frames received');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (frames != firstFrames) {
      throw StateError('Pitch events continued after stop');
    }
    await source.start();
    await Future<void>.delayed(const Duration(seconds: 2));
    await source.stop();
    if (frames <= firstFrames) throw StateError('No frames after restarting');
    if (streamError != null) throw StateError('Stream error: $streamError');
    status.value =
        'Tuner microphone test passed\nStart, capture, stop and restart\n$frames audio frames checked';
    debugPrint('TUNER_DEVICE_SMOKE_PASS frames=$frames');
  } catch (error) {
    status.value = 'Tuner microphone test failed\n$error';
    debugPrint('TUNER_DEVICE_SMOKE_FAIL $error');
  } finally {
    await subscription.cancel();
    await source.dispose();
  }
}
