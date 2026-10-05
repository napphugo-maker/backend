-- Separation test. Re-run after every database change: supabase test db
begin;
create extension if not exists pgtap with schema extensions;
select plan(20);

-- Two companies, each with a user, venue, device, holder, scan, allocation, close count.
insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'a@test.local'),
  ('bbbbbbbb-0000-0000-0000-000000000001', 'b@test.local');
insert into public.companies (id, name) values
  ('aaaaaaaa-0000-0000-0000-000000000002', 'Company A'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'Company B');
insert into public.members (company_id, user_id, role) values
  ('aaaaaaaa-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000001', 'owner'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000001', 'owner');
insert into public.venues (id, company_id, name, timezone, card_code_prefix) values
  ('aaaaaaaa-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000002', 'Venue A', 'Asia/Makassar', 'AA'),
  ('bbbbbbbb-0000-0000-0000-000000000003', 'bbbbbbbb-0000-0000-0000-000000000002', 'Venue B', 'Europe/London', 'BB');
insert into public.devices (id, venue_id, station_label, device_key_hash) values
  ('aaaaaaaa-0000-0000-0000-000000000004', 'aaaaaaaa-0000-0000-0000-000000000003', 'Host desk',
   encode(extensions.digest('key-a', 'sha256'), 'hex')),
  ('bbbbbbbb-0000-0000-0000-000000000004', 'bbbbbbbb-0000-0000-0000-000000000003', 'Host desk',
   encode(extensions.digest('key-b', 'sha256'), 'hex'));
insert into public.card_holders (id, venue_id, code, name) values
  ('aaaaaaaa-0000-0000-0000-000000000005', 'aaaaaaaa-0000-0000-0000-000000000003', 'A01', 'Holder A'),
  ('bbbbbbbb-0000-0000-0000-000000000005', 'bbbbbbbb-0000-0000-0000-000000000003', 'B01', 'Holder B');
insert into public.allocations (venue_id, night_date, card_holder_id, cards_taken) values
  ('aaaaaaaa-0000-0000-0000-000000000003', '2026-10-01', 'aaaaaaaa-0000-0000-0000-000000000005', 10);
insert into public.close_counts (venue_id, night_date, cards_counted) values
  ('aaaaaaaa-0000-0000-0000-000000000003', '2026-10-01', 5);

-- A's phone uploads one scan, twice. Also check its device/venue cannot be spoofed.
set local role anon;
select public.upload_scans('key-a', '[{"night_date":"2026-10-01","seq":1,"code":"AA-1","result":"ok",
  "timestamp":"2026-10-01T23:00:00+08","venue_id":"bbbbbbbb-0000-0000-0000-000000000003"}]');
select public.upload_scans('key-a', '[{"night_date":"2026-10-01","seq":1,"code":"AA-1","result":"ok",
  "timestamp":"2026-10-01T23:00:00+08"}]');

-- Phones with no login can read nothing.
select throws_ok('select count(*) from public.scans',        '42501', null, 'anon cannot read scans');
select throws_ok('select count(*) from public.card_holders', '42501', null, 'anon cannot read card_holders');
select throws_ok($$insert into public.scans (venue_id, device_id, night_date, seq, code, result, "timestamp")
  values ('aaaaaaaa-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000004', '2026-10-01', 99, 'x', 'ok', now())$$,
  '42501', null, 'anon cannot insert scans directly');
select throws_ok($$select public.upload_scans('wrong-key', '[]')$$, '28000', null, 'unknown key refused');

reset role;
select is((select count(*)::int from public.scans where code = 'AA-1'), 1, 'same scan sent twice leaves one row');
select is((select venue_id from public.scans where code = 'AA-1'),
  'aaaaaaaa-0000-0000-0000-000000000003'::uuid, 'scan lands in the key''s venue, not the one sent');

-- Log in as company B.
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;

select is((select count(*)::int from public.companies    where id = 'aaaaaaaa-0000-0000-0000-000000000002'), 0, 'B cannot see company A');
select is((select count(*)::int from public.venues       where company_id = 'aaaaaaaa-0000-0000-0000-000000000002'), 0, 'B cannot see A venues');
select is((select count(*)::int from public.members      where company_id = 'aaaaaaaa-0000-0000-0000-000000000002'), 0, 'B cannot see A members');
select is((select count(*)::int from public.devices      where venue_id = 'aaaaaaaa-0000-0000-0000-000000000003'), 0, 'B cannot see A devices');
select is((select count(*)::int from public.card_holders where venue_id = 'aaaaaaaa-0000-0000-0000-000000000003'), 0, 'B cannot see A card holders');
select is((select count(*)::int from public.scans        where venue_id = 'aaaaaaaa-0000-0000-0000-000000000003'), 0, 'B cannot see A scans');
select is((select count(*)::int from public.allocations  where venue_id = 'aaaaaaaa-0000-0000-0000-000000000003'), 0, 'B cannot see A allocations');
select is((select count(*)::int from public.close_counts where venue_id = 'aaaaaaaa-0000-0000-0000-000000000003'), 0, 'B cannot see A close counts');
select is((select count(*)::int from public.venues), 1, 'B sees its own venue');

select throws_ok($$insert into public.card_holders (venue_id, code, name)
  values ('aaaaaaaa-0000-0000-0000-000000000003', 'X99', 'Intruder')$$, '42501', null, 'B cannot add holders to A');
update public.venues set name = 'Hacked' where id = 'aaaaaaaa-0000-0000-0000-000000000003';
select throws_ok($$update public.card_holders set venue_id = 'aaaaaaaa-0000-0000-0000-000000000003'
  where id = 'bbbbbbbb-0000-0000-0000-000000000005'$$, null, null, 'B cannot move a row into A');
select throws_ok($$insert into public.scans (venue_id, device_id, night_date, seq, code, result, "timestamp")
  values ('bbbbbbbb-0000-0000-0000-000000000003', 'bbbbbbbb-0000-0000-0000-000000000004', '2026-10-01', 1, 'x', 'ok', now())$$,
  '42501', null, 'people cannot insert scans directly');

reset role;
select is((select name from public.venues where id = 'aaaaaaaa-0000-0000-0000-000000000003'), 'Venue A', 'B update to A venue had no effect');

-- Revoked device is refused.
update public.devices set revoked_at = now() where id = 'aaaaaaaa-0000-0000-0000-000000000004';
set local role anon;
select throws_ok($$select public.upload_scans('key-a', '[]')$$, '28000', null, 'revoked device refused');

select * from finish();
rollback;
