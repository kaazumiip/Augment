import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:augment_app/choose_tuner_instrument_page.dart';
import 'package:augment_app/tuner_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('augment/voice_range');
  setUpAll(() async {
    await (FontLoader('Instrument Sans')..addFont(rootBundle.load('fonts/InstrumentSans-VariableFont_wdth,wght.ttf'))).load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => true);
  });
  testWidgets('audit pitch events, stale reading and automatic target selection', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: TunerPage(instrument: instruments.first)));
    await tester.pumpAndSettle();
    Future<void> pitch(double hz) async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        'augment/voice_range', const StandardMethodCodec().encodeMethodCall(MethodCall('tunerPitch', {'hz': hz})), (_) {});
      await tester.pump(const Duration(milliseconds: 100));
    }
    for (var i = 0; i < 8; i++) { await pitch(82.41); }
    expect(find.textContaining('IN TUNE'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(find.textContaining('IN TUNE'), findsOneWidget, reason: 'Audit confirms stale in-tune feedback after silence');
    await tester.tap(find.text('A2'));
    for (var i = 0; i < 12; i++) { await pitch(82.41); }
    expect(find.text('E2'), findsNWidgets(2), reason: 'Auto detection overrides the manual A2 selection');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  for (final size in [const Size(390, 844), const Size(320, 568), const Size(844, 390)]) {
    for (final instrument in instruments) {
      testWidgets('${instrument.name} at $size', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(MaterialApp(theme: ThemeData(fontFamily: 'Instrument Sans'), home: TunerPage(instrument: instrument)));
        await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 150)); });
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (instrument.name == 'Guitar' || instrument.name == 'Flute') {
          await expectLater(find.byType(TunerPage), matchesGoldenFile('../audit_output/${instrument.name}_${size.width.toInt()}.png'));
        }
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 150)); });
        await tester.pumpAndSettle();
      });
    }
  }
}
  const List<TunerInstrument> instruments = [
    // String instruments
    TunerInstrument(
      name: 'Guitar',
      subtitle: 'Guitar 6-String',
      category: 'String',
      imagePath: 'assets/tuner_guitar.png',
      isRedCard: true,
      strings: [
        {'note': 'E', 'octave': 2, 'freq': 82.41},
        {'note': 'A', 'octave': 2, 'freq': 110.00},
        {'note': 'D', 'octave': 3, 'freq': 146.83},
        {'note': 'G', 'octave': 3, 'freq': 196.00},
        {'note': 'B', 'octave': 3, 'freq': 246.94},
        {'note': 'E', 'octave': 4, 'freq': 329.63},
      ],
    ),
    TunerInstrument(
      name: 'Bass',
      subtitle: 'Bass guitar 4-String',
      category: 'String',
      isRedCard: false,
      strings: [
        {'note': 'E', 'octave': 1, 'freq': 41.20},
        {'note': 'A', 'octave': 1, 'freq': 55.00},
        {'note': 'D', 'octave': 2, 'freq': 73.42},
        {'note': 'G', 'octave': 2, 'freq': 98.00},
      ],
    ),
    TunerInstrument(
      name: 'Ukulele',
      subtitle: 'Ukulele 4-String',
      category: 'String',
      isRedCard: true,
      strings: [
        {'note': 'G', 'octave': 4, 'freq': 392.00},
        {'note': 'C', 'octave': 4, 'freq': 261.63},
        {'note': 'E', 'octave': 4, 'freq': 329.63},
        {'note': 'A', 'octave': 4, 'freq': 440.00},
      ],
    ),
    TunerInstrument(
      name: 'Violin',
      subtitle: 'Violin',
      category: 'String',
      isRedCard: false,
      strings: [
        {'note': 'G', 'octave': 3, 'freq': 196.00},
        {'note': 'D', 'octave': 4, 'freq': 293.66},
        {'note': 'A', 'octave': 4, 'freq': 440.00},
        {'note': 'E', 'octave': 5, 'freq': 659.25},
      ],
    ),
    TunerInstrument(
      name: 'Cello',
      subtitle: 'Cello 4-String',
      category: 'String',
      isRedCard: true,
      strings: [
        {'note': 'C', 'octave': 2, 'freq': 65.41},
        {'note': 'G', 'octave': 2, 'freq': 98.00},
        {'note': 'D', 'octave': 3, 'freq': 146.83},
        {'note': 'A', 'octave': 3, 'freq': 220.00},
      ],
    ),
    TunerInstrument(
      name: 'Electric guitar',
      subtitle: 'Electric guitar 6-String',
      category: 'String',
      isRedCard: false,
      strings: [
        {'note': 'E', 'octave': 2, 'freq': 82.41},
        {'note': 'A', 'octave': 2, 'freq': 110.00},
        {'note': 'D', 'octave': 3, 'freq': 146.83},
        {'note': 'G', 'octave': 3, 'freq': 196.00},
        {'note': 'B', 'octave': 3, 'freq': 246.94},
        {'note': 'E', 'octave': 4, 'freq': 329.63},
      ],
    ),
    // Wind instruments
    TunerInstrument(
      name: 'Alto Saxophone',
      subtitle: 'Eb Alto Sax',
      category: 'Wind',
      imagePath: 'assets/saxophonist.png',
      isRedCard: true,
      isChromatic: true,
      minMidi: 49,
      maxMidi: 81,
      writtenPitchOffset: 9,
      preferFlats: true,
      strings: [
        {'note': 'Bb', 'octave': 3, 'freq': 233.08},
        {'note': 'Eb', 'octave': 4, 'freq': 311.13},
        {'note': 'Ab', 'octave': 4, 'freq': 415.30},
        {'note': 'Db', 'octave': 5, 'freq': 554.37},
      ],
    ),
    TunerInstrument(
      name: 'Tenor Saxophone',
      subtitle: 'Bb Tenor Sax',
      category: 'Wind',
      imagePath: 'assets/saxophonist.png',
      isRedCard: false,
      isChromatic: true,
      minMidi: 44,
      maxMidi: 76,
      writtenPitchOffset: 14,
      preferFlats: true,
      strings: [
        {'note': 'Ab', 'octave': 2, 'freq': 103.83},
        {'note': 'Db', 'octave': 3, 'freq': 138.59},
        {'note': 'Gb', 'octave': 3, 'freq': 185.00},
        {'note': 'B', 'octave': 3, 'freq': 246.94},
      ],
    ),
    TunerInstrument(
      name: 'Trumpet',
      subtitle: 'Brass Trumpet',
      category: 'Wind',
      isRedCard: false,
      isChromatic: true,
      minMidi: 54,
      maxMidi: 82,
      writtenPitchOffset: 2,
      preferFlats: true,
      strings: [
        {'note': 'Bb', 'octave': 3, 'freq': 233.08},
        {'note': 'C', 'octave': 4, 'freq': 261.63},
        {'note': 'D', 'octave': 4, 'freq': 293.66},
        {'note': 'Eb', 'octave': 4, 'freq': 311.13},
      ],
    ),
    TunerInstrument(
      name: 'Flute',
      subtitle: 'Concert Flute',
      category: 'Wind',
      isRedCard: true,
      isChromatic: true,
      minMidi: 60,
      maxMidi: 96,
      strings: [
        {'note': 'C', 'octave': 4, 'freq': 261.63},
        {'note': 'D', 'octave': 4, 'freq': 293.66},
        {'note': 'E', 'octave': 4, 'freq': 329.63},
        {'note': 'F', 'octave': 4, 'freq': 349.23},
      ],
    ),
    TunerInstrument(
      name: 'Clarinet',
      subtitle: 'Bb Clarinet',
      category: 'Wind',
      isRedCard: false,
      isChromatic: true,
      minMidi: 50,
      maxMidi: 91,
      writtenPitchOffset: 2,
      preferFlats: true,
      strings: [
        {'note': 'D', 'octave': 3, 'freq': 146.83},
        {'note': 'G', 'octave': 3, 'freq': 196.00},
        {'note': 'C', 'octave': 4, 'freq': 261.63},
        {'note': 'F', 'octave': 4, 'freq': 349.23},
      ],
    ),
  ];




