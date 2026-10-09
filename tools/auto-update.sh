#!/usr/bin/env bash
# Hands-off T3 Code updates. launchd runs `run` every 30 minutes; when a newer nightly exists,
# T3 Code is open and nothing is working, it merges and builds (tools/update.sh --no-install),
# shows a 60-second dialog, installs (tools/install-built-app.sh --yes) and prunes old backups.
# Personal file: lives on features/tiliakoos only, never in a PR diff.
# Usage: tools/auto-update.sh setup | remove | status | run | prune
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
LABEL=com.tiliakoos.t3code-auto-update
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/t3code-auto-update.log"
STATE="$HOME/Library/Application Support/t3code-auto-update"
DB="$HOME/.t3/userdata/statev2.sqlite"
APP="/Applications/T3 Code (Nightly).app"
ID=com.t3tools.t3code
KEEP_DAYS=3
POSTPONE_SECONDS=7200
# After a failure, so a lasting problem does not rebuild or show the dialog every 30 minutes.
BACKOFF_SECONDS=21600

# To stderr, so functions that print a result (ask) keep it clean; `run` sends both to the log.
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
notify() { osascript -e "display notification \"$1\" with title \"T3 Code update\"" >/dev/null 2>&1 || true; }
# Notify once per distinct problem, not on every 30-minute run.
notify_once() {
  local key=$1
  shift
  if [ "$(cat "$STATE/last-notice" 2>/dev/null)" != "$key" ]; then
    echo "$key" >"$STATE/last-notice"
    notify "$*"
  fi
}
hold() { echo $(($(date +%s) + $1)) >"$STATE/postponed-until"; }
app_running() { osascript -e "application id \"$ID\" is running" 2>/dev/null | grep -q true; }
installed_version() { /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo none; }

# Work that quitting T3 Code would cut off, read from its database without write access:
# unfinished runs, questions waiting on Nick, and agents' background commands.
active_work() {
  sqlite3 -readonly "file:$DB?mode=ro" "
    select
      (select count(*) from orchestration_v2_projection_runs
        where status not in ('completed', 'interrupted', 'failed', 'cancelled', 'rolled_back'))
    + (select count(*) from orchestration_v2_projection_runtime_requests where status = 'pending')
    + (select count(*) from orchestration_v2_projection_provider_threads pt
        join orchestration_v2_projection_threads t on t.thread_id = pt.thread_id
        where t.deleted_at is null
          and coalesce(json_array_length(json_extract(pt.payload_json, '$.pendingBackgroundTasks')), 0) > 0);"
}

# True when nothing is working. An unreadable database (say, a schema change upstream) counts as busy.
idle() {
  local n
  n=$(active_work 2>&1) || true
  case "$n" in
    0) return 0 ;;
    '' | *[!0-9]*)
      log "waiting: could not read thread status: $n"
      notify_once db-unreadable "Auto-update can't tell whether threads are working, so it is waiting. Ask an agent to check $LOG."
      return 1
      ;;
    *)
      log "waiting: $n run(s), question(s) or background task(s) active"
      return 1
      ;;
  esac
}

# Prints "update", "postpone" or "error". No answer within 60 seconds means update.
ask() {
  local answer
  answer=$(osascript -e "display dialog \"T3 Code $1 is ready. In 60 seconds T3 Code will quit, back up its data, update and reopen.\" with title \"T3 Code update\" buttons {\"Not now\", \"Update now\"} default button \"Update now\" giving up after 60" 2>&1) || {
    log "dialog failed: $answer"
    echo error
    return
  }
  case "$answer" in
    *"Not now"*) echo postpone ;;
    *) echo update ;;
  esac
}

# Reads "day name" lines, oldest first, and prints the names to delete. Kept: the newest, which
# undoes the last install, and the earliest of each of the newest $KEEP_DAYS days, which undoes
# all of that day's installs. So several installs in one night do not push out older days.
stale() {
  awk -v keep="$KEEP_DAYS" '
    { day[NR] = $1; name[NR] = substr($0, length($1) + 2) }
    END {
      kept[NR] = 1
      for (i = NR; i >= 1 && days < keep; i--)
        if (day[i] != day[i - 1]) { kept[i] = 1; days++ }
      for (i = 1; i <= NR; i++) if (!kept[i]) print name[i]
    }'
}

