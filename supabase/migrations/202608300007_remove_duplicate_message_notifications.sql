-- Run once in Supabase Dashboard -> SQL Editor.
-- Direct-message alerts are handled by the Messages badge, not the bell.

drop trigger if exists direct_message_notification on public.messages;
delete from public.notifications where kind = 'message';
