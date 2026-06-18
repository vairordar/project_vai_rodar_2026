-- ============================================================
-- Vai Rodar - fixes puntuales de diagnostico
-- Admin backoffice, realtime y profiles.role
-- Idempotente: seguro de re-ejecutar.
-- ============================================================

-- 1. El enum real usa 'motorist', no 'motorista'. Esta constraint
-- es redundante porque el enum ya valida role.
alter table public.profiles
  drop constraint if exists profiles_role_check;

-- 2. La vista admin_workshops_overview fue creada antes de business_type
-- y parts_categories. Se recrea incluyendo esos campos.
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
  sub.id as current_subscription_id,
  sub.expires_at as subscription_expires_at,
  case
    when sub.expires_at is null then null
    else greatest(0, extract(day from (sub.expires_at - now()))::integer)
  end as subscription_days_remaining,
  w.business_type,
  w.parts_categories
from public.workshops w
left join lateral (
  select id, expires_at
  from public.workshop_subscriptions ws
  where ws.workshop_id = w.id
    and ws.status = 'active'
  order by ws.expires_at desc
  limit 1
) sub on true;

-- 3. total_users filtraba por role='user', pero el enum real es 'motorist'.
create or replace view public.admin_dashboard_summary as
select
  (select count(*) from public.workshops) as total_workshops,
  (select count(*) from public.workshops where approval_status = 'approved' and visible = true) as active_workshops,
  (select count(*) from public.workshops where approval_status = 'pending') as pending_workshops,
  (select count(*) from public.workshops where subscription_status in ('active','trial')) as paying_workshops,
  (select count(*) from public.workshops where subscription_status = 'expired') as expired_workshops,
  (select count(*) from public.profiles where role::text = 'motorist') as total_users,
  (select count(*) from public.service_requests where created_at >= now() - interval '30 days') as total_service_requests_30d,
  (select count(*) from public.reservations where created_at >= now() - interval '30 days') as total_reservations_30d,
  (select count(*) from public.conversations where created_at >= now() - interval '30 days') as total_chats_30d,
  (select count(*) from public.analytics_events
    where event_type = 'offer_clicked'
      and created_at >= now() - interval '30 days') as total_offer_clicks_30d,
  (case
    when (select count(*) from public.service_requests where created_at >= now() - interval '30 days') = 0 then 0
    else round(
      100.0 * (select count(*) from public.reservations where created_at >= now() - interval '30 days')
      / (select count(*) from public.service_requests where created_at >= now() - interval '30 days'), 1
    )
  end) as request_to_reservation_conversion_30d;

-- 4. Realtime para notifications.
do $$ begin
  alter publication supabase_realtime add table public.notifications;
exception when duplicate_object then null;
end $$;

-- Diagnostico opcional despues de correr:
-- select conname from pg_constraint
-- where conrelid = 'public.profiles'::regclass and conname = 'profiles_role_check';
--
-- select column_name from information_schema.columns
-- where table_schema = 'public' and table_name = 'admin_workshops_overview'
-- order by ordinal_position;
--
-- select schemaname, tablename
-- from pg_publication_tables
-- where pubname = 'supabase_realtime'
-- order by tablename;
