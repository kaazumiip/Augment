import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_palette.dart';
import 'social_avatar.dart';
import 'social_page.dart';
import 'social_profile_page.dart';
import 'social_service.dart';

class CommentsPage extends StatefulWidget {
  const CommentsPage({
    super.key,
    required this.post,
    this.onPostUpdated,
    this.onPostDeleted,
  });

  final SocialPost post;
  final ValueChanged<SocialPost>? onPostUpdated;
  final ValueChanged<SocialPost>? onPostDeleted;

  @override
  State<CommentsPage> createState() => _CommentsPageState();
}

class _CommentsPageState extends State<CommentsPage> {
  static const _red = Color(0xFFCA000A);
  static const _font = 'Instrument Sans';
  final _controller = TextEditingController();
  final _composerFocus = FocusNode();
  final _scrollController = ScrollController();
  late SocialPost _post;
  bool _sending = false;
  PostComment? _replyingTo;

  @override
  void initState() {
    super.initState();
    _post = widget.post;
  }

  @override
  void dispose() {
    _controller.dispose();
    _composerFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  String _relativeTime(DateTime time) {
    final difference = DateTime.now().difference(time);
    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inHours < 1) return '${difference.inMinutes}m ago';
    if (difference.inDays < 1) return '${difference.inHours}h ago';
    return '${difference.inDays}d ago';
  }

