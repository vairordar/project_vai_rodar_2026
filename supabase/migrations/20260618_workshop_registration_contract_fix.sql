-- ============================================================
-- Vai Rodar - Workshop registration/admin contract fix
-- Safe to re-run. Does not delete existing workshop data.
--
-- Purpose:
-- register-workshop.js writes these columns through service role.
-- admin-data.js reads admin_workshops_overview.
-- This migration makes the DB contract explicit in one place.
-- ============================================================

do $$
begin
  alter type public.user_role add value if not exists 'workshop';
exception when others then
  null;
end $$;

alter table if exists public.profiles
  drop constraint if exists profiles_role_check;

alter table if exists public.profiles
  add column if not exists phone text,
  add column if not exists avatar_url text;

create table if not exists public.workshops (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid references public.profiles(id) on delete set null,
  name       text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.workshops
  add column if not exists owner_id uuid references public.profiles(id) on delete set null,
  add column if not exists name text,
  add column if not exists legal_name text,
  add column if not exists cnpj text,
  add column if not exists responsible_name text,
  add column if not exists contact_phone text,
  add column if not exists business_type text not null default 'workshop',
  add column if not exists parts_categories text[] not null default '{}',
  add column if not exists parts_delivery_enabled boolean not null default false,
  add column if not exists parts_pickup_enabled boolean not null default true,
  add column if not exists description text,
  add column if not exists email text,
  add column if not exists phone text,
  add column if not exists whatsapp text,
  add column if not exists address text,
  add column if not exists neighborhood text,
  add column if not exists city text,
  add column if not exists state text,
  add column if not exists zip_code text,
  add column if not exists cep text,
  add column if not exists latitude numeric,
  add column if not exists longitude numeric,
  add column if not exists services text[] default '{}',
  add column if not exists category text,
  add column if not exists schedule jsonb default '{}'::jsonb,
  add column if not exists open boolean not null default false,
  add column if not exists visible boolean not null default false,
  add column if not exists approval_status text not null default 'pending',
  add column if not exists approved_at timestamptz,
  add column if not exists approved_by uuid references public.profiles(id),
  add column if not exists subscription_status text not null default 'pending_payment',
  add column if not exists max_bookings_per_slot integer not null default 1,
  add column if not exists slot_minutes integer not null default 60,
  add column if not exists rating numeric(3,2) default 0,
  add column if not exists review_count integer default 0,
  add column if not exists photo_url text,
  add column if not exists website text,
  add column if not exists parts_whatsapp text,
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists updated_at timestamptz not null default now();

update public.workshops
set
  business_type = coalesce(nullif(business_type,''), 'workshop'),
  parts_categories = coalesce(parts_categories, '{}'),
  parts_delivery_enabled = coalesce(parts_delivery_enabled, false),
  parts_pickup_enabled = coalesce(parts_pickup_enabled, true),
  services = coalesce(services, '{}'),
  schedule = coalesce(schedule, '{}'::jsonb),
  open = coalesce(open, false),
  visible = coalesce(visible, false),
  approval_status = coalesce(nullif(approval_status,''), 'pending'),
  subscription_status = coalesce(nullif(subscription_status,''), 'pending_payment'),
  max_bookings_per_slot = coalesce(max_bookings_per_slot, 1),
  slot_minutes = coalesce(slot_minutes, 60)
where true;

do $$
begin
  alter table public.workshops
    add constraint workshops_business_type_check
    check (business_type in ('workshop','parts_store','both'));
exception when duplicate_object then null;
end $$;

do $$
begin
  alter table public.workshops
    add constraint workshops_approval_status_check
    check (approval_status in ('pending','approved','rejected','blocked'));
exception when duplicate_object then null;
end $$;

do $$
begin
  alter table public.workshops
    add constraint workshops_subscription_status_check
    check (subscription_status in ('trial','active','pending_payment','expired','cancelled'));
exception when duplicate_object then null;
end $$;

create index if not exists workshops_owner_id_idx on public.workshops(owner_id);
create index if not exists workshops_approval_status_idx on public.workshops(approval_status);
create index if not exists workshops_visible_open_idx on public.workshops(visible, open);
create index if not exists workshops_business_type_idx on public.workshops(business_type);
create index if not exists workshops_city_idx on public.workshops(city);

alter table public.workshops enable row level security;

do $$
begin
  create policy "Dueno ve su propio workshop"
    on public.workshops for select
    to authenticated
    using (auth.uid() = owner_id);
exception when duplicate_object then null;
end $$;

do $$
begin
  create policy "Dueno crea su propio workshop"
    on public.workshops for insert
    to authenticated
    with check (auth.uid() = owner_id);
exception when duplicate_object then null;
end $$;

do $$
begin
  create policy "Dueno actualiza su propio workshop"
    on public.workshops for update
    to authenticated
    using (auth.uid() = owner_id)
    with check (auth.uid() = owner_id);
exception when duplicate_object then null;
end $$;

drop view if exists public.admin_workshops_overview;

create view public.admin_workshops_overview as
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
  w.updated_at
from public.workshops w;

grant select on public.admin_workshops_overview to authenticated;

-- Diagnostics after running:
-- select column_name from information_schema.columns
-- where table_schema='public' and table_name='workshops'
-- order by ordinal_position;
--
-- select * from public.admin_workshops_overview order by created_at desc limit 5;
