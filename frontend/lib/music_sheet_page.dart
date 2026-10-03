import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_saver/file_saver.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'generated_sheets_store.dart';
import 'pdf_preview_page.dart';
import 'app_palette.dart';
import 'api_config.dart';
import 'music_note_editor.dart';
import 'sheet_name_editor.dart';
import 'sheet_score_renderer.dart';
import 'sheet_playback_seek_guard.dart';

class MusicSheetPage extends StatefulWidget {
  final String instrumentName;
  final Map<String, dynamic>? apiResult;
  final int sheetNumber;
  final SavedSheet? savedSheet;

  const MusicSheetPage({
    Key? key,
    required this.instrumentName,
    this.apiResult,
    this.sheetNumber = 1,
    this.savedSheet,
  }) : super(key: key);

  @override
  State<MusicSheetPage> createState() => _MusicSheetPageState();
}

class _MusicSheetPageState extends State<MusicSheetPage>
    with SingleTickerProviderStateMixin {
  static const Color brandRed = Color(0xFFBA0007);
  List<String> get _baseUrls => ApiConfig.baseUrls;
  List<String> get _musicXmlSourceUrls {
    final source = _activeResult['source_base_url']?.toString().trim() ?? '';
    return {
      if (source.startsWith('http')) source.replaceFirst(RegExp(r'/+$'), ''),
      ..._baseUrls,
    }.toList(growable: false);
  }

  bool _isPlaying = false;
  bool _isLooping = false;
  bool _isFullscreen = false;
  late AnimationController _playController;
  AudioPlayer? _audioPlayer;
  InAppWebViewController? _sheetController;
  StreamSubscription<Duration>? _positionSubscription;
  bool _hasPlayed = false;
  bool _loadingAudio = false;
  bool _isScrubbing = false;
  bool _resumeAfterScrub = false;
  bool _isSheetDragging = false;
  bool _resumeAfterSheetDrag = false;
  Future<void>? _audioReady;
  final _seekGuard = SheetPlaybackSeekGuard();
  String? _preparedAudioIdentity;
  Future<void>? _sourcePreparation;

  int _totalNotes = 0;
  String _instrument = '';
  String _outputFile = '';
  String _sheetServerUrl = ApiConfig.primaryUrl;
  bool _pdfAvailable = false;
  String _pdfFile = '';
  bool _audioAvailable = false;
  String _audioFile = '';
  double _audioDuration = 8.0;
  int _tempo = 120;
  double _playbackTempo = 120;
  String _keySignature = 'C';
  String _timeSignature = '4/4';
  String _transcriptionQuality = 'unverified';
  List<String> _transcriptionWarnings = const [];
  String _sourceStrategy = '';
  String _sourceStem = '';

  bool _sheetImageAvailable = false;
  String _sheetImageFile = '';

  String _musicXmlContent = '';
  String? _scoreRendererUrl;
  String? _scoreRendererError;
  bool _isLoadingMusicXml = false;
  int _sheetLoadToken = 0;
  String? _sheetLoadError;
  List<dynamic> _playbackEvents = const [];
  late Map<String, dynamic> _activeResult;
  int _selectedBandView = 0;
  bool _savingToMySheets = false;
  bool _savedToMySheets = false;
  bool _leavingSheet = false;
  bool _allowPop = false;
  late String _sheetTitle;

  @override
  void initState() {
    super.initState();
    _activeResult = Map<String, dynamic>.from(widget.apiResult ?? const {});
    _savedToMySheets = widget.savedSheet != null ||
        _activeResult['remote_project_id']?.toString().isNotEmpty == true;
    _parseApiResult();
    _loadScoreRenderer();
    final resultTitle = _activeResult['title']?.toString().trim() ?? '';
    _sheetTitle = widget.savedSheet?.title ??
        (resultTitle.isNotEmpty
            ? resultTitle
            : '${_instrument.isEmpty ? widget.instrumentName : _instrument} sheet');
    GeneratedSheetsStore.instance.addListener(_refreshSavedTitle);
    _loadCachedMusicXmlOrFetch();
    _playController = AnimationController(
      vsync: this,
      duration: Duration(seconds: _audioDuration.ceil().clamp(1, 600)),
    );
    if (_audioAvailable) {
      _audioReady = _initAudio();
    }
  }

  Future<void> _loadScoreRenderer() async {
    try {
      final url = await SheetScoreRenderer.loadScriptUrl();
      if (mounted) setState(() => _scoreRendererUrl = url);
    } catch (_) {
      if (mounted) {
        setState(() => _scoreRendererError =
            'Could not load the sheet viewer. Please reopen this sheet.');
      }
    }
  }

  void _refreshSavedTitle() {
    if (!mounted || _outputFile.isEmpty) return;
    for (final sheet in GeneratedSheetsStore.instance.sheets) {
      if (sheet.result['output_file']?.toString() != _outputFile) continue;
      if (sheet.title != _sheetTitle) {
        setState(() {
          _sheetTitle = sheet.title;
          _activeResult['title'] = sheet.title;
          _savedToMySheets = true;
        });
      }
      return;
    }
  }

  void _parseApiResult() {
    final data = _activeResult;
    if (data.isEmpty) return;

    _totalNotes = (data['total_notes'] as num?)?.toInt() ?? 0;
    _instrument = data['instrument'] ?? widget.instrumentName;
    _outputFile = data['output_file'] ?? '';
    _pdfFile = data['pdf_file']?.toString() ?? '';
    if (_pdfFile.isEmpty && _outputFile.isNotEmpty) {
      _pdfFile = _outputFile.replaceFirst(
        RegExp(r'\.(musicxml|xml)$', caseSensitive: false),
        '.pdf',
      );
    }
    // Guitar exports can finish MusicXML before MuseScore's PDF flag reaches
    // the client. Keep the PDF action visible whenever a predictable PDF
    // filename exists; the download endpoint can serve the completed export
    // once it is ready instead of hiding the option entirely.
    _pdfAvailable = _pdfFile.isNotEmpty;
    _audioAvailable = data['audio_available'] ?? false;
    _audioFile = data['audio_file'] ?? '';
    _audioDuration = (data['audio_duration'] as num?)?.toDouble() ?? 8.0;
    _tempo = (data['tempo'] as num?)?.round() ?? 120;
    _playbackTempo = (data['tempo'] as num?)?.toDouble() ?? 120;
    _keySignature = data['key_signature'] ?? 'C';
    _timeSignature = data['time_signature'] ?? '4/4';
    _transcriptionQuality = data['transcription_quality'] ?? 'unverified';
    _sourceStrategy = data['source_strategy']?.toString() ?? '';
    _sourceStem = data['source_stem']?.toString() ?? '';
    _transcriptionWarnings = (data['warnings'] as List<dynamic>? ?? const [])
        .map((warning) => warning.toString())
        .where((warning) => warning.isNotEmpty)
        .toList(growable: false);
    _playbackEvents = data['playback_events'] as List<dynamic>? ?? const [];
    if (_audioDuration <= 0) _audioDuration = 8.0;

    _sheetImageAvailable = data['sheet_image_available'] ?? false;
    _sheetImageFile = data['sheet_image'] ?? '';
    debugPrint(
        'Parsed API result: outputFile=$_outputFile, sheetImage=$_sheetImageAvailable, totalNotes=$_totalNotes');
  }

  Future<void> _loadCachedMusicXmlOrFetch() async {
    if (_outputFile.isEmpty) return;
    final loadToken = _sheetLoadToken;
    // The generation page now hands off the completed MusicXML directly.
    // Use it before checking disk/network so a finished generation opens as a
    // finished score, rather than showing another loading pass.
    final inlineXml = _activeResult['musicxml_content']?.toString();
    if (inlineXml != null && inlineXml.length > 100) {
      setState(() => _musicXmlContent = inlineXml);
      unawaited(GeneratedSheetsStore.instance.cacheMusicXml(
        outputFile: _outputFile,
        content: inlineXml,
      ));
      if (_audioPlayer != null && _audioAvailable) {
        await _setAudioSourceWithFallback();
      }
      return;
    }
    final cached =
        await GeneratedSheetsStore.instance.readCachedMusicXml(_activeResult);
    if (!mounted || loadToken != _sheetLoadToken) return;
    if (cached != null) {
      setState(() {
        _musicXmlContent = cached;
        // Keep the already-loaded score with the result so saving the sheet
        // cannot race the backend's temporary artifact cleanup.
        _activeResult = Map<String, dynamic>.from(_activeResult)
          ..['musicxml_content'] = cached;
      });
      if (_audioPlayer != null && _audioAvailable) {
        await _setAudioSourceWithFallback();
      }
      return;
    }
    await _fetchMusicXml();
  }

  List<Map<String, dynamic>> get _bandViews {
    final root = widget.apiResult;
    if (root == null || root['mode'] != 'band') return const [];
    final views = <Map<String, dynamic>>[Map<String, dynamic>.from(root)];
    final parts = root['parts'] as List<dynamic>? ?? const [];
    for (final value in parts.whereType<Map>()) {
      final part = Map<String, dynamic>.from(value);
      final stats = part['stats'] as Map?;
      views.add({
        ...root,
        ...part,
        'mode': 'band-part',
        'total_notes': (stats?['notes'] as num?)?.toInt() ?? 0,
        'pdf_file': part['pdf_file'] ??
            part['output_file']?.toString().replaceFirst(
                  RegExp(r'\.(musicxml|xml)$', caseSensitive: false),
                  '.pdf',
                ),
        'pdf_url': part['pdf_url'],
        'parts': const <dynamic>[],
      });
    }
    return views;
  }

  Future<void> _selectBandView(int index) async {
    final views = _bandViews;
    if (index < 0 || index >= views.length || index == _selectedBandView) {
      return;
    }
    await _audioPlayer?.stop();
    if (!mounted) return;
    setState(() {
      _sheetLoadToken++;
      _selectedBandView = index;
      _activeResult = views[index];
      _musicXmlContent = '';
      _sheetLoadError = null;
      _isLoadingMusicXml = false;
      _isPlaying = false;
      _hasPlayed = false;
      _playController.value = 0;
      _parseApiResult();
      _playController.duration =
          Duration(seconds: _audioDuration.ceil().clamp(1, 600));
    });
    await _loadCachedMusicXmlOrFetch();
  }

  Future<void> _fetchMusicXml() async {
    if (_isLoadingMusicXml) return;
    final loadToken = ++_sheetLoadToken;
    if (mounted) {
      setState(() {
        _isLoadingMusicXml = true;
        _sheetLoadError = null;
      });
    }
    try {
      final results = await Future.wait(
        _musicXmlSourceUrls.map((baseUrl) async {
          try {
            final response = await http
                .get(
                  Uri.parse('$baseUrl/api/sheet/download/$_outputFile'),
                  headers: await _authHeaders(),
                )
                .timeout(const Duration(seconds: 10));
            if (response.statusCode == 200 && response.body.length > 100) {
              return (baseUrl: baseUrl, content: response.body);
            }
          } catch (_) {}
          return null;
        }),
      );
      final matches = results.whereType<({String baseUrl, String content})>();
      if (matches.isEmpty) {
        throw Exception(
            'The saved MusicXML file is not available on the backend.');
      }
      final match = matches.first;
      if (!mounted || loadToken != _sheetLoadToken) return;
      setState(() {
        _musicXmlContent = match.content;
        _sheetServerUrl = match.baseUrl;
        _activeResult = Map<String, dynamic>.from(_activeResult)
          ..['musicxml_content'] = match.content;
      });
      unawaited(GeneratedSheetsStore.instance.cacheMusicXml(
        outputFile: _outputFile,
        content: match.content,
      ));
      if (_audioPlayer != null && _audioAvailable) {
        await _setAudioSourceWithFallback();
      }
    } catch (e) {
      debugPrint('Fetch MusicXML error: $e');
      if (mounted && loadToken == _sheetLoadToken) {
        setState(() => _sheetLoadError = e.toString());
      }
    } finally {
      if (mounted && loadToken == _sheetLoadToken) {
        setState(() => _isLoadingMusicXml = false);
      }
    }
  }

  Future<Map<String, String>> _authHeaders() async {
    final token = await FirebaseAuth.instance.currentUser?.getIdToken();
    return token == null ? const {} : {'Authorization': 'Bearer $token'};
  }

  Future<void> _editNotes() async {
    if (_musicXmlContent.isEmpty) {
      _showPlaybackError(
          'Wait for the sheet to finish loading before editing notes.');
      return;
    }
    final edited =
        await Navigator.of(context).push<EditedMusicSheet>(MaterialPageRoute(
      builder: (_) => MusicNoteEditorPage(
        musicXml: _musicXmlContent,
        osmdScriptUrl:
            '$_sheetServerUrl/assets/web/js/opensheetmusicdisplay.min.js',
        apiBaseUrls: _baseUrls,
      ),
    ));
    if (!mounted || edited == null || edited.musicXml == _musicXmlContent) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Preparing your edited sheet and playback…'),
      duration: Duration(seconds: 2),
    ));
    final rendered = await _renderEditedScore(edited.musicXml);
    if (!mounted) return;
    if (rendered == null || rendered['audio_available'] != true) {
      _showPlaybackError(
          'Playback could not be updated. Your previous saved sheet is unchanged. Please try again.');
      return;
    }
    await _audioPlayer?.stop();
    if (!mounted) return;
    setState(() {
      _musicXmlContent = edited.musicXml;
      _activeResult = Map<String, dynamic>.from(_activeResult)
        ..remove('musicxml_url')
        ..remove('audio_url')
        ..remove('pdf_url')
        ..remove('sheet_image_url')
        ..remove('cached_music_xml_path')
        ..addAll(rendered)
        ..['musicxml_content'] = edited.musicXml
        ..['source_base_url'] = _sheetServerUrl
        ..remove('cached_audio_path');
      _hasPlayed = false;
      _isPlaying = false;
      _parseApiResult();
      _playController.duration =
          Duration(seconds: _audioDuration.ceil().clamp(1, 600));
      _playController.value = 0;
    });
    await GeneratedSheetsStore.instance.cacheMusicXml(
        outputFile: _outputFile, content: edited.musicXml);
    if (!_savedToMySheets) {
      await GeneratedSheetsStore.instance.saveGeneratedSheet(
          instrument: _instrument,
          result: Map<String, dynamic>.from(_activeResult)..['title'] = _sheetTitle);
      if (mounted) setState(() => _savedToMySheets = true);
    }
    await GeneratedSheetsStore.instance.updateSavedResult(
      outputFile: _outputFile,
      result: _activeResult,
      clearCachedAudio: true,
    );
    if (_audioPlayer != null && _audioAvailable) {
      try {
        await _setAudioSourceWithFallback();
      } catch (_) {
        // The next play request will surface a clear playback error if needed.
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Sheet and playback updated from your edited notes.')));
    }
  }

  Future<Map<String, dynamic>?> _renderEditedScore(String musicXml) async {
    for (final baseUrl in _baseUrls) {
      try {
        final response = await http
            .post(
              Uri.parse('$baseUrl/api/sheet/render-edited'),
              headers: {
                'Content-Type': 'application/json',
                ...await _authHeaders(),
              },
              body: jsonEncode({
                'musicxml_content': musicXml,
                'instrument': _instrument,
                'output_file': _outputFile,
              }),
            )
            .timeout(const Duration(minutes: 3));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          final data = jsonDecode(response.body);
          if (data is Map && data['success'] == true) {
            _sheetServerUrl = baseUrl;
            return Map<String, dynamic>.from(data);
          }
        }
      } catch (_) {
        // Try the next configured backend endpoint.
      }
    }
    return null;
  }

  Future<void> _downloadCurrentMusicXml() async {
    if (_musicXmlContent.isEmpty) {
      _showPlaybackError(
          'Wait for the sheet to finish loading before downloading MusicXML.');
      return;
    }
    final name = _outputFile.isEmpty
        ? '${_instrument.isEmpty ? 'music' : _instrument.toLowerCase().replaceAll(' ', '_')}_sheet'
        : _outputFile.replaceFirst(
            RegExp(r'\.(musicxml|xml)$', caseSensitive: false), '');
    try {
      final savedPath = await FileSaver.instance.saveFile(
        name: name,
        bytes: utf8.encode(_musicXmlContent),
        fileExtension: 'musicxml',
        mimeType: MimeType.other,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('MusicXML saved: $savedPath')));
      }
    } catch (error) {
      if (mounted) {
        _showPlaybackError('Could not save MusicXML: $error');
      }
    }
  }

  Future<bool> _saveToMySheets() async {
    if (_savedToMySheets) return true;
    if (_savingToMySheets) return false;
    setState(() => _savingToMySheets = true);
    try {
      // Do not create a My Sheets card that relies on a temporary server file.
      // A finished generation normally hands us the XML inline; this fallback
      // covers a slow handoff and guarantees the local saved copy can open.
      if (_musicXmlContent.length <= 100) {
        await _loadCachedMusicXmlOrFetch();
      }
      if (_musicXmlContent.length <= 100) {
        throw StateError(
            'The finished sheet is not available yet. Please try Save again in a moment.');
      }
      final immediatelyOpenableResult = Map<String, dynamic>.from(_activeResult)
        ..['musicxml_content'] = _musicXmlContent
        ..['title'] = _sheetTitle;
      final saved = await GeneratedSheetsStore.instance.saveGeneratedSheet(
        instrument: _instrument.isEmpty ? widget.instrumentName : _instrument,
        result: immediatelyOpenableResult,
      );
      if (!mounted) return false;
      setState(() {
        _activeResult = Map<String, dynamic>.from(saved);
        _savedToMySheets = true;
        _sheetTitle = _sheetTitle.trim().isEmpty
            ? '${_instrument.isEmpty ? widget.instrumentName : _instrument} sheet'
            : _sheetTitle;
      });
      showSheetNotice(context, 'Saved to My sheets');
      return true;
    } catch (error) {
      if (mounted) _showPlaybackError('Could not save this sheet: $error');
      return false;
    } finally {
      if (mounted) setState(() => _savingToMySheets = false);
    }
  }

  Future<void> _leaveSheet() async {
    if (_leavingSheet) return;
    if (_isFullscreen) {
      setState(() => _isFullscreen = false);
      return;
    }
    _leavingSheet = true;
    try {
      if (!_savedToMySheets) {
        final save = await showModalBottomSheet<bool>(
          context: context,
          useSafeArea: true,
          backgroundColor: Colors.transparent,
          builder: (sheetContext) => Material(
            color: AppPalette.page(sheetContext),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppPalette.border(sheetContext),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                const SizedBox(height: 20),
                const Icon(Icons.library_music_rounded,
                    size: 38, color: brandRed),
                const SizedBox(height: 12),
                Text('Save this sheet?',
                    style: TextStyle(
                        color: AppPalette.text(sheetContext),
                        fontSize: 21,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 7),
                Text('Do you want to save this sheet to your collection?',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: AppPalette.muted(sheetContext), height: 1.35)),
                const SizedBox(height: 22),
                Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(sheetContext, false),
                      child: const Text('No'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: brandRed,
                          foregroundColor: Colors.white),
                      onPressed: () => Navigator.pop(sheetContext, true),
                      child: const Text('Yes, save'),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
        );
        if (save == null || !mounted) return;
        if (save && !await _saveToMySheets()) return;
      }
      if (!mounted) return;
      setState(() => _allowPop = true);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      Navigator.pop(context);
    } finally {
      _leavingSheet = false;
    }
  }

  Future<void> _renameCurrentSheet() async {
    final title = await showSheetNameEditor(context, currentName: _sheetTitle);
    if (title == null || title == _sheetTitle) return;

    if (!_savedToMySheets) {
      await _saveToMySheets();
      if (!mounted || !_savedToMySheets) return;
    }
    final renamed = _outputFile.isNotEmpty &&
        await GeneratedSheetsStore.instance
            .renameByOutputFile(_outputFile, title);
    if (!mounted) return;
    if (!renamed) {
      _showPlaybackError('Could not save the sheet name. Please try again.');
      return;
    }
    setState(() {
      _sheetTitle = title;
      _activeResult['title'] = title;
    });
    showSheetNotice(context, 'Sheet name updated');
  }

  Future<void> _initAudio() async {
    _loadingAudio = true;
    _audioPlayer = AudioPlayer();
    await _audioPlayer!.setVolume(1.0);
    _positionSubscription =
        _audioPlayer!.onPositionChanged.listen(_handleAudioPosition);
    _audioPlayer!.onDurationChanged.listen((duration) {
      if (mounted && duration.inMilliseconds > 0) {
        _playController.duration = duration;
        setState(() {
          _audioDuration = duration.inMilliseconds / 1000;
        });
      }
    });
    _audioPlayer!.onPlayerComplete.listen((_) async {
      if (_isLooping) {
        await _seekToFraction(0, resume: true);
      } else if (mounted) {
        _playController.value = 1;
        setState(() => _isPlaying = false);
      }
    });
    try {
      await _setAudioSourceWithFallback();
    } catch (e) {
      debugPrint('Audio init error: $e');
      if (mounted) {
        setState(() {
          _audioAvailable = false;
        });
      }
    } finally {
      if (mounted) setState(() => _loadingAudio = false);
    }
  }

  @override
  void dispose() {
    GeneratedSheetsStore.instance.removeListener(_refreshSavedTitle);
    _playController.dispose();
    _positionSubscription?.cancel();
    _audioPlayer?.dispose();
    super.dispose();
  }

  void _togglePlay() async {
    await _audioReady;
    if (!mounted) return;
    if (!_audioAvailable || _audioPlayer == null) {
      _showPlaybackError(
          'This sheet has no playable audio file. Generate it again after restarting Python.');
      return;
    }

    if (!_isPlaying) {
      try {
        if (_playController.value >= 0.999) {
          await _seekToFraction(0);
        }
        if (_hasPlayed) {
          await _audioPlayer!.resume();
        } else {
          await _playAudioWithFallback(_currentPlaybackPosition);
          _hasPlayed = true;
        }
      } catch (error) {
        if (mounted) setState(() => _isPlaying = false);
        _hasPlayed = false;
        _showPlaybackError('Unable to play the generated audio. $error');
        return;
      }
      if (mounted) setState(() => _isPlaying = true);
    } else {
      await _audioPlayer!.pause();
      if (mounted) setState(() => _isPlaying = false);
    }
  }

  Duration get _currentPlaybackPosition => Duration(
      milliseconds: (_playController.value * _audioDuration * 1000).round());

  Future<void> _handleAudioPosition(Duration position) async {
    if (!mounted || _isScrubbing || _isSheetDragging || _audioDuration <= 0) {
      return;
    }
    if (!_seekGuard.accept(position, DateTime.now(), dragging: false)) return;
    final fraction =
        (position.inMilliseconds / (_audioDuration * 1000)).clamp(0.0, 1.0);
    if (mounted) {
      setState(() => _playController.value = fraction);
    }
    await _syncSheetCursor(position);
  }

  Future<void> _syncSheetCursor(Duration position) async {
    if (_playbackEvents.isEmpty) return;
    final seconds = position.inMilliseconds / 1000;
    await _sheetController?.evaluateJavascript(
      source: 'window.syncScoreCursor && window.syncScoreCursor($seconds);',
    );
  }

  Future<void> _seekToFraction(double fraction, {bool resume = false}) async {
    final safeFraction = fraction.clamp(0.0, 1.0);
    final target = Duration(
      milliseconds: (safeFraction * _audioDuration * 1000).round(),
    );
    _playController.value = safeFraction;
    _seekGuard.seek(target, DateTime.now());
    try {
      await _audioPlayer?.seek(target);
    } catch (_) {
      _seekGuard.clear();
      rethrow;
    }
    await _syncSheetCursor(target);
    if (resume && _audioPlayer != null) {
      if (_hasPlayed) {
        await _audioPlayer!.resume();
      } else {
        await _playAudioWithFallback(target);
        _hasPlayed = true;
      }
      if (mounted) setState(() => _isPlaying = true);
    }
  }

  Future<void> _startScrub() async {
    _isScrubbing = true;
    _resumeAfterScrub = _isPlaying;
    if (_isPlaying) {
      await _audioPlayer?.pause();
      if (mounted) setState(() => _isPlaying = false);
    }
  }

  Future<void> _finishScrub(double value) async {
    try {
      await _seekToFraction(value, resume: _resumeAfterScrub);
    } finally {
      _isScrubbing = false;
      _resumeAfterScrub = false;
    }
  }

  void _previewSheetSeek(double fraction) {
    final safeFraction = fraction.clamp(0.0, 1.0);
    setState(() => _playController.value = safeFraction);
    _syncSheetCursor(Duration(
      milliseconds: (safeFraction * _audioDuration * 1000).round(),
    ));
  }

  Future<void> _beginSheetDrag(double fraction) async {
    if (!_audioAvailable || _isSheetDragging) return;
    _isSheetDragging = true;
    _resumeAfterSheetDrag = _isPlaying;
    _previewSheetSeek(fraction);
    if (_isPlaying) {
      await _audioPlayer?.pause();
      if (mounted) setState(() => _isPlaying = false);
    }
  }

  Future<void> _endSheetDrag(double fraction) async {
    if (!_audioAvailable) return;
    try {
      await _seekToFraction(fraction, resume: _resumeAfterSheetDrag);
    } finally {
      _isSheetDragging = false;
      _resumeAfterSheetDrag = false;
    }
  }

  String _formatPlaybackTime(double fraction) {
    final totalSeconds = (_audioDuration * fraction).round();
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  void _toggleLoop() => setState(() => _isLooping = !_isLooping);
  void _toggleFullscreen() => setState(() => _isFullscreen = !_isFullscreen);

  void _showPlaybackError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _downloadFile(String filename) async {
    if (filename.isEmpty) return;
    try {
      Object? lastError;
      final permanentUrl = _permanentUrlFor(filename);
      final urls = permanentUrl == null
          ? _audioBaseUrls()
              .map((baseUrl) => _downloadUrlFrom(baseUrl, filename))
          : [permanentUrl];
      for (final candidate in urls) {
        final url = Uri.parse(candidate);
        final response = await http
            .get(url,
                headers: permanentUrl == null ? await _authHeaders() : null)
            .timeout(const Duration(seconds: 180));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          if (filename.toLowerCase().endsWith('.pdf')) {
            if (!mounted) return;
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => PdfPreviewPage(
                  bytes: response.bodyBytes,
                  filename: filename,
                ),
              ),
            );
          } else {
            final extension =
                filename.contains('.') ? filename.split('.').last : 'musicxml';
            final savedPath = await FileSaver.instance.saveFile(
              name: filename.replaceFirst(RegExp(r'\.[^.]+$'), ''),
              bytes: response.bodyBytes,
              fileExtension: extension,
              mimeType: MimeType.other,
            );
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('File saved: $savedPath')),
              );
            }
          }
          return;
        }
        lastError = response.body;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Download failed: $lastError')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Download failed: $error')),
      );
    }
  }

  String _downloadUrl(String filename, [int baseUrlIndex = 0]) {
    final permanentUrl = _permanentUrlFor(filename);
    if (permanentUrl != null) return permanentUrl;
    return _downloadUrlFrom(_baseUrls[baseUrlIndex], filename);
  }

  String? _permanentUrlFor(String filename) {
    final data = _activeResult;
    if (data.isEmpty) return null;
    String? usableUrl(Object? value) {
      final url = value?.toString().trim() ?? '';
      return url.isEmpty ? null : url;
    }

    if (filename == _outputFile) return usableUrl(data['musicxml_url']);
    if (filename == _pdfFile) return usableUrl(data['pdf_url']);
    if (filename == _audioFile) return usableUrl(data['audio_url']);
    if (filename == _sheetImageFile) {
      return usableUrl(data['sheet_image_url']);
    }
    return null;
  }

  String _downloadUrlFrom(String baseUrl, String filename) {
    return '$baseUrl/api/sheet/download/$filename';
  }

  List<String> _audioBaseUrls() {
    return <String>{_sheetServerUrl, ..._baseUrls}.toList();
  }

  Future<void> _setAudioSourceWithFallback() async {
    if (_sourcePreparation != null) await _sourcePreparation;
    final preparation = _prepareAudioSource();
    _sourcePreparation = preparation;
    try {
      await preparation;
    } finally {
      if (identical(_sourcePreparation, preparation)) _sourcePreparation = null;
    }
  }

  Future<void> _prepareAudioSource() async {
    final identity = '$_outputFile/$_audioFile';
    // Score loading also calls this method. Do not reset an already prepared
    // player to zero just because the sheet finished loading.
    if (_preparedAudioIdentity == identity) return;
    Object? lastError;

    for (final baseUrl in _audioBaseUrls()) {
      try {
        await _audioPlayer!.setSource(await _audioSource(baseUrl));
        _preparedAudioIdentity = identity;
        return;
      } catch (e) {
        lastError = e;
      }
    }

    throw lastError ?? Exception('Unable to load audio');
  }

  Future<void> _playAudioWithFallback([Duration? position]) async {
    if (_preparedAudioIdentity == '$_outputFile/$_audioFile') {
      if (position != null) await _audioPlayer!.seek(position);
      await _audioPlayer!.resume();
      return;
    }
    Object? lastError;

    for (final baseUrl in _audioBaseUrls()) {
      try {
        await _audioPlayer!
            .play(await _audioSource(baseUrl), position: position);
        return;
      } catch (e) {
        lastError = e;
      }
    }

    throw lastError ?? Exception('Unable to play audio');
  }

  Future<Source> _audioSource(String baseUrl) async {
    final cachedAudio =
        await GeneratedSheetsStore.instance.readCachedAudioPath(_activeResult);
    if (cachedAudio != null) {
      return DeviceFileSource(cachedAudio);
    }
    final permanentUrl = _permanentUrlFor(_audioFile);
    if (permanentUrl != null && permanentUrl.isNotEmpty) {
      // Fully prepare audio on the device for responsive seek/playback rather
      // than starting a second network stream while caching in parallel.
      final response = await http
          .get(Uri.parse(permanentUrl))
          .timeout(const Duration(minutes: 3));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('Could not load saved audio (${response.statusCode}).');
      }
      await GeneratedSheetsStore.instance.cacheAudio(
          outputFile: _outputFile,
          audioFile: _audioFile,
          bytes: response.bodyBytes);
      final local = await GeneratedSheetsStore.instance
          .readCachedAudioPath(_activeResult);
      return local != null
          ? DeviceFileSource(local)
          : BytesSource(response.bodyBytes);
    }
    final response = await http
        .get(
          Uri.parse(_downloadUrlFrom(baseUrl, _audioFile)),
          headers: await _authHeaders(),
        )
        .timeout(const Duration(minutes: 3));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
          'Could not load generated audio (${response.statusCode}).');
    }
    await GeneratedSheetsStore.instance.cacheAudio(
      outputFile: _outputFile,
      audioFile: _audioFile,
      bytes: response.bodyBytes,
    );
    return BytesSource(response.bodyBytes);
  }

  @override
  Widget build(BuildContext context) {
    final backgroundColor = AppPalette.page(context);
    final scoreSurface =
        AppPalette.isDark(context) ? Colors.black : AppPalette.surface(context);
    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallScreen = screenWidth < 360;

    final sheetContent = Column(
      children: [
        Expanded(
          child: _musicXmlContent.isEmpty && !_sheetImageAvailable
              ? (_isLoadingMusicXml
                  ? const Center(child: CircularProgressIndicator())
                  : _buildEmptyState())
              : _buildScrollableSheet(isSmallScreen),
        ),
        _buildPlayerBar(isSmallScreen),
      ],
    );

    if (_isFullscreen) {
      return PopScope(
        canPop: _allowPop,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_leaveSheet());
        },
        child: Scaffold(
          backgroundColor: backgroundColor,
          body: SafeArea(
            child: Container(
              margin: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: scoreSurface,
                borderRadius: BorderRadius.circular(16),
              ),
              child: sheetContent,
            ),
          ),
        ),
      );
    }

    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leaveSheet());
      },
      child: Scaffold(
        backgroundColor: backgroundColor,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: isSmallScreen ? 16.0 : 20.0,
                  vertical: isSmallScreen ? 10.0 : 14.0,
                ),
                child: Row(
                  children: [
                    AppBackButton(
                      size: isSmallScreen ? 20 : 24,
                      onPressed: _leaveSheet,
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _savingToMySheets || _savedToMySheets
                          ? null
                          : () => _saveToMySheets(),
                      style: TextButton.styleFrom(foregroundColor: brandRed),
                      icon: _savingToMySheets
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              _savedToMySheets
                                  ? Icons.bookmark_added_rounded
                                  : Icons.bookmark_add_outlined,
                              size: 18),
                      label: Text(_savedToMySheets ? 'In Sheets' : 'To Sheets',
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                    TextButton.icon(
                      onPressed: _musicXmlContent.isEmpty ? null : _editNotes,
                      icon: const Icon(Icons.edit_note_rounded, size: 20),
                      label: isSmallScreen
                          ? const SizedBox.shrink()
                          : const Text('Edit notes'),
                      style: TextButton.styleFrom(
                        foregroundColor: brandRed,
                        minimumSize: isSmallScreen ? const Size(42, 42) : null,
                        padding: isSmallScreen
                            ? const EdgeInsets.symmetric(horizontal: 9)
                            : null,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Download MusicXML',
                      onPressed: _musicXmlContent.isEmpty
                          ? null
                          : _downloadCurrentMusicXml,
                      color: brandRed,
                      icon: const Icon(Icons.file_download_outlined),
                    ),
                  ],
                ),
              ),
              if (_bandViews.isNotEmpty)
                SizedBox(
                  height: 43,
                  child: ListView.separated(
                    padding: EdgeInsets.symmetric(
                        horizontal: isSmallScreen ? 12 : 16),
                    scrollDirection: Axis.horizontal,
                    itemCount: _bandViews.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 7),
                    itemBuilder: (context, index) {
                      final view = _bandViews[index];
                      final label = index == 0
                          ? 'Full Band'
                          : '${view['display_name'] ?? view['instrument']} - ${_roleLabel(view['role'])}';
                      return ChoiceChip(
                        label: Text(label),
                        selected: _selectedBandView == index,
                        onSelected: (_) => _selectBandView(index),
                        selectedColor: brandRed,
                        labelStyle: TextStyle(
                          color: _selectedBandView == index
                              ? Colors.white
                              : AppPalette.text(context),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      );
                    },
                  ),
                ),
              if (_bandViews.isNotEmpty) const SizedBox(height: 8),
              if (_sourceStrategy.isNotEmpty && _selectedBandView > 0)
                Container(
                  width: double.infinity,
                  margin: EdgeInsets.fromLTRB(
                      isSmallScreen ? 12 : 16, 0, isSmallScreen ? 12 : 16, 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppPalette.surface(context),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppPalette.border(context)),
                  ),
                  child: Text(
                    _sourceStrategy == 'matched_instrument'
                        ? 'Detected instrument source: ${_sourceStem.replaceAll('_', ' ')}'
                        : _sourceStrategy == 'uncertain'
                            ? 'Low-confidence part — review or leave silent where it does not match the recording.'
                            : 'Arranged from the ${_sourceStem.replaceAll('_', ' ')} source for this role.',
                    style: TextStyle(
                      fontFamily: 'Instrument Sans',
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      color: AppPalette.muted(context),
                    ),
                  ),
                ),
              if (_transcriptionQuality == 'review')
                Container(
                  width: double.infinity,
                  margin: EdgeInsets.fromLTRB(
                      isSmallScreen ? 12 : 16, 0, isSmallScreen ? 12 : 16, 10),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: brandRed.withValues(alpha: .08),
                    border: Border.all(color: brandRed.withValues(alpha: .45)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _transcriptionWarnings.isNotEmpty
                        ? _transcriptionWarnings.first
                        : 'Some passages may need review before performing.',
                    style: TextStyle(
                      fontFamily: 'Instrument Sans',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppPalette.text(context),
                    ),
                  ),
                ),
              Expanded(
                child: Container(
                  margin:
                      EdgeInsets.symmetric(horizontal: isSmallScreen ? 12 : 16),
                  decoration: BoxDecoration(
                    color: scoreSurface,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                            alpha: AppPalette.isDark(context) ? .28 : .06),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: sheetContent,
                ),
              ),
              _buildBottomInfo(isSmallScreen),
            ],
          ),
        ),
      ),
    );
  }

  String _roleLabel(Object? role) => switch (role?.toString()) {
        'melody' || 'lead' => 'Lead',
        'harmony' || 'chords' => 'Harmony',
        'bass' => 'Bass',
        'drums' => 'Rhythm',
        final value => value ?? '',
      };

  Widget _buildEmptyState() {
    final hasOutput = _outputFile.isNotEmpty;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.music_off, size: 48, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text(
            hasOutput ? 'Sheet music unavailable' : 'No notes to display',
            style: TextStyle(
              fontFamily: 'Instrument Sans',
              fontSize: 16,
              color: Colors.grey.shade500,
            ),
          ),
          if (_totalNotes > 0) ...[
            const SizedBox(height: 8),
            Text(
              '$_totalNotes notes processed.',
              style: TextStyle(
                fontFamily: 'Instrument Sans',
                fontSize: 13,
                color: Colors.grey.shade400,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          if (_sheetLoadError != null) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Text(
                'Start the Node and Python backends, then try again.',
                style: TextStyle(
                  fontFamily: 'Instrument Sans',
                  fontSize: 12,
                  color: Colors.grey.shade400,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
          if (hasOutput) ...[
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _loadCachedMusicXmlOrFetch,
              icon: const Icon(Icons.refresh, color: Colors.white, size: 18),
              label: const Text(
                'Retry',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: brandRed,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInfoRow(bool isSmallScreen) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '$_totalNotes notes',
              style: TextStyle(
                fontFamily: 'Instrument Sans',
                fontSize: 12,
                color: AppPalette.text(context),
              ),
            ),
            Text(
              _instrument,
              style: TextStyle(
                fontFamily: 'Instrument Sans',
                fontSize: 13,
                color: AppPalette.muted(context),
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Key: $_keySignature | Time: $_timeSignature | Tempo: $_tempo BPM',
          style: TextStyle(
            fontFamily: 'Instrument Sans',
            fontSize: 12,
            color: AppPalette.muted(context),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildPlayerBar(bool isSmallScreen) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: brandRed,
        borderRadius: BorderRadius.circular(30),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.music_note_rounded,
                  color: Colors.white, size: 16),
              const SizedBox(width: 5),
              Text(
                'Music ${widget.sheetNumber}',
                style: TextStyle(
                  fontFamily: 'Instrument Sans',
                  color: Colors.white,
                  fontSize: isSmallScreen ? 12 : 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              Text(
                _instrument,
                style: TextStyle(
                  fontFamily: 'Instrument Sans',
                  color: Colors.white.withValues(alpha: 0.72),
                  fontSize: isSmallScreen ? 11 : 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                _formatPlaybackTime(_playController.value),
                style: TextStyle(
                  fontFamily: 'Instrument Sans',
                  color: Colors.white.withValues(alpha: 0.8),
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.32),
                    thumbColor: Colors.white,
                    overlayColor: Colors.white.withValues(alpha: 0.16),
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 14),
                  ),
                  child: Slider(
                    value: _playController.value.clamp(0.0, 1.0),
                    onChangeStart: _audioAvailable
                        ? (_) {
                            _startScrub();
                          }
                        : null,
                    onChanged: _audioAvailable
                        ? (value) {
                            setState(() => _playController.value = value);
                            _syncSheetCursor(Duration(
                              milliseconds:
                                  (value * _audioDuration * 1000).round(),
                            ));
                          }
                        : null,
                    onChangeEnd: _audioAvailable
                        ? (value) {
                            _finishScrub(value);
                          }
                        : null,
                  ),
                ),
              ),
              Text(
                _formatPlaybackTime(1),
                style: TextStyle(
                  fontFamily: 'Instrument Sans',
                  color: Colors.white.withValues(alpha: 0.8),
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              GestureDetector(
                onTap: _toggleLoop,
                child: Icon(
                  Icons.repeat,
                  color: _isLooping
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.4),
                  size: isSmallScreen ? 20 : 22,
                ),
              ),
              IconButton(
                tooltip: 'Restart',
                onPressed: _audioAvailable
                    ? () => _seekToFraction(0, resume: _isPlaying)
                    : null,
                icon: Icon(Icons.skip_previous,
                    color: Colors.white, size: isSmallScreen ? 22 : 26),
              ),
              GestureDetector(
                onTap: _loadingAudio ? null : _togglePlay,
                child: Container(
                  width: isSmallScreen ? 44 : 50,
                  height: isSmallScreen ? 44 : 50,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  child: _loadingAudio
                      ? const Padding(
                          padding: EdgeInsets.all(13),
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: brandRed),
                        )
                      : Icon(
                          _isPlaying ? Icons.pause : Icons.play_arrow,
                          color: brandRed,
                          size: 30,
                        ),
                ),
              ),
              Icon(Icons.music_note,
                  color: Colors.white, size: isSmallScreen ? 20 : 22),
              GestureDetector(
                onTap: _toggleFullscreen,
                child: Icon(
                  _isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                  color: Colors.white,
                  size: isSmallScreen ? 20 : 22,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBottomInfo(bool isSmallScreen) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        isSmallScreen ? 20 : 28,
        20,
        isSmallScreen ? 20 : 28,
        isSmallScreen ? 16 : 20,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _sheetTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Instrument Sans',
                    fontSize: isSmallScreen ? 21 : 24,
                    fontWeight: FontWeight.w800,
                    color: AppPalette.text(context),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Edit sheet name',
                onPressed: _renameCurrentSheet,
                color: brandRed,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.edit_rounded, size: 19),
              ),
              const SizedBox(width: 4),
              Text(
                _instrument,
                style: TextStyle(
                  fontFamily: 'Instrument Sans',
                  fontSize: isSmallScreen ? 13 : 14,
                  fontWeight: FontWeight.w600,
                  color: brandRed,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              if (_pdfAvailable)
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _downloadFile(_pdfFile),
                    icon: const Icon(Icons.download, color: brandRed, size: 18),
                    label: const Text(
                      'Download PDF',
                      style: TextStyle(
                        color: brandRed,
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: brandRed, width: 1.5),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              if (_pdfAvailable) const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => _downloadFile(_outputFile),
                  icon:
                      const Icon(Icons.download, color: Colors.white, size: 18),
                  label: Text(
                    _pdfAvailable ? 'Download XML' : 'Download MusicXML',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: brandRed,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildScrollableSheet(bool isSmallScreen) {
    if (_musicXmlContent.isNotEmpty) {
      if (_scoreRendererError != null) {
        return Center(child: Text(_scoreRendererError!));
      }
      if (_scoreRendererUrl == null) {
        return const Center(child: CircularProgressIndicator());
      }
      final escapedXml = jsonEncode(_musicXmlContent);
      final escapedPlaybackEvents = jsonEncode(_playbackEvents);
      final darkScore = AppPalette.isDark(context);
      final scoreBackground = darkScore ? '#000000' : '#FFFFFF';
      final notationColor = darkScore ? '#FFFFFF' : '#000000';
      final isFullBandView = _bandViews.isNotEmpty && _selectedBandView == 0;
      final scoreZoom = isFullBandView
          ? (isSmallScreen ? 0.38 : 0.48)
          : (isSmallScreen ? 0.46 : 0.60);
      final html = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=3.0, user-scalable=yes" />
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    html, body { width: 100%; background: $scoreBackground; color: $notationColor; overflow: auto; -webkit-overflow-scrolling: touch; }
    #osmdContainer { width: 100%; ${isFullBandView ? 'min-width: 960px;' : ''} min-height: 100%; padding: ${isFullBandView ? '12px' : '2px'}; position: relative; background: $scoreBackground; }
    #osmdContainer svg { background: $scoreBackground !important; }
    #bandInstrumentRoster { display: none; padding: 8px 10px 4px; gap: 6px; flex-wrap: wrap; font-family: sans-serif; }
    #bandInstrumentRoster span { border: 1px solid #888; border-radius: 999px; padding: 3px 8px; font-size: 11px; color: $notationColor; }
    /* OSMD's normal cursor is very faint on a phone screen. Keep it as a
       crisp, high-contrast red playhead across the active staff. */
    #osmdCursor, .osmd-cursor, [id*="cursor" i] {
      stroke: #d30a02 !important;
      stroke-width: 3px !important;
      fill: #d30a02 !important;
      fill-opacity: 0.18 !important;
      opacity: 1 !important;
    }
    #smoothScorePlayhead {
      position: absolute;
      top: 0;
      left: 0;
      z-index: 5;
      width: 3px;
      min-height: 48px;
      border-radius: 3px;
      background: #d30a02;
      pointer-events: none;
      opacity: 0;
      transition: transform 160ms linear, height 160ms linear, opacity 120ms ease;
    }
    #loading { display: flex; align-items: center; justify-content: center; height: 200px; font-family: sans-serif; color: #888; }
    #error { display: none; padding: 16px; font-family: sans-serif; color: #c00; background: #fee; margin: 8px; border-radius: 8px; }
  </style>
</head>
<body>
  <div id="loading">Loading sheet music...</div>
  <div id="error"></div>
  <div id="bandInstrumentRoster"></div>
  <div id="osmdContainer"></div>
  <script>
    window.osmd = null;
    var musicXmlData = $escapedXml;
    var playbackEvents = $escapedPlaybackEvents;
    var playbackTempo = $_playbackTempo;
    var playbackDuration = $_audioDuration;
    var displayedEventIndex = 0;
    var cursorPositions = [];
    var lastRenderedRow = null;
    var draggingPlayhead = false;
    var lastDragFraction = 0;
    var lastAutoScrollAt = 0;
    var currentPlaybackSeconds = ${_currentPlaybackPosition.inMilliseconds / 1000};

    function loadScript(source) {
      return new Promise(function(resolve, reject) {
        var script = document.createElement('script');
        script.src = source;
        script.onload = resolve;
        script.onerror = function() { reject(new Error('Unable to load ' + source)); };
        document.head.appendChild(script);
      });
    }

    async function ensureOsmd() {
      if (window.opensheetmusicdisplay) return;
      // Shipped inside the app: saved scores never wait for Railway or a CDN.
      await loadScript(${jsonEncode(_scoreRendererUrl)});
      if (!window.opensheetmusicdisplay) {
        throw new Error('OpenSheetMusicDisplay did not load.');
      }
    }

    window.resetScoreCursor = function() {
      if (!window.osmd || !window.osmd.cursor) return;
      window.osmd.cursor.reset();
      window.osmd.cursor.show();
      displayedEventIndex = 0;
    };

    function cursorElement() {
      return document.querySelector('#osmdCursor') ||
        document.querySelector('.osmd-cursor') ||
        document.querySelector('[id*="cursor" i]') ||
        document.querySelector('[class*="cursor" i]');
    }

    function eventTime(index) {
      var event = playbackEvents[index] || {};
      return event.time !== undefined
        ? Number(event.time)
        : Number(event.offset || 0) * (60 / playbackTempo);
    }

    function buildCursorPositions() {
      if (!window.osmd || !window.osmd.cursor || !playbackEvents.length) return;
      ensurePlayhead();
      cursorPositions = [];
      window.osmd.cursor.reset();
      window.osmd.cursor.show();
      var container = document.getElementById('osmdContainer');
      var scorePositions = [];
      for (var step = 0; step < 10000; step++) {
        var iterator = window.osmd.cursor.iterator || window.osmd.cursor.Iterator;
        if (iterator && (iterator.endReached || iterator.EndReached)) break;
        var cursor = cursorElement();
        if (cursor) {
          var rect = cursor.getBoundingClientRect();
          var parentRect = container.getBoundingClientRect();
          var stamp = iterator &&
            (iterator.currentTimeStamp || iterator.CurrentTimeStamp);
          var scoreOffset = stamp &&
            Number(stamp.realValue !== undefined ? stamp.realValue : stamp.RealValue) * 4;
          if (rect.width || rect.height) {
          scorePositions.push({
            scoreOffset: Number.isFinite(scoreOffset) ? scoreOffset : null,
            x: rect.left - parentRect.left + rect.width / 2,
            y: rect.top - parentRect.top,
            height: Math.max(48, rect.height),
          });
          }
        }
        window.osmd.cursor.next();
      }
      // Group the score cursor stops by engraved staff row. A new row must
      // begin at its own leftmost music position, not animate from the end of
      // the previous row or inherit its horizontal position.
      var scoreRows = [];
      scorePositions.forEach(function(point) {
        var rowIndex = scoreRows.findIndex(function(row) {
          return Math.abs(row.y - point.y) < 18;
        });
        if (rowIndex < 0) {
          rowIndex = scoreRows.length;
          scoreRows.push({y: point.y, startX: point.x, endX: point.x});
        } else {
          scoreRows[rowIndex].startX = Math.min(scoreRows[rowIndex].startX, point.x);
          scoreRows[rowIndex].endX = Math.max(scoreRows[rowIndex].endX, point.x);
        }
        point.rowIndex = rowIndex;
      });
      var uniqueAttackIndex = -1;
      for (var index = 0; index < playbackEvents.length; index++) {
        var event = playbackEvents[index] || {};
        if (index === 0 || Math.abs(eventTime(index) - eventTime(index - 1)) >= 0.005) {
          uniqueAttackIndex++;
        }
        var scoreOffset = event.score_offset !== undefined
          ? Number(event.score_offset)
          : event.offset !== undefined ? Number(event.offset)
          : Number(event.time) * playbackTempo / 60;
        var nearest = scorePositions[Math.min(uniqueAttackIndex, scorePositions.length - 1)];
        if (Number.isFinite(scoreOffset)) {
          var distance = Infinity;
          for (var point of scorePositions) {
            if (point.scoreOffset === null) continue;
            var candidateDistance = Math.abs(point.scoreOffset - scoreOffset);
            if (candidateDistance < distance) {
              nearest = point;
              distance = candidateDistance;
            }
          }
        } else if (index > 0 &&
            Math.abs(eventTime(index) - eventTime(index - 1)) < 0.005) {
          nearest = cursorPositions[cursorPositions.length - 1];
        }
        if (nearest) {
          var row = scoreRows[nearest.rowIndex];
          cursorPositions.push(Object.assign({}, nearest, {
            time: eventTime(index),
            rowStartX: row.startX,
            rowEndX: row.endX,
          }));
        }
      }
      var firstTimeByRow = {};
      cursorPositions.forEach(function(point) {
        if (firstTimeByRow[point.rowIndex] === undefined) {
          firstTimeByRow[point.rowIndex] = point.time;
        }
        point.firstInRow = Math.abs(point.time - firstTimeByRow[point.rowIndex]) < 0.005;
      });
      lastRenderedRow = null;
      window.osmd.cursor.reset();
      window.osmd.cursor.hide();
      displayedEventIndex = 0;
      if (!cursorPositions.length) {
        window.osmd.cursor.show();
        return;
      }
      window.syncScoreCursor(currentPlaybackSeconds);
    }

    function ensurePlayhead() {
      var playhead = document.getElementById('smoothScorePlayhead');
      if (playhead) return playhead;
      playhead = document.createElement('div');
      playhead.id = 'smoothScorePlayhead';
      document.getElementById('osmdContainer').appendChild(playhead);
      return playhead;
    }

    function nearestCursorFraction(clientX, clientY) {
      if (!cursorPositions.length || playbackDuration <= 0) return null;
      var nearest = cursorPositions[0];
      var nearestDistance = Infinity;
      var containerRect = document.getElementById('osmdContainer').getBoundingClientRect();
      for (var index = 0; index < cursorPositions.length; index++) {
        var point = cursorPositions[index];
        var distance = Math.abs(containerRect.left + point.x - clientX) +
          Math.abs(containerRect.top + point.y + point.height / 2 - clientY) * 2.2;
        if (distance < nearestDistance) {
          nearest = point;
          nearestDistance = distance;
        }
      }
      return Math.max(0, Math.min(1, nearest.time / playbackDuration));
    }

    function activeCursorPosition() {
      if (!cursorPositions.length) return null;
      return cursorPositions[Math.max(0, Math.min(cursorPositions.length - 1, displayedEventIndex - 1))];
    }

    window.syncScoreCursor = function(seconds) {
      currentPlaybackSeconds = Math.max(0, Number(seconds) || 0);
      if (!cursorPositions.length) return;
      var activeIndex = 0;
      while (activeIndex + 1 < cursorPositions.length &&
          cursorPositions[activeIndex + 1].time <= currentPlaybackSeconds + 0.025) {
        activeIndex++;
      }
      displayedEventIndex = activeIndex + 1;
      var active = cursorPositions[activeIndex];
      var following = cursorPositions[activeIndex + 1];
      var x = active.x;
      var sameRow = following && following.rowIndex === active.rowIndex;
      if (sameRow && following.time > active.time) {
        var progress = Math.max(0, Math.min(1,
          (currentPlaybackSeconds - active.time) / (following.time - active.time)));
        if (active.firstInRow && active.rowStartX < active.x - 1) {
          // On a fresh row, enter from the first music position before
          // continuing through the notes in that row.
          var entry = Math.min(0.25, 0.12 / (following.time - active.time));
          x = progress < entry
            ? active.rowStartX + (active.x - active.rowStartX) * progress / entry
            : active.x + (following.x - active.x) * (progress - entry) / (1 - entry);
        } else {
          x += (following.x - active.x) * progress;
        }
      } else if (following && following.time > active.time) {
        // Finish the current staff row during its final interval, then reset
        // directly to the left edge of the next row at its first attack.
        var rowProgress = Math.max(0, Math.min(1,
          (currentPlaybackSeconds - active.time) / (following.time - active.time)));
        x += (active.rowEndX - active.x) * rowProgress;
      } else if (active.firstInRow) {
        x = active.rowStartX;
      }
      var playhead = ensurePlayhead();
      playhead.style.height = active.height + 'px';
      // Never tween diagonally across two staff rows. Normal same-row updates
      // retain the short linear transition between player position callbacks.
      playhead.style.transition = lastRenderedRow !== active.rowIndex
        ? 'none'
        : 'transform 160ms linear, height 160ms linear, opacity 120ms ease';
      playhead.style.transform = 'translate3d(' + x + 'px,' + active.y + 'px,0)';
      playhead.style.opacity = '1';
      lastRenderedRow = active.rowIndex;
      var viewRect = playhead.getBoundingClientRect();
      if ((viewRect.top < window.innerHeight * 0.12 ||
           viewRect.bottom > window.innerHeight * 0.88) &&
          Date.now() - lastAutoScrollAt > 750) {
        playhead.scrollIntoView({block: 'center', behavior: 'smooth'});
        lastAutoScrollAt = Date.now();
      }
    };

    async function renderOSMD(data) {
      var loadingEl = document.getElementById('loading');
      var errorEl = document.getElementById('error');
      var containerEl = document.getElementById('osmdContainer');
      loadingEl.style.display = 'flex';
      errorEl.style.display = 'none';
      containerEl.innerHTML = '';
      try {
        await ensureOsmd();
        if (!window.osmd) {
          window.osmd = new opensheetmusicdisplay.OpenSheetMusicDisplay(containerEl, {
            autoResize: true,
            backend: 'svg',
            drawTitle: ${isFullBandView ? 'true' : 'false'},
            drawSubtitle: false,
            drawComposer: false,
            drawCredits: false,
            drawPartNames: ${isFullBandView ? 'true' : 'false'},
            drawPartAbbreviations: ${isFullBandView ? 'true' : 'false'},
            defaultColorMusic: '$notationColor',
            defaultColorLabel: '$notationColor',
            defaultColorTitle: '$notationColor',
            // Use a real portrait score page so the staff spacing and line
            // breaks match conventional engraved sheet music.
            pageFormat: '${isFullBandView ? 'Endless' : 'A4_P'}',
          });
        }
        await window.osmd.load(data);
        var fullBandScore = ${isFullBandView ? 'true' : 'false'};
        if (window.osmd.EngravingRules) {
          window.osmd.EngravingRules.RenderPartNames = fullBandScore;
          window.osmd.EngravingRules.RenderPartAbbreviations = fullBandScore;
          if (fullBandScore) {
            // Leave room for ledger lines, ties and tall rhythmic groups.
            // These are engraving distances, not a CSS stretch of the score.
            window.osmd.EngravingRules.BetweenStaffDistance = 8;
            window.osmd.EngravingRules.MinSkyBottomDistBetweenStaves = 3;
            window.osmd.EngravingRules.MinimumDistanceBetweenSystems = 12;
            window.osmd.EngravingRules.MinSkyBottomDistBetweenSystems = 8;
          }
        }
        if (window.osmd.DrawingParameters) {
          window.osmd.DrawingParameters.DrawPartNames = fullBandScore;
        }
        // A compact page view keeps the complete grand-staff system visible
        // on a phone while preserving the airy layout of a printed score.
        // Use a wide conductor canvas with compact notation and horizontal
        // scrolling on phones. Native SVG coordinates preserve cursor alignment.
        window.osmd.zoom = fullBandScore
          ? 0.48
          : $scoreZoom;
        window.osmd.render();
        ensurePlayhead();
        if (fullBandScore) {
          var roster = document.getElementById('bandInstrumentRoster');
          var parsedXml = new DOMParser().parseFromString(data, 'application/xml');
          var names = Array.from(parsedXml.querySelectorAll('score-part > part-name'))
            .map(function(node) { return (node.textContent || '').trim(); })
            .filter(function(name) { return name.length > 0; });
          roster.innerHTML = names.map(function(name) {
            return '<span>' + name.replace(/&/g, '&amp;').replace(/</g, '&lt;') + '</span>';
          }).join('');
          roster.style.display = names.length ? 'flex' : 'none';
        }
        // OSMD assigns colours to some SVG primitives after its configured
        // default colour is applied. Force every notation primitive to the
        // active score ink colour, without touching the red playback cursor.
        if (${darkScore ? 'true' : 'false'}) {
          containerEl.querySelectorAll('path, line, polyline, polygon, rect, circle, ellipse, text, tspan').forEach(function(element) {
            var id = (element.id || '').toLowerCase();
            var className = (element.getAttribute('class') || '').toLowerCase();
            if (id.indexOf('cursor') !== -1 || className.indexOf('cursor') !== -1) return;
            element.style.setProperty('stroke', '#ffffff', 'important');
            element.style.setProperty('fill', '#ffffff', 'important');
          });
        }
        window.osmd.cursor.hide();
        setTimeout(buildCursorPositions, 50);
        loadingEl.style.display = 'none';
      } catch (err) {
        loadingEl.style.display = 'none';
        errorEl.style.display = 'block';
        errorEl.textContent = 'Error: ' + err.message;
      }
    }

    var container = document.getElementById('osmdContainer');
    container.addEventListener('pointerdown', function(event) {
      var active = activeCursorPosition();
      // Let normal scrolling and pinch zoom work everywhere except close to
      // the red playhead itself, which acts as the seek handle.
      if (!active || Math.abs(event.clientX -
          (container.getBoundingClientRect().left + active.x)) > 28) return;
      var fraction = nearestCursorFraction(event.clientX, event.clientY);
      if (fraction === null) return;
      draggingPlayhead = true;
      lastDragFraction = fraction;
      container.setPointerCapture(event.pointerId);
      event.preventDefault();
      window.flutter_inappwebview.callHandler('sheetPlayheadStart', fraction);
    });
    container.addEventListener('pointermove', function(event) {
      if (!draggingPlayhead) return;
      var fraction = nearestCursorFraction(event.clientX, event.clientY);
      if (fraction === null) return;
      event.preventDefault();
      lastDragFraction = fraction;
      window.flutter_inappwebview.callHandler('sheetPlayheadPreview', fraction);
    });
    container.addEventListener('pointerup', function(event) {
      if (!draggingPlayhead) return;
      draggingPlayhead = false;
      var fraction = nearestCursorFraction(event.clientX, event.clientY);
      window.flutter_inappwebview.callHandler('sheetPlayheadEnd',
        fraction !== null ? fraction : lastDragFraction);
    });
    container.addEventListener('pointercancel', function() {
      if (!draggingPlayhead) return;
      draggingPlayhead = false;
      window.flutter_inappwebview.callHandler('sheetPlayheadEnd', lastDragFraction);
    });

    renderOSMD(musicXmlData);
    var resizeTimer;
    window.addEventListener('resize', function() {
      clearTimeout(resizeTimer);
      resizeTimer = setTimeout(buildCursorPositions, 300);
    });
  </script>
</body>
</html>
''';

      return InAppWebView(
        key: ValueKey(_musicXmlContent.hashCode),
        initialData: InAppWebViewInitialData(
          data: html,
        ),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          supportZoom: true,
          builtInZoomControls: true,
          displayZoomControls: false,
          transparentBackground: true,
          loadWithOverviewMode: false,
          useWideViewPort: false,
        ),
        onWebViewCreated: (controller) {
          _sheetController = controller;
          controller.addJavaScriptHandler(
            handlerName: 'sheetPlayheadStart',
            callback: (arguments) {
              final fraction = (arguments.firstOrNull as num?)?.toDouble();
              if (fraction != null) _beginSheetDrag(fraction);
              return null;
            },
          );
          controller.addJavaScriptHandler(
            handlerName: 'sheetPlayheadPreview',
            callback: (arguments) {
              final fraction = (arguments.firstOrNull as num?)?.toDouble();
              if (fraction != null && _isSheetDragging) {
                _previewSheetSeek(fraction);
              }
              return null;
            },
          );
          controller.addJavaScriptHandler(
            handlerName: 'sheetPlayheadEnd',
            callback: (arguments) {
              final fraction = (arguments.firstOrNull as num?)?.toDouble();
              if (fraction != null) _endSheetDrag(fraction);
              return null;
            },
          );
        },
        onLoadStop: (controller, url) async {
          debugPrint('OSMD loaded: $url');
        },
        onReceivedError: (controller, request, error) {
          debugPrint(
            'OSMD load error: url=${request.url}, '
            'code=${error.type}, message=${error.description}',
          );
        },
        onConsoleMessage: (controller, consoleMessage) {
          debugPrint('JS: ${consoleMessage.message}');
        },
      );
    }

    if (_sheetImageAvailable) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildInfoRow(isSmallScreen),
            const SizedBox(height: 8),
            Image.network(
              _downloadUrl(_sheetImageFile),
              fit: BoxFit.fitWidth,
              width: double.infinity,
              loadingBuilder: (context, child, loadingProgress) {
                if (loadingProgress == null) return child;
                return const SizedBox(
                  height: 120,
                  child: Center(child: CircularProgressIndicator()),
                );
              },
              errorBuilder: (context, error, stackTrace) {
                return Image.network(
                  _downloadUrl(_sheetImageFile, 1),
                  fit: BoxFit.fitWidth,
                  width: double.infinity,
                  errorBuilder: (context, error, stackTrace) {
                    return const SizedBox(
                      height: 120,
                      child: Center(child: Text('Failed to load sheet')),
                    );
                  },
                );
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      );
    }

    return _buildEmptyState();
  }
}
