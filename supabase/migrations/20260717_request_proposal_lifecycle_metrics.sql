-- ============================================================
-- Vai Rodar - ciclo completo de solicitacoes e propostas
-- Data: 2026-07-17
--
-- Objetivos:
--   1. Registrar qual proposta e qual oficina foram escolhidas.
--   2. Fechar a solicitacao de forma atomica ao aceitar uma proposta.
--   3. Recusar automaticamente as demais propostas pendentes.
--   4. Preservar datas e motivos de cada decisao.
--   5. Expor ao admin o funil e metricas por categoria.
-- ============================================================

begin;

alter table public.service_requests
  add column if not exists accepted_proposal_id uuid,
  add column if not exists accepted_workshop_id uuid,
  add column if not exists accepted_at timestamptz,
  add column if not exists closed_at timestamptz,
  add column if not exists closed_reason text;

alter table public.proposals
  add column if not exists responded_at timestamptz,
  add column if not exists decision_reason text;

create table if not exists public.request_lifecycle_events (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.service_requests(id) on delete cascade,
  proposal_id uuid references public.proposals(id) on delete set null,
  workshop_id uuid references public.workshops(id) on delete set null,
  event_type text not null,
  from_status text,
  to_status text,
  actor_id uuid,
  event_key text not null unique,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.request_lifecycle_events enable row level security;

create index if not exists request_lifecycle_events_request_created_idx
  on public.request_lifecycle_events(request_id, created_at desc);

create index if not exists request_lifecycle_events_workshop_created_idx
  on public.request_lifecycle_events(workshop_id, created_at desc);

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'service_requests_accepted_proposal_fkey'
      and conrelid = 'public.service_requests'::regclass
  ) then
    alter table public.service_requests
      add constraint service_requests_accepted_proposal_fkey
      foreign key (accepted_proposal_id)
      references public.proposals(id)
      on delete set null;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'service_requests_accepted_workshop_fkey'
      and conrelid = 'public.service_requests'::regclass
  ) then
    alter table public.service_requests
      add constraint service_requests_accepted_workshop_fkey
      foreign key (accepted_workshop_id)
      references public.workshops(id)
      on delete set null;
  end if;
end $$;

-- Se existirem dados antigos inconsistentes, conserva como vencedora a
-- proposta aceita mais recentemente e encerra as demais como recusadas.
with ranked_accepted as (
  select
    id,
    row_number() over (
      partition by request_id
      order by coalesce(updated_at, created_at) desc, created_at desc, id
    ) as position
  from public.proposals
  where status = 'accepted'
)
update public.proposals p
set
  status = 'declined',
  responded_at = coalesce(p.responded_at, p.updated_at, p.created_at),
  decision_reason = coalesce(p.decision_reason, 'superseded_during_lifecycle_backfill')
from ranked_accepted ranked
where p.id = ranked.id
  and ranked.position > 1;

update public.proposals
set responded_at = coalesce(responded_at, updated_at, created_at)
where status in ('accepted', 'declined', 'expired')
  and responded_at is null;

create unique index if not exists proposals_one_accepted_per_request_idx
  on public.proposals(request_id)
  where status = 'accepted';

create index if not exists proposals_status_created_idx
  on public.proposals(status, created_at desc);

create index if not exists service_requests_accepted_workshop_idx
  on public.service_requests(accepted_workshop_id)
  where accepted_workshop_id is not null;

create index if not exists service_requests_accepted_at_idx
  on public.service_requests(accepted_at desc)
  where accepted_at is not null;

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

drop trigger if exists trg_prepare_proposal_decision on public.proposals;
create trigger trg_prepare_proposal_decision
  before insert or update of status on public.proposals
  for each row
  execute function public.prepare_proposal_decision();

create or replace function public.resolve_service_request_from_proposal()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'accepted'
     and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    update public.service_requests
    set
      status = 'closed',
      accepted_proposal_id = new.id,
      accepted_workshop_id = new.workshop_id,
      accepted_at = coalesce(new.responded_at, now()),
      closed_at = coalesce(closed_at, new.responded_at, now()),
      closed_reason = 'proposal_accepted',
      updated_at = now()
    where id = new.request_id
      and (accepted_proposal_id is null or accepted_proposal_id = new.id);

    if not found then
      raise exception 'Nao foi possivel fechar a solicitacao ou ja existe outra proposta aceita';
    end if;

    update public.proposals
    set
      status = 'declined',
      responded_at = coalesce(responded_at, new.responded_at, now()),
      decision_reason = coalesce(decision_reason, 'another_proposal_accepted'),
      updated_at = now()
    where request_id = new.request_id
      and id <> new.id
      and status = 'pending';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_resolve_service_request_from_proposal on public.proposals;
