import 'package:flutter/material.dart';

import 'generation_state.dart';
import 'app_palette.dart';
import 'band_part.dart';

class GenerationStartedPage extends StatefulWidget {
  const GenerationStartedPage({
    super.key,
    required this.instrumentName,
    required this.source,
    this.mode = 'solo',
    this.bandParts = const [],
    this.fileUrl,
    this.filePath,
  });

  final String instrumentName;
  final String source;
  final String mode;
  final List<BandPart> bandParts;
  final String? fileUrl;
  final String? filePath;

  @override
  State<GenerationStartedPage> createState() => _GenerationStartedPageState();
}

class _GenerationStartedPageState extends State<GenerationStartedPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entranceController;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 720),
    )..forward();
    GenerationState.instance.startGeneration(
      instrumentName: widget.instrumentName,
      source: widget.source,
      mode: widget.mode,
      bandParts: widget.bandParts,
      fileUrl: widget.fileUrl,
      filePath: widget.filePath,
    );
    Future<void>.delayed(const Duration(milliseconds: 900), () {
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    });
  }

  @override
  void dispose() {
    _entranceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.page(context),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildBouncingItem(
                const CircleAvatar(
                  radius: 35,
                  backgroundColor: Color(0xFF2E7D32),
                  child:
                      Icon(Icons.check_rounded, color: Colors.white, size: 42),
                ),
                0,
              ),
              const SizedBox(height: 20),
              _buildBouncingItem(
                Text(
                    widget.mode == 'band'
                        ? 'Band score is generating'
                        : 'Music sheet is generating',
                    style: TextStyle(
                        color: AppPalette.text(context),
                        fontSize: 21,
                        fontWeight: FontWeight.w800)),
                1,
              ),
              const SizedBox(height: 7),
              _buildBouncingItem(
                Text('You can keep exploring while it finishes.',
                    style: TextStyle(
                        fontSize: 13, color: AppPalette.muted(context))),
                2,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBouncingItem(Widget child, int index) {
    final animation = CurvedAnimation(
      parent: _entranceController,
      curve: Interval(.12 + index * .2, .62 + index * .14,
          curve: Curves.easeOutBack),
    );
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) => Opacity(
        opacity: animation.value.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, 14 * (1 - animation.value)),
          child: Transform.scale(
            scale: .9 + (.1 * animation.value),
            child: child,
          ),
        ),
      ),
    );
  }
}
