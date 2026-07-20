-- ============================================================
-- Vai Rodar — Flujo propuesta → aceptación → reserva
-- Migration: 20260720_flujo_propuesta_reserva.sql
-- IDEMPOTENTE — seguro de re-ejecutar
-- Requiere: 20260717_request_proposal_lifecycle_metrics.sql
--
-- Construye SOBRE la infraestructura del 17/07 (triggers de
-- aceptación atómica, request_lifecycle_events). No la duplica.
--
-- Contenido:
--   1. proposals: booking_mode, estimated_duration_text,
--      booking_instructions, validity_days, valid_until
--      (+ trigger de cálculo + backfill + guard de columnas)
--   2. Validez en la aceptación (extiende prepare_proposal_decision)
--   3. reservations: request_id, proposal_id, booking_mode,
--      estimated_duration_text, booking_instructions,
--      confirmed_at, cancel_reason; scheduled_at ahora nullable;
--      UNIQUE parcial por proposal_id (anti-duplicados)
--   4. Guard de updates de reservations (motorista limitado)
--   5. Helper notify_user + validate_reservation_slot
--   6. RPCs: accept_proposal, request_reservation_slot,
--      confirm_reservation, complete_reservation,
--      cancel_reservation
-- ============================================================


-- ─── 1. proposals: columnas de modalidad y validez ───────────

alter table public.proposals
  add column if not exists booking_mode            text,
  add column if not exists estimated_duration_text text,
  add column if not exists booking_instructions    text,
  add column if not exists validity_days           integer default 5,
  add column if not exists valid_until             timestamptz;

do $$ begin
  alter table public.proposals
    add constraint proposals_booking_mode_check
    check (booking_mode is null or booking_mode in ('scheduled','dropoff','walkin'));
exception when duplicate_object then null;
end $$;

do $$ begin
  alter table public.proposals
    add constraint proposals_validity_days_check
    check (validity_days is null or validity_days in (3,5,7,15));
exception when duplicate_object then null;
end $$;

-- Trigger: normaliza modalidad y calcula valid_until
create or replace function public.set_proposal_validity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.booking_mode is null then
    new.booking_mode := 'scheduled';
  end if;
  if new.validity_days is null then
    new.validity_days := 5;
  end if;
  new.valid_until := coalesce(new.created_at, now()) + make_interval(days => new.validity_days);
  return new;
end;
$$;

drop trigger if exists trg_set_proposal_validity on public.proposals;
create trigger trg_set_proposal_validity
  before insert or update of validity_days on public.proposals
  for each row execute function public.set_proposal_validity();

-- Backfill de propuestas antiguas (no toca estimated_time)
update public.proposals
set
  booking_mode  = coalesce(booking_mode, 'scheduled'),
  validity_days = coalesce(validity_days, 5),
  valid_until   = coalesce(valid_until, created_at + interval '5 days')
where booking_mode is null or validity_days is null or valid_until is null;

-- Guard existente ampliado: el motorista tampoco puede tocar las
-- columnas nuevas de la propuesta.
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

  if not v_is_workshop_owner then
    if new.price                   is distinct from old.price
       or new.message                 is distinct from old.message
       or new.estimated_time          is distinct from old.estimated_time
       or new.workshop_id             is distinct from old.workshop_id
       or new.request_id              is distinct from old.request_id
       or new.booking_mode            is distinct from old.booking_mode
       or new.estimated_duration_text is distinct from old.estimated_duration_text
       or new.booking_instructions    is distinct from old.booking_instructions
       or new.validity_days           is distinct from old.validity_days
       or new.valid_until             is distinct from old.valid_until
    then
      raise exception 'O motorista so pode aceitar ou recusar a proposta; nao pode alterar os dados definidos pela oficina';
    end if;
  end if;

  return new;
end;
$$;


-- ─── 2. Validez de la propuesta al aceptar ───────────────────
-- Redefinición completa de prepare_proposal_decision (17/07)
-- agregando UNA regla: no se acepta una propuesta vencida.

