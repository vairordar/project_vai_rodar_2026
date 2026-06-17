-- ============================================================
-- Vai Rodar — OAuth metadata, Ubicación real, Marketplace mensajería,
-- Vista admin de usuarios
-- Migration: 20260616_oauth_location_marketplace_admin.sql
-- IDEMPOTENTE — seguro de re-ejecutar
-- ============================================================

-- ─── 1. handle_new_user robusto para login social (Google/Apple) ─
-- Google entrega: name, full_name, picture, avatar_url
-- Apple entrega:  email (a veces relay), name solo en el primer login
-- Se agrega columna avatar_url si no existe y se mejora el trigger.

alter table public.profiles
  add column if not exists avatar_url text;

-- (la columna avatar_url puede ya existir; el add column if not exists es seguro)

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, name, email, avatar_url, role)
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data->>'name',
      new.raw_user_meta_data->>'full_name',
      new.raw_user_meta_data->>'given_name',
      split_part(new.email, '@', 1),
      'Usuario'
    ),
    new.email,
    coalesce(
      new.raw_user_meta_data->>'avatar_url',
      new.raw_user_meta_data->>'picture'
    ),
    'motorist'
  )
  on conflict (id) do update
    set email = coalesce(excluded.email, public.profiles.email),
        avatar_url = coalesce(public.profiles.avatar_url, excluded.avatar_url);
  return new;
end;
$$;

do $$ begin
  if not exists (
    select 1 from pg_trigger where tgname = 'on_auth_user_created'
  ) then
    create trigger on_auth_user_created
      after insert on auth.users
      for each row execute function public.handle_new_user();
  end if;
end $$;

-- ─── 2. Ubicación real: lat/lng en service_requests ───────────

alter table public.service_requests
  add column if not exists latitude  double precision,
  add column if not exists longitude double precision,
  add column if not exists address   text;

do $$ begin
  alter table public.service_requests
    add constraint service_requests_lat_check check (latitude  is null or (latitude  between -90  and 90));
exception when duplicate_object then null;
end $$;

do $$ begin
  alter table public.service_requests
    add constraint service_requests_lng_check check (longitude is null or (longitude between -180 and 180));
exception when duplicate_object then null;
end $$;

-- ─── 3. Ubicación real: lat/lng en vehicle_listings ───────────

alter table public.vehicle_listings
  add column if not exists latitude  double precision,
  add column if not exists longitude double precision,
  add column if not exists address   text;

do $$ begin
  alter table public.vehicle_listings
    add constraint vehicle_listings_lat_check check (latitude  is null or (latitude  between -90  and 90));
exception when duplicate_object then null;
end $$;

do $$ begin
  alter table public.vehicle_listings
    add constraint vehicle_listings_lng_check check (longitude is null or (longitude between -180 and 180));
exception when duplicate_object then null;
end $$;

-- ─── 4. workshops ya tiene latitude/longitude (admin_backoffice_data_model.sql) ─
-- Se agrega 'address' solo si faltara (no se toca si ya existe).

alter table public.workshops
  add column if not exists address_full text;

-- ─── 5. Marketplace: ofertas con precio en vehicle_listing_messages ─
-- La tabla ya existe (creada en 20260615_business_types_parts_and_marketplace.sql)
-- con message_type in ('message','offer'). Se agrega offer_price para
-- soportar "enviar propuesta con precio".

alter table public.vehicle_listing_messages
  add column if not exists offer_price numeric(12,2);

do $$ begin
  alter table public.vehicle_listing_messages
    add constraint vehicle_listing_messages_offer_price_check
    check (offer_price is null or offer_price >= 0);
exception when duplicate_object then null;
end $$;

do $$ begin
  alter table public.vehicle_listing_messages
    add constraint vehicle_listing_messages_offer_requires_price
    check (message_type <> 'offer' or offer_price is not null);
exception when duplicate_object then null;
end $$;

-- ─── 6. Función: marcar conversación de vehículo como leída ──

