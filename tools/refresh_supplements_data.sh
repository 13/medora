#!/usr/bin/env bash
# tools/refresh_supplements_data.sh
# Rebuilds and publishes the food-supplement register data (see
# docs/release.md). Run monthly from a machine in Italy; the systemd user
# timer in tools/systemd/ does exactly that. Logs to
# ~/.local/state/medora/refresh-supplements.log and exits non-zero on failure.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/medora"
LOG="$LOG_DIR/refresh-supplements.log"
mkdir -p "$LOG_DIR"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }

log "refresh starting (repo $ROOT)"
if ! command -v pdftotext > /dev/null; then
  log "FAIL: pdftotext (poppler-utils) is not installed"
  exit 1
fi
if ! command -v gh > /dev/null; then
  log "FAIL: gh is not installed"
  exit 1
fi
if ! gh auth status >> "$LOG" 2>&1; then
  log "FAIL: gh is not authenticated"
  exit 1
fi

cd "$ROOT"
if "$ROOT/tools/build_supplements_data.py" --publish >> "$LOG" 2>&1; then
  log "refresh finished OK"
else
  status=$?
  log "FAIL: build_supplements_data.py exited $status"
  exit "$status"
fi
