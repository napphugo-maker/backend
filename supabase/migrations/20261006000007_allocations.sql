create table public.allocations (
  id             uuid primary key default gen_random_uuid(),
  venue_id       uuid not null references public.venues(id),
  night_date     date not null,
  card_holder_id uuid not null references public.card_holders(id),
  cards_taken    integer not null default 0 check (cards_taken >= 0),
  cards_returned integer not null default 0 check (cards_returned >= 0),
  updated_at     timestamptz not null default now(),
  unique (venue_id, night_date, card_holder_id)
);
