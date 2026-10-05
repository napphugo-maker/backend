-- Only a hash of the device key is stored; the raw key lives on the device.
create table public.devices (
  id              uuid primary key default gen_random_uuid(),
  venue_id        uuid not null references public.venues(id),
  station_label   text not null,
  device_key_hash text not null unique,
  last_seen_at    timestamptz,
  revoked_at      timestamptz,
  created_at      timestamptz not null default now()
);
create index on public.devices (venue_id);
