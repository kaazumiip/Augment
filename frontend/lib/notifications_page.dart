import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'social_service.dart';

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});
  static const _red = Color(0xFFCA000A);

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  final _service = SocialService.instance;

  @override
  void initState() {
    super.initState();
    _service.markNotificationsRead();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppPalette.page(context),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(27, 18, 27, 24),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              AppBackButton(onPressed: () => Navigator.pop(context)),
              const SizedBox(height: 28),
              RichText(
                text: TextSpan(
                  text: 'Notifications',
                  style: TextStyle(
                    color: AppPalette.text(context),
                    fontSize: 25,
                    fontWeight: FontWeight.w800,
                  ),
                  children: const [
                    TextSpan(
                      text: ' .',
                      style: TextStyle(color: NotificationsPage._red),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Expanded(
                child: StreamBuilder<List<AppNotification>>(
                  stream: _service.notifications(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return Center(
                        child: Text(
                          'Notifications are not set up yet.',
                          style: TextStyle(color: AppPalette.muted(context)),
                        ),
                      );
                    }
                    final notices = snapshot.data ?? const [];
                    if (notices.isEmpty) {
                      return Center(
                        child: Text(
                          "You're all caught up.",
                          style: TextStyle(color: AppPalette.muted(context)),
                        ),
                      );
                    }
                    final today = notices.where(_isToday).toList();
                    final earlier =
                        notices.where((item) => !_isToday(item)).toList();
                    return ListView(
                      children: [
                        if (today.isNotEmpty) ...[
                          const _SectionTitle(text: 'Today'),
                          ...today.map((notice) => _Notice(notice: notice)),
                        ],
                        if (earlier.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          const _SectionTitle(text: 'Earlier'),
                          ...earlier.map((notice) => _Notice(notice: notice)),
                        ],
                      ],
                    );
                  },
                ),
              ),
            ]),
          ),
        ),
      );

  bool _isToday(AppNotification item) {
    final now = DateTime.now();
    final time = item.createdAt;
    return time.year == now.year &&
        time.month == now.month &&
        time.day == now.day;
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style: TextStyle(
                color: AppPalette.muted(context),
                fontSize: 13,
                fontWeight: FontWeight.w700)),
      );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.notice});
  final AppNotification notice;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(children: [
          CircleAvatar(
            radius: 23,
            backgroundColor: AppPalette.surface(context),
            child: Text(notice.actorName.substring(0, 1).toUpperCase(),
                style: const TextStyle(
                    color: NotificationsPage._red,
                    fontSize: 17,
                    fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: TextStyle(
                    color: AppPalette.text(context), fontSize: 13, height: 1.2),
                children: [
                  TextSpan(
                    text: notice.actorName,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  TextSpan(text: ' ${_messageFor(notice.kind)}'),
                ],
              ),
            ),
          ),
          Text(_ago(notice.createdAt),
              style: TextStyle(color: AppPalette.muted(context), fontSize: 10)),
        ]),
      );

  String _messageFor(String kind) => switch (kind) {
        'like' => 'liked your post.',
        'comment' => 'commented on your post.',
        'message' => 'sent you a message.',
        'friend_request_accepted' => 'accepted your follow request.',
        'follow_request_accepted' => 'accepted your follow request.',
        _ => 'interacted with your account.',
      };

  String _ago(DateTime time) {
    final age = DateTime.now().difference(time);
    if (age.inDays > 0) return '${age.inDays}d';
    if (age.inHours > 0) return '${age.inHours}h';
    return '${age.inMinutes.clamp(1, 59)}m';
  }
}