create trigger trg_resolve_service_request_from_proposal
  after insert or update of status on public.proposals
  for each row
  execute function public.resolve_service_request_from_proposal();

create or replace function public.log_proposal_lifecycle_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  event_name text;
  previous_status text;
  event_moment timestamptz;
begin
  if tg_op = 'INSERT' then
    previous_status := null;
    event_name := case
      when new.status = 'accepted' then 'proposal_accepted'
      when new.status = 'declined' then 'proposal_declined'
      when new.status = 'expired' then 'proposal_expired'
      else 'proposal_created'
    end;
    event_moment := coalesce(new.responded_at, new.created_at, now());
  else
    if new.status is not distinct from old.status then
      return new;
    end if;
    previous_status := old.status::text;
    event_name := case
      when new.status = 'accepted' then 'proposal_accepted'
      when new.status = 'declined' then 'proposal_declined'
      when new.status = 'expired' then 'proposal_expired'
      else 'proposal_status_changed'
    end;
    event_moment := coalesce(new.responded_at, new.updated_at, now());
  end if;

  insert into public.request_lifecycle_events (
    request_id,
    proposal_id,
    workshop_id,
    event_type,
    from_status,
    to_status,
    actor_id,
    event_key,
    metadata,
    created_at
  ) values (
    new.request_id,
    new.id,
    new.workshop_id,
    event_name,
    previous_status,
    new.status::text,
    auth.uid(),
    'proposal:' || new.id::text || ':' || event_name,
    jsonb_build_object(
      'price', new.price,
      'estimated_time', new.estimated_time,
      'decision_reason', new.decision_reason
    ),
    event_moment
  )
  on conflict (event_key) do nothing;

  return new;
end;
$$;

drop trigger if exists trg_log_proposal_lifecycle_event on public.proposals;
create trigger trg_log_proposal_lifecycle_event
  after insert or update of status on public.proposals
  for each row
  execute function public.log_proposal_lifecycle_event();

create or replace function public.log_request_lifecycle_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  event_name text;
  previous_status text;
  event_key_value text;
begin
  if tg_op = 'INSERT' then
    event_name := 'request_created';
    previous_status := null;
    event_key_value := 'request:' || new.id::text || ':created';
  else
    if new.status is not distinct from old.status then
      return new;
    end if;
    previous_status := old.status::text;
    event_name := case
      when new.status::text = 'closed' then 'request_closed'
      when new.status::text = 'expired' then 'request_expired'
      else 'request_status_changed'
    end;
    event_key_value := 'request:' || new.id::text || ':' || event_name || ':'
      || txid_current()::text;
  end if;

  insert into public.request_lifecycle_events (
    request_id,
    event_type,
    from_status,
    to_status,
    actor_id,
    event_key,
    metadata,
    created_at
  ) values (
    new.id,
    event_name,
    previous_status,
    new.status::text,
    auth.uid(),
    event_key_value,
    jsonb_build_object(
      'category', new.category,
      'closed_reason', new.closed_reason,
      'accepted_proposal_id', new.accepted_proposal_id,
      'accepted_workshop_id', new.accepted_workshop_id
    ),
    case when tg_op = 'INSERT' then coalesce(new.created_at, now()) else now() end
  )
  on conflict (event_key) do nothing;

  return new;
end;
$$;

drop trigger if exists trg_log_request_lifecycle_event on public.service_requests;
create trigger trg_log_request_lifecycle_event
  after insert or update of status on public.service_requests
  for each row
  execute function public.log_request_lifecycle_event();

-- Backfill do vencedor e do fechamento para propostas aceitas antigas.
with winners as (
  select distinct on (p.request_id)
    p.request_id,
    p.id as proposal_id,
    p.workshop_id,
    coalesce(p.responded_at, p.updated_at, p.created_at) as accepted_at
  from public.proposals p
  where p.status = 'accepted'
  order by p.request_id, coalesce(p.responded_at, p.updated_at, p.created_at) desc, p.id
)
update public.service_requests r
set
  status = 'closed',
  accepted_proposal_id = winners.proposal_id,
  accepted_workshop_id = winners.workshop_id,
  accepted_at = winners.accepted_at,
  closed_at = coalesce(r.closed_at, winners.accepted_at),
  closed_reason = coalesce(r.closed_reason, 'proposal_accepted'),
  updated_at = now()
