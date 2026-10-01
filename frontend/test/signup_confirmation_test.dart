import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/login_page.dart';

void main() {
  testWidgets('sign-up rejects mismatched confirmation before authentication',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));
    await tester.tap(find.text('Sign up!'));
    await tester.pumpAndSettle();
    expect(find.text('Confirm password'), findsOneWidget);
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'example@example.com');
    await tester.enterText(fields.at(1), 'Password123');
    await tester.enterText(fields.at(2), 'Different123');
    await tester.ensureVisible(find.text('CREATE ACCOUNT'));
    await tester.tap(find.text('CREATE ACCOUNT'));
    await tester.pumpAndSettle();
    expect(find.text('Passwords do not match'), findsOneWidget);
    await tester.ensureVisible(find.text('Log in'));
    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();
    expect(find.text('Confirm password'), findsNothing);
  });
}
