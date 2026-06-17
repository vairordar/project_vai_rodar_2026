-- ============================================================
-- Vai Rodar — Endurecimiento de RLS (profiles, service_requests,
-- proposals, workshops)
-- Migration: 20260617_security_rls_hardening.sql
-- IDEMPOTENTE — seguro de re-ejecutar
-- ============================================================

-- ─── 1. public.profiles ────────────────────────────────────────
-- Antes: "Perfil visível para todos autenticados" exponía nombre,
-- email y teléfono de TODOS los usuarios a cualquier autenticado.

drop policy if exists "Perfil visível para todos autenticados" on public.profiles;
drop policy if exists "Usuário atualiza próprio perfil"        on public.profiles;
drop policy if exists "Admin seleciona todos os perfis"        on public.profiles; -- queda subsumida por la policy ALL de abajo

do $$ begin
  create policy "Usuario lee su propio perfil"
    on public.profiles for select
    using (auth.uid() = id);
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Usuario actualiza su propio perfil"
    on public.profiles for update
    using (auth.uid() = id)
    with check (auth.uid() = id);
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Admin gestiona perfiles"
    on public.profiles for all
    using (public.is_admin())
    with check (public.is_admin());
exception when duplicate_object then null;
end $$;

-- NOTA: si en algún momento se necesita un "perfil público mínimo"
-- (ej. nombre del taller mostrado en un chat), exponerlo a través de
-- una vista específica (ej. public_profile_minimal con solo id+name),
-- nunca reabriendo el SELECT general de profiles.

-- ─── 2. public.service_requests ─────────────────────────────────
-- Antes: "Oficinas veem solicitações abertas" using (status='open')
-- dejaba ver TODAS las solicitudes abiertas a cualquier autenticado,
-- sin validar que fuera un taller aprobado/visible ni que el tipo
-- de negocio fuera compatible.

drop policy if exists "Oficinas veem solicitações abertas" on public.service_requests;

-- Las policies "Motorista vê suas solicitações", "Motorista cria
-- solicitações" y "Motorista atualiza suas solicitações" ya estaban
-- correctamente scoped a auth.uid() = user_id y se mantienen.

do $$ begin
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
      )
    );
exception when duplicate_object then null;
end $$;

-- Cubre el caso "no bloquear solicitudes ya recibidas": si el taller
-- ya envió una proposal para esa solicitud, sigue viéndola aunque
-- después se ponga open=false, visible=false o pierda aprobación.
do $$ begin
  create policy "Taller ve solicitudes con propuesta propia"
    on public.service_requests for select
    using (
      exists (
        select 1
        from public.proposals p
        join public.workshops w on w.id = p.workshop_id
        where p.request_id = service_requests.id
          and w.owner_id = auth.uid()
      )
    );
exception when duplicate_object then null;
end $$;

-- Admin ya tenía "Admin seleciona todas as solicitacoes" (select).
-- Se agrega ALL para que también pueda actualizar/insertar/borrar
-- desde el backoffice si fuera necesario.
do $$ begin
  create policy "Admin gestiona solicitudes"
    on public.service_requests for all
    using (public.is_admin())
    with check (public.is_admin());
exception when duplicate_object then null;
end $$;

-- ─── 3. public.proposals ────────────────────────────────────────
-- Antes: insert/update abiertos a cualquier auth.role()='authenticated',
-- sin validar que el remitente fuera dueño del taller correspondiente.

drop policy if exists "Oficina envia proposta"            on public.proposals;
drop policy if exists "Oficina/motorista atualiza proposta" on public.proposals;

-- "Motorista vê propostas das suas solicitações" y "Oficina vê suas
-- propostas" (select) ya estaban correctamente scoped y se mantienen.

do $$ begin
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
      and exists (
        select 1 from public.service_requests r
        join public.workshops w on w.id = workshop_id
        where r.id = request_id
          and r.status = 'open'
          and (
            (r.target_business_type = 'workshop'    and w.business_type in ('workshop','both'))
            or (r.target_business_type = 'parts_store' and w.business_type in ('parts_store','both'))
            or (r.target_business_type = 'both'        and w.business_type in ('workshop','parts_store','both'))
          )
      )
    );
