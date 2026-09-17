-- ============================================================
-- Medora - Sync v2: a change cursor the server assigns, row versions,
-- write ids, edit times per column and idempotent stock changes.
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
--
-- Run it in one transaction (`supabase db push` and the SQL editor do).
-- Every statement can be run again, so a failed run can simply be
-- retried.
--
-- After this migration:
-- - never run 20260901000000_initial_schema.sql again: it would put back
--   the old update_updated_at() and break the rule in section 4;
-- - do not enable read replicas for this project: a pull reads its pages
--   below a horizon taken on the primary, and a lagging replica would
--   answer without rows that are already below it.
-- ============================================================

-- The ALTER TABLEs wait for every open transaction on these tables, and
-- every API request on them would queue behind that wait. Give up instead.
set local lock_timeout = '5s';

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
--              corrected, a dose dropped from a changed schedule). It is the
--              time the last write carried; the merge reads the times per
--              column below.
-- field_edited_at
--              per column, when that column's last applied change was made:
--              {"<column>": {"at": <timestamptz>, "auto": <bool>}}. "auto"
--              marks a change the app made on its own. A time is never
--              later than the server received the change, and never earlier
--              than the time the map already held for that column. The
--              stock (quantity) and the bookkeeping columns have no entry.
--              An empty map (every row from before this migration, every
--              row not updated since it was inserted): each column was last
--              changed at the row's edited_at, or its updated_at when that
--              is empty. The first update of such a row fills the map.

alter table public.medications
  add column if not exists sync_xid        bigint not null default 0,
  add column if not exists row_version     bigint not null default 1,
  add column if not exists write_id        uuid,
  add column if not exists edited_at       timestamptz,
  add column if not exists field_edited_at jsonb not null default '{}'::jsonb;

alter table public.treatments
  add column if not exists sync_xid        bigint not null default 0,
  add column if not exists row_version     bigint not null default 1,
  add column if not exists write_id        uuid,
  add column if not exists edited_at       timestamptz,
  add column if not exists field_edited_at jsonb not null default '{}'::jsonb;

alter table public.prescriptions
  add column if not exists sync_xid        bigint not null default 0,
  add column if not exists row_version     bigint not null default 1,
  add column if not exists write_id        uuid,
  add column if not exists edited_at       timestamptz,
  add column if not exists field_edited_at jsonb not null default '{}'::jsonb;

alter table public.dose_logs
  add column if not exists sync_xid        bigint not null default 0,
  add column if not exists row_version     bigint not null default 1,
  add column if not exists write_id        uuid,
  add column if not exists edited_at       timestamptz,
  add column if not exists field_edited_at jsonb not null default '{}'::jsonb;

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
declare
  c_ceiling constant timestamptz := timestamptz '1970-01-02 00:00:00+00';
  c_epoch   constant timestamptz := timestamptz '1970-01-01 00:00:00+00';
  -- Columns with no edit time of their own: the bookkeeping, and the stock,
  -- which only apply_stock_change writes.
  c_untimed constant text[] := array['id', 'user_id', 'created_at', 'updated_at',
    'deleted_at', 'sync_xid', 'row_version', 'write_id', 'edited_at',
    'field_edited_at', 'quantity'];
  v_now    timestamptz := now();
  v_legacy boolean := false;
  v_new    jsonb;
  v_old    jsonb;
  v_sent   jsonb;
  v_map    jsonb := '{}';
  v_key    text;
  v_entry  jsonb;
  v_at     timestamptz;
  v_auto   boolean;
begin
  new.sync_xid := pg_current_xact_id()::text::bigint;
  if tg_op = 'INSERT' then
    new.row_version := 1;
    new.edited_at := coalesce(new.edited_at, new.updated_at, v_now);
  else
    new.row_version := old.row_version + 1;
    if new.write_id is null or new.write_id is not distinct from old.write_id then
      -- A writer that sends no write id: Medora 0.3.0 and older, the
      -- tombstone cascade. Its change counts as made when it arrived.
      v_legacy := true;
      new.write_id := null;
      new.edited_at := v_now;
    elsif new.edited_at is null then
      new.edited_at := coalesce(old.updated_at, v_now);
    end if;
  end if;
  if new.edited_at < c_ceiling then
    new.edited_at := c_epoch;
  else
    new.edited_at := least(new.edited_at, v_now);
    if tg_op = 'INSERT' then
      -- A row a person created is stamped on arrival, so a device whose
      -- updated_at cursor passed its creation time while it was offline
      -- still pulls it (Medora 0.3.0 pulls by updated_at). A generated
      -- row keeps its 1970 stamp and stays invisible to those cursors.
      new.updated_at := v_now;
    end if;
  end if;

  -- Edit times per column. A 0.4.0 client sends an entry for each column
  -- it writes; the entries are read only for the columns the write really
  -- changes (an insert: the columns it names), and never for a legacy
  -- write.
  v_new := to_jsonb(new);
  if tg_op = 'INSERT' then
    v_sent := new.field_edited_at;
  else
    v_old := to_jsonb(old);
    v_map := old.field_edited_at;
    if not v_legacy and new.field_edited_at is distinct from old.field_edited_at then
      v_sent := new.field_edited_at;
    end if;
    if v_map = '{}' then
      -- The first update since the row was written: every column was last
      -- changed at the row's own time.
      v_map := '{}';
      v_at := least(coalesce(old.edited_at, old.updated_at, v_now), v_now);
      v_auto := v_at < c_ceiling;
      for v_key in select jsonb_object_keys(v_old) loop
        continue when v_key = any(c_untimed);
        v_map := v_map || jsonb_build_object(v_key, jsonb_build_object(
          'at', case when v_auto then c_epoch else v_at end, 'auto', v_auto));
      end loop;
    end if;
  end if;
  for v_key in select jsonb_object_keys(v_new) loop
    continue when v_key = any(c_untimed);
    v_entry := v_sent -> v_key;
    if tg_op = 'INSERT' then
      continue when v_entry is null;
    else
      continue when (v_new -> v_key) is not distinct from (v_old -> v_key);
    end if;
    -- A changed column with no entry takes the time the write carried
    -- (a legacy write: its arrival).
    v_at := coalesce((v_entry ->> 'at')::timestamptz, new.edited_at);
    v_auto := coalesce((v_entry ->> 'auto')::boolean, false) or v_at < c_ceiling;
    v_at := case when v_auto then c_epoch else least(v_at, v_now) end;
    -- Never earlier than the time already held (greatest skips a NULL).
    v_at := greatest((v_map -> v_key ->> 'at')::timestamptz, v_at);
    v_map := v_map || jsonb_build_object(v_key, jsonb_build_object('at', v_at, 'auto', v_auto));
  end loop;
  new.field_edited_at := v_map;
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

