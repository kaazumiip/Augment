import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfx/pdfx.dart';

import 'app_palette.dart';

class PdfPreviewPage extends StatefulWidget {
  const PdfPreviewPage({
    super.key,
    required this.bytes,
    required this.filename,
  });

  final Uint8List bytes;
  final String filename;

  @override
  State<PdfPreviewPage> createState() => _PdfPreviewPageState();
}

class _PdfPreviewPageState extends State<PdfPreviewPage> {
  late final PdfControllerPinch _controller;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller = PdfControllerPinch(
      document: PdfDocument.openData(widget.bytes),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _savePdf() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final bareName = widget.filename
          .replaceFirst(RegExp(r'\.pdf$', caseSensitive: false), '');
      final path = !kIsWeb && defaultTargetPlatform == TargetPlatform.android
          ? await const MethodChannel('augment/downloads')
                  .invokeMethod<String>('savePdf', {
                'name': '$bareName.pdf',
                'bytes': widget.bytes,
              }) ??
              'Downloads/$bareName.pdf'
          : await FileSaver.instance.saveFile(
              name: bareName,
              bytes: widget.bytes,
              fileExtension: 'pdf',
              mimeType: MimeType.pdf,
            );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('PDF saved to $path')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save PDF: $error')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.page(context),
      appBar: AppBar(
        backgroundColor: AppPalette.page(context),
        foregroundColor: AppPalette.text(context),
        elevation: 0,
        title: const Text(
          'PDF preview',
          style: TextStyle(
            fontFamily: 'Instrument Sans',
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: PdfViewPinch(
        controller: _controller,
        padding: 12,
        builders: PdfViewPinchBuilders<DefaultBuilderOptions>(
          options: const DefaultBuilderOptions(),
          documentLoaderBuilder: (context) => const Center(
            child: CircularProgressIndicator(color: Color(0xFFBA0007)),
          ),
          errorBuilder: (context, error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Text(
                'This PDF could not be previewed.\n$error',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppPalette.muted(context)),
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(18, 8, 18, 16),
        child: SizedBox(
          height: 48,
          child: ElevatedButton.icon(
            onPressed: _saving ? null : _savePdf,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.download_rounded),
            label: Text(_saving ? 'Saving...' : 'Download PDF'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFBA0007),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
