import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'social_service.dart';
import 'seller_payout_page.dart';

class CreateMarketplaceListingPage extends StatefulWidget {
  const CreateMarketplaceListingPage({super.key});

  @override
  State<CreateMarketplaceListingPage> createState() =>
      _CreateMarketplaceListingPageState();
}

class _CreateMarketplaceListingPageState
    extends State<CreateMarketplaceListingPage> {
  static const _red = Color(0xFFCA000A);
  final _title = TextEditingController();
  final _price = TextEditingController();
  String _category = 'Music';
  String? _genre;
  PlatformFile? _file;
  PlatformFile? _cover;
  bool _saving = false;
  static const _genres = [
    'Pop',
    'Rock',
    'R&B',
    'Hip hop',
    'Jazz',
    'Classical',
    'Electronic',
    'Country',
    'Folk',
    'Blues',
    'Metal',
    'Reggae',
    'Latin',
    'K-pop',
    'Indie',
    'Soul',
    'Gospel',
    'Soundtrack',
  ];

  @override
  void dispose() {
    _title.dispose();
    _price.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const [
        'mp3',
        'wav',
        'm4a',
        'pdf',
        'musicxml',
        'xml',
        'txt'
      ],
      withData: true,
    );
    if (result != null && result.files.isNotEmpty && mounted) {
      setState(() => _file = result.files.single);
    }
  }

  Future<void> _pickCover() async {
    final result = await FilePicker.platform
        .pickFiles(type: FileType.image, withData: true);
    if (result != null && result.files.isNotEmpty && mounted) {
      setState(() => _cover = result.files.single);
    }
  }

  Future<void> _pickGenre() async {
    final genre = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          _GenrePickerSheet(current: _genre ?? _genres.first, genres: _genres),
    );
    if (genre != null && mounted) setState(() => _genre = genre);
  }

  Future<void> _openPreview() async {
    final price = double.tryParse(_price.text.trim());
    if (_title.text.trim().isEmpty || price == null || price < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Add a title and a valid price.')));
      return;
    }
    final published = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => _ListingPreviewPage(
              title: _title.text.trim(),
              category: _category,
              genre: _genre ?? 'Unspecified',
              price: price,
              file: _file,
              cover: _cover,
              onPublish: _publish,
            )));
    if (published == true && mounted) Navigator.pop(context, true);
  }

  Future<void> _publish() async {
    final price = double.tryParse(_price.text.trim());
    if (_title.text.trim().isEmpty || price == null || price < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add a title and a valid price.')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await SocialService.instance.createMarketplaceListing(
        NewMarketplaceListing(
          title: _title.text,
          category: _category,
          price: price,
          description: _genre ?? 'Unspecified',
          file: _file,
          cover: _cover,
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not publish listing: $error')),
        );
      }
      rethrow;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width <= 360;
    return Scaffold(
      backgroundColor: AppPalette.page(context),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              compact ? 16 : 28, compact ? 14 : 25, compact ? 16 : 28, 24),
          child: SingleChildScrollView(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                IconButton(
                  tooltip: 'Back',
                  onPressed: _saving ? null : () => Navigator.pop(context),
                  constraints:
                      const BoxConstraints.tightFor(width: 40, height: 44),
                  alignment: Alignment.centerLeft,
                  padding: EdgeInsets.zero,
                  icon: Icon(Icons.arrow_back_ios_new_rounded,
                      color: AppPalette.text(context), size: 20),
                ),
                const SizedBox(width: 4),
                Expanded(
                    child: Text(
                  'ADD PRODUCT',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Instrument Sans',
                    color: AppPalette.text(context),
                    fontSize: compact ? 19 : 22,
                    fontWeight: FontWeight.w900,
                    letterSpacing: compact ? 0 : .4,
                  ),
                )),
                IconButton(
                  tooltip: 'Seller payouts',
                  color: _red,
                  constraints:
                      const BoxConstraints.tightFor(width: 40, height: 44),
                  icon: const Icon(Icons.account_balance_wallet_outlined),
                  onPressed: _saving
                      ? null
                      : () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const SellerPayoutPage(),
                            ),
                          ),
                ),
              ]),
              const SizedBox(height: 10),
              Text(
                'Create a listing for the Marketplace.',
                style: TextStyle(
                  color: AppPalette.muted(context),
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 26),
              Text('Type of product',
                  style: TextStyle(
                      color: AppPalette.text(context),
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Row(children: [
                _productTypeCard('Music', Icons.music_note_rounded),
                const SizedBox(width: 9),
                _productTypeCard('Music sheet', Icons.library_music_rounded),
                const SizedBox(width: 9),
                _productTypeCard('Lyrics', Icons.subject_rounded),
              ]),
              const SizedBox(height: 25),
              _field(
                  controller: _title,
                  label: 'Title',
                  hint: 'Enter the title of the song'),
              const SizedBox(height: 20),
              _genrePicker(),
              const SizedBox(height: 23),
              Text('Upload file',
                  style: TextStyle(
                      color: AppPalette.text(context),
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _saving ? null : _pickFile,
                  icon: const Icon(Icons.attach_file_rounded),
                  label: Text(_file == null ? 'Attachment' : _file!.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _red,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(128, 42),
                    alignment: Alignment.center,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
              const SizedBox(height: 25),
              Text('Cover image',
                  style: TextStyle(
                      color: AppPalette.text(context),
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              InkWell(
                  onTap: _pickCover,
                  child: Row(children: [
                    Container(
                        width: 64,
                        height: 64,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                            color: AppPalette.surface(context),
                            borderRadius: BorderRadius.circular(6),
                            border:
                                Border.all(color: AppPalette.border(context))),
                        child: _cover?.bytes == null
                            ? Icon(Icons.add_rounded,
                                color: AppPalette.muted(context), size: 30)
                            : Image.memory(_cover!.bytes!,
                                fit: BoxFit.cover, width: 64, height: 64)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                          _cover == null
                              ? 'Add cover image\nJPG, PNG'
                              : _cover!.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: AppPalette.muted(context), fontSize: 13)),
                    ),
                  ])),
              const SizedBox(height: 25),
              _field(
                  controller: _price,
                  label: 'Price',
                  hint: '\$0.00',
                  keyboard: TextInputType.number),
              const SizedBox(height: 25),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: ElevatedButton(
                  onPressed: _saving ? null : _openPreview,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _red,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Preview product'),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _productTypeCard(String type, IconData icon) {
    final selected = _category == type;
    return Expanded(
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          onTap: _saving ? null : () => setState(() => _category = type),
          borderRadius: BorderRadius.circular(7),
          child: Container(
            height: 76,
            padding: const EdgeInsets.symmetric(horizontal: 5),
            decoration: BoxDecoration(
              color: selected ? _red : AppPalette.surface(context),
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                  color: selected ? _red : AppPalette.border(context)),
            ),
            child:
                Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon,
                  size: 20,
                  color: selected ? Colors.white : AppPalette.text(context)),
              const SizedBox(height: 6),
              Text(type,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  style: TextStyle(
                      color: selected ? Colors.white : AppPalette.text(context),
                      fontSize: 11,
                      fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _genrePicker() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Genre',
            style: TextStyle(
                color: AppPalette.text(context),
                fontSize: 14,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        SizedBox(
          height: 46,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _saving ? null : _pickGenre,
              borderRadius: BorderRadius.circular(8),
              child: InputDecorator(
                decoration: _decoration(context, 'Select genre'),
                child: Row(children: [
                  Expanded(
                      child: Text(_genre ?? 'Choose genre',
                          style: TextStyle(
                              color: _genre == null
                                  ? AppPalette.muted(context)
                                  : AppPalette.text(context),
                              fontSize: 14,
                              fontWeight: _genre == null
                                  ? FontWeight.w500
                                  : FontWeight.w700))),
                  Icon(Icons.expand_more_rounded,
                      color: AppPalette.muted(context)),
                ]),
              ),
            ),
          ),
        ),
      ]);

  Widget _field(
          {required TextEditingController controller,
          required String label,
          required String hint,
          TextInputType? keyboard}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: TextStyle(
                color: AppPalette.text(context),
                fontSize: 14,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        SizedBox(
            height: 46,
            child: TextField(
              controller: controller,
              keyboardType: keyboard,
              style: TextStyle(color: AppPalette.text(context), fontSize: 14),
              decoration: _decoration(context, hint),
            )),
      ]);

  InputDecoration _decoration(BuildContext context, String label) =>
      InputDecoration(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
        hintText: label,
        hintStyle: TextStyle(color: AppPalette.muted(context)),
        filled: true,
        fillColor: AppPalette.surface(context),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppPalette.border(context)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppPalette.border(context)),
        ),
      );
}

class _GenrePickerSheet extends StatefulWidget {
  const _GenrePickerSheet({required this.current, required this.genres});
  final String current;
  final List<String> genres;

  @override
  State<_GenrePickerSheet> createState() => _GenrePickerSheetState();
}

class _GenrePickerSheetState extends State<_GenrePickerSheet> {
  late int _index;
  FixedExtentScrollController? _controller;

  @override
  void initState() {
    super.initState();
    _index = widget.genres
        .indexOf(widget.current)
        .clamp(0, widget.genres.length - 1)
        .toInt();
    _controller = FixedExtentScrollController(
        initialItem: widget.genres.length * 1000 + _index);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _controller ??= FixedExtentScrollController(
        initialItem: widget.genres.length * 1000 + _index);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Container(
        height: 420,
        padding: const EdgeInsets.fromLTRB(26, 12, 26, 26),
        decoration: BoxDecoration(
          color: AppPalette.surface(context),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppPalette.border(context)),
          boxShadow: const [
            BoxShadow(
                color: Color(0x24000000),
                blurRadius: 16,
                offset: Offset(0, -3)),
          ],
        ),
        child: Column(children: [
          Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                  color: AppPalette.border(context),
                  borderRadius: BorderRadius.circular(99))),
          const SizedBox(height: 8),
          Text('Choose genre',
              style: TextStyle(
                  color: AppPalette.text(context),
                  fontSize: 17,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 14),
          SizedBox(
            height: 250,
            child: ListWheelScrollView.useDelegate(
              controller: _controller!,
              itemExtent: 44,
              physics: const FixedExtentScrollPhysics(),
              perspective: .003,
              onSelectedItemChanged: (value) =>
                  setState(() => _index = value % widget.genres.length),
              childDelegate: ListWheelChildLoopingListDelegate(
                children: widget.genres.asMap().entries.map((entry) {
                  final index = entry.key;
                  final selected = index == _index;
                  return Center(
                    child: Container(
                      width: 218,
                      height: 36,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: selected
                            ? const Color(0xFFCA000A).withValues(alpha: .88)
                            : AppPalette.page(context).withValues(alpha: .58),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                            color: selected
                                ? Colors.white.withValues(alpha: .18)
                                : Colors.white.withValues(alpha: .10)),
                        boxShadow: selected
                            ? const [
                                BoxShadow(
                                    color: Color(0x1FCA000A),
                                    blurRadius: 8,
                                    offset: Offset(0, 3))
                              ]
                            : null,
                      ),
                      child: Text(entry.value,
                          style: TextStyle(
                              color: selected
                                  ? Colors.white
                                  : AppPalette.text(context),
                              fontSize: selected ? 16 : 14,
                              fontWeight: selected
                                  ? FontWeight.w800
                                  : FontWeight.w600)),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          const Spacer(),
          SizedBox(
              width: double.infinity,
              height: 46,
              child: ElevatedButton(
                  onPressed: () =>
                      Navigator.pop(context, widget.genres[_index]),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFCA000A),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8))),
                  child: const Text('Done'))),
        ]),
      ),
    );
  }
}

