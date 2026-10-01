import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'choose_tuner_instrument_page.dart';
import 'metronome_page.dart';
import 'tuner_page.dart';

class ToolsPage extends StatelessWidget {
  const ToolsPage({super.key});

  static const _tools = [
    (
      'METRONOME',
      'Stay in sync. Choose a tempo, start the beat, and focus on the music.',
      true,
      Icons.timer_outlined
    ),
    (
      'Tuner',
      'Tune your instrument accurately before you play.',
      false,
      Icons.tune_rounded
    ),
    (
      'Voice pitch test',
      'Test and explore your vocal range.',
      true,
      Icons.mic_none_rounded
    ),
    (
      'Pitch detector',
      'Identify pitch from a recorded sound.',
      false,
      Icons.graphic_eq_rounded
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.page(context),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            IconButton(
                onPressed: () => Navigator.pop(context),
                icon: Icon(Icons.arrow_back_ios_new_rounded,
                    color: AppPalette.text(context)),
                padding: EdgeInsets.zero),
            const SizedBox(height: 20),
            Text('Other tools .',
                style: TextStyle(
                    color: AppPalette.text(context),
                    fontSize: 25,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 7),
            Text('Practice tools for your music.',
                style:
                    TextStyle(color: AppPalette.muted(context), fontSize: 13)),
            const SizedBox(height: 24),
            Expanded(
                child: ListView.separated(
                    itemCount: _tools.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 14),
                    itemBuilder: (context, index) {
                      final tool = _tools[index];
                      return _ToolCard(
                        title: tool.$1,
                        text: tool.$2,
                        dark: tool.$3,
                        icon: tool.$4,
                        onTap: index == 0
                            ? () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => const MetronomePage()),
                                )
                            : index == 1
                                ? () async {
                                    final instrument = await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            const ChooseTunerInstrumentPage(),
                                      ),
                                    );
                                    if (!context.mounted || instrument == null)
                                      return;
                                    await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            TunerPage(instrument: instrument),
                                      ),
                                    );
                                  }
                                : null,
                      );
                    })),
          ]),
        ),
      ),
    );
  }
}

class _ToolCard extends StatelessWidget {
  const _ToolCard(
      {required this.title,
      required this.text,
      required this.dark,
      required this.icon,
      this.onTap});
  final String title, text;
  final bool dark;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: 145,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: dark
                    ? const [Color(0xFFBA0007), Color(0xFF540003)]
                    : const [Color(0xFFFFFFFF), Color(0xFFEFEAE6)],
              ),
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: .15),
                    blurRadius: 8,
                    spreadRadius: -2,
                    offset: const Offset(0, 4))
              ],
            ),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: dark ? Colors.white : const Color(0xFF8A0004),
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          letterSpacing: .2)),
                  const SizedBox(height: 6),
                  Text(text,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: dark
                              ? Colors.white.withValues(alpha: .8)
                              : Colors.black87.withValues(alpha: .7),
                          fontSize: 10,
                          height: 1.25)),
                ]),
          ),
        ),
      );
}
