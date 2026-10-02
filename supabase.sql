-- Вставьте в Supabase: SQL Editor -> New query -> Run
create table public.orders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  code text,
  details text,
  total int,
  sel jsonb,
  created_at timestamptz not null default now()
);
alter table public.orders enable row level security;
create policy "own select" on public.orders for select using (auth.uid() = user_id);
create policy "own insert" on public.orders for insert with check (auth.uid() = user_id);
