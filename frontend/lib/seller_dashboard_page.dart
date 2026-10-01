import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'marketplace_payment_service.dart';
import 'seller_payout_page.dart';
import 'social_service.dart';

/// Seller-facing marketplace view.  Funds are purchase records held by
/// Augment; requesting a payout never marks money as transferred.
class SellerDashboardPage extends StatefulWidget {
  const SellerDashboardPage({super.key});

  @override
  State<SellerDashboardPage> createState() => _SellerDashboardPageState();
}

class _SellerDashboardPageState extends State<SellerDashboardPage> {
  MarketplaceSellerSummary? _summary;
  Object? _error;
  bool _loading = true;
  bool _requestingPayout = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final summary = await MarketplacePaymentService.sellerSummary();
      if (mounted) setState(() => _summary = summary);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _requestPayout() async {
    final summary = _summary;
    if (summary == null || summary.availableBalance <= 0) return;
    // A payout request is only actionable when the seller has told Augment
    // where the manual transfer should go.
    try {
      final destination = await SocialService.instance.sellerPayout();
      if (destination == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Add your ABA / KHQR payout destination first.'),
        ));
        await Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const SellerPayoutPage()));
        return;
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not confirm your payout destination.'),
      ));
      return;
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Request payout?'),
        content: Text(
          'Request ${_money(summary.availableBalance)} for manual payout to your saved ABA / KHQR destination. This does not transfer money automatically.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Not now')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Request payout')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _requestingPayout = true);
    try {
      final updated = await MarketplacePaymentService.requestSellerPayout();
      if (!mounted) return;
      setState(() => _summary = updated);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content:
            Text('Payout requested. Augment will review and pay it manually.'),
      ));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not request payout: $error')));
      }
    } finally {
      if (mounted) setState(() => _requestingPayout = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = AppPalette.text(context);
    return Scaffold(
      backgroundColor: AppPalette.page(context),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? ListView(children: [
                      const SizedBox(height: 180),
                      Icon(Icons.cloud_off_rounded,
                          color: AppPalette.muted(context), size: 42),
                      const SizedBox(height: 12),
                      Center(
                          child: Text('Could not load your seller dashboard.',
                              style: TextStyle(color: text))),
                      const SizedBox(height: 12),
                      Center(
                          child: OutlinedButton(
                              onPressed: _load,
                              child: const Text('Try again'))),
                    ])
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(22, 12, 22, 34),
                      children: [
                        Row(children: [
                          AppBackButton(
                              onPressed: () => Navigator.pop(context)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text('Seller dashboard',
                                style: TextStyle(
                                    color: text,
                                    fontSize: 24,
                                    fontWeight: FontWeight.w800)),
                          ),
                          IconButton(
                              tooltip: 'Refresh',
                              onPressed: _load,
                              icon: const Icon(Icons.refresh_rounded)),
                        ]),
                        const SizedBox(height: 18),
                        _BalanceCard(summary: _summary!),
                        const SizedBox(height: 14),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(52),
                              backgroundColor: const Color(0xFFCA000A)),
                          onPressed: _requestingPayout ||
                                  _summary!.availableBalance <= 0
                              ? null
                              : _requestPayout,
                          icon: _requestingPayout
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      color: Colors.white, strokeWidth: 2))
                              : const Icon(
                                  Icons.account_balance_wallet_outlined),
                          label: Text(_summary!.availableBalance > 0
                              ? 'Request ${_money(_summary!.availableBalance)} payout'
                              : 'No payout available yet'),
                        ),
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: () async {
                            await Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => const SellerPayoutPage()));
                          },
                          icon: const Icon(Icons.qr_code_2_rounded),
                          label: const Text('Payout destination'),
                        ),
                        const SizedBox(height: 24),
                        Text('Your products',
                            style: TextStyle(
                                color: text,
                                fontSize: 19,
                                fontWeight: FontWeight.w800)),
                        const SizedBox(height: 10),
                        _Listings(
                            ownerId: FirebaseAuth.instance.currentUser?.uid),
                        const SizedBox(height: 24),
                        Text('Recent sales',
                            style: TextStyle(
                                color: text,
                                fontSize: 19,
                                fontWeight: FontWeight.w800)),
                        const SizedBox(height: 10),
                        if (_summary!.sales.isEmpty)
                          const _EmptyCard(
                              icon: Icons.receipt_long_outlined,
                              label:
                                  'Sales will appear here after a buyer pays.')
                        else
                          ..._summary!.sales
                              .map((sale) => _SaleTile(sale: sale)),
                      ],
                    ),
        ),
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.summary});
  final MarketplaceSellerSummary summary;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(20),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: const Color(0xFFCA000A),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Stack(children: [
          Padding(
            padding: const EdgeInsets.only(right: 102),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Available balance',
                  style: TextStyle(
                      color: Colors.white70, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(_money(summary.availableBalance),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 34,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 16),
              Row(children: [
                _BalanceDetail('Requested', summary.payoutRequestedBalance),
                const SizedBox(width: 12),
                _BalanceDetail(
                    'Awaiting payment', summary.awaitingBuyerPaymentBalance),
              ]),
            ]),
          ),
          Positioned(
            right: -6,
            bottom: -17,
            child: IgnorePointer(
              child: Image.asset(
                'assets/augment_bunny_mascot_wink.png',
                height: 142,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
                semanticLabel: 'Augment mascot winking',
              ),
            ),
          ),
        ]),
      );
}

