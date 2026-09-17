#!/usr/bin/env bash
# Applies every migration in supabase/migrations to a throwaway Postgres 15
# (with a stand-in for Supabase's auth schema) and runs the SQL checks in
# tools/sql/. Needs either Docker (default) or PGHOST/PGUSER/PGPASSWORD
# pointing at an empty scratch database (CI sets them; USE_DOCKER=0).
# Never point it at a real Supabase project.
set -euo pipefail
cd "$(dirname "$0")/.."

use_docker="${USE_DOCKER:-1}"
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
  psql_run() { docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -q "$@"; }
else
  psql_run() { psql -v ON_ERROR_STOP=1 -q "$@"; }
fi

sync_v2=supabase/migrations/20260918000000_sync_v2.sql
test -f "$sync_v2" || { echo "missing $sync_v2" >&2; exit 1; }

# Every migration in file-name order (the order Supabase applies them).
{
  cat tools/sql/auth_shim.sql
  for f in supabase/migrations/*.sql; do
    if [[ "$f" == "$sync_v2" ]]; then
      # A row from before sync v2.
      echo "insert into auth.users values ('00000000-0000-0000-0000-0000000000cc');"
      echo "insert into medications (id, user_id, name) values ('pre-migration', '00000000-0000-0000-0000-0000000000cc', 'Old');"
      cat "$f"
      # Re-runnable: apply it a second time.
      cat "$f"
    else
      cat "$f"
    fi
  done
} | psql_run >/dev/null

psql_run < tools/sql/sync_v2_checks.sql

# The horizon holds back a row whose transaction is still open.
psql_run -c "insert into medications (id, user_id, name) values ('slow-owner', '00000000-0000-0000-0000-00000000000a', 'x');" >/dev/null
if [[ "$use_docker" == 1 ]]; then
  docker exec -d "$container" psql -U postgres -c "begin; insert into medications (id, user_id, name) values ('slow', '00000000-0000-0000-0000-00000000000a', 'Slow'); select pg_sleep(4); commit;"
else
  psql -q -c "begin; insert into medications (id, user_id, name) values ('slow', '00000000-0000-0000-0000-00000000000a', 'Slow'); select pg_sleep(4); commit;" >/dev/null &
fi
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
