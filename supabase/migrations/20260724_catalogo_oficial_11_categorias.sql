-- ============================================================
-- Vai Rodar - catalogo oficial de servicos (11 categorias)
-- Migration: 20260724_catalogo_oficial_11_categorias.sql
-- Idempotente: conserva oficinas, subcategorias e servicos.
-- ============================================================

begin;

insert into public.service_categories
  (name, slug, description, icon, sort_order, active)
values
  ('Mecânica geral',          'mecanica-geral',          'Manutenção, diagnóstico e reparos mecânicos.',              'wrench',       10,  true),
  ('Óleo e filtros',          'oleo-e-filtros',          'Troca de óleo e filtros do veículo.',                        'oil',          20,  true),
  ('Freios',                  'freios',                   'Inspeção e manutenção do sistema de freios.',                'brakes',       30,  true),
  ('Pneus',                   'pneus',                    'Pneus, alinhamento, balanceamento e reparos.',                'tire',         40,  true),
  ('Bateria e elétrica',      'bateria-e-eletrica',      'Bateria, partida, iluminação e sistema elétrico.',           'battery',      50,  true),
  ('Ar-condicionado',         'ar-condicionado',         'Diagnóstico, carga e higienização do ar-condicionado.',      'snowflake',    60,  true),
  ('Funilaria e pintura',     'funilaria-e-pintura',     'Reparos de carroceria, amassados e pintura.',                 'paint',        70,  true),
  ('Estética automotiva',     'estetica-automotiva',     'Lavagem, higienização, polimento e detalhamento.',            'sparkles',     80,  true),
  ('Vidros e para-brisas',    'vidros-e-para-brisas',    'Reparo e troca de vidros e para-brisas.',                    'windshield',   90,  true),
  ('Acessórios',              'acessorios',               'Instalação e manutenção de acessórios automotivos.',         'toolbox',      100, true),
  ('Chaveiro automotivo',     'chaveiro-automotivo',     'Abertura, cópia e programação de chaves automotivas.',       'key',          110, true)
on conflict (name) do update
set slug        = excluded.slug,
    description = excluded.description,
    icon        = excluded.icon,
    sort_order  = excluded.sort_order,
    active      = true,
    updated_at  = now();

create temporary table vr_category_merge (
  source_name text primary key,
  target_name text not null
) on commit drop;

insert into vr_category_merge (source_name, target_name) values
  ('Revisão geral / Manutenção preventiva', 'Mecânica geral'),
  ('Troca de óleo e filtros',                'Óleo e filtros'),
  ('Freios e suspensão',                     'Freios'),
  ('Motor e transmissão',                    'Mecânica geral'),
  ('Elétrica automotiva',                    'Bateria e elétrica'),
  ('Pneus e alinhamento',                    'Pneus'),
  ('Diagnóstico computadorizado',            'Mecânica geral'),
  ('Vidros e acessórios',                    'Vidros e para-brisas'),
  ('Blindagem',                              'Acessórios'),
  ('Lavagem e estética',                     'Estética automotiva');

do $$
declare
  mapping record;
  source_id uuid;
  target_id uuid;
  source_sub record;
  target_sub_id uuid;
begin
  for mapping in select * from vr_category_merge loop
    select id into source_id
    from public.service_categories
    where name = mapping.source_name;

    select id into target_id
    from public.service_categories
    where name = mapping.target_name;

    if source_id is null or target_id is null or source_id = target_id then
      continue;
    end if;

    insert into public.workshop_categories (workshop_id, category_id)
    select workshop_id, target_id
    from public.workshop_categories
    where category_id = source_id
    on conflict (workshop_id, category_id) do nothing;

    delete from public.workshop_categories
    where category_id = source_id;

    for source_sub in
      select id, name
      from public.service_subcategories
      where category_id = source_id
    loop
      select id into target_sub_id
      from public.service_subcategories
      where category_id = target_id
        and name = source_sub.name
      limit 1;

      if target_sub_id is not null then
        update public.workshop_services
        set subcategory_id = target_sub_id
        where subcategory_id = source_sub.id;

        delete from public.service_subcategories
        where id = source_sub.id;
      else
        update public.service_subcategories
        set category_id = target_id,
            updated_at = now()
        where id = source_sub.id;
      end if;
    end loop;

    delete from public.workshop_services source_service
    where source_service.category_id = source_id
      and exists (
        select 1
        from public.workshop_services target_service
        where target_service.workshop_id = source_service.workshop_id
          and target_service.category_id = target_id
          and target_service.name = source_service.name
      );

    update public.workshop_services
    set category_id = target_id,
        updated_at = now()
    where category_id = source_id;

    delete from public.service_categories
    where id = source_id;
  end loop;
