-- Permanent generated sheet files. Safe to run more than once.
insert into storage.buckets (id, name, public)
values ('sheet-assets', 'sheet-assets', true)
on conflict (id) do update set public = true;

drop policy if exists "Signed-in users view sheet assets" on storage.objects;
create policy "Signed-in users view sheet assets" on storage.objects
for select to authenticated using (bucket_id = 'sheet-assets');

drop policy if exists "Users upload their sheet assets" on storage.objects;
create policy "Users upload their sheet assets" on storage.objects
for insert to authenticated with check (
  bucket_id = 'sheet-assets'
  and (storage.foldername(name))[1] = (auth.jwt() ->> 'sub')
);

drop policy if exists "Users update their sheet assets" on storage.objects;
create policy "Users update their sheet assets" on storage.objects
for update to authenticated using (
  bucket_id = 'sheet-assets'
  and (storage.foldername(name))[1] = (auth.jwt() ->> 'sub')
) with check (
  bucket_id = 'sheet-assets'
  and (storage.foldername(name))[1] = (auth.jwt() ->> 'sub')
);

drop policy if exists "Users delete their sheet assets" on storage.objects;
create policy "Users delete their sheet assets" on storage.objects
for delete to authenticated using (
  bucket_id = 'sheet-assets'
  and (storage.foldername(name))[1] = (auth.jwt() ->> 'sub')
);
