-- Checks for supabase/migrations/20260918000000_sync_v2.sql.
-- Run by tools/check_supabase_sql.sh against a throwaway Postgres 15 with
-- tools/sql/auth_shim.sql and every migration applied. Any failed ASSERT
-- stops the script with a non-zero exit.
--
-- psql runs every top-level statement in a transaction of its own. A DO
-- block is one transaction, so every write inside it shares one xid: a
-- check that a write moves sync_xid needs the write in a later statement.
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('00000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-00000000000b');

-- A row written before the migration keeps the defaults.
do $$ begin
  assert (select sync_xid = 0 and row_version = 1 and write_id is null and edited_at is null
              and field_edited_at = '{}'
            from medications where id = 'pre-migration'),
    'a row from before the migration keeps sync_xid 0, row_version 1, an empty edit-time map';
end $$;

-- Its first update fills the edit-time map: the columns it does not change
-- were last changed no later than the row's old stamp; the one it changes
-- (a 0.3.0 write) counts as made on arrival.
update medications set notes = 'changed by 0.3.0' where id = 'pre-migration-2';
do $$
declare m jsonb;
begin
  select field_edited_at into m from medications where id = 'pre-migration-2';
  assert (m->'name'->>'at')::timestamptz = timestamptz '2026-01-01T00:00:00Z'
     and m->'name'->>'auto' = 'false',
    'fill: an unchanged column carries the row''s old updated_at ' || m::text;
  assert (m->'notes'->>'at')::timestamptz = (select updated_at from medications where id = 'pre-migration-2')
     and m->'notes'->>'auto' = 'false',
    'fill: the changed column is stamped on arrival ' || m::text;
  assert not (m ? 'quantity') and not (m ? 'updated_at') and not (m ? 'id')
     and not (m ? 'user_id') and not (m ? 'edited_at') and not (m ? 'field_edited_at'),
    'fill: bookkeeping and the stock have no edit time ' || m::text;
end $$;

-- A 0.3.0 update of that row (a later transaction) stamps it.
update medications set name = 'Old' where id = 'pre-migration';
do $$ begin
  assert (select sync_xid > 0 and row_version = 2 and write_id is null
              and edited_at > now() - interval '1 minute'
            from medications where id = 'pre-migration'),
    'update: a row from before the migration is stamped by its first update';
end $$;

-- Clients never truncate, add triggers or add foreign keys, on any table.
-- Row-level security does not cover TRUNCATE, and Supabase grants all three.
do $$
declare t text; r text; p text;
begin
  foreach t in array array['medications', 'treatments', 'prescriptions', 'dose_logs',
                           'families', 'family_members', 'stock_changes'] loop
    foreach r in array array['anon', 'authenticated'] loop
      foreach p in array array['TRUNCATE', 'TRIGGER', 'REFERENCES'] loop
        assert not has_table_privilege(r, 'public.' || t, p),
          format('grants: %s must not hold %s on %s', r, p, t);
      end loop;
    end loop;
  end loop;
  -- Trigger functions run as triggers only.
  foreach t in array array['medora_sync_stamp()', 'update_updated_at()',
                           'cascade_tombstone_treatment()', 'cascade_tombstone_medication()',
                           'cascade_tombstone_prescription()'] loop
    foreach r in array array['anon', 'authenticated'] loop
      assert not has_function_privilege(r, 'public.' || t, 'EXECUTE'),
        format('grants: %s must not execute %s', r, t);
    end loop;
  end loop;
end $$;

set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';

