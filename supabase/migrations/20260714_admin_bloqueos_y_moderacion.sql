-- ============================================================
-- Vai Rodar — Bloqueos (usuarios/placas), moderación de ofertas,
-- workshop_categories y vistas admin ampliadas
-- Migration: 20260714_admin_bloqueos_y_moderacion.sql
-- IDEMPOTENTE — seguro de re-ejecutar
-- Requiere: 20260713_mvp_v2_backend_contracts.sql y
--           20260713_solicitudes_expiracion_y_corte_por_alta.sql
--
-- Contenido:
--   1. Bloqueo de usuarios: profiles.blocked (+motivo/fecha/quién)
--   2. Bloqueo de placas: vehicles.blocked (+motivo/fecha/quién)
--   3. Motivo/fecha de rechazo o bloqueo de comercios (workshops)
--   4. Moderación de ofertas: nueva oferta nace 'pending'; solo
--      'active' aparece públicamente (trigger + constraint)
--   5. workshop_categories (puente) + backfill desde services
--   6. admin_users_overview y admin_workshops_overview ampliadas
--   7. RLS: usuario o placa bloqueados no crean solicitudes/reservas
-- ============================================================


-- ─── 1. Bloqueo de usuarios ──────────────────────────────────

alter table public.profiles
  add column if not exists blocked        boolean not null default false,
  add column if not exists blocked_reason text,
  add column if not exists blocked_at     timestamptz,
  add column if not exists blocked_by     text;


-- ─── 2. Bloqueo de placas ────────────────────────────────────

alter table public.vehicles
  add column if not exists blocked        boolean not null default false,
  add column if not exists blocked_reason text,
  add column if not exists blocked_at     timestamptz,
  add column if not exists blocked_by     text;


-- ─── 3. Motivo de rechazo/bloqueo de comercios ───────────────
-- El frontend admin lee blocked_reason y blocked_at para la
-- pestaña "Rejeitados e bloqueados".

alter table public.workshops
  add column if not exists blocked_reason text,
  add column if not exists blocked_at     timestamptz;


-- ─── 4. Moderación de ofertas ────────────────────────────────
-- Estado único: pending (nueva, esperando al admin) → active
-- (aprobada y publicada) / inactive (apagada) / rejected /
-- expired. La vista pública y la policy ya filtran 'active',
-- así que 'pending' nunca se publica.

do $$ begin
  alter table public.workshop_offers drop constraint offers_status_check;
exception when undefined_object then null;
end $$;

do $$ begin
  alter table public.workshop_offers
    add constraint offers_status_check
    check (status in ('pending','active','inactive','rejected','expired'));
exception when duplicate_object then null;
end $$;

alter table public.workshop_offers alter column status set default 'pending';

-- El panel del taller inserta status='active' directamente; este
-- trigger fuerza 'pending' cuando inserta un usuario autenticado
-- que no es admin. El service role (admin backoffice) tiene
-- auth.uid() null y no se ve afectado.
create or replace function public.force_offer_pending()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    new.status := 'pending';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_offers_force_pending on public.workshop_offers;
create trigger trg_offers_force_pending
  before insert on public.workshop_offers
  for each row execute function public.force_offer_pending();

-- Un comercio no puede aprobar o rechazar sus propias ofertas. Si edita
-- el contenido de una oferta ya publicada, vuelve a moderacion.
create or replace function public.guard_offer_moderation_update()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    if new.status in ('rejected', 'expired') then
      new.status := old.status;
    elsif new.status = 'active' and old.status is distinct from 'active' then
      new.status := 'pending';
    end if;

    if old.status = 'active'
       and new.status = 'active'
       and (
         new.category is distinct from old.category
         or new.title is distinct from old.title
         or new.description is distinct from old.description
         or new.image_url is distinct from old.image_url
         or new.starts_at is distinct from old.starts_at
         or new.ends_at is distinct from old.ends_at
       ) then
      new.status := 'pending';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_offers_guard_moderation_update on public.workshop_offers;
create trigger trg_offers_guard_moderation_update
  before update on public.workshop_offers
  for each row execute function public.guard_offer_moderation_update();


-- ─── 5. workshop_categories (fuente única de categorías) ─────

create table if not exists public.workshop_categories (
  workshop_id uuid not null references public.workshops(id) on delete cascade,
  category_id uuid not null references public.service_categories(id) on delete restrict,
  created_at  timestamptz not null default now(),
  primary key (workshop_id, category_id)
);

-- Corrige instalaciones parciales o re-ejecuciones donde la FK anterior
-- todavia tenga ON DELETE CASCADE.
alter table public.workshop_categories
  drop constraint if exists workshop_categories_category_id_fkey;
alter table public.workshop_categories
  add constraint workshop_categories_category_id_fkey
  foreign key (category_id) references public.service_categories(id) on delete restrict;

alter table public.workshop_categories enable row level security;

drop policy if exists "Publico lee categorias de comercios"
  on public.workshop_categories;
create policy "Publico lee categorias de comercios"
  on public.workshop_categories for select
  using (
    exists (
      select 1 from public.workshops w
      where w.id = workshop_categories.workshop_id
        and w.approval_status = 'approved'
        and w.visible = true
    )
    and exists (
      select 1 from public.service_categories c
      where c.id = workshop_categories.category_id
        and c.active = true
    )
  );

