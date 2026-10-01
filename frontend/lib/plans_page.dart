import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_palette.dart';
import 'app_settings.dart';
import 'bakong_payment_service.dart';
import 'keyboard_aware_sheet.dart';

class PlansPage extends StatelessWidget {
  const PlansPage({super.key});

  static const _red = Color(0xFFD30A02);

  static const _plans = <_PlanDetails>[
    _PlanDetails(
      type: AppPlan.free,
      name: 'Free',
      price: r'$0',
      period: 'forever',
      description: 'For getting started with Augment.',
      features: [
        'Instrument tuner and metronome',
        'Community and music market',
        '3 sheet generations each month',
      ],
      badge: 'STARTER',
    ),
    _PlanDetails(
      type: AppPlan.plus,
      name: 'Plus',
      price: r'$4.99',
      period: 'per month',
      description: 'For musicians who practise regularly.',
      features: [
        'Everything included in Free',
        '25 sheet generations each month',
        'Save and reopen generated sheets offline',
      ],
      badge: 'MOST POPULAR',
    ),
    _PlanDetails(
      type: AppPlan.pro,
      name: 'Pro',
      price: r'$9.99',
      period: 'per month',
      description: 'For musicians creating every day.',
      features: [
        'Everything included in Plus',
        'Unlimited sheet generations',
        'Priority music generation',
      ],
      badge: 'FULL ACCESS',
    ),
  ];

  Future<void> _selectPlan(BuildContext context, _PlanDetails plan) async {
    if (AppSettings.instance.plan == plan.type) return;
    if (plan.type == AppPlan.free) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'Your current plan stays active until it ends. Manage renewal in Manage plan.'),
      ));
      return;
    }
    final paid = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _BakongPaymentDialog(plan: plan.type, label: plan.name),
    );
    if (paid != true) return;
    final subscription = await BakongPaymentService.subscription();
    AppSettings.instance.applyServerPlan(subscription.plan);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text('${plan.name} plan selected.')),
      );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppPalette.page(context),
        body: SafeArea(
          child: ListenableBuilder(
            listenable: AppSettings.instance,
            builder: (context, _) => ListView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 36),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: AppBackButton(
                    onPressed: () => Navigator.maybePop(context),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: RichText(
                        text: TextSpan(
                          text: 'Plans',
                          style: TextStyle(
                            color: AppPalette.text(context),
                            fontSize: 27,
                            fontWeight: FontWeight.w900,
                          ),
                          children: const [
                            TextSpan(
                              text: ' .',
                              style: TextStyle(color: _red),
                            ),
                          ],
                        ),
                      ),
                    ),
                    _CurrentPlanPill(
                      label: AppSettings.instance.planLabel,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Find the plan that works for your music.',
                  style: TextStyle(
                    color: AppPalette.muted(context),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 24),
                ..._plans.map(
                  (plan) => Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: _VerticalPlanCard(
                      plan: plan,
                      current: AppSettings.instance.plan == plan.type,
                      onChoose: () => _selectPlan(context, plan),
                    ),
                  ),
                ),
                const _RedeemCodeCard(),
              ],
            ),
          ),
        ),
      );
}

class _RedeemCodeCard extends StatefulWidget {
  const _RedeemCodeCard();

  @override
  State<_RedeemCodeCard> createState() => _RedeemCodeCardState();
}

class _RedeemCodeCardState extends State<_RedeemCodeCard> {
  final _controller = TextEditingController();
  bool _redeeming = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _redeem() async {
    if (_redeeming || _controller.text.trim().isEmpty) return;
    setState(() {
      _redeeming = true;
      _error = null;
    });
    try {
      final subscription =
          await BakongPaymentService.redeemCode(_controller.text);
      AppSettings.instance.applyServerPlan(subscription.plan);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
            content: Text('Pro access activated for this account.')));
    } catch (error) {
      if (mounted) {
        setState(
            () => _error = error.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _redeeming = false);
    }
  }

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppPalette.surface(context),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: AppPalette.border(context)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Have a redeem code?',
              style: TextStyle(
                  color: AppPalette.text(context),
                  fontSize: 18,
                  fontWeight: FontWeight.w900)),
          const SizedBox(height: 5),
          Text('Enter a code to activate your plan on this account.',
              style: TextStyle(color: AppPalette.muted(context), fontSize: 12)),
          const SizedBox(height: 15),
          TextField(
            controller: _controller,
            maxLength: 64,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _redeem(),
            decoration: InputDecoration(
              hintText: 'Redeem code',
              counterText: '',
              prefixIcon: const Icon(Icons.verified_outlined, size: 20),
              filled: true,
              fillColor: AppPalette.page(context),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(13)),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: const TextStyle(color: Color(0xFFD30A02), fontSize: 12)),
          ],
          const SizedBox(height: 12),
          SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _redeeming ? null : _redeem,
                style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFD30A02)),
                child: _redeeming
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Redeem'),
              )),
        ]),
      );
}

class _BakongPaymentDialog extends StatefulWidget {
  const _BakongPaymentDialog({required this.plan, required this.label});
  final AppPlan plan;
  final String label;

  @override
  State<_BakongPaymentDialog> createState() => _BakongPaymentDialogState();
}

