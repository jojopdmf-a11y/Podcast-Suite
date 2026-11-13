#!/bin/zsh
set -euo pipefail

# Copies the Python engine, the speaker model, and a macOS uv binary into the app.
# Called from app/scripts/build_app.sh. Needs network once to fetch uv.
# Customers still download torch/demucs on first launch into Application Support.
#
# The speaker model is downloaded once into Application Support, then copied
# into Contents/Resources/models. A developer Hugging Face token (Keychain
# service com.podcaststripper.huggingface, or HF_TOKEN for this command only)
# is used only for that download. It is not written into the app.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-}"
if [[ -z "$APP" || ! -d "$APP/Contents" ]]; then
  echo "Usage: $0 /path/to/PodStripper.app"
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

# Speaker model. Weights stay out of git. The fetch script reads a developer
# token into memory only when the cache is missing, and never prints it.
MODEL_DEST="${PODSTRIPPER_MODEL_CACHE:-$HOME/Library/Application Support/CougarCalc/Podcast Stripper/models/speaker-diarization-community-1}"
FETCH="$ROOT/scripts/fetch_speaker_model.py"
UV_BIN=""
if [[ -x "$ROOT/tools/uv" ]]; then
  UV_BIN="$ROOT/tools/uv"
elif command -v uv >/dev/null 2>&1; then
  UV_BIN="$(command -v uv)"
fi

echo "==> Preparing the speaker model…"
set +e
if [[ -n "$UV_BIN" ]]; then
  "$UV_BIN" run --project "$ROOT/engine" python "$FETCH" --dest "$MODEL_DEST"
  FETCH_STATUS=$?
else
  /usr/bin/python3 "$FETCH" --dest "$MODEL_DEST"
  FETCH_STATUS=$?
fi
set -e
if [[ "$FETCH_STATUS" -eq 2 ]]; then
  echo "Stopping: the speaker model is over about 2 GB, so it was not copied into the app."
  exit 1
fi
if [[ "$FETCH_STATUS" -ne 0 ]]; then
  echo "Stopping: the speaker model could not be prepared."
  exit "$FETCH_STATUS"
fi

echo "==> Copying speaker model into the app…"
mkdir -p "$RES/models/speaker-diarization-community-1"
rsync -a --delete \
  --exclude '.cache/' \
  --exclude 'diarization.gif' \
  "$MODEL_DEST/" "$RES/models/speaker-diarization-community-1/"
if [[ -f "$ROOT/NOTICE" ]]; then
  cp "$ROOT/NOTICE" "$RES/NOTICE"
fi
MODEL_BYTES="$(/usr/bin/python3 -c 'import sys; from pathlib import Path; root = Path(sys.argv[1]); print(sum(p.stat().st_size for p in root.rglob("*") if p.is_file()))' "$RES/models/speaker-diarization-community-1")"
echo "Bundled speaker model: $RES/models/speaker-diarization-community-1 ($MODEL_BYTES bytes)"
