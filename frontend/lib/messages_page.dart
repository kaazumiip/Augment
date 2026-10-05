import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import 'app_palette.dart';
import 'social_avatar.dart';
import 'social_profile_page.dart';
import 'social_service.dart';

enum _MessageAttachmentKind { photo, video, voiceNote, pdf, file }

class MessagesPage extends StatefulWidget {
  const MessagesPage({super.key});
  static const _red = Color(0xFFCA000A);

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  final _searchController = TextEditingController();
  final _service = SocialService.instance;
  late Stream<List<ConversationSummary>> _conversationStream;
  late Future<List<MessageRequest>> _requestsFuture;

  @override
  void initState() {
    super.initState();
    _conversationStream = _service.conversations();
    _requestsFuture = _service.messageRequests();
  }

  void _retryConversations() {
    setState(() {
      _conversationStream = _service.conversations();
      _requestsFuture = _service.messageRequests();
    });
  }

  Future<void> _respondToRequest(MessageRequest request, bool accept) async {
    try {
      await _service.respondToMessageRequest(request.conversationId,
          accept: accept);
      if (!mounted) return;
      setState(() => _requestsFuture = _service.messageRequests());
      if (accept) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ChatPage(
              conversation: ConversationSummary(
                id: request.conversationId,
                otherUserId: request.senderId,
                name: request.senderName,
                lastMessage: request.preview,
                updatedAt: request.createdAt,
                unread: true,
                avatarUrl: request.senderAvatarUrl,
              ),
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update request: $error')),
        );
      }
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppPalette.page(context),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 19, 24, 18),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              AppBackButton(onPressed: () => Navigator.pop(context)),
              const SizedBox(height: 25),
              Row(children: [
                Expanded(
                    child: Text('Message .',
                        style: TextStyle(
                            color: AppPalette.text(context),
                            fontSize: 25,
                            fontWeight: FontWeight.w800))),
                TextButton.icon(
                    onPressed: _createGroup,
                    icon: const Icon(Icons.group_add_outlined),
                    label: const Text('Create group')),
              ]),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.center,
                child: ConstrainedBox(
                  // Keep a visible equal margin on each side rather than
                  // making the field look left-anchored on compact phones.
                  constraints: const BoxConstraints(maxWidth: 300),
                  child: SizedBox(
                    width: double.infinity,
                    height: 43,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppPalette.surface(context),
                        border: Border.all(color: AppPalette.border(context)),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: TextField(
                        controller: _searchController,
                        onChanged: (_) => setState(() {}),
                        style: TextStyle(color: AppPalette.text(context)),
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search_rounded,
                              color: Color(0xFFA5A5A5), size: 20),
                          hintText: 'Search messages',
                          hintStyle:
                              TextStyle(fontSize: 13, color: Color(0xFFAAAAAA)),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 22),
              Expanded(
                child: StreamBuilder<List<ConversationSummary>>(
                  stream: _conversationStream,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return _StateMessage(
                        text: 'Messages unavailable: ${snapshot.error}',
                        onRetry: _retryConversations,
                      );
                    }
                    final query = _searchController.text.trim().toLowerCase();
                    final rows =
                        (snapshot.data ?? const <ConversationSummary>[])
                            .where((item) =>
                                query.isEmpty ||
                                item.name.toLowerCase().contains(query) ||
                                item.lastMessage.toLowerCase().contains(query))
                            .toList();
                    return FutureBuilder<List<MessageRequest>>(
                      future: _requestsFuture,
                      builder: (context, requestSnapshot) {
                        final requests = requestSnapshot.data ?? const [];
                        if (rows.isEmpty && requests.isEmpty) {
                          return _StartConversationList(
                            query: query,
                            onSelect: _startConversation,
                          );
                        }
                        return RefreshIndicator(
                          onRefresh: () async {
                            await _service.refreshConversations();
                            if (mounted) {
                              setState(() =>
                                  _requestsFuture = _service.messageRequests());
                            }
                          },
                          child: ListView(
                            children: [
                              if (requests.isNotEmpty)
                                _MessageRequestSection(
                                  requests: requests,
                                  onRespond: _respondToRequest,
                                ),
                              ...rows.map(
                                (item) => _Conversation(
                                  item: item,
                                  onLongPress: () => _conversationMenu(item),
                                  onTap: () async {
                                    await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            ChatPage(conversation: item),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ]),
          ),
        ),
      );

  Future<void> _startConversation(SocialProfileSummary profile) async {
    try {
      final conversationId = await _service.startDirectConversation(profile.id);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatPage(
            conversation: ConversationSummary(
              id: conversationId,
              otherUserId: profile.id,
              name: profile.name,
              lastMessage: 'No message yet.',
              updatedAt: null,
              unread: false,
              avatarUrl: profile.avatarUrl,
            ),
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not start conversation: $error')),
        );
      }
    }
  }

  Future<void> _conversationMenu(ConversationSummary item) async {
    final action = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: AppPalette.surface(context),
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        builder: (ctx) => SafeArea(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(
                  title: Text(item.name,
                      style: const TextStyle(fontWeight: FontWeight.w800))),
              ListTile(
                  leading: const Icon(Icons.push_pin_outlined),
                  title: Text(item.isPinned ? 'Unpin' : 'Pin'),
                  onTap: () => Navigator.pop(ctx, 'pin')),
              ListTile(
                  leading: const Icon(Icons.notifications_off_outlined),
                  title: Text(item.isMuted ? 'Unmute' : 'Mute'),
                  onTap: () => Navigator.pop(ctx, 'mute')),
              ListTile(
                  leading: const Icon(Icons.delete_outline,
                      color: MessagesPage._red),
                  title: const Text('Delete',
                      style: TextStyle(color: MessagesPage._red)),
                  onTap: () => Navigator.pop(ctx, 'delete')),
            ])));
    if (!mounted || action == null) return;
    try {
      if (action == 'delete') {
        final confirmed = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
                    title: const Text('Delete this conversation?'),
                    content: const Text(
                        'This clears the conversation for you only. Other people keep their messages. New messages will appear again.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel')),
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Delete'))
                    ]));
        if (confirmed != true) return;
        await _service.deleteConversationForMe(item.id);
      } else {
        await _service.setConversationSetting(
            item.id,
            action == 'pin' ? 'is_pinned' : 'is_muted',
            action == 'pin' ? !item.isPinned : !item.isMuted);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not update chat: $error')));
      }
    }
  }

  Future<void> _createGroup() async {
    final name = TextEditingController();
    final selected = <String>{};
    try {
      final contacts = await _service.groupContacts();
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => StatefulBuilder(
              builder: (ctx, change) => AlertDialog(
                title: const Text('Create group'),
                scrollable: true,
                      content: SizedBox(
                          width: double.maxFinite,
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                            TextField(
                                controller: name,
                                maxLength: 80,
                                onChanged: (_) => change(() {}),
                                decoration: const InputDecoration(
                                    labelText: 'Group name')),
                            const Text('Choose 2 to 19 connected musicians.'),
                            SizedBox(
                                height: 220,
                                child: contacts.isEmpty
                                    ? const Center(
                                        child: Text(
                                            'Connect with musicians first.'))
                                    : ListView(
                                        children: contacts
                                            .map((p) => CheckboxListTile(
                                                title: Text(p.name),
                                                value: selected.contains(p.id),
                                                onChanged: (value) =>
                                                    change(() {
                                                      if (value == true &&
                                                          selected.length <
                                                              19) {
                                                        selected.add(p.id);
                                                      } else {
                                                        selected.remove(p.id);
                                                      }
                                                    })))
                                            .toList())),
                          ])),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Cancel')),
                        FilledButton(
                            onPressed:
                                selected.length < 2 || name.text.trim().isEmpty
                                    ? null
                                    : () => Navigator.pop(ctx, true),
                            child: const Text('Create'))
                      ])));
      if (confirmed != true) return;
      final id = await _service.createGroup(name.text, selected.toList());
      if (!mounted) return;
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => ChatPage(
                  conversation: ConversationSummary(
                      id: id,
                      otherUserId: '',
                      name: name.text.trim(),
                      lastMessage: '',
                      updatedAt: null,
                      unread: false,
                      isGroup: true))));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not create group: $error')));
      }
    } finally {
      name.dispose();
    }
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.conversation});
  final ConversationSummary conversation;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _messageController = TextEditingController();
  final _service = SocialService.instance;
  final _attachmentButtonKey = GlobalKey();
  final _recorder = AudioRecorder();
  StreamSubscription<Amplitude>? _amplitudeSubscription;
  bool _sending = false;
  PlatformFile? _attachment;
  List<double>? _attachmentWaveform;
  _PendingOutgoingMessage? _pendingOutgoingMessage;
  bool _attachmentMenuOpen = false;
  bool _recordingVoiceNote = false;
  bool _voicePressActive = false;
  bool _startingVoiceNote = false;
  final List<double> _recordingWaveform = [];
  late final Stream<List<ChatMessage>> _messagesStream;
  late final Stream<UserPresence> _presenceStream;
  String? _lastMarkedIncomingMessageId;

  Future<void> _markConversationRead({DateTime? through}) async {
    try {
      await _service.markConversationRead(widget.conversation.id,
          through: through);
    } catch (_) {
      // Reading the conversation must never make the chat unusable.
      _lastMarkedIncomingMessageId = null;
    }
  }

  void _openOtherProfile() {
    if (widget.conversation.isGroup) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SocialProfilePage(
          name: widget.conversation.name,
          userId: widget.conversation.otherUserId,
          isOwnProfile: false,
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _messagesStream = _service.messages(widget.conversation.id);
    _presenceStream = widget.conversation.isGroup
        ? Stream.value(const UserPresence(null))
        : _service.presence(widget.conversation.otherUserId);
  }

  @override
  void dispose() {
    _messageController.dispose();
    _recorder.dispose();
    _amplitudeSubscription?.cancel();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending ||
        (_messageController.text.trim().isEmpty && _attachment == null)) {
      return;
    }
    final draft = _PendingOutgoingMessage(
      text: _messageController.text.trim(),
      attachment: _attachment,
      waveform: List<double>.from(_attachmentWaveform ?? const []),
      mediaType: _draftMediaType(_attachment),
      createdAt: DateTime.now(),
    );
    setState(() {
      _sending = true;
      _pendingOutgoingMessage = draft;
    });
    try {
      await _service.sendMessage(
          widget.conversation.id, _messageController.text,
          attachment: _attachment, waveform: _attachmentWaveform);
      _messageController.clear();
      if (mounted) {
        setState(() {
          _attachment = null;
          _attachmentWaveform = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _pendingOutgoingMessage = null);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not send message: $error')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });
      }
    }
  }

  bool _isImageAttachment(PlatformFile? attachment) => const {
        'jpg',
        'jpeg',
        'png',
        'gif',
        'webp',
        'heic'
      }.contains((attachment?.extension ?? '').toLowerCase());

  String? _draftMediaType(PlatformFile? attachment) =>
      _isImageAttachment(attachment) ? 'image' : null;

  Future<void> _pickAttachment(FileType type,
      {List<String>? allowedExtensions}) async {
    final result = await FilePicker.platform.pickFiles(
      type: type,
      allowedExtensions: allowedExtensions,
      withData: false,
    );
    if (result == null || result.files.isEmpty || !mounted) return;
    setState(() => _attachment = result.files.single);
  }

  Future<void> _chooseAttachment(_MessageAttachmentKind kind) {
    return switch (kind) {
      _MessageAttachmentKind.photo => _pickAttachment(FileType.image),
      // These formats are playable by Flutter's Android/iOS video backends.
      // Do not accept AVI/MKV here: they upload successfully but cannot play
      // reliably in the app without a server-side transcode service.
      _MessageAttachmentKind.video => _pickAttachment(FileType.custom,
          allowedExtensions: const ['mp4', 'mov', 'webm']),
      _MessageAttachmentKind.voiceNote => _pickAttachment(FileType.audio),
      _MessageAttachmentKind.pdf =>
        _pickAttachment(FileType.custom, allowedExtensions: const ['pdf']),
      _MessageAttachmentKind.file => _pickAttachment(FileType.any),
    };
  }

  Future<void> _startVoiceRecording() async {
    if (_recordingVoiceNote || _startingVoiceNote) return;
    _startingVoiceNote = true;
    try {
      if (!await _recorder.hasPermission()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content:
                  Text('Allow microphone access to record a voice note.')));
        }
        return;
      }
      if (!_voicePressActive) return;
      final directory = await getTemporaryDirectory();
      final path = '${directory.path}/voice_note_'
          '${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc),
          path: path);
      if (!mounted) return;
      setState(() {
        _recordingVoiceNote = true;
        _recordingWaveform.clear();
      });
      _amplitudeSubscription?.cancel();
      _amplitudeSubscription = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 70))
          .listen((amplitude) {
        if (!mounted) return;
        final level =
            ((amplitude.current + 55) / 55).clamp(.05, 1.0).toDouble();
        setState(() {
          _recordingWaveform.add(level);
          if (_recordingWaveform.length > 42) _recordingWaveform.removeAt(0);
        });
      });
      if (!_voicePressActive) await _finishVoiceRecording();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not start voice recording.')));
      }
    } finally {
      _startingVoiceNote = false;
    }
  }

  Future<void> _finishVoiceRecording() async {
    if (!_recordingVoiceNote) return;
    final path = await _recorder.stop();
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
    if (!mounted) return;
    setState(() => _recordingVoiceNote = false);
    if (path == null) return;
    final file = File(path);
    if (!await file.exists()) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    setState(() {
      _attachment = PlatformFile(
          name: 'Voice note ${DateTime.now().millisecondsSinceEpoch}.m4a',
          size: bytes.length,
          path: path,
          bytes: bytes);
      _attachmentWaveform = List<double>.from(_recordingWaveform);
    });
  }

  void _onVoiceLongPressStart(LongPressStartDetails _) {
    _voicePressActive = true;
    _startVoiceRecording();
  }

  void _onVoiceLongPressEnd(LongPressEndDetails _) {
    _voicePressActive = false;
    if (!_startingVoiceNote) _finishVoiceRecording();
  }

  void _markVisibleMessagesRead(List<ChatMessage> messages) {
    if (!(ModalRoute.of(context)?.isCurrent ?? false)) return;
    final ownId = FirebaseAuth.instance.currentUser?.uid;
    ChatMessage? latestIncoming;
    for (final message in messages.reversed) {
      if (message.senderId != ownId) {
        latestIncoming = message;
        break;
      }
    }
    if (latestIncoming == null ||
        latestIncoming.id == _lastMarkedIncomingMessageId) {
      return;
    }
    _lastMarkedIncomingMessageId = latestIncoming.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) {
        unawaited(_markConversationRead(through: latestIncoming!.createdAt));
      }
    });
  }

  Future<void> _openAttachmentMenu() async {
    if (_attachmentMenuOpen) return;
    final renderBox =
        _attachmentButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final buttonOffset = renderBox.localToGlobal(Offset.zero);
    final pageSize = MediaQuery.sizeOf(context);
    final menuLeft = (buttonOffset.dx - 2).clamp(12.0, pageSize.width - 188.0);
    final menuBottom = pageSize.height - buttonOffset.dy + 18;
    final initialKeyboardInset = MediaQuery.viewInsetsOf(context).bottom;

    setState(() => _attachmentMenuOpen = true);
    try {
      await showGeneralDialog<void>(
        context: context,
        requestFocus: false,
        barrierDismissible: true,
        barrierLabel: 'Close attachments',
        barrierColor: Colors.transparent,
        transitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (dialogContext, _, __) {
          // The composer moves when the keyboard closes. Follow its new
          // position instead of leaving the popover at its old screen offset.
          final keyboardDelta = MediaQuery.viewInsetsOf(dialogContext).bottom -
              initialKeyboardInset;
          return Material(
            color: Colors.transparent,
            child: Stack(children: [
              Positioned(
                left: menuLeft,
                bottom: menuBottom + keyboardDelta,
                width: 176,
                child: _AttachmentPopover(
                  onSelect: (kind) {
                    Navigator.pop(dialogContext);
                    _chooseAttachment(kind);
                  },
                ),
              ),
              Positioned(
                left: buttonOffset.dx,
                top: buttonOffset.dy - keyboardDelta,
                width: renderBox.size.width,
                height: renderBox.size.height,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.pop(dialogContext),
                ),
              ),
            ]),
          );
        },
        transitionBuilder: (_, animation, __, child) {
          final curve =
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: curve,
            child: SlideTransition(
              position:
                  Tween<Offset>(begin: const Offset(0, .14), end: Offset.zero)
                      .animate(curve),
              child: child,
            ),
          );
        },
      );
    } finally {
      if (mounted) setState(() => _attachmentMenuOpen = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppPalette.page(context),
        body: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 27, 15),
              child: Row(children: [
                AppBackButton(onPressed: () => Navigator.pop(context)),
                Expanded(
                  child: InkWell(
                    onTap: _openOtherProfile,
                    borderRadius: BorderRadius.circular(12),
                    child: Row(children: [
                      StreamBuilder<String?>(
                        stream: SocialService.instance
                            .profileAvatar(widget.conversation.otherUserId),
                        builder: (context, snapshot) => _InitialAvatar(
                          name: widget.conversation.name,
                          imageUrl:
                              snapshot.data ?? widget.conversation.avatarUrl,
                          radius: 17,
                        ),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(widget.conversation.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: AppPalette.text(context),
                                      fontSize: 14,
                                      fontWeight: FontWeight.w800)),
                              StreamBuilder<UserPresence>(
                                stream: _presenceStream,
                                builder: (context, snapshot) => Text(
                                  widget.conversation.isGroup
                                      ? 'Group conversation'
                                      : _presenceLabel(snapshot.data),
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: snapshot.data?.isOnline == true
                                        ? const Color(0xFF24A148)
                                        : MessagesPage._red,
                                  ),
                                ),
                              ),
                            ]),
                      ),
                    ]),
                  ),
                ),
              ]),
            ),
            Expanded(
              child: StreamBuilder<List<ChatMessage>>(
                stream: _messagesStream,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const Center(
                        child: Text('Could not load messages.'));
                  }
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final ownId = FirebaseAuth.instance.currentUser?.uid;
                  final messages = snapshot.data!;
                  final pending = _pendingOutgoingMessage;
                  final pendingDelivered = pending != null &&
                      messages.any((message) =>
                          message.senderId == ownId &&
                          message.body == pending.text &&
                          message.fileName == pending.attachment?.name &&
                          message.createdAt.isAfter(pending.createdAt
                              .subtract(const Duration(seconds: 5))));
                  if (pendingDelivered) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted && _pendingOutgoingMessage == pending) {
                        setState(() => _pendingOutgoingMessage = null);
                      }
                    });
                  }
                  final visiblePending = pendingDelivered ? null : pending;
                  _markVisibleMessagesRead(messages);
                  if (messages.isEmpty && visiblePending == null) {
                    return Center(
                        child: Text('No message yet.',
                            style:
                                TextStyle(color: AppPalette.muted(context))));
                  }
                  return ListView.separated(
                    reverse: true,
                    padding: const EdgeInsets.fromLTRB(27, 24, 27, 12),
                    itemCount:
                        messages.length + (visiblePending == null ? 0 : 1),
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      if (visiblePending != null && index == 0) {
                        return _Bubble(
                          text: visiblePending.text,
                          incoming: false,
                          time: 'Sending…',
                          mediaType: visiblePending.mediaType,
                          localAttachment: visiblePending.attachment,
                          waveform: visiblePending.waveform,
                        );
                      }
                      final messageIndex =
                          index - (visiblePending == null ? 0 : 1);
                      final message =
                          messages[messages.length - 1 - messageIndex];
                      return _Bubble(
                          text: message.body,
                          incoming: message.senderId != ownId,
                          time: _time(message.createdAt),
                          mediaUrl: message.mediaUrl,
                          mediaType: message.mediaType,
                          fileName: message.fileName,
                          waveform: message.waveform);
                    },
                  );
                },
              ),
            ),
            if (_attachment != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(25, 5, 25, 1),
                child: Row(children: [
                  if (_attachmentWaveform != null) ...[
                    const Icon(Icons.mic_none_rounded,
                        color: MessagesPage._red, size: 17),
                    const SizedBox(width: 7),
                    const Text('Voice note',
                        style: TextStyle(
                            color: MessagesPage._red,
                            fontSize: 11,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(width: 9),
                    Expanded(
                        child: SizedBox(
                            height: 22,
                            child: _WaveformBars(
                                samples: _attachmentWaveform!,
                                color: MessagesPage._red))),
                  ] else ...[
                    if (_isImageAttachment(_attachment)) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(7),
                        child: SizedBox(
                          width: 36,
                          height: 36,
                          child: _LocalImagePreview(file: _attachment!),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text('Photo ready to send',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: MessagesPage._red,
                                fontSize: 11,
                                fontWeight: FontWeight.w700)),
                      ),
                    ] else ...[
                      const Icon(Icons.attach_file_rounded,
                          color: MessagesPage._red, size: 17),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(_attachment!.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: AppPalette.text(context), fontSize: 11)),
                      ),
                    ],
                  ],
                  IconButton(
                      onPressed: () => setState(() {
                            _attachment = null;
                            _attachmentWaveform = null;
                          }),
                      icon: const Icon(Icons.close_rounded, size: 17)),
                ]),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(19, 9, 19, 13),
              child: Container(
                height: 47,
                padding: const EdgeInsets.only(left: 11, right: 5),
                decoration: BoxDecoration(
                    color: AppPalette.surface(context),
                    borderRadius: BorderRadius.circular(24)),
                child: Row(children: [
                  InkWell(
                    key: _attachmentButtonKey,
                    onTap: _openAttachmentMenu,
                    borderRadius: BorderRadius.circular(20),
                    child: CircleAvatar(
                        radius: 15,
                        backgroundColor: MessagesPage._red,
                        child: AnimatedRotation(
                          turns: _attachmentMenuOpen ? .125 : 0,
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutCubic,
                          child: const Icon(Icons.add_rounded,
                              color: Colors.white, size: 18),
                        )),
                  ),
                  Tooltip(
                    message: 'Hold to record a voice note',
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onLongPressStart: _onVoiceLongPressStart,
                      onLongPressEnd: _onVoiceLongPressEnd,
                      onLongPressCancel: () {
                        _voicePressActive = false;
                        if (!_startingVoiceNote) _finishVoiceRecording();
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                            color: _recordingVoiceNote
                                ? MessagesPage._red
                                : Colors.transparent,
                            shape: BoxShape.circle),
                        alignment: Alignment.center,
                        child: Icon(Icons.mic_none_rounded,
                            color: _recordingVoiceNote
                                ? Colors.white
                                : MessagesPage._red,
                            size: 19),
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      child: _recordingVoiceNote
                          ? _InlineRecordingWave(
                              key: const ValueKey('recording-wave'),
                              samples: _recordingWaveform)
                          : TextField(
                              key: const ValueKey('message-input'),
                              controller: _messageController,
                              onSubmitted: (_) => _send(),
                              style: TextStyle(
                                  color: AppPalette.text(context),
                                  fontSize: 13),
                              decoration: const InputDecoration(
                                  hintText: 'Type a message...',
                                  border: InputBorder.none,
                                  hintStyle: TextStyle(
                                      color: Color(0xFFADADAD), fontSize: 13)),
                            ),
                    ),
                  ),
                  IconButton(
                      onPressed: _sending ? null : _send,
                      icon: const Icon(Icons.send_rounded,
                          color: MessagesPage._red, size: 21)),
                ]),
              ),
            ),
          ]),
        ),
      );

  String _time(DateTime value) {
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    return '$hour:${value.minute.toString().padLeft(2, '0')} ${value.hour >= 12 ? 'PM' : 'AM'}';
  }

  String _presenceLabel(UserPresence? presence) {
    if (presence == null || presence.lastSeenAt == null) return 'Offline';
    if (presence.isOnline) return 'Online';
    final age = DateTime.now().difference(presence.lastSeenAt!);
    if (age.inMinutes < 1) return 'Last seen just now';
    if (age.inMinutes < 60) return 'Last seen ${age.inMinutes}m ago';
    if (age.inHours < 24) return 'Last seen ${age.inHours}h ago';
    return 'Last seen ${age.inDays}d ago';
  }
}