create or replace function public.prepare_proposal_decision()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  request_owner uuid;
  request_status_value text;
  request_expires_at timestamptz;
  current_winner uuid;
  actor_is_admin boolean := false;
  actor_is_service_role boolean := false;
  actor_is_workshop_owner boolean := false;
begin
  if tg_op = 'INSERT' then
    if new.status = 'accepted' then
      raise exception 'Uma proposta deve ser aceita pelo motorista depois de enviada';
    end if;

    if new.status in ('declined', 'expired') then
      new.responded_at := coalesce(new.responded_at, now());
      new.decision_reason := coalesce(
        new.decision_reason,
        case when new.status = 'declined' then 'workshop_declined' else 'expired' end
      );
    end if;
    return new;
  end if;

  if new.status is not distinct from old.status then
    return new;
  end if;

  select
    r.user_id,
    r.status::text,
    r.expires_at,
    r.accepted_proposal_id
  into
    request_owner,
    request_status_value,
    request_expires_at,
    current_winner
  from public.service_requests r
  where r.id = new.request_id
  for update;

  if request_owner is null then
    raise exception 'Solicitacao da proposta nao encontrada';
  end if;

  actor_is_service_role := coalesce(auth.role() = 'service_role', false);
  actor_is_admin := actor_is_service_role or public.is_admin();

  select exists (
    select 1
    from public.workshops w
    where w.id = new.workshop_id
      and w.owner_id = auth.uid()
  ) into actor_is_workshop_owner;

  if old.status = 'accepted' and new.status <> 'accepted' then
    raise exception 'A proposta aceita nao pode voltar para outro estado';
  end if;

  if new.status = 'accepted' then
    if not actor_is_admin and auth.uid() is distinct from request_owner then
      raise exception 'Somente o motorista da solicitacao pode aceitar a proposta';
    end if;

    if current_winner is not null and current_winner <> new.id then
      raise exception 'Esta solicitacao ja possui uma proposta aceita';
    end if;

    if request_status_value = 'expired'
       or (request_expires_at is not null and request_expires_at <= now()) then
      raise exception 'Nao e possivel aceitar proposta de uma solicitacao expirada';
    end if;

    if request_status_value = 'closed' and current_winner is null then
      raise exception 'Nao e possivel aceitar proposta de uma solicitacao encerrada';
    end if;

    -- REGLA NUEVA: propuesta vencida no se acepta
    if new.valid_until is not null and new.valid_until <= now() then
      raise exception 'Esta proposta venceu em % e nao pode mais ser aceita',
        to_char(new.valid_until, 'DD/MM/YYYY');
    end if;

    new.responded_at := coalesce(new.responded_at, now());
    new.decision_reason := coalesce(new.decision_reason, 'accepted_by_motorist');
  elsif new.status = 'declined' then
    if not actor_is_admin
       and auth.uid() is distinct from request_owner
       and not actor_is_workshop_owner then
      raise exception 'Sem permissao para recusar esta proposta';
    end if;

    new.responded_at := coalesce(new.responded_at, now());
    new.decision_reason := coalesce(
      new.decision_reason,
      case
        when actor_is_workshop_owner then 'withdrawn_by_workshop'
        else 'declined_by_motorist'
      end
    );
  elsif new.status = 'expired' then
    new.responded_at := coalesce(new.responded_at, now());
    new.decision_reason := coalesce(new.decision_reason, 'expired');
  elsif old.status <> 'pending' and new.status = 'pending' and not actor_is_admin then
    raise exception 'Uma proposta respondida nao pode voltar para pendente';
  end if;

  return new;
end;
$$;


-- ─── 3. reservations: vínculos y modalidad ───────────────────

alter table public.reservations
  add column if not exists request_id              uuid,
  add column if not exists proposal_id             uuid,
  add column if not exists booking_mode            text,
  add column if not exists estimated_duration_text text,
  add column if not exists booking_instructions    text,
  add column if not exists confirmed_at            timestamptz,
  add column if not exists cancel_reason           text;

alter table public.reservations alter column scheduled_at drop not null;

do $$ begin
  alter table public.reservations
    add constraint reservations_request_fkey
    foreign key (request_id) references public.service_requests(id) on delete set null;
