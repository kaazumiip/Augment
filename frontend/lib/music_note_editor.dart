import 'dart:convert';
import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;

class EditedMusicSheet {
  const EditedMusicSheet(this.musicXml);
  final String musicXml;
}

class MusicNoteEditorPage extends StatefulWidget {
  const MusicNoteEditorPage({
    super.key,
    required this.musicXml,
    required this.osmdScriptUrl,
    required this.apiBaseUrls,
  });
  final String musicXml;
  final String osmdScriptUrl;
  final List<String> apiBaseUrls;

  @override
  State<MusicNoteEditorPage> createState() => _MusicNoteEditorPageState();
}

class _MusicNoteEditorPageState extends State<MusicNoteEditorPage> {
  late final List<_ScoreNote> _notes = _ScoreNote.parse(widget.musicXml);
  late String _xml = widget.musicXml;
  InAppWebViewController? _controller;
  AudioPlayer? _previewPlayer;
  int? _selected;
  int? _selectedMeasure;
  int _previewToken = 0;
  bool _editorOpen = false;
  final List<_EditorSnapshot> _undoStack = [];
  final List<_EditorSnapshot> _redoStack = [];

  bool get _canUndo => _undoStack.isNotEmpty;
  bool get _canRedo => _redoStack.isNotEmpty;

  _EditorSnapshot get _snapshot => _EditorSnapshot(
        notes: List<_ScoreNote>.of(_notes),
        selected: _selected,
        selectedMeasure: _selectedMeasure,
      );

  Future<void> _restoreSnapshot(_EditorSnapshot snapshot) async {
    setState(() {
      _notes
        ..clear()
        ..addAll(snapshot.notes);
      _selected = snapshot.selected;
      _selectedMeasure = snapshot.selectedMeasure;
      _xml = _ScoreNote.apply(widget.musicXml, _notes);
    });
    await _renderScore();
  }

  Future<void> _undo() async {
    if (!_canUndo) return;
    final previous = _undoStack.removeLast();
    _redoStack.add(_snapshot);
    await _restoreSnapshot(previous);
  }

  Future<void> _redo() async {
    if (!_canRedo) return;
    final next = _redoStack.removeLast();
    _undoStack.add(_snapshot);
    await _restoreSnapshot(next);
  }

  Future<void> _renderScore() async {
    await _controller?.evaluateJavascript(
      source: 'window.updateScore(${jsonEncode(_xml)});',
    );
    final index = _selected;
    if (index != null) {
      await _controller?.evaluateJavascript(
        source: 'window.selectScoreIndex($index);',
      );
    }
  }

  Future<void> _selectEvent(int index) async {
    if (index < 0 || index >= _notes.length) return;
    setState(() {
      _selected = index;
      _selectedMeasure = _notes[index].measure;
    });
    await _controller?.evaluateJavascript(
      source: 'window.selectScoreIndex($index);',
    );
  }

  int get _activeMeasure =>
      _selectedMeasure ?? (_notes.isEmpty ? 1 : _notes.first.measure);

  List<int> get _measures =>
      _notes.map((note) => note.measure).toSet().toList()..sort();

  List<int> get _eventsInActiveMeasure => [
        for (var index = 0; index < _notes.length; index++)
          if (_notes[index].measure == _activeMeasure) index,
      ];

  Future<void> _selectMeasure(int measure) async {
    final firstEvent = _notes.indexWhere((note) => note.measure == measure);
    if (firstEvent >= 0) {
      await _selectEvent(firstEvent);
    } else {
      setState(() => _selectedMeasure = measure);
    }
  }

