-- Run once in Supabase Dashboard -> SQL Editor to enable message attachments.

alter table public.messages add column if not exists media_url text;
alter table public.messages add column if not exists media_type text
  check (media_type in ('image', 'video', 'audio', 'pdf', 'file'));
alter table public.messages add column if not exists file_name text;
alter table public.messages add column if not exists waveform jsonb;

alter table public.messages drop constraint if exists messages_body_check;
alter table public.messages add constraint messages_body_check check (
  char_length(trim(body)) between 0 and 4000
  and (char_length(trim(body)) > 0 or media_url is not null)
);

insert into storage.buckets (id, name, public)
values ('message-media', 'message-media', true)
on conflict (id) do update set public = true;

drop policy if exists "Members view message attachments" on storage.objects;
create policy "Members view message attachments" on storage.objects
for select to authenticated using (bucket_id = 'message-media');

drop policy if exists "Users upload message attachments" on storage.objects;
create policy "Users upload message attachments" on storage.objects
for insert to authenticated with check (
  bucket_id = 'message-media'
  and (storage.foldername(name))[1] = (auth.jwt() ->> 'sub')
);

drop policy if exists "Users delete their message attachments" on storage.objects;
create policy "Users delete their message attachments" on storage.objects
for delete to authenticated using (
  bucket_id = 'message-media'
  and (storage.foldername(name))[1] = (auth.jwt() ->> 'sub')
);