exception when duplicate_object then null;
end $$;

do $$ begin
  alter table public.reservations
    add constraint reservations_proposal_fkey
    foreign key (proposal_id) references public.proposals(id) on delete set null;
exception when duplicate_object then null;
end $$;

do $$ begin
  alter table public.reservations
    add constraint reservations_booking_mode_check
    check (booking_mode is null or booking_mode in ('scheduled','dropoff','walkin'));
exception when duplicate_object then null;
end $$;

-- Aceptar dos veces jamás crea dos reservas
create unique index if not exists reservations_proposal_unique_idx
  on public.reservations (proposal_id)
  where proposal_id is not null;

create index if not exists reservations_request_idx
  on public.reservations (request_id)
  where request_id is not null;


-- ─── 4. Guard de updates de reservations ─────────────────────
-- La policy legacy "Partes atualizam reserva" permitía a CUALQUIER
-- autenticado actualizar CUALQUIER reserva. Se reemplaza por
-- policies por dueño + guard de columnas/estados.

drop policy if exists "Partes atualizam reserva" on public.reservations;

do $$ begin
  create policy "Motorista atualiza sua reserva"
    on public.reservations for update
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);
exception when duplicate_object then null;
end $$;

-- ("Taller atualiza reservas da oficina" ya existe y se conserva.)

create or replace function public.enforce_reservation_update_rules()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_is_workshop_owner boolean;
begin
  if auth.uid() is null or public.is_admin() then
    return new; -- service role / admin / RPCs security definer internas
  end if;

  select exists(
    select 1 from public.workshops w
    where w.id = new.workshop_id and w.owner_id = auth.uid()
  ) into v_is_workshop_owner;

  -- Nadie mueve los vínculos ni las partes
  if new.user_id     is distinct from old.user_id
     or new.workshop_id is distinct from old.workshop_id
     or new.request_id  is distinct from old.request_id
     or new.proposal_id is distinct from old.proposal_id then
    raise exception 'Os vinculos da reserva nao podem ser alterados';
  end if;

  if not v_is_workshop_owner then
    -- Motorista: no toca condiciones definidas por el taller
    if new.estimated_price         is distinct from old.estimated_price
       or new.booking_mode            is distinct from old.booking_mode
       or new.estimated_duration_text is distinct from old.estimated_duration_text
       or new.booking_instructions    is distinct from old.booking_instructions
       or new.confirmed_at            is distinct from old.confirmed_at
       or new.completed_at            is distinct from old.completed_at then
      raise exception 'O motorista nao pode alterar as condicoes definidas pela oficina';
    end if;

    -- Motorista: único cambio de estado permitido es cancelar
    if new.status is distinct from old.status then
      if not (old.status in ('pending','confirmed') and new.status = 'cancelled') then
        raise exception 'O motorista so pode cancelar a reserva';
      end if;
    end if;

    -- Motorista: solo elige horario mientras está pendiente
    if new.scheduled_at is distinct from old.scheduled_at and old.status <> 'pending' then
      raise exception 'O horario so pode ser alterado enquanto a reserva esta pendente';
    end if;
  end if;

  if new.status = 'cancelled' and old.status <> 'cancelled' then
    new.cancelled_at := coalesce(new.cancelled_at, now());
  end if;
  if new.status = 'completed' and old.status <> 'completed' then
    new.completed_at := coalesce(new.completed_at, now());
  end if;
  if new.status = 'confirmed' and old.status <> 'confirmed' then
    new.confirmed_at := coalesce(new.confirmed_at, now());
  end if;

  return new;
end;
$$;

drop trigger if exists trg_enforce_reservation_update_rules on public.reservations;
create trigger trg_enforce_reservation_update_rules
  before update on public.reservations
  for each row execute function public.enforce_reservation_update_rules();


-- ─── 5. Helpers ──────────────────────────────────────────────

