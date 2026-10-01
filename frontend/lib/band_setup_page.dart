import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'band_part.dart';
import 'generation_started_page.dart';

class BandSetupPage extends StatefulWidget {
  const BandSetupPage({
    super.key,
    required this.source,
    this.fileUrl,
    this.filePath,
  });

  final String source;
  final String? fileUrl;
  final String? filePath;

  @override
  State<BandSetupPage> createState() => _BandSetupPageState();
}

class _BandSetupPageState extends State<BandSetupPage> {
  static const _red = Color(0xFFBA0007);
  static const _instruments = [
    'Violin',
    'Guitar',
    'Electric Guitar',
    'Cello',
    'Ukulele',
    'Piano',
    'Saxophone',
    'Flute',
    'Drums',
  ];
  static const _presets = {
    'Rock': [
      ('Electric Guitar', 'melody'),
      ('Guitar', 'harmony'),
      ('Cello', 'bass'),
      ('Drums', 'drums'),
    ],
    'Jazz': [
      ('Saxophone', 'melody'),
      ('Piano', 'harmony'),
      ('Cello', 'bass'),
      ('Drums', 'drums'),
    ],
    'Classical': [
      ('Violin', 'melody'),
      ('Flute', 'harmony'),
      ('Cello', 'bass'),
      ('Piano', 'harmony'),
    ],
    'Acoustic': [
      ('Violin', 'melody'),
      ('Guitar', 'harmony'),
      ('Cello', 'bass'),
    ],
  };

  String _selectedPreset = 'Rock';
  List<BandPart> _parts = const [];
  int _nextId = 0;
  bool _continuing = false;

  @override
  void initState() {
    super.initState();
    _applyPreset('Rock', notify: false);
  }

  void _applyPreset(String name, {bool notify = true}) {
    final values = _presets[name]!;
    final parts = values
        .map((value) => BandPart(
              id: 'part_${_nextId++}',
              instrument: value.$1,
              role: value.$2,
            ))
        .toList();
    if (notify) {
      setState(() {
        _selectedPreset = name;
        _parts = parts;
      });
    } else {
      _selectedPreset = name;
      _parts = parts;
    }
  }

  void _updatePart(int index, BandPart value) {
    final normalized = value.normalizedForInstrument();
    setState(() {
      _selectedPreset = 'Custom';
      _parts = [..._parts]..[index] = normalized;
    });
  }

  void _addPart() {
    if (_parts.length >= 4) return;
    setState(() {
      _selectedPreset = 'Custom';
      _parts = [
        ..._parts,
        BandPart(
          id: 'part_${_nextId++}',
          instrument: 'Piano',
          role: 'harmony',
        ),
      ];
    });
  }

  void _removePart(int index) {
    if (_parts.length <= 2) return;
    setState(() {
      _selectedPreset = 'Custom';
      _parts = [..._parts]..removeAt(index);
    });
  }

