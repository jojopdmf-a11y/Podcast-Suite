# Podcast Stripper

A small Mac app that takes **one mixed podcast file** and writes **one WAV track per speaker**, plus a **Music_and_SFX** track for intros, beds, and sound effects. The tracks are the same length and line up in time. When someone is not talking, their speaker track is silence. You can drop the files into GarageBand, Logic, or any editor.

Audio is processed **on this Mac**. Nothing is uploaded.

This is version 1. It does not transcribe, name speakers, or unmix two people talking over each other.

Speaker detection uses [pyannote community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) on the original mix. Set **Speakers** to the real headcount when you know it — that is the main control if voices land wrong.

## Test an update

In the Podcast Suite folder, double-click **`Update Podcast Stripper.command`**. That pulls GitHub, rebuilds, and launches the app.

## What you need

**macOS 14 Sonoma or newer** — the app will not launch on older systems.

**We highly recommend** an Apple Silicon Mac (M1 or newer) with **16 GB of RAM**. A Mac mini M4 is a comfortable machine for weekly shows. Intel Macs are not recommended: the app may still open, but splits can take many times longer.

You also need:

- A free [Hugging Face](https://huggingface.co/join) account (speaker detection)
- About 2 GB of disk for Python packages and the speaker model

The suite README has the full Mac table (8 GB Air, Intel, etc.).

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

First run on a new Mac can be slower while models download (once). An M1 or M2 is often about 1.5–2× these times. More speakers add a little; music separation is most of the wait.

## First-time setup

Do these steps once.

### 1. Install Homebrew, ffmpeg, and uv

Open **Terminal**, paste this, and press Return:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Follow the prompts. When it finishes, it may tell you to run two more lines that start with `echo` and `eval`. Run those too.

Then install the tools:

```bash
brew install ffmpeg uv
```

If Homebrew is already installed, you only need that second command.

### 2. Install this project’s Python engine

In Terminal:

```bash
cd "/Users/audio/.cursor/Podcast Stripper"
chmod +x scripts/setup.sh scripts/run_engine.sh app/scripts/build_app.sh
./scripts/setup.sh
```

The first run downloads a large machine-learning stack. That can take several minutes.

### 3. Hugging Face token (required for speaker detection)

The speaker model is free. Hugging Face still requires a login and a one-time “I agree” click.

1. Create an account at [huggingface.co/join](https://huggingface.co/join)
2. Open [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens)
3. Click **Create new token**
4. Name it `podcast-stripper`, set the type to **Read**, and create it
5. Copy the token (it starts with `hf_`)
6. Open [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1)
7. Accept the user conditions
8. Save the token, either:
   - In the app: **Settings → paste token → Save token**, or
   - In Terminal:

```bash
./scripts/run_engine.sh --save-token hf_your_token_here
```

The token is stored in the **macOS Keychain**, not in this project. Never put it in a file you commit to git.

### 4. Build the Mac window

```bash
./app/scripts/build_app.sh
```

That creates `dist/Podcast Stripper.app`. Keep that app **inside this project folder** so it can find the engine. Double-click it like any other Mac app.

You do not need the full Xcode app from the App Store for this. The Mac command-line developer tools are enough to compile it.

## Use the app

1. Drop an `.mp3`, `.m4a`, `.wav`, `.aiff`, or `.flac` file onto the window
2. If you know how many people are talking, choose that number (2 is right for most interviews)
3. Click **Split into tracks**
4. Wait. The status line says what it is doing and how long it has been running. A one-hour episode is often around 15–20 minutes on a Mac mini M4; the first time on a new Mac also downloads a large model.
5. Click **Show in Finder**

You will get:

- `Speaker_1.wav`, `Speaker_2.wav`, …
- `Music_and_SFX.wav` (intros, music beds, and sound effects)
- `speakers.json` (who spoke when), useful if a voice landed on the wrong track

## Use Terminal instead

```bash
./scripts/run_engine.sh "/path/to/episode.m4a" -o "/path/to/output_folder" --num-speakers 2
```

Check that tools are ready:

```bash
./scripts/run_engine.sh --check-setup
```

## If something goes wrong

- **No Hugging Face token** — complete step 3. The error text will say `missing_token`.
- **Cannot download the model** — you must be logged in and must accept the community-1 terms. Use a **Read** token.
- **ffmpeg was not found** — run `brew install ffmpeg`, then `./scripts/setup.sh` again.
- **Speakers mixed up** — try setting the exact speaker count. Short clips and heavy music beds are harder. After detection, the app also fingerprint-checks turns and moves clear wrong-track moments to the matching speaker.
- **Two people talking at once** — that moment stays on whoever the app thinks was speaking. True unmixing is not in v1.

## Project layout

- `engine/` — Python that converts audio, detects speakers, and writes WAV tracks
- `app/` — SwiftUI Mac window
- `scripts/setup.sh` — install Python and packages
- `scripts/run_engine.sh` — run the splitter from Terminal
