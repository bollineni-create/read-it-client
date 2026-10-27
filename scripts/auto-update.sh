#!/bin/bash
# Keeps /Applications/Rounds.app in step with origin/main. Run every few minutes by the launch agent that
# scripts/install-auto-update.sh sets up; safe to run by hand too.
#
# Each run: fetch origin, fast-forward main if the checkout is on main and clean, and if the installed
# app wasn't built from that commit, build Release, quit Rounds, swap the app in and reopen it.
# Local work is never touched: on another branch or with uncommitted changes it only logs and skips.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
cd "$(dirname "$0")/.."
ROOT="$PWD"

STATE="$HOME/Library/Application Support/Rounds Auto-Update"
LOG="$HOME/Library/Logs/Rounds-auto-update.log"
APP_DEST="/Applications/Rounds.app"
BUNDLE_ID="com.naren.rounds"
mkdir -p "$STATE" "$(dirname "$LOG")"
exec >>"$LOG" 2>&1

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

# One run at a time: a build can outlast the launch agent's interval.
LOCK="$STATE/lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  # A lock left by a crashed run (older than an hour) is cleared; a live one means skip.
  if [[ -n "$(find "$LOCK" -maxdepth 0 -mmin +60 2>/dev/null)" ]]; then
    rmdir "$LOCK" && mkdir "$LOCK"
  else
    exit 0
  fi
fi
trap 'rmdir "$LOCK"' EXIT

if ! git fetch --quiet origin main; then
  log "git fetch failed (offline, or git can't reach GitHub without a prompt); will retry"
  exit 0
fi

branch="$(git symbolic-ref --short -q HEAD || true)"
if [[ "$branch" != "main" ]]; then
  log "checkout is on '${branch:-detached}', not main; skipping"
  exit 0
fi
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  log "uncommitted changes in $ROOT; skipping"
  exit 0
fi
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
  if ! git merge --quiet --ff-only origin/main; then
    log "main has diverged from origin/main; skipping until that's resolved"
    exit 0
  fi
fi

head="$(git rev-parse HEAD)"
installed="$(cat "$STATE/installed-commit" 2>/dev/null || true)"
failed="$(cat "$STATE/failed-commit" 2>/dev/null || true)"
if [[ "$head" == "$installed" && -d "$APP_DEST" ]]; then exit 0; fi
if [[ "$head" == "$failed" ]]; then exit 0; fi   # don't rebuild a broken commit every few minutes

log "building ${head:0:7}: $(git log -1 --format=%s)"
if ! xcodebuild -quiet -project Rounds.xcodeproj -scheme Rounds -configuration Release \
     -destination 'platform=macOS' -derivedDataPath build build; then
  echo "$head" >"$STATE/failed-commit"
  log "build failed for ${head:0:7}; keeping the installed app"
  osascript -e "display notification \"Build of ${head:0:7} failed. See $LOG\" with title \"Rounds update failed\"" || true
  exit 0
fi
BUILT="$ROOT/build/Build/Products/Release/Rounds.app"

was_running=false
if pgrep -x Rounds >/dev/null; then
  was_running=true
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" || true
  for _ in $(seq 1 20); do pgrep -x Rounds >/dev/null || break; sleep 0.5; done
  if pgrep -x Rounds >/dev/null; then
    log "Rounds didn't quit; will install on the next run"
    exit 0
  fi
fi

rm -rf "$APP_DEST.new"
ditto "$BUILT" "$APP_DEST.new"
rm -rf "$APP_DEST"
mv "$APP_DEST.new" "$APP_DEST"
echo "$head" >"$STATE/installed-commit"
rm -f "$STATE/failed-commit"
log "installed ${head:0:7} into $APP_DEST"

if $was_running; then open "$APP_DEST"; fi
osascript -e "display notification \"$(git log -1 --format=%s | sed 's/"/\\"/g')\" with title \"Rounds updated\"" || true
