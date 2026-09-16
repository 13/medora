#!/usr/bin/env bash
# tools/release.sh <major.minor.patch>+<build>
# Bumps pubspec.yaml, commits, tags v<version>+<build>, pushes commit + tag.
# The tag triggers .github/workflows/release.yml.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
NEW="${1:-}"
[[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$ ]] || { echo "usage: tools/release.sh <major.minor.patch>+<build>" >&2; exit 2; }
[ "$(git branch --show-current)" = "main" ] || { echo "release from main only" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "working tree not clean" >&2; exit 1; }
CUR="$(sed -n 's/^version: //p' pubspec.yaml)"
CUR_BUILD="${CUR##*+}"; NEW_BUILD="${NEW##*+}"
[ "$NEW_BUILD" -gt "$CUR_BUILD" ] || { echo "build number must increase ($CUR -> $NEW)" >&2; exit 1; }
# --split-per-abi APKs report 1000*abi + build as their version code; the app
# strips that offset, so a build number must stay below 1000.
[ "$NEW_BUILD" -lt 1000 ] || { echo "build number must be below 1000 ($NEW)" >&2; exit 1; }
git tag -l "v$NEW" | grep -q . && { echo "tag v$NEW exists" >&2; exit 1; }
sed -i "s/^version: .*/version: $NEW/" pubspec.yaml
git add pubspec.yaml
git commit -q -m "chore(release): v$NEW"
git tag -a "v$NEW" -m "Medora $NEW"

# Everything from here until the push exists only locally, and the `tag v$NEW
# exists` guard above refuses a re-run while it does — so each step that can
# fail undoes the commit and the tag itself instead of stranding them.
# docs/release.md ("If a release run fails") documents the same two commands
# for anything this cannot catch, such as an interrupted shell.
rollback() {
  git tag -d "v$NEW" > /dev/null 2>&1 || true
  git reset -q --hard HEAD~1
  echo "rolled back the local release commit and tag v$NEW" >&2
}

# The release body, built from the tag that now exists. The workflow rebuilds
# it the same way from the pushed tag, so this copy is for reading the
# changelog before it goes out (and for a manual gh release).
if ! tools/release_notes.sh "v$NEW" > dist-notes.md; then
  rollback
  echo "release notes failed; nothing was pushed" >&2
  exit 1
fi
echo "release notes written to dist-notes.md"

# --atomic so a partial push is not a possible outcome: either main and the
# tag are both on origin, or neither is and the rollback above is correct.
if ! git push --atomic origin main "v$NEW"; then
  rollback
  echo "push failed; nothing was pushed" >&2
  exit 1
fi
echo "tagged v$NEW — watch: gh run list --workflow Release"
