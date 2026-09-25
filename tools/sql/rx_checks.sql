-- Checks for supabase/migrations/20260923000000_rx.sql (persons, rx,
-- rx_dispensings). Run by tools/check_supabase_sql.sh after
-- sync_v2_checks.sql, with every migration applied. Any failed ASSERT stops
-- the script with a non-zero exit.
--
-- Users D and E of their own: "delete all data" below must not touch the
-- rows the later checks in tools/check_supabase_sql.sh expect of user A.
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('00000000-0000-0000-0000-00000000000d'),
  ('00000000-0000-0000-0000-00000000000e');

-- BEFORE triggers of one event fire in name order: the parent check must
-- run after the stamp (which would otherwise take its 1970 edit time for a
-- person's) and before updated_at.
do $$
declare names text[];
begin
  select array_agg(tgname::text order by tgname) into names
    from pg_trigger
   where tgrelid = 'public.rx_dispensings'::regclass
     and not tgisinternal
     and tgtype & 2 = 2; -- BEFORE
  assert names = array['rx_dispensings_sync_stamp', 'rx_dispensings_sync_stamp_parent',
                       'rx_dispensings_updated_at'],
    'triggers: rx_dispensings BEFORE triggers in the wrong order ' || names::text;
end $$;

-- Clients never truncate, add triggers or add foreign keys; the trigger
-- functions run as triggers only.
do $$
declare t text; r text; p text;
begin
  foreach t in array array['persons', 'rx', 'rx_dispensings'] loop
    foreach r in array array['anon', 'authenticated'] loop
      foreach p in array array['TRUNCATE', 'TRIGGER', 'REFERENCES'] loop
        assert not has_table_privilege(r, 'public.' || t, p),
          format('grants: %s must not hold %s on %s', r, p, t);
      end loop;
    end loop;
  end loop;
  foreach t in array array['medora_rx_dispensing_parent()', 'cascade_tombstone_rx()'] loop
    foreach r in array array['anon', 'authenticated'] loop
      assert not has_function_privilege(r, 'public.' || t, 'EXECUTE'),
        format('grants: %s must not execute %s', r, t);
    end loop;
  end loop;
end $$;

set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000d';

insert into persons (id, user_id, name, write_id, edited_at)
  values ('rx-person', auth.uid(), 'Anna', gen_random_uuid(), now());
insert into rx (id, user_id, person_id, kind, issued_on, items, write_id, edited_at)
  values ('rx-1', auth.uid(), 'rx-person', 'ssn', '2026-09-01',
          '[{"id": "i1", "name": "Tachipirina", "packs": 2}]', gen_random_uuid(), now()),
         ('rx-2', auth.uid(), 'rx-person', 'white', '2026-09-01', '[]', gen_random_uuid(), now());
insert into rx_dispensings (id, user_id, rx_id, item_id, packs, dispensed_on, write_id, edited_at)
  values ('rx-d1', auth.uid(), 'rx-1', 'i1', 1, '2026-09-02', gen_random_uuid(), now()),
         ('rx-d2', auth.uid(), 'rx-2', 'i1', 1, '2026-09-02', gen_random_uuid(), now());

do $$ begin
  assert (select count(*) from rx_dispensings where rx_id = 'rx-1' and deleted_at is null
             and row_version = 1 and sync_xid > 0) = 1,
    'insert: a dispensing under a live prescription lands live and stamped';
end $$;

-- A white electronic prescription's PIN is 5 letters or digits, or absent.
do $$ begin
  begin
    insert into rx (id, user_id, kind, issued_on, pin, write_id, edited_at)
      values ('rx-pin-bad', auth.uid(), 'white', '2026-09-01', 'bad!', gen_random_uuid(), now());
    assert false, 'check: pin must be 5 letters or digits';
  exception when check_violation then null;
  end;
end $$;
update rx set pin = '7XQ2K', write_id = gen_random_uuid(), edited_at = now() where id = 'rx-2';
do $$ begin
  assert (select pin from rx where id = 'rx-2') = '7XQ2K', 'pin: a valid PIN is stored';
end $$;

-- Row-level security: user E sees none of D's rows and cannot hang a
-- dispensing on D's prescription, neither new nor by moving its own.
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000e';
insert into rx (id, user_id, kind, issued_on, write_id, edited_at)
  values ('rx-e', auth.uid(), 'white', '2026-09-01', gen_random_uuid(), now());
insert into rx_dispensings (id, user_id, rx_id, item_id, packs, dispensed_on, write_id, edited_at)
  values ('rx-e-d', auth.uid(), 'rx-e', 'i1', 1, '2026-09-02', gen_random_uuid(), now());
do $$ begin
  assert (select count(*) from persons) = 0, 'rls: E sees none of D''s persons';
  assert (select count(*) from rx) = 1, 'rls: E sees only its own prescription';
  assert (select count(*) from rx_dispensings) = 1, 'rls: E sees only its own dispensing';
  begin
    insert into rx_dispensings (id, user_id, rx_id, item_id, packs, dispensed_on)
      values ('rx-e-d2', auth.uid(), 'rx-1', 'i1', 1, '2026-09-02');
    assert false, 'rls: E must not add a dispensing to D''s prescription';
  exception when insufficient_privilege then null;
  end;
  begin
    update rx_dispensings set rx_id = 'rx-1', write_id = gen_random_uuid(), edited_at = now()
     where id = 'rx-e-d';
    assert false, 'rls: E must not move its dispensing to D''s prescription';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into rx (id, user_id, kind, issued_on) values ('rx-e2', '00000000-0000-0000-0000-00000000000d', 'white', '2026-09-01');
    assert false, 'rls: E must not write a prescription as D';
  exception when insufficient_privilege then null;
  end;
  update rx set notes = 'x' where id = 'rx-1';
  assert not found, 'rls: E must not change D''s prescription';
  delete from rx_dispensings where id = 'rx-d1';
  assert not found, 'rls: E must not delete D''s dispensing';
end $$;
-- Its own dispensing may still move between its own prescriptions.
insert into rx (id, user_id, kind, issued_on, write_id, edited_at)
  values ('rx-e3', auth.uid(), 'white', '2026-09-01', gen_random_uuid(), now());
update rx_dispensings set rx_id = 'rx-e3', write_id = gen_random_uuid(), edited_at = now()
 where id = 'rx-e-d';
do $$ begin
  assert (select rx_id = 'rx-e3' from rx_dispensings where id = 'rx-e-d'),
    'rls: E moves its dispensing between its own prescriptions';
end $$;

-- A prescription's tombstone takes its dispensings with it, as the app's
-- own change.
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000d';
update rx set deleted_at = now(), write_id = gen_random_uuid(), edited_at = now()
 where id = 'rx-1';
do $$ begin
  assert (select deleted_at = (select deleted_at from rx where id = 'rx-1')
              and edited_at = timestamptz '1970-01-01T00:00:00Z'
              and row_version = 2
            from rx_dispensings where id = 'rx-d1'),
    'cascade: the prescription''s tombstone deletes its dispensing as the app''s own';
  assert (select deleted_at is null from rx_dispensings where id = 'rx-d2'),
    'cascade: another prescription''s dispensing stays live';
end $$;

-- A device that has not heard of the delete sends a live dispensing, or
-- brings the deleted one back: both are stored deleted, as the app's own.
insert into rx_dispensings (id, user_id, rx_id, item_id, packs, dispensed_on, write_id, edited_at)
  values ('rx-d3', auth.uid(), 'rx-1', 'i1', 1, '2026-09-03', gen_random_uuid(), now());
update rx_dispensings set deleted_at = null, pharmacy = 'Farmacia', write_id = gen_random_uuid(),
       edited_at = now()
 where id = 'rx-d1';
do $$ begin
  assert (select deleted_at = (select deleted_at from rx where id = 'rx-1')
              and edited_at = timestamptz '1970-01-01T00:00:00Z'
            from rx_dispensings where id = 'rx-d3'),
    'parent: a live dispensing under a deleted prescription is stored deleted';
  assert (select deleted_at is not null and edited_at = timestamptz '1970-01-01T00:00:00Z'
            from rx_dispensings where id = 'rx-d1'),
    'parent: a dispensing brought back under a deleted prescription stays deleted';
end $$;

-- "Delete all data" removes the caller's prescriptions, and only those.
select medora_delete_all_data() \g /dev/null
do $$ begin
  assert (select count(*) from persons) = 0, 'delete all: D''s persons are gone';
  assert (select count(*) from rx) = 0, 'delete all: D''s prescriptions are gone';
  assert (select count(*) from rx_dispensings) = 0, 'delete all: D''s dispensings are gone';
end $$;
reset role;
do $$ begin
  assert (select count(*) from rx where user_id = '00000000-0000-0000-0000-00000000000d') = 0,
    'delete all: none of D''s prescriptions left, seen without row-level security';
  assert (select count(*) from rx where user_id = '00000000-0000-0000-0000-00000000000e') = 2
     and (select count(*) from rx_dispensings where user_id = '00000000-0000-0000-0000-00000000000e') = 1,
    'delete all: E''s rows untouched';
end $$;
select 'rx checks passed' as result;
