# PodStripper

A small Mac app that takes **one mixed podcast file** and writes **one WAV track per speaker**, plus a **Music_and_SFX** track for intros, beds, and sound effects. The tracks are the same length and line up in time. When someone is not talking, their speaker track is silence. You can drop the files into GarageBand, Logic, or any editor.

Audio is processed **on this Mac**. Nothing is uploaded.

This is version 1. It does not transcribe, name speakers, or unmix two people talking over each other. When talk-over lands on several speaker tracks, Stripper keeps the main talker loud and ducks the extras so the mix does not jump up. It also fingerprint-checks each voice and the handoff into the next person, so a guest’s first words are less likely to sit on the host track.

Speaker detection uses [pyannote community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) on the original mix. Set **Speakers** to the real headcount when you know it — that is the main control if voices land wrong.

## Test an update

In the PodStudio folder, double-click **`Update PodStripper.command`**. That pulls GitHub, rebuilds, and launches the app.

## What you need

**macOS 14 Sonoma or newer** — the app will not launch on older systems.

**We highly recommend** an Apple Silicon Mac (M1 or newer) with **16 GB of RAM**. A Mac mini M4 is a comfortable machine for weekly shows. Intel Macs are not recommended: the app may still open, but splits can take many times longer.

You also need:

- A free [Hugging Face](https://huggingface.co/join) account (speaker detection)
- About 2 GB of disk and Wi-Fi the **first time** you open the app (it installs the engine on this Mac)

You do **not** need Homebrew or Terminal for the Mac app.

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

First open of the app on a new Mac installs the engine (once). The first split can also download the speaker model. An M1 or M2 is often about 1.5–2× these times. More speakers add a little; music separation is most of the wait.

## First-time setup (the Mac app)

Do these steps once. Stay on Wi-Fi.

1. Double-click **PodStripper**. The first open installs the engine on this Mac (about 2 GB). Wait until the status line says **Ready** (or asks for a Hugging Face token). Homebrew is not required.
2. Add the Hugging Face token below.
3. Drop a podcast file and click **Split into tracks**.

### Hugging Face token (required for speaker detection)

The speaker model is free. Hugging Face still requires a login and a one-time “I agree” click.

1. Create an account at [huggingface.co/join](https://huggingface.co/join)
2. Open [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens)
3. Click **Create new token**
4. Name it `podcast-stripper`, set the type to **Read**, and create it
5. Copy the token (it starts with `hf_`)
6. Open [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1)
7. Accept the user conditions
8. In the app: **Settings → paste token → Save token**

The token is stored in the **macOS Keychain**, not in this project. Never put it in a file you commit to git.

## Working from the project folder

This is only if you are building from GitHub, not for the downloaded app.

```bash
chmod +x scripts/setup.sh scripts/run_engine.sh app/scripts/build_app.sh scripts/bundle_runtime.sh
./scripts/setup.sh
./app/scripts/build_app.sh
```

`setup.sh` is for pytest and Terminal. The Mac window’s **build_app.sh** copies the engine and `uv` into `dist/PodStripper.app`, so the app no longer has to sit next to this folder. You do not need the full Xcode app from the App Store. The Mac command-line developer tools are enough to compile it.

To save a token from Terminal instead of Settings:

```bash
./scripts/run_engine.sh --save-token hf_your_token_here
```

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

- **No Hugging Face token** — complete the Hugging Face steps above. The error text will say `missing_token`.
- **Cannot download the model** — you must be logged in and must accept the community-1 terms. Use a **Read** token.
- **ffmpeg was not found** — close the window, wait until the first-open install finished, then open the app again. From the project folder you can run `./scripts/setup.sh`.
- **Speakers mixed up** — try setting the exact speaker count. Short clips and heavy music beds are harder. After detection, the app fingerprint-checks turns and the moment one person hands to the next, so the next talker’s first words are less likely to stay on the previous track. It does not transcribe or “understand” the conversation.
- **Two people talking at once** — that moment is not unmixed into two clean voices. The main talker stays loud on their track; extras are ducked so the mix does not jump up.

## Project layout

- `engine/` — Python that converts audio, detects speakers, and writes WAV tracks
- `app/` — SwiftUI Mac window
- `scripts/setup.sh` — install Python and packages (project builds / pytest)
- `scripts/run_engine.sh` — run the splitter from Terminal
- `scripts/bundle_runtime.sh` — copy the engine and `uv` into the `.app`