class _ListingPreviewPage extends StatefulWidget {
  const _ListingPreviewPage(
      {required this.title,
      required this.category,
      required this.genre,
      required this.price,
      this.file,
      required this.cover,
      required this.onPublish});
  final String title, category, genre;
  final double price;
  final PlatformFile? file;
  final PlatformFile? cover;
  final Future<void> Function() onPublish;
  @override
  State<_ListingPreviewPage> createState() => _ListingPreviewPageState();
}

class _ListingPreviewPageState extends State<_ListingPreviewPage> {
  bool _publishing = false;
  AudioPlayer? _previewPlayer;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<void>? _completionSubscription;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isPreviewing = false;

  String? get _fileExtension {
    final explicitExtension = widget.file?.extension?.trim().toLowerCase();
    if (explicitExtension != null && explicitExtension.isNotEmpty) {
      return explicitExtension;
    }
    final name = widget.file?.name ?? '';
    final dot = name.lastIndexOf('.');
    return dot == -1 ? null : name.substring(dot + 1).toLowerCase();
  }

  bool get _canPreviewAudio {
    final extension = _fileExtension;
    return widget.category == 'Music' &&
        const {'mp3', 'wav', 'm4a', 'aac', 'ogg', 'flac'}.contains(extension);
  }

  Source? get _audioSource {
    final file = widget.file;
    if (file == null) return null;
    if (file.bytes != null) return BytesSource(file.bytes!);
    if (file.path != null) return DeviceFileSource(file.path!);
    return null;
  }

