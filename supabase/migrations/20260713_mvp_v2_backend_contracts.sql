-- ============================================================
-- Vai Rodar — Contratos backend MVP V2 (user app 2026-07-13)
-- Migration: 20260713_mvp_v2_backend_contracts.sql
-- IDEMPOTENTE — seguro de re-ejecutar
--
-- Escrita sobre el estado REAL del banco verificado el 13/07/2026
-- (diagnóstico: supabase/diagnostico_backend_mvp_v2_20260713.sql).
--
-- Contenido:
--   1. Columnas nuevas: workshops.home_service,
--      service_requests.home_service
--   2. Catálogo: service_categories, service_subcategories,
--      workshop_services (+ RLS + seeds)
--   3. P0 solicitudes dirigidas: policy SELECT de service_requests
--      + request_open_for_workshop + can_view_request_photos
--      + workshop_can_view_request_owner
--   4. Vistas públicas: public_workshops_search con photo_url,
--      schedule, home_service y service_items; se versiona también
--      public_parts_stores_search tal como existe en el banco real
--      (tenía drift: latitude/longitude no estaban versionadas)
--   5. Storage: bucket workshop-logos + policies
-- ============================================================


-- ─── 1. Columnas nuevas ───────────────────────────────────────

alter table public.workshops
  add column if not exists home_service boolean not null default false;

alter table public.service_requests
  add column if not exists home_service boolean not null default false;


-- ─── 2. Catálogo de categorías, subcategorías y servicios ────

