#!/usr/bin/env bash
# Tests for global-claude/bin/firstmate-trim.
#
# Run from anywhere:  bash tests/firstmate_trim_test.sh [path/to/firstmate-trim]
#
# Everything happens in a throwaway directory; the real FirstMate folders and
# hook log are never touched.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRIM="${1:-$SCRIPT_DIR/../global-claude/bin/firstmate-trim}"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/firstmate-trim-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

FAILED=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; FAILED=$((FAILED + 1)); }

root="$SANDBOX/FirstMateNotify"
log="$SANDBOX/turn-notify.log"
outside="$SANDBOX/outside"
mkdir -p "$root/Processed/.markers" "$root/Failed" "$root/Logs" "$root/Queue" "$outside"

old() { touch -t "$(date -v-30H '+%Y%m%d%H%M')" "$@"; }
recent() { touch -t "$(date -v-2H '+%Y%m%d%H%M')" "$@"; }

printf '{}' >"$root/Processed/old.json";  old "$root/Processed/old.json"
printf '{}' >"$root/Processed/new.json";  recent "$root/Processed/new.json"
: >"$root/Processed/.markers/id-old.marker"; old "$root/Processed/.markers/id-old.marker"
: >"$root/Processed/.markers/id-new.marker"; recent "$root/Processed/.markers/id-new.marker"
printf 'x' >"$root/Failed/old.json";      old "$root/Failed/old.json"
printf 'x' >"$root/Logs/old.log";         old "$root/Logs/old.log"
printf '{}' >"$root/Queue/pending.json";  old "$root/Queue/pending.json"
printf 'keep' >"$outside/target.json";    old "$outside/target.json"
ln -s "$outside" "$root/Processed/link-to-outside"

{
  printf '%s old event\n' "$(date -v-30H '+%Y-%m-%d %H:%M:%S')"
  printf 'continuation of the old event\n'
  printf '%s recent event\n' "$(date -v-2H '+%Y-%m-%d %H:%M:%S')"
  printf 'continuation of the recent event\n'
} >"$log"

FIRSTMATE_TRIM_ROOT="$root" FIRSTMATE_TRIM_LOG="$log" bash "$TRIM"
rc=$?

[ "$rc" -eq 0 ] && pass "exits 0" || fail "exits 0 (got $rc)"
[ ! -e "$root/Processed/old.json" ] && pass "removes a day-old delivered alert" || fail "removes a day-old delivered alert"
[ -e "$root/Processed/new.json" ] && pass "keeps a recent delivered alert" || fail "keeps a recent delivered alert"
[ ! -e "$root/Processed/.markers/id-old.marker" ] && pass "removes a day-old marker" || fail "removes a day-old marker"
[ -e "$root/Processed/.markers/id-new.marker" ] && pass "keeps a recent marker" || fail "keeps a recent marker"
[ ! -e "$root/Failed/old.json" ] && pass "removes a day-old failed alert" || fail "removes a day-old failed alert"
[ ! -e "$root/Logs/old.log" ] && pass "removes a day-old app log" || fail "removes a day-old app log"
[ -e "$root/Queue/pending.json" ] && pass "never touches the queue" || fail "never touches the queue"
[ -e "$outside/target.json" ] && pass "does not follow a symlink out of the folder" || fail "does not follow a symlink out of the folder"
[ -d "$root/Processed/.markers" ] && pass "keeps the folders themselves" || fail "keeps the folders themselves"

if ! grep -q 'old event' "$log" && grep -q 'recent event' "$log" \
   && grep -q 'continuation of the recent event' "$log" && ! grep -q 'continuation of the old event' "$log"; then
  pass "keeps only the last day of the hook log"
else
  fail "keeps only the last day of the hook log"
fi

FIRSTMATE_TRIM_ROOT="$root" FIRSTMATE_TRIM_LOG="$log" FIRSTMATE_TRIM_HOURS=abc bash "$TRIM" 2>/dev/null
[ $? -eq 2 ] && pass "refuses a bad retention value" || fail "refuses a bad retention value"

FIRSTMATE_TRIM_ROOT="$SANDBOX/missing" FIRSTMATE_TRIM_LOG="$SANDBOX/missing.log" bash "$TRIM"
[ $? -eq 0 ] && pass "succeeds when nothing exists yet" || fail "succeeds when nothing exists yet"

echo
if [ "$FAILED" -eq 0 ]; then echo "all passed"; else echo "$FAILED failed"; fi
exit "$FAILED"
