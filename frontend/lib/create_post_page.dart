import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'app_palette.dart';
import 'social_avatar.dart';
import 'social_service.dart';
import 'social_profile_page.dart';

class _PollDraft {
  const _PollDraft({required this.choices, required this.duration});
  final List<String> choices;
  final Duration duration;
}

class _PollDialog extends StatefulWidget {
  const _PollDialog(
      {required this.initialChoices, required this.initialDuration});
  final List<String> initialChoices;
  final Duration initialDuration;

  @override
  State<_PollDialog> createState() => _PollDialogState();
}

class _PollDialogState extends State<_PollDialog> {
  static const red = Color(0xFFCA000A);
  late final List<TextEditingController> _options;
  late Duration _duration;

  @override
  void initState() {
    super.initState();
    _duration = widget.initialDuration;
    final count = widget.initialChoices.length.clamp(2, 4);
    _options = List.generate(
      count,
      (index) => TextEditingController(
          text: index < widget.initialChoices.length
              ? widget.initialChoices[index]
              : ''),
    );
  }

  bool get _valid {
    final values = _options.map((item) => item.text.trim()).toList();
    return values.every((value) => value.isNotEmpty) &&
        values.map((value) => value.toLowerCase()).toSet().length ==
            values.length;
  }

  void _addOption() {
    if (_options.length >= 4) return;
    setState(() => _options.add(TextEditingController()));
  }

  void _removeOption(int index) {
    if (_options.length <= 2) return;
    final controller = _options.removeAt(index);
    controller.dispose();
    setState(() {});
  }

  @override
  void dispose() {
    for (final controller in _options) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: AppPalette.page(context),
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        contentPadding: const EdgeInsets.symmetric(horizontal: 24),
        actionsPadding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        title: Row(children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
                color: red.withValues(alpha: .1),
                borderRadius: BorderRadius.circular(13)),
            child: const Icon(Icons.poll_rounded, color: red, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text('Create a poll',
                style: TextStyle(
                    color: AppPalette.text(context),
                    fontSize: 20,
                    fontWeight: FontWeight.w800)),
          ),
        ]),
        scrollable: true,
        content: SizedBox(
            width: 360,
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Add between two and four choices.',
                      style: TextStyle(
                          color: AppPalette.muted(context), fontSize: 14)),
                  const SizedBox(height: 20),
                  for (var i = 0; i < _options.length; i++)
                    Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(children: [
                          Expanded(
                            child: TextField(
                              controller: _options[i],
                              autofocus: i == 0,
                              maxLength: 80,
                              buildCounter: (_,
                                      {required currentLength,
                                      required isFocused,
                                      maxLength}) =>
                                  null,
                              onChanged: (_) => setState(() {}),
                              textInputAction: i == _options.length - 1
                                  ? TextInputAction.done
                                  : TextInputAction.next,
                              onSubmitted: (_) {
                                if (i == _options.length - 1 && _valid) {
                                  _submit();
                                }
                              },
                              style: TextStyle(color: AppPalette.text(context)),
                              cursorColor: red,
                              decoration: InputDecoration(
                                  prefixIcon: Padding(
                                    padding: const EdgeInsets.all(11),
                                    child: CircleAvatar(
                                      radius: 11,
                                      backgroundColor:
                                          red.withValues(alpha: .1),
                                      child: Text('${i + 1}',
                                          style: const TextStyle(
                                              color: red,
                                              fontSize: 11,
                                              fontWeight: FontWeight.w800)),
                                    ),
                                  ),
                                  hintText: 'Option ${i + 1}',
                                  filled: true,
                                  fillColor: AppPalette.surface(context),
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 15),
                                  enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(13),
                                      borderSide: BorderSide(
                                          color: AppPalette.border(context))),
                                  focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(13),
                                      borderSide: const BorderSide(
                                          color: red, width: 1.5))),
                            ),
                          ),
                          if (_options.length > 2) ...[
                            const SizedBox(width: 5),
                            IconButton(
                              tooltip: 'Remove option',
                              onPressed: () => _removeOption(i),
                              icon: Icon(Icons.remove_circle_outline_rounded,
                                  color: AppPalette.muted(context)),
                            ),
                          ],
                        ])),
                  if (_options.length < 4)
                    TextButton.icon(
                      onPressed: _addOption,
                      icon: const Icon(Icons.add_circle_outline_rounded,
                          size: 18),
                      label: const Text('Add another choice'),
                      style: TextButton.styleFrom(foregroundColor: red),
                    ),
                  const SizedBox(height: 14),
                  Text('Poll duration',
                      style: TextStyle(
                          color: AppPalette.text(context),
                          fontSize: 13,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(height: 9),
                  Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: [
                      _durationChip('1 hour', const Duration(hours: 1)),
                      _durationChip('1 day', const Duration(days: 1)),
                      _durationChip('3 days', const Duration(days: 3)),
                      _durationChip('7 days', const Duration(days: 7)),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text('Choices must be different and cannot be empty.',
                      style: TextStyle(
                          color: AppPalette.muted(context), fontSize: 12)),
                ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              style: TextButton.styleFrom(
                  foregroundColor: AppPalette.muted(context)),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: _valid ? _submit : null,
              style: FilledButton.styleFrom(
                  backgroundColor: red,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(104, 48),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12))),
              child: const Text('Add poll')),
        ],
      );

  Widget _durationChip(String label, Duration value) {
    final selected = _duration == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => setState(() => _duration = value),
      selectedColor: red.withValues(alpha: .14),
      backgroundColor: AppPalette.surface(context),
      side: BorderSide(color: selected ? red : AppPalette.border(context)),
      labelStyle: TextStyle(
        color: selected ? red : AppPalette.text(context),
        fontSize: 11.5,
        fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
      ),
      showCheckmark: false,
    );
  }

  void _submit() => Navigator.pop(
        context,
        _PollDraft(
          choices:
              _options.map((controller) => controller.text.trim()).toList(),
          duration: _duration,
        ),
      );
}