class _MessageRequestSection extends StatelessWidget {
  const _MessageRequestSection(
      {required this.requests, required this.onRespond});

  final List<MessageRequest> requests;
  final Future<void> Function(MessageRequest request, bool accept) onRespond;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 10),
        decoration: BoxDecoration(
          color: AppPalette.surface(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: MessagesPage._red.withValues(alpha: .28)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.mark_unread_chat_alt_outlined,
                color: MessagesPage._red, size: 19),
            const SizedBox(width: 8),
            Text('Message requests',
                style: TextStyle(
                    color: AppPalette.text(context),
                    fontWeight: FontWeight.w800,
                    fontSize: 15)),
            const Spacer(),
            Text('${requests.length}',
                style: const TextStyle(
                    color: MessagesPage._red, fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 8),
          ...requests.map(
            (request) => Padding(
              padding: const EdgeInsets.only(top: 9),
              child:
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SocialAccountAvatar(
                  name: request.senderName,
                  imageUrl: request.senderAvatarUrl,
                  size: 38,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(request.senderName,
                          style: TextStyle(
                              color: AppPalette.text(context),
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(request.preview,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: AppPalette.muted(context), fontSize: 12)),
                      const SizedBox(height: 8),
                      Row(children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => onRespond(request, false),
                            child: const Text('Decline'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                                backgroundColor: MessagesPage._red),
                            onPressed: () => onRespond(request, true),
                            child: const Text('Accept'),
                          ),
                        ),
                      ]),
                    ],
                  ),
                ),
              ]),
            ),
          ),
        ]),
      );
}

