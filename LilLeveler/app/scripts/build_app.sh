#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$ROOT/app"
cd "$APP_DIR"

swift build -c release --product LilLeveler
BIN="$(swift build -c release --show-bin-path)/LilLeveler"
APP="$ROOT/dist/Lil Leveler.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LilLeveler"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
ICON_SRC="$HOME/.cursor/CougarCalc-Brand/icns/AppIcon-LilLeveler.icns"
if [[ -f "$ICON_SRC" ]]; then
  cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
fi
chmod +x "$APP/Contents/MacOS/LilLeveler"
echo "Built $APP"
open -R "$APP"