  Future<void> _continue() async {
    if (_continuing || _parts.length < 2 || _parts.length > 4) return;
    setState(() => _continuing = true);
    try {
      String? filePath = widget.filePath;
      if (filePath == null &&
          !(widget.source == 'link' && widget.fileUrl != null)) {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: const [
            'mp3',
            'wav',
            'm4a',
            'flac',
            'ogg',
            'mp4',
            'mov',
            'mkv',
            'webm',
            'avi',
            '3gp',
          ],
        );
        if (result == null) return;
        filePath = result.files.single.path;
      }
      if (!mounted) return;
      final submittedParts = _parts
          .asMap()
          .entries
          .map((entry) =>
              entry.value.copyWith(displayName: _displayName(entry.key)))
          .toList(growable: false);
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => GenerationStartedPage(
            instrumentName: 'Band',
            mode: 'band',
            bandParts: List.unmodifiable(submittedParts),
            source: widget.source,
            fileUrl: widget.fileUrl,
            filePath: filePath,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _continuing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppPalette.page(context),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: AppPalette.text(context),
          elevation: 0,
          titleSpacing: 4,
          title: const Text('Band mode',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
            children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: _red.withValues(alpha: .1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.graphic_eq_rounded,
                      color: _red, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Build your band',
                          style: TextStyle(
                              color: AppPalette.text(context),
                              fontSize: 24,
                              height: 1.2,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 5),
                      Text('Choose 2–4 instruments and assign their roles.',
                          style: TextStyle(
                              color: AppPalette.muted(context), fontSize: 14)),
                    ],
                  ),
                ),
              ]),
              const SizedBox(height: 24),
              Text('Choose a sound',
                  style: TextStyle(
                      color: AppPalette.text(context),
                      fontSize: 18,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 3),
              Text('Start with a preset, then make it yours.',
                  style: TextStyle(
                      color: AppPalette.muted(context), fontSize: 14)),
              const SizedBox(height: 13),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ..._presets.keys.map((name) => ChoiceChip(
                        label: Text(name),
                        selected: _selectedPreset == name,
                        selectedColor: _red,
                        backgroundColor: AppPalette.surface(context),
                        side: BorderSide(
                          color: _selectedPreset == name
                              ? _red
                              : AppPalette.border(context),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 7),
                        labelStyle: TextStyle(
                            color: _selectedPreset == name
                                ? Colors.white
                                : AppPalette.text(context),
                            fontWeight: FontWeight.w700),
                        onSelected: (_) => _applyPreset(name),
                      )),
                  if (_selectedPreset == 'Custom')
                    const ChoiceChip(
                      label: Text('Custom'),
                      selected: true,
                      selectedColor: _red,
                      labelStyle: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w700),
                    ),
                ],
              ),
              const SizedBox(height: 24),
              Row(children: [
                Expanded(
                  child: Text('Your lineup',
                      style: TextStyle(
                          color: AppPalette.text(context),
                          fontSize: 18,
                          fontWeight: FontWeight.w600)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                    color: _red.withValues(alpha: .1),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text('${_parts.length} OF 4',
                      style: const TextStyle(
                          color: _red,
                          fontSize: 12,
                          letterSpacing: .5,
                          fontWeight: FontWeight.w500)),
                ),
              ]),
              const SizedBox(height: 5),
              Text('Assign a musical role to every player.',
                  style: TextStyle(
                      color: AppPalette.muted(context), fontSize: 14)),
              const SizedBox(height: 12),
              ..._parts.asMap().entries.map((entry) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _BandPartCard(
                      key: ValueKey(entry.value.id),
                      number: entry.key + 1,
                      part: entry.value,
                      instruments: _instruments,
                      roles:
                          BandPart.rolesForInstrument(entry.value.instrument),
                      displayName: _displayName(entry.key),
                      canRemove: _parts.length > 2,
                      onChanged: (value) => _updatePart(entry.key, value),
                      onRemove: () => _removePart(entry.key),
                    ),
                  )),
              if (_parts.length < 4)
                SizedBox(
                  height: 50,
                  child: OutlinedButton.icon(
                    onPressed: _addPart,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _red,
                      side: BorderSide(
                          color: _red.withValues(alpha: .55), width: 1.4),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    icon:
                        const Icon(Icons.add_circle_outline_rounded, size: 20),
                    label: const Text('Add instrument',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                  ),
                ),
              const SizedBox(height: 9),
              Center(
                child: Text('Use 2-4 instruments · Roles may repeat',
                    style: TextStyle(
                        color: AppPalette.muted(context), fontSize: 14)),
              ),
            ],
          ),
        ),
        bottomNavigationBar: Container(
          decoration: BoxDecoration(
            color: AppPalette.page(context),
            border: Border(
              top: BorderSide(
                  color: AppPalette.border(context).withValues(alpha: .55)),
            ),
          ),
          child: SafeArea(
            minimum: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: FilledButton(
              onPressed: _continuing ? null : _continue,
              style: FilledButton.styleFrom(
                backgroundColor: _red,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(54),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15)),
              ),
              child:
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (_continuing)
                  const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                else
                  const Icon(Icons.auto_awesome_rounded, size: 19),
                const SizedBox(width: 9),
                Text(
                    _continuing
                        ? 'Preparing your band...'
                        : 'Generate band score',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
                if (!_continuing) ...[
                  const SizedBox(width: 9),
                  const Icon(Icons.arrow_forward_rounded, size: 18),
                ],
              ]),
            ),
          ),
        ),
      );

  String _displayName(int index) {
    final instrument = _parts[index].instrument;
    final matches = _parts
        .take(index + 1)
        .where((part) => part.instrument == instrument)
        .length;
    final total = _parts.where((part) => part.instrument == instrument).length;
    return total > 1 ? '$instrument $matches' : instrument;
  }
}

