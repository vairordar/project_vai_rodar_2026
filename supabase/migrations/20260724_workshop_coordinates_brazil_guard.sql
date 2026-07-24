-- Vai Rodar: corrige coordenadas invertidas e impede oficinas fora do Brasil.
-- Limites amplos para cobrir todo o territorio brasileiro.

begin;

-- Corrige o erro comum em que longitude e latitude foram salvas ao contrario.
update public.workshops
set
  latitude = longitude,
  longitude = latitude
where latitude is not null
  and longitude is not null
  and not (
    latitude between -35 and 6
    and longitude between -75 and -28
  )
  and longitude between -35 and 6
  and latitude between -75 and -28;

-- Coordenadas restantes fora do Brasil nao devem produzir marcadores falsos.
update public.workshops
set latitude = null, longitude = null
where (latitude is null) <> (longitude is null)
   or (
     latitude is not null
     and longitude is not null
     and not (
       latitude between -35 and 6
       and longitude between -75 and -28
     )
   );

alter table public.workshops
  drop constraint if exists workshops_brazil_coordinates_check;

alter table public.workshops
  add constraint workshops_brazil_coordinates_check
  check (
    (latitude is null and longitude is null)
    or (
      latitude between -35 and 6
      and longitude between -75 and -28
    )
  );

commit;
