import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'sheet_artifact_service.dart';

class SavedSheet {
  const SavedSheet(
      {required this.title,
      required this.instrument,
      required this.createdAt,
      required this.result});

  final String title;
  final String instrument;
  final DateTime createdAt;
  final Map<String, dynamic> result;

  Map<String, dynamic> toJson() => {
        'title': title,
        'instrument': instrument,
        'created_at': createdAt.toIso8601String(),
        'result': result,
      };

  factory SavedSheet.fromJson(Map<String, dynamic> json) => SavedSheet(
        title: json['title']?.toString().trim().isNotEmpty == true
            ? json['title'].toString()
            : '${json['instrument']?.toString() ?? 'Music'} sheet',
        instrument: json['instrument']?.toString() ?? 'Music',
        createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '') ??
            DateTime.now(),
        result: Map<String, dynamic>.from(json['result'] as Map? ?? const {}),
      );
}

class GeneratedSheetsStore extends ChangeNotifier {
  GeneratedSheetsStore._();
  static final instance = GeneratedSheetsStore._();
  static const _keyPrefix = 'generated_sheets';
  static const _artifactService = SheetArtifactService();

  final List<SavedSheet> _sheets = [];
  bool _loaded = false;
  String? _loadedForUserId;
  Future<void>? _remoteLoad;
  List<SavedSheet> get sheets => List.unmodifiable(_sheets);

  String _storageKey(String? userId) =>
      '${_keyPrefix}_${userId ?? 'anonymous'}';

