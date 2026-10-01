import 'package:flutter/material.dart';
import 'augment_logo_motion.dart';

class VectorSplashScreen extends StatefulWidget {
  const VectorSplashScreen({super.key, required this.destinationBuilder});
  final Widget Function(VoidCallback ready) destinationBuilder;

  /// Replays in place, preserving Home and its existing data/state.
  static void debugReplay(BuildContext context) {
    assert(() {
      context.findAncestorStateOfType<_VectorSplashScreenState>()?._replay();
      return true;
    }());
  }

  @override
  State<VectorSplashScreen> createState() => _VectorSplashScreenState();
}

class _VectorSplashScreenState extends State<VectorSplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _motion;
  late final AnimationController _slide;
  late final Animation<double> _pan;
  late final Widget _destination;
  bool _filmDone = false, _ready = false, _started = false, _complete = false;

  @override
  void initState() {
    super.initState();
    _slide = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 360));
    // Never translate past zero: overshooting reveals a strip of background.
    _pan = Tween<double>(begin: 1, end: 0).animate(
      CurvedAnimation(parent: _slide, curve: Curves.easeInOutCubic),
    );
    _destination = widget.destinationBuilder(() {
      _ready = true;
      _trySlide();
    });
    _motion = AnimationController(
      vsync: this,
      duration: AugmentLogoMotion.duration,
      // The branded launch motion must not jump straight to its final frame
      // when Android's global animator scale is disabled.
      animationBehavior: AnimationBehavior.preserve,
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed) _finishFilm();
      });

    // Start only after the zero-progress splash has visibly reached the
    // screen. A single post-frame callback is often too short on a cold
    // Android launch: the first animated frame can arrive before the user has
    // seen the beginning, making the logo film look cut off.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.delayed(const Duration(milliseconds: 140), () {
        if (mounted) _motion.forward(from: 0);
      });
    });
  }

  void _replay() {
    if (!_complete) return;
    setState(() {
      _filmDone = false;
      _started = false;
      _complete = false;
      _slide.reset();
      _motion.forward(from: 0);
    });
  }

  void _finishFilm() {
    if (!mounted || _filmDone) return;
    setState(() => _filmDone = true);
    _trySlide();
  }

  void _trySlide() {
    if (!mounted || !_filmDone || !_ready || _started) return;
    // The destination has already painted at its natural position behind the
    // opaque film. Move it offscreen only when starting the pan.
    _started = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (MediaQuery.disableAnimationsOf(context)) {
        setState(() => _complete = true);
        return;
      }
      await _slide.forward();
      if (mounted) setState(() => _complete = true);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _motion.dispose();
    _slide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The same vector canvas remains mounted through the pan.
    final film = RepaintBoundary(
      child: ColoredBox(
        color: Colors.white,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 540),
            child: AspectRatio(
              // The logo's path and final dot extend below the old 288px
              // artwork box, which clipped the end of the launch animation.
              aspectRatio: 540 / 360,
              child: CustomPaint(painter: AugmentLogoMotion(_motion)),
            ),
          ),
        ),
      ),
    );
    return AnimatedBuilder(
      animation: _pan,
      child: RepaintBoundary(child: _destination),
      builder: (context, page) =>
          Stack(clipBehavior: Clip.hardEdge, fit: StackFit.expand, children: [
        ColoredBox(color: Theme.of(context).scaffoldBackgroundColor),
        // Keep the destination mounted throughout so its state is never recreated.
        FractionalTranslation(
          translation: Offset(_complete || !_started ? 0 : _pan.value, 0),
          child: IgnorePointer(
              ignoring: !_complete,
              child: ExcludeSemantics(excluding: !_complete, child: page!)),
        ),
        if (!_complete)
          FractionalTranslation(
            translation: Offset(_pan.value - 1, 0),
            child: film,
          ),
      ]),
    );
  }
}
