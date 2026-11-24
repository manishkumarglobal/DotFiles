#!/usr/bin/env bash
# Tests for global-claude/bin/firstmate-trim.
#
# Run from anywhere:  bash tests/firstmate_trim_test.sh [path/to/firstmate-trim]
#
# Everything happens in a throwaway directory; the real FirstMate folders and
# hook log are never touched.
# The script runs under the same bash as this test, so
# `/bin/bash tests/firstmate_trim_test.sh` checks the bash the LaunchAgent uses.

set -u

BASH_UNDER_TEST="${BASH:-bash}"
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

FIRSTMATE_TRIM_ROOT="$root" FIRSTMATE_TRIM_LOG="$log" "$BASH_UNDER_TEST" "$TRIM"
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

FIRSTMATE_TRIM_ROOT="$root" FIRSTMATE_TRIM_LOG="$log" FIRSTMATE_TRIM_HOURS=abc "$BASH_UNDER_TEST" "$TRIM" 2>/dev/null
[ $? -eq 2 ] && pass "refuses a bad retention value" || fail "refuses a bad retention value"

FIRSTMATE_TRIM_ROOT="$SANDBOX/missing" FIRSTMATE_TRIM_LOG="$SANDBOX/missing.log" "$BASH_UNDER_TEST" "$TRIM"
[ $? -eq 0 ] && pass "succeeds when nothing exists yet" || fail "succeeds when nothing exists yet"

# A leading zero is a decimal number, not octal ("08" and "09" are not valid octal).
# One file is 30 hours old, one is 10 hours old and one is 2 hours old.
mkdir -p "$SANDBOX/zero/Processed" "$SANDBOX/zero/Failed" "$SANDBOX/zero/Logs"
printf '{}' >"$SANDBOX/zero/Processed/thirty.json"; old "$SANDBOX/zero/Processed/thirty.json"
printf '{}' >"$SANDBOX/zero/Processed/ten.json";    touch -t "$(date -v-10H '+%Y%m%d%H%M')" "$SANDBOX/zero/Processed/ten.json"
printf '{}' >"$SANDBOX/zero/Processed/two.json";    recent "$SANDBOX/zero/Processed/two.json"
FIRSTMATE_TRIM_ROOT="$SANDBOX/zero" FIRSTMATE_TRIM_LOG="$SANDBOX/zero.log" FIRSTMATE_TRIM_HOURS=08 "$BASH_UNDER_TEST" "$TRIM" 2>/dev/null
rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$SANDBOX/zero/Processed/thirty.json" ] && [ ! -e "$SANDBOX/zero/Processed/ten.json" ] \
   && [ -e "$SANDBOX/zero/Processed/two.json" ]; then
  pass "reads a leading-zero retention value (08) as decimal"
else
  fail "reads a leading-zero retention value (08) as decimal (got $rc)"
fi
FIRSTMATE_TRIM_ROOT="$SANDBOX/zero" FIRSTMATE_TRIM_LOG="$SANDBOX/zero.log" FIRSTMATE_TRIM_HOURS=09 "$BASH_UNDER_TEST" "$TRIM" 2>/dev/null
[ $? -eq 0 ] && pass "accepts 09" || fail "accepts 09"

# The log is trimmed through a temporary copy. A job that is killed part way, or
# whose rewrite fails, must not leave that copy behind: backup.sh would skip it,
# but it holds the log's contents. A stand-in awk that never finishes holds the
# job in the middle of the rewrite, with the temporary copy already created.
stub="$SANDBOX/stub"
mkdir -p "$stub"
printf '#!/bin/sh\nexec sleep 30\n' >"$stub/awk"
chmod +x "$stub/awk"

killed_midway() {
  signal="$1"
  slog="$SANDBOX/killed-$signal.log"
  printf '%s old event\n' "$(date -v-30H '+%Y-%m-%d %H:%M:%S')" >"$slog"
  PATH="$stub:$PATH" FIRSTMATE_TRIM_ROOT="$SANDBOX/missing" FIRSTMATE_TRIM_LOG="$slog" \
    "$BASH_UNDER_TEST" "$TRIM" 2>/dev/null &
  pid=$!
  seen=""
  for _ in $(seq 1 100); do
    set -- "$slog".*.tmp
    if [ -e "$1" ]; then seen="$1"; break; fi
    sleep 0.1
  done
  # The stand-in awk gets the signal too, as it does when launchd stops a job.
  kill -s "$signal" "$pid" 2>/dev/null
  pkill "-$signal" -P "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  left="$(ls "$slog".* 2>/dev/null)"
  case "$seen" in
    *.tmp) pass "the temporary copy of the log ends in .tmp ($signal)" ;;
    *) fail "the temporary copy of the log ends in .tmp ($signal)" ;;
  esac
  [ -z "$left" ] && pass "a job stopped by $signal mid-write leaves no temporary copy" \
    || fail "a job stopped by $signal mid-write leaves no temporary copy (left: $left)"
  grep -q 'old event' "$slog" && pass "a job stopped by $signal leaves the log as it was" \
    || fail "a job stopped by $signal leaves the log as it was"
}
killed_midway TERM
killed_midway HUP

# A rewrite that fails also cleans up after itself.
printf '#!/bin/sh\nexit 1\n' >"$stub/awk"
flog="$SANDBOX/failed.log"
printf '%s old event\n' "$(date -v-30H '+%Y-%m-%d %H:%M:%S')" >"$flog"
PATH="$stub:$PATH" FIRSTMATE_TRIM_ROOT="$SANDBOX/missing" FIRSTMATE_TRIM_LOG="$flog" "$BASH_UNDER_TEST" "$TRIM"
rc=$?
[ "$rc" -eq 1 ] && pass "reports a failed rewrite" || fail "reports a failed rewrite (got $rc)"
[ -z "$(ls "$flog".* 2>/dev/null)" ] && pass "a failed rewrite leaves no temporary copy" || fail "a failed rewrite leaves no temporary copy"

echo
if [ "$FAILED" -eq 0 ]; then echo "all passed"; else echo "$FAILED failed"; fi
exit "$FAILED"