class _BakongPaymentDialogState extends State<_BakongPaymentDialog> {
  BakongPayment? _payment;
  String? _error;
  bool _checking = false;
  bool _creating = true;
  bool _savingQr = false;
  Timer? _expiryTimer;
  Timer? _verificationTimer;
  Duration _remaining = Duration.zero;
  bool _verificationUsed = false;
  int _verificationScheduleIndex = 0;
  DateTime? _verificationStartedAt;

  static const _verificationSchedule = <Duration>[
    Duration(seconds: 20),
    Duration(seconds: 40),
    Duration(seconds: 60),
    Duration(seconds: 80),
  ];

  @override
  void initState() {
    super.initState();
    _create();
  }

  Future<void> _create() async {
    setState(() {
      _creating = true;
      _error = null;
      _payment = null;
      _remaining = Duration.zero;
      _verificationUsed = false;
      _verificationScheduleIndex = 0;
      _verificationStartedAt = null;
    });
    _expiryTimer?.cancel();
    _verificationTimer?.cancel();
    try {
      final payment = await BakongPaymentService.createCheckout(widget.plan);
      if (mounted) {
        setState(() {
          _payment = payment;
          _creating = false;
          _remaining = payment.expiresAt.difference(DateTime.now());
          _verificationStartedAt = DateTime.now();
        });
        _startExpiryCountdown();
        _scheduleNextVerification();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _creating = false;
          _error = error.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  void _startExpiryCountdown() {
    _expiryTimer?.cancel();
    _expiryTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final expiresAt = _payment?.expiresAt;
      if (!mounted || expiresAt == null) return;
      final remaining = expiresAt.difference(DateTime.now());
      setState(
          () => _remaining = remaining.isNegative ? Duration.zero : remaining);
      if (remaining.isNegative) {
        _expiryTimer?.cancel();
        _verificationTimer?.cancel();
      }
    });
  }

  void _scheduleNextVerification() {
    _verificationTimer?.cancel();
    final payment = _payment;
    if (!mounted || payment == null || _verificationUsed) return;
    if (!payment.expiresAt.isAfter(DateTime.now())) return;
    final startedAt = _verificationStartedAt;
    if (startedAt == null ||
        _verificationScheduleIndex >= _verificationSchedule.length) {
      return;
    }
    final target = startedAt.add(
      _verificationSchedule[_verificationScheduleIndex],
    );
    _verificationScheduleIndex += 1;
    final delay = target.difference(DateTime.now());
    final untilExpiry = payment.expiresAt.difference(DateTime.now());
    if (untilExpiry <= Duration.zero) return;
    final safeDelay = delay.isNegative ? Duration.zero : delay;
    if (untilExpiry <= safeDelay) return;
    _verificationTimer = Timer(safeDelay, () async {
      await _verify(automatic: true);
      if (mounted && !_verificationUsed) _scheduleNextVerification();
    });
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    _verificationTimer?.cancel();
    super.dispose();
  }

  Future<void> _openPaymentApp() async {
    final payment = _payment;
    final dataUrl = payment?.qrImage;

    // 1. Try sending QR image directly to ABA Mobile or via system share sheet
    if (dataUrl != null && dataUrl.isNotEmpty) {
      try {
        final bytes = base64Decode(dataUrl.split(',').last);

        // On Android: Attempt direct intent to ABA Mobile's QR scanner/handler
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
          try {
            const channel = MethodChannel('augment/aba_share');
            final launchedDirectly = await channel
                .invokeMethod<bool>('shareToAba', {'bytes': bytes});
            if (launchedDirectly == true) {
              if (mounted) setState(() => _error = null);
              return;
            }
          } catch (_) {
            // Fall through to cross-platform sharing
          }
        }

        // Cross-platform: Share the QR image file
        final tempDir = await getTemporaryDirectory();
        final file = File('${tempDir.path}/khqr_aba_payment.png');
        await file.writeAsBytes(bytes);

        if (!mounted) return;

        final box = context.findRenderObject() as RenderBox?;
        final sharePositionOrigin =
            box == null ? null : box.localToGlobal(Offset.zero) & box.size;

        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path, mimeType: 'image/png')],
            text: 'Scan with ABA Mobile',
            sharePositionOrigin: sharePositionOrigin,
          ),
        );

        if (mounted) setState(() => _error = null);
        return;
      } catch (_) {
        // Fall through to link fallback
      }
    }

    // 2. Fallback: try opening universal link if available
    final link = payment?.paymentLink;
    if (link != null && link.isNotEmpty) {
      try {
        final uri = Uri.parse(link);
        final opened =
            await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (opened) {
          if (mounted) setState(() => _error = null);
          return;
        }
      } catch (_) {}
    }

    // 3. If neither worked:
    if (mounted) {
      setState(() => _error =
          'Could not open ABA. Save the QR and select it from your ABA scan gallery.');
    }
  }

  Future<void> _saveQr() async {
    final payment = _payment;
    final dataUrl = payment?.qrImage;
    if (payment == null || dataUrl == null || _savingQr) return;
    setState(() => _savingQr = true);
    try {
      final bytes = base64Decode(dataUrl.split(',').last);
      final filename = 'khqr_${payment.id.replaceAll('-', '').substring(0, 8)}';
      await FileSaver.instance.saveFile(
        name: filename,
        bytes: bytes,
        fileExtension: 'png',
        mimeType: MimeType.png,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('QR code saved. Select it from your ABA scan gallery.'),
            duration: Duration(seconds: 4),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not save QR code: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _savingQr = false);
      }
    }
  }

  Future<void> _verify({bool automatic = false}) async {
    final payment = _payment;
    if (payment == null || _checking || _verificationUsed) return;
    _checking = true;
    try {
      final verified = await BakongPaymentService.verify(payment.id);
      if (!mounted) return;
      if (verified.status == 'paid') {
        _verificationUsed = true;
        _verificationTimer?.cancel();
        _expiryTimer?.cancel();
        Navigator.pop(context, true);
      } else if (verified.status == 'expired') {
        setState(() {
          _verificationUsed = true;
          _verificationTimer?.cancel();
          _expiryTimer?.cancel();
          _error = 'This QR has expired. Close this window and try again.';
        });
      } else {
        if (!automatic) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'Payment not confirmed yet. It will automatically update once completed in ABA.'),
              duration: Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (error) {
      if (mounted && !automatic) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error.toString().replaceFirst('Exception: ', '')),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      _checking = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final dataUrl = _payment?.qrImage;
    final image =
        dataUrl == null ? null : base64Decode(dataUrl.split(',').last);
    if (MediaQuery.sizeOf(context).width >= 0) {
      return _KhqrCheckoutView(
        planLabel: widget.label,
        payment: _payment,
        image: image,
        error: _error,
        creating: _creating,
        checking: _checking,
        remaining: _remaining,
        onRetry: _create,
        onVerify: () => _verify(),
        onOpenPaymentApp: _openPaymentApp,
        onSaveQr: _saveQr,
        savingQr: _savingQr,
        canVerify: !_verificationUsed,
      );
    }
    final expiresAt = _payment?.expiresAt;
    final timeLabel = expiresAt == null
        ? 'Creating secure checkout...'
        : 'Expires ${expiresAt.hour.toString().padLeft(2, '0')}:${expiresAt.minute.toString().padLeft(2, '0')}';
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 390),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(24, 22, 18, 22),
              decoration: BoxDecoration(
                color: AppPalette.surface(context),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(28)),
                border: Border(
                    bottom: BorderSide(color: AppPalette.border(context))),
              ),
              child: Row(children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD30A02).withValues(alpha: .1),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: const Icon(Icons.qr_code_2_rounded,
                      color: Color(0xFFD30A02)),
                ),
                const SizedBox(width: 13),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text('KHQR checkout',
                          style: TextStyle(
                              color: AppPalette.text(context),
                              fontSize: 18,
                              fontWeight: FontWeight.w900)),
                      Text('${widget.label} monthly plan',
                          style: TextStyle(
                              color: AppPalette.muted(context), fontSize: 12)),
                    ])),
                IconButton(
                    onPressed: () => Navigator.pop(context, false),
                    icon: Icon(Icons.close_rounded,
                        color: AppPalette.muted(context))),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
              child: Column(children: [
                Text('Scan to pay',
                    style: TextStyle(
                        color: AppPalette.text(context),
                        fontSize: 20,
                        fontWeight: FontWeight.w900)),
                if (_payment != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${_payment!.currency == 'USD' ? '\$' : ''}${_payment!.amount.toStringAsFixed(2)} ${_payment!.currency}',
                    style: const TextStyle(
                      color: Color(0xFFD30A02),
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
                const SizedBox(height: 5),
                Text(
                    'Open Bakong or your banking app, then scan this one-time QR.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: AppPalette.muted(context),
                        fontSize: 12.5,
                        height: 1.35)),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(13),
                  decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                          color: const Color(0xFFD30A02).withValues(alpha: .18),
                          width: 1.5),
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black.withValues(alpha: .08),
                            blurRadius: 20,
                            offset: const Offset(0, 8))
                      ]),
                  child: image != null
                      ? Image.memory(image, width: 218, height: 218)
                      : SizedBox(
                          width: 218,
                          height: 218,
                          child: Center(
                              child: _error == null
                                  ? const CircularProgressIndicator(
                                      color: Color(0xFFD30A02))
                                  : const Icon(Icons.error_outline_rounded,
                                      color: Color(0xFFD30A02), size: 42))),
                ),
                const SizedBox(height: 14),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                      color: const Color(0xFFFFF1EF),
                      borderRadius: BorderRadius.circular(12)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.timer_outlined,
                        size: 16, color: Color(0xFFD30A02)),
                    const SizedBox(width: 7),
                    Text(timeLabel,
                        style: const TextStyle(
                            color: Color(0xFFD30A02),
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800))
                  ]),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 13),
                  Text(_error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Color(0xFFD30A02), fontSize: 12)),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _creating ? null : _create,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Try again'),
                  ),
                ],
                const SizedBox(height: 20),
                Row(children: [
                  Expanded(
                      child: OutlinedButton(
                          onPressed: () => Navigator.pop(context, false),
                          style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(50),
                              side:
                                  BorderSide(color: AppPalette.border(context)),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14))),
                          child: const Text('Cancel'))),
                  const SizedBox(width: 10),
                  Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                          onPressed:
                              image == null || _checking ? null : _verify,
                          style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFFD30A02),
                              minimumSize: const Size.fromHeight(50),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14))),
                          icon: _checking
                              ? const SizedBox(
                                  width: 17,
                                  height: 17,
                                  child: CircularProgressIndicator(
                                      color: Colors.white, strokeWidth: 2))
                              : const Icon(Icons.verified_rounded, size: 18),
                          label: Text(
                              _checking ? 'Verifying...' : 'I have paid',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w800)))),
                ]),
                const SizedBox(height: 12),
                const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.lock_outline_rounded,
                          size: 13, color: Color(0xFF18864B)),
                      SizedBox(width: 5),
                      Text('Plan activates only after Bakong confirms payment',
                          style: TextStyle(
                              color: Color(0xFF18864B),
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700))
                    ]),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _KhqrCheckoutView extends StatelessWidget {
  const _KhqrCheckoutView({
    required this.planLabel,
    required this.payment,
    required this.image,
    required this.error,
    required this.creating,
    required this.checking,
    required this.remaining,
    required this.onRetry,
    required this.onVerify,
    required this.onOpenPaymentApp,
    required this.onSaveQr,
    required this.savingQr,
    required this.canVerify,
  });

  final String planLabel;
  final BakongPayment? payment;
  final Uint8List? image;
  final String? error;
  final bool creating;
  final bool checking;
  final Duration remaining;
  final VoidCallback onRetry;
  final VoidCallback onVerify;
  final VoidCallback onOpenPaymentApp;
  final VoidCallback onSaveQr;
  final bool savingQr;
  final bool canVerify;

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFD30A02);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screen = MediaQuery.sizeOf(context);
    final compact = screen.width < 370 || screen.height < 720;
    final qrSize = (screen.width - 88).clamp(160.0, compact ? 208.0 : 246.0);
    final horizontalPadding = compact ? 16.0 : 22.0;
    final textColor = AppPalette.text(context);
    final mutedColor = AppPalette.muted(context);
    final countdown = payment == null
        ? null
        : '${remaining.inMinutes.toString().padLeft(2, '0')}:${(remaining.inSeconds % 60).toString().padLeft(2, '0')}';
    final expired = payment != null && remaining == Duration.zero;
    final price = payment == null
        ? null
        : '${payment!.currency == 'USD' ? '\$' : ''}${payment!.amount.toStringAsFixed(2)} ${payment!.currency}';

    return Dialog.fullscreen(
      backgroundColor: Colors.transparent,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppPalette.page(context),
        ),
        child: Stack(
          children: [
            MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.noScaling),
              child: SafeArea(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(horizontalPadding, 8,
                      horizontalPadding, compact ? 16 : 24),
                  child: Column(children: [
                    Row(children: [
                      IconButton.filledTonal(
                        onPressed: () => Navigator.pop(context, false),
                        style: IconButton.styleFrom(
                          backgroundColor: AppPalette.surface(context),
                          foregroundColor: textColor,
                          side: BorderSide(color: AppPalette.border(context)),
                        ),
                        icon: const Icon(Icons.arrow_back_rounded, size: 22),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Checkout',
                                style: TextStyle(
                                    color: textColor,
                                    fontSize: compact ? 18 : 21,
                                    fontWeight: FontWeight.w700)),
                            Text('$planLabel plan · monthly',
                                style: TextStyle(
                                    color: mutedColor,
                                    fontSize: compact ? 10.5 : 12)),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                            color: red.withValues(alpha: .09),
                            borderRadius: BorderRadius.circular(20)),
                        child: const Text('KHQR',
                            style: TextStyle(
                                color: red,
                                fontSize: 10,
                                fontWeight: FontWeight.w900,
                                letterSpacing: .8)),
                      ),
                    ]),
                    SizedBox(height: compact ? 16 : 22),
                    Text('Scan to Pay',
                        style: TextStyle(
                            color: textColor,
                            fontFamily: 'Instrument Sans',
                            fontSize: compact ? 21 : 25,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -.8)),
                    const SizedBox(height: 5),
                    Text('Scan the QR with ABA Mobile or Bakong',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: mutedColor, fontSize: compact ? 11 : 12.5)),
                    SizedBox(height: compact ? 12 : 16),
                    Container(
                      width: double.infinity,
                      constraints: const BoxConstraints(maxWidth: 390),
                      decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: isDark
                                ? const [Color(0xFF292525), Color(0xFF1B1919)]
                                : const [Colors.white, Color(0xFFFFF7F2)],
                          ),
                          border: Border.all(
                              color: red.withValues(alpha: isDark ? .22 : .12)),
                          borderRadius: BorderRadius.circular(26),
                          boxShadow: [
                            BoxShadow(
                                color: Colors.black
                                    .withValues(alpha: isDark ? .18 : .055),
                                blurRadius: 32,
                                offset: const Offset(0, 14))
                          ]),
                      child: Column(children: [
                        Container(
                          height: compact ? 62 : 72,
                          width: double.infinity,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                stops: [0, .42, 1],
                                colors: [
                                  Color(0xFFE22930),
                                  Color(0xFFBA0007),
                                  Color(0xFF540003)
                                ],
                              ),
                              borderRadius: BorderRadius.vertical(
                                  top: Radius.circular(26))),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 22),
                            child: Row(children: [
                              const Expanded(
                                  child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('augment.',
                                      style: TextStyle(
                                          fontFamily: 'Instrument Sans',
                                          color: Colors.white,
                                          fontSize: 23,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: -1)),
                                ],
                              )),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 11, vertical: 8),
                                decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: .12),
                                    border: Border.all(
                                        color: Colors.white
                                            .withValues(alpha: .28)),
                                    boxShadow: [
                                      BoxShadow(
                                          color: Colors.black
                                              .withValues(alpha: .08),
                                          blurRadius: 10,
                                          offset: const Offset(0, 3))
                                    ],
                                    borderRadius: BorderRadius.circular(12)),
                                child: const Text('KHQR',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 1)),
                              ),
                            ]),
                          ),
                        ),
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                              compact ? 16 : 22,
                              compact ? 13 : 18,
                              compact ? 16 : 22,
                              compact ? 16 : 22),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                    payment?.recipientName ??
                                        'CHANMONYROTH HOUT',
                                    style: TextStyle(
                                        fontFamily: 'Instrument Sans',
                                        color: textColor,
                                        fontSize: compact ? 16 : 18,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: -.4)),
                                const SizedBox(height: 10),
                                Text('TOTAL DUE',
                                    style: TextStyle(
                                        color: mutedColor,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 1.4)),
                                const SizedBox(height: 9),
                                Row(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Expanded(
                                          child: Text(
                                              price ?? 'Preparing payment...',
                                              style: TextStyle(
                                                  color: textColor,
                                                  fontSize: compact ? 24 : 28,
                                                  fontWeight:
                                                      FontWeight.w900))),
                                      Flexible(
                                          child: Text('$planLabel / month',
                                              textAlign: TextAlign.right,
                                              style: TextStyle(
                                                  color: mutedColor,
                                                  fontSize: 10,
                                                  fontWeight:
                                                      FontWeight.w600))),
                                    ]),
                                const SizedBox(height: 14),
                                LayoutBuilder(
                                    builder: (context, constraints) => Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: List.generate(
                                              (constraints.maxWidth / 10)
                                                  .floor(),
                                              (_) => SizedBox(
                                                  width: 4,
                                                  height: 1,
                                                  child: ColoredBox(
                                                      color:
                                                          mutedColor.withValues(
                                                              alpha: .3)))),
                                        )),
                                const SizedBox(height: 16),
                                Center(
                                  child: Container(
                                    width: qrSize,
                                    height: qrSize,
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                        color: Colors.white,
                                        border: Border.all(
                                            color: const Color(0xFFEEEAE7)),
                                        borderRadius:
                                            BorderRadius.circular(16)),
                                    foregroundDecoration:
                                        const _QrAccentDecoration(),
                                    child: image != null
                                        ? Image.memory(image!,
                                            fit: BoxFit.contain,
                                            gaplessPlayback: true)
                                        : _QrLoadingState(
                                            error: error,
                                            creating: creating,
                                            onRetry: onRetry),
                                  ),
                                ),
                              ]),
                        ),
                      ]),
                    ),
                    SizedBox(height: compact ? 10 : 15),
                    if (countdown != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 9),
                        decoration: BoxDecoration(
                          color: AppPalette.surface(context),
                          border: Border.all(color: red.withValues(alpha: .18)),
                          borderRadius: BorderRadius.circular(30),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.timer_outlined,
                              color: red, size: 17),
                          const SizedBox(width: 7),
                          Text(expired ? 'QR expired' : 'Expires in $countdown',
                              style: const TextStyle(
                                  color: red,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800)),
                        ]),
                      ),
                    if (error != null && image != null) ...[
                      const SizedBox(height: 10),
                      Text(error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: red, fontSize: 12)),
                    ],
                    SizedBox(height: compact ? 16 : 20),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 390),
                      child: SizedBox(
                        width: double.infinity,
                        height: compact ? 48 : 52,
                        child: FilledButton.icon(
                          onPressed: image == null || expired
                              ? null
                              : onOpenPaymentApp,
                          style: FilledButton.styleFrom(
                            backgroundColor: red,
                            foregroundColor: Colors.white,
                            elevation: 2,
                            shadowColor: red.withValues(alpha: .28),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                          icon: const Icon(Icons.open_in_new_rounded, size: 20),
                          label: const Text('Pay with ABA Mobile',
                              style: TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w800)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 390),
                      child: SizedBox(
                        width: double.infinity,
                        height: compact ? 44 : 48,
                        child: OutlinedButton.icon(
                          onPressed: () => showModalBottomSheet<void>(
                            context: context,
                            isScrollControlled: true,
                            useSafeArea: true,
                            backgroundColor: Colors.transparent,
                            builder: (_) => const KeyboardAwareSheet(
                              child: _PlanCardDemoSheet(),
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: textColor,
                            side: BorderSide(color: AppPalette.border(context)),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                          icon: const Icon(Icons.credit_card_rounded, size: 18),
                          label: const Text('Visa / Mastercard demo',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 390),
                      child: Row(
                        children: [
                          Expanded(
                            child: SizedBox(
                              height: compact ? 44 : 48,
                              child: OutlinedButton.icon(
                                onPressed: image == null || expired || savingQr
                                    ? null
                                    : onSaveQr,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: textColor,
                                  side: BorderSide(
                                      color: AppPalette.border(context)),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14)),
                                ),
                                icon: savingQr
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2))
                                    : const Icon(Icons.download_rounded,
                                        size: 18),
                                label: Text(savingQr ? 'Saving...' : 'Save QR',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700)),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: SizedBox(
                              height: compact ? 44 : 48,
                              child: OutlinedButton.icon(
                                onPressed:
                                    image == null || expired || !canVerify
                                        ? null
                                        : onVerify,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: textColor,
                                  side: BorderSide(
                                      color: AppPalette.border(context)),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14)),
                                ),
                                icon: const Icon(
                                    Icons.check_circle_outline_rounded,
                                    size: 18),
                                label: const Text('I have paid',
                                    style:
                                        TextStyle(fontWeight: FontWeight.w700)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: compact ? 12 : 16),
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(Icons.lock_outline_rounded,
                          color: mutedColor, size: 14),
                      const SizedBox(width: 6),
                      Flexible(
                          child: Text(
                              'Secured by National Bank of Cambodia (NBC) Bakong',
                              textAlign: TextAlign.center,
                              style:
                                  TextStyle(color: mutedColor, fontSize: 11))),
                    ]),
                  ]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A visual, local-only card checker. Real card payments must use a gateway.
class _PlanCardDemoSheet extends StatefulWidget {
  const _PlanCardDemoSheet();

  @override
  State<_PlanCardDemoSheet> createState() => _PlanCardDemoSheetState();
}

class _PlanCardDemoSheetState extends State<_PlanCardDemoSheet> {
  final _number = TextEditingController();
  final _expiryMonth = TextEditingController();
  final _expiryYear = TextEditingController();
  final _cvc = TextEditingController();
  final _cvcFocus = FocusNode();
  String? _message;
  bool _showBack = false;

  @override
  void initState() {
    super.initState();
    _cvcFocus.addListener(() {
      if (mounted) setState(() => _showBack = _cvcFocus.hasFocus);
    });
  }

  String get _digits => _number.text.replaceAll(RegExp(r'\D'), '');
  String get _expiry => '${_expiryMonth.text}/${_expiryYear.text}';
  String get _brand => _digits.startsWith('4')
      ? 'VISA'
      : RegExp(r'^(5[1-5]|2[2-7])').hasMatch(_digits)
          ? 'mastercard'
          : 'CARD';
  String get _shownNumber {
    if (_digits.isEmpty) return '•••• •••• •••• ••••';
    return '$_digits••••••••••••••••'
        .substring(0, 16)
        .replaceAllMapped(RegExp(r'.{4}'), (match) => '${match.group(0)} ')
        .trimRight();
  }

  bool _passesLuhn() {
    if (_digits.length < 13 || _digits.length > 19) return false;
    var sum = 0;
    for (var index = 0; index < _digits.length; index++) {
      var value = int.parse(_digits[_digits.length - 1 - index]);
      if (index.isOdd) {
        value *= 2;
        if (value > 9) value -= 9;
      }
      sum += value;
    }
    return sum % 10 == 0;
  }

  void _check() {
    final expiry = RegExp(r'^(0[1-9]|1[0-2])/(\d{2})$').firstMatch(_expiry);
    final now = DateTime.now();
    final validExpiry = expiry != null &&
        ((2000 + int.parse(expiry.group(2)!)) > now.year ||
            ((2000 + int.parse(expiry.group(2)!)) == now.year &&
                int.parse(expiry.group(1)!) >= now.month));
    final validCvc = RegExp(r'^\d{3,4}$').hasMatch(_cvc.text.trim());
    setState(() => _message = _passesLuhn() && validExpiry && validCvc
        ? 'Card details are valid. Connect a payment provider to charge it.'
        : 'Check the card number, expiry date, and security code.');
  }

  @override
  void dispose() {
    _number.dispose();
    _expiryMonth.dispose();
    _expiryYear.dispose();
    _cvc.dispose();
    _cvcFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Material(
        color: AppPalette.page(context),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: (MediaQuery.sizeOf(context).height -
                      MediaQuery.viewInsetsOf(context).bottom -
                      MediaQuery.paddingOf(context).top -
                      12)
                  .clamp(0.0, MediaQuery.sizeOf(context).height * .88),
            ),
            child: SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 22),
              child: Center(
                  child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                      height: 4,
                      width: 42,
                      decoration: BoxDecoration(
                          color: AppPalette.border(context),
                          borderRadius: BorderRadius.circular(8))),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(
                      child: Text('Card payment',
                          style: TextStyle(
                              color: AppPalette.text(context),
                              fontSize: 21,
                              fontWeight: FontWeight.w800)),
                    ),
                    IconButton(
                      tooltip: 'Close card payment',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                      color: AppPalette.text(context),
                    ),
                  ]),
                  const SizedBox(height: 5),
                  Text(
                    'Card format is checked on this device. A payment provider is required to verify or charge a bank card.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: AppPalette.muted(context), fontSize: 12),
                  ),
                  const SizedBox(height: 18),
                  _PlanPaymentCard(
                      showBack: _showBack,
                      onTap: () => setState(() => _showBack = !_showBack),
                      brand: _brand,
                      number: _shownNumber,
                      expiry:
                          _expiryMonth.text.isEmpty && _expiryYear.text.isEmpty
                              ? 'MM / YY'
                              : _expiry,
                      cvc: _cvc.text),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _number,
                    onChanged: (_) => setState(() {}),
                    maxLength: 19,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                        labelText: 'Visa / Mastercard number',
                        prefixIcon: _PlanBrandMark(brand: _brand)),
                  ),
                  ResponsivePaymentFields(
                    expiry: _expiryFields(context),
                    securityCode: _cvcField(),
                  ),
                  if (_message != null)
                    Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(_message!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: _message!.startsWith('Card details')
                                    ? const Color(0xFF267342)
                                    : const Color(0xFFBA0007),
                                fontSize: 12))),
                  const SizedBox(height: 10),
                  FilledButton(
                      onPressed: _check,
                      style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFD30A02),
                          minimumSize: const Size.fromHeight(50)),
                      child: const Text('Continue with card')),
                ]),
              )),
            ),
          ),
        ),
      );

  Widget _expiryFields(BuildContext context) => Row(children: [
        Expanded(
            child: TextField(
          controller: _expiryMonth,
          onChanged: (_) => setState(() {}),
          maxLength: 2,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'MM', counterText: ''),
        )),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text('/',
              style: TextStyle(color: AppPalette.muted(context), fontSize: 20)),
        ),
        Expanded(
            child: TextField(
          controller: _expiryYear,
          onChanged: (_) => setState(() {}),
          maxLength: 2,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'YY', counterText: ''),
        )),
      ]);

  Widget _cvcField() => TextField(
        controller: _cvc,
        focusNode: _cvcFocus,
        maxLength: 4,
        obscureText: true,
        keyboardType: TextInputType.number,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(labelText: 'CVC', counterText: ''),
      );
}

