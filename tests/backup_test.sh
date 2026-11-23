#!/usr/bin/env bash
# Tests for scripts/backup.sh: what it publishes from ~/.claude.
#
# Run from anywhere:  bash tests/backup_test.sh [path/to/backup.sh]
#
# The real script runs end to end, commit and push included, against a
# throwaway home whose DotFiles checkout pushes to a local bare repository. HOME
# is the only thing that tells backup.sh where to read and where to push, so the
# real ~/.claude and the real remote are never touched. Git ignores the system
# and global configuration here.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP="${1:-$SCRIPT_DIR/../scripts/backup.sh}"
BACKUP="$(cd "$(dirname "$BACKUP")" && pwd)/$(basename "$BACKUP")"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/backup-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

FAILED=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; FAILED=$((FAILED + 1)); }

sandbox_git() {
  env -i HOME="$SANDBOX/home" PATH="$PATH" \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid \
    GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid \
    "$@"
}

# A home with a configuration to back up, and a checkout that pushes locally.
mkdir -p "$SANDBOX/home/.claude/hooks/.turn-notify-state" "$SANDBOX/home/git"
printf '# rules\n' >"$SANDBOX/home/.claude/CLAUDE.md"
printf '{}\n' >"$SANDBOX/home/.claude/settings.json"
printf '#!/bin/sh\necho current\n' >"$SANDBOX/home/.claude/hooks/notify.sh"
printf '#!/bin/sh\necho old\n' >"$SANDBOX/home/.claude/hooks/notify.sh.before-20261123-some-fix"
printf '#!/bin/sh\necho old test\n' >"$SANDBOX/home/.claude/hooks/notify.test.sh.before-20261122-other"
printf 'line\n' >"$SANDBOX/home/.claude/hooks/turn-notify.log"
printf 'stamp\n' >"$SANDBOX/home/.claude/hooks/.turn-notify-state/ready-abc"

sandbox_git git init --quiet --bare "$SANDBOX/remote.git"
sandbox_git git clone --quiet "$SANDBOX/remote.git" "$SANDBOX/home/git/DotFiles" 2>/dev/null
# backup.sh stages these paths by name, as the real repository has them.
printf '# DotFiles\n' >"$SANDBOX/home/git/DotFiles/README.md"
printf '*.log\n' >"$SANDBOX/home/git/DotFiles/.gitignore"
mkdir -p "$SANDBOX/home/git/DotFiles/scripts"
cp "$BACKUP" "$SANDBOX/home/git/DotFiles/scripts/backup.sh"
sandbox_git git -C "$SANDBOX/home/git/DotFiles" add README.md .gitignore scripts
sandbox_git git -C "$SANDBOX/home/git/DotFiles" commit --quiet -m init
sandbox_git git -C "$SANDBOX/home/git/DotFiles" push --quiet -u origin HEAD 2>/dev/null

if sandbox_git bash "$BACKUP" >"$SANDBOX/out" 2>&1; then
  pass "backup.sh completes"
else
  fail "backup.sh completes"
  sed 's/^/     /' "$SANDBOX/out"
fi

# Judge what reached the remote, which is what the public would see.
published="$(sandbox_git git -C "$SANDBOX/remote.git" ls-tree -r --name-only HEAD 2>/dev/null)"

case "$published" in
  *"global-claude/hooks/notify.sh"*) pass "the hook in use is published" ;;
  *) fail "the hook in use is published" ;;
esac
case "$published" in
  *".before-"*) fail "dated safety copies are not published" ;;
  *) pass "dated safety copies are not published" ;;
esac
case "$published" in
  *"turn-notify.log"*) fail "the log is not published" ;;
  *) pass "the log is not published" ;;
esac
case "$published" in
  *".turn-notify-state"*) fail "runtime state is not published" ;;
  *) pass "runtime state is not published" ;;
esac

if [ "$FAILED" -eq 0 ]; then
  echo "all passed"
  exit 0
fi
echo "$FAILED failed"
exit 1
