import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:file_picker/file_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SocialPost {
  const SocialPost({
    required this.id,
    required this.authorId,
    required this.authorName,
    this.authorAvatarUrl,
    required this.body,
    required this.createdAt,
    required this.likes,
    required this.comments,
    required this.isLiked,
    required this.isSaved,
    this.mediaUrl,
    this.mediaType,
    this.media = const [],
    this.pollOptions = const [],
    this.pollEndsAt,
  });

  final String id;
  final String authorId;
  final String authorName;
  final String? authorAvatarUrl;
  final String body;
  final DateTime createdAt;
  final int likes;
  final int comments;
  final bool isLiked;
  final bool isSaved;
  final String? mediaUrl;
  final String? mediaType;
  final List<PostMedia> media;
  final List<PollOption> pollOptions;
  final DateTime? pollEndsAt;

  SocialPost copyWith({
    String? body,
    int? likes,
    int? comments,
    bool? isLiked,
    bool? isSaved,
  }) =>
      SocialPost(
        id: id,
        authorId: authorId,
        authorName: authorName,
        authorAvatarUrl: authorAvatarUrl,
        body: body ?? this.body,
        createdAt: createdAt,
        likes: likes ?? this.likes,
        comments: comments ?? this.comments,
        isLiked: isLiked ?? this.isLiked,
        isSaved: isSaved ?? this.isSaved,
        mediaUrl: mediaUrl,
        mediaType: mediaType,
        media: media,
        pollOptions: pollOptions,
        pollEndsAt: pollEndsAt,
      );

  factory SocialPost.fromMap(Map<String, dynamic> data, String currentUserId) {
    final profile = data['profiles'] as Map<String, dynamic>?;
    final likes = (data['post_likes'] as List?) ?? const [];
    final comments = (data['post_comments'] as List?) ?? const [];
    final saves = (data['post_saves'] as List?) ?? const [];
    return SocialPost(
      id: data['id'] as String,
      authorId: data['user_id'] as String,
      authorName: (profile?['display_name'] as String?) ?? 'Augment user',
      authorAvatarUrl: profile?['avatar_url'] as String?,
      body: data['body'] as String,
      createdAt: DateTime.parse(data['created_at'] as String).toLocal(),
      likes: likes.length,
      comments: comments.length,
      isLiked: likes.any((like) => like['user_id'] == currentUserId),
      isSaved: saves.any((save) => save['user_id'] == currentUserId),
      mediaUrl: data['media_url'] as String?,
      mediaType: data['media_type'] as String?,
      media: ((data['post_media'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map(PostMedia.fromMap)
          .toList(),
      pollOptions: ((data['poll_options'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map((option) => PollOption.fromMap(option, currentUserId))
          .toList(),
      pollEndsAt: data['poll_ends_at'] == null
          ? null
          : DateTime.parse(data['poll_ends_at'] as String).toLocal(),
    );
  }
}

class PostComment {
  const PostComment(
      {required this.id,
      required this.authorId,
      required this.authorName,
      required this.body,
      required this.createdAt,
      this.parentCommentId,
      this.authorAvatarUrl});
  final String id;
  final String authorId;
  final String authorName;
  final String body;
  final DateTime createdAt;

  /// A reply belongs beneath this comment. Top-level comments have no parent.
  final String? parentCommentId;
  final String? authorAvatarUrl;
}

class PostMedia {
  const PostMedia({required this.url, required this.type});
  final String url;
  final String type;
  factory PostMedia.fromMap(Map<String, dynamic> data) => PostMedia(
        url: data['media_url'] as String,
        type: data['media_type'] as String,
      );
}

class PollOption {
  const PollOption(
      {required this.id,
      required this.label,
      required this.votes,
      required this.voted});
  final String id;
  final String label;
  final int votes;
  final bool voted;
  factory PollOption.fromMap(Map<String, dynamic> data, String userId) {
    final votes = (data['poll_votes'] as List?) ?? const [];
    return PollOption(
      id: data['id'] as String,
      label: data['label'] as String,
      votes: votes.length,
      voted: votes.any((vote) => vote['user_id'] == userId),
    );
  }
}

class NewPostContent {
  const NewPostContent(
      {required this.body,
      this.files = const [],
      this.mediaType,
      this.pollChoices = const [],
      this.pollDuration});
  final String body;
  final List<PlatformFile> files;
  final String? mediaType;
  final List<String> pollChoices;
  final Duration? pollDuration;
}

class ChatMessage {
  const ChatMessage(
      {required this.id,
      required this.senderId,
      required this.body,
      required this.createdAt,
      this.mediaUrl,
      this.mediaType,
      this.fileName,
      this.waveform = const []});
  final String id;
  final String senderId;
  final String body;
  final DateTime createdAt;
  final String? mediaUrl;
  final String? mediaType;
  final String? fileName;
  final List<double> waveform;
  factory ChatMessage.fromMap(Map<String, dynamic> data) => ChatMessage(
        id: data['id'] as String,
        senderId: data['sender_id'] as String,
        body: data['body'] as String,
        createdAt: DateTime.parse(data['created_at'] as String).toLocal(),
        mediaUrl: data['media_url'] as String?,
        mediaType: data['media_type'] as String?,
        fileName: data['file_name'] as String?,
        waveform: ((data['waveform'] as List?) ?? const [])
            .map((value) => (value as num).toDouble())
            .toList(),
      );
}

class UserPresence {
  const UserPresence(this.lastSeenAt);

  final DateTime? lastSeenAt;

  bool get isOnline =>
      lastSeenAt != null &&
      DateTime.now().difference(lastSeenAt!).inSeconds < 75;
}

class ConversationSummary {
  const ConversationSummary({
    required this.id,
    required this.otherUserId,
    required this.name,
    required this.lastMessage,
    required this.updatedAt,
    required this.unread,
    this.unreadCount = 0,
    this.lastSenderId,
    this.avatarUrl,
  });
  final String id;
  final String otherUserId;
  final String name;
  final String lastMessage;
  final DateTime? updatedAt;
  final bool unread;
  final int unreadCount;
  final String? lastSenderId;
  final String? avatarUrl;
  factory ConversationSummary.fromMap(Map<String, dynamic> data,
      {String? currentUserId}) {
    final lastAt = data['last_message_at'] as String?;
    final readAt = data['last_read_at'] as String?;
    final lastTime = lastAt == null ? null : DateTime.parse(lastAt).toLocal();
    final readTime = readAt == null ? null : DateTime.parse(readAt).toLocal();
    final lastSenderId = data['last_sender_id'] as String?;
    final unreadCount = (data['unread_count'] as num?)?.toInt() ?? 0;
    return ConversationSummary(
      id: data['conversation_id'] as String,
      otherUserId: data['other_user_id'] as String,
      name: (data['other_name'] as String?) ?? 'Augment user',
      lastMessage: (data['last_message'] as String?) ?? 'No message yet.',
      lastSenderId: lastSenderId,
      updatedAt: lastTime,
      unreadCount: unreadCount,
      unread: unreadCount > 0 ||
          (lastSenderId != null &&
              lastSenderId != currentUserId &&
              lastTime != null &&
              (readTime == null || lastTime.isAfter(readTime))),
      avatarUrl: data['other_avatar_url'] as String?,
    );
  }

  ConversationSummary copyWith({String? avatarUrl}) => ConversationSummary(
        id: id,
        otherUserId: otherUserId,
        name: name,
        lastMessage: lastMessage,
        updatedAt: updatedAt,
        unread: unread,
        unreadCount: unreadCount,
        lastSenderId: lastSenderId,
        avatarUrl: avatarUrl ?? this.avatarUrl,
      );
}

class MessageRequest {
  const MessageRequest({
    required this.conversationId,
    required this.senderId,
    required this.senderName,
    required this.preview,
    required this.createdAt,
    this.senderAvatarUrl,
  });

  final String conversationId;
  final String senderId;
  final String senderName;
  final String preview;
  final DateTime createdAt;
  final String? senderAvatarUrl;

  factory MessageRequest.fromMap(Map<String, dynamic> data) => MessageRequest(
        conversationId: data['conversation_id'] as String,
        senderId: data['sender_id'] as String,
        senderName: (data['sender_name'] as String?) ?? 'Augment user',
        preview: (data['preview'] as String?) ?? 'Sent you a message request',
        createdAt: DateTime.parse(data['created_at'] as String).toLocal(),
        senderAvatarUrl: data['sender_avatar_url'] as String?,
      );
}

class AppNotification {
  const AppNotification({
    required this.id,
    required this.actorName,
    required this.kind,
    required this.createdAt,
    required this.read,
  });

  final String id;
  final String actorName;
  final String kind;
  final DateTime createdAt;
  final bool read;
}

class FriendRequest {
  const FriendRequest({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.createdAt,
    this.senderAvatarUrl,
  });
  final String id;
  final String senderId;
  final String senderName;
  final DateTime createdAt;
  final String? senderAvatarUrl;
}

class MarketplaceListing {
  const MarketplaceListing({
    required this.id,
    required this.ownerId,
    required this.ownerName,
    required this.title,
    required this.category,
    required this.price,
    required this.description,
    this.assetUrl,
    this.coverUrl,
  });

  final String id;
  final String ownerId;
  final String ownerName;
  final String title;
  final String category;
  final double price;
  final String description;
  final String? assetUrl;
  final String? coverUrl;

  factory MarketplaceListing.fromMap(
          Map<String, dynamic> data, String ownerName) =>
      MarketplaceListing(
        id: data['id'] as String,
        ownerId: data['owner_id'] as String,
        ownerName: ownerName,
        title: data['title'] as String,
        category: data['category'] as String,
        price: (data['price'] as num).toDouble(),
        description: data['description'] as String? ?? '',
        assetUrl: data['asset_url'] as String?,
        coverUrl: data['cover_url'] as String?,
      );
}

class NewMarketplaceListing {
  const NewMarketplaceListing({
    required this.title,
    required this.category,
    required this.price,
    required this.description,
    this.file,
    this.cover,
  });

  final String title;
  final String category;
  final double price;
  final String description;
  final PlatformFile? file;
  final PlatformFile? cover;
}

class MarketplaceSellerPayout {
  const MarketplaceSellerPayout({
    required this.recipientName,
    required this.method,
    required this.qrImageUrl,
    required this.status,
  });

  final String recipientName;
  final String method;
  final String qrImageUrl;
  final String status;

  factory MarketplaceSellerPayout.fromMap(Map<String, dynamic> row) =>
      MarketplaceSellerPayout(
        recipientName: row['recipient_name']?.toString() ?? '',
        method: row['payout_method']?.toString() ?? 'khqr',
        qrImageUrl: row['qr_image_url']?.toString() ?? '',
        status: row['payout_status']?.toString() ?? 'not_ready',
      );
}

class SocialProfileSummary {
  const SocialProfileSummary({
    required this.id,
    required this.name,
    this.avatarUrl,
  });
  final String id;
  final String name;
  final String? avatarUrl;

  factory SocialProfileSummary.fromMap(Map<String, dynamic> data) =>
      SocialProfileSummary(
        id: data['id'] as String,
        name: (data['display_name'] as String?)?.trim().isNotEmpty == true
            ? data['display_name'] as String
            : 'Augment user',
        avatarUrl: data['avatar_url'] as String?,
      );
}

class SocialProfileDetails {
  const SocialProfileDetails({
    required this.bio,
    required this.followers,
    required this.following,
  });

  final String bio;
  final int followers;
  final int following;

  SocialProfileDetails copyWith({String? bio}) => SocialProfileDetails(
        bio: bio ?? this.bio,
        followers: followers,
        following: following,
      );
}

class SocialService {
  SocialService._();
  static final instance = SocialService._();
  SupabaseClient get _db => Supabase.instance.client;
  final _localConversationChanges = StreamController<void>.broadcast();
  final _localMessageChanges = StreamController<String>.broadcast();
  String get _uid {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('You need to be signed in.');
    return uid;
  }

  Stream<List<SocialPost>> posts() async* {
    final changes = StreamController<void>();
    final postSubscription = _db
        .from('posts')
        .stream(primaryKey: ['id'])
        .order('created_at', ascending: false)
        .listen((_) => changes.add(null), onError: (_) {});
    final profileSubscription = _db.from('profiles').stream(
        primaryKey: ['id']).listen((_) => changes.add(null), onError: (_) {});
    try {
      yield await loadPosts();
      await for (final _ in changes.stream) {
        yield await loadPosts();
      }
    } finally {
      await postSubscription.cancel();
      await profileSubscription.cancel();
      await changes.close();
    }
  }

  Future<List<SocialPost>> loadPosts() async {
    final rows = await _db
        .from('posts')
        .select(
            'id,user_id,body,media_url,media_type,created_at,poll_ends_at,post_likes(user_id),post_saves(user_id),post_comments(id),post_media(media_url,media_type,position),poll_options(id,label,position,poll_votes(user_id))')
        .order('created_at', ascending: false);
    final postRows = (rows as List).cast<Map<String, dynamic>>();
    final userIds = postRows.map((row) => row['user_id'] as String).toSet();
    final profiles = userIds.isEmpty
        ? const <Map<String, dynamic>>[]
        : (await _db
                .from('profiles')
                .select('id,display_name,avatar_url')
                .inFilter('id', userIds.toList()))
            .cast<Map<String, dynamic>>();
    final profilesById = {
      for (final profile in profiles) profile['id'] as String: profile,
    };
    return postRows
        .map((row) => SocialPost.fromMap(
              {
                ...row,
                'profiles':
                    profilesById[row['user_id']] ?? const <String, dynamic>{},
              },
              _uid,
            ))
        .toList();
  }

  Future<List<SocialPost>> savedPosts() async {
    final rows =
        await _db.from('post_saves').select('post_id').eq('user_id', _uid);
    final ids = (rows as List)
        .cast<Map<String, dynamic>>()
        .map((row) => row['post_id'] as String)
        .toSet();
    return (await loadPosts()).where((post) => ids.contains(post.id)).toList();
  }

  Future<void> createPost(NewPostContent content) async {
    final values = <String, dynamic>{
      'user_id': _uid,
      'body': content.body.trim(),
      if (content.pollChoices.isNotEmpty)
        'poll_ends_at': DateTime.now()
            .toUtc()
            .add(content.pollDuration ?? const Duration(days: 1))
            .toIso8601String(),
    };
    final post = await _db.from('posts').insert(values).select('id').single();
    final uploadedPaths = <String>[];
    try {
      if (content.files.isNotEmpty && content.mediaType != null) {
        final items = <Map<String, dynamic>>[];
        for (var index = 0; index < content.files.length; index++) {
          final file = content.files[index];
          if (file.bytes == null) {
            throw StateError('One selected file could not be read.');
          }
          final safeName =
              file.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
          final path =
              '$_uid/${DateTime.now().millisecondsSinceEpoch}_${index}_$safeName';
          await _db.storage.from('social-media').uploadBinary(
                path,
                file.bytes!,
                fileOptions: FileOptions(
                  contentType: _contentType(file.extension, content.mediaType),
                ),
              );
          uploadedPaths.add(path);
          items.add({
            'post_id': post['id'],
            'media_url': _db.storage.from('social-media').getPublicUrl(path),
            'media_type': content.mediaType,
            'position': index
          });
        }
        await _db.from('post_media').insert(items);
        await _touchPost(post['id'] as String);
      }
      if (content.pollChoices.isNotEmpty) {
        await _db.from('poll_options').insert([
          for (var index = 0; index < content.pollChoices.length; index++)
            {
              'post_id': post['id'],
              'label': content.pollChoices[index],
              'position': index
            },
        ]);
      }
    } catch (_) {
      if (uploadedPaths.isNotEmpty) {
        try {
          await _db.storage.from('social-media').remove(uploadedPaths);
        } catch (_) {}
      }
      await _db.from('posts').delete().eq('id', post['id']);
      rethrow;
    }
  }

  String _contentType(String? extension, String? mediaType) {
    final ext = extension?.toLowerCase();
    if (mediaType == 'audio') {
      return switch (ext) {
        'mp3' => 'audio/mpeg',
        'm4a' => 'audio/mp4',
        'wav' => 'audio/wav',
        'aac' => 'audio/aac',
        _ => 'audio/mpeg',
      };
    }
    if (mediaType == 'video') {
      return ext == 'webm' ? 'video/webm' : 'video/mp4';
    }
    if (mediaType == 'sheet') {
      if (ext == 'pdf') return 'application/pdf';
      if (ext == 'png') return 'image/png';
      if (ext == 'webp') return 'image/webp';
      return 'image/jpeg';
    }
    return ext == 'webp' ? 'image/webp' : 'image/jpeg';
  }

  Future<void> vote(PollOption option) async {
    await _db.rpc('vote_in_poll', params: {'target_option_id': option.id});
  }

  Future<void> deletePost(String postId) async {
    final mediaRows =
        await _db.from('post_media').select('media_url').eq('post_id', postId);
    await _db.from('posts').delete().eq('id', postId).eq('user_id', _uid);
    final paths = (mediaRows as List)
        .cast<Map<String, dynamic>>()
        .map((row) => _storagePath(row['media_url'] as String?))
        .whereType<String>()
        .toList();
    if (paths.isNotEmpty) {
      try {
        await _db.storage.from('social-media').remove(paths);
      } catch (_) {}
    }
  }

  Future<void> updatePost(String postId, String body) async {
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(body, 'body', 'Post text cannot be empty.');
    }
    await _db
        .from('posts')
        .update({
          'body': trimmed,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', postId)
        .eq('user_id', _uid);
  }

  String? _storagePath(String? publicUrl) {
    if (publicUrl == null) return null;
    const marker = '/social-media/';
    final markerIndex = publicUrl.indexOf(marker);
    if (markerIndex < 0) return null;
    return Uri.decodeComponent(
        publicUrl.substring(markerIndex + marker.length));
  }

  Future<void> toggleLike(SocialPost post) async {
    if (post.isLiked) {
      await _db
          .from('post_likes')
          .delete()
          .eq('post_id', post.id)
          .eq('user_id', _uid);
    } else {
      await _db
          .from('post_likes')
          .insert({'post_id': post.id, 'user_id': _uid});
    }
    await _touchPost(post.id);
  }

  Future<void> toggleSave(SocialPost post) async {
    if (post.isSaved) {
      await _db
          .from('post_saves')
          .delete()
          .eq('post_id', post.id)
          .eq('user_id', _uid);
    } else {
      await _db
          .from('post_saves')
          .insert({'post_id': post.id, 'user_id': _uid});
    }
    await _touchPost(post.id);
  }

  Future<void> _touchPost(String postId) => _db.from('posts').update({
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', postId);

  Future<void> addComment(String postId, String body,
      {String? parentCommentId}) async {
    await _db.from('post_comments').insert({
      'post_id': postId,
      'author_id': _uid,
      'body': body.trim(),
      if (parentCommentId != null) 'parent_comment_id': parentCommentId,
    });
    await _touchPost(postId);
  }

  Stream<List<PostComment>> comments(String postId) async* {
    final changes = StreamController<void>();
    final commentSubscription = _db
        .from('post_comments')
        .stream(primaryKey: ['id'])
        .eq('post_id', postId)
        .order('created_at')
        .listen((_) => changes.add(null), onError: (_) {});
    final profileSubscription = _db.from('profiles').stream(
        primaryKey: ['id']).listen((_) => changes.add(null), onError: (_) {});
    try {
      yield await _loadComments(postId);
      await for (final _ in changes.stream) {
        yield await _loadComments(postId);
      }
    } finally {
      await commentSubscription.cancel();
      await profileSubscription.cancel();
      await changes.close();
    }
  }

  Future<List<PostComment>> _loadComments(String postId) async {
    final rows = await _db
        .from('post_comments')
        .select('id,author_id,body,created_at,parent_comment_id')
        .eq('post_id', postId)
        .order('created_at');
    final comments = (rows as List).cast<Map<String, dynamic>>();
    final ids =
        comments.map((comment) => comment['author_id'] as String).toSet();
    final profiles = ids.isEmpty
        ? const <Map<String, dynamic>>[]
        : (await _db
                .from('profiles')
                .select('id,display_name,avatar_url')
                .inFilter('id', ids.toList()))
            .cast<Map<String, dynamic>>();
    final profilesById = {
      for (final profile in profiles) profile['id'] as String: profile,
    };
    return comments
        .map((comment) => PostComment(
            id: comment['id'] as String,
            authorId: comment['author_id'] as String,
            authorName: profilesById[comment['author_id']]?['display_name']
                    as String? ??
                'Augment user',
            authorAvatarUrl:
                profilesById[comment['author_id']]?['avatar_url'] as String?,
            body: comment['body'] as String,
            parentCommentId: comment['parent_comment_id'] as String?,
            createdAt:
                DateTime.parse(comment['created_at'] as String).toLocal()))
        .toList();
  }

  Stream<List<ChatMessage>> messages(String conversationId) async* {
    final changes = StreamController<void>();
    final subscription = _db
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('conversation_id', conversationId)
        .order('created_at')
        .listen((_) => changes.add(null), onError: (_) {});
    final localSubscription = _localMessageChanges.stream
        .where((id) => id == conversationId)
        .listen((_) => changes.add(null));
    final polling =
        Timer.periodic(const Duration(seconds: 10), (_) => changes.add(null));
    try {
      yield await _loadMessages(conversationId);
      await for (final _ in changes.stream) {
        yield await _loadMessages(conversationId);
      }
    } finally {
      polling.cancel();
      await subscription.cancel();
      await localSubscription.cancel();
      await changes.close();
    }
  }

  Future<List<ChatMessage>> _loadMessages(String conversationId) async {
    final rows = await _db
        .from('messages')
        .select(
            'id,sender_id,body,created_at,media_url,media_type,file_name,waveform')
        .eq('conversation_id', conversationId)
        .order('created_at', ascending: true);
    return (rows as List)
        .cast<Map<String, dynamic>>()
        .map(ChatMessage.fromMap)
        .toList();
  }

  Future<void> sendMessage(String conversationId, String text,
      {PlatformFile? attachment, List<double>? waveform}) async {
    final body = text.trim();
    if (body.isEmpty && attachment == null) return;
    String? mediaUrl;
    String? mediaType;
    if (attachment != null) {
      final bytes = attachment.bytes;
      final filePath = attachment.path;
      if (bytes == null && filePath == null) {
        throw StateError('The selected attachment could not be read.');
      }
      final safeName =
          attachment.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final path = '$_uid/messages/$conversationId/'
          '${DateTime.now().millisecondsSinceEpoch}_$safeName';
      final uploadOptions = FileOptions(
        contentType: _messageContentType(attachment),
      );
      if (filePath != null) {
        await _db.storage
            .from('message-media')
            .upload(path, File(filePath), fileOptions: uploadOptions);
      } else {
        await _db.storage
            .from('message-media')
            .uploadBinary(path, bytes!, fileOptions: uploadOptions);
      }
      mediaUrl = _db.storage.from('message-media').getPublicUrl(path);
      mediaType =
          waveform != null ? 'voice' : _messageAttachmentType(attachment);
    }
    await _db.from('messages').insert({
      'conversation_id': conversationId,
      'sender_id': _uid,
      'body': body,
      'media_url': mediaUrl,
      'media_type': mediaType,
      'file_name': attachment?.name,
      'waveform': waveform,
    });
    // Refresh the inbox immediately for the sender as well as for Realtime
    // recipients. This keeps the newest preview visible when returning back.
    _localConversationChanges.add(null);
    // Realtime can take a moment to deliver the sender's own insert. Wake
    // the open chat immediately so its confirmed message replaces the local
    // "Sending…" preview without requiring a route refresh.
    _localMessageChanges.add(conversationId);
  }

  String _messageAttachmentType(PlatformFile file) {
    final extension = (file.extension ?? '').toLowerCase();
    if (const {'jpg', 'jpeg', 'png', 'gif', 'webp'}.contains(extension)) {
      return 'image';
    }
    if (const {'mp4', 'mov', 'avi', 'mkv', 'webm'}.contains(extension)) {
      return 'video';
    }
    if (const {'mp3', 'm4a', 'wav', 'aac', 'ogg', 'flac'}.contains(extension)) {
      return 'audio';
    }
    if (extension == 'pdf') return 'pdf';
    return 'file';
  }

  String _messageContentType(PlatformFile file) {
    final extension = (file.extension ?? '').toLowerCase();
    return switch (extension) {
      'mp4' => 'video/mp4',
      'mov' => 'video/quicktime',
      'webm' => 'video/webm',
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'mp3' => 'audio/mpeg',
      'm4a' => 'audio/mp4',
      'wav' => 'audio/wav',
      'aac' => 'audio/aac',
      'ogg' => 'audio/ogg',
      'flac' => 'audio/flac',
      'pdf' => 'application/pdf',
      _ => 'application/octet-stream',
    };
  }

  Future<void> updatePresence() async {
    if (FirebaseAuth.instance.currentUser == null) return;
    await _db.from('profiles').update({
      'last_seen_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', _uid);
  }

  Stream<UserPresence> presence(String userId) async* {
    final changes = StreamController<void>();
    final subscription = _db
        .from('profiles')
        .stream(primaryKey: ['id'])
        .eq('id', userId)
        .listen((_) => changes.add(null), onError: (_) {});
    final refresh =
        Timer.periodic(const Duration(seconds: 15), (_) => changes.add(null));

    Future<UserPresence> load() async {
      final row = await _db
          .from('profiles')
          .select('last_seen_at')
          .eq('id', userId)
          .maybeSingle();
      final value = row?['last_seen_at'] as String?;
      return UserPresence(
          value == null ? null : DateTime.parse(value).toLocal());
    }

    try {
      yield await load();
      await for (final _ in changes.stream) {
        yield await load();
      }
    } finally {
      refresh.cancel();
      await subscription.cancel();
      await changes.close();
    }
  }

  Future<void> markConversationRead(String conversationId) async {
    await _db
        .from('conversation_members')
        .update({'last_read_at': DateTime.now().toUtc().toIso8601String()})
        .eq('conversation_id', conversationId)
        .eq('user_id', _uid);
    _localConversationChanges.add(null);
  }

  Future<List<ConversationSummary>> loadConversations() async {
    final rows = await _db
        .from('conversation_summaries')
        .select()
        .order('last_message_at', ascending: false);
    final conversations = (rows as List)
        .cast<Map<String, dynamic>>()
        .map((row) => ConversationSummary.fromMap(
              row,
              currentUserId: _uid,
            ))
        .toList();
    final userIds = conversations.map((item) => item.otherUserId).toSet();
    if (userIds.isEmpty) return conversations;
    final profiles = (await _db
            .from('profiles')
            .select('id,avatar_url')
            .inFilter('id', userIds.toList()))
        .cast<Map<String, dynamic>>();
    final avatars = {
      for (final profile in profiles)
        profile['id'] as String: profile['avatar_url'] as String?,
    };
    return conversations
        .map((item) => item.copyWith(avatarUrl: avatars[item.otherUserId]))
        .toList();
  }

  Stream<List<ConversationSummary>> conversations() async* {
    // Messages are live through Supabase Realtime. Local read receipts use a
    // lightweight app signal, so this does not require Realtime on membership.
    final changes = StreamController<void>();
    final messageSubscription = _db
        .from('messages')
        .stream(primaryKey: ['id'])
        .order('created_at')
        .listen((_) => changes.add(null), onError: (_) {});
    final localReadSubscription =
        _localConversationChanges.stream.listen((_) => changes.add(null));
    final profileSubscription = _db.from('profiles').stream(
        primaryKey: ['id']).listen((_) => changes.add(null), onError: (_) {});
    final polling =
        Timer.periodic(const Duration(seconds: 12), (_) => changes.add(null));
    try {
      yield await loadConversations();
      await for (final _ in changes.stream) {
        yield await loadConversations();
      }
    } finally {
      polling.cancel();
      await messageSubscription.cancel();
      await localReadSubscription.cancel();
      await profileSubscription.cancel();
      await changes.close();
    }
  }

  Future<void> refreshConversations() async {
    _localConversationChanges.add(null);
  }

  Future<List<MessageRequest>> messageRequests() async {
    final rows = await _db
        .from('message_request_summaries')
        .select()
        .order('created_at', ascending: false);
    return (rows as List)
        .cast<Map<String, dynamic>>()
        .map(MessageRequest.fromMap)
        .toList();
  }

  Future<void> respondToMessageRequest(String conversationId,
      {required bool accept}) async {
    await _db.rpc('respond_to_message_request', params: {
      'target_conversation_id': conversationId,
      'accept_request': accept,
    });
    _localConversationChanges.add(null);
  }

  Stream<List<AppNotification>> notifications() => _db
      .from('notifications')
      .stream(primaryKey: ['id'])
      .eq('recipient_id', _uid)
      .neq('kind', 'message')
      .order('created_at', ascending: false)
      .asyncMap(_mapNotifications);

  Stream<List<FriendRequest>> followRequests() => _db
      .from('friend_requests')
      .stream(primaryKey: ['id'])
      .eq('receiver_id', _uid)
      .eq('status', 'pending')
      .order('created_at', ascending: false)
      .asyncMap(_mapFriendRequests);

  Future<Map<String, dynamic>?> profilePhotos(String userId) => _db
      .from('profiles')
      .select('avatar_url,cover_url')
      .eq('id', userId)
      .maybeSingle();

  Future<SocialProfileDetails> profileDetails(String userId) async {
    final results = await Future.wait<dynamic>([
      (() async => await _db
          .from('profiles')
          .select('bio')
          .eq('id', userId)
          .maybeSingle())(),
      (() async => await _db
          .rpc('profile_social_stats', params: {'profile_id': userId}))(),
    ]);
    final profile = results[0] as Map<String, dynamic>?;
    final stats = (results[1] as List).isEmpty
        ? const <String, dynamic>{}
        : (results[1] as List).first as Map<String, dynamic>;
    return SocialProfileDetails(
      bio: (profile?['bio'] as String? ?? '').trim(),
      followers: (stats['followers'] as num?)?.toInt() ?? 0,
      following: (stats['following'] as num?)?.toInt() ?? 0,
    );
  }

  Future<void> updateBio(String bio) =>
      _db.from('profiles').update({'bio': bio.trim()}).eq('id', _uid);

  Stream<String?> profileAvatar(String userId) => _db
      .from('profiles')
      .stream(primaryKey: ['id'])
      .eq('id', userId)
      .map((rows) => rows.isEmpty ? null : rows.first['avatar_url'] as String?);

  Stream<SocialProfileSummary?> currentProfile() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return Stream.value(null);
    return _db.from('profiles').stream(primaryKey: ['id']).eq('id', uid).map(
        (rows) =>
            rows.isEmpty ? null : SocialProfileSummary.fromMap(rows.first));
  }

  Future<String> uploadProfilePhoto(PlatformFile file,
      {required bool cover}) async {
    if (file.bytes == null || file.size > 10 * 1024 * 1024) {
      throw StateError('Choose an image smaller than 10 MB.');
    }
    final extension = file.extension?.toLowerCase();
    if (!['jpg', 'jpeg', 'png', 'webp'].contains(extension)) {
      throw StateError('Choose a JPG, PNG, or WebP image.');
    }
    final path =
        '$_uid/profile/${DateTime.now().microsecondsSinceEpoch}.$extension';
    final bucket = _db.storage.from('social-media');
    await bucket.uploadBinary(path, file.bytes!,
        fileOptions: FileOptions(
            contentType: extension == 'jpg' || extension == 'jpeg'
                ? 'image/jpeg'
                : 'image/$extension'));
    final url = bucket.getPublicUrl(path);
    try {
      await _db
          .from('profiles')
          .update({cover ? 'cover_url' : 'avatar_url': url})
          .eq('id', _uid)
          .select('id')
          .single();
      _localConversationChanges.add(null);
    } catch (_) {
      await bucket.remove([path]);
      rethrow;
    }
    return url;
  }

  Future<bool> hasPendingFollowRequest(String receiverId) async {
    final rows = await _db
        .from('friend_requests')
        .select('id')
        .eq('sender_id', _uid)
        .eq('receiver_id', receiverId)
        .eq('status', 'pending');
    return rows.isNotEmpty;
  }

  Future<void> cancelFollowRequest(String receiverId) async {
    await _db
        .from('friend_requests')
        .delete()
        .eq('sender_id', _uid)
        .eq('receiver_id', receiverId)
        .eq('status', 'pending');
  }

  Future<void> unfollow(String otherUserId) async {
    await _db
        .from('friend_requests')
        .delete()
        .eq('sender_id', _uid)
        .eq('receiver_id', otherUserId)
        .eq('status', 'accepted');
  }

  Future<void> sendFollowRequest(String receiverId) => _db
      .from('friend_requests')
      .insert({'sender_id': _uid, 'receiver_id': receiverId});

  Future<void> respondToFollowRequest(String requestId,
          {required bool accept}) =>
      _db
          .from('friend_requests')
          .update({'status': accept ? 'accepted' : 'declined'})
          .eq('id', requestId)
          .eq('receiver_id', _uid);

  /// Accounts connected by an accepted follow can start a direct message.
  Future<List<SocialProfileSummary>> messageContacts(
      [String query = '']) async {
    final relationships = await _db
        .from('friend_requests')
        .select('sender_id,receiver_id')
        .eq('status', 'accepted')
        .or('sender_id.eq.$_uid,receiver_id.eq.$_uid');
    final friendIds = (relationships as List)
        .cast<Map<String, dynamic>>()
        .map((row) => row['sender_id'] == _uid
            ? row['receiver_id'] as String
            : row['sender_id'] as String)
        .toSet()
        .toList();
    if (friendIds.isEmpty) return const [];

    final profiles = await _db
        .from('profiles')
        .select('id,display_name,avatar_url')
        .inFilter('id', friendIds)
        .order('display_name');
    final cleanQuery = query.trim().toLowerCase();
    return (profiles as List)
        .cast<Map<String, dynamic>>()
        .map(SocialProfileSummary.fromMap)
        .where((profile) =>
            cleanQuery.isEmpty ||
            profile.name.toLowerCase().contains(cleanQuery))
        .toList();
  }

  Future<bool> isFollowing(String otherUserId) async {
    final rows = await _db
        .from('friend_requests')
        .select('id')
        .eq('status', 'accepted')
        .eq('sender_id', _uid)
        .eq('receiver_id', otherUserId)
        .limit(1);
    return (rows as List).isNotEmpty;
  }

  Future<bool> isFollowedBy(String otherUserId) async {
    final rows = await _db
        .from('friend_requests')
        .select('id')
        .eq('status', 'accepted')
        .eq('sender_id', otherUserId)
        .eq('receiver_id', _uid)
        .limit(1);
    return (rows as List).isNotEmpty;
  }

  /// Profiles the current account is not already following or requesting.
  Future<List<SocialProfileSummary>> followSuggestions({int limit = 12}) async {
    final profilesFuture = _db
        .from('profiles')
        .select('id,display_name,avatar_url')
        .order('updated_at', ascending: false)
        .limit(limit + 8);
    final relationshipsFuture = _db
        .from('friend_requests')
        .select('sender_id,receiver_id')
        .or('sender_id.eq.$_uid,receiver_id.eq.$_uid');

    final results = await Future.wait([profilesFuture, relationshipsFuture]);
    final alreadyFollowingIds = <String>{
      for (final row in (results[1] as List).cast<Map<String, dynamic>>())
        if (row['sender_id'] == _uid) row['receiver_id'] as String,
    };
    return (results[0] as List)
        .cast<Map<String, dynamic>>()
        .map(SocialProfileSummary.fromMap)
        .where((profile) =>
            profile.id != _uid && !alreadyFollowingIds.contains(profile.id))
        .take(limit)
        .toList();
  }

  Future<List<FriendRequest>> _mapFriendRequests(
      List<Map<String, dynamic>> rows) async {
    final senderIds =
        rows.map((row) => row['sender_id'] as String).toSet().toList();
    final profiles = senderIds.isEmpty
        ? const <Map<String, dynamic>>[]
        : (await _db
                .from('profiles')
                .select('id,display_name,avatar_url')
                .inFilter('id', senderIds))
            .cast<Map<String, dynamic>>();
    final names = {
      for (final profile in profiles)
        profile['id'] as String:
            (profile['display_name'] as String?) ?? 'Augment user'
    };
    final avatars = {
      for (final profile in profiles)
        profile['id'] as String: profile['avatar_url'] as String?,
    };
    return rows
        .map((row) => FriendRequest(
              id: row['id'] as String,
              senderId: row['sender_id'] as String,
              senderName: names[row['sender_id']] ?? 'Augment user',
              senderAvatarUrl: avatars[row['sender_id']],
              createdAt: DateTime.parse(row['created_at'] as String).toLocal(),
            ))
        .toList();
  }

  Stream<List<MarketplaceListing>> marketplaceListings(String ownerId) => _db
      .from('market_listings')
      .stream(primaryKey: ['id'])
      .eq('owner_id', ownerId)
      .order('created_at', ascending: false)
      .asyncMap(_mapMarketplaceListings);

  Stream<List<MarketplaceListing>> marketplaceFeed() => _db
      .from('market_listings')
      .stream(primaryKey: ['id'])
      .order('created_at', ascending: false)
      .asyncMap(_mapMarketplaceListings);

  Future<List<MarketplaceListing>> _mapMarketplaceListings(
      List<Map<String, dynamic>> rows) async {
    final ids = rows.map((row) => row['owner_id'] as String).toSet().toList();
    final profiles = ids.isEmpty
        ? const <Map<String, dynamic>>[]
        : (await _db
                .from('profiles')
                .select('id,display_name')
                .inFilter('id', ids))
            .cast<Map<String, dynamic>>();
    final names = {
      for (final profile in profiles)
        profile['id'] as String:
            (profile['display_name'] as String?)?.trim().isNotEmpty == true
                ? profile['display_name'] as String
                : 'Augment user',
    };
    return rows
        .map((row) => MarketplaceListing.fromMap(
            row, names[row['owner_id']] ?? 'Augment user'))
        .toList();
  }

  Future<void> createMarketplaceListing(NewMarketplaceListing listing) async {
    Future<String?> uploadMarketplaceFile(
        PlatformFile? file, String folder) async {
      if (file?.bytes == null) return null;
      final safeName = file!.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final path = '$_uid/marketplace/$folder/'
          '${DateTime.now().millisecondsSinceEpoch}_$safeName';
      await _db.storage.from('social-media').uploadBinary(
            path,
            file.bytes!,
            fileOptions:
                FileOptions(contentType: _marketplaceContentType(file)),
          );
      return _db.storage.from('social-media').getPublicUrl(path);
    }

    final assetUrl = await uploadMarketplaceFile(listing.file, 'files');
    final coverUrl = await uploadMarketplaceFile(listing.cover, 'covers');
    await _db.from('market_listings').insert({
      'owner_id': _uid,
      'title': listing.title.trim(),
      'category': listing.category,
      'price': listing.price,
      'description': listing.description.trim(),
      'asset_url': assetUrl,
      'cover_url': coverUrl,
    });
  }

  Future<MarketplaceSellerPayout?> sellerPayout() async {
    final row = await _db
        .from('marketplace_seller_payouts')
        .select('recipient_name,payout_method,qr_image_url,payout_status')
        .eq('owner_id', _uid)
        .maybeSingle();
    if (row == null) return null;
    return MarketplaceSellerPayout.fromMap(Map<String, dynamic>.from(row));
  }

  Future<void> saveSellerPayout({
    required String recipientName,
    required String method,
    required PlatformFile qrImage,
  }) async {
    if (qrImage.bytes == null || qrImage.bytes!.isEmpty) {
      throw StateError('Choose a valid QR image.');
    }
    final extension = (qrImage.extension ?? 'png').toLowerCase();
    if (!const {'png', 'jpg', 'jpeg', 'webp'}.contains(extension)) {
      throw StateError('Use a PNG, JPG, or WEBP QR image.');
    }
    final filename = qrImage.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final path =
        '$_uid/marketplace/payout/${DateTime.now().millisecondsSinceEpoch}_$filename';
    await _db.storage.from('social-media').uploadBinary(
          path,
          qrImage.bytes!,
          fileOptions:
              FileOptions(contentType: _marketplaceContentType(qrImage)),
        );
    final imageUrl = _db.storage.from('social-media').getPublicUrl(path);
    await _db.from('marketplace_seller_payouts').upsert({
      'owner_id': _uid,
      'recipient_name': recipientName.trim(),
      'payout_method': method,
      'qr_image_url': imageUrl,
      'payout_status': 'not_ready',
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> deleteMarketplaceListing(String listingId) async {
    await _db
        .from('market_listings')
        .delete()
        .eq('id', listingId)
        .eq('owner_id', _uid);
  }

  String _marketplaceContentType(PlatformFile file) {
    switch (file.extension?.toLowerCase()) {
      case 'pdf':
        return 'application/pdf';
      case 'mp3':
        return 'audio/mpeg';
      case 'wav':
        return 'audio/wav';
      case 'm4a':
        return 'audio/mp4';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'txt':
        return 'text/plain';
      default:
        return 'application/octet-stream';
    }
  }

  Future<List<AppNotification>> _mapNotifications(
      List<Map<String, dynamic>> rows) async {
    final actorIds = rows
        .map((row) => row['actor_id'] as String?)
        .whereType<String>()
        .toSet()
        .toList();
    final profiles = actorIds.isEmpty
        ? const <Map<String, dynamic>>[]
        : (await _db
                .from('profiles')
                .select('id,display_name')
                .inFilter('id', actorIds))
            .cast<Map<String, dynamic>>();
    final names = {
      for (final profile in profiles)
        profile['id'] as String:
            (profile['display_name'] as String?)?.trim().isNotEmpty == true
                ? profile['display_name'] as String
                : 'Augment user',
    };
    return rows
        .map((row) => AppNotification(
              id: row['id'] as String,
              actorName: names[row['actor_id']] ?? 'Augment',
              kind: row['kind'] as String? ?? 'activity',
              createdAt: DateTime.parse(row['created_at'] as String).toLocal(),
              read: row['read_at'] != null,
            ))
        .toList();
  }

  Future<void> markNotificationsRead() => _db
      .from('notifications')
      .update({'read_at': DateTime.now().toUtc().toIso8601String()})
      .eq('recipient_id', _uid)
      .isFilter('read_at', null);

  Future<String> startDirectConversation(String otherUserId) async {
    final currentUserId = _uid;
    if (otherUserId == currentUserId) {
      throw StateError('You cannot message yourself');
    }

    // 1. Check if a conversation between the two users already exists in conversation_members
    try {
      final myMemberships = await _db
          .from('conversation_members')
          .select('conversation_id')
          .eq('user_id', currentUserId);
      final myConvIds = (myMemberships as List)
          .map((m) => m['conversation_id'] as String)
          .toList();
      if (myConvIds.isNotEmpty) {
        final shared = await _db
            .from('conversation_members')
            .select('conversation_id')
            .inFilter('conversation_id', myConvIds)
            .eq('user_id', otherUserId)
            .limit(1);
        if ((shared as List).isNotEmpty) {
          final foundId = (shared as List).first['conversation_id'] as String;
          return foundId;
        }
      }
    } catch (_) {
      // Proceed to RPC if direct membership check encounters an issue
    }

    // 2. Try Supabase RPC 'start_direct_conversation'
    try {
      final id = await _db.rpc('start_direct_conversation',
          params: {'other_user_id': otherUserId});
      if (id != null && id.toString().trim().isNotEmpty) {
        return id.toString();
      }
    } catch (_) {
      // The RPC may fail if the database still has the older friend-only constraint
      // or if the migration is not yet applied. Fall back to direct table insertion.
    }

    // 3. Fallback: try inserting conversation and membership directly
    try {
      final newConv = await _db
          .from('conversations')
          .insert({
            'created_at': DateTime.now().toUtc().toIso8601String(),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .select('id')
          .single();
      final convId = newConv['id'] as String;

      try {
        await _db.from('conversation_members').insert([
          {'conversation_id': convId, 'user_id': currentUserId},
          {'conversation_id': convId, 'user_id': otherUserId},
        ]);
      } catch (_) {
        try {
          await _db.from('conversation_members').insert({
            'conversation_id': convId,
            'user_id': currentUserId,
          });
        } catch (_) {}
      }
      return convId;
    } catch (_) {
      // Proceed to deterministic fallback
    }

    // 4. Deterministic fallback UUID:
    // Generate a consistent, valid UUID derived from the two user IDs.
    // This guarantees both participants resolve to the exact same conversation ID.
    return deterministicConversationId(currentUserId, otherUserId);
  }

  static String deterministicConversationId(String userA, String userB) {
    final sorted = [userA, userB]..sort();
    final combined = 'aug_conv_${sorted[0]}_${sorted[1]}';
    var h1 = 0x811c9dc5;
    var h2 = 0x5bd1e995;
    for (var i = 0; i < combined.length; i++) {
      final c = combined.codeUnitAt(i);
      h1 = ((h1 ^ c) * 0x01000193) & 0xFFFFFFFF;
      h2 = ((h2 ^ (c * 31)) * 0x01000193) & 0xFFFFFFFF;
    }
    final hex1 = h1.toRadixString(16).padLeft(8, '0');
    final hex2 = h2.toRadixString(16).padLeft(8, '0');
    final hex3 = (h1 ^ 0xAAAAAAAA).toRadixString(16).padLeft(8, '0');
    final hex4 = (h2 ^ 0x55555555).toRadixString(16).padLeft(8, '0');
    final full = '$hex1$hex2$hex3$hex4';
    return '${full.substring(0, 8)}-${full.substring(8, 12)}-4${full.substring(13, 16)}-a${full.substring(17, 20)}-${full.substring(20, 32)}';
  }

  Future<List<SocialProfileSummary>> searchProfiles(String query) async {
    final cleanQuery = query.trim();
    final rows = cleanQuery.isEmpty
        ? await _db
            .from('profiles')
            .select('id,display_name,avatar_url')
            .order('updated_at', ascending: false)
            .limit(20)
        : await _db
            .from('profiles')
            .select('id,display_name,avatar_url')
            .ilike('display_name', '%$cleanQuery%')
            .limit(20);
    return (rows as List)
        .cast<Map<String, dynamic>>()
        .map(SocialProfileSummary.fromMap)
        .toList();
  }

  Future<List<SocialPost>> searchPosts(String query) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) return const [];
    final rows = await _db
        .from('posts')
        .select(
            'id,user_id,body,media_url,media_type,created_at,poll_ends_at,post_likes(user_id),post_saves(user_id),post_comments(id),post_media(media_url,media_type,position),poll_options(id,label,position,poll_votes(user_id))')
        .ilike('body', '%$cleanQuery%')
        .order('created_at', ascending: false)
        .limit(20);
    final postRows = (rows as List).cast<Map<String, dynamic>>();
    // Do not embed `profiles` here: posts has several indirect profile
    // relationships through likes, saves, and poll votes. A separate lookup
    // removes that ambiguity in PostgREST and matches the normal feed path.
    final authorIds = postRows.map((row) => row['user_id'] as String).toSet();
    final profiles = authorIds.isEmpty
        ? const <Map<String, dynamic>>[]
        : (await _db
                .from('profiles')
                .select('id,display_name,avatar_url')
                .inFilter('id', authorIds.toList()))
            .cast<Map<String, dynamic>>();
    final profilesById = {
      for (final profile in profiles) profile['id'] as String: profile,
    };
    return postRows
        .map((row) => SocialPost.fromMap({
              ...row,
              'profiles':
                  profilesById[row['user_id']] ?? const <String, dynamic>{},
            }, _uid))
        .toList();
  }
}