create or replace function public.mark_vehicle_conversation_read(
  p_listing_id uuid,
  p_other_user_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'No autenticado';
  end if;

  update public.vehicle_listing_messages
  set read_at = now()
  where listing_id = p_listing_id
    and recipient_id = auth.uid()
    and sender_id = p_other_user_id
    and read_at is null;
end;
$$;

grant execute on function public.mark_vehicle_conversation_read(uuid, uuid) to authenticated;

-- ─── 7. Vista: conversaciones de vehículos (resumen) ──────────

create or replace view public.vehicle_conversations_overview as
select
  vl.id                                                as listing_id,
  vl.brand,
  vl.model,
  vl.year,
  vl.price,
  vl.user_id                                            as seller_id,
  m.other_user_id,
  max(m.created_at)                                     as last_message_at,
  count(*) filter (where m.read_at is null and m.recipient_id = auth.uid()) as unread_count
from public.vehicle_listings vl
join lateral (
  select
    case when vlm.sender_id = auth.uid() then vlm.recipient_id else vlm.sender_id end as other_user_id,
    vlm.created_at,
    vlm.read_at,
    vlm.recipient_id
  from public.vehicle_listing_messages vlm
  where vlm.listing_id = vl.id
    and (vlm.sender_id = auth.uid() or vlm.recipient_id = auth.uid())
) m on true
group by vl.id, vl.brand, vl.model, vl.year, vl.price, vl.user_id, m.other_user_id;

alter view public.vehicle_conversations_overview set (security_invoker = on);

-- ─── 8. Vista + función: admin_users_overview (solo admin) ───
-- La vista accede a auth.users (correo, fecha registro, last_sign_in_at),
-- por lo que NO debe ser security_invoker. Se expone únicamente a través
-- de la función admin_list_users(), que verifica is_admin().

create or replace view public.admin_users_overview as
select
  p.id,
  p.name,
  p.email,
  p.phone,
  p.role::text                                   as role,
  p.created_at                                    as registered_at,
  u.last_sign_in_at,
  coalesce(v.vehicle_count, 0)                    as vehicle_count,
  coalesce(sr.request_count, 0)                   as request_count,
  coalesce(vl.listing_count, 0)                   as listing_count
from public.profiles p
left join auth.users u on u.id = p.id
left join (
  select user_id, count(*) as vehicle_count
  from public.vehicles
  group by user_id
) v on v.user_id = p.id
left join (
  select user_id, count(*) as request_count
  from public.service_requests
  group by user_id
) sr on sr.user_id = p.id
left join (
  select user_id, count(*) as listing_count
  from public.vehicle_listings
  group by user_id
) vl on vl.user_id = p.id;

revoke all on public.admin_users_overview from public, anon, authenticated;

create or replace function public.admin_list_users()
returns setof public.admin_users_overview
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Acceso restringido a administradores';
  end if;
  return query select * from public.admin_users_overview order by registered_at desc;
end;
$$;

grant execute on function public.admin_list_users() to authenticated;

-- ─── 9. workshop_offers: confirmar columnas (ya existentes) ──
-- image_url, category, starts_at, ends_at, status, clicks, sales
-- ya fueron creadas en 20260614_workshop_backoffice_complete.sql.
-- Se agrega solo un índice de soporte si faltara.

create index if not exists workshop_offers_category_idx
  on public.workshop_offers(category);

-- ─── 10. Índices de ubicación ──────────────────────────────────

create index if not exists service_requests_lat_lng_idx
  on public.service_requests(latitude, longitude);

create index if not exists vehicle_listings_lat_lng_idx
  on public.vehicle_listings(latitude, longitude);

-- ─── FIN DE MIGRATION ─────────────────────────────────────────
--
-- NOTAS PARA CODEX (frontend, no incluido en esta migration):
--
-- 1. Login social:
--    - Activar Google/Apple en Supabase Dashboard (ver documento adjunto).
--    - No requiere cambios de schema adicionales: el trigger handle_new_user
--      ya soporta los metadatos que Google/Apple envían.
--
-- 2. Ubicación:
--    - Frontend debe llamar navigator.geolocation.getCurrentPosition()
--    - Luego POST a /.netlify/functions/geocode con {lat,lng}
--    - Guardar latitude, longitude, address en service_requests,
--      vehicle_listings y workshops (estas últimas dos ya tenían
--      latitude/longitude desde antes).
--
-- 3. Marketplace:
--    - Insertar en vehicle_listing_messages con message_type='offer'
--      y offer_price para enviar una propuesta.
--    - Llamar rpc('mark_vehicle_conversation_read', {p_listing_id, p_other_user_id})
--      para marcar como leído.
--    - Usar vehicle_conversations_overview para listar conversaciones.
--
-- 4. Admin usuarios:
--    - Llamar rpc('admin_list_users') desde el backoffice admin.
--      Lanza excepción si el usuario no es admin.
-- ─────────────────────────────────────────────────────────────
