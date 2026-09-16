#!/usr/bin/env bash
# tools/test_release_notes.sh
# Checks tools/release_notes.sh against a throwaway repository built in a
# temp dir: it never touches this repository, its tags or its remote.
#
# The cases here are the producer half of a pair. Their consumer half lives in
# test/services/release_notes_test.dart, which renders the same subjects in
# the in-app update sheet - a subject that survives the changelog only to be
# mangled by the sheet is just as broken, so both sides pin the same strings.
set -euo pipefail
# A BASH_ENV rc is sourced by every non-interactive bash, including the one
# under test, and anything it prints lands in the captured stdout. Compare
# against a clean environment rather than against whoever's dotfiles are
# installed on the machine running this.
unset BASH_ENV
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

mkdir -p "$tmp/tools"
cp "$ROOT/tools/release_notes.sh" "$tmp/tools/release_notes.sh"
cd "$tmp"

git init -q -b main .
git config user.email test@example.invalid
git config user.name "release notes test"
git config commit.gpgsign false

commit() { git commit -q --allow-empty -m "$1"; }

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

check() { # check <label> <expected> <actual>
  if [ "$2" != "$3" ]; then
    printf 'FAIL: %s\n--- expected ---\n%s\n--- actual ---\n%s\n' "$1" "$2" "$3" >&2
    exit 1
  fi
  printf 'ok: %s\n' "$1"
}

# --- the first release covers all history, and only feat/fix are grouped ---
commit "chore: seed"
commit "feat: first thing"
commit "docs: not listed"
git tag -a v0.0.1 -m v0.0.1

expected="## What's new in 0.0.1

### Features
- first thing"
check "first release covers all history" "$expected" "$(tools/release_notes.sh v0.0.1)"

# --- the cases that were silently mangled ---
# A subject with a second '): ' in it: a greedy scope pattern matched up to
# the *last* one and deleted the words before it.
commit "feat(a): weird (b): scope-with-paren"
commit "fix: plain fix"
# Markdown-significant characters in a raw commit subject. The changelog is
# published verbatim, so these must reach the release body untouched.
commit "feat(db): rename user_id to userId and *star*"
commit "fix(build): ignore *.dart and **/*.g.dart"
commit "refactor: not listed"
git tag -a v0.0.2 -m v0.0.2

expected="## What's new in 0.0.2

### Features
- rename user_id to userId and *star*
- weird (b): scope-with-paren

### Fixes
- ignore *.dart and **/*.g.dart
- plain fix"
check "scopes, parens and markdown characters survive" "$expected" "$(tools/release_notes.sh v0.0.2)"

# --- a release with nothing to group still says something ---
commit "chore: only chores"
git tag -a v0.0.3 -m v0.0.3
expected="## What's new in 0.0.3

See the commit log for the full list of changes."
check "a release with no feat/fix falls back" "$expected" "$(tools/release_notes.sh v0.0.3)"

# --- an unknown tag fails loudly rather than publishing an empty body ---
if tools/release_notes.sh v9.9.9 > /dev/null 2>&1; then
  fail "an unknown tag was accepted"
fi
printf 'ok: an unknown tag is rejected\n'

printf 'all release_notes.sh checks passed\n'