class _Conversation extends StatelessWidget {
  const _Conversation({
    required this.item,
    required this.onTap,
    required this.onLongPress,
  });
  final ConversationSummary item;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(children: [
            Expanded(
              child: Row(children: [
                _InitialAvatar(
                  name: item.name,
                  imageUrl: item.avatarUrl,
                  radius: 23,
                ),
                const SizedBox(width: 12),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(item.name,
                          style: TextStyle(
                              color: AppPalette.text(context),
                              fontSize: 14,
                              fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      Text(
                          item.lastSenderId == null
                              ? item.lastMessage
                              : '${item.lastSenderId == FirebaseAuth.instance.currentUser?.uid ? 'You' : item.name}: ${item.lastMessage}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFFAEAEAE),
                              height: 1.15)),
                    ])),
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              if (item.isPinned)
                const Icon(Icons.push_pin, size: 15, color: MessagesPage._red),
              if (item.isMuted)
                const Icon(Icons.notifications_off_outlined, size: 15),
              Text(item.updatedAt == null ? '' : _ago(item.updatedAt!),
                  style:
                      const TextStyle(fontSize: 10, color: Color(0xFFAAAAAA))),
              if (item.unread)
                Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: CircleAvatar(
                        radius: 10,
                        backgroundColor: MessagesPage._red,
                        child: Text(
                            item.unreadCount > 9
                                ? '9+'
                                : '${item.unreadCount.clamp(1, 9)}',
                            style: const TextStyle(
                                fontSize: 10, color: Colors.white)))),
            ]),
          ]),
        ),
      );
  String _ago(DateTime time) {
    final age = DateTime.now().difference(time);
    return age.inHours > 0 ? '${age.inHours}h ago' : '${age.inMinutes}m ago';
  }
}

