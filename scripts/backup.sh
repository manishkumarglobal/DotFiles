#!/usr/bin/env bash

set -Eeuo pipefail

SOURCE="${HOME}/.claude"
REPO="${HOME}/git/DotFiles"
DEST="${REPO}/global-claude"

BACKUP_DIRECTORIES=(
  # skills/ is intentionally absent. Agent skills are owned by
  # EngineeringToolsMK (skills/global/), and ~/.claude/skills now holds
  # per-skill symlinks into that repository. rsync -a preserves symlinks, so
  # backing the directory up here would capture links pointing at another
  # repository rather than the skills themselves, and would recreate a second,
  # misleading source of truth for content that is already version controlled.
  # Removed 2026-08-21 when the skills were centralized.
  agents
  commands
  rules
  # hooks/ holds the scripts that settings.json points at, so backing up
  # settings.json without it captures a configuration whose commands do not
  # exist anywhere else. Restoring that state gives you hooks wired to missing
  # files, which fail silently. Added 2026-08-14 after the turn-completion
  # notifier turned out to be untracked on this machine only.
  hooks
)

BACKUP_FILES=(
  CLAUDE.md
  settings.json
)

die() {
  echo "ERROR: $*" >&2
  exit 1
}

command -v git >/dev/null 2>&1 || die "git is not installed."
command -v rsync >/dev/null 2>&1 || die "rsync is not installed."

[[ -d "$SOURCE" ]] || die "Claude configuration directory not found: $SOURCE"
[[ -d "$REPO/.git" ]] || die "Backup repository not found: $REPO"

mkdir -p "$DEST"

echo "Backing up Claude Code configuration..."

# Back up top-level Claude configuration files.
#
# If a previously backed-up file no longer exists in ~/.claude,
# remove it from the backup so the repository reflects the source.
for file in "${BACKUP_FILES[@]}"; do
  if [[ -f "$SOURCE/$file" ]]; then
    cp -p "$SOURCE/$file" "$DEST/$file"
  else
    rm -f "$DEST/$file"
  fi
done

# Back up reusable Claude customizations.
#
# rsync -a preserves:
# - nested directory structure
# - permissions
# - timestamps
# - symbolic links
#
# --delete ensures files removed from ~/.claude are also removed
# from the backup.
for directory in "${BACKUP_DIRECTORIES[@]}"; do
  source_directory="$SOURCE/$directory"
  destination_directory="$DEST/$directory"

  if [[ -d "$source_directory" ]]; then
    mkdir -p "$destination_directory"

    # Runtime output is excluded: logs and state stamps change on every turn,
    # so backing them up would produce a commit's worth of churn each run and
    # bury the configuration changes that actually matter.
    #
    # Dated safety copies (name.before-<date>-<reason>) are excluded too. They
    # are made beside a file before a live edit, so a rollback is one `cp`, and
    # they are never reviewed: this script commits and pushes to a public
    # repository on its own, so it must publish only the files in use.
    #
    # The turn-alert hook and its tests are installed copies, not originals.
    # EngineeringToolsMK owns and installs them, as it owns the skills above.
    # Copying them here would bring back a second, drifting source of truth.
    # Retired 2026-11-24. The ignore list beside them (turn-notify-ignore) is
    # configuration and is still backed up. The leading slash anchors each name
    # to hooks/ itself.
    #
    # --delete-excluded also removes excluded files already in the checkout,
    # so a stray copy made earlier cannot stay there and be committed.
    #
    # turn-notify-disabled is the hook's off switch: runtime state, not
    # configuration.
    rsync -a --delete --delete-excluded \
      --exclude='.DS_Store' \
      --exclude='*.tmp' \
      --exclude='*.swp' \
      --exclude='*.log' \
      --exclude='*.before-*' \
      --exclude='/claude-turn-notify.sh' \
      --exclude='/claude-turn-notify.test.sh' \
      --exclude='/turn-notify-disabled' \
      --exclude='.turn-notify-state/' \
      "$source_directory/" \
      "$destination_directory/"
  else
    rm -rf "$destination_directory"
  fi
done

# Git does not track empty directories.
# Add .gitkeep files so an intentionally empty nested rules structure
# is retained in the remote repository.
if [[ -d "$DEST/rules" ]]; then
  while IFS= read -r -d '' directory; do
    touch "$directory/.gitkeep"
  done < <(
    find "$DEST/rules" \
      -type d \
      -empty \
      -print0
  )
fi

cd "$REPO"

# git diff does not include untracked files.
# git status --porcelain detects added, modified, renamed, and deleted files.
if [[ -z "$(git status --porcelain -- \
  global-claude \
  scripts \
  .gitignore \
  README.md)" ]]; then
  echo "No Claude Code configuration changes detected."
  exit 0
fi

git add -- \
  global-claude \
  scripts \
  .gitignore \
  README.md

# Defensive check after staging.
if git diff --cached --quiet; then
  echo "No staged Claude Code configuration changes detected."
  exit 0
fi

git commit \
  -m "Back up Claude Code configuration $(date '+%Y-%m-%d %H:%M:%S')"

git push

echo "Claude Code configuration and rule structure backed up successfully."
