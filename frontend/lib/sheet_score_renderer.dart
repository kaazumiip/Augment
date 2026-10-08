import 'dart:convert';
import 'package:flutter/services.dart';

/// The score renderer travels with the APK; it needs no backend or CDN.
class SheetScoreRenderer {
  static Future<String>? _scriptUrl;
  static Future<String>? _scriptSource;

  static Future<String> loadScriptUrl() => _scriptUrl ??= _load();

  static Future<String> loadScriptSource() => _scriptSource ??= _loadSource();

  static Future<String> _loadSource() async {
    try {
      return await rootBundle
          .loadString('assets/web/js/opensheetmusicdisplay.min.js');
    } catch (_) {
      _scriptSource = null;
      rethrow;
    }
  }

  static Future<String> _load() async {
    try {
      final data = await rootBundle
          .load('assets/web/js/opensheetmusicdisplay.min.js');
      final bytes = data.buffer
          .asUint8List(data.offsetInBytes, data.lengthInBytes);
      return 'data:application/javascript;base64,${base64Encode(bytes)}';
    } catch (_) {
      _scriptUrl = null;
      rethrow;
    }
  }
}

