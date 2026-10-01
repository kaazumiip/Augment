import 'package:flutter/material.dart';

/// Plays the Augment bunny's authored PNG poses as a frame animation.
class AnimatedMascot extends StatefulWidget {
  const AnimatedMascot({
    super.key,
    required this.height,
    this.alignment = Alignment.bottomCenter,
  });

  final double height;
  final Alignment alignment;

  @override
  State<AnimatedMascot> createState() => _AnimatedMascotState();
}

class _AnimatedMascotState extends State<AnimatedMascot>
    with SingleTickerProviderStateMixin {
  static const _neutral = 'assets/augment_bunny_mascot.png';
  static const _crouch = 'assets/mascot_animation/crouch.png';
  static const _hop = 'assets/mascot_animation/hop.png';

  // Repeated entries create anticipation, a quick hop, and a soft landing.
  // The separately generated wave frame is intentionally excluded because its
  // rendering style does not match the other poses closely enough.
  static const _timeline = <String>[
    _neutral,
    _neutral,
    _neutral,
    _crouch,
    _crouch,
    _hop,
    _hop,
    _hop,
    _crouch,
    _crouch,
    _neutral,
    _neutral,
  ];

  static const _assets = <String>{_neutral, _crouch, _hop};
  late final AnimationController _controller;
  bool _precacheRequested = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (_timeline.length * 1000) ~/ 12),
    )..repeat();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_precacheRequested) return;
    _precacheRequested = true;
    for (final asset in _assets) {
      precacheImage(AssetImage(asset), context);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      image: true,
      label: 'Augment bunny mascot hopping',
      child: RepaintBoundary(
        child: SizedBox(
          height: widget.height,
          child: reduceMotion
              ? _frame(_neutral)
              : AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) {
                    final frame =
                        (_controller.value * _timeline.length).floor() %
                            _timeline.length;
                    return _frame(_timeline[frame]);
                  },
                ),
        ),
      ),
    );
  }

  Widget _frame(String asset) => Image.asset(
        asset,
        key: ValueKey(asset),
        height: widget.height,
        fit: BoxFit.contain,
        alignment: widget.alignment,
        filterQuality: FilterQuality.high,
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) => asset == _neutral
            ? const SizedBox.shrink()
            : Image.asset(
                _neutral,
                height: widget.height,
                fit: BoxFit.contain,
                alignment: widget.alignment,
                filterQuality: FilterQuality.high,
              ),
      );
}
