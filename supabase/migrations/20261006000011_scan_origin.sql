-- Scan origin. A phone uploads its own rows and any it received by handover, so the
-- uploader is not always the scanner. source_device_id is the scanning phone's own
-- install ID (the CSV's device_id); device_id stays as the paired device that uploaded.
-- A repeat is the same scanner, night and seq within one venue. Without this, a
-- satellite's handed-over rows collide with the host desk's own seqs and are dropped.
alter table public.scans add column source_device_id uuid;
update public.scans set source_device_id = device_id;
alter table public.scans alter column source_device_id set not null;

alter table public.scans drop constraint scans_device_id_night_date_seq_key;
alter table public.scans add constraint scans_origin_key
  unique (venue_id, source_device_id, night_date, seq);

-- The phone's install ID, recorded at pairing so a re-paired phone can be recognised.
alter table public.devices add column client_device_id uuid;
create index on public.devices (client_device_id);

-- Return type changes (per scanner, not per night), so drop and recreate.
drop function public.upload_scans(text, jsonb);

-- Phone upload. The key decides the venue and uploading device; anything the phone
-- sends for them is ignored. Each row must carry the scanner's device_id. A void row
-- names the scan it cancels by cancels_seq (same scanner and night). Repeats are
-- skipped. Returns the highest seq held per scanner in the batch: seq never resets on
-- a phone, so one number per scanner is all the phone needs to know what to resend.
create function public.upload_scans(device_key text, rows jsonb)
  returns table (source_device_id uuid, max_seq integer)
  language plpgsql security definer set search_path = '' as $$
declare
  d public.devices;
  r record;
  target uuid;
begin
  select * into d from public.devices
  where device_key_hash = encode(extensions.digest(device_key, 'sha256'), 'hex');
  if d.id is null or d.revoked_at is not null then
    raise exception 'unknown or revoked device' using errcode = '28000';
  end if;

  for r in
    select * from jsonb_to_recordset(rows) as x(
      device_id uuid, night_date date, seq integer, code text, result text, promoter_code text,
      promoter text, night text, batch_date date, serial text, card_type text,
      device text, "timestamp" timestamptz, time_local text, station text, cancels_seq integer)
    order by x.device_id, x.seq
  loop
    if r.device_id is null then
      raise exception 'row seq % has no device_id', r.seq using errcode = '22023';
    end if;

    target := null;
    if r.cancels_seq is not null then
      select s.id into target from public.scans s
      where s.venue_id = d.venue_id and s.source_device_id = r.device_id
        and s.night_date = r.night_date and s.seq = r.cancels_seq;
      -- Named so a stuck uploader is diagnosable rather than a bare check failure.
      if target is null then
        raise exception 'void seq % cancels seq % which the server does not hold', r.seq, r.cancels_seq
          using errcode = '23503';
      end if;
    end if;

    insert into public.scans (venue_id, device_id, source_device_id, night_date, seq, code, result,
      promoter_code, promoter, night, batch_date, serial, card_type, device, "timestamp",
      time_local, station, cancels_scan_id)
    values (d.venue_id, d.id, r.device_id, r.night_date, r.seq, r.code, r.result,
      r.promoter_code, r.promoter, r.night, r.batch_date, r.serial, r.card_type, r.device,
      r."timestamp", r.time_local, r.station, target)
    on conflict on constraint scans_origin_key do nothing;
  end loop;

  update public.devices set last_seen_at = now() where id = d.id;

  return query
    select s.source_device_id, max(s.seq)
    from public.scans s
    where s.venue_id = d.venue_id
      and s.source_device_id in (select (e->>'device_id')::uuid from jsonb_array_elements(rows) e)
    group by s.source_device_id;
end $$;

revoke execute on function public.upload_scans(text, jsonb) from public;
grant  execute on function public.upload_scans(text, jsonb) to anon, authenticated;
