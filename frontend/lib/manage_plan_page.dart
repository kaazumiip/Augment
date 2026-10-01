import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'app_settings.dart';
import 'bakong_payment_service.dart';

class ManagePlanPage extends StatefulWidget {
  const ManagePlanPage({super.key});

  @override
  State<ManagePlanPage> createState() => _ManagePlanPageState();
}

class _ManagePlanPageState extends State<ManagePlanPage> {
  static const _red = Color(0xFFD30A02);

  BillingSubscription? _subscription;
  PlanGenerationUsage? _usage;
  List<BakongPayment> _payments = const [];
  String? _billingError;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadBilling();
  }

  Future<void> _loadBilling() async {
    try {
      final values = await Future.wait([
        BakongPaymentService.subscription(),
        BakongPaymentService.paymentHistory(),
        BakongPaymentService.generationUsage(),
      ]);
      if (!mounted) return;
      final subscription = values[0] as BillingSubscription;
      AppSettings.instance.applyServerPlan(subscription.plan);
      setState(() {
        _subscription = subscription;
        _payments = values[1] as List<BakongPayment>;
        _usage = values[2] as PlanGenerationUsage;
        _billingError = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _billingError =
            'Billing data is unavailable. Check that the app server is running.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _cancelPlan(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Turn off renewal?'),
        content: const Text(
          'You will keep your paid features until the end of the current billing period. Bakong will not charge automatically; this only stops renewal reminders.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep plan'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: _red),
            child: const Text('Turn off renewal'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await BakongPaymentService.setAutoRenew(false);
      await _loadBilling();
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text('Could not update renewal settings. Please try again.')),
      );
      return;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
            content: Text(
                'Auto-renewal is off. Your plan remains active until its renewal date.')),
      );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppPalette.page(context),
        body: SafeArea(
          child: ListenableBuilder(
            listenable: AppSettings.instance,
            builder: (context, _) {
              final isFree = AppSettings.instance.plan == AppPlan.free;
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 36),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppBackButton(
                      onPressed: () => Navigator.maybePop(context),
                    ),
                    const SizedBox(height: 12),
                    RichText(
                      text: TextSpan(
                        text: 'Manage plan',
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
                    const SizedBox(height: 24),
                    const _SectionLabel(label: 'Your plan'),
                    const SizedBox(height: 10),
                    if (_loading)
                      const Center(
                          child: Padding(
                              padding: EdgeInsets.all(24),
                              child: CircularProgressIndicator()))
                    else if (_billingError != null)
                      _BillingUnavailable(
                          message: _billingError!, onRetry: _loadBilling)
                    else
                      _CurrentPlanCard(
                          isFree: isFree, subscription: _subscription),
                    if (!_loading && _usage != null) ...[
                      const SizedBox(height: 14),
                      _GenerationUsageCard(usage: _usage!),
                    ],
                    const SizedBox(height: 28),
                    const _SectionLabel(label: 'Payment history'),
                    const SizedBox(height: 10),
                    if (!_loading && _billingError == null)
                      _PaymentHistory(payments: _payments)
                    else
                      const _EmptyPaymentHistory(),
                    const SizedBox(height: 28),
                    if (_subscription?.permanent != true) ...[
                      const _SectionLabel(label: 'Cancel plan'),
                      const SizedBox(height: 10),
                      _CancelSection(
                        enabled: !isFree,
                        onCancel: () => _cancelPlan(context),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Text(
        label,
        style: TextStyle(
          color: AppPalette.text(context),
          fontSize: 17,
          fontWeight: FontWeight.w900,
        ),
      );
}

class _CurrentPlanCard extends StatelessWidget {
  const _CurrentPlanCard({required this.isFree, required this.subscription});

  final bool isFree;
  final BillingSubscription? subscription;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppPalette.surface(context),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppPalette.border(context)),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: const Color(0xFFD30A02).withValues(alpha: .1),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.workspace_premium_rounded,
                color: Color(0xFFD30A02),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${AppSettings.instance.planLabel} plan',
                    style: TextStyle(
                      color: AppPalette.text(context),
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isFree
                        ? 'Free forever'
                        : subscription?.permanent == true
                            ? 'Redeemed Pro · no expiry or renewal'
                            : subscription?.currentPeriodEnd == null
                                ? 'Active subscription'
                                : '${subscription!.autoRenew ? 'Renewal reminder' : 'Ends'} ${_date(subscription!.currentPeriodEnd!)}',
                    style: TextStyle(
                      color: AppPalette.muted(context),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFF18864B).withValues(alpha: .1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'ACTIVE',
                style: TextStyle(
                  color: Color(0xFF18864B),
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
      );
}

class _GenerationUsageCard extends StatelessWidget {
  const _GenerationUsageCard({required this.usage});
  final PlanGenerationUsage usage;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppPalette.surface(context),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppPalette.border(context)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Sheet generations this month',
              style: TextStyle(
                  color: AppPalette.text(context),
                  fontSize: 14,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
              usage.limit == null
                  ? '${usage.used} completed · Unlimited on Pro'
                  : '${usage.used} of ${usage.limit} used · ${usage.remaining} remaining',
              style: TextStyle(color: AppPalette.muted(context), fontSize: 12)),
          if (usage.inProgress > 0) ...[
            const SizedBox(height: 4),
            Text('${usage.inProgress} generation in progress',
                style:
                    TextStyle(color: AppPalette.muted(context), fontSize: 11)),
          ],
        ]),
      );
}

String _date(DateTime value) =>
    '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year}';

class _BillingUnavailable extends StatelessWidget {
  const _BillingUnavailable({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
            color: AppPalette.surface(context),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppPalette.border(context))),
        child: Column(children: [
          Text(message,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppPalette.muted(context))),
          const SizedBox(height: 10),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ]),
      );
}

class _PaymentHistory extends StatelessWidget {
  const _PaymentHistory({required this.payments});
  final List<BakongPayment> payments;

  @override
  Widget build(BuildContext context) {
    if (payments.isEmpty) return const _EmptyPaymentHistory();
    return Container(
      decoration: BoxDecoration(
          color: AppPalette.surface(context),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppPalette.border(context))),
      child: Column(
          children: payments
              .take(10)
              .map((payment) => ListTile(
                    leading: const Icon(Icons.receipt_long_rounded,
                        color: Color(0xFFD30A02)),
                    title: Text(
                        '${payment.plan.name[0].toUpperCase()}${payment.plan.name.substring(1)} plan'),
                    subtitle: Text(
                        payment.status == 'paid' ? 'Paid' : payment.status),
                    trailing: Text(_date(payment.expiresAt),
                        style: TextStyle(
                            color: AppPalette.muted(context), fontSize: 11)),
                  ))
              .toList()),
    );
  }
}

