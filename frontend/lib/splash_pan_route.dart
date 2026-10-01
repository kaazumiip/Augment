import 'package:flutter/material.dart';

/// Owns its transition visuals independently of the disposed splash State.
Route<void> splashPanRoute(Widget destination) => PageRouteBuilder<void>(
      pageBuilder: (_, __, ___) => destination,
      transitionDuration: const Duration(milliseconds: 850),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        if (animation.status == AnimationStatus.completed) return child;
        final pan = TweenSequence<double>([
          TweenSequenceItem(
            tween: Tween(begin: 1.0, end: -0.018)
                .chain(CurveTween(curve: Curves.easeInOutCubic)),
            weight: 82,
          ),
          TweenSequenceItem(
            tween: Tween(begin: -0.018, end: 0.0)
                .chain(CurveTween(curve: Curves.easeOutCubic)),
            weight: 18,
          ),
        ]).animate(animation);
        final background = Theme.of(context).scaffoldBackgroundColor;
        return AnimatedBuilder(
          animation: pan,
          child: RepaintBoundary(child: child),
          builder: (_, page) => Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: background),
              FractionalTranslation(
                translation: Offset(pan.value - 1, 0),
                child: const RepaintBoundary(
                  child: ColoredBox(
                    color: Colors.white,
                    child: Center(
                      child: Image(
                        image: AssetImage('assets/augment_logo_end.png'),
                        width: 540,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                ),
              ),
              FractionalTranslation(
                translation: Offset(pan.value, 0),
                child: page,
              ),
            ],
          ),
        );
      },
    );
