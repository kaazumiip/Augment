import 'package:flutter_test/flutter_test.dart';
import '../lib/sheet_playback_seek_guard.dart';

void main() {
  test('old zero position cannot overwrite a seek to the middle', () {
    final guard = SheetPlaybackSeekGuard();
    final now = DateTime(2026, 10, 1);
    guard.seek(const Duration(seconds: 55), now);
    expect(guard.accept(Duration.zero, now, dragging: false), false);
    expect(
        guard.accept(const Duration(seconds: 55), now, dragging: false), true);
    expect(
        guard.accept(const Duration(seconds: 56), now, dragging: false), true);
  });
  test('positions are ignored while dragging; newest seek wins', () {
    final guard = SheetPlaybackSeekGuard();
    final now = DateTime(2026, 10, 1);
    expect(guard.accept(Duration.zero, now, dragging: true), false);
    guard.seek(const Duration(seconds: 20), now);
    guard.seek(const Duration(seconds: 80), now);
    expect(
        guard.accept(const Duration(seconds: 20), now, dragging: false), false);
    expect(
        guard.accept(const Duration(seconds: 80), now, dragging: false), true);
  });
  test('restart and failed-seek reset work; guard cannot freeze forever', () {
    final guard = SheetPlaybackSeekGuard();
    final now = DateTime(2026, 10, 1);
    guard.seek(Duration.zero, now);
    expect(guard.accept(Duration.zero, now, dragging: false), true);
    guard.seek(const Duration(seconds: 80), now);
    guard.clear();
    expect(guard.accept(Duration.zero, now, dragging: false), true);
    guard.seek(const Duration(seconds: 80), now);
    expect(
        guard.accept(Duration.zero, now.add(const Duration(seconds: 3)),
            dragging: false),
        true);
  });
}
