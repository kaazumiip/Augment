-- Run this file once in Supabase: SQL Editor -> New query -> Run.
-- Firebase user IDs are text values, not PostgreSQL UUIDs.

create table if not exists public.profiles (
  id text primary key,
  display_name text,
  avatar_url text,
  onboarding_completed boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles
  add column if not exists onboarding_completed boolean not null default false;

create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  user_id text not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) <= 2000),
  media_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.sheet_projects (
  id uuid primary key default gen_random_uuid(),
  user_id text not null references public.profiles(id) on delete cascade,
  title text not null default 'Untitled',
  instrument text not null,
  source_name text,
  musicxml_url text,
  preview_audio_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.sheet_projects
  add column if not exists result jsonb not null default '{}'::jsonb;

alter table public.profiles enable row level security;
alter table public.posts enable row level security;
alter table public.sheet_projects enable row level security;

grant usage on schema public to authenticated;
grant select, insert, update, delete on public.profiles to authenticated;
grant select, insert, update, delete on public.posts to authenticated;
grant select, insert, update, delete on public.sheet_projects to authenticated;

create policy "Users can read their own profile"
  on public.profiles for select to authenticated
  using ((auth.jwt() ->> 'sub') = id);

create policy "Users can create their own profile"
  on public.profiles for insert to authenticated
  with check ((auth.jwt() ->> 'sub') = id);

create policy "Users can update their own profile"
  on public.profiles for update to authenticated
  using ((auth.jwt() ->> 'sub') = id)
  with check ((auth.jwt() ->> 'sub') = id);

create policy "Authenticated users can read posts"
  on public.posts for select to authenticated using (true);

create policy "Users can create their own posts"
  on public.posts for insert to authenticated
  with check ((auth.jwt() ->> 'sub') = user_id);

create policy "Users can update their own posts"
  on public.posts for update to authenticated
  using ((auth.jwt() ->> 'sub') = user_id)
  with check ((auth.jwt() ->> 'sub') = user_id);

create policy "Users can delete their own posts"
  on public.posts for delete to authenticated
  using ((auth.jwt() ->> 'sub') = user_id);

create policy "Users can access their own sheet projects"
  on public.sheet_projects for select to authenticated
  using ((auth.jwt() ->> 'sub') = user_id);

create policy "Users can create their own sheet projects"
  on public.sheet_projects for insert to authenticated
  with check ((auth.jwt() ->> 'sub') = user_id);

create policy "Users can update their own sheet projects"
  on public.sheet_projects for update to authenticated
  using ((auth.jwt() ->> 'sub') = user_id)
  with check ((auth.jwt() ->> 'sub') = user_id);

create policy "Users can delete their own sheet projects"
  on public.sheet_projects for delete to authenticated
  using ((auth.jwt() ->> 'sub') = user_id);
