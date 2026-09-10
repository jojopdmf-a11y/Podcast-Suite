#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UV=""

if [[ -x "$ROOT/tools/uv" ]]; then
  UV="$ROOT/tools/uv"
elif [[ -x "$ROOT/tools/uv-venv/bin/uv" ]]; then
  UV="$ROOT/tools/uv-venv/bin/uv"
elif command -v uv >/dev/null 2>&1; then
  UV="$(command -v uv)"
elif [[ -x "$HOME/.local/bin/uv" ]]; then
  UV="$HOME/.local/bin/uv"
fi

if [[ -z "$UV" ]]; then
  echo "uv is not installed. Install it first:"
  echo "  brew install uv"
  echo "or follow https://docs.astral.sh/uv/getting-started/installation/"
  exit 1
fi

exec "$UV" run --project "$ROOT/engine" podcast-stripper "$@"
