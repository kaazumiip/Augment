# Tuner fixes completed

All original audit findings below have been addressed in source: responsive meter/artwork layout; silence timeout; Auto/Manual target locking; wind guidance; note-specific confirmation; target smoothing reset; cross-platform PCM microphone capture; foreground lifecycle, cancellation, errors and Retry; Apple microphone permissions; larger touch targets. The legacy simulated sheet now uses the real tuner. The old Android tuner thread was removed; voice-range recording remains separate.

Validation: all 115 project tests passed. Analyzer: no issues in changed Dart files and test tools. All 11 instrument screens rendered and visually reviewed at three sizes. Generated-tone tests cover 41.2 to 2093 Hz at 44.1/48 kHz, including strong harmonics, noise and PCM chunk boundaries. Android debug build succeeded. Updated renders: `fixed/`.

Device verification limitation: the Android smoke test did not complete while the phone was locked, and the debugger lost connection. Real instrument accuracy and iOS/macOS/web hardware behavior remain unverified. The following is the original audit, retained as historical evidence.

---

# Tuner audit — 12 September 2026

Reviewed the active instrument picker, tuner page, pitch conversion, navigation from Home/Tools, Android audio implementation and iOS registration. No application source was changed.

## Verification

- Flutter analyzer: no issues in tuner_page.dart, tuner_pitch.dart and choose_tuner_instrument_page.dart.
- Existing pitch tests: 4 passed (concert A, range rejection, transposition, sharp/flat deviation).
- Diagnostic widget run: 34 passed: all 11 instruments at 390×844, 320×568 and 844×390, plus injected pitch events. Native microphone calls were mocked. Actual app font and image assets were loaded. These checks establish rendering and reproduce current behavior; they do not establish that all behavior is correct.
- Visually inspected Guitar portrait and Flute small portrait/landscape renders. Other instruments were rendered and checked for Flutter layout exceptions, but were not individually visually reviewed.
- A physical Android device is connected, but this audit did not install a build, record microphone audio, or verify tuning accuracy with a real instrument.

## Findings

| Priority | Finding | Evidence and impact | Suggested correction |
|---|---|---|---|
| High | Artwork obscures the meter | tuner_page.dart:485 places artwork in a second Stack layer at 60% of full screen height. Flute screenshots show overlap at 320×568 and 844×390. Passing overflow tests do not detect stacked occlusion. | Allocate separate layout space for the meter and artwork; support short/landscape viewports. |
| High | Stale in-tune result persists after silence | Android only emits detected frequencies; Dart has no reading timeout. Injected E2 followed by five seconds without events still shows IN TUNE. | Clear pitch history, frequency and tuned state after a short detection timeout. |
| High on non-Android | Missing microphone implementation and unhandled missing-plugin errors | Custom augment/voice_range channel is implemented in Android MainActivity, but not iOS AppDelegate. Dart catches PlatformException only; MissingPluginException and the unawaited stop call are unhandled. | Implement supported platforms or show a clear supported-platform message and handle start/stop failures. |
| Medium | Manual string choice is overridden by automatic detection | Injected E2 after tapping A2 switches the target back to E2. The UI offers no Auto/Manual distinction. | Make automatic mode explicit and allow selected-string locking. |
| Medium | Incorrect wind-instrument guidance | tuner_page.dart:353 uses TIGHTEN/LOOSEN for every instrument, including flute, saxophone, trumpet and clarinet. | Use neutral flat/sharp guidance for wind instruments. |
| Medium | Confirmation overstates what was checked | tuner_page.dart:462 says Guitar in tune after a single string is detected; there is no completed-string tracking. | Say E2 in tune or track every required string before confirming the instrument. |
| Medium | Smoothing crosses tuning targets | _smoothCents retains its prior value when an automatically selected string or chromatic MIDI note changes. Previous-target error can temporarily bias the new reading. | Reset cents smoothing and tuned hysteresis when the target changes. |
| Medium | Microphone lifecycle needs hardening | No background pause/resume handling; Android tuning flag is shared across threads without volatile visibility. stopTuner joins before stopping the recorder and does not cancel pending permission state. | Tie recording to foreground lifecycle and ensure orderly, session-safe shutdown. Physical-device verification remains necessary. |
| Low | Weak microphone failure recovery | Permission denial/start failure only produces a snackbar; idle text says Tap a note and play it, with no explicit retry action. | Show a persistent microphone state and retry control. |
| Low | Small control touch areas | Back icon is a GestureDetector around a 20–24 pixel icon; string controls are 42×42. | Use accessible labeled buttons with at least 48×48 touch areas. |

## Other observations

The legacy tuner_sheet.dart generates simulated random readings, but no current lib file imports or opens it. The active tuner route uses real Android microphone events; do not confuse the unused demo with the active feature.

Current targets cover six string instruments and five wind instruments. Standard tuning tables and written/concert transposition logic were reviewed; the existing math tests cover representative conversions. Native YIN frequency extraction, harmonic rejection, noise behavior, latency, permissions and microphone release still need controlled audio and physical-device tests before a claim of end-to-end accuracy.

## Artifacts

PNG files alongside this report show Guitar and Flute at the three sizes. audit_output_log.txt contains the diagnostic test output. tuner_audit_diagnostic.dart is the audit harness, stored outside test discovery because it intentionally asserts current problematic behavior. To rerun, copy it to frontend/test/tuner_audit_temp_test.dart and run `flutter test test/tuner_audit_temp_test.dart --update-goldens` from frontend; remove the temporary copy afterwards.
