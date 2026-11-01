#!/usr/bin/env bash
# Cloud Agent install step for the PodStripper Python engine.
# The three SwiftUI apps (PodStripper, PodProducer, PodLeveler) only build on
# macOS 14+, so on Linux the runnable/testable component is engine/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_DIR="$ROOT/Podcast Stripper/engine"

# uv drives Python + dependency management for the engine (mirrors scripts/setup.sh).
if ! command -v uv >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/uv" ]; then
  echo "==> Installing uv…"
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="$HOME/.local/bin:$PATH"

echo "==> Installing Python 3.12 via uv…"
uv python install 3.12

echo "==> Syncing engine dependencies (torch/demucs/pyannote + pytest)…"
uv sync --project "$ENGINE_DIR" --group dev

echo "==> Engine setup check:"
uv run --project "$ENGINE_DIR" podcast-stripper --check-setup || true

echo "==> PodStripper engine ready. Run tests with:"
echo "    uv run --project \"$ENGINE_DIR\" pytest"
