import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'animated_mascot.dart';
import 'app_palette.dart';
import 'auth_service.dart';
import 'home_page.dart';

class WelcomeNamePage extends StatefulWidget {
  const WelcomeNamePage({super.key});

  @override
  State<WelcomeNamePage> createState() => _WelcomeNamePageState();
}

class _WelcomeNamePageState extends State<WelcomeNamePage> {
  final _controller = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    final name = _controller.text.trim();
    if (name.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      await AuthService.completeNameOnboarding(name);
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const AugmentHomePage()),
        (_) => false,
      );
    } on AuthException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
      setState(() => _saving = false);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Could not save your name. Please try again.')),
      );
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const brandRed = Color(0xFFBA0007);
    const gradientTop = Color(0xFF5E0004);
    const gradientBottom = Color(0xFFBA0007);

    final media = MediaQuery.of(context);
    final screenHeight = media.size.height;
    final bannerHeight = (screenHeight * 0.36).clamp(230.0, 310.0);

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
                      top: -60,
                      right: -30,
                      child: Container(
                        width: 220,
                        height: 220,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: -40,
                      left: -20,
                      child: Container(
                        width: 160,
                        height: 160,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black.withValues(alpha: 0.12),
                        ),
                      ),
                    ),
                    // Sparkles / star accents
                    Positioned(
                      top: 48,
                      right: 48,
                      child: Icon(
                        Icons.auto_awesome,
                        color: Colors.white.withValues(alpha: 0.35),
                        size: 20,
                      ),
                    ),
                    Positioned(
                      bottom: 50,
                      left: 36,
                      child: Icon(
                        Icons.music_note,
                        color: Colors.white.withValues(alpha: 0.25),
                        size: 24,
                      ),
                    ),
                    // Banner content: Mascot + Welcome title
                    SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            // Text column
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(alpha: 0.18),
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: const Text(
                                      'WELCOME',
                                      style: TextStyle(
                                        fontFamily: 'Instrument Sans',
                                        fontSize: 11,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 1.2,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  const Text(
                                    'Hello there!',
                                    style: TextStyle(
                                      fontFamily: 'Instrument Sans',
                                      fontSize: 28,
                                      fontWeight: FontWeight.w900,
                                      color: Colors.white,
                                      height: 1.1,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'Welcome to Augment. Let’s get your musical journey started.',
                                    style: TextStyle(
                                      fontFamily: 'Instrument Sans',
                                      fontSize: 13,
                                      color: Colors.white.withValues(alpha: 0.85),
                                      height: 1.35,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            // Mascot
                            AnimatedMascot(
                              height: (bannerHeight * 0.52).clamp(100.0, 138.0),
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
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
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
                  padding: const EdgeInsets.fromLTRB(28, 32, 28, 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Accent line
                      Center(
                        child: Container(
                          width: 44,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 24),
                          decoration: BoxDecoration(
                            color: Colors.grey.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Text(
                        'What is your name?',
                        style: TextStyle(
                          fontFamily: 'Instrument Sans',
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                          color: AppPalette.text(context),
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Enter your name or artist name so your band and friends can find you.',
                        style: TextStyle(
                          fontFamily: 'Instrument Sans',
                          fontSize: 14,
                          color: AppPalette.muted(context),
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 28),
                      TextField(
                        controller: _controller,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _continue(),
                        autofocus: false,
                        style: TextStyle(
                          fontFamily: 'Instrument Sans',
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: AppPalette.text(context),
                        ),
                        decoration: InputDecoration(
                          hintText: 'e.g. Maya Lin',
                          hintStyle: TextStyle(
                            fontFamily: 'Instrument Sans',
                            color: AppPalette.muted(context).withValues(alpha: 0.6),
                          ),
                          filled: true,
                          fillColor: AppPalette.surface(context),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 16,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide(
                              color: AppPalette.muted(context).withValues(alpha: 0.25),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide(
                              color: AppPalette.muted(context).withValues(alpha: 0.2),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(
                              color: brandRed,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton(
                          onPressed: _saving ? null : _continue,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: brandRed,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: _saving
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.4,
                                    valueColor: AlwaysStoppedAnimation(Colors.white),
                                  ),
                                )
                              : const Text(
                                  'CONTINUE',
                                  style: TextStyle(
                                    fontFamily: 'Instrument Sans',
                                    fontSize: 15,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.6,
                                  ),
                                ),
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
}
