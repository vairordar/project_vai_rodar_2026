-- ============================================================
-- Vai Rodar — Admin Backoffice Connection
-- Migration: 20260615_admin_backoffice_connection.sql
-- Depende de: 20260615_admin_backoffice_data_model.sql
-- IDEMPOTENTE — seguro de re-ejecutar
-- ============================================================

-- ─── 1. Extender enum user_role con valores admin/motorista/workshop ─
-- Si user_role es un enum de Postgres, agregar valores si no existen.
-- Si no es enum sino text, estos bloques fallan silenciosamente.
do $$ begin
  alter type public.user_role add value if not exists 'admin';
exception when others then null;
end $$;

do $$ begin
  alter type public.user_role add value if not exists 'motorista';
exception when others then null;
end $$;

do $$ begin
  alter type public.user_role add value if not exists 'workshop';
exception when others then null;
end $$;

-- Si role es text con check constraint, agregar 'admin' si falta:
do $$ begin
  alter table public.profiles
    drop constraint if exists profiles_role_check;
  alter table public.profiles
    add constraint profiles_role_check
    check (role::text in ('motorista','workshop','admin'));
exception when others then null;
end $$;

-- ─── 2. RLS admin sobre public.workshops ─────────────────────
-- Necesario para que las views con security_invoker funcionen para admins.

do $$ begin
  create policy "Admin seleciona todos os talleres"
    on public.workshops for select
    using (public.is_admin());
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Admin atualiza talleres"
    on public.workshops for update
    using (public.is_admin())
    with check (public.is_admin());
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Admin insere talleres"
    on public.workshops for insert
    with check (public.is_admin());
exception when duplicate_object then null;
end $$;

-- ─── 3. RLS admin sobre public.profiles ──────────────────────
do $$ begin
  create policy "Admin seleciona todos os perfis"
    on public.profiles for select
    using (public.is_admin());
exception when duplicate_object then null;
end $$;

-- ─── 4. RLS admin sobre public.service_requests ──────────────
do $$ begin
  create policy "Admin seleciona todas as solicitacoes"
    on public.service_requests for select
    using (public.is_admin());
exception when duplicate_object then null;
end $$;

-- ─── 5. RLS admin sobre public.reservations ──────────────────
do $$ begin
  create policy "Admin seleciona todas as reservas"
    on public.reservations for select
    using (public.is_admin());
exception when duplicate_object then null;
end $$;

-- ─── 6. RLS admin sobre public.conversations ─────────────────
do $$ begin
  create policy "Admin seleciona todas as conversas"
    on public.conversations for select
    using (public.is_admin());
exception when duplicate_object then null;
end $$;

-- ─── 7. RLS admin sobre public.messages ──────────────────────
do $$ begin
  create policy "Admin seleciona todas as mensagens"
    on public.messages for select
    using (public.is_admin());
exception when duplicate_object then null;
end $$;

-- ─── 8. Corregir analytics_events INSERT policy ──────────────
-- La policy anterior permite insert sin autenticación.
-- Reemplazar por una que exija usuario autenticado.
drop policy if exists "Apps insertan eventos" on public.analytics_events;

do $$ begin
  create policy "Apps insertan eventos autenticados"
    on public.analytics_events for insert
    with check (auth.role() = 'authenticated');
exception when duplicate_object then null;
end $$;

-- ─── 9. Views con security_invoker = on ──────────────────────
-- Hace que las views apliquen RLS del usuario llamante.
-- Requiere PostgreSQL 15+ (Supabase lo soporta).
alter view public.admin_workshops_overview    set (security_invoker = on);
alter view public.admin_dashboard_summary     set (security_invoker = on);
alter view public.admin_top_locations_30d     set (security_invoker = on);
alter view public.admin_top_services_30d      set (security_invoker = on);
alter view public.admin_chat_usage_30d        set (security_invoker = on);

-- ─── 10. Función: create_workshop_subscription_payment ───────
-- Crea subscription + payment en una sola operación.
-- Solo ejecutable por admin.
-- El trigger fn_subscription_on_paid calcula starts_at, expires_at y status.

create or replace function public.create_workshop_subscription_payment(
  p_workshop_id    uuid,
  p_amount         numeric,
  p_method         text,
  p_reference      text    default null,
  p_invoice_url    text    default null,
  p_notes          text    default null,
  p_duration_days  integer default 365
)
returns uuid  -- retorna subscription id
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sub_id   uuid;
  v_paid_at  timestamptz := now();
  v_email    text;
