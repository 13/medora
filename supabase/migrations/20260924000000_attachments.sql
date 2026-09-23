-- ============================================================
-- Medora - Attachments (spec 2026-09-23 §7): metadata rows synced like
-- every other table, bytes in a private storage bucket, one folder per
-- user. Apply after 20260923000000_rx.sql and before any device runs the
-- release that adds attachments. Every statement can be run again.
-- ============================================================

set local lock_timeout = '5s';

create table if not exists public.attachments (
  id              text primary key,
  user_id         uuid not null references auth.users(id) on delete cascade,
  owner_kind      text not null check (owner_kind in ('rx', 'treatment', 'person')),
  owner_id        text not null,
  kind            text not null check (kind in ('photo', 'pdf')),
  mime            text not null check (mime in ('image/jpeg', 'application/pdf')),
  size_bytes      integer not null check (size_bytes > 0 and size_bytes <= 20971520),
  sha256          text not null,
  original_name   text,
  remote_path     text,
  created_at      timestamptz default now(),
  updated_at      timestamptz default now(),
  deleted_at      timestamptz,
  sync_xid        bigint not null default 0,
  row_version     bigint not null default 1,
  write_id        uuid,
  edited_at       timestamptz,
  field_edited_at jsonb not null default '{}'::jsonb,
  -- The id is the object's file name: it cannot open a sub-folder.
  constraint attachments_id_plain check (id !~ '/'),
  -- A photo is always a JPEG and a PDF always a PDF.
  constraint attachments_kind_mime check (
    (kind = 'photo' and mime = 'image/jpeg')
    or (kind = 'pdf' and mime = 'application/pdf')
  ),
  -- A path always sits in the owner's folder and names this attachment.
  constraint attachments_remote_path check (
    remote_path is null
    or remote_path = user_id::text || '/' || id || '.' ||
       case kind when 'photo' then 'jpg' else 'pdf' end
  )
);

create index if not exists idx_att_sync on public.attachments (user_id, sync_xid, id);

alter table public.attachments enable row level security;

drop policy if exists "attachments_select" on public.attachments;
create policy "attachments_select" on public.attachments
  for select using (user_id = auth.uid());
drop policy if exists "attachments_insert" on public.attachments;
create policy "attachments_insert" on public.attachments
  for insert with check (user_id = auth.uid());
drop policy if exists "attachments_update" on public.attachments;
create policy "attachments_update" on public.attachments
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists "attachments_delete" on public.attachments;
create policy "attachments_delete" on public.attachments
  for delete using (user_id = auth.uid());

revoke truncate, trigger, references on public.attachments from anon, authenticated;

drop trigger if exists attachments_sync_stamp on public.attachments;
create trigger attachments_sync_stamp
  before insert or update on public.attachments
  for each row execute function public.medora_sync_stamp();
drop trigger if exists attachments_updated_at on public.attachments;
create trigger attachments_updated_at
  before update on public.attachments
  for each row execute function public.update_updated_at();

-- The bucket: private, 20 MB per object, JPEG and PDF only.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('attachments', 'attachments', false, 20971520,
        array['image/jpeg', 'application/pdf'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Objects: a user reads, adds and removes only inside their own folder.
-- No update policy: contents never change.
drop policy if exists "attachments_objects_select" on storage.objects;
create policy "attachments_objects_select" on storage.objects
  for select to authenticated
  using (bucket_id = 'attachments'
         and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "attachments_objects_insert" on storage.objects;
create policy "attachments_objects_insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'attachments'
              and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "attachments_objects_delete" on storage.objects;
create policy "attachments_objects_delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'attachments'
         and (storage.foldername(name))[1] = auth.uid()::text);

-- "Delete all data" also removes the attachment rows. Storage objects cannot
-- be deleted from SQL (Supabase blocks direct deletes on storage tables); the
-- app removes the user's folder through the storage API right after the call.
-- Same function as in 20260923000000_rx.sql, with the attachments delete added.
create or replace function public.medora_delete_all_data()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid        uuid := auth.uid();
  v_at         timestamptz := now();
  v_generation bigint;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('medora-wipe:' || v_uid::text, 0));
  insert into public.sync_wipes as w (user_id, generation, wiped_at)
    values (v_uid, 1, v_at)
    on conflict (user_id) do update
      set generation = w.generation + 1, wiped_at = excluded.wiped_at
    returning w.generation into v_generation;
  delete from public.dose_logs d
   using public.prescriptions p, public.treatments t
   where d.prescription_id = p.id and p.treatment_id = t.id and t.user_id = v_uid;
  delete from public.prescriptions p
   using public.treatments t
   where p.treatment_id = t.id and t.user_id = v_uid;
  delete from public.treatments where user_id = v_uid;
  delete from public.attachments where user_id = v_uid;
  delete from public.rx_dispensings where user_id = v_uid;
  delete from public.rx where user_id = v_uid;
  delete from public.persons where user_id = v_uid;
  delete from public.medications where user_id = v_uid;
  return jsonb_build_object('generation', v_generation, 'wiped_at', v_at);
end;
$$;

revoke all on function public.medora_delete_all_data() from public, anon;
grant execute on function public.medora_delete_all_data() to authenticated;
