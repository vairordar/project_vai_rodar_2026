-- ============================================================
-- Vai Rodar — Business Types, Parts & Marketplace
-- Migration: 20260615_business_types_parts_and_marketplace.sql
-- IDEMPOTENTE — seguro de re-ejecutar
-- ============================================================

-- ─── 1. Extender public.workshops ────────────────────────────

alter table public.workshops
  add column if not exists business_type          text        not null default 'workshop',
  add column if not exists parts_categories       text[]      not null default '{}',
  add column if not exists parts_delivery_enabled boolean     not null default false,
  add column if not exists parts_pickup_enabled   boolean     not null default true,
  add column if not exists parts_whatsapp         text,
  add column if not exists parts_notes            text;

do $$ begin
  alter table public.workshops
    add constraint workshops_business_type_check
    check (business_type in ('workshop','parts_store','both'));
exception when duplicate_object then null;
end $$;

-- ─── 2. Extender public.service_requests ─────────────────────

alter table public.service_requests
  add column if not exists request_type          text    not null default 'service',
  add column if not exists target_business_type  text    not null default 'workshop',
  add column if not exists part_name             text,
  add column if not exists part_specs            jsonb   not null default '{}'::jsonb,
  add column if not exists selected_business_ids uuid[]  not null default '{}';

do $$ begin
  alter table public.service_requests
    add constraint service_requests_request_type_check
    check (request_type in ('service','part_quote','car_sale','car_purchase','valuation'));
exception when duplicate_object then null;
end $$;

do $$ begin
  alter table public.service_requests
    add constraint service_requests_target_business_type_check
    check (target_business_type in ('workshop','parts_store','both'));
exception when duplicate_object then null;
end $$;

-- ─── 3. Tabla public.parts_quote_items ───────────────────────

create table if not exists public.parts_quote_items (
  id          uuid        primary key default gen_random_uuid(),
  request_id  uuid        not null references public.service_requests(id) on delete cascade,
  part_name   text        not null,
  quantity    integer     not null default 1,
  specs       jsonb       not null default '{}'::jsonb,
  notes       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint parts_quote_items_quantity_check check (quantity > 0)
);

alter table public.parts_quote_items enable row level security;

do $$ begin
  create policy "Usuario gerencia seus quote items"
    on public.parts_quote_items for all
    using (
      exists (
        select 1 from public.service_requests sr
        where sr.id = request_id
          and sr.user_id = auth.uid()
      )
    )
    with check (
      exists (
        select 1 from public.service_requests sr
        where sr.id = request_id
          and sr.user_id = auth.uid()
      )
    );
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Comercio ve items de solicitudes de piezas abertas"
    on public.parts_quote_items for select
    using (
      exists (
        select 1 from public.service_requests sr
        join public.workshops w on w.owner_id = auth.uid()
        where sr.id = request_id
          and sr.status = 'open'
          and sr.target_business_type in ('parts_store','both')
          and w.business_type in ('parts_store','both')
          and w.open = true
      )
    );
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Admin gerencia todos os quote items"
    on public.parts_quote_items for all
    using (public.is_admin())
    with check (public.is_admin());
exception when duplicate_object then null;
end $$;

do $$ begin
  create trigger trg_parts_quote_items_updated_at
    before update on public.parts_quote_items
    for each row execute function public.update_updated_at_column();
exception when duplicate_object then null;
end $$;

-- ─── 4. Tabla public.parts_inventory ─────────────────────────

create table if not exists public.parts_inventory (
  id          uuid          primary key default gen_random_uuid(),
  workshop_id uuid          not null references public.workshops(id) on delete cascade,
  part_name   text          not null,
  category    text,
  brand       text,
  sku         text,
  description text,
  price       numeric(12,2),
  available   boolean       not null default true,
  quantity    integer,
  image_url   text,
  created_at  timestamptz   not null default now(),
  updated_at  timestamptz   not null default now(),
  constraint parts_inventory_price_check check (price is null or price >= 0)
);

