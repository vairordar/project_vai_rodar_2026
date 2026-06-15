-- Vai Rodar - Workshop capacity per scheduling slot
-- Adds simple operational capacity used by workshop-app and user-app.

alter table public.workshops
  add column if not exists max_bookings_per_slot integer not null default 1,
  add column if not exists slot_minutes integer not null default 60;

do $$ begin
  alter table public.workshops
    add constraint workshops_max_bookings_per_slot_check
    check (max_bookings_per_slot between 1 and 10);
exception when duplicate_object then null;
end $$;

do $$ begin
  alter table public.workshops
    add constraint workshops_slot_minutes_check
    check (slot_minutes in (30, 60, 90, 120));
exception when duplicate_object then null;
end $$;

comment on column public.workshops.max_bookings_per_slot is
  'Maximum number of vehicles the workshop can receive in the same scheduling slot.';

comment on column public.workshops.slot_minutes is
  'Scheduling slot duration in minutes. MVP uses 60 minutes by default.';

create or replace function public.get_workshop_slot_usage(
  p_workshop_id uuid,
  p_slot_start timestamptz,
  p_slot_minutes integer default 60
)
returns integer
language sql
security definer
set search_path = public
as $$
  select count(*)::integer
  from public.reservations r
  where r.workshop_id = p_workshop_id
    and r.status in ('pending','confirmed')
    and r.scheduled_at >= p_slot_start
    and r.scheduled_at < p_slot_start + make_interval(mins => coalesce(p_slot_minutes,60));
$$;

grant execute on function public.get_workshop_slot_usage(uuid,timestamptz,integer) to anon, authenticated;