class _BalanceDetail extends StatelessWidget {
  const _BalanceDetail(this.label, this.amount);
  final String label;
  final double amount;
  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 11)),
          const SizedBox(height: 3),
          Text(_money(amount),
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w800)),
        ]),
      );
}

class _Listings extends StatelessWidget {
  const _Listings({required this.ownerId});
  final String? ownerId;
  @override
  Widget build(BuildContext context) {
    final userId = ownerId;
    if (userId == null) {
      return const _EmptyCard(
          icon: Icons.lock_outline_rounded,
          label: 'Sign in to see your products.');
    }
    return StreamBuilder<List<MarketplaceListing>>(
      stream: SocialService.instance.marketplaceListings(userId),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const _EmptyCard(
              icon: Icons.cloud_off_rounded,
              label: 'Your listings could not be loaded.');
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.data!.isEmpty) {
          return const _EmptyCard(
              icon: Icons.storefront_outlined,
              label: 'You have no published products yet.');
        }
        return Column(
            children: snapshot.data!
                .map((listing) => _ListingTile(listing: listing))
                .toList(growable: false));
      },
    );
  }
}

class _ListingTile extends StatelessWidget {
  const _ListingTile({required this.listing});
  final MarketplaceListing listing;
  @override
  Widget build(BuildContext context) => Card(
        color: AppPalette.surface(context),
        child: ListTile(
          leading: CircleAvatar(
              backgroundColor: const Color(0xFFFFE8E5),
              child:
                  Icon(Icons.music_note_rounded, color: Colors.red.shade800)),
          title:
              Text(listing.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(listing.category),
          trailing: Text(_money(listing.price),
              style: const TextStyle(fontWeight: FontWeight.w800)),
        ),
      );
}

class _SaleTile extends StatelessWidget {
  const _SaleTile({required this.sale});
  final MarketplaceSellerSale sale;
  @override
  Widget build(BuildContext context) => Card(
        color: AppPalette.surface(context),
        child: ListTile(
          leading: const CircleAvatar(child: Icon(Icons.receipt_long_outlined)),
          title: Text(sale.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
              '${sale.quantity} item${sale.quantity == 1 ? '' : 's'} · ${_statusLabel(sale.payoutStatus)}'),
          trailing: Text(_money(sale.amount),
              style: const TextStyle(fontWeight: FontWeight.w800)),
        ),
      );
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({required this.icon, required this.label});
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppPalette.surface(context),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppPalette.border(context)),
        ),
        child: Row(children: [
          Icon(icon, color: AppPalette.muted(context)),
          const SizedBox(width: 12),
          Expanded(
              child: Text(label,
                  style: TextStyle(color: AppPalette.muted(context)))),
        ]),
      );
}

String _statusLabel(String status) {
  switch (status) {
    case 'available':
      return 'Ready for payout';
    case 'requested':
      return 'Payout requested';
    case 'paid':
      return 'Paid out';
    default:
      return 'Awaiting buyer payment';
  }
}

String _money(double amount) => '\$${amount.toStringAsFixed(2)}';