do $$ begin
  create policy "Dueno gestiona categorias de su comercio"
    on public.workshop_categories for all
    using (exists (
      select 1 from public.workshops w
      where w.id = workshop_categories.workshop_id and w.owner_id = auth.uid()
    ))
    with check (exists (
      select 1 from public.workshops w
      where w.id = workshop_categories.workshop_id and w.owner_id = auth.uid()
    ));
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Admin gestiona categorias de comercios"
    on public.workshop_categories for all
    using (public.is_admin())
    with check (public.is_admin());
exception when duplicate_object then null;
end $$;

-- Backfill desde workshops.services (nombres exactos del catálogo)
insert into public.workshop_categories (workshop_id, category_id)
select w.id, c.id
from public.workshops w
join public.service_categories c
  on c.name = any(w.services)
  or lower(trim(c.name)) = any(select lower(trim(s)) from unnest(w.services) as s)
on conflict (workshop_id, category_id) do nothing;


-- ─── 6. Vistas admin ampliadas ───────────────────────────────

-- 6.1 admin_users_overview: se agregan columnas AL FINAL (create
--     or replace lo permite). Incluye bloqueo, ban de Auth y el
--     comercio asociado si el usuario es dueño de uno.
create or replace view public.admin_users_overview as
select
  p.id,
  p.name,
  p.email,
  p.phone,
  p.role::text                                    as role,
  p.created_at                                    as registered_at,
  u.last_sign_in_at,
  coalesce(v.vehicle_count, 0)                    as vehicle_count,
  coalesce(sr.request_count, 0)                   as request_count,
  coalesce(vl.listing_count, 0)                   as listing_count,
  p.blocked,
  p.blocked_reason,
  p.blocked_at,
  u.banned_until,
  w.id                                            as workshop_id,
  w.name                                          as workshop_name
from public.profiles p
left join auth.users u on u.id = p.id
left join (
  select user_id, count(*) as vehicle_count
  from public.vehicles
  group by user_id
) v on v.user_id = p.id
left join (
  select user_id, count(*) as request_count
  from public.service_requests
  group by user_id
) sr on sr.user_id = p.id
left join (
  select user_id, count(*) as listing_count
  from public.vehicle_listings
  group by user_id
) vl on vl.user_id = p.id
left join public.workshops w on w.owner_id = p.id;

revoke all on public.admin_users_overview from public, anon, authenticated;

-- 6.2 admin_workshops_overview: columnas nuevas al final.
create or replace view public.admin_workshops_overview as
select
  w.id,
  w.owner_id,
  w.name,
  w.legal_name,
  w.cnpj,
  w.responsible_name,
  w.contact_phone,
  w.whatsapp,
  w.email,
  w.cep,
  w.zip_code,
  w.address,
  w.neighborhood,
  w.city,
  w.state,
  w.latitude,
  w.longitude,
  w.category,
  w.services as categories,
  w.services,
  w.business_type,
  w.parts_categories,
  w.parts_delivery_enabled,
  w.parts_pickup_enabled,
  w.open,
  w.visible,
  w.approval_status,
  w.subscription_status,
  w.created_at,
  w.updated_at,
  w.photo_url,
  w.schedule,
  w.home_service,
  w.blocked_reason,
  w.blocked_at
from public.workshops w;


-- ─── 7. RLS: bloqueados no operan ────────────────────────────
-- El bloqueo principal es el ban en Supabase Auth (no puede
-- iniciar sesión). Estas policies cubren tokens todavía vivos.

-- 7.1 Usuario bloqueado o placa bloqueada no crean solicitudes
drop policy if exists "Motorista cria solicitações" on public.service_requests;

create policy "Motorista cria solicitações"
  on public.service_requests for insert
  with check (
    auth.uid() = user_id
    and not exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.blocked = true
    )
    and (
      vehicle_id is null
      or not exists (
        select 1 from public.vehicles v
        where v.id = vehicle_id and v.blocked = true
      )
    )
  );

-- 7.2 Usuario bloqueado no crea reservas
drop policy if exists "Motorista cria reserva" on public.reservations;

create policy "Motorista cria reserva"
  on public.reservations for insert
  with check (
    auth.uid() = user_id
    and not exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.blocked = true
    )
  );


-- ============================================================
-- DIAGNÓSTICO — correr después de aplicar la migration
-- ============================================================

-- 1. Columnas de bloqueo:
-- select column_name from information_schema.columns
-- where table_name in ('profiles','vehicles','workshops')
--   and column_name like 'blocked%' order by table_name, column_name;

-- 2. Backfill de categorías:
-- select w.name, count(wc.category_id) as categorias
-- from public.workshops w
-- left join public.workshop_categories wc on wc.workshop_id = w.id
-- group by w.name;

-- 3. Moderación de ofertas (default pending):
-- select column_default from information_schema.columns
-- where table_name = 'workshop_offers' and column_name = 'status';

-- 4. Vista de usuarios con bloqueo:
-- select id, name, role, blocked, workshop_name
-- from public.admin_users_overview limit 5;

-- ─── FIN DE MIGRATION ─────────────────────────────────────────
