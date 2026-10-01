// Explicit visual QA: flutter test tool/tuner_visual_review.dart --update-goldens
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:augment_app/choose_tuner_instrument_page.dart';
import 'package:augment_app/tuner_page.dart';

import '../test/tuner_page_test.dart' show FakeTunerAudio;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader('Instrument Sans')
          ..addFont(rootBundle
              .load('fonts/InstrumentSans-VariableFont_wdth,wght.ttf')))
        .load();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });
  for (final size in [
    const Size(390, 844),
    const Size(320, 568),
    const Size(844, 390)
  ]) {
    for (final instrument in ChooseTunerInstrumentPage.instruments) {
      testWidgets('${instrument.name} at $size', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: 'Instrument Sans'),
          home:
              TunerPage(instrument: instrument, audioSource: FakeTunerAudio()),
        ));
        await tester.runAsync(() async =>
            Future<void>.delayed(const Duration(milliseconds: 200)));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(
            find.byType(TunerPage),
            matchesGoldenFile(
                '../audit_output/fixed/${instrument.name.replaceAll(' ', '_')}_${size.width.toInt()}.png'));
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });
    }
  }
}
