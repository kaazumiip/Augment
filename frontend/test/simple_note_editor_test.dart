import 'package:augment_app/music_note_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'sheet_edit_document_test.dart' show editorFixture;

void main() {
  testWidgets('save returns edited XML and discard does not save',
      (tester) async {
    SharedPreferences.setMockInitialValues({'sheet_editor_tour_v3': true});
    EditedMusicSheet? result;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (ctx) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      result = await Navigator.push<EditedMusicSheet>(
                          ctx,
                          MaterialPageRoute(
                              builder: (_) => MusicNoteEditorPage(
                                  musicXml: editorFixture,
                                  osmdScriptUrl: '',
                                  apiBaseUrls: const [],
                                  scoreBuilder: (ctx, select) => TextButton(
                                      onPressed: () => select(0),
                                      child: const Text('Select C4')))));
                    },
                    child: const Text('Open editor'))))));
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select C4'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('D4'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(result?.musicXml, contains('<step>D</step>'));
    result = null;
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select C4'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('D4'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Save your changes?'), findsOneWidget);
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.text('Open editor'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final size in [
    const Size(280, 650),
    const Size(390, 800),
    const Size(800, 390)
  ]) {
    testWidgets('select edit undo and length panel fit $size', (tester) async {
      SharedPreferences.setMockInitialValues({'sheet_editor_tour_v3': true});
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          home: MusicNoteEditorPage(
              musicXml: editorFixture,
              osmdScriptUrl: '',
              apiBaseUrls: const [],
              scoreBuilder: (ctx, select) => Center(
                  child: TextButton(
                      onPressed: () => select(0),
                      child: const Text('Select C4'))))));
      await tester.pumpAndSettle();
      expect(
          find.text('Tap a note on the sheet to change it.'), findsOneWidget);
      await tester.tap(find.text('Select C4'));
      await tester.pumpAndSettle();
      expect(find.text('Bar 1 · C4'), findsOneWidget);
      await tester.ensureVisible(find.text('D4'));
      await tester.tap(find.text('D4'));
      await tester.pumpAndSettle();
      expect(find.text('Bar 1 · D4'), findsOneWidget);
      expect(find.text('Unsaved changes'), findsOneWidget);
      await tester.tap(find.byTooltip('Undo'));
      await tester.pumpAndSettle();
      expect(find.text('Bar 1 · C4'), findsOneWidget);
      await tester.ensureVisible(find.text('Note length'));
      await tester.tap(find.text('Note length'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('0.5 beats'));
      await tester.tap(find.text('0.5 beats'));
      await tester.pumpAndSettle();
      expect(find.text('Current length: 0.5 beats'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
