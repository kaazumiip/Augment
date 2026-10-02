import 'package:flutter_test/flutter_test.dart';
import '../lib/marketplace_payment_service.dart';

void main() {
  test('paid purchase retains listing identity rather than matching by title',
      () {
    final first = MarketplacePurchase.fromJson({
      'orderId': 'order-one',
      'listingId': 'listing-one',
      'title': 'Same title',
      'paidAt': '2026-10-03T00:00:00Z',
    });
    final second = MarketplacePurchase.fromJson({
      'orderId': 'order-two',
      'listingId': 'listing-two',
      'title': 'Same title',
      'paidAt': '2026-10-03T00:00:00Z',
    });
    expect(first.listingId, 'listing-one');
    expect(second.listingId, 'listing-two');
    expect(first.listingId, isNot(second.listingId));
  });

  test('legacy purchase without listing identity remains accessible', () {
    final purchase = MarketplacePurchase.fromJson({
      'orderId': 'legacy',
      'title': 'Music',
      'assetUrl': 'https://example.com/music.pdf',
    });
    expect(purchase.listingId, isNull);
    expect(purchase.assetUrl, 'https://example.com/music.pdf');
  });
}
