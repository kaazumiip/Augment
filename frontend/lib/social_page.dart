import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:video_player/video_player.dart';
import 'animated_mascot.dart';
import 'social_service.dart';
import 'create_post_page.dart';
import 'app_palette.dart';
import 'social_avatar.dart';
import 'messages_page.dart';
import 'friend_requests_page.dart';
import 'morphing_search_bar.dart';
import 'social_search_page.dart';
import 'social_profile_page.dart';
import 'notifications_page.dart';
import 'comments_page.dart';

class SocialPage extends StatefulWidget {
  const SocialPage({Key? key}) : super(key: key);

  static const Color _red = Color(0xFFCA000A);
  static const Color _ink = Color(0xFF202020);
  static const String _font = 'Instrument Sans';
  static const String font = 'Instrument Sans';

  @override
  State<SocialPage> createState() => _SocialPageState();
}

class _SocialPageState extends State<SocialPage> {
  final _service = SocialService.instance;
  final _headerSearchController = TextEditingController();
  StreamSubscription<List<SocialPost>>? _postsSubscription;
  List<SocialPost>? _posts;
  String? _feedError;
  bool _posting = false;
  late Future<List<SocialProfileSummary>> _suggestions;

  @override
  void initState() {
    super.initState();
    _suggestions = _service.followSuggestions();
    _postsSubscription = _service.posts().listen(
      (posts) {
        if (mounted) {
          setState(() {
            _posts = posts;
            _feedError = null;
          });
        }
      },
      onError: (Object error) {
        if (mounted) setState(() => _feedError = error.toString());
      },
    );
    _refreshPosts();
  }

  @override
  void dispose() {
    _headerSearchController.dispose();
    _postsSubscription?.cancel();
    super.dispose();
  }

