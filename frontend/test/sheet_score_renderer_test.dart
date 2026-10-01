import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:augment_app/sheet_score_renderer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('score renderer loads from the APK without any network URL', () async {
    final first = SheetScoreRenderer.loadScriptUrl();
    expect(identical(first, SheetScoreRenderer.loadScriptUrl()), isTrue);
    final url = await first;
    expect(url.startsWith('data:application/javascript;base64,'), isTrue);
    final script = utf8.decode(base64Decode(url.split(',').last));
    expect(script, contains('OpenSheetMusicDisplay'));
    expect(script.length, greaterThan(100000));
  });
}
