import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_palette.dart';
import 'api_config.dart';

class VoiceRangePage extends StatefulWidget {
  const VoiceRangePage({super.key});

  @override
  State<VoiceRangePage> createState() => _VoiceRangePageState();
}

class _VoiceRangePageState extends State<VoiceRangePage>
    with SingleTickerProviderStateMixin {
  static const _channel = MethodChannel('augment/voice_range');
  List<String> get _baseUrls => ApiConfig.baseUrls;

  late final AnimationController _motion;
  Timer? _timer;
  bool _recording = false;
  bool _analyzing = false;
  bool _analysisComplete = false;
  bool _showIntro = false;
  bool _restoring = true;
  int _seconds = 0;
  double? _liveHz;
  String? _error;
  Map<String, dynamic>? _result;

  @override
  void initState() {
    super.initState();
    _motion = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1100))
      ..repeat();
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'voicePitch' || !mounted) return;
      final values = Map<Object?, Object?>.from(call.arguments as Map);
      final hz = (values['hz'] as num?)?.toDouble();
      if (hz != null && hz.isFinite && hz > 0) {
        setState(() => _liveHz = hz);
      }
    });
    _restoreLastResult();
  }

  String get _resultKey {
    final userId = FirebaseAuth.instance.currentUser?.uid ?? 'anonymous';
    return 'voice_range_result_$userId';
  }

  Future<void> _restoreLastResult() async {
    final preferences = await SharedPreferences.getInstance();
    final saved = preferences.getString(_resultKey);
    Map<String, dynamic>? restored;
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId != null) {
      try {
        final row = await Supabase.instance.client
            .from('voice_range_results')
            .select('result')
            .eq('user_id', userId)
            .maybeSingle();
        if (row?['result'] is Map) {
          restored = Map<String, dynamic>.from(row!['result'] as Map);
          await preferences.setString(_resultKey, jsonEncode(restored));
        }
      } catch (_) {
        // Fall back to the account-scoped device cache while offline.
      }
    }
    if (restored == null && saved != null) {
      try {
        restored = jsonDecode(saved) as Map<String, dynamic>;
      } catch (_) {
        await preferences.remove(_resultKey);
      }
    }
    if (!mounted) return;
    setState(() {
      _result = restored;
      _showIntro = restored == null;
      _restoring = false;
    });
  }

  Future<void> _saveResult(Map<String, dynamic> result) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_resultKey, jsonEncode(result));
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) return;
    try {
      await Supabase.instance.client.from('voice_range_results').upsert({
        'user_id': userId,
        'result': result,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'user_id');
    } catch (_) {
      // Keep the local result; the user can still view it while offline.
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _channel.setMethodCallHandler(null);
    _motion.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_recording || _analyzing) return;
    setState(() {
      _error = null;
      _result = null;
      _liveHz = null;
    });
    try {
      await _channel.invokeMethod('start');
      if (!mounted) return;
      setState(() {
        _recording = true;
        _seconds = 0;
      });
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted || !_recording) {
          return;
        }
        setState(() => _seconds++);
        if (_seconds >= 12) {
          _stopAndAnalyze();
        }
      });
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
            () => _error = error.message ?? 'Microphone permission is needed.');
      }
    } catch (_) {
      if (mounted) {
        setState(
            () => _error = 'Voice recording is available on Android devices.');
      }
    }
  }

  Future<void> _stopAndAnalyze() async {
    if (!_recording) {
      return;
    }
    _timer?.cancel();
    setState(() {
      _recording = false;
      _analyzing = true;
      _analysisComplete = false;
    });
    try {
      final path = await _channel.invokeMethod<String>('stop');
      if (path == null || path.isEmpty) {
        throw Exception('No recording was created.');
      }
      final result = await _analyze(File(path));
      try {
        await File(path).delete();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _result = result;
          _analysisComplete = true;
        });
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await _saveResult(result);
      }
    } catch (error) {
      if (mounted) {
        setState(
            () => _error = error.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) {
        setState(() => _analyzing = false);
      }
    }
  }

  Future<Map<String, dynamic>> _analyze(File file) async {
    Object? lastError;
    for (var index = 0; index < _baseUrls.length; index++) {
      final baseUrl = _baseUrls[index];
      try {
        final request = http.MultipartRequest(
            'POST', Uri.parse('$baseUrl/api/voice/analyze'))
          ..files.add(await http.MultipartFile.fromPath('file', file.path));
        // USB reverse and the current LAN address can take a little longer
        // while Python analyzes the recording. Other old addresses should
        // fail quickly instead of holding the result screen hostage.
        final response =
            await request.send().timeout(Duration(seconds: index < 2 ? 60 : 6));
        final data = jsonDecode(await response.stream
            .bytesToString()
            .timeout(const Duration(seconds: 5))) as Map<String, dynamic>;
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return data;
        }
        lastError = data['error'] ?? 'Voice analysis failed.';
        // A 4xx response reached the correct server. Retrying other network
        // addresses cannot fix an invalid or too-quiet recording.
        if (response.statusCode >= 400 && response.statusCode < 500) break;
      } catch (error) {
        lastError = error;
      }
    }
    throw Exception(lastError ??
        'Could not reach the voice analysis service. Start the Python and Node servers, then try again.');
  }

  String? _noteFromHz(double? hz) {
    if (hz == null || hz <= 0) return null;
    const names = [
      'C',
      'C#',
      'D',
      'D#',
      'E',
      'F',
      'F#',
      'G',
      'G#',
      'A',
      'A#',
      'B'
    ];
    final midi = (69 + 12 * (math.log(hz / 440) / math.ln2)).round();
    if (midi < 40 || midi > 84) return null;
    return '${names[midi % 12]}${midi ~/ 12 - 1}';
  }

  @override
  Widget build(BuildContext context) {
    final text = AppPalette.text(context);
    final muted = AppPalette.muted(context);
    final active = _recording || _analyzing;
    final note = _recording ? (_noteFromHz(_liveHz) ?? '--') : '--';
    return Scaffold(
      backgroundColor: AppPalette.page(context),
      body: Stack(children: [
        SafeArea(
            child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 34),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AppBackButton(
              color: text,
              size: 24,
              onPressed: () => Navigator.pop(context),
            ),
            const SizedBox(height: 18),
            RichText(
                text: TextSpan(
                    style: TextStyle(
                        fontFamily: 'Instrument Sans',
                        color: text,
                        fontSize: 27,
                        fontWeight: FontWeight.w800),
                    children: const [
                  TextSpan(text: 'Voice pitch test'),
                  TextSpan(
                      text: ' .', style: TextStyle(color: Color(0xFFBA0007)))
                ])),
            const SizedBox(height: 7),
            Text('Sing from your lowest comfortable note to your highest.',
                style: TextStyle(color: muted, fontSize: 14)),
            const SizedBox(height: 24),
            Center(
                child: Column(children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                    width: 9,
                    height: 9,
                    decoration: const BoxDecoration(
                        color: Color(0xFFDF161B), shape: BoxShape.circle)),
                const SizedBox(width: 7),
                Text(
                    _analyzing
                        ? 'Analyzing your range...'
                        : _recording
                            ? 'Listening...'
                            : 'Ready to listen',
                    style: TextStyle(
                        color: muted,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
              ]),
              const SizedBox(height: 17),
              AnimatedBuilder(
                  animation: _motion,
                  builder: (_, __) => _PitchDial(
                      note: note,
                      active: active,
                      phase: _motion.value,
                      text: text)),
            ])),
            const SizedBox(height: 20),
            AnimatedBuilder(
                animation: _motion,
                builder: (_, __) =>
                    _SoundWave(active: _recording, phase: _motion.value)),
            if (_error != null) ...[
              const SizedBox(height: 24),
              Text(_error!,
                  style:
                      const TextStyle(color: Color(0xFFBA0007), fontSize: 13))
            ],
            if (_result != null) ...[
              const SizedBox(height: 22),
              _ResultPanel(result: _result!, text: text, muted: muted)
            ],
            const SizedBox(height: 25),
            Center(
              child: Column(children: [
                Material(
                  color: Colors.transparent,
                  shape: const CircleBorder(),
                  child: InkWell(
                    onTap: _analyzing
                        ? null
                        : (_recording ? _stopAndAnalyze : _start),
                    customBorder: const CircleBorder(),
                    child: Ink(
                      width: 76,
                      height: 76,
                      decoration: const BoxDecoration(
                          color: Color(0xFFBA0007), shape: BoxShape.circle),
                      child: Icon(
                        _analyzing
                            ? Icons.hourglass_top_rounded
                            : _recording
                                ? Icons.stop_rounded
                                : Icons.mic_rounded,
                        color: Colors.white,
                        size: 31,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 9),
                Text(
                  _analyzing
                      ? 'Analyzing'
                      : _recording
                          ? 'Tap to finish'
                          : _result == null
                              ? 'Tap to record'
                              : 'Tap to test again',
                  style: TextStyle(
                      color: muted, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ]),
            ),
          ]),
        )),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 520),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeOutCubic,
          transitionBuilder: (child, animation) {
            final curve =
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
            return FadeTransition(
              opacity: curve,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, -.025),
                  end: Offset.zero,
                ).animate(curve),
                child: ScaleTransition(
                  scale: Tween<double>(begin: .985, end: 1).animate(curve),
                  child: child,
                ),
              ),
            );
          },
          child: _restoring
              ? ColoredBox(
                  key: const ValueKey('restoring'),
                  color: AppPalette.page(context),
                )
              : _showIntro
                  ? _VoiceTestIntro(
                      key: const ValueKey('intro'),
                      onStart: () => setState(() => _showIntro = false),
                    )
                  : _analyzing
                      ? _VoiceTestAnalyzing(
                          key: const ValueKey('analyzing'),
                          complete: _analysisComplete)
                      : _result != null
                          ? _VoiceTestResult(
                              key: const ValueKey('result'),
                              result: _result!,
                              onAgain: () => setState(() {
                                _result = null;
                                _error = null;
                                _showIntro = true;
                              }),
                            )
                          : const SizedBox.shrink(key: ValueKey('test')),
        ),
      ]),
    );
  }
}

