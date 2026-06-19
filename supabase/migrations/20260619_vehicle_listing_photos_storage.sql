-- ============================================================
-- Vai Rodar — Bucket de Storage para fotos de anuncios de vehiculos
-- Migration: 20260619_vehicle_listing_photos_storage.sql
-- IDEMPOTENTE — seguro de re-ejecutar
-- ============================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'vehicle-listing-photos',
  'vehicle-listing-photos',
  true,
  5242880,
  array['image/jpeg','image/png','image/webp','image/gif']
)
on conflict (id) do nothing;

do $$ begin
  if not exists (
    select 1 from pg_policies
    where tablename='objects' and schemaname='storage'
    and policyname='Usuario sobe fotos de seus anuncios'
  ) then
    create policy "Usuario sobe fotos de seus anuncios"
      on storage.objects for insert
      with check (
        bucket_id = 'vehicle-listing-photos'
        and auth.role() = 'authenticated'
        and (storage.foldername(name))[1] = auth.uid()::text
      );
  end if;
end $$;

do $$ begin
  if not exists (
    select 1 from pg_policies
    where tablename='objects' and schemaname='storage'
    and policyname='Publico le fotos de anuncios'
  ) then
    create policy "Publico le fotos de anuncios"
      on storage.objects for select
      using (bucket_id = 'vehicle-listing-photos');
  end if;
end $$;

do $$ begin
  if not exists (
    select 1 from pg_policies
    where tablename='objects' and schemaname='storage'
    and policyname='Usuario deleta fotos de seus anuncios'
  ) then
    create policy "Usuario deleta fotos de seus anuncios"
      on storage.objects for delete
      using (
        bucket_id = 'vehicle-listing-photos'
        and (storage.foldername(name))[1] = auth.uid()::text
      );
  end if;
end $$;
