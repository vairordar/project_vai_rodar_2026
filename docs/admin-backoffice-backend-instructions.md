# Instrucciones para Claude - Admin Backoffice Vai Rodar

Objetivo: crear la base de datos y endpoints necesarios para que `apps/admin-backoffice/index.html` funcione con datos reales, exportables a CSV/Excel, y con control completo de suscripciones de talleres.

No cambiar nombres de carpetas ni archivos.

Frontend objetivo:

- `apps/admin-backoffice/index.html`

## 1. Tablas existentes que NO deben renombrarse

Ya existen o estan previstas en el proyecto:

- `public.profiles`
- `public.vehicles`
- `public.workshops`
- `public.service_requests`
- `public.proposals`
- `public.conversations`
- `public.messages`
- `public.reservations`
- `public.notifications`
- `public.workshop_availability_blocks`
- `public.workshop_offers`
- `public.workshop_profile_change_requests`
- `public.workshop_owner_details`

## 2. Campos nuevos/confirmados en `public.workshops`

Extender `public.workshops` sin romper campos existentes:

```sql
alter table public.workshops
  add column if not exists legal_name text,
  add column if not exists cnpj text,
  add column if not exists responsible_name text,
  add column if not exists contact_phone text,
  add column if not exists whatsapp text,
  add column if not exists cep text,
  add column if not exists neighborhood text,
  add column if not exists latitude numeric,
  add column if not exists longitude numeric,
  add column if not exists approval_status text not null default 'pending',
  add column if not exists approved_at timestamptz,
  add column if not exists approved_by uuid references public.profiles(id),
  add column if not exists visible boolean not null default false,
  add column if not exists subscription_status text not null default 'pending_payment';
```

Constraints esperadas:

- `approval_status in ('pending','approved','rejected','blocked')`
- `subscription_status in ('trial','active','pending_payment','expired','cancelled')`

Regla:

- Una oficina solo debe aparecer en el user app si:
  - `workshops.approval_status = 'approved'`
  - `workshops.visible = true`
  - `workshops.open = true`
  - `workshops.subscription_status in ('trial','active')`

## 3. Tabla `public.workshop_subscriptions`

Crear tabla:

```sql
create table if not exists public.workshop_subscriptions (
  id uuid primary key default uuid_generate_v4(),
  workshop_id uuid not null references public.workshops(id) on delete cascade,
  plan_name text not null default 'Anual oficina',
  status text not null default 'pending_payment',
  paid_at timestamptz,
  starts_at timestamptz,
  expires_at timestamptz,
  duration_days integer not null default 365,
  amount_paid numeric(10,2) default 0,
  payment_method text,
  payment_reference text,
  invoice_url text,
  created_by_admin uuid references public.profiles(id),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
```

Constraints:

- `status in ('trial','active','pending_payment','expired','cancelled')`
- `duration_days > 0`
- `amount_paid >= 0`

Regla de negocio:

- Si `paid_at` tiene valor y `duration_days = 365`:
  - `starts_at = date_trunc('day', paid_at) + interval '1 day'`
  - `expires_at = starts_at + interval '365 days'`
  - `status = 'active'`

Crear trigger o function para calcular automaticamente `starts_at`, `expires_at` y actualizar `workshops.subscription_status`.

## 4. Tabla `public.workshop_payments`

Crear tabla:

```sql
create table if not exists public.workshop_payments (
  id uuid primary key default uuid_generate_v4(),
  workshop_id uuid not null references public.workshops(id) on delete cascade,
  subscription_id uuid references public.workshop_subscriptions(id) on delete set null,
  paid_at timestamptz not null default now(),
  status text not null default 'paid',
  method text,
  amount numeric(10,2) not null default 0,
  reference text,
  invoice_url text,
  notes text,
  created_by_admin uuid references public.profiles(id),
  created_at timestamptz not null default now()
);
```

Constraints:

- `status in ('paid','pending','failed','refunded','cancelled')`
- `amount >= 0`

## 5. Tabla `public.analytics_events`

Crear tabla generica para trazabilidad del negocio:

```sql
create table if not exists public.analytics_events (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid references public.profiles(id) on delete set null,
  workshop_id uuid references public.workshops(id) on delete set null,
  event_type text not null,
  source_app text not null default 'user-app',
  search_query text,
  service_category text,
  location_text text,
  city text,
  state text,
  neighborhood text,
  latitude numeric,
  longitude numeric,
  related_request_id uuid references public.service_requests(id) on delete set null,
  related_conversation_id uuid references public.conversations(id) on delete set null,
  related_offer_id uuid references public.workshop_offers(id) on delete set null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
```

Eventos esperados:

