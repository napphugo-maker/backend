create table public.members (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  user_id    uuid not null references auth.users(id),
  role       text not null check (role in ('owner', 'manager')),
  created_at timestamptz not null default now(),
  unique (company_id, user_id)
);
create index on public.members (user_id);
