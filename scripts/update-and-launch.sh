#!/bin/zsh
# Pull latest from GitHub, rebuild one Mac app, and launch it.
# Usage: update-and-launch.sh fixer|leveler|stripper
set -euo pipefail

APP_KEY="${1:-fixer}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

case "$APP_KEY" in
  fixer)
    DISPLAY_NAME="PodProducer"
    LEGACY_NAME="Fixer Mixer"
    PROCESS_NAME="FixerMixer"
    BUILD_SCRIPT="$ROOT/FixerMixer/app/scripts/build_app.sh"
    APP_PATH="$ROOT/FixerMixer/dist/PodProducer.app"
    ;;
  leveler)
    DISPLAY_NAME="PodLeveler"
    LEGACY_NAME="Lil Leveler"
    PROCESS_NAME="LilLeveler"
    BUILD_SCRIPT="$ROOT/LilLeveler/app/scripts/build_app.sh"
    APP_PATH="$ROOT/LilLeveler/dist/PodLeveler.app"
    ;;
  stripper)
    DISPLAY_NAME="PodStripper"
    LEGACY_NAME="Podcast Stripper"
    PROCESS_NAME="PodcastStripper"
    BUILD_SCRIPT="$ROOT/Podcast Stripper/app/scripts/build_app.sh"
    APP_PATH="$ROOT/Podcast Stripper/dist/PodStripper.app"
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

explain_xcode_license() {
  echo "Apple’s developer tools need a one-time Agree on this Mac."
  echo "(This pops up after some Mac / Xcode updates. It is not a PodStudio bug.)"
  echo ""
  echo "Do this once:"
  echo "  1. Spotlight → Terminal"
  echo "  2. Paste this line and press Return:"
  echo "       sudo xcodebuild -license accept"
  echo "  3. Type your Mac login password. Nothing will show as you type — that is normal."
  echo "     Press Return."
  echo "  4. Double-click this Update icon again."
  echo ""
  echo "Or open the Xcode app (if you have it) and click Agree."
}

# git and swift both use Apple’s tools. If the license is not agreed, they dump
# a long legal document into this window — catch that before we pull.
if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  echo "==> $DISPLAY_NAME"
  echo "Repo: $ROOT"
  echo ""
  explain_xcode_license
  echo ""
  echo "Press Return to close."
  read -r
  exit 1
fi

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
osascript -e "tell application \"$LEGACY_NAME\" to quit" >/dev/null 2>&1 || true
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
# -n forces THIS built copy. Plain `open` can reuse an older app
# already registered with macOS (same name, leftover from another folder).
open -n "$APP_PATH"
echo "Opened: $APP_PATH"
PLIST="$APP_PATH/Contents/Info.plist"
if [[ -f "$PLIST" ]]; then
  VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || true)"
  BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null || true)"
  if [[ -n "$VER" && -n "$BUILD" ]]; then
    echo "This copy is Version $VER ($BUILD). Look for that lime line under the title."
  fi
fi

echo ""
echo "Done. You can close this window."
trap - ERR
