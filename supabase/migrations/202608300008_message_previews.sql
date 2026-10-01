-- Run this once in the Supabase SQL editor after message attachments are set up.
-- It gives the inbox a meaningful last-message preview for text and media.
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
  last_message.sender_id as last_sender_id
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
where mine.user_id = (auth.jwt() ->> 'sub');

grant select on public.conversation_summaries to authenticated;
