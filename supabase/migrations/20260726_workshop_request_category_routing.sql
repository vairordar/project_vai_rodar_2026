-- Vai Rodar: roteamento de solicitacoes por categoria oficial.
-- Mantem o historico de propostas enviadas e separa novas/vencidas no backoffice.

create or replace function public.vr_category_key(p_value text)
returns text
language plpgsql
immutable
as $$
declare
  value text := translate(
    lower(trim(coalesce(p_value, ''))),
    'áàâãäéèêëíìîïóòôõöúùûüç',
    'aaaaaeeeeiiiiooooouuuuc'
  );
begin
  if value = '' then return ''; end if;
  if value like '%chave%' then return 'chaveiro-automotivo'; end if;
  if value like '%oleo%' or value like '%filtro%' then return 'oleo-e-filtros'; end if;
  if value like '%freio%' or value like '%suspens%' then return 'freios'; end if;
  if value like '%pneu%' or value like '%alinh%' then return 'pneus'; end if;
  if value like '%bateria%' or value like '%eletric%' then return 'bateria-e-eletrica'; end if;
  if value like '%ar-condicionado%' or value like '%ar condicionado%' then return 'ar-condicionado'; end if;
  if value like '%funilar%' or value like '%pintura%' then return 'funilaria-e-pintura'; end if;
  if value like '%estetic%' or value like '%lavagem%' or value like '%detailing%' then return 'estetica-automotiva'; end if;
  if value like '%vidro%' or value like '%para-brisa%' then return 'vidros-e-para-brisas'; end if;
  if value like '%acessor%' or value like '%blindagem%' then return 'acessorios'; end if;
  if value like '%mecan%' or value like '%revis%' or value like '%manutenc%'
     or value like '%motor%' or value like '%transmiss%' then return 'mecanica-geral'; end if;
  return trim(both '-' from regexp_replace(value, '[^a-z0-9]+', '-', 'g'));
end;
$$;

create or replace function public.workshop_accepts_request_category(
  p_workshop_id uuid,
  p_request_category text
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    public.vr_category_key(p_request_category) <> ''
    and (
      exists (
        select 1
        from public.workshop_categories wc
        join public.service_categories c on c.id = wc.category_id
        where wc.workshop_id = p_workshop_id
          and c.active = true
          and public.vr_category_key(coalesce(c.slug, c.name)) =
              public.vr_category_key(p_request_category)
      )
      or exists (
        select 1
        from public.workshop_services ws
        join public.service_categories c on c.id = ws.category_id
        where ws.workshop_id = p_workshop_id
          and ws.active is distinct from false
          and c.active = true
          and public.vr_category_key(coalesce(c.slug, c.name)) =
              public.vr_category_key(p_request_category)
      )
      or (
        not exists (
          select 1 from public.workshop_categories wc
          where wc.workshop_id = p_workshop_id
        )
        and not exists (
          select 1 from public.workshop_services ws
          where ws.workshop_id = p_workshop_id
            and ws.active is distinct from false
        )
        and exists (
          select 1
          from public.workshops w
          where w.id = p_workshop_id
            and (
              public.vr_category_key(w.category) = public.vr_category_key(p_request_category)
              or exists (
                select 1
                from unnest(coalesce(w.services, '{}'::text[])) legacy_category
                where public.vr_category_key(legacy_category) =
                      public.vr_category_key(p_request_category)
              )
            )
        )
      )
    );
$$;

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
      and public.workshop_accepts_request_category(workshop.id, request.category)
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

create or replace function public.request_visible_for_workshop(
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
    from public.workshops workshop
    join public.service_requests request on request.id = p_request_id
    where workshop.id = p_workshop_id
      and workshop.owner_id = auth.uid()
      and (
        exists (
          select 1 from public.proposals proposal
          where proposal.request_id = request.id
            and proposal.workshop_id = workshop.id
        )
        or (
          workshop.approval_status = 'approved'
          and workshop.visible = true
          and request.created_at >= workshop.created_at
          and public.workshop_accepts_request_category(workshop.id, request.category)
          and (
            coalesce(request.selected_business_ids, '{}'::uuid[]) = '{}'::uuid[]
            or workshop.id = any(request.selected_business_ids)
          )
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
        )
      )
  );
$$;

drop policy if exists "Taller aprobado ve solicitudes abiertas compatibles"
  on public.service_requests;
drop policy if exists "Taller ve solicitudes con propuesta propia"
  on public.service_requests;
drop policy if exists "Taller ve solicitudes compatibles por categoria"
  on public.service_requests;

create policy "Taller ve solicitudes compatibles por categoria"
  on public.service_requests
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.workshops workshop
      where workshop.owner_id = auth.uid()
        and public.request_visible_for_workshop(service_requests.id, workshop.id)
    )
  );

create or replace function public.enforce_proposal_request_category()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.request_open_for_workshop(new.request_id, new.workshop_id) then
    raise exception 'Esta solicitacao nao esta aberta para uma categoria oferecida pela oficina.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_enforce_proposal_request_category on public.proposals;
create trigger trg_enforce_proposal_request_category
before insert on public.proposals
for each row execute function public.enforce_proposal_request_category();

create index if not exists idx_service_requests_category_created
  on public.service_requests (category, created_at desc);

create index if not exists idx_workshop_categories_workshop_category
  on public.workshop_categories (workshop_id, category_id);

-- Diagnostico: deve retornar apenas categorias oficiais ativas por oficina.
-- select w.name, c.name as category
-- from public.workshops w
-- join public.workshop_categories wc on wc.workshop_id = w.id
-- join public.service_categories c on c.id = wc.category_id
-- where c.active = true
-- order by w.name, c.sort_order;
