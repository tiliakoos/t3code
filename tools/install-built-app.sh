#!/usr/bin/env bash
# Install the app tools/reload-local.sh built in release/local: quit T3 Code, back up its data,
# swap the app in /Applications, reopen. Refuses to run inside T3 Code, because quitting the app
# would kill this script halfway through. Run it from Terminal.app.
# Personal file: lives on features/tiliakoos only, never in a PR diff.
# Usage: tools/install-built-app.sh [--yes]   (--yes skips the confirmation)
set -euo pipefail

# T3 Code's integrated terminal and its agents' shells all descend from the app process.
inside_t3code() {
  local pid=$$
  while [ "${pid:-0}" -gt 1 ]; do
    case "$(ps -o command= -p "$pid" 2>/dev/null)" in
      *"T3 Code"*".app/Contents/MacOS/"*) return 0 ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
  return 1
}
if inside_t3code; then
  echo "Not installing: this is running inside T3 Code, and installing quits T3 Code."
  echo "Run this from Terminal.app instead:"
  echo "  $(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  exit 1
fi

ID=com.t3tools.t3code
OUT="$(cd "$(dirname "$0")/.." && pwd)/release/local"
DATA="$HOME/.t3/userdata"
PROFILE="$HOME/Library/Application Support/t3code-v2"
STAMP=$(date +%Y%m%d-%H%M)

SRC=$(ls -d "$OUT"/app/*.app 2>/dev/null | head -1)
[ -n "$SRC" ] || { echo "No built app in $OUT/app. Build one with tools/update.sh or tools/reload-local.sh."; exit 1; }
DEST="/Applications/$(basename "$SRC")"
codesign --verify --deep --strict "$SRC"
NEW=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$SRC/Contents/Info.plist")
OLD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$DEST/Contents/Info.plist" 2>/dev/null || echo none)
echo "Installed: $OLD"
echo "New build: $NEW"

if [ "${1:-}" != "--yes" ]; then
  if [ ! -t 0 ]; then
    echo "Not interactive, so nothing was installed. Run this from Terminal.app to install."
    exit 0
  fi
  read -r -p "Quit T3 Code, back up its data, and install $NEW now? [y/N] " answer || answer=
  case "$answer" in
    y | Y | yes) ;;
    *) echo "Nothing installed. Run tools/install-built-app.sh when you're ready."; exit 0 ;;
  esac
fi

running() { osascript -e "application id \"$ID\" is running" 2>/dev/null | grep -q true; }
if running; then
  echo "Quitting T3 Code..."
  # May be refused if Terminal lacks Automation permission; the wait below then explains what to do.
  osascript -e "tell application id \"$ID\" to quit" || true
fi
for _ in $(seq 60); do running || break; sleep 1; done
if running; then
  echo "T3 Code did not quit (maybe a confirm dialog is open). Quit it yourself, then run this again."
  exit 1
fi

# The backend can outlive the window for a moment; the copy is only safe once nothing holds the database.
# lsof exits 1 if any listed file is closed, so test its output, not its status.
dbopen() { [ -n "$(lsof "$DATA"/state*.sqlite* 2>/dev/null)" ]; }
for _ in $(seq 30); do dbopen || break; sleep 1; done
if dbopen; then
  echo "Something still has the database open, so nothing was changed:"
  lsof "$DATA"/state*.sqlite*
  exit 1
fi

echo "Backing up data..."
backup_failed() {
  echo "Backup failed, so nothing was installed. Open T3 Code to keep using $OLD."
  exit 1
}
cp -Rp "$DATA" "$DATA.bak-$STAMP" || backup_failed
if [ -d "$PROFILE" ]; then cp -Rp "$PROFILE" "$PROFILE.bak-$STAMP" || backup_failed; fi
CHECK=$(sqlite3 "$DATA.bak-$STAMP/statev2.sqlite" 'PRAGMA quick_check' 2>&1 || true)
if [ "$CHECK" != "ok" ]; then
  echo "Backup database check failed ($CHECK). Nothing was installed; your current app is untouched."
  exit 1
fi
echo "  $DATA.bak-$STAMP (database check ok)"
[ -d "$PROFILE.bak-$STAMP" ] && echo "  $PROFILE.bak-$STAMP"

echo "Installing..."
# Keep the old app until the next build clears release/local, so going back is a move, not a rebuild.
if [ -d "$DEST" ]; then
  mkdir -p "$OUT/previous-$STAMP"
  mv "$DEST" "$OUT/previous-$STAMP/"
fi
if ! ditto "$SRC" "$DEST"; then
  rm -rf "$DEST"
  mv "$OUT/previous-$STAMP/$(basename "$DEST")" "$DEST"
  open "$DEST"
  echo "Install failed, so the old app ($OLD) was put back and reopened."
  exit 1
fi
open "$DEST"
echo "Done: installed $NEW and reopened T3 Code. The previous app is in $OUT/previous-$STAMP."
