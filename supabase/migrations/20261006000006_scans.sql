-- Columns mirror the door export CSV (Scripts/fixtures/.../corazon-THU-20260917-0246-HOSTDESK.csv),
-- plus venue_id. device_id, night_date and seq come from the CSV.
-- Append-only: a removal is a new row with result = 'void' and cancels_scan_id set.
create table public.scans (
  id              uuid primary key default gen_random_uuid(),
  venue_id        uuid not null references public.venues(id),
  device_id       uuid not null references public.devices(id),
  night_date      date not null,
  seq             integer not null check (seq > 0),
  code            text not null,
  result          text not null,
  promoter_code   text,
  promoter        text,
  night           text,
  batch_date      date,
  serial          text,
  card_type       text,
  device          text,
  "timestamp"     timestamptz not null,
  time_local      text,
  station         text,
  cancels_scan_id uuid references public.scans(id),
  received_at     timestamptz not null default now(),
  unique (device_id, night_date, seq),
  check ((result = 'void') = (cancels_scan_id is not null))
);
create index on public.scans (venue_id, night_date);
create unique index scans_cancel_once on public.scans (cancels_scan_id) where cancels_scan_id is not null;
