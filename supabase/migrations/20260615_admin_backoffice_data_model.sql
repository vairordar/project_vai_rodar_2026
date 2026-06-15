-- ============================================================
-- Vai Rodar — Admin Backoffice Data Model
-- Migration: 20260615_admin_backoffice_data_model.sql
-- Ejecutar completo en Supabase SQL Editor
-- IDEMPOTENTE — seguro de re-ejecutar
-- ============================================================

-- ─── 0. Extensiones requeridas ───────────────────────────────
create extension if not exists "uuid-ossp";

-- ─── 1. Extender public.workshops ────────────────────────────
alter table public.workshops
  add column if not exists legal_name          text,
  add column if not exists cnpj                text,
  add column if not exists responsible_name    text,
  add column if not exists contact_phone       text,
  add column if not exists whatsapp            text,
  add column if not exists cep                 text,
  add column if not exists neighborhood        text,
  add column if not exists latitude            numeric,
  add column if not exists longitude           numeric,
  add column if not exists approval_status     text not null default 'pending',
  add column if not exists approved_at         timestamptz,
  add column if not exists approved_by         uuid references public.profiles(id),
  add column if not exists visible             boolean not null default false,
  add column if not exists subscription_status text not null default 'pending_payment';

-- Constraints sobre workshops (idempotente via DO block)
do $$ begin
  alter table public.workshops
    add constraint workshops_approval_status_check
    check (approval_status in ('pending','approved','rejected','blocked'));
exception when duplicate_object then null;
end $$;

do $$ begin
  alter table public.workshops
    add constraint workshops_subscription_status_check
    check (subscription_status in ('trial','active','pending_payment','expired','cancelled'));
exception when duplicate_object then null;
end $$;

-- ─── 2. Tabla public.workshop_subscriptions ──────────────────
create table if not exists public.workshop_subscriptions (
  id                uuid        primary key default uuid_generate_v4(),
  workshop_id       uuid        not null references public.workshops(id) on delete cascade,
  plan_name         text        not null default 'Anual oficina',
  status            text        not null default 'pending_payment',
  paid_at           timestamptz,
  starts_at         timestamptz,
  expires_at        timestamptz,
  duration_days     integer     not null default 365,
  amount_paid       numeric(10,2) default 0,
  payment_method    text,
  payment_reference text,
  invoice_url       text,
  created_by_admin  uuid        references public.profiles(id),
  notes             text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint workshop_subscriptions_status_check
    check (status in ('trial','active','pending_payment','expired','cancelled')),
  constraint workshop_subscriptions_duration_check
    check (duration_days > 0),
  constraint workshop_subscriptions_amount_check
    check (amount_paid >= 0)
);

-- Trigger: calcular starts_at, expires_at y sincronizar workshops.subscription_status
create or replace function public.fn_subscription_on_paid()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Si paid_at se acaba de establecer, calcular fechas automáticamente
  if new.paid_at is not null and (old.paid_at is null or old.paid_at <> new.paid_at) then
    new.starts_at  := date_trunc('day', new.paid_at) + interval '1 day';
    new.expires_at := new.starts_at + (new.duration_days || ' days')::interval;
    new.status     := 'active';
  end if;

  -- Actualizar workshops.subscription_status
  update public.workshops
    set subscription_status = new.status
    where id = new.workshop_id;

  new.updated_at := now();
  return new;
end;
$$;

do $$ begin
  create trigger trg_subscription_on_paid
    before insert or update on public.workshop_subscriptions
    for each row execute function public.fn_subscription_on_paid();
exception when duplicate_object then null;
end $$;

-- ─── 3. Tabla public.workshop_payments ───────────────────────
create table if not exists public.workshop_payments (
  id               uuid        primary key default uuid_generate_v4(),
  workshop_id      uuid        not null references public.workshops(id) on delete cascade,
  subscription_id  uuid        references public.workshop_subscriptions(id) on delete set null,
  paid_at          timestamptz not null default now(),
  status           text        not null default 'paid',
  method           text,
  amount           numeric(10,2) not null default 0,
  reference        text,
  invoice_url      text,
  notes            text,
  created_by_admin uuid        references public.profiles(id),
  created_at       timestamptz not null default now(),
  constraint workshop_payments_status_check
    check (status in ('paid','pending','failed','refunded','cancelled')),
  constraint workshop_payments_amount_check
    check (amount >= 0)
);

