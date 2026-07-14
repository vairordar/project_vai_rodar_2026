-- ============================================================
-- Vai Rodar — Expiración de solicitudes (3 días) y corte por
-- fecha de alta del taller
-- Migration: 20260713_solicitudes_expiracion_y_corte_por_alta.sql
-- IDEMPOTENTE — seguro de re-ejecutar
-- Requiere: 20260713_mvp_v2_backend_contracts.sql aplicada antes
--
-- Reglas nuevas:
--   A. Las solicitudes expiran a los 3 días de creadas. Un taller
--      no ve ni puede responder solicitudes expiradas. El motorista
--      sigue viendo las suyas (para su historial), y el taller que
--      YA envió propuesta conserva acceso (policy "con propuesta
--      propia", sin cambios).
--   B. Un taller solo ve solicitudes creadas DESPUÉS de su alta
--      (workshops.created_at). Las anteriores a su registro nunca
--      le aparecen.
--
-- Ambas reglas se aplican en los mismos 5 puntos que gobiernan la
-- visibilidad del taller:
--   1. Policy SELECT de service_requests
--   2. request_open_for_workshop  (protege INSERT de proposals)
--   3. can_view_request_photos    (fotos de la solicitud)
--   4. workshop_can_view_request_owner (datos del cliente)
--   5. Policy INSERT de proposals
-- ============================================================


-- ─── 1. Default de expiración: 3 días ────────────────────────

alter table public.service_requests
  alter column expires_at set default (now() + interval '3 days');

-- Nota: las solicitudes ya existentes conservan su expires_at
-- original (7 días desde su creación). Al validar expires_at en
-- las policies, igualmente dejarán de mostrarse al vencer.


-- ─── 2. Policy SELECT del taller ──────────────────────────────

drop policy if exists "Taller aprobado ve solicitudes abiertas compatibles"
  on public.service_requests;

create policy "Taller aprobado ve solicitudes abiertas compatibles"
  on public.service_requests for select
  using (
    status = 'open'
    and (service_requests.expires_at is null or service_requests.expires_at > now())
    and exists (
      select 1 from public.workshops w
      where w.owner_id = auth.uid()
        and w.visible = true
        and w.open = true
        and w.approval_status = 'approved'
        and service_requests.created_at >= w.created_at
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


-- ─── 3. request_open_for_workshop ─────────────────────────────

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
      and (r.expires_at is null or r.expires_at > now())
      and r.created_at >= w.created_at
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


-- ─── 4. can_view_request_photos ───────────────────────────────

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
                and (r.expires_at is null or r.expires_at > now())
                and r.created_at >= w.created_at
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


-- ─── 5. workshop_can_view_request_owner ───────────────────────

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
          and (r.expires_at is null or r.expires_at > now())
          and r.created_at >= w.created_at
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


-- ─── 6. Policy INSERT de proposals ────────────────────────────
-- La policy anterior validaba status='open' directamente y no
-- consultaba request_open_for_workshop(), por lo que no aplicaba
-- expires_at, created_at del taller ni selected_business_ids.

drop policy if exists "Taller aprobado envia propuesta"
  on public.proposals;

create policy "Taller aprobado envia propuesta"
  on public.proposals for insert
  with check (
    exists (
      select 1 from public.workshops w
      where w.id = workshop_id
        and w.owner_id = auth.uid()
        and w.visible = true
        and w.open = true
        and w.approval_status = 'approved'
    )
    and public.request_open_for_workshop(request_id, workshop_id)
  );


-- ─── 7. Índice de apoyo ───────────────────────────────────────

create index if not exists idx_service_requests_open_expira
  on public.service_requests (status, expires_at, created_at);


-- ============================================================
-- DIAGNÓSTICO — correr después de aplicar la migration
-- ============================================================

-- 1. Default nuevo (debe decir 3 days):
-- select column_default from information_schema.columns
-- where table_name = 'service_requests' and column_name = 'expires_at';

-- 2. Crear una solicitud de prueba y confirmar expires_at ≈ +3 días.

-- 3. Logueado como taller: una solicitud con created_at anterior al
--    created_at del taller NO debe aparecer en el panel.

-- 4. Una solicitud con expires_at en el pasado NO debe aparecer en
--    el panel de ningún taller, pero sí en el historial del motorista
--    y en el panel del taller que ya envió propuesta.

-- ─── FIN DE MIGRATION ─────────────────────────────────────────
