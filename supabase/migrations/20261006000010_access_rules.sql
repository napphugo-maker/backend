-- Access rules. People see only their own companies' venues; phones never touch
-- tables directly and write scans only through upload_scans().

-- Helpers run as definer so policies can read members without recursing into its own RLS.
create function public.my_company_ids() returns setof uuid
  language sql stable security definer set search_path = '' as $$
  select company_id from public.members where user_id = auth.uid()
$$;

create function public.my_owner_company_ids() returns setof uuid
  language sql stable security definer set search_path = '' as $$
  select company_id from public.members where user_id = auth.uid() and role = 'owner'
$$;

create function public.my_venue_ids() returns setof uuid
  language sql stable security definer set search_path = '' as $$
  select v.id from public.venues v
  join public.members m on m.company_id = v.company_id
  where m.user_id = auth.uid()
$$;

revoke execute on function public.my_company_ids(), public.my_owner_company_ids(), public.my_venue_ids() from public, anon;
grant  execute on function public.my_company_ids(), public.my_owner_company_ids(), public.my_venue_ids() to authenticated;

-- Phones (anon) get no table access at all.
revoke all on public.companies, public.venues, public.members, public.devices,
              public.card_holders, public.scans, public.allocations, public.close_counts from anon;

-- companies: read own. Created by hand.
create policy companies_read on public.companies for select to authenticated
  using (id in (select public.my_company_ids()));

-- members: read own companies; owners manage.
create policy members_read on public.members for select to authenticated
  using (company_id in (select public.my_company_ids()));
create policy members_owner_insert on public.members for insert to authenticated
  with check (company_id in (select public.my_owner_company_ids()));
create policy members_owner_update on public.members for update to authenticated
  using (company_id in (select public.my_owner_company_ids()))
  with check (company_id in (select public.my_owner_company_ids()));
create policy members_owner_delete on public.members for delete to authenticated
  using (company_id in (select public.my_owner_company_ids()));

-- venues: read own; owners edit settings. Created by hand.
create policy venues_read on public.venues for select to authenticated
  using (company_id in (select public.my_company_ids()));
create policy venues_owner_update on public.venues for update to authenticated
  using (company_id in (select public.my_owner_company_ids()))
  with check (company_id in (select public.my_owner_company_ids()));

-- devices, card_holders, close_counts: owners and managers, own venues.
create policy devices_read on public.devices for select to authenticated
  using (venue_id in (select public.my_venue_ids()));
create policy devices_insert on public.devices for insert to authenticated
  with check (venue_id in (select public.my_venue_ids()));
create policy devices_update on public.devices for update to authenticated
  using (venue_id in (select public.my_venue_ids()))
  with check (venue_id in (select public.my_venue_ids()));

create policy card_holders_read on public.card_holders for select to authenticated
  using (venue_id in (select public.my_venue_ids()));
create policy card_holders_insert on public.card_holders for insert to authenticated
  with check (venue_id in (select public.my_venue_ids()));
create policy card_holders_update on public.card_holders for update to authenticated
  using (venue_id in (select public.my_venue_ids()))
  with check (venue_id in (select public.my_venue_ids()));

create policy close_counts_read on public.close_counts for select to authenticated
  using (venue_id in (select public.my_venue_ids()));
create policy close_counts_insert on public.close_counts for insert to authenticated
  with check (venue_id in (select public.my_venue_ids()));
create policy close_counts_update on public.close_counts for update to authenticated
  using (venue_id in (select public.my_venue_ids()))
  with check (venue_id in (select public.my_venue_ids()));

-- allocations: as above, and the holder must belong to the same venue.
create policy allocations_read on public.allocations for select to authenticated
  using (venue_id in (select public.my_venue_ids()));
create policy allocations_insert on public.allocations for insert to authenticated
  with check (venue_id in (select public.my_venue_ids())
    and card_holder_id in (select h.id from public.card_holders h where h.venue_id = allocations.venue_id));
create policy allocations_update on public.allocations for update to authenticated
  using (venue_id in (select public.my_venue_ids()))
  with check (venue_id in (select public.my_venue_ids())
    and card_holder_id in (select h.id from public.card_holders h where h.venue_id = allocations.venue_id));

-- scans: people read own venues; nobody writes except upload_scans().
create policy scans_read on public.scans for select to authenticated
  using (venue_id in (select public.my_venue_ids()));

-- Phone upload. The key decides the device and venue; anything the phone sends for
-- them is ignored. A void row names the scan it cancels by cancels_seq (same device
-- and night). Repeats are skipped. Returns the highest seq held per night in the batch.
create function public.upload_scans(device_key text, rows jsonb)
  returns table (night_date date, max_seq integer)
  language plpgsql security definer set search_path = '' as $$
declare
  d public.devices;
  r record;
begin
  select * into d from public.devices
  where device_key_hash = encode(extensions.digest(device_key, 'sha256'), 'hex');
  if d.id is null or d.revoked_at is not null then
    raise exception 'unknown or revoked device' using errcode = '28000';
  end if;

  for r in
    select * from jsonb_to_recordset(rows) as x(
      night_date date, seq integer, code text, result text, promoter_code text,
      promoter text, night text, batch_date date, serial text, card_type text,
      device text, "timestamp" timestamptz, time_local text, station text, cancels_seq integer)
    order by x.seq
  loop
    insert into public.scans (venue_id, device_id, night_date, seq, code, result, promoter_code,
      promoter, night, batch_date, serial, card_type, device, "timestamp", time_local, station,
      cancels_scan_id)
    values (d.venue_id, d.id, r.night_date, r.seq, r.code, r.result, r.promoter_code,
      r.promoter, r.night, r.batch_date, r.serial, r.card_type, r.device, r."timestamp",
      r.time_local, r.station,
      (select s.id from public.scans s
        where s.device_id = d.id and s.night_date = r.night_date and s.seq = r.cancels_seq))
    on conflict on constraint scans_device_id_night_date_seq_key do nothing;
  end loop;

  update public.devices set last_seen_at = now() where id = d.id;

  return query
    select s.night_date, max(s.seq)
    from public.scans s
    where s.device_id = d.id
      and s.night_date in (select (e->>'night_date')::date from jsonb_array_elements(rows) e)
    group by s.night_date;
end $$;

revoke execute on function public.upload_scans(text, jsonb) from public;
grant  execute on function public.upload_scans(text, jsonb) to anon, authenticated;
