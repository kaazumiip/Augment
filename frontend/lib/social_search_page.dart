import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_palette.dart';
import 'comments_page.dart';
import 'morphing_search_bar.dart';
import 'social_avatar.dart';
import 'social_profile_page.dart';
import 'social_service.dart';

class SocialSearchPage extends StatefulWidget {
  const SocialSearchPage({super.key, this.initialQuery = ''});
  final String initialQuery;

  @override
  State<SocialSearchPage> createState() => _SocialSearchPageState();
}

class _SocialSearchPageState extends State<SocialSearchPage> {
  static const _red = Color(0xFFCA000A);
  final _controller = TextEditingController();
  final _service = SocialService.instance;
  List<SocialProfileSummary> _recentPeople = [];
  final _hashtags = const [
    '#Piano',
    '#Guitar',
    '#Violin',
    '#Composition',
    '#Practice',
    '#Jazz'
  ];

  String get _query => _controller.text.trim();

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initialQuery;
    _loadRecentPeople();
  }

  String get _recentKey =>
      'social_recent_people_${FirebaseAuth.instance.currentUser?.uid ?? 'guest'}';

  Future<void> _loadRecentPeople() async {
    final preferences = await SharedPreferences.getInstance();
    final rows = preferences.getStringList(_recentKey) ?? const [];
    final people = rows
        .map((row) {
          final split = row.split('|');
          return split.length == 2
              ? SocialProfileSummary(id: split[0], name: split[1])
              : null;
        })
        .whereType<SocialProfileSummary>()
        .toList();
    if (mounted) setState(() => _recentPeople = people);
  }

  Future<void> _rememberPerson(SocialProfileSummary person) async {
    final next = [
      person,
      ..._recentPeople.where((item) => item.id != person.id),
    ].take(8).toList();
    setState(() => _recentPeople = next);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(
      _recentKey,
      next.map((item) => '${item.id}|${item.name}').toList(),
    );
  }

  Future<void> _removeRecentPerson(SocialProfileSummary person) async {
    final next = _recentPeople.where((item) => item.id != person.id).toList();
    setState(() => _recentPeople = next);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(
      _recentKey,
      next.map((item) => '${item.id}|${item.name}').toList(),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hashtags = _query.isEmpty
        ? _hashtags
        : _hashtags
            .where((tag) => tag.toLowerCase().contains(_query.toLowerCase()))
            .toList();

    return Scaffold(
      backgroundColor: AppPalette.page(context),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            MediaQuery.sizeOf(context).width < 380 ? 14 : 21,
            24,
            MediaQuery.sizeOf(context).width < 380 ? 14 : 29,
            24,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                LogoBackMorph(
                  tag: 'social-logo-back',
                  showBack: true,
                  onTap: () => Navigator.pop(context),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: MorphingSearchBar(
                      controller: _controller,
                      hintText: 'Search people or posts',
                      heroTag: 'social-search',
                      width: MediaQuery.sizeOf(context).width - 94,
                      autoExpand: true,
                      onChanged: (_) => setState(() {}),
                      onClose: () => Navigator.pop(context),
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: EdgeInsets.only(
                    top: 18,
                    bottom: 28 + MediaQuery.viewInsetsOf(context).bottom,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RichText(
                        text: TextSpan(
                          text: 'Search',
                          style: TextStyle(
                              color: AppPalette.text(context),
                              fontSize: 24,
                              fontWeight: FontWeight.w800),
                          children: const [
                            TextSpan(text: ' .', style: TextStyle(color: _red))
                          ],
                        ),
                      ),
                      const SizedBox(height: 33),
                      _SectionTitle(
                          text: _query.isEmpty
                              ? 'Recent searches'
                              : 'Search results'),
                      const SizedBox(height: 14),
                      FutureBuilder<List<Object>>(
                        key: ValueKey(_query),
                        future: _query.isEmpty
                            ? Future.value(_recentPeople.cast<Object>())
                            : _loadResults(),
                        builder: (context, snapshot) {
                          if (snapshot.hasError) {
                            return Text(
                              'Could not search: ${snapshot.error}',
                              style: TextStyle(
                                color: AppPalette.muted(context),
                                fontSize: 13,
                              ),
                            );
                          }
                          if (!snapshot.hasData) {
                            return const Padding(
                              padding: EdgeInsets.all(18),
                              child: Center(child: CircularProgressIndicator()),
                            );
                          }
                          final results = snapshot.data!;
                          if (results.isEmpty) {
                            return Text(
                                _query.isEmpty
                                    ? 'Search for people to keep them here.'
                                    : 'No people or posts found',
                                style: TextStyle(
                                    color: AppPalette.muted(context),
                                    fontSize: 13));
                          }
                          return Column(
                            children: results.map((result) {
                              if (result is SocialProfileSummary) {
                                return _PersonRow(
                                  name: result.name,
                                  avatarUrl: result.avatarUrl,
                                  onRemove: _query.isEmpty
                                      ? () => _removeRecentPerson(result)
                                      : null,
                                  onTap: () async {
                                    await _rememberPerson(result);
                                    if (!context.mounted) return;
                                    await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => SocialProfilePage(
                                          name: result.name,
                                          userId: result.id,
                                          isOwnProfile: false,
                                        ),
                                      ),
                                    );
                                  },
                                );
                              }
                              final post = result as SocialPost;
                              return _PostResult(post: post);
                            }).toList(),
                          );
                        },
                      ),
                      const SizedBox(height: 22),
                      const _SectionTitle(text: 'Explore by hashtag'),
                      const SizedBox(height: 15),
                      Wrap(
                        spacing: 30,
                        runSpacing: 20,
                        children: hashtags
                            .map((tag) => InkWell(
                                  onTap: () => setState(() =>
                                      _controller.text = tag.substring(1)),
                                  borderRadius: BorderRadius.circular(5),
                                  child: Text(tag,
                                      style: TextStyle(
                                          color: AppPalette.text(context),
                                          fontSize: 12.5)),
                                ))
                            .toList(),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<List<Object>> _loadResults() async {
    final profiles = await _service.searchProfiles(_query);
    final posts = await _service.searchPosts(_query);
    return [...profiles, ...posts];
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final split = text.split(' ');
    return RichText(
      text: TextSpan(
        style: TextStyle(
            color: AppPalette.text(context),
            fontSize: 14,
            fontWeight: FontWeight.w800),
        children: [
          TextSpan(text: split.first),
          if (split.length > 1)
            TextSpan(
                text: ' ${split.sublist(1).join(' ')}',
                style: const TextStyle(color: _SocialSearchPageState._red)),
        ],
      ),
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({
    required this.name,
    required this.onTap,
    this.avatarUrl,
    this.onRemove,
  });
  final String name;
  final String? avatarUrl;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 17),
        child: Row(
          children: [
            SocialAccountAvatar(name: name, imageUrl: avatarUrl, size: 43),
            const SizedBox(width: 12),
            Text(name,
                style: TextStyle(
                    color: AppPalette.text(context),
                    fontSize: 14,
                    fontWeight: FontWeight.w700)),
            const Spacer(),
            if (onRemove != null)
              IconButton(
                onPressed: onRemove,
                icon: Icon(Icons.close_rounded,
                    color: AppPalette.muted(context), size: 19),
                tooltip: 'Remove from recent searches',
              ),
          ],
        ),
      ),
    );
  }
}

class _PostResult extends StatelessWidget {
  const _PostResult({required this.post});
  final SocialPost post;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => CommentsPage(post: post)),
        ),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 13),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: AppPalette.border(context)),
            borderRadius: BorderRadius.circular(8),
          ),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(post.authorName,
                style: TextStyle(
                    color: AppPalette.text(context),
                    fontWeight: FontWeight.w700,
                    fontSize: 13)),
            const SizedBox(height: 5),
            Text(post.body,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    TextStyle(color: AppPalette.muted(context), fontSize: 12)),
          ]),
        ),
      );
}
