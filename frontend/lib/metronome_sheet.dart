import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math' as math;

class MetronomeSheet extends StatefulWidget {
  const MetronomeSheet({Key? key}) : super(key: key);

  @override
  State<MetronomeSheet> createState() => _MetronomeSheetState();
}

class _MetronomeSheetState extends State<MetronomeSheet>
    with SingleTickerProviderStateMixin {
  int _bpm = 120;
  bool _isPlaying = false;
  int _beats = 4;
  int _currentBeat = 0;
  Timer? _timer;

  late AnimationController _pendulumController;
  late Animation<double> _pendulumAnimation;

  @override
  void initState() {
    super.initState();
    _pendulumController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: _calculateDurationMs(_bpm)),
    );

    _pendulumAnimation = Tween<double>(
      begin: -0.5,
      end: 0.5,
    ).animate(CurvedAnimation(
      parent: _pendulumController,
      curve: Curves.easeInOut,
    ));

    _pendulumController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _pendulumController.reverse();
        _onTick();
      } else if (status == AnimationStatus.dismissed) {
        _pendulumController.forward();
        _onTick();
      }
    });
  }

  int _calculateDurationMs(int bpm) {
    return (60000 / bpm).round();
  }

  void _onTick() {
    if (!mounted) return;
    setState(() {
      _currentBeat = (_currentBeat + 1) % _beats;
    });
  }

  void _togglePlayback() {
    setState(() {
      _isPlaying = !_isPlaying;
      if (_isPlaying) {
        _pendulumController.duration =
            Duration(milliseconds: _calculateDurationMs(_bpm));
        _pendulumController.forward();
      } else {
        _pendulumController.stop();
        _currentBeat = 0;
      }
    });
  }

  void _updateBpm(int val) {
    setState(() {
      _bpm = val.clamp(40, 240);
      if (_isPlaying) {
        _pendulumController.duration =
            Duration(milliseconds: _calculateDurationMs(_bpm));
        // Reset/continue animation speed
        if (!_pendulumController.isAnimating) {
          _pendulumController.forward();
        }
      }
    });
  }

  // Tap Tempo Logic
  List<DateTime> _tapTimes = [];
  void _onTapTempo() {
    final now = DateTime.now();
    _tapTimes.add(now);
    if (_tapTimes.length > 4) {
      _tapTimes.removeAt(0);
    }
    if (_tapTimes.length >= 2) {
      double totalDiff = 0;
      for (int i = 0; i < _tapTimes.length - 1; i++) {
        totalDiff += _tapTimes[i + 1].difference(_tapTimes[i]).inMilliseconds;
      }
      final averageDiff = totalDiff / (_tapTimes.length - 1);
      final calculatedBpm = (60000 / averageDiff).round();
      _updateBpm(calculatedBpm);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pendulumController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Colors matching user specs
    const Color cardBackground = Color(0xFFFFF9F5);
    const Color brandRed = Color(0xFFBA0007);
    const LinearGradient headerGradient = LinearGradient(
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
              // Header Drag Handle
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
                      'METRONOME',
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
                      // Pendulum Display
                      Container(
                        height: 200,
                        width: double.infinity,
                        margin: const EdgeInsets.symmetric(vertical: 16),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.03),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: AnimatedBuilder(
                          animation: _pendulumAnimation,
                          builder: (context, child) {
                            return CustomPaint(
                              painter: _MetronomePendulumPainter(
                                angle:
                                    _isPlaying ? _pendulumAnimation.value : 0.0,
                                currentBeat: _currentBeat,
                                totalBeats: _beats,
                                accentColor: brandRed,
                              ),
                            );
                          },
                        ),
                      ),

                      // Beat Indicator lights
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(_beats, (index) {
                          final isActive = _isPlaying && _currentBeat == index;
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 100),
                            margin: const EdgeInsets.symmetric(horizontal: 6),
                            width: isActive ? 16 : 10,
                            height: isActive ? 16 : 10,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isActive ? brandRed : Colors.grey.shade300,
                              boxShadow: isActive
                                  ? [
                                      BoxShadow(
                                        color: brandRed.withOpacity(0.6),
                                        blurRadius: 10,
                                        spreadRadius: 2,
                                      )
                                    ]
                                  : null,
                            ),
                          );
                        }),
                      ),

                      const SizedBox(height: 32),

                      // BPM Value and Info Display
                      Text(
                        '$_bpm',
                        style: const TextStyle(
                          fontFamily: 'Instrument Sans',
                          fontSize: 84,
                          fontWeight: FontWeight.w900,
                          color: Colors.black,
                          letterSpacing: -2,
                          height: 1,
                        ),
                      ),
                      const Text(
                        'BPM',
                        style: TextStyle(
                          fontFamily: 'Instrument Sans',
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Colors.grey,
                          letterSpacing: 2,
                        ),
                      ),

                      const SizedBox(height: 16),

                      // Slider & +/- adjustment buttons
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.remove_circle_outline,
                                size: 32),
                            onPressed: () => _updateBpm(_bpm - 1),
                          ),
                          Expanded(
                            child: SliderTheme(
                              data: SliderThemeData(
                                activeTrackColor: brandRed,
                                inactiveTrackColor: Colors.grey.shade300,
                                thumbColor: brandRed,
                                overlayColor: brandRed.withOpacity(0.12),
                                trackHeight: 6,
                              ),
                              child: Slider(
                                value: _bpm.toDouble(),
                                min: 40,
                                max: 240,
                                onChanged: (value) => _updateBpm(value.toInt()),
                              ),
                            ),
                          ),
                          IconButton(
                            icon:
                                const Icon(Icons.add_circle_outline, size: 32),
                            onPressed: () => _updateBpm(_bpm + 1),
                          ),
                        ],
                      ),

                      const SizedBox(height: 24),

                      // Play/Pause & Tap Tempo Controls
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          // Tap Tempo Button
                          OutlinedButton(
                            onPressed: _onTapTempo,
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(
                                  color: Colors.black26, width: 1.5),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 24, vertical: 16),
                            ),
                            child: const Text(
                              'TAP TEMPO',
                              style: TextStyle(
                                fontFamily: 'Instrument Sans',
                                color: Colors.black87,
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),

                          // Floating Play Action
                          GestureDetector(
                            onTap: _togglePlayback,
                            child: Container(
                              width: 80,
                              height: 80,
                              decoration: BoxDecoration(
                                gradient: headerGradient,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: brandRed.withOpacity(0.35),
                                    blurRadius: 18,
                                    offset: const Offset(0, 8),
                                  )
                                ],
                              ),
                              child: Icon(
                                _isPlaying ? Icons.pause : Icons.play_arrow,
                                color: Colors.white,
                                size: 40,
                              ),
                            ),
                          ),

                          // Beats setup
                          PopupMenuButton<int>(
                            initialValue: _beats,
                            onSelected: (val) {
                              setState(() {
                                _beats = val;
                                _currentBeat = 0;
                              });
                            },
                            child: Container(
                              decoration: BoxDecoration(
                                border: Border.all(
                                    color: Colors.black26, width: 1.5),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 16),
                              child: Text(
                                '$_beats / 4',
                                style: const TextStyle(
                                  fontFamily: 'Instrument Sans',
                                  color: Colors.black87,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            itemBuilder: (context) => [
                              for (int i in [2, 3, 4, 6, 8])
                                PopupMenuItem(
                                  value: i,
                                  child: Text('$i / 4 Time'),
                                )
                            ],
                          ),
                        ],
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

class _MetronomePendulumPainter extends CustomPainter {
  final double angle;
  final int currentBeat;
  final int totalBeats;
  final Color accentColor;

  _MetronomePendulumPainter({
    required this.angle,
    required this.currentBeat,
    required this.totalBeats,
    required this.accentColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.85);
    final length = size.height * 0.7;

    // Draw background scale/lines
    final scalePaint = Paint()
      ..color = Colors.black12
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    for (double i = -0.5; i <= 0.5; i += 0.25) {
      final dx = math.sin(i) * length;
      final dy = math.cos(i) * length;
      canvas.drawLine(
        center,
        Offset(center.dx + dx, center.dy - dy),
        scalePaint,
      );
    }

    // Pendulum weight anchor pivot
    final pivotPaint = Paint()
      ..color = Colors.grey.shade400
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 8, pivotPaint);

    // Calculate pendulum rod end coordinates
    final rx = math.sin(angle) * length;
    final ry = math.cos(angle) * length;
    final endPoint = Offset(center.dx + rx, center.dy - ry);

    // Draw pendulum rod
    final rodPaint = Paint()
      ..color = Colors.black87
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke;
    canvas.drawLine(center, endPoint, rodPaint);

    // Draw pendulum sliding weight
    final weightDist = length * 0.65;
    final wx = math.sin(angle) * weightDist;
    final wy = math.cos(angle) * weightDist;
    final weightPoint = Offset(center.dx + wx, center.dy - wy);

    final weightPaint = Paint()
      ..color = accentColor
      ..style = PaintingStyle.fill;

    // Draw trapezoidal weight
    final wPath = Path()
      ..moveTo(weightPoint.dx - 12, weightPoint.dy + 8)
      ..lineTo(weightPoint.dx + 12, weightPoint.dy + 8)
      ..lineTo(weightPoint.dx + 8, weightPoint.dy - 8)
      ..lineTo(weightPoint.dx - 8, weightPoint.dy - 8)
      ..close();
    canvas.drawPath(wPath, weightPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
