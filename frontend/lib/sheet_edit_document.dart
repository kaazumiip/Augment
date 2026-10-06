import 'package:xml/xml.dart';

/// Edits the selected XML element, preserving all other voices and score metadata.
class SheetEditDocument {
  SheetEditDocument(String xml) : document = XmlDocument.parse(xml) {
    _index();
  }
  final XmlDocument document;
  final List<SheetEditNote> notes = [];
  String get xml => document.toXmlString();

  void _index() {
    var partIndex = 0;
    for (final part in document.rootElement.findElements('part')) {
      var divisions = 1;
      var bar = 0;
      for (final measure in part.findElements('measure')) {
        var cursor = 0;
        var chordStart = 0;
        bar++;
        for (final e in measure.childElements) {
          if (e.name.local == 'attributes') {
            divisions =
                int.tryParse(e.getElement('divisions')?.innerText ?? '') ??
                    divisions;
          }
          final duration =
              int.tryParse(e.getElement('duration')?.innerText ?? '') ?? 0;
          if (e.name.local == 'backup') cursor -= duration;
          if (e.name.local == 'forward') cursor += duration;
          if (e.name.local != 'note') continue;
          final chord = e.getElement('chord') != null;
          final onset = chord ? chordStart : cursor;
          if (!chord) {
            chordStart = onset;
            cursor += duration;
          }
          // Keep percussion/grace notes in the score, but don't expose unsafe edits.
          notes.add(
              SheetEditNote(e, notes.length, partIndex, bar, onset, divisions));
        }
      }
      partIndex++;
    }
  }

  void pitch(int index, int midi) {
    final n = notes[index];
    if (n.locked) {
      throw StateError(
          'Connected or grace notes cannot be changed individually.');
    }
    if (midi < 12 || midi > 119) {
      throw StateError('Choose a note between C0 and B8.');
    }
    const steps = ['C', 'C', 'D', 'D', 'E', 'F', 'F', 'G', 'G', 'A', 'A', 'B'];
    const alters = [0, 1, 0, 1, 0, 0, 1, 0, 1, 0, 1, 0];
    final pitch = XmlElement(XmlName('pitch'), [], [
      _value('step', steps[midi % 12]),
      if (alters[midi % 12] != 0) _value('alter', '${alters[midi % 12]}'),
      _value('octave', '${midi ~/ 12 - 1}'),
    ]);
    final old = n.element.getElement('pitch') ?? n.element.getElement('rest');
    if (old == null) throw StateError('This note cannot be edited.');
    n.element.children[n.element.children.indexOf(old)] = pitch;
    n.element.children
        .removeWhere((e) => e is XmlElement && e.name.local == 'accidental');
  }

  void silence(int index) {
    final n = notes[index];
    if (n.locked || n.isTied || n.inChord(notes)) {
      throw StateError('This connected note or chord must stay together.');
    }
    final pitch = n.element.getElement('pitch');
    if (pitch == null) return;
    n.element.children[n.element.children.indexOf(pitch)] =
        XmlElement(XmlName('rest'));
    n.element.children.removeWhere((e) =>
        e is XmlElement &&
        ['accidental', 'stem', 'beam'].contains(e.name.local));
  }

