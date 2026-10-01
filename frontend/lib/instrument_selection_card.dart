import 'package:flutter/material.dart';

import 'app_palette.dart';

class InstrumentSelectionCard extends StatelessWidget {
  const InstrumentSelectionCard({
    super.key,
    required this.name,
    required this.subtitle,
    required this.isRed,
    required this.height,
    required this.onTap,
  });

  final String name;
  final String subtitle;
  final bool isRed;
  final double height;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFBA0007);
    final dark = AppPalette.isDark(context);
    final imagePath = _assetFor(name);
    final titleColor = isRed ? Colors.white : red;
    final lowerName = name.toLowerCase();
    final imageOffset = lowerName.contains('violin')
        ? 0.0
        : lowerName.contains('cello')
            ? height * .09
            : lowerName.contains('piano')
                ? height * .48
                : 0.0;
    final imageScale = lowerName.contains('piano')
        ? .98
        : lowerName.contains('ukulele') || lowerName.contains('violin')
            ? .88
            : 1.24;
    final imageHorizontalOffset =
        lowerName.contains('piano') ? -height * .07 : 0.0;
    const titleOffset = 0.0;
    final subtitleColor = isRed
        ? Colors.white.withValues(alpha: .9)
        : Colors.black.withValues(alpha: .72);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isRed
                ? const [Color(0xFFD5000A), Color(0xFF760006)]
                : const [Color(0xFFFFFFFF), Color(0xFFD2D2D2)],
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? .34 : .20),
              blurRadius: 8,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
              child: Transform.translate(
                offset: const Offset(0, titleOffset),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Transform.translate(
                      offset: const Offset(-5, 6),
                      child: _titleText(
                        color: titleColor,
                        stroke: true,
                      ),
                    ),
                    _titleText(color: titleColor, stroke: false),
                  ],
                ),
              ),
            ),
            Positioned.fill(
              child: Transform.translate(
                offset: Offset(imageHorizontalOffset, imageOffset),
                child: Transform.scale(
                  scale: imageScale,
                  child: imagePath == null
                      ? Icon(
                          Icons.music_note_rounded,
                          size: height * .50,
                          color: titleColor.withValues(alpha: .72),
                        )
                      : Image.asset(imagePath, fit: BoxFit.contain),
                ),
              ),
            ),
            Positioned(
              right: 18,
              bottom: 15,
              child: SizedBox(
                width: 92,
                child: Text(
                  subtitle,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontFamily: 'Instrument Sans',
                    fontSize: 12,
                    height: 1.0,
                    fontWeight: FontWeight.w700,
                    color: subtitleColor,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String? _assetFor(String value) {
    final name = value.toLowerCase();
    if (name.contains('cello')) {
      return 'assets/cello.png';
    }
    if (name.contains('violin')) {
      return 'assets/violin_instrument_card.png';
    }
    if (name.contains('bass')) return 'assets/bass guitar..png';
    if (name.contains('electric guitar')) {
      return 'assets/electric guitar.png';
    }
    if (name.contains('ukulele')) {
      return 'assets/ukulele_instrument_card.png';
    }
    if (name.contains('guitar')) {
      return 'assets/guitar.png';
    }
    if (name.contains('sax')) return 'assets/saxophone.png';
    if (name.contains('trumpet')) return 'assets/trumpet.png';
    if (name.contains('flute')) return 'assets/flute.png';
    if (name.contains('clarinet')) return 'assets/Clarinet.png';
    if (name.contains('piano')) return 'assets/Piano.png';
    return null;
  }

  Widget _titleText({required Color color, required bool stroke}) => Text(
        name.toUpperCase(),
        textAlign: TextAlign.center,
        maxLines: 2,
        style: TextStyle(
          fontFamily: 'Instrument Sans',
          fontSize: height * .25,
          height: .82,
          fontWeight: FontWeight.w900,
          color: stroke ? null : color,
          foreground: stroke
              ? (Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = .9
                ..color = color)
              : null,
        ),
      );
}
