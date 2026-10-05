-- Per-user inbox settings: deleting hides history only for that member.
begin;
alter table public.conversation_members
  add column if not exists is_pinned boolean not null default false,
  add column if not exists is_muted boolean not null default false,
  add column if not exists cleared_at timestamptz;
alter table public.conversations
  add column if not exists is_group boolean not null default false,
  add column if not exists group_name text;

create or replace function public.create_group_conversation(group_title text, member_ids text[])
returns uuid language plpgsql security definer set search_path = public as $$
declare caller text := auth.jwt()->>'sub'; new_id uuid; ids text[];
begin
  if caller is null then raise exception 'Sign in required'; end if;
  if group_title is null or char_length(trim(group_title)) not between 1 and 80 then
    raise exception 'Group name must be 1 to 80 characters';
  end if;
  select array_agg(distinct id) into ids from unnest(member_ids || array[caller]) id;
  if cardinality(ids) not between 3 and 20 then raise exception 'Choose 2 to 19 people'; end if;
  if exists(select 1 from unnest(ids) as members(member_id)
    where not exists(select 1 from profiles p where p.id = members.member_id)) then
    raise exception 'Member unavailable';
  end if;
  -- Only connected people can be added without a group invitation.
  if exists(select 1 from unnest(ids) as members(member_id) where members.member_id <> caller and not exists(
    select 1 from friend_requests f where f.status='accepted' and
      ((f.sender_id=caller and f.receiver_id=members.member_id) or (f.receiver_id=caller and f.sender_id=members.member_id))
  )) then raise exception 'Only connected musicians can be added'; end if;
  insert into conversations(is_group,group_name,request_status) values(true,trim(group_title),'accepted') returning id into new_id;
  insert into conversation_members(conversation_id,user_id) select new_id,id from unnest(ids) id;
  return new_id;
end $$;
revoke all on function public.create_group_conversation(text,text[]) from public;
grant execute on function public.create_group_conversation(text,text[]) to authenticated;

create or replace view public.conversation_summaries with (security_invoker=true) as
select mine.conversation_id,
  coalesce(other_member.user_id,'') as other_user_id,
  case when c.is_group then c.group_name else p.display_name end as other_name,
  coalesce(nullif(latest.body,''),case latest.media_type
    when 'voice' then 'Voice message' when 'audio' then 'Audio'
    when 'image' then 'Photo' when 'video' then 'Video'
    when 'pdf' then 'PDF document' when 'file' then 'File attachment'
    end,'Start a conversation') as last_message,
  latest.created_at as last_message_at, mine.last_read_at,
  latest.sender_id as last_sender_id,
  (select count(*)::integer from messages m
    where m.conversation_id=mine.conversation_id and m.sender_id<>mine.user_id
      and m.created_at>greatest(coalesce(mine.last_read_at,'-infinity'::timestamptz),
        coalesce(mine.cleared_at,'-infinity'::timestamptz))) as unread_count,
  mine.is_pinned,mine.is_muted,c.is_group
from conversation_members mine
join conversations c on c.id=mine.conversation_id
left join lateral(select user_id from conversation_members cm
  where cm.conversation_id=mine.conversation_id and cm.user_id<>mine.user_id
    and not c.is_group order by user_id limit 1) other_member on true
left join profiles p on p.id=other_member.user_id
left join lateral(select body,media_type,sender_id,created_at from messages m
  where m.conversation_id=mine.conversation_id
    and m.created_at>coalesce(mine.cleared_at,'-infinity'::timestamptz)
  order by created_at desc,id desc limit 1) latest on true
where mine.user_id=(auth.jwt()->>'sub') and c.request_status='accepted'
  and (mine.cleared_at is null or latest.created_at is not null);
grant select on public.conversation_summaries to authenticated;

create or replace function public.start_direct_conversation(other_user_id text)
returns uuid language plpgsql security definer set search_path=public as $$
declare caller text := auth.jwt()->>'sub'; found_id uuid; connected boolean;
begin
  if caller is null or caller=other_user_id then raise exception 'Invalid recipient'; end if;
  select mine.conversation_id into found_id from conversation_members mine
    join conversation_members other on other.conversation_id=mine.conversation_id
    join conversations c on c.id=mine.conversation_id
    where mine.user_id=caller and other.user_id=other_user_id and not c.is_group limit 1;
  if found_id is not null then return found_id; end if;
  select exists(select 1 from friend_requests f where f.status='accepted' and
    ((f.sender_id=caller and f.receiver_id=other_user_id) or (f.sender_id=other_user_id and f.receiver_id=caller))) into connected;
  insert into conversations(request_status,request_sender_id)
    values(case when connected then 'accepted' else 'pending' end,case when connected then null else caller end)
    returning id into found_id;
  insert into conversation_members(conversation_id,user_id) values(found_id,caller),(found_id,other_user_id);
  return found_id;
end $$;
revoke all on function public.start_direct_conversation(text) from public;
grant execute on function public.start_direct_conversation(text) to authenticated;

create or replace function public.mark_conversation_read(target_id uuid, read_through timestamptz)
returns void language plpgsql security definer set search_path=public as $$
begin
  update conversation_members set last_read_at=greatest(
    coalesce(last_read_at,'-infinity'::timestamptz),least(read_through,now()))
  where conversation_id=target_id and user_id=(auth.jwt()->>'sub');
  if not found then raise exception 'Conversation unavailable'; end if;
end $$;
revoke all on function public.mark_conversation_read(uuid,timestamptz) from public;
grant execute on function public.mark_conversation_read(uuid,timestamptz) to authenticated;
-- Use the server clock so a phone clock cannot hide future incoming messages.
create or replace function public.clear_conversation_for_me(target_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  update conversation_members set cleared_at=now(), last_read_at=now(), is_pinned=false
  where conversation_id=target_id and user_id=(auth.jwt()->>'sub');
  if not found then raise exception 'Conversation unavailable'; end if;
end $$;
revoke all on function public.clear_conversation_for_me(uuid) from public;
grant execute on function public.clear_conversation_for_me(uuid) to authenticated;
commit;