-- Trigger functions run as triggers only (a trigger does not need EXECUTE).
revoke all on function public.medora_sync_stamp() from public, anon, authenticated;
revoke all on function public.update_updated_at() from public, anon, authenticated;
revoke all on function public.cascade_tombstone_treatment() from public, anon, authenticated;
revoke all on function public.cascade_tombstone_medication() from public, anon, authenticated;
revoke all on function public.cascade_tombstone_prescription() from public, anon, authenticated;

-- Clients never truncate, add triggers or add foreign keys. Row-level
-- security does not cover TRUNCATE, and Supabase grants all three by
-- default, so one signed-in user could otherwise empty every user's rows
-- through any SQL surface. Hard DELETE ("delete all data") stays, under the
-- tables' policies.
revoke truncate, trigger, references
  on public.medications, public.treatments, public.prescriptions,
     public.dose_logs, public.families, public.family_members
  from anon, authenticated;

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
  constraint stock_changes_set_to_range check (set_to is null or set_to between 0 and 999999),
  constraint stock_changes_quantity_range check (quantity_after between 0 and 999999)
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
--   {"status":"gone"}      (no live medication with this id for the caller:
--                           deleted, removed from the server, or never
--                           there. The change can never apply: drop it.)
-- A client sends a change only for a medication whose create has reached
-- the server, so "never there" means removed. The ledger rows of a removed
-- medication go with it, so a retry after the removal is gone as well.
--
-- Values out of range are brought into range before anything else, so a
-- change is never refused for good: set_to to 0..999999, delta to
-- -999999..999999; the new quantity is set_to, or quantity + delta
-- (computed without overflow) capped to 0..999999. The ledger records the
-- values in range. lib/data/datasources/stock_remote.dart (stockAfter) and
-- test/helpers/fake_server.dart follow the same rule.
--
-- The medication keeps its edit time (a stock change is not a field edit
-- that the merge compares). Medications never carry the 1970 edit time of
-- an automatic change, so updated_at moves and 0.3.0 pulls the change.
--
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
  v_delta   integer;
  v_set_to  integer;
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
  -- (greatest and least skip NULLs, so keep a NULL as it is.)
  v_delta := case when p_delta is not null then greatest(-999999, least(999999, p_delta)) end;
  v_set_to := case when p_set_to is not null then greatest(0, least(999999, p_set_to)) end;

  -- Two attempts with one op id (a retry racing the original) run one
  -- after the other.
  perform pg_advisory_xact_lock(hashtextextended(p_op_id::text, 0));

  select quantity_after into v_after
    from public.stock_changes where op_id = p_op_id;
  if found then
    return jsonb_build_object('status', 'duplicate', 'quantity', v_after);
  end if;

  update public.medications m
     set quantity = coalesce(
           v_set_to,
           greatest(0, least(999999, m.quantity::bigint + v_delta))::integer
         ),
         write_id = p_op_id
   where m.id = p_medication_id
     and m.deleted_at is null
  returning m.quantity, m.row_version into v_qty, v_version;

  if not found then
    return jsonb_build_object('status', 'gone');
  end if;

  insert into public.stock_changes (op_id, medication_id, delta, set_to, quantity_after)
    values (p_op_id, p_medication_id, v_delta, v_set_to, v_qty);

  return jsonb_build_object(
    'status', 'applied', 'quantity', v_qty, 'row_version', v_version
  );
end;
$$;

revoke all on function public.apply_stock_change(uuid, text, integer, integer) from public, anon;
grant execute on function public.apply_stock_change(uuid, text, integer, integer) to authenticated;
