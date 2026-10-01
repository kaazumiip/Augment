import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';

import 'app_palette.dart';

const int _minTempoBpm = 1;
const int _maxTempoBpm = 320;

class _RipplePulse {
  _RipplePulse({required this.controller, required this.colorIndex});

  final AnimationController controller;
  final int colorIndex;
}

class _RippleWave {
  const _RippleWave({required this.progress, required this.color});

  final double progress;
  final Color color;
}

class MetronomePage extends StatefulWidget {
  const MetronomePage({Key? key}) : super(key: key);

  @override
  State<MetronomePage> createState() => _MetronomePageState();
}

class _MetronomePageState extends State<MetronomePage>
    with TickerProviderStateMixin {
  int _bpm = 150;
  bool _isPlaying = false;
  bool _isTapMode = false;
  int _beats = 4;
  int _timeSignatureDenominator = 4;
  int _subdivision = 1;
  int _soundStyle = 0;
  int _activeBeat = 1;
  int _rippleColorIndex = 6;
  int _beatInMeasure = 1;
  int _subBeat = 0;
  bool _lastPulseWasAccent = true;
  double _volume = 0.8;
  Timer? _timer;
  Timer? _playStartTimer;
  var _runToken = 0;
  bool _transportStarted = false;
  final Stopwatch _transportClock = Stopwatch();
  int _nextTickAtMs = 0;
  final List<DateTime> _tapTimes = [];
  AudioPool? _clickPool;
  AudioPool? _accentPool;
  late Future<void> _audioSetup;
  late final AnimationController _beatPulseController;
  final List<_RipplePulse> _ripples = [];

  @override
  void initState() {
    super.initState();
    _beatPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 860),
    );
    _audioSetup = _prepareClickAudio();
  }

  int _calculateDurationMs(int bpm) => (60000 / bpm).round();

  void _onTick() {
    if (!mounted) return;
    final beat = _beatInMeasure;
    final isMainBeat = _subBeat == 0;
    final isAccent = isMainBeat && beat == 1;
    _lastPulseWasAccent = isAccent;
    // Keep the visual release attached to this beat instead of running as an
    // unrelated loop at a fixed speed.
    final beatLength = _calculateDurationMs(_bpm);
    if (isMainBeat) {
      _beatPulseController.duration = Duration(
        milliseconds: (beatLength * 0.92).round().clamp(180, 920),
      );
      _beatPulseController.forward(from: 0);
      final ripple = _RipplePulse(
        controller: AnimationController(
          vsync: this,
          duration: Duration(
            milliseconds: (beatLength * 3.2).round().clamp(950, 2600),
          ),
        ),
        colorIndex: (_rippleColorIndex + 1) % 7,
      );
      ripple.controller.addStatusListener((status) {
        if (status != AnimationStatus.completed) return;
        if (mounted) {
          setState(() => _ripples.remove(ripple));
        }
        ripple.controller.dispose();
      });
      _ripples.add(ripple);
      ripple.controller.forward();
    }
    setState(() {
      if (isMainBeat) {
        _activeBeat = beat;
        _rippleColorIndex = (_rippleColorIndex + 1) % 7;
        _beatInMeasure = beat >= _beats ? 1 : beat + 1;
      }
      _subBeat = (_subBeat + 1) % _subdivision;
    });
    _playClick(accent: isAccent, subdivision: !isMainBeat);
  }

  void _togglePlayback() {
    if (_isPlaying) {
      _playStartTimer?.cancel();
      _stopMetronome();
      setState(() {
        _isPlaying = false;
        _transportStarted = false;
      });
    } else {
      setState(() => _isPlaying = true);
      // Let the dial complete its physical move before the first pulse is
      // released. This avoids exposing the oversized ripple canvas mid-morph.
      _playStartTimer?.cancel();
      _playStartTimer = Timer(const Duration(milliseconds: 520), () {
        if (!mounted || !_isPlaying) return;
        setState(() => _transportStarted = true);
        _startMetronome();
      });
    }
  }

  void _startMetronome() {
    _runToken++;
    _timer?.cancel();
    _transportClock
      ..reset()
      ..start();
    _beatInMeasure = 1;
    _subBeat = 0;
    _activeBeat = 1;
    _onTick();
    _nextTickAtMs = _tickDurationMs;
    _scheduleNextTick(_runToken);
  }

  void _scheduleNextTick(int token) {
    final delayMs =
        math.max(0, _nextTickAtMs - _transportClock.elapsedMilliseconds);
    _timer = Timer(Duration(milliseconds: delayMs), () {
      if (!_isPlaying || token != _runToken) return;
      _onTick();
      final interval = _tickDurationMs;
      _nextTickAtMs += interval;
      // Preserve the musical clock if the OS delivers a callback late.
      while (_nextTickAtMs <= _transportClock.elapsedMilliseconds) {
        _nextTickAtMs += interval;
      }
      _scheduleNextTick(token);
    });
  }

  void _stopMetronome() {
    _runToken++;
    _timer?.cancel();
    _timer = null;
    _transportClock.stop();
    _beatInMeasure = 1;
    _subBeat = 0;
    _activeBeat = 1;
  }

  void _updateBpm(int val) {
    final nextBpm = val.clamp(_minTempoBpm, _maxTempoBpm);
    setState(() => _bpm = nextBpm);
    if (_isPlaying) {
      _startMetronome();
    }
  }

  void _updateTimeSignature(_TimeSignature signature) {
    setState(() {
      _beats = signature.numerator;
      _timeSignatureDenominator = signature.denominator;
      _beatInMeasure = 1;
      _activeBeat = 1;
      _subBeat = 0;
    });
    if (_isPlaying) {
      _startMetronome();
    }
  }

  int get _tickDurationMs =>
      math.max(1, (_calculateDurationMs(_bpm) / _subdivision).round());

  void _updateSubdivision(int subdivision) {
    setState(() {
      _subdivision = subdivision.clamp(1, 4);
      _subBeat = 0;
    });
    if (_isPlaying) {
      _startMetronome();
    }
  }

  void _updateVolume(double val) {
    setState(() => _volume = val.clamp(0.0, 1.0));
  }

  void _updateSoundStyle(int style) {
    if (style == _soundStyle) return;
    setState(() => _soundStyle = style);
    _audioSetup = _prepareClickAudio();
  }

  Future<void> _prepareClickAudio() async {
    final clickAsset = switch (_soundStyle) {
      1 => 'audio/wood_click.wav',
      2 => 'audio/bell_click.wav',
      3 => 'audio/snap_click.wav',
      4 => 'audio/digital_click.wav',
      5 => 'audio/clave_click.wav',
      6 => 'audio/tap_click.wav',
      7 => 'audio/soft_click.wav',
      8 => 'audio/knock_click.wav',
      _ => 'audio/click.wav',
    };
    final accentAsset = switch (_soundStyle) {
      1 => 'audio/wood_accent.wav',
      2 => 'audio/bell_accent.wav',
      3 => 'audio/snap_accent.wav',
      4 => 'audio/digital_accent.wav',
      5 => 'audio/clave_accent.wav',
      6 => 'audio/tap_accent.wav',
      7 => 'audio/soft_accent.wav',
      8 => 'audio/knock_accent.wav',
      _ => 'audio/accent.wav',
    };
    final oldClickPool = _clickPool;
    final oldAccentPool = _accentPool;
    _clickPool = null;
    _accentPool = null;
    await Future.wait([
      if (oldClickPool != null) oldClickPool.dispose(),
      if (oldAccentPool != null) oldAccentPool.dispose(),
    ]);
    _clickPool = await AudioPool.createFromAsset(
      path: clickAsset,
      minPlayers: 3,
      maxPlayers: 8,
      playerMode: PlayerMode.lowLatency,
    );
    _accentPool = await AudioPool.createFromAsset(
      path: accentAsset,
      minPlayers: 2,
      maxPlayers: 6,
      playerMode: PlayerMode.lowLatency,
    );
  }

  Future<void> _playClick(
      {required bool accent, bool subdivision = false}) async {
    if (_volume <= 0) return;
    try {
      await _audioSetup;
      final pool = accent ? _accentPool : _clickPool;
      if (pool == null) return;
      // Secondary beats need to remain clearly audible; only beat one is
      // accented, not the only beat in the measure.
      final stop = await pool.start(
        volume: accent ? _volume : _volume * (subdivision ? 0.48 : 0.72),
      );
      unawaited(Future<void>.delayed(
        const Duration(milliseconds: 180),
        stop,
      ));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to play metronome click: $error')),
      );
    }
  }

  void _onTapTempo() {
    final now = DateTime.now();
    if (_tapTimes.isNotEmpty &&
        now.difference(_tapTimes.last) > const Duration(seconds: 2)) {
      _tapTimes.clear();
    }
    _tapTimes.add(now);
    if (_tapTimes.length > 6) {
      _tapTimes.removeAt(0);
    }
    if (_tapTimes.length < 2) return;

    var totalMs = 0;
    for (var i = 1; i < _tapTimes.length; i++) {
      totalMs += _tapTimes[i].difference(_tapTimes[i - 1]).inMilliseconds;
    }
    final averageMs = totalMs / (_tapTimes.length - 1);
    if (averageMs <= 0) return;
    _updateBpm((60000 / averageMs).round());
  }

  void _toggleTempoInputMode() {
    setState(() {
      _isTapMode = !_isTapMode;
      _tapTimes.clear();
    });
  }

  Future<void> _openSettings() => showModalBottomSheet<void>(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (sheetContext) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 26),
          child: StatefulBuilder(
            builder: (context, setDialogState) => Stack(
              clipBehavior: Clip.none,
              children: [
                _MetronomeControlsCard(
                  beats: _beats,
                  denominator: _timeSignatureDenominator,
                  subdivision: _subdivision,
                  activeBeat: _activeBeat,
                  soundStyle: _soundStyle,
                  volume: _volume,
                  onTimeSignatureSelected: (signature) {
                    _updateTimeSignature(signature);
                    setDialogState(() {});
                  },
                  onSubdivisionSelected: (subdivision) {
                    _updateSubdivision(subdivision);
                    setDialogState(() {});
                  },
                  onVolumeChanged: (volume) {
                    _updateVolume(volume);
                    setDialogState(() {});
                  },
                  onSoundStyleChanged: (style) {
                    _updateSoundStyle(style);
                    setDialogState(() {});
                  },
                ),
                Positioned(
                  top: -12,
                  right: -12,
                  child: Material(
                    color: const Color(0xFFBA0007),
                    shape: const CircleBorder(),
                    child: InkWell(
                      onTap: () => Navigator.pop(sheetContext),
                      customBorder: const CircleBorder(),
                      child: const SizedBox(
                        width: 32,
                        height: 32,
                        child: Icon(Icons.close_rounded,
                            color: Colors.white, size: 18),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  @override
  void dispose() {
    _timer?.cancel();
    _playStartTimer?.cancel();
    _clickPool?.dispose();
    _accentPool?.dispose();
    _beatPulseController.dispose();
    for (final ripple in _ripples) {
      ripple.controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const Color brandRed = Color(0xFFBA0007);
    final backgroundColor = AppPalette.page(context);

    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallScreen = screenWidth < 360;

    return Scaffold(
      backgroundColor: backgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            IgnorePointer(
              ignoring: _isPlaying,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                opacity: _isPlaying ? 0 : 1,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: isSmallScreen ? 16.0 : 20.0,
                    vertical: isSmallScreen ? 10.0 : 14.0,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      AppBackButton(
                        size: isSmallScreen ? 20 : 24,
                        onPressed: () => Navigator.pop(context),
                      ),
                      GestureDetector(
                        onTap: _toggleTempoInputMode,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: brandRed,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            _isTapMode ? 'Use slider' : 'Tap for beat',
                            style: const TextStyle(
                              fontFamily: 'Instrument Sans',
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final horizontalPadding = isSmallScreen ? 20.0 : 28.0;
                  final editDialHeight = (isSmallScreen ? 250.0 : 300.0) + 38;
                  final focusedDialHeight =
                      (isSmallScreen ? 282.0 : 330.0) + 90;
                  const sliderHeight = 112.0;
                  const gap = 22.0;
                  final lowerPosition = isSmallScreen ? 30.0 : 40.0;
                  final editContentHeight =
                      editDialHeight + (_isTapMode ? 0 : gap + sliderHeight);
                  final editDialTop = _isTapMode
                      ? (constraints.maxHeight - editDialHeight) / 2 -
                          18 +
                          lowerPosition
                      : ((constraints.maxHeight - editContentHeight) / 2)
                              .clamp(18.0, 58.0) +
                          26 +
                          lowerPosition;
                  final dialTop = _isPlaying
                      ? (constraints.maxHeight - focusedDialHeight) / 2 +
                          lowerPosition
                      : editDialTop;
                  final sliderTop = editDialTop + editDialHeight + gap;

                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _isPlaying
                        ? _togglePlayback
                        : _isTapMode
                            ? _onTapTempo
                            : null,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        AnimatedPositioned(
                          duration: const Duration(milliseconds: 520),
                          curve: Curves.easeInOutCubicEmphasized,
                          left: horizontalPadding,
                          right: horizontalPadding,
                          top: dialTop,
                          child: AnimatedSize(
                            duration: const Duration(milliseconds: 520),
                            curve: Curves.easeInOutCubicEmphasized,
                            alignment: Alignment.topCenter,
                            child: _TempoDial(
                              bpm: _bpm,
                              isPlaying: _isPlaying,
                              isSmallScreen: isSmallScreen,
                              onToggle: _togglePlayback,
                              pulseAnimation: _transportStarted
                                  ? _beatPulseController
                                  : null,
                              ripples: _ripples,
                              rippleColorIndex: _rippleColorIndex,
                              pulseAccent: _lastPulseWasAccent,
                              isFocused: _isPlaying,
                            ),
                          ),
                        ),
                        AnimatedPositioned(
                          duration: const Duration(milliseconds: 520),
                          curve: Curves.easeInOutCubicEmphasized,
                          left: horizontalPadding,
                          right: horizontalPadding,
                          top: _isPlaying
                              ? constraints.maxHeight + 32
                              : _isTapMode
                                  ? constraints.maxHeight + 32
                                  : sliderTop,
                          child: IgnorePointer(
                            ignoring: _isPlaying || _isTapMode,
                            child: Column(
                              children: [
                                _TempoSlider(
                                  bpm: _bpm,
                                  onChanged: _updateBpm,
                                ),
                              ],
                            ),
                          ),
                        ),
                        AnimatedPositioned(
                          duration: const Duration(milliseconds: 520),
                          curve: Curves.easeInOutCubicEmphasized,
                          right: horizontalPadding,
                          bottom: _isPlaying ? -64 : 18,
                          child: IgnorePointer(
                            ignoring: _isPlaying,
                            child: _MetronomeSettingsButton(
                              onTap: _openSettings,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TempoDial extends StatelessWidget {
  const _TempoDial({
    required this.bpm,
    required this.isPlaying,
    required this.isSmallScreen,
    required this.onToggle,
    this.pulseAnimation,
    this.ripples = const [],
    this.rippleColorIndex = 0,
    this.pulseAccent = true,
    this.isFocused = false,
  });

  final int bpm;
  final bool isPlaying;
  final bool isSmallScreen;
  final VoidCallback onToggle;
  final Animation<double>? pulseAnimation;
  final List<_RipplePulse> ripples;
  final int rippleColorIndex;
  final bool pulseAccent;
  final bool isFocused;

  @override
  Widget build(BuildContext context) {
    const brandRed = Color(0xFFBA0007);
    final text = AppPalette.text(context);
    final playButtonColor =
        AppPalette.isDark(context) ? const Color(0xFF2C2C2C) : Colors.black;
    final dialSize = isFocused
        ? (isSmallScreen ? 282.0 : 330.0)
        : (isSmallScreen ? 250.0 : 300.0);
    final bpmProgress =
        ((bpm - _minTempoBpm) / (_maxTempoBpm - _minTempoBpm)).clamp(0.0, 1.0);
    final markerAngle = math.pi * .75 + bpmProgress * math.pi * 2;
    final markerRadius = dialSize * .42;
    final ringColor =
        pulseAnimation != null ? _rippleColor(rippleColorIndex) : brandRed;
    final viewport = MediaQuery.sizeOf(context);
    final rippleReach = math.max(viewport.width, viewport.height) * .58;
    final rippleCanvasSize = dialSize + rippleReach * 2 + 28;

    double ringWeightFor(double progress) {
      if (progress <= 0) return 0;
      if (progress < 0.28) {
        return Curves.easeInOutCubicEmphasized.transform(progress / 0.28);
      }
      final release = ((progress - 0.28) / 0.60).clamp(0.0, 1.0);
      final settle = Curves.easeInOutSine.transform(1 - release);
      final vibration =
          math.sin(release * math.pi * 3.2) * math.pow(1 - release, 1.8) * 0.12;
      return (settle + vibration).clamp(0.0, 1.0);
    }

    Widget dialCircle(double pulseWeight) {
      return SizedBox(
        width: dialSize,
        height: dialSize,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            CustomPaint(
              size: Size(dialSize, dialSize),
              painter: _DialLineGlowPainter(
                color: ringColor,
                weight: pulseWeight,
                accent: pulseAccent,
              ),
            ),
            Center(
              child: Text(
                '$bpm',
                style: TextStyle(
                  fontFamily: 'Instrument Sans',
                  fontSize: isSmallScreen ? 72 : 84,
                  fontWeight: FontWeight.w300,
                  color: text,
                  height: 1,
                ),
              ),
            ),
            TweenAnimationBuilder<double>(
              duration: const Duration(milliseconds: 460),
              curve: Curves.easeInOutCubicEmphasized,
              tween: Tween(end: markerAngle),
              builder: (context, angle, child) => Positioned(
                left: dialSize / 2 + math.cos(angle) * markerRadius - 4.5,
                top: dialSize / 2 + math.sin(angle) * markerRadius - 4.5,
                child: child!,
              ),
              child: Container(
                width: 9,
                height: 9,
                decoration: const BoxDecoration(
                  color: brandRed,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return SizedBox(
      width: double.infinity,
      height: dialSize + (isFocused ? 90 : 38),
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.topCenter,
        children: [
          if (pulseAnimation != null)
            Positioned(
              top: -(rippleCanvasSize - dialSize) / 2,
              child: AnimatedBuilder(
                animation: Listenable.merge([
                  pulseAnimation!,
                  ...ripples.map((ripple) => ripple.controller),
                ]),
                builder: (context, child) {
                  return CustomPaint(
                    size: Size(rippleCanvasSize, rippleCanvasSize),
                    painter: _BeatPulsePainter(
                      waves: [
                        for (final ripple in ripples)
                          _RippleWave(
                            progress: ripple.controller.value,
                            color: _rippleColor(ripple.colorIndex),
                          ),
                      ],
                      dialRadius: dialSize / 2,
                      rippleReach: rippleReach,
                    ),
                  );
                },
              ),
            ),
          if (pulseAnimation == null)
            dialCircle(0)
          else
            AnimatedBuilder(
              animation: pulseAnimation!,
              builder: (context, child) {
                final weight = ringWeightFor(pulseAnimation!.value);
                return dialCircle(weight);
              },
            ),
          if (!isPlaying)
            Positioned(
              bottom: 0,
              child: GestureDetector(
                onTap: onToggle,
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: playButtonColor,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 36,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Color _rippleColor(int index) {
    const rainbow = [
      Color(0xFFFF3B30),
      Color(0xFFFF9500),
      Color(0xFFD6A600),
      Color(0xFF34C759),
      Color(0xFF0A84FF),
      Color(0xFF5E5CE6),
      Color(0xFFBF5AF2),
    ];
    return rainbow[index % rainbow.length];
  }
}

class _DialLineGlowPainter extends CustomPainter {
  const _DialLineGlowPainter({
    required this.color,
    required this.weight,
    required this.accent,
  });

  final Color color;
  final double weight;
  final bool accent;

  @override
  void paint(Canvas canvas, Size size) {
    final width = 2.0 + weight * (accent ? 23.0 : 13.0);
    const baseWidth = 2.0;
    // The stroke is centered on the resting ring, so it gains weight equally
    // toward the BPM value and into the surrounding page.
    final radius = size.shortestSide / 2 - baseWidth / 2;
    if (weight > 0) {
      final glowPaint = Paint()
        ..color = color.withValues(alpha: 0.08 + weight * 0.26)
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 1.5 + weight * 3.2);
      canvas.drawCircle(
        Offset(size.width / 2, size.height / 2),
        radius,
        glowPaint,
      );
    }
    final linePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      radius,
      linePaint,
    );
  }

  @override
  bool shouldRepaint(covariant _DialLineGlowPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.weight != weight ||
        oldDelegate.accent != accent;
  }
}

class _BeatPulsePainter extends CustomPainter {
  _BeatPulsePainter({
    required this.waves,
    required this.dialRadius,
    required this.rippleReach,
  });

  final List<_RippleWave> waves;
  final double dialRadius;
  final double rippleReach;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    // Every beat releases one complete wave. It uses nearly the full beat
    // interval, so it feels measured rather than flickering past.
    for (final wave in waves) {
      if (wave.progress <= 0 || wave.progress >= 1) continue;
      _drawWave(
        canvas,
        center,
        progress: wave.progress,
        start: 0.081,
        distance: rippleReach,
        opacity: 0.86,
        width: 2.35,
        color: wave.color,
      );
    }
  }

  void _drawWave(
    Canvas canvas,
    Offset center, {
    required double progress,
    required double start,
    required double distance,
    required double opacity,
    required double width,
    required Color color,
  }) {
    final travel = ((progress - start) / (1 - start)).clamp(0.0, 1.0);
    if (travel <= 0 || travel >= 1) return;
    final eased = Curves.easeOutSine.transform(travel);
    final fadeIn =
        Curves.easeOutCubic.transform((travel / 0.025).clamp(0.0, 1.0));
    final fadeOut = math.pow(1 - travel, 0.18).toDouble();
    final paint = Paint()
      ..color = color.withValues(alpha: opacity * fadeIn * fadeOut)
      ..style = PaintingStyle.stroke
      ..strokeWidth = width * (0.8 + fadeOut * 0.2);
    canvas.drawCircle(center, dialRadius + 7 + distance * eased, paint);
  }

  @override
  bool shouldRepaint(covariant _BeatPulsePainter oldDelegate) {
    return true;
  }
}

class _TempoSlider extends StatefulWidget {
  const _TempoSlider({
    required this.bpm,
    required this.onChanged,
  });

  final int bpm;
  final ValueChanged<int> onChanged;

  @override
  State<_TempoSlider> createState() => _TempoSliderState();
}

class _TempoSliderState extends State<_TempoSlider>
    with SingleTickerProviderStateMixin {
  late final AnimationController _snapController;
  Animation<double>? _snapAnimation;
  double _visualBpm = 150;

  @override
  void initState() {
    super.initState();
    _visualBpm = widget.bpm.toDouble();
    _snapController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
    )..addListener(() {
        final animation = _snapAnimation;
        if (animation == null) return;
        setState(() => _visualBpm = animation.value);
      });
  }

  @override
  void didUpdateWidget(covariant _TempoSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_snapController.isAnimating && widget.bpm != oldWidget.bpm) {
      _visualBpm = widget.bpm.toDouble();
    }
  }

  @override
  void dispose() {
    _snapController.dispose();
    super.dispose();
  }

  void _setVisualBpm(double value) {
    _visualBpm = value.clamp(
      _minTempoBpm.toDouble(),
      _maxTempoBpm.toDouble(),
    );
    widget.onChanged(_visualBpm.round());
  }

  void _snapToNearestTick(double velocity, double bpmPerPixel) {
    final projectedBpm = (_visualBpm - velocity * bpmPerPixel * 0.12).clamp(
      _minTempoBpm.toDouble(),
      _maxTempoBpm.toDouble(),
    );
    final targetBpm = projectedBpm.round().clamp(_minTempoBpm, _maxTempoBpm);
    final distance = (targetBpm - _visualBpm).abs();
    _snapController.duration =
        Duration(milliseconds: (220 + distance * 18).round().clamp(220, 520));
    _snapAnimation = Tween<double>(
      begin: _visualBpm,
      end: targetBpm.toDouble(),
    ).animate(
      CurvedAnimation(parent: _snapController, curve: Curves.easeOutCubic),
    );
    _snapController.forward(from: 0).whenComplete(() {
      if (!mounted) return;
      widget.onChanged(targetBpm);
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 112,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tickSpacing = constraints.maxWidth * 0.032;
          final bpmPerPixel = 1 / tickSpacing;

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) => _snapController.stop(),
            onHorizontalDragUpdate: (details) {
              final deltaBpm = -details.delta.dx * bpmPerPixel;
              setState(() => _setVisualBpm(_visualBpm + deltaBpm));
            },
            onHorizontalDragEnd: (details) {
              _snapToNearestTick(details.primaryVelocity ?? 0, bpmPerPixel);
            },
            onTapDown: (details) {
              final center = constraints.maxWidth / 2;
              final deltaBpm =
                  -(details.localPosition.dx - center) * bpmPerPixel;
              setState(() => _setVisualBpm(_visualBpm + deltaBpm));
              _snapToNearestTick(0, bpmPerPixel);
            },
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _TempoRulerPainter(
                      bpm: _visualBpm,
                      dark: AppPalette.isDark(context),
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _MetronomeSettingsButton extends StatelessWidget {
  const _MetronomeSettingsButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Metronome settings',
        child: Material(
          color: const Color(0xFFBA0007),
          shape: const CircleBorder(),
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: Container(
              height: 48,
              width: 48,
              decoration: const BoxDecoration(shape: BoxShape.circle),
              alignment: Alignment.center,
              child: const Icon(Icons.settings_rounded,
                  color: Colors.white, size: 22),
            ),
          ),
        ),
      );
}

class _MetronomeControlsCard extends StatelessWidget {
  const _MetronomeControlsCard({
    required this.beats,
    required this.denominator,
    required this.subdivision,
    required this.activeBeat,
    required this.soundStyle,
    required this.volume,
    required this.onTimeSignatureSelected,
    required this.onSubdivisionSelected,
    required this.onVolumeChanged,
    required this.onSoundStyleChanged,
  });

  final int beats;
  final int denominator;
  final int subdivision;
  final int activeBeat;
  final int soundStyle;
  final double volume;
  final ValueChanged<_TimeSignature> onTimeSignatureSelected;
  final ValueChanged<int> onSubdivisionSelected;
  final ValueChanged<double> onVolumeChanged;
  final ValueChanged<int> onSoundStyleChanged;

  @override
  Widget build(BuildContext context) {
    const brandRed = Color(0xFFBA0007);
    final text = AppPalette.text(context);
    final mutedSurface = AppPalette.isDark(context)
        ? const Color(0xFF3A3A3A)
        : const Color(0xFFE8E8E8);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      decoration: BoxDecoration(
        color: AppPalette.surface(context),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black
                .withValues(alpha: AppPalette.isDark(context) ? 0.30 : 0.08),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('TIME SIGNATURE',
              style: TextStyle(
                  fontFamily: 'Instrument Sans',
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  color: brandRed)),
          const SizedBox(height: 5),
          Text('$beats/$denominator',
              style: TextStyle(
                  fontFamily: 'Instrument Sans',
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: text)),
          const SizedBox(height: 8),
          _TimeSignaturePager(
            selected: _TimeSignature(beats, denominator),
            onSelected: onTimeSignatureSelected,
          ),
          const SizedBox(height: 14),
          Divider(height: 1, color: text.withValues(alpha: .16)),
          const SizedBox(height: 13),
          const Text('SUBDIVISION',
              style: TextStyle(
                  fontFamily: 'Instrument Sans',
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  color: brandRed)),
          const SizedBox(height: 6),
          Text(
            'How many clicks happen inside each beat',
            style: TextStyle(
              fontFamily: 'Instrument Sans',
              fontSize: 11,
              color: text.withValues(alpha: .58),
            ),
          ),
          const SizedBox(height: 9),
          Row(
            children: const [
              _SubdivisionSpec(1, Icons.music_note_rounded, '1'),
              _SubdivisionSpec(2, Icons.queue_music_rounded, '2'),
              _SubdivisionSpec(3, Icons.looks_3_rounded, '3'),
              _SubdivisionSpec(4, Icons.format_list_numbered_rounded, '4'),
            ].map((spec) {
              final selected = spec.value == subdivision;
              return Padding(
                padding: const EdgeInsets.only(right: 9),
                child: GestureDetector(
                  onTap: () => onSubdivisionSelected(spec.value),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: 48,
                    height: 44,
                    decoration: BoxDecoration(
                      color: selected ? brandRed : mutedSurface,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(spec.icon,
                            size: 18, color: selected ? Colors.white : text),
                        const SizedBox(height: 1),
                        Text('${spec.value}x',
                            style: TextStyle(
                                fontFamily: 'Instrument Sans',
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                color: selected ? Colors.white : text)),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 14),
          Divider(height: 1, color: text.withValues(alpha: .16)),
          const SizedBox(height: 13),
          const Text('SOUND',
              style: TextStyle(
                  fontFamily: 'Instrument Sans',
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  color: brandRed)),
          const SizedBox(height: 9),
          _SoundStylePager(
            soundStyle: soundStyle,
            onSoundStyleChanged: onSoundStyleChanged,
          ),
          const SizedBox(height: 11),
          Row(children: [
            Icon(
                volume == 0
                    ? Icons.volume_off_rounded
                    : Icons.volume_up_rounded,
                color: text,
                size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  activeTrackColor: brandRed,
                  inactiveTrackColor: mutedSurface,
                  thumbColor: brandRed,
                  overlayColor: brandRed.withValues(alpha: .10),
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6),
                ),
                child: Slider(value: volume, onChanged: onVolumeChanged),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

class _SubdivisionSpec {
  const _SubdivisionSpec(this.value, this.icon, this.label);

  final int value;
  final IconData icon;
  final String label;
}

class _TimeSignature {
  const _TimeSignature(this.numerator, this.denominator);

  final int numerator;
  final int denominator;

  @override
  bool operator ==(Object other) =>
      other is _TimeSignature &&
      other.numerator == numerator &&
      other.denominator == denominator;

  @override
  int get hashCode => Object.hash(numerator, denominator);
}

class _TimeSignaturePager extends StatefulWidget {
  const _TimeSignaturePager({required this.selected, required this.onSelected});

  final _TimeSignature selected;
  final ValueChanged<_TimeSignature> onSelected;

  @override
  State<_TimeSignaturePager> createState() => _TimeSignaturePagerState();
}

class _TimeSignaturePagerState extends State<_TimeSignaturePager> {
  var _page = 0;

  static const _pages = [
    [
      _TimeSignature(1, 4),
      _TimeSignature(2, 4),
      _TimeSignature(3, 4),
      _TimeSignature(4, 4),
      _TimeSignature(3, 8),
      _TimeSignature(6, 8),
      _TimeSignature(9, 8),
      _TimeSignature(12, 8),
    ],
    [
      _TimeSignature(5, 4),
      _TimeSignature(7, 4),
      _TimeSignature(5, 8),
      _TimeSignature(7, 8),
      _TimeSignature(6, 4),
      _TimeSignature(9, 4),
      _TimeSignature(11, 8),
      _TimeSignature(13, 8),
    ],
  ];

  @override
  Widget build(BuildContext context) {
    const brandRed = Color(0xFFBA0007);
    final text = AppPalette.text(context);
    final surface = AppPalette.isDark(context)
        ? const Color(0xFF3A3A3A)
        : const Color(0xFFE8E8E8);
    return SizedBox(
      height: 96,
      child: Column(
        children: [
          Expanded(
            child: PageView.builder(
              itemCount: _pages.length,
              onPageChanged: (page) => setState(() => _page = page),
              itemBuilder: (context, page) => Column(
                children: [
                  Expanded(
                      child: _signatureRow(_pages[page].take(4).toList(), text,
                          surface, brandRed)),
                  const SizedBox(height: 8),
                  Expanded(
                      child: _signatureRow(_pages[page].skip(4).toList(), text,
                          surface, brandRed)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 7),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              _pages.length,
              (index) => AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                height: 4,
                width: index == _page ? 14 : 4,
                decoration: BoxDecoration(
                  color:
                      index == _page ? brandRed : text.withValues(alpha: .25),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _signatureRow(
    List<_TimeSignature> signatures,
    Color text,
    Color surface,
    Color brandRed,
  ) =>
      Row(
        children: signatures.map((signature) {
          final selected = signature == widget.selected;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => widget.onSelected(signature),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected ? brandRed : surface,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${signature.numerator}/${signature.denominator}',
                    style: TextStyle(
                      fontFamily: 'Instrument Sans',
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: selected ? Colors.white : text,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      );
}

class _SoundStylePager extends StatefulWidget {
  const _SoundStylePager({
    required this.soundStyle,
    required this.onSoundStyleChanged,
  });

  final int soundStyle;
  final ValueChanged<int> onSoundStyleChanged;

  @override
  State<_SoundStylePager> createState() => _SoundStylePagerState();
}

class _SoundStylePagerState extends State<_SoundStylePager> {
  var _page = 0;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 96,
        child: Column(
          children: [
            Expanded(
              child: PageView(
                onPageChanged: (page) => setState(() => _page = page),
                children: [
                  Column(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            _option(0, 'Classic', Icons.graphic_eq_rounded),
                            const SizedBox(width: 8),
                            _option(1, 'Wood', Icons.album_rounded),
                            const SizedBox(width: 8),
                            _option(
                                2, 'Bell', Icons.notifications_active_outlined),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: Row(
                          children: [
                            _option(3, 'Snap', Icons.bolt_rounded),
                            const SizedBox(width: 8),
                            _option(4, 'Digital', Icons.memory_rounded),
                            const SizedBox(width: 8),
                            _option(5, 'Clave', Icons.music_note_rounded),
                          ],
                        ),
                      ),
                    ],
                  ),
                  Column(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            _option(6, 'Tap', Icons.touch_app_rounded),
                            const SizedBox(width: 8),
                            _option(7, 'Soft', Icons.waves_rounded),
                            const SizedBox(width: 8),
                            _option(
                                8, 'Knock', Icons.radio_button_checked_rounded),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Expanded(child: SizedBox()),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                2,
                (index) => AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: _page == index ? 13 : 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: _page == index
                        ? const Color(0xFFBA0007)
                        : AppPalette.border(context),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
          ],
        ),
      );

  Widget _option(int value, String label, IconData icon) => _SoundStyleOption(
        label: label,
        icon: icon,
        selected: widget.soundStyle == value,
        onTap: () => widget.onSoundStyleChanged(value),
      );
}

class _SoundStyleOption extends StatelessWidget {
  const _SoundStyleOption({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const brandRed = Color(0xFFBA0007);
    final text = AppPalette.text(context);
    final surface = AppPalette.isDark(context)
        ? const Color(0xFF3A3A3A)
        : const Color(0xFFE8E8E8);
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: 38,
          decoration: BoxDecoration(
            color: selected ? brandRed : surface,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 15, color: selected ? Colors.white : text),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontFamily: 'Instrument Sans',
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: selected ? Colors.white : text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TempoRulerPainter extends CustomPainter {
  _TempoRulerPainter({required this.bpm, required this.dark});

  final double bpm;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    const tickStep = 1;
    final tickSpacing = size.width * 0.032;
    final visiblePadding = tickSpacing * 10;

    for (var tickBpm = _minTempoBpm;
        tickBpm <= _maxTempoBpm;
        tickBpm += tickStep) {
      final x = center.dx + ((tickBpm - bpm) / tickStep) * tickSpacing;
      if (x < -visiblePadding || x > size.width + visiblePadding) continue;

      final distanceFromCenter =
          ((x - center.dx).abs() / (size.width * 0.43)).clamp(0.0, 1.0);
      final darkness = 1 - distanceFromCenter;
      final centerProgress =
          (1 - ((x - center.dx).abs() / tickSpacing).clamp(0.0, 1.0));
      final isFiveBpm = tickBpm % 5 == 0;
      final isTenBpm = tickBpm % 10 == 0;
      final alpha = 0.12 + darkness * 0.82;
      final baseHeight = isTenBpm
          ? 72.0
          : isFiveBpm
              ? 62.0
              : 40.0;
      final height = baseHeight * (1 - centerProgress) + 108.0 * centerProgress;
      final base =
          (dark ? Colors.white : Colors.black).withValues(alpha: alpha);
      final color = Color.lerp(base, const Color(0xFFBA0007), centerProgress)!;
      final paint = Paint()
        ..color = color
        ..strokeWidth = isFiveBpm ? 2.2 : 1.4 + centerProgress * 1.1
        ..strokeCap = StrokeCap.round;

      canvas.drawLine(
        Offset(x, center.dy - height / 2),
        Offset(x, center.dy + height / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TempoRulerPainter oldDelegate) {
    return oldDelegate.bpm != bpm || oldDelegate.dark != dark;
  }
}
