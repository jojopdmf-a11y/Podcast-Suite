#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$ROOT/app"
cd "$APP_DIR"

swift build -c release --product PodcastStripper
BIN="$(swift build -c release --show-bin-path)/PodcastStripper"
APP="$ROOT/dist/Podcast Stripper.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PodcastStripper"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"

# Finder shows the display name from Info.plist; keep the binary name space-free.
chmod +x "$APP/Contents/MacOS/PodcastStripper"
echo "Built $APP"
if [[ "${SKIP_REVEAL:-}" != "1" ]]; then
  open -R "$APP"
fi