  Future<void> _composePost([String? initialAction]) async {
    final displayName = FirebaseAuth.instance.currentUser?.displayName?.trim();
    final name =
        displayName?.isNotEmpty == true ? displayName! : 'Augment user';
    final body = await Navigator.push<NewPostContent>(
      context,
      MaterialPageRoute(
        builder: (_) => CreatePostPage(
          name: name,
          initialAction: initialAction,
        ),
      ),
    );
    if (body == null ||
        (body.body.trim().isEmpty &&
            body.files.isEmpty &&
            body.pollChoices.isEmpty)) {
      return;
    }
    setState(() => _posting = true);
    try {
      await _service.createPost(body);
      await _refreshPosts();
    } catch (error) {
      if (mounted) {
        final message = error.toString().toLowerCase().contains('media_type')
            ? 'Run the updated Supabase SQL once more before posting media.'
            : 'Could not publish your post: $error';
        _showError(message);
      }
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Future<void> _refreshPosts() async {
    try {
      final posts = await _service.loadPosts();
      if (mounted) {
        setState(() {
          _posts = posts;
          _feedError = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _feedError = error.toString());
    }
  }

  Future<void> _comment(SocialPost post) async {
    final controller = TextEditingController();
    final body = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add comment'),
        content:
            TextField(controller: controller, autofocus: true, maxLines: 3),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Send')),
        ],
      ),
    );
    if (body == null || body.trim().isEmpty) return;
    try {
      await _service.addComment(post.id, body);
    } catch (_) {
      if (mounted) _showError('Could not add your comment.');
    }
  }

  void _showError(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  void _replacePost(String id, SocialPost Function(SocialPost) update) {
    final posts = _posts;
    if (posts == null) return;
    setState(() => _posts = [
          for (final post in posts) post.id == id ? update(post) : post,
        ]);
  }

  Future<void> _toggleLike(SocialPost post) async {
    _replacePost(
        post.id,
        (current) => current.copyWith(
            isLiked: !current.isLiked,
            likes: (current.likes + (current.isLiked ? -1 : 1))
                .clamp(0, 1 << 30)));
    try {
      await _service.toggleLike(post);
    } catch (_) {
      _replacePost(post.id, (_) => post);
      if (mounted) _showError('Could not update the reaction.');
    }
  }

  Future<void> _toggleSave(SocialPost post) async {
    _replacePost(
        post.id, (current) => current.copyWith(isSaved: !current.isSaved));
    try {
      await _service.toggleSave(post);
    } catch (_) {
      _replacePost(post.id, (_) => post);
      if (mounted) _showError('Could not update saved posts.');
    }
  }

  Future<void> _deletePost(SocialPost post) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete post?'),
        content: const Text('This post will be permanently removed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: SocialPage._red),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    final previous = _posts;
    setState(
        () => _posts = previous?.where((item) => item.id != post.id).toList());
    try {
      await _service.deletePost(post.id);
    } catch (_) {
      if (mounted) {
        setState(() => _posts = previous);
        _showError('Could not delete this post.');
      }
    }
  }

  Future<void> _editPost(SocialPost post) async {
    final controller = TextEditingController(text: post.body);
    final body = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(
            20, 18, 20, MediaQuery.viewInsetsOf(sheetContext).bottom + 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Edit post',
              style: TextStyle(
                  color: AppPalette.text(sheetContext),
                  fontSize: 19,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            autofocus: true,
            minLines: 3,
            maxLines: 7,
            maxLength: 1000,
            decoration: const InputDecoration(hintText: 'Share your update'),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: SocialPage._red),
              onPressed: () => Navigator.pop(sheetContext, controller.text),
              child: const Text('Save changes'),
            ),
          ),
        ]),
      ),
    );
    controller.dispose();
    if (body == null || body.trim().isEmpty || body.trim() == post.body) return;
    try {
      await _service.updatePost(post.id, body);
      _replacePost(post.id, (current) => current.copyWith(body: body.trim()));
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Post updated.')));
      }
    } catch (_) {
      if (mounted) _showError('Could not update this post.');
    }
  }

  void _showPostActions(SocialPost post) {
    final ownsPost = post.authorId == FirebaseAuth.instance.currentUser?.uid;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Wrap(children: [
          ListTile(
            leading: const Icon(Icons.copy_rounded),
            title: const Text('Copy post text'),
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: post.body));
              if (sheetContext.mounted) Navigator.pop(sheetContext);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Post text copied.')));
              }
            },
          ),
          if (ownsPost)
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit post'),
              onTap: () {
                Navigator.pop(sheetContext);
                _editPost(post);
              },
            ),
          if (ownsPost)
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded,
                  color: SocialPage._red),
              title: const Text('Delete post',
                  style: TextStyle(color: SocialPage._red)),
              onTap: () {
                Navigator.pop(sheetContext);
                _deletePost(post);
              },
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final displayName = FirebaseAuth.instance.currentUser?.displayName?.trim();
    final name = displayName?.isNotEmpty == true ? displayName! : 'there';
    return Stack(children: [
      ColoredBox(
        color: AppPalette.page(context),
        child: RefreshIndicator(
          color: SocialPage._red,
          onRefresh: _refreshPosts,
          child: ListView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 120),
            children: [
              _SocialHeader(searchController: _headerSearchController),
              const SizedBox(height: 34),
              _ComposerCard(
                name: name,
                onTap: _composePost,
                onChooseAction: _composePost,
              ),
              const SizedBox(height: 20),
              _FriendSuggestions(
                suggestions: _suggestions,
                onOpenProfile: (profile) =>
                    _openProfile(context, profile.name, profile.id),
                onSent: () =>
                    setState(() => _suggestions = _service.followSuggestions()),
              ),
              const SizedBox(height: 24),
              Builder(builder: (context) {
                final posts = _posts;
                if (_feedError != null && posts == null) {
                  return _FeedError(
                      message: _feedError!, onRetry: _refreshPosts);
                }
                if (posts == null) return const _FeedLoading();
                if (posts.isEmpty) return const _EmptyFeed();
                return Column(
                    children: posts
                        .map((post) => Padding(
                              padding: const EdgeInsets.only(bottom: 30),
                              child: SocialPostCard(
                                avatar: SocialAccountAvatar(
                                  name: post.authorName,
                                  imageUrl: post.authorAvatarUrl,
                                ),
                                author: post.authorName,
                                time: _relativeTime(post.createdAt),
                                body: post.body,
                                likes: '${post.likes}',
                                comments: '${post.comments}',
                                saves: post.isSaved ? 'Saved' : 'Save',
                                liked: post.isLiked,
                                onTap: () => _openPost(post),
                                onLike: () => _toggleLike(post),
                                onComment: () => _openPost(post),
                                saved: post.isSaved,
                                onSave: () => _toggleSave(post),
                                onMore: () => _showPostActions(post),
                                attachment: (post.media.isNotEmpty ||
                                        post.mediaUrl != null ||
                                        post.pollOptions.isNotEmpty)
                                    ? SocialPostAttachment(post: post)
                                    : null,
                                onProfileTap: () => _openProfile(
                                    context, post.authorName, post.authorId),
                              ),
                            ))
                        .toList());
              }),
            ],
          ),
        ),
      ),
      if (_posting)
        Positioned(
          left: 18,
          right: 18,
          bottom: 96,
          child: _PostUploadBanner(hasMedia: true),
        ),
    ]);
  }

  String _relativeTime(DateTime time) {
    final difference = DateTime.now().difference(time);
    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inHours < 1) return '${difference.inMinutes}m ago';
    if (difference.inDays < 1) return '${difference.inHours}h ago';
    return '${difference.inDays}d ago';
  }

  void _openProfile(BuildContext context, String name, [String? userId]) {
    final isOwnProfile =
        userId != null && userId == FirebaseAuth.instance.currentUser?.uid;
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => SocialProfilePage(
                name: name, isOwnProfile: isOwnProfile, userId: userId)));
  }

  void _openPost(SocialPost post) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CommentsPage(
          post: post,
          onPostUpdated: (updated) => _replacePost(updated.id, (_) => updated),
          onPostDeleted: (deleted) =>
              setState(() => _posts?.removeWhere((p) => p.id == deleted.id)),
        ),
      ),
    );
  }
}

class _FeedLoading extends StatelessWidget {
  const _FeedLoading();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 46),
        child: Center(
          child: CircularProgressIndicator(
              strokeWidth: 2.4, color: SocialPage._red),
        ),
      );
}

class _EmptyFeed extends StatelessWidget {
  const _EmptyFeed();
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 42, horizontal: 18),
        child: Column(children: [
          const AnimatedMascot(height: 118),
          const SizedBox(height: 8),
          Text('No posts yet',
              style: TextStyle(
                  color: AppPalette.text(context),
                  fontSize: 17,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 5),
          Text('Start the conversation with something you are working on.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppPalette.muted(context), fontSize: 13)),
        ]),
      );
}

class _FeedError extends StatelessWidget {
  const _FeedError({required this.message, required this.onRetry});
  final String message;
  final Future<void> Function() onRetry;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 38),
        child: Column(children: [
          const Icon(Icons.cloud_off_rounded, color: SocialPage._red, size: 32),
          const SizedBox(height: 10),
          Text('Could not load the community',
              style: TextStyle(
                  color: AppPalette.text(context),
                  fontSize: 16,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 5),
          Text(message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppPalette.muted(context), fontSize: 12)),
          const SizedBox(height: 14),
          OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry')),
        ]),
      );
}

class _FriendSuggestions extends StatelessWidget {
  const _FriendSuggestions({
    required this.suggestions,
    required this.onOpenProfile,
    required this.onSent,
  });

