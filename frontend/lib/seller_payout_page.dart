import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'social_service.dart';

class SellerPayoutPage extends StatefulWidget {
  const SellerPayoutPage({super.key});

  @override
  State<SellerPayoutPage> createState() => _SellerPayoutPageState();
}

class _SellerPayoutPageState extends State<SellerPayoutPage> {
  final _name = TextEditingController();
  String _method = 'khqr';
  PlatformFile? _qrImage;
  MarketplaceSellerPayout? _existing;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final payout = await SocialService.instance.sellerPayout();
      if (!mounted) return;
      setState(() {
        _existing = payout;
        _name.text = payout?.recipientName ?? '';
        _method = payout?.method ?? 'khqr';
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickQr() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result != null && result.files.isNotEmpty && mounted) {
      setState(() => _qrImage = result.files.single);
    }
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty || _qrImage == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Add the recipient name and their payment QR image.'),
      ));
      return;
    }
    setState(() => _saving = true);
    try {
      await SocialService.instance.saveSellerPayout(
        recipientName: _name.text,
        method: _method,
        qrImage: _qrImage!,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Payout QR saved. Augment can use it for your payout.'),
      ));
      await _load();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save payout QR: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = AppPalette.text(context);
    final muted = AppPalette.muted(context);
    return Scaffold(
      backgroundColor: AppPalette.page(context),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(22, 12, 22, 34),
                children: [
                  Row(children: [
                    AppBackButton(onPressed: () => Navigator.pop(context)),
                    const SizedBox(width: 10),
                    Text('Seller payouts',
                        style: TextStyle(
                            color: text,
                            fontSize: 24,
                            fontWeight: FontWeight.w800)),
                  ]),
                  const SizedBox(height: 22),
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFE8E5),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(children: [
                      Icon(Icons.account_balance_wallet_rounded,
                          color: Color(0xFFCA000A)),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Buyers pay Augment first. Your QR is used when Augment pays your seller balance.',
                          style: TextStyle(height: 1.35),
                        ),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 24),
                  Text('Payment method',
                      style:
                          TextStyle(color: text, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 9),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'khqr', label: Text('ABA / KHQR')),
                      ButtonSegment(value: 'aba', label: Text('ABA transfer')),
                    ],
                    selected: {_method},
                    onSelectionChanged: (value) =>
                        setState(() => _method = value.first),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _name,
                    maxLength: 120,
                    decoration: const InputDecoration(
                      labelText: 'Recipient name',
                      prefixIcon: Icon(Icons.person_outline_rounded),
                    ),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _pickQr,
                    icon: const Icon(Icons.qr_code_2_rounded),
                    label: Text(_qrImage == null
                        ? 'Upload ABA / KHQR image'
                        : _qrImage!.name),
                  ),
                  if (_existing?.qrImageUrl.isNotEmpty == true &&
                      _qrImage == null) ...[
                    const SizedBox(height: 14),
                    Text('Current payout QR saved',
                        style: TextStyle(
                            color: muted, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.network(_existing!.qrImageUrl,
                          height: 180,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) =>
                              const SizedBox.shrink()),
                    ),
                  ],
                  const SizedBox(height: 28),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                      backgroundColor: const Color(0xFFCA000A),
                    ),
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.save_rounded),
                    label: const Text('Save payout details'),
                  ),
                ],
              ),
      ),
    );
  }
}
