import 'dart:async';
import 'dart:convert';
import 'package:audioplayers/audioplayers.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'sheet_edit_document.dart';
import 'sheet_editor_walkthrough.dart';

class EditedMusicSheet {
  const EditedMusicSheet(this.musicXml);
  final String musicXml;
}

class MusicNoteEditorPage extends StatefulWidget {
  const MusicNoteEditorPage(
      {super.key,
      required this.musicXml,
      required this.osmdScriptUrl,
      required this.apiBaseUrls,
      this.scoreBuilder});
  final String musicXml, osmdScriptUrl;
  final List<String> apiBaseUrls;
  @visibleForTesting
  final Widget Function(BuildContext, ValueChanged<int>)? scoreBuilder;
  @override
  State<MusicNoteEditorPage> createState() => _MusicNoteEditorPageState();
}

class _MusicNoteEditorPageState extends State<MusicNoteEditorPage> {
  late SheetEditDocument _score;
  late String _xml = widget.musicXml;
  String? _loadError, _html;
  InAppWebViewController? _controller;
  final _undo = <String>[];
  final _redo = <String>[];
  final _tourTargets = List.generate(4, (_) => GlobalKey());
  final _previewCache = <String, List<int>>{};
  AudioPlayer? _player;
  Timer? _redrawTimer;
  int? _selected;
  int _octave = 4, _previewToken = 0;
  bool _tourOpen = false, _drawing = false, _drawAgain = false;
  bool _previewing = false, _playing = false, _leaving = false;
  String _tab = 'Change note';
  bool get _dirty => _xml != widget.musicXml;
  SheetEditNote? get _note =>
      _selected == null ? null : _score.notes[_selected!];