  final Future<List<SocialProfileSummary>> suggestions;
  final ValueChanged<SocialProfileSummary> onOpenProfile;
  final VoidCallback onSent;

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<List<SocialProfileSummary>>(
        future: suggestions,
        builder: (context, snapshot) {
          if (snapshot.hasError ||
              !snapshot.hasData ||
              snapshot.data!.isEmpty) {
            return const SizedBox.shrink();
          }
          final profiles = snapshot.data!;
          return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: SocialPage._red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: const Icon(Icons.group_add_rounded,
                        size: 20, color: SocialPage._red),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('People you may know',
                          style: TextStyle(
                              color: AppPalette.text(context),
                              fontFamily: SocialPage._font,
                              fontSize: 17,
                              fontWeight: FontWeight.w800)),
                      const SizedBox(height: 1),
                      Text('Follow fellow creators',
                          style: TextStyle(
                              color: AppPalette.muted(context), fontSize: 12)),
                    ],
                  )),
                  Text('${profiles.length}',
                      style: const TextStyle(
                          color: SocialPage._red,
                          fontSize: 13,
                          fontWeight: FontWeight.w800)),
                ]),
                const SizedBox(height: 14),
                SizedBox(
                  height: 188,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    itemCount: profiles.length,
                    clipBehavior: Clip.none,
                    separatorBuilder: (_, __) => const SizedBox(width: 12),
                    itemBuilder: (context, index) => _FriendSuggestionCard(
                      profile: profiles[index],
                      onOpenProfile: () => onOpenProfile(profiles[index]),
                      onSent: onSent,
                    ),
                  ),
                ),
              ]);
        },
      );
}

class _FriendSuggestionCard extends StatefulWidget {
  const _FriendSuggestionCard({
    required this.profile,
    required this.onOpenProfile,
    required this.onSent,
  });

  final SocialProfileSummary profile;
  final VoidCallback onOpenProfile;
  final VoidCallback onSent;

  @override
  State<_FriendSuggestionCard> createState() => _FriendSuggestionCardState();
}

class _FriendSuggestionCardState extends State<_FriendSuggestionCard> {
  bool _sending = false;
  bool _pending = false;

  Future<void> _sendRequest() async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      await SocialService.instance.sendFollowRequest(widget.profile.id);
      if (mounted) {
        setState(() {
          _sending = false;
          _pending = true;
        });
        final messenger = ScaffoldMessenger.of(context);
        final receiverId = widget.profile.id;
        messenger.showSnackBar(SnackBar(
          duration: const Duration(seconds: 2),
          content: const Text('Follow request pending'),
          action: SnackBarAction(
              label: 'Undo',
              onPressed: () async {
                try {
                  await SocialService.instance.cancelFollowRequest(receiverId);
                  messenger.showSnackBar(const SnackBar(
                      duration: Duration(milliseconds: 1200),
                      content: Text('Follow request cancelled')));
                } catch (_) {
                  messenger.showSnackBar(const SnackBar(
                      content: Text(
                          'Could not cancel the request. Try from their profile.')));
                }
              }),
        ));
        // Let the new state be visible before the refreshed suggestions omit
        // people who already have an outgoing request.
        await Future<void>.delayed(const Duration(milliseconds: 650));
        if (!mounted) return;
        widget.onSent();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not send follow request.')));
      }
    } finally {
      if (mounted && !_pending) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Container(
        width: 154,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppPalette.border(context)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          InkWell(
            onTap: widget.onOpenProfile,
            borderRadius: BorderRadius.circular(28),
            child: CircleAvatar(
              radius: 25,
              backgroundColor: SocialPage._red.withValues(alpha: 0.1),
              backgroundImage: widget.profile.avatarUrl == null ||
                      widget.profile.avatarUrl!.isEmpty
                  ? null
                  : NetworkImage(widget.profile.avatarUrl!),
              child: widget.profile.avatarUrl == null ||
                      widget.profile.avatarUrl!.isEmpty
                  ? Text(widget.profile.name.substring(0, 1).toUpperCase(),
                      style: const TextStyle(
                          color: SocialPage._red,
                          fontSize: 18,
                          fontWeight: FontWeight.w800))
                  : null,
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              InkWell(
                onTap: widget.onOpenProfile,
                child: Text(widget.profile.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: AppPalette.text(context),
                        fontFamily: SocialPage._font,
                        fontSize: 14,
                        height: 1.15,
                        fontWeight: FontWeight.w800)),
              ),
              const SizedBox(height: 5),
              Text('Suggested for you',
                  style: TextStyle(
                      color: AppPalette.muted(context), fontSize: 11)),
            ]),
          ),
          SizedBox(
            width: double.infinity,
            height: 36,
            child: FilledButton.icon(
              onPressed: _sending || _pending ? null : _sendRequest,
              style: FilledButton.styleFrom(
                backgroundColor:
                    _pending ? const Color(0xFFF4EEE9) : SocialPage._red,
                foregroundColor: _pending ? SocialPage._red : Colors.white,
                side: _pending
                    ? const BorderSide(color: SocialPage._red, width: 1)
                    : BorderSide.none,
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(9)),
              ),
              icon: _sending
                  ? const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.8, color: Colors.white))
                  : Icon(
                      _pending
                          ? Icons.schedule_rounded
                          : Icons.person_add_alt_1_rounded,
                      size: 16),
              label: Text(_pending ? 'Request pending' : 'Follow',
                  style: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w800)),
            ),
          ),
        ]),
      );
}

class _PostUploadBanner extends StatelessWidget {
  const _PostUploadBanner({required this.hasMedia});
  final bool hasMedia;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
          decoration: BoxDecoration(
            color: AppPalette.surface(context),
            borderRadius: BorderRadius.circular(10),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x24000000),
                  blurRadius: 10,
                  offset: Offset(0, 4))
            ],
          ),
          child: Row(children: [
            const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2.4, color: SocialPage._red)),
            const SizedBox(width: 12),
            Expanded(
                child: Text(
                    hasMedia
                        ? 'Uploading your post...'
                        : 'Publishing your post...',
                    style: TextStyle(
                        color: AppPalette.text(context),
                        fontSize: 13,
                        fontWeight: FontWeight.w700))),
          ]),
        ),
      );
}

