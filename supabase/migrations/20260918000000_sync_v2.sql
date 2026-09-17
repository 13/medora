-- ============================================================
-- Medora - Sync v2: a change cursor the server assigns, row versions,
-- write ids, edit times and idempotent stock changes.
--
-- Apply after 20260917000000_treatment_sick_leave.sql and BEFORE any
-- device runs Medora 0.4.0. Medora 0.3.0 keeps working against it:
-- every new column has a default or is set by a trigger, no existing
-- column changes meaning for a client that does not send the new ones,
-- and `updated_at` still moves on every change such a client can see.
--
-- No backfill UPDATE: every new column is added with a constant default
-- (no table rewrite, no trigger fires), so no row changes `updated_at`
-- and no 0.3.0 device sees its pending edit turn stale.
-- ============================================================

-- 1. Columns ---------------------------------------------------------------
--
-- sync_xid     the id of the transaction that last wrote the row. Pulls
--              read rows with sync_xid below a horizon every older
--              transaction has finished by (medora_sync_state), so a row
--              committed late is never skipped. 0 = written before this
--              migration.
-- row_version  1 on insert, +1 on every update. A client updates only
--              the version it last saw.
-- write_id     the id a 0.4.0+ client gives each write attempt, so it can
--              recognise its own write when the answer never arrived.
--              NULL for a write from a client that does not send one.
-- edited_at    when the change was made on the device, never later than
--              the server received it. 1970-01-01 marks a change the app
--              made on its own (an overdue dose marked missed, a dose time
--              corrected, a dose dropped from a changed schedule).

alter table public.medications
  add column if not exists sync_xid    bigint not null default 0,
  add column if not exists row_version bigint not null default 1,
  add column if not exists write_id    uuid,
  add column if not exists edited_at   timestamptz;

alter table public.treatments
  add column if not exists sync_xid    bigint not null default 0,
  add column if not exists row_version bigint not null default 1,
  add column if not exists write_id    uuid,
  add column if not exists edited_at   timestamptz;

alter table public.prescriptions
  add column if not exists sync_xid    bigint not null default 0,
  add column if not exists row_version bigint not null default 1,
  add column if not exists write_id    uuid,
  add column if not exists edited_at   timestamptz;

alter table public.dose_logs
  add column if not exists sync_xid    bigint not null default 0,
  add column if not exists row_version bigint not null default 1,
  add column if not exists write_id    uuid,
  add column if not exists edited_at   timestamptz;

-- 2. Pull indexes (keyset: sync_xid, then id) -----------------------------

create index if not exists idx_med_sync   on public.medications   (user_id, sync_xid, id);
create index if not exists idx_treat_sync on public.treatments    (user_id, sync_xid, id);
create index if not exists idx_presc_sync on public.prescriptions (sync_xid, id);
create index if not exists idx_dose_sync  on public.dose_logs     (sync_xid, id);

-- 3. The stamp trigger ------------------------------------------------------
--
-- Runs BEFORE the `<table>_updated_at` trigger: Postgres fires BEFORE
-- triggers of one event in name order, and `_sync_stamp` sorts before
-- `_updated_at`. update_updated_at() below relies on that order.

create or replace function public.medora_sync_stamp()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.sync_xid := pg_current_xact_id()::text::bigint;
  if tg_op = 'INSERT' then
    new.row_version := 1;
    new.edited_at := coalesce(new.edited_at, new.updated_at, now());
  else
    new.row_version := old.row_version + 1;
    if new.write_id is null or new.write_id is not distinct from old.write_id then
      -- A writer that sends no write id: Medora 0.3.0 and older, the
      -- tombstone cascade. Its change counts as made when it arrived.
      new.write_id := null;
      new.edited_at := now();
    elsif new.edited_at is null then
      new.edited_at := coalesce(old.updated_at, now());
    end if;
  end if;
  if new.edited_at < timestamptz '1970-01-02 00:00:00+00' then
    new.edited_at := timestamptz '1970-01-01 00:00:00+00';
  else
    new.edited_at := least(new.edited_at, now());
    if tg_op = 'INSERT' then
      -- A row a person created is stamped on arrival, so a device whose
      -- updated_at cursor passed its creation time while it was offline
      -- still pulls it (Medora 0.3.0 pulls by updated_at). A generated
      -- row keeps its 1970 stamp and stays invisible to those cursors.
      new.updated_at := now();
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists medications_sync_stamp on public.medications;
create trigger medications_sync_stamp
  before insert or update on public.medications
  for each row execute function public.medora_sync_stamp();

drop trigger if exists treatments_sync_stamp on public.treatments;
create trigger treatments_sync_stamp
  before insert or update on public.treatments
  for each row execute function public.medora_sync_stamp();

drop trigger if exists prescriptions_sync_stamp on public.prescriptions;
create trigger prescriptions_sync_stamp
  before insert or update on public.prescriptions
  for each row execute function public.medora_sync_stamp();

drop trigger if exists dose_logs_sync_stamp on public.dose_logs;
create trigger dose_logs_sync_stamp
  before insert or update on public.dose_logs
  for each row execute function public.medora_sync_stamp();

