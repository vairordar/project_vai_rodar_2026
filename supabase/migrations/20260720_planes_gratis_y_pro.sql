-- ============================================================
-- Vai Rodar — Planes Grátis y Profissional
-- Migration: 20260720_planes_gratis_y_pro.sql
-- IDEMPOTENTE — seguro de re-ejecutar
--
-- Modelo:
--   1. plans: catálogo oficial de planes con precio (admin lo
--      edita; el cadastro lo lee). price_monthly NULL = "Em breve"
--      (se muestra el plan pero aún no se cobra).
--   2. workshops.plan ('free'|'pro') elegido en el cadastro,
--      workshops.plan_price = override de precio POR CLIENTE
--      (null = usa el precio oficial de la tabla plans).
--   3. Visibilidad: el plan free funciona completo YA — un taller
--      free aprobado aparece en el mapa sin necesidad de
--      suscripción/pago. El gating por suscripción queda para pro.
--   4. Los 2 talleres existentes quedan en free.
-- ============================================================


-- ─── 1. Catálogo de planes ───────────────────────────────────

create table if not exists public.plans (
  code          text primary key,
  name          text not null,
  description   text,
  price_monthly numeric(10,2),          -- NULL = "Em breve" (sin cobro)
  benefits      jsonb not null default '[]'::jsonb,
  active        boolean not null default true,
  sort_order    integer not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

drop trigger if exists trg_plans_updated_at on public.plans;
create trigger trg_plans_updated_at
  before update on public.plans
  for each row execute function public.update_updated_at_column();

alter table public.plans enable row level security;

do $$ begin
  create policy "Publico lee planes activos"
    on public.plans for select
    using (active = true);
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Admin gestiona planes"
    on public.plans for all
    using (public.is_admin()) with check (public.is_admin());
exception when duplicate_object then null;
end $$;

-- Seeds (el admin puede editar textos, beneficios y precio después)
insert into public.plans (code, name, description, price_monthly, benefits, sort_order) values
  (
    'free',
    'Grátis',
    'O essencial para começar a receber clientes.',
    0,
    '["Aparecer no mapa do Vai Rodar","Receber solicitações de motoristas","Enviar propostas com preço e prazo","Chat com clientes","Agenda e reservas"]'::jsonb,
    10
  ),
  (
    'pro',
    'Profissional',
    'Para oficinas que querem se destacar e crescer.',
    null,
    '["Tudo do plano Grátis","Destaque nos resultados do mapa","Selo de oficina verificada","Ofertas e promoções em destaque","Prioridade nas solicitações da região","Suporte prioritário"]'::jsonb,
    20
  )
on conflict (code) do nothing;


-- ─── 2. Plan del taller ──────────────────────────────────────

alter table public.workshops
  add column if not exists plan             text not null default 'free',
  add column if not exists plan_price       numeric(10,2),
  add column if not exists plan_selected_at timestamptz;

do $$ begin
  alter table public.workshops
    add constraint workshops_plan_check
    check (plan in ('free','pro'));
exception when duplicate_object then null;
end $$;

-- Talleres existentes quedan en free explícitamente
update public.workshops
set plan = 'free', plan_selected_at = coalesce(plan_selected_at, created_at)
where plan is null or plan = '' or plan = 'free';


-- ─── 3. Visibilidad: free funciona sin suscripción ───────────
-- Se recrean las 3 vistas públicas cambiando SOLO la condición de
-- suscripción: plan free pasa siempre; pro exige suscripción
-- vigente (trial/active) como hasta ahora.

create or replace view public.public_workshops_search as
select
  w.id,
  w.name,
  w.business_type,
  w.city,
  w.address,
  w.neighborhood,
  w.category,
  coalesce(
    nullif(
      (
        select array_agg(c.name order by c.sort_order, c.name)
        from public.workshop_categories wc
        join public.service_categories c on c.id = wc.category_id
        where wc.workshop_id = w.id
          and c.active = true
      ),
      '{}'::text[]
    ),
    w.services
  ) as categories,
  w.parts_categories,
  w.open,
  w.visible,
  w.parts_delivery_enabled,
  w.parts_pickup_enabled,
  w.latitude,
  w.longitude,
  w.photo_url,
  coalesce(w.schedule, '{}'::jsonb) as schedule,
  w.home_service,
  (
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'name',        ws.name,
          'category',    sc.name,
          'subcategory', ssc.name,
          'price',       ws.reference_price,
          'duration',    ws.duration,
          'unit',        ws.duration_unit
        )
        order by sc.sort_order, coalesce(ssc.sort_order, 0), ws.name
      ),
      '[]'::jsonb
    )
    from public.workshop_services ws
    join public.service_categories sc  on sc.id = ws.category_id
    left join public.service_subcategories ssc on ssc.id = ws.subcategory_id
    where ws.workshop_id = w.id
      and ws.active = true
  ) as service_items
from public.workshops w
where w.open = true
  and w.visible = true
  and w.approval_status = 'approved'
  and w.business_type in ('workshop','both')
  and (
    coalesce(w.plan, 'free') = 'free'
    or w.subscription_status is null
    or w.subscription_status in ('trial','active')
  );

create or replace view public.public_parts_stores_search as
select
  w.id,
  w.name,
  w.business_type,
  w.city,
  w.address,
  w.neighborhood,
  w.category,
  w.services as categories,
  w.parts_categories,
  w.open,
  w.visible,
  w.parts_delivery_enabled,
  w.parts_pickup_enabled,
  w.parts_whatsapp,
  w.latitude,
  w.longitude
from public.workshops w
where w.open = true
  and w.visible = true
  and w.approval_status = 'approved'
  and w.business_type in ('parts_store','both')
  and (
    coalesce(w.plan, 'free') = 'free'
    or w.subscription_status is null
    or w.subscription_status in ('trial','active')
  );

create or replace view public.public_active_offers as
select
  wo.id as offer_id,
  wo.workshop_id,
  w.name as business_name,
  w.business_type,
  wo.category,
  wo.title,
  wo.description,
  wo.image_url,
  wo.starts_at,
  wo.ends_at,
  wo.clicks,
  wo.sales
from public.workshop_offers wo
join public.workshops w on w.id = wo.workshop_id
where wo.status = 'active'
  and wo.starts_at <= now()
  and wo.ends_at >= now()
  and w.open = true
  and w.visible = true
  and w.approval_status = 'approved'
  and (
    coalesce(w.plan, 'free') = 'free'
    or w.subscription_status is null
    or w.subscription_status in ('trial','active')
  );

grant select on public.public_workshops_search    to anon, authenticated;
grant select on public.public_parts_stores_search to anon, authenticated;
grant select on public.public_active_offers       to anon, authenticated;


-- ─── 4. Vista admin con el plan ──────────────────────────────
-- Columnas nuevas AL FINAL (create or replace lo permite).

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
  w.blocked_at,
  w.plan,
  w.plan_price,
  w.plan_selected_at
from public.workshops w;


-- ============================================================
-- DIAGNÓSTICO — correr después de aplicar la migration
-- ============================================================

-- 1. Catálogo de planes:
-- select code, name, price_monthly, active from public.plans order by sort_order;

-- 2. Talleres con plan:
-- select name, plan, plan_price, subscription_status from public.workshops;

-- 3. Un taller free aprobado y visible debe aparecer aunque tenga
--    subscription_status = 'pending_payment':
-- select id, name from public.public_workshops_search;

-- ─── FIN DE MIGRATION ─────────────────────────────────────────
