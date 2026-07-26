-- Vai Rodar: envio de propostas consistente entre tela e banco.
-- Idempotente e seguro para reexecucao.

-- Solicitudes antigas sem expires_at nao podem permanecer abertas para sempre.
update public.service_requests
set expires_at = created_at + interval '3 days'
where expires_at is null;

create or replace function public.request_open_for_workshop(
  p_request_id uuid,
  p_workshop_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.service_requests request
    join public.workshops workshop on workshop.id = p_workshop_id
    where request.id = p_request_id
      and request.status = 'open'
      and coalesce(request.expires_at, request.created_at + interval '3 days') > now()
      and request.created_at >= workshop.created_at
      and workshop.owner_id = auth.uid()
      and workshop.visible = true
      and workshop.open = true
      and workshop.approval_status = 'approved'
      and (
        coalesce(request.target_business_type,
          case when request.request_type = 'part_quote' then 'parts_store' else 'workshop' end
        ) = 'both'
        or (
          coalesce(request.target_business_type,
            case when request.request_type = 'part_quote' then 'parts_store' else 'workshop' end
          ) = 'workshop'
          and coalesce(workshop.business_type, 'workshop') in ('workshop', 'both')
        )
        or (
          coalesce(request.target_business_type,
            case when request.request_type = 'part_quote' then 'parts_store' else 'workshop' end
          ) = 'parts_store'
          and coalesce(workshop.business_type, 'workshop') in ('parts_store', 'both')
        )
      )
      and (
        coalesce(request.selected_business_ids, '{}'::uuid[]) = '{}'::uuid[]
        or workshop.id = any(request.selected_business_ids)
      )
  );
$$;

drop policy if exists "Taller aprobado ve solicitudes abiertas compatibles"
  on public.service_requests;

create policy "Taller aprobado ve solicitudes abiertas compatibles"
  on public.service_requests
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.workshops workshop
      where workshop.owner_id = auth.uid()
        and public.request_open_for_workshop(service_requests.id, workshop.id)
    )
  );

drop policy if exists "Taller aprobado envia propuesta"
  on public.proposals;

create policy "Taller aprobado envia propuesta"
  on public.proposals
  for insert
  to authenticated
  with check (
    public.request_open_for_workshop(request_id, workshop_id)
  );

create or replace function public.submit_workshop_proposal(
  p_request_id uuid,
  p_workshop_id uuid,
  p_message text,
  p_price numeric default null,
  p_estimated_time text default null,
  p_estimated_duration_text text default null,
  p_booking_mode text default 'scheduled',
  p_booking_instructions text default null,
  p_validity_days integer default 5
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  request_row public.service_requests%rowtype;
  workshop_row public.workshops%rowtype;
  proposal_id uuid;
  target_type text;
begin
  if auth.uid() is null then
    raise exception 'Sessao expirada. Entre novamente no backoffice.';
  end if;

  select * into workshop_row
  from public.workshops
  where id = p_workshop_id;

  if not found or workshop_row.owner_id <> auth.uid() then
    raise exception 'Esta conta nao administra a oficina informada.';
  end if;

  if workshop_row.approval_status is distinct from 'approved'
     or workshop_row.visible is distinct from true
     or workshop_row.open is distinct from true then
    raise exception 'A oficina precisa estar aprovada, visivel e recebendo pedidos.';
  end if;

  select * into request_row
  from public.service_requests
  where id = p_request_id
  for update;

  if not found then
    raise exception 'Solicitacao nao encontrada.';
  end if;

  if request_row.status <> 'open' then
    raise exception 'Esta solicitacao nao esta mais aberta.';
  end if;

  if coalesce(request_row.expires_at, request_row.created_at + interval '3 days') <= now() then
    raise exception 'Esta solicitacao ja venceu.';
  end if;

  if request_row.created_at < workshop_row.created_at then
    raise exception 'Esta solicitacao e anterior ao cadastro desta oficina.';
  end if;

  if coalesce(request_row.selected_business_ids, '{}'::uuid[]) <> '{}'::uuid[]
     and not (p_workshop_id = any(request_row.selected_business_ids)) then
    raise exception 'Esta solicitacao foi enviada para outras oficinas.';
  end if;

  target_type := coalesce(
    request_row.target_business_type,
    case when request_row.request_type = 'part_quote' then 'parts_store' else 'workshop' end
  );

  if not (
    target_type = 'both'
    or (target_type = 'workshop' and coalesce(workshop_row.business_type, 'workshop') in ('workshop', 'both'))
    or (target_type = 'parts_store' and coalesce(workshop_row.business_type, 'workshop') in ('parts_store', 'both'))
  ) then
    raise exception 'Esta solicitacao nao corresponde ao tipo deste estabelecimento.';
  end if;

  if coalesce(length(trim(p_message)), 0) < 10 then
    raise exception 'Descreva o servico que sera feito.';
  end if;

  if p_price is not null and p_price < 0 then
    raise exception 'Preco invalido.';
  end if;

  if p_booking_mode not in ('scheduled', 'dropoff', 'walkin') then
    raise exception 'Modalidade de reserva invalida.';
  end if;

  if p_validity_days not in (3, 5, 7, 15) then
    raise exception 'Validade da proposta invalida.';
  end if;

  if exists (
    select 1 from public.proposals
    where request_id = p_request_id
      and workshop_id = p_workshop_id
      and status in ('pending', 'accepted')
  ) then
    raise exception 'Esta oficina ja enviou uma proposta para esta solicitacao.';
  end if;

  insert into public.proposals (
    request_id,
    workshop_id,
    message,
    price,
    estimated_time,
    estimated_duration_text,
    booking_mode,
    booking_instructions,
    validity_days,
    status
  )
  values (
    p_request_id,
    p_workshop_id,
    trim(p_message),
    p_price,
    nullif(trim(coalesce(p_estimated_time, '')), ''),
    nullif(trim(coalesce(p_estimated_duration_text, '')), ''),
    p_booking_mode,
    nullif(trim(coalesce(p_booking_instructions, '')), ''),
    p_validity_days,
    'pending'
  )
  returning id into proposal_id;

  return proposal_id;
end;
$$;

revoke all on function public.submit_workshop_proposal(
  uuid, uuid, text, numeric, text, text, text, text, integer
) from public, anon;

grant execute on function public.submit_workshop_proposal(
  uuid, uuid, text, numeric, text, text, text, text, integer
) to authenticated;
