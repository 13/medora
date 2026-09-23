#!/usr/bin/env bash
# Applies every migration in supabase/migrations to a throwaway Postgres 15
# (with a stand-in for Supabase's auth schema) and runs the SQL checks in
# tools/sql/. Needs either Docker (default) or PGHOST/PGUSER/PGPASSWORD
# pointing at an empty scratch database (CI sets them; USE_DOCKER=0).
# Never point it at a real Supabase project.
#
# PG_IMAGE picks the Docker image (default postgres:15-alpine). With
# Supabase's own image (PG_IMAGE=public.ecr.aws/supabase/postgres:15.8.1.085)
# the migrations run as its `postgres` role, which is not a superuser,
# against its real auth schema and roles, so tools/sql/auth_shim.sql is
# skipped. AUTH_SHIM=0 skips it on the USE_DOCKER=0 path too.
set -euo pipefail
cd "$(dirname "$0")/.."

use_docker="${USE_DOCKER:-1}"
image="${PG_IMAGE:-postgres:15-alpine}"
case "$image" in
  *supabase/postgres*) auth_shim="${AUTH_SHIM:-0}" ;;
  *) auth_shim="${AUTH_SHIM:-1}" ;;
esac
# Only warnings and errors: no NOTICE lines from IF NOT EXISTS.
quiet="-c client_min_messages=warning"
container=""
cleanup() { [[ -n "$container" ]] && docker stop "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT

if [[ "$use_docker" == 1 ]]; then
  container="medora-sql-check-$$"
  docker run -d --rm --name "$container" -e POSTGRES_PASSWORD=check "$image" >/dev/null
  # Ask over TCP: while the image initialises the database it runs a
  # temporary server that answers on the socket only, then restarts it.
  ready=0
  for _ in $(seq 1 60); do
    if docker exec "$container" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ "$ready" != 1 ]]; then
    echo "postgres did not start" >&2
    exit 1
  fi
  # Over TCP, as a client connects (the Supabase image trusts local TCP).
  psql_run() { docker exec -i -e PGOPTIONS="$quiet" "$container" psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U postgres -q "$@"; }
  # A second session that keeps running while the script goes on.
  psql_bg() { docker exec -d -e PGOPTIONS="$quiet" "$container" psql -h 127.0.0.1 -U postgres -q "$@"; }
else
  psql_run() { PGOPTIONS="$quiet" psql -v ON_ERROR_STOP=1 -q "$@"; }
  psql_bg() { PGOPTIONS="$quiet" psql -q "$@" >/dev/null 2>&1 & }
fi

sync_v2=supabase/migrations/20260918000000_sync_v2.sql
test -f "$sync_v2" || { echo "missing $sync_v2" >&2; exit 1; }

