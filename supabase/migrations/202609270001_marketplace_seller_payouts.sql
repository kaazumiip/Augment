-- Seller-owned payout destination. Buyer money is collected by Augment first;
-- these details are used only by the operator when paying a seller later.
create table if not exists public.marketplace_seller_payouts (
  owner_id text primary key references public.profiles(id) on delete cascade,
  recipient_name text not null check (char_length(trim(recipient_name)) between 1 and 120),
  payout_method text not null check (payout_method in ('khqr', 'aba')) default 'khqr',
  qr_image_url text not null,
  payout_status text not null check (payout_status in ('not_ready', 'pending', 'paid')) default 'not_ready',
  updated_at timestamptz not null default now()
);

alter table public.marketplace_seller_payouts enable row level security;

drop policy if exists "Sellers manage their payout destination" on public.marketplace_seller_payouts;
create policy "Sellers manage their payout destination" on public.marketplace_seller_payouts
for all to authenticated
using (owner_id = (auth.jwt() ->> 'sub'))
with check (owner_id = (auth.jwt() ->> 'sub'));

-- The existing social-media bucket already limits writes to the signed-in
-- user's folder. Payout QR images use that owner folder and are only read by
-- the seller in the app; do not expose payout details in marketplace feeds.
