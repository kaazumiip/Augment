import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/keyboard_aware_sheet.dart';

void main() {
  for (final width in [280.0, 360.0, 412.0, 800.0]) {
    for (final inset in [0.0, 280.0]) {
      testWidgets('payment fields remain usable at $width with inset $inset',
          (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 640);
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                      onPressed: () => showModalBottomSheet<void>(
                        context: context,
                        useSafeArea: true,
                        isScrollControlled: true,
                        builder: (_) => KeyboardAwareSheet(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox(height: 170),
                                  const TextField(key: Key('number')),
                                  const ResponsivePaymentFields(
                                    expiry: Row(children: [
                                      Expanded(child: TextField()),
                                      SizedBox(width: 6),
                                      Expanded(child: TextField()),
                                    ]),
                                    securityCode: TextField(key: Key('cvc')),
                                  ),
                                  TextButton(
                                    onPressed: () => Navigator.of(_).pop(),
                                    child: const Text('Close'),
                                  ),
                                ]),
                          ),
                        ),
                      ),
                      child: const Text('Open'),
                    )),
          ),
        ));
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byKey(const Key('cvc')));
        await tester.enterText(find.byKey(const Key('cvc')), '123');
        await tester.pumpAndSettle();
        expect(find.text('123'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Close'));
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('cvc')), findsNothing);
      });
    }
  }

  testWidgets('sheet moves above keyboard and returns when it closes',
      (tester) async {
    Future<void> showInset(double inset) async {
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(viewInsets: EdgeInsets.only(bottom: inset)),
          child: const Align(
            alignment: Alignment.bottomCenter,
            child: KeyboardAwareSheet(
              child: SizedBox(key: Key('card'), width: 200, height: 100),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    await showInset(0);
    final original = tester.getBottomLeft(find.byKey(const Key('card'))).dy;
    await showInset(250);
    expect(
        tester.getBottomLeft(find.byKey(const Key('card'))).dy, original - 250);
    await showInset(0);
    expect(tester.getBottomLeft(find.byKey(const Key('card'))).dy, original);
    expect(tester.takeException(), isNull);
  });
}
