import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import 'api_config.dart';

class MarketplacePayment {
  const MarketplacePayment({
    required this.id,
    required this.amount,
    required this.currency,
    required this.status,
    required this.qrImage,
    required this.expiresAt,
    required this.recipientName,
    required this.paymentLink,
  });

  final String id;
  final double amount;
  final String currency;
  final String status;
  final String? qrImage;
  final DateTime expiresAt;
  final String? recipientName;
  final String? paymentLink;

  factory MarketplacePayment.fromJson(Map<String, dynamic> json) =>
      MarketplacePayment(
        id: json['id']?.toString() ?? '',
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
        currency: json['currency']?.toString() ?? 'USD',
        status: json['status']?.toString() ?? 'pending',
        qrImage: json['qrImage']?.toString(),
        expiresAt: DateTime.parse(json['expiresAt']?.toString() ??
            DateTime.now().toUtc().toIso8601String()),
        recipientName: json['recipientName']?.toString(),
        paymentLink: json['paymentLink']?.toString(),
      );
}

class MarketplaceCheckoutItem {
  const MarketplaceCheckoutItem(
      {required this.listingId, required this.quantity});
  final String listingId;
  final int quantity;

  Map<String, dynamic> toJson() =>
      {'listingId': listingId, 'quantity': quantity};
}

class MarketplaceSellerSale {
  const MarketplaceSellerSale({
    required this.orderId,
    required this.title,
    required this.quantity,
    required this.amount,
    required this.orderStatus,
    required this.payoutStatus,
  });

  final String orderId;
  final String title;
  final int quantity;
  final double amount;
  final String orderStatus;
  final String payoutStatus;

  factory MarketplaceSellerSale.fromJson(Map<String, dynamic> json) =>
      MarketplaceSellerSale(
        orderId: json['orderId']?.toString() ?? '',
        title: json['title']?.toString() ?? 'Marketplace item',
        quantity: (json['quantity'] as num?)?.toInt() ?? 0,
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
        orderStatus: json['orderStatus']?.toString() ?? 'pending',
        payoutStatus: json['payoutStatus']?.toString() ?? 'awaiting_payment',
      );
}

class MarketplacePurchase {
  const MarketplacePurchase({
    required this.orderId,
    required this.title,
    required this.quantity,
    required this.paidAt,
    this.listingId,
    this.assetUrl,
  });

  final String orderId;
  final String? listingId;
  final String title;
  final int quantity;
  final DateTime paidAt;
  final String? assetUrl;

  factory MarketplacePurchase.fromJson(Map<String, dynamic> json) =>
      MarketplacePurchase(
        orderId: json['orderId']?.toString() ?? '',
        listingId: json['listingId']?.toString(),
        title: json['title']?.toString() ?? 'Marketplace item',
        quantity: (json['quantity'] as num?)?.toInt() ?? 1,
        paidAt:
            DateTime.tryParse(json['paidAt']?.toString() ?? '')?.toLocal() ??
                DateTime.now(),
        assetUrl: json['assetUrl']?.toString(),
      );
}

class MarketplaceSellerSummary {
  const MarketplaceSellerSummary({
    required this.currency,
    required this.availableBalance,
    required this.payoutRequestedBalance,
    required this.paidOutBalance,
    required this.awaitingBuyerPaymentBalance,
    required this.sales,
  });

  final String currency;
  final double availableBalance;
  final double payoutRequestedBalance;
  final double paidOutBalance;
  final double awaitingBuyerPaymentBalance;
  final List<MarketplaceSellerSale> sales;

  factory MarketplaceSellerSummary.fromJson(Map<String, dynamic> json) =>
      MarketplaceSellerSummary(
        currency: json['currency']?.toString() ?? 'USD',
        availableBalance: (json['availableBalance'] as num?)?.toDouble() ?? 0,
        payoutRequestedBalance:
            (json['payoutRequestedBalance'] as num?)?.toDouble() ?? 0,
        paidOutBalance: (json['paidOutBalance'] as num?)?.toDouble() ?? 0,
        awaitingBuyerPaymentBalance:
            (json['awaitingBuyerPaymentBalance'] as num?)?.toDouble() ?? 0,
        sales: ((json['sales'] as List?) ?? const [])
            .whereType<Map>()
            .map((sale) =>
                MarketplaceSellerSale.fromJson(Map<String, dynamic>.from(sale)))
            .toList(growable: false),
      );
}

class _MarketplaceServerError implements Exception {
  const _MarketplaceServerError(this.message);
  final String message;

  @override
  String toString() => message;
}

class MarketplacePaymentService {
  const MarketplacePaymentService._();

  static final _purchaseChanges = StreamController<void>.broadcast();
  static Stream<void> get purchaseChanges => _purchaseChanges.stream;

  static Future<MarketplacePayment> createCheckout(
          List<MarketplaceCheckoutItem> items) async =>
      MarketplacePayment.fromJson(
          await _request('POST', '/api/marketplace/checkout', body: {
        'items': items.map((item) => item.toJson()).toList(),
      }));

  static Future<MarketplacePayment> verify(String paymentId) async {
    final payment = MarketplacePayment.fromJson(await _request(
        'POST', '/api/payments/bakong/$paymentId/verify',
        body: const {}));
    if (payment.status == 'paid') _purchaseChanges.add(null);
    return payment;
  }

  static Future<MarketplaceSellerSummary> sellerSummary() async =>
      MarketplaceSellerSummary.fromJson(await _request(
          'GET', '/api/marketplace/seller/summary',
          body: const {}));

  static Future<MarketplaceSellerSummary> requestSellerPayout() async =>
      MarketplaceSellerSummary.fromJson(await _request(
          'POST', '/api/marketplace/seller/request-payout',
          body: const {}));

  static Future<List<MarketplacePurchase>> purchases() async {
    final data =
        await _request('GET', '/api/marketplace/purchases', body: const {});
    return ((data['purchases'] as List?) ?? const [])
        .whereType<Map>()
        .map((item) =>
            MarketplacePurchase.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }

  static Future<Map<String, dynamic>> _request(String method, String path,
      {required Map<String, dynamic> body}) async {
    final token = await FirebaseAuth.instance.currentUser?.getIdToken();
    if (token == null) throw Exception('Please sign in before checking out.');
    Object? lastError;
    for (final baseUrl in ApiConfig.baseUrls) {
      try {
        final request = http.Request(method, Uri.parse('$baseUrl$path'))
          ..headers.addAll({
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          });
        if (method != 'GET') request.body = jsonEncode(body);
        final response = await http.Response.fromStream(
            await request.send().timeout(const Duration(seconds: 20)));
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return data;
        }
        // A server response is authoritative. Trying the emulator address
        // afterward hides the actual cart/Bakong error behind a timeout.
        throw _MarketplaceServerError(
            data['error']?.toString() ?? 'Checkout request failed.');
      } on _MarketplaceServerError {
        rethrow;
      } on TimeoutException {
        lastError =
            Exception('The checkout server took too long. Please retry.');
      } catch (error) {
        lastError = error;
      }
    }
    throw Exception(lastError?.toString() ?? 'Checkout is unavailable.');
  }
}