class _VoiceTestIntro extends StatelessWidget {
  const _VoiceTestIntro({super.key, required this.onStart});
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: AppPalette.page(context),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(26, 18, 26, 32),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              AppBackButton(onPressed: () => Navigator.pop(context)),
              const Spacer(),
              Container(
                width: 68,
                height: 68,
                decoration: const BoxDecoration(
                    color: Color(0xFFBA0007), shape: BoxShape.circle),
                child: const Icon(Icons.mic_none_rounded,
                    color: Colors.white, size: 33),
              ),
              const SizedBox(height: 28),
              Text('Find your voice range .',
                  style: TextStyle(
                      color: AppPalette.text(context),
                      fontSize: 29,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              Text(
                  'Sing from your lowest comfortable note to your highest, without straining. Take one smooth, relaxed glide.',
                  style: TextStyle(
                      color: AppPalette.muted(context),
                      fontSize: 15,
                      height: 1.35)),
              const Spacer(flex: 2),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: onStart,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFBA0007),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Start voice test'),
                ),
              ),
            ]),
          ),
        ),
      );
}

class _VoiceTestAnalyzing extends StatefulWidget {
  const _VoiceTestAnalyzing({super.key, required this.complete});
  final bool complete;

  @override
  State<_VoiceTestAnalyzing> createState() => _VoiceTestAnalyzingState();
}