alter table public.parts_inventory enable row level security;

do $$ begin
  create policy "Comercio gerencia seu inventario"
    on public.parts_inventory for all
    using (
      exists (
        select 1 from public.workshops w
        where w.id = workshop_id and w.owner_id = auth.uid()
      )
    )
    with check (
      exists (
        select 1 from public.workshops w
        where w.id = workshop_id and w.owner_id = auth.uid()
      )
    );
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Publico ve inventario disponivel"
    on public.parts_inventory for select
    using (
      available = true
      and exists (
        select 1 from public.workshops w
        where w.id = workshop_id
          and w.open = true
          and w.visible = true
      )
    );
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Admin gerencia todo o inventario"
    on public.parts_inventory for all
    using (public.is_admin())
    with check (public.is_admin());
exception when duplicate_object then null;
end $$;

do $$ begin
  create trigger trg_parts_inventory_updated_at
    before update on public.parts_inventory
    for each row execute function public.update_updated_at_column();
exception when duplicate_object then null;
end $$;

-- ─── 5. Tabla public.vehicle_listings ────────────────────────

create table if not exists public.vehicle_listings (
  id           uuid          primary key default gen_random_uuid(),
  user_id      uuid          references auth.users(id) on delete cascade,
  vehicle_id   uuid          references public.vehicles(id) on delete set null,
  plate        text,
  brand        text,
  model        text,
  year         integer,
  color        text,
  mileage      integer,
  price        numeric(12,2),
  fipe_value   numeric(12,2),
  location     text,
  description  text,
  status       text          not null default 'draft',
  visibility   text          not null default 'free',
  created_at   timestamptz   not null default now(),
  updated_at   timestamptz   not null default now(),
  published_at timestamptz,
  expires_at   timestamptz,
  constraint vehicle_listings_status_check
    check (status in ('draft','pending_review','active','paused','sold','expired','rejected')),
  constraint vehicle_listings_visibility_check
    check (visibility in ('free','featured')),
  constraint vehicle_listings_year_check
    check (year is null or (year >= 1950 and year <= extract(year from now())::integer + 1)),
  constraint vehicle_listings_price_check
    check (price is null or price >= 0),
  constraint vehicle_listings_mileage_check
    check (mileage is null or mileage >= 0)
);

alter table public.vehicle_listings enable row level security;

do $$ begin
  create policy "Usuario gerencia seus anuncios"
    on public.vehicle_listings for all
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Publico ve anuncios ativos"
    on public.vehicle_listings for select
    using (status = 'active');
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Admin gerencia todos os anuncios"
    on public.vehicle_listings for all
    using (public.is_admin())
    with check (public.is_admin());
exception when duplicate_object then null;
end $$;

do $$ begin
  create trigger trg_vehicle_listings_updated_at
    before update on public.vehicle_listings
    for each row execute function public.update_updated_at_column();
exception when duplicate_object then null;
end $$;

-- ─── 6. Tabla public.vehicle_listing_photos ──────────────────

create table if not exists public.vehicle_listing_photos (
  id          uuid        primary key default gen_random_uuid(),
  listing_id  uuid        not null references public.vehicle_listings(id) on delete cascade,
  image_url   text        not null,
  sort_order  integer     not null default 0,
  created_at  timestamptz not null default now()
);

alter table public.vehicle_listing_photos enable row level security;

do $$ begin
  create policy "Dono do anuncio gerencia fotos"
    on public.vehicle_listing_photos for all
    using (
      exists (
        select 1 from public.vehicle_listings vl
        where vl.id = listing_id and vl.user_id = auth.uid()
      )
    )
    with check (
      exists (
        select 1 from public.vehicle_listings vl
        where vl.id = listing_id and vl.user_id = auth.uid()
      )
    );
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Publico ve fotos de anuncios ativos"
    on public.vehicle_listing_photos for select
    using (
      exists (
        select 1 from public.vehicle_listings vl
        where vl.id = listing_id and vl.status = 'active'
      )
    );
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Admin gerencia todas as fotos"
    on public.vehicle_listing_photos for all
    using (public.is_admin())
    with check (public.is_admin());
