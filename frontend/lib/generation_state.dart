import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import 'api_config.dart';
import 'band_part.dart';

class _GenerationJobFailed implements Exception {
  const _GenerationJobFailed(this.message);

  final String message;

  @override
  String toString() => message;
}

class GenerationState extends ChangeNotifier {
  static final GenerationState instance = GenerationState._();
  GenerationState._();

  List<String> get _baseUrls => ApiConfig.baseUrls;

  bool isGenerating = false;
  bool isFinished = false;
  bool hasError = false;
  bool generationLimitReached = false;
  String statusText = '';
  String fileName = '';
  String instrumentName = '';
  String mode = 'solo';
  List<BandPart> bandParts = const [];
  double progress = 0.0;
  Map<String, dynamic>? result;
  String? errorMsg;
  int _generationToken = 0;

  bool get hasResult => result != null && !isGenerating;

  Future<void> startGeneration({
    required String instrumentName,
    required String source,
    String mode = 'solo',
    List<BandPart> bandParts = const [],
    String? fileUrl,
    String? filePath,
  }) async {
    if (isGenerating) return;

    final generationToken = ++_generationToken;

    isGenerating = true;
    isFinished = false;
    hasError = false;
    generationLimitReached = false;
    this.instrumentName = instrumentName;
    this.mode = mode;
    this.bandParts = List.unmodifiable(bandParts);
    fileName =
        filePath?.split(Platform.pathSeparator).last ?? fileUrl ?? 'link';
    statusText = 'Preparing...';
    progress = 0.0;
    result = null;
    errorMsg = null;
    notifyListeners();

    try {
      Map<String, dynamic> apiResult;
      String? artifactBaseUrl;

      if (source == 'link' && fileUrl != null) {
        statusText = 'Processing link...';
        progress = 0.05;
        notifyListeners();
        final response = await _postJsonWithFallback(
          '/api/sheet/generate-url',
          {
            'url': fileUrl,
            'instrument': instrumentName,
            'mode': mode,
            if (bandParts.isNotEmpty)
              'instruments': bandParts.map((part) => part.toJson()).toList(),
          },
        );
        artifactBaseUrl = response.request?.url.origin;
        if (response.statusCode < 200 || response.statusCode >= 300) {
          generationLimitReached = response.statusCode == 403;
          _fail(
            generationLimitReached
                ? _readServerError(response.body)
                : 'Server error (${response.statusCode}): ${_readServerError(response.body)}',
            generationToken,
          );
          return;
        }
        apiResult = jsonDecode(response.body);
        if (apiResult is String) {
          apiResult = {'error': apiResult};
        }
      } else {
        if (filePath == null) {
          _fail('No file selected', generationToken);
          return;
        }
        statusText = 'Uploading file...';
        progress = 0.05;
        notifyListeners();
        final file = File(filePath);
        statusText = 'Generating sheet music...';
        progress = 0.10;
        notifyListeners();
        final streamedResponse = await _sendMultipartWithFallback(
          '/api/sheet/generate',
          file,
          instrumentName,
          mode,
          bandParts,
        );
        artifactBaseUrl = streamedResponse.request?.url.origin;
        final responseBody = await streamedResponse.stream.bytesToString();
        if (streamedResponse.statusCode < 200 ||
            streamedResponse.statusCode >= 300) {
          generationLimitReached = streamedResponse.statusCode == 403;
          _fail(
            generationLimitReached
                ? _readServerError(responseBody)
                : 'Upload failed (${streamedResponse.statusCode}): ${_readServerError(responseBody)}',
            generationToken,
          );
          return;
        }
        if (responseBody.trimLeft().startsWith('<')) {
          _fail(
            'The backend returned an unexpected web page. Restart the Node server and try again.',
            generationToken,
          );
          return;
        }
        apiResult = jsonDecode(responseBody);
        final jobId = apiResult['job_id'];
        if (jobId is String && jobId.isNotEmpty) {
          final requestUrl = streamedResponse.request?.url;
          final jobBaseUrl = requestUrl?.origin ?? _baseUrls.first;
          statusText = 'Transcribing audio...';
          notifyListeners();
          apiResult = await _waitForGenerationJob(
            jobBaseUrl,
            jobId,
            generationToken,
          );
        }
      }

      if (generationToken != _generationToken) return;
      if (apiResult['error'] != null) {
        _fail(apiResult['error'].toString(), generationToken);
        return;
      }

      statusText = 'Finalizing...';
      progress = 1.0;
      notifyListeners();

      if (artifactBaseUrl != null) {
        apiResult['source_base_url'] = artifactBaseUrl;
      }

      statusText = 'Loading your finished sheet...';
      progress = .98;
      notifyListeners();
      // A backend response means rendering is complete, but the score page
      // used to start a second MusicXML download after this screen closed.
      // Fetch it while the generation screen is still visible and pass the
      // content straight into the score page instead.
      await _preloadCompletedMusicXml(
        apiResult,
        artifactBaseUrl,
        generationToken,
      );

      await Future.delayed(const Duration(milliseconds: 500));

      if (generationToken != _generationToken) return;
      result = apiResult;
      isGenerating = false;
      isFinished = true;
      statusText = 'Sheet ready!';
      notifyListeners();
    } catch (e) {
      _fail(e.toString(), generationToken);
    }
  }

