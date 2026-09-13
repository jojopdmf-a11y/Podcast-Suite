#!/bin/zsh
set -euo pipefail

# Copies the Python engine and a macOS uv binary into Podcast Stripper.app.
# Called from app/scripts/build_app.sh. Needs network once to fetch uv.
# Customers still download torch/demucs on first launch into Application Support.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-}"
if [[ -z "$APP" || ! -d "$APP/Contents" ]]; then
  echo "Usage: $0 /path/to/Podcast Stripper.app"
  exit 1
fi

RES="$APP/Contents/Resources"
mkdir -p "$RES/engine" "$RES/tools"

echo "==> Copying engine into the app…"
rsync -a --delete \
  --exclude '.venv/' \
  --exclude '.pytest_cache/' \
  --exclude 'tests/' \
  --exclude '__pycache__/' \
  --exclude '*.pyc' \
  "$ROOT/engine/" "$RES/engine/"
if [[ -f "$ROOT/engine/.python-version" ]]; then
  cp "$ROOT/engine/.python-version" "$RES/engine/.python-version"
fi

ARCH="$(uname -m)"
case "$ARCH" in
  arm64) UV_TRIPLE="aarch64-apple-darwin" ;;
  x86_64) UV_TRIPLE="x86_64-apple-darwin" ;;
  *)
    echo "Unsupported Mac architecture: $ARCH"
    exit 1
    ;;
esac

echo "==> Fetching uv for $UV_TRIPLE…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if [[ -x "$ROOT/tools/uv" ]]; then
  echo "==> Using cached uv: $ROOT/tools/uv"
  cp "$ROOT/tools/uv" "$RES/tools/uv"
else
  UV_URL="https://github.com/astral-sh/uv/releases/latest/download/uv-${UV_TRIPLE}.tar.gz"
  curl -fsSL "$UV_URL" -o "$TMP/uv.tgz"
  tar -xzf "$TMP/uv.tgz" -C "$TMP"
  if [[ -x "$TMP/uv-${UV_TRIPLE}/uv" ]]; then
    UV_BIN="$TMP/uv-${UV_TRIPLE}/uv"
  else
    UV_BIN="$(find "$TMP" -type f -name uv | head -n 1)"
  fi
  if [[ -z "${UV_BIN:-}" || ! -x "$UV_BIN" ]]; then
    echo "uv did not unpack from $UV_URL"
    exit 1
  fi
  mkdir -p "$ROOT/tools"
  cp "$UV_BIN" "$ROOT/tools/uv"
  chmod +x "$ROOT/tools/uv"
  cp "$ROOT/tools/uv" "$RES/tools/uv"
fi
chmod +x "$RES/tools/uv"
echo "Bundled uv: $RES/tools/uv"
echo "Bundled engine: $RES/engine"