-- 4. updated_at: an automatic change keeps the old stamp ------------------
--
-- Medora 0.3.0 pulls by updated_at and skips its own pending edit when the
-- server's updated_at is newer. A change the app made on its own must lose
-- to that edit, so it leaves updated_at alone (0.3.0 neither pulls it nor
-- counts it as newer). Every other update is stamped now(), as before.

create or replace function public.update_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.write_id is not null
     and new.edited_at = timestamptz '1970-01-01 00:00:00+00' then
    new.updated_at := old.updated_at;
  else
    new.updated_at := now();
  end if;
  return new;
end;
$$;

-- 5. The pull horizon -------------------------------------------------------
--
-- Every transaction with an id below `horizon` has finished, so every row
-- a pull can ever see with `sync_xid < horizon` is visible now. A pull
-- reads [its stored key, horizon) and stores the horizon as its next
-- start. `schema` lets the app tell a project without this migration.

create or replace function public.medora_sync_state()
returns jsonb
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'schema', 2,
    'horizon', pg_snapshot_xmin(pg_current_snapshot())::text::bigint
  )
$$;

revoke all on function public.medora_sync_state() from public, anon;
grant execute on function public.medora_sync_state() to authenticated;

-- 6. Stock changes ----------------------------------------------------------
--
-- A stock change is sent as a change (a delta, or a counted quantity),
-- never as the new total. Each carries an id the device chose; the ledger
-- remembers every id it applied, so a retry after a lost answer is not
-- counted twice, and changes from two devices both apply.

create table if not exists public.stock_changes (
  op_id          uuid primary key,
  medication_id  text not null references public.medications(id) on delete cascade,
  user_id        uuid not null default auth.uid() references auth.users(id) on delete cascade,
  delta          integer,
  set_to         integer,
  quantity_after integer not null,
  applied_at     timestamptz not null default now(),
  constraint stock_changes_one_kind check ((delta is null) <> (set_to is null)),
  constraint stock_changes_delta_range check (delta is null or delta between -999999 and 999999),
  constraint stock_changes_set_to_range check (set_to is null or set_to between 0 and 999999)
);

create index if not exists idx_stock_changes_med on public.stock_changes (medication_id);

alter table public.stock_changes enable row level security;

-- The ledger follows the medication: whoever may see the medication row
-- (the owner today; the medications policies decide) may read and add its
-- changes. The subquery runs under the caller's own policies. No update
-- or delete policy: clients only append.
drop policy if exists "stock_changes_select" on public.stock_changes;
create policy "stock_changes_select" on public.stock_changes
  for select using (
    user_id = auth.uid()
    and exists (select 1 from public.medications m where m.id = medication_id)
  );

drop policy if exists "stock_changes_insert" on public.stock_changes;
create policy "stock_changes_insert" on public.stock_changes
  for insert with check (
    user_id = auth.uid()
    and exists (select 1 from public.medications m where m.id = medication_id)
  );

-- Supabase grants every right on a new table to anon and authenticated.
-- Row-level security does not cover TRUNCATE, so take the rights away and
-- give back only reading and appending.
revoke all on public.stock_changes from anon, authenticated;
grant select, insert on public.stock_changes to authenticated;

-- Applies one stock change once. Returns
--   {"status":"applied",   "quantity":q, "row_version":v}
--   {"status":"duplicate", "quantity":q}   (this op_id was applied before)
--   {"status":"gone"}      (the medication is deleted: drop the change)
--   {"status":"missing"}   (no such medication yet: keep the change)
-- Runs with the caller's rights, so row-level security applies throughout.
create or replace function public.apply_stock_change(
  p_op_id         uuid,
  p_medication_id text,
  p_delta         integer default null,
  p_set_to        integer default null
)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_after   integer;
  v_qty     integer;
  v_version bigint;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if (p_delta is null) = (p_set_to is null) then
    raise exception 'pass exactly one of p_delta and p_set_to'
      using errcode = '22023';
  end if;

  -- Two attempts with one op id (a retry racing the original) run one
  -- after the other.
  perform pg_advisory_xact_lock(hashtextextended(p_op_id::text, 0));

  select quantity_after into v_after
    from public.stock_changes where op_id = p_op_id;
  if found then
    return jsonb_build_object('status', 'duplicate', 'quantity', v_after);
  end if;

  update public.medications m
     set quantity = case
           when p_set_to is not null then greatest(0, least(999999, p_set_to))
           else greatest(0, least(999999, m.quantity + p_delta))
         end,
         write_id = p_op_id
   where m.id = p_medication_id
     and m.deleted_at is null
  returning m.quantity, m.row_version into v_qty, v_version;

  if not found then
    if exists (select 1 from public.medications m where m.id = p_medication_id) then
      return jsonb_build_object('status', 'gone');
    end if;
    return jsonb_build_object('status', 'missing');
  end if;

  insert into public.stock_changes (op_id, medication_id, delta, set_to, quantity_after)
    values (p_op_id, p_medication_id, p_delta, p_set_to, v_qty);

  return jsonb_build_object(
    'status', 'applied', 'quantity', v_qty, 'row_version', v_version
  );
end;
$$;

revoke all on function public.apply_stock_change(uuid, text, integer, integer) from public, anon;
grant execute on function public.apply_stock_change(uuid, text, integer, integer) to authenticated;