class _VoiceTestAnalyzingState extends State<_VoiceTestAnalyzing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  final _elapsed = Stopwatch();
  Timer? _progressTimer;

  double get _progress => widget.complete
      ? 1
      : .05 + .90 * (1 - math.exp(-_elapsed.elapsedMilliseconds / 18000));

  @override
  void initState() {
    super.initState();
    _elapsed.start();
    _progressTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
    _controller = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 4200))
      ..repeat();
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _elapsed.stop();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: AppPalette.page(context),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            AnimatedBuilder(
              animation: _controller,
              builder: (_, __) => SizedBox(
                width: 172,
                height: 126,
                child: CustomPaint(
                  painter: _AnalysisWavePainter(phase: _controller.value),
                ),
              ),
            ),
            const SizedBox(height: 25),
            Text('Listening for your vocal range',
                style: TextStyle(
                    color: AppPalette.text(context),
                    fontSize: 20,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 7),
            Text('Matching your notes to a comfortable range',
                style:
                    TextStyle(color: AppPalette.muted(context), fontSize: 13)),
            const SizedBox(height: 22),
            Text('${(_progress * 100).floor()}%',
                style: const TextStyle(
                    color: Color(0xFFD30A02),
                    fontSize: 30,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            SizedBox(
                width: 230,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                      value: _progress,
                      minHeight: 6,
                      color: const Color(0xFFD30A02),
                      backgroundColor:
                          AppPalette.muted(context).withValues(alpha: .15)),
                )),
            const SizedBox(height: 9),
            Text(widget.complete ? 'Analysis complete' : 'Estimated progress',
                style:
                    TextStyle(color: AppPalette.muted(context), fontSize: 12)),
          ]),
        ),
      );
}

