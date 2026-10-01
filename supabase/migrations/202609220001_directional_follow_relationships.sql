-- Convert the old mutual friendship meaning into Instagram-style directional
-- follows while retaining the existing table so deployed clients keep working.

-- Existing accepted friends should initially follow one another in both
-- directions. Future follows remain independent directional rows.
insert into public.friend_requests (
  sender_id,
  receiver_id,
  status,
  created_at,
  updated_at
)
select
  receiver_id,
  sender_id,
  'accepted',
  created_at,
  now()
from public.friend_requests
where status = 'accepted'
on conflict (sender_id, receiver_id) do update
set status = 'accepted', updated_at = now();

-- Counts are directional: accepted incoming rows are followers and accepted
-- outgoing rows are accounts the profile follows.
create or replace function public.profile_social_stats(profile_id text)
returns table(followers bigint, following bigint)
language sql
stable
security definer
set search_path = public
as $$
  select
    count(*) filter (
      where receiver_id = profile_id and status = 'accepted'
    )::bigint as followers,
    count(*) filter (
      where sender_id = profile_id and status = 'accepted'
    )::bigint as following
  from public.friend_requests
  where status = 'accepted'
    and (sender_id = profile_id or receiver_id = profile_id);
$$;

grant execute on function public.profile_social_stats(text) to authenticated;

-- A direct message is available when either person has an accepted follow
-- relationship with the other. Following does not need to be reciprocal.
create or replace function public.start_direct_conversation(other_user_id text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  found_conversation uuid;
begin
  if other_user_id = (auth.jwt() ->> 'sub') then
    raise exception 'You cannot message yourself';
  end if;

  if not exists (
    select 1 from public.friend_requests
    where status = 'accepted'
      and (
        (sender_id = (auth.jwt() ->> 'sub') and receiver_id = other_user_id)
        or
        (sender_id = other_user_id and receiver_id = (auth.jwt() ->> 'sub'))
      )
  ) then
    raise exception 'Follow this account before starting a conversation';
  end if;

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

  insert into public.conversations default values returning id into found_conversation;
  insert into public.conversation_members(conversation_id, user_id)
  values (found_conversation, (auth.jwt() ->> 'sub')),
         (found_conversation, other_user_id);
  return found_conversation;
end;
$$;

grant execute on function public.start_direct_conversation(text) to authenticated;

alter table public.notifications drop constraint if exists notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in (
    'like',
    'comment',
    'message',
    'friend_request_accepted',
    'follow_request_accepted'
  ));

create or replace function public.notify_follow_request_accepted()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.status <> 'accepted' and new.status = 'accepted' then
    insert into public.notifications(recipient_id, actor_id, kind)
    values (new.sender_id, new.receiver_id, 'follow_request_accepted');
  end if;
  return new;
end;
$$;

drop trigger if exists friend_request_accepted_notification on public.friend_requests;
drop trigger if exists follow_request_accepted_notification on public.friend_requests;
create trigger follow_request_accepted_notification
after update of status on public.friend_requests
for each row execute function public.notify_follow_request_accepted();

-- The follower may cancel a request or unfollow. The followed account can
-- remove a follower after accepting it.
drop policy if exists "Participants remove friendships" on public.friend_requests;
drop policy if exists "Participants remove follows" on public.friend_requests;
create policy "Participants remove follows" on public.friend_requests
for delete to authenticated using (
  sender_id = (auth.jwt() ->> 'sub')
  or (receiver_id = (auth.jwt() ->> 'sub') and status = 'accepted')
);