  Future<void> _preloadCompletedMusicXml(
    Map<String, dynamic> result,
    String? artifactBaseUrl,
    int generationToken,
  ) async {
    if (artifactBaseUrl == null || artifactBaseUrl.isEmpty) return;
    final targets = <Map<String, dynamic>>[result];
    for (final part in result['parts'] as List<dynamic>? ?? const []) {
      if (part is Map) targets.add(Map<String, dynamic>.from(part));
    }
    await Future.wait(targets.map((target) async {
      if (generationToken != _generationToken) return;
      final outputFile = target['output_file']?.toString();
      if (outputFile == null || outputFile.isEmpty) return;
      try {
        final response = await http
            .get(
              Uri.parse('$artifactBaseUrl/api/sheet/download/$outputFile'),
              headers: await _headers(),
            )
            .timeout(const Duration(seconds: 20));
        if (response.statusCode == 200 && response.body.length > 100) {
          target['musicxml_content'] = response.body;
          // For a band result, put the enriched map back into its exact part
          // entry instead of only changing a temporary copy.
          if (!identical(target, result)) {
            final parts = result['parts'] as List<dynamic>? ?? const [];
            final index = parts.indexWhere((part) =>
                part is Map && part['output_file']?.toString() == outputFile);
            if (index >= 0) {
              parts[index] = target;
            }
          }
        }
      } catch (_) {
        // The score page retains its existing cache/network fallback.
      }
    }));
  }

  void _fail(String msg, [int? generationToken]) {
    if (generationToken != null && generationToken != _generationToken) return;
    if (!isGenerating) {
      return;
    }
    isGenerating = false;
    hasError = true;
    errorMsg = msg;
    statusText = generationLimitReached
        ? 'Generation limit reached'
        : 'Generation failed';
    notifyListeners();
  }

  String _readServerError(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] != null) {
        return decoded['error'].toString();
      }
    } catch (_) {}
    return body.length > 180 ? '${body.substring(0, 180)}...' : body;
  }

  Future<Map<String, dynamic>> _waitForGenerationJob(
    String baseUrl,
    String jobId,
    int generationToken,
  ) async {
    const maxChecks = 900; // 30 minutes at one short request every two seconds.
    for (var check = 0; check < maxChecks; check += 1) {
      if (generationToken != _generationToken) {
        throw const _GenerationJobFailed('Generation was cancelled.');
      }
      try {
        final response = await http
            .get(
              Uri.parse('$baseUrl/api/sheet/jobs/$jobId'),
              headers: await _headers(),
            )
            .timeout(const Duration(seconds: 20));
        if (response.statusCode == 404) {
          throw Exception(
              'The generation job was lost because the Node server restarted. Generate the sheet again.');
        }
        if (response.statusCode == 200) {
          final job = jsonDecode(response.body) as Map<String, dynamic>;
          final serverProgress = (job['progress'] as num?)?.toDouble();
          if (serverProgress != null) {
            progress = (serverProgress / 100).clamp(0.0, 0.95);
            statusText = job['stage']?.toString() ?? 'Processing audio';
            notifyListeners();
          }
          if (job['status'] == 'complete' && job['result'] is Map) {
            return Map<String, dynamic>.from(job['result'] as Map);
          }
          if (job['status'] == 'failed') {
            throw _GenerationJobFailed(
              job['error']?.toString() ?? 'Generation failed',
            );
          }
        }
      } catch (error) {
        if (error is _GenerationJobFailed) rethrow;
        // A single missed status check should not discard a long-running job.
        if (check == maxChecks - 1) rethrow;
      }
      await Future.delayed(const Duration(seconds: 2));
    }
    throw Exception('Generation timed out after 30 minutes.');
  }

  Future<http.Response> _postJsonWithFallback(
      String path, Map<String, dynamic> body) async {
    Object? lastError;

    for (final baseUrl in _baseUrls) {
      try {
        return await http.post(
          Uri.parse('$baseUrl$path'),
          headers: await _headers(json: true),
          body: jsonEncode(body),
        );
      } catch (e) {
        lastError = e;
      }
    }

    throw lastError ?? Exception('Unable to connect to backend');
  }

  Future<http.StreamedResponse> _sendMultipartWithFallback(
    String path,
    File file,
    String instrumentName,
    String mode,
    List<BandPart> bandParts,
  ) async {
    Object? lastError;

    for (final baseUrl in _baseUrls) {
      try {
        final request =
            http.MultipartRequest('POST', Uri.parse('$baseUrl$path'));
        request.headers.addAll(await _headers());
        request.fields['instrument'] = instrumentName;
        request.fields['mode'] = mode;
        if (bandParts.isNotEmpty) {
          request.fields['instruments'] =
              jsonEncode(bandParts.map((part) => part.toJson()).toList());
        }
        request.files.add(await http.MultipartFile.fromPath('file', file.path));
        return await request.send();
      } catch (e) {
        lastError = e;
      }
    }

    throw lastError ?? Exception('Unable to connect to backend');
  }

  Future<Map<String, String>> _headers({bool json = false}) async {
    final token = await FirebaseAuth.instance.currentUser?.getIdToken();
    if (token == null || token.isEmpty) {
      throw Exception('Sign in before generating a music sheet.');
    }
    return {
      'Authorization': 'Bearer $token',
      if (json) 'Content-Type': 'application/json',
    };
  }

  void clearResult() {
    result = null;
    isFinished = false;
    hasError = false;
    generationLimitReached = false;
    errorMsg = null;
    statusText = '';
    progress = 0.0;
    notifyListeners();
  }

  void dismissBanner() {
    isFinished = false;
    hasError = false;
    generationLimitReached = false;
    notifyListeners();
  }

  void cancelGeneration() {
    if (!isGenerating) return;
    _generationToken += 1;
    isGenerating = false;
    isFinished = false;
    hasError = false;
    generationLimitReached = false;
    result = null;
    errorMsg = null;
    statusText = '';
    progress = 0.0;
    notifyListeners();
  }
}
