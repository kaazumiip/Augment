import 'dart:math';
import 'package:flutter/material.dart';
import 'generation_state.dart';
import 'music_sheet_page.dart';
import 'app_logo.dart';

class LoadingPage extends StatefulWidget {
  final String instrumentName;
  final String source;
  final String? fileUrl;
  final String? filePath;

  const LoadingPage({
    Key? key,
    required this.instrumentName,
    required this.source,
    this.fileUrl,
    this.filePath,
  }) : super(key: key);

  @override
  State<LoadingPage> createState() => _LoadingPageState();
}

class _LoadingPageState extends State<LoadingPage>
    with TickerProviderStateMixin {
  late final AnimationController _waveController;
  late final AnimationController _dotController;
  bool _showWaves = false;
  late final GenerationState _genState;

  @override
  void initState() {
    super.initState();
    _genState = GenerationState.instance;
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    _dotController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat();

    Future.delayed(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _showWaves = true);
      _waveController.repeat();
    });

    _genState.addListener(_onStateChange);

    if (!_genState.isGenerating && !_genState.isFinished) {
      _genState.startGeneration(
        instrumentName: widget.instrumentName,
        source: widget.source,
        fileUrl: widget.fileUrl,
        filePath: widget.filePath,
      );
    }
  }

  void _onStateChange() {
    if (!mounted) return;

    if (_genState.isFinished && _genState.result != null) {
      _genState.removeListener(_onStateChange);
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => MusicSheetPage(
            instrumentName: widget.instrumentName,
            apiResult: _genState.result,
          ),
        ),
      );
    } else if (_genState.hasError) {
      setState(() {});
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _genState.removeListener(_onStateChange);
    _waveController.dispose();
    _dotController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const Color backgroundColor = Color(0xFFFAF5F1);
    const Color brandRed = Color(0xFFBA0007);

    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallScreen = screenWidth < 360;

    return Scaffold(
      backgroundColor: backgroundColor,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned(
              top: 8,
              left: 0,
              child: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new,
                    color: Colors.black54, size: 20),
                onPressed: () => Navigator.pop(context),
              ),
            ),
            Center(
              child: _genState.hasError
                  ? _buildError(brandRed, isSmallScreen)
                  : _buildLoading(brandRed, isSmallScreen),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError(Color brandRed, bool isSmallScreen) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          _genState.generationLimitReached
              ? Icons.music_off_rounded
              : Icons.error_outline,
          size: 64,
          color: brandRed,
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            _genState.generationLimitReached
                ? 'Generation limit reached'
                : 'Generation failed',
            style: TextStyle(
              fontFamily: 'Instrument Sans',
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: Colors.black,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            _genState.errorMsg ?? 'Unknown error',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Instrument Sans',
              fontSize: 14,
              color: Colors.grey.shade600,
            ),
          ),
        ),
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: () {
            _genState.clearResult();
            Navigator.pop(context);
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: brandRed,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
          ),
          child: const Text(
            'Go Back',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLoading(Color brandRed, bool isSmallScreen) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 300,
          height: 300,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (_showWaves)
                AnimatedBuilder(
                  animation: _waveController,
                  builder: (context, child) {
                    return CustomPaint(
                      size: const Size(300, 300),
                      painter: _SoundWavePainter(
                        animation: _waveController.value,
                        color: brandRed,
                      ),
                    );
                  },
                ),
              AppLogo(
                width: isSmallScreen ? 34 : 43,
                height: isSmallScreen ? 22 : 28,
              ),
              Positioned(
                bottom: 60,
                child: AnimatedBuilder(
                  animation: _dotController,
                  builder: (context, child) {
                    final dotCount = ((_dotController.value * 6).floor() % 6);
                    final dots = '.' * dotCount;
                    final status =
                        _genState.statusText.replaceAll(RegExp(r'\.+$'), '');
                    final percent = (_genState.progress * 100).round();
                    final steps = [
                      'Prepare audio',
                      'Separate instruments',
                      'Transcribe MIDI',
                      'Write sheet music',
                      'Render instrument sound',
                    ];
                    final statusLower = status.toLowerCase();
                    final activeStep = statusLower.contains('render')
                        ? 4
                        : statusLower.contains('clean') ||
                                statusLower.contains('engraving')
                            ? 3
                            : statusLower.contains('transcrib')
                                ? 2
                                : statusLower.contains('separat')
                                    ? 1
                                    : 0;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          status + dots,
                          style: TextStyle(
                            fontFamily: 'Instrument Sans',
                            fontSize: isSmallScreen ? 14 : 16,
                            fontWeight: FontWeight.w600,
                            color: brandRed,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Estimated progress: $percent%',
                          style: TextStyle(
                            fontFamily: 'Instrument Sans',
                            fontSize: isSmallScreen ? 11 : 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.black54,
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: isSmallScreen ? 205 : 235,
                          child: Column(
                            children: List.generate(steps.length, (index) {
                              final complete = index < activeStep;
                              final active = index == activeStep;
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: 20,
                                    child: Column(
                                      children: [
                                        Container(
                                          width: isSmallScreen ? 14 : 16,
                                          height: isSmallScreen ? 14 : 16,
                                          decoration: BoxDecoration(
                                            color: complete || active
                                                ? brandRed
                                                : Colors.white,
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: complete || active
                                                  ? brandRed
                                                  : Colors.black26,
                                              width: 1.5,
                                            ),
                                          ),
                                          child: complete
                                              ? Icon(Icons.check,
                                                  size: isSmallScreen ? 10 : 12,
                                                  color: Colors.white)
                                              : active
                                                  ? Icon(Icons.more_horiz,
                                                      size: isSmallScreen
                                                          ? 10
                                                          : 12,
                                                      color: Colors.white)
                                                  : null,
                                        ),
                                        if (index < steps.length - 1)
                                          Container(
                                            width: 1.5,
                                            height: isSmallScreen ? 13 : 16,
                                            color: complete
                                                ? brandRed
                                                : Colors.black12,
                                          ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 9),
                                  Padding(
                                    padding: const EdgeInsets.only(top: 1),
                                    child: Text(
                                      steps[index],
                                      style: TextStyle(
                                        fontFamily: 'Instrument Sans',
                                        fontSize: isSmallScreen ? 11 : 12,
                                        fontWeight: active
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                        color: active
                                            ? Colors.black87
                                            : Colors.black54,
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            }),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SoundWavePainter extends CustomPainter {
  final double animation;
  final Color color;

  _SoundWavePainter({required this.animation, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width * 1.2;
    final int waveCount = 2;

    for (int i = 0; i < waveCount; i++) {
      final phase = (animation + i / waveCount) % 1.0;
      final radius = phase * maxRadius;
      final opacity = (1.0 - phase).clamp(0.0, 1.0);

      if (opacity <= 0.01 || radius < 1) continue;

      final paint = Paint()
        ..color = color.withValues(alpha: opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;

      final path = Path();
      final int segments = 60;
      final double wiggleAmplitude = 0.8;
      final double wiggleFrequency = 6.0;

      for (int j = 0; j <= segments; j++) {
        final angle = (j / segments) * 2 * pi;
        final wiggle =
            sin(angle * wiggleFrequency + phase * 2 * pi) * wiggleAmplitude;
        final r = radius + wiggle;
        final point = Offset(
          center.dx + r * cos(angle),
          center.dy + r * sin(angle),
        );
        if (j == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      path.close();
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_SoundWavePainter oldDelegate) =>
      oldDelegate.animation != animation;
}
