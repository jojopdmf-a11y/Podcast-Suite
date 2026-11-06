#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$ROOT/app"
cd "$APP_DIR"

swift build -c release --product PodLounge
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/PodLounge"
APP="$ROOT/dist/PodLounge.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PodLounge"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/PodLounge"

# Card screenshots. Bundle.main looks in Contents/Resources. The SwiftPM
# resource bundle sits next to the executable during `swift run`; copy it
# too so either lookup finds the same PNGs.
cp "$APP_DIR/Sources/PodLounge/Resources/"*.png "$APP/Contents/Resources/"
RESOURCE_BUNDLE="$BIN_DIR/PodLounge_PodLounge.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
  cp -R "$RESOURCE_BUNDLE" "$APP/Contents/MacOS/"
fi

echo "Built $APP"
if [[ "${SKIP_REVEAL:-}" != "1" ]]; then
  open -R "$APP"
fi
