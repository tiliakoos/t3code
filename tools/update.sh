#!/usr/bin/env bash
# Bring the daily driver up to upstream's newest nightly tag, build it, and offer to install it.
# Personal file: lives on features/tiliakoos only, never in a PR diff.
# Usage: tools/update.sh [--check] [--yes]
#   --check  report only: fetches tags, changes nothing, prints a STATUS= line for agents
#   --yes    install without asking
# Building is safe while T3 Code runs. Installing quits it, so run this from Terminal.app;
# inside T3 Code it stops after the build.
set -euo pipefail
cd "$(dirname "$0")/.."

BRANCH=features/tiliakoos
APP="/Applications/T3 Code (Nightly).app"
MODE=update
YES=
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    --yes) YES=--yes ;;
    *) echo "usage: tools/update.sh [--check] [--yes]"; exit 2 ;;
  esac
done

git fetch -q upstream --tags
LATEST=$(git tag -l 'v*-nightly.*' | sort -V | tail -1)
CURRENT=$(git tag --merged "$BRANCH" -l 'v*-nightly.*' | sort -V | tail -1)
INSTALLED=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo none)

BLOCKED=
if [ "$(git rev-parse --abbrev-ref HEAD)" != "$BRANCH" ]; then
  BLOCKED="not-on-$BRANCH"
elif git rev-parse -q --verify MERGE_HEAD >/dev/null; then
  BLOCKED=merge-in-progress
elif ! git diff --quiet || ! git diff --cached --quiet; then
  BLOCKED=uncommitted-changes
fi

if [ "$LATEST" != "$CURRENT" ]; then
  STATUS=update-available
elif [ "$INSTALLED" != "${CURRENT#v}" ]; then
  STATUS=install-pending
else
  STATUS=up-to-date
fi
if [ -n "$BLOCKED" ] && [ "$STATUS" != up-to-date ]; then STATUS="blocked:$BLOCKED"; fi

echo "STATUS=$STATUS"
echo "Installed app:  $INSTALLED"
echo "Your branch:    $CURRENT ($BRANCH @ $(git rev-parse --short "$BRANCH"))"
echo "Newest nightly: $LATEST ($(git log -1 --format=%cs "$LATEST"))"

if [ "$LATEST" != "$CURRENT" ]; then
  echo "Commits:        $(git rev-list --count "$CURRENT..$LATEST")"
  # Only added migrations touch an existing database. Applied ones never rerun, so edits to them
  # (such as a library-wide import rename) are only counted.
  MIG=apps/server/src/persistence/Migrations
  NEW_MIGRATIONS=$(git diff --name-only --diff-filter=A "$CURRENT" "$LATEST" -- "$MIG" | grep -v '\.test\.ts$' || true)
  EDITED=$(git diff --name-only --diff-filter=M "$CURRENT" "$LATEST" -- "$MIG" | grep -vc '\.test\.ts$' || true)
  if [ -n "$NEW_MIGRATIONS" ]; then
    echo "Database:       $(printf '%s\n' "$NEW_MIGRATIONS" | wc -l | tr -d ' ') new migration(s): one-way, and the install step backs up your data first"
    printf '%s\n' "$NEW_MIGRATIONS" | sed "s|^$MIG/|  |"
  else
    echo "Database:       no new migrations (safe to roll back)"
  fi
  if [ "$EDITED" -gt 0 ]; then
    echo "                $EDITED existing migration files edited; they never rerun, so your data is unaffected"
  fi
  BUILD_FILES=$(git diff --name-only "$CURRENT" "$LATEST" -- package.json pnpm-workspace.yaml \
    scripts/build-desktop-artifact.ts apps/desktop/package.json | tr '\n' ' ')
  echo "Build files:    ${BUILD_FILES:-none changed}"
  if CONFLICTS=$(git merge-tree --write-tree --name-only --no-messages "$BRANCH" "$LATEST"); then
    echo "Merge:          clean"
  else
    echo "Merge:          CONFLICTS in: $(printf '%s\n' "$CONFLICTS" | tail -n +2 | tr '\n' ' ')"
  fi
  echo "Changes:"
  git log --no-merges --format='  %s' "$CURRENT..$LATEST" | grep -E '^  (feat|fix|perf)' | sort || true
fi

[ "$MODE" = check ] && exit 0

if [ "$STATUS" = up-to-date ]; then
  echo "Nothing to do."
  exit 0
fi
if [ -n "$BLOCKED" ]; then
  echo "Stopped: the main clone is $BLOCKED. Sort that out first, then run this again."
  exit 1
fi

if [ "$STATUS" = update-available ]; then
  # The mirror is a convenience; a failure here should not stop the update.
  git fetch -q . upstream/main:main && git push -q origin main ||
    echo "warning: could not update main on your fork (continuing)"
  BACKUP="backup/features-tiliakoos-$(date +%m%d)"
  if git rev-parse -q --verify "refs/heads/$BACKUP" >/dev/null; then BACKUP="$BACKUP-$(date +%H%M)"; fi
  git branch "$BACKUP" "$BRANCH"
  if ! git merge -q --no-edit "$LATEST"; then
    git merge --abort
    git branch -q -D "$BACKUP"
    echo "Stopped: merging $LATEST conflicts with your changes. Nothing was changed."
    echo "Ask an agent with the t3code-update skill to resolve it."
    exit 1
  fi
  echo "Merged $LATEST (previous state saved as $BACKUP)."
  git push -q origin "$BRANCH" || echo "warning: could not push $BRANCH to your fork (continuing)"
fi

# Skip the build when release/local already holds one made from this exact commit.
STAMP_FILE=release/local/built-from
if [ -f "$STAMP_FILE" ] && [ "$(cat "$STAMP_FILE")" = "$(git rev-parse HEAD)" ] &&
  ls -d release/local/app/*.app >/dev/null 2>&1; then
  echo "Already built from this commit; skipping the build."
else
  echo "Building (about 4 minutes; T3 Code keeps running)..."
  env -u ELECTRON_RUN_AS_NODE tools/reload-local.sh --no-install
  git rev-parse HEAD >"$STAMP_FILE"
fi

tools/install-built-app.sh $YES