  Future<void> _editSelected() async {
    final index = _selected;
    if (index == null || _editorOpen) return;
    _editorOpen = true;
    try {
      final result = await showModalBottomSheet<_ScoreNote>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _NoteTools(
          note: _notes[index],
          onPreview: _previewEditedNote,
        ),
      );
      if (result == null || !mounted) return;
      _undoStack.add(_snapshot);
      _redoStack.clear();
      setState(() {
        _notes[index] = result;
        _xml = _ScoreNote.apply(widget.musicXml, _notes);
      });
      await _renderScore();
      if (!result.isRest) unawaited(_previewEditedNote(result));
    } finally {
      _editorOpen = false;
    }
  }

  Future<void> _updateSelected(
      _ScoreNote Function(_ScoreNote note) update) async {
    final index = _selected;
    if (index == null) return;
    final updated = update(_notes[index]);
    if (identical(updated, _notes[index])) return;
    _undoStack.add(_snapshot);
    _redoStack.clear();
    setState(() {
      _notes[index] = updated;
      _xml = _ScoreNote.apply(widget.musicXml, _notes);
    });
    await _renderScore();
    if (!_notes[index].isRest) unawaited(_previewEditedNote(_notes[index]));
  }

  Future<void> _previewEditedNote(_ScoreNote note) async {
    final token = ++_previewToken;
    _previewPlayer ??= AudioPlayer();
    await _previewPlayer?.stop();
    const durations = {
      'whole': 1.35,
      'half': 1.0,
      'quarter': .70,
      'eighth': .48,
      '16th': .30,
      '32nd': .22,
    };
    for (final baseUrl in widget.apiBaseUrls) {
      try {
        final response = await http
            .post(
              Uri.parse('$baseUrl/api/sheet/preview-note'),
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({
                'pitch': note.previewPitch,
                'instrument': _instrumentNameFromXml(),
                'duration': durations[note.type] ?? .70,
              }),
            )
            .timeout(const Duration(seconds: 20));
        if (token != _previewToken || response.statusCode != 200) continue;
        await _previewPlayer!.play(BytesSource(response.bodyBytes));
        return;
      } catch (_) {
        // A note edit stays valid even if the local renderer is offline.
      }
    }
  }

  String _instrumentNameFromXml() {
    final xml = _xml.toLowerCase();
    if (xml.contains('violin')) return 'Violin';
    if (xml.contains('guitar')) return 'Guitar';
    if (xml.contains('cello')) return 'Cello';
    if (xml.contains('flute')) return 'Flute';
    if (xml.contains('saxophone')) return 'Saxophone';
    if (xml.contains('trumpet')) return 'Trumpet';
    if (xml.contains('clarinet')) return 'Clarinet';
    return 'Piano';
  }

  @override
  void dispose() {
    _previewPlayer?.dispose();
    super.dispose();
  }

  Future<void> _transposeSelected(int semitones) async {
    const natural = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11};
    const spellings = [
      ('C', 0),
      ('C', 1),
      ('D', 0),
      ('D', 1),
      ('E', 0),
      ('F', 0),
      ('F', 1),
      ('G', 0),
      ('G', 1),
      ('A', 0),
      ('A', 1),
      ('B', 0),
    ];
    await _updateSelected((note) {
      if (note.isRest) return note;
      final midi =
          (note.octave * 12 + natural[note.step]! + note.alter + semitones)
              .clamp(0, 8 * 12 + 11)
              .toInt();
      final spelling = spellings[midi % 12];
      return note.copyWith(
        step: spelling.$1,
        alter: spelling.$2,
        octave: midi ~/ 12,
        type: note.type,
        duration: note.duration,
        dotted: note.dotted,
        tie: note.tie,
      );
    });
  }

  Future<void> _setDuration(String type) async {
    const beats = {
      'whole': 4.0,
      'half': 2.0,
      'quarter': 1.0,
      'eighth': .5,
      '16th': .25,
      '32nd': .125,
    };
    await _updateSelected((note) {
      // MusicXML divisions differ between generated scores. Scale from the
      // selected note's existing valid duration instead of assuming a fixed
      // divisions-per-quarter value.
      final oldBeats = beats[note.type] ?? 1.0;
      final newBeats = beats[type] ?? oldBeats;
      return note.copyWith(
        step: note.step,
        alter: note.alter,
        octave: note.octave,
        type: type,
        duration: (note.duration * newBeats / oldBeats).round().clamp(1, 4096),
        dotted: note.dotted,
        tie: note.tie,
      );
    });
  }

  /// Reuses the selected event's existing rhythmic slot. This lets a user
  /// place a note into a rest (or remove a note) without shifting the rest of
  /// the measure and breaking the exported PDF layout.
  Future<void> _setRestState(bool isRest) =>
      _updateSelected((note) => note.copyWith(
            step: note.step,
            alter: note.alter,
            octave: note.octave,
            type: note.type,
            duration: note.duration,
            dotted: note.dotted,
            tie: isRest ? 'none' : note.tie,
            isRest: isRest,
          ));

  Future<void> _setAccidental(int alter) =>
      _updateSelected((note) => note.copyWith(
            step: note.step,
            alter: alter,
            octave: note.octave,
            type: note.type,
            duration: note.duration,
            dotted: note.dotted,
            tie: note.tie,
          ));

  Future<void> _toggleDot() => _updateSelected((note) => note.copyWith(
        step: note.step,
        alter: note.alter,
        octave: note.octave,
        type: note.type,
        duration: note.duration,
        dotted: !note.dotted,
        tie: note.tie,
      ));

  @override
  Widget build(BuildContext context) {
    final selected = _selected == null ? null : _notes[_selected!];
    final activeMeasure = _activeMeasure;
    final activeEvents = _eventsInActiveMeasure;
    final selectedEventPosition =
        _selected == null ? -1 : activeEvents.indexOf(_selected!);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sheet studio'),
        actions: [
          IconButton(
            tooltip: 'Undo',
            onPressed: _canUndo ? _undo : null,
            icon: const Icon(Icons.undo_rounded),
          ),
          IconButton(
            tooltip: 'Redo',
            onPressed: _canRedo ? _redo : null,
            icon: const Icon(Icons.redo_rounded),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, EditedMusicSheet(_xml)),
            child: const Text('Save'),
          ),
        ],
      ),
      body: Column(children: [
        _StudioPalette(
          enabled: selected != null,
          selectedDuration: selected?.type,
          isRest: selected?.isRest ?? false,
          onTransposeDown: () => _transposeSelected(-1),
          onTransposeUp: () => _transposeSelected(1),
          onAccidental: _setAccidental,
          onDuration: _setDuration,
          onDot: _toggleDot,
          onWriteNote: () => _setRestState(false),
          onWriteRest: () => _setRestState(true),
          onMore: _editSelected,
        ),
        _MeasureStrip(
          measures: _measures,
          selectedMeasure: activeMeasure,
          onSelected: _selectMeasure,
        ),
        _ScoreEventStrip(
          notes: _notes,
          selected: _selected,
          eventIndexes: activeEvents,
          onSelected: _selectEvent,
        ),
        Expanded(
          child: _notes.isEmpty
              ? const Center(child: Text('No editable score events found.'))
              : InAppWebView(
                  initialData: InAppWebViewInitialData(data: _scoreHtml()),
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    supportZoom: true,
                    builtInZoomControls: true,
                    displayZoomControls: false,
                  ),
                  onWebViewCreated: (controller) {
                    _controller = controller;
                    controller.addJavaScriptHandler(
                      handlerName: 'selectScoreNote',
                      callback: (args) {
                        final index = (args.firstOrNull as num?)?.toInt();
                        if (index != null &&
                            index >= 0 &&
                            index < _notes.length &&
                            mounted) {
                          unawaited(_selectEvent(index));
                        }
                        return null;
                      },
                    );
                  },
                ),
        ),
        SafeArea(
          top: false,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 7, 12, 9),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(
                  top: BorderSide(color: Theme.of(context).dividerColor)),
            ),
            child: Row(children: [
              IconButton.outlined(
                tooltip: 'Previous event',
                onPressed: selectedEventPosition <= 0
                    ? null
                    : () =>
                        _selectEvent(activeEvents[selectedEventPosition - 1]),
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              Expanded(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(
                    selected == null
                        ? 'Tap a note or rest to edit'
                        : 'Bar ${selected.measure}  •  ${selected.label}',
                    style: TextStyle(
                      color: selected == null
                          ? Theme.of(context).colorScheme.onSurfaceVariant
                          : const Color(0xFFBA0007),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (selected != null)
                    Text(
                      '${selected.type}${selected.dotted ? ' • dotted' : ''}${selected.tie == 'none' ? '' : ' • ${selected.tie} tie'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ]),
              ),
              IconButton.outlined(
                tooltip: 'Next event',
                onPressed: selectedEventPosition < 0 ||
                        selectedEventPosition >= activeEvents.length - 1
                    ? null
                    : () =>
                        _selectEvent(activeEvents[selectedEventPosition + 1]),
                icon: const Icon(Icons.chevron_right_rounded),
              ),
              const SizedBox(width: 7),
              FilledButton.tonalIcon(
                onPressed: selected == null ? null : _editSelected,
                icon: const Icon(Icons.tune_rounded, size: 18),
                label: const Text('Edit'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 11),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  String _scoreHtml() {
    final xml = jsonEncode(_xml);
    final scriptUrl = jsonEncode(widget.osmdScriptUrl);
    final eventTimes = jsonEncode(_notes.map((note) => note.timeKey).toList());
    return '''<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=3,user-scalable=yes"><style>
html,body{margin:0;background:#fffaf8}#score{min-height:100vh;padding:2px}#loading{padding:30px;text-align:center;color:#777}#hint{position:fixed;right:10px;bottom:10px;background:#222d;color:#fff;padding:7px 10px;border-radius:14px;font:11px sans-serif;z-index:12}#noteGlow{display:none;position:fixed;width:8px;border-radius:5px;background:#d50000;box-shadow:0 0 0 4px #ef171526,0 0 14px #ef171566;transform:translateX(-50%);pointer-events:none;z-index:11}
</style></head><body><div id="loading">Loading editable score…</div><div id="hint">Tap a note to select it</div><div id="score"></div><script>
var scoreXml=$xml,eventTimes=$eventTimes,osmd,positions=[],score=document.getElementById('score');
function script(){return new Promise(function(ok,bad){var s=document.createElement('script');s.src=$scriptUrl;s.onload=ok;s.onerror=function(){var f=document.createElement('script');f.src='https://unpkg.com/opensheetmusicdisplay@1.9.9/build/opensheetmusicdisplay.min.js';f.onload=ok;f.onerror=bad;document.head.appendChild(f)};document.head.appendChild(s)})}
function cursor(){return document.querySelector('#osmdCursor')||document.querySelector('.osmd-cursor')||document.querySelector('[id*=cursor i]')}
async function render(xml){document.getElementById('loading').style.display='block';score.innerHTML='';if(!window.opensheetmusicdisplay)await script();osmd=new opensheetmusicdisplay.OpenSheetMusicDisplay(score,{autoResize:true,backend:'svg',drawTitle:true,drawComposer:false,drawCredits:false,pageFormat:'A4_P'});await osmd.load(xml);osmd.zoom=window.innerWidth<=430?.46:.54;osmd.render();document.getElementById('loading').style.display='none';mapNotes()}
function timeOrder(a,b){var x=a.split(':').map(Number),y=b.split(':').map(Number);return x[0]-y[0]||x[1]-y[1]}
function mapNotes(){positions=[];if(!osmd||!osmd.cursor)return;var groups=Array.from(new Set(eventTimes)).sort(timeOrder),points=[];osmd.cursor.reset();osmd.cursor.show();for(var i=0;i<groups.length;i++){var c=cursor();if(c){var r=c.getBoundingClientRect();points.push({step:i,x:r.left+r.width/2,y:r.top+r.height/2})}try{osmd.cursor.next()}catch(e){break}}for(var j=0;j<eventTimes.length;j++){var position=points[groups.indexOf(eventTimes[j])];if(position)positions.push({index:j,step:position.step,x:position.x,y:position.y})}osmd.cursor.hide()}
function select(point){osmd.cursor.reset();osmd.cursor.show();for(var i=0;i<point.step;i++){try{osmd.cursor.next()}catch(e){break}}var c=cursor(),glow=document.getElementById('noteGlow');if(!glow){glow=document.createElement('div');glow.id='noteGlow';document.body.appendChild(glow)}if(c){c.style.setProperty('stroke','#ba0007','important');c.style.setProperty('stroke-width','3px','important');c.style.setProperty('fill','#ba0007','important');c.style.setProperty('fill-opacity','.12','important');var r=c.getBoundingClientRect();glow.style.left=(r.left+r.width/2)+'px';glow.style.top=(r.top+2)+'px';glow.style.height=Math.max(26,r.height-4)+'px';glow.style.display='block';c.scrollIntoView({block:'center',inline:'center',behavior:'smooth'})}}
score.addEventListener('pointerup',function(e){if(!positions.length)return;var best=positions[0],distance=Infinity;positions.forEach(function(p){var d=Math.abs(p.x-e.clientX)+Math.abs(p.y-e.clientY)*2;if(d<distance){best=p;distance=d}});if(distance>90)return;select(best);window.flutter_inappwebview.callHandler('selectScoreNote',best.index)});
window.selectScoreIndex=function(index){var point=positions.find(function(p){return p.index===index});if(point)select(point)};
window.updateScore=async function(xml){scoreXml=xml;await render(xml)};render(scoreXml);
</script></body></html>''';
  }
}

class _StudioPalette extends StatelessWidget {
  const _StudioPalette({
    required this.enabled,
    required this.selectedDuration,
    required this.isRest,
    required this.onTransposeDown,
    required this.onTransposeUp,
    required this.onAccidental,
    required this.onDuration,
    required this.onDot,
    required this.onWriteNote,
    required this.onWriteRest,
    required this.onMore,
  });

  final bool enabled;
  final String? selectedDuration;
  final bool isRest;
  final VoidCallback onTransposeDown;
  final VoidCallback onTransposeUp;
  final ValueChanged<int> onAccidental;
  final ValueChanged<String> onDuration;
  final VoidCallback onDot;
  final VoidCallback onWriteNote;
  final VoidCallback onWriteRest;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Container(
        height: 74,
        decoration: BoxDecoration(
          border:
              Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
        ),
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          children: [
            _PaletteAction(
              icon: Icons.arrow_downward_rounded,
              label: 'Down',
              enabled: enabled,
              onTap: onTransposeDown,
            ),
            _PaletteAction(
              icon: Icons.arrow_upward_rounded,
              label: 'Up',
              enabled: enabled,
              onTap: onTransposeUp,
            ),
            _PaletteAction(
              icon: Icons.edit_note_rounded,
              label: 'Write note',
              enabled: enabled,
              selected: enabled && !isRest,
              onTap: onWriteNote,
            ),
            _PaletteAction(
              icon: Icons.pause_circle_outline_rounded,
              label: 'Rest',
              enabled: enabled,
              selected: enabled && isRest,
              onTap: onWriteRest,
            ),
            _PaletteTextAction(
              text: '𝅝',
              label: 'Whole',
              enabled: enabled,
              selected: selectedDuration == 'whole',
              onTap: () => onDuration('whole'),
            ),
            _PaletteTextAction(
              text: '𝅗𝅥',
              label: 'Half',
              enabled: enabled,
              selected: selectedDuration == 'half',
              onTap: () => onDuration('half'),
            ),
            _PaletteAction(
              icon: Icons.music_note_rounded,
              label: 'Quarter',
              enabled: enabled,
              selected: selectedDuration == 'quarter',
              onTap: () => onDuration('quarter'),
            ),
            _PaletteAction(
              icon: Icons.music_note_outlined,
              label: 'Eighth',
              enabled: enabled,
              selected: selectedDuration == 'eighth',
              onTap: () => onDuration('eighth'),
            ),
            _PaletteTextAction(
              text: '𝅘𝅥𝅯',
              label: '16th',
              enabled: enabled,
              selected: selectedDuration == '16th',
              onTap: () => onDuration('16th'),
            ),
            _PaletteTextAction(
              text: '𝅘𝅥𝅰',
              label: '32nd',
              enabled: enabled,
              selected: selectedDuration == '32nd',
              onTap: () => onDuration('32nd'),
            ),
            _PaletteTextAction(
              text: '♭',
              label: 'Flat',
              enabled: enabled,
              onTap: () => onAccidental(-1),
            ),
            _PaletteTextAction(
              text: '♮',
              label: 'Natural',
              enabled: enabled,
              onTap: () => onAccidental(0),
            ),
            _PaletteTextAction(
              text: '♯',
              label: 'Sharp',
              enabled: enabled,
              onTap: () => onAccidental(1),
            ),
            _PaletteAction(
              icon: Icons.circle_outlined,
              label: 'Dot',
              enabled: enabled,
              onTap: onDot,
            ),
            _PaletteAction(
              icon: Icons.tune_rounded,
              label: 'More',
              enabled: enabled,
              onTap: onMore,
            ),
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 17),
              child: Text(
                enabled ? 'Writing tools' : 'Select a note',
                style: TextStyle(color: muted, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The score is edited one bar at a time, like desktop notation software. It
/// keeps the mobile editor focused without hiding any score event.
class _MeasureStrip extends StatelessWidget {
  const _MeasureStrip({
    required this.measures,
    required this.selectedMeasure,
    required this.onSelected,
  });

  final List<int> measures;
  final int selectedMeasure;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) => Container(
        height: 47,
        width: double.infinity,
        color: Theme.of(context).colorScheme.surface,
        child: Row(children: [
          const SizedBox(width: 14),
          const Icon(Icons.view_week_outlined, size: 18),
          const SizedBox(width: 7),
          const Text('BAR',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
          const SizedBox(width: 8),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemCount: measures.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (context, index) {
                final measure = measures[index];
                return ChoiceChip(
                  label: Text('$measure'),
                  selected: selectedMeasure == measure,
                  selectedColor: const Color(0xFFCA000A),
                  labelStyle: TextStyle(
                    color: selectedMeasure == measure ? Colors.white : null,
                    fontWeight: FontWeight.w700,
                  ),
                  onSelected: (_) => onSelected(measure),
                );
              },
            ),
          ),
          const SizedBox(width: 8),
        ]),
      );
}

/// An exact event navigator. SVG hit testing is useful, but a visual score can
/// contain chords and several voices at one time. This strip keeps every
/// MusicXML note and rest reachable, including each member of a chord.
class _ScoreEventStrip extends StatelessWidget {
  const _ScoreEventStrip({
    required this.notes,
    required this.selected,
    required this.eventIndexes,
    required this.onSelected,
  });

  final List<_ScoreNote> notes;
  final int? selected;
  final List<int> eventIndexes;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      height: 54,
      width: double.infinity,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLowest,
        border:
            Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        scrollDirection: Axis.horizontal,
        itemCount: eventIndexes.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, stripIndex) {
          final index = eventIndexes[stripIndex];
          final note = notes[index];
          return ChoiceChip(
            selected: selected == index,
            selectedColor: const Color(0xFFFFDDD9),
            avatar: Icon(
              note.isRest ? Icons.pause_rounded : Icons.music_note_rounded,
              size: 15,
              color: selected == index ? const Color(0xFFBA0007) : null,
            ),
            label: Text(note.label),
            labelStyle: TextStyle(
              fontSize: 11,
              fontWeight: selected == index ? FontWeight.w700 : FontWeight.w500,
              color: selected == index ? const Color(0xFF8E0006) : null,
            ),
            onSelected: (_) => onSelected(index),
          );
        },
      ),
    );
  }
}

class _PaletteAction extends StatelessWidget {
  const _PaletteAction({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onTap,
    this.selected = false,
  });
  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 62,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(10),
          child: Opacity(
            opacity: enabled ? 1 : .38,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: selected ? const Color(0xFFFFDDD9) : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon,
                        color: selected ? const Color(0xFFBA0007) : null),
                    const SizedBox(height: 2),
                    Text(label,
                        style: TextStyle(
                          fontSize: 10,
                          color: selected ? const Color(0xFF8E0006) : null,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.normal,
                        )),
                  ]),
            ),
          ),
        ),
      );
}