-- 2.1 Categorías (administradas por el admin; el nombre coincide
--     con allowedCategories del user app)
create table if not exists public.service_categories (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  sort_order  integer not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- 2.2 Subcategorías (administradas por el admin)
create table if not exists public.service_subcategories (
  id           uuid primary key default gen_random_uuid(),
  category_id  uuid not null references public.service_categories(id) on delete cascade,
  name         text not null,
  sort_order   integer not null default 0,
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (category_id, name)
);

create index if not exists idx_service_subcategories_category
  on public.service_subcategories(category_id);

-- 2.3 Servicios ofrecidos por cada taller (subcategoría aprobada
--     + precio de referencia y duración opcionales)
create table if not exists public.workshop_services (
  id               uuid primary key default gen_random_uuid(),
  workshop_id      uuid not null references public.workshops(id) on delete cascade,
  category_id      uuid not null references public.service_categories(id),
  subcategory_id   uuid references public.service_subcategories(id) on delete set null,
  name             text not null,
  reference_price  numeric(10,2),
  duration         numeric(10,2),
  duration_unit    text,
  active           boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (workshop_id, category_id, name)
);

do $$ begin
  alter table public.workshop_services
    add constraint workshop_services_duration_unit_check
    check (duration_unit is null or duration_unit in ('minutes','hours','days'));
exception when duplicate_object then null;
end $$;

create index if not exists idx_workshop_services_workshop
  on public.workshop_services(workshop_id);

-- 2.4 Trigger updated_at (reutiliza la función ya existente)
drop trigger if exists trg_workshop_services_updated_at on public.workshop_services;
create trigger trg_workshop_services_updated_at
  before update on public.workshop_services
  for each row execute function public.update_updated_at_column();

drop trigger if exists trg_service_categories_updated_at on public.service_categories;
create trigger trg_service_categories_updated_at
  before update on public.service_categories
  for each row execute function public.update_updated_at_column();

drop trigger if exists trg_service_subcategories_updated_at on public.service_subcategories;
create trigger trg_service_subcategories_updated_at
  before update on public.service_subcategories
  for each row execute function public.update_updated_at_column();

-- 2.5 RLS del catálogo
alter table public.service_categories    enable row level security;
alter table public.service_subcategories enable row level security;
alter table public.workshop_services     enable row level security;

-- Catálogo maestro: lectura pública de lo activo, gestión solo admin
do $$ begin
  create policy "Publico lee categorias activas"
    on public.service_categories for select
    using (active = true);
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Admin gestiona categorias"
    on public.service_categories for all
    using (public.is_admin())
    with check (public.is_admin());
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Publico lee subcategorias activas"
    on public.service_subcategories for select
    using (active = true);
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Admin gestiona subcategorias"
    on public.service_subcategories for all
    using (public.is_admin())
    with check (public.is_admin());
exception when duplicate_object then null;
end $$;

-- Servicios del taller: el dueño gestiona los suyos, admin todo.
-- La lectura pública sale por la vista public_workshops_search
-- (owner postgres), no por SELECT directo de anon a la tabla.
do $$ begin
  create policy "Dueno gestiona servicios de su taller"
    on public.workshop_services for all
    using (exists (
      select 1 from public.workshops w
      where w.id = workshop_services.workshop_id
        and w.owner_id = auth.uid()
    ))
    with check (exists (
      select 1 from public.workshops w
      where w.id = workshop_services.workshop_id
        and w.owner_id = auth.uid()
    ));
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Admin gestiona servicios de talleres"
    on public.workshop_services for all
    using (public.is_admin())
    with check (public.is_admin());
exception when duplicate_object then null;
end $$;

-- 2.6 Seeds de categorías (idempotentes; nombres exactos de
--     allowedCategories en apps/user-app/index.html)
insert into public.service_categories (name, sort_order) values
  ('Revisão geral / Manutenção preventiva', 10),
  ('Troca de óleo e filtros',               20),
  ('Freios e suspensão',                    30),
  ('Motor e transmissão',                   40),
  ('Elétrica automotiva',                   50),
  ('Ar-condicionado',                       60),
  ('Funilaria e pintura',                   70),
  ('Pneus e alinhamento',                   80),
  ('Diagnóstico computadorizado',           90),
  ('Vidros e acessórios',                  100),
  ('Blindagem',                            110),
  ('Lavagem e estética',                   120),
  ('Chaveiro automotivo',                  130)
on conflict (name) do nothing;

-- 2.7 Seeds de subcategorías iniciales (editables por el admin)
insert into public.service_subcategories (category_id, name, sort_order)
select c.id, s.name, s.sort_order
from public.service_categories c
join (values
  ('Revisão geral / Manutenção preventiva', 'Revisão completa',            10),
  ('Revisão geral / Manutenção preventiva', 'Revisão pré-viagem',          20),
  ('Revisão geral / Manutenção preventiva', 'Troca de correia dentada',    30),
  ('Revisão geral / Manutenção preventiva', 'Troca de velas',              40),
  ('Troca de óleo e filtros',               'Troca de óleo',               10),
  ('Troca de óleo e filtros',               'Troca de filtro de óleo',     20),
  ('Troca de óleo e filtros',               'Troca de filtro de ar',       30),
  ('Troca de óleo e filtros',               'Troca de filtro de combustível', 40),
  ('Freios e suspensão',                    'Troca de pastilhas',          10),
  ('Freios e suspensão',                    'Troca de discos',             20),
  ('Freios e suspensão',                    'Diagnóstico de freios',       30),
  ('Freios e suspensão',                    'Troca de amortecedores',      40),
  ('Freios e suspensão',                    'Troca de fluido de freio',    50),
  ('Motor e transmissão',                   'Diagnóstico de motor',        10),
  ('Motor e transmissão',                   'Troca de embreagem',          20),
  ('Motor e transmissão',                   'Troca de óleo de câmbio',     30),
  ('Elétrica automotiva',                   'Troca de bateria',            10),
  ('Elétrica automotiva',                   'Diagnóstico elétrico',        20),
  ('Elétrica automotiva',                   'Troca de alternador',         30),
  ('Elétrica automotiva',                   'Iluminação',                  40),
  ('Ar-condicionado',                       'Higienização do ar-condicionado', 10),
  ('Ar-condicionado',                       'Carga de gás',                20),
  ('Ar-condicionado',                       'Troca de filtro de cabine',   30),
  ('Ar-condicionado',                       'Diagnóstico de ar-condicionado', 40),
  ('Funilaria e pintura',                   'Reparo de amassados',         10),
  ('Funilaria e pintura',                   'Martelinho de ouro',          20),
  ('Funilaria e pintura',                   'Pintura de para-choque',      30),
  ('Funilaria e pintura',                   'Pintura completa',            40),
  ('Pneus e alinhamento',                   'Troca de pneus',              10),
  ('Pneus e alinhamento',                   'Alinhamento',                 20),
  ('Pneus e alinhamento',                   'Balanceamento',               30),
  ('Pneus e alinhamento',                   'Conserto de furo',            40),
  ('Diagnóstico computadorizado',           'Escaneamento completo',       10),
  ('Diagnóstico computadorizado',           'Leitura de falhas',           20),
  ('Diagnóstico computadorizado',           'Reset de injeção',            30),
  ('Vidros e acessórios',                   'Troca de para-brisa',         10),
  ('Vidros e acessórios',                   'Reparo de trinca',            20),
  ('Vidros e acessórios',                   'Película automotiva',         30),
  ('Vidros e acessórios',                   'Instalação de acessórios',    40),
  ('Blindagem',                             'Blindagem completa',          10),
  ('Blindagem',                             'Manutenção de blindagem',     20),
  ('Blindagem',                             'Troca de vidros blindados',   30),
  ('Lavagem e estética',                    'Lavagem completa',            10),
  ('Lavagem e estética',                    'Limpeza com vapor',           20),
  ('Lavagem e estética',                    'Polimento',                   30),
  ('Lavagem e estética',                    'Cristalização',               40),
  ('Chaveiro automotivo',                   'Cópia de chave',              10),
  ('Chaveiro automotivo',                   'Chave codificada',            20),
  ('Chaveiro automotivo',                   'Abertura de veículo',         30)
) as s(category_name, name, sort_order)
  on s.category_name = c.name
on conflict (category_id, name) do nothing;


-- ─── 3. P0: Solicitudes dirigidas (selected_business_ids) ────
-- Regla: array vacío = broadcast a talleres compatibles;
--        array con IDs = solo los talleres listados ven/responden.

-- 3.1 Policy SELECT del taller sobre service_requests
drop policy if exists "Taller aprobado ve solicitudes abiertas compatibles"
  on public.service_requests;

create policy "Taller aprobado ve solicitudes abiertas compatibles"
  on public.service_requests for select
  using (
    status = 'open'
    and exists (
      select 1 from public.workshops w
      where w.owner_id = auth.uid()
        and w.visible = true
        and w.open = true
        and w.approval_status = 'approved'
        and (
          (service_requests.target_business_type = 'workshop'    and w.business_type in ('workshop','both'))
          or (service_requests.target_business_type = 'parts_store' and w.business_type in ('parts_store','both'))
          or (service_requests.target_business_type = 'both'        and w.business_type in ('workshop','parts_store','both'))
        )
        and (
          coalesce(service_requests.selected_business_ids, '{}') = '{}'
          or w.id = any(service_requests.selected_business_ids)
        )
    )
  );

-- 3.2 request_open_for_workshop: protege el INSERT de proposals
create or replace function public.request_open_for_workshop(p_request_id uuid, p_workshop_id uuid)
returns boolean
language sql
stable security definer
set search_path to 'public'
as $function$
  select exists (
    select 1 from public.service_requests r
    join public.workshops w on w.id = p_workshop_id
    where r.id = p_request_id
      and r.status = 'open'
      and (
        (r.target_business_type = 'workshop'    and w.business_type in ('workshop','both'))
        or (r.target_business_type = 'parts_store' and w.business_type in ('parts_store','both'))
        or (r.target_business_type = 'both'        and w.business_type in ('workshop','parts_store','both'))
      )
      and (
        coalesce(r.selected_business_ids, '{}') = '{}'
        or w.id = any(r.selected_business_ids)
      )
  );
$function$;

-- 3.3 can_view_request_photos: fotos solo para talleres habilitados
create or replace function public.can_view_request_photos(p_request_id uuid)
returns boolean
language sql
stable security definer
set search_path to 'public'
as $function$
  select exists (
    select 1
    from public.service_requests r
    where r.id = p_request_id
      and (
        r.user_id = auth.uid()
        or public.is_admin()
        or exists (
          select 1
          from public.workshops w
          where w.owner_id = auth.uid()
            and (
              (
                r.status = 'open'
                and w.visible = true
                and w.open = true
                and w.approval_status = 'approved'
                and (
                  (r.target_business_type = 'workshop'    and w.business_type in ('workshop','both'))
                  or (r.target_business_type = 'parts_store' and w.business_type in ('parts_store','both'))
                  or (r.target_business_type = 'both'        and w.business_type in ('workshop','parts_store','both'))
                )
                and (
                  coalesce(r.selected_business_ids, '{}') = '{}'
                  or w.id = any(r.selected_business_ids)
                )
              )
              or exists (
                select 1 from public.proposals p
                where p.request_id = r.id and p.workshop_id = w.id
              )
            )
        )
      )
  );
$function$;

-- 3.4 workshop_can_view_request_owner: datos del cliente solo
--     para talleres habilitados
create or replace function public.workshop_can_view_request_owner(p_user_id uuid)
returns boolean
language sql
stable security definer
set search_path to 'public'
as $function$
  select exists (
    select 1
    from public.service_requests r
    join public.workshops w on w.owner_id = auth.uid()
    where r.user_id = p_user_id
      and (
        (
          r.status = 'open'
          and w.visible = true
          and w.open = true
          and w.approval_status = 'approved'
          and (
            (r.target_business_type = 'workshop'    and w.business_type in ('workshop','both'))
            or (r.target_business_type = 'parts_store' and w.business_type in ('parts_store','both'))
            or (r.target_business_type = 'both'        and w.business_type in ('workshop','parts_store','both'))
          )
          and (
            coalesce(r.selected_business_ids, '{}') = '{}'
            or w.id = any(r.selected_business_ids)
          )
        )
        or exists (
          select 1 from public.proposals p
          where p.request_id = r.id and p.workshop_id = w.id
        )
      )
  );
$function$;


-- ─── 4. Vistas públicas ──────────────────────────────────────
-- Se recrean con DROP + CREATE porque se agregan columnas.
-- Corren con privilegios del owner (postgres), sin security_invoker,
-- igual que hasta ahora. Solo datos públicos: nada de CNPJ,
-- razón social, responsable ni teléfonos internos.

-- 4.1 public_workshops_search
--     Prefijo de columnas idéntico al banco real; se agregan al
--     final: photo_url, schedule, home_service, service_items.
drop view if exists public.public_workshops_search;

create view public.public_workshops_search as
select
  w.id,
  w.name,
  w.business_type,
  w.city,
  w.address,
  w.neighborhood,
  w.category,
  w.services       as categories,
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
  and (w.subscription_status is null or w.subscription_status in ('trial','active'));

-- 4.2 public_parts_stores_search — se versiona el estado real
--     (tenía latitude/longitude sin versionar) sin cambios extra.
drop view if exists public.public_parts_stores_search;

create view public.public_parts_stores_search as
select
  w.id,
  w.name,
  w.business_type,
  w.city,
  w.address,
  w.neighborhood,
  w.category,
  w.services       as categories,
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
  and (w.subscription_status is null or w.subscription_status in ('trial','active'));

-- 4.3 Re-otorgar grants (el DROP los elimina)
grant select on public.public_workshops_search    to anon, authenticated;
grant select on public.public_parts_stores_search to anon, authenticated;


-- ─── 5. Storage: bucket workshop-logos ───────────────────────
-- Mismo patrón que los buckets existentes: lectura pública,
-- escritura solo en carpeta propia (auth.uid()).

insert into storage.buckets (id, name, public)
values ('workshop-logos', 'workshop-logos', true)
on conflict (id) do nothing;

do $$ begin
  create policy "Publico lee logos de talleres"
    on storage.objects for select
    using (bucket_id = 'workshop-logos');
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Taller sube su logo"
    on storage.objects for insert
    with check (
      bucket_id = 'workshop-logos'
      and auth.role() = 'authenticated'
      and (storage.foldername(name))[1] = auth.uid()::text
    );
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Taller actualiza su logo"
    on storage.objects for update
    using (
      bucket_id = 'workshop-logos'
      and (storage.foldername(name))[1] = auth.uid()::text
    )
    with check (
      bucket_id = 'workshop-logos'
      and (storage.foldername(name))[1] = auth.uid()::text
    );
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Taller borra su logo"
    on storage.objects for delete
    using (
      bucket_id = 'workshop-logos'
      and (storage.foldername(name))[1] = auth.uid()::text
    );
exception when duplicate_object then null;
end $$;


-- ============================================================
-- DIAGNÓSTICO — correr después de aplicar la migration
-- ============================================================

-- 1. La vista debe incluir photo_url, schedule, home_service,
--    service_items:
-- select * from public.public_workshops_search limit 2;

-- 2. Catálogo sembrado:
-- select c.name, count(s.id) as subcategorias
-- from public.service_categories c
-- left join public.service_subcategories s on s.category_id = c.id
-- group by c.name order by min(c.sort_order);

-- 3. Dirigidas — logueado como taller NO listado en una solicitud
--    dirigida, esto NO debe devolver esa solicitud:
-- select id, title, selected_business_ids from public.service_requests
-- where status = 'open';

-- 4. Bucket creado:
-- select id, public from storage.buckets where id = 'workshop-logos';

-- ─── FIN DE MIGRATION ─────────────────────────────────────────
