import 'package:flutter/material.dart';
import 'dart:math' as math;

class PitchTesterSheet extends StatefulWidget {
  const PitchTesterSheet({Key? key}) : super(key: key);

  @override
  State<PitchTesterSheet> createState() => _PitchTesterSheetState();
}

class _PitchTesterSheetState extends State<PitchTesterSheet> {
  bool _isTesting = false;
  double _currentHz = 165.0;
  String _vocalRange = 'Baritone';
  List<double> _pitchHistory = [];

  final List<Map<String, dynamic>> _ranges = [
    {'name': 'Bass', 'min': 82.0, 'max': 147.0, 'color': Color(0xFF540003)},
    {'name': 'Tenor', 'min': 147.0, 'max': 262.0, 'color': Color(0xFFBA0007)},
    {'name': 'Alto', 'min': 262.0, 'max': 392.0, 'color': Color(0xFFD63031)},
    {'name': 'Soprano', 'min': 392.0, 'max': 880.0, 'color': Color(0xFFFD79A8)},
  ];

  void _toggleTest() {
    setState(() {
      _isTesting = !_isTesting;
      if (_isTesting) {
        _simulateVoiceInput();
      } else {
        _pitchHistory.clear();
      }
    });
  }

  void _simulateVoiceInput() {
    Future.doWhile(() async {
      if (!_isTesting || !mounted) return false;
      await Future.delayed(const Duration(milliseconds: 150));

      final baseRandom = math.Random().nextDouble();
      // Generate vocal frequency values around typical speaking ranges (120 - 350 Hz)
      final double hz = 130 + (baseRandom * 220);

      setState(() {
        _currentHz = hz;
        _pitchHistory.add(hz);
        if (_pitchHistory.length > 30) {
          _pitchHistory.removeAt(0);
        }

        // Identify Vocal Range
        if (hz <= 130) {
          _vocalRange = 'Bass';
        } else if (hz > 130 && hz <= 220) {
          _vocalRange = 'Tenor';
        } else if (hz > 220 && hz <= 340) {
          _vocalRange = 'Alto';
        } else {
          _vocalRange = 'Soprano';
        }
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
                      'VOICE PITCH TEST',
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
                        'Test your singing voice classification and monitor active vocal frequency ranges.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: 'Instrument Sans',
                          color: Colors.black54,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Graphic dynamic waveform tracker box
                      Container(
                        height: 180,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.02),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(24),
                          child: CustomPaint(
                            painter: _WaveformHistoryPainter(
                              history: _pitchHistory,
                              isTesting: _isTesting,
                              accentColor: brandRed,
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 24),

                      // Large Real-time Vocal Range Indicator
                      Text(
                        _isTesting ? _vocalRange.toUpperCase() : 'READY',
                        style: const TextStyle(
                          fontFamily: 'Instrument Sans',
                          fontSize: 48,
                          fontWeight: FontWeight.w900,
                          color: Colors.black,
                          letterSpacing: -1,
                        ),
                      ),
                      Text(
                        _isTesting
                            ? '${_currentHz.toStringAsFixed(1)} Hz'
                            : 'TAP BUTTON AND SING',
                        style: TextStyle(
                          fontFamily: 'Instrument Sans',
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: _isTesting ? brandRed : Colors.grey,
                          letterSpacing: 1.0,
                        ),
                      ),

                      const SizedBox(height: 32),

                      // Vocal Range Scales Grid
                      Column(
                        children: _ranges.map((r) {
                          final isCurrent =
                              _isTesting && _vocalRange == r['name'];
                          return Container(
                            margin: const EdgeInsets.symmetric(vertical: 6),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: isCurrent
                                  ? r['color'].withOpacity(0.08)
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isCurrent
                                    ? r['color']
                                    : Colors.grey.shade200,
                                width: isCurrent ? 2.0 : 1.0,
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  r['name'],
                                  style: TextStyle(
                                    fontFamily: 'Instrument Sans',
                                    fontWeight: FontWeight.w800,
                                    fontSize: 16,
                                    color:
                                        isCurrent ? r['color'] : Colors.black87,
                                  ),
                                ),
                                Text(
                                  '${r['min'].toInt()} - ${r['max'].toInt()} Hz',
                                  style: TextStyle(
                                    fontFamily: 'Instrument Sans',
                                    fontWeight: FontWeight.w600,
                                    color: isCurrent ? r['color'] : Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ),

                      const SizedBox(height: 36),

                      // Action Button
                      GestureDetector(
                        onTap: _toggleTest,
                        child: Container(
                          width: double.infinity,
                          height: 56,
                          decoration: BoxDecoration(
                            gradient: redGradient,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            _isTesting ? 'STOP TEST' : 'START TEST',
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

class _WaveformHistoryPainter extends CustomPainter {
  final List<double> history;
  final bool isTesting;
  final Color accentColor;

  _WaveformHistoryPainter({
    required this.history,
    required this.isTesting,
    required this.accentColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (!isTesting || history.isEmpty) {
      // Draw simulated quiet wave
      final linePaint = Paint()
        ..color = Colors.grey.shade300
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      canvas.drawLine(Offset(0, size.height / 2),
          Offset(size.width, size.height / 2), linePaint);
      return;
    }

    final paint = Paint()
      ..color = accentColor
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path = Path();
    final step = size.width / 30;

    for (int i = 0; i < history.length; i++) {
      // Scale frequency data to height coordinates
      final normalizedH = (history[i] - 80) / 400.0;
      final y = size.height -
          (normalizedH * size.height).clamp(10.0, size.height - 10.0);
      final x = i * step;

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