class _StartConversationList extends StatefulWidget {
  const _StartConversationList({required this.query, required this.onSelect});
  final String query;
  final ValueChanged<SocialProfileSummary> onSelect;

  @override
  State<_StartConversationList> createState() => _StartConversationListState();
}

class _StartConversationListState extends State<_StartConversationList> {
  late Future<List<SocialProfileSummary>> _people;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _StartConversationList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) _load();
  }

  void _load() {
    _people = SocialService.instance.messageContacts(widget.query);
  }

  void _retry() => setState(_load);

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<List<SocialProfileSummary>>(
        future: _people,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return _StateMessage(
              text: 'Could not load people to message.',
              onRetry: _retry,
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final people = snapshot.data!;
          if (people.isEmpty) {
            return _StateMessage(
              text: widget.query.isEmpty
                  ? 'Follow someone to start a conversation.'
                  : 'No connected accounts match that search.',
              onRetry: _retry,
            );
          }
          return ListView(
            children: [
              Text('People',
                  style: TextStyle(
                      color: AppPalette.text(context),
                      fontSize: 14,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              ...people.map((person) => InkWell(
                    onTap: () => widget.onSelect(person),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(children: [
                        _InitialAvatar(
                          name: person.name,
                          imageUrl: person.avatarUrl,
                          radius: 23,
                        ),
                        const SizedBox(width: 12),
                        Text(person.name,
                            style: TextStyle(
                                color: AppPalette.text(context),
                                fontSize: 14,
                                fontWeight: FontWeight.w800)),
                      ]),
                    ),
                  )),
            ],
          );
        },
      );
}

