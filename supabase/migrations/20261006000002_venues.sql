create table public.venues (
  id                  uuid primary key default gen_random_uuid(),
  company_id          uuid not null references public.companies(id),
  name                text not null,
  timezone            text not null,
  night_rollover_hour smallint not null default 6 check (night_rollover_hour between 0 and 23),
  early_entry_cutoff  time,
  card_code_prefix    text not null,
  created_at          timestamptz not null default now(),
  unique (company_id, card_code_prefix)
);
create index on public.venues (company_id);
