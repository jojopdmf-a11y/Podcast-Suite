#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$ROOT/app"
cd "$APP_DIR"

swift build -c release --product FixerMixer
BIN="$(swift build -c release --show-bin-path)/FixerMixer"
APP="$ROOT/dist/PodProducer.app"

rm -rf "$APP"
rm -rf "$ROOT/dist/Fixer Mixer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FixerMixer"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
ICON_SRC="$HOME/.cursor/CougarCalc-Brand/icns/AppIcon-FixerMixer.icns"
if [[ -f "$ICON_SRC" ]]; then
  cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
fi
chmod +x "$APP/Contents/MacOS/FixerMixer"
# Old Update script still looks for this filename after a mid-update pull.
ln -sfn "PodProducer.app" "$ROOT/dist/Fixer Mixer.app"
echo "Built $APP"
if [[ "${SKIP_REVEAL:-}" != "1" ]]; then
  open -R "$APP"
fi
