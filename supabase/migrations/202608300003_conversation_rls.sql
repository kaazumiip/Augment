-- Run this once in Supabase Dashboard -> SQL Editor.
-- Fixes: "infinite recursion detected in policy for relation conversation_members".

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
create policy "Members see conversations" on public.conversations
for select to authenticated using (public.is_conversation_member(id));

drop policy if exists "Members update conversations" on public.conversations;
create policy "Members update conversations" on public.conversations
for update to authenticated using (public.is_conversation_member(id));

drop policy if exists "Members see membership" on public.conversation_members;
create policy "Members see membership" on public.conversation_members
for select to authenticated using (public.is_conversation_member(conversation_id));

drop policy if exists "Members see messages" on public.messages;
create policy "Members see messages" on public.messages
for select to authenticated using (public.is_conversation_member(conversation_id));

drop policy if exists "Members send messages" on public.messages;
create policy "Members send messages" on public.messages
for insert to authenticated with check (
  sender_id = (auth.jwt() ->> 'sub')
  and public.is_conversation_member(conversation_id)
);