class _VoiceTestResult extends StatelessWidget {
  const _VoiceTestResult(
      {super.key, required this.result, required this.onAgain});
  final Map<String, dynamic> result;
  final VoidCallback onAgain;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: AppPalette.page(context),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(26, 18, 26, 32),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              AppBackButton(onPressed: () => Navigator.pop(context)),
              const SizedBox(height: 22),
              Text('Your vocal range',
                  style: TextStyle(
                      color: AppPalette.muted(context),
                      fontSize: 13,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 16),
              _RangeSummary(
                result: result,
                text: AppPalette.text(context),
                muted: AppPalette.muted(context),
              ),
              const SizedBox(height: 24),
              _ResultPanel(
                result: result,
                text: AppPalette.text(context),
                muted: AppPalette.muted(context),
              ),
              const SizedBox(height: 24),
              Text('Vocal range guide',
                  style: TextStyle(
                      color: AppPalette.muted(context),
                      fontSize: 13,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              _RangeGuide(isDark: AppPalette.isDark(context), result: result),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: OutlinedButton(
                  onPressed: onAgain,
                  style: OutlinedButton.styleFrom(
                    backgroundColor: const Color(0xFFBA0007),
                    foregroundColor: Colors.white,
                    side: BorderSide.none,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Test again'),
                ),
              ),
            ]),
          ),
        ),
      );
}

class _AnalysisWavePainter extends CustomPainter {
  const _AnalysisWavePainter({required this.phase});
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    const bars = 29;
    final paint = Paint()
      ..color = const Color(0xFFBA0007)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    for (var index = 0; index < bars; index++) {
      final position = index / (bars - 1);
      final width = size.width / bars;
      final x = width * index + width / 2;
      final envelope = .3 + math.sin(position * math.pi).abs() * .7;
      // Layered sine motion keeps every bar moving with rounded, continuous
      // level changes instead of sharp equalizer-style jumps.
      final time = phase * math.pi * 2;
      final swell =
          .5 + .5 * math.sin(time * .86 + index * .46 + math.sin(index * .18));
      final detail = .5 + .5 * math.sin(time * 1.21 + index * .91);
      final drift = .5 + .5 * math.sin(time * .43 - index * .28);
      final level = swell * .57 + detail * .27 + drift * .16;
      final height = 7 + level * 49 * envelope;
      paint.color =
          const Color(0xFFBA0007).withValues(alpha: .42 + (height / 56) * .58);
      canvas.drawLine(Offset(x, centerY - height / 2),
          Offset(x, centerY + height / 2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _AnalysisWavePainter oldDelegate) =>
      oldDelegate.phase != phase;
}

class _PitchDial extends StatelessWidget {
  const _PitchDial(
      {required this.note,
      required this.active,
      required this.phase,
      required this.text});
  final String note;
  final bool active;
  final double phase;
  final Color text;
  @override
  Widget build(BuildContext context) => SizedBox(
      width: 255,
      height: 255,
      child: CustomPaint(
        painter:
            _PitchDialPainter(active: active, phase: phase, textColor: text),
        child: Center(
            child: Container(
                width: 84,
                height: 84,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: active
                        ? const Color(0xFF242424)
                        : AppPalette.surface(context)),
                child: Text(note,
                    style: TextStyle(
                        color: active ? const Color(0xFFE0181B) : text,
                        fontSize: 24,
                        fontWeight: FontWeight.w800)))),
      ));
}

class _PitchDialPainter extends CustomPainter {
  _PitchDialPainter(
      {required this.active, required this.phase, required this.textColor});
  final bool active;
  final double phase;
  final Color textColor;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 4;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = const Color(0xFFBA0007).withValues(alpha: active ? .35 : .15);
    canvas.drawCircle(center, radius, ring);
    canvas.drawCircle(center, radius * .59,
        ring..color = const Color(0xFFBA0007).withValues(alpha: .12));
    if (active) {
      canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius * .79),
          -2.75,
          .54,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 22
            ..color = const Color(0xFFDF161B).withValues(
                alpha: .72 + math.sin(phase * math.pi * 2).abs() * .18));
    }
    const notes = [
      'C',
      'C#',
      'D',
      'D#',
      'E',
      'F',
      'F#',
      'G',
      'G#',
      'A',
      'A#',
      'B'
    ];
    for (var i = 0; i < notes.length; i++) {
      final angle = -math.pi / 2 + i * 2 * math.pi / notes.length;
      canvas.drawLine(
          center + Offset(math.cos(angle), math.sin(angle)) * radius * .62,
          center + Offset(math.cos(angle), math.sin(angle)) * radius,
          Paint()..color = const Color(0xFFBA0007).withValues(alpha: .10));
      final position =
          center + Offset(math.cos(angle), math.sin(angle)) * radius * .84;
      final painter = TextPainter(
          text: TextSpan(
              text: notes[i],
              style: TextStyle(
                  color: active && notes[i] == 'A#'
                      ? const Color(0xFFBA0007)
                      : textColor,
                  fontSize: 16,
                  fontWeight: FontWeight.w600)),
          textDirection: TextDirection.ltr)
        ..layout();
      painter.paint(
          canvas, position - Offset(painter.width / 2, painter.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _PitchDialPainter old) =>
      old.active != active || old.phase != phase || old.textColor != textColor;
}

class _SoundWave extends StatelessWidget {
  const _SoundWave({required this.active, required this.phase});
  final bool active;
  final double phase;
  @override
  Widget build(BuildContext context) => Container(
      height: 58,
      width: double.infinity,
      decoration: BoxDecoration(
          color: AppPalette.surface(context),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppPalette.border(context))),
      child: CustomPaint(
          painter: _SoundWavePainter(active: active, phase: phase)));
}

