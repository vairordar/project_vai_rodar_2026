-- ============================================================
-- Vai Rodar — CRM WhatsApp (prospección de talleres) + onboarding
-- Migration: 20260720_crm_whatsapp_y_onboarding.sql
-- IDEMPOTENTE — seguro de re-ejecutar
--
-- Contenido:
--   1. crm_contacts: prospectos de talleres (teléfono E.164 único)
--   2. crm_messages: historial entrante/saliente por contacto
--   3. crm_templates: plantillas de mensaje (estado de aprobación Meta)
--   4. RLS: acceso SOLO service role (funciones Netlify) y admin
--   5. Onboarding del backoffice del taller: estado persistente
--
-- El envío/recepción real requiere las variables de entorno en
-- Netlify (WHATSAPP_TOKEN, WHATSAPP_PHONE_NUMBER_ID,
-- WHATSAPP_VERIFY_TOKEN). Sin ellas, el CRM funciona en modo
-- preparación: contactos, notas y plantillas, sin envío.
-- ============================================================


-- ─── 1. Contactos (prospectos) ───────────────────────────────

create table if not exists public.crm_contacts (
  id                   uuid primary key default gen_random_uuid(),
  phone                text not null unique,          -- E.164, ej. +5511999999999
  name                 text,                          -- persona de contacto
  business_name        text,                          -- nombre del taller/comercio
  city                 text,
  state                text,
  source               text not null default 'manual',
  status               text not null default 'new',
  workshop_id          uuid references public.workshops(id) on delete set null,
  tags                 text[] not null default '{}',
  notes                text,
  last_message_at      timestamptz,
  last_message_preview text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

do $$ begin
  alter table public.crm_contacts
    add constraint crm_contacts_source_check
    check (source in ('manual','import','inbound'));
exception when duplicate_object then null;
end $$;

do $$ begin
  alter table public.crm_contacts
    add constraint crm_contacts_status_check
    check (status in ('new','contacted','interested','negotiating','registered','not_interested','invalid'));
exception when duplicate_object then null;
end $$;

create index if not exists idx_crm_contacts_status
  on public.crm_contacts (status);
create index if not exists idx_crm_contacts_last_message
  on public.crm_contacts (last_message_at desc nulls last);

drop trigger if exists trg_crm_contacts_updated_at on public.crm_contacts;
create trigger trg_crm_contacts_updated_at
  before update on public.crm_contacts
  for each row execute function public.update_updated_at_column();


-- ─── 2. Mensajes ─────────────────────────────────────────────

create table if not exists public.crm_messages (
  id            uuid primary key default gen_random_uuid(),
  contact_id    uuid not null references public.crm_contacts(id) on delete cascade,
  direction     text not null,                        -- inbound | outbound
  body          text,
  template_name text,                                 -- si fue plantilla
  wa_message_id text unique,                          -- id de Meta (statuses)
  status        text not null default 'queued',
  error         text,
  created_at    timestamptz not null default now()
);

do $$ begin
  alter table public.crm_messages
    add constraint crm_messages_direction_check
    check (direction in ('inbound','outbound'));
exception when duplicate_object then null;
end $$;

do $$ begin
  alter table public.crm_messages
    add constraint crm_messages_status_check
    check (status in ('queued','sent','delivered','read','failed','received'));
exception when duplicate_object then null;
end $$;

create index if not exists idx_crm_messages_contact_created
  on public.crm_messages (contact_id, created_at desc);


-- ─── 3. Plantillas ───────────────────────────────────────────
-- Meta exige plantillas aprobadas para iniciar conversaciones.
-- meta_status refleja el estado de aprobación en Meta Business.

create table if not exists public.crm_templates (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,                   -- nombre exacto en Meta
  language    text not null default 'pt_BR',
  body        text not null,                          -- texto con {{1}}, {{2}}...
  meta_status text not null default 'draft',
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

do $$ begin
  alter table public.crm_templates
    add constraint crm_templates_meta_status_check
    check (meta_status in ('draft','pending','approved','rejected'));
exception when duplicate_object then null;
end $$;

drop trigger if exists trg_crm_templates_updated_at on public.crm_templates;
create trigger trg_crm_templates_updated_at
  before update on public.crm_templates
  for each row execute function public.update_updated_at_column();


-- ─── 4. RLS: solo service role y admin ───────────────────────
-- El CRM es interno de Vai Rodar. Ningún taller ni motorista debe
-- ver estos datos. Las funciones Netlify usan service role (bypass
-- RLS); las policies de admin quedan para acceso directo futuro.

alter table public.crm_contacts  enable row level security;
alter table public.crm_messages  enable row level security;
alter table public.crm_templates enable row level security;

revoke all on public.crm_contacts  from anon, authenticated;
revoke all on public.crm_messages  from anon, authenticated;
revoke all on public.crm_templates from anon, authenticated;

do $$ begin
  create policy "Admin gestiona contactos CRM"
    on public.crm_contacts for all
    using (public.is_admin()) with check (public.is_admin());
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Admin gestiona mensajes CRM"
    on public.crm_messages for all
    using (public.is_admin()) with check (public.is_admin());
exception when duplicate_object then null;
end $$;

do $$ begin
  create policy "Admin gestiona plantillas CRM"
    on public.crm_templates for all
    using (public.is_admin()) with check (public.is_admin());
exception when duplicate_object then null;
end $$;


-- ─── 5. Onboarding del backoffice del taller ─────────────────
-- onboarding_state: jsonb libre para el frontend
--   { "tour_done": true, "tour_step": 4, "checklist_dismissed": false }
-- onboarding_completed_at: cuándo terminó el tour.
-- El checklist NO se guarda: se calcula en vivo con datos reales
-- (logo, horarios, categorías, servicios, primera oferta).

alter table public.workshops
  add column if not exists onboarding_state        jsonb not null default '{}'::jsonb,
  add column if not exists onboarding_completed_at timestamptz;

-- El dueño ya puede actualizar su workshop (policy existente
-- "Dueno actualiza su propio workshop"), así que el frontend
-- persiste el estado con un UPDATE normal.


-- ============================================================
-- DIAGNÓSTICO — correr después de aplicar la migration
-- ============================================================

-- 1. Tablas CRM creadas:
-- select table_name from information_schema.tables
-- where table_schema = 'public' and table_name like 'crm_%';

-- 2. Solo admin/service role acceden (debe devolver 0 filas):
-- select grantee, table_name, privilege_type
-- from information_schema.role_table_grants
-- where table_schema = 'public' and table_name like 'crm_%'
--   and grantee in ('anon','authenticated');

-- 3. Onboarding:
-- select column_name from information_schema.columns
-- where table_name = 'workshops' and column_name like 'onboarding%';

-- ─── FIN DE MIGRATION ─────────────────────────────────────────
