-- Vai Rodar: sincroniza a modalidade de atendimento com o filtro publico.
-- A domicilio e Ambos entram no filtro "A domicilio".
-- A modalidade exata continua preservada em workshops.schedule->>'mode'.

alter table public.workshops
  add column if not exists home_service boolean not null default false;

create or replace function public.workshop_service_mode_key(value text)
returns text
language sql
immutable
set search_path = public
as $$
  select translate(
    lower(trim(coalesce(value, ''))),
    'áàâãäéèêëíìîïóòôõöúùûüç',
    'aaaaaeeeeiiiiooooouuuuc'
  );
$$;

update public.workshops
set home_service = case
  when public.workshop_service_mode_key(schedule->>'mode') <> '' then
    public.workshop_service_mode_key(schedule->>'mode') like '%domicilio%'
    or public.workshop_service_mode_key(schedule->>'mode') like '%ambos%'
    or public.workshop_service_mode_key(schedule->>'mode') in ('home', 'both')
  else coalesce(home_service, false) or coalesce(parts_delivery_enabled, false)
end;

create or replace function public.sync_workshop_home_service()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  mode_key text := public.workshop_service_mode_key(new.schedule->>'mode');
begin
  if mode_key <> '' then
    new.home_service :=
      mode_key like '%domicilio%'
      or mode_key like '%ambos%'
      or mode_key in ('home', 'both');
  else
    new.home_service :=
      coalesce(new.home_service, false)
      or coalesce(new.parts_delivery_enabled, false);
  end if;

  return new;
end;
$$;

drop trigger if exists trg_sync_workshop_home_service on public.workshops;
create trigger trg_sync_workshop_home_service
before insert or update of home_service, parts_delivery_enabled, schedule
on public.workshops
for each row
execute function public.sync_workshop_home_service();

comment on column public.workshops.home_service is
  'True para oficinas com atendimento A domicilio ou Ambos; usado pelos filtros publicos.';
