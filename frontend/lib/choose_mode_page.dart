import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'animated_mascot.dart';
import 'choose_instrument_page.dart';
import 'band_setup_page.dart';
import 'app_palette.dart';
import 'app_logo.dart';
import 'app_settings.dart';
import 'plans_page.dart';

class ChooseModePage extends StatelessWidget {
  final String source;
  final String? fileUrl;
  final String? filePath;

  const ChooseModePage(
      {Key? key, required this.source, this.fileUrl, this.filePath})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    const Color brandRed = Color(0xFFBA0007);
    const Color gradientTop = Color(0xFF5E0004);
    const Color gradientBottom = Color(0xFFBA0007);

    final media = MediaQuery.of(context);
    final screenWidth = media.size.width;
    final isSmallScreen = screenWidth < 360;
    final double bannerHeight = (media.size.height * 0.32).clamp(220.0, 270.0);

    return Scaffold(
      backgroundColor: gradientTop,
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Column(
          children: [
            // Top decorative banner with mascot
            SizedBox(
              height: bannerHeight,
              width: double.infinity,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [gradientTop, gradientBottom],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
                child: Stack(
                  children: [
                    // Ambient glow rings
                    Positioned(
                      top: -50,
                      right: -30,
                      child: Container(
                        width: 200,
                        height: 200,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: -30,
                      left: -20,
                      child: Container(
                        width: 140,
                        height: 140,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black.withValues(alpha: 0.12),
                        ),
                      ),
                    ),
                    // Sparkle accents
                    Positioned(
                      top: 46,
                      right: 50,
                      child: Icon(
                        Icons.auto_awesome,
                        color: Colors.white.withValues(alpha: 0.35),
                        size: 20,
                      ),
                    ),
                    Positioned(
                      bottom: 40,
                      left: 28,
                      child: Icon(
                        Icons.music_note,
                        color: Colors.white.withValues(alpha: 0.25),
                        size: 22,
                      ),
                    ),
                    // Banner content: Back button + title + mascot
                    SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Back button
                            GestureDetector(
                              onTap: () => Navigator.pop(context),
                              child: Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.2),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.arrow_back_ios_new,
                                  color: Colors.white,
                                  size: 18,
                                ),
                              ),
                            ),
                            const Spacer(),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 10, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(alpha: 0.18),
                                          borderRadius: BorderRadius.circular(16),
                                        ),
                                        child: const Text(
                                          'ARRANGEMENT',
                                          style: TextStyle(
                                            fontFamily: 'Instrument Sans',
                                            fontSize: 10,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: 1.2,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      const Text(
                                        'Choose your mode',
                                        style: TextStyle(
                                          fontFamily: 'Instrument Sans',
                                          fontSize: 24,
                                          fontWeight: FontWeight.w900,
                                          color: Colors.white,
                                          height: 1.15,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'Solo practice or full band arrangement.',
                                        style: TextStyle(
                                          fontFamily: 'Instrument Sans',
                                          fontSize: 12,
                                          color: Colors.white.withValues(alpha: 0.85),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                AnimatedMascot(
                                  height: (bannerHeight * 0.52).clamp(95.0, 125.0),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Bottom rounded surface
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: AppPalette.page(context),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 20,
                      offset: const Offset(0, -4),
                    ),
                  ],
                ),
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: EdgeInsets.symmetric(
                    horizontal: isSmallScreen ? 20.0 : 28.0,
                    vertical: 24.0,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Handle accent
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 20),
                          decoration: BoxDecoration(
                            color: Colors.grey.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),

                      // Solo mode card
                      _buildModeCard(
                        context: context,
                        image: 'assets/solo.png',
                        title: 'Solo',
                        mode: 'mode',
                        description: 'Browse your audio or MIDI files',
                        isSmallScreen: isSmallScreen,
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ChooseInstrumentPage(
                                mode: 'Solo',
                                source: source,
                                fileUrl: fileUrl,
                                filePath: filePath,
                              ),
                            ),
                          );
                        },
                      ),
                      SizedBox(height: isSmallScreen ? 14 : 18),

                      // Band mode card
                      _buildModeCard(
                        context: context,
                        image: 'assets/band.png',
                        title: 'Band',
                        mode: 'mode',
                        description: 'Google Drive, Dropbox, OneDrive and more',
                        isSmallScreen: isSmallScreen,
                        onTap: () {
                          if (AppSettings.instance.plan == AppPlan.free) {
                            showDialog<void>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                title: const Text(
                                  'Band Mode Requires Plus or Pro',
                                  style: TextStyle(
                                    fontFamily: 'Instrument Sans',
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                content: const Text(
                                  'Band mode is not included in the Free plan. Upgrade to Plus or Pro to transcribe multi-instrument band tracks.',
                                  style: TextStyle(
                                    fontFamily: 'Instrument Sans',
                                    fontSize: 14,
                                  ),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx),
                                    child: const Text('Cancel'),
                                  ),
                                  ElevatedButton(
                                    onPressed: () {
                                      Navigator.pop(ctx);
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => const PlansPage(),
                                        ),
                                      );
                                    },
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: brandRed,
                                      foregroundColor: Colors.white,
                                    ),
                                    child: const Text('View Plans'),
                                  ),
                                ],
                              ),
                            );
                            return;
                          }
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => BandSetupPage(
                                source: source,
                                fileUrl: fileUrl,
                                filePath: filePath,
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 36),

                      // Logo at bottom
                      Center(
                        child: AppLogo(
                          width: isSmallScreen ? 42 : 56,
                          height: isSmallScreen ? 30 : 40,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeCard({
    required BuildContext context,
    required String image,
    required String title,
    required String mode,
    required String description,
    required bool isSmallScreen,
    required VoidCallback onTap,
  }) {
    const Color brandRed = Color(0xFFBA0007);

    final double iconSize = isSmallScreen ? 64 : 80;
    final double innerIconSize = isSmallScreen ? 44 : 56;
    final double cardPad = isSmallScreen ? 16 : 20;
    final double titleFontSize = isSmallScreen ? 16 : 19;
    final double descFontSize = isSmallScreen ? 12 : 14;
    final double arrowSize = isSmallScreen ? 42 : 48;
    final double arrowIconSize = isSmallScreen ? 16 : 20;

    return GestureDetector(
      key: ValueKey('mode_card_$title'),
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(cardPad),
        decoration: BoxDecoration(
          color: AppPalette.surface(context),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black
                  .withValues(alpha: AppPalette.isDark(context) ? 0.25 : 0.05),
              blurRadius: 15,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Row(
          children: [
            // Image
            Container(
              width: iconSize,
              height: iconSize,
              decoration: const BoxDecoration(
                color: Color(0xFFFCE4EC),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Image.asset(
                  image,
                  width: innerIconSize,
                  height: innerIconSize,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) {
                    return Icon(
                      image.contains('solo') ? Icons.piano : Icons.groups,
                      size: innerIconSize,
                      color: brandRed,
                    );
                  },
                ),
              ),
            ),
            SizedBox(width: isSmallScreen ? 14 : 18),

            // Text content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  RichText(
                    text: TextSpan(
                      children: [
                        TextSpan(
                          text: '$title ',
                          style: TextStyle(
                            fontFamily: 'Instrument Sans',
                            fontSize: titleFontSize,
                            fontWeight: FontWeight.w800,
                            color: AppPalette.text(context),
                          ),
                        ),
                        TextSpan(
                          text: mode,
                          style: TextStyle(
                            fontFamily: 'Instrument Sans',
                            fontSize: titleFontSize,
                            fontWeight: FontWeight.w800,
                            color: brandRed,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: isSmallScreen ? 3 : 4),
                  Text(
                    description,
                    style: TextStyle(
                      fontFamily: 'Instrument Sans',
                      fontSize: descFontSize,
                      color: AppPalette.muted(context),
                    ),
                  ),
                ],
              ),
            ),

            // Arrow button
            Container(
              width: arrowSize,
              height: arrowSize,
              decoration: const BoxDecoration(
                color: brandRed,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.arrow_forward_ios,
                color: Colors.white,
                size: arrowIconSize,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
