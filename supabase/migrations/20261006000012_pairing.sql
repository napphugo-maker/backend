-- Pairing. A one-time code ties a phone to a venue and hands it a key that only works
-- there. Only a hash of each code is stored, like device keys.
create table public.pairing_codes (
  id               uuid primary key default gen_random_uuid(),
  venue_id         uuid not null references public.venues(id),
  station_label    text not null,
  code_hash        text not null unique,
  expires_at       timestamptz not null,
  used_at          timestamptz,
  used_by_device   uuid references public.devices(id),
  created_by       uuid references auth.users(id),
  created_at       timestamptz not null default now()
);
create index on public.pairing_codes (venue_id);

alter table public.pairing_codes enable row level security;
revoke all on public.pairing_codes from anon;
create policy pairing_codes_read on public.pairing_codes for select to authenticated
  using (venue_id in (select public.my_venue_ids()));

-- Codes are typed on a phone, so drop look-alikes (0/O, 1/I/L) and ignore case,
-- spaces and dashes.
create function public.normalise_pairing_code(code text) returns text
  language sql immutable set search_path = '' as $$
  select upper(regexp_replace(coalesce(code, ''), '[^A-Za-z0-9]', '', 'g'))
$$;

-- Returns the code once; it cannot be read back. Run from the SQL editor until the
-- dashboard exists. A signed-in person may only create codes for their own venues.
create function public.create_pairing_code(venue_id uuid, station_label text)
  returns text
  language plpgsql security definer set search_path = '' as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  b bytea := extensions.gen_random_bytes(8);
  code text := '';
  i int;
begin
  if auth.uid() is not null and venue_id not in (select public.my_venue_ids()) then
    raise exception 'not your venue' using errcode = '42501';
  end if;
  if coalesce(trim(station_label), '') = '' then
    raise exception 'station label is required' using errcode = '22023';
  end if;
  for i in 0..7 loop
    code := code || substr(alphabet, (get_byte(b, i) % length(alphabet)) + 1, 1);
  end loop;
  insert into public.pairing_codes (venue_id, station_label, code_hash, expires_at, created_by)
  values (create_pairing_code.venue_id, trim(create_pairing_code.station_label),
    encode(extensions.digest(code, 'sha256'), 'hex'), now() + interval '24 hours', auth.uid());
  return code;
end $$;

revoke execute on function public.create_pairing_code(uuid, text) from public, anon;
grant  execute on function public.create_pairing_code(uuid, text) to authenticated;

-- The phone sends the code and its own install ID. One use per code. Re-pairing the
-- same phone revokes its earlier key for that venue, so a phone never holds two.
-- Every failure gives the same answer, so a guess learns nothing about which codes exist.
create function public.pair_device(code text, phone_device_id uuid)
  returns table (device_key text, venue_id uuid, venue_name text, station_label text)
  language plpgsql security definer set search_path = '' as $$
declare
  pc public.pairing_codes;
  new_key text := encode(extensions.gen_random_bytes(32), 'hex');
  new_id uuid;
begin
  select * into pc from public.pairing_codes p
  where p.code_hash = encode(extensions.digest(public.normalise_pairing_code(code), 'sha256'), 'hex')
  for update;
  if pc.id is null or pc.used_at is not null or pc.expires_at < now() or phone_device_id is null then
    raise exception 'invalid or expired pairing code' using errcode = '28000';
  end if;

  update public.devices d set revoked_at = now()
  where d.venue_id = pc.venue_id and d.client_device_id = phone_device_id and d.revoked_at is null;

  insert into public.devices (venue_id, station_label, device_key_hash, client_device_id, last_seen_at)
  values (pc.venue_id, pc.station_label, encode(extensions.digest(new_key, 'sha256'), 'hex'),
    phone_device_id, now())
  returning id into new_id;

  update public.pairing_codes set used_at = now(), used_by_device = new_id where id = pc.id;

  return query
    select new_key, v.id, v.name, pc.station_label from public.venues v where v.id = pc.venue_id;
end $$;

revoke execute on function public.pair_device(text, uuid) from public;
grant  execute on function public.pair_device(text, uuid) to anon, authenticated;
