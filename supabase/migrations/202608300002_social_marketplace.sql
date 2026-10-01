-- Run this once in Supabase Dashboard -> SQL Editor.
-- This reads the Firebase user id from the JWT subject as text.

create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  user_id text not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(trim(body)) between 1 and 2000),
  media_url text,
  media_type text check (media_type in ('image', 'video', 'audio')),
  created_at timestamptz not null default now()
);

alter table public.posts add column if not exists media_type text
  check (media_type in ('image', 'video', 'audio'));

create table if not exists public.poll_options (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  label text not null check (char_length(trim(label)) between 1 and 120),
  position smallint not null,
  unique (post_id, position)
);

create table if not exists public.poll_votes (
  option_id uuid not null references public.poll_options(id) on delete cascade,
  user_id text not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (option_id, user_id)
);

create table if not exists public.post_media (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  media_url text not null,
  media_type text not null check (media_type in ('image', 'video', 'audio')),
  position smallint not null default 0,
  created_at timestamptz not null default now(),
  unique (post_id, position)
);

insert into storage.buckets (id, name, public)
values ('social-media', 'social-media', true)
on conflict (id) do update set public = true;

create table if not exists public.post_likes (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id text not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

create table if not exists public.post_saves (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id text not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

create table if not exists public.post_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  author_id text not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(trim(body)) between 1 and 1000),
  created_at timestamptz not null default now()
);

create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.conversation_members (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id text not null references public.profiles(id) on delete cascade,
  last_read_at timestamptz,
  primary key (conversation_id, user_id)
);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id text not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(trim(body)) between 1 and 4000),
  waveform jsonb,
  created_at timestamptz not null default now()
);

create index if not exists posts_created_at_idx on public.posts(created_at desc);
create index if not exists comments_post_id_idx on public.post_comments(post_id, created_at);
create index if not exists messages_conversation_id_idx on public.messages(conversation_id, created_at);
create index if not exists poll_options_post_id_idx on public.poll_options(post_id, position);
create index if not exists post_media_post_id_idx on public.post_media(post_id, position);

-- Existing projects may already have posts(user_id, ...) from the first setup.
-- Add the profile relationship only when it is not already present.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'posts_user_id_fkey'
  ) then
    alter table public.posts add constraint posts_user_id_fkey
      foreign key (user_id) references public.profiles(id) on delete cascade;
  end if;
end $$;

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
    select 1 from friend_requests
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
  from conversation_members mine
  join conversation_members other on other.conversation_id = mine.conversation_id
  where mine.user_id = (auth.jwt() ->> 'sub') and other.user_id = other_user_id
  limit 1;
  if found_conversation is not null then return found_conversation; end if;
  insert into conversations default values returning id into found_conversation;
  insert into conversation_members(conversation_id, user_id)
  values (found_conversation, (auth.jwt() ->> 'sub')), (found_conversation, other_user_id);
  return found_conversation;
end;
$$;

insert into storage.buckets (id, name, public)
values ('marketplace-assets', 'marketplace-assets', true)
on conflict (id) do update set public = true;

drop policy if exists "Anyone can view marketplace assets" on storage.objects;
create policy "Anyone can view marketplace assets" on storage.objects
for select to authenticated using (bucket_id = 'marketplace-assets');

drop policy if exists "Sellers upload marketplace assets" on storage.objects;
create policy "Sellers upload marketplace assets" on storage.objects
for insert to authenticated with check (
  bucket_id = 'marketplace-assets'
  and (storage.foldername(name))[1] = (auth.jwt() ->> 'sub')
);

drop policy if exists "Sellers update marketplace assets" on storage.objects;
create policy "Sellers update marketplace assets" on storage.objects
for update to authenticated using (
  bucket_id = 'marketplace-assets'
  and (storage.foldername(name))[1] = (auth.jwt() ->> 'sub')
);

drop policy if exists "Sellers delete marketplace assets" on storage.objects;
create policy "Sellers delete marketplace assets" on storage.objects
for delete to authenticated using (
  bucket_id = 'marketplace-assets'
  and (storage.foldername(name))[1] = (auth.jwt() ->> 'sub')
);

