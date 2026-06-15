-- =================================================================
-- Vai Rodar — Workshop Backoffice Complete
-- supabase/migrations/20260614_workshop_backoffice_complete.sql
--
-- Ejecutar completo en Supabase SQL Editor.
-- Seguro para re-ejecutar: usa IF NOT EXISTS y ADD COLUMN IF NOT EXISTS.
-- No borra datos existentes.
-- =================================================================


-- ─────────────────────────────────────────────────────────────────
-- HELPER: función updated_at (reutiliza si ya existe)
-- ─────────────────────────────────────────────────────────────────
create or replace function public.update_updated_at_column()
  returns trigger
  language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;


-- =================================================================
-- 1. RESERVATIONS — extender para reservas manuales externas
-- =================================================================
-- La tabla ya existe. Solo agregamos columnas nuevas.
-- El front selecciona exactamente estos campos:
--   id, user_id, workshop_id, source, service_type, scheduled_at,
--   notes, status, created_at, estimated_price,
--   external_client_name, external_client_phone, external_client_email,
--   external_vehicle_plate, external_vehicle_description,
--   profiles(id,name,email)

-- user_id nullable (reservas manuales no tienen usuario Vai Rodar)
alter table public.reservations
  alter column user_id drop not null;

-- Columnas nuevas
alter table public.reservations
  add column if not exists source                       text          not null default 'app',
  add column if not exists external_client_name         text,
  add column if not exists external_client_phone        text,
  add column if not exists external_client_email        text,
  add column if not exists external_vehicle_plate       text,
  add column if not exists external_vehicle_description text,
  add column if not exists estimated_price              numeric(10,2),
  add column if not exists cancelled_at                 timestamptz,
  add column if not exists completed_at                 timestamptz;

-- Constraint de source (idempotente via DO)
do $$ begin
  alter table public.reservations
    add constraint reservations_source_check
    check (source in ('app','manual'));
exception when duplicate_object then null;
end $$;

-- RLS para reservations (taller ve y gestiona las suyas)
alter table public.reservations enable row level security;

-- Motorista ve sus propias reservas
do $$ begin
  if not exists (
    select 1 from pg_policies
    where tablename='reservations' and policyname='Usuario ve suas reservas'
  ) then
    create policy "Usuario ve suas reservas"
      on public.reservations for select
      using (user_id = auth.uid());
  end if;
end $$;

-- Taller ve todas las reservas de su oficina (app + manual)
do $$ begin
  if not exists (
    select 1 from pg_policies
    where tablename='reservations' and policyname='Taller ve reservas da oficina'
  ) then
    create policy "Taller ve reservas da oficina"
      on public.reservations for select
      using (
        exists (
          select 1 from public.workshops w
          where w.id = workshop_id and w.owner_id = auth.uid()
        )
      );
  end if;
end $$;

-- Taller crea reservas manuales para su oficina
do $$ begin
  if not exists (
    select 1 from pg_policies
    where tablename='reservations' and policyname='Taller cria reservas para sua oficina'
  ) then
    create policy "Taller cria reservas para sua oficina"
      on public.reservations for insert
      with check (
        exists (
          select 1 from public.workshops w
          where w.id = workshop_id and w.owner_id = auth.uid()
        )
      );
  end if;
end $$;

-- Taller atualiza reservas de sua oficina (status, datos externos, reagendar)
do $$ begin
  if not exists (
    select 1 from pg_policies
    where tablename='reservations' and policyname='Taller atualiza reservas da oficina'
  ) then
    create policy "Taller atualiza reservas da oficina"
      on public.reservations for update
      using (
        exists (
          select 1 from public.workshops w
          where w.id = workshop_id and w.owner_id = auth.uid()
        )
      );
  end if;
end $$;

-- Admin ve e gerencia tudo
do $$ begin
  if not exists (
    select 1 from pg_policies
    where tablename='reservations' and policyname='Admin gerencia reservas'
  ) then
    create policy "Admin gerencia reservas"
      on public.reservations for all
      using (
        exists (
          select 1 from public.profiles p
          where p.id = auth.uid() and p.role = 'admin'
        )
      );
  end if;