class _PlanBrandMark extends StatelessWidget {
  const _PlanBrandMark({required this.brand});
  final String brand;

  @override
  Widget build(BuildContext context) {
    if (brand == 'VISA') {
      return const Center(
          child: Text('VISA',
              style: TextStyle(
                  color: Color(0xFF1434CB),
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                  fontStyle: FontStyle.italic)));
    }
    if (brand == 'mastercard') {
      return const Center(
          child: SizedBox(
              width: 29,
              child: Stack(children: [
                Positioned(
                    left: 2,
                    child: CircleAvatar(
                        radius: 8, backgroundColor: Color(0xFFEB001B))),
                Positioned(
                    right: 2,
                    child: CircleAvatar(
                        radius: 8, backgroundColor: Color(0xFFF79E1B))),
              ])));
    }
    return const Icon(Icons.credit_card_outlined);
  }
}

class _PlanPaymentCard extends StatelessWidget {
  const _PlanPaymentCard({
    required this.showBack,
    required this.onTap,
    required this.brand,
    required this.number,
    required this.expiry,
    required this.cvc,
  });
  final bool showBack;
  final VoidCallback onTap;
  final String brand;
  final String number;
  final String expiry;
  final String cvc;

  LinearGradient get _gradient => brand == 'VISA'
      ? const LinearGradient(
          colors: [Color(0xFF06184D), Color(0xFF0A3C92), Color(0xFF1459C7)])
      : brand == 'mastercard'
          ? const LinearGradient(
              colors: [Color(0xFF151515), Color(0xFF3D2020), Color(0xFF8D1F24)])
          : const LinearGradient(colors: [
              Color(0xFF101319),
              Color(0xFF333940),
              Color(0xFF16181B)
            ]);

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        duration: const Duration(milliseconds: 520),
        curve: Curves.easeInOutCubic,
        tween: Tween(end: showBack ? 1.0 : 0.0),
        builder: (context, turn, _) => GestureDetector(
          onTap: onTap,
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, .0015)
              ..rotateY(turn * 3.141592653589793),
            child: AspectRatio(
                aspectRatio: 1.72,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    gradient: _gradient,
                  ),
                  child: turn >= .5
                      ? Transform(
                          alignment: Alignment.center,
                          transform: Matrix4.rotationY(3.141592653589793),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 2),
                                Container(height: 24, color: Colors.black),
                                const SizedBox(height: 6),
                                const Text('AUTHORIZED SIGNATURE',
                                    style: TextStyle(
                                        color: Colors.white70, fontSize: 8)),
                                const SizedBox(height: 2),
                                Container(
                                    height: 24,
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10),
                                    alignment: Alignment.centerRight,
                                    color: Colors.white,
                                    child: Text(cvc.isEmpty ? 'CVV' : cvc,
                                        style: const TextStyle(
                                            color: Color(0xFF222222),
                                            letterSpacing: 2,
                                            fontWeight: FontWeight.w800))),
                                const Spacer(),
                                Align(
                                    alignment: Alignment.centerRight,
                                    child: Text(brand,
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 18,
                                            fontWeight: FontWeight.w900,
                                            fontStyle: FontStyle.italic))),
                              ]))
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                              Row(children: [
                                const Icon(Icons.contactless_rounded,
                                    color: Colors.white),
                                const Spacer(),
                                Text(brand,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 21,
                                        fontWeight: FontWeight.w900,
                                        fontStyle: FontStyle.italic)),
                              ]),
                              const Spacer(),
                              FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(number,
                                      maxLines: 1,
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 19,
                                          letterSpacing: 1.1,
                                          fontWeight: FontWeight.w600))),
                              const SizedBox(height: 12),
                              Text('EXPIRES  $expiry',
                                  style: const TextStyle(
                                      color: Colors.white70, fontSize: 11)),
                            ]),
                )),
          ),
        ),
      );
}

