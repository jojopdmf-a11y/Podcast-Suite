# PodStudio

Local Mac apps for the CougarCalc podcast desk: **PodStripper** → **PodProducer** → **PodLeveler**. Together they are **PodStudio**.

This repo is the apps. The marketing site and free tools live in [CougarCalc](https://github.com/jojopdmf-a11y/CougarCalc).

## Layout

```
FixerMixer/           # PodProducer — stems → polish → bounce
LilLeveler/           # PodLeveler — final mix → platform loudness
Podcast Stripper/     # PodStripper — stereo mix → speaker tracks + music
```

(Folder names on disk stay as they are so updates and saved files keep working.)

## Test an update (easiest)

On a Mac, double-click one of these in this folder:

- **`Update PodStripper.command`**
- **`Update PodProducer.command`**
- **`Update PodLeveler.command`**

Each one pulls from GitHub, rebuilds that app, and launches it.

First time only: if macOS blocks it, right-click → Open.

If Update stops and says Apple’s developer tools need Agree: Spotlight → **Terminal**, paste `sudo xcodebuild -license accept`, type your Mac password (it will not show), Return, then double-click Update again. Or open the **Xcode** app once and click Agree.

## System requirements

**It only runs on macOS 14 Sonoma or newer.** The three apps will not launch on Ventura or older.

**We highly recommend** an Apple Silicon Mac (M1 or newer) with **16 GB of RAM**. A Mac mini M4 is a comfortable home for weekly shows. PodProducer and PodLeveler stay snappy on older Apple Silicon; **PodStripper** is the wait — it does the heavy lifting on this Mac (nothing is uploaded).

| | Works? | Notes |
|---|---|---|
| macOS 14+ Apple Silicon, 16 GB+ | Yes — this is the target | Stripper time is in the table below |
| M1 Air with 8 GB | Yes, but tight | Close other apps. Stripper can crawl and the Mac may swap |
| Intel Mac | Not recommended | Same buttons, much slower. Some Python pieces are a poor fit |

### How long Stripper takes

Timed on a **Mac mini M4**, **2 speakers**, a **31-minute** episode: **9 minutes 23 seconds** (about **18 seconds of wait per minute of show**, or roughly **one-third** the length of the episode).

Ballpark on that same class of Mac, 2 voices:

| Episode | About this long to strip |
|---|---|
| 15 minutes | ~4–5 minutes |
| 30 minutes | ~9 minutes |
| 60 minutes | ~18 minutes |
| 90 minutes | ~27 minutes |
| 2 hours | ~35–40 minutes |

The first time you open PodStripper, it installs the engine on this Mac (about 2 GB, once). Homebrew is not required. The first split can add extra time while the speaker model downloads. Three to five speakers add a little on “who spoke when”; pulling music is most of the wait and does not really care how many voices you picked. An M1/M2 is often about **1.5–2×** these numbers. The PodStripper window shows a live clock and what step it is on, then keeps the total when it finishes.

PodProducer and PodLeveler are light: mix and level in real time on any Apple Silicon Mac that meets the macOS 14 floor. PodProducer loads the whole episode into memory, so long shows with several speaker tracks are happier with 16 GB.

The **full public write-up** for cougarcalc.com is [`docs/cougarcalc-system-requirements.md`](docs/cougarcalc-system-requirements.md). Privacy and terms drafts for the site are [`docs/privacy-policy.md`](docs/privacy-policy.md) and [`docs/terms.md`](docs/terms.md). PodStripper also has a short **YOUR MAC** panel next to Settings.

## Saving your work

- **PodStripper** — nothing to save. Output folder and the Hugging Face token are already remembered.
- **PodProducer** — **SAVE MIX** writes `FixerMixer.mix.json` next to the tracks (same filename as before, so old folders still load). Drop that folder later and the mix comes back. **LOAD MIX…** opens a mix file. You can also drop any audio files (up to 8 speakers and 2 stereo beds), or **NEW SESSION** (empty mixer, no channels) then **ADD STRIP** / **RECORD**. **ALL TRACKS** stacks every waveform in one view; click a lane to zoom in on that strip. Pinch or scroll the wave to zoom; swipe left/right to move when zoomed. Shift-drag the waveform to mute a cough (silence, same length — not a cut).
- **PodLeveler** — **CUSTOM** → **SAVE PRESET** keeps your own LUFS / true-peak target in the PLATFORM list on this Mac.

## Build

Each app has `app/scripts/build_app.sh`. Run it from that app folder. Built `.app` bundles land in `dist/` and are not committed.

## Sync across Macs

Double-click the Update command above, or:

```bash
git pull
# …edit…
git push
```