do $$
declare r medications%rowtype; n int;
begin
  -- 0.3.0 insert: no write id, no edit time.
  insert into medications (id, user_id, name, quantity, updated_at)
    values ('m1', auth.uid(), 'Ibuprofen', 10, '2026-09-01T08:00:00Z');
  select * into r from medications where id = 'm1';
  assert r.row_version = 1, 'insert: version 1';
  assert r.write_id is null, 'insert: no write id';
  assert r.edited_at = timestamptz '2026-09-01T08:00:00Z', 'insert: edited_at falls back to updated_at';
  assert r.updated_at = now(), 'insert: a created row is stamped on arrival';
  assert r.sync_xid = pg_current_xact_id()::text::bigint, 'insert: sync_xid is the writing transaction';

  -- A client cannot choose its own bookkeeping on insert.
  insert into medications (id, user_id, name, row_version, sync_xid)
    values ('forged', auth.uid(), 'Forged', 99, 1);
  select * into r from medications where id = 'forged';
  assert r.row_version = 1 and r.sync_xid = pg_current_xact_id()::text::bigint,
    'insert: a sent row_version and sync_xid are overwritten';

  -- 0.3.0 upsert (ON CONFLICT DO UPDATE with the payload columns only).
  insert into medications (id, user_id, name, quantity, updated_at)
    values ('m1', auth.uid(), 'Ibuprofen 400', 10, '2026-09-01T09:00:00Z')
    on conflict (id) do update
      set name = excluded.name, quantity = excluded.quantity, updated_at = excluded.updated_at;
  select * into r from medications where id = 'm1';
  assert r.row_version = 2, 'upsert: version 2';
  assert r.write_id is null, 'upsert: legacy write has no write id';
  assert r.edited_at = now(), 'upsert: a legacy edit counts as made on arrival';
  assert r.updated_at = now(), 'upsert: updated_at still moves for 0.3.0';

  -- 0.4.0 conditional update.
  update medications set notes = 'after food',
         write_id = '11111111-1111-1111-1111-111111111111', edited_at = '2026-09-16T10:00:00Z'
   where id = 'm1' and row_version = 2;
  get diagnostics n = row_count;
  assert n = 1, 'conditional update on the current version applies';
  select * into r from medications where id = 'm1';
  assert r.row_version = 3 and r.write_id = '11111111-1111-1111-1111-111111111111'
     and r.edited_at = timestamptz '2026-09-16T10:00:00Z', 'conditional update: version, write id, edit time';

  -- The same attempt again (its answer was lost): no row matches.
  update medications set notes = 'after food', write_id = '11111111-1111-1111-1111-111111111111'
   where id = 'm1' and row_version = 2;
  get diagnostics n = row_count;
  assert n = 0, 'a replayed attempt matches nothing';

  -- A clock in the future is capped.
  update medications set notes = 'x', write_id = '22222222-2222-2222-2222-222222222222',
         edited_at = '2099-01-01T00:00:00Z' where id = 'm1';
  assert (select edited_at = now() from medications where id = 'm1'), 'future edit time capped at now()';

  -- An update that repeats the stored write id is a legacy write.
  update medications set notes = 'legacy', write_id = '22222222-2222-2222-2222-222222222222' where id = 'm1';
  assert (select write_id is null from medications where id = 'm1'), 'repeated write id is cleared';

  -- Doses: a generated insert and an automatic change keep updated_at.
  insert into treatments (id, user_id, name, start_date) values ('t1', auth.uid(), 'Flu', '2026-09-10');
  insert into prescriptions (id, treatment_id, medication_id, dosage, start_time)
    values ('p1', 't1', 'm1', '1', '2026-09-10T08:00:00');
  insert into dose_logs (id, prescription_id, scheduled_time, status, updated_at, write_id, edited_at)
    values ('d1', 'p1', '2026-09-10T08:00:00Z', 'pending', '1970-01-01T00:00:00Z',
            '33333333-3333-3333-3333-333333333333', '1970-01-01T00:00:00Z');
  assert (select updated_at = timestamptz '1970-01-01T00:00:00Z' from dose_logs where id = 'd1'),
    'generated insert keeps its 1970 stamp';
  update dose_logs set status = 'missed', write_id = '44444444-4444-4444-4444-444444444444',
         edited_at = '1970-01-01T00:00:00.001Z' where id = 'd1' and row_version = 1;
  assert (select status = 'missed' and row_version = 2
              and updated_at = timestamptz '1970-01-01T00:00:00Z'
              and edited_at = timestamptz '1970-01-01T00:00:00Z'
            from dose_logs where id = 'd1'), 'automatic change: updated_at kept, edit time normalised';
  update dose_logs set status = 'taken', taken_time = now(),
         write_id = '55555555-5555-5555-5555-555555555555', edited_at = now() - interval '1 minute'
   where id = 'd1' and row_version = 2;
  assert (select status = 'taken' and updated_at = now() and row_version = 3
            from dose_logs where id = 'd1'), 'real change: updated_at moves';

  -- A guarded tombstone does not touch a taken dose.
  update dose_logs set deleted_at = now(), write_id = '66666666-6666-6666-6666-666666666666',
         edited_at = '1970-01-01T00:00:00Z'
   where id = 'd1' and status = 'pending' and deleted_at is null;
  get diagnostics n = row_count;
  assert n = 0, 'guarded tombstone skips a taken dose';
end $$;

-- Edit times per column (field_edited_at). Every statement below is a
-- transaction of its own, so each has its own now(); a real update stamps
-- updated_at with that now(), which the checks use as "when it arrived".
-- pg_temp.at(id, column) is the entry's time, pg_temp.auto(id, column) its
-- flag.
create function pg_temp.at(p_id text, p_col text) returns timestamptz language sql as $$
  select (field_edited_at->p_col->>'at')::timestamptz from treatments where id = p_id
$$;
create function pg_temp.auto(p_id text, p_col text) returns boolean language sql as $$
  select (field_edited_at->p_col->>'auto')::boolean from treatments where id = p_id
$$;
create function pg_temp.arrived(p_id text) returns timestamptz language sql as $$
  select updated_at from treatments where id = p_id
