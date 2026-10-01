-- Run once in Supabase Dashboard -> SQL Editor.
-- Adds a notification for the person whose friend request was accepted.

alter table public.notifications drop constraint if exists notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('like', 'comment', 'message', 'friend_request_accepted'));

create or replace function public.notify_friend_request_accepted()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.status <> 'accepted' and new.status = 'accepted' then
    insert into public.notifications(recipient_id, actor_id, kind)
    values (new.sender_id, new.receiver_id, 'friend_request_accepted');
  end if;
  return new;
end;
$$;

drop trigger if exists friend_request_accepted_notification on public.friend_requests;
create trigger friend_request_accepted_notification
after update of status on public.friend_requests
for each row execute function public.notify_friend_request_accepted();
