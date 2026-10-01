import 'package:flutter/material.dart';

class AppPalette {
  const AppPalette._();

  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;
  static Color page(BuildContext context) =>
      isDark(context) ? Colors.black : const Color(0xFFFFF9F6);
  static Color surface(BuildContext context) =>
      isDark(context) ? const Color(0xFF252525) : Colors.white;
  static Color text(BuildContext context) =>
      isDark(context) ? Colors.white : const Color(0xFF1A1A1A);
  static Color muted(BuildContext context) =>
      isDark(context) ? const Color(0xFFB6B6B6) : const Color(0xFF777777);
  static Color border(BuildContext context) =>
      isDark(context) ? const Color(0xFFE0E0E0) : const Color(0xFFD9D9D9);
}

/// A consistent leading Back control for full-screen pages.
class AppBackButton extends StatelessWidget {
  const AppBackButton({
    super.key,
    required this.onPressed,
    this.color,
    this.size = 22,
    this.tooltip = 'Back',
  });

  final VoidCallback? onPressed;
  final Color? color;
  final double size;
  final String tooltip;

  @override
  Widget build(BuildContext context) => Transform.translate(
        offset: const Offset(-12, 0),
        child: IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          alignment: Alignment.centerLeft,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 48, height: 48),
          icon: Icon(
            Icons.arrow_back_ios_new_rounded,
            color: color ?? AppPalette.text(context),
            size: size,
          ),
        ),
      );
}