from winners
where r.id = winners.request_id;

-- Historico minimo para propostas existentes antes desta migracao.
insert into public.request_lifecycle_events (
  request_id,
  proposal_id,
  workshop_id,
  event_type,
  from_status,
  to_status,
  event_key,
  metadata,
  created_at
)
select
  p.request_id,
  p.id,
  p.workshop_id,
  case
    when p.status = 'accepted' then 'proposal_accepted'
    when p.status = 'declined' then 'proposal_declined'
    when p.status = 'expired' then 'proposal_expired'
    else 'proposal_created'
  end,
  null,
  p.status::text,
  'proposal:' || p.id::text || ':' || case
    when p.status = 'accepted' then 'proposal_accepted'
    when p.status = 'declined' then 'proposal_declined'
    when p.status = 'expired' then 'proposal_expired'
    else 'proposal_created'
  end,
  jsonb_build_object(
    'price', p.price,
    'estimated_time', p.estimated_time,
    'decision_reason', p.decision_reason,
    'backfilled', true
  ),
  coalesce(p.responded_at, p.created_at)
from public.proposals p
on conflict (event_key) do nothing;

insert into public.request_lifecycle_events (
  request_id,
  event_type,
  from_status,
  to_status,
  event_key,
  metadata,
  created_at
)
select
  r.id,
  'request_created',
  null,
  'open',
  'request:' || r.id::text || ':created',
  jsonb_build_object('category', r.category, 'backfilled', true),
  r.created_at
from public.service_requests r
on conflict (event_key) do nothing;

insert into public.request_lifecycle_events (
  request_id,
  proposal_id,
  workshop_id,
  event_type,
  from_status,
  to_status,
  event_key,
  metadata,
  created_at
)
select
  r.id,
  r.accepted_proposal_id,
  r.accepted_workshop_id,
  case when r.status::text = 'expired' then 'request_expired' else 'request_closed' end,
  'open',
  r.status::text,
  'request:' || r.id::text || ':backfill:' || r.status::text,
  jsonb_build_object(
    'closed_reason', r.closed_reason,
    'accepted_proposal_id', r.accepted_proposal_id,
    'accepted_workshop_id', r.accepted_workshop_id,
    'backfilled', true
  ),
  coalesce(r.closed_at, r.accepted_at, r.updated_at, r.created_at)
from public.service_requests r
where r.status::text in ('closed', 'expired')
on conflict (event_key) do nothing;

create or replace view public.admin_request_lifecycle
with (security_invoker = true)
as
select
  r.id as request_id,
  r.user_id,
  profile.name as user_name,
  profile.email as user_email,
  r.vehicle_id,
  vehicle.plate as vehicle_plate,
  vehicle.brand as vehicle_brand,
  vehicle.model as vehicle_model,
  vehicle.year as vehicle_year,
  r.title,
  r.description,
  r.category,
  r.status::text as request_status,
  r.created_at,
  r.expires_at,
  r.accepted_at,
  r.closed_at,
  r.closed_reason,
  r.accepted_proposal_id,
  r.accepted_workshop_id,
  winner.name as accepted_workshop_name,
  accepted.price as accepted_price,
  accepted.estimated_time as accepted_estimated_time,
  accepted.message as accepted_message,
  proposal_totals.total_proposals,
  proposal_totals.pending_proposals,
  proposal_totals.accepted_proposals,
  proposal_totals.declined_proposals,
  case
    when r.accepted_proposal_id is not null
      or r.accepted_workshop_id is not null
      or r.accepted_at is not null then 'accepted'
    when r.status::text = 'expired' or (r.expires_at is not null and r.expires_at <= now()) then 'expired'
    when r.status::text = 'closed' then 'closed'
    when proposal_totals.total_proposals > 0 then 'with_proposals'
    else 'open'
  end as lifecycle_status
from public.service_requests r
left join public.profiles profile on profile.id = r.user_id
left join public.vehicles vehicle on vehicle.id = r.vehicle_id
left join public.proposals accepted on accepted.id = r.accepted_proposal_id
left join public.workshops winner on winner.id = r.accepted_workshop_id
left join lateral (
  select
    count(*)::integer as total_proposals,
    count(*) filter (where p.status = 'pending')::integer as pending_proposals,
    count(*) filter (where p.status = 'accepted')::integer as accepted_proposals,
    count(*) filter (where p.status = 'declined')::integer as declined_proposals
  from public.proposals p
  where p.request_id = r.id
) proposal_totals on true;