  void _openProfile(String name, [String? userId]) {
    final isOwnProfile =
        userId != null && userId == FirebaseAuth.instance.currentUser?.uid;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SocialProfilePage(
          name: name,
          isOwnProfile: isOwnProfile,
          userId: userId,
        ),
      ),
    );
  }

  Future<void> _toggleLike() async {
    final nextLiked = !_post.isLiked;
    final nextLikes = (_post.likes + (nextLiked ? 1 : -1)).clamp(0, 1 << 30);
    final updated = _post.copyWith(isLiked: nextLiked, likes: nextLikes);
    setState(() => _post = updated);
    widget.onPostUpdated?.call(updated);

    try {
      await SocialService.instance.toggleLike(_post);
    } catch (_) {
      if (mounted) {
        setState(() => _post = widget.post);
        widget.onPostUpdated?.call(widget.post);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update reaction.')),
        );
      }
    }
  }

  Future<void> _toggleSave() async {
    final nextSaved = !_post.isSaved;
    final updated = _post.copyWith(isSaved: nextSaved);
    setState(() => _post = updated);
    widget.onPostUpdated?.call(updated);

    try {
      await SocialService.instance.toggleSave(_post);
    } catch (_) {
      if (mounted) {
        setState(() => _post = widget.post);
        widget.onPostUpdated?.call(widget.post);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update saved status.')),
        );
      }
    }
  }

  void _showPostActions() {
    final ownsPost = _post.authorId == FirebaseAuth.instance.currentUser?.uid;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('Copy post text'),
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: _post.body));
                if (sheetContext.mounted) Navigator.pop(sheetContext);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Post text copied.')),
                  );
                }
              },
            ),
            if (ownsPost)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit post'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _editPost();
                },
              ),
            if (ownsPost)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded, color: _red),
                title: const Text('Delete post', style: TextStyle(color: _red)),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (dialogCtx) => AlertDialog(
                      title: const Text('Delete post?'),
                      content:
                          const Text('This post will be removed permanently.'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogCtx, false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(dialogCtx, true),
                          child: const Text('Delete',
                              style: TextStyle(color: _red)),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    try {
                      await SocialService.instance.deletePost(_post.id);
                      widget.onPostDeleted?.call(_post);
                      if (mounted) Navigator.pop(context);
                    } catch (_) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Could not delete post.')),
                        );
                      }
                    }
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _editPost() async {
    final controller = TextEditingController(text: _post.body);
    final updatedBody = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(
            20, 16, 20, MediaQuery.viewInsetsOf(sheetContext).bottom + 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Edit post',
              style: TextStyle(
                  color: AppPalette.text(sheetContext),
                  fontFamily: _font,
                  fontSize: 19,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 14),
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
              onPressed: () => Navigator.pop(sheetContext, controller.text),
              style: FilledButton.styleFrom(backgroundColor: _red),
              child: const Text('Save changes'),
            ),
          ),
        ]),
      ),
    );
    controller.dispose();
    if (updatedBody == null ||
        updatedBody.trim().isEmpty ||
        updatedBody.trim() == _post.body) return;
    try {
      await SocialService.instance.updatePost(_post.id, updatedBody);
      final updated = _post.copyWith(body: updatedBody.trim());
      if (mounted) {
        setState(() => _post = updated);
        widget.onPostUpdated?.call(updated);
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Post updated.')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not update post.')));
      }
    }
  }

  Future<void> _send() async {
    final body = _controller.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await SocialService.instance
          .addComment(_post.id, body, parentCommentId: _replyingTo?.id);
      _controller.clear();
      final updated = _post.copyWith(comments: _post.comments + 1);
      setState(() => _post = updated);
      widget.onPostUpdated?.call(updated);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not post comment.')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Stream<List<PostComment>> get _commentsStream {
    try {
      return SocialService.instance.comments(_post.id);
    } catch (_) {
      return Stream.value(<PostComment>[]);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.page(context),
      body: SafeArea(
        child: Column(
          children: [
            // Top Navigation Bar
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
              child: Row(
                children: [
                  AppBackButton(
                    size: 20,
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Post',
                    style: TextStyle(
                      fontFamily: _font,
                      color: AppPalette.text(context),
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: _showPostActions,
                    icon: Icon(
                      Icons.more_horiz_rounded,
                      color: AppPalette.text(context),
                      size: 22,
                    ),
                    tooltip: 'Post options',
                  ),
                ],
              ),
            ),

            // Main Content: Full Post Details & Comments
            Expanded(
              child: ListView(
                controller: _scrollController,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                children: [
                  // Full Post Card
                  SocialPostCard(
                    avatar: SocialAccountAvatar(
                      name: _post.authorName,
                      imageUrl: _post.authorAvatarUrl,
                      size: 44,
                    ),
                    author: _post.authorName,
                    time: _relativeTime(_post.createdAt),
                    body: _post.body,
                    likes: '${_post.likes}',
                    comments: '${_post.comments}',
                    saves: _post.isSaved ? 'Saved' : 'Save',
                    liked: _post.isLiked,
                    saved: _post.isSaved,
                    onLike: _toggleLike,
                    onSave: _toggleSave,
                    onMore: _showPostActions,
                    onProfileTap: () =>
                        _openProfile(_post.authorName, _post.authorId),
                    attachment: (_post.media.isNotEmpty ||
                            _post.mediaUrl != null ||
                            _post.pollOptions.isNotEmpty)
                        ? SocialPostAttachment(post: _post)
                        : null,
                  ),

                  const SizedBox(height: 24),

                  // Comments Section Header
                  Row(
                    children: [
                      Text(
                        'Comments',
                        style: TextStyle(
                          fontFamily: _font,
                          color: AppPalette.text(context),
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: _red.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${_post.comments}',
                          style: const TextStyle(
                            color: _red,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 14),

                  // Real-time Comments List
                  StreamBuilder<List<PostComment>>(
                    stream: _commentsStream,
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 36),
                          child: Center(
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              color: _red,
                            ),
                          ),
                        );
                      }
                      final comments = snapshot.data!;
                      if (comments.isEmpty) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 40),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.chat_bubble_outline_rounded,
                                size: 40,
                                color: AppPalette.muted(context),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'No comments yet',
                                style: TextStyle(
                                  fontFamily: _font,
                                  color: AppPalette.text(context),
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Be the first to start the conversation!',
                                style: TextStyle(
                                  color: AppPalette.muted(context),
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        );
                      }

                      final replies = <String, List<PostComment>>{};
                      final roots = <PostComment>[];
                      for (final comment in comments) {
                        if (comment.parentCommentId == null) {
                          roots.add(comment);
                        } else {
                          replies
                              .putIfAbsent(comment.parentCommentId!, () => [])
                              .add(comment);
                        }
                      }
                      return Column(
                        children: [
                          for (final comment in roots) ...[
                            _CommentTile(
                              comment: comment,
                              relativeTime: _relativeTime,
                              onReply: () => setState(() {
                                _replyingTo = comment;
                                _composerFocus.requestFocus();
                              }),
                            ),
                            for (final reply in replies[comment.id] ?? const [])
                              Padding(
                                padding:
                                    const EdgeInsets.only(left: 42, top: 10),
                                child: _CommentTile(
                                  comment: reply,
                                  relativeTime: _relativeTime,
                                  compact: true,
                                  onReply: () => setState(() {
                                    _replyingTo = comment;
                                    _composerFocus.requestFocus();
                                  }),
                                ),
                              ),
                            const SizedBox(height: 18),
                          ],
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),

            // Pinned Bottom Comment Composer
            if (_replyingTo != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 14, 6),
                child: Row(children: [
                  Expanded(
                      child: Text('Replying to ${_replyingTo!.authorName}',
                          style: TextStyle(
                              color: AppPalette.muted(context), fontSize: 12))),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    tooltip: 'Cancel reply',
                    onPressed: () => setState(() => _replyingTo = null),
                  ),
                ]),
              ),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              decoration: BoxDecoration(
                color: AppPalette.page(context),
                border: Border(
                  top: BorderSide(color: AppPalette.border(context)),
                ),
              ),
              child: Container(
                height: 48,
                padding: const EdgeInsets.only(left: 16, right: 4),
                decoration: BoxDecoration(
                  color: AppPalette.surface(context),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: AppPalette.border(context)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        focusNode: _composerFocus,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        style: TextStyle(
                          color: AppPalette.text(context),
                          fontSize: 13.5,
                        ),
                        decoration: InputDecoration(
                          hintText: _replyingTo == null
                              ? 'Write a comment...'
                              : 'Write a reply...',
                          hintStyle: TextStyle(
                            color: AppPalette.muted(context),
                            fontSize: 13.5,
                          ),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: _sending ? null : _send,
                      icon: _sending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: _red,
                              ),
                            )
                          : const Icon(Icons.send_rounded,
                              color: _red, size: 20),
                      tooltip: 'Send comment',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({
    required this.comment,
    required this.relativeTime,
    required this.onReply,
    this.compact = false,
  });

  final PostComment comment;
  final String Function(DateTime) relativeTime;
  final VoidCallback onReply;
  final bool compact;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SocialAccountAvatar(
            name: comment.authorName,
            imageUrl: comment.authorAvatarUrl,
            size: compact ? 30 : 34,
          ),
          const SizedBox(width: 10),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(comment.authorName,
                      style: TextStyle(
                          fontFamily: 'Instrument Sans',
                          color: AppPalette.text(context),
                          fontSize: 13,
                          fontWeight: FontWeight.w800)),
                ),
                Text(relativeTime(comment.createdAt),
                    style: TextStyle(
                        color: AppPalette.muted(context), fontSize: 11)),
              ]),
              const SizedBox(height: 4),
              SelectableText(comment.body,
                  style: TextStyle(
                      fontFamily: 'Instrument Sans',
                      color: AppPalette.text(context),
                      fontSize: 13,
                      height: 1.3)),
              TextButton(
                onPressed: onReply,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.only(top: 3, right: 10, bottom: 0),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: AppPalette.muted(context),
                ),
                child: const Text('Reply',
                    style:
                        TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
              ),
            ]),
          ),
        ],
      );
}
