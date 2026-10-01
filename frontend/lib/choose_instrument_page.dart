import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'generation_started_page.dart';
import 'app_palette.dart';
import 'instrument_selection_card.dart';

class Instrument {
  final String name;
  final String subtitle;
  final String category;
  final String? imagePath;
  final bool isRedCard;

  const Instrument({
    required this.name,
    required this.subtitle,
    required this.category,
    this.imagePath,
    this.isRedCard = true,
  });
}

class ChooseInstrumentPage extends StatefulWidget {
  final String mode;
  final String source;
  final String? fileUrl;
  final String? filePath;

  const ChooseInstrumentPage({
    Key? key,
    required this.mode,
    this.source = 'device',
    this.fileUrl,
    this.filePath,
  }) : super(key: key);

  @override
  State<ChooseInstrumentPage> createState() => _ChooseInstrumentPageState();
}

class _ChooseInstrumentPageState extends State<ChooseInstrumentPage> {
  String _selectedCategory = 'All';
  bool _isLoading = false;

  static const List<Instrument> _allInstruments = [
    Instrument(
        name: 'Violin',
        subtitle: 'Violin',
        category: 'String',
        imagePath: 'assets/instruments/violin.png',
        isRedCard: true),
    Instrument(
        name: 'Guitar',
        subtitle: 'Guitar 6-String',
        category: 'String',
        imagePath: 'assets/instruments/guitar.png',
        isRedCard: false),
    Instrument(
        name: 'Electric Guitar',
        subtitle: 'Electric guitar 6-String',
        category: 'String',
        imagePath: 'assets/instruments/electric_guitar.png',
        isRedCard: false),
    Instrument(
        name: 'Cello',
        subtitle: 'Cello',
        category: 'String',
        imagePath: 'assets/instruments/cello.png',
        isRedCard: true),
    Instrument(
        name: 'Ukulele',
        subtitle: 'Ukulele 4-String',
        category: 'String',
        imagePath: 'assets/instruments/ukulele.png',
        isRedCard: false),
    Instrument(
        name: 'Piano',
        subtitle: 'Acoustic Piano',
        category: 'Keyboard',
        imagePath: 'assets/instruments/piano.png',
        isRedCard: true),
    Instrument(
        name: 'Saxophone',
        subtitle: 'Alto / Tenor Sax',
        category: 'Wind',
        imagePath: 'assets/instruments/saxophone.png',
        isRedCard: true),
    Instrument(
        name: 'Flute',
        subtitle: 'Concert Flute',
        category: 'Wind',
        imagePath: 'assets/instruments/flute.png',
        isRedCard: true),
  ];

  List<Instrument> get _filteredInstruments {
    if (_selectedCategory == 'All') return _allInstruments;
    return _allInstruments
        .where((i) => i.category == _selectedCategory)
        .toList();
  }

  List<String> get _categories {
    final cats = _allInstruments.map((i) => i.category).toSet().toList();
    return ['All', ...cats];
  }

  Future<void> _onInstrumentSelected(String instrumentName) async {
    if (_isLoading) return;
    setState(() => _isLoading = true);

    try {
      String? filePath;

      if (widget.filePath != null) {
        filePath = widget.filePath;
      } else if (widget.source == 'link' && widget.fileUrl != null) {
        filePath = null;
      } else {
        final fileResult = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: [
            'mp3',
            'wav',
            'm4a',
            'aac',
            'flac',
            'ogg',
            'opus',
            'wma',
            'aif',
            'aiff',
            'caf',
            'mid',
            'midi',
            'musicxml',
            'xml',
            'mxl',
            'krn',
            'abc',
          ],
        );
        if (fileResult == null) {
          setState(() => _isLoading = false);
          return;
        }
        filePath = fileResult.files.single.path;
      }

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => GenerationStartedPage(
            instrumentName: instrumentName,
            source: widget.source,
            fileUrl: widget.fileUrl,
            filePath: filePath,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    const Color brandRed = Color(0xFFBA0007);

    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallScreen = screenWidth < 360;

    final double horizontalPad = isSmallScreen ? 20.0 : 28.0;
    final double titleSize = isSmallScreen ? 24.0 : 30.0;
    final double topSpacing = isSmallScreen ? 12.0 : 24.0;

    return Scaffold(
      backgroundColor: AppPalette.page(context),
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
                  AppBackButton(
                    size: isSmallScreen ? 20 : 24,
                    onPressed: () => Navigator.pop(context),
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
                                  color: AppPalette.text(context),
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
                    height: 36,
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
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? brandRed
                                  : AppPalette.surface(context),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: isSelected
                                    ? brandRed
                                    : Colors.grey.shade300,
                              ),
                            ),
                            child: Text(
                              cat,
                              style: TextStyle(
                                fontFamily: 'Instrument Sans',
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: isSelected
                                    ? Colors.white
                                    : AppPalette.text(context),
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
                      onTap: () => _onInstrumentSelected(instrument.name),
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
    required Instrument instrument,
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
    required Instrument instrument,
    required bool isSmallScreen,
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
                : const [Color(0xFFFFFFFF), Color(0xFF999999)],
          ),
          boxShadow: [
            BoxShadow(
              color: isRed
                  ? const Color(0xFFBA0007).withValues(alpha: 0.4)
                  : Colors.black.withValues(alpha: 0.15),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
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
                            Colors.white.withValues(alpha: 0.5),
                            Colors.transparent,
                          ],
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Image.asset(
                    instrument.imagePath ?? '',
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) {
                      return Icon(
                        Icons.music_note,
                        size: isSmallScreen ? 80 : 100,
                        color: isRed
                            ? Colors.white.withValues(alpha: 0.3)
                            : const Color(0xFFBA0007).withValues(alpha: 0.25),
                      );
                    },
                  ),
                ),
              ),
            ),
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
                      : Colors.black.withValues(alpha: 0.6),
                ),
              ),
            ),
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isRed
                        ? Colors.white.withValues(alpha: 0.1)
                        : Colors.black.withValues(alpha: 0.05),
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