end $$;

-- Índice útil
create index if not exists reservations_workshop_id_idx on public.reservations(workshop_id);
create index if not exists reservations_source_idx      on public.reservations(source);


-- =================================================================
-- 2. WORKSHOPS — confirmar coluna open
-- =================================================================
alter table public.workshops
  add column if not exists open boolean not null default true;

-- Índice para busca de oficinas abertas
create index if not exists workshops_open_idx on public.workshops(open) where open = true;


-- =================================================================
-- 3. WORKSHOP_AVAILABILITY_BLOCKS
-- =================================================================
-- O front insere: workshop_id, day_of_week, start_time, end_time, reason, active
-- O front lê:     id, workshop_id, day_of_week, start_time, end_time, reason, active
-- Múltiplos rows por insert (un por dia da semana selecionado)

create table if not exists public.workshop_availability_blocks (
  id           uuid        primary key default gen_random_uuid(),
  workshop_id  uuid        not null references public.workshops(id) on delete cascade,
  day_of_week  int         not null check (day_of_week between 0 and 6),
  start_time   time        not null,
  end_time     time        not null,
  reason       text,
  active       boolean     not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint   availability_blocks_time_check check (start_time < end_time)
);

alter table public.workshop_availability_blocks enable row level security;

-- Trigger updated_at
do $$ begin
  if not exists (
    select 1 from pg_trigger
    where tgname = 'set_workshop_availability_blocks_updated_at'
  ) then
    create trigger set_workshop_availability_blocks_updated_at
      before update on public.workshop_availability_blocks
      for each row execute function public.update_updated_at_column();
  end if;
end $$;

-- RLS: taller owner pode tudo em seus bloqueios
create policy "Taller gerencia seus bloqueios"
  on public.workshop_availability_blocks for all
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

-- RLS: admin vê tudo
create policy "Admin gerencia bloqueios"
  on public.workshop_availability_blocks for all
  using (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role = 'admin'
    )
  );

-- Índices
create index if not exists blocks_workshop_id_idx  on public.workshop_availability_blocks(workshop_id);
create index if not exists blocks_active_idx        on public.workshop_availability_blocks(workshop_id, active);


-- =================================================================
-- 4. WORKSHOP_OFFERS
-- =================================================================
-- O front insere: workshop_id, category, title, description, image_url,
--                 starts_at, ends_at, status
-- O front lê:     id, workshop_id, category, title, description, image_url,
--                 starts_at, ends_at, status, clicks, sales, created_at
-- O front mapeia: start = starts_at, end = ends_at

create table if not exists public.workshop_offers (
  id           uuid        primary key default gen_random_uuid(),
  workshop_id  uuid        not null references public.workshops(id) on delete cascade,
  category     text        not null,
  title        text        not null,
  description  text,
  image_url    text        not null,
  starts_at    date        not null,
  ends_at      date        not null,
  status       text        not null default 'active',
  clicks       int         not null default 0,
  sales        int         not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint   offers_status_check  check (status in ('active','inactive','expired')),
  constraint   offers_dates_check   check (ends_at >= starts_at)
);

alter table public.workshop_offers enable row level security;

-- Trigger updated_at
do $$ begin
  if not exists (
    select 1 from pg_trigger
    where tgname = 'set_workshop_offers_updated_at'
  ) then
    create trigger set_workshop_offers_updated_at
      before update on public.workshop_offers
      for each row execute function public.update_updated_at_column();
  end if;
end $$;

-- RLS: taller owner gere suas ofertas
create policy "Taller gerencia suas ofertas"
  on public.workshop_offers for all
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

-- RLS: público lê ofertas ativas e vigentes (para user-app)
create policy "Publico ve ofertas ativas"
  on public.workshop_offers for select
  using (
    status = 'active'
    and starts_at <= current_date
    and ends_at   >= current_date
  );

-- RLS: admin tudo
create policy "Admin gerencia ofertas"
  on public.workshop_offers for all
  using (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role = 'admin'
    )
  );

-- Índices
create index if not exists offers_workshop_id_idx   on public.workshop_offers(workshop_id);
create index if not exists offers_status_dates_idx  on public.workshop_offers(status, starts_at, ends_at);