  @override
  void initState() {
    super.initState();
    try {
      _score = SheetEditDocument(_xml);
    } catch (_) {
      _loadError = 'This sheet could not be opened for editing.';
    }
    unawaited(_loadView());
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _startTour(firstVisit: true));
  }

  Future<void> _loadView() async {
    if (_loadError != null || widget.scoreBuilder != null) return;
    final script = await rootBundle.loadString('assets/web/js/sheet_editor.js');
    if (!mounted) return;
    setState(() => _html = '''<!doctype html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=3,user-scalable=yes">
<style>html,body{margin:0;width:100%;background:#ffffff;overflow:auto;-webkit-overflow-scrolling:touch}#score{width:100%;min-height:100%;padding:2px;position:relative;background:#ffffff}#score svg{background:#ffffff!important}#status{padding:24px;font:14px sans-serif;color:#555}#selection{position:absolute;border:2px solid #ba0007;background:#ba000718;border-radius:4px;pointer-events:none;display:none;box-sizing:border-box}</style>
</head><body><div id="status">Opening sheet…</div><div id="score"></div><div id="selection"></div>
<script>var initialXml=${jsonEncode(_xml)}, initialNotes=${jsonEncode(_score.notes.map((n) => n.selectionData).toList())}, scriptUrl=${jsonEncode(widget.osmdScriptUrl)};</script>
<script>$script</script></body></html>''');
  }

  Future<void> _startTour({bool firstVisit = false}) async {
    if (_tourOpen || _loadError != null) return;
    _tourOpen = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted ||
          (firstVisit && prefs.getBool('sheet_editor_tour_v3') == true)) {
        return;
      }
      await showSheetEditorWalkthrough(context, _tourTargets);
      await prefs.setBool('sheet_editor_tour_v3', true);
    } finally {
      _tourOpen = false;
    }
  }

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  void _select(int index) {
    if (index < 0 || index >= _score.notes.length) return;
    setState(() {
      _selected = index;
      _octave = (_note!.midi ~/ 12 - 1).clamp(0, 8);
    });
    unawaited(_controller?.evaluateJavascript(
            source: 'window.selectScoreIndex($index);') ??
        Future.value());
  }

  void _edit(void Function(SheetEditDocument, int) operation) {
    if (_selected == null) return;
    try {
      final draft = SheetEditDocument(_xml);
      operation(draft, _selected!);
      final next = draft.xml;
      if (next == _xml) return;
      _undo.add(_xml);
      _redo.clear();
      _replace(next);
    } on StateError catch (e) {
      _message(e.message);
    } catch (_) {
      _message('This note could not be changed. Your sheet is unchanged.');
    }
  }

  void _replace(String xml) {
    unawaited(_stopPreview());
    setState(() {
      _xml = xml;
      _score = SheetEditDocument(xml);
      if (_selected != null && _selected! >= _score.notes.length) {
        _selected = null;
      }
    });
    _redrawTimer?.cancel();
    _redrawTimer = Timer(const Duration(milliseconds: 160), _draw);
  }

  Future<void> _draw() async {
    if (_drawing) {
      _drawAgain = true;
      return;
    }
    _drawing = true;
    try {
      do {
        _drawAgain = false;
        if (!mounted) return;
        await _controller?.evaluateJavascript(
            source:
                'window.updateScore(${jsonEncode(_xml)},${jsonEncode(_score.notes.map((n) => n.selectionData).toList())},${jsonEncode(_selected)});');
      } while (_drawAgain);
    } catch (_) {
      _message(
          'The preview could not refresh. Undo or reopen the editor to retry.');
    } finally {
      _drawing = false;
    }
  }

  void _history(bool redo) {
    final from = redo ? _redo : _undo, to = redo ? _undo : _redo;
    if (from.isEmpty) return;
    to.add(_xml);
    _replace(from.removeLast());
  }

  Future<void> _stopPreview() async {
    _previewToken++;
    if (mounted) {
      setState(() {
        _previewing = false;
        _playing = false;
      });
    }
    await _player?.stop();
  }

  Future<void> _listen() async {
    if (_previewing || _playing) {
      await _stopPreview();
      return;
    }
    final note = _note;
    if (note == null) return;
    final excerpt = _score.barXml(note.bar);
    final token = ++_previewToken;
    setState(() => _previewing = true);
    try {
      var bytes = _previewCache[excerpt];
      if (bytes == null) {
        final auth = await FirebaseAuth.instance.currentUser?.getIdToken();
        for (final base in widget.apiBaseUrls) {
          try {
            final response = await http
                .post(Uri.parse('$base/api/sheet/preview-bar'),
                    headers: {
                      'Content-Type': 'application/json',
                      if (auth != null) 'Authorization': 'Bearer $auth'
                    },
                    body: jsonEncode({'musicxml_content': excerpt}))
                .timeout(const Duration(seconds: 45));
            if (!mounted || token != _previewToken) return;
            if (response.statusCode == 200 &&
                (response.headers['content-type'] ?? '').contains('audio')) {
              bytes = response.bodyBytes;
              break;
            }
          } catch (_) {/* Try the next configured server. */}
        }
        if (bytes == null) throw StateError('Preview unavailable');
        if (_previewCache.length >= 8) {
          _previewCache.remove(_previewCache.keys.first);
        }
        _previewCache[excerpt] = bytes;
      }
      if (!mounted || token != _previewToken) return;
      if (_player == null) {
        _player = AudioPlayer();
        _player!.onPlayerComplete.listen((_) {
          if (mounted) setState(() => _playing = false);
        });
      }
      await _player!.play(BytesSource(Uint8List.fromList(bytes)));
      if (mounted && token == _previewToken) setState(() => _playing = true);
    } catch (_) {
      if (token == _previewToken) {
        _message(
            'Could not play this bar. Check your connection and try again.');
      }
    } finally {
      if (mounted && token == _previewToken) {
        setState(() => _previewing = false);
      }
    }
  }

  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    try {
      if (!_dirty) {
        Navigator.pop(context);
        return;
      }
      final choice = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
                  title: const Text('Save your changes?'),
                  content:
                      const Text('Save updates the sheet and its playback.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, 'stay'),
                        child: const Text('Keep editing')),
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, 'discard'),
                        child: const Text('Discard')),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, 'save'),
                        child: const Text('Save'))
                  ]));
      if (!mounted) return;
      if (choice == 'save') Navigator.pop(context, EditedMusicSheet(_xml));
      if (choice == 'discard') Navigator.pop(context);
    } finally {
      _leaving = false;
    }
  }

  @override
  void dispose() {
    _redrawTimer?.cancel();
    _previewToken++;
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final note = _loadError == null ? _note : null;
    return PopScope(
        canPop: !_dirty || _leaving,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_leave());
        },
        child: Scaffold(
          appBar: AppBar(
              leading: BackButton(onPressed: _leave),
              titleSpacing: 0,
              title: Text(_dirty ? 'Unsaved changes' : 'Edit sheet',
                  style: const TextStyle(fontSize: 15)),
              actions: [
                IconButton(
                    key: _tourTargets[2],
                    tooltip: 'Undo',
                    onPressed: _undo.isEmpty ? null : () => _history(false),
                    icon: const Icon(Icons.undo)),
                IconButton(
                    tooltip: 'Redo',
                    onPressed: _redo.isEmpty ? null : () => _history(true),
                    icon: const Icon(Icons.redo)),
                IconButton(
                    tooltip: 'Help',
                    onPressed: _startTour,
                    icon: const Icon(Icons.help_outline))
              ]),
          body: LayoutBuilder(
              builder: (context, constraints) => Column(children: [
                    Expanded(
                        key: _tourTargets[0],
                        child: _loadError != null
                            ? Center(child: Text(_loadError!))
                            : widget.scoreBuilder?.call(context, _select) ??
                                (_html == null
                                    ? const Center(
                                        child: CircularProgressIndicator())
                                    : InAppWebView(
                                        initialData: InAppWebViewInitialData(
                                            data: _html!),
                                        initialSettings: InAppWebViewSettings(
                                            javaScriptEnabled: true,
                                            supportZoom: true,
                                            builtInZoomControls: true,
                                            displayZoomControls: false),
                                        onWebViewCreated: (controller) {
                                          _controller = controller;
                                          controller.addJavaScriptHandler(
                                              handlerName: 'selectScoreNote',
                                              callback: (args) {
                                                final index =
                                                    (args.firstOrNull as num?)
                                                        ?.toInt();
                                                if (mounted && index != null) {
                                                  _select(index);
                                                }
                                                return null;
                                              });
                                        }))),
                    ConstrainedBox(
                        constraints: BoxConstraints(
                            maxHeight: constraints.maxHeight * .55),
                        child: Material(
                            key: _tourTargets[1],
                            elevation: 8,
                            color: Theme.of(context).colorScheme.surface,
                            child: SingleChildScrollView(
                                child: Padding(
                                    padding:
                                        const EdgeInsets.fromLTRB(12, 8, 12, 4),
                                    child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (note == null)
                                            const Padding(
                                                padding: EdgeInsets.all(16),
                                                child: Text(
                                                    'Tap a note on the sheet to change it.'))
                                          else ...[
                                            Row(children: [
                                              IconButton(
                                                  tooltip: 'Previous note',
                                                  onPressed: note.index > 0
                                                      ? () => _select(
                                                          note.index - 1)
                                                      : null,
                                                  icon: const Icon(
                                                      Icons.chevron_left)),
                                              Expanded(
                                                  child: Text(
                                                      'Bar ${note.bar} · ${note.label}',
                                                      textAlign:
                                                          TextAlign.center,
                                                      style: const TextStyle(
                                                          fontWeight: FontWeight
                                                              .bold))),
                                              IconButton(
                                                  tooltip: 'Next note',
                                                  onPressed: note.index + 1 <
                                                          _score.notes.length
                                                      ? () => _select(
                                                          note.index + 1)
                                                      : null,
                                                  icon: const Icon(
                                                      Icons.chevron_right))
                                            ]),
                                            _buildNotationToolbar(note),
                                            const SizedBox(height: 6),
                                            Wrap(spacing: 8, children: [
                                              for (final tab in [
                                                'Change note',
                                                'Note length'
                                              ])
                                                ChoiceChip(
                                                    label: Text(tab),
                                                    selected: _tab == tab,
                                                    onSelected: (_) => setState(
                                                        () => _tab = tab))
                                            ]),
                                            if (_tab == 'Change note') ...[
                                              Row(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.center,
                                                  children: [
                                                    IconButton(
                                                        tooltip: 'Lower octave',
                                                        onPressed: _octave > 0
                                                            ? () => setState(
                                                                () => _octave--)
                                                            : null,
                                                        icon: const Icon(
                                                            Icons.remove)),
                                                    Text('Octave $_octave'),
                                                    IconButton(
                                                        tooltip:
                                                            'Higher octave',
                                                        onPressed: _octave < 8
                                                            ? () => setState(
                                                                () => _octave++)
                                                            : null,
                                                        icon: const Icon(
                                                            Icons.add))
                                                  ]),
                                              SheetPianoKeys(
                                                  octave: _octave,
                                                  selectedMidi: note.isRest
                                                      ? null
                                                      : note.midi,
                                                  enabled: !note.locked,
                                                  onSelected: (midi) => _edit(
                                                      (doc, index) => doc.pitch(
                                                          index, midi))),
                                            ] else ...[
                                              Padding(
                                                  padding: const EdgeInsets
                                                      .symmetric(vertical: 8),
                                                  child: Text(
                                                      'Current length: ${note.beatLength} beats',
                                                      textAlign:
                                                          TextAlign.center)),
                                              Wrap(
                                                  spacing: 6,
                                                  runSpacing: 4,
                                                  children: [
                                                    for (final entry
                                                        in SheetEditDocument
                                                            .beats.entries)
                                                      OutlinedButton(
                                                          onPressed: note.locked ||
                                                                  note.isRest ||
                                                                  note.inChord(
                                                                      _score
                                                                          .notes)
                                                              ? null
                                                              : () => _edit((doc,
                                                                      index) =>
                                                                  doc.length(
                                                                      index,
                                                                      entry
                                                                          .key)),
                                                          child:
                                                              Text('${entry.value} beat${entry.value == 1 ? '' : 's'}'))
                                                  ]),
                                              const Padding(
                                                  padding:
                                                      EdgeInsets.only(top: 6),
                                                  child: Text(
                                                      'Shorter adds silence. Longer uses the silence after this note.',
                                                      style: TextStyle(
                                                          fontSize: 12),
                                                      textAlign:
                                                          TextAlign.center)),
                                            ],
                                            if (note.locked)
                                              const Padding(
                                                  padding: EdgeInsets.all(8),
                                                  child: Text(
                                                      'This connected or grace note cannot be edited on its own.',
                                                      textAlign:
                                                          TextAlign.center)),
                                            Wrap(
                                                spacing: 8,
                                                alignment: WrapAlignment.center,
                                                children: [
                                                  TextButton.icon(
                                                      onPressed: note.locked ||
                                                              note.isRest ||
                                                              note.inChord(
                                                                  _score.notes)
                                                          ? null
                                                          : () => _edit(
                                                              (doc, index) =>
                                                                  doc.silence(
                                                                      index)),
                                                      icon: const Icon(
                                                          Icons.pause),
                                                      label: const Text(
                                                          'Make silent')),
                                                  FilledButton.tonalIcon(
                                                      onPressed: _listen,
                                                      icon: Icon(_previewing ||
                                                              _playing
                                                          ? Icons.stop
                                                          : Icons.play_arrow),
                                                      label: Text(_previewing
                                                          ? 'Cancel preview'
                                                          : _playing
                                                              ? 'Stop'
                                                              : 'Listen to bar'))
                                                ]),
                                            if (_previewing)
                                              const LinearProgressIndicator(),
                                          ],
                                        ]))))),
                    SafeArea(
                        top: false,
                        child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
                            child: SizedBox(
                                width: double.infinity,
                                child: FilledButton(
                                    key: _tourTargets[3],
                                    onPressed: _dirty
                                        ? () {
                                            _leaving = true;
                                            Navigator.pop(context,
                                                EditedMusicSheet(_xml));
                                          }
                                        : null,
                                    child: const Text('Save changes'))))),
                  ])),
        ));
  }

  Widget _buildNotationToolbar(SheetEditNote note) {
    const red = Color(0xFFBA0007);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    Widget toolBtn({
      required String label,
      required String tooltip,
      required bool active,
      required VoidCallback? onPressed,
      double fontSize = 16,
    }) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Tooltip(
          message: tooltip,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: active
                    ? red.withValues(alpha: 0.15)
                    : (isDark
                        ? const Color(0xFF2C2C2C)
                        : const Color(0xFFF3F3F3)),
                border: Border.all(
                  color: active
                      ? red
                      : (isDark
                          ? const Color(0xFF444444)
                          : const Color(0xFFE0E0E0)),
                  width: active ? 2.0 : 1.0,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: active ? FontWeight.bold : FontWeight.normal,
                  color: onPressed == null
                      ? (isDark ? Colors.grey[700] : Colors.grey[400])
                      : (active
                          ? red
                          : (isDark ? Colors.white : const Color(0xFF1A1A1A))),
                ),
              ),
            ),
          ),
        ),
      );
    }

    Widget divider() {
      return Container(
        width: 1,
        height: 24,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        color: isDark ? const Color(0xFF444444) : const Color(0xFFD6D6D6),
      );
    }

    return Container(
      height: 48,
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF202020) : const Color(0xFFFAFAFA),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDark ? const Color(0xFF333333) : const Color(0xFFE8E8E8),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Durations
            toolBtn(
              label: '𝅝',
              tooltip: 'Whole note (4 beats)',
              active: !note.isRest && note.type == 'whole',
              onPressed: note.locked || note.isRest
                  ? null
                  : () => _edit((doc, i) => doc.length(i, 'whole')),
              fontSize: 22,
            ),
            toolBtn(
              label: '𝅗𝅥',
              tooltip: 'Half note (2 beats)',
              active: !note.isRest && note.type == 'half',
              onPressed: note.locked || note.isRest
                  ? null
                  : () => _edit((doc, i) => doc.length(i, 'half')),
              fontSize: 22,
            ),
            toolBtn(
              label: '♩',
              tooltip: 'Quarter note (1 beat)',
              active: !note.isRest && note.type == 'quarter',
              onPressed: note.locked || note.isRest
                  ? null
                  : () => _edit((doc, i) => doc.length(i, 'quarter')),
              fontSize: 22,
            ),
            toolBtn(
              label: '♪',
              tooltip: 'Eighth note (1/2 beat)',
              active: !note.isRest && note.type == 'eighth',
              onPressed: note.locked || note.isRest
                  ? null
                  : () => _edit((doc, i) => doc.length(i, 'eighth')),
              fontSize: 22,
            ),
            toolBtn(
              label: '𝅘𝅥𝅯',
              tooltip: '16th note (1/4 beat)',
              active: !note.isRest && note.type == '16th',
              onPressed: note.locked || note.isRest
                  ? null
                  : () => _edit((doc, i) => doc.length(i, '16th')),
              fontSize: 22,
            ),
            toolBtn(
              label: '•',
              tooltip: 'Dotted note (adds 50% length)',
              active: note.hasDot,
              onPressed: note.locked || note.isRest
                  ? null
                  : () => _edit((doc, i) => doc.toggleDot(i)),
              fontSize: 24,
            ),
            toolBtn(
              label: '𝄽',
              tooltip: 'Rest (silence)',
              active: note.isRest,
              onPressed: note.locked
                  ? null
                  : () => _edit((doc, i) => doc.silence(i)),
              fontSize: 22,
            ),

            divider(),

            // Accidentals
            toolBtn(
              label: '𝄫',
              tooltip: 'Double flat',
              active: !note.isRest && note.alter == -2,
              onPressed: note.locked || note.isRest
                  ? null
                  : () => _edit((doc, i) => doc.setAccidental(i, -2)),
              fontSize: 18,
            ),
            toolBtn(
              label: '♭',
              tooltip: 'Flat',
              active: !note.isRest && note.alter == -1,
              onPressed: note.locked || note.isRest
                  ? null
                  : () => _edit((doc, i) => doc.setAccidental(i, -1)),
              fontSize: 18,
            ),
            toolBtn(
              label: '♮',
              tooltip: 'Natural',
              active: !note.isRest && note.alter == 0,
              onPressed: note.locked || note.isRest
                  ? null
                  : () => _edit((doc, i) => doc.setAccidental(i, 0)),
              fontSize: 18,
            ),
            toolBtn(
              label: '♯',
              tooltip: 'Sharp',
              active: !note.isRest && note.alter == 1,
              onPressed: note.locked || note.isRest
                  ? null
                  : () => _edit((doc, i) => doc.setAccidental(i, 1)),
              fontSize: 18,
            ),
            toolBtn(
              label: '𝄪',
              tooltip: 'Double sharp',
              active: !note.isRest && note.alter == 2,
              onPressed: note.locked || note.isRest
                  ? null
                  : () => _edit((doc, i) => doc.setAccidental(i, 2)),
              fontSize: 18,
            ),

            divider(),

            // Articulations
            toolBtn(
              label: '·',
              tooltip: 'Staccato',
              active: note.hasArticulation('staccato'),
              onPressed: note.isRest
                  ? null
                  : () =>
                      _edit((doc, i) => doc.toggleArticulation(i, 'staccato')),
              fontSize: 24,
            ),
            toolBtn(
              label: '>',
              tooltip: 'Accent',
              active: note.hasArticulation('accent'),
              onPressed: note.isRest
                  ? null
                  : () => _edit((doc, i) => doc.toggleArticulation(i, 'accent')),
              fontSize: 16,
            ),
            toolBtn(
              label: '—',
              tooltip: 'Tenuto',
              active: note.hasArticulation('tenuto'),
              onPressed: note.isRest
                  ? null
                  : () => _edit((doc, i) => doc.toggleArticulation(i, 'tenuto')),
              fontSize: 16,
            ),
            toolBtn(
              label: '^',
              tooltip: 'Marcato',
              active: note.hasArticulation('strong-accent'),
              onPressed: note.isRest
                  ? null
                  : () => _edit(
                      (doc, i) => doc.toggleArticulation(i, 'strong-accent')),
              fontSize: 16,
            ),

            divider(),

            // Tie
            toolBtn(
              label: '⌒',
              tooltip: 'Tie note',
              active: note.isTied,
              onPressed: note.isRest
                  ? null
                  : () => _edit((doc, i) => doc.toggleTie(i)),
              fontSize: 18,
            ),
          ],
        ),
      ),
    );
  }
}