class _SocialHeader extends StatelessWidget {
  const _SocialHeader({required this.searchController});
  final TextEditingController searchController;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Stack(children: [
        Align(
          alignment: Alignment.centerLeft,
          child: const LogoBackMorph(tag: 'social-logo-back', showBack: false),
        ),
        Positioned(
          right: 138,
          child: const _UnreadMessageAction(),
        ),
        Positioned(
          right: 92,
          child: const _FriendRequestsAction(),
        ),
        Positioned(
          right: 46,
          child: const _NotificationsAction(),
        ),
        Positioned(
          right: 1,
          child: MorphingSearchBar(
            controller: searchController,
            hintText: 'Search people',
            onChanged: (_) {},
            heroTag: 'social-search',
            collapsedSize: 38,
            width: MediaQuery.sizeOf(context).width - 94,
            onOpen: () async {
              await Navigator.push(
                  context, morphSearchRoute((_) => const SocialSearchPage()));
            },
          ),
        ),
      ]),
    );
  }
}

class _UnreadMessageAction extends StatelessWidget {
  const _UnreadMessageAction();

  @override
  Widget build(BuildContext context) =>
      StreamBuilder<List<ConversationSummary>>(
        stream: SocialService.instance.conversations(),
        builder: (context, snapshot) {
          final unread = (snapshot.data ?? const <ConversationSummary>[])
              .where((conversation) => conversation.unread)
              .length;
          return Stack(clipBehavior: Clip.none, children: [
            _CircleAction(
              icon: Icons.send_rounded,
              background:
                  AppPalette.isDark(context) ? Colors.white : Colors.black,
              foreground:
                  AppPalette.isDark(context) ? Colors.black : Colors.white,
              size: 38,
              iconSize: 19,
              rotation: -0.25,
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const MessagesPage())),
            ),
            if (unread > 0)
              Positioned(
                right: -5,
                top: -5,
                child: Container(
                  constraints:
                      const BoxConstraints(minWidth: 20, minHeight: 20),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                      color: SocialPage._red, shape: BoxShape.circle),
                  child: Text(unread > 9 ? '9+' : '$unread',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w800)),
                ),
              ),
          ]);
        },
      );
}

class _FriendRequestsAction extends StatelessWidget {
  const _FriendRequestsAction();

  @override
  Widget build(BuildContext context) => StreamBuilder<List<FriendRequest>>(
        stream: SocialService.instance.followRequests(),
        builder: (context, snapshot) {
          final count = (snapshot.data ?? const <FriendRequest>[]).length;
          return Stack(clipBehavior: Clip.none, children: [
            _CircleAction(
              icon: Icons.person_add_alt_1_rounded,
              background: Colors.white,
              foreground: SocialPage._red,
              border: SocialPage._red,
              size: 38,
              iconSize: 17,
              onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const FriendRequestsPage())),
            ),
            if (count > 0)
              Positioned(
                right: -5,
                top: -5,
                child: Container(
                  constraints:
                      const BoxConstraints(minWidth: 20, minHeight: 20),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                      color: SocialPage._red, shape: BoxShape.circle),
                  child: Text(count > 9 ? '9+' : '$count',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w800)),
                ),
              ),
          ]);
        },
      );
}

class _NotificationsAction extends StatelessWidget {
  const _NotificationsAction();

  @override
  Widget build(BuildContext context) => StreamBuilder<List<AppNotification>>(
        stream: SocialService.instance.notifications(),
        builder: (context, snapshot) {
          final unread = (snapshot.data ?? const <AppNotification>[])
              .where((notice) => !notice.read)
              .length;
          return Stack(clipBehavior: Clip.none, children: [
            _CircleAction(
              icon: Icons.notifications_rounded,
              background: Colors.white,
              foreground: SocialPage._red,
              border: SocialPage._red,
              size: 38,
              iconSize: 17,
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const NotificationsPage())),
            ),
            if (unread > 0)
              Positioned(
                right: -5,
                top: -5,
                child: Container(
                  constraints:
                      const BoxConstraints(minWidth: 20, minHeight: 20),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                      color: SocialPage._red, shape: BoxShape.circle),
                  child: Text(unread > 9 ? '9+' : '$unread',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w800)),
                ),
              ),
          ]);
        },
      );
}

class _CircleAction extends StatelessWidget {
  const _CircleAction({
    required this.icon,
    required this.background,
    required this.foreground,
    this.border,
    this.size = 36,
    this.iconSize = 18,
    this.rotation = 0,
    this.onTap,
  });

  final IconData icon;
  final Color background;
  final Color foreground;
  final Color? border;
  final double size;
  final double iconSize;
  final double rotation;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: background,
          shape: BoxShape.circle,
          border:
              border == null ? null : Border.all(color: border!, width: 1.4),
        ),
        child: Transform.rotate(
          angle: rotation,
          child: Icon(icon, color: foreground, size: iconSize),
        ),
      ),
    );
  }
}

class _ComposerCard extends StatelessWidget {
  const _ComposerCard({
    required this.name,
    required this.onTap,
    required this.onChooseAction,
  });

  final String name;
  final VoidCallback onTap;
  final ValueChanged<String> onChooseAction;

  @override
  Widget build(BuildContext context) => StreamBuilder<SocialProfileSummary?>(
        stream: SocialService.instance.currentProfile(),
        builder: (context, snapshot) {
          final profile = snapshot.data;
          final currentName =
              profile?.name.trim().isNotEmpty == true ? profile!.name : name;
          return _buildCard(context, currentName, profile?.avatarUrl);
        },
      );