$$;
create function pg_temp.entry(p_at timestamptz, p_auto boolean default false) returns jsonb
  language sql as $$ select jsonb_build_object('at', p_at, 'auto', p_auto) $$;

-- A 0.4.0 insert sends its map: a future time is capped at arrival, a time
-- before 1970-01-02 is automatic, bookkeeping and unknown keys are dropped,
-- a column it names no time for has no entry.
insert into treatments (id, user_id, name, start_date, notes, sick_leave_ref, doctor,
                        write_id, edited_at, field_edited_at)
  values ('ft', auth.uid(), 'Flu', '2026-09-10', 'n0', 'R0', 'Dr. A',
          'f0000000-0000-0000-0000-000000000001', now() - interval '5 hours',
          jsonb_build_object(
            'name', pg_temp.entry(now() - interval '5 hours'),
            'notes', pg_temp.entry(now() - interval '5 hours'),
            'sick_leave_ref', pg_temp.entry('2099-01-01T00:00:00Z'),
            'doctor', pg_temp.entry('1970-01-01T00:00:00.5Z'),
            'updated_at', pg_temp.entry(now()),
            'no_such_column', pg_temp.entry(now())));
do $$
declare m jsonb := (select field_edited_at from treatments where id = 'ft');
begin
  assert pg_temp.at('ft', 'name') < pg_temp.arrived('ft') - interval '4 hours'
     and not pg_temp.auto('ft', 'name'), 'map insert: a sent time is kept ' || m::text;
  assert pg_temp.at('ft', 'sick_leave_ref') = pg_temp.arrived('ft'),
    'map insert: a future time is capped at arrival ' || m::text;
  assert pg_temp.at('ft', 'doctor') = timestamptz '1970-01-01T00:00:00Z' and pg_temp.auto('ft', 'doctor'),
    'map insert: a time before 1970-01-02 is an automatic change ' || m::text;
  assert not (m ? 'updated_at') and not (m ? 'no_such_column') and not (m ? 'end_date'),
    'map insert: only the sent data columns have an entry ' || m::text;
end $$;
-- A 0.3.0 insert has an empty map: the row's edited_at stands for every column.
insert into treatments (id, user_id, name, start_date) values ('ft-legacy', auth.uid(), 'Old', '2026-09-10');
do $$ begin
  assert (select field_edited_at = '{}' from treatments where id = 'ft-legacy'),
    'map insert: a 0.3.0 insert has an empty map';
end $$;

-- Device A changes notes (its "10:00").
update treatments set notes = 'A', write_id = 'f0000000-0000-0000-0000-00000000000a',
       edited_at = now() - interval '1 hour',
       field_edited_at = jsonb_build_object('notes', pg_temp.entry(now() - interval '1 hour'))
 where id = 'ft';
do $$ begin
  assert pg_temp.at('ft', 'notes') between pg_temp.arrived('ft') - interval '61 minutes'
                                       and pg_temp.arrived('ft') - interval '59 minutes',
    'map: a later time replaces the entry';
end $$;
create temp table ft_a as select pg_temp.at('ft', 'notes') as notes_at;

-- Device B, offline, changed sick_leave_from earlier (its "09:00").
update treatments set sick_leave_from = '2026-09-11', write_id = 'f0000000-0000-0000-0000-00000000000b',
       edited_at = now() - interval '4 hours',
       field_edited_at = jsonb_build_object('sick_leave_from', pg_temp.entry(now() - interval '4 hours'))
 where id = 'ft';
do $$ begin
  assert pg_temp.at('ft', 'notes') = (select notes_at from ft_a),
    'map: a change to another column leaves the notes entry alone';
  assert pg_temp.at('ft', 'sick_leave_from') < pg_temp.arrived('ft') - interval '3 hours',
    'map: B''s column gets B''s time';
  assert (select edited_at from treatments where id = 'ft') < pg_temp.at('ft', 'notes'),
    'map: the row''s edited_at is the last write''s time, the entries keep their own';
end $$;

-- Device C writes notes with an older time (its "09:30"): the value lands
-- (the client merged first), the entry never goes back.
update treatments set notes = 'C', write_id = 'f0000000-0000-0000-0000-00000000000c',
       edited_at = now() - interval '3 hours',
       field_edited_at = jsonb_build_object('notes', pg_temp.entry(now() - interval '3 hours'))
 where id = 'ft';
do $$ begin
  assert (select notes from treatments where id = 'ft') = 'C', 'map: the older write still lands';
  assert pg_temp.at('ft', 'notes') = (select notes_at from ft_a),
    'map: an older time never overwrites the entry';
end $$;

-- A future time is capped when it arrives.
update treatments set notes = 'D', write_id = 'f0000000-0000-0000-0000-00000000000d',
       edited_at = now(), field_edited_at = jsonb_build_object('notes', pg_temp.entry('2099-01-01T00:00:00Z'))
 where id = 'ft';