# Every migration in file-name order (the order Supabase applies them),
# each in a transaction of its own, as `supabase db push` runs them.
{
  if [[ "$auth_shim" == 1 ]]; then
    cat tools/sql/auth_shim.sql
  fi
  for f in supabase/migrations/*.sql; do
    if [[ "$f" == "$sync_v2" ]]; then
      # A row from before sync v2.
      echo "insert into auth.users (id) values ('00000000-0000-0000-0000-0000000000cc');"
      echo "insert into medications (id, user_id, name) values ('pre-migration', '00000000-0000-0000-0000-0000000000cc', 'Old');"
      # One with a known stamp: its first update fills the edit-time map.
      echo "insert into medications (id, user_id, name, notes, updated_at) values ('pre-migration-2', '00000000-0000-0000-0000-0000000000cc', 'Old', 'n', '2026-01-01T00:00:00Z');"
      # One a 0.4.0 write without an edit time reaches first, and one
      # stamped by a clock far ahead.
      echo "insert into medications (id, user_id, name, updated_at) values ('pre-migration-3', '00000000-0000-0000-0000-0000000000cc', 'Old', '2026-01-01T00:00:00Z');"
      echo "insert into medications (id, user_id, name, updated_at) values ('pre-migration-future', '00000000-0000-0000-0000-0000000000cc', 'Ahead', '2099-01-01T00:00:00Z');"
      # A live dose under a deleted prescription, as 0.3.0 could leave it:
      # the migration deletes it.
      echo "insert into treatments (id, user_id, name, start_date) values ('pre-orphan-t', '00000000-0000-0000-0000-0000000000cc', 'Old', '2026-01-01');"
      echo "insert into prescriptions (id, treatment_id, medication_id, dosage, start_time, deleted_at) values ('pre-orphan-p', 'pre-orphan-t', 'pre-migration', '1', '2026-01-01T08:00:00Z', '2026-01-02T00:00:00Z');"
      echo "insert into dose_logs (id, prescription_id, scheduled_time, status, updated_at) values ('pre-orphan-d', 'pre-orphan-p', '2026-01-03T08:00:00Z', 'taken', '2026-01-03T08:00:00Z');"
      printf 'begin;\n'; cat "$f"; printf '\ncommit;\n'
      # Re-runnable: apply it a second time.
      printf 'begin;\n'; cat "$f"; printf '\ncommit;\n'
    else
      printf 'begin;\n'; cat "$f"; printf '\ncommit;\n'
    fi
  done
} | psql_run >/dev/null

psql_run < tools/sql/sync_v2_checks.sql
# The fake server's answers to the same writes
# (test/helpers/fake_server_parity_test.dart writes this file).
psql_run < tools/sql/fake_server_parity.sql
# Prescriptions (20260923000000_rx.sql).
psql_run < tools/sql/rx_checks.sql

# The horizon holds back a row whose transaction is still open.
psql_run -c "insert into medications (id, user_id, name) values ('slow-owner', '00000000-0000-0000-0000-00000000000a', 'x');" >/dev/null
psql_bg -c "begin; insert into medications (id, user_id, name) values ('slow', '00000000-0000-0000-0000-00000000000a', 'Slow'); select pg_sleep(4); commit;"
sleep 1.5
psql_run -c "insert into medications (id, user_id, name) values ('fast', '00000000-0000-0000-0000-00000000000a', 'Fast');" >/dev/null
during=$(psql_run -At -c "select count(*) from medications where id in ('slow','fast') and sync_xid < (medora_sync_state()->>'horizon')::bigint;")
sleep 4
after=$(psql_run -At -c "select count(*) from medications where id in ('slow','fast') and sync_xid < (medora_sync_state()->>'horizon')::bigint;")
wait || true
if [[ "$during" != 0 || "$after" != 2 ]]; then
  echo "horizon check failed: during=$during (want 0), after=$after (want 2)" >&2
  exit 1
fi
echo "horizon check passed"

# A retry that races its original (the answer was lost, the request is
# still running) waits for it and is answered duplicate; the stock moves
# once. Without the advisory lock the retry fails on the ledger's key.
as_a=(-c "set role authenticated" -c "set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a'")
op="select apply_stock_change('dededede-0000-0000-0000-000000000001', 'lock-med', -1, null)"
psql_bg "${as_a[@]}" -c "begin" -c "$op" -c "select pg_sleep(4)" -c "commit"
sleep 1.5
retry=$(psql_run -At "${as_a[@]}" -c "$op ->> 'status'" 2>&1) || true
wait || true
quantity=$(psql_run -At -c "select quantity from medications where id = 'lock-med';")
if [[ "$retry" != duplicate || "$quantity" != 9 ]]; then
  echo "retry race check failed: retry=$retry (want duplicate), quantity=$quantity (want 9)" >&2
  exit 1
fi
echo "retry race check passed"

# A child written while another request deletes its parent (review I-3):
# whichever runs first, the other waits for it, and the child ends deleted,
# as the app's own delete. Both sessions are user A's, under row-level
# security. Without the parent lookup's FOR SHARE the two pass each other
# and the dose stays live under a deleted prescription.
psql_run >/dev/null <<'SQL'
insert into treatments (id, user_id, name, start_date)
  values ('race-t', '00000000-0000-0000-0000-00000000000a', 'Race', '2026-09-10');
insert into medications (id, user_id, name)
  values ('race-m', '00000000-0000-0000-0000-00000000000a', 'Race'),
         ('race-m3', '00000000-0000-0000-0000-00000000000a', 'Race');
insert into prescriptions (id, treatment_id, medication_id, dosage, start_time)
  values ('race-p1', 'race-t', 'race-m', '1', '2026-09-10T08:00:00Z'),
         ('race-p2', 'race-t', 'race-m', '1', '2026-09-10T08:00:00Z');
SQL
race_insert() { # $1 dose id, $2 prescription id
  echo "insert into dose_logs (id, prescription_id, scheduled_time, status, write_id, edited_at, field_edited_at)
        values ('$1', '$2', '2026-09-11T08:00:00Z', 'taken', gen_random_uuid(), now(),
                jsonb_build_object('status', jsonb_build_object('at', now(), 'auto', false)))"
}
race_delete() { # $1 prescription id
  echo "update prescriptions set deleted_at = now(), write_id = gen_random_uuid(), edited_at = now() where id = '$1'"
}
race_result() { # $1 dose id
  psql_run -At -c "select coalesce((select (deleted_at is not null)::text || '/' || (edited_at = timestamptz '1970-01-01T00:00:00Z')::text from dose_logs where id = '$1'), 'missing');"
}
# 1. The insert is open while the delete runs.
psql_bg "${as_a[@]}" -c "begin" -c "$(race_insert race-d1 race-p1)" -c "select pg_sleep(4)" -c "commit"
sleep 1.5
psql_run "${as_a[@]}" -c "$(race_delete race-p1)" >/dev/null
# Read only once the other session has finished either way.
sleep 3
first=$(race_result race-d1)
# 2. The delete is open while the insert runs.
psql_bg "${as_a[@]}" -c "begin" -c "$(race_delete race-p2)" -c "select pg_sleep(4)" -c "commit"
sleep 1.5
psql_run "${as_a[@]}" -c "$(race_insert race-d2 race-p2)" >/dev/null
sleep 3
second=$(race_result race-d2)
# 3. A prescription insert is open while its medication is deleted.
psql_bg "${as_a[@]}" -c "begin" -c "insert into prescriptions (id, treatment_id, medication_id, dosage, start_time, write_id, edited_at) values ('race-p3', 'race-t', 'race-m3', '1', '2026-09-10T08:00:00Z', gen_random_uuid(), now())" -c "select pg_sleep(4)" -c "commit"
sleep 1.5
psql_run "${as_a[@]}" -c "update medications set deleted_at = now(), write_id = gen_random_uuid(), edited_at = now() where id = 'race-m3'" >/dev/null
sleep 3
third=$(psql_run -At -c "select coalesce((select (deleted_at is not null)::text || '/' || (edited_at = timestamptz '1970-01-01T00:00:00Z')::text from prescriptions where id = 'race-p3'), 'missing');")
wait || true
if [[ "$first" != true/true || "$second" != true/true || "$third" != true/true ]]; then
  echo "parent race check failed: dose insert first=$first, delete first=$second; prescription insert first=$third (want true/true: deleted, as the app's own)" >&2
  exit 1
fi
echo "parent race check passed"

# "Delete all data" and an insert at the same moment (the wipe marker): the
# wipe waits for an insert already open and deletes its row; an insert that
# starts while the wipe is open waits, then sees it, and a row changed
# before the wipe from a device that had not seen it lands deleted. User C.
psql_run -c "insert into auth.users (id) values ('00000000-0000-0000-0000-00000000000c');" >/dev/null
as_c=(-c "set role authenticated" -c "set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000c'")
wipe_insert() { # $1 id, $2 the wipe generation the device has seen
  echo "insert into medications (id, user_id, name, write_id, edited_at, field_edited_at)
        values ('$1', auth.uid(), 'Race', gen_random_uuid(), now() - interval '1 hour', '{\"@wipe\": $2}')"
}
# 1. The insert is open while the wipe runs.
psql_bg "${as_c[@]}" -c "begin" -c "$(wipe_insert wipe-race-1 0)" -c "select pg_sleep(4)" -c "commit"
sleep 1.5
psql_run "${as_c[@]}" -c "select medora_delete_all_data()" >/dev/null
sleep 3
first=$(psql_run -At -c "select coalesce((select case when deleted_at is null then 'live' else 'deleted' end from medications where id = 'wipe-race-1'), 'gone');")
# 2. The wipe is open while the insert runs.
psql_bg "${as_c[@]}" -c "begin" -c "select medora_delete_all_data()" -c "select pg_sleep(4)" -c "commit"
sleep 1.5
psql_run "${as_c[@]}" -c "$(wipe_insert wipe-race-2 1)" >/dev/null
sleep 3
second=$(psql_run -At -c "select coalesce((select case when deleted_at is null then 'live' when edited_at = (select wiped_at from sync_wipes where user_id = '00000000-0000-0000-0000-00000000000c') then 'deleted-by-wipe' else 'deleted' end from medications where id = 'wipe-race-2'), 'gone');")
wait || true
if [[ "$first" != gone || "$second" != deleted-by-wipe ]]; then
  echo "wipe race check failed: insert first=$first (want gone), wipe first=$second (want deleted-by-wipe)" >&2
  exit 1
fi
echo "wipe race check passed"