/// Corner accents sit in the outer padding, outside the QR and its quiet zone.
class _QrAccentDecoration extends Decoration {
  const _QrAccentDecoration();

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _QrAccentPainter();
}

class _QrAccentPainter extends BoxPainter {
  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null) return;
    final paint = Paint()
      ..color = const Color(0xFFBA0007)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    for (final corner in [
      const Offset(0, 0),
      Offset(size.width, 0),
      Offset(0, size.height),
      Offset(size.width, size.height),
    ]) {
      final dx = corner.dx == 0 ? 1.0 : -1.0;
      final dy = corner.dy == 0 ? 1.0 : -1.0;
      canvas.drawPath(
          Path()
            ..moveTo(corner.dx + dx * 23, corner.dy + dy * 5)
            ..lineTo(corner.dx + dx * 13, corner.dy + dy * 5)
            ..quadraticBezierTo(corner.dx + dx * 5, corner.dy + dy * 5,
                corner.dx + dx * 5, corner.dy + dy * 13)
            ..lineTo(corner.dx + dx * 5, corner.dy + dy * 23),
          paint);
    }
    canvas.restore();
  }
}

class _QrLoadingState extends StatelessWidget {
  const _QrLoadingState(
      {required this.error, required this.creating, required this.onRetry});
  final String? error;
  final bool creating;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: error == null
            ? const Column(mainAxisSize: MainAxisSize.min, children: [
                CircularProgressIndicator(color: Color(0xFFD30A02)),
                SizedBox(height: 14),
                Text('Creating secure QR...',
                    style: TextStyle(
                        color: Color(0xFF37434B), fontWeight: FontWeight.w700))
              ])
            : Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.cloud_off_rounded,
                    color: Color(0xFFD30A02), size: 38),
                const SizedBox(height: 10),
                Text(error!,
                    textAlign: TextAlign.center,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Color(0xFF5E666B), fontSize: 11.5)),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                    onPressed: creating ? null : onRetry,
                    icon: const Icon(Icons.refresh_rounded, size: 17),
                    label: const Text('Retry'))
              ]),
      );
}

