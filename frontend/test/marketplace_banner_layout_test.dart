import 'package:augment_app/marketplace_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in [280.0, 320.0, 360.0, 390.0, 430.0, 600.0]) {
    for (final scale in [1.0, 1.5]) {
      testWidgets('Banner fits width $width at text scale $scale',
          (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
                size: Size(width, 900), textScaler: TextScaler.linear(scale)),
            child: const Scaffold(
                body: SingleChildScrollView(
              child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 28),
                  child: MarketplaceHero()),
            )),
          ),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final image = tester.getRect(find.byType(Image));
        final text =
            tester.getRect(find.text('Music,\nSheets &\nlyrics for\neveryone'));
        expect(image.center.dy, closeTo(text.center.dy, .1));
        if (width < 360) {
          expect(image.width, greaterThan(text.width));
          expect(image.top, lessThan(text.top));
          final heading = tester.widget<Text>(find.text('Music,\nSheets &\nlyrics for\neveryone'));
          expect(heading.style!.fontSize, greaterThanOrEqualTo(23));
        }
        expect(text.right, lessThanOrEqualTo(image.left));
        expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.contain);
        expect(image.right, lessThanOrEqualTo(width));
        expect(text.right, lessThanOrEqualTo(width));
      });
    }
  }
}