class _PaletteTextAction extends StatelessWidget {
  const _PaletteTextAction({
    required this.text,
    required this.label,
    required this.enabled,
    required this.onTap,
    this.selected = false,
  });
  final String text;
  final String label;
  final bool enabled;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 52,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(10),
          child: Opacity(
            opacity: enabled ? 1 : .38,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: selected ? const Color(0xFFFFDDD9) : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(text,
                        style: TextStyle(
                          fontSize: 23,
                          height: 1,
                          color: selected ? const Color(0xFFBA0007) : null,
                        )),
                    const SizedBox(height: 3),
                    Text(label,
                        style: TextStyle(
                          fontSize: 10,
                          color: selected ? const Color(0xFF8E0006) : null,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.normal,
                        )),
                  ]),
            ),
          ),
        ),
      );
}

class _NoteTools extends StatefulWidget {
  const _NoteTools({required this.note, required this.onPreview});
  final _ScoreNote note;
  final ValueChanged<_ScoreNote> onPreview;
  @override
  State<_NoteTools> createState() => _NoteToolsState();
}

class _NoteToolsState extends State<_NoteTools> {
  late String _step = widget.note.step,
      _type = widget.note.type,
      _tie = widget.note.tie;
  late int _alter = widget.note.alter,
      _octave = widget.note.octave,
      _duration = widget.note.duration;
  late bool _dotted = widget.note.dotted;
  late bool _isRest = widget.note.isRest;

