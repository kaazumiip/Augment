import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'app_logo.dart';

class MorphingSearchBar extends StatefulWidget {
  const MorphingSearchBar({
    super.key,
    required this.controller,
    required this.onChanged,
    this.onSubmitted,
    this.onOpen,
    this.hintText = 'Search',
    this.accent = const Color(0xFFCA000A),
    this.width = 190,
    this.collapsedSize = 44,
    this.heroTag,
    this.autoExpand = false,
    this.onClose,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final ValueChanged<String>? onSubmitted;
  final Future<void> Function()? onOpen;
  final String hintText;
  final Color accent;
  final double width;
  final double collapsedSize;
  final String? heroTag;
  final bool autoExpand;
  final VoidCallback? onClose;

  @override
  State<MorphingSearchBar> createState() => _MorphingSearchBarState();
}

class _MorphingSearchBarState extends State<MorphingSearchBar> {
  final _focusNode = FocusNode();
  var _expanded = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus && widget.controller.text.isEmpty && mounted) {
        setState(() => _expanded = false);
      }
    });
    if (widget.autoExpand) {
      // Wait for the compact Hero to land, then visibly grow the real field.
      Future<void>.delayed(const Duration(milliseconds: 205), () {
        if (!mounted) {
          return;
        }
        _expand();
      });
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _expand() {
    if (widget.onOpen != null) {
      widget.onOpen!();
      return;
    }
    setState(() => _expanded = true);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _focusNode.requestFocus());
  }

  void _clearOrClose() {
    if (widget.onClose != null) {
      widget.onClose!();
      return;
    }
    _focusNode.unfocus();
    setState(() => _expanded = false);
  }

  @override
  Widget build(BuildContext context) {
    const muted = Color(0xFF898989);
    final search = AnimatedContainer(
      duration: const Duration(milliseconds: 230),
      curve: Curves.easeOutCubic,
      width: _expanded ? widget.width : widget.collapsedSize,
      height: _expanded ? 52 : widget.collapsedSize,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: _expanded ? Colors.white : Colors.transparent,
        borderRadius:
            BorderRadius.circular(_expanded ? 22 : widget.collapsedSize / 2),
        border: _expanded ? Border.all(color: widget.accent, width: 1.2) : null,
      ),
      child: Stack(children: [
        if (_expanded)
          Positioned(
            left: 0,
            right: 56,
            top: 2,
            bottom: 2,
            child: TextField(
              controller: widget.controller,
              focusNode: _focusNode,
              onChanged: widget.onChanged,
              onSubmitted: widget.onSubmitted,
              textAlignVertical: TextAlignVertical.center,
              style: const TextStyle(color: Colors.black, fontSize: 13),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded, color: muted, size: 20),
                hintText: 'Search',
                hintStyle: TextStyle(color: muted, fontSize: 12),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.only(top: 1),
              ).copyWith(hintText: widget.hintText),
            ),
          ),
        Positioned(
          top: _expanded ? 4 : 0,
          right: _expanded ? 4 : 0,
          child: Material(
            color: widget.accent,
            shape: const CircleBorder(),
            child: InkWell(
              onTap: _expanded ? _clearOrClose : _expand,
              customBorder: const CircleBorder(),
              child: SizedBox(
                width: _expanded ? 44 : widget.collapsedSize,
                height: _expanded ? 44 : widget.collapsedSize,
                child: Center(
                  child: _AnimatedSearchCloseIcon(isClose: _expanded),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
    if (widget.heroTag == null) {
      return search;
    }
    return Hero(
      tag: widget.heroTag!,
      createRectTween: (begin, end) => RectTween(begin: begin, end: end),
      child: Material(color: Colors.transparent, child: search),
    );
  }
}

Route<T> morphSearchRoute<T>(WidgetBuilder builder) => PageRouteBuilder<T>(
      transitionDuration: const Duration(milliseconds: 180),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (context, animation, secondaryAnimation) => builder(context),
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          Stack(children: [
        Positioned.fill(child: ColoredBox(color: AppPalette.page(context))),
        FadeTransition(
          // Let the shared search field finish its left-growing morph first.
          opacity: CurvedAnimation(
            parent: animation,
            curve: const Interval(.72, 1, curve: Curves.easeInOutCubic),
          ),
          child: child,
        ),
      ]),
    );

class _AnimatedSearchCloseIcon extends StatelessWidget {
  const _AnimatedSearchCloseIcon({required this.isClose});
  final bool isClose;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(end: isClose ? 1 : 0),
        duration: const Duration(milliseconds: 360),
        curve: Curves.easeInOutCubic,
        builder: (context, progress, child) => CustomPaint(
          size: const Size(23, 23),
          painter: _SearchClosePainter(progress),
        ),
      );
}

class _SearchClosePainter extends CustomPainter {
  const _SearchClosePainter(this.progress);
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final searchPaint = Paint()
      ..color = Colors.white.withValues(alpha: 1 - progress)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.3
      ..strokeCap = StrokeCap.round;
    final closePaint = Paint()
      ..color = Colors.white.withValues(alpha: progress)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.3
      ..strokeCap = StrokeCap.round;
    final center = Offset(size.width * .44, size.height * .44);
    canvas.drawCircle(center, size.width * .23, searchPaint);
    canvas.drawLine(Offset(size.width * .61, size.height * .61),
        Offset(size.width * .86, size.height * .86), searchPaint);
    canvas.drawLine(Offset(size.width * .23, size.height * .23),
        Offset(size.width * .77, size.height * .77), closePaint);
    canvas.drawLine(Offset(size.width * .77, size.height * .23),
        Offset(size.width * .23, size.height * .77), closePaint);
  }

  @override
  bool shouldRepaint(covariant _SearchClosePainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class LogoBackMorph extends StatelessWidget {
  const LogoBackMorph({
    super.key,
    required this.tag,
    required this.showBack,
    this.onTap,
  });

  final String tag;
  final bool showBack;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Hero(
        tag: tag,
        createRectTween: (begin, end) => RectTween(begin: begin, end: end),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(22),
            child: SizedBox(
              width: 36,
              height: 44,
              child: Center(
                child: showBack
                    ? Transform.translate(
                        offset: const Offset(-12, 0),
                        child: Icon(Icons.arrow_back_ios_new_rounded,
                            color: AppPalette.text(context), size: 21),
                      )
                    : const AppLogo(width: 32, height: 32),
              ),
            ),
          ),
        ),
      );
}