  Widget _buildCard(
      BuildContext context, String currentName, String? avatarUrl) {
    return LayoutBuilder(builder: (context, constraints) {
      // Community content has generous page margins. On very narrow phones,
      // let the composer deliberately reflow rather than squeezing its tools.
      // Most small phones still have enough room for the normal, readable
      // composer. Only use the reduced layout on genuinely tiny widths.
      final compact = constraints.maxWidth < 250;
      // Medium phones keep the compact one-row tool bar. Only the smallest
      // cards switch to two rows so their touch targets never get squeezed.
      final twoColumnTools = constraints.maxWidth < 300;
      final tools = [
        _ComposerTool(
          icon: Icons.camera_alt_rounded,
          label: 'Photo',
          compact: compact,
          expanded: true,
          grid: twoColumnTools,
          onTap: () => onChooseAction('image'),
        ),
        _ComposerTool(
          icon: Icons.videocam_rounded,
          label: 'Video',
          compact: compact,
          expanded: true,
          grid: twoColumnTools,
          onTap: () => onChooseAction('video'),
        ),
        _ComposerTool(
          icon: Icons.poll_rounded,
          label: 'Poll',
          compact: compact,
          expanded: true,
          grid: twoColumnTools,
          onTap: () => onChooseAction('poll'),
        ),
        _ComposerTool(
          icon: Icons.graphic_eq_rounded,
          label: 'Audio',
          compact: compact,
          expanded: true,
          grid: twoColumnTools,
          onTap: () => onChooseAction('audio'),
        ),
      ];
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(compact ? 12 : 16, compact ? 16 : 22,
              compact ? 12 : 16, compact ? 16 : 28),
          decoration: _cardDecoration(context),
          child: Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => SocialProfilePage(
                                name: currentName, isOwnProfile: true))),
                    child: SocialAccountAvatar(
                      name: currentName,
                      imageUrl: avatarUrl,
                      size: compact ? 44 : 56,
                    ),
                  ),
                  SizedBox(width: compact ? 12 : 22),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "What's on your mind, $currentName?",
                          maxLines: compact ? 2 : 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: SocialPage._font,
                            color: AppPalette.text(context),
                            fontSize: compact ? 13.5 : 15,
                            fontWeight: FontWeight.w800,
                            height: 1.15,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Share your music, ideas or updates with the community',
                          maxLines: compact ? 2 : null,
                          overflow: compact ? TextOverflow.ellipsis : null,
                          style: TextStyle(
                            fontFamily: SocialPage._font,
                            color: AppPalette.muted(context),
                            fontSize: compact ? 11.5 : 12.5,
                            fontWeight: FontWeight.w500,
                            height: 1.25,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              SizedBox(height: compact ? 16 : 26),
              if (twoColumnTools)
                Column(
                  children: [
                    Row(children: [
                      Expanded(child: tools[0]),
                      const SizedBox(width: 8),
                      Expanded(child: tools[1]),
                    ]),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(child: tools[2]),
                      const SizedBox(width: 8),
                      Expanded(child: tools[3]),
                    ]),
                  ],
                )
              else
                Row(
                  children: [
                    for (var index = 0; index < tools.length; index++) ...[
                      if (index > 0) const SizedBox(width: 12),
                      Expanded(child: tools[index]),
                    ],
                  ],
                ),
            ],
          ),
        ),
      );
    });
  }
}

class _ComposerTool extends StatelessWidget {
  const _ComposerTool({
    required this.icon,
    required this.label,
    required this.onTap,
    this.compact = false,
    this.expanded = false,
    this.grid = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool compact;
  final bool expanded;
  final bool grid;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(grid ? 14 : 20),
      child: Padding(
        padding:
            grid ? EdgeInsets.zero : const EdgeInsets.symmetric(vertical: 4),
        child: grid
            ? Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: AppPalette.page(context),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: AppPalette.border(context).withValues(alpha: .7),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _CircleAction(
                        icon: icon,
                        background: SocialPage._red,
                        foreground: Colors.white,
                        size: 29,
                        iconSize: 15),
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text(label,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontFamily: SocialPage._font,
                              color: AppPalette.text(context),
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800)),
                    ),
                  ],
                ),
              )
            : compact
                ? Column(mainAxisSize: MainAxisSize.min, children: [
                    _CircleAction(
                        icon: icon,
                        background: SocialPage._red,
                        foreground: Colors.white,
                        size: 27,
                        iconSize: 14),
                    const SizedBox(height: 3),
                    Text(label,
                        style: const TextStyle(
                            fontFamily: SocialPage._font,
                            color: SocialPage._ink,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w600)),
                  ])
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize:
                        expanded ? MainAxisSize.max : MainAxisSize.min,
                    children: [
                      _CircleAction(
                        icon: icon,
                        background: SocialPage._red,
                        foreground: Colors.white,
                        size: 24,
                        iconSize: 13,
                      ),
                      const SizedBox(width: 3),
                      Flexible(
                          child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: SocialPage._font,
                          color: SocialPage._ink,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w500,
                        ),
                      )),
                    ],
                  ),
      ),
    );
  }
}

class SocialPostCard extends StatelessWidget {
  const SocialPostCard({
    super.key,
    required this.avatar,
    required this.author,
    required this.time,
    required this.body,
    required this.likes,
    required this.comments,
    required this.saves,
    this.media,
    this.onTap,
    this.onProfileTap,
    this.onLike,
    this.onComment,
    this.liked = false,
    this.attachment,
    this.saved = false,
    this.onSave,
    this.onMore,
  });

