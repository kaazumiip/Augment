-- Community posts may share a rendered music-sheet image or PDF.
alter table public.posts
  drop constraint if exists posts_media_type_check;
alter table public.posts
  add constraint posts_media_type_check
  check (media_type in ('image', 'video', 'audio', 'sheet'));

alter table public.post_media
  drop constraint if exists post_media_media_type_check;
alter table public.post_media
  add constraint post_media_media_type_check
  check (media_type in ('image', 'video', 'audio', 'sheet'));