  void _audition() {
    if (_isRest) return;
    widget.onPreview(widget.note.copyWith(
      step: _step,
      alter: _alter,
      octave: _octave,
      type: _type,
      duration: _duration,
      dotted: _dotted,
      tie: _tie,
      isRest: false,
    ));
  }

  void _transposeSemitone(int delta) {
    const naturalSemitones = {
      'C': 0,
      'D': 2,
      'E': 4,
      'F': 5,
      'G': 7,
      'A': 9,
      'B': 11
    };
    const sharpNames = [
      ('C', 0),
      ('C', 1),
      ('D', 0),
      ('D', 1),
      ('E', 0),
      ('F', 0),
      ('F', 1),
      ('G', 0),
      ('G', 1),
      ('A', 0),
      ('A', 1),
      ('B', 0),
    ];
    final current = _octave * 12 + naturalSemitones[_step]! + _alter;
    final target = (current + delta).clamp(0, 8 * 12 + 11).toInt();
    setState(() {
      _octave = target ~/ 12;
      final spelling = sharpNames[target % 12];
      _step = spelling.$1;
      _alter = spelling.$2;
    });
    _audition();
  }

  @override
  Widget build(BuildContext context) => Material(
      color: const Color(0xFFFFFAF8),
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: SafeArea(
          child: SingleChildScrollView(
              child: Padding(
        padding: EdgeInsets.fromLTRB(
            20, 20, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_isRest ? 'Edit rest' : 'Edit ${widget.note.label}',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          if (_isRest)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  setState(() => _isRest = false);
                  _audition();
                },
                icon: const Icon(Icons.edit_note_rounded),
                label: const Text('Write a note in this rest slot'),
              ),
            )
          else ...[
            Row(children: [
              _drop('Pitch', _step, 'CDEFGAB'.split(''), (v) {
                setState(() => _step = v!);
                _audition();
              }),
              const SizedBox(width: 10),
              _drop('Accidental', _alter, const [-2, -1, 0, 1, 2], (v) {
                setState(() => _alter = v!);
                _audition();
              },
                  label: (v) =>
                      const {-2: '𝄫', -1: '♭', 0: '♮', 1: '♯', 2: '𝄪'}[v]!),
              const SizedBox(width: 10),
              _drop('Octave', _octave, List.generate(9, (i) => i), (v) {
                setState(() => _octave = v!);
                _audition();
              })
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _transposeSemitone(-1),
                  icon: const Icon(Icons.arrow_downward_rounded),
                  label: const Text('Down'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _transposeSemitone(1),
                  icon: const Icon(Icons.arrow_upward_rounded),
                  label: const Text('Up'),
                ),
              ),
            ]),
          ],
          const SizedBox(height: 12),
          Row(children: [
            _drop('Length', _type, const [
              'whole',
              'half',
              'quarter',
              'eighth',
              '16th',
              '32nd'
            ], (v) {
              setState(() => _type = v!);
              _audition();
            }),
            const SizedBox(width: 10),
            Expanded(
                child: TextFormField(
                    initialValue: '$_duration',
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Duration'),
                    onChanged: (v) => _duration = int.tryParse(v) ?? _duration))
          ]),
          const SizedBox(height: 6),
          Text(
            'Pitch and rest edits preserve this event’s rhythm slot. Changing length changes the written rhythm in this measure.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          Row(children: [
            Expanded(
                child: SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Dotted'),
                    value: _dotted,
                    onChanged: (v) => setState(() => _dotted = v))),
            const SizedBox(width: 10),
            _drop('Tie', _tie, const ['none', 'start', 'stop'],
                (v) => setState(() => _tie = v!),
                label: (v) => v == 'none'
                    ? 'No tie'
                    : '${v[0].toUpperCase()}${v.substring(1)} tie')
          ]),
          const SizedBox(height: 12),
          SizedBox(
              width: double.infinity,
              child: FilledButton(
                  onPressed: () => Navigator.pop(
                      context,
                      widget.note.copyWith(
                          step: _step,
                          alter: _alter,
                          octave: _octave,
                          type: _type,
                          duration: _duration,
                          dotted: _dotted,
                          tie: _isRest ? 'none' : _tie,
                          isRest: _isRest)),
                  child: const Text('Apply changes'))),
        ]),
      ))));

  Expanded _drop<T>(
          String title, T value, List<T> values, ValueChanged<T?> onChanged,
          {String Function(T)? label}) =>
      Expanded(
          child: DropdownButtonFormField<T>(
              initialValue: value,
              isExpanded: true,
              decoration: InputDecoration(labelText: title),
              items: values
                  .map((v) => DropdownMenuItem(
                      value: v,
                      child: Text(label?.call(v) ?? '$v',
                          overflow: TextOverflow.ellipsis)))
                  .toList(),
              onChanged: onChanged));
}

