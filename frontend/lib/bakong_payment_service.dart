import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import 'api_config.dart';
import 'app_settings.dart';

class BakongPayment {
  const BakongPayment({
    required this.id,
    required this.plan,
    required this.status,
    required this.qrImage,
    required this.expiresAt,
    required this.paymentLink,
    required this.amount,
    required this.currency,
    required this.verificationUsed,
    this.recipientName,
  });

  final String id;
  final AppPlan plan;
  final String status;
  final String? qrImage;
  final DateTime expiresAt;
  final String? paymentLink;
  final double amount;
  final String currency;
  final bool verificationUsed;
  final String? recipientName;

  factory BakongPayment.fromJson(Map<String, dynamic> json) => BakongPayment(
        id: json['id'] as String,
        plan: AppPlan.values.byName(json['plan'] as String),
        status: json['status'] as String,
        qrImage: json['qrImage'] as String?,
        expiresAt: DateTime.parse(json['expiresAt'] as String),
        paymentLink: json['paymentLink'] as String?,
        amount: (json['amount'] as num).toDouble(),
        currency: json['currency'] as String,
        verificationUsed: json['verificationUsed'] == true,
        recipientName: json['recipientName'] as String?,
      );
}

class BakongPaymentService {
  const BakongPaymentService._();

  static Future<BakongPayment> createCheckout(AppPlan plan) async {
    if (plan == AppPlan.free) {
      throw Exception('Free plans do not need a payment.');
    }
    return _post('/api/payments/bakong/checkout', {'plan': plan.name});
  }

  static Future<BakongPayment> verify(String id) =>
      _post('/api/payments/bakong/$id/verify', const {});

  static Future<BillingSubscription> subscription() async {
    final data = await _request('GET', '/api/billing/subscription');
    return BillingSubscription.fromJson(data);
  }

  static Future<BillingSubscription> redeemCode(String code) async {
    final data = await _request('POST', '/api/billing/redeem',
        body: {'code': code.trim()});
    return BillingSubscription.fromJson(data);
  }

  static Future<PlanGenerationUsage> generationUsage() async {
    final data = await _request('GET', '/api/billing/usage');
    return PlanGenerationUsage.fromJson(data);
  }

  static Future<BillingSubscription> setAutoRenew(bool value) async {
    final data = await _request('POST', '/api/billing/subscription/auto-renew',
        body: {'autoRenew': value});
    return BillingSubscription.fromJson(data);
  }

  static Future<List<BakongPayment>> paymentHistory() async {
    // Manage Plan is a receipt list, not a record of QR codes or card forms
    // that were merely opened. The server also applies this filter.
    final data = await _request('GET', '/api/payments?status=paid');
    final payments = data['payments'] as List<dynamic>? ?? const [];
    // Marketplace orders share the backend payment ledger but are not plan
    // receipts. Never let an order with plan:null break Manage Plan's
    // subscription history parsing.
    return payments
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .where((item) => item['kind']?.toString() != 'marketplace')
        .where((item) => item['status']?.toString().toLowerCase() == 'paid')
        .where((item) =>
            AppPlan.values.any((plan) => plan.name == item['plan']?.toString()))
        .map(BakongPayment.fromJson)
        .toList();
  }

  static Future<BakongPayment> _post(
      String route, Map<String, dynamic> body) async {
    return BakongPayment.fromJson(await _request('POST', route, body: body));
  }

  static Future<Map<String, dynamic>> _request(String method, String route,
      {Map<String, dynamic>? body}) async {
    final token = await FirebaseAuth.instance.currentUser?.getIdToken();
    if (token == null) {
      throw Exception('Please sign in again before making a payment.');
    }
    Object? lastError;
    for (final baseUrl in ApiConfig.baseUrls) {
      try {
        final request = http.Request(method, Uri.parse('$baseUrl$route'))
          ..headers.addAll({
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          });
        if (body != null) request.body = jsonEncode(body);
        final streamed =
            await request.send().timeout(const Duration(seconds: 15));
        final response = await http.Response.fromStream(streamed);
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return data;
        }
        throw Exception(data['error']?.toString() ?? 'Payment request failed.');
      } on TimeoutException {
        lastError = Exception(
            'The payment server took too long to respond. Tap Retry.');
      } catch (error) {
        lastError = error;
      }
    }
    throw Exception(lastError?.toString() ?? 'Payment service is unavailable.');
  }
}

class BillingSubscription {
  const BillingSubscription(
      {required this.plan,
      required this.status,
      required this.autoRenew,
      this.source,
      this.permanent = false,
      this.currentPeriodEnd,
      this.gracePeriodEnd});
  final AppPlan plan;
  final String status;
  final bool autoRenew;
  final String? source;
  final bool permanent;
  final DateTime? currentPeriodEnd;
  final DateTime? gracePeriodEnd;

  factory BillingSubscription.fromJson(Map<String, dynamic> json) =>
      BillingSubscription(
        plan: AppPlan.values.byName(json['plan'] as String),
        status: json['status'] as String,
        autoRenew: json['autoRenew'] == true,
        source: json['source'] as String?,
        permanent: json['permanent'] == true,
        currentPeriodEnd: json['currentPeriodEnd'] == null
            ? null
            : DateTime.parse(json['currentPeriodEnd'] as String),
        gracePeriodEnd: json['gracePeriodEnd'] == null
            ? null
            : DateTime.parse(json['gracePeriodEnd'] as String),
      );
}

class PlanGenerationUsage {
  const PlanGenerationUsage(
      {required this.plan,
      required this.month,
      required this.used,
      required this.inProgress,
      this.limit,
      this.remaining});

  final AppPlan plan;
  final String month;
  final int used;
  final int inProgress;
  final int? limit;
  final int? remaining;

  factory PlanGenerationUsage.fromJson(Map<String, dynamic> json) =>
      PlanGenerationUsage(
        plan: AppPlan.values.byName(json['plan'] as String),
        month: json['month'] as String,
        used: (json['used'] as num).toInt(),
        inProgress: (json['inProgress'] as num).toInt(),
        limit: (json['limit'] as num?)?.toInt(),
        remaining: (json['remaining'] as num?)?.toInt(),
      );
}
