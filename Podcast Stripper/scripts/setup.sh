#!/bin/zsh
set -euo pipefail

# Installs Python, project packages, and ffmpeg for this Mac.
# Safe to run more than once.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v brew >/dev/null 2>&1 && [[ ! -x /opt/homebrew/bin/brew ]]; then
  echo "Homebrew is not installed."
  echo "Install it from https://brew.sh then run this script again, or continue and we will use a bundled ffmpeg."
else
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi
fi

install_uv() {
  if [[ -x "$ROOT/tools/uv" ]]; then
    echo "uv: $ROOT/tools/uv"
    return
  fi
  if [[ -x "$ROOT/tools/uv-venv/bin/uv" ]]; then
    echo "uv: $ROOT/tools/uv-venv/bin/uv"
    return
  fi
  if command -v uv >/dev/null 2>&1; then
    echo "uv: $(command -v uv)"
    return
  fi
  if command -v brew >/dev/null 2>&1; then
    echo "Installing uv with Homebrew…"
    brew install uv
    return
  fi
  echo "Installing uv with pip into tools/uv-venv…"
  mkdir -p "$ROOT/tools"
  python3 -m pip install --target "$ROOT/tools/uv-venv" uv
  if [[ ! -x "$ROOT/tools/uv-venv/bin/uv" ]]; then
    echo "Could not install uv. Install Homebrew from https://brew.sh then run: brew install uv"
    exit 1
  fi
  echo "uv: $ROOT/tools/uv-venv/bin/uv"
}

install_uv

UV="$(command -v uv 2>/dev/null || true)"
if [[ -x "$ROOT/tools/uv" ]]; then
  UV="$ROOT/tools/uv"
elif [[ -x "$ROOT/tools/uv-venv/bin/uv" ]]; then
  UV="$ROOT/tools/uv-venv/bin/uv"
fi
if [[ -z "$UV" ]]; then
  echo "uv was installed but not found on PATH."
  exit 1
fi

echo "Installing Python 3.12 with uv…"
"$UV" python install 3.12

echo "Installing PodStripper engine packages (this downloads the speaker model stack)…"
"$UV" sync --project "$ROOT/engine" --group dev

if command -v brew >/dev/null 2>&1; then
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "Installing ffmpeg with Homebrew…"
    brew install ffmpeg
  else
    echo "ffmpeg: $(command -v ffmpeg)"
  fi
else
  echo "Homebrew not found; the engine will use its bundled ffmpeg."
fi

echo
echo "Setup of tools is done."
echo
echo "Customers do not need a Hugging Face account. The speaker model is"
echo "downloaded once when you build the app, then copied into the .app."
echo "  ./scripts/fetch_speaker_model.py"
echo "  ./app/scripts/build_app.sh"
echo
echo "That download reads a developer token from the macOS Keychain"
echo "(service com.podcaststripper.huggingface) or from HF_TOKEN in that"
echo "process only. The token is not printed and is not shipped in the app."
echo "A token in Settings is only a backup if the bundled model is missing."
echo
"$UV" run --project "$ROOT/engine" podcast-stripper --check-setup || true