class _InitialAvatar extends StatelessWidget {
  const _InitialAvatar({
    required this.name,
    required this.radius,
    this.imageUrl,
  });
  final String name;
  final double radius;
  final String? imageUrl;
  @override
  Widget build(BuildContext context) => CircleAvatar(
        radius: radius,
        backgroundColor: const Color(0xFFE6E2DF),
        backgroundImage: imageUrl == null || imageUrl!.isEmpty
            ? null
            : NetworkImage(imageUrl!),
        child: imageUrl == null || imageUrl!.isEmpty
            ? Text(name.isEmpty ? '?' : name[0].toUpperCase(),
                style:
                    TextStyle(color: const Color(0xFF777777), fontSize: radius))
            : null,
      );
}

class _StateMessage extends StatelessWidget {
  const _StateMessage({required this.text, required this.onRetry});
  final String text;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(text, textAlign: TextAlign.center),
        const SizedBox(height: 10),
        TextButton(onPressed: onRetry, child: const Text('Retry'))
      ]));
}

class _AttachmentPopover extends StatelessWidget {
  const _AttachmentPopover({required this.onSelect});
  final ValueChanged<_MessageAttachmentKind> onSelect;

  @override
  Widget build(BuildContext context) => Material(
        color: AppPalette.surface(context),
        elevation: 10,
        shadowColor: Colors.black.withValues(alpha: .2),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _option(context, _MessageAttachmentKind.photo, Icons.image_outlined,
                'Photo'),
            _option(context, _MessageAttachmentKind.video,
                Icons.videocam_outlined, 'Video'),
            _option(context, _MessageAttachmentKind.voiceNote,
                Icons.graphic_eq_rounded, 'Audio'),
            _option(context, _MessageAttachmentKind.pdf,
                Icons.picture_as_pdf_outlined, 'PDF'),
            _option(context, _MessageAttachmentKind.file,
                Icons.attach_file_rounded, 'File'),
          ]),
        ),
      );

  Widget _option(BuildContext context, _MessageAttachmentKind kind,
          IconData icon, String label) =>
      InkWell(
        onTap: () => onSelect(kind),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(children: [
            Icon(icon, size: 19, color: MessagesPage._red),
            const SizedBox(width: 11),
            Text(label,
                style:
                    TextStyle(color: AppPalette.text(context), fontSize: 13)),
          ]),
        ),
      );
}