-- 5.1 Notificación interna (siempre se crea; el push lo dispara
--     el frontend vía la función Netlify notify-event existente)
create or replace function public.notify_user(
  p_user_id uuid,
  p_type    text,
  p_title   text,
  p_detail  text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_user_id is null then return; end if;
  insert into public.notifications (user_id, type, title, detail, link)
  values (
    p_user_id,
    case when p_type in ('quote','message','system','promo')
         then p_type::notification_type else 'system'::notification_type end,
    p_title,
    p_detail,
    '/'
  );
exception when others then
  -- una notificación fallida nunca debe romper la transacción principal
  raise warning 'notify_user: %', sqlerrm;
end;
$$;

-- 5.2 Validación de horario contra agenda del taller
--     (horario de atención + bloqueos + capacidad por franja)
create or replace function public.validate_reservation_slot(
  p_workshop_id uuid,
  p_at          timestamptz,
  p_exclude_reservation uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ws           record;
  v_local        timestamp;
  v_dow          int;
  v_day_name     text;
  v_names        text[] := array['Domingo','Segunda-feira','Terça-feira','Quarta-feira','Quinta-feira','Sexta-feira','Sábado'];
  v_custom       text;
  v_segment      text;
  v_part         text;
  v_times        text[];
  v_open         time;
  v_close        time;
  v_time         time;
  v_slot_start   timestamptz;
  v_slot_minutes int;
  v_max          int;
  v_count        int;
begin
  if p_at is null then
    raise exception 'Informe data e horario.';
  end if;
  if p_at <= now() then
    raise exception 'O horario escolhido ja passou. Escolha uma data futura.';
  end if;

  select id, schedule, slot_minutes, max_bookings_per_slot
  into v_ws
  from public.workshops where id = p_workshop_id;

  if v_ws.id is null then
    raise exception 'Oficina nao encontrada.';
  end if;

  v_local    := p_at at time zone 'America/Sao_Paulo';
  v_dow      := extract(dow from v_local)::int;
  v_day_name := v_names[v_dow + 1];
  v_time     := v_local::time;

  -- 5.2.a Horario de atención (formato real: schedule.custom =
  -- "Segunda-feira: 08:00 às 18:00 | ... | Domingo: Fechado").
  -- Si el taller no tiene horario cargado, no se bloquea.
  v_custom := v_ws.schedule->>'custom';
  if v_custom is not null and length(trim(v_custom)) > 0 then
    select trim(seg) into v_segment
    from unnest(string_to_array(v_custom, '|')) as seg
    where trim(seg) ilike v_day_name || ':%'
    limit 1;

    if v_segment is not null then
      v_part := trim(substring(v_segment from position(':' in v_segment) + 1));
      if v_part ilike '%fechado%' then
        raise exception 'A oficina nao atende em %.', v_day_name;
      end if;
      v_times := regexp_match(v_part, '(\d{1,2}:\d{2}).*?(\d{1,2}:\d{2})');
      if v_times is not null then
        v_open  := v_times[1]::time;
        v_close := v_times[2]::time;
        if v_time < v_open or v_time >= v_close then
          raise exception 'A oficina atende em % das % as %.', v_day_name, v_times[1], v_times[2];
        end if;
      end if;
    end if;
  end if;

  -- 5.2.b Bloqueos de agenda
  if exists (
    select 1 from public.workshop_availability_blocks b
    where b.workshop_id = p_workshop_id
      and b.active = true
      and b.day_of_week = v_dow
      and v_time >= b.start_time
      and v_time <  b.end_time
  ) then
    raise exception 'A oficina bloqueou este horario na agenda. Escolha outro.';
  end if;

  -- 5.2.c Capacidad por franja (walk-in no consume capacidad)
  v_slot_minutes := coalesce(v_ws.slot_minutes, 60);
  v_max          := coalesce(v_ws.max_bookings_per_slot, 1);
  v_slot_start   := date_trunc('hour', p_at)
    + (floor(extract(minute from p_at)::numeric / v_slot_minutes) * v_slot_minutes) * interval '1 minute';

  select count(*) into v_count
  from public.reservations r
  where r.workshop_id = p_workshop_id
    and r.status in ('pending','confirmed')
    and coalesce(r.booking_mode, 'scheduled') <> 'walkin'
    and r.scheduled_at >= v_slot_start
    and r.scheduled_at <  v_slot_start + make_interval(mins => v_slot_minutes)
    and (p_exclude_reservation is null or r.id <> p_exclude_reservation);

  if v_count >= v_max then
    raise exception 'Este horario ja esta lotado. Escolha outra franja.';
  end if;
end;
$$;


-- ─── 6. RPCs del flujo ───────────────────────────────────────

-- 6.1 accept_proposal: aceptación + reserva única, idempotente
create or replace function public.accept_proposal(p_proposal_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_prop        record;
  v_req         record;
  v_res         public.reservations%rowtype;
  v_owner_id    uuid;
  v_did_accept  boolean := false;
begin
  if auth.uid() is null then
    raise exception 'Autenticacao obrigatoria.';
  end if;

  select * into v_prop from public.proposals where id = p_proposal_id for update;
  if v_prop.id is null then
    raise exception 'Proposta nao encontrada.';
  end if;

  select * into v_req from public.service_requests where id = v_prop.request_id for update;
  if v_req.id is null then
    raise exception 'Solicitacao da proposta nao encontrada.';
  end if;

  if v_req.user_id is distinct from auth.uid() and not public.is_admin() then
    raise exception 'Somente o motorista da solicitacao pode aceitar esta proposta.';
  end if;

  if v_prop.status = 'pending' then
    -- Los triggers del 17/07 validan todo, cierran la solicitud,
    -- rechazan las demás propuestas y registran el historial.
    update public.proposals set status = 'accepted' where id = v_prop.id;
    v_did_accept := true;
    select * into v_prop from public.proposals where id = p_proposal_id;
  elsif v_prop.status <> 'accepted' then
    raise exception 'Esta proposta ja foi % e nao pode ser aceita.',
      case v_prop.status when 'declined' then 'recusada' else v_prop.status end;
  end if;

  -- Reserva única por propuesta (índice parcial garantiza unicidad)
  insert into public.reservations (
    user_id, workshop_id, request_id, proposal_id, source,
    service_type, scheduled_at, notes, status, estimated_price,
    booking_mode, estimated_duration_text, booking_instructions
  ) values (
    v_req.user_id,
    v_prop.workshop_id,
    v_req.id,
    v_prop.id,
    'app',
    coalesce(nullif(trim(v_req.category), ''), v_req.title, 'Servico'),
    null,
    v_prop.message,
    'pending',
    v_prop.price,
    coalesce(v_prop.booking_mode, 'scheduled'),
    coalesce(v_prop.estimated_duration_text, v_prop.estimated_time),
    v_prop.booking_instructions
  )
  on conflict (proposal_id) where proposal_id is not null do nothing;

  select * into v_res from public.reservations where proposal_id = v_prop.id limit 1;

  if v_did_accept then
    select owner_id into v_owner_id from public.workshops where id = v_prop.workshop_id;
    perform public.notify_user(
      v_owner_id, 'quote', 'Proposta aceita',
      'O motorista aceitou sua proposta' ||
      case when v_prop.price is not null then ' de R$ ' || v_prop.price::text else '' end ||
      '. Uma reserva foi criada.'
    );
    perform public.notify_user(
      v_req.user_id, 'quote', 'Reserva criada',
      case coalesce(v_prop.booking_mode, 'scheduled')
        when 'walkin'  then 'Voce pode ir ate a oficina conforme as instrucoes, sem agendar horario.'
        when 'dropoff' then 'Escolha o horario de entrega do veiculo para concluir o agendamento.'
        else 'Escolha a data e o horario do atendimento para concluir o agendamento.'
      end
    );
  end if;

  return jsonb_build_object(
    'success', true,
    'accepted', v_did_accept,
    'request_id', v_req.id,
    'proposal_id', v_prop.id,
    'reservation', to_jsonb(v_res)
  );
end;
$$;

-- 6.2 request_reservation_slot: el motorista elige horario
create or replace function public.request_reservation_slot(
  p_reservation_id uuid,
  p_scheduled_at   timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_res      public.reservations%rowtype;
  v_owner_id uuid;
begin
  select * into v_res from public.reservations where id = p_reservation_id for update;
  if v_res.id is null then
    raise exception 'Reserva nao encontrada.';
  end if;
  if v_res.user_id is distinct from auth.uid() and not public.is_admin() then
    raise exception 'Somente o dono da reserva pode escolher o horario.';
  end if;
  if coalesce(v_res.booking_mode, 'scheduled') = 'walkin' then
    raise exception 'Esta reserva e walk-in: va ate a oficina conforme as instrucoes, sem agendar.';
  end if;
  if v_res.status <> 'pending' then
    raise exception 'O horario so pode ser escolhido enquanto a reserva esta pendente.';
  end if;

  perform public.validate_reservation_slot(v_res.workshop_id, p_scheduled_at, v_res.id);

  update public.reservations
  set scheduled_at = p_scheduled_at, updated_at = now()
  where id = v_res.id;

  select owner_id into v_owner_id from public.workshops where id = v_res.workshop_id;
  perform public.notify_user(
    v_owner_id, 'quote', 'Horario solicitado',
    'O motorista escolheu ' || to_char(p_scheduled_at at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') ||
    case when coalesce(v_res.booking_mode,'scheduled') = 'dropoff'
         then ' para a entrega do veiculo.' else ' para o atendimento.' end ||
    ' Confirme a reserva.'
  );

  select * into v_res from public.reservations where id = p_reservation_id;
  return jsonb_build_object('success', true, 'reservation', to_jsonb(v_res));
end;
$$;

-- 6.3 confirm_reservation: el taller confirma
create or replace function public.confirm_reservation(p_reservation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_res public.reservations%rowtype;
begin
  select r.* into v_res
  from public.reservations r
  join public.workshops w on w.id = r.workshop_id
  where r.id = p_reservation_id
    and (w.owner_id = auth.uid() or public.is_admin())
  for update of r;

  if v_res.id is null then
    raise exception 'Reserva nao encontrada ou sem permissao.';
  end if;
  if v_res.status <> 'pending' then
    raise exception 'Somente reservas pendentes podem ser confirmadas.';
  end if;
  if coalesce(v_res.booking_mode, 'scheduled') <> 'walkin' and v_res.scheduled_at is null then
    raise exception 'O motorista ainda nao escolheu o horario.';
  end if;

  if v_res.scheduled_at is not null then
    perform public.validate_reservation_slot(v_res.workshop_id, v_res.scheduled_at, v_res.id);
  end if;

  update public.reservations
  set status = 'confirmed', confirmed_at = now(), updated_at = now()
  where id = v_res.id;

  perform public.notify_user(
    v_res.user_id, 'quote', 'Reserva confirmada',
    'A oficina confirmou sua reserva' ||
    case when v_res.scheduled_at is not null
      then ' para ' || to_char(v_res.scheduled_at at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || '.'
      else '.' end
  );

  select * into v_res from public.reservations where id = p_reservation_id;
  return jsonb_build_object('success', true, 'reservation', to_jsonb(v_res));
end;
$$;

-- 6.4 complete_reservation: el taller finaliza el servicio
create or replace function public.complete_reservation(p_reservation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_res public.reservations%rowtype;
begin
  select r.* into v_res
  from public.reservations r
  join public.workshops w on w.id = r.workshop_id
  where r.id = p_reservation_id
    and (w.owner_id = auth.uid() or public.is_admin())
  for update of r;

  if v_res.id is null then
    raise exception 'Reserva nao encontrada ou sem permissao.';
  end if;
  if v_res.status not in ('pending','confirmed') then
    raise exception 'Esta reserva nao pode ser finalizada (status atual: %).', v_res.status;
  end if;

  update public.reservations
  set status = 'completed', completed_at = now(), updated_at = now()
  where id = v_res.id;

  perform public.notify_user(
    v_res.user_id, 'quote', 'Servico concluido',
    'A oficina marcou seu servico como concluido. Obrigado por usar o Vai Rodar!'
  );

  select * into v_res from public.reservations where id = p_reservation_id;
  return jsonb_build_object('success', true, 'reservation', to_jsonb(v_res));
end;
$$;

-- 6.5 cancel_reservation: motorista o taller
create or replace function public.cancel_reservation(
  p_reservation_id uuid,
  p_reason         text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_res       public.reservations%rowtype;
  v_owner_id  uuid;
  v_is_owner  boolean;
  v_is_user   boolean;
begin
  select * into v_res from public.reservations where id = p_reservation_id for update;
  if v_res.id is null then
    raise exception 'Reserva nao encontrada.';
  end if;

  select owner_id into v_owner_id from public.workshops where id = v_res.workshop_id;
  v_is_user  := v_res.user_id = auth.uid();
  v_is_owner := v_owner_id    = auth.uid();

  if not v_is_user and not v_is_owner and not public.is_admin() then
    raise exception 'Sem permissao para cancelar esta reserva.';
  end if;
  if v_res.status not in ('pending','confirmed') then
    raise exception 'Esta reserva nao pode ser cancelada (status atual: %).', v_res.status;
  end if;

  update public.reservations
  set status = 'cancelled',
      cancelled_at = now(),
      cancel_reason = nullif(trim(coalesce(p_reason, '')), ''),
      updated_at = now()
  where id = v_res.id;

  -- Notificar a la contraparte
  if v_is_user then
    perform public.notify_user(
      v_owner_id, 'quote', 'Reserva cancelada',
      'O motorista cancelou a reserva' ||
      coalesce(': ' || nullif(trim(p_reason), ''), '.') );
  else
    perform public.notify_user(
      v_res.user_id, 'quote', 'Reserva cancelada',
      'A oficina cancelou sua reserva' ||
      coalesce(': ' || nullif(trim(p_reason), ''), '.') );
  end if;

  select * into v_res from public.reservations where id = p_reservation_id;
  return jsonb_build_object('success', true, 'reservation', to_jsonb(v_res));
end;
$$;

-- Permisos de ejecución: solo usuarios autenticados
revoke all on function public.accept_proposal(uuid)                     from public, anon;
revoke all on function public.request_reservation_slot(uuid, timestamptz) from public, anon;
revoke all on function public.confirm_reservation(uuid)                 from public, anon;
revoke all on function public.complete_reservation(uuid)                from public, anon;
revoke all on function public.cancel_reservation(uuid, text)            from public, anon;

grant execute on function public.accept_proposal(uuid)                     to authenticated;
grant execute on function public.request_reservation_slot(uuid, timestamptz) to authenticated;
grant execute on function public.confirm_reservation(uuid)                 to authenticated;
grant execute on function public.complete_reservation(uuid)                to authenticated;
grant execute on function public.cancel_reservation(uuid, text)            to authenticated;


-- ============================================================
-- DIAGNÓSTICO — correr después de aplicar la migration
-- ============================================================

-- 1. Columnas nuevas:
-- select column_name from information_schema.columns
-- where table_name in ('proposals','reservations')
--   and column_name in ('booking_mode','validity_days','valid_until',
--     'request_id','proposal_id','confirmed_at','cancel_reason',
--     'estimated_duration_text','booking_instructions')
-- order by table_name, column_name;

-- 2. Backfill de validez (todas las propuestas deben tener valid_until):
-- select count(*) filter (where valid_until is null) as sin_validez,
--        count(*) as total from public.proposals;

-- 3. scheduled_at ahora nullable:
-- select is_nullable from information_schema.columns
-- where table_name = 'reservations' and column_name = 'scheduled_at';

-- 4. RPCs creadas:
-- select routine_name from information_schema.routines
-- where routine_schema = 'public'
--   and routine_name in ('accept_proposal','request_reservation_slot',
--     'confirm_reservation','complete_reservation','cancel_reservation',
--     'validate_reservation_slot','notify_user');

-- 5. Aceptación idempotente (logueado como motorista, con una
--    propuesta pendiente de prueba):
-- select public.accept_proposal('<proposal_id>');
-- select public.accept_proposal('<proposal_id>');  -- misma reserva
-- select count(*) from public.reservations where proposal_id = '<proposal_id>'; -- = 1

-- ─── FIN DE MIGRATION ─────────────────────────────────────────
