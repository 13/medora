-- Checks for supabase/migrations/20260918000000_sync_v2.sql.
-- Run by tools/check_supabase_sql.sh against a throwaway Postgres 15 with
-- tools/sql/auth_shim.sql and every migration applied. Any failed ASSERT
-- stops the script with a non-zero exit.
\set ON_ERROR_STOP on

insert into auth.users values
  ('00000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-00000000000b');

-- A row written before the migration keeps the defaults.
do $$ begin
  assert (select sync_xid = 0 and row_version = 1 and write_id is null and edited_at is null
            from medications where id = 'pre-migration'),
    'a row from before the migration keeps sync_xid 0, row_version 1';
end $$;

set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);

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
  assert r.sync_xid > 0, 'insert: sync_xid set';

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
  assert j->>'status' = 'applied' and (j->>'quantity')::int = 7, 'stock: applied ' || j;
  j := apply_stock_change('aaaaaaaa-0000-0000-0000-000000000001', 'm1', -3, null);
  assert j->>'status' = 'duplicate' and (j->>'quantity')::int = 7, 'stock: duplicate ' || j;
  assert (select quantity from medications where id = 'm1') = 7, 'stock: a retry is not counted twice';
  j := apply_stock_change('aaaaaaaa-0000-0000-0000-000000000002', 'm1', -100, null);
  assert (j->>'quantity')::int = 0, 'stock: never below zero';
  j := apply_stock_change('aaaaaaaa-0000-0000-0000-000000000003', 'm1', null, 20);
  assert (j->>'quantity')::int = 20, 'stock: counted quantity';
  j := apply_stock_change('aaaaaaaa-0000-0000-0000-000000000004', 'nope', -1, null);
  assert j->>'status' = 'missing', 'stock: unknown medication is missing';
  assert (select count(*) from stock_changes) = 3, 'stock: ledger holds the three applied changes';
  begin
    perform apply_stock_change('aaaaaaaa-0000-0000-0000-000000000006', 'm1', -1, 1);
    assert false, 'stock: both kinds must be refused';
  exception when sqlstate '22023' then null;
  end;
  update medications set deleted_at = now(), write_id = '77777777-7777-7777-7777-777777777777' where id = 'm1';
  j := apply_stock_change('aaaaaaaa-0000-0000-0000-000000000005', 'm1', -1, null);
  assert j->>'status' = 'gone', 'stock: deleted medication is gone';

  insert into medications (id, user_id, name, quantity) values ('m2', auth.uid(), 'Paracetamol', 5);
end $$;

-- Row-level security: user B.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false);
do $$
declare j jsonb;
begin
  assert (select count(*) from stock_changes) = 0, 'rls: B sees none of A''s ledger';
  j := apply_stock_change('bbbbbbbb-0000-0000-0000-000000000001', 'm2', -1, null);
  assert j->>'status' = 'missing', 'rls: B cannot change A''s stock';
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
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
do $$ begin
  assert (select quantity from medications where id = 'm2') = 5, 'rls: A''s stock untouched';
  -- The tombstone cascade still runs and counts as a real change.
  update treatments set deleted_at = now(), write_id = '88888888-8888-8888-8888-888888888888',
         edited_at = now() where id = 't1';
  assert (select deleted_at is not null and write_id is null and row_version = 2
            from prescriptions where id = 'p1'), 'cascade: child tombstoned as a legacy write';
end $$;

-- anon may call neither function.
reset role;
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