begin
  if not public.is_admin() then
    raise exception 'Acesso negado: apenas admin pode criar assinaturas.';
  end if;

  select email into v_email from auth.users where id = auth.uid();

  -- Inserir subscription — trigger calcula starts_at, expires_at, status = active
  insert into public.workshop_subscriptions (
    workshop_id,
    plan_name,
    paid_at,
    duration_days,
    amount_paid,
    payment_method,
    payment_reference,
    invoice_url,
    notes,
    created_by_admin
  ) values (
    p_workshop_id,
    'Anual oficina',
    v_paid_at,
    p_duration_days,
    p_amount,
    p_method,
    p_reference,
    p_invoice_url,
    p_notes,
    auth.uid()
  )
  returning id into v_sub_id;

  -- Inserir payment linkado à subscription
  insert into public.workshop_payments (
    workshop_id,
    subscription_id,
    paid_at,
    status,
    method,
    amount,
    reference,
    invoice_url,
    notes,
    created_by_admin
  ) values (
    p_workshop_id,
    v_sub_id,
    v_paid_at,
    'paid',
    p_method,
    p_amount,
    p_reference,
    p_invoice_url,
    p_notes,
    auth.uid()
  );

  -- Audit log
  insert into public.admin_audit_logs (
    admin_id,
    admin_email,
    action,
    entity,
    entity_id,
    detail,
    metadata
  ) values (
    auth.uid(),
    v_email,
    'subscription_created',
    'workshop_subscriptions',
    v_sub_id,
    format('Assinatura criada para oficina %s — R$ %s via %s. Inicio: amanha. Duracao: %s dias.',
           p_workshop_id, p_amount, p_method, p_duration_days),
    jsonb_build_object(
      'workshop_id', p_workshop_id,
      'amount', p_amount,
      'method', p_method,
      'duration_days', p_duration_days
    )
  );

  return v_sub_id;
end;
$$;

grant execute on function public.create_workshop_subscription_payment(uuid,numeric,text,text,text,text,integer)
  to authenticated;

-- ─── 11. Función: admin_set_workshop_visibility ───────────────
-- Aprobar / bloquear / activar / desactivar un taller + audit log.

create or replace function public.admin_set_workshop_visibility(
  p_workshop_id      uuid,
  p_approval_status  text,
  p_visible          boolean,
  p_open             boolean default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text;
begin
  if not public.is_admin() then
    raise exception 'Acesso negado: apenas admin pode alterar visibilidade do taller.';
  end if;

  -- Validar approval_status
  if p_approval_status not in ('pending','approved','rejected','blocked') then
    raise exception 'approval_status invalido: %', p_approval_status;
  end if;

  select email into v_email from auth.users where id = auth.uid();

  update public.workshops set
    approval_status = p_approval_status,
    visible         = p_visible,
    approved_at     = case when p_approval_status = 'approved' then now()       else approved_at end,
    approved_by     = case when p_approval_status = 'approved' then auth.uid()  else approved_by end,
    open            = coalesce(p_open, open)
  where id = p_workshop_id;

  -- Audit log
  insert into public.admin_audit_logs (
    admin_id,
    admin_email,
    action,
    entity,
    entity_id,
    detail,
    metadata
  ) values (
    auth.uid(),
    v_email,
    case p_approval_status
      when 'approved' then 'workshop_approved'
      when 'rejected' then 'workshop_rejected'
      when 'blocked'  then 'workshop_blocked'
      else 'workshop_updated'
    end,
    'workshops',
    p_workshop_id,
    format('approval_status=%s visible=%s open=%s', p_approval_status, p_visible, coalesce(p_open::text,'unchanged')),
    jsonb_build_object(
      'approval_status', p_approval_status,
      'visible', p_visible,
      'open', p_open
    )
  );
end;
$$;

grant execute on function public.admin_set_workshop_visibility(uuid,text,boolean,boolean)
  to authenticated;

-- ─── 12. Recriar is_admin() con cast seguro ───────────────────
-- Garantir que funciona con enum y con text.
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

-- ─── 13. Confirmar event_type constraint cobre todos los eventos ─
-- Los 13 event_types del spec ya están en la constraint de la migration anterior.
-- Si por algún motivo la constraint no existe, recrearla aquí:
do $$ begin
  alter table public.analytics_events
    drop constraint if exists analytics_events_type_check;
  alter table public.analytics_events
    add constraint analytics_events_type_check
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
    ));
exception when others then null;
end $$;

-- ─── FIN DE MIGRATION ─────────────────────────────────────────
--
-- QUERY PARA TORNAR SEU USUÁRIO ADMIN:
--
--   update public.profiles
--   set role = 'admin'
--   where id = (select id from auth.users where email = 'SEU_EMAIL_AQUI');
--
-- Executar no SQL Editor do Supabase com Role: postgres
-- Substituir SEU_EMAIL_AQUI pelo email da sua conta Supabase.
--
-- REGRA OPERACIONAL:
-- Um taller aparece no user-app SOMENTE se:
--   approval_status = 'approved'
--   AND visible = true
--   AND open = true
--   AND subscription_status in ('trial', 'active')
--
-- REGRA DE ASSINATURA 365 DIAS:
--   paid_at  = data do pagamento
--   starts_at = date_trunc('day', paid_at) + 1 dia
--   expires_at = starts_at + 365 dias
--   status   = 'active'
-- (Calculado automaticamente pelo trigger trg_subscription_on_paid)
--
-- Exemplo: pago em 2026-06-15
--   starts_at  = 2026-06-16 00:00:00
--   expires_at = 2027-06-16 00:00:00
--
-- ─────────────────────────────────────────────────────────────
