import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/login_page.dart';

void main() {
  for (final size in [
    const Size(280, 653),
    const Size(360, 800),
    const Size(430, 932),
    const Size(600, 960),
    const Size(766, 883),
  ]) {
    testWidgets('login and signup fit ${size.width}px', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const MaterialApp(home: LoginPage()));
      await tester.pumpAndSettle();
      expect(find.text('Continue with Apple'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Sign up!'));
      await tester.tap(find.text('Sign up!'));
      await tester.pumpAndSettle();
      expect(find.text('Confirm password'), findsOneWidget);
      expect(find.text('Continue with Apple'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