class _InlineRecordingWave extends StatelessWidget {
  const _InlineRecordingWave({super.key, required this.samples});
  final List<double> samples;

  @override
  Widget build(BuildContext context) => Row(children: [
        const Text('Recording',
            style: TextStyle(
                color: MessagesPage._red,
                fontSize: 11,
                fontWeight: FontWeight.w700)),
        const SizedBox(width: 8),
        Expanded(
            child: _WaveformBars(samples: samples, color: MessagesPage._red)),
      ]);
}

class _VoiceNotePlayer extends StatefulWidget {
  const _VoiceNotePlayer(
      {required this.url, required this.incoming, required this.waveform});
  final String url;
  final bool incoming;
  final List<double> waveform;

  @override
  State<_VoiceNotePlayer> createState() => _VoiceNotePlayerState();
}

class _VoiceNotePlayerState extends State<_VoiceNotePlayer> {
  final _player = AudioPlayer();
  bool _playing = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _player.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() {
          _playing = state == PlayerState.playing;
          _loading = false;
        });
      }
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _loading = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_loading) return;
    if (_playing) {
      await _player.pause();
    } else {
      setState(() => _loading = true);
      try {
        await _player.play(UrlSource(widget.url));
      } catch (_) {
        if (mounted) setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final actionColor = widget.incoming ? Colors.white : MessagesPage._red;
    final waveColor = widget.incoming
        ? MessagesPage._red.withValues(alpha: .75)
        : Colors.white.withValues(alpha: .85);
    return Container(
      width: 205,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
          color: widget.incoming
              ? AppPalette.page(context)
              : Colors.white.withValues(alpha: .16),
          borderRadius: BorderRadius.circular(7)),
      child: Row(children: [
        InkWell(
          onTap: _toggle,
          borderRadius: BorderRadius.circular(16),
          child: Container(
              width: 29,
              height: 29,
              decoration: BoxDecoration(
                  color: widget.incoming ? MessagesPage._red : Colors.white,
                  shape: BoxShape.circle),
              alignment: Alignment.center,
              child: _loading
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.8, color: actionColor))
                  : Icon(
                      _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      size: 18,
                      color: actionColor)),
        ),
        const SizedBox(width: 9),
        Expanded(
            child: _WaveformBars(samples: widget.waveform, color: waveColor)),
      ]),
    );
  }
}

class _MusicFilePlayer extends StatefulWidget {
  const _MusicFilePlayer(
      {required this.url, required this.fileName, required this.incoming});

  final String url;
  final String? fileName;
  final bool incoming;

  @override
  State<_MusicFilePlayer> createState() => _MusicFilePlayerState();
}