class _SoundWavePainter extends CustomPainter {
  _SoundWavePainter({required this.active, required this.phase});
  final bool active;
  final double phase;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFFBA0007).withValues(alpha: active ? .9 : .25);
    for (var i = 0; i < 33; i++) {
      final height = active
          ? 7 +
              math.sin(i * .62 + phase * math.pi * 2).abs() *
                  27 *
                  math.sin(i / 32 * math.pi)
          : 5;
      final x = size.width / 34 * (i + 1);
      canvas.drawLine(Offset(x, size.height / 2 - height / 2),
          Offset(x, size.height / 2 + height / 2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SoundWavePainter old) =>
      old.active != active || old.phase != phase;
}

class _RangeGuide extends StatelessWidget {
  const _RangeGuide({required this.isDark, required this.result});
  final bool isDark;
  final Map<String, dynamic>? result;

  String _normalise(String value) {
    final lower = value.toLowerCase();
    if (lower.contains('contralto') || lower.contains('alto')) return 'Alto';
    if (lower.contains('mezzo')) return 'Mezzo';
    if (lower.contains('baritone')) return 'Baritone';
    if (lower.contains('soprano')) return 'Soprano';
    if (lower.contains('tenor')) return 'Tenor';
    return 'Bass';
  }

  Color _rangeColor(String label) => switch (label) {
        'Bass' => const Color(0xFF4D7796),
        'Baritone' => const Color(0xFF796299),
        'Tenor' => const Color(0xFFAA7044),
        'Alto' => const Color(0xFFB04D6B),
        'Mezzo' => const Color(0xFFC05D49),
        _ => const Color(0xFFB33D64),
      };

  @override
  Widget build(BuildContext context) {
    final labels = ['Bass', 'Baritone', 'Tenor', 'Alto', 'Mezzo', 'Soprano'];
    final classification = result?['classification']?.toString() ?? '';
    final primary = _normalise(result?['primary_range']?.toString() ??
        classification.split('/').first);
    final secondaryRaw = result?['secondary_range']?.toString() ??
        result?['blend_with']?.toString() ??
        (classification.contains('/')
            ? classification.split('/').last.replaceAll('mix', '').trim()
            : null);
    final secondary = secondaryRaw == null || secondaryRaw == 'null'
        ? null
        : _normalise(secondaryRaw);
    return Row(
        children: labels.map((label) {
      final isPrimary = label == primary;
      final isSecondary = label == secondary && !isPrimary;
      return Expanded(
          child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Column(children: [
                Container(
                    height: isPrimary
                        ? 42
                        : isSecondary
                            ? 34
                            : 28,
                    decoration: BoxDecoration(
                        color: isPrimary || isSecondary
                            ? _rangeColor(label)
                                .withValues(alpha: isPrimary ? 1 : .58)
                            : (isDark
                                ? const Color(0xFF333333)
                                : const Color(0xFFE8E3E0)),
                        borderRadius: BorderRadius.circular(3))),
                const SizedBox(height: 7),
                Text(label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 9,
                        fontWeight:
                            isPrimary ? FontWeight.w800 : FontWeight.w500))
              ])));
    }).toList());
  }
}

class _ResultPanel extends StatefulWidget {
  const _ResultPanel(
      {required this.result, required this.text, required this.muted});
  final Map<String, dynamic> result;
  final Color text;
  final Color muted;

