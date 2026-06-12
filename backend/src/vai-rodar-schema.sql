-- ============================================================
-- vai-rodar-schema.sql
-- Schema completo do Supabase para o projeto Vai Rodar 2026
-- Execute no SQL Editor do Supabase
-- ============================================================

-- ─── Extensions ─────────────────────────────────────────────
create extension if not exists "uuid-ossp";
create extension if not exists "pg_trgm"; -- busca textual eficiente

-- ─── Enum types ──────────────────────────────────────────────
create type user_role          as enum ('motorist', 'workshop', 'admin');
create type request_status     as enum ('open', 'in_progress', 'closed', 'expired');
create type proposal_status    as enum ('pending', 'accepted', 'declined', 'expired');
create type reservation_status as enum ('pending', 'confirmed', 'completed', 'cancelled');
create type notification_type  as enum ('quote', 'message', 'system', 'promo');

-- ============================================================
-- TABELAS
-- ============================================================

-- ─── Profiles (extensão da auth.users do Supabase) ───────────
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  name        text not null,
  email       text,
  phone       text,
  avatar_url  text,
  role        user_role not null default 'motorist',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ─── Vehicles (veículos do motorista) ────────────────────────
create table if not exists public.vehicles (
  id          uuid primary key default uuid_generate_v4(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  plate       text not null,
  brand       text not null,
  model       text not null,
  year        integer,
  color       text,
  created_at  timestamptz not null default now()
);

create index if not exists vehicles_user_id_idx on public.vehicles(user_id);

-- ─── Workshops ───────────────────────────────────────────────
create table if not exists public.workshops (
  id              uuid primary key default uuid_generate_v4(),
  owner_id        uuid references public.profiles(id),
  name            text not null,
  description     text,
  category        text,              -- ex: "Pneus e alinhamento"
  address         text,
  city            text,
  state           text,
  zip_code        text,
  phone           text,
  whatsapp        text,
  email           text,
  website         text,
  photo_url       text,
  rating          numeric(3,2) default 0,
  review_count    integer default 0,
  open            boolean default true,
  verified        boolean default false,
  services        text[],            -- ex: ARRAY['Pneus','Alinhamento']
  schedule        jsonb,             -- horários por dia da semana
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index if not exists workshops_city_idx       on public.workshops(city);
create index if not exists workshops_category_idx   on public.workshops(category);
create index if not exists workshops_rating_idx     on public.workshops(rating desc);
create index if not exists workshops_name_trgm_idx  on public.workshops using gin(name gin_trgm_ops);

-- ─── Service Requests (cotações do motorista) ────────────────
create table if not exists public.service_requests (
  id          uuid primary key default uuid_generate_v4(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  vehicle_id  uuid references public.vehicles(id),
  title       text not null,
  description text,
  category    text,
  location    text,
  image_url   text,
  status      request_status not null default 'open',
  expires_at  timestamptz default (now() + interval '7 days'),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists service_requests_user_id_idx  on public.service_requests(user_id);
create index if not exists service_requests_status_idx   on public.service_requests(status);

-- ─── Proposals (respostas das oficinas) ──────────────────────
create table if not exists public.proposals (
  id              uuid primary key default uuid_generate_v4(),
  request_id      uuid not null references public.service_requests(id) on delete cascade,
  workshop_id     uuid not null references public.workshops(id),
  price           numeric(10,2),
  estimated_time  text,              -- ex: "2 horas"
  message         text,
  status          proposal_status not null default 'pending',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index if not exists proposals_request_id_idx  on public.proposals(request_id);
create index if not exists proposals_workshop_id_idx on public.proposals(workshop_id);

-- ─── Conversations ───────────────────────────────────────────
create table if not exists public.conversations (
  id           uuid primary key default uuid_generate_v4(),
  user_id      uuid not null references public.profiles(id) on delete cascade,
  workshop_id  uuid not null references public.workshops(id) on delete cascade,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique(user_id, workshop_id)
);

create index if not exists conversations_user_idx     on public.conversations(user_id);
create index if not exists conversations_workshop_idx on public.conversations(workshop_id);

-- ─── Messages ────────────────────────────────────────────────
create table if not exists public.messages (
  id               uuid primary key default uuid_generate_v4(),
  conversation_id  uuid not null references public.conversations(id) on delete cascade,
  sender_id        uuid not null references public.profiles(id),
  text             text,
  image_url        text,
  read             boolean default false,
  created_at       timestamptz not null default now()
);

create index if not exists messages_conversation_idx on public.messages(conversation_id);
create index if not exists messages_sender_idx       on public.messages(sender_id);

-- ─── Reservations ────────────────────────────────────────────
create table if not exists public.reservations (
  id            uuid primary key default uuid_generate_v4(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  workshop_id   uuid not null references public.workshops(id),
  service_type  text,
  scheduled_at  timestamptz not null,
  notes         text,
  status        reservation_status not null default 'pending',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists reservations_user_idx     on public.reservations(user_id);
create index if not exists reservations_workshop_idx on public.reservations(workshop_id);
create index if not exists reservations_date_idx     on public.reservations(scheduled_at);

-- ─── Notifications ───────────────────────────────────────────
create table if not exists public.notifications (
  id          uuid primary key default uuid_generate_v4(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  type        notification_type not null default 'system',
  title       text not null,
  detail      text,
  read        boolean default false,
  link        text,
  created_at  timestamptz not null default now()
);

create index if not exists notifications_user_idx  on public.notifications(user_id);
create index if not exists notifications_read_idx  on public.notifications(read);

-- ============================================================
-- TRIGGERS — updated_at automático
-- ============================================================
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger trg_profiles_updated_at
  before update on public.profiles
  for each row execute procedure public.set_updated_at();

create trigger trg_workshops_updated_at
  before update on public.workshops
  for each row execute procedure public.set_updated_at();

create trigger trg_service_requests_updated_at
  before update on public.service_requests
  for each row execute procedure public.set_updated_at();

create trigger trg_proposals_updated_at
  before update on public.proposals
  for each row execute procedure public.set_updated_at();

create trigger trg_conversations_updated_at
  before update on public.conversations
  for each row execute procedure public.set_updated_at();

create trigger trg_reservations_updated_at
  before update on public.reservations
  for each row execute procedure public.set_updated_at();

-- ─── Trigger: novo profile ao registrar user ─────────────────
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, name, email, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'name', split_part(new.email,'@',1)),
    new.email,
    coalesce((new.raw_user_meta_data->>'role')::user_role, 'motorist')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ─── Trigger: atualiza conversations.updated_at ao enviar mensagem ─
create or replace function public.update_conversation_on_message()
returns trigger language plpgsql as $$
begin
  update public.conversations
    set updated_at = now()
    where id = new.conversation_id;
  return new;
end;
$$;

create trigger trg_message_updates_conversation
  after insert on public.messages
  for each row execute procedure public.update_conversation_on_message();

-- ============================================================
-- ROW LEVEL SECURITY (RLS)
-- ============================================================
alter table public.profiles      enable row level security;
alter table public.vehicles      enable row level security;
alter table public.workshops     enable row level security;
alter table public.service_requests enable row level security;
alter table public.proposals     enable row level security;
alter table public.conversations enable row level security;
alter table public.messages      enable row level security;
alter table public.reservations  enable row level security;
alter table public.notifications enable row level security;

-- ─── Profiles ────────────────────────────────────────────────
create policy "Perfil visível para todos autenticados"
  on public.profiles for select using (auth.role() = 'authenticated');

create policy "Usuário atualiza próprio perfil"
  on public.profiles for update using (auth.uid() = id);

-- ─── Vehicles ────────────────────────────────────────────────
create policy "Motorista vê seus veículos"
  on public.vehicles for select using (auth.uid() = user_id);

create policy "Motorista gerencia seus veículos"
  on public.vehicles for all using (auth.uid() = user_id);

-- ─── Workshops ───────────────────────────────────────────────
create policy "Oficinas visíveis para todos"
  on public.workshops for select using (true);

create policy "Dono da oficina atualiza"
  on public.workshops for update using (auth.uid() = owner_id);

create policy "Usuário autenticado cadastra oficina"
  on public.workshops for insert with check (auth.role() = 'authenticated');

-- ─── Service Requests ────────────────────────────────────────
create policy "Motorista vê suas solicitações"
  on public.service_requests for select using (auth.uid() = user_id);

create policy "Oficinas veem solicitações abertas"
  on public.service_requests for select using (status = 'open');

create policy "Motorista cria solicitações"
  on public.service_requests for insert with check (auth.uid() = user_id);

create policy "Motorista atualiza suas solicitações"
  on public.service_requests for update using (auth.uid() = user_id);

-- ─── Proposals ───────────────────────────────────────────────
create policy "Motorista vê propostas das suas solicitações"
  on public.proposals for select
  using (
    exists (
      select 1 from public.service_requests r
      where r.id = request_id and r.user_id = auth.uid()
    )
  );

create policy "Oficina vê suas propostas"
  on public.proposals for select
  using (
    exists (
      select 1 from public.workshops w
      where w.id = workshop_id and w.owner_id = auth.uid()
    )
  );

create policy "Oficina envia proposta"
  on public.proposals for insert with check (auth.role() = 'authenticated');

create policy "Oficina/motorista atualiza proposta"
  on public.proposals for update using (auth.role() = 'authenticated');

-- ─── Conversations ───────────────────────────────────────────
create policy "Partes veem sua conversa"
  on public.conversations for select
  using (
    auth.uid() = user_id or
    exists (select 1 from public.workshops w where w.id = workshop_id and w.owner_id = auth.uid())
  );

create policy "Criar conversa autenticado"
  on public.conversations for insert with check (auth.role() = 'authenticated');

-- ─── Messages ────────────────────────────────────────────────
create policy "Partes veem mensagens da sua conversa"
  on public.messages for select
  using (
    exists (
      select 1 from public.conversations c
      where c.id = conversation_id
        and (c.user_id = auth.uid() or
             exists (select 1 from public.workshops w where w.id = c.workshop_id and w.owner_id = auth.uid()))
    )
  );

create policy "Envia mensagem autenticado"
  on public.messages for insert with check (auth.uid() = sender_id);

-- ─── Reservations ────────────────────────────────────────────
create policy "Motorista vê suas reservas"
  on public.reservations for select using (auth.uid() = user_id);

create policy "Oficina vê reservas do dia"
  on public.reservations for select
  using (
    exists (select 1 from public.workshops w where w.id = workshop_id and w.owner_id = auth.uid())
  );

create policy "Motorista cria reserva"
  on public.reservations for insert with check (auth.uid() = user_id);

create policy "Partes atualizam reserva"
  on public.reservations for update using (auth.role() = 'authenticated');

-- ─── Notifications ───────────────────────────────────────────
create policy "Usuário vê suas notificações"
  on public.notifications for select using (auth.uid() = user_id);

create policy "Usuário atualiza suas notificações"
  on public.notifications for update using (auth.uid() = user_id);

-- ============================================================
-- REALTIME — habilita tabelas para Supabase Realtime
-- ============================================================
alter publication supabase_realtime add table public.messages;
alter publication supabase_realtime add table public.notifications;
alter publication supabase_realtime add table public.proposals;