  final Widget avatar;
  final String author;
  final String time;
  final String body;
  final String likes;
  final String comments;
  final String saves;
  final Widget? media;
  final VoidCallback? onTap;
  final VoidCallback? onProfileTap;
  final VoidCallback? onLike;
  final VoidCallback? onComment;
  final bool liked;
  final Widget? attachment;
  final bool saved;
  final VoidCallback? onSave;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final hasAttachment = media != null || attachment != null;
    final isPoll = attachment is SocialPostAttachment &&
        (attachment! as SocialPostAttachment).post.pollOptions.isNotEmpty;
    final likesCount = int.tryParse(likes) ?? 0;
    final commentsCount = int.tryParse(comments) ?? 0;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(26),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: onProfileTap,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  avatar,
                  const SizedBox(width: 10),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            author,
                            style: TextStyle(
                              fontFamily: SocialPage._font,
                              color: AppPalette.text(context),
                              fontSize: 13.5,
                              fontWeight: FontWeight.w800,
                              height: 1,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            time,
                            style: TextStyle(
                              fontFamily: SocialPage._font,
                              color: Color(0xFFB1B1B1),
                              fontSize: 10.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: onMore,
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Post options',
                    icon: Icon(Icons.more_horiz_rounded,
                        color: AppPalette.text(context), size: 20),
                  ),
                ],
              ),
            ),
            if (body.trim().isNotEmpty && !hasAttachment) ...[
              const SizedBox(height: 9),
              _PostCaption(author: author, body: body),
            ],
            if (media != null) ...[
              const SizedBox(height: 9),
              ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: AspectRatio(
                  // Keep the photo prominent like a social feed, without
                  // making every uploaded image an edge-to-edge square tile.
                  aspectRatio: 1.12,
                  child: media,
                ),
              ),
            ],
            if (attachment != null) ...[
              const SizedBox(height: 9),
              attachment!,
            ],
            const SizedBox(height: 4),
            Row(
              children: [
                _FeedActionButton(
                    icon: liked
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    color: liked ? SocialPage._red : null,
                    onTap: onLike),
                _FeedActionButton(
                    icon: Icons.chat_bubble_outline_rounded, onTap: onComment),
                _FeedActionButton(icon: Icons.send_outlined, onTap: onTap),
                const Spacer(),
                _FeedActionButton(
                    icon: saved
                        ? Icons.bookmark_rounded
                        : Icons.bookmark_border_rounded,
                    color: saved ? SocialPage._red : null,
                    onTap: onSave),
              ],
            ),
            if (likesCount > 0) ...[
              const SizedBox(height: 2),
              Text('$likesCount ${likesCount == 1 ? 'like' : 'likes'}',
                  style: TextStyle(
                      color: AppPalette.text(context),
                      fontSize: 11,
                      fontWeight: FontWeight.w800)),
            ],
            if (body.trim().isNotEmpty && hasAttachment && !isPoll) ...[
              const SizedBox(height: 4),
              _PostCaption(author: author, body: body),
            ],
            if (commentsCount > 0) ...[
              const SizedBox(height: 4),
              GestureDetector(
                onTap: onComment,
                child: Text(
                  'View ${commentsCount == 1 ? 'comment' : 'all $commentsCount comments'}',
                  style: TextStyle(
                      color: AppPalette.muted(context),
                      fontSize: 11,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PostCaption extends StatelessWidget {
  const _PostCaption({required this.author, required this.body});
  final String author;
  final String body;

  @override
  Widget build(BuildContext context) => Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('$author  ',
              style: TextStyle(
                  fontFamily: SocialPage._font,
                  color: AppPalette.text(context),
                  fontSize: 12,
                  fontWeight: FontWeight.w800)),
          Text(body,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontFamily: SocialPage._font,
                  color: AppPalette.text(context),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  height: 1.28)),
        ],
      );
}

class _FeedActionButton extends StatelessWidget {
  const _FeedActionButton({required this.icon, this.color, this.onTap});
  final IconData icon;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => IconButton(
        onPressed: onTap,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        padding: EdgeInsets.zero,
        icon: Icon(icon, size: 18, color: color ?? AppPalette.text(context)),
      );
}

class SocialPostAttachment extends StatelessWidget {
  const SocialPostAttachment({required this.post});
  final SocialPost post;
  @override
  Widget build(BuildContext context) {
    if (post.pollOptions.isNotEmpty) {
      return _PollAttachment(
        postId: post.id,
        question: post.body,
        author: post.authorName,
        options: post.pollOptions,
        endsAt: post.pollEndsAt,
      );
    }
    final media = post.media.isNotEmpty
        ? post.media
        : post.mediaUrl == null || post.mediaType == null
            ? const <PostMedia>[]
            : [PostMedia(url: post.mediaUrl!, type: post.mediaType!)];
    return Column(
      children: media.map((item) {
        final child = item.type == 'image' ||
                (item.type == 'sheet' && _isSheetImage(item.url))
            ? ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(item.url,
                    width: double.infinity, fit: BoxFit.cover))
            : item.type == 'sheet'
                ? _SheetAttachment(url: item.url)
                : item.type == 'audio'
                    ? _AudioAttachment(url: item.url)
                    : _VideoAttachment(url: item.url);
        return Padding(
            padding: const EdgeInsets.only(bottom: 10), child: child);
      }).toList(),
    );
  }

  bool _isSheetImage(String url) =>
      RegExp(r'\.(png|jpe?g|webp)(?:\?|$)', caseSensitive: false).hasMatch(url);
}

class _SheetAttachment extends StatelessWidget {
  const _SheetAttachment({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppPalette.surface(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppPalette.border(context)),
        ),
        child: Row(children: [
          const Icon(Icons.picture_as_pdf_rounded, color: Color(0xFFCA000A)),
          const SizedBox(width: 10),
          Expanded(
              child: Text('Music sheet PDF',
                  style: TextStyle(
                      color: AppPalette.text(context),
                      fontWeight: FontWeight.w800))),
          TextButton.icon(
            onPressed: () =>
                launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
            icon: const Icon(Icons.open_in_new_rounded, size: 17),
            label: const Text('Open'),
          ),
        ]),
      );
}

