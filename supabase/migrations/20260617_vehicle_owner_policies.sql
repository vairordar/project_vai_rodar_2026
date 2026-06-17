-- ============================================================
-- Vai Rodar - Vehicles owner policies
-- Ensures users can manage their own saved plates only.
-- Safe to re-run.
-- ============================================================

alter table public.vehicles enable row level security;

revoke all on public.vehicles from anon;
grant select, insert, update, delete on public.vehicles to authenticated;

drop policy if exists "Motorista ve seus veiculos" on public.vehicles;
drop policy if exists "Motorista cria seus veiculos" on public.vehicles;
drop policy if exists "Motorista atualiza seus veiculos" on public.vehicles;
drop policy if exists "Motorista remove seus veiculos" on public.vehicles;
drop policy if exists "Motorista vê seus veículos" on public.vehicles;
drop policy if exists "Motorista gerencia seus veículos" on public.vehicles;

create policy "Motorista ve seus veiculos"
  on public.vehicles
  for select
  to authenticated
  using (auth.uid() = user_id);

create policy "Motorista cria seus veiculos"
  on public.vehicles
  for insert
  to authenticated
  with check (auth.uid() = user_id);

create policy "Motorista atualiza seus veiculos"
  on public.vehicles
  for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "Motorista remove seus veiculos"
  on public.vehicles
  for delete
  to authenticated
  using (auth.uid() = user_id);

-- Diagnostic checks after running:
-- select rowsecurity from pg_tables where schemaname='public' and tablename='vehicles';
-- select policyname, cmd, qual, with_check from pg_policies where schemaname='public' and tablename='vehicles';
-- select grantee, privilege_type from information_schema.role_table_grants where table_schema='public' and table_name='vehicles';
