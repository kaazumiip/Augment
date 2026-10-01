import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'instrument_selection_card.dart';
import 'tuner_page.dart';

class TunerInstrument {
  final String name;
  final String subtitle;
  final String category;
  final String? imagePath;
  final bool isRedCard;
  final List<Map<String, dynamic>> strings;
  final bool isChromatic;
  final int minMidi;
  final int maxMidi;
  final int writtenPitchOffset;
  final bool preferFlats;

  const TunerInstrument({
    required this.name,
    required this.subtitle,
    required this.category,
    this.imagePath,
    this.isRedCard = true,
    required this.strings,
    this.isChromatic = false,
    this.minMidi = 40,
    this.maxMidi = 100,
    this.writtenPitchOffset = 0,
    this.preferFlats = false,
  });
}

class ChooseTunerInstrumentPage extends StatefulWidget {
  const ChooseTunerInstrumentPage({Key? key}) : super(key: key);

  static const List<TunerInstrument> instruments = [
    // String instruments
    TunerInstrument(
      name: 'Guitar',
      subtitle: 'Guitar 6-String',
      category: 'String',
      imagePath: 'assets/tuner_guitar.png',
      isRedCard: true,
      strings: [
        {'note': 'E', 'octave': 2, 'freq': 82.41},
        {'note': 'A', 'octave': 2, 'freq': 110.00},
        {'note': 'D', 'octave': 3, 'freq': 146.83},
        {'note': 'G', 'octave': 3, 'freq': 196.00},
        {'note': 'B', 'octave': 3, 'freq': 246.94},
        {'note': 'E', 'octave': 4, 'freq': 329.63},
      ],
    ),
    TunerInstrument(
      name: 'Ukulele',
      subtitle: 'Ukulele 4-String',
      category: 'String',
      isRedCard: true,
      strings: [
        {'note': 'G', 'octave': 4, 'freq': 392.00},
        {'note': 'C', 'octave': 4, 'freq': 261.63},
        {'note': 'E', 'octave': 4, 'freq': 329.63},
        {'note': 'A', 'octave': 4, 'freq': 440.00},
      ],
    ),
    TunerInstrument(
      name: 'Violin',
      subtitle: 'Violin',
      category: 'String',
      isRedCard: false,
      strings: [
        {'note': 'G', 'octave': 3, 'freq': 196.00},
        {'note': 'D', 'octave': 4, 'freq': 293.66},
        {'note': 'A', 'octave': 4, 'freq': 440.00},
        {'note': 'E', 'octave': 5, 'freq': 659.25},
      ],
    ),
    TunerInstrument(
      name: 'Cello',
      subtitle: 'Cello 4-String',
      category: 'String',
      isRedCard: true,
      strings: [
        {'note': 'C', 'octave': 2, 'freq': 65.41},
        {'note': 'G', 'octave': 2, 'freq': 98.00},
        {'note': 'D', 'octave': 3, 'freq': 146.83},
        {'note': 'A', 'octave': 3, 'freq': 220.00},
      ],
    ),
    TunerInstrument(
      name: 'Electric guitar',
      subtitle: 'Electric guitar 6-String',
      category: 'String',
      isRedCard: false,
      strings: [
        {'note': 'E', 'octave': 2, 'freq': 82.41},
        {'note': 'A', 'octave': 2, 'freq': 110.00},
        {'note': 'D', 'octave': 3, 'freq': 146.83},
        {'note': 'G', 'octave': 3, 'freq': 196.00},
        {'note': 'B', 'octave': 3, 'freq': 246.94},
        {'note': 'E', 'octave': 4, 'freq': 329.63},
      ],
    ),
    // Wind instruments
    TunerInstrument(
      name: 'Alto Saxophone',
      subtitle: 'Eb Alto Sax',
      category: 'Wind',
      imagePath: 'assets/saxophonist.png',
      isRedCard: true,
      isChromatic: true,
      minMidi: 49,
      maxMidi: 81,
      writtenPitchOffset: 9,
      preferFlats: true,
      strings: [
        {'note': 'Bb', 'octave': 3, 'freq': 233.08},
        {'note': 'Eb', 'octave': 4, 'freq': 311.13},
        {'note': 'Ab', 'octave': 4, 'freq': 415.30},
        {'note': 'Db', 'octave': 5, 'freq': 554.37},
      ],
    ),
    TunerInstrument(
      name: 'Tenor Saxophone',
      subtitle: 'Bb Tenor Sax',
      category: 'Wind',
      imagePath: 'assets/saxophonist.png',
      isRedCard: false,
      isChromatic: true,
      minMidi: 44,
      maxMidi: 76,
      writtenPitchOffset: 14,
      preferFlats: true,
      strings: [
        {'note': 'Ab', 'octave': 2, 'freq': 103.83},
        {'note': 'Db', 'octave': 3, 'freq': 138.59},
        {'note': 'Gb', 'octave': 3, 'freq': 185.00},
        {'note': 'B', 'octave': 3, 'freq': 246.94},
      ],
    ),
    TunerInstrument(
      name: 'Flute',
      subtitle: 'Concert Flute',
      category: 'Wind',
      isRedCard: true,
      isChromatic: true,
      minMidi: 60,
      maxMidi: 96,
      strings: [
        {'note': 'C', 'octave': 4, 'freq': 261.63},
        {'note': 'D', 'octave': 4, 'freq': 293.66},
        {'note': 'E', 'octave': 4, 'freq': 329.63},
        {'note': 'F', 'octave': 4, 'freq': 349.23},
      ],
    ),
  ];

