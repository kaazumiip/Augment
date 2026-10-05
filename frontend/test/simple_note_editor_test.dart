import 'package:augment_app/music_note_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final width in [280.0, 390.0]) {
    testWidgets('simple editor controls fit at $width', (tester) async {
      final previousErrorHandler = FlutterError.onError;
      FlutterError.onError = (details) {
        debugPrint(details.toString());
        previousErrorHandler?.call(details);
      };
      addTearDown(() => FlutterError.onError = previousErrorHandler);
      SharedPreferences.setMockInitialValues({'sheet_editor_tour_v2': true});
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const MaterialApp(
          home: MusicNoteEditorPage(
        musicXml: '<score-partwise><part-list/></score-partwise>',
        osmdScriptUrl: '',
        apiBaseUrls: [],
      )));
      await tester.pumpAndSettle();
      expect(find.text('Lower'), findsOneWidget);
      expect(find.text('Higher'), findsOneWidget);
      expect(find.text('Hear note'), findsOneWidget);
      expect(find.text('Save changes'), findsOneWidget);
      expect(find.text('Whole'), findsNothing);
      expect(find.text('Duration'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
