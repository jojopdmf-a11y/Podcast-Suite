# PodStripper

A small Mac app that takes **one mixed podcast file** and writes **one track per speaker**, plus a **Music_and_SFX** track for intros, beds, and sound effects. The tracks are the same length and line up in time. When someone is not talking, their speaker track is silence. You can drop the files into GarageBand, Logic, or any editor.

On Split, pick **sample rate** (Native, 44.1, 48, or 96 kHz) and **format** (WAV 16-bit, WAV 24-bit, or AIFF 24-bit). The split still happens at the file’s native rate; conversion is only when writing the files.

Audio is processed **on this Mac**. Nothing is uploaded.

This is version 1. It does not transcribe, name speakers, or unmix two people talking over each other. When talk-over lands on several speaker tracks, Stripper keeps the main talker loud and ducks the extras so the mix does not jump up. It also fingerprint-checks each voice and the handoff into the next person, so a guest’s first words are less likely to sit on the host track.

Speaker detection uses [pyannote community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) (CC-BY-4.0) on the original mix. The model is included with the app. You do not need a Hugging Face account. Set **Speakers** to the real headcount when you know it — that is the main control if voices land wrong. Author credit is in **About**, **Settings**, and `NOTICE`.

## Test an update

In the PodStudio folder, double-click **`Update PodStripper.command`**. That pulls GitHub, rebuilds, and launches the app.

## What you need

**macOS 14 Sonoma or newer** — the app will not launch on older systems.

**We highly recommend** an Apple Silicon Mac (M1 or newer) with **16 GB of RAM**. A Mac mini M4 is a comfortable machine for weekly shows. Intel Macs are not recommended: the app may still open, but splits can take many times longer.

You also need about 2 GB of disk and Wi-Fi the **first time** you open the app (it installs the engine on this Mac). The speaker model is already in the app.

You do **not** need a Hugging Face account, Homebrew, or Terminal for the Mac app.

The suite README has the full Mac table (8 GB Air, Intel, etc.). In the app, **YOUR MAC** (next to Settings) reads this Mac’s chip and RAM and scales the wait estimate. Drop a file first to estimate that episode. The website copy lives in `docs/cougarcalc-system-requirements.md`.

## How long a split takes

The window shows a live clock and the current step (preparing audio, pulling music, who spoke when, writing tracks). When it finishes, that total stays on screen.

Timed on a **Mac mini M4**, **2 speakers**, **31-minute** episode: **9 minutes 23 seconds**. That is about **18 seconds of wait per minute of show**.

On that same class of Mac, 2 voices, ballpark:

| Episode | About this long to strip |
|---|---|
| 15 minutes | ~4–5 minutes |
| 30 minutes | ~9 minutes |
| 60 minutes | ~18 minutes |
| 90 minutes | ~27 minutes |
| 2 hours | ~35–40 minutes |

First open of the app on a new Mac installs the engine (once). The speaker model is already included, so the first split does not download it. An M1 or M2 is often about 1.5–2× these times. More speakers add a little; music separation is most of the wait.

## First-time setup (the Mac app)

Do these steps once. Stay on Wi-Fi.

1. Double-click **PodStripper**. The first open installs the engine on this Mac (about 2 GB). Wait until the status line says **Ready**. Homebrew is not required. You do not need a Hugging Face account.
2. Drop a podcast file, choose sample rate and format if you want something other than Native WAV 16-bit, and click **Split into tracks**.

### Hugging Face token (optional backup)

The usual app includes the speaker model. Settings still has a token field for a copy that is missing that model. You can leave it empty.

If you do save a backup token, it goes in the **macOS Keychain**, not in this project. Never put a token in a file you commit to git.

## Working from the project folder

This is only if you are building from GitHub, not for the downloaded app.

```bash
chmod +x scripts/setup.sh scripts/run_engine.sh app/scripts/build_app.sh scripts/bundle_runtime.sh
./scripts/setup.sh
./app/scripts/build_app.sh
```

`setup.sh` is for pytest and Terminal. The Mac window’s **build_app.sh** copies the engine, `uv`, and the speaker model into `dist/PodStripper.app`, so the app no longer has to sit next to this folder. You do not need the full Xcode app from the App Store. The Mac command-line developer tools are enough to compile it.

### Developer download of the speaker model

Customers never do this. `scripts/bundle_runtime.sh` (run by `build_app.sh`) calls `scripts/fetch_speaker_model.py` if the model is not already cached.

The cache lives outside the repo:

`~/Library/Application Support/CougarCalc/Podcast Stripper/models/speaker-diarization-community-1`

The script reads a developer token from the macOS Keychain (service `com.podcaststripper.huggingface`, account `hf_token`) or from `HF_TOKEN` in that process only. The token stays in memory for the download. It is not printed, not written into the model folder, and not copied into the app. Model weights are gitignored. Do not commit them.

If that download would be more than about 2 GB, the build stops and does not package it.

You can still save a backup token from Terminal:

```bash
./scripts/run_engine.sh --save-token YOUR_TOKEN
```

## Use the app

1. Drop an `.mp3`, `.m4a`, `.wav`, `.aiff`, or `.flac` file onto the window
2. If you know how many people are talking, choose that number (2 is right for most interviews)
3. Choose sample rate and format if you want something other than Native WAV 16-bit, then click **Split into tracks**
4. Wait. The status line says what it is doing and how long it has been running. A one-hour episode is often around 15–20 minutes on a Mac mini M4. The first open on a new Mac installs the engine; the speaker model is already in the app.
5. Click **Show in Finder**

You will get:

- `Speaker_1.wav`, `Speaker_2.wav`, … (or `.aiff` if you picked AIFF)
- `Music_and_SFX.wav` (intros, music beds, and sound effects)
- `speakers.json` (who spoke when), useful if a voice landed on the wrong track

## Use Terminal instead

```bash
./scripts/run_engine.sh "/path/to/episode.m4a" -o "/path/to/output_folder" --num-speakers 2 --sample-rate native --audio-format wav16
```

Check that tools are ready:

```bash
./scripts/run_engine.sh --check-setup
```

## If something goes wrong

- **Speaker model missing** — the usual app includes it. If a split stops immediately and says the model is missing, re-download PodStripper. A token in Settings is only a backup for that case. The error code is `missing_model`.
- **Cannot download the backup model** — the included model is the normal path. A backup token has to be a **Read** token for the community-1 model, and only if the included files are missing.
- **ffmpeg was not found** — close the window, wait until the first-open install finished, then open the app again. From the project folder you can run `./scripts/setup.sh`.
- **Speakers mixed up** — try setting the exact speaker count. Short clips and heavy music beds are harder. After detection, the app fingerprint-checks turns and the moment one person hands to the next, so the next talker’s first words are less likely to stay on the previous track. It does not transcribe or “understand” the conversation.
- **Two people talking at once** — that moment is not unmixed into two clean voices. The main talker stays loud on their track; extras are ducked so the mix does not jump up.

## Project layout

- `engine/` — Python that converts audio, detects speakers, and writes WAV tracks
- `app/` — SwiftUI Mac window
- `scripts/setup.sh` — install Python and packages (project builds / pytest)
- `scripts/run_engine.sh` — run the splitter from Terminal
- `scripts/bundle_runtime.sh` — copy the engine, `uv`, and the speaker model into the `.app`
- `scripts/fetch_speaker_model.py` — one-time developer download of the speaker model (token is not stored)
- `NOTICE` — CC-BY-4.0 credit for the pyannote community-1 model
