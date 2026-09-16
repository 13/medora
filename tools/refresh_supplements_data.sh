#!/usr/bin/env bash
# tools/refresh_supplements_data.sh
# Rebuilds and publishes the food-supplement register data (see
# docs/release.md). Run periodically from a machine in Italy; the systemd
# user timer in tools/systemd/ does exactly that. Logs to
# ~/.local/state/medora/refresh-supplements.log *and* to stderr (so
# `journalctl --user -u medora-supplements.service` shows the real failure
# reason, not just the unit's exit code), and exits non-zero on failure.
# Generated data files are written to a temp dir and never touch the working
# tree or the repo root.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/medora"
LOG="$LOG_DIR/refresh-supplements.log"
mkdir -p "$LOG_DIR"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG" >&2; }

# Refuse to run two refreshes at once — the timer and a manual
# `systemctl --user start medora-supplements.service` (docs/release.md) can
# otherwise race and upload the same release from two processes at once.
exec 9>"$LOG_DIR/.refresh.lock"
if ! flock -n 9; then
  log "FAIL: another refresh is already running"
  exit 1
fi

# Keep the log from growing without bound: once it passes ~2000 lines, keep
# only the most recent 1000. This has to run *under* the lock. Rotating
# before taking it let the second of two invocations (the timer plus a manual
# `systemctl --user start` - the very race the lock exists for) truncate the
# log of the run already in progress, and let both write "$LOG.tmp" at once.
# "$LOG.tmp" is removed on a failed tail rather than left behind: no trap
# covers it, and the one below is installed later and only for the temp dir.
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 2000 ]; then
  if tail -n 1000 "$LOG" > "$LOG.tmp"; then
    mv "$LOG.tmp" "$LOG"
  else
    rm -f "$LOG.tmp"
    log "warning: could not rotate $LOG"
  fi
fi

log "refresh starting (repo $ROOT)"

for tool in pdftotext gh curl flock; do
  if ! command -v "$tool" > /dev/null; then
    log "FAIL: $tool is not installed"
    exit 1
  fi
done
if ! gh auth status 2>&1 | tee -a "$LOG" >&2; then
  log "FAIL: gh is not authenticated"
  exit 1
fi

cd "$ROOT"

# Never publish from a dirty or non-default checkout: this runs unattended
# with the operator's gh credentials, and a half-finished parser edit could
# still produce a structurally valid, semantically wrong CSV that overwrites
# the public register for every installed app. A *committed* work in progress
# is not "dirty", so the branch has to be checked as well - and the branch
# alone is not enough either, because main can sit behind origin or carry
# unpushed commits. The local half of that runs here; the comparison against
# origin needs the network and runs after the connectivity wait below.
if ! git diff --quiet || ! git diff --cached --quiet; then
  log "FAIL: working tree is dirty, refusing to publish"
  exit 1
fi
branch="$(git rev-parse --abbrev-ref HEAD)"
if [ "$branch" != "main" ]; then
  log "FAIL: checked out on '$branch', not main, refusing to publish"
  exit 1
fi

# `After=network-online.target` in the service unit does nothing (that
# target does not exist for the per-user systemd manager), so wait for
# connectivity to the Ministry site ourselves, bounded so a real outage
# still fails the run instead of hanging past TimeoutStartSec.
host=www.salute.gov.it
attempt=0
max_attempts=10
until curl -sfI --max-time 10 "https://$host/" > /dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge "$max_attempts" ]; then
    log "FAIL: $host unreachable after $attempt attempts"
    exit 1
  fi
  log "waiting for network ($host unreachable, attempt $attempt/$max_attempts)"
  sleep 30
done

# The second half of the checkout guard, now that the network is up: what
# gets published has to be exactly what origin/main says is released.
if ! git fetch -q origin main; then
  log "FAIL: could not fetch origin/main"
  exit 1
fi
ahead="$(git rev-list --count origin/main..HEAD)"
behind="$(git rev-list --count HEAD..origin/main)"
if [ "$ahead" != 0 ] || [ "$behind" != 0 ]; then
  log "FAIL: HEAD is $ahead ahead of and $behind behind origin/main, refusing to publish"
  exit 1
fi

out_dir="$(mktemp -d)"
# TERM and INT as well as EXIT: systemd sends SIGTERM when TimeoutStartSec
# expires, and bash runs no EXIT trap for an untrapped fatal signal, so a
# timed-out run would leak the temp dir. Exiting from the signal handler is
# what gets the EXIT trap to run.
trap 'rm -rf "$out_dir"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

if "$ROOT/tools/build_supplements_data.py" --publish \
    --out "$out_dir/integratori.csv.gz" 2>&1 | tee -a "$LOG" >&2; then
  log "refresh finished OK"
else
  status=$?
  log "FAIL: build_supplements_data.py exited $status"
  exit "$status"
fi