end $$;

-- Textos historicos usados antes da tabela ponte.
update public.workshops w
set services = coalesce((
  select array_agg(distinct mapped_name order by mapped_name)
  from (
    select case service_name
      when 'Revisão geral / Manutenção preventiva' then 'Mecânica geral'
      when 'Troca de óleo e filtros'                then 'Óleo e filtros'
      when 'Freios e suspensão'                     then 'Freios'
      when 'Motor e transmissão'                    then 'Mecânica geral'
      when 'Elétrica automotiva'                    then 'Bateria e elétrica'
      when 'Pneus e alinhamento'                    then 'Pneus'
      when 'Diagnóstico computadorizado'            then 'Mecânica geral'
      when 'Vidros e acessórios'                    then 'Vidros e para-brisas'
      when 'Blindagem'                              then 'Acessórios'
      when 'Lavagem e estética'                     then 'Estética automotiva'
      else service_name
    end as mapped_name
    from unnest(coalesce(w.services, '{}'::text[])) service_name
  ) mapped
), '{}'::text[])
where w.services is not null;

update public.workshops
set category = case category
  when 'Revisão geral / Manutenção preventiva' then 'Mecânica geral'
  when 'Troca de óleo e filtros'                then 'Óleo e filtros'
  when 'Freios e suspensão'                     then 'Freios'
  when 'Motor e transmissão'                    then 'Mecânica geral'
  when 'Elétrica automotiva'                    then 'Bateria e elétrica'
  when 'Pneus e alinhamento'                    then 'Pneus'
  when 'Diagnóstico computadorizado'            then 'Mecânica geral'
  when 'Vidros e acessórios'                    then 'Vidros e para-brisas'
  when 'Blindagem'                              then 'Acessórios'
  when 'Lavagem e estética'                     then 'Estética automotiva'
  else category
end
where category is not null;

update public.service_requests
set category = case category
  when 'Revisão geral / Manutenção preventiva' then 'Mecânica geral'
  when 'Troca de óleo e filtros'                then 'Óleo e filtros'
  when 'Freios e suspensão'                     then 'Freios'
  when 'Motor e transmissão'                    then 'Mecânica geral'
  when 'Elétrica automotiva'                    then 'Bateria e elétrica'
  when 'Pneus e alinhamento'                    then 'Pneus'
  when 'Diagnóstico computadorizado'            then 'Mecânica geral'
  when 'Vidros e acessórios'                    then 'Vidros e para-brisas'
  when 'Blindagem'                              then 'Acessórios'
  when 'Lavagem e estética'                     then 'Estética automotiva'
  else category
end
where category is not null;

-- Apenas as 11 categorias oficiais ficam expostas no cadastro e nos apps.
update public.service_categories
set active = name in (
  'Mecânica geral',
  'Óleo e filtros',
  'Freios',
  'Pneus',
  'Bateria e elétrica',
  'Ar-condicionado',
  'Funilaria e pintura',
  'Estética automotiva',
  'Vidros e para-brisas',
  'Acessórios',
  'Chaveiro automotivo'
),
updated_at = now();

commit;

-- Verificacao esperada: exatamente 11 linhas ativas, nesta ordem.
select name, slug, sort_order, active
from public.service_categories
where active = true
order by sort_order, name;