-- Marketplace listings belong to a profile and can be displayed on that
-- profile's Music market tab.
create table if not exists public.market_listings (
  id uuid primary key default gen_random_uuid(),
  owner_id text not null references public.profiles(id) on delete cascade,
  title text not null check (char_length(trim(title)) between 1 and 120),
  category text not null check (category in ('Music', 'Music sheet', 'Lyrics')),
  price numeric(10,2) not null check (price >= 0),
  description text,
  asset_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists market_listings_owner_created_idx
  on public.market_listings(owner_id, created_at desc);

alter table public.market_listings enable row level security;

drop policy if exists "Marketplace listings are visible" on public.market_listings;
create policy "Marketplace listings are visible" on public.market_listings
for select to authenticated using (true);

drop policy if exists "Owners create marketplace listings" on public.market_listings;
create policy "Owners create marketplace listings" on public.market_listings
for insert to authenticated with check (owner_id = (auth.jwt() ->> 'sub'));

drop policy if exists "Owners update marketplace listings" on public.market_listings;
create policy "Owners update marketplace listings" on public.market_listings
for update to authenticated using (owner_id = (auth.jwt() ->> 'sub'))
with check (owner_id = (auth.jwt() ->> 'sub'));

drop policy if exists "Owners delete marketplace listings" on public.market_listings;
create policy "Owners delete marketplace listings" on public.market_listings
for delete to authenticated using (owner_id = (auth.jwt() ->> 'sub'));

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public'
      and tablename = 'market_listings'
  ) then
    alter publication supabase_realtime add table public.market_listings;
  end if;
end;
$$;

grant execute on function public.start_direct_conversation(text) to authenticated;

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

-- Friend requests power the pending requests button in the social header.
create table if not exists public.friend_requests (
  id uuid primary key default gen_random_uuid(),
  sender_id text not null references public.profiles(id) on delete cascade,
  receiver_id text not null references public.profiles(id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending', 'accepted', 'declined')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (sender_id, receiver_id),
  check (sender_id <> receiver_id)
);

create index if not exists friend_requests_receiver_status_idx
  on public.friend_requests(receiver_id, status, created_at desc);

alter table public.friend_requests enable row level security;

drop policy if exists "Users see their friend requests" on public.friend_requests;
create policy "Users see their friend requests" on public.friend_requests
for select to authenticated using (
  sender_id = (auth.jwt() ->> 'sub') or receiver_id = (auth.jwt() ->> 'sub')
);

drop policy if exists "Users send friend requests" on public.friend_requests;
create policy "Users send friend requests" on public.friend_requests
for insert to authenticated with check (
  sender_id = (auth.jwt() ->> 'sub') and receiver_id <> (auth.jwt() ->> 'sub')
);

drop policy if exists "Recipients respond to friend requests" on public.friend_requests;
create policy "Recipients respond to friend requests" on public.friend_requests
for update to authenticated using (receiver_id = (auth.jwt() ->> 'sub'))
with check (receiver_id = (auth.jwt() ->> 'sub'));

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'friend_requests'
  ) then
    alter publication supabase_realtime add table public.friend_requests;
  end if;
end;
$$;

alter table public.posts enable row level security;
alter table public.post_likes enable row level security;
alter table public.post_saves enable row level security;
alter table public.post_comments enable row level security;
alter table public.conversations enable row level security;
alter table public.conversation_members enable row level security;
alter table public.messages enable row level security;
alter table public.poll_options enable row level security;
alter table public.poll_votes enable row level security;
alter table public.post_media enable row level security;

alter table public.profiles enable row level security;
drop policy if exists "Profiles are visible to signed-in users" on public.profiles;
create policy "Profiles are visible to signed-in users" on public.profiles
for select to authenticated using (true);

drop policy if exists "Posts are visible" on public.posts;
create policy "Posts are visible" on public.posts for select to authenticated using (true);
drop policy if exists "Users create their posts" on public.posts;
create policy "Users create their posts" on public.posts for insert to authenticated with check (user_id = (auth.jwt() ->> 'sub'));
drop policy if exists "Users edit their posts" on public.posts;
create policy "Users edit their posts" on public.posts for update to authenticated using (user_id = (auth.jwt() ->> 'sub')) with check (user_id = (auth.jwt() ->> 'sub'));
drop policy if exists "Users delete their posts" on public.posts;
create policy "Users delete their posts" on public.posts for delete to authenticated using (user_id = (auth.jwt() ->> 'sub'));

