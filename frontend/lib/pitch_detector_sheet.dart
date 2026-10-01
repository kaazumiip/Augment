import 'package:flutter/material.dart';
import 'dart:math' as math;

class PitchDetectorSheet extends StatefulWidget {
  const PitchDetectorSheet({Key? key}) : super(key: key);

  @override
  State<PitchDetectorSheet> createState() => _PitchDetectorSheetState();
}

class _PitchDetectorSheetState extends State<PitchDetectorSheet>
    with SingleTickerProviderStateMixin {
  bool _isListening = false;
  double _frequency = 440.0;
  String _note = 'A';
  late AnimationController _waveController;

  @override
  void initState() {
    super.initState();
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _waveController.dispose();
    super.dispose();
  }

  void _toggleListening() {
    setState(() {
      _isListening = !_isListening;
      if (_isListening) {
        _simulateDetection();
      }
    });
  }

  void _simulateDetection() {
    Future.doWhile(() async {
      if (!_isListening || !mounted) return false;
      await Future.delayed(const Duration(milliseconds: 400));

      final notes = [
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
      final baseFrequencies = [
        261.63,
        277.18,
        293.66,
        311.13,
        329.63,
        349.23,
        369.99,
        392.00,
        415.30,
        440.00,
        466.16,
        493.88
      ];

      final index = math.Random().nextInt(notes.length);
      final offset = (math.Random().nextDouble() * 2) - 1.0;

      setState(() {
        _note = notes[index];
        _frequency =
            double.parse((baseFrequencies[index] + offset).toStringAsFixed(2));
      });

      return true;
    });
  }

  @override
  Widget build(BuildContext context) {
    const Color cardBackground = Color(0xFFFFF9F5);
    const Color brandRed = Color(0xFFBA0007);
    const LinearGradient redGradient = LinearGradient(
      colors: [Color(0xFFBA0007), Color(0xFF540003)],
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
    );

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: cardBackground,
            borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
          ),
          child: Column(
            children: [
              // Pull Bar
              Container(
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                width: 48,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(10),
                ),
              ),

              // Title Header
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 24.0, vertical: 12.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'PITCH DETECTOR',
                      style: TextStyle(
                        fontFamily: 'Instrument Sans',
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        color: brandRed,
                        letterSpacing: 0.5,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.black87),
                      onPressed: () => Navigator.pop(context),
                    )
                  ],
                ),
              ),

              Expanded(
                child: SingleChildScrollView(
                  controller: scrollController,
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  child: Column(
                    children: [
                      const Text(
                        'Accurately identify note values and frequencies from incoming audio signals.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: 'Instrument Sans',
                          color: Colors.black54,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 32),

                      // Large Note Indicator Circle
                      Container(
                        width: 160,
                        height: 160,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                          border: Border.all(
                            color:
                                _isListening ? brandRed : Colors.grey.shade300,
                            width: 3.0,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: (_isListening ? brandRed : Colors.black)
                                  .withOpacity(0.06),
                              blurRadius: 16,
                              offset: const Offset(0, 8),
                            )
                          ],
                        ),
                        alignment: Alignment.center,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              _isListening ? _note : '-',
                              style: TextStyle(
                                fontFamily: 'Instrument Sans',
                                fontSize: 60,
                                fontWeight: FontWeight.w900,
                                color: _isListening ? brandRed : Colors.black38,
                              ),
                            ),
                            if (_isListening)
                              Text(
                                '$_frequency Hz',
                                style: const TextStyle(
                                  fontFamily: 'Instrument Sans',
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.black54,
                                ),
                              ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 48),

                      // Sine wave oscilating live visualizer
                      Container(
                        height: 100,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.02),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(20),
                          child: AnimatedBuilder(
                            animation: _waveController,
                            builder: (context, child) {
                              return CustomPaint(
                                painter: _OscilloscopePainter(
                                  value: _waveController.value,
                                  isListening: _isListening,
                                  waveColor: brandRed,
                                ),
                              );
                            },
                          ),
                        ),
                      ),

                      const SizedBox(height: 48),

                      // Action Button
                      GestureDetector(
                        onTap: _toggleListening,
                        child: Container(
                          width: double.infinity,
                          height: 56,
                          decoration: BoxDecoration(
                            gradient: redGradient,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            _isListening ? 'STOP SCANNING' : 'START SCANNING',
                            style: const TextStyle(
                              fontFamily: 'Instrument Sans',
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 36),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _OscilloscopePainter extends CustomPainter {
  final double value;
  final bool isListening;
  final Color waveColor;

  _OscilloscopePainter({
    required this.value,
    required this.isListening,
    required this.waveColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = isListening ? waveColor : Colors.grey.shade300
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path = Path();
    final width = size.width;
    final height = size.height;
    final midY = height / 2;

    if (!isListening) {
      // flat line with small noise ripples
      path.moveTo(0, midY);
      for (double x = 0; x <= width; x += 5) {
        path.lineTo(x, midY + math.sin(x * 0.1) * 2);
      }
    } else {
      // active oscillating sine wave
      path.moveTo(0, midY);
      for (double x = 0; x <= width; x += 2) {
        final phase = value * 2 * math.pi;
        final y =
            midY + math.sin((x / width) * 4 * math.pi + phase) * (height * 0.3);
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
