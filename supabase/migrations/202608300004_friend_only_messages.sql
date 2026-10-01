-- Run this once in Supabase Dashboard -> SQL Editor after friend requests
-- have been created. It ensures direct messages are limited to accepted friends.

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
    raise exception 'You can only message accepted friends';
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