drop policy if exists "Likes are visible" on public.post_likes;
create policy "Likes are visible" on public.post_likes for select to authenticated using (true);
drop policy if exists "Users manage their likes" on public.post_likes;
create policy "Users manage their likes" on public.post_likes for all to authenticated using (user_id = (auth.jwt() ->> 'sub')) with check (user_id = (auth.jwt() ->> 'sub'));

drop policy if exists "Saves are visible to their owner" on public.post_saves;
create policy "Saves are visible to their owner" on public.post_saves for select to authenticated using (user_id = (auth.jwt() ->> 'sub'));
drop policy if exists "Users manage their saves" on public.post_saves;
create policy "Users manage their saves" on public.post_saves for all to authenticated using (user_id = (auth.jwt() ->> 'sub')) with check (user_id = (auth.jwt() ->> 'sub'));

drop policy if exists "Comments are visible" on public.post_comments;
create policy "Comments are visible" on public.post_comments for select to authenticated using (true);
drop policy if exists "Users create comments" on public.post_comments;
create policy "Users create comments" on public.post_comments for insert to authenticated with check (author_id = (auth.jwt() ->> 'sub'));
drop policy if exists "Users edit their comments" on public.post_comments;
create policy "Users edit their comments" on public.post_comments for update to authenticated using (author_id = (auth.jwt() ->> 'sub')) with check (author_id = (auth.jwt() ->> 'sub'));
drop policy if exists "Users delete their comments" on public.post_comments;
create policy "Users delete their comments" on public.post_comments for delete to authenticated using (author_id = (auth.jwt() ->> 'sub'));

-- This function runs with the database owner's privileges, so policies may
-- safely check membership without recursively querying conversation_members
-- through its own RLS policy.
create or replace function public.is_conversation_member(
  target_conversation_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.conversation_members member
    where member.conversation_id = target_conversation_id
      and member.user_id = (auth.jwt() ->> 'sub')
  );
$$;

grant execute on function public.is_conversation_member(uuid) to authenticated;

drop policy if exists "Members see conversations" on public.conversations;
create policy "Members see conversations" on public.conversations for select to authenticated using (public.is_conversation_member(id));
drop policy if exists "Users create conversations" on public.conversations;
create policy "Users create conversations" on public.conversations for insert to authenticated with check (true);
drop policy if exists "Members update conversations" on public.conversations;
create policy "Members update conversations" on public.conversations for update to authenticated using (public.is_conversation_member(id));

drop policy if exists "Members see membership" on public.conversation_members;
create policy "Members see membership" on public.conversation_members for select to authenticated using (public.is_conversation_member(conversation_id));
drop policy if exists "Users add themselves to conversations" on public.conversation_members;
create policy "Users add themselves to conversations" on public.conversation_members for insert to authenticated with check (user_id = (auth.jwt() ->> 'sub'));
drop policy if exists "Users update their membership" on public.conversation_members;
create policy "Users update their membership" on public.conversation_members for update to authenticated using (user_id = (auth.jwt() ->> 'sub')) with check (user_id = (auth.jwt() ->> 'sub'));

drop policy if exists "Members see messages" on public.messages;
create policy "Members see messages" on public.messages for select to authenticated using (public.is_conversation_member(conversation_id));
drop policy if exists "Members send messages" on public.messages;
create policy "Members send messages" on public.messages for insert to authenticated with check (sender_id = (auth.jwt() ->> 'sub') and public.is_conversation_member(conversation_id));

drop policy if exists "Poll options are visible" on public.poll_options;
create policy "Poll options are visible" on public.poll_options for select to authenticated using (true);
drop policy if exists "Post owners create poll options" on public.poll_options;
create policy "Post owners create poll options" on public.poll_options for insert to authenticated with check (exists (select 1 from public.posts p where p.id = post_id and p.user_id = (auth.jwt() ->> 'sub')));

drop policy if exists "Poll votes are visible" on public.poll_votes;
create policy "Poll votes are visible" on public.poll_votes for select to authenticated using (true);
drop policy if exists "Users manage their poll votes" on public.poll_votes;
create policy "Users manage their poll votes" on public.poll_votes for all to authenticated using (user_id = (auth.jwt() ->> 'sub')) with check (user_id = (auth.jwt() ->> 'sub'));

drop policy if exists "Post media is visible" on public.post_media;
create policy "Post media is visible" on public.post_media for select to authenticated using (true);
drop policy if exists "Post owners create media" on public.post_media;
create policy "Post owners create media" on public.post_media for insert to authenticated with check (exists (select 1 from public.posts p where p.id = post_id and p.user_id = (auth.jwt() ->> 'sub')));

