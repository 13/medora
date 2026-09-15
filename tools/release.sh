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
git push origin main "v$NEW"
echo "tagged v$NEW — watch: gh run list --workflow Release"