- `search`
- `chat_started`
- `chat_message`
- `plate_lookup`
- `service_request_created`
- `proposal_received`
- `proposal_accepted`
- `reservation_created`
- `workshop_profile_view`
- `offer_viewed`
- `offer_clicked`
- `workshop_register_started`
- `workshop_register_completed`

## 6. Tabla `public.admin_audit_logs`

Crear tabla:

```sql
create table if not exists public.admin_audit_logs (
  id uuid primary key default uuid_generate_v4(),
  admin_id uuid references public.profiles(id) on delete set null,
  admin_email text,
  action text not null,
  entity text,
  entity_id uuid,
  detail text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
```

Usar para registrar:

- aprobacion de taller
- rechazo de taller
- bloqueo de taller
- activacion/desactivacion de visibilidad
- creacion de suscripcion
- registro de pago
- cambio de categoria aprobado o rechazado

## 7. Helper admin y RLS

Crear helper:

```sql
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid()
      and role = 'admin'
  );
$$;
```

RLS:

- Admin puede `select/insert/update/delete` en tablas admin.
- Taller NO puede modificar suscripcion, payment ni audit.
- Taller puede ver solo sus datos operativos existentes.
- Usuario final no puede ver tablas admin.

Tablas con RLS:

- `workshop_subscriptions`
- `workshop_payments`
- `analytics_events`
- `admin_audit_logs`

## 8. Vistas para el frontend admin

Crear estas views con exactamente estos nombres:

### `public.admin_workshops_overview`

Debe devolver al menos:

- `id`
- `name`
- `legal_name`
- `cnpj`
- `responsible_name`
- `contact_phone`
- `whatsapp`
- `cep`
- `address`
- `neighborhood`
- `city`
- `state`
- `latitude`
- `longitude`
- `category`
- `services`
- `approval_status`
- `open`
- `visible`
- `subscription_status`
- `created_at`
- `approved_at`
- `current_subscription_id`
- `subscription_expires_at`
- `subscription_days_remaining`

### `public.admin_dashboard_summary`

Una fila con:

- `total_workshops`
- `active_workshops`
- `pending_workshops`
- `paying_workshops`
- `expired_workshops`
- `total_users`
- `total_service_requests_30d`
- `total_reservations_30d`
- `total_chats_30d`
- `total_offer_clicks_30d`
- `request_to_reservation_conversion_30d`

### `public.admin_top_locations_30d`

Campos:

- `location_text`
- `city`
- `state`
- `neighborhood`
- `event_count`

### `public.admin_top_services_30d`

Campos:

- `service_category`
- `event_count`

### `public.admin_chat_usage_30d`

Campos:

- `workshop_id`
- `workshop_name`
- `conversation_count`
- `message_count`

## 9. Exportaciones CSV/Excel

El frontend actual genera CSV local desde los datos cargados.

Claude debe dejar disponibles estas fuentes para conectar despues:

- `admin_workshops_overview`
- `workshop_subscriptions`
- `workshop_payments`
- `analytics_events`
- `admin_top_locations_30d`
- `admin_top_services_30d`
- `admin_audit_logs`

No crear XLSX todavia. CSV es suficiente porque Excel lo abre.

## 10. Indices recomendados

Crear indices:

```sql
create index if not exists workshops_approval_status_idx on public.workshops(approval_status);
create index if not exists workshops_subscription_status_idx on public.workshops(subscription_status);
create index if not exists workshops_visible_open_idx on public.workshops(visible, open);
create index if not exists workshop_subscriptions_workshop_id_idx on public.workshop_subscriptions(workshop_id);
create index if not exists workshop_subscriptions_status_idx on public.workshop_subscriptions(status);
create index if not exists workshop_subscriptions_expires_at_idx on public.workshop_subscriptions(expires_at);
create index if not exists workshop_payments_workshop_id_idx on public.workshop_payments(workshop_id);
create index if not exists workshop_payments_paid_at_idx on public.workshop_payments(paid_at desc);
create index if not exists analytics_events_type_created_idx on public.analytics_events(event_type, created_at desc);
create index if not exists analytics_events_location_idx on public.analytics_events(city, state, neighborhood);
create index if not exists analytics_events_service_idx on public.analytics_events(service_category);
create index if not exists admin_audit_logs_created_idx on public.admin_audit_logs(created_at desc);
```

## 11. Entrega esperada de Claude

Claude debe entregar:

1. Migration SQL en:
   - `supabase/migrations/20260615_admin_backoffice_data_model.sql`

2. Explicacion breve de:
   - tablas creadas
   - campos agregados
   - RLS
   - views
   - regla de suscripcion 365 dias

3. Confirmar que no cambio:
   - `apps/user-app`
   - `apps/workshop-app`
   - `apps/workshop-register-standalone`
   - nombres de carpetas

