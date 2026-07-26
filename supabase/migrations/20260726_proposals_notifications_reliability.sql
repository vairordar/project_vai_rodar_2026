-- Vai Rodar: propostas e notificacoes confiaveis.
-- Idempotente: pode ser executada novamente sem duplicar policies ou triggers.

alter table public.proposals enable row level security;
alter table public.notifications enable row level security;

drop policy if exists "Motorista le propostas recebidas" on public.proposals;
create policy "Motorista le propostas recebidas"
  on public.proposals
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.service_requests request
      where request.id = proposals.request_id
        and request.user_id = auth.uid()
    )
  );

drop policy if exists "Oficina le propostas enviadas" on public.proposals;
create policy "Oficina le propostas enviadas"
  on public.proposals
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.workshops workshop
      where workshop.id = proposals.workshop_id
        and workshop.owner_id = auth.uid()
    )
  );

drop policy if exists "Usuario elimina suas notificacoes" on public.notifications;
create policy "Usuario elimina suas notificacoes"
  on public.notifications
  for delete
  to authenticated
  using (user_id = auth.uid());

create or replace function public.notify_driver_on_proposal_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  driver_id uuid;
  request_title text;
  workshop_name text;
  price_text text;
begin
  select request.user_id, coalesce(request.title, request.description, 'sua solicitacao')
    into driver_id, request_title
  from public.service_requests request
  where request.id = new.request_id;

  select coalesce(workshop.name, 'Uma oficina')
    into workshop_name
  from public.workshops workshop
  where workshop.id = new.workshop_id;

  if driver_id is null then
    return new;
  end if;

  price_text := case
    when new.price is null then 'preco a combinar'
    else 'R$ ' || new.price::text
  end;

  insert into public.notifications (user_id, type, title, detail, link)
  values (
    driver_id,
    'quote',
    'Nova proposta recebida',
    workshop_name || ' respondeu: ' || request_title || ' (' || price_text || ').',
    'quote:' || new.request_id::text
  );

  return new;
end;
$$;

drop trigger if exists trg_notify_driver_on_proposal_insert on public.proposals;
create trigger trg_notify_driver_on_proposal_insert
  after insert on public.proposals
  for each row execute function public.notify_driver_on_proposal_insert();

grant select on public.proposals to authenticated;
grant delete on public.notifications to authenticated;
