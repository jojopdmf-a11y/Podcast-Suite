#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$ROOT/app"
cd "$APP_DIR"

install_lame() {
  local app="$1"
  local repo
  repo="$(cd "$ROOT/.." && pwd)"
  local dylib="$repo/ThirdParty/lame/build/lib/libmp3lame.0.dylib"
  if [[ ! -f "$dylib" ]]; then
    "$repo/ThirdParty/lame/build_lame.sh"
  fi
  mkdir -p "$app/Contents/Frameworks" "$app/Contents/Resources"
  cp "$dylib" "$app/Contents/Frameworks/libmp3lame.0.dylib"
  chmod 755 "$app/Contents/Frameworks/libmp3lame.0.dylib"
  codesign --force --sign - "$app/Contents/Frameworks/libmp3lame.0.dylib"
  cp "$repo/ThirdParty/lame/build/COPYING" "$app/Contents/Resources/LAME-COPYING.txt"
}

swift build -c release --product LilLeveler
BIN="$(swift build -c release --show-bin-path)/LilLeveler"
APP="$ROOT/dist/PodLeveler.app"

rm -rf "$APP"
rm -rf "$ROOT/dist/Lil Leveler.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LilLeveler"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
ICON_SRC="$HOME/.cursor/CougarCalc-Brand/icns/AppIcon-LilLeveler.icns"
if [[ -f "$ICON_SRC" ]]; then
  cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
fi
chmod +x "$APP/Contents/MacOS/LilLeveler"
install_lame "$APP"
ln -sfn "PodLeveler.app" "$ROOT/dist/Lil Leveler.app"
echo "Built $APP"
if [[ "${SKIP_REVEAL:-}" != "1" ]]; then
  open -R "$APP"
fi