class _BandPartCard extends StatelessWidget {
  const _BandPartCard({
    super.key,
    required this.number,
    required this.part,
    required this.instruments,
    required this.roles,
    required this.displayName,
    required this.canRemove,
    required this.onChanged,
    required this.onRemove,
  });

  final int number;
  final BandPart part;
  final List<String> instruments;
  final List<String> roles;
  final String displayName;
  final bool canRemove;
  final ValueChanged<BandPart> onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppPalette.border(context)),
        ),
        child: Row(children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _roleColor(part.role).withValues(alpha: .11),
              shape: BoxShape.circle,
            ),
            child: Text('$number',
                style: TextStyle(
                    color: _roleColor(part.role),
                    fontSize: 12,
                    fontWeight: FontWeight.w500)),
          ),
          const SizedBox(width: 9),
          Expanded(
            flex: 6,
            child: DropdownButtonFormField<String>(
              key: ValueKey('instrument-${part.id}-${part.instrument}'),
              initialValue: part.instrument,
              style: TextStyle(
                  color: AppPalette.text(context),
                  fontSize: 16,
                  fontWeight: FontWeight.w600),
              isExpanded: true,
              decoration: _fieldDecoration(context, 'Instrument'),
              items: instruments
                  .map((value) => DropdownMenuItem(
                      value: value,
                      child: Text(value,
                          maxLines: 1, overflow: TextOverflow.ellipsis)))
                  .toList(),
              onChanged: (value) {
                if (value != null) {
                  onChanged(part.copyWith(instrument: value));
                }
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 4,
            child: DropdownButtonFormField<String>(
              key: ValueKey('role-${part.id}-${part.role}'),
              initialValue: part.role,
              style: TextStyle(
                  color: AppPalette.text(context),
                  fontSize: 14,
                  fontWeight: FontWeight.w500),
              isExpanded: true,
              decoration: _fieldDecoration(context, 'Role'),
              items: roles
                  .map((value) => DropdownMenuItem(
                      value: value,
                      child: Text(
                          BandPart(id: '', instrument: '', role: value)
                              .roleLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis)))
                  .toList(),
              onChanged: (value) {
                if (value != null) onChanged(part.copyWith(role: value));
              },
            ),
          ),
          IconButton(
            tooltip: 'Remove $displayName',
            onPressed: canRemove ? onRemove : null,
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close_rounded,
                color:
                    canRemove ? AppPalette.muted(context) : Colors.transparent,
                size: 18),
          ),
        ]),
      );

  static Color _roleColor(String role) => switch (role) {
        'melody' => const Color(0xFFBA0007),
        'harmony' => const Color(0xFF6E4BB8),
        'bass' => const Color(0xFF216D8F),
        'drums' => const Color(0xFFD27616),
        _ => const Color(0xFF777777),
      };

  static InputDecoration _fieldDecoration(BuildContext context, String label) =>
      InputDecoration(
        labelText: label,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(11),
          borderSide: BorderSide(
              color: AppPalette.border(context).withValues(alpha: .75)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(11),
          borderSide: const BorderSide(color: Color(0xFFBA0007), width: 1.4),
        ),
      );
}
