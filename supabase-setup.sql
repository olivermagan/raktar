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
-- napló: csak az admin olvassa; mindenki ír (a trigger tölti a nevet); módosítás/törlés senkinek
create policy "admin olvas"  on public.moves for select to authenticated using (public.is_admin());
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

-- Vevői fiókok (3. verzió): vevő csak a saját adatait látja
alter table public.members add column if not exists customer_id text;
alter table public.members drop constraint if exists members_role_check;
alter table public.members add constraint members_role_check check (role in ('admin','worker','customer'));
create or replace function public.is_member()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where lower(email) = lower(auth.jwt() ->> 'email') and active and role in ('admin','worker'));
$$;
create or replace function public.is_customer()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where lower(email) = lower(auth.jwt() ->> 'email') and active and role = 'customer');
$$;
create or replace function public.my_customer()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', c.id, 'name', c.data ->> 'name', 'discount', coalesce(nullif(c.data ->> 'discount','')::numeric, 0),
    'addr', c.data ->> 'addr', 'email', c.data ->> 'email', 'tax', c.data ->> 'tax')
  from public.customers c join public.members m on m.customer_id = c.id
  where lower(m.email) = lower(auth.jwt() ->> 'email') and m.active and m.role = 'customer' limit 1;
$$;
create or replace function public.my_orders()
returns setof jsonb language sql stable security definer set search_path = public as $$
  select o.data || jsonb_build_object('id', o.id) from public.orders o
  where public.is_customer() and o.data -> 'customer' ->> 'id' = (select customer_id from public.members where lower(email) = lower(auth.jwt() ->> 'email') and active and role = 'customer' limit 1)
  order by o.data ->> 'createdAt' desc;
$$;
create or replace function public.catalog()
returns table(id text, name text, category text, unit text, price numeric, vat numeric, qty numeric, image text)
language sql stable security definer set search_path = public as $$
  select p.id, p.data ->> 'name', p.data ->> 'category', coalesce(nullif(p.data ->> 'unit',''), 'db'),
    nullif(p.data ->> 'price','')::numeric, coalesce(nullif(p.data ->> 'vat','')::numeric, 27),
    coalesce(nullif(p.data ->> 'qty','')::numeric, 0), coalesce(p.data ->> 'imageUrl', p.data ->> 'imageData')
  from public.products p where public.is_member() or public.is_customer()
  order by p.data ->> 'name';
$$;
revoke execute on function public.my_customer() from anon;
revoke execute on function public.my_orders() from anon;
revoke execute on function public.catalog() from anon;

-- vevő e-mail címe = vevői belépés (automatikusan)
create or replace function public.customer_sync_member()
returns trigger language plpgsql security definer set search_path = public as $$
declare em text;
begin
  if tg_op = 'DELETE' then
    delete from public.members where customer_id = old.id and role = 'customer';
    return old;
  end if;
  em := lower(nullif(trim(new.data ->> 'email'), ''));
  if em is null then
    delete from public.members where customer_id = new.id and role = 'customer';
    return new;
  end if;
  if exists (select 1 from public.members where lower(email) = em and role <> 'customer') then return new; end if;
  delete from public.members where customer_id = new.id and role = 'customer' and lower(email) <> em;
  insert into public.members (email, name, role, active, customer_id)
  values (em, coalesce(new.data ->> 'name', ''), 'customer', true, new.id)
  on conflict (email) do update set name = excluded.name, customer_id = excluded.customer_id where public.members.role = 'customer';
  return new;
end $$;
drop trigger if exists customer_sync_member on public.customers;
create trigger customer_sync_member after insert or update or delete on public.customers for each row execute function public.customer_sync_member();

-- Értékesítés szerepkör és vevői rendelések (4. verzió): a leadott rendeléseket csak admin és értékesítés látja
alter table public.members drop constraint if exists members_role_check;
alter table public.members add constraint members_role_check check (role in ('admin','worker','sales','customer'));
create or replace function public.is_member()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where lower(email) = lower(auth.jwt() ->> 'email') and active and role in ('admin','worker','sales'));
$$;
create or replace function public.is_seller()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where lower(email) = lower(auth.jwt() ->> 'email') and active and role in ('admin','sales'));
$$;
create or replace function public.my_customer_id()
returns text language sql stable security definer set search_path = public as $$
  select customer_id from public.members where lower(email) = lower(auth.jwt() ->> 'email') and active and role = 'customer' limit 1;
$$;
create table if not exists public.requests (
  id            text primary key default gen_random_uuid()::text,
  created_at    timestamptz not null default now(),
  customer_id   text,
  customer_name text,
  created_by    text,
  items         jsonb not null default '[]',
  note          text,
  status        text not null default 'uj' check (status in ('uj','feldolgozva','elutasitva')),
  order_no      text,
  handled_by    text,
  handled_at    timestamptz
);
create or replace function public.requests_set()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.customer_id := public.my_customer_id();
  if new.customer_id is null then raise exception 'Csak vevoi fiokbol lehet rendelest leadni'; end if;
  new.customer_name := (select data ->> 'name' from public.customers where id = new.customer_id);
  new.created_by := auth.jwt() ->> 'email';
  new.created_at := now();
  new.status := 'uj'; new.order_no := null; new.handled_by := null; new.handled_at := null;
  return new;
end $$;
drop trigger if exists requests_set on public.requests;
create trigger requests_set before insert on public.requests for each row execute function public.requests_set();
alter table public.requests enable row level security;
drop policy if exists "olvas" on public.requests;
drop policy if exists "vevo lead" on public.requests;
drop policy if exists "ertekesites kezel" on public.requests;
create policy "olvas" on public.requests for select to authenticated using (public.is_seller() or customer_id = public.my_customer_id());
create policy "vevo lead" on public.requests for insert to authenticated with check (public.is_customer());
create policy "ertekesites kezel" on public.requests for update to authenticated using (public.is_seller()) with check (public.is_seller());
do $$ begin
  begin alter publication supabase_realtime add table public.requests; exception when others then null; end;
end $$;

-- >>> ÍRD ÁT A SAJÁT E-MAIL CÍMEDRE ÉS NEVEDRE (te leszel az admin) <<<
insert into public.members (email, name, role) values ('IDE_AZ_EMAIL_CIMED@pelda.hu', 'Saját Név', 'admin')
on conflict (email) do update set role = 'admin', active = true;