class _PlanDetails {
  const _PlanDetails({
    required this.type,
    required this.name,
    required this.price,
    required this.period,
    required this.description,
    required this.features,
    this.badge,
  });

  final AppPlan type;
  final String name;
  final String price;
  final String period;
  final String description;
  final List<String> features;
  final String? badge;
}

class _VerticalPlanCard extends StatelessWidget {
  const _VerticalPlanCard({
    required this.plan,
    required this.current,
    required this.onChoose,
  });

  final _PlanDetails plan;
  final bool current;
  final VoidCallback onChoose;

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFD30A02);
    final text = AppPalette.text(context);
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: AppPalette.surface(context),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: current ? red : AppPalette.border(context),
          width: current ? 1.8 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .07),
            blurRadius: 18,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          plan.name,
                          style: TextStyle(
                            color: text,
                            fontSize: 27,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        if (plan.badge != null) ...[
                          const SizedBox(width: 9),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: red,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              plan.badge!,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 8.5,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      plan.description,
                      style: TextStyle(
                        color: AppPalette.muted(context),
                        fontSize: 12.5,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    plan.price,
                    style: const TextStyle(
                      color: red,
                      fontSize: 27,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    plan.period,
                    style: TextStyle(
                      color: AppPalette.muted(context),
                      fontSize: 9,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 20),
          const SizedBox(height: 18),
          Divider(
            height: 1,
            color: AppPalette.border(context),
          ),
          const SizedBox(height: 17),
          const SizedBox(height: 16),
          ...plan.features.map(
            (feature) => Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: Row(
                children: [
                  const Icon(
                    Icons.check_rounded,
                    color: red,
                    size: 16,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      feature,
                      style: TextStyle(
                        color: text,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: current
                ? OutlinedButton(
                    onPressed: null,
                    style: OutlinedButton.styleFrom(
                      disabledForegroundColor: red,
                      side: BorderSide(
                        color: red.withValues(alpha: .35),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(11),
                      ),
                    ),
                    child: const Text(
                      'Current plan',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  )
                : FilledButton(
                    onPressed: onChoose,
                    style: FilledButton.styleFrom(
                      backgroundColor: red,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(11),
                      ),
                    ),
                    child: Text(
                      'Choose ${plan.name}',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _CurrentPlanPill extends StatelessWidget {
  const _CurrentPlanPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xFFD30A02).withValues(alpha: .1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          '$label plan',
          style: const TextStyle(
            color: Color(0xFFD30A02),
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
}
