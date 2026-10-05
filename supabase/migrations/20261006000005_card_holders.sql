-- Holders are retired, never deleted. Codes are unique per venue for all time.
create table public.card_holders (
  id         uuid primary key default gen_random_uuid(),
  venue_id   uuid not null references public.venues(id),
  code       text not null,
  name       text not null,
  team       text,
  status     text not null default 'active' check (status in ('active', 'retired')),
  retired_at timestamptz,
  created_at timestamptz not null default now(),
  unique (venue_id, code),
  check ((status = 'retired') = (retired_at is not null))
);
