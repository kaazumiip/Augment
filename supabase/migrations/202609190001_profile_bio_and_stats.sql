alter table public.profiles
  add column if not exists bio text not null default ''
  check (char_length(bio) <= 160);

-- These counts are safe to expose for any visible profile. The function runs
-- with the table owner's permissions so visitors do not need access to each
-- individual friendship row.
create or replace function public.profile_social_stats(profile_id text)
returns table(followers bigint, following bigint)
language sql
stable
security definer
set search_path = public
as $$
  select
    count(*) filter (where receiver_id = profile_id)::bigint as followers,
    count(*) filter (where sender_id = profile_id)::bigint as following
  from public.friend_requests
  where status = 'accepted'
    and (sender_id = profile_id or receiver_id = profile_id);
$$;

grant execute on function public.profile_social_stats(text) to authenticated;