  @override
  State<_ResultPanel> createState() => _ResultPanelState();
}

class _ResultPanelState extends State<_ResultPanel> {
  late final PageController _artistController;

  @override
  void initState() {
    super.initState();
    _artistController = PageController(viewportFraction: .62);
  }

  @override
  void dispose() {
    _artistController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const artistSongs = {
      'Ariana Grande': 'The Way',
      'Whitney Houston': 'I Have Nothing',
      'Avi Kaplan': 'Change on the Rise',
      'Barry White': "Can't Get Enough of Your Love, Babe",
      'Hozier': 'Take Me to Church',
      'Frank Sinatra': 'Fly Me to the Moon',
      'Bruno Mars': 'Versace on the Floor',
      'Sam Smith': 'Stay With Me',
      'Sade': 'By Your Side',
      'Tracy Chapman': 'Fast Car',
      'Annie Lennox': 'Sweet Dreams',
      'Adele': 'Easy On Me',
      'Lady Gaga': 'Shallow',
    };
    final artists = (widget.result['artists'] as List? ?? const [])
        .map((item) => item.toString())
        .toList();
    return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(17, 16, 17, 14),
        decoration: BoxDecoration(
            color: AppPalette.page(context),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppPalette.border(context))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (artists.isNotEmpty) ...[
            Text('Artists with a similar vocal range',
                style: TextStyle(
                    color: widget.muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            SizedBox(
              height: 230,
              child: PageView.builder(
                controller: _artistController,
                physics: const BouncingScrollPhysics(),
                padEnds: true,
                itemCount: artists.length,
                itemBuilder: (context, index) {
                  final artist = artists[index];
                  return AnimatedBuilder(
                    animation: _artistController,
                    builder: (context, child) {
                      final page = _artistController.hasClients &&
                              _artistController.position.hasContentDimensions
                          ? (_artistController.page ?? 0)
                          : 0.0;
                      final distance = (page - index).abs().clamp(0.0, 1.0);
                      final scale = 1.0 - (distance * .14);
                      return Transform.scale(
                        scale: scale,
                        alignment: Alignment.center,
                        child: child,
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      child: _ArtistReferenceCard(
                        artist: artist,
                        song: artistSongs[artist] ?? 'Similar vocal range',
                        text: widget.text,
                        muted: widget.muted,
                      ),
                    ),
                  );
                },
              ),
            )
          ]
        ]));
  }
}

class _ArtistReferenceCard extends StatelessWidget {
  const _ArtistReferenceCard(
      {required this.artist,
      required this.song,
      required this.text,
      required this.muted});

  final String artist;
  final String song;
  final Color text;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(7),
      decoration: BoxDecoration(
        color: AppPalette.page(context),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: AppPalette.border(context)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: double.infinity,
          height: 136,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppPalette.isDark(context)
                ? const Color(0xFF303030)
                : const Color(0xFFE8E3E0),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Icon(Icons.person_rounded,
              size: 47,
              color: AppPalette.muted(context).withValues(alpha: .65)),
        ),
        const SizedBox(height: 8),
        Text(artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: text, fontSize: 12, fontWeight: FontWeight.w800)),
        const SizedBox(height: 2),
        Text(song,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: muted, fontSize: 10)),
      ]),
    );
  }
}

class _RangeSummary extends StatelessWidget {
  const _RangeSummary(
      {required this.result, required this.text, required this.muted});

  final Map<String, dynamic> result;
  final Color text;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    final classification = result['classification']?.toString() ?? '';
    final primary = result['primary_range']?.toString() ??
        classification.split('/').first.trim();
    final secondary = result['secondary_range']?.toString() ??
        result['blend_with']?.toString() ??
        (classification.contains('/')
            ? classification.split('/').last.replaceAll('mix', '').trim()
            : null);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(primary.isEmpty ? 'Voice range' : primary,
          style: TextStyle(
              color: text, fontSize: 29, fontWeight: FontWeight.w800)),
      if (secondary != null && secondary != 'null') ...[
        const SizedBox(height: 2),
        Text(secondary,
            style: TextStyle(
                color: muted, fontSize: 17, fontWeight: FontWeight.w700)),
      ],
      const SizedBox(height: 6),
      Text('${result['low_note']} to ${result['high_note']}',
          style: const TextStyle(
              color: Color(0xFFBA0007),
              fontWeight: FontWeight.w800,
              fontSize: 15)),
    ]);
  }
}
