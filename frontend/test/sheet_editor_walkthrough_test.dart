import 'package:augment_app/sheet_editor_walkthrough.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('mascot walkthrough advances, goes back and closes on a narrow screen', (tester) async {
    tester.view.physicalSize = const Size(280, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final keys = List.generate(4, (_) => GlobalKey());
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) {
      return Column(children: [
        for (final key in keys) SizedBox(key: key, height: 24, width: 100),
        TextButton(onPressed: () => showSheetEditorWalkthrough(context, keys), child: const Text('Help')),
      ]);
    }))));
    await tester.tap(find.text('Help'));
    await tester.pumpAndSettle();
    expect(find.text('1 of 4 • Choose a note'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('2 of 4 • Change its sound'), findsOneWidget);
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('1 of 4 • Choose a note'), findsOneWidget);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    expect(find.text('Next'), findsNothing);
    await tester.tap(find.text('Help'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(find.text('Next'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
