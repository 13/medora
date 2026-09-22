#!/usr/bin/env bash
# tools/release_notes.sh <tag>
# Writes the GitHub release body for <tag> to stdout: the conventional-commit
# subjects since the previous release tag, grouped under plain headings.
#
# Only feat/fix/perf are listed by subject: this body is also what the in-app
# update sheet shows, and a refactor's subject means nothing to a user. A
# release holding none of the three says how many maintenance commits it held
# and of what kinds, rather than nothing at all.
#
# Both tools/release.sh and .github/workflows/release.yml call this, so a
# scripted release and a hand-pushed tag produce exactly the same changelog,
# and the text can be reviewed before it is ever published.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TAG="${1:-}"
[ -n "$TAG" ] || { echo "usage: tools/release_notes.sh <tag>" >&2; exit 2; }
git rev-parse -q --verify "$TAG^{commit}" > /dev/null || { echo "unknown tag: $TAG" >&2; exit 1; }
# --match 'v*' so a non-release tag (data-integratori) can never be the
# baseline; empty on the very first release, which then covers all history.
PREV="$(git describe --tags --abbrev=0 --match 'v*' "$TAG^" 2> /dev/null || true)"
RANGE="${PREV:+$PREV..}$TAG"

BODY=""
for group in "feat:Features" "fix:Fixes" "perf:Performance"; do
  prefix="${group%%:*}"; title="${group##*:}"
  # \([^)]*\), not \(.+\): a greedy scope swallows everything up to the last
  # "): " in the subject, so `feat(a): weird (b): scope` published as
  # "scope" — the words in between silently deleted from the changelog.
  subjects="$(git log --no-merges --pretty=%s "$RANGE" | grep -E "^$prefix(\([^)]*\))?: " | sed -E "s/^$prefix(\([^)]*\))?: //" || true)"
  [ -n "$subjects" ] || continue
  BODY+="### $title"$'\n'
  while IFS= read -r subject; do BODY+="- $subject"$'\n'; done <<< "$subjects"
  BODY+=$'\n'
done

# What a release with no feat/fix/perf actually held. Only those three
# groups are listed by subject, because the body is what the in-app update
# sheet shows a user, and "refactor: the cycle's state machine leaves
# SyncService" tells them nothing. But a release that says only "see the
# commit log" tells them less than nothing — v0.4.1+20 published exactly
# that for six commits of CI and refactoring work — so name the kinds and
# count them.
maintenance_line() {
  local kinds count
  count="$(git log --no-merges --pretty=%s "$RANGE" | grep -cE '^[a-z]+(\([^)]*\))?: ' || true)"
  # `paste -sd ', '` would cycle through the delimiter list one character at
  # a time and join as "ci,docs refactor"; the delimiter here is the pair.
  kinds="$(git log --no-merges --pretty=%s "$RANGE" \
    | sed -nE 's/^([a-z]+)(\([^)]*\))?: .*/\1/p' | sort -u \
    | tr '\n' ',' | sed -E 's/,$//; s/,/, /g')"
  [ -n "$kinds" ] || { echo "See the commit log for the full list of changes."; return; }
  echo "No user-facing changes: $count maintenance commit(s) ($kinds)."
  echo
  echo "See the commit log for the full list of changes."
}

echo "## What's new in ${TAG#v}"
echo
if [ -n "$BODY" ]; then
  printf '%s' "$BODY"
else
  maintenance_line
fi
