-- Distinguish uploaded music from recorded voice notes and support live presence.

alter table public.profiles
  add column if not exists last_seen_at timestamptz;

create index if not exists profiles_last_seen_at_idx
  on public.profiles(last_seen_at desc);

alter table public.messages drop constraint if exists messages_media_type_check;
alter table public.messages add constraint messages_media_type_check
  check (media_type in ('image', 'video', 'audio', 'voice', 'pdf', 'file'));

create or replace view public.conversation_summaries
with (security_invoker = true)
as
select
  mine.conversation_id,
  other_member.user_id as other_user_id,
  profile.display_name as other_name,
  coalesce(
    nullif(last_message.body, ''),
    case last_message.media_type
      when 'audio' then 'Music file'
      when 'voice' then 'Voice message'
      when 'image' then 'Photo'
      when 'video' then 'Video'
      when 'pdf' then 'PDF document'
      when 'file' then 'File attachment'
      else null
    end,
    'Start a conversation'
  ) as last_message,
  last_message.created_at as last_message_at,
  mine.last_read_at,
  last_message.sender_id as last_sender_id,
  coalesce(unread.unread_count, 0)::integer as unread_count
from conversation_members mine
join conversation_members other_member
  on other_member.conversation_id = mine.conversation_id
  and other_member.user_id <> mine.user_id
join profiles profile on profile.id = other_member.user_id
left join lateral (
  select body, media_type, sender_id, created_at from messages
  where conversation_id = mine.conversation_id
  order by created_at desc limit 1
) last_message on true
left join lateral (
  select count(*) as unread_count from messages unread_message
  where unread_message.conversation_id = mine.conversation_id
    and unread_message.sender_id <> mine.user_id
    and (mine.last_read_at is null or unread_message.created_at > mine.last_read_at)
) unread on true
where mine.user_id = (auth.jwt() ->> 'sub');

grant select on public.conversation_summaries to authenticated;
