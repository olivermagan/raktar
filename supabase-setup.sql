-- =====================================================================
--  RAKTÁR – Supabase beállítás
--  Supabase → SQL Editor → New query → másold be az egészet → Run
--  FONTOS: az utolsó sorban írd át az e-mail címet a sajátodra!
-- =====================================================================

-- Kik kezelhetik a raktárat (admin). Később ide jönnek a szerepkörök.
create table if not exists public.admins (
  email text primary key
);

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where lower(email) = lower(auth.jwt() ->> 'email'));
$$;

-- Adattáblák (az adat egy JSON mezőben, így később bővíthető átalakítás nélkül)
create table if not exists public.products  (id text primary key, data jsonb not null default '{}', updated_at timestamptz not null default now());
create table if not exists public.customers (id text primary key, data jsonb not null default '{}', updated_at timestamptz not null default now());
create table if not exists public.orders    (id text primary key, data jsonb not null default '{}', updated_at timestamptz not null default now());
create table if not exists public.config    (id text primary key, data jsonb not null default '{}', updated_at timestamptz not null default now());

create index if not exists products_barcode_idx on public.products ((data ->> 'barcode'));

-- Jogosultságok: csak admin olvas és ír
alter table public.admins    enable row level security;
alter table public.products  enable row level security;
alter table public.customers enable row level security;
alter table public.orders    enable row level security;
alter table public.config    enable row level security;

drop policy if exists "admin all" on public.products;
drop policy if exists "admin all" on public.customers;
drop policy if exists "admin all" on public.orders;
drop policy if exists "admin all" on public.config;
drop policy if exists "admin read" on public.admins;
create policy "admin all" on public.products  for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admin all" on public.customers for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admin all" on public.orders    for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admin all" on public.config    for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admin read" on public.admins   for select to authenticated using (public.is_admin());

-- Készlet atomi módosítása (két telefon egyszerre se rontsa el a darabszámot)
create or replace function public.adjust_stock(pid text, delta numeric)
returns jsonb language plpgsql security invoker set search_path = public as $$
declare result jsonb;
begin
  update public.products
     set data = jsonb_set(data, '{qty}', to_jsonb(coalesce((data ->> 'qty')::numeric, 0) + delta)),
         updated_at = now()
   where id = pid
  returning data into result;
  return result;
end $$;

-- Élő szinkron (telefon ↔ gép)
do $$ begin
  begin alter publication supabase_realtime add table public.products;  exception when others then null; end;
  begin alter publication supabase_realtime add table public.customers; exception when others then null; end;
  begin alter publication supabase_realtime add table public.orders;    exception when others then null; end;
  begin alter publication supabase_realtime add table public.config;    exception when others then null; end;
end $$;

-- Termékképek tárolója (nyilvánosan olvasható kép-URL, írni csak admin tud)
insert into storage.buckets (id, name, public) values ('termekkepek', 'termekkepek', true)
on conflict (id) do nothing;

drop policy if exists "termekkep olvas" on storage.objects;
drop policy if exists "termekkep ir" on storage.objects;
drop policy if exists "termekkep modosit" on storage.objects;
drop policy if exists "termekkep torol" on storage.objects;
create policy "termekkep olvas"   on storage.objects for select using (bucket_id = 'termekkepek');
create policy "termekkep ir"      on storage.objects for insert to authenticated with check (bucket_id = 'termekkepek' and public.is_admin());
create policy "termekkep modosit" on storage.objects for update to authenticated using (bucket_id = 'termekkepek' and public.is_admin());
create policy "termekkep torol"   on storage.objects for delete to authenticated using (bucket_id = 'termekkepek' and public.is_admin());

-- >>> ÍRD ÁT A SAJÁT E-MAIL CÍMEDRE (ezzel fogsz belépni az appba) <<<
insert into public.admins (email) values ('IDE_AZ_EMAIL_CIMED@pelda.hu') on conflict do nothing;
