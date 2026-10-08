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

  testWidgets('can navigate to other note and close dialogue', (tester) async {
    SharedPreferences.setMockInitialValues({'sheet_editor_tour_v3': true});
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
    expect(find.text('Tap a note on the sheet to change it.'), findsOneWidget);

    // Select note 0
    await tester.tap(find.text('Select C4'));
    await tester.pumpAndSettle();
    expect(find.text('Bar 1 · C4'), findsOneWidget);

    // Navigate to next note (rest)
    await tester.tap(find.byTooltip('Next note'));
    await tester.pumpAndSettle();
    expect(find.text('Bar 1 · Rest'), findsOneWidget);

    // Navigate to previous note
    await tester.tap(find.byTooltip('Previous note'));
    await tester.pumpAndSettle();
    expect(find.text('Bar 1 · C4'), findsOneWidget);

    // Close the dialogue
    await tester.tap(find.byTooltip('Close dialogue'));
    await tester.pumpAndSettle();
    expect(find.text('Tap a note on the sheet to change it.'), findsOneWidget);
    expect(find.text('Bar 1 · C4'), findsNothing);
  });

  testWidgets('can change note twice, thrice, and switch to edit other notes',
      (tester) async {
    SharedPreferences.setMockInitialValues({'sheet_editor_tour_v3': true});
    void Function(int)? selectCallback;
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
                                  scoreBuilder: (ctx, select) {
                                    selectCallback = select;
                                    return const SizedBox();
                                  })));
                    },
                    child: const Text('Open editor'))))));
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();

    // Select note 0 (C4)
    selectCallback!(0);
    await tester.pumpAndSettle();
    expect(find.text('Bar 1 · C4'), findsOneWidget);

    // 1st change: C4 -> D4
    await tester.tap(find.text('D4'));
    await tester.pumpAndSettle();
    expect(find.text('Bar 1 · D4'), findsOneWidget);

    // 2nd change: D4 -> E4
    await tester.tap(find.text('E4'));
    await tester.pumpAndSettle();
    expect(find.text('Bar 1 · E4'), findsOneWidget);

    // 3rd change: E4 -> F4
    await tester.tap(find.text('F4'));
    await tester.pumpAndSettle();
    expect(find.text('Bar 1 · F4'), findsOneWidget);

    // Switch to note 2 (E4 in measure 1)
    selectCallback!(2);
    await tester.pumpAndSettle();
    expect(find.text('Bar 1 · E4'), findsOneWidget);

    // Change note 2: E4 -> G4
    await tester.tap(find.text('G4'));
    await tester.pumpAndSettle();
    expect(find.text('Bar 1 · G4'), findsOneWidget);

    // 2nd change on note 2: G4 -> A4
    await tester.tap(find.text('A4'));
    await tester.pumpAndSettle();
    expect(find.text('Bar 1 · A4'), findsOneWidget);

    // Save changes
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.musicXml, contains('<step>F</step>'));
    expect(result!.musicXml, contains('<step>A</step>'));
    expect(tester.takeException(), isNull);
  });
}

