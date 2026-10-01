-- Direct messages no longer require a follow relationship.  A first-time
-- conversation is a pending message request until its recipient accepts it.

alter table public.conversations
  add column if not exists request_status text not null default 'accepted'
    check (request_status in ('pending', 'accepted', 'declined')),
  add column if not exists request_sender_id text references public.profiles(id)
    on delete set null;

create index if not exists conversations_request_recipient_idx
  on public.conversations (request_status, request_sender_id);

create or replace function public.start_direct_conversation(other_user_id text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  found_conversation uuid;
  is_connected boolean;
begin
  if other_user_id = (auth.jwt() ->> 'sub') then
    raise exception 'You cannot message yourself';
  end if;

  select exists (
    select 1 from public.friend_requests
    where status = 'accepted'
      and ((sender_id = (auth.jwt() ->> 'sub') and receiver_id = other_user_id)
        or (sender_id = other_user_id and receiver_id = (auth.jwt() ->> 'sub')))
  ) into is_connected;

  select mine.conversation_id into found_conversation
  from public.conversation_members mine
  join public.conversation_members other
    on other.conversation_id = mine.conversation_id
  where mine.user_id = (auth.jwt() ->> 'sub')
    and other.user_id = other_user_id
  limit 1;
  if found_conversation is not null then
    return found_conversation;
  end if;

  insert into public.conversations (request_status, request_sender_id)
  values (case when is_connected then 'accepted' else 'pending' end,
          case when is_connected then null else (auth.jwt() ->> 'sub') end)
  returning id into found_conversation;
  insert into public.conversation_members(conversation_id, user_id)
  values (found_conversation, (auth.jwt() ->> 'sub')),
         (found_conversation, other_user_id);
  return found_conversation;
end;
$$;

create or replace function public.respond_to_message_request(
  target_conversation_id uuid,
  accept_request boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.conversations
  set request_status = case when accept_request then 'accepted' else 'declined' end,
      updated_at = now()
  where id = target_conversation_id
    and request_status = 'pending'
    and request_sender_id <> (auth.jwt() ->> 'sub')
    and exists (
      select 1 from public.conversation_members
      where conversation_id = target_conversation_id
        and user_id = (auth.jwt() ->> 'sub')
    );
  if not found then
    raise exception 'Message request is unavailable';
  end if;
end;
$$;

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
from public.conversation_members mine
join public.conversations conversation on conversation.id = mine.conversation_id
join public.conversation_members other_member
  on other_member.conversation_id = mine.conversation_id
  and other_member.user_id <> mine.user_id
join public.profiles profile on profile.id = other_member.user_id
left join lateral (
  select body, media_type, sender_id, created_at from public.messages
  where conversation_id = mine.conversation_id
  order by created_at desc limit 1
) last_message on true
where mine.user_id = (auth.jwt() ->> 'sub')
  and conversation.request_status = 'accepted';

create or replace view public.message_request_summaries
with (security_invoker = true)
as
select
  conversation.id as conversation_id,
  sender.id as sender_id,
  sender.display_name as sender_name,
  sender.avatar_url as sender_avatar_url,
  coalesce(nullif(first_message.body, ''), 'Sent you a message request') as preview,
  conversation.created_at
from public.conversations conversation
join public.profiles sender on sender.id = conversation.request_sender_id
left join lateral (
  select body from public.messages
  where conversation_id = conversation.id
  order by created_at asc limit 1
) first_message on true
where conversation.request_status = 'pending'
  and exists (
    select 1 from public.conversation_members member
    where member.conversation_id = conversation.id
      and member.user_id = (auth.jwt() ->> 'sub')
      and member.user_id <> conversation.request_sender_id
  );

grant select on public.conversation_summaries, public.message_request_summaries to authenticated;
grant execute on function public.start_direct_conversation(text),
  public.respond_to_message_request(uuid, boolean) to authenticated;

-- A requester can send one opening message. The recipient can read it in
-- Message requests, but cannot reply until accepting; after acceptance both
-- conversation members use the existing normal chat policy.
drop policy if exists "Members send messages" on public.messages;
create policy "Accepted members or request opener send messages"
on public.messages for insert to authenticated
with check (
  sender_id = (auth.jwt() ->> 'sub')
  and public.is_conversation_member(conversation_id)
  and (
    exists (
      select 1 from public.conversations
      where id = conversation_id and request_status = 'accepted'
    )
    or exists (
      select 1 from public.conversations
      where id = conversation_id
        and request_status = 'pending'
        and request_sender_id = (auth.jwt() ->> 'sub')
        and not exists (
          select 1 from public.messages prior
          where prior.conversation_id = conversation_id
        )
    )
  )
);
