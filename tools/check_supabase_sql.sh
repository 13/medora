#!/usr/bin/env bash
# Applies every migration in supabase/migrations to a throwaway Postgres 15
# (with a stand-in for Supabase's auth schema) and runs the SQL checks in
# tools/sql/. Needs either Docker (default) or PGHOST/PGUSER/PGPASSWORD
# pointing at an empty scratch database (CI sets them; USE_DOCKER=0).
# Never point it at a real Supabase project.
set -euo pipefail
cd "$(dirname "$0")/.."

use_docker="${USE_DOCKER:-1}"
# Only warnings and errors: no NOTICE lines from IF NOT EXISTS.
quiet="-c client_min_messages=warning"
container=""
cleanup() { [[ -n "$container" ]] && docker stop "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT

if [[ "$use_docker" == 1 ]]; then
  container="medora-sql-check-$$"
  docker run -d --rm --name "$container" -e POSTGRES_PASSWORD=check postgres:15-alpine >/dev/null
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
  psql_run() { docker exec -i -e PGOPTIONS="$quiet" "$container" psql -v ON_ERROR_STOP=1 -U postgres -q "$@"; }
  # A second session that keeps running while the script goes on.
  psql_bg() { docker exec -d -e PGOPTIONS="$quiet" "$container" psql -U postgres -q "$@"; }
else
  psql_run() { PGOPTIONS="$quiet" psql -v ON_ERROR_STOP=1 -q "$@"; }
  psql_bg() { PGOPTIONS="$quiet" psql -q "$@" >/dev/null 2>&1 & }
fi

sync_v2=supabase/migrations/20260918000000_sync_v2.sql
test -f "$sync_v2" || { echo "missing $sync_v2" >&2; exit 1; }

# Every migration in file-name order (the order Supabase applies them),
# each in a transaction of its own, as `supabase db push` runs them.
{
  cat tools/sql/auth_shim.sql
  for f in supabase/migrations/*.sql; do
    if [[ "$f" == "$sync_v2" ]]; then
      # A row from before sync v2.
      echo "insert into auth.users (id) values ('00000000-0000-0000-0000-0000000000cc');"
      echo "insert into medications (id, user_id, name) values ('pre-migration', '00000000-0000-0000-0000-0000000000cc', 'Old');"
      # One with a known stamp: its first update fills the edit-time map.
      echo "insert into medications (id, user_id, name, notes, updated_at) values ('pre-migration-2', '00000000-0000-0000-0000-0000000000cc', 'Old', 'n', '2026-01-01T00:00:00Z');"
      printf 'begin;\n'; cat "$f"; printf '\ncommit;\n'
      # Re-runnable: apply it a second time.
      printf 'begin;\n'; cat "$f"; printf '\ncommit;\n'
    else
      printf 'begin;\n'; cat "$f"; printf '\ncommit;\n'
    fi
  done
} | psql_run >/dev/null

psql_run < tools/sql/sync_v2_checks.sql

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
