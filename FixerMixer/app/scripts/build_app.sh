#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$ROOT/app"
cd "$APP_DIR"

swift build -c release --product FixerMixer
BIN="$(swift build -c release --show-bin-path)/FixerMixer"
APP="$ROOT/dist/Fixer Mixer.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FixerMixer"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
ICON_SRC="$HOME/.cursor/CougarCalc-Brand/icns/AppIcon-FixerMixer.icns"
if [[ -f "$ICON_SRC" ]]; then
  cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
fi
chmod +x "$APP/Contents/MacOS/FixerMixer"
echo "Built $APP"
if [[ "${SKIP_REVEAL:-}" != "1" ]]; then
  open -R "$APP"
fi