do $$ begin
  assert pg_temp.at('ft', 'notes') = pg_temp.arrived('ft'), 'map: a future time is capped at arrival';
  assert not pg_temp.auto('ft', 'notes'), 'map: a person''s change';
end $$;
create temp table ft_d as select pg_temp.at('ft', 'notes') as notes_at, pg_temp.arrived('ft') as arrived;

-- An automatic change of notes: marked automatic, the time stays, and
-- updated_at stays too (0.3.0 must not see it).
update treatments set notes = 'auto', write_id = 'f0000000-0000-0000-0000-0000000000a1',
       edited_at = '1970-01-01T00:00:00Z',
       field_edited_at = jsonb_build_object('notes', pg_temp.entry('1970-01-01T00:00:00Z', true))
 where id = 'ft';
do $$ begin
  assert pg_temp.auto('ft', 'notes'), 'map: an automatic change is marked automatic';
  assert pg_temp.at('ft', 'notes') = (select notes_at from ft_d), 'map: an automatic change keeps the time';
  assert pg_temp.arrived('ft') = (select arrived from ft_d), 'map: an automatic change keeps updated_at';
end $$;
-- A flag sent with a real time is automatic as well.
update treatments set doctor = 'Dr. auto', write_id = 'f0000000-0000-0000-0000-0000000000a2',
       edited_at = '1970-01-01T00:00:00Z',
       field_edited_at = jsonb_build_object('doctor', pg_temp.entry(now(), true))
 where id = 'ft';
do $$ begin
  assert pg_temp.auto('ft', 'doctor') and pg_temp.at('ft', 'doctor') = timestamptz '1970-01-01T00:00:00Z',
    'map: an automatic flag with a real time is automatic';
end $$;