exception when duplicate_object then null;
end $$;

-- ─── 7. Tabla public.vehicle_listing_messages ────────────────

create table if not exists public.vehicle_listing_messages (
  id           uuid        primary key default gen_random_uuid(),
  listing_id   uuid        not null references public.vehicle_listings(id) on delete cascade,
  sender_id    uuid        references auth.users(id) on delete set null,
  recipient_id uuid        references auth.users(id) on delete set null,
  message      text        not null,
  message_type text        not null default 'message',
  created_at   timestamptz not null default now(),
  read_at      timestamptz,
  constraint vehicle_listing_messages_type_check
    check (message_type in ('message','offer'))
);

alter table public.vehicle_listing_messages enable row level security;

do $$ begin
  create policy "Participantes veem suas mensagens"
    on public.vehicle_listing_messages for select
    using (auth.uid() = sender_id or auth.uid() = recipient_id);
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Autenticado envia mensagem"
    on public.vehicle_listing_messages for insert
    with check (auth.uid() = sender_id and auth.role() = 'authenticated');
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Admin gerencia mensagens"
    on public.vehicle_listing_messages for all
    using (public.is_admin())
    with check (public.is_admin());
exception when duplicate_object then null;
end $$;

-- ─── 8. Verificar/completar public.workshop_offers ───────────

alter table public.workshop_offers
  add column if not exists clicks integer not null default 0,
  add column if not exists sales  integer not null default 0;

-- ─── 9. Vista: public_active_offers ──────────────────────────

create or replace view public.public_active_offers as
select
  wo.id          as offer_id,
  wo.workshop_id,
  w.name         as business_name,
  w.business_type,
  wo.category,
  wo.title,
  wo.description,
  wo.image_url,
  wo.starts_at,
  wo.ends_at,
  wo.clicks,
  wo.sales
from public.workshop_offers wo
join public.workshops w on w.id = wo.workshop_id
where wo.status = 'active'
  and wo.starts_at <= now()
  and wo.ends_at   >= now()
  and w.open   = true
  and w.visible = true
  and (w.approval_status is null or w.approval_status = 'approved');

-- ─── 10. Vista: public_workshops_search ──────────────────────

create or replace view public.public_workshops_search as
select
  w.id,
  w.name,
  w.business_type,
  w.city,
  w.address,
  w.neighborhood,
  w.category,
  w.services       as categories,
  w.parts_categories,
  w.open,
  w.visible,
  w.parts_delivery_enabled,
  w.parts_pickup_enabled
from public.workshops w
where w.open    = true
  and w.visible = true
  and w.business_type in ('workshop','both')
  and (w.approval_status is null or w.approval_status = 'approved')
  and (w.subscription_status is null or w.subscription_status in ('trial','active'));

-- ─── 11. Vista: public_parts_stores_search ───────────────────

create or replace view public.public_parts_stores_search as
select
  w.id,
  w.name,
  w.business_type,
  w.city,
  w.address,
  w.neighborhood,
  w.category,
  w.services       as categories,
  w.parts_categories,
  w.open,
  w.visible,
  w.parts_delivery_enabled,
  w.parts_pickup_enabled,
  w.parts_whatsapp
from public.workshops w
where w.open    = true
  and w.visible = true
  and w.business_type in ('parts_store','both')
  and (w.approval_status is null or w.approval_status = 'approved')
  and (w.subscription_status is null or w.subscription_status in ('trial','active'));

-- ─── 12. Extender constraint de analytics_events ─────────────
-- Agregar nuevos event_types sin romper los existentes

