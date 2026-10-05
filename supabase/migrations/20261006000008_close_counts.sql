create table public.close_counts (
  id            uuid primary key default gen_random_uuid(),
  venue_id      uuid not null references public.venues(id),
  night_date    date not null,
  cards_counted integer not null check (cards_counted >= 0),
  counted_by    uuid references auth.users(id),
  counted_at    timestamptz not null default now(),
  unique (venue_id, night_date)
);