drop policy if exists "Signed-in users see social media" on storage.objects;
create policy "Signed-in users see social media" on storage.objects for select to authenticated using (bucket_id = 'social-media');
drop policy if exists "Users upload their social media" on storage.objects;
create policy "Users upload their social media" on storage.objects for insert to authenticated with check (bucket_id = 'social-media' and (storage.foldername(name))[1] = (auth.jwt() ->> 'sub'));
drop policy if exists "Users update their social media" on storage.objects;
create policy "Users update their social media" on storage.objects for update to authenticated using (bucket_id = 'social-media' and (storage.foldername(name))[1] = (auth.jwt() ->> 'sub'));
drop policy if exists "Users delete their social media" on storage.objects;
create policy "Users delete their social media" on storage.objects for delete to authenticated using (bucket_id = 'social-media' and (storage.foldername(name))[1] = (auth.jwt() ->> 'sub'));

-- Realtime for posts was configured by the initial setup. New media records
-- update their parent post, which refreshes the feed without adding tables
-- repeatedly to the publication.

-- Live activity notifications. These are generated in the database so they
-- work for every signed-in device, not only the one that performed an action.
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id text not null references public.profiles(id) on delete cascade,
  actor_id text references public.profiles(id) on delete set null,
  kind text not null check (kind in ('like', 'comment', 'message', 'friend_request_accepted')),
  post_id uuid references public.posts(id) on delete cascade,
  conversation_id uuid references public.conversations(id) on delete cascade,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.notifications drop constraint if exists notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('like', 'comment', 'message', 'friend_request_accepted'));

create index if not exists notifications_recipient_created_idx
  on public.notifications(recipient_id, created_at desc);

alter table public.notifications enable row level security;

drop policy if exists "Recipients read their notifications" on public.notifications;
create policy "Recipients read their notifications" on public.notifications
for select to authenticated using (recipient_id = (auth.jwt() ->> 'sub'));

drop policy if exists "Recipients mark their notifications read" on public.notifications;
create policy "Recipients mark their notifications read" on public.notifications
for update to authenticated using (recipient_id = (auth.jwt() ->> 'sub'))
with check (recipient_id = (auth.jwt() ->> 'sub'));

create or replace function public.notify_post_like()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare owner_id text;
begin
  select user_id into owner_id from posts where id = new.post_id;
  if owner_id is not null and owner_id <> new.user_id then
    insert into notifications(recipient_id, actor_id, kind, post_id)
    values (owner_id, new.user_id, 'like', new.post_id);
  end if;
  return new;
end;
$$;

create or replace function public.notify_post_comment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare owner_id text;
begin
  select user_id into owner_id from posts where id = new.post_id;
  if owner_id is not null and owner_id <> new.author_id then
    insert into notifications(recipient_id, actor_id, kind, post_id)
    values (owner_id, new.author_id, 'comment', new.post_id);
  end if;
  return new;
end;
$$;

create or replace function public.notify_direct_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into notifications(recipient_id, actor_id, kind, conversation_id)
  select member.user_id, new.sender_id, 'message', new.conversation_id
  from conversation_members member
  where member.conversation_id = new.conversation_id
    and member.user_id <> new.sender_id;
  return new;
end;
$$;

create or replace function public.notify_friend_request_accepted()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.status <> 'accepted' and new.status = 'accepted' then
    insert into notifications(recipient_id, actor_id, kind)
    values (new.sender_id, new.receiver_id, 'friend_request_accepted');
  end if;
  return new;
end;
$$;

drop trigger if exists post_like_notification on public.post_likes;
create trigger post_like_notification
after insert on public.post_likes
for each row execute function public.notify_post_like();

drop trigger if exists post_comment_notification on public.post_comments;
create trigger post_comment_notification
after insert on public.post_comments
for each row execute function public.notify_post_comment();

drop trigger if exists direct_message_notification on public.messages;

drop trigger if exists friend_request_accepted_notification on public.friend_requests;
create trigger friend_request_accepted_notification
after update of status on public.friend_requests
for each row execute function public.notify_friend_request_accepted();

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public'
      and tablename = 'messages'
  ) then
    alter publication supabase_realtime add table public.messages;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public'
      and tablename = 'notifications'
  ) then
    alter publication supabase_realtime add table public.notifications;
  end if;
end;
$$;