do $$ begin
  alter table public.analytics_events
    drop constraint if exists analytics_events_type_check;
  alter table public.analytics_events
    add constraint analytics_events_type_check
    check (event_type in (
      -- Originales
      'search',
      'chat_started',
      'chat_message',
      'plate_lookup',
      'service_request_created',
      'proposal_received',
      'proposal_accepted',
      'reservation_created',
      'workshop_profile_view',
      'offer_viewed',
      'offer_clicked',
      'workshop_register_started',
      'workshop_register_completed',
      -- Nuevos
      'search_workshop',
      'search_parts',
      'create_service_request',
      'create_parts_request',
      'view_offer',
      'click_offer',
      'create_vehicle_listing',
      'message_vehicle_seller',
      'parts_store_view',
      'parts_inventory_view'
    ));
exception when others then null;
end $$;

-- ─── 13. Índices ──────────────────────────────────────────────

create index if not exists workshops_business_type_idx
  on public.workshops(business_type);

create index if not exists workshops_open_visible_idx
  on public.workshops(open, visible);

create index if not exists service_requests_request_type_idx
  on public.service_requests(request_type);

create index if not exists service_requests_target_business_type_idx
  on public.service_requests(target_business_type);

create index if not exists parts_quote_items_request_id_idx
  on public.parts_quote_items(request_id);

create index if not exists parts_inventory_workshop_id_idx
  on public.parts_inventory(workshop_id);

create index if not exists parts_inventory_available_idx
  on public.parts_inventory(available) where available = true;

create index if not exists vehicle_listings_user_id_idx
  on public.vehicle_listings(user_id);

create index if not exists vehicle_listings_status_idx
  on public.vehicle_listings(status);

create index if not exists vehicle_listing_messages_listing_id_idx
  on public.vehicle_listing_messages(listing_id);

create index if not exists vehicle_listing_messages_sender_recipient_idx
  on public.vehicle_listing_messages(sender_id, recipient_id);

create index if not exists workshop_offers_status_dates_idx
  on public.workshop_offers(status, starts_at, ends_at);

-- ─── 14. Realtime (idempotente) ───────────────────────────────

do $$ begin
  alter publication supabase_realtime add table public.service_requests;
exception when duplicate_object then null;
end $$;

do $$ begin
  alter publication supabase_realtime add table public.parts_quote_items;
exception when duplicate_object then null;
end $$;

do $$ begin
  alter publication supabase_realtime add table public.vehicle_listings;
exception when duplicate_object then null;
end $$;

do $$ begin
  alter publication supabase_realtime add table public.vehicle_listing_messages;
exception when duplicate_object then null;
end $$;

do $$ begin
  alter publication supabase_realtime add table public.workshop_offers;
exception when duplicate_object then null;
end $$;

-- ─── FIN DE MIGRATION ─────────────────────────────────────────
--
-- REGLA DE NEGOCIO:
--   workshops.business_type = 'workshop'    → aparece solo en búsqueda de oficinas
--   workshops.business_type = 'parts_store' → aparece solo en búsqueda de piezas
--   workshops.business_type = 'both'        → aparece en ambas búsquedas
--
-- COMPATIBILIDAD CON FRONTEND ACTUAL:
--   ✓ user-app puede seguir insertando en service_requests (request_type default='service')
--   ✓ workshop-app puede seguir leyendo service_requests sin cambios
--   ✓ workshop_offers sigue funcionando (solo se agregaron clicks/sales si faltaban)
--   ✓ Registro actual de oficinas no se rompe (business_type default='workshop')
--   ✓ No se modificó ningún archivo HTML/JS
--
-- PRÓXIMOS PASOS (frontend):
--   1. Cadastro: agregar selector de business_type
--   2. User-app: solicitudes de piezas solo a parts_store/both
--   3. Backoffice: secciones condicionales por business_type
--   4. Marketplace: conectar vehicle_listings al user-app
-- ─────────────────────────────────────────────────────────────
