import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'app_palette.dart';
import 'marketplace_payment_service.dart';

class MarketplacePurchasesPage extends StatefulWidget {
  const MarketplacePurchasesPage({
    super.key,
    this.showPurchaseConfirmation = false,
  });

  final bool showPurchaseConfirmation;

  @override
  State<MarketplacePurchasesPage> createState() =>
      _MarketplacePurchasesPageState();
}

class _MarketplacePurchasesPageState extends State<MarketplacePurchasesPage> {
  static const _red = Color(0xFFCA000A);
  late Future<List<MarketplacePurchase>> _purchases =
      MarketplacePaymentService.purchases();
  String? _downloadingOrder;

  @override
  void initState() {
    super.initState();
    if (widget.showPurchaseConfirmation) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Payment confirmed — your product is ready to download.'),
        ));
      });
    }
  }

  Future<void> _download(MarketplacePurchase purchase) async {
    final url = purchase.assetUrl;
    if (url == null || url.isEmpty) return;
    setState(() => _downloadingOrder = purchase.orderId);
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('The file could not be downloaded.');
      }
      final path = Uri.parse(url).path;
      final extension = RegExp(r'\.([A-Za-z0-9]{1,8})$')
              .firstMatch(path)
              ?.group(1)
              ?.toLowerCase() ??
          'file';
      final safeName = purchase.title
          .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '')
          .trim()
          .replaceAll(' ', '_');
      await FileSaver.instance.saveFile(
        name: safeName.isEmpty ? 'augment_purchase' : safeName,
        bytes: Uint8List.fromList(response.bodyBytes),
        fileExtension: extension,
        mimeType: MimeType.other,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved to your Downloads folder.')),
        );
      }
    } catch (_) {
      if (!mounted) return;
      final opened =
          await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not download this product.')),
        );
      }
    } finally {
      if (mounted) setState(() => _downloadingOrder = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = AppPalette.text(context);
    return Scaffold(
      backgroundColor: AppPalette.page(context),
      appBar: AppBar(
        backgroundColor: AppPalette.page(context),
        surfaceTintColor: Colors.transparent,
        title: Text('My purchases',
            style: TextStyle(color: text, fontWeight: FontWeight.w800)),
      ),
      body: FutureBuilder<List<MarketplacePurchase>>(
        future: _purchases,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator(color: _red));
          }
          if (snapshot.hasError) {
            return _PurchaseMessage(
              icon: Icons.cloud_off_rounded,
              title: 'Could not load your purchases',
              action: () => setState(
                  () => _purchases = MarketplacePaymentService.purchases()),
              actionLabel: 'Try again',
            );
          }
          final purchases = snapshot.data ?? const <MarketplacePurchase>[];
          if (purchases.isEmpty) {
            return const _PurchaseMessage(
              icon: Icons.shopping_bag_outlined,
              title: 'No purchases yet',
              message:
                  'Paid marketplace products will appear here ready to download.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 40),
            itemCount: purchases.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final purchase = purchases[index];
              final available = purchase.assetUrl?.isNotEmpty == true;
              final busy = _downloadingOrder == purchase.orderId;
              return Container(
                padding: const EdgeInsets.all(17),
                decoration: BoxDecoration(
                  color: AppPalette.surface(context),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppPalette.border(context)),
                ),
                child: Row(children: [
                  Container(
                    width: 45,
                    height: 45,
                    decoration: BoxDecoration(
                      color: _red.withValues(alpha: .10),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(Icons.music_note_rounded, color: _red),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(purchase.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: text,
                                fontWeight: FontWeight.w800,
                                fontSize: 15)),
                        const SizedBox(height: 4),
                        Text(
                          available
                              ? 'Paid · Ready to download'
                              : 'Paid · Seller has not uploaded a file yet',
                          style: TextStyle(
                              color: available
                                  ? const Color(0xFF148147)
                                  : AppPalette.muted(context),
                              fontSize: 11,
                              fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip:
                        available ? 'Download product' : 'File unavailable',
                    onPressed:
                        available && !busy ? () => _download(purchase) : null,
                    icon: busy
                        ? const SizedBox(
                            width: 19,
                            height: 19,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(Icons.download_rounded,
                            color:
                                available ? _red : AppPalette.muted(context)),
                  ),
                ]),
              );
            },
          );
        },
      ),
    );
  }
}

class _PurchaseMessage extends StatelessWidget {
  const _PurchaseMessage({
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.actionLabel,
  });
  final IconData icon;
  final String title;
  final String? message;
  final VoidCallback? action;
  final String? actionLabel;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 42, color: AppPalette.muted(context)),
            const SizedBox(height: 13),
            Text(title,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: AppPalette.text(context),
                    fontWeight: FontWeight.w800,
                    fontSize: 18)),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(message!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: AppPalette.muted(context), height: 1.35)),
            ],
            if (action != null) ...[
              const SizedBox(height: 12),
              TextButton(
                  onPressed: action, child: Text(actionLabel ?? 'Retry')),
            ],
          ]),
        ),
      );
}