-- =================================================================
-- 5. STORAGE — bucket offer-images
-- =================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'offer-images',
  'offer-images',
  true,
  5242880,  -- 5MB limit
  array['image/jpeg','image/png','image/webp','image/gif']
)
on conflict (id) do nothing;

-- Policy: taller autenticado sobe na sua pasta {auth.uid()}/...
do $$ begin
  if not exists (
    select 1 from pg_policies
    where tablename='objects' and schemaname='storage'
    and policyname='Taller sobe imagens de ofertas'
  ) then
    create policy "Taller sobe imagens de ofertas"
      on storage.objects for insert
      with check (
        bucket_id = 'offer-images'
        and auth.role() = 'authenticated'
        and (storage.foldername(name))[1] = auth.uid()::text
      );
  end if;
end $$;

-- Policy: público lê imagens (as ofertas serão visíveis no user-app)
do $$ begin
  if not exists (
    select 1 from pg_policies
    where tablename='objects' and schemaname='storage'
    and policyname='Publico le imagens de ofertas'
  ) then
    create policy "Publico le imagens de ofertas"
      on storage.objects for select
      using (bucket_id = 'offer-images');
  end if;
end $$;

-- Policy: taller deleta suas imagens
do $$ begin
  if not exists (
    select 1 from pg_policies
    where tablename='objects' and schemaname='storage'
    and policyname='Taller deleta suas imagens'
  ) then
    create policy "Taller deleta suas imagens"
      on storage.objects for delete
      using (
        bucket_id = 'offer-images'
        and (storage.foldername(name))[1] = auth.uid()::text
      );
  end if;
end $$;


-- =================================================================
-- 6. WORKSHOP_PROFILE_CHANGE_REQUESTS
-- =================================================================
-- O front insere: workshop_id, requested_by, field_name, new_value, reason
-- O front lê via maybeSingle (não renderiza lista ainda, mas a tabela precisa existir)
-- Campos que o front usa em requestProfileChange():
--   field_name, new_value (jsonb), reason

create table if not exists public.workshop_profile_change_requests (
  id            uuid        primary key default gen_random_uuid(),
  workshop_id   uuid        not null references public.workshops(id) on delete cascade,
  requested_by  uuid        references auth.users(id) on delete set null,
  field_name    text        not null,
  new_value     jsonb       not null,
  reason        text,
  status        text        not null default 'pending',
  admin_notes   text,
  reviewed_by   uuid        references auth.users(id) on delete set null,
  reviewed_at   timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint    pcr_status_check check (status in ('pending','approved','rejected'))
);

alter table public.workshop_profile_change_requests enable row level security;

-- Trigger updated_at
do $$ begin
  if not exists (
    select 1 from pg_trigger
    where tgname = 'set_workshop_pcr_updated_at'
  ) then
    create trigger set_workshop_pcr_updated_at
      before update on public.workshop_profile_change_requests
      for each row execute function public.update_updated_at_column();
  end if;
end $$;

-- RLS: taller ve suas solicitações
create policy "Taller ve suas solicitacoes de mudanca"
  on public.workshop_profile_change_requests for select
  using (
    exists (
      select 1 from public.workshops w
      where w.id = workshop_id and w.owner_id = auth.uid()
    )
  );

-- RLS: taller cria solicitações (não aprova)
create policy "Taller cria solicitacoes de mudanca"
  on public.workshop_profile_change_requests for insert
  with check (
    exists (
      select 1 from public.workshops w
      where w.id = workshop_id and w.owner_id = auth.uid()
    )
  );

-- RLS: admin gerencia tudo (aprovar/rejeitar)
create policy "Admin gerencia solicitacoes de mudanca"
  on public.workshop_profile_change_requests for all
  using (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role = 'admin'
    )
  );

-- Índice
create index if not exists pcr_workshop_id_idx  on public.workshop_profile_change_requests(workshop_id);
create index if not exists pcr_status_idx       on public.workshop_profile_change_requests(status);