  /// Shortening inserts silence; lengthening consumes only immediately following
  /// plain rests in the same voice. Every later onset and total bar length stay fixed.
  void length(int index, String type) {
    final n = notes[index];
    if (n.locked ||
        n.isTied ||
        n.inChord(notes) ||
        n.element.getElement('time-modification') != null ||
        n.isRest) {
      throw StateError('Choose a single, untied note to change its length.');
    }
    final targetValue = (beats[type] ?? 0) * n.divisions;
    if (targetValue < 1 || targetValue != targetValue.roundToDouble()) {
      throw StateError('This length is too small for this score.');
    }
    final target = targetValue.toInt();
    final difference = target - n.duration;
    if (difference == 0) return;
    final parent = n.element.parentElement!;
    final rests = <SheetEditNote>[];
    var available = 0;
    if (difference > 0) {
      var next = n.element.nextElementSibling;
      while (next != null && available < difference) {
        final matches = notes.where((e) => identical(e.element, next));
        if (matches.isEmpty) break;
        final rest = matches.first;
        if (!rest.isRest ||
            rest.locked ||
            rest.voice != n.voice ||
            rest.staff != n.staff ||
            rest.element.getElement('time-modification') != null ||
            rest.inChord(notes)) {
          break;
        }
        // Do not erase annotations attached to a rest.
        if (rest.element.childElements.any((e) => ![
              'rest',
              'duration',
              'voice',
              'type',
              'dot',
              'staff'
            ].contains(e.name.local))) {
          break;
        }
        rests.add(rest);
        available += rest.duration;
        next = next.nextElementSibling;
      }
      if (available < difference) {
        throw StateError(
            'There is another note in the way. A longer note needs silence after it.');
      }
    }
    final remainder = difference < 0 ? -difference : available - difference;
    final replacementRests =
        _rests(n, remainder); // Validate before changing XML.
    _setValue(n.element, 'duration', '$target');
    _setValue(n.element, 'type', type);
    n.element.children.removeWhere(
        (e) => e is XmlElement && ['dot', 'beam'].contains(e.name.local));
    for (final r in rests) {
      parent.children.remove(r.element);
    }
    parent.children
        .insertAll(parent.children.indexOf(n.element) + 1, replacementRests);
  }

  void setAccidental(int index, int alter) {
    final n = notes[index];
    if (n.isRest || n.locked) return;
    final pitch = n.element.getElement('pitch');
    if (pitch == null) return;
    final alterEl = pitch.getElement('alter');
    if (alter == 0) {
      if (alterEl != null) pitch.children.remove(alterEl);
    } else {
      if (alterEl != null) {
        alterEl.innerText = '$alter';
      } else {
        pitch.children.add(_value('alter', '$alter'));
      }
    }
    n.element.children
        .removeWhere((e) => e is XmlElement && e.name.local == 'accidental');
    const accidentalNames = {
      -2: 'flat-flat',
      -1: 'flat',
      0: 'natural',
      1: 'sharp',
      2: 'double-sharp',
    };
    final accName = accidentalNames[alter];
    if (accName != null) {
      final pitchIdx = n.element.children.indexOf(pitch);
      n.element.children.insert(pitchIdx + 1, _value('accidental', accName));
    }
  }

  void toggleArticulation(int index, String name) {
    final n = notes[index];
    if (n.isRest || n.locked) return;
    var notations = n.element.getElement('notations');
    if (notations == null) {
      notations = XmlElement(XmlName('notations'));
      n.element.children.add(notations);
    }
    var articulations = notations.getElement('articulations');
    if (articulations == null) {
      articulations = XmlElement(XmlName('articulations'));
      notations.children.add(articulations);
    }
    final existing = articulations.getElement(name);
    if (existing != null) {
      articulations.children.remove(existing);
      if (articulations.children.isEmpty) {
        notations.children.remove(articulations);
      }
      if (notations.children.isEmpty) {
        n.element.children.remove(notations);
      }
    } else {
      articulations.children.add(XmlElement(XmlName(name)));
    }
  }

  void toggleTie(int index) {
    final n = notes[index];
    if (n.isRest) return;
    final existingTie = n.element.getElement('tie');
    if (existingTie != null) {
      n.element.children
          .removeWhere((e) => e is XmlElement && e.name.local == 'tie');
      final notations = n.element.getElement('notations');
      if (notations != null) {
        notations.children
            .removeWhere((e) => e is XmlElement && e.name.local == 'tied');
        if (notations.children.isEmpty) n.element.children.remove(notations);
      }
    } else {
      n.element.children.add(XmlElement(
          XmlName('tie'), [XmlAttribute(XmlName('type'), 'start')]));
      var notations = n.element.getElement('notations');
      if (notations == null) {
        notations = XmlElement(XmlName('notations'));
        n.element.children.add(notations);
      }
      notations.children.add(XmlElement(
          XmlName('tied'), [XmlAttribute(XmlName('type'), 'start')]));
    }
  }

