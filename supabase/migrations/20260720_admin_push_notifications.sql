-- Vai Rodar - dispositivos autorizados a receber alertas do backoffice admin.
-- O frontend nunca acessa esta tabela diretamente; somente Netlify Functions
-- autenticadas com ADMIN_PASSWORD e SUPABASE_SERVICE_ROLE_KEY.
create table if not exists public.admin_push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  endpoint text not null unique,
  subscription jsonb not null,
  user_agent text,
  platform text not null default 'web',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_admin_push_subscriptions_active
  on public.admin_push_subscriptions(active);

alter table public.admin_push_subscriptions enable row level security;
revoke all on table public.admin_push_subscriptions from anon, authenticated;

comment on table public.admin_push_subscriptions is
  'Dispositivos do administrador. Acesso exclusivo por service role nas Netlify Functions.';