class _PollAttachment extends StatefulWidget {
  const _PollAttachment(
      {required this.postId,
      required this.question,
      required this.author,
      required this.options,
      required this.endsAt});
  final String postId;
  final String question;
  final String author;
  final List<PollOption> options;
  final DateTime? endsAt;

  @override
  State<_PollAttachment> createState() => _PollAttachmentState();
}

class _PollAttachmentState extends State<_PollAttachment> {
  String? _optimisticVoteId;
  bool _submitting = false;
  DateTime _now = DateTime.now();
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _PollAttachment oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.postId != widget.postId) {
      _optimisticVoteId = null;
      _submitting = false;
    } else if (_optimisticVoteId != null &&
        widget.options
            .any((item) => item.voted && item.id == _optimisticVoteId)) {
      // Supabase has confirmed the optimistic selection.
      _optimisticVoteId = null;
    }
  }

  Future<void> _vote(PollOption option) async {
    final serverSelection = _serverSelection;
    final currentSelection = _optimisticVoteId ?? serverSelection?.id;
    if (_submitting || _ended || currentSelection == option.id) return;
    setState(() {
      _optimisticVoteId = option.id;
      _submitting = true;
    });
    try {
      await SocialService.instance.vote(option);
    } catch (_) {
      if (!mounted) return;
      setState(() => _optimisticVoteId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not submit your vote. Try again.')),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final serverSelection = _serverSelection;
    final selectedId = _optimisticVoteId ?? serverSelection?.id;
    final hasOptimisticChange =
        _optimisticVoteId != null && _optimisticVoteId != serverSelection?.id;
    final totalVotes =
        widget.options.fold<int>(0, (sum, item) => sum + item.votes) +
            (hasOptimisticChange && serverSelection == null ? 1 : 0);
    final hasVoted = selectedId != null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
      decoration: BoxDecoration(
        color: AppPalette.isDark(context) ? const Color(0xFF292929) : Colors.transparent,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(hasVoted || _ended ? 'POLL RESULTS' : 'COMMUNITY POLL',
            style: TextStyle(
                color: AppPalette.muted(context),
                fontSize: 9,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w800)),
        if (widget.question.trim().isNotEmpty) ...[
          const SizedBox(height: 7),
          Text(widget.question.trim(),
              style: TextStyle(
                  color: AppPalette.text(context),
                  fontSize: 16,
                  height: 1.22,
                  fontWeight: FontWeight.w800)),
        ],
        const SizedBox(height: 6),
        Text('Created by ${widget.author}',
            style: TextStyle(color: AppPalette.muted(context), fontSize: 10.5)),
        const SizedBox(height: 22),
        for (var index = 0; index < widget.options.length; index++)
          Padding(
            padding: const EdgeInsets.only(bottom: 11),
            child: _PollChoice(
              option: PollOption(
                id: widget.options[index].id,
                label: widget.options[index].label,
                votes: widget.options[index].votes +
                    (hasOptimisticChange &&
                            widget.options[index].id == _optimisticVoteId
                        ? 1
                        : 0) -
                    (hasOptimisticChange &&
                            widget.options[index].id == serverSelection?.id
                        ? 1
                        : 0),
                voted: widget.options[index].id == selectedId,
              ),
              index: index,
              totalVotes: totalVotes,
              showResults: hasVoted || _ended,
              onTap: _ended || _submitting
                  ? null
                  : () => _vote(widget.options[index]),
            ),
          ),
        const SizedBox(height: 12),
        Row(children: [
          Icon(Icons.people_alt_outlined,
              size: 14, color: AppPalette.muted(context)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
                '$totalVotes ${totalVotes == 1 ? 'person' : 'people'} voted',
                style:
                    TextStyle(color: AppPalette.muted(context), fontSize: 10.5)),
          ),
          Icon(Icons.schedule_rounded,
              size: 13, color: AppPalette.muted(context)),
          const SizedBox(width: 4),
          Text(widget.endsAt == null ? 'Open poll' : _timeLabel,
              style: TextStyle(color: AppPalette.muted(context), fontSize: 10.5)),
        ]),
      ]),
    );
  }

  PollOption? get _serverSelection {
    for (final option in widget.options) {
      if (option.voted) return option;
    }
    return null;
  }

  bool get _ended => widget.endsAt != null && !_now.isBefore(widget.endsAt!);

  String get _timeLabel {
    final endsAt = widget.endsAt;
    if (endsAt == null) return '';
    final remaining = endsAt.difference(_now);
    if (remaining <= Duration.zero) return 'Ended';
    if (remaining.inDays > 0) {
      return '${remaining.inDays}d ${remaining.inHours.remainder(24)}h left';
    }
    if (remaining.inHours > 0) {
      return '${remaining.inHours}h ${remaining.inMinutes.remainder(60)}m left';
    }
    return '${remaining.inMinutes.clamp(1, 59)}m left';
  }
}

