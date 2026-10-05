-- scans: append-only for every role, including service_role.
create function public.reject_change() returns trigger language plpgsql as $$
begin
  raise exception '% on %.% is not allowed', tg_op, tg_table_schema, tg_table_name;
end $$;

create trigger scans_no_update   before update   on public.scans for each row execute function public.reject_change();
create trigger scans_no_delete   before delete   on public.scans for each row execute function public.reject_change();
create trigger scans_no_truncate before truncate on public.scans for each statement execute function public.reject_change();

-- card_holders: never deleted; code frozen; retired is final.
create trigger card_holders_no_delete   before delete   on public.card_holders for each row execute function public.reject_change();
create trigger card_holders_no_truncate before truncate on public.card_holders for each statement execute function public.reject_change();

create function public.guard_card_holder_update() returns trigger language plpgsql as $$
begin
  if new.code <> old.code or new.venue_id <> old.venue_id then
    raise exception 'card holder code and venue cannot change';
  end if;
  if old.status = 'retired' and new.status <> 'retired' then
    raise exception 'a retired card holder cannot be reactivated';
  end if;
  return new;
end $$;
create trigger card_holders_guard_update before update on public.card_holders
  for each row execute function public.guard_card_holder_update();

-- RLS on, no policies yet (prompt 2).
alter table public.companies    enable row level security;
alter table public.venues       enable row level security;
alter table public.members      enable row level security;
alter table public.devices      enable row level security;
alter table public.card_holders enable row level security;
alter table public.scans        enable row level security;
alter table public.allocations  enable row level security;
alter table public.close_counts enable row level security;
