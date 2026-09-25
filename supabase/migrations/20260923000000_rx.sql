-- ============================================================
-- Medora - Prescriptions (spec 2026-09-23): persons, prescription
-- documents (rx) and their dispensings, synced like every other table
-- (sync v2 columns, the stamp trigger, owner-scoped RLS).
--
-- Apply after 20260918000000_sync_v2.sql and BEFORE any device runs
-- Medora 0.6.0. Older app versions never touch these tables. Every
-- statement can be run again.
-- ============================================================

set local lock_timeout = '5s';

-- 1. Tables -----------------------------------------------------------------
--
-- A prescription names its person, treatment and medications without a
-- foreign key: deleting one of those never deletes a prescription. A
-- dispensing belongs to its prescription.

create table if not exists public.persons (
  id              text primary key,
  user_id         uuid not null references auth.users(id) on delete cascade,
  name            text not null,
  tax_code        text,
  exemptions      text,
  notes           text,
  created_at      timestamptz default now(),
  updated_at      timestamptz default now(),
  deleted_at      timestamptz,
  sync_xid        bigint not null default 0,
  row_version     bigint not null default 1,
  write_id        uuid,
  edited_at       timestamptz,
  field_edited_at jsonb not null default '{}'::jsonb
);

create table if not exists public.rx (
  id              text primary key,
  user_id         uuid not null references auth.users(id) on delete cascade,
  person_id       text,
  treatment_id    text,
  kind            text not null
                  check (kind in ('ssn', 'white', 'white_repeatable', 'referral')),
  nre             text,
  pin             text check (pin is null or pin ~ '^[A-Z0-9]{5}$'),
  issued_on       date not null,
  valid_until     date,
  doctor          text,
  exemption_code  text,
  priority        text check (priority in ('U', 'B', 'D', 'P')),
  max_dispensings integer check (max_dispensings > 0),
  items           jsonb not null default '[]'::jsonb,
  closed_on       date,
  cancelled       boolean not null default false,
  notes           text,
  created_at      timestamptz default now(),
  updated_at      timestamptz default now(),
  deleted_at      timestamptz,
  sync_xid        bigint not null default 0,
  row_version     bigint not null default 1,
  write_id        uuid,
  edited_at       timestamptz,
  field_edited_at jsonb not null default '{}'::jsonb
);

create table if not exists public.rx_dispensings (
  id              text primary key,
  user_id         uuid not null references auth.users(id) on delete cascade,
  rx_id           text not null references public.rx(id) on delete cascade,
  item_id         text not null,
  packs           integer not null check (packs > 0),
  dispensed_on    date not null,
  pharmacy        text,
  units_added     integer not null default 0 check (units_added >= 0),
  created_at      timestamptz default now(),
  updated_at      timestamptz default now(),
  deleted_at      timestamptz,
  sync_xid        bigint not null default 0,
  row_version     bigint not null default 1,
  write_id        uuid,
  edited_at       timestamptz,
  field_edited_at jsonb not null default '{}'::jsonb
);

create index if not exists idx_persons_sync on public.persons (user_id, sync_xid, id);
create index if not exists idx_rx_sync      on public.rx (user_id, sync_xid, id);
create index if not exists idx_rx_disp_sync on public.rx_dispensings (user_id, sync_xid, id);
create index if not exists idx_rx_disp_rx   on public.rx_dispensings (rx_id);

-- 2. Row-level security: the owner only ----------------------------------

alter table public.persons        enable row level security;
alter table public.rx             enable row level security;
alter table public.rx_dispensings enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array['persons', 'rx', 'rx_dispensings'] loop
    execute format('drop policy if exists "%1$s_select" on public.%1$s', t);
    execute format('create policy "%1$s_select" on public.%1$s for select using (user_id = auth.uid())', t);
    execute format('drop policy if exists "%1$s_insert" on public.%1$s', t);
    execute format('create policy "%1$s_insert" on public.%1$s for insert with check (user_id = auth.uid())', t);
    execute format('drop policy if exists "%1$s_update" on public.%1$s', t);
    execute format('create policy "%1$s_update" on public.%1$s for update using (user_id = auth.uid()) with check (user_id = auth.uid())', t);
    execute format('drop policy if exists "%1$s_delete" on public.%1$s', t);
    execute format('create policy "%1$s_delete" on public.%1$s for delete using (user_id = auth.uid())', t);
  end loop;
