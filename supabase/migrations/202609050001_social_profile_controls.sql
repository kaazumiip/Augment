alter table public.profiles add column if not exists cover_url text;

drop policy if exists "Participants remove friendships" on public.friend_requests;
create policy "Participants remove friendships" on public.friend_requests
for delete to authenticated using (
  (sender_id = (auth.jwt() ->> 'sub') and status in ('pending', 'accepted'))
  or (receiver_id = (auth.jwt() ->> 'sub') and status = 'accepted')
);