  void toggleDot(int index) {
    final n = notes[index];
    if (n.isRest || n.locked) return;
    if (n.hasDot) {
      final dot = n.element.getElement('dot');
      if (dot != null) n.element.children.remove(dot);
      final prevDur = n.duration;
      final newDur = (prevDur * 2) ~/ 3;
      final diff = prevDur - newDur;
      _setValue(n.element, 'duration', '$newDur');
      final nextEl = n.element.nextElementSibling;
      if (nextEl != null && nextEl.getElement('rest') != null) {
        final restDur =
            int.tryParse(nextEl.getElement('duration')?.innerText ?? '') ?? 0;
        _setValue(nextEl, 'duration', '${restDur + diff}');
      } else {
        final parent = n.element.parentElement!;
        final restElements = _rests(n, diff);
        final idx = parent.children.indexOf(n.element);
        parent.children.insertAll(idx + 1, restElements);
      }
    } else {
      final diff = n.duration ~/ 2;
      final nextEl = n.element.nextElementSibling;
      if (nextEl != null && nextEl.getElement('rest') != null) {
        final restDur =
            int.tryParse(nextEl.getElement('duration')?.innerText ?? '') ?? 0;
        if (restDur < diff) {
          throw StateError('Not enough rest duration to add dot.');
        }
        if (restDur == diff) {
          nextEl.parentElement?.children.remove(nextEl);
        } else {
          _setValue(nextEl, 'duration', '${restDur - diff}');
        }
        _setValue(n.element, 'duration', '${n.duration + diff}');
        final typeEl = n.element.getElement('type');
        final dotEl = XmlElement(XmlName('dot'));
        if (typeEl != null) {
          final idx = n.element.children.indexOf(typeEl);
          n.element.children.insert(idx + 1, dotEl);
        } else {
          n.element.children.add(dotEl);
        }
      } else {
        throw StateError('Cannot add dot without trailing rest.');
      }
    }
  }

  static const beats = {
    'whole': 4.0,
    'half': 2.0,
    'quarter': 1.0,
    'eighth': .5,
    '16th': .25,
    '32nd': .125
  };
  static List<XmlElement> _rests(SheetEditNote n, int units) {
    final result = <XmlElement>[];
    for (final entry in beats.entries) {
      final exact = entry.value * n.divisions;
      if (exact != exact.roundToDouble() || exact < 1) continue;
      final value = exact.toInt();
      while (units >= value) {
        result.add(XmlElement(XmlName('note'), [], [
          XmlElement(XmlName('rest')),
          _value('duration', '$value'),
          _value('voice', n.voice),
          _value('type', entry.key),
          _value('staff', n.staff)
        ]));
        units -= value;
      }
    }
    if (units != 0) {
      throw StateError('This rhythm needs a more advanced length edit.');
    }
    return result;
  }

