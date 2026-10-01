import 'dart:convert';
import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

class SheetArtifactService {
  const SheetArtifactService();

  Future<Map<String, dynamic>> persist({
    required Map<String, dynamic> result,
    required String sourceBaseUrl,
  }) async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) return result;

    final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    const artifacts = {
      'output_file': 'musicxml_url',
      'pdf_file': 'pdf_url',
      'audio_file': 'audio_url',
      'sheet_image': 'sheet_image_url',
    };
    Future<Map<String, dynamic>> persistMap(Map<String, dynamic> source) async {
      final updated = Map<String, dynamic>.from(source);
      for (final entry in artifacts.entries) {
        final filename = source[entry.key]?.toString();
        if (filename == null || filename.isEmpty) continue;
        try {
          Uint8List? bytes;
          // MusicXML may already be loaded in the app. Upload that durable
          // copy directly so saving does not depend on a temporary backend
          // output still existing when the user taps "save".
          final inlineXml = entry.key == 'output_file'
              ? source['musicxml_content']?.toString()
              : null;
          if (inlineXml != null && inlineXml.length > 100) {
            bytes = Uint8List.fromList(utf8.encode(inlineXml));
          } else if (sourceBaseUrl.isNotEmpty) {
            final response = await http.get(
              Uri.parse('$sourceBaseUrl/api/sheet/download/$filename'),
              headers: {
                'Authorization':
                    'Bearer ${await FirebaseAuth.instance.currentUser!.getIdToken()}',
              },
            ).timeout(const Duration(minutes: 3));
            if (response.statusCode >= 200 && response.statusCode < 300) {
              bytes = response.bodyBytes;
              if (entry.key == 'output_file' && response.body.length > 100) {
                updated['musicxml_content'] = response.body;
              }
            }
          }
          if (bytes == null || bytes.isEmpty) continue;
          final safeName = filename.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
          final path = '$userId/sheets/$stamp/$safeName';
          await Supabase.instance.client.storage
              .from('sheet-assets')
              .uploadBinary(
                path,
                bytes,
                fileOptions: const FileOptions(upsert: true),
              );
          updated[entry.value] = Supabase.instance.client.storage
              .from('sheet-assets')
              .getPublicUrl(path);
        } catch (_) {
          // The local backend copy remains available and can be synced later.
        }
      }
      return updated;
    }

    final updated = await persistMap(result);
    final parts = result['parts'] as List<dynamic>?;
    if (parts != null) {
      updated['parts'] = await Future.wait(parts
          .whereType<Map>()
          .map((part) => persistMap(Map<String, dynamic>.from(part))));
    }
    return updated;
  }

  Future<void> delete(Map<String, dynamic> result) async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) return;
    const keys = ['musicxml_url', 'pdf_url', 'audio_url', 'sheet_image_url'];
    final urls = <String>[
      for (final key in keys)
        if (result[key] is String) result[key] as String,
      for (final part in (result['parts'] as List? ?? const []))
        if (part is Map)
          for (final key in keys)
            if (part[key] is String) part[key] as String,
    ];
    final paths = urls
        .map((url) => _pathFromPublicUrl(url, userId))
        .whereType<String>()
        .toSet()
        .toList();
    if (paths.isNotEmpty) {
      await Supabase.instance.client.storage.from('sheet-assets').remove(paths);
    }
  }

  String? _pathFromPublicUrl(String url, String userId) {
    try {
      final segments = Uri.parse(url).pathSegments;
      final bucketIndex = segments.indexOf('sheet-assets');
      if (bucketIndex < 0 || bucketIndex + 1 >= segments.length) return null;
      final path = segments.sublist(bucketIndex + 1).join('/');
      return path.startsWith('$userId/sheets/') ? path : null;
    } catch (_) {
      return null;
    }
  }
}
