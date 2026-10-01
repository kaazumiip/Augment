import 'package:flutter/material.dart';

import 'app_palette.dart';

class AppLogo extends StatelessWidget {
  const AppLogo({super.key, required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => Image.asset(
        AppPalette.isDark(context)
            ? 'assets/augment_logo_dark.png'
            : 'assets/augment_logo.png',
        width: width,
        height: height,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      );
}