  /// A standalone bar with inherited clefs, key, divisions, meter and tempo.
  /// All parts are retained, so the user hears the accompaniment too.
  String barXml(int bar) {
    final copy = XmlDocument.parse(xml);
    for (final part in copy.rootElement.findElements('part')) {
      final measures = part.findElements('measure').toList();
      if (bar < 1 || bar > measures.length) continue;
      final selected = measures[bar - 1];
      final attributes = <String, XmlElement>{};
      XmlElement? tempo;
      for (final measure in measures.take(bar)) {
        for (final a in measure.findElements('attributes')) {
          for (final child in a.childElements) {
            attributes[
                    '${child.name.local}:${child.getAttribute('number') ?? ''}'] =
                child.copy();
          }
        }
        for (final d in measure.findElements('direction')) {
          if (d.descendants.whereType<XmlElement>().any((e) =>
              e.name.local == 'sound' && e.getAttribute('tempo') != null)) {
            tempo = d.copy();
          }
        }
      }
      selected.children.removeWhere((e) =>
          e is XmlElement &&
          ['attributes', 'barline', 'print'].contains(e.name.local));
      selected.children
          .insert(0, XmlElement(XmlName('attributes'), [], attributes.values));
      if (tempo != null &&
          !selected.findElements('direction').any((d) => d.descendants
              .whereType<XmlElement>()
              .any((e) =>
                  e.name.local == 'sound' &&
                  e.getAttribute('tempo') != null))) {
        selected.children.insert(1, tempo);
      }
      for (final measure in measures) {
        if (!identical(measure, selected)) part.children.remove(measure);
      }
      // At an excerpt boundary, tied continuations must be audible on their own.
      for (final note in selected.findElements('note')) {
        note.children
            .removeWhere((e) => e is XmlElement && e.name.local == 'tie');
        for (final notation in note.findElements('notations')) {
          notation.children
              .removeWhere((e) => e is XmlElement && e.name.local == 'tied');
        }
      }
    }
    return copy.toXmlString();
  }

  static XmlElement _value(String name, String value) =>
      XmlElement(XmlName(name), [], [XmlText(value)]);
  static void _setValue(XmlElement element, String name, String value) {
    final existing = element.getElement(name);
    if (existing != null) {
      existing.innerText = value;
    } else {
      element.children.add(_value(name, value));
    }
  }
}

class SheetEditNote {
  SheetEditNote(this.element, this.index, this.part, this.bar, this.onset,
      this.divisions);
  final XmlElement element;
  final int index, part, bar, onset, divisions;
  int get duration =>
      int.tryParse(element.getElement('duration')?.innerText ?? '') ?? 0;
  String get voice => element.getElement('voice')?.innerText ?? '1';
  String get staff => element.getElement('staff')?.innerText ?? '1';
  bool get isRest => element.getElement('rest') != null;
  bool get locked =>
      duration == 0 ||
      element.getElement('grace') != null ||
      element.getElement('unpitched') != null;
  bool inChord(List<SheetEditNote> notes) =>
      element.getElement('chord') != null ||
      notes.any((n) =>
          n.index != index &&
          n.part == part &&
          n.bar == bar &&
          n.onset == onset &&
          n.voice == voice &&
          n.staff == staff &&
          n.element.getElement('chord') != null);
  int get midi {
    final p = element.getElement('pitch');
    const natural = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11};
    return 12 *
            ((int.tryParse(p?.getElement('octave')?.innerText ?? '') ?? 4) +
                1) +
        (natural[p?.getElement('step')?.innerText] ?? 0) +
        (int.tryParse(p?.getElement('alter')?.innerText ?? '') ?? 0);
  }

  String get type => element.getElement('type')?.innerText ?? 'quarter';
  bool get hasDot => element.getElement('dot') != null;
  int get alter {
    final p = element.getElement('pitch');
    return int.tryParse(p?.getElement('alter')?.innerText ?? '') ?? 0;
  }
  bool hasArticulation(String name) =>
      element.findElements('notations').any((n) =>
          n.findElements('articulations').any((a) => a.getElement(name) != null));
  bool get isTied =>
      element.getElement('tie') != null ||
      element.findAllElements('tied').isNotEmpty;

  String get label => isRest
      ? 'Rest'
      : '${[
          'C',
          'C♯',
          'D',
          'E♭',
          'E',
          'F',
          'F♯',
          'G',
          'A♭',
          'A',
          'B♭',
          'B'
        ][midi % 12]}${midi ~/ 12 - 1}';
  double get beatLength => duration / divisions;
  Map<String, dynamic> get selectionData => {
        'index': index,
        'part': part,
        'bar': bar - 1,
        'onset': onset / divisions / 4,
        'staff': int.tryParse(staff) ?? 1,
        'voice': voice,
        'midi': isRest ? null : midi
      };
}