class _MusicFilePlayerState extends State<_MusicFilePlayer> {
  final _player = AudioPlayer();
  bool _playing = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _player.onPlayerStateChanged.listen((state) {
      if (!mounted) return;
      setState(() {
        _playing = state == PlayerState.playing;
        _loading = false;
      });
    });
    _player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() => _playing = false);
    });
  }

  Future<void> _toggle() async {
    if (_loading) return;
    if (_playing) {
      await _player.pause();
      return;
    }
    setState(() => _loading = true);
    try {
      await _player.play(UrlSource(widget.url));
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final foreground = widget.incoming ? MessagesPage._red : Colors.white;
    return Container(
      width: 205,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: widget.incoming
            ? AppPalette.page(context)
            : Colors.white.withValues(alpha: .16),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: foreground.withValues(alpha: .13),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Icon(Icons.music_note_rounded, color: foreground, size: 22),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.fileName ?? 'Audio track',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color:
                      widget.incoming ? AppPalette.text(context) : Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text('Music file',
                  style: TextStyle(
                      color: widget.incoming
                          ? AppPalette.muted(context)
                          : Colors.white70,
                      fontSize: 9.5)),
            ],
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: _toggle,
          icon: _loading
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.8, color: foreground))
              : Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: foreground),
        ),
      ]),
    );
  }
}

class _WaveformBars extends StatelessWidget {
  const _WaveformBars({required this.samples, required this.color});
  final List<double> samples;
  final Color color;

  @override
  Widget build(BuildContext context) {
    const count = 22;
    final fallback = List<double>.generate(
        count, (index) => .24 + (((index * 7) % 12) / 25));
    final source = samples.isEmpty ? fallback : samples;
    final values = List<double>.generate(count, (index) {
      final sourceIndex = ((index / (count - 1)) * (source.length - 1)).round();
      return source[sourceIndex].clamp(.08, 1.0).toDouble();
    });
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: values
          .map((value) => AnimatedContainer(
                duration: const Duration(milliseconds: 70),
                width: 2,
                height: 4 + value * 17,
                decoration: BoxDecoration(
                    color: color, borderRadius: BorderRadius.circular(2)),
              ))
          .toList(),
    );
  }
}

class _PendingOutgoingMessage {
  const _PendingOutgoingMessage({
    required this.text,
    required this.attachment,
    required this.waveform,
    required this.mediaType,
    required this.createdAt,
  });

  final String text;
  final PlatformFile? attachment;
  final List<double> waveform;
  final String? mediaType;
  final DateTime createdAt;
}

class _LocalImagePreview extends StatelessWidget {
  const _LocalImagePreview({required this.file});
  final PlatformFile file;

  @override
  Widget build(BuildContext context) {
    final bytes = file.bytes;
    if (bytes != null) {
      return Image.memory(bytes, fit: BoxFit.cover);
    }
    final path = file.path;
    if (path != null && path.isNotEmpty) {
      return Image.file(File(path), fit: BoxFit.cover);
    }
    return const ColoredBox(
      color: Color(0xFFECE4E0),
      child: Icon(Icons.image_not_supported_outlined),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble(
      {required this.text,
      required this.incoming,
      required this.time,
      this.mediaUrl,
      this.mediaType,
      this.fileName,
      this.localAttachment,
      this.waveform = const []});
  final String text, time;
  final bool incoming;
  final String? mediaUrl, mediaType, fileName;
  final PlatformFile? localAttachment;
  final List<double> waveform;

  Future<void> _openAttachment() async {
    final url = mediaUrl;
    if (url == null) return;
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  bool get _hasAttachment => mediaUrl != null || localAttachment != null;

  bool get _isVisualMedia =>
      _hasAttachment && (mediaType == 'image' || mediaType == 'video');

  @override
  Widget build(BuildContext context) {
    if (_isVisualMedia) {
      return Align(
        alignment: incoming ? Alignment.centerLeft : Alignment.centerRight,
        child: Column(
          crossAxisAlignment:
              incoming ? CrossAxisAlignment.start : CrossAxisAlignment.end,
          children: [
            _attachment(context),
            if (text.isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                constraints: const BoxConstraints(maxWidth: 245),
                padding:
                    const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                decoration: BoxDecoration(
                  color: incoming
                      ? AppPalette.surface(context)
                      : MessagesPage._red,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(text,
                    style: TextStyle(
                        color:
                            incoming ? AppPalette.text(context) : Colors.white,
                        fontSize: 12,
                        height: 1.25)),
              ),
            ],
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(time,
                  style:
                      const TextStyle(color: Color(0xFF999999), fontSize: 9.5)),
            ),
          ],
        ),
      );
    }

    return Align(
      alignment: incoming ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 245),
        padding: const EdgeInsets.fromLTRB(13, 11, 13, 8),
        decoration: BoxDecoration(
            color: incoming ? AppPalette.surface(context) : MessagesPage._red,
            borderRadius: BorderRadius.circular(9)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          if (_hasAttachment) _attachment(context),
          if (_hasAttachment && text.isNotEmpty) const SizedBox(height: 8),
          if (text.isNotEmpty)
            Text(text,
                style: TextStyle(
                    color: incoming ? AppPalette.text(context) : Colors.white,
                    fontSize: 12,
                    height: 1.25)),
          const SizedBox(height: 5),
          Text(time,
              style: TextStyle(
                  color: incoming
                      ? const Color(0xFF999999)
                      : Colors.white.withValues(alpha: .8),
                  fontSize: 9.5)),
        ]),
      ),
    );
  }

  Widget _attachment(BuildContext context) {
    final type = mediaType ?? 'file';
    if (type == 'image') {
      final local = localAttachment;
      if (local != null) {
        return ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 196, maxHeight: 230),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 196,
              height: 132,
              child: _LocalImagePreview(file: local),
            ),
          ),
        );
      }
      return GestureDetector(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => _MessageImageFullscreenPage(url: mediaUrl!),
          ),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 196, maxHeight: 230),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.network(
              mediaUrl!,
              width: 196,
              fit: BoxFit.cover,
              loadingBuilder: (context, child, progress) => progress == null
                  ? child
                  : const SizedBox(
                      width: 196,
                      height: 132,
                      child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
              errorBuilder: (_, __, ___) => _fileTile(context, type),
            ),
          ),
        ),
      );
    }
    if (type == 'voice' || (type == 'audio' && waveform.isNotEmpty)) {
      return _VoiceNotePlayer(
          url: mediaUrl!, incoming: incoming, waveform: waveform);
    }
    if (type == 'audio') {
      return _MusicFilePlayer(
          url: mediaUrl!, fileName: fileName, incoming: incoming);
    }
    if (type == 'video') {
      return _MessageVideoPreview(url: mediaUrl!, incoming: incoming);
    }
    return InkWell(onTap: _openAttachment, child: _fileTile(context, type));
  }

  Widget _fileTile(BuildContext context, String type) {
    final icon = switch (type) {
      'video' => Icons.play_circle_fill_rounded,
      'audio' => Icons.music_note_rounded,
      'voice' => Icons.graphic_eq_rounded,
      'pdf' => Icons.picture_as_pdf_rounded,
      _ => Icons.insert_drive_file_outlined,
    };
    return Container(
      width: 205,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
          color: incoming
              ? AppPalette.page(context)
              : Colors.white.withValues(alpha: .16),
          borderRadius: BorderRadius.circular(6)),
      child: Row(children: [
        Icon(icon, color: incoming ? MessagesPage._red : Colors.white),
        const SizedBox(width: 9),
        Expanded(
            child: Text(fileName ?? '${type.toUpperCase()} attachment',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: incoming ? AppPalette.text(context) : Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600))),
        Icon(Icons.open_in_new_rounded,
            size: 15,
            color: incoming ? AppPalette.muted(context) : Colors.white),
      ]),
    );
  }
}

