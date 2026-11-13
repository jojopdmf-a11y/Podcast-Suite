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

swift build -c release --product PodLounge
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/PodLounge"
APP="$ROOT/dist/PodLounge.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PodLounge"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/PodLounge"
install_lame "$APP"

# Same engine source, lockfile, and uv the standalone app bundles. The installed
# environment stays in ~/Library/Application Support/CougarCalc/Podcast Stripper.
STRIPPER_ROOT="$(cd "$ROOT/../Podcast Stripper" && pwd)"
chmod +x "$STRIPPER_ROOT/scripts/bundle_runtime.sh"
"$STRIPPER_ROOT/scripts/bundle_runtime.sh" "$APP"

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
