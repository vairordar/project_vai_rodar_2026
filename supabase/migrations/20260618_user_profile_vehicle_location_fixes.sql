-- ============================================================
-- Vai Rodar - User profile, saved plates and location support
-- Safe to re-run. Does not delete existing data.
-- ============================================================

alter table if exists public.profiles
  add column if not exists phone text,
  add column if not exists avatar_url text;

do $$
begin
  alter type public.user_role add value if not exists 'workshop';
exception when others then
  null;
end $$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, name, email, phone, avatar_url, role)
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data->>'name',
      new.raw_user_meta_data->>'full_name',
      new.raw_user_meta_data->>'given_name',
      split_part(new.email, '@', 1),
      'Usuario'
    ),
    new.email,
    new.raw_user_meta_data->>'phone',
    coalesce(
      new.raw_user_meta_data->>'avatar_url',
      new.raw_user_meta_data->>'picture'
    ),
    case
      when new.raw_user_meta_data->>'role' = 'admin' then 'admin'::user_role
      else 'motorist'::user_role
    end
  )
  on conflict (id) do update set
    name = coalesce(excluded.name, public.profiles.name),
    email = coalesce(excluded.email, public.profiles.email),
    phone = coalesce(excluded.phone, public.profiles.phone),
    avatar_url = coalesce(excluded.avatar_url, public.profiles.avatar_url);
  return new;
end;
$$;

do $$
begin
  if not exists (
    select 1
    from pg_trigger
    where tgname = 'on_auth_user_created'
  ) then
    create trigger on_auth_user_created
      after insert on auth.users
      for each row execute function public.handle_new_user();
  end if;
end $$;

create table if not exists public.vehicles (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  plate      text not null,
  brand      text not null default '-',
  model      text not null default '-',
  year       integer,
  color      text,
  created_at timestamptz not null default now()
);

alter table public.vehicles
  add column if not exists user_id uuid references public.profiles(id) on delete cascade,
  add column if not exists plate text,
  add column if not exists brand text default '-',
  add column if not exists model text default '-',
  add column if not exists year integer,
  add column if not exists color text,
  add column if not exists created_at timestamptz not null default now();

create index if not exists vehicles_user_id_idx on public.vehicles(user_id);
create index if not exists vehicles_user_plate_idx on public.vehicles(user_id, plate);

alter table public.vehicles enable row level security;

revoke all on public.vehicles from anon;
grant select, insert, update, delete on public.vehicles to authenticated;
grant select, update on public.profiles to authenticated;

drop policy if exists "Motorista ve seus veiculos" on public.vehicles;
drop policy if exists "Motorista cria seus veiculos" on public.vehicles;
drop policy if exists "Motorista atualiza seus veiculos" on public.vehicles;
drop policy if exists "Motorista remove seus veiculos" on public.vehicles;
drop policy if exists "Motorista vê seus veículos" on public.vehicles;
drop policy if exists "Motorista gerencia seus veículos" on public.vehicles;

create policy "Motorista ve seus veiculos"
  on public.vehicles
  for select
  to authenticated
  using (auth.uid() = user_id);

create policy "Motorista cria seus veiculos"
  on public.vehicles
  for insert
  to authenticated
  with check (auth.uid() = user_id);

create policy "Motorista atualiza seus veiculos"
  on public.vehicles
  for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "Motorista remove seus veiculos"
  on public.vehicles
  for delete
  to authenticated
  using (auth.uid() = user_id);

drop policy if exists "Usuario lee su propio perfil" on public.profiles;
drop policy if exists "Usuario actualiza su propio perfil" on public.profiles;

create policy "Usuario lee su propio perfil"
  on public.profiles
  for select
  to authenticated
  using (auth.uid() = id);

create policy "Usuario actualiza su propio perfil"
  on public.profiles
  for update
  to authenticated
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- Diagnostics after running:
-- select column_name, data_type from information_schema.columns
-- where table_schema='public' and table_name in ('profiles','vehicles')
-- order by table_name, ordinal_position;
--
-- select tablename, rowsecurity from pg_tables
-- where schemaname='public' and tablename in ('profiles','vehicles');
--
-- select tablename, policyname, cmd, qual, with_check from pg_policies
-- where schemaname='public' and tablename in ('profiles','vehicles')
-- order by tablename, policyname;
