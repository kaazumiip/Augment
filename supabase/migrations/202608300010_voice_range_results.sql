create table if not exists public.voice_range_results (
  user_id text primary key references public.profiles(id) on delete cascade,
  result jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.voice_range_results enable row level security;
grant select, insert, update, delete on public.voice_range_results to authenticated;

drop policy if exists "Users read their voice result" on public.voice_range_results;
create policy "Users read their voice result" on public.voice_range_results
for select to authenticated using (user_id = (auth.jwt() ->> 'sub'));

drop policy if exists "Users create their voice result" on public.voice_range_results;
create policy "Users create their voice result" on public.voice_range_results
for insert to authenticated with check (user_id = (auth.jwt() ->> 'sub'));

drop policy if exists "Users update their voice result" on public.voice_range_results;
create policy "Users update their voice result" on public.voice_range_results
for update to authenticated using (user_id = (auth.jwt() ->> 'sub'))
with check (user_id = (auth.jwt() ->> 'sub'));

drop policy if exists "Users delete their voice result" on public.voice_range_results;
create policy "Users delete their voice result" on public.voice_range_results
for delete to authenticated using (user_id = (auth.jwt() ->> 'sub'));