class _MessageVideoPreview extends StatefulWidget {
  const _MessageVideoPreview({required this.url, required this.incoming});
  final String url;
  final bool incoming;

  @override
  State<_MessageVideoPreview> createState() => _MessageVideoPreviewState();
}

class _MessageVideoPreviewState extends State<_MessageVideoPreview> {
  late final VideoPlayerController _controller;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize().then((_) {
        if (mounted) setState(() {});
      }).catchError((Object error) {
        if (mounted) setState(() => _error = error);
      });
    _controller.addListener(_onPlayerChanged);
  }

  void _onPlayerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onPlayerChanged)
      ..dispose();
    super.dispose();
  }

  Future<void> _togglePlayback() async {
    if (!_controller.value.isInitialized) return;
    if (_controller.value.isPlaying) {
      await _controller.pause();
    } else {
      await _controller.play();
    }
  }

  Future<void> _openFullscreen() async {
    await _controller.pause();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _MessageVideoFullscreenPage(url: widget.url),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final initialized = _controller.value.isInitialized;
    return SizedBox(
      width: 275,
      child: AspectRatio(
        aspectRatio: initialized
            ? _controller.value.aspectRatio.clamp(.75, 1.8)
            : 16 / 9,
        child: Stack(fit: StackFit.expand, children: [
          const ColoredBox(color: Colors.black),
          if (initialized)
            FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: _controller.value.size.width,
                height: _controller.value.size.height,
                child: VideoPlayer(_controller),
              ),
            ),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _togglePlayback,
              child: Center(
                child: _error != null
                    ? const Icon(Icons.video_file_outlined,
                        color: Colors.white70, size: 34)
                    : !initialized
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2))
                        : AnimatedOpacity(
                            opacity: _controller.value.isPlaying ? 0 : 1,
                            duration: const Duration(milliseconds: 180),
                            child: const Icon(Icons.play_circle_fill_rounded,
                                color: Colors.white, size: 46),
                          ),
              ),
            ),
          ),
          Positioned(
            right: 3,
            bottom: 3,
            child: IconButton(
              tooltip: 'Play fullscreen',
              onPressed: initialized ? _openFullscreen : null,
              icon: const Icon(Icons.fullscreen_rounded,
                  color: Colors.white, size: 23),
            ),
          ),
        ]),
      ),
    );
  }
}

class _MessageImageFullscreenPage extends StatelessWidget {
  const _MessageImageFullscreenPage({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 5,
                  child: Center(
                    child: Image.network(
                      url,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const Text(
                        'This image could not be loaded.',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 6,
                left: 6,
                child: IconButton.filledTonal(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
            ],
          ),
        ),
      );
}

class _MessageVideoFullscreenPage extends StatefulWidget {
  const _MessageVideoFullscreenPage({required this.url});
  final String url;

  @override
  State<_MessageVideoFullscreenPage> createState() =>
      _MessageVideoFullscreenPageState();
}

class _MessageVideoFullscreenPageState
    extends State<_MessageVideoFullscreenPage> {
  late final VideoPlayerController _controller;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize().then((_) async {
        if (!mounted) return;
        await _controller.play();
        if (mounted) setState(() {});
      }).catchError((Object error) {
        if (mounted) setState(() => _error = error);
      });
    _controller.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final initialized = _controller.value.isInitialized;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(children: [
          Center(
            child: _error != null
                ? const Text('This video could not be played.',
                    style: TextStyle(color: Colors.white))
                : !initialized
                    ? const CircularProgressIndicator(color: Colors.white)
                    : AspectRatio(
                        aspectRatio: _controller.value.aspectRatio,
                        child: GestureDetector(
                          onTap: () => _controller.value.isPlaying
                              ? _controller.pause()
                              : _controller.play(),
                          child: VideoPlayer(_controller),
                        ),
                      ),
          ),
          Positioned(
            top: 6,
            left: 6,
            child: IconButton.filledTonal(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close_rounded),
            ),
          ),
          if (initialized)
            Positioned(
              left: 18,
              right: 18,
              bottom: 14,
              child: VideoProgressIndicator(_controller,
                  allowScrubbing: true,
                  colors: const VideoProgressColors(
                      playedColor: MessagesPage._red,
                      bufferedColor: Colors.white54,
                      backgroundColor: Colors.white24)),
            ),
        ]),
      ),
    );
  }
}
