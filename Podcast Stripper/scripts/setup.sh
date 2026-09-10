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

echo "Installing Podcast Stripper engine packages (this downloads the speaker model stack)…"
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
echo "You still need a free Hugging Face token (one-time):"
echo "  1. Create an account at https://huggingface.co/join"
echo "  2. Create a Read token at https://huggingface.co/settings/tokens"
echo "  3. Open https://huggingface.co/pyannote/speaker-diarization-community-1"
echo "     and accept the terms."
echo "  4. Save the token in the Mac app Settings, or run:"
echo "     $ROOT/scripts/run_engine.sh --save-token YOUR_TOKEN"
echo
"$UV" run --project "$ROOT/engine" podcast-stripper --check-setup || true
