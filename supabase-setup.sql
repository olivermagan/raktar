-- =====================================================================
--  RAKTÁR – Supabase beállítás (2. verzió: felhasználók, szerepkörök, mozgásnapló)
--  Supabase → SQL Editor → New query → másold be az egészet → Run
--  FONTOS: az utolsó sorban írd át az e-mail címet és a nevet a sajátodra!
--  Többször is lefuttatható, nem töröl adatot.
-- =====================================================================

-- Felhasználók (tagok): csak akik itt szerepelnek és aktívak, használhatják az appot
create table if not exists public.members (
  email      text primary key,
  name       text not null default '',
  role       text not null default 'worker' check (role in ('admin','worker')),
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

create or replace function public.is_member()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where lower(email) = lower(auth.jwt() ->> 'email') and active);
$$;
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where lower(email) = lower(auth.jwt() ->> 'email') and active and role = 'admin');
$$;

-- Adattáblák
create table if not exists public.products  (id text primary key, data jsonb not null default '{}', updated_at timestamptz not null default now());
create table if not exists public.customers (id text primary key, data jsonb not null default '{}', updated_at timestamptz not null default now());
create table if not exists public.orders    (id text primary key, data jsonb not null default '{}', updated_at timestamptz not null default now());
create table if not exists public.config    (id text primary key, data jsonb not null default '{}', updated_at timestamptz not null default now());
create index if not exists products_barcode_idx on public.products ((data ->> 'barcode'));

-- Mozgásnapló: ki, mikor, mit, mennyit. Nem módosítható és nem törölhető (az admin sem tudja).
create table if not exists public.moves (
  id           bigint generated always as identity primary key,
  created_at   timestamptz not null default now(),
  user_email   text not null default '',
  user_name    text not null default '',
  product_id   text,
  product_name text,
  delta        numeric not null default 0,
  qty_after    numeric,
  kind         text not null default '',
  ref          text,
  note         text
);
create index if not exists moves_created_idx on public.moves (created_at desc);
create index if not exists moves_product_idx on public.moves (product_id);
create index if not exists moves_user_idx on public.moves (user_email);

-- a naplóba mindig a valódi bejelentkezett felhasználó kerül, nem lehet hamisítani
create or replace function public.moves_set_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.user_email := coalesce(auth.jwt() ->> 'email', '');
  new.user_name  := coalesce((select name from public.members where lower(email) = lower(new.user_email)), '');
  new.created_at := now();
  return new;
end $$;
drop trigger if exists moves_set_user on public.moves;
create trigger moves_set_user before insert on public.moves for each row execute function public.moves_set_user();

-- Jogosultságok
alter table public.members   enable row level security;
alter table public.products  enable row level security;
alter table public.customers enable row level security;
alter table public.orders    enable row level security;
alter table public.config    enable row level security;
alter table public.moves     enable row level security;

do $$ declare t text; p record; begin
  foreach t in array array['members','products','customers','orders','config','moves'] loop
    for p in select policyname from pg_policies where schemaname='public' and tablename=t loop
      execute format('drop policy %I on public.%I', p.policyname, t);
    end loop;
  end loop;
end $$;

-- tagok: mindenki látja a névsort, csak admin kezeli
create policy "tag olvas"   on public.members for select to authenticated using (public.is_member() or lower(email)=lower(auth.jwt()->>'email'));
create policy "admin kezel" on public.members for all    to authenticated using (public.is_admin()) with check (public.is_admin());
-- termékek, vevők: tag olvas/felvesz/módosít, törölni csak admin
create policy "tag olvas"    on public.products  for select to authenticated using (public.is_member());
create policy "tag felvesz"  on public.products  for insert to authenticated with check (public.is_member());
create policy "tag modosit"  on public.products  for update to authenticated using (public.is_member()) with check (public.is_member());
create policy "admin torol"  on public.products  for delete to authenticated using (public.is_admin());
create policy "tag olvas"    on public.customers for select to authenticated using (public.is_member());
create policy "tag felvesz"  on public.customers for insert to authenticated with check (public.is_member());
create policy "tag modosit"  on public.customers for update to authenticated using (public.is_member()) with check (public.is_member());
create policy "admin torol"  on public.customers for delete to authenticated using (public.is_admin());
-- rendelések: tag olvas/felvesz, sztornózni (törölni) csak admin
create policy "tag olvas"    on public.orders for select to authenticated using (public.is_member());
create policy "tag felvesz"  on public.orders for insert to authenticated with check (public.is_member());
create policy "admin modosit" on public.orders for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admin torol"  on public.orders for delete to authenticated using (public.is_admin());
-- cégadatok: mindenki olvassa, csak admin írja
create policy "tag olvas"    on public.config for select to authenticated using (public.is_member());
create policy "admin ir"     on public.config for all    to authenticated using (public.is_admin()) with check (public.is_admin());
-- napló: tag olvas és ír (a trigger tölti a nevet), módosítás/törlés senkinek
create policy "tag olvas"    on public.moves for select to authenticated using (public.is_member());
create policy "tag ir"       on public.moves for insert to authenticated with check (public.is_member());

-- Készlet atomi módosítása + naplózás egy lépésben
drop function if exists public.adjust_stock(text, numeric);
create or replace function public.adjust_stock(pid text, delta numeric, kind text default '', ref text default null)
returns jsonb language plpgsql security invoker set search_path = public as $$
declare result jsonb;
begin
  update public.products
     set data = jsonb_set(data, '{qty}', to_jsonb(coalesce((data ->> 'qty')::numeric, 0) + delta)),
         updated_at = now()
   where id = pid
  returning data into result;
  if result is not null then
    insert into public.moves (product_id, product_name, delta, qty_after, kind, ref)
    values (pid, result ->> 'name', delta, (result ->> 'qty')::numeric, kind, ref);
  end if;
  return result;
end $$;

-- Élő szinkron (telefon ↔ gép)
do $$ declare t text; begin
  foreach t in array array['products','customers','orders','config','members'] loop
    begin execute format('alter publication supabase_realtime add table public.%I', t); exception when others then null; end;
  end loop;
end $$;

-- Termékképek
insert into storage.buckets (id, name, public) values ('termekkepek', 'termekkepek', true)
on conflict (id) do nothing;
drop policy if exists "termekkep olvas" on storage.objects;
drop policy if exists "termekkep ir" on storage.objects;
drop policy if exists "termekkep modosit" on storage.objects;
drop policy if exists "termekkep torol" on storage.objects;
create policy "termekkep olvas"   on storage.objects for select using (bucket_id = 'termekkepek');
create policy "termekkep ir"      on storage.objects for insert to authenticated with check (bucket_id = 'termekkepek' and public.is_member());
create policy "termekkep modosit" on storage.objects for update to authenticated using (bucket_id = 'termekkepek' and public.is_member());
create policy "termekkep torol"   on storage.objects for delete to authenticated using (bucket_id = 'termekkepek' and public.is_admin());

-- >>> ÍRD ÁT A SAJÁT E-MAIL CÍMEDRE ÉS NEVEDRE (te leszel az admin) <<<
insert into public.members (email, name, role) values ('IDE_AZ_EMAIL_CIMED@pelda.hu', 'Saját Név', 'admin')
on conflict (email) do update set role = 'admin', active = true;
