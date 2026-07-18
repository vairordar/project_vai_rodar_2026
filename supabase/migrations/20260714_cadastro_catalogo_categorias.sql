-- ============================================================
-- Vai Rodar — Cadastro de oficinas por catálogo administrado
-- Migration: 20260714_cadastro_catalogo_categorias.sql
-- IDEMPOTENTE — seguro de re-ejecutar
-- Requiere: 20260714_admin_bloqueos_y_moderacion.sql aplicada
--           antes (crea workshop_categories y su backfill).
--
-- Contenido:
--   1. Contrato de lectura de service_categories: slug,
--      description, icon (+ backfill de slug)
--   2. Índice por category_id en workshop_categories
--   3. RLS estricta: el dueño solo puede asociar categorías
--      existentes Y activas
--   4. public_workshops_search: categories sale de
--      workshop_categories (fallback a workshops.services para
--      talleres antiguos sin backfill completo)
--   5. Reporte de backfill: nombres antiguos sin match
-- ============================================================


-- ─── 1. Contrato de service_categories ───────────────────────

alter table public.service_categories
  add column if not exists slug        text,
  add column if not exists description text,
  add column if not exists icon        text;

-- Backfill de slug desde el nombre (minúsculas, sin acentos
-- comunes de pt-BR, separador '-'). Solo donde falte.
update public.service_categories
set slug = trim(both '-' from regexp_replace(
  translate(
    lower(name),
    'áàâãäéèêëíìîïóòôõöúùûüçñ/',
    'aaaaaeeeeiiiiooooouuuucn-'
  ),
  '[^a-z0-9]+', '-', 'g'
))
where slug is null or slug = '';

-- Unicidad del slug (parcial: permite null en filas futuras
-- hasta que se les genere slug)
create unique index if not exists idx_service_categories_slug
  on public.service_categories (slug)
  where slug is not null;


-- ─── 2. Índice de la tabla puente ────────────────────────────

create index if not exists idx_workshop_categories_category
  on public.workshop_categories (category_id);


-- ─── 3. RLS estricta en workshop_categories ──────────────────
-- Se reemplaza la policy ALL del dueño por policies granulares:
-- leer/borrar lo propio; insertar solo categorías activas.
-- (El alta inicial desde register-workshop.js usa service role
-- y no pasa por RLS; esto cubre la gestión posterior del taller.)

drop policy if exists "Dueno gestiona categorias de su comercio"
  on public.workshop_categories;

do $$ begin
  create policy "Dueno lee categorias de su comercio"
    on public.workshop_categories for select
    using (exists (
      select 1 from public.workshops w
      where w.id = workshop_categories.workshop_id and w.owner_id = auth.uid()
    ));
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Dueno quita categorias de su comercio"
    on public.workshop_categories for delete
    using (exists (
      select 1 from public.workshops w
      where w.id = workshop_categories.workshop_id and w.owner_id = auth.uid()
    ));
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Dueno agrega categorias activas a su comercio"
    on public.workshop_categories for insert
    with check (
      exists (
        select 1 from public.workshops w
        where w.id = workshop_categories.workshop_id and w.owner_id = auth.uid()
      )
      and exists (
        select 1 from public.service_categories c
        where c.id = workshop_categories.category_id and c.active = true
      )
    );
exception when duplicate_object then null;
end $$;

-- "Publico lee categorias de comercios" (select using true) y
-- "Admin gestiona categorias de comercios" quedan como están.


-- ─── 4. Vista pública: categories desde la tabla puente ──────
-- Mismo listado de columnas y orden que la versión vigente
-- (create or replace válido). Solo cambia la expresión de
-- `categories`: primero workshop_categories (solo categorías
-- activas), y si el taller aún no tiene relaciones, cae a
-- workshops.services (compatibilidad con talleres antiguos).

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
  and (w.subscription_status is null or w.subscription_status in ('trial','active'));

grant select on public.public_workshops_search to anon, authenticated;


-- ============================================================
-- DIAGNÓSTICO — correr después de aplicar la migration
-- ============================================================

-- 1. REPORTE DE BACKFILL: nombres antiguos en workshops.services
--    que NO matchearon con ninguna categoría del catálogo.
--    Si devuelve filas, decidir a mano: crear la categoría en el
--    admin o corregir el taller. NUNCA se crean automáticamente.
-- select distinct w.id as workshop_id, w.name as workshop, s.nombre_viejo
-- from public.workshops w
-- cross join lateral unnest(w.services) as s(nombre_viejo)
-- where not exists (
--   select 1 from public.service_categories c
--   where lower(trim(c.name)) = lower(trim(s.nombre_viejo))
-- )
-- order by w.name;

-- 2. Relaciones creadas por taller:
-- select w.name, array_agg(c.name order by c.sort_order) as categorias
-- from public.workshops w
-- join public.workshop_categories wc on wc.workshop_id = w.id
-- join public.service_categories c on c.id = wc.category_id
-- group by w.name;

-- 3. Contrato de lectura del cadastro (lo que verá el frontend):
-- select id, name, slug, description, icon, sort_order, active
-- from public.service_categories
-- where active = true
-- order by sort_order asc, name asc;

-- ─── FIN DE MIGRATION ─────────────────────────────────────────