class _SyncedPostAuthor extends StatelessWidget {
  const _SyncedPostAuthor({required this.fallbackName, required this.onPost});

  final String fallbackName;
  final VoidCallback onPost;

  @override
  Widget build(BuildContext context) {
    final firebaseName = FirebaseAuth.instance.currentUser?.displayName?.trim();
    final fallback =
        firebaseName?.isNotEmpty == true ? firebaseName! : fallbackName;
    return StreamBuilder<SocialProfileSummary?>(
      stream: SocialService.instance.currentProfile(),
      builder: (context, snapshot) {
        final profile = snapshot.data;
        final name =
            profile?.name.trim().isNotEmpty == true ? profile!.name : fallback;
        return GestureDetector(
          onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) =>
                      SocialProfilePage(name: name, isOwnProfile: true))),
          child: Row(children: [
            SocialAccountAvatar(
              name: name,
              imageUrl: profile?.avatarUrl,
              size: 50,
            ),
            const SizedBox(width: 12),
            Expanded(
                child: Text(name,
                    style: TextStyle(
                        color: AppPalette.text(context),
                        fontSize: 15,
                        fontWeight: FontWeight.w800))),
            SizedBox(
              height: 29,
              child: FilledButton(
                onPressed: onPost,
                style: FilledButton.styleFrom(
                  backgroundColor: _CreatePostPageState._red,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Post',
                    style:
                        TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        );
      },
    );
  }
}

class CreatePostPage extends StatefulWidget {
  const CreatePostPage({super.key, required this.name, this.initialAction});
  final String name;
  // One of image, video, audio, sheet, or poll when opened from a shortcut.
  final String? initialAction;

  @override
  State<CreatePostPage> createState() => _CreatePostPageState();
}

class _CreatePostPageState extends State<CreatePostPage> {
  static const _red = Color(0xFFCA000A);
  final _controller = TextEditingController();
  List<PlatformFile> _files = const [];
  String? _mediaType;
  List<String> _pollChoices = const [];
  Duration _pollDuration = const Duration(days: 1);

  @override
  void initState() {
    super.initState();
    final action = widget.initialAction;
    if (action == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (action == 'poll') {
        _choosePoll();
      } else {
        _chooseMedia(action);
      }
    });
  }

  Future<void> _chooseMedia(String type) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: type == 'image'
          ? const ['jpg', 'jpeg', 'png', 'webp']
          : type == 'video'
              ? const ['mp4', 'mov', 'webm']
              : type == 'sheet'
                  ? const ['pdf', 'png', 'jpg', 'jpeg', 'webp']
                  : const ['mp3', 'm4a', 'wav', 'aac'],
      withData: true,
      allowMultiple: true,
    );
    if (result == null) return;
    setState(() {
      _files = result.files;
      _mediaType = type;
      _pollChoices = const [];
    });
  }

  Future<void> _choosePoll() async {
    final draft = await showDialog<_PollDraft>(
      context: context,
      builder: (_) => _PollDialog(
        initialChoices: _pollChoices,
        initialDuration: _pollDuration,
      ),
    );
    if (!mounted || draft == null) return;
    final clean = draft.choices
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    if (clean.length < 2) return;
    setState(() {
      _pollChoices = clean;
      _pollDuration = draft.duration;
      _files = const [];
      _mediaType = null;
    });
  }

  void _submit() => Navigator.pop(
      context,
      NewPostContent(
          body: _controller.text,
          files: _files,
          mediaType: _mediaType,
          pollChoices: _pollChoices,
          pollDuration: _pollChoices.isEmpty ? null : _pollDuration));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppPalette.page(context),
        body: SafeArea(
          child: Stack(children: [
            Positioned(
              right: -111,
              bottom: 124,
              child: IgnorePointer(
                child: Container(
                  width: 290,
                  height: 290,
                  decoration: BoxDecoration(
                    color: _red.withValues(alpha: .31),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      AppBackButton(onPressed: () => Navigator.pop(context)),
                      const SizedBox(width: 8),
                      Text('Create post',
                          style: TextStyle(
                              color: AppPalette.text(context),
                              fontSize: 20,
                              fontWeight: FontWeight.w700)),
                    ]),
                    const SizedBox(height: 24),
                    _SyncedPostAuthor(
                      fallbackName: widget.name,
                      onPost: _submit,
                    ),
                    const SizedBox(height: 24),
                    const Text("What's on your mind?",
                        style: TextStyle(
                            color: _red,
                            fontSize: 14,
                            fontWeight: FontWeight.w800)),
                    const SizedBox(height: 12),
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        autofocus: true,
                        expands: true,
                        minLines: null,
                        maxLines: null,
                        textAlignVertical: TextAlignVertical.top,
                        style: TextStyle(
                            color: AppPalette.text(context),
                            fontSize: 15,
                            height: 1.25),
                        decoration: InputDecoration(
                          hintText: _files.isNotEmpty
                              ? 'Add a caption...'
                              : 'share your music, ideas or updates\nwith the community',
                          hintStyle: TextStyle(
                              color: AppPalette.muted(context),
                              fontSize: 13,
                              height: 1.1),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                    if (_files.isNotEmpty || _pollChoices.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: _pollChoices.isNotEmpty
                            ? _PollDraftCard(
                                choices: _pollChoices,
                                duration: _pollDuration,
                                onEdit: _choosePoll,
                                onRemove: () =>
                                    setState(() => _pollChoices = const []),
                              )
                            : Row(children: [
                                const Icon(Icons.attach_file_rounded,
                                    color: _red, size: 18),
                                const SizedBox(width: 7),
                                Expanded(
                                    child: Text(
                                        '${_files.length} file${_files.length == 1 ? '' : 's'} selected',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            color: AppPalette.text(context),
                                            fontSize: 12))),
                                IconButton(
                                    onPressed: () => setState(() {
                                          _files = const [];
                                          _mediaType = null;
                                        }),
                                    icon: const Icon(Icons.close_rounded,
                                        size: 18)),
                              ]),
                      ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _PostTool(
                            icon: Icons.camera_alt_rounded,
                            label: 'Photo',
                            onTap: () => _chooseMedia('image')),
                        _PostTool(
                            icon: Icons.videocam_rounded,
                            label: 'Video',
                            onTap: () => _chooseMedia('video')),
                        _PostTool(
                            icon: Icons.poll_rounded,
                            label: 'Poll',
                            onTap: _choosePoll),
                        _PostTool(
                            icon: Icons.graphic_eq_rounded,
                            label: 'Audio',
                            onTap: () => _chooseMedia('audio')),
                        _PostTool(
                            icon: Icons.library_music_rounded,
                            label: 'Sheet',
                            onTap: () => _chooseMedia('sheet')),
                      ],
                    ),
                  ]),
            ),
          ]),
        ),
      );
}

