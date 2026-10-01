import 'package:flutter/material.dart';
import 'main.dart';

/// Animated splash screen built with the exact vector geometry from augment-logo-vector.svg
/// and the official brand motion choreography.
class SplashScreen extends StatefulWidget {
  const SplashScreen({
    super.key,
    this.nextScreen,
    this.animationDuration = const Duration(milliseconds: 2600),
  });

  final Widget? nextScreen;
  final Duration animationDuration;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _strokeDraw;
  late final Animation<double> _logoScale;
  late final Animation<double> _textOpacity;
  late final Animation<double> _textSlide;
  late final Animation<double> _dotScale;
  late final Animation<double> _fadeExit;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: widget.animationDuration,
    );

    // 1. Exact stroke path drawing of the "a" glyph (0.00 to 0.46 progress)
    _strokeDraw = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.00, 0.46, curve: Curves.easeInOutCubic),
      ),
    );

    // 2. Logo settle scale (starts slightly larger and locks into place)
    _logoScale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.15, end: 0.96)
            .chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 60.0,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.96, end: 1.00)
            .chain(CurveTween(curve: Curves.easeOutQuad)),
        weight: 40.0,
      ),
    ]).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.00, 0.48),
      ),
    );

    // 3. Wordmark "augment" slide & fade reveal (0.35 to 0.65 progress)
    _textOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.35, 0.62, curve: Curves.easeOut),
      ),
    );

    _textSlide = Tween<double>(begin: 18.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.35, 0.65, curve: Curves.easeOutCubic),
      ),
    );

    // 4. Red dot elastic pop & overshoot (0.65 to 0.93 progress)
    _dotScale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.0, end: 1.45)
            .chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 55.0,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.45, end: 0.90)
            .chain(CurveTween(curve: Curves.easeInOutSine)),
        weight: 25.0,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.90, end: 1.0)
            .chain(CurveTween(curve: Curves.easeOutQuad)),
        weight: 20.0,
      ),
    ]).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.65, 0.93),
      ),
    );

    // 5. Clean exit transition fade
    _fadeExit = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.96, 1.0, curve: Curves.easeOut),
      ),
    );

    _controller.forward().then((_) {
      if (mounted) {
        _navigateToNext();
      }
    });
  }

  void _navigateToNext() {
    final next = widget.nextScreen ?? const AuthGate();
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => next,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? Colors.black : const Color(0xFFFFF9F5);
    final fgColor = isDark ? Colors.white : const Color(0xFF202020);

    return Scaffold(
      backgroundColor: bgColor,
      body: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Opacity(
            opacity: _fadeExit.value.clamp(0.0, 1.0),
            child: Center(
              child: SizedBox(
                width: 260,
                height: 230,
                child: CustomPaint(
                  painter: AugmentExactVectorPainter(
                    strokeDraw: _strokeDraw.value,
                    logoScale: _logoScale.value,
                    dotScale: _dotScale.value,
                    textOpacity: _textOpacity.value,
                    textSlide: _textSlide.value,
                    fgColor: fgColor,
                    dotColor: const Color(0xFFC81012),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// CustomPainter rendering the exact SVG vector geometry from augment-logo-vector.svg
/// viewBox: 0 0 600 530
class AugmentExactVectorPainter extends CustomPainter {
  AugmentExactVectorPainter({
    required this.strokeDraw,
    required this.logoScale,
    required this.dotScale,
    required this.textOpacity,
    required this.textSlide,
    this.fgColor = const Color(0xFF202020),
    this.dotColor = const Color(0xFFC81012),
  });

  final double strokeDraw;
  final double logoScale;
  final double dotScale;
  final double textOpacity;
  final double textSlide;
  final Color fgColor;
  final Color dotColor;

  static const double nativeWidth = 600.0;
  static const double nativeHeight = 530.0;

  @override
  void paint(Canvas canvas, Size size) {
    final double scale = size.width / nativeWidth;
    final double dx = (size.width - nativeWidth * scale) / 2;
    final double dy = (size.height - nativeHeight * scale) / 2;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(scale, scale);

    // 1. Draw animated top symbol: "a."
    // Group transform: translate(66, 20)
    // Center of symbol within native 600x530 is approx (300, 185)
    canvas.save();
    const double symbolCenterX = 300.0;
    const double symbolCenterY = 185.0;
    canvas.translate(symbolCenterX, symbolCenterY);
    canvas.scale(logoScale, logoScale);
    canvas.translate(-symbolCenterX, -symbolCenterY);

    canvas.save();
    canvas.translate(66.0, 20.0);

    // Full path definition: M292 260 C210 332 85 294 85 166 C85 97 141 41 210 41 C279 41 335 97 335 166 L335 290
    final fullPath = Path()
      ..moveTo(292.0, 260.0)
      ..cubicTo(210.0, 332.0, 85.0, 294.0, 85.0, 166.0)
      ..cubicTo(85.0, 97.0, 141.0, 41.0, 210.0, 41.0)
      ..cubicTo(279.0, 41.0, 335.0, 97.0, 335.0, 166.0)
      ..lineTo(335.0, 290.0);

    if (strokeDraw > 0.0) {
      final strokePaint = Paint()
        ..color = fgColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 48.0
        ..strokeCap = StrokeCap.butt
        ..strokeJoin = StrokeJoin.miter
        ..isAntiAlias = true;

      if (strokeDraw >= 1.0) {
        canvas.drawPath(fullPath, strokePaint);
      } else {
        final animatedPath = Path();
        for (final metric in fullPath.computeMetrics()) {
          final extractLen = metric.length * strokeDraw.clamp(0.0, 1.0);
          animatedPath.addPath(
            metric.extractPath(0.0, extractLen),
            Offset.zero,
          );
        }
        canvas.drawPath(animatedPath, strokePaint);
      }
    }

    // Draw Red Dot (cx: 408, cy: 286, r: 27)
    if (dotScale > 0.0) {
      final dotPaint = Paint()
        ..color = dotColor
        ..style = PaintingStyle.fill
        ..isAntiAlias = true;

      canvas.save();
      canvas.translate(408.0, 286.0);
      canvas.scale(dotScale, dotScale);
      canvas.drawCircle(Offset.zero, 27.0, dotPaint);
      canvas.restore();
    }

    canvas.restore(); // restore translate(66, 20)
    canvas.restore(); // restore symbol scale

    // 2. Draw animated wordmark "augment"
    // text: x=300, y=432, anchor=middle, font-size=64, font-weight=600, letter-spacing=20
    if (textOpacity > 0.0) {
      final textPainter = TextPainter(
        text: TextSpan(
          text: 'augment',
          style: TextStyle(
            fontFamily: 'Instrument Sans',
            fontSize: 64.0,
            fontWeight: FontWeight.w600,
            letterSpacing: 20.0,
            color: fgColor.withValues(alpha: textOpacity.clamp(0.0, 1.0)),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final double textX = 300.0 -
          (textPainter.width / 2) +
          10.0; // compensate trailing letter spacing
      final double textY = 432.0 -
          textPainter.computeDistanceToActualBaseline(TextBaseline.alphabetic) +
          textSlide;

      textPainter.paint(canvas, Offset(textX, textY));
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant AugmentExactVectorPainter oldDelegate) {
    return oldDelegate.strokeDraw != strokeDraw ||
        oldDelegate.logoScale != logoScale ||
        oldDelegate.dotScale != dotScale ||
        oldDelegate.textOpacity != textOpacity ||
        oldDelegate.textSlide != textSlide ||
        oldDelegate.fgColor != fgColor ||
        oldDelegate.dotColor != dotColor;
  }
}