create or replace view public.admin_proposal_metrics_30d
with (security_invoker = true)
as
with request_stats as (
  select
    coalesce(nullif(trim(r.category), ''), 'Sem categoria') as category,
    count(*)::integer as total_requests,
    count(*) filter (where r.accepted_proposal_id is not null)::integer as accepted_requests,
    count(*) filter (
      where exists (select 1 from public.proposals p where p.request_id = r.id)
    )::integer as requests_with_proposals,
    avg(
      extract(epoch from (r.accepted_at - r.created_at)) / 3600.0
    ) filter (where r.accepted_at is not null) as avg_hours_to_acceptance
  from public.service_requests r
  where r.created_at >= now() - interval '30 days'
  group by 1
),
proposal_stats as (
  select
    coalesce(nullif(trim(r.category), ''), 'Sem categoria') as category,
    count(p.id)::integer as total_proposals,
    count(p.id) filter (where p.status = 'accepted')::integer as accepted_proposals,
    count(p.id) filter (where p.status = 'declined')::integer as declined_proposals,
    avg(p.price) filter (where p.price is not null) as avg_proposed_price,
    avg(p.price) filter (where p.status = 'accepted' and p.price is not null) as avg_accepted_price
  from public.service_requests r
  left join public.proposals p on p.request_id = r.id
  where r.created_at >= now() - interval '30 days'
  group by 1
)
select
  requests.category,
  requests.total_requests,
  requests.requests_with_proposals,
  requests.accepted_requests,
  proposals.total_proposals,
  proposals.accepted_proposals,
  proposals.declined_proposals,
  round(
    case when requests.total_requests = 0 then 0
      else requests.accepted_requests::numeric * 100 / requests.total_requests end,
    2
  ) as request_conversion_rate_pct,
  round(
    case when proposals.total_proposals = 0 then 0
      else proposals.accepted_proposals::numeric * 100 / proposals.total_proposals end,
    2
  ) as proposal_acceptance_rate_pct,
  round(proposals.avg_proposed_price, 2) as avg_proposed_price,
  round(proposals.avg_accepted_price, 2) as avg_accepted_price,
  round(requests.avg_hours_to_acceptance::numeric, 2) as avg_hours_to_acceptance
from request_stats requests
join proposal_stats proposals using (category)
order by requests.total_requests desc, requests.category;

create or replace view public.admin_proposal_summary_30d
with (security_invoker = true)
as
select
  count(distinct r.id)::integer as total_requests,
  count(distinct r.id) filter (
    where exists (select 1 from public.proposals existing where existing.request_id = r.id)
  )::integer as requests_with_proposals,
  count(distinct r.id) filter (where r.accepted_proposal_id is not null)::integer as accepted_requests,
  count(p.id)::integer as total_proposals,
  count(p.id) filter (where p.status = 'accepted')::integer as accepted_proposals,
  round(
    case when count(distinct r.id) = 0 then 0
      else count(distinct r.id) filter (where r.accepted_proposal_id is not null)::numeric
        * 100 / count(distinct r.id) end,
    2
  ) as request_conversion_rate_pct,
  round(avg(p.price) filter (where p.price is not null), 2) as avg_proposed_price,
  round(avg(p.price) filter (where p.status = 'accepted' and p.price is not null), 2) as avg_accepted_price,
  round(
    (avg(extract(epoch from (r.accepted_at - r.created_at)) / 3600.0)
      filter (where r.accepted_at is not null))::numeric,
    2
  ) as avg_hours_to_acceptance
from public.service_requests r
left join public.proposals p on p.request_id = r.id
where r.created_at >= now() - interval '30 days';

revoke all on public.admin_request_lifecycle from anon, authenticated;
revoke all on public.admin_proposal_metrics_30d from anon, authenticated;
revoke all on public.admin_proposal_summary_30d from anon, authenticated;
revoke all on public.request_lifecycle_events from anon, authenticated;

grant select on public.admin_request_lifecycle to service_role;
grant select on public.admin_proposal_metrics_30d to service_role;
grant select on public.admin_proposal_summary_30d to service_role;
grant select on public.request_lifecycle_events to service_role;

commit;

-- Verificacao opcional:
-- select * from public.admin_proposal_summary_30d;
-- select * from public.admin_proposal_metrics_30d;
-- select * from public.admin_request_lifecycle order by created_at desc limit 20;