class _PollDraftCard extends StatelessWidget {
  const _PollDraftCard(
      {required this.choices,
      required this.duration,
      required this.onEdit,
      required this.onRemove});
  final List<String> choices;
  final Duration duration;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(13, 11, 7, 12),
        decoration: BoxDecoration(
          color: AppPalette.surface(context),
          borderRadius: BorderRadius.circular(14),
          border:
              Border.all(color: const Color(0xFFCA000A).withValues(alpha: .2)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.poll_rounded, color: Color(0xFFCA000A), size: 18),
            const SizedBox(width: 7),
            Text('Poll preview',
                style: TextStyle(
                    color: AppPalette.text(context),
                    fontSize: 12,
                    fontWeight: FontWeight.w800)),
            const SizedBox(width: 8),
            Text('• ${_durationLabel(duration)}',
                style: TextStyle(
                    color: AppPalette.muted(context), fontSize: 10.5)),
            const Spacer(),
            IconButton(
                tooltip: 'Edit poll',
                visualDensity: VisualDensity.compact,
                onPressed: onEdit,
                icon: const Icon(Icons.edit_outlined, size: 18)),
            IconButton(
                tooltip: 'Remove poll',
                visualDensity: VisualDensity.compact,
                onPressed: onRemove,
                icon: const Icon(Icons.close_rounded, size: 18)),
          ]),
          for (var index = 0; index < choices.length; index++)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 7, right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
              decoration: BoxDecoration(
                color: AppPalette.page(context),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppPalette.border(context)),
              ),
              child: Text('${index + 1}.  ${choices[index]}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: AppPalette.text(context), fontSize: 11.5)),
            ),
        ]),
      );

  static String _durationLabel(Duration value) {
    if (value.inDays > 0) {
      return '${value.inDays} ${value.inDays == 1 ? 'day' : 'days'}';
    }
    return '${value.inHours} ${value.inHours == 1 ? 'hour' : 'hours'}';
  }
}

class _PostTool extends StatelessWidget {
  const _PostTool(
      {required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 30,
          height: 30,
          decoration: const BoxDecoration(
              color: Color(0xFFCA000A), shape: BoxShape.circle),
          child: Icon(icon, color: Colors.white, size: 16),
        ),
        const SizedBox(width: 7),
        Text(label,
            style: TextStyle(
                color: AppPalette.text(context),
                fontSize: 10.5,
                fontWeight: FontWeight.w500)),
      ]));
}
