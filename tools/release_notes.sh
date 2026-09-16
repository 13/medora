#!/usr/bin/env bash
# tools/release_notes.sh <tag>
# Writes the GitHub release body for <tag> to stdout: the conventional-commit
# subjects since the previous release tag, grouped under plain headings.
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
for group in "feat:Features" "fix:Fixes"; do
  prefix="${group%%:*}"; title="${group##*:}"
  subjects="$(git log --no-merges --pretty=%s "$RANGE" | grep -E "^$prefix(\(.+\))?: " | sed -E "s/^$prefix(\(.+\))?: //" || true)"
  [ -n "$subjects" ] || continue
  BODY+="### $title"$'\n'
  while IFS= read -r subject; do BODY+="- $subject"$'\n'; done <<< "$subjects"
  BODY+=$'\n'
done

echo "## What's new in ${TAG#v}"
echo
if [ -n "$BODY" ]; then
  printf '%s' "$BODY"
else
  echo "See the commit log for the full list of changes."
fi