# Prunes data backups (stamped YYYYMMDD-HHMM, so they sort chronologically) and backup branches
# (named by the day they were made, MMDD; a bare name is that day's first) with `stale`.
prune() {
  shopt -s nullglob
  local prefix backup stamp branch day
  for prefix in "$HOME/.t3/userdata.bak-" "$HOME/Library/Application Support/t3code-v2.bak-"; do
    for backup in "$prefix"[0-9]*; do
      stamp=${backup#"$prefix"}
      echo "${stamp:0:8} $backup"
    done | stale | while IFS= read -r backup; do
      rm -rf "$backup"
      log "pruned $backup"
    done
  done
  git -C "$REPO" for-each-ref --sort=committerdate --format='%(refname:short)' \
    'refs/heads/backup/features-tiliakoos-*' | while IFS= read -r branch; do
    day=${branch#backup/features-tiliakoos-}
    echo "${day:0:4} $branch"
  done | stale | while IFS= read -r branch; do
    if git -C "$REPO" branch -q -D "$branch"; then log "pruned branch $branch"; fi
  done
}

run() {
  mkdir -p "$STATE"
  # One run at a time; a lock left by a crashed run is taken over.
  if ! mkdir "$STATE/lock" 2>/dev/null; then
    kill -0 "$(cat "$STATE/lock/pid" 2>/dev/null)" 2>/dev/null && exit 0
    rm -rf "$STATE/lock"
    mkdir "$STATE/lock"
  fi
  echo $$ >"$STATE/lock/pid"
  trap 'rm -rf "$STATE/lock"' EXIT

  # Set up by `setup`: ask macOS for permission to quit T3 Code from this job, and show the dialog style.
  if [ -f "$STATE/first-run" ]; then
    rm -f "$STATE/first-run"
    osascript -e "tell application id \"$ID\" to activate" >/dev/null 2>&1 || log "permission probe failed"
    osascript -e 'display dialog "T3 Code auto-update is on. When an update is ready and no thread is working, a prompt like this gives you 60 seconds to say Not now." with title "T3 Code update" buttons {"OK"} default button "OK" giving up after 120' >/dev/null 2>&1 ||
      log "setup dialog failed"
    log "setup: permission probe and dialog shown"
  fi

  # Keep the log short.
  if [ -f "$LOG" ] && [ "$(wc -l <"$LOG")" -gt 2000 ]; then
    tail -n 500 "$LOG" >"$LOG.tmp" && cat "$LOG.tmp" >"$LOG" && rm -f "$LOG.tmp"
  fi

  if [ "$(date +%s)" -lt "$(cat "$STATE/postponed-until" 2>/dev/null || echo 0)" ]; then exit 0; fi

  local report status newest
  if ! report=$("$REPO/tools/update.sh" --check 2>&1); then
    log "check failed: $(printf '%s\n' "$report" | tail -n 1)"
    exit 0
  fi
  status=$(printf '%s\n' "$report" | sed -n 's/^STATUS=//p')
  newest=$(printf '%s\n' "$report" | sed -n 's/^Newest nightly: *v\([^ ]*\).*/\1/p')
  case "$status" in
    up-to-date) exit 0 ;;
    update-available | install-pending) ;;
    blocked:*)
      log "waiting: the main clone is ${status#blocked:}"
      notify_once "$status" "An update is waiting: the T3 Code clone is ${status#blocked:}."
      exit 0
      ;;
    *)
      log "unexpected check result: $status"
      exit 0
      ;;
  esac

  if ! app_running; then
    log "waiting: T3 Code is not open"
    exit 0
  fi
  idle || exit 0

  log "preparing $newest (merge and build, reused when already built)"
  if ! "$REPO/tools/update.sh" --no-install >"$STATE/last-build.log" 2>&1; then
    log "build failed: $(tail -n 2 "$STATE/last-build.log" | tr '\n' ' ')"
    notify_once "failed:$newest" "Updating to $newest stopped before installing; nothing changed. Ask an agent to check $LOG."
    hold "$BACKOFF_SECONDS"
    exit 1
  fi

  # Work may have started during the build or while the dialog was up.
  idle || exit 0
  case "$(ask "$newest")" in
    postpone)
      hold "$POSTPONE_SECONDS"
      log "postponed by Nick for $((POSTPONE_SECONDS / 3600)) hours"
      exit 0
      ;;
    error)
      notify_once dialog-failed "T3 Code $newest is ready, but the update prompt could not be shown. Ask an agent to check $LOG."
      hold "$BACKOFF_SECONDS"
      exit 0
      ;;
  esac
  idle || exit 0

  log "installing $newest"
  if ! "$REPO/tools/install-built-app.sh" --yes >>"$STATE/last-build.log" 2>&1; then
    log "install failed: $(tail -n 2 "$STATE/last-build.log" | tr '\n' ' ')"
    notify_once "install-failed:$newest" "Installing $newest stopped; T3 Code was not changed. Ask an agent to check $LOG."
    hold "$BACKOFF_SECONDS"
    exit 1
  fi
  if [ "$(installed_version)" != "$newest" ]; then
    log "install finished but the app reports $(installed_version)"
    notify_once "mismatch:$newest" "T3 Code reports $(installed_version) after updating to $newest. Ask an agent to check."
    hold "$BACKOFF_SECONDS"
    exit 1
  fi
  log "installed $newest"
  rm -f "$STATE/last-notice"
  notify "T3 Code updated to $newest."
  prune
}

setup() {
  mkdir -p "$STATE" "$(dirname "$PLIST")" "$(dirname "$LOG")"
  cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$REPO/tools/auto-update.sh</string><string>run</string></array>
  <key>StartInterval</key><integer>1800</integer>
  <key>RunAtLoad</key><true/>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
  touch "$STATE/first-run"
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "Auto-update is on: checks every 30 minutes. Log: $LOG"
  echo "Allow the macOS prompt to control T3 Code if one appears, then click OK on the T3 Code update dialog."
}

remove() {
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Auto-update is off. The log stays at $LOG."
}

status() {
  if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    echo "Auto-update: on (every 30 minutes)"
  else
    echo "Auto-update: off"
  fi
  local until
  until=$(cat "$STATE/postponed-until" 2>/dev/null || echo 0)
  if [ "$(date +%s)" -lt "$until" ]; then echo "Postponed until $(date -r "$until" '+%H:%M')"; fi
  echo "Installed: $(installed_version)"
  echo "Recent log:"
  tail -n 10 "$LOG" 2>/dev/null | sed 's/^/  /' || echo "  (none yet)"
}

case "${1:-}" in
  setup | remove | status | prune) "$1" ;;
  run) run >>"$LOG" 2>&1 ;;
  *) echo "usage: tools/auto-update.sh setup | remove | status | run | prune"; exit 2 ;;
esac