  /// Hydrate the on-device list only. This deliberately has no network work:
  /// a completed sheet must be saved and reopenable even when Supabase or the
  /// artifact upload is slow or unavailable.
  Future<void> _ensureLocalLoaded() async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (_loaded && _loadedForUserId == userId) return;
    _loaded = true;
    _loadedForUserId = userId;
    _remoteLoad = null;
    _sheets.clear();
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey(userId));
    if (raw != null) {
      try {
        final values = jsonDecode(raw) as List<dynamic>;
        _sheets
          ..clear()
          ..addAll(values.whereType<Map>().map(
              (item) => SavedSheet.fromJson(Map<String, dynamic>.from(item))));
        notifyListeners();
      } catch (_) {}
    }
  }

  /// Load the device cache only. This is deliberately the path used when the
  /// My Sheets page opens, so previously generated sheets appear immediately.
  Future<void> loadLocal() => _ensureLocalLoaded();

  /// Refresh cloud records after the local cache has already been displayed.
  /// Reuse a single sync so repeated widget builds cannot create repeated
  /// network work or competing list updates.
  Future<void> refreshFromCloud() async {
    await _ensureLocalLoaded();
    final inFlight = _remoteLoad;
    if (inFlight != null) return inFlight;
    final sync = _loadRemoteAndBackfill();
    _remoteLoad = sync;
    return sync;
  }

  /// Backwards-compatible combined load for callers that explicitly need a
  /// cloud refresh as well as the local cache.
  Future<void> load() async {
    await refreshFromCloud();
  }

  Future<void> _loadRemoteAndBackfill() async {
    await _loadRemote();
    await _backfillLocalSheets();
  }

  Future<void> add(
      {required String instrument,
      required Map<String, dynamic> result,
      bool syncRemote = true}) async {
    await _ensureLocalLoaded();
    final outputFile = result['output_file']?.toString();
    final previous = _sheets.cast<SavedSheet?>().firstWhere(
          (sheet) =>
              outputFile != null &&
              outputFile.isNotEmpty &&
              sheet?.result['output_file']?.toString() == outputFile,
          orElse: () => null,
        );
    final requestedTitle = result['title']?.toString().trim() ?? '';
    final title = previous?.title ??
        (requestedTitle.isNotEmpty ? requestedTitle : '$instrument sheet');
    _sheets.removeWhere((sheet) =>
        outputFile != null &&
        outputFile.isNotEmpty &&
        sheet.result['output_file']?.toString() == outputFile);
    _sheets.insert(
        0,
        SavedSheet(
            title: title,
            instrument: instrument,
            createdAt: previous?.createdAt ?? DateTime.now(),
            result: Map<String, dynamic>.from(result)
              ..addAll({
                'title': title,
                if (previous?.result['remote_project_id'] != null)
                  'remote_project_id': previous!.result['remote_project_id'],
                if (previous?.result['_pending_title_sync'] == true)
                  '_pending_title_sync': true,
              })));
    // Never delete a user's older sheet merely because a new one was saved.
    await _persist();
    notifyListeners();
    if (!syncRemote) return;
    final current = _sheets.first;
    final remoteId = current.result['remote_project_id']?.toString() ??
        await _saveRemote(current);
    if (remoteId != null) {
      final index = _sheets.indexWhere(
          (sheet) => sheet.result['output_file']?.toString() == outputFile);
      if (index < 0) return;
      final created = _sheets[index];
      _sheets[index] = SavedSheet(
        title: created.title,
        instrument: created.instrument,
        createdAt: created.createdAt,
        result: Map<String, dynamic>.from(created.result)
          ..['remote_project_id'] = remoteId,
      );
      await _persist();
      notifyListeners();
      await _syncPendingTitle(outputFile);
    }
  }

  Future<Map<String, dynamic>> saveGeneratedSheet({
    required String instrument,
    required Map<String, dynamic> result,
  }) async {
    final savedResult = Map<String, dynamic>.from(result);
    // Saving to My sheets must make the sheet available immediately. Cloud
    // artifact uploads (WAV/PDF/PNG/MusicXML) can take seconds and must never
    // keep the finished score on a loading screen.
    await add(
      instrument: instrument,
      result: savedResult,
      syncRemote: false,
    );
    final outputFile = savedResult['output_file']?.toString();
    final inlineXml = savedResult['musicxml_content']?.toString();
    if (outputFile != null &&
        outputFile.isNotEmpty &&
        inlineXml != null &&
        inlineXml.length > 100) {
      await cacheMusicXml(outputFile: outputFile, content: inlineXml);
    }
    final localResult = _sheets
        .firstWhere(
          (sheet) => sheet.result['output_file']?.toString() == outputFile,
          orElse: () => SavedSheet(
              title: '$instrument sheet',
              instrument: instrument,
              createdAt: DateTime.now(),
              result: savedResult),
        )
        .result;
    unawaited(_syncSavedSheetInBackground(
      outputFile: outputFile,
      sourceBaseUrl: savedResult['source_base_url']?.toString() ?? '',
      musicXml: inlineXml,
    ));
    return localResult;
  }

  Future<void> _syncSavedSheetInBackground({
    required String? outputFile,
    required String sourceBaseUrl,
    String? musicXml,
  }) async {
    if (outputFile == null || outputFile.isEmpty) return;
    var index = _sheets.indexWhere(
        (sheet) => sheet.result['output_file']?.toString() == outputFile);
    if (index < 0) return;
    final existing = _sheets[index];
    final resultForArtifactSync = Map<String, dynamic>.from(existing.result);
    if (musicXml != null && musicXml.length > 100) {
      resultForArtifactSync['musicxml_content'] = musicXml;
    }
    final synced = await _artifactService.persist(
      result: resultForArtifactSync,
      sourceBaseUrl: sourceBaseUrl,
    );
    if (synced['musicxml_url'] != null || synced['audio_url'] != null) {
      // The on-device file is the immediate/offline copy. Do not duplicate a
      // large XML document in SharedPreferences after its cloud artifact is
      // safely stored.
      final storedResult = Map<String, dynamic>.from(synced)
        ..remove('musicxml_content')
        ..remove('_pending_title_sync');
      index = _sheets.indexWhere(
          (sheet) => sheet.result['output_file']?.toString() == outputFile);
      if (index < 0) return;
      final latest = _sheets[index];
      _sheets[index] = SavedSheet(
        title: latest.title,
        instrument: latest.instrument,
        createdAt: latest.createdAt,
        result: Map<String, dynamic>.from(latest.result)
          ..addAll(storedResult)
          ..['title'] = latest.title
          ..['output_file'] = outputFile
          ..addAll(latest.result['_pending_title_sync'] == true
              ? {'_pending_title_sync': true}
              : {}),
      );
      await _persist();
      notifyListeners();
    }
    index = _sheets.indexWhere(
        (sheet) => sheet.result['output_file']?.toString() == outputFile);
    if (index < 0) return;
    final current = _sheets[index];
    final remoteId = current.result['remote_project_id']?.toString();
    if (remoteId == null || remoteId.isEmpty) {
      final createdId = await _saveRemote(current);
      if (createdId != null) {
        index = _sheets.indexWhere(
            (sheet) => sheet.result['output_file']?.toString() == outputFile);
        if (index < 0) return;
        final latest = _sheets[index];
        _sheets[index] = SavedSheet(
          title: latest.title,
          instrument: latest.instrument,
          createdAt: latest.createdAt,
          result: Map<String, dynamic>.from(latest.result)
            ..['remote_project_id'] = createdId,
        );
        await _persist();
        notifyListeners();
        await _syncPendingTitle(outputFile);
      }
    } else {
      await _updateRemoteSheet(remoteId, current.result);
    }
  }

  Future<bool> rename(SavedSheet sheet, String title) async {
    final clean = title.trim();
    if (clean.isEmpty) return false;
    final index = _sheets.indexWhere((item) =>
        item.createdAt == sheet.createdAt &&
        item.result['output_file'] == sheet.result['output_file']);
    if (index < 0) return false;
    final current = _sheets[index];
    final outputFile = current.result['output_file']?.toString();
    _sheets[index] = SavedSheet(
      title: clean,
      instrument: current.instrument,
      createdAt: current.createdAt,
      result: Map<String, dynamic>.from(current.result)
        ..['title'] = clean
        ..['_pending_title_sync'] = true,
    );
    await _persist();
    notifyListeners();
    await _syncPendingTitle(outputFile);
    return true;
  }

  Future<void> _syncPendingTitle(String? outputFile) async {
    final index = _sheets.indexWhere((sheet) =>
        outputFile != null &&
        sheet.result['output_file']?.toString() == outputFile);
    if (index < 0) return;
    final current = _sheets[index];
    if (current.result['_pending_title_sync'] != true) return;
    final remoteId = current.result['remote_project_id']?.toString();
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (remoteId == null || remoteId.isEmpty || userId == null) return;
    try {
      await Supabase.instance.client
          .from('sheet_projects')
          .update({
            'title': current.title,
            'updated_at': DateTime.now().toUtc().toIso8601String()
          })
          .eq('id', remoteId)
          .eq('user_id', userId);
      final latestIndex = _sheets.indexWhere(
          (sheet) => sheet.result['output_file']?.toString() == outputFile);
      if (latestIndex >= 0 && _sheets[latestIndex].title == current.title) {
        final latest = _sheets[latestIndex];
        _sheets[latestIndex] = SavedSheet(
          title: latest.title,
          instrument: latest.instrument,
          createdAt: latest.createdAt,
          result: Map<String, dynamic>.from(latest.result)
            ..remove('_pending_title_sync'),
        );
        await _persist();
      }
    } catch (_) {
      // Keep the local title and retry on the next cloud refresh.
    }
  }

  /// Lets the open sheet page rename its saved entry without needing to keep a
  /// stale [SavedSheet] instance while the store syncs in the background.
  Future<bool> renameByOutputFile(String outputFile, String title) async {
    await _ensureLocalLoaded();
    final sheet = _sheets.cast<SavedSheet?>().firstWhere(
          (item) => item?.result['output_file']?.toString() == outputFile,
          orElse: () => null,
        );
    if (sheet == null) return false;
    return rename(sheet, title);
  }

  Future<void> updateSavedResult({
    required String outputFile,
    required Map<String, dynamic> result,
    bool clearCachedAudio = false,
  }) async {
    await _ensureLocalLoaded();
    final index = _sheets.indexWhere(
        (sheet) => sheet.result['output_file']?.toString() == outputFile);
    if (index < 0) return;
    final existing = _sheets[index];
    final merged = Map<String, dynamic>.from(existing.result)..addAll(result);
    if (clearCachedAudio) merged.remove('cached_audio_path');
    _sheets[index] = SavedSheet(
      title: existing.title,
      instrument: existing.instrument,
      createdAt: existing.createdAt,
      result: merged,
    );
    await _persist();
    notifyListeners();
    await _updateRemoteSheet(
        existing.result['remote_project_id']?.toString(), merged);
  }

  Future<void> delete(SavedSheet sheet) async {
    final index = _sheets.indexWhere((item) =>
        item.result['remote_project_id'] == sheet.result['remote_project_id'] &&
        item.createdAt == sheet.createdAt);
    if (index < 0) return;
    final removed = _sheets.removeAt(index);
    await _deleteLocalCache(removed.result);
    await _persist();
    notifyListeners();
    final remoteId = removed.result['remote_project_id']?.toString();
    final userId = FirebaseAuth.instance.currentUser?.uid;
    try {
      await _artifactService.delete(removed.result);
      if (remoteId != null && remoteId.isNotEmpty && userId != null) {
        await Supabase.instance.client
            .from('sheet_projects')
            .delete()
            .eq('id', remoteId)
            .eq('user_id', userId);
      }
    } catch (_) {
      // The item is removed locally even if an offline cloud cleanup retries later.
    }
  }

  Future<Map<String, dynamic>> persistArtifacts({
    required Map<String, dynamic> result,
    required String sourceBaseUrl,
  }) =>
      _artifactService.persist(result: result, sourceBaseUrl: sourceBaseUrl);

  Future<void> _loadRemote() async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) return;
    try {
      final rows = await Supabase.instance.client
          .from('sheet_projects')
          .select('id,title,instrument,created_at,result')
          .eq('user_id', userId)
          .order('created_at', ascending: false)
          .limit(100);
      final remote = (rows as List)
          .cast<Map<String, dynamic>>()
          .map((row) => SavedSheet(
                title: row['title']?.toString().trim().isNotEmpty == true
                    ? row['title'].toString()
                    : '${row['instrument']?.toString() ?? 'Music'} sheet',
                instrument: row['instrument']?.toString() ?? 'Music',
                createdAt:
                    DateTime.tryParse(row['created_at']?.toString() ?? '') ??
                        DateTime.now(),
                result:
                    Map<String, dynamic>.from(row['result'] as Map? ?? const {})
                      ..['remote_project_id'] = row['id']?.toString(),
              ))
          .where((sheet) => sheet.result.isNotEmpty)
          .toList();
      for (final sheet in remote.reversed) {
        final localIndex = _sheets.indexWhere((local) =>
            local.result['output_file'] == sheet.result['output_file']);
        final local = localIndex < 0 ? null : _sheets[localIndex];
        if (localIndex >= 0) _sheets.removeAt(localIndex);
        // Cloud rows intentionally omit device paths. Keep the local artifact
        // references so an already-saved sheet continues to open offline
        // after a refresh or app restart.
        final mergedResult = _mergeWithLocalCaches(sheet.result, local?.result);
        final pendingTitle = local?.result['_pending_title_sync'] == true;
        final title = pendingTitle ? local!.title : sheet.title;
        mergedResult['title'] = title;
        if (pendingTitle) mergedResult['_pending_title_sync'] = true;
        _sheets.insert(
            0,
            SavedSheet(
              title: title,
              instrument: sheet.instrument,
              createdAt: sheet.createdAt,
              result: mergedResult,
            ));
      }
      // Cloud refresh may return only a page; preserve older device copies.
      await _persist();
      notifyListeners();
      for (final sheet in _sheets
          .where((sheet) => sheet.result['_pending_title_sync'] == true)
          .toList()) {
        await _syncPendingTitle(sheet.result['output_file']?.toString());
      }
    } catch (_) {
      // Local sheets remain available if Supabase is temporarily offline.
    }
  }

  Future<String?> _saveRemote(SavedSheet sheet) async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) return null;
    try {
      final row = await Supabase.instance.client
          .from('sheet_projects')
          .insert({
            'user_id': userId,
            'title': sheet.title,
            'instrument': sheet.instrument,
            'result': _remoteResult(sheet.result),
            'created_at': sheet.createdAt.toUtc().toIso8601String(),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .select('id')
          .single();
      return row['id']?.toString();
    } catch (_) {
      // The local copy is retained and will remain usable on this device.
      return null;
    }
  }

  Future<String?> readCachedMusicXml(Map<String, dynamic> result) async {
    final cloudContent = result['musicxml_content']?.toString();
    if (cloudContent != null && cloudContent.length > 100) {
      return cloudContent;
    }
    final path = result['cached_music_xml_path']?.toString();
    if (path != null && path.isNotEmpty) {
      try {
        final file = File(path);
        if (await file.exists()) {
          final contents = await file.readAsString();
          if (contents.length > 100) return contents;
        }
      } catch (_) {}
    }
    final cloudUrl = result['musicxml_url']?.toString();
    if (cloudUrl == null || !cloudUrl.startsWith('http')) return null;
    try {
      final response = await http.get(Uri.parse(cloudUrl));
      if (response.statusCode == 200 && response.body.length > 100) {
        return response.body;
      }
    } catch (_) {
      // A saved local file may be unavailable after app data was cleared.
    }
    return null;
  }

  Future<String?> readCachedAudioPath(Map<String, dynamic> result) async {
    final path = result['cached_audio_path']?.toString();
    if (path == null || path.isEmpty) return null;
    try {
      final file = File(path);
      if (await file.exists() && await file.length() > 0) return file.path;
    } catch (_) {}
    return null;
  }

  Future<void> cacheAudio({
    required String outputFile,
    required String audioFile,
    required Uint8List bytes,
  }) async {
    if (outputFile.isEmpty || audioFile.isEmpty || bytes.isEmpty) return;
    await _ensureLocalLoaded();
    final index = _sheets.indexWhere(
        (sheet) => sheet.result['output_file']?.toString() == outputFile);
    if (index < 0) return;
    final safeAudioName = audioFile.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final documents = await getApplicationDocumentsDirectory();
    final userFolder = (FirebaseAuth.instance.currentUser?.uid ?? 'anonymous')
        .replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final cacheDirectory = Directory(
        '${documents.path}${Platform.pathSeparator}sheets${Platform.pathSeparator}$userFolder');
    if (!await cacheDirectory.exists()) {
      await cacheDirectory.create(recursive: true);
    }
    final cachedFile =
        File('${cacheDirectory.path}${Platform.pathSeparator}$safeAudioName');
    await cachedFile.writeAsBytes(bytes, flush: true);
    final existing = _sheets[index];
    _sheets[index] = SavedSheet(
      title: existing.title,
      instrument: existing.instrument,
      createdAt: existing.createdAt,
      result: Map<String, dynamic>.from(existing.result)
        ..['cached_audio_path'] = cachedFile.path,
    );
    await _persist();
    notifyListeners();
  }

  Future<void> cacheMusicXml({
    required String outputFile,
    required String content,
  }) async {
    if (outputFile.isEmpty || content.length < 100) return;
    await _ensureLocalLoaded();
    final index = _sheets.indexWhere((sheet) {
      if (sheet.result['output_file']?.toString() == outputFile) return true;
      final parts = sheet.result['parts'] as List<dynamic>? ?? const [];
      return parts
          .whereType<Map>()
          .any((part) => part['output_file']?.toString() == outputFile);
    });
    if (index < 0) return;

    final safeName = outputFile.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final documents = await getApplicationDocumentsDirectory();
    final userFolder = (FirebaseAuth.instance.currentUser?.uid ?? 'anonymous')
        .replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final cacheDirectory = Directory(
        '${documents.path}${Platform.pathSeparator}sheets${Platform.pathSeparator}$userFolder');
    if (!await cacheDirectory.exists()) {
      await cacheDirectory.create(recursive: true);
    }
    final cachedFile =
        File('${cacheDirectory.path}${Platform.pathSeparator}$safeName');
    await cachedFile.writeAsString(content, flush: true);

    final existing = _sheets[index];
    final updatedResult = Map<String, dynamic>.from(existing.result);
    if (updatedResult['output_file']?.toString() == outputFile) {
      updatedResult
        ..['cached_music_xml_path'] = cachedFile.path
        ..remove('musicxml_content');
    } else {
      final parts = updatedResult['parts'] as List<dynamic>? ?? const [];
      updatedResult['parts'] = parts.map((value) {
        final part = Map<String, dynamic>.from(value as Map);
        if (part['output_file']?.toString() == outputFile) {
          part
            ..['cached_music_xml_path'] = cachedFile.path
            ..remove('musicxml_content');
        }
        return part;
      }).toList();
    }
    _sheets[index] = SavedSheet(
      title: existing.title,
      instrument: existing.instrument,
      createdAt: existing.createdAt,
      result: updatedResult,
    );
    await _persist();
    notifyListeners();
    await _updateRemoteSheet(
        existing.result['remote_project_id']?.toString(), updatedResult);
  }

  Future<void> _updateRemoteSheet(
      String? remoteId, Map<String, dynamic> result) async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (remoteId == null || remoteId.isEmpty || userId == null) return;
    try {
      await Supabase.instance.client
          .from('sheet_projects')
          .update({
            'result': _remoteResult(result),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', remoteId)
          .eq('user_id', userId);
    } catch (_) {
      // Local cache remains usable if the network is unavailable.
    }
  }

  Map<String, dynamic> _mergeWithLocalCaches(
      Map<String, dynamic> remote, Map<String, dynamic>? local) {
    final merged = Map<String, dynamic>.from(remote);
    if (local == null) return merged;

    void preserveCachedFields(
        Map<String, dynamic> destination, Map<String, dynamic> source) {
      for (final entry in source.entries) {
        if (entry.key.startsWith('cached_') && entry.value != null) {
          destination[entry.key] = entry.value;
        }
      }
    }

    preserveCachedFields(merged, local);
    final remoteParts = merged['parts'] as List?;
    final localParts = local['parts'] as List?;
    if (remoteParts == null || localParts == null) return merged;
    merged['parts'] = remoteParts.whereType<Map>().map((remotePart) {
      final part = Map<String, dynamic>.from(remotePart);
      final localPart = localParts.whereType<Map>().cast<Map>().firstWhere(
          (candidate) =>
              candidate['output_file']?.toString() ==
              part['output_file']?.toString(),
          orElse: () => const <String, dynamic>{});
      preserveCachedFields(part, Map<String, dynamic>.from(localPart));
      return part;
    }).toList();
    return merged;
  }

  Map<String, dynamic> _remoteResult(Map<String, dynamic> result) {
    final cleaned = Map<String, dynamic>.from(result)
      ..remove('musicxml_content')
      ..remove('cached_music_xml_path')
      ..remove('_pending_title_sync');
    final parts = cleaned['parts'] as List?;
    if (parts != null) {
      cleaned['parts'] = parts
          .whereType<Map>()
          .map((part) => _remoteResult(Map<String, dynamic>.from(part)))
          .toList();
    }
    return cleaned;
  }

  Future<void> _deleteLocalCache(Map<String, dynamic> result) async {
    final paths = <String>[
      result['cached_music_xml_path']?.toString() ?? '',
      result['cached_audio_path']?.toString() ?? '',
      for (final part in (result['parts'] as List? ?? const []))
        if (part is Map) part['cached_music_xml_path']?.toString() ?? '',
    ].where((path) => path.isNotEmpty).toSet();
    for (final path in paths) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  Future<void> _backfillLocalSheets() async {
    if (FirebaseAuth.instance.currentUser == null) return;
    var changed = false;
    for (var index = 0; index < _sheets.length; index++) {
      var sheet = _sheets[index];
      final outputFile = sheet.result['output_file']?.toString();
      final sourceBaseUrl = sheet.result['source_base_url']?.toString();
      if (sheet.result['musicxml_url'] == null &&
          sourceBaseUrl != null &&
          sourceBaseUrl.isNotEmpty) {
        final syncedResult = await _artifactService.persist(
          result: sheet.result,
          sourceBaseUrl: sourceBaseUrl,
        );
        if (syncedResult['musicxml_url'] != null) {
          final latestIndex = _sheets.indexWhere((candidate) =>
              candidate.result['output_file']?.toString() == outputFile);
          if (latestIndex < 0) continue;
          index = latestIndex;
          final latest = _sheets[index];
          sheet = SavedSheet(
            title: latest.title,
            instrument: latest.instrument,
            createdAt: latest.createdAt,
            result: Map<String, dynamic>.from(latest.result)
              ..addAll(syncedResult)
              ..['title'] = latest.title
              ..addAll(latest.result['_pending_title_sync'] == true
                  ? {'_pending_title_sync': true}
                  : {}),
          );
          _sheets[index] = sheet;
          changed = true;
        }
      }
      final remoteId = sheet.result['remote_project_id']?.toString();
      if (remoteId != null && remoteId.isNotEmpty) continue;
      final createdId = await _saveRemote(sheet);
      if (createdId == null) continue;
      final latestIndex = _sheets.indexWhere((candidate) =>
          candidate.result['output_file']?.toString() == outputFile);
      if (latestIndex < 0) continue;
      index = latestIndex;
      sheet = _sheets[index];
      _sheets[index] = SavedSheet(
        title: sheet.title,
        instrument: sheet.instrument,
        createdAt: sheet.createdAt,
        result: Map<String, dynamic>.from(sheet.result)
          ..['remote_project_id'] = createdId,
      );
      await _syncPendingTitle(outputFile);
      changed = true;
    }
    if (changed) {
      await _persist();
      notifyListeners();
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _storageKey(FirebaseAuth.instance.currentUser?.uid),
      jsonEncode(_sheets.map((sheet) => sheet.toJson()).toList()),
    );
  }

  void clearSession() {
    _sheets.clear();
    _loaded = false;
    _loadedForUserId = null;
    _remoteLoad = null;
    notifyListeners();
  }
}