class _EmptyPaymentHistory extends StatelessWidget {
  const _EmptyPaymentHistory();

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 25),
        decoration: BoxDecoration(
          color: AppPalette.surface(context),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppPalette.border(context)),
        ),
        child: Column(
          children: [
            Icon(
              Icons.receipt_long_rounded,
              size: 30,
              color: AppPalette.muted(context),
            ),
            const SizedBox(height: 10),
            Text(
              'No payments yet',
              style: TextStyle(
                color: AppPalette.text(context),
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Your receipts and payment dates will appear here.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppPalette.muted(context),
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ],
        ),
      );
}

class _CancelSection extends StatelessWidget {
  const _CancelSection({required this.enabled, required this.onCancel});

  final bool enabled;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppPalette.surface(context),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppPalette.border(context)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              enabled
                  ? 'You will move to the Free plan when you cancel.'
                  : 'There is no paid plan to cancel.',
              style: TextStyle(
                color: AppPalette.muted(context),
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 15),
            SizedBox(
              width: double.infinity,
              height: 45,
              child: OutlinedButton(
                onPressed: enabled ? onCancel : null,
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFD30A02),
                  side: BorderSide(
                    color: enabled
                        ? const Color(0xFFD30A02)
                        : AppPalette.border(context),
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  'Cancel plan',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ],
        ),
      );
}
