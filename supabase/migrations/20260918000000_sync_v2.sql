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
-- and no 0.3.0 device sees its pending edit turn stale. The one UPDATE
-- (section 7) deletes the live rows it finds under a deleted parent, as
-- the app's own change. Section 8 adds "delete all data", which records a
-- wipe marker (section 2b) every device follows.
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

-- 2b. The wipe marker ------------------------------------------------------
--
-- One row per user who used "delete all data" (medora_delete_all_data,
-- section 8): how many times, and when the last one ran. Every device reads
-- it with the sync state; one that sees a newer generation than it last
-- saw removes what it holds from before `wiped_at` and pulls again. Only
-- that function writes it; a user reads only their own row.

create table if not exists public.sync_wipes (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  generation bigint not null,
  wiped_at   timestamptz not null
);

alter table public.sync_wipes enable row level security;

drop policy if exists "sync_wipes_select" on public.sync_wipes;
create policy "sync_wipes_select" on public.sync_wipes
  for select using (user_id = auth.uid());

revoke all on public.sync_wipes from anon, authenticated;
grant select on public.sync_wipes to authenticated;

-- 3. The stamp trigger ------------------------------------------------------
--
-- Runs BEFORE the `<table>_updated_at` trigger: Postgres fires BEFORE
-- triggers of one event in name order, and `_sync_stamp` sorts before
-- `_updated_at`. update_updated_at() below relies on that order.
--
-- Deletes. A tombstone whose edited_at is 1970 is the app's own delete:
-- a dose dropped from a changed schedule, a child deleted with its
-- parent. On a dose, a 0.4.0 device lets a person's change still waiting
-- beat it, and lets the schedule generate the dose again, but only under
-- a live prescription. Every other tombstone is a person's delete and
-- always wins. Around that:
-- - a child written live under a deleted parent (prescriptions under a
--   treatment or medication, doses under a prescription) is stored
--   deleted, with the parent's deleted_at, as the app's own delete. The
--   write still lands (its columns, its write id), so the device that
--   sent it learns the row is gone. With the tombstone cascade below, the
--   server never holds a live row under a deleted parent;
-- - the cascade (a write made by another trigger) deletes as the app's own
--   change, but still moves updated_at, so 0.3.0 sees it as before;
-- - a 0.3.0 write that sets a dose the app deleted to taken or skipped
--   brings it back (a person's take beats the app's delete). Any other
--   0.3.0 write to such a row leaves it deleted, still as the app's own.

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
  -- A write made by another trigger: the tombstone cascade.
  v_cascade boolean := pg_trigger_depth() > 1;
  -- The row stays or becomes the app's own tombstone.
  v_app_delete boolean := false;
  v_parent_deleted timestamptz;
  v_other_deleted  timestamptz;
  -- "Delete all data" (section 8): the caller's last wipe, and the wipe
  -- generation a 0.4.0 insert says its device has seen.
  v_wiped_at   timestamptz;
  v_generation bigint;
  v_wipe_delete boolean := false;
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

  -- A 0.4.0 insert from a device that has not seen the caller's last
  -- "delete all data" (the wipe generation it sends under "@wipe" is
  -- older), of a row a person last changed before that wipe, is stored
  -- deleted, as that person's delete: the device read the sync state just
  -- before the wipe, and its next cycle removes the row there too. A row
  -- changed after the wipe is new data, and so is every insert from a
  -- writer that sends no "@wipe" (Medora 0.3.0). The shared lock makes
  -- inserts and the wipe (which takes it exclusively) run one after the
  -- other, so this reads the wipe that is committed when the row lands.
  if tg_op = 'INSERT' and auth.uid() is not null then
    perform pg_advisory_xact_lock_shared(
      hashtextextended('medora-wipe:' || auth.uid()::text, 0));
    if new.deleted_at is null and new.write_id is not null
       and jsonb_typeof(new.field_edited_at) = 'object'
       and new.field_edited_at ? '@wipe'
       and new.edited_at >= c_ceiling then
      select w.wiped_at, w.generation into v_wiped_at, v_generation
        from public.sync_wipes w where w.user_id = auth.uid();
      if v_generation > (new.field_edited_at ->> '@wipe')::bigint
         and new.edited_at <= v_wiped_at then
        new.deleted_at := v_wiped_at;
        v_wipe_delete := true;
      end if;
    end if;
  end if;

  v_new := to_jsonb(new);
  if tg_op = 'UPDATE' then
    v_old := to_jsonb(old);
    -- A legacy write to a row the app deleted, that does not delete it
    -- itself.
    if v_legacy and not v_cascade and old.deleted_at is not null
       and old.edited_at < c_ceiling
       and new.deleted_at is not distinct from old.deleted_at then
      if tg_table_name = 'dose_logs'
         and v_new->>'status' in ('taken', 'skipped')
         and (v_new->'status') is distinct from (v_old->'status') then
        new.deleted_at := null;
      else
        v_app_delete := true;
      end if;
    end if;
  end if;

  -- Edit times per column. A 0.4.0 client sends an entry for each column
  -- it writes; the entries are read for the columns the write really
  -- changes (an insert: the columns it names), and for an unchanged column
  -- only as a later person's time (below); never for a legacy write.
  if tg_op = 'INSERT' then
    v_sent := new.field_edited_at;
  else
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
    elsif (v_new -> v_key) is not distinct from (v_old -> v_key) then
      -- An unchanged value moves its entry only when the write sent a
      -- person's time for it that is later than the one held: the same
      -- value set again, later, is the latest edit of that column. Any
      -- other entry for an unchanged column is ignored (a legacy write
      -- sends none).
      v_at := (v_entry ->> 'at')::timestamptz;
      continue when v_at is null
        or coalesce((v_entry ->> 'auto')::boolean, false)
        or v_at < c_ceiling
        or least(v_at, v_now)
           <= coalesce((v_map -> v_key ->> 'at')::timestamptz, '-infinity');
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

  -- A live child under a deleted parent is stored deleted.
  --
  -- The parents are read FOR SHARE and held until this write commits. A
  -- parent's delete (FOR NO KEY UPDATE) then waits for this write, and its
  -- cascade, which runs after that wait, sees this row and deletes it; a
  -- delete that came first makes this read wait, and it then sees the
  -- parent deleted. Without the lock the two pass each other (the foreign
  -- key's FOR KEY SHARE does not conflict with a delete) and a live child
  -- stays under a deleted parent. Reading FOR SHARE needs the UPDATE right
  -- and policy on the parent, which its owner has.
  if new.deleted_at is null then
    if tg_table_name = 'prescriptions' then
      select t.deleted_at into v_parent_deleted
        from public.treatments t where t.id = v_new->>'treatment_id' for share;
      select m.deleted_at into v_other_deleted
        from public.medications m where m.id = v_new->>'medication_id' for share;
      v_parent_deleted := coalesce(v_parent_deleted, v_other_deleted);
    elsif tg_table_name = 'dose_logs' then
      select p.deleted_at into v_parent_deleted
        from public.prescriptions p where p.id = v_new->>'prescription_id' for share;
    end if;
    if v_parent_deleted is not null then
      new.deleted_at := v_parent_deleted;
      v_app_delete := true;
    end if;
  end if;
  if v_cascade or v_app_delete then
    -- After the column times: the columns a write changes keep its time.
    new.edited_at := c_epoch;
  elsif v_wipe_delete then
    new.edited_at := v_wiped_at;
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
-- counts it as newer). Every other update is stamped now(), as before,
-- including the tombstone cascade and a 0.3.0 write (they send no write
-- id).

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
-- through any SQL surface. Hard DELETE stays, under the tables' policies
-- ("delete all data" uses medora_delete_all_data, section 8, which also
-- tells the user's other devices).
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
    'horizon', pg_snapshot_xmin(pg_current_snapshot())::text::bigint,
    'wipe', (select jsonb_build_object('generation', w.generation, 'wiped_at', w.wiped_at)
               from public.sync_wipes w where w.user_id = auth.uid())
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

-- 7. Live rows under deleted parents ---------------------------------------
--
-- Before this migration a device could leave a live child under a parent
-- deleted elsewhere (a dose generated offline, pushed after the
-- prescription was deleted). Every device would fail to store such a row.
-- They are deleted here as the app's own change (the trigger above keeps
-- it so from now on): prescriptions first, whose own tombstones cascade
-- to their doses, then the doses left. The rows updated here keep their
-- updated_at, like any other change the app makes; 0.3.0 devices already
-- dropped them with their parent. The doses the cascade reaches from a
-- prescription repaired here are a cascade write, which moves updated_at
-- (0.3.0 then pulls a tombstone for a row it no longer holds, which does
-- nothing). Running this again finds nothing.

