import 'dart:math' as math;
import 'dart:ui' show PathMetric;
import 'package:flutter/material.dart';

/// Symbol geometry transcribed from public/augment-logo-vector.svg.
/// The reference film uses only the symbol, not the SVG's text element.
class AugmentLogoMotion extends CustomPainter {
  // Keep playback aligned with the sampled logo phases so the final dot and
  // settle frame are always visible before the app transition begins.
  // Long enough to show every phase, but short enough to keep cold launches
  // feeling immediate. The final dot lands at 1.42 seconds.
  static const duration = Duration(milliseconds: 1580);
  AugmentLogoMotion(this.progress) : super(repaint: progress);
  final Animation<double> progress;

  static final Path _symbol = Path()
    ..moveTo(292, 260)
    ..cubicTo(210, 332, 85, 294, 85, 166)
    ..cubicTo(85, 97, 141, 41, 210, 41)
    ..cubicTo(279, 41, 335, 97, 335, 166)
    ..lineTo(335, 290);
  static final PathMetric _metric = _symbol.computeMetrics().single;

  static double _phase(double seconds, double start, double end) =>
      ((seconds - start) / (end - start)).clamp(0.0, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    final seconds = progress.value * duration.inMilliseconds / 1000;
    // Sampled reference: large stem/arc initially, full bowl by ~1 s,
    // red dot immediately after the settle, followed by a short final hold.
    final draw =
        0.40 + 0.60 * Curves.easeInOutSine.transform(_phase(seconds, 0, 1.05));
    final shrink = Curves.easeInOutCubic.transform(_phase(seconds, 0.25, 1.05));
    final logoScale = 0.49 + (0.23 - 0.49) * shrink;
    final dot = Curves.easeOutCubic.transform(_phase(seconds, 1.28, 1.42));
    // The source mark extends to about y=356 (including the end dot and
    // stroke). Scale it uniformly inside a 540x360 design canvas so a tall
    // phone never crops the final phase of the animation.
    final layoutScale = math.min(size.width / 540, size.height / 360);
    canvas.save();
    canvas.translate((size.width - 540 * layoutScale) / 2,
        (size.height - 360 * layoutScale) / 2);
    canvas.scale(layoutScale);
    canvas.translate(270, 144);
    canvas.scale(logoScale);
    canvas.translate(-276, -177);
    canvas.drawPath(
      _metric.extractPath(_metric.length * (1 - draw), _metric.length),
      Paint()
        ..color = const Color(0xFF202020)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 48
        ..strokeCap = StrokeCap.butt
        ..strokeJoin = StrokeJoin.miter,
    );
    if (dot > 0) {
      canvas.drawCircle(const Offset(408, 286), 31 * dot,
          Paint()..color = const Color(0xFFC81012));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant AugmentLogoMotion oldDelegate) =>
      oldDelegate.progress != progress;
}