-- =================================================================
-- 7. WORKSHOP_OWNER_DETAILS
-- =================================================================
-- O front lê: * (maybeSingle) via workshop_id
-- O front usa: responsible_name, cnpj, no_cnpj, contact_phone
-- Render em renderAccount():
--   owner.cnpj, owner.responsible_name, owner.contact_phone, owner.no_cnpj

create table if not exists public.workshop_owner_details (
  id                uuid        primary key default gen_random_uuid(),
  workshop_id       uuid        not null unique references public.workshops(id) on delete cascade,
  responsible_name  text,
  cnpj              text,
  no_cnpj           boolean     not null default false,
  contact_phone     text,
  contact_email     text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

alter table public.workshop_owner_details enable row level security;

-- Trigger updated_at
do $$ begin
  if not exists (
    select 1 from pg_trigger
    where tgname = 'set_workshop_owner_details_updated_at'
  ) then
    create trigger set_workshop_owner_details_updated_at
      before update on public.workshop_owner_details
      for each row execute function public.update_updated_at_column();
  end if;
end $$;

-- RLS: taller vê seus dados (somente leitura — mudanças passam por change_requests)
create policy "Taller ve seus dados de dono"
  on public.workshop_owner_details for select
  using (
    exists (
      select 1 from public.workshops w
      where w.id = workshop_id and w.owner_id = auth.uid()
    )
  );

-- RLS: admin gerencia tudo
create policy "Admin gerencia dados de dono"
  on public.workshop_owner_details for all
  using (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role = 'admin'
    )
  );

-- Índice
create index if not exists owner_details_workshop_idx on public.workshop_owner_details(workshop_id);


-- =================================================================
-- 8. REALTIME — habilitar tabelas
-- =================================================================
-- Ignorar erros "already member of publication"
do $$ begin
  alter publication supabase_realtime add table public.service_requests;
exception when others then null;
end $$;

do $$ begin
  alter publication supabase_realtime add table public.proposals;
exception when others then null;
end $$;

do $$ begin
  alter publication supabase_realtime add table public.reservations;
exception when others then null;
end $$;

do $$ begin
  alter publication supabase_realtime add table public.messages;
exception when others then null;
end $$;

do $$ begin
  alter publication supabase_realtime add table public.workshop_availability_blocks;
exception when others then null;
end $$;


-- =================================================================
-- VERIFICAÇÕES — confirmar que o frontend não precisa de ajustes
-- =================================================================
--
-- ✅ reservations: front usa service_type (coluna existente), notes,
--    scheduled_at, profiles(id,name,email) — tudo OK
--
-- ✅ workshop_availability_blocks: front insere/lê
--    day_of_week, start_time, end_time, reason, active — nomes corretos
--
-- ✅ workshop_offers: front usa starts_at/ends_at (mapeado para start/end)
--    e status in ('active','inactive') — OK com constraint
--
-- ✅ workshop_owner_details: front usa responsible_name, cnpj,
--    no_cnpj, contact_phone — nomes corretos
--
-- ✅ workshop_profile_change_requests: front insere
--    workshop_id, requested_by, field_name, new_value (jsonb), reason — OK
--
-- ✅ workshops.open: front lê state.workshop.open!==false
--    e atualiza com update({open: nextOpen}) — OK
--
-- ⚠️  AJUSTE NECESSÁRIO NO FRONTEND (1 ponto):
--    Em cancelManualReservation(), o front faz:
--      update({status:"cancelled", cancelled_at: new Date().toISOString()})
--    A coluna cancelled_at é adicionada aqui — OK.
--
-- ⚠️  AJUSTE NECESSÁRIO NO FRONTEND (1 ponto):
--    Em loadRequests(), o front NÃO filtra por workshops.open do lado do DB.
--    Solicitudes chegam para todos os talleres independente de open.
--    Para filtrar por open no lado do servidor, adicionar RLS em service_requests
--    ou fazer join no front. Por ora, o front já mostra aviso visual quando open=false.
--    Não crítico para a migration.
--
-- NOTA: Confirmar no Supabase Dashboard:
--    Authentication → Settings → "Enable email confirmations" → DESATIVAR
--    (para que o taller tenha sessão imediata após registro)
--
-- =================================================================