end;
$$;

-- A dispensing may only name a prescription of the same owner, when it is
-- written and when it is moved: the lookup runs under the caller's own
-- `rx_select` policy, so another user's prescription is not found.
drop policy if exists "rx_dispensings_insert" on public.rx_dispensings;
create policy "rx_dispensings_insert" on public.rx_dispensings
  for insert with check (
    user_id = auth.uid()
    and exists (select 1 from public.rx r where r.id = rx_id)
  );
drop policy if exists "rx_dispensings_update" on public.rx_dispensings;
create policy "rx_dispensings_update" on public.rx_dispensings
  for update using (user_id = auth.uid()) with check (
    user_id = auth.uid()
    and exists (select 1 from public.rx r where r.id = rx_id)
  );

revoke truncate, trigger, references
  on public.persons, public.rx, public.rx_dispensings
  from anon, authenticated;

-- 3. Triggers ---------------------------------------------------------------
--
-- The same stamp and updated_at triggers as the other synced tables. The
-- stamp trigger's parent check knows only the original tables, so a
-- second BEFORE trigger stores a live dispensing under a deleted
-- prescription deleted, as the app's own change. Its name sorts after
-- `_sync_stamp` and before `_updated_at`, so it runs between them (BEFORE
-- triggers of one event fire in name order).

do $$
declare
  t text;
begin
  foreach t in array array['persons', 'rx', 'rx_dispensings'] loop
    execute format('drop trigger if exists %1$s_sync_stamp on public.%1$s', t);
    execute format('create trigger %1$s_sync_stamp before insert or update on public.%1$s for each row execute function public.medora_sync_stamp()', t);
    execute format('drop trigger if exists %1$s_updated_at on public.%1$s', t);
    execute format('create trigger %1$s_updated_at before update on public.%1$s for each row execute function public.update_updated_at()', t);
  end loop;
end;
$$;

create or replace function public.medora_rx_dispensing_parent()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_parent_deleted timestamptz;
begin
  if new.deleted_at is null then
    -- FOR SHARE: see the note on the parent check in medora_sync_stamp.
    select r.deleted_at into v_parent_deleted
      from public.rx r where r.id = new.rx_id for share;
    if v_parent_deleted is not null then
      new.deleted_at := v_parent_deleted;
      new.edited_at := timestamptz '1970-01-01 00:00:00+00';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists rx_dispensings_sync_stamp_parent on public.rx_dispensings;
create trigger rx_dispensings_sync_stamp_parent
  before insert or update on public.rx_dispensings
  for each row execute function public.medora_rx_dispensing_parent();

-- A prescription's tombstone takes its dispensings with it.
create or replace function public.cascade_tombstone_rx()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.deleted_at is not null and old.deleted_at is null then
    update public.rx_dispensings set deleted_at = new.deleted_at
     where rx_id = new.id and deleted_at is null;
  end if;
  return new;
end;
$$;

drop trigger if exists rx_tombstone_cascade on public.rx;
create trigger rx_tombstone_cascade
  after update of deleted_at on public.rx
  for each row execute function public.cascade_tombstone_rx();

revoke all on function public.medora_rx_dispensing_parent() from public, anon, authenticated;
revoke all on function public.cascade_tombstone_rx() from public, anon, authenticated;

-- 4. "Delete all data" covers the new tables -----------------------------
--
-- Same function as in 20260918000000_sync_v2.sql, section 8, with the three
-- deletes added before the medications.

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
  delete from public.rx_dispensings where user_id = v_uid;
  delete from public.rx where user_id = v_uid;
  delete from public.persons where user_id = v_uid;
  delete from public.medications where user_id = v_uid;
  return jsonb_build_object('generation', v_generation, 'wiped_at', v_at);
end;
$$;

revoke all on function public.medora_delete_all_data() from public, anon;
grant execute on function public.medora_delete_all_data() to authenticated;