class _EditorSnapshot {
  const _EditorSnapshot({
    required this.notes,
    required this.selected,
    required this.selectedMeasure,
  });

  final List<_ScoreNote> notes;
  final int? selected;
  final int? selectedMeasure;
}

class _ScoreNote {
  const _ScoreNote(
      {required this.start,
      required this.end,
      required this.source,
      required this.measure,
      required this.step,
      required this.alter,
      required this.octave,
      required this.duration,
      required this.type,
      required this.dotted,
      required this.tie,
      required this.timeKey,
      required this.isRest});
  final int start, end, measure, alter, octave, duration;
  final String source, step, type, tie, timeKey;
  final bool dotted, isRest;
  String get label => isRest
      ? 'Rest'
      : '$step${alter == 2 ? '𝄪' : alter == 1 ? '♯' : alter == -1 ? '♭' : alter == -2 ? '𝄫' : ''}$octave';
  String get previewPitch =>
      '$step${alter == 2 ? '##' : alter == 1 ? '#' : alter == -1 ? 'b' : alter == -2 ? 'bb' : ''}$octave';
  _ScoreNote copyWith(
          {required String step,
          required int alter,
          required int octave,
          required String type,
          required int duration,
          required bool dotted,
          required String tie,
          bool? isRest}) =>
      _ScoreNote(
          start: start,
          end: end,
          source: source,
          measure: measure,
          step: step,
          alter: alter,
          octave: octave,
          duration: duration,
          type: type,
          dotted: dotted,
          tie: tie,
          timeKey: timeKey,
          isRest: isRest ?? this.isRest);
  static List<_ScoreNote> parse(String xml) {
    final out = <_ScoreNote>[];
    final token = RegExp(
            r'<part\b[^>]*>|</part>|<measure\b[^>]*>|<backup\b[^>]*>[\s\S]*?</backup>|<forward\b[^>]*>[\s\S]*?</forward>|<note\b[^>]*>[\s\S]*?</note>',
            caseSensitive: false),
        step = RegExp(r'<step>\s*([A-G])\s*</step>', caseSensitive: false),
        oct = RegExp(r'<octave>\s*([0-8])\s*</octave>', caseSensitive: false),
        alter = RegExp(r'<alter>\s*(-?\d+)\s*</alter>', caseSensitive: false),
        duration =
            RegExp(r'<duration>\s*(\d+)\s*</duration>', caseSensitive: false),
        type = RegExp(r'<type>\s*([\w]+)\s*</type>', caseSensitive: false);
    var measure = 0;
    var cursor = 0;
    var previousChordStart = 0;
    for (final m in token.allMatches(xml)) {
      final source = m.group(0)!;
      if (RegExp(r'^<part\b', caseSensitive: false).hasMatch(source)) {
        measure = 0;
        cursor = 0;
        previousChordStart = 0;
        continue;
      }
      if (RegExp(r'^<measure\b', caseSensitive: false).hasMatch(source)) {
        measure++;
        cursor = 0;
        previousChordStart = 0;
        continue;
      }
      final movement = int.tryParse(
              RegExp(r'<duration>\s*(\d+)\s*</duration>', caseSensitive: false)
                      .firstMatch(source)
                      ?.group(1) ??
                  '') ??
          0;
      if (RegExp(r'^<backup\b', caseSensitive: false).hasMatch(source)) {
        cursor = (cursor - movement).clamp(0, 1 << 30);
        continue;
      }
      if (RegExp(r'^<forward\b', caseSensitive: false).hasMatch(source)) {
        cursor += movement;
        continue;
      }
      if (!RegExp(r'^<note\b', caseSensitive: false).hasMatch(source)) {
        continue;
      }
      final isRest =
          RegExp(r'<rest\s*/?>', caseSensitive: false).hasMatch(source);
      final isChord =
          RegExp(r'<chord\s*/?>', caseSensitive: false).hasMatch(source);
      final value = step.firstMatch(source)?.group(1)?.toUpperCase(),
          octave = int.tryParse(oct.firstMatch(source)?.group(1) ?? '');
      if (!isRest && (value == null || octave == null)) continue;
      final onset = isChord ? previousChordStart : cursor;
      if (!isChord) previousChordStart = onset;
      out.add(_ScoreNote(
          start: m.start,
          end: m.end,
          source: source,
          measure: measure == 0 ? 1 : measure,
          step: value ?? 'C',
          alter: int.tryParse(alter.firstMatch(source)?.group(1) ?? '') ?? 0,
          octave: octave ?? 4,
          duration:
              int.tryParse(duration.firstMatch(source)?.group(1) ?? '') ?? 1,
          type: type.firstMatch(source)?.group(1) ?? 'quarter',
          dotted: RegExp(r'<dot\s*/?>', caseSensitive: false).hasMatch(source),
          tie: RegExp(r'<tie\s+type="(start|stop)"\s*/?>', caseSensitive: false)
                  .firstMatch(source)
                  ?.group(1) ??
              'none',
          timeKey: '$measure:$onset',
          isRest: isRest));
      if (!isChord) cursor += movement;
    }
    return out;
  }