  @override
  void initState() {
    super.initState();
    if (_canPreviewAudio && _audioSource != null) {
      _previewPlayer = AudioPlayer();
      _positionSubscription = _previewPlayer!.onPositionChanged.listen((value) {
        if (mounted) setState(() => _position = value);
      });
      _durationSubscription = _previewPlayer!.onDurationChanged.listen((value) {
        if (mounted) setState(() => _duration = value);
      });
      _completionSubscription = _previewPlayer!.onPlayerComplete.listen((_) {
        if (mounted) {
          setState(() {
            _position = Duration.zero;
            _isPreviewing = false;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _completionSubscription?.cancel();
    _previewPlayer?.dispose();
    super.dispose();
  }

  Future<void> _togglePreview() async {
    final player = _previewPlayer;
    final source = _audioSource;
    if (player == null || source == null) return;
    if (_isPreviewing) {
      await player.pause();
      if (mounted) setState(() => _isPreviewing = false);
      return;
    }
    if (_position >= _duration && _duration > Duration.zero) {
      await player.seek(Duration.zero);
    }
    try {
      await player.play(source, position: _position);
      if (mounted) setState(() => _isPreviewing = true);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('This audio file could not be previewed.')),
        );
      }
    }
  }

  String _formatDuration(Duration value) {
    final minutes = value.inMinutes;
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Future<void> _seekPreview(double fraction) async {
    if (_previewPlayer == null || _duration <= Duration.zero) return;
    final target =
        Duration(milliseconds: (_duration.inMilliseconds * fraction).round());
    await _previewPlayer!.seek(target);
    if (mounted) setState(() => _position = target);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppPalette.page(context),
        body: SafeArea(
            child: Padding(
                padding: const EdgeInsets.fromLTRB(26, 16, 26, 24),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppBackButton(
                        onPressed:
                            _publishing ? null : () => Navigator.pop(context),
                      ),
                      const SizedBox(height: 18),
                      Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                              color: AppPalette.surface(context),
                              border:
                                  Border.all(color: AppPalette.border(context)),
                              borderRadius: BorderRadius.circular(8)),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                          width: 92,
                                          height: 92,
                                          alignment: Alignment.center,
                                          decoration: BoxDecoration(
                                              color:
                                                  AppPalette.surface(context),
                                              borderRadius:
                                                  BorderRadius.circular(6)),
                                          child: widget.cover?.bytes == null
                                              ? Icon(Icons.music_note_rounded,
                                                  color:
                                                      AppPalette.muted(context),
                                                  size: 35)
                                              : ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(6),
                                                  child: Image.memory(
                                                      widget.cover!.bytes!,
                                                      fit: BoxFit.cover,
                                                      width: 92,
                                                      height: 92))),
                                      const SizedBox(width: 13),
                                      Expanded(
                                          child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                            Text(widget.title,
                                                style: TextStyle(
                                                    color: AppPalette.text(
                                                        context),
                                                    fontWeight: FontWeight.w800,
                                                    fontSize: 15)),
                                            const SizedBox(height: 5),
                                            Text(widget.category,
                                                style: TextStyle(
                                                    color: AppPalette.muted(
                                                        context),
                                                    fontSize: 11)),
                                            const SizedBox(height: 4),
                                            const Text('By: You',
                                                style: TextStyle(
                                                    color:
                                                        _CreateMarketplaceListingPageState
                                                            ._red,
                                                    fontSize: 10)),
                                            if (widget.genre.isNotEmpty)
                                              Text('Genre: ${widget.genre}',
                                                  style: TextStyle(
                                                      color: AppPalette.muted(
                                                          context),
                                                      fontSize: 10)),
                                            const SizedBox(height: 14),
                                            Text(
                                                '\$${widget.price.toStringAsFixed(2)}',
                                                style: const TextStyle(
                                                    color:
                                                        _CreateMarketplaceListingPageState
                                                            ._red,
                                                    fontWeight:
                                                        FontWeight.w800))
                                          ]))
                                    ]),
                                const SizedBox(height: 24),
                                Text('Preview',
                                    style: TextStyle(
                                        color: AppPalette.text(context),
                                        fontWeight: FontWeight.w800,
                                        fontSize: 12)),
                                const SizedBox(height: 9),
                                Row(children: [
                                  GestureDetector(
                                    onTap: _canPreviewAudio
                                        ? _togglePreview
                                        : null,
                                    child: Container(
                                      width: 30,
                                      height: 30,
                                      decoration: BoxDecoration(
                                        color: _canPreviewAudio
                                            ? _CreateMarketplaceListingPageState
                                                ._red
                                            : AppPalette.border(context),
                                        shape: BoxShape.circle,
                                      ),
                                      child: Icon(
                                        _isPreviewing
                                            ? Icons.pause_rounded
                                            : Icons.play_arrow_rounded,
                                        color: Colors.white,
                                        size: 19,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: SliderTheme(
                                      data: SliderTheme.of(context).copyWith(
                                        trackHeight: 3,
                                        activeTrackColor:
                                            _CreateMarketplaceListingPageState
                                                ._red,
                                        inactiveTrackColor:
                                            AppPalette.border(context),
                                        thumbColor:
                                            _CreateMarketplaceListingPageState
                                                ._red,
                                        thumbShape: const RoundSliderThumbShape(
                                            enabledThumbRadius: 5),
                                        overlayShape:
                                            const RoundSliderOverlayShape(
                                                overlayRadius: 12),
                                      ),
                                      child: Slider(
                                        value: _duration > Duration.zero
                                            ? (_position.inMilliseconds /
                                                    _duration.inMilliseconds)
                                                .clamp(0.0, 1.0)
                                            : 0,
                                        onChanged: _canPreviewAudio &&
                                                _duration > Duration.zero
                                            ? _seekPreview
                                            : null,
                                      ),
                                    ),
                                  ),
                                ]),
                                const SizedBox(height: 3),
                                Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(_formatDuration(_position),
                                          style: TextStyle(
                                              fontSize: 10,
                                              color: AppPalette.text(context))),
                                      Text(
                                          _duration > Duration.zero
                                              ? _formatDuration(_duration)
                                              : (_canPreviewAudio
                                                  ? 'Loading...'
                                                  : 'No audio preview'),
                                          style: TextStyle(
                                              fontSize: 10,
                                              color: AppPalette.text(context)))
                                    ]),
                              ])),
                      const SizedBox(height: 20),
                      Row(children: [
                        const Icon(Icons.check_box_rounded,
                            color: _CreateMarketplaceListingPageState._red),
                        const SizedBox(width: 9),
                        Expanded(
                            child: Text(
                                'I confirm that I own the rights to this content and agree to Terms and Services',
                                style: TextStyle(
                                    color: AppPalette.muted(context),
                                    fontSize: 10)))
                      ]),
                      const Spacer(),
                      SizedBox(
                          width: double.infinity,
                          height: 48,
                          child: ElevatedButton(
                              onPressed: _publishing
                                  ? null
                                  : () async {
                                      setState(() => _publishing = true);
                                      try {
                                        await widget.onPublish();
                                        if (!context.mounted) return;
                                        Navigator.of(context).pop(true);
                                      } catch (_) {
                                        if (mounted) {
                                          setState(() => _publishing = false);
                                        }
                                      }
                                    },
                              style: ElevatedButton.styleFrom(
                                  backgroundColor:
                                      _CreateMarketplaceListingPageState._red,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8))),
                              child: Text(
                                  _publishing ? 'Publishing...' : 'Publish'))),
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Center(
                              child: Text('Edit detail',
                                  style: TextStyle(
                                      color: _CreateMarketplaceListingPageState
                                          ._red))))
                    ]))),
      );
}
