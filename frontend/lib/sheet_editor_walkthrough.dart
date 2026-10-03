import 'package:flutter/material.dart';

Future<void> showSheetEditorWalkthrough(
    BuildContext context, List<GlobalKey> targets) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.transparent,
    useSafeArea: false,
    builder: (_) => _EditorTour(targets: targets),
  );
}

class _EditorTour extends StatefulWidget {
  const _EditorTour({required this.targets});
  final List<GlobalKey> targets;
  @override
  State<_EditorTour> createState() => _EditorTourState();
}

class _EditorTourState extends State<_EditorTour> {
  int step = 0;
  static const messages = [
    ('Choose a note', 'Tap a note in the sheet or this note list. Use the bar selector to find the part you want.'),
    ('Change its sound', 'Up and Down change the pitch. The note-length buttons change how long it plays. Swipe this toolbar to see more tools.'),
    ('Made a mistake?', 'Undo reverses your last change. Redo brings it back. Nothing is saved until you choose Save & listen.'),
    ('Save & listen', 'This rebuilds playback from your edited notes and saves the sheet to your collection. Stay connected for playback and cloud saving.'),
  ];

  @override
  Widget build(BuildContext context) {
    final box = widget.targets[step].currentContext?.findRenderObject();
    final rect = box is RenderBox && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size : null;
    return Material(
      type: MaterialType.transparency,
      child: Stack(children: [
        Positioned.fill(child: CustomPaint(painter: _Spotlight(rect))),
        if (rect != null) Positioned.fromRect(
          rect: rect.inflate(3),
          child: IgnorePointer(child: DecoratedBox(decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFBA0007), width: 2),
            borderRadius: BorderRadius.circular(10)))),
        ),
        Align(alignment: Alignment.bottomCenter, child: SafeArea(
          child: Padding(padding: const EdgeInsets.all(16), child: Material(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(24),
            child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480),
              child: SingleChildScrollView(child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Row(children: [
                    Image.asset('assets/augment_bunny_mascot_wink.png', width: 56, height: 76),
                    const SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${step + 1} of 4 • ${messages[step].$1}',
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                      const SizedBox(height: 8),
                      Text(messages[step].$2, style: const TextStyle(height: 1.4)),
                    ])),
                  ]),
                  const SizedBox(height: 12),
                  Wrap(alignment: WrapAlignment.end, spacing: 6, runSpacing: 4, children: [
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Skip')),
                    if (step > 0) TextButton(onPressed: () => setState(() => step--), child: const Text('Back')),
                    FilledButton(onPressed: () {
                      if (step == 3) { Navigator.pop(context); }
                      else { setState(() => step++); }
                    }, child: Text(step == 3 ? 'Got it' : 'Next')),
                  ]),
                ]),
              ))),
          )),
        )),
      ]),
    );
  }
}

class _Spotlight extends CustomPainter {
  const _Spotlight(this.rect);
  final Rect? rect;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size);
    if (rect != null) path.addRRect(RRect.fromRectAndRadius(rect!.inflate(3), const Radius.circular(10)));
    canvas.drawPath(path, Paint()..color = Colors.black.withValues(alpha: .60));
  }
  @override
  bool shouldRepaint(_Spotlight oldDelegate) => oldDelegate.rect != rect;
}