-- One write, three columns: each gets the time sent for it (one of them
-- the app's own), a column sent without one the row's; the rest keep the
-- time the row had when it was inserted.
insert into treatments (id, user_id, name, start_date, write_id, edited_at)
  values ('ft2', auth.uid(), 'Cold', '2026-09-10', 'f0000000-0000-0000-0000-0000000000c1',
          now() - interval '6 hours');
update treatments set notes = 'n', end_date = '2026-09-13', sick_leave_ref = 'R',
       write_id = 'f0000000-0000-0000-0000-0000000000c2',
       edited_at = now() - interval '10 minutes',
       field_edited_at = jsonb_build_object(
         'notes', pg_temp.entry(now() - interval '2 hours'),
         'end_date', pg_temp.entry(now() - interval '10 minutes', true))
 where id = 'ft2';
do $$ begin
  assert pg_temp.at('ft2', 'notes') between pg_temp.arrived('ft2') - interval '121 minutes'
                                        and pg_temp.arrived('ft2') - interval '119 minutes'
     and not pg_temp.auto('ft2', 'notes'),
    'map: a column gets the time sent for it, not the row''s';
  assert pg_temp.auto('ft2', 'end_date'),
    'map: the app''s own column in a person''s write is automatic';
  assert pg_temp.at('ft2', 'sick_leave_ref') between pg_temp.arrived('ft2') - interval '11 minutes'
                                                 and pg_temp.arrived('ft2') - interval '9 minutes',
    'map: a column sent without a time takes the row''s';
  assert pg_temp.at('ft2', 'name') < pg_temp.arrived('ft2') - interval '5 hours'
     and pg_temp.at('ft2', 'end_date') = pg_temp.at('ft2', 'name'),
    'map: the first update fills the rest from the inserted row''s time';
end $$;

-- A person's change after it: no longer automatic; the time never goes back.
update treatments set notes = 'E', write_id = 'f0000000-0000-0000-0000-00000000000e',
       edited_at = now() - interval '2 hours',
       field_edited_at = jsonb_build_object('notes', pg_temp.entry(now() - interval '2 hours'))
 where id = 'ft';
do $$ begin
  assert not pg_temp.auto('ft', 'notes'), 'map: a person''s change clears the automatic flag';
  assert pg_temp.at('ft', 'notes') = (select notes_at from ft_d), 'map: and keeps the later time';
end $$;

-- An entry for a column the write does not change is ignored; a column it
-- changes without an entry takes the row's edited_at; a map that is not
-- an object counts as none.
update treatments set name = 'Flu', doctor = 'Dr. B', write_id = 'f0000000-0000-0000-0000-0000000000f1',
       edited_at = now() - interval '30 minutes',
       field_edited_at = jsonb_build_object('name', pg_temp.entry(now()))
 where id = 'ft';
do $$ begin
  assert pg_temp.at('ft', 'name') < pg_temp.arrived('ft') - interval '4 hours',
    'map: an entry for an unchanged column is ignored';
  assert pg_temp.at('ft', 'doctor') between pg_temp.arrived('ft') - interval '31 minutes'
                                        and pg_temp.arrived('ft') - interval '29 minutes'
     and not pg_temp.auto('ft', 'doctor'),
    'map: a changed column with no entry takes the row''s edit time';
end $$;
update treatments set doctor = 'Dr. C', write_id = 'f0000000-0000-0000-0000-0000000000f2',
       edited_at = now() - interval '10 minutes', field_edited_at = '["doctor"]'
 where id = 'ft';
do $$ begin
  assert pg_temp.at('ft', 'doctor') < pg_temp.arrived('ft') - interval '9 minutes',
    'map: a map that is not an object counts as none';
  assert (select jsonb_typeof(field_edited_at) from treatments where id = 'ft') = 'object',
    'map: the stored map stays an object';
end $$;

-- A 0.3.0 upsert (whole row): only the columns it really changes are
-- stamped, on arrival; a map it cannot send is never read.
create temp table ft_before as select field_edited_at as m from treatments where id = 'ft';
insert into treatments (id, user_id, name, start_date, notes, end_date, updated_at)
  values ('ft', auth.uid(), 'Flu', '2026-09-10', 'E', '2026-09-12', '2026-09-01T00:00:00Z')
  on conflict (id) do update
    set name = excluded.name, start_date = excluded.start_date, notes = excluded.notes,
        end_date = excluded.end_date, updated_at = excluded.updated_at;
do $$ begin
  assert pg_temp.at('ft', 'end_date') = pg_temp.arrived('ft') and not pg_temp.auto('ft', 'end_date'),
    'map legacy: a changed column is stamped on arrival';
  assert (select field_edited_at - 'end_date' from treatments where id = 'ft') = (select m from ft_before),
    'map legacy: unchanged columns keep their entries';
end $$;
update treatments set notes = 'F',
       field_edited_at = jsonb_build_object('notes', pg_temp.entry('2000-01-01T00:00:00Z'))
 where id = 'ft';
do $$ begin
  assert pg_temp.at('ft', 'notes') = pg_temp.arrived('ft'),
    'map legacy: a writer without a new write id is stamped on arrival, whatever map it sets';
  assert (select write_id is null from treatments where id = 'ft'), 'map legacy: write id cleared';
end $$;

-- Every update moves sync_xid: the pull finds a changed row only by it.
-- `seen` holds the cursor each row had before the next write.
create temp table seen (id text primary key, xid bigint, version bigint);
create function pg_temp.remember(p_id text) returns void language sql as $$
  insert into seen
    select id, sync_xid, row_version from medications where id = p_id
    union all select id, sync_xid, row_version from dose_logs where id = p_id
    union all select id, sync_xid, row_version from prescriptions where id = p_id
  on conflict (id) do update set xid = excluded.xid, version = excluded.version
$$;
create function pg_temp.moved(p_id text) returns boolean language sql as $$
  select coalesce(
    (select m.sync_xid > s.xid and m.row_version = s.version + 1
       from (select id, sync_xid, row_version from medications
             union all select id, sync_xid, row_version from dose_logs
             union all select id, sync_xid, row_version from prescriptions) m
       join seen s using (id)
      where m.id = p_id),
    false)
$$;

select pg_temp.remember('m1') \g /dev/null
update medications set name = name where id = 'm1';
do $$ begin
  assert pg_temp.moved('m1'), 'update: a no-change update moves sync_xid';
end $$;

select pg_temp.remember('m1') \g /dev/null
insert into medications (id, user_id, name, quantity, updated_at)
  values ('m1', auth.uid(), 'Ibuprofen 400', 10, '2026-09-01T09:00:00Z')
  on conflict (id) do update
    set name = excluded.name, quantity = excluded.quantity, updated_at = excluded.updated_at;
do $$ begin
  assert pg_temp.moved('m1'), 'update: a 0.3.0 upsert moves sync_xid';
end $$;

select pg_temp.remember('m1') \g /dev/null
update medications set notes = 'v2', write_id = '12121212-1212-1212-1212-121212121212',
       edited_at = now() where id = 'm1';
do $$ begin
  assert pg_temp.moved('m1'), 'update: a 0.4.0 update moves sync_xid';
end $$;

select pg_temp.remember('d1') \g /dev/null
update dose_logs set notes = 'auto', write_id = '13131313-1313-1313-1313-131313131313',
       edited_at = '1970-01-01T00:00:00Z' where id = 'd1';
do $$ begin
  assert pg_temp.moved('d1'), 'update: an automatic change moves sync_xid (updated_at does not)';
end $$;

-- The horizon, read in a transaction of its own (as PostgREST does), is
-- above every finished write. Inside the writing transaction it would not
-- be: a transaction's own rows are not finished yet.
do $$ begin
  assert (medora_sync_state()->>'schema')::int = 2, 'schema 2';
  assert (medora_sync_state()->>'horizon')::bigint > (select max(sync_xid) from dose_logs),
    'horizon above finished writes';
end $$;

-- Stock changes.
do $$
declare j jsonb;
begin
  j := apply_stock_change('aaaaaaaa-0000-0000-0000-000000000001', 'm1', -3, null);
  assert j->>'status' = 'applied' and (j->>'quantity')::int = 7, 'stock: applied ' || j::text;
  j := apply_stock_change('aaaaaaaa-0000-0000-0000-000000000001', 'm1', -3, null);
  assert j->>'status' = 'duplicate' and (j->>'quantity')::int = 7, 'stock: duplicate ' || j::text;
  assert (select quantity from medications where id = 'm1') = 7, 'stock: a retry is not counted twice';
  j := apply_stock_change('aaaaaaaa-0000-0000-0000-000000000002', 'm1', -100, null);
  assert (j->>'quantity')::int = 0, 'stock: never below zero';
  j := apply_stock_change('aaaaaaaa-0000-0000-0000-000000000003', 'm1', null, 20);
  assert (j->>'quantity')::int = 20, 'stock: counted quantity';
  j := apply_stock_change('aaaaaaaa-0000-0000-0000-000000000004', 'nope', -1, null);
  assert j->>'status' = 'gone', 'stock: a medication the server does not have is gone ' || j::text;
  assert (select count(*) from stock_changes) = 3, 'stock: ledger holds the three applied changes';
  begin
    perform apply_stock_change('aaaaaaaa-0000-0000-0000-000000000006', 'm1', -1, 1);
    assert false, 'stock: both kinds must be refused';
  exception when sqlstate '22023' then null;
  end;
  begin
    insert into stock_changes (op_id, medication_id, delta, quantity_after)
      values ('aaaaaaaa-0000-0000-0000-000000000007', 'm1', -1, -500);
    assert false, 'stock: a ledger row never holds a quantity out of range';
  exception when check_violation then null;
  end;
end $$;

-- Values out of range are brought into range before they are recorded, so
-- a change is never refused for good (the same table is in
-- test/helpers/fake_server_test.dart).
do $$
declare j jsonb;
begin
  j := apply_stock_change('abababab-0000-0000-0000-000000000001', 'm1', null, -1);
  assert j->>'status' = 'applied' and (j->>'quantity')::int = 0, 'range: set_to -1 counts as 0 ' || j::text;
  j := apply_stock_change('abababab-0000-0000-0000-000000000002', 'm1', null, 1000000);
  assert (j->>'quantity')::int = 999999, 'range: set_to 1000000 counts as 999999 ' || j::text;
  j := apply_stock_change('abababab-0000-0000-0000-000000000003', 'm1', null, 2147483647);
  assert (j->>'quantity')::int = 999999, 'range: the largest set_to counts as 999999 ' || j::text;
  j := apply_stock_change('abababab-0000-0000-0000-000000000004', 'm1', 2147483647, null);
  assert j->>'status' = 'applied' and (j->>'quantity')::int = 999999, 'range: the largest delta ' || j::text;
  j := apply_stock_change('abababab-0000-0000-0000-000000000005', 'm1', -2147483648, null);
  assert (j->>'quantity')::int = 0, 'range: the smallest delta ' || j::text;
  j := apply_stock_change('abababab-0000-0000-0000-000000000006', 'm1', null, 5);
  j := apply_stock_change('abababab-0000-0000-0000-000000000007', 'm1', 1000000, null);
  assert (j->>'quantity')::int = 999999, 'range: a delta above the limit ' || j::text;
  j := apply_stock_change('abababab-0000-0000-0000-000000000007', 'm1', 1000000, null);
  assert j->>'status' = 'duplicate' and (j->>'quantity')::int = 999999, 'range: its retry is a duplicate ' || j::text;
  assert (select delta = 999999 and set_to is null and quantity_after = 999999
            from stock_changes where op_id = 'abababab-0000-0000-0000-000000000007'),
    'range: the ledger records the value in range';
  assert (select set_to = 0 from stock_changes where op_id = 'abababab-0000-0000-0000-000000000001'),
    'range: the ledger records set_to in range';
  -- A quantity out of range stored by an older client.
  update medications set quantity = -5 where id = 'm1';
  j := apply_stock_change('abababab-0000-0000-0000-000000000008', 'm1', 3, null);
  assert (j->>'quantity')::int = 0, 'range: -5 plus 3 is 0 ' || j::text;
  update medications set quantity = 2000000 where id = 'm1';
  j := apply_stock_change('abababab-0000-0000-0000-000000000009', 'm1', -2000000, null);
  assert (j->>'quantity')::int = 999999, 'range: 2000000 minus at most 999999, capped ' || j::text;
  j := apply_stock_change('abababab-0000-0000-0000-000000000010', 'm1', null, 20);
  assert (j->>'quantity')::int = 20, 'range: back to 20 ' || j::text;
end $$;

-- A stock change moves sync_xid and the version, and leaves the edit-time
-- map alone: the stock is the server's, not a column the merge compares.
select pg_temp.remember('m1') \g /dev/null
create temp table m1_before as select field_edited_at as m from medications where id = 'm1';
select apply_stock_change('acacacac-0000-0000-0000-000000000001', 'm1', -1, null) \g /dev/null
do $$ begin
  assert pg_temp.moved('m1'), 'stock: a change moves sync_xid';
  assert (select quantity from medications where id = 'm1') = 19, 'stock: 20 minus 1';
  assert (select field_edited_at from medications where id = 'm1') = (select m from m1_before)
     and (select m from m1_before) <> '{}',
    'stock: the edit-time map is unchanged';
end $$;

-- A medication removed from the server (a purge, or "delete all data")
-- answers gone for ever: a retry and any new change are dropped.
do $$
declare j jsonb;
begin
  insert into medications (id, user_id, name, quantity) values ('purged', auth.uid(), 'Purged', 5);
  j := apply_stock_change('adadadad-0000-0000-0000-000000000001', 'purged', -1, null);
  assert j->>'status' = 'applied', 'purge: applied first ' || j::text;
end $$;
delete from medications where id = 'purged';
do $$
declare j jsonb;
begin
  assert (select count(*) from stock_changes where medication_id = 'purged') = 0,
    'purge: the ledger follows the medication';
  j := apply_stock_change('adadadad-0000-0000-0000-000000000001', 'purged', -1, null);
  assert j = '{"status": "gone"}', 'purge: a retry is gone ' || j::text;
  j := apply_stock_change('adadadad-0000-0000-0000-000000000002', 'purged', null, 3);
  assert j = '{"status": "gone"}', 'purge: a new change is gone ' || j::text;
end $$;

do $$
declare j jsonb;
begin
  update medications set deleted_at = now(), write_id = '77777777-7777-7777-7777-777777777777' where id = 'm1';
  j := apply_stock_change('aaaaaaaa-0000-0000-0000-000000000005', 'm1', -1, null);
  assert j = '{"status": "gone"}', 'stock: deleted medication is gone ' || j::text;

  insert into medications (id, user_id, name, quantity) values ('m2', auth.uid(), 'Paracetamol', 5);
  insert into medications (id, user_id, name, quantity) values ('lock-med', auth.uid(), 'Lock', 10);
end $$;

-- Row-level security: user B.
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000b';
do $$
declare j jsonb;
begin
  assert (select count(*) from stock_changes) = 0, 'rls: B sees none of A''s ledger';
  j := apply_stock_change('bbbbbbbb-0000-0000-0000-000000000001', 'm2', -1, null);
  assert j = '{"status": "gone"}', 'rls: B cannot change A''s stock, and learns nothing ' || j::text;
  begin
    insert into stock_changes (op_id, medication_id, delta, quantity_after)
      values ('bbbbbbbb-0000-0000-0000-000000000002', 'm2', -1, 0);
    assert false, 'rls: B must not append to A''s ledger';
  exception when insufficient_privilege then null;
  end;
  -- Clients only append. Row-level security does not cover TRUNCATE, so the
  -- right itself must be gone (Supabase grants every right on new tables).
  begin
    truncate stock_changes;
    assert false, 'grants: a client must not truncate the ledger';
  exception when insufficient_privilege then null;
  end;
  begin
    update stock_changes set quantity_after = 0;
    assert false, 'grants: a client must not update the ledger';
  exception when insufficient_privilege then null;
  end;
  begin
    delete from stock_changes;
    assert false, 'grants: a client must not delete from the ledger';
  exception when insufficient_privilege then null;
  end;
  -- The same for the data tables: TRUNCATE would wipe every user's rows.
  begin
    truncate dose_logs;
    assert false, 'grants: a client must not truncate dose_logs';
  exception when insufficient_privilege then null;
  end;
  begin
    truncate prescriptions cascade;
    assert false, 'grants: a client must not truncate prescriptions';
  exception when insufficient_privilege then null;
  end;
  begin
    create trigger b_trigger before update on medications
      for each row execute function cascade_tombstone_medication();
    assert false, 'grants: a client must not add a trigger';
  exception when insufficient_privilege then null;
  end;
end $$;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
do $$ begin
  assert (select quantity from medications where id = 'm2') = 5, 'rls: A''s stock untouched';
end $$;

-- The tombstone cascade still runs (m1's delete above already tombstoned
-- p1), counts as a real change and moves the child's sync_xid.
do $$ begin
  update treatments set deleted_at = now(), write_id = '88888888-8888-8888-8888-888888888888',
         edited_at = now() where id = 't1';
  assert (select deleted_at is not null and write_id is null and row_version = 2
            from prescriptions where id = 'p1'), 'cascade: child tombstoned as a legacy write';
  assert (select not (field_edited_at ? 'deleted_at') and field_edited_at ? 'dosage'
            from prescriptions where id = 'p1'), 'cascade: a tombstone has no edit time of its own';
  insert into treatments (id, user_id, name, start_date) values ('t2', auth.uid(), 'Cold', '2026-09-10');
  insert into prescriptions (id, treatment_id, medication_id, dosage, start_time)
    values ('p2', 't2', 'm2', '1', '2026-09-10T08:00:00');
end $$;
select pg_temp.remember('p2') \g /dev/null
update treatments set deleted_at = now(), write_id = '89898989-8989-8989-8989-898989898989',
       edited_at = now() where id = 't2';
do $$ begin
  assert pg_temp.moved('p2'), 'cascade: the child''s sync_xid moves';
end $$;

-- Families, as the app uses them (family_remote_datasource.dart).
insert into families (id, name, invite_code, owner_id)
  values ('f1', 'Home', 'INVITE1', auth.uid())
  on conflict (id) do update set name = excluded.name, invite_code = excluded.invite_code;
insert into families (id, name, invite_code, owner_id)
  values ('f1', 'Home 2', 'INVITE1', auth.uid())
  on conflict (id) do update set name = excluded.name, invite_code = excluded.invite_code;
insert into family_members (id, family_id, user_id, display_name, role)
  values ('fm-a', 'f1', auth.uid(), 'A', 'owner')
  on conflict (id) do update set display_name = excluded.display_name, role = excluded.role;
update family_members set display_name = 'Anna' where id = 'fm-a';
update families set name = 'Home 3' where id = 'f1';
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000b';
do $$
declare j json;
begin
  j := join_family('INVITE1', 'Bea');
  assert j->'family'->>'id' = 'f1' and j->'member'->>'display_name' = 'Bea', 'family: B joins ' || j::text;
  assert (select count(*) from families where id = 'f1') = 1, 'family: B sees the family';
  update family_members set display_name = 'Bee' where user_id = auth.uid();
  delete from family_members where user_id = auth.uid();
  assert (select count(*) from family_members where user_id = auth.uid()) = 0, 'family: B leaves';
end $$;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
delete from family_members where id = 'fm-a';
delete from families where id = 'f1';
do $$ begin
  assert (select count(*) from families) = 0, 'family: A deletes the family';
end $$;

-- A retry racing its original is checked by tools/check_supabase_sql.sh;
-- it needs lock-med, so "delete all data" below is B's.
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000b';
do $$ begin
  insert into medications (id, user_id, name, quantity) values ('b-med', auth.uid(), 'B', 3);
  insert into treatments (id, user_id, name, start_date) values ('b-t', auth.uid(), 'B', '2026-09-10');
  insert into prescriptions (id, treatment_id, medication_id, dosage, start_time)
    values ('b-p', 'b-t', 'b-med', '1', '2026-09-10T08:00:00');
  insert into dose_logs (id, prescription_id, scheduled_time) values ('b-d', 'b-p', '2026-09-10T08:00:00Z');
  perform apply_stock_change('bdbdbdbd-0000-0000-0000-000000000001', 'b-med', -1, null);
end $$;
-- "Delete all data" (settings_dialogs.dart): hard deletes in FK order.
delete from dose_logs where id <> '';
delete from prescriptions where id <> '';
delete from treatments where id <> '';
delete from medications where id <> '';
do $$ begin
  assert (select count(*) from medications) + (select count(*) from treatments)
       + (select count(*) from prescriptions) + (select count(*) from dose_logs)
       + (select count(*) from stock_changes) = 0, 'delete all: B has nothing left';
  assert apply_stock_change('bdbdbdbd-0000-0000-0000-000000000001', 'b-med', -1, null)
       = '{"status": "gone"}', 'delete all: a queued change is gone';
end $$;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
do $$ begin
  assert (select count(*) from medications where id in ('m1', 'm2', 'lock-med')) = 3,
    'delete all: A''s rows untouched';
end $$;

-- Seen without row-level security: the removed medications' ledger rows
-- are really gone ("delete all data" leaves nothing behind).
reset role;
do $$ begin
  assert (select count(*) from stock_changes where medication_id in ('purged', 'b-med')) = 0,
    'purge: no ledger row outlives its medication';
end $$;

-- anon may call neither function.
set role anon;
do $$ begin
  begin
    perform medora_sync_state();
    assert false, 'anon must not read the sync state';
  exception when insufficient_privilege then null;
  end;
  begin
    perform apply_stock_change('cccccccc-0000-0000-0000-000000000001', 'm2', -1, null);
    assert false, 'anon must not change stock';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
select 'sync_v2 checks passed' as result;
