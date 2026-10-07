import 'package:flutter/foundation.dart';

class ApiConfig {
  const ApiConfig._();

  static const _defaultProductionUrl =
      'https://augment-production-f590.up.railway.app';
  static const _configuredUrl = String.fromEnvironment('AUGMENT_API_URL');

  static List<String> get baseUrls {
    final configured = _normalize(_configuredUrl);
    if (configured.isNotEmpty) return [configured];
    if (kReleaseMode) {
      return const [_defaultProductionUrl];
    }
    // 127.0.0.1 works with `adb reverse`; 10.0.2.2 is the Android emulator.
    return const [
      _defaultProductionUrl,
      'http://127.0.0.1:3000',
      'http://10.0.2.2:3000',
    ];
  }

  static String get primaryUrl => baseUrls.first;

  static String _normalize(String value) =>
      value.trim().replaceFirst(RegExp(r'/+$'), '');
}