class _PollChoice extends StatelessWidget {
  const _PollChoice({
    required this.option,
    required this.index,
    required this.totalVotes,
    required this.showResults,
    required this.onTap,
  });
  final PollOption option;
  final int index;
  final int totalVotes;
  final bool showResults;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final progress = totalVotes == 0 ? 0.0 : option.votes / totalVotes;
    final percentage = (progress * 100).toStringAsFixed(1);
    const colors = [Color(0xFF43F477), Color(0xFFFF5C93), Color(0xFFE9F23E)];
    final accent = colors[index % colors.length];
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(99),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(99),
        child: Container(
          height: 42,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: AppPalette.isDark(context) ? const Color(0xFF292929) : Colors.transparent,
            borderRadius: BorderRadius.circular(99),
            border: Border.all(color: accent.withValues(alpha: .86), width: 1),
          ),
          child: Stack(fit: StackFit.expand, children: [
            if (showResults)
              Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: progress,
                  child: ColoredBox(color: accent),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                if (showResults)
                  SizedBox(
                    width: 54,
                    child: Text('$percentage%',
                        style: TextStyle(
                            color: AppPalette.isDark(context) ? Colors.white : AppPalette.text(context),
                            fontSize: 10,
                            fontWeight: FontWeight.w800)),
                  ),
                Expanded(
                  child: Text(option.label,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: AppPalette.text(context),
                          fontSize: 11,
                          fontWeight: FontWeight.w700)),
                ),
                if (showResults) const SizedBox(width: 54),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _AudioAttachment extends StatefulWidget {
  const _AudioAttachment({required this.url});
  final String url;
  @override
  State<_AudioAttachment> createState() => _AudioAttachmentState();
}

class _AudioAttachmentState extends State<_AudioAttachment> {
  final _player = AudioPlayer();
  bool _playing = false;
  bool _loading = false;
  String? _error;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  String get _title {
    final name =
        Uri.decodeComponent(widget.url.split('?').first.split('/').last);
    final clean = name.replaceFirst(RegExp(r'^\d+_\d+_'), '');
    final dot = clean.lastIndexOf('.');
    return dot > 0 ? clean.substring(0, dot) : clean;
  }

  String _format(Duration value) {
    final minutes = value.inMinutes;
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  void initState() {
    super.initState();
    _player.onPlayerStateChanged.listen((state) {
      if (mounted) setState(() => _playing = state == PlayerState.playing);
    });
    _player.onDurationChanged.listen((value) {
      if (mounted) setState(() => _duration = value);
    });
    _player.onPositionChanged.listen((value) {
      if (mounted) setState(() => _position = value);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _position = Duration.zero;
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
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_playing) {
        await _player.pause();
      } else {
        await _player.play(UrlSource(widget.url));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'This audio file could not be played.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _duration.inMilliseconds == 0
        ? 0.0
        : (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
    return LayoutBuilder(builder: (context, constraints) {
      final coverSize = constraints.maxWidth.clamp(190.0, 280.0).toDouble();
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppPalette.surface(context),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppPalette.border(context)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: double.infinity,
              height: coverSize,
              child: const _AudioArtwork(),
            ),
          ),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(_title.isEmpty ? 'Audio post' : _title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: AppPalette.text(context),
                          fontSize: 16,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(height: 3),
                  Text('Audio post',
                      style: TextStyle(
                          color: AppPalette.muted(context), fontSize: 11)),
                ])),
            Material(
              color: SocialPage._red,
              shape: const CircleBorder(),
              child: InkWell(
                onTap: _toggle,
                customBorder: const CircleBorder(),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Icon(
                      _loading
                          ? Icons.more_horiz_rounded
                          : _playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 27),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          SizedBox(
            height: 18,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
              ),
              child: Slider(
                value: progress,
                activeColor: SocialPage._red,
                inactiveColor: AppPalette.border(context),
                onChanged: _duration == Duration.zero
                    ? null
                    : (value) => _player.seek(Duration(
                        milliseconds:
                            (_duration.inMilliseconds * value).round())),
              ),
            ),
          ),
          Row(children: [
            Text(_format(_position),
                style:
                    TextStyle(color: AppPalette.muted(context), fontSize: 10)),
            const Spacer(),
            Text(_duration == Duration.zero ? '--:--' : _format(_duration),
                style:
                    TextStyle(color: AppPalette.muted(context), fontSize: 10)),
          ]),
          if (_error != null) ...[
            const SizedBox(height: 7),
            Text(_error!,
                style: const TextStyle(color: SocialPage._red, fontSize: 10)),
          ],
        ]),
      );
    });
  }
}

class _AudioArtwork extends StatelessWidget {
  const _AudioArtwork();
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: AppPalette.surface(context),
          borderRadius: BorderRadius.circular(6),
        ),
        alignment: Alignment.center,
        child: Icon(Icons.image_outlined,
            color: AppPalette.muted(context), size: 42),
      );
}

class _VideoAttachment extends StatefulWidget {
  const _VideoAttachment({required this.url});
  final String url;
  @override
  State<_VideoAttachment> createState() => _VideoAttachmentState();
}

class _VideoAttachmentState extends State<_VideoAttachment> {
  late final VideoPlayerController _controller;
  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize().then((_) {
        if (mounted) setState(() {});
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_controller.value.isInitialized)
      return const AspectRatio(
          aspectRatio: 1.55, child: Center(child: CircularProgressIndicator()));
    return GestureDetector(
      onTap: () => setState(() => _controller.value.isPlaying
          ? _controller.pause()
          : _controller.play()),
      child: AspectRatio(
          aspectRatio: _controller.value.aspectRatio,
          child: Stack(alignment: Alignment.center, children: [
            VideoPlayer(_controller),
            if (!_controller.value.isPlaying)
              const Icon(Icons.play_circle_fill_rounded,
                  color: Colors.white, size: 48)
          ])),
    );
  }
}

class _PostImagePlaceholder extends StatelessWidget {
  const _PostImagePlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: const BoxDecoration(
        color: Color(0xFFEDEBE9),
      ),
      child: const Center(
        child: Icon(
          Icons.image_outlined,
          color: Color(0xFFA9A5A2),
          size: 42,
        ),
      ),
    );
  }
}

BoxDecoration _cardDecoration(BuildContext context) {
  return BoxDecoration(
    color: AppPalette.page(context),
    borderRadius: BorderRadius.circular(8),
    border: Border.all(color: AppPalette.border(context), width: 1.2),
  );
}
