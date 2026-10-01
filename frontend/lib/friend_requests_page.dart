import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'social_avatar.dart';
import 'social_profile_page.dart';
import 'social_service.dart';

class FriendRequestsPage extends StatelessWidget {
  const FriendRequestsPage({super.key});
  static const _red = Color(0xFFCA000A);

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppPalette.page(context),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              AppBackButton(onPressed: () => Navigator.pop(context)),
              const SizedBox(height: 27),
              RichText(
                  text: TextSpan(
                      text: 'Follow requests',
                      style: TextStyle(
                          color: AppPalette.text(context),
                          fontSize: 25,
                          fontWeight: FontWeight.w800),
                      children: const [
                    TextSpan(text: ' .', style: TextStyle(color: _red))
                  ])),
              const SizedBox(height: 22),
              Expanded(
                child: StreamBuilder<List<FriendRequest>>(
                  stream: SocialService.instance.followRequests(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return Center(
                          child: Text('Follow requests are not set up yet.',
                              style:
                                  TextStyle(color: AppPalette.muted(context))));
                    }
                    final requests = snapshot.data ?? const <FriendRequest>[];
                    if (requests.isEmpty) {
                      return Center(
                          child: Text('No pending follow requests.',
                              style:
                                  TextStyle(color: AppPalette.muted(context))));
                    }
                    return ListView.separated(
                      itemCount: requests.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 14),
                      itemBuilder: (context, index) =>
                          _RequestCard(request: requests[index]),
                    );
                  },
                ),
              ),
            ]),
          ),
        ),
      );
}

class _RequestCard extends StatefulWidget {
  const _RequestCard({required this.request});
  final FriendRequest request;
  @override
  State<_RequestCard> createState() => _RequestCardState();
}

class _RequestCardState extends State<_RequestCard> {
  bool _busy = false;
  bool _handled = false;

  void _openProfile() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SocialProfilePage(
          name: widget.request.senderName,
          isOwnProfile: false,
          userId: widget.request.senderId,
        ),
      ),
    );
  }

  Future<void> _respond(bool accept) async {
    if (_busy || _handled) return;
    // Remove the card immediately; Supabase then confirms the change in the
    // background and the realtime list catches up without a visible delay.
    setState(() {
      _busy = true;
      _handled = true;
    });
    try {
      await SocialService.instance
          .respondToFollowRequest(widget.request.id, accept: accept);
    } catch (_) {
      if (!mounted) return;
      setState(() => _handled = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(accept
              ? 'Could not accept the follow request.'
              : 'Could not decline the follow request.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        child: _handled ? const SizedBox.shrink() : _requestCard(context),
      );

  Widget _requestCard(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
        decoration: BoxDecoration(
            color: AppPalette.surface(context),
            border: Border.all(color: AppPalette.border(context)),
            borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          GestureDetector(
            onTap: _openProfile,
            child: SocialAccountAvatar(
              name: widget.request.senderName,
              imageUrl: widget.request.senderAvatarUrl,
              size: 46,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: InkWell(
              onTap: _openProfile,
              child: _requestLabel(context),
            ),
          ),
          if (_busy)
            const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2))
          else ...[
            _roundAction(
                icon: Icons.close_rounded,
                onTap: () => _respond(false),
                foreground: AppPalette.text(context),
                border: AppPalette.border(context)),
            const SizedBox(width: 8),
            _roundAction(
                icon: Icons.check_rounded,
                onTap: () => _respond(true),
                foreground: Colors.white,
                background: FriendRequestsPage._red),
          ],
        ]),
      );

  Widget _requestLabel(BuildContext context) => RichText(
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        text: TextSpan(
          style: TextStyle(color: AppPalette.text(context), fontSize: 13),
          children: [
            TextSpan(
                text: widget.request.senderName,
                style: const TextStyle(fontWeight: FontWeight.w800)),
            const TextSpan(text: ' requested to follow you'),
          ],
        ),
      );

  Widget _roundAction({
    required IconData icon,
    required VoidCallback onTap,
    required Color foreground,
    Color? background,
    Color? border,
  }) =>
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
              color: background ?? Colors.transparent,
              shape: BoxShape.circle,
              border: border == null ? null : Border.all(color: border)),
          alignment: Alignment.center,
          child: Icon(icon, color: foreground, size: 18),
        ),
      );
}