  @override
  State<ChooseTunerInstrumentPage> createState() =>
      _ChooseTunerInstrumentPageState();
}

class _ChooseTunerInstrumentPageState extends State<ChooseTunerInstrumentPage> {
  String _selectedCategory = 'String';

  List<TunerInstrument> get _filteredInstruments => _selectedCategory == 'All'
      ? ChooseTunerInstrumentPage.instruments
      : ChooseTunerInstrumentPage.instruments
          .where((i) => i.category == _selectedCategory)
          .toList();

  List<String> get _categories {
    final cats = ChooseTunerInstrumentPage.instruments
        .map((i) => i.category)
        .toSet()
        .toList();
    return ['All', ...cats];
  }

  @override
  Widget build(BuildContext context) {
    const Color brandRed = Color(0xFFBA0007);
    final backgroundColor = AppPalette.page(context);
    final text = AppPalette.text(context);
    final surface = AppPalette.surface(context);

    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallScreen = screenWidth < 360;

    final double horizontalPad = isSmallScreen ? 20.0 : 28.0;
    final double titleSize = isSmallScreen ? 24.0 : 30.0;
    final double topSpacing = isSmallScreen ? 12.0 : 24.0;

    return Scaffold(
      backgroundColor: backgroundColor,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: horizontalPad,
                vertical: isSmallScreen ? 12.0 : 16.0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IconButton(
                    tooltip: 'Back',
                    onPressed: () => Navigator.maybePop(context),
                    icon: Icon(
                      Icons.arrow_back_ios,
                      size: isSmallScreen ? 20 : 24,
                      color: text,
                    ),
                  ),
                  SizedBox(height: topSpacing),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: RichText(
                          text: TextSpan(
                            children: [
                              TextSpan(
                                text: 'CHOOSE\n',
                                style: TextStyle(
                                  fontFamily: 'Instrument Sans',
                                  fontSize: titleSize,
                                  fontWeight: FontWeight.w900,
                                  color: text,
                                  height: 1.1,
                                ),
                              ),
                              TextSpan(
                                text: 'INSTRUMENT',
                                style: TextStyle(
                                  fontFamily: 'Instrument Sans',
                                  fontSize: titleSize,
                                  fontWeight: FontWeight.w900,
                                  color: brandRed,
                                  height: 1.1,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      _buildCategoryChip(_selectedCategory),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 48,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _categories.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final cat = _categories[index];
                        final isSelected = cat == _selectedCategory;
                        return GestureDetector(
                          onTap: () => setState(() => _selectedCategory = cat),
                          child: Container(
                            alignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
                            decoration: BoxDecoration(
                              color: isSelected ? brandRed : surface,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: isSelected
                                    ? brandRed
                                    : AppPalette.border(context),
                              ),
                            ),
                            child: Text(
                              cat,
                              style: TextStyle(
                                fontFamily: 'Instrument Sans',
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: isSelected ? Colors.white : text,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  SizedBox(height: isSmallScreen ? 12 : 16),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.symmetric(horizontal: horizontalPad),
                itemCount: _filteredInstruments.length,
                itemBuilder: (context, index) {
                  final instrument = _filteredInstruments[index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: _buildInstrumentCard(
                      instrument: instrument,
                      isSmallScreen: isSmallScreen,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => TunerPage(instrument: instrument),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryChip(String label) {
    const Color brandRed = Color(0xFFBA0007);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: brandRed,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: 'Instrument Sans',
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _buildInstrumentCard({
    required TunerInstrument instrument,
    required bool isSmallScreen,
    required VoidCallback onTap,
  }) =>
      InstrumentSelectionCard(
        name: instrument.name,
        subtitle: instrument.subtitle,
        isRed: instrument.isRedCard,
        height: isSmallScreen ? 200 : 240,
        onTap: onTap,
      );

  // Retained temporarily while the picker data is migrated to the shared card.
  // ignore: unused_element
  Widget _buildLegacyInstrumentCard({
    required TunerInstrument instrument,
    required bool isSmallScreen,
    required bool dark,
    required VoidCallback onTap,
  }) {
    final double cardHeight = isSmallScreen ? 200 : 240;
    final bool isRed = instrument.isRedCard;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: cardHeight,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isRed
                ? const [Color(0xFFBA0007), Color(0xFF540003)]
                : dark
                    ? const [Color(0xFF3A3A3A), Color(0xFF202020)]
                    : const [Color(0xFFFFFFFF), Color(0xFF999999)],
          ),
          boxShadow: [
            BoxShadow(
              color: isRed
                  ? const Color(0xFFBA0007).withValues(alpha: 0.4)
                  : Colors.black.withValues(alpha: dark ? 0.35 : 0.15),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            // Subtle texture overlay
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0.2, -0.3),
                    radius: 1.2,
                    colors: isRed
                        ? [
                            Colors.white.withValues(alpha: 0.08),
                            Colors.transparent,
                          ]
                        : [
                            (dark ? Colors.white : Colors.black)
                                .withValues(alpha: dark ? 0.10 : 0.08),
                            Colors.transparent,
                          ],
                  ),
                ),
              ),
            ),

            // Large instrument image centered
            Positioned.fill(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: instrument.imagePath != null
                      ? Image.asset(
                          instrument.imagePath!,
                          fit: BoxFit.contain,
                          errorBuilder: (context, error, stackTrace) {
                            return Icon(
                              Icons.music_note,
                              size: isSmallScreen ? 80 : 100,
                              color: isRed
                                  ? Colors.white.withValues(alpha: 0.3)
                                  : const Color(0xFFBA0007)
                                      .withValues(alpha: 0.25),
                            );
                          },
                        )
                      : Icon(
                          Icons.music_note,
                          size: isSmallScreen ? 80 : 100,
                          color: isRed
                              ? Colors.white.withValues(alpha: 0.3)
                              : const Color(0xFFBA0007).withValues(alpha: 0.25),
                        ),
                ),
              ),
            ),

            // Large instrument name behind the image
            Positioned.fill(
              child: Center(
                child: Text(
                  instrument.name.toUpperCase(),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Instrument Sans',
                    fontSize: isSmallScreen ? 42 : 54,
                    fontWeight: FontWeight.w900,
                    color: isRed
                        ? Colors.white.withValues(alpha: 0.95)
                        : const Color(0xFFBA0007).withValues(alpha: 0.9),
                    height: 0.95,
                    letterSpacing: 2,
                    shadows: [
                      Shadow(
                        color: isRed
                            ? Colors.black.withValues(alpha: 0.3)
                            : Colors.black.withValues(alpha: 0.1),
                        blurRadius: 4,
                        offset: const Offset(2, 2),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Subtitle bottom-right
            Positioned(
              right: 20,
              bottom: 20,
              child: Text(
                instrument.subtitle,
                style: TextStyle(
                  fontFamily: 'Instrument Sans',
                  fontSize: isSmallScreen ? 12 : 14,
                  fontWeight: FontWeight.w600,
                  color: isRed
                      ? Colors.white.withValues(alpha: 0.9)
                      : (dark ? Colors.white : Colors.black)
                          .withValues(alpha: 0.6),
                ),
              ),
            ),

            // Subtle border
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isRed
                        ? Colors.white.withValues(alpha: 0.1)
                        : (dark ? Colors.white : Colors.black)
                            .withValues(alpha: 0.12),
                    width: 1,
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