-- ─── 4. Tabla public.analytics_events ────────────────────────
create table if not exists public.analytics_events (
  id                      uuid        primary key default uuid_generate_v4(),
  user_id                 uuid        references public.profiles(id) on delete set null,
  workshop_id             uuid        references public.workshops(id) on delete set null,
  event_type              text        not null,
  source_app              text        not null default 'user-app',
  search_query            text,
  service_category        text,
  location_text           text,
  city                    text,
  state                   text,
  neighborhood            text,
  latitude                numeric,
  longitude               numeric,
  related_request_id      uuid        references public.service_requests(id) on delete set null,
  related_conversation_id uuid        references public.conversations(id) on delete set null,
  related_offer_id        uuid        references public.workshop_offers(id) on delete set null,
  metadata                jsonb       not null default '{}'::jsonb,
  created_at              timestamptz not null default now(),
  constraint analytics_events_type_check
    check (event_type in (
      'search',
      'chat_started',
      'chat_message',
      'plate_lookup',
      'service_request_created',
      'proposal_received',
      'proposal_accepted',
      'reservation_created',
      'workshop_profile_view',
      'offer_viewed',
      'offer_clicked',
      'workshop_register_started',
      'workshop_register_completed'
    ))
);

-- ─── 5. Tabla public.admin_audit_logs ────────────────────────
create table if not exists public.admin_audit_logs (
  id          uuid        primary key default uuid_generate_v4(),
  admin_id    uuid        references public.profiles(id) on delete set null,
  admin_email text,
  action      text        not null,
  entity      text,
  entity_id   uuid,
  detail      text,
  metadata    jsonb       not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);

-- ─── 6. Helper function is_admin() ───────────────────────────
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid()
      and role::text = 'admin'
  );
$$;

-- ─── 7. RLS ──────────────────────────────────────────────────

-- workshop_subscriptions
alter table public.workshop_subscriptions enable row level security;

do $$ begin
  create policy "Admin gestiona suscripciones"
    on public.workshop_subscriptions for all
    using (public.is_admin())
    with check (public.is_admin());
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Taller ve sua suscripcion"
    on public.workshop_subscriptions for select
    using (
      exists (
        select 1 from public.workshops w
        where w.id = workshop_id and w.owner_id = auth.uid()
      )
    );
exception when duplicate_object then null;
end $$;

-- workshop_payments
alter table public.workshop_payments enable row level security;

do $$ begin
  create policy "Admin gestiona pagos"
    on public.workshop_payments for all
    using (public.is_admin())
    with check (public.is_admin());
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Taller ve seus pagos"
    on public.workshop_payments for select
    using (
      exists (
        select 1 from public.workshops w
        where w.id = workshop_id and w.owner_id = auth.uid()
      )
    );
exception when duplicate_object then null;
end $$;

-- analytics_events
alter table public.analytics_events enable row level security;

do $$ begin
  create policy "Admin ve todos los eventos"
    on public.analytics_events for all
    using (public.is_admin())
    with check (public.is_admin());
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Apps insertan eventos"
    on public.analytics_events for insert
    with check (true);
exception when duplicate_object then null;
end $$;

-- admin_audit_logs
alter table public.admin_audit_logs enable row level security;

do $$ begin
  create policy "Admin gestiona audit logs"
    on public.admin_audit_logs for all
    using (public.is_admin())
    with check (public.is_admin());
exception when duplicate_object then null;
end $$;

-- ─── 8. Trigger updated_at para workshop_subscriptions ───────
-- (workshop_payments y admin_audit_logs son inmutables por diseño)
create or replace function public.update_updated_at_column()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

do $$ begin
  create trigger trg_ws_subscriptions_updated_at
    before update on public.workshop_subscriptions
    for each row execute function public.update_updated_at_column();
exception when duplicate_object then null;
end $$;

-- ─── 9. Vistas para el admin backoffice ──────────────────────

-- Vista: admin_workshops_overview
create or replace view public.admin_workshops_overview as
select
  w.id,
  w.name,
  w.legal_name,
  w.cnpj,
  w.responsible_name,
  w.contact_phone,
  w.whatsapp,
  w.cep,
  w.address,
  w.neighborhood,
  w.city,
  w.state,
  w.latitude,
  w.longitude,
  w.category,
  w.services,
  w.approval_status,
  w.open,
  w.visible,
  w.subscription_status,
  w.created_at,
  w.approved_at,
  sub.id                                       as current_subscription_id,
  sub.expires_at                               as subscription_expires_at,
  case
    when sub.expires_at is null then null
    else greatest(0, extract(day from (sub.expires_at - now()))::integer)
  end                                          as subscription_days_remaining