class SheetPianoKeys extends StatelessWidget {
  const SheetPianoKeys(
      {super.key,
      required this.octave,
      required this.selectedMidi,
      required this.enabled,
      required this.onSelected});
  final int octave;
  final int? selectedMidi;
  final bool enabled;
  final ValueChanged<int> onSelected;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
          width: 308,
          height: 100,
          child: Stack(children: [
            for (var i = 0; i < 7; i++)
              Positioned(
                  left: i * 44,
                  top: 0,
                  bottom: 0,
                  width: 44,
                  child: _key([0, 2, 4, 5, 7, 9, 11][i], false)),
            for (final pair in [(0, 1), (1, 3), (3, 6), (4, 8), (5, 10)])
              Positioned(
                  left: (pair.$1 + 1) * 44 - 14,
                  top: 0,
                  width: 28,
                  height: 60,
                  child: _key(pair.$2, true)),
          ])));
  Widget _key(int pitch, bool black) {
    final midi = (octave + 1) * 12 + pitch;
    final selected = midi == selectedMidi;
    final label = '${[
      'C',
      'C♯',
      'D',
      'D♯',
      'E',
      'F',
      'F♯',
      'G',
      'G♯',
      'A',
      'A♯',
      'B'
    ][pitch]}$octave';
    return Semantics(
        button: true,
        label: label,
        selected: selected,
        child: Material(
            color: selected
                ? const Color(0xFFBA0007)
                : black
                    ? const Color(0xFF222222)
                    : Colors.white,
            shape: RoundedRectangleBorder(
                side: const BorderSide(color: Colors.grey, width: .5),
                borderRadius: BorderRadius.circular(4)),
            child: InkWell(
                onTap: enabled ? () => onSelected(midi) : null,
                child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(label,
                            style: TextStyle(
                                fontSize: black ? 9 : 12,
                                color: selected || black
                                    ? Colors.white
                                    : Colors.black)))))));
  }
}