exception when duplicate_object then null;
end $$;

-- NOTA: esta policy es solo para INSERT (primera propuesta). La
-- continuidad para propuestas YA existentes está cubierta por
-- "Taller actualiza su propuesta" (update, sin volver a exigir que
-- la solicitud siga open) y por "Taller ve solicitudes con propuesta
-- propia" en service_requests, que no depende de status='open'.

do $$ begin
  create policy "Taller actualiza su propuesta"
    on public.proposals for update
    using (
      exists (select 1 from public.workshops w where w.id = workshop_id and w.owner_id = auth.uid())
    )
    with check (
      exists (select 1 from public.workshops w where w.id = workshop_id and w.owner_id = auth.uid())
    );
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Motorista actualiza propuesta recibida"
    on public.proposals for update
    using (
      exists (select 1 from public.service_requests r where r.id = request_id and r.user_id = auth.uid())
    )
    with check (
      exists (select 1 from public.service_requests r where r.id = request_id and r.user_id = auth.uid())
    );
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Admin gestiona propuestas"
    on public.proposals for all
    using (public.is_admin())
    with check (public.is_admin());
exception when duplicate_object then null;
end $$;

-- RLS no puede restringir columnas individuales dentro de un UPDATE.
-- La policy "Motorista actualiza propuesta recibida" de arriba permite
-- update de la fila completa. Para que el motorista NO pueda cambiar
-- price/message/estimated_time/workshop_id/request_id (solo debería
-- poder cambiar status al aceptar/rechazar), se agrega este trigger:

create or replace function public.enforce_proposal_update_columns()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_is_workshop_owner boolean;
begin
  if public.is_admin() then
    return new;
  end if;

  select exists(
    select 1 from public.workshops w
    where w.id = new.workshop_id and w.owner_id = auth.uid()
  ) into v_is_workshop_owner;

  -- Si quien actualiza NO es el dueño del taller (es decir, es el
  -- motorista aceptando/rechazando), bloquear cambios a campos que
  -- solo el taller debería poder definir.
  if not v_is_workshop_owner then
    if new.price          is distinct from old.price
       or new.message        is distinct from old.message
       or new.estimated_time is distinct from old.estimated_time
       or new.workshop_id    is distinct from old.workshop_id
       or new.request_id     is distinct from old.request_id then
      raise exception 'No tienes permiso para modificar estos campos de la propuesta';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_enforce_proposal_update_columns on public.proposals;

create trigger trg_enforce_proposal_update_columns
  before update on public.proposals
  for each row execute function public.enforce_proposal_update_columns();

-- ─── 4. public.workshops ────────────────────────────────────────
-- Antes: "Oficinas visíveis para todos" using (true) expone TODOS
-- los talleres (incluso no aprobados/ocultos) y TODAS sus columnas
-- (legal_name, cnpj, responsible_name, contact_phone, etc.) a
-- cualquiera, incluso anónimos.

drop policy if exists "Oficinas visíveis para todos" on public.workshops;

-- AJUSTE FINAL: NO se crea ninguna policy pública de SELECT sobre
-- public.workshops. RLS filtra filas, no columnas — una policy
-- "using (open and visible and approved)" seguiría exponiendo CNPJ,
-- legal_name, responsible_name, contact_phone, etc. de cada fila
-- aprobada a cualquier autenticado. La única vía de lectura pública
-- es a través de las vistas (sección 4-bis), que seleccionan
-- explícitamente solo columnas no sensibles.

do $$ begin
  create policy "Dueno ve su propio workshop"
    on public.workshops for select
    using (auth.uid() = owner_id);
exception when duplicate_object then null;
end $$;

-- Antes: "Usuário autenticado cadastra oficina" permitía que
-- cualquier usuario autenticado insertara un workshop con
-- owner_id arbitrario (no necesariamente el suyo).
drop policy if exists "Usuário autenticado cadastra oficina" on public.workshops;