update public.prescriptions c
   set deleted_at = coalesce(t.deleted_at, m.deleted_at),
       write_id = gen_random_uuid(),
       edited_at = timestamptz '1970-01-01 00:00:00+00'
  from public.treatments t, public.medications m
 where t.id = c.treatment_id
   and m.id = c.medication_id
   and c.deleted_at is null
   and (t.deleted_at is not null or m.deleted_at is not null);

update public.dose_logs c
   set deleted_at = p.deleted_at,
       write_id = gen_random_uuid(),
       edited_at = timestamptz '1970-01-01 00:00:00+00'
  from public.prescriptions p
 where p.id = c.prescription_id
   and c.deleted_at is null
   and p.deleted_at is not null;

-- 8. "Delete all data" -----------------------------------------------------
--
-- Removes every medication, treatment, prescription and dose of the caller,
-- and records the wipe (section 2b) in the same transaction, so every other
-- device of the account removes its copies on its next sync instead of
-- keeping them (and writing them back with a later edit). Returns
-- {"generation": g, "wiped_at": t}.
--
-- Runs with the owner's rights, so it can write the marker, which clients
-- cannot; every delete names the caller's rows exactly as the tables'
-- delete policies do (prescriptions and doses through the caller's
-- treatments). The stock ledger goes with the medications (foreign key).
-- The exclusive lock makes the caller's inserts wait for the wipe, or the
-- wipe for them (medora_sync_stamp takes the shared side), so a row
-- inserted meanwhile is either deleted here or sees this wipe.
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
  delete from public.medications where user_id = v_uid;
  return jsonb_build_object('generation', v_generation, 'wiped_at', v_at);
end;
$$;

revoke all on function public.medora_delete_all_data() from public, anon;
grant execute on function public.medora_delete_all_data() to authenticated;
