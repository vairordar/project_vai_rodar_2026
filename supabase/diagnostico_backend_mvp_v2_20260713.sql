-- ============================================================
-- Vai Rodar — Diagnóstico de estado real del banco (SOLO LECTURA)
-- Fecha: 2026-07-13 · Previo a migraciones backend MVP V2
-- Correr en Supabase SQL Editor y pegar TODOS los resultados.
-- No modifica nada.
-- ============================================================

-- 1. Todas las tablas y vistas del schema public
select table_name, table_type
from information_schema.tables
where table_schema = 'public'
order by table_type, table_name;

-- 2. Columnas reales de workshops
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'workshops'
order by ordinal_position;

-- 3. Columnas reales de service_requests
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'service_requests'
order by ordinal_position;

-- 4. Definición actual de las vistas públicas
select viewname, pg_get_viewdef(('public.'||viewname)::regclass, true) as definicion
from pg_views
where schemaname = 'public'
  and viewname in ('public_workshops_search','public_parts_stores_search','public_active_offers');

-- 5. Policies RLS activas en las tablas clave
select tablename, policyname, cmd, roles, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename in ('workshops','service_requests','proposals','reservations',
                    'conversations','messages','notifications','workshop_offers')
order by tablename, cmd, policyname;

-- 6. RLS habilitado por tabla
select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
order by tablename;

-- 7. Grants de anon/authenticated sobre vistas y tablas clave
select grantee, table_name, privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and grantee in ('anon','authenticated')
  and table_name in ('workshops','public_workshops_search','public_parts_stores_search',
                     'public_active_offers','service_requests','proposals')
order by table_name, grantee, privilege_type;

-- 8. ¿Existen ya tablas de catálogo? (cualquier nombre parecido)
select table_name
from information_schema.tables
where table_schema = 'public'
  and (table_name ilike '%categor%' or table_name ilike '%service%' or table_name ilike '%catalog%')
order by table_name;

-- 9. Funciones relevantes (is_admin y RPCs existentes)
select routine_name, routine_type, security_type
from information_schema.routines
where routine_schema = 'public'
order by routine_name;

-- 10. Buckets de Storage existentes
select id, name, public
from storage.buckets
order by name;

-- 11. Policies de Storage
select policyname, cmd, qual, with_check
from pg_policies
where schemaname = 'storage' and tablename = 'objects'
order by policyname;

-- 12. Constraints de service_requests (checks)
select conname, pg_get_constraintdef(oid) as definicion
from pg_constraint
where conrelid = 'public.service_requests'::regclass
order by conname;

-- 13. Muestra de datos (conteos, sin datos personales)
select
  (select count(*) from public.workshops)                                        as workshops_total,
  (select count(*) from public.workshops where approval_status = 'approved')     as workshops_aprobados,
  (select count(*) from public.workshops where latitude is not null)             as workshops_con_coordenadas,
  (select count(*) from public.workshops where photo_url is not null)            as workshops_con_logo,
  (select count(*) from public.workshops where schedule <> '{}'::jsonb)          as workshops_con_horario,
  (select count(*) from public.service_requests)                                 as solicitudes_total,
  (select count(*) from public.service_requests where selected_business_ids <> '{}') as solicitudes_dirigidas;