from public.workshops w
left join lateral (
  select id, expires_at
  from public.workshop_subscriptions ws
  where ws.workshop_id = w.id
    and ws.status = 'active'
  order by ws.expires_at desc
  limit 1
) sub on true;

-- Vista: admin_dashboard_summary
create or replace view public.admin_dashboard_summary as
select
  (select count(*)                        from public.workshops)                                                  as total_workshops,
  (select count(*)                        from public.workshops where approval_status = 'approved' and visible = true) as active_workshops,
  (select count(*)                        from public.workshops where approval_status = 'pending')                as pending_workshops,
  (select count(*)                        from public.workshops where subscription_status in ('active','trial'))  as paying_workshops,
  (select count(*)                        from public.workshops where subscription_status = 'expired')            as expired_workshops,
  (select count(*)                        from public.profiles  where role::text = 'user')                        as total_users,
  (select count(*)                        from public.service_requests where created_at >= now() - interval '30 days') as total_service_requests_30d,
  (select count(*)                        from public.reservations     where created_at >= now() - interval '30 days') as total_reservations_30d,
  (select count(*)                        from public.conversations    where created_at >= now() - interval '30 days') as total_chats_30d,
  (select count(*)                        from public.analytics_events
                                          where event_type = 'offer_clicked'
                                            and created_at >= now() - interval '30 days')                         as total_offer_clicks_30d,
  (case
    when (select count(*) from public.service_requests where created_at >= now() - interval '30 days') = 0 then 0
    else round(
      (select count(*) from public.reservations where created_at >= now() - interval '30 days')::numeric /
      (select count(*) from public.service_requests where created_at >= now() - interval '30 days')::numeric * 100,
      2
    )
  end)                                                                                                            as request_to_reservation_conversion_30d;

-- Vista: admin_top_locations_30d
create or replace view public.admin_top_locations_30d as
select
  location_text,
  city,
  state,
  neighborhood,
  count(*) as event_count
from public.analytics_events
where event_type = 'search'
  and created_at >= now() - interval '30 days'
group by location_text, city, state, neighborhood
order by event_count desc;

-- Vista: admin_top_services_30d
create or replace view public.admin_top_services_30d as
select
  service_category,
  count(*) as event_count
from public.analytics_events
where service_category is not null
  and created_at >= now() - interval '30 days'
group by service_category
order by event_count desc;

-- Vista: admin_chat_usage_30d
create or replace view public.admin_chat_usage_30d as
select
  c.workshop_id,
  w.name as workshop_name,
  count(distinct c.id)  as conversation_count,
  count(m.id)           as message_count
from public.conversations c
join public.workshops w on w.id = c.workshop_id
left join public.messages m on m.conversation_id = c.id
  and m.created_at >= now() - interval '30 days'
where c.created_at >= now() - interval '30 days'
group by c.workshop_id, w.name
order by message_count desc;

-- ─── 10. Índices ─────────────────────────────────────────────
create index if not exists workshops_approval_status_idx      on public.workshops(approval_status);
create index if not exists workshops_subscription_status_idx  on public.workshops(subscription_status);
create index if not exists workshops_visible_open_idx         on public.workshops(visible, open);
create index if not exists workshop_subscriptions_workshop_id_idx on public.workshop_subscriptions(workshop_id);
create index if not exists workshop_subscriptions_status_idx  on public.workshop_subscriptions(status);
create index if not exists workshop_subscriptions_expires_at_idx  on public.workshop_subscriptions(expires_at);
create index if not exists workshop_payments_workshop_id_idx  on public.workshop_payments(workshop_id);
create index if not exists workshop_payments_paid_at_idx      on public.workshop_payments(paid_at desc);
create index if not exists analytics_events_type_created_idx  on public.analytics_events(event_type, created_at desc);
create index if not exists analytics_events_location_idx      on public.analytics_events(city, state, neighborhood);
create index if not exists analytics_events_service_idx       on public.analytics_events(service_category);
create index if not exists admin_audit_logs_created_idx       on public.admin_audit_logs(created_at desc);

-- ─── FIN DE MIGRATION ────────────────────────────────────────
-- Tablas NO tocadas: user-app, workshop-app, workshop-register-standalone
-- Tablas existentes NO modificadas (solo extendidas): workshops
-- ─────────────────────────────────────────────────────────────
