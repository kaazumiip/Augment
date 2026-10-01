import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'social_avatar.dart';
import 'comments_page.dart';
import 'social_page.dart';
import 'social_service.dart';

class SavedPostsPage extends StatefulWidget {
  const SavedPostsPage({super.key});

  @override
  State<SavedPostsPage> createState() => _SavedPostsPageState();
}

class _SavedPostsPageState extends State<SavedPostsPage> {
  late Future<List<SocialPost>> _savedPosts;

  @override
  void initState() {
    super.initState();
    _savedPosts = SocialService.instance.savedPosts();
  }

  void _refresh() =>
      setState(() => _savedPosts = SocialService.instance.savedPosts());

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppPalette.page(context),
        body: SafeArea(
            child: Padding(
          padding: const EdgeInsets.fromLTRB(27, 18, 27, 24),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AppBackButton(onPressed: () => Navigator.pop(context)),
            const SizedBox(height: 22),
            Text('Saved posts',
                style: TextStyle(
                    color: AppPalette.text(context),
                    fontSize: 24,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 20),
            Expanded(
                child: FutureBuilder<List<SocialPost>>(
              future: _savedPosts,
              builder: (context, snapshot) {
                if (!snapshot.hasData)
                  return const Center(child: CircularProgressIndicator());
                final posts = snapshot.data!;
                if (posts.isEmpty)
                  return Center(
                      child: Text('Posts you save will appear here.',
                          style: TextStyle(color: AppPalette.muted(context))));
                return ListView.separated(
                    itemCount: posts.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 14),
                    itemBuilder: (context, index) {
                      final post = posts[index];
                      return SocialPostCard(
                        avatar: SocialAccountAvatar(
                          name: post.authorName,
                          imageUrl: post.authorAvatarUrl,
                          size: 42,
                        ),
                        author: post.authorName,
                        time: _relativeTime(post.createdAt),
                        body: post.body,
                        likes: '${post.likes}',
                        comments: '${post.comments}',
                        saves: 'Saved',
                        liked: post.isLiked,
                        saved: true,
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => CommentsPage(
                                    post: post,
                                    onPostUpdated: (_) => _refresh(),
                                  )),
                        ),
                        attachment: (post.media.isNotEmpty ||
                                post.mediaUrl != null ||
                                post.pollOptions.isNotEmpty)
                            ? SocialPostAttachment(post: post)
                            : null,
                        onLike: () => SocialService.instance.toggleLike(post),
                        onComment: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => CommentsPage(
                                    post: post,
                                    onPostUpdated: (_) => _refresh(),
                                  )),
                        ),
                        onSave: () async {
                          await SocialService.instance.toggleSave(post);
                          if (mounted) _refresh();
                        },
                      );
                    });
              },
            )),
          ]),
        )),
      );

  String _relativeTime(DateTime time) {
    final difference = DateTime.now().difference(time);
    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inHours < 1) return '${difference.inMinutes}m ago';
    if (difference.inDays < 1) return '${difference.inHours}h ago';
    return '${difference.inDays}d ago';
  }
}