do $$ begin
  create policy "Usuario autenticado cadastra su workshop"
    on public.workshops for insert
    with check (
      auth.role() = 'authenticated'
      and owner_id = auth.uid()
    );
exception when duplicate_object then null;
end $$;

-- "Dono da oficina atualiza" (update por owner_id) ya existía y se
-- mantiene. "Admin seleciona/atualiza/insere talleres" (de 20260615_
-- admin_backoffice_connection.sql) ya cubre la gestión total del admin.

-- Resultado en public.workshops: solo el dueño (su propia fila,
-- todas las columnas) y el admin (todas las filas) pueden leer la
-- tabla directamente. anon y cualquier otro authenticated obtienen
-- 0 filas si consultan la tabla, sin importar approval_status.

-- ─── 4-bis. Endurecer vistas públicas de búsqueda ────────────────
-- Las vistas ya existían (business_types_parts_and_marketplace.sql)
-- pero su filtro era "approval_status is null or approval_status =
-- 'approved'", lo cual contradice la decisión de la sección 4 (un
-- approval_status NULL no debe tratarse como aprobado). Se corrige
-- aquí. Estas vistas corren con privilegios del owner (postgres) y
-- no tienen security_invoker, por lo que seguirán funcionando aunque
-- la tabla workshops ya no tenga policy pública de SELECT.

create or replace view public.public_workshops_search as
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
  w.parts_pickup_enabled
from public.workshops w
where w.open            = true
  and w.visible          = true
  and w.approval_status  = 'approved'
  and w.business_type in ('workshop','both')
  and (w.subscription_status is null or w.subscription_status in ('trial','active'));

create or replace view public.public_parts_stores_search as
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
  w.parts_whatsapp
from public.workshops w
where w.open            = true
  and w.visible          = true
  and w.approval_status  = 'approved'
  and w.business_type in ('parts_store','both')
  and (w.subscription_status is null or w.subscription_status in ('trial','active'));

create or replace view public.public_active_offers as
select
  wo.id          as offer_id,
  wo.workshop_id,
  w.name         as business_name,
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
where wo.status        = 'active'
  and wo.starts_at     <= now()
  and wo.ends_at        >= now()
  and w.open            = true
  and w.visible          = true
  and w.approval_status  = 'approved';

-- Ninguna de las 3 vistas selecciona cnpj, legal_name,
-- responsible_name ni contact_phone — solo datos de contacto
-- pensados para mostrarse públicamente (parts_whatsapp es el
-- WhatsApp comercial del comercio, no un teléfono interno).

-- Grants explícitos: anon y authenticated pueden leer las vistas,
-- pero NO la tabla public.workshops completa.
grant select on public.public_workshops_search    to anon, authenticated;
grant select on public.public_parts_stores_search  to anon, authenticated;
grant select on public.public_active_offers        to anon, authenticated;

-- Defensa en profundidad: revocar el SELECT de tabla completa que
-- Supabase otorga por defecto a anon/authenticated sobre todas las
-- tablas de public. Con esto, aunque en el futuro alguien borre por
-- error la policy de RLS, anon ya no tiene ni siquiera el permiso de
-- base para leer public.workshops.
revoke select on public.workshops from anon;

-- ============================================================
-- DIAGNÓSTICO — correr después de aplicar la migration
-- ============================================================

-- 1. Listar policies activas en las 4 tablas endurecidas
select schemaname, tablename, policyname, cmd, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename in ('profiles', 'service_requests', 'proposals', 'workshops')
order by tablename, cmd, policyname;

-- 2. Confirmar que RLS está habilitado en las 4 tablas
select schemaname, tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in ('profiles', 'service_requests', 'proposals', 'workshops');

-- 3. Confirmar que anon NO puede leer public.workshops directamente,
--    pero SÍ puede leer las 3 vistas públicas.
select grantee, table_name, privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in ('workshops', 'public_workshops_search', 'public_parts_stores_search', 'public_active_offers')
  and grantee in ('anon', 'authenticated')
order by table_name, grantee;

-- ─── FIN DE MIGRATION ─────────────────────────────────────────
