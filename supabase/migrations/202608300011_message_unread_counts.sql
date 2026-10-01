-- Keep the inbox preview stable and return the real unread count per chat.
-- Dropping first also repairs installations that have an older view column
-- order, which PostgreSQL cannot change through create or replace view.
drop view if exists public.conversation_summaries;

create view public.conversation_summaries
with (security_invoker = true)
as
select
  mine.conversation_id,
  other_member.user_id as other_user_id,
  profile.display_name as other_name,
  coalesce(
    nullif(last_message.body, ''),
    case last_message.media_type
      when 'audio' then 'Voice message'
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
  (
    select count(*)::integer
    from public.messages unread_message
    where unread_message.conversation_id = mine.conversation_id
      and unread_message.sender_id <> mine.user_id
      and unread_message.created_at > coalesce(mine.last_read_at, '-infinity'::timestamptz)
  ) as unread_count
from public.conversation_members mine
join public.conversation_members other_member
  on other_member.conversation_id = mine.conversation_id
  and other_member.user_id <> mine.user_id
join public.profiles profile on profile.id = other_member.user_id
left join lateral (
  select body, media_type, sender_id, created_at
  from public.messages
  where conversation_id = mine.conversation_id
  order by created_at desc
  limit 1
) last_message on true
where mine.user_id = (auth.jwt() ->> 'sub');

grant select on public.conversation_summaries to authenticated;
