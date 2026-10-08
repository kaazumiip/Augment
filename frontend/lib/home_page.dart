import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'vector_splash_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:async';
import 'dart:math' as math;
import 'metronome_page.dart';
import 'choose_tuner_instrument_page.dart';
import 'tuner_page.dart';
import 'sheet_generation_page.dart';
import 'social_page.dart';
import 'marketplace_page.dart';
import 'settings_page.dart';
import 'generation_state.dart';
import 'music_sheet_page.dart';
import 'app_palette.dart';
import 'tools_page.dart';
import 'saved_sheets_page.dart';
import 'voice_range_page.dart';
import 'pitch_detector_page.dart';
import 'social_avatar.dart';
import 'social_profile_page.dart';
import 'social_service.dart';

const double _circleSize = 48;

class AugmentHomePage extends StatefulWidget {
  const AugmentHomePage({Key? key}) : super(key: key);

  @override
  State<AugmentHomePage> createState() => _AugmentHomePageState();
}

class _AugmentHomePageState extends State<AugmentHomePage>
    with TickerProviderStateMixin {
  int _selectedIndex = 0;

  late final AnimationController _navAnimController;
  late final Animation<double> _navCurve;
  double _notchStartX = 0;
  double _notchEndX = 0;
  double _currentNotchX = 0;
  int _prevIndex = 0;
  bool _isNavTransitioning = false;

  static const double _navBarHeight = 78;
  static const double _circleElevation = 12;
  static const double _notchRadius = 32;
  static const int _navItemCount = 5;

  late AnimationController _entranceController;
  late AnimationController _gradientController;
  late Animation<double> _headerAnim;
  late Animation<double> _imageAnim;
  late Animation<double> _cardAnim;
  late Animation<double> _carouselAnim;
  late final StreamSubscription<User?> _userChangesSubscription;
  Future<Map<String, dynamic>?>? _homeProfilePhotosFuture;

  // Theme styling helpers
  static const String fontFamily = 'Instrument Sans';

  static const LinearGradient redGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFFBA0007),
      Color(0xFF540003),
    ],
  );

  static const LinearGradient whiteCardGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFFFFFFFF),
      Color(0xFFEFEAE6),
    ],
  );

  // Carousel controller + state for the utility cards row
  final PageController _carouselController =
      PageController(viewportFraction: 0.82);
  int _currentPage = 0;

  static const List<Map<String, dynamic>> _utilityCardData = [
    {
      'title': 'METRONOME',
      'text':
          'Stay in sync. Choose a tempo, start the beat, and focus on the music.',
      'isDark': true,
      'type': 'metronome',
    },
    {
      'title': 'Tuner',
      'text':
          'Stay in sync. Choose a tempo, start the beat, and focus on the music.',
      'isDark': false,
      'type': 'tuner',
    },
    {
      'title': 'Voice pitch test',
      'text':
          'Stay in sync. Choose a tempo, start the beat, and focus on the music.',
      'isDark': true,
      'type': 'voicePitch',
    },
    {
      'title': 'Pitch detector',
      'text':
          'Stay in sync. Choose a tempo, start the beat, and focus on the music.',
      'isDark': false,
      'type': 'pitchDetector',
    },
  ];

  @override
  void initState() {
    super.initState();
    _refreshHomeProfilePhoto();
    _userChangesSubscription = FirebaseAuth.instance.userChanges().listen((_) {
      if (mounted) {
        setState(_refreshHomeProfilePhoto);
      }
    });
    _navAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _navCurve = CurvedAnimation(
      parent: _navAnimController,
      curve: Curves.easeOutQuint,
      reverseCurve: Curves.easeInQuint,
    );
    _navAnimController.addListener(() {
      final t = _navCurve.value;
      setState(() {
        _currentNotchX = _notchStartX + (_notchEndX - _notchStartX) * t;
      });
    });
    _navAnimController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _isNavTransitioning = false;
      }
    });

    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _headerAnim = CurvedAnimation(
      parent: _entranceController,
      curve: const Interval(0.0, 0.3, curve: Curves.easeOutCubic),
    );
    _imageAnim = CurvedAnimation(
      parent: _entranceController,
      curve: const Interval(0.12, 0.45, curve: Curves.easeOutCubic),
    );
    _cardAnim = CurvedAnimation(
      parent: _entranceController,
      curve: const Interval(0.25, 0.6, curve: Curves.easeOutCubic),
    );
    _carouselAnim = CurvedAnimation(
      parent: _entranceController,
      curve: const Interval(0.4, 0.8, curve: Curves.easeOutCubic),
    );
    _entranceController.forward();
    _gradientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();

    GenerationState.instance.addListener(_onGenerationChange);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_currentNotchX == 0) {
      final screenWidth = MediaQuery.of(context).size.width;
      _currentNotchX = _getNavItemCenterX(0, screenWidth);
      _notchStartX = _currentNotchX;
      _notchEndX = _currentNotchX;
    }
  }

  @override
  void dispose() {
    GenerationState.instance.removeListener(_onGenerationChange);
    _userChangesSubscription.cancel();
    _carouselController.dispose();
    _navAnimController.dispose();
    _entranceController.dispose();
    _gradientController.dispose();
    super.dispose();
  }

  void _onGenerationChange() {
    if (mounted) setState(() {});
  }

  void _refreshHomeProfilePhoto() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    _homeProfilePhotosFuture =
        uid == null ? null : SocialService.instance.profilePhotos(uid);
  }

  Future<void> _openOwnCommunityProfile(String name) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SocialProfilePage(
          name: name,
          isOwnProfile: true,
          userId: FirebaseAuth.instance.currentUser?.uid,
        ),
      ),
    );
    if (mounted) setState(_refreshHomeProfilePhoto);
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;

    return Scaffold(
      extendBody: true,
      backgroundColor: AppPalette.page(context),
      bottomNavigationBar: Stack(
        children: [
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: MediaQuery.of(context).viewPadding.bottom,
            child: ColoredBox(
                color: AppPalette.isDark(context)
                    ? const Color(0xFF2C2C2C)
                    : Colors.white),
          ),
          SafeArea(
            top: false,
            left: false,
            right: false,
            child: Material(
              color: Colors.transparent,
              child: SizedBox(
                height: _navBarHeight + _circleElevation + 6,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      height: _navBarHeight,
                      child: AnimatedBuilder(
                        animation: _navCurve,
                        builder: (context, child) {
                          return CustomPaint(
                            size: Size(screenWidth, _navBarHeight),
                            painter: _NavBarPainter(
                              notchCenterX: _isNavTransitioning
                                  ? _lerpDouble(
                                      _getNavItemCenterX(
                                          _prevIndex, screenWidth),
                                      _getNavItemCenterX(
                                          _selectedIndex, screenWidth),
                                      _navCurve.value)
                                  : _getNavItemCenterX(
                                      _selectedIndex, screenWidth),
                              notchRadius: _notchRadius,
                              barHeight: _navBarHeight,
                              darkMode: AppPalette.isDark(context),
                            ),
                          );
                        },
                      ),
                    ),
                    Positioned(
                      bottom: 11,
                      left: 0,
                      right: 0,
                      height: _navBarHeight + _circleElevation + 6,
                      child: SafeArea(
                        top: false,
                        bottom: false,
                        left: false,
                        right: false,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12.0),
                          child: AnimatedBuilder(
                            animation: _navCurve,
                            builder: (context, child) {
                              return Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceAround,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  _buildNavItem(0, 'assets/home_highlight.png',
                                      screenWidth),
                                  _buildNavItem(
                                      1, 'assets/community.png', screenWidth),
                                  _buildNavItem(
                                      2, 'assets/marketplace.png', screenWidth),
                                  _buildNavItem(3, null, screenWidth,
                                      icon: Icons.library_music_rounded),
                                  _buildNavItem(
                                      4, 'assets/setting.png', screenWidth),
                                ],
                              );
                            },
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
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            _buildBody(),
            _buildGenerationBanner(),
            if (kDebugMode && _selectedIndex == 0)
              Positioned(
                top: 8,
                right: 12,
                child: Material(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(24),
                  elevation: 2,
                  child: IconButton(
                    tooltip: 'Replay splash (debug)',
                    icon: const Icon(Icons.replay_rounded),
                    onPressed: () => VectorSplashScreen.debugReplay(context),
                  ),
                ),
              ),
            if (GenerationState.instance.hasError &&
                GenerationState.instance.generationLimitReached)
              _buildGenerationLimitOverlay(),
          ],
        ),
      ),
    );
  }

  void _handleUtilityCardTap(BuildContext context, String type) {
    switch (type) {
      case 'metronome':
        Navigator.push(
            context, MaterialPageRoute(builder: (_) => const MetronomePage()));
        break;
      case 'tuner':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ChooseTunerInstrumentPage()),
        ).then((instrument) {
          if (instrument != null && mounted && context.mounted) {
            Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => TunerPage(instrument: instrument)),
            );
          }
        });
        break;
      case 'voicePitch':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const VoiceRangePage()),
        );
        break;
      case 'pitchDetector':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const PitchDetectorPage()),
        );
        break;
    }
  }

  void _openSheetGeneration(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 950),
        reverseTransitionDuration: const Duration(milliseconds: 500),
        pageBuilder: (_, __, ___) => const SheetGenerationPage(),
        transitionsBuilder: (context, animation, _, child) {
          return LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final value = animation.value;

              double panelOffset(double delay) {
                final enter = Curves.easeOutCubic.transform(
                  Interval(delay, delay + .3).transform(value),
                );
                final leave = Curves.easeInCubic.transform(
                  Interval(.52 + delay * .35, .9 + delay * .08)
                      .transform(value),
                );
                return -width * (1 - enter) + width * leave;
              }

              return Stack(
                children: [
                  Opacity(
                    opacity: const Interval(.48, .66, curve: Curves.easeOut)
                        .transform(value),
                    child: child,
                  ),
                  _buildTransitionPanel(
                    panelOffset(.00),
                    Colors.black,
                  ),
                  _buildTransitionPanel(
                    panelOffset(.09),
                    Colors.white,
                  ),
                  _buildTransitionPanel(
                    panelOffset(.18),
                    const Color(0xFFD30906),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildTransitionPanel(double offset, Color color) {
    return Positioned.fill(
      child: Transform.translate(
        offset: Offset(offset, 0),
        child: IgnorePointer(child: ColoredBox(color: color)),
      ),
    );
  }

  Widget _buildIllustrationFor(String type) {
    switch (type) {
      case 'metronome':
        return Image.asset('assets/metronome.png', fit: BoxFit.contain);
      case 'tuner':
        return _buildTunerIllustration();
      default:
        return const SizedBox.shrink();
    }
  }

  void _openSheet(BuildContext context, Widget sheet) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (context) => sheet,
    );
  }

  double _getNavItemCenterX(int index, double screenWidth) {
    const sidePadding = 12.0;
    final freeSpace =
        screenWidth - sidePadding * 2 - _circleSize * _navItemCount;
    final firstCenter =
        sidePadding + freeSpace / (_navItemCount * 2) + _circleSize / 2;
    final centerSpacing = _circleSize + freeSpace / _navItemCount;
    return firstCenter + index * centerSpacing;
  }

  Widget _buildNavItem(int index, String? iconPath, double screenWidth,
      {IconData? icon}) {
    final t = _navCurve.value;

    final double animT;
    double horizontalOffset = 0;

    if (_isNavTransitioning && _navAnimController.isAnimating) {
      if (index == _selectedIndex) {
        animT = t;
        final oldCenter = _getNavItemCenterX(_prevIndex, screenWidth);
        final newCenter = _getNavItemCenterX(_selectedIndex, screenWidth);
        horizontalOffset = (oldCenter - newCenter) * (1.0 - t);
      } else {
        animT = 0.0;
      }
    } else {
      animT = (index == _selectedIndex) ? 1.0 : 0.0;
    }

    final double circleY = _lerpDouble(0.55, -0.43, animT);
    final activeColor = AppPalette.isDark(context)
        ? const Color(0xFFD30A02)
        : const Color(0xFF1C1C1C);
    final Color circleColor =
        Color.lerp(Colors.transparent, activeColor, animT)!;
    final inactiveIcon =
        AppPalette.isDark(context) ? Colors.white : const Color(0xFF3A3A3A);
    final Color iconTint = Color.lerp(inactiveIcon, Colors.white, animT)!;
    final double circleScale = _lerpDouble(0.92, 1.1, animT);

    return GestureDetector(
      onTap: () => _onNavTap(index, screenWidth),
      child: SizedBox(
        width: _circleSize,
        height: _circleSize + _circleElevation,
        child: Align(
          alignment: Alignment(0, circleY),
          child: Transform.translate(
            offset: Offset(horizontalOffset, 0),
            child: Transform.scale(
              scale: circleScale,
              child: Container(
                width: _circleSize,
                height: _circleSize,
                decoration: BoxDecoration(
                  color: circleColor,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: icon != null
                      ? Icon(icon, size: 24, color: iconTint)
                      : Image.asset(
                          iconPath!,
                          width: 24,
                          height: 24,
                          color: iconTint,
                          errorBuilder: (context, error, stackTrace) => Icon(
                            Icons.circle,
                            size: 22,
                            color: iconTint,
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _onNavTap(int index, double screenWidth) {
    if (_selectedIndex == index || _isNavTransitioning) return;
    _prevIndex = _selectedIndex;
    final oldX = _getNavItemCenterX(_prevIndex, screenWidth);
    final newX = _getNavItemCenterX(index, screenWidth);
    _notchStartX = oldX;
    _notchEndX = newX;
    _isNavTransitioning = true;
    _selectedIndex = index;
    final distance = (newX - oldX).abs();
    final maxDistance = screenWidth * 0.7;
    final extraMs = ((distance / maxDistance) * 200).round();
    _navAnimController.duration = Duration(milliseconds: 300 + extraMs);
    _navAnimController.forward(from: 0);
  }

  double _lerpDouble(double a, double b, double t) {
    return a + (b - a) * t;
  }

  Future<void> _confirmCancelGeneration() async {
    final dark = AppPalette.isDark(context);
    final shouldCancel = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor:
            dark ? const Color(0xFF252525) : const Color(0xFFFFF9F6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.music_note_rounded,
                  color: const Color(0xFFD30A02), size: 30),
              const SizedBox(height: 14),
              Text(
                'Cancel generation?',
                style: TextStyle(
                  color: AppPalette.text(dialogContext),
                  fontSize: 21,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Your sheet music will stop generating and this progress will be lost.',
                style: TextStyle(
                    color: AppPalette.muted(dialogContext),
                    fontSize: 13,
                    height: 1.35),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppPalette.text(dialogContext),
                        side: BorderSide(
                            color: AppPalette.text(dialogContext)
                                .withValues(alpha: .28)),
                        minimumSize: const Size.fromHeight(46),
                      ),
                      child: const Text('Continue'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFD30A02),
                        minimumSize: const Size.fromHeight(46),
                      ),
                      child: const Text('Stop'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (shouldCancel == true && mounted) {
      GenerationState.instance.cancelGeneration();
    }
  }

  Widget _buildGenerationBanner() {
    final gen = GenerationState.instance;
    if (gen.hasError && gen.generationLimitReached) {
      return const SizedBox.shrink();
    }
    if (!gen.isGenerating && !gen.isFinished && !gen.hasError) {
      return const SizedBox.shrink();
    }

    if (gen.isGenerating) {
      return _buildActiveGenerationBanner(gen);
    }

    Color bgColor;
    IconData icon;
    String title;
    String subtitle;
    VoidCallback? onTap;
    bool showProgress = false;

    if (gen.isGenerating) {
      bgColor = const Color(0xFFBA0007);
      icon = Icons.hourglass_top_rounded;
      title = 'Generating sheet...';
      subtitle = gen.statusText;
      showProgress = true;
      onTap = null;
    } else if (gen.isFinished && gen.result != null) {
      bgColor = const Color(0xFF2E7D32);
      icon = Icons.check_circle_outline;
      title = gen.mode == 'band'
          ? 'Band score ready!'
          : '${gen.instrumentName} sheet ready!';
      subtitle = 'Tap to view';
      onTap = () {
        final result = gen.result;
        final instrument = gen.instrumentName;
        gen.clearResult();
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => MusicSheetPage(
              instrumentName: instrument,
              apiResult: result,
            ),
          ),
        );
      };
    } else if (gen.hasError) {
      bgColor = const Color(0xFFC62828);
      icon = Icons.error_outline;
      title = 'Generation failed';
      subtitle = gen.errorMsg ?? 'Unknown error';
      onTap = () => gen.dismissBanner();
    } else {
      return const SizedBox.shrink();
    }

    return Positioned(
      bottom: _navBarHeight + _circleElevation + 18,
      left: 16,
      right: 16,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: bgColor.withValues(alpha: 0.4),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(icon, color: Colors.white, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontFamily: 'Instrument Sans',
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      showProgress
                          ? '$subtitle  ${((gen.progress.clamp(0.0, 1.0)) * 100).round()}%'
                          : subtitle,
                      style: TextStyle(
                          fontFamily: 'Instrument Sans',
                          color: Colors.white.withValues(alpha: 0.8),
                          fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (showProgress) ...[
                      const SizedBox(height: 6),
                      LinearProgressIndicator(
                        value: gen.progress > 0
                            ? gen.progress.clamp(0.0, 1.0)
                            : null,
                        backgroundColor: Colors.white.withValues(alpha: 0.2),
                        valueColor:
                            const AlwaysStoppedAnimation<Color>(Colors.white),
                        minHeight: 2,
                      ),
                    ],
                  ],
                ),
              ),
              if (!gen.isGenerating)
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 18),
                  onPressed: () => gen.dismissBanner(),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGenerationLimitOverlay() {
    final gen = GenerationState.instance;
    const red = Color(0xFFBA0007);
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.55),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppPalette.surface(context),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: const [
                    BoxShadow(color: Color(0x33000000), blurRadius: 28),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircleAvatar(
                        radius: 29,
                        backgroundColor: Color(0x1FBA0007),
                        child:
                            Icon(Icons.music_off_rounded, color: red, size: 29),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        'Generation limit reached',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: 'Instrument Sans',
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                          color: AppPalette.text(context),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        gen.errorMsg ??
                            'You have used all your sheet generations for this month.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: 'Instrument Sans',
                          fontSize: 14,
                          height: 1.4,
                          color: AppPalette.muted(context),
                        ),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: gen.dismissBanner,
                          style: FilledButton.styleFrom(
                            backgroundColor: red,
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text('Got it'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActiveGenerationBanner(GenerationState gen) {
    final percentage = (gen.progress.clamp(0.0, 1.0) * 100).round();
    return Positioned(
      bottom: _navBarHeight + _circleElevation + 18,
      left: 16,
      right: 16,
      child: GestureDetector(
        onTap: _confirmCancelGeneration,
        child: AnimatedBuilder(
          animation: _gradientController,
          builder: (context, _) {
            final darkMode = Theme.of(context).brightness == Brightness.dark;
            return Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: darkMode
                    ? Border.all(
                        color: const Color(0xFFD30A02).withValues(alpha: .72),
                        width: 1.15,
                      )
                    : null,
                boxShadow: darkMode
                    ? [
                        BoxShadow(
                          color: const Color(0xFFD30A02).withValues(alpha: .28),
                          blurRadius: 12,
                          spreadRadius: .4,
                        ),
                      ]
                    : const [],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(13),
                child: Container(
                  height: 76,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: ClipPath(
                          clipper: _GenerationFluidClipper(
                            phase: _gradientController.value,
                            progress: gen.progress.clamp(0.0, 1.0),
                          ),
                          child: const ColoredBox(color: Colors.white),
                        ),
                      ),
                      _buildGenerationBannerContent(
                        gen,
                        percentage,
                        Colors.white,
                      ),
                      Positioned.fill(
                        child: ClipPath(
                          clipper: _GenerationFluidClipper(
                            phase: _gradientController.value,
                            progress: gen.progress.clamp(0.0, 1.0),
                          ),
                          child: _buildGenerationBannerContent(
                            gen,
                            percentage,
                            Colors.black,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildGenerationBannerContent(
    GenerationState gen,
    int percentage,
    Color color,
  ) {
    return Row(
      children: [
        const SizedBox(width: 20),
        Icon(Icons.music_note_rounded, color: color, size: 27),
        const Spacer(),
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '$percentage%',
              style: TextStyle(
                fontFamily: 'Instrument Sans',
                color: color,
                fontSize: 24,
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(
              gen.statusText,
              style: TextStyle(
                fontFamily: 'Instrument Sans',
                color: color.withValues(alpha: .82),
                fontSize: 10,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        const Spacer(),
        Icon(Icons.description_outlined, color: color, size: 26),
        const SizedBox(width: 20),
      ],
    );
  }

  Widget _buildBody() {
    Widget page;
    switch (_selectedIndex) {
      case 0:
        page = _buildHomePage();
        break;
      case 1:
        page = const SocialPage();
        break;
      case 2:
        page = const MarketplacePage();
        break;
      case 3:
        page = const SavedSheetsPage();
        break;
      case 4:
        page = const SettingsPage();
        break;
      default:
        page = _buildHomePage();
    }
    // Keep exactly one page in the stack. An outgoing page can otherwise
    // remain above Social briefly and absorb its touches.
    return KeyedSubtree(
      key: ValueKey(_selectedIndex),
      child: page,
    );
  }

  Widget _buildHomePage() {
    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallScreen = screenWidth < 360;
    // Roomy height so the Go now button and multi-line description never get cut off
    final sheetCardHeight = isSmallScreen ? 285.0 : 310.0;
    final displayName = FirebaseAuth.instance.currentUser?.displayName?.trim();
    final greetingName =
        displayName?.isNotEmpty == true ? displayName! : 'Musician';

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      key: const ValueKey('home_scroll'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header section
          AnimatedBuilder(
            animation: _headerAnim,
            builder: (context, child) {
              final t = _headerAnim.value;
              return Opacity(
                opacity: t,
                child: Transform.translate(
                  offset: Offset(0, 30 * (1 - t)),
                  child: child,
                ),
              );
            },
            child: SizedBox(
              width: double.infinity,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 24.0,
                    top: 16.0,
                    child: StreamBuilder<SocialProfileSummary?>(
                      stream: SocialService.instance.currentProfile(),
                      builder: (context, snapshot) {
                        final profile = snapshot.data;
                        final name = profile?.name.trim().isNotEmpty == true
                            ? profile!.name
                            : greetingName;
                        return FutureBuilder<Map<String, dynamic>?>(
                          future: _homeProfilePhotosFuture,
                          builder: (context, photoSnapshot) {
                            final storedAvatar =
                                photoSnapshot.data?['avatar_url'] as String?;
                            final avatarUrl =
                                storedAvatar?.trim().isNotEmpty == true
                                    ? storedAvatar
                                    : profile?.avatarUrl;
                            return Semantics(
                              button: true,
                              label: 'Open community profile',
                              child: GestureDetector(
                                onTap: () => _openOwnCommunityProfile(name),
                                child: SocialAccountAvatar(
                                  name: name,
                                  imageUrl: avatarUrl,
                                  size: 34,
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                  Positioned(
                    right: -20,
                    top: -20,
                    child: AnimatedBuilder(
                      animation: _imageAnim,
                      builder: (context, child) {
                        return Opacity(
                          opacity: _imageAnim.value,
                          child: Transform.translate(
                            offset: Offset(0, 40 * (1 - _imageAnim.value)),
                            child: child,
                          ),
                        );
                      },
                      child: Image.asset(
                        'assets/saxophonist.png',
                        height: 340,
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            height: 300,
                            width: 200,
                            alignment: Alignment.bottomRight,
                            child: Icon(
                              Icons.music_note,
                              size: 150,
                              color: const Color(0xFFBA0007).withOpacity(0.15),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 28.0, top: 76.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _StaggeredText(
                          text: 'Good Morning,',
                          animation: _headerAnim,
                          style: TextStyle(
                            fontFamily: fontFamily,
                            fontSize: isSmallScreen ? 14 : 16,
                            fontWeight: FontWeight.w400,
                            color: AppPalette.text(context),
                          ),
                        ),
                        _StaggeredText(
                          text: greetingName,
                          animation: _headerAnim,
                          style: TextStyle(
                            fontFamily: fontFamily,
                            fontSize: isSmallScreen ? 36 : 48,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -1.0,
                            color: AppPalette.text(context),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          width: 60,
                          height: 3,
                          color: const Color(0xFFBA0007),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'CREATE.\nPRATICE.\nPERFORM.',
                          style: TextStyle(
                            fontFamily: fontFamily,
                            fontSize: isSmallScreen ? 11 : 14,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.5,
                            height: 1.3,
                            color: const Color(0xFFBA0007),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 280),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Sheet Generation Card
          AnimatedBuilder(
            animation: _cardAnim,
            builder: (context, child) {
              final t = _cardAnim.value;
              return Opacity(
                opacity: t,
                child: Transform.translate(
                  offset: Offset(0, 30 * (1 - t)),
                  child: child,
                ),
              );
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  splashColor: Colors.white.withValues(alpha: .14),
                  highlightColor: Colors.black.withValues(alpha: .13),
                  onTap: () => _openSheetGeneration(context),
                  child: AnimatedBuilder(
                    animation: _gradientController,
                    builder: (context, child) => Container(
                      width: double.infinity,
                      height: sheetCardHeight,
                      decoration: BoxDecoration(
                        gradient:
                            _animatedGradient(true, _gradientController.value),
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF540003).withOpacity(0.3),
                            blurRadius: 20,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: CustomPaint(
                        foregroundPainter: _RunningGlowBorderPainter(
                          progress: _gradientController.value,
                        ),
                        child: child,
                      ),
                    ),
                    child: Stack(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(20.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                decoration: BoxDecoration(
                                  color: Colors.black26,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 6),
                                child: Text(
                                  'Feature',
                                  style: TextStyle(
                                    fontFamily: fontFamily,
                                    color: Colors.white,
                                    fontSize: isSmallScreen ? 10 : 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'SHEET\nGENERATION',
                                style: TextStyle(
                                  fontFamily: fontFamily,
                                  color: Colors.white,
                                  fontSize: isSmallScreen ? 20 : 26,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.5,
                                  height: 1.1,
                                ),
                              ),
                              const SizedBox(height: 8),
                              SizedBox(
                                width: isSmallScreen ? 130 : 170,
                                child: Text(
                                  'Generate a music sheet by uploading your own audio /files.',
                                  style: TextStyle(
                                    fontFamily: fontFamily,
                                    color: Colors.white.withOpacity(0.85),
                                    fontSize: isSmallScreen ? 10 : 12,
                                    height: 1.3,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 20),
                              _PressActionButton(
                                isSmallScreen: isSmallScreen,
                                onPressed: () => _openSheetGeneration(context),
                              ),
                            ],
                          ),
                        ),
                        Positioned(
                          right: -15,
                          top: 20,
                          bottom: 0,
                          width: 210,
                          child: IgnorePointer(
                            child: Image.asset(
                              'assets/sheet_music_preview.png',
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 20),

          // Other Tools header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'OTHER TOOLS',
                      style: TextStyle(
                        fontFamily: fontFamily,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: AppPalette.text(context),
                        letterSpacing: 0.5,
                      ),
                    ),
                    GestureDetector(
                      onTap: () => Navigator.push(context,
                          MaterialPageRoute(builder: (_) => const ToolsPage())),
                      child: Text(
                        'See all  >',
                        style: TextStyle(
                          fontFamily: fontFamily,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppPalette.muted(context),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Container(
                  height: 1,
                  color: AppPalette.border(context),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Utility Cards Carousel
          AnimatedBuilder(
            animation: _carouselAnim,
            builder: (context, child) {
              final t = _carouselAnim.value;
              return Opacity(
                opacity: t,
                child: Transform.translate(
                  offset: Offset(0, 30 * (1 - t)),
                  child: child,
                ),
              );
            },
            child: SizedBox(
              height: 200,
              child: PageView.builder(
                controller: _carouselController,
                padEnds: false,
                physics: const PageScrollPhysics(),
                onPageChanged: (index) {
                  setState(() => _currentPage = index);
                },
                itemCount: _utilityCardData.length,
                itemBuilder: (context, index) {
                  final data = _utilityCardData[index];
                  final isActive = index == _currentPage;
                  return AnimatedScale(
                    scale: isActive ? 1.0 : 0.78,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                    child: Padding(
                      padding: EdgeInsets.only(
                        left: index == 0 ? 16.0 : 4.0,
                        right:
                            index == _utilityCardData.length - 1 ? 16.0 : 4.0,
                      ),
                      child: _buildUtilityCard(
                        title: data['title'] as String,
                        text: data['text'] as String,
                        isDark: data['isDark'] as bool,
                        onTap: () {
                          if (isActive) {
                            _handleUtilityCardTap(
                                context, data['type'] as String);
                          } else {
                            _carouselController.animateToPage(
                              index,
                              duration: const Duration(milliseconds: 400),
                              curve: Curves.easeOutCubic,
                            );
                          }
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
          ),

          const SizedBox(height: 14),

          // Carousel page indicator dots
          Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_utilityCardData.length, (index) {
                final bool isActive = index == _currentPage;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: isActive ? 18.0 : 6.0,
                  height: 6.0,
                  decoration: BoxDecoration(
                    color: isActive
                        ? const Color(0xFFBA0007)
                        : const Color(0xFFBA0007).withOpacity(0.2),
                    borderRadius: BorderRadius.circular(3),
                  ),
                );
              }),
            ),
          ),

          const SizedBox(height: 100),
        ],
      ),
    );
  }

  Widget _buildUtilityCard({
    required String title,
    required String text,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    final titleColor = isDark ? Colors.white : const Color(0xFF8A0004);
    final textColor = isDark
        ? Colors.white.withOpacity(0.8)
        : Colors.black87.withOpacity(0.7);
    final isSmallScreen = MediaQuery.of(context).size.width < 360;
    final darkMode = AppPalette.isDark(context);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedBuilder(
        animation: _gradientController,
        builder: (context, child) => Container(
          decoration: BoxDecoration(
            gradient: _animatedGradient(isDark, _gradientController.value),
            borderRadius: BorderRadius.circular(10),
            border: darkMode
                ? Border.all(color: const Color(0xFFE30B05), width: 1.25)
                : null,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.15),
                blurRadius: 8,
                spreadRadius: -2,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: child,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontFamily: fontFamily,
                  color: titleColor,
                  fontSize: isSmallScreen ? 13 : 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                text,
                style: TextStyle(
                  fontFamily: fontFamily,
                  color: textColor,
                  fontSize: isSmallScreen ? 8 : 10,
                  height: 1.25,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  LinearGradient _animatedGradient(bool dark, double value) {
    final first = dark ? const Color(0xFFD90808) : const Color(0xFFFFFFFF);
    final second = dark ? const Color(0xFF650004) : const Color(0xFFFFE5DE);
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [first, second],
      transform: GradientRotation(math.pi * 2 * value),
    );
  }

  Widget _buildTunerIllustration() {
    return CustomPaint(
      painter: _TunerPainter(color: const Color(0xFFBA0007).withOpacity(0.12)),
    );
  }

  Widget _buildVoicePitchIllustration() {
    return CustomPaint(
      painter: _VoicePitchPainter(color: Colors.white24),
    );
  }

  Widget _buildPitchDetectorIllustration() {
    return CustomPaint(
      painter:
          _TuningForkPainter(color: const Color(0xFFBA0007).withOpacity(0.12)),
    );
  }
}

class _PressActionButton extends StatefulWidget {
  final bool isSmallScreen;
  final VoidCallback onPressed;

  const _PressActionButton({
    required this.isSmallScreen,
    required this.onPressed,
  });

  @override
  State<_PressActionButton> createState() => _PressActionButtonState();
}

class _PressActionButtonState extends State<_PressActionButton>
    with TickerProviderStateMixin {
  late final AnimationController _pressController;

  @override
  void initState() {
    super.initState();
    _pressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 110),
    );
  }

  @override
  void dispose() {
    _pressController.dispose();
    super.dispose();
  }

  Future<void> _handleTap() async {
    if (_pressController.isAnimating) return;
    _pressController.forward().then((_) {
      if (mounted) _pressController.reverse();
    });
    await Future<void>.delayed(const Duration(milliseconds: 180));
    if (mounted) widget.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pressController,
      builder: (context, _) {
        return Transform.scale(
          scale: 1 - (_pressController.value * .035),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _handleTap,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                color: Colors.black,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  child: Text(
                    'Go now',
                    style: TextStyle(
                      fontFamily: 'Instrument Sans',
                      color: Colors.white,
                      fontSize: widget.isSmallScreen ? 11 : 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RunningGlowBorderPainter extends CustomPainter {
  final double progress;

  const _RunningGlowBorderPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    const radius = Radius.circular(10);
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
        Offset.zero & size,
        radius,
      ));
    final metric = path.computeMetrics().first;
    final length = metric.length;
    final start = length * progress;
    const segmentFraction = 0.16;
    final segmentLength = length * segmentFraction;
    final trace = Path();

    if (start + segmentLength <= length) {
      trace.addPath(
          metric.extractPath(start, start + segmentLength), Offset.zero);
    } else {
      trace.addPath(metric.extractPath(start, length), Offset.zero);
      trace.addPath(
          metric.extractPath(0, (start + segmentLength) - length), Offset.zero);
    }

    canvas.drawPath(
      trace,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.62)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    canvas.drawPath(
      trace,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.95)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.15
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _RunningGlowBorderPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class _GenerationFluidClipper extends CustomClipper<Path> {
  final double phase;
  final double progress;

  const _GenerationFluidClipper({required this.phase, required this.progress});

  @override
  Path getClip(Size size) {
    final surfaceHeight = size.height * (.84 - .7 * progress.clamp(0.0, 1.0));
    final fluid = Path()
      ..moveTo(0, size.height)
      ..lineTo(0, surfaceHeight);

    for (double x = 0; x <= size.width; x += 3) {
      final wave =
          math.sin((x / size.width * math.pi * 3) + phase * math.pi * 2);
      final secondWave = math.sin(
        (x / size.width * math.pi * 5) - phase * math.pi * 2,
      );
      fluid.lineTo(x, surfaceHeight + wave * 4 + secondWave * 2);
    }
    return fluid
      ..lineTo(size.width, size.height)
      ..close();
  }

  @override
  bool shouldReclip(covariant _GenerationFluidClipper oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.progress != progress;
}

class _StaggeredText extends StatelessWidget {
  final String text;
  final Animation<double> animation;
  final TextStyle style;

  const _StaggeredText({
    required this.text,
    required this.animation,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: List.generate(text.length, (i) {
            final charDelay = i / (text.length + 4);
            final charAnim = CurvedAnimation(
              parent: animation,
              curve: Interval(
                charDelay,
                (charDelay + 0.5).clamp(0.0, 1.0),
                curve: Curves.easeOutCubic,
              ),
            );
            return Opacity(
              opacity: charAnim.value,
              child: Transform.translate(
                offset: Offset(0, 20 * (1 - charAnim.value)),
                child: Text(
                  text[i] == '\n' ? '\n' : text[i],
                  style: style,
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

// Drawers for illustrations on the cards
class _TunerPainter extends CustomPainter {
  final Color color;
  _TunerPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5;

    canvas.drawArc(
      Rect.fromLTWH(size.width * 0.15, size.height * 0.2, size.width * 0.7,
          size.height * 0.7),
      math.pi,
      math.pi,
      false,
      paint,
    );

    final indicatorPaint = Paint()
      ..color = color.withOpacity(color.opacity * 2.5)
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke;

    canvas.drawLine(
      Offset(size.width * 0.5, size.height * 0.85),
      Offset(size.width * 0.65, size.height * 0.3),
      indicatorPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _VoicePitchPainter extends CustomPainter {
  final Color color;
  _VoicePitchPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withOpacity(color.opacity * 1.5)
      ..style = PaintingStyle.fill;

    final cols = [0.4, 0.7, 0.5, 0.9, 0.6, 0.8, 0.3];
    final colWidth = size.width / (cols.length * 1.6);
    for (int i = 0; i < cols.length; i++) {
      final h = size.height * 0.6 * cols[i];
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            size.width * 0.1 + i * colWidth * 1.5,
            size.height * 0.5 - h / 2,
            colWidth,
            h,
          ),
          const Radius.circular(4),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _TuningForkPainter extends CustomPainter {
  final Color color;
  _TuningForkPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 4.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path = Path()
      ..moveTo(size.width * 0.35, size.height * 0.25)
      ..lineTo(size.width * 0.35, size.height * 0.6)
      ..arcToPoint(
        Offset(size.width * 0.65, size.height * 0.6),
        radius: const Radius.circular(15),
        clockwise: false,
      )
      ..lineTo(size.width * 0.65, size.height * 0.25);

    canvas.drawPath(path, paint);

    canvas.drawLine(
      Offset(size.width * 0.5, size.height * 0.69),
      Offset(size.width * 0.5, size.height * 0.88),
      paint,
    );

    final fillPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
        Offset(size.width * 0.5, size.height * 0.88), 4.5, fillPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _NavBarPainter extends CustomPainter {
  final double notchCenterX;
  final double notchRadius;
  final double barHeight;
  final bool darkMode;

  _NavBarPainter({
    required this.notchCenterX,
    required this.notchRadius,
    required this.barHeight,
    required this.darkMode,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final halfW = _circleSize * 0.78;
    final depth = _circleSize * 0.92;
    // The selected 48px control is scaled to 1.1 and sits ~34px below
    // the bar's top. Leave a small clearance beneath its 26.4px radius.
    final notchDepth = _circleSize * 1.35;

    // Shadow path (slightly larger, offset down)
    final shadowPath = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, barHeight + 4)
      ..lineTo(notchCenterX + halfW + 12, barHeight + 4)
      ..cubicTo(
        notchCenterX + halfW * 0.88,
        barHeight + 4,
        notchCenterX + halfW * 0.88,
        depth * 0.96,
        notchCenterX,
        depth + 2,
      )
      ..cubicTo(
        notchCenterX - halfW * 0.88,
        depth * 0.96,
        notchCenterX - halfW * 0.88,
        barHeight + 4,
        notchCenterX - halfW - 12,
        barHeight + 4,
      )
      ..lineTo(0, barHeight + 4)
      ..close();

    final shadowPaint = Paint()
      ..color = Colors.transparent
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10)
      ..style = PaintingStyle.fill;
    canvas.drawPath(shadowPath, shadowPaint);

    // Bar background path with notch cutout
    final barPath = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, barHeight)
      ..lineTo(0, barHeight)
      ..close();

    // Notch cutout with rounded shoulders where the concave meets the bar.
    final cornerR = 14.0;
    final notchTopY = -2.0;
    final leftStart = notchCenterX - halfW - 12;
    final rightEnd = notchCenterX + halfW + 12;
    final notchPath = Path()
      ..moveTo(leftStart, notchTopY)
      ..quadraticBezierTo(
        leftStart + cornerR * 0.55,
        notchTopY,
        leftStart + cornerR,
        notchTopY + cornerR * 0.55,
      )
      ..cubicTo(
        notchCenterX - halfW * 0.92,
        notchDepth * 0.52,
        notchCenterX - halfW * 0.55,
        notchDepth,
        notchCenterX,
        notchDepth,
      )
      ..cubicTo(
        notchCenterX + halfW * 0.55,
        notchDepth,
        notchCenterX + halfW * 0.92,
        notchDepth * 0.52,
        rightEnd - cornerR,
        notchTopY + cornerR * 0.55,
      )
      ..quadraticBezierTo(
        rightEnd - cornerR * 0.55,
        notchTopY,
        rightEnd,
        notchTopY,
      )
      ..lineTo(rightEnd, -30)
      ..lineTo(leftStart, -30)
      ..close();

    final barWithNotch = Path.combine(
      PathOperation.difference,
      barPath,
      notchPath,
    );

    // Compact navigation surface with a concave cradle for the active control.
    final barPaint = Paint()
      ..color = darkMode ? const Color(0xFF2C2C2C) : Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawPath(barWithNotch, barPaint);

    // One continuous top edge, curved through the concave rather than crossing it.
    final contourShadow = Path()
      ..moveTo(0, 0)
      ..lineTo(leftStart, 0)
      ..quadraticBezierTo(
        leftStart + cornerR * 0.55,
        0,
        leftStart + cornerR,
        cornerR * 0.55,
      )
      ..cubicTo(
        notchCenterX - halfW * 0.92,
        notchDepth * 0.52,
        notchCenterX - halfW * 0.55,
        notchDepth,
        notchCenterX,
        notchDepth,
      )
      ..cubicTo(
        notchCenterX + halfW * 0.55,
        notchDepth,
        notchCenterX + halfW * 0.92,
        notchDepth * 0.52,
        rightEnd - cornerR,
        cornerR * 0.55,
      )
      ..quadraticBezierTo(rightEnd - cornerR * 0.55, 0, rightEnd, 0)
      ..lineTo(size.width, 0);

    final contourShadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: .16)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round;
    if (!darkMode) {
      canvas.save();
      canvas.translate(0, -2);
      canvas.drawPath(contourShadow, contourShadowPaint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _NavBarPainter oldDelegate) {
    return oldDelegate.notchCenterX != notchCenterX ||
        oldDelegate.notchRadius != notchRadius ||
        oldDelegate.barHeight != barHeight ||
        oldDelegate.darkMode != darkMode;
  }
}
