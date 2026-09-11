#!/bin/zsh
# Pull latest from GitHub, rebuild one Mac app, and launch it.
# Usage: update-and-launch.sh fixer|leveler|stripper
set -euo pipefail

APP_KEY="${1:-fixer}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

case "$APP_KEY" in
  fixer)
    DISPLAY_NAME="Fixer Mixer"
    PROCESS_NAME="FixerMixer"
    BUILD_SCRIPT="$ROOT/FixerMixer/app/scripts/build_app.sh"
    APP_PATH="$ROOT/FixerMixer/dist/Fixer Mixer.app"
    ;;
  leveler)
    DISPLAY_NAME="Lil Leveler"
    PROCESS_NAME="LilLeveler"
    BUILD_SCRIPT="$ROOT/LilLeveler/app/scripts/build_app.sh"
    APP_PATH="$ROOT/LilLeveler/dist/Lil Leveler.app"
    ;;
  stripper)
    DISPLAY_NAME="Podcast Stripper"
    PROCESS_NAME="PodcastStripper"
    BUILD_SCRIPT="$ROOT/Podcast Stripper/app/scripts/build_app.sh"
    APP_PATH="$ROOT/Podcast Stripper/dist/Podcast Stripper.app"
    ;;
  *)
    echo "Usage: $0 fixer|leveler|stripper"
    exit 1
    ;;
esac

on_fail() {
  echo ""
  echo "Update failed. This window will stay open so you can read the error."
  echo "Press Return to close."
  read -r
  exit 1
}
trap on_fail ERR

echo "==> $DISPLAY_NAME"
echo "Repo: $ROOT"
echo ""

echo "==> Pulling latest from GitHub (main)…"
git fetch origin
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "This folder has unsaved edits, so the updater stopped."
  echo "If you did not mean to change any files, tell Cursor and we can sort it out."
  exit 1
fi
git checkout main
git pull --ff-only origin main
echo "On $(git branch --show-current) @ $(git log -1 --oneline)"
echo ""

echo "==> Quitting any running $DISPLAY_NAME…"
osascript -e "tell application \"$DISPLAY_NAME\" to quit" >/dev/null 2>&1 || true
for _ in {1..10}; do
  pgrep -x "$PROCESS_NAME" >/dev/null 2>&1 || break
  sleep 0.3
done
killall -9 "$PROCESS_NAME" >/dev/null 2>&1 || true

echo "==> Building…"
chmod +x "$BUILD_SCRIPT"
# Reveal-in-Finder is noisy when we're about to launch.
SKIP_REVEAL=1 "$BUILD_SCRIPT"

echo ""
echo "==> Launching $DISPLAY_NAME…"
# -n forces THIS built copy. Plain `open` can reuse an older Podcast Stripper
# already registered with macOS (same name, leftover from another folder).
open -n "$APP_PATH"
echo "Opened: $APP_PATH"
echo "The window should say Version 1.0.1 (3) under the title."

echo ""
echo "Done. You can close this window."
trap - ERR
