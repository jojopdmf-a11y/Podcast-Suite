# AGENTS.md — PodStudio

PodStudio is three macOS apps plus one shared Python engine, all in this repo:

| Folder | App name | What it does |
|---|---|---|
| `Podcast Stripper/` | **PodStripper** | One mixed episode → one aligned track per speaker + a Music/SFX track. Has a Python engine (`engine/`) and a SwiftUI app (`app/`). |
| `FixerMixer/` | **PodProducer** | Stems → polish → bounce. SwiftUI app only. |
| `LilLeveler/` | **PodLeveler** | Final mix → platform loudness. SwiftUI app only. |

Folder names on disk intentionally differ from the product names; do not rename them (updates and saved files depend on the paths).

## The one rule that decides where work can run

- **The Python engine (`Podcast Stripper/engine/`) runs anywhere**, including Linux and Cursor Cloud Agents.
- **The three SwiftUI apps only build and run on macOS 14 (Sonoma) or newer.** They use `swift-tools-version: 6.0` and target `.macOS(.v14)`. They **cannot be built or tested on Linux / in a cloud agent** — a Swift/macOS toolchain and macOS frameworks (AppKit, AVFoundation, SwiftUI) are required.

So: edit Swift code anywhere, but **build/test the apps only on a Mac** (use a local agent on the user's Mac). Do engine work anywhere.

## Python engine — `Podcast Stripper/engine/`

Managed with [`uv`](https://docs.astral.sh/uv/). Python 3.12 (see `.python-version`). Dependencies include `numpy`, `pyannote.audio`, `demucs` (Torch), and `imageio-ffmpeg`.

Set up:

```bash
# Linux / Cursor Cloud (also runs automatically on cloud boot):
bash .cursor/install.sh

# macOS (Terminal): the repo's own script — needs zsh, is NOT available on the cloud image:
./"Podcast Stripper"/scripts/setup.sh
```

Common commands (run from `Podcast Stripper/engine/`, or add `--project "Podcast Stripper/engine"`):

```bash
uv sync --group dev                      # install/refresh deps (idempotent)
uv run pytest                            # run the test suite (36 tests)
uv run podcast-stripper --check-setup    # verify ffmpeg + token, exit 0 if ffmpeg found
uv run podcast-stripper --version
```

Run a real split **without any model download or token** (good for end-to-end checks):

```bash
# make a synthetic 2-speaker clip + a segments sidecar
uv run python scripts/generate_test_clip.py -o /tmp/demo/episode.wav
# split using provided speaker turns; --skip-separate avoids the Demucs model
uv run podcast-stripper /tmp/demo/episode.wav -o /tmp/demo/tracks \
  --from-segments /tmp/demo/episode_segments.json --skip-separate \
  --sample-rate 48000 --audio-format wav24
```

This writes `Speaker_1.wav`, `Speaker_2.wav`, `Music_and_SFX.wav`, and `speakers.json`. Splitting always happens at the file's native sample rate; sample-rate/format conversion only happens on export.

**Full speaker diarization** (the real AI model, no `--from-segments`) additionally needs a **Hugging Face token** and one-time acceptance of the model terms at <https://huggingface.co/pyannote/speaker-diarization-community-1>. Provide the token via the `HF_TOKEN` env var, `--hf-token`, or `podcast-stripper --save-token <token>`. Never commit a token.

## macOS apps (build only on a Mac)

Each app is a Swift Package under `<App>/app` with a build script that produces a `.app` bundle in `<App>/dist/` (not committed). Requires the macOS command-line developer tools (full Xcode not required).

```bash
# PodStripper
cd "Podcast Stripper/app" && swift build -c release --product PodcastStripper
./scripts/build_app.sh          # -> Podcast Stripper/dist/PodStripper.app

# PodProducer
cd FixerMixer/app && swift build -c release --product FixerMixer
./scripts/build_app.sh          # -> FixerMixer/dist/PodProducer.app

# PodLeveler
cd LilLeveler/app && swift build -c release --product LilLeveler
./scripts/build_app.sh          # -> LilLeveler/dist/PodLeveler.app
```

`build_app.sh` uses `zsh`, and for PodStripper it also bundles the engine + a macOS `uv` into the app. Set `SKIP_REVEAL=1` to skip the Finder reveal.

## Cursor Cloud specific instructions

- The Cloud Agent environment is defined in `.cursor/environment.json` and installs the Python engine via `.cursor/install.sh` (bootstraps `uv` + Python 3.12, then `uv sync --group dev`). System `ffmpeg` is present in the base image; `imageio-ffmpeg` is a bundled fallback.
- **Cloud agents can fully work on and test the Python engine** (install, `pytest`, end-to-end splits, and Demucs music separation on CPU all work on Linux).
- **Cloud agents cannot build or test the three SwiftUI apps.** For any change that needs an app built or its UI tested, hand off to a **local agent on a macOS 14+ Mac** (e.g. via Move to Cloud / Remote Control, or run the build scripts above on the Mac).
- For diarization tests in the cloud, add the Hugging Face token as a Cursor **Secret** named `HF_TOKEN`; otherwise use the `--from-segments` path, which needs no token.
