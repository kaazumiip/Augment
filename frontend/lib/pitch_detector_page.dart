import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_palette.dart';

class PitchDetectorPage extends StatefulWidget {
  const PitchDetectorPage({super.key});

  @override
  State<PitchDetectorPage> createState() => _PitchDetectorPageState();
}

class _PitchDetectorPageState extends State<PitchDetectorPage>
    with SingleTickerProviderStateMixin {
  static const _notes = [
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
  late final AnimationController _motion;
  Timer? _timer;
  bool _listening = false;
  int _noteIndex = 9;

  @override
  void initState() {
    super.initState();
    _motion = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1050))
      ..repeat();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _motion.dispose();
    super.dispose();
  }

  void _toggleListening() {
    setState(() => _listening = !_listening);
    _timer?.cancel();
    if (_listening) {
      _timer = Timer.periodic(const Duration(milliseconds: 560), (_) {
        if (mounted)
          setState(() => _noteIndex =
              (_noteIndex + 1 + math.Random().nextInt(3)) % _notes.length);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = AppPalette.text(context);
    final muted = AppPalette.muted(context);
    final note = _listening ? _notes[_noteIndex] : '--';
    return Scaffold(
      backgroundColor: AppPalette.page(context),
      body: SafeArea(
          child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
                TextSpan(text: 'Pitch detector'),
                TextSpan(text: ' .', style: TextStyle(color: Color(0xFFBA0007)))
              ])),
          const SizedBox(height: 7),
          Text('Listen for the note you are playing or singing.',
              style: TextStyle(color: muted, fontSize: 14)),
          const Spacer(),
          Center(
              child: AnimatedBuilder(
                  animation: _motion,
                  builder: (_, __) => _Dial(
                      note: note,
                      active: _listening,
                      phase: _motion.value,
                      text: text))),
          const SizedBox(height: 20),
          _NoteOnlyCard(note: note),
          const SizedBox(height: 20),
          AnimatedBuilder(
              animation: _motion,
              builder: (_, __) =>
                  _Wave(active: _listening, phase: _motion.value)),
          const Spacer(),
          SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton.icon(
                  onPressed: _toggleListening,
                  icon:
                      Icon(_listening ? Icons.stop_rounded : Icons.mic_rounded),
                  label:
                      Text(_listening ? 'Stop listening' : 'Start listening'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFBA0007),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(9))))),
        ]),
      )),
    );
  }
}

class _Dial extends StatelessWidget {
  const _Dial(
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
      width: 270,
      height: 270,
      child: CustomPaint(
        painter: _DialPainter(active: active, phase: phase, text: text),
        child: Center(
            child: Container(
                width: 88,
                height: 88,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: active
                        ? const Color(0xFF242424)
                        : AppPalette.surface(context)),
                child: Text(note,
                    style: TextStyle(
                        color: active ? const Color(0xFFE0181B) : text,
                        fontSize: 27,
                        fontWeight: FontWeight.w800)))),
      ));
}

class _DialPainter extends CustomPainter {
  _DialPainter({required this.active, required this.phase, required this.text});
  final bool active;
  final double phase;
  final Color text;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 5;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = const Color(0xFFBA0007).withValues(alpha: active ? .34 : .15);
    canvas.drawCircle(center, radius, ring);
    canvas.drawCircle(center, radius * .6,
        ring..color = const Color(0xFFBA0007).withValues(alpha: .1));
    if (active)
      canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius * .79),
          -2.65,
          .58,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 23
            ..color = const Color(0xFFDF161B).withValues(
                alpha: .65 + .25 * math.sin(phase * math.pi * 2).abs()));
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
          Paint()..color = const Color(0xFFBA0007).withValues(alpha: .1));
      final position =
          center + Offset(math.cos(angle), math.sin(angle)) * radius * .84;
      final tp = TextPainter(
          text: TextSpan(
              text: notes[i],
              style: TextStyle(
                  color: text, fontSize: 16, fontWeight: FontWeight.w600)),
          textDirection: TextDirection.ltr)
        ..layout();
      tp.paint(canvas, position - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _DialPainter old) =>
      active != old.active || phase != old.phase || text != old.text;
}

class _NoteOnlyCard extends StatelessWidget {
  const _NoteOnlyCard({required this.note});
  final String note;
  @override
  Widget build(BuildContext context) => Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 15),
      decoration: BoxDecoration(
          color: AppPalette.surface(context),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppPalette.border(context))),
      child: Column(children: [
        const Text('NOTE',
            style: TextStyle(
                color: Color(0xFFBA0007),
                fontSize: 10,
                fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(note,
            style: TextStyle(
                color: note == '--'
                    ? AppPalette.muted(context)
                    : AppPalette.text(context),
                fontSize: 25,
                fontWeight: FontWeight.w800))
      ]));
}

class _Wave extends StatelessWidget {
  const _Wave({required this.active, required this.phase});
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
      child: CustomPaint(painter: _WavePainter(active: active, phase: phase)));
}

class _WavePainter extends CustomPainter {
  _WavePainter({required this.active, required this.phase});
  final bool active;
  final double phase;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFFBA0007).withValues(alpha: active ? .9 : .24);
    for (var i = 0; i < 33; i++) {
      final h = active
          ? 7 +
              math.sin(i * .62 + phase * math.pi * 2).abs() *
                  26 *
                  math.sin(i / 32 * math.pi)
          : 5;
      final x = size.width / 34 * (i + 1);
      canvas.drawLine(Offset(x, size.height / 2 - h / 2),
          Offset(x, size.height / 2 + h / 2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      active != old.active || phase != old.phase;
}
