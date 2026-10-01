import 'package:flutter/material.dart';

class SheetGenerationSheet extends StatefulWidget {
  const SheetGenerationSheet({Key? key}) : super(key: key);

  @override
  State<SheetGenerationSheet> createState() => _SheetGenerationSheetState();
}

class _SheetGenerationSheetState extends State<SheetGenerationSheet> {
  bool _isUploading = false;
  bool _isGenerating = false;
  bool _isFinished = false;
  double _progress = 0.0;
  String _fileName = '';

  void _startProcess(String name) {
    setState(() {
      _fileName = name;
      _isUploading = true;
      _progress = 0.0;
    });

    // Simulate Upload progress
    Future.doWhile(() async {
      await Future.delayed(const Duration(milliseconds: 100));
      if (!mounted) return false;
      setState(() {
        _progress += 0.05;
      });
      if (_progress >= 1.0) {
        _progress = 1.0;
        _isUploading = false;
        _isGenerating = true;
        _startConversion();
        return false;
      }
      return true;
    });
  }

  void _startConversion() {
    _progress = 0.0;
    // Simulate AI Conversion/Generation progress
    Future.doWhile(() async {
      await Future.delayed(const Duration(milliseconds: 150));
      if (!mounted) return false;
      setState(() {
        _progress += 0.04;
      });
      if (_progress >= 1.0) {
        _progress = 1.0;
        _isGenerating = false;
        _isFinished = true;
        return false;
      }
      return true;
    });
  }

  void _reset() {
    setState(() {
      _isUploading = false;
      _isGenerating = false;
      _isFinished = false;
      _progress = 0.0;
      _fileName = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    const Color cardBackground = Color(0xFFFFF9F5);
    const Color brandRed = Color(0xFFBA0007);
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: cardBackground,
            borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
          ),
          child: Column(
            children: [
              // Pull Bar
              Container(
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                width: 48,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(10),
                ),
              ),

              // Title Header
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 24.0, vertical: 12.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'SHEET GENERATOR',
                      style: TextStyle(
                        fontFamily: 'Instrument Sans',
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        color: brandRed,
                        letterSpacing: 0.5,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.black87),
                      onPressed: () => Navigator.pop(context),
                    )
                  ],
                ),
              ),

              Expanded(
                child: SingleChildScrollView(
                  controller: scrollController,
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  child: Column(
                    children: [
                      if (!_isUploading && !_isGenerating && !_isFinished) ...[
                        // Initial State: File Upload Area
                        const Text(
                          'Upload audio records, voice humming, or instrument tracks to synthesize editable music sheets.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: 'Instrument Sans',
                            color: Colors.black54,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 36),

                        // Drag and drop simulated card
                        GestureDetector(
                          onTap: () => _startProcess('guitar_solo_record.wav'),
                          child: Container(
                            height: 240,
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: brandRed.withOpacity(0.3),
                                width: 2.0,
                                style: BorderStyle
                                    .solid, // simulated dash or solid border
                              ),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.cloud_upload_outlined,
                                  size: 64,
                                  color: brandRed.withOpacity(0.8),
                                ),
                                const SizedBox(height: 16),
                                const Text(
                                  'Tap to choose file or record audio',
                                  style: TextStyle(
                                    fontFamily: 'Instrument Sans',
                                    fontWeight: FontWeight.w700,
                                    fontSize: 16,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Supports MP3, WAV, MIDI, M4A up to 50MB',
                                  style: TextStyle(
                                    fontFamily: 'Instrument Sans',
                                    color: Colors.grey.shade500,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ] else if (_isUploading || _isGenerating) ...[
                        // Processing/Loading State
                        const SizedBox(height: 48),
                        Text(
                          _isUploading
                              ? 'UPLOADING FILE...'
                              : 'GENERATING SHEET MUSIC...',
                          style: const TextStyle(
                            fontFamily: 'Instrument Sans',
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _fileName,
                          style: const TextStyle(
                            fontFamily: 'Instrument Sans',
                            color: Colors.grey,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 48),

                        // Progress Circle indicator
                        Stack(
                          alignment: Alignment.center,
                          children: [
                            SizedBox(
                              width: 140,
                              height: 140,
                              child: CircularProgressIndicator(
                                value: _progress,
                                strokeWidth: 8.0,
                                color: brandRed,
                                backgroundColor: Colors.grey.shade200,
                              ),
                            ),
                            Text(
                              '${(_progress * 100).toInt()}%',
                              style: const TextStyle(
                                fontFamily: 'Instrument Sans',
                                fontSize: 24,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 36),
                        Text(
                          _isUploading
                              ? 'Transferring audio samples to server safely...'
                              : 'AI transcribing notes, bars, and chords structure...',
                          style: const TextStyle(
                            fontFamily: 'Instrument Sans',
                            color: Colors.black54,
                            fontSize: 13,
                          ),
                        ),
                      ] else if (_isFinished) ...[
                        // Finished Mock sheet display state
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'GENERATED SHEET',
                              style: TextStyle(
                                fontFamily: 'Instrument Sans',
                                fontWeight: FontWeight.w800,
                                fontSize: 16,
                              ),
                            ),
                            TextButton.icon(
                              onPressed: _reset,
                              icon: const Icon(Icons.refresh,
                                  size: 18, color: brandRed),
                              label: const Text(
                                'Upload New',
                                style: TextStyle(
                                  fontFamily: 'Instrument Sans',
                                  color: brandRed,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // Sheet Image Mockup
                        Container(
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.05),
                                blurRadius: 10,
                                offset: const Offset(0, 5),
                              )
                            ],
                          ),
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Guitar Solo Transcription',
                                style: TextStyle(
                                  fontFamily: 'Instrument Sans',
                                  fontSize: 18,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              const Text(
                                'Key: C Major | Tempo: 120 BPM',
                                style: TextStyle(
                                  fontFamily: 'Instrument Sans',
                                  fontSize: 12,
                                  color: Colors.grey,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 24),
                              // Drawn stave/staff line representations
                              for (int i = 0; i < 4; i++) ...[
                                Column(
                                  children: [
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        // Clef mockup icon
                                        Icon(Icons.music_note,
                                            size: 24,
                                            color: Colors.grey.shade700),
                                        Expanded(
                                          child: Container(
                                            margin:
                                                const EdgeInsets.only(left: 12),
                                            height: 12,
                                            decoration: BoxDecoration(
                                              border: Border(
                                                top: BorderSide(
                                                    color:
                                                        Colors.grey.shade400),
                                                bottom: BorderSide(
                                                    color:
                                                        Colors.grey.shade400),
                                              ),
                                            ),
                                            child: Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.spaceEvenly,
                                              children: List.generate(
                                                  4,
                                                  (index) => Container(
                                                      width: 8,
                                                      height: 8,
                                                      decoration: BoxDecoration(
                                                          shape:
                                                              BoxShape.circle,
                                                          color: Colors.black
                                                              .withOpacity(
                                                                  0.85)))),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 16),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),

                        const SizedBox(height: 24),

                        // Action Controls
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () {},
                                icon: const Icon(Icons.share,
                                    color: Colors.black87),
                                label: const Text('SHARE',
                                    style: TextStyle(
                                        color: Colors.black87,
                                        fontWeight: FontWeight.w800)),
                                style: OutlinedButton.styleFrom(
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12)),
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 14),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: () {},
                                icon: const Icon(Icons.download,
                                    color: Colors.white),
                                label: const Text('DOWNLOAD PDF',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w800)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: brandRed,
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12)),
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 14),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 36),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
