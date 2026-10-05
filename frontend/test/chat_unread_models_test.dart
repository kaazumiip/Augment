import 'package:flutter_test/flutter_test.dart';
import 'package:augment_app/social_service.dart';

Map<String,dynamic> row(String id, int unread, {bool group=false}) => {
  'conversation_id': id, 'other_user_id': group ? '' : 'other',
  'other_name': 'Musicians', 'last_message_at': '2026-10-05T08:00:00Z',
  'last_sender_id': 'other', 'unread_count': unread, 'is_group': group,
  'is_pinned': true, 'is_muted': true,
};

void main() {
  test('legacy direct chat still loads without new optional fields', () {
    final chat = ConversationSummary.fromMap({
      'conversation_id': 'old', 'other_user_id': 'other',
      'other_name': 'Roth', 'last_sender_id': 'other',
      'last_message_at': '2026-10-05T08:00:00Z',
    }, currentUserId: 'me');
    expect(chat.isGroup, false);
    expect(chat.isPinned, false);
    expect(chat.isMuted, false);
    expect(chat.unread, true);
  });
  test('explicit zero count overrides old preview timestamp', () {
    final chat = ConversationSummary.fromMap(row('a', 0), currentUserId: 'me');
    expect(chat.unread, false);
    expect(chat.unreadCount, 0);
  });
  test('reading one chat leaves the other unread', () {
    final chats = [ConversationSummary.fromMap(row('a',0)), ConversationSummary.fromMap(row('b',3))];
    expect(chats.where((c) => c.unread).length, 1);
    expect(chats.last.unreadCount, 3);
  });
  test('avatar enrichment preserves group, pin and mute settings', () {
    final chat = ConversationSummary.fromMap(row('g',2,group:true)).copyWith(avatarUrl: 'photo');
    expect(chat.isGroup, true);
    expect(chat.isPinned, true);
    expect(chat.isMuted, true);
    expect(chat.unreadCount, 2);
  });
  test('notification preserves actor for profile navigation', () {
    final notice = AppNotification(id:'n', actorId:'person', actorName:'Roth', kind:'follow',
      createdAt:DateTime(2026), read:false);
    expect(notice.actorId,'person');
    expect(notice.read,false);
  });
}