  static String apply(String xml, List<_ScoreNote> notes) {
    var out = xml;
    for (final n in notes.reversed) {
      var s = n.source;
      final pitchElement =
          RegExp(r'<pitch\b[^>]*>[\s\S]*?</pitch>', caseSensitive: false);
      final restElement = RegExp(r'<rest\s*/?>', caseSensitive: false);
      if (n.isRest) {
        s = s.replaceFirst(pitchElement, '<rest/>');
        s = s.replaceAll(
            RegExp(r'<accidental>\s*[^<]+\s*</accidental>',
                caseSensitive: false),
            '');
      } else if (restElement.hasMatch(s)) {
        s = s.replaceFirst(restElement,
            '<pitch><step>${n.step}</step>${n.alter == 0 ? '' : '<alter>${n.alter}</alter>'}<octave>${n.octave}</octave></pitch>');
      }
      if (!n.isRest) {
        s = s
            .replaceFirst(
                RegExp(r'<step>\s*[A-G]\s*</step>', caseSensitive: false),
                '<step>${n.step}</step>')
            .replaceFirst(
                RegExp(r'<octave>\s*[0-8]\s*</octave>', caseSensitive: false),
                '<octave>${n.octave}</octave>');
      }
      s = s
          .replaceFirst(
              RegExp(r'<duration>\s*\d+\s*</duration>', caseSensitive: false),
              '<duration>${n.duration}</duration>')
          .replaceFirst(
              RegExp(r'<type>\s*[\w]+\s*</type>', caseSensitive: false),
              '<type>${n.type}</type>');
      final alter = RegExp(r'<alter>\s*-?\d+\s*</alter>', caseSensitive: false);
      if (n.isRest || n.alter == 0) {
        s = s.replaceFirst(alter, '');
      } else if (alter.hasMatch(s)) {
        s = s.replaceFirst(alter, '<alter>${n.alter}</alter>');
      } else {
        s = s.replaceFirst('</step>', '</step><alter>${n.alter}</alter>');
      }
      final dot = RegExp(r'<dot\s*/?>', caseSensitive: false);
      if (n.dotted && !dot.hasMatch(s)) {
        s = s.replaceFirst('</type>', '</type><dot/>');
      } else if (!n.dotted) {
        s = s.replaceFirst(dot, '');
      }
      final tie =
          RegExp(r'<tie\s+type="(?:start|stop)"\s*/?>', caseSensitive: false);
      if (n.isRest || n.tie == 'none') {
        s = s.replaceAll(tie, '');
      } else if (tie.hasMatch(s)) {
        s = s.replaceFirst(tie, '<tie type="${n.tie}"/>');
      } else {
        s = s.replaceFirst('</note>', '<tie type="${n.tie}"/></note>');
      }
      out = out.replaceRange(n.start, n.end, s);
    }
    return out;
  }
}
