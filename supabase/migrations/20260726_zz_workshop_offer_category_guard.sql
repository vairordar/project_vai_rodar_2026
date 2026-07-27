-- ============================================================
-- Vai Rodar - ofertas limitadas ao catalogo aprovado da oficina
-- ============================================================
-- Impede que uma oferta seja criada ou alterada com uma categoria
-- que nao esteja ativa e vinculada oficialmente a sua oficina.

create or replace function public.enforce_workshop_offer_category()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1
    from public.workshop_categories wc
    join public.service_categories c on c.id = wc.category_id
    where wc.workshop_id = new.workshop_id
      and c.active = true
      and public.vr_category_key(coalesce(c.slug, c.name)) =
          public.vr_category_key(new.category)
  ) then
    raise exception
      'A categoria da oferta nao esta aprovada para esta oficina.'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_enforce_workshop_offer_category
  on public.workshop_offers;

create trigger trg_enforce_workshop_offer_category
before insert or update of workshop_id, category
on public.workshop_offers
for each row execute function public.enforce_workshop_offer_category();

-- Diagnostico opcional:
-- select w.name as oficina, c.name as categoria_aprovada
-- from public.workshops w
-- join public.workshop_categories wc on wc.workshop_id = w.id
-- join public.service_categories c on c.id = wc.category_id
-- where c.active = true
-- order by w.name, c.sort_order, c.name;
