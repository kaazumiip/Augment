-- Timed polls with exactly one mutable vote per person.
alter table public.posts
  add column if not exists poll_ends_at timestamptz;

-- Existing polls did not have a duration. Close them at migration time so the
-- app and database agree that they are result-only rather than open forever.
update public.posts post_row
set poll_ends_at = now()
where post_row.poll_ends_at is null
  and exists (
    select 1 from public.poll_options option_row
    where option_row.post_id = post_row.id
  );

alter table public.poll_votes
  add column if not exists post_id uuid;

update public.poll_votes vote
set post_id = option_row.post_id
from public.poll_options option_row
where option_row.id = vote.option_id
  and vote.post_id is null;

-- Older clients could vote for more than one option in the same poll. Keep
-- only the most recent vote before adding the database-level uniqueness rule.
with ranked_votes as (
  select
    ctid,
    row_number() over (
      partition by post_id, user_id
      order by created_at desc, option_id
    ) as position
  from public.poll_votes
)
delete from public.poll_votes vote
using ranked_votes ranked
where vote.ctid = ranked.ctid
  and ranked.position > 1;

alter table public.poll_votes
  alter column post_id set not null;

alter table public.poll_votes
  drop constraint if exists poll_votes_pkey;

alter table public.poll_votes
  add constraint poll_votes_pkey primary key (post_id, user_id);

alter table public.poll_votes
  drop constraint if exists poll_votes_post_id_fkey;

alter table public.poll_votes
  add constraint poll_votes_post_id_fkey
  foreign key (post_id) references public.posts(id) on delete cascade;

create or replace function public.vote_in_poll(target_option_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  voter_id text := auth.jwt() ->> 'sub';
  target_post_id uuid;
  closes_at timestamptz;
begin
  if voter_id is null or voter_id = '' then
    raise exception 'Authentication is required.';
  end if;

  select option_row.post_id, post_row.poll_ends_at
  into target_post_id, closes_at
  from public.poll_options option_row
  join public.posts post_row on post_row.id = option_row.post_id
  where option_row.id = target_option_id;

  if target_post_id is null then
    raise exception 'Poll option not found.';
  end if;

  if closes_at is null or closes_at <= now() then
    raise exception 'This poll has ended.';
  end if;

  insert into public.poll_votes (post_id, option_id, user_id, created_at)
  values (target_post_id, target_option_id, voter_id, now())
  on conflict (post_id, user_id) do update
    set option_id = excluded.option_id,
        created_at = excluded.created_at;

  update public.posts
  set updated_at = now()
  where id = target_post_id;
end;
$$;

revoke all on function public.vote_in_poll(uuid) from public;
grant execute on function public.vote_in_poll(uuid) to authenticated;

-- Votes remain visible for result counts. All writes go through the function
-- above so clients cannot bypass the one-vote or expiry rules.
drop policy if exists "Users manage their poll votes" on public.poll_votes;
