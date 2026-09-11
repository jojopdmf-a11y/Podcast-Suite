# Podcast Suite — Mac requirements & how long Stripper takes

This is the **full public copy** for [cougarcalc.com](https://cougarcalc.com). Website edits happen in the CougarCalc repo / that chat. Keep this file as the source of truth and port it over.

The **short** version also lives in Podcast Stripper: **YOUR MAC** (next to Settings).

---

## The short version

**It only runs on macOS 14 Sonoma or newer.** The three local apps — Podcast Stripper, Fixer Mixer, and Lil Leveler — will not launch on Ventura or older.

**We highly recommend** an Apple Silicon Mac (M1 or newer) with **16 GB of RAM**. A Mac mini M4 is a comfortable machine for weekly shows.

Stripper is the wait. On a Mac mini M4, a **31-minute** two-person episode took **9 minutes 23 seconds** to strip (about **18 seconds of wait per minute of show**). Mixer and Leveler stay light.

Everything runs **on this Mac**. Nothing is uploaded.

---

## What this software is

CougarCalc Podcast Suite is three small Mac apps you run locally:

1. **Podcast Stripper** — one mixed episode in; one WAV track per speaker, plus a Music/SFX track, out.
2. **Fixer Mixer** — polish those stems (EQ, small rooms, leveler) and bounce.
3. **Lil Leveler** — hit a platform loudness target on the final mix.

They are not a website tool and not a cloud render farm. Speed depends on the Mac in front of you.

---

## Operating system

| | |
|---|---|
| **Required** | **macOS 14 Sonoma** or newer |
| Will not launch | macOS 13 Ventura and older |

Apple calls the system **macOS** (not OS X). Check: Apple menu → About This Mac.

---

## Hardware we highly recommend

| | Recommendation |
|---|---|
| Chip | **Apple Silicon** — M1, M2, M3, or M4 |
| Memory | **16 GB RAM** or more |
| A comfortable weekly machine | **Mac mini M4** (this is the machine we timed) |
| Disk | A couple of GB free for Stripper’s models (one-time download) |

Apple Silicon matters most for **Stripper**. Mixer and Leveler are native audio and feel fine on any Apple Silicon Mac that meets the macOS 14 floor.

---

## Will it work on my Mac?

| Mac | Works? | What to expect |
|---|---|---|
| macOS 14+, Apple Silicon, 16 GB+ | **Yes — this is the target** | Stripper wait is in the table below |
| M2 / M3 Mini or better | Yes | Close to the M4 times, a little slower on older chips |
| M1 Mini or Air, 16 GB | Yes | Same features. Stripper often about **1.5–2×** the M4 wait |
| M1 Air, **8 GB** | Yes, but **tight** | Close other apps. Stripper can crawl; the Mac may swap to disk |
| Intel Mac | **Not recommended** | Same buttons, much slower. Some of the Python pieces are a poor fit for Intel |

**Functionality** (does it split, does the EQ sound the same) does not depend on an M4. **Patience** does, and almost all of that patience is Stripper.

---

## How long Podcast Stripper takes

Stripper does the heavy work on your CPU (pulling music off the voices) and uses Apple’s GPU when it can for “who spoke when.” The window shows a **live clock** and **what step it is on**. When the job finishes, the **total time stays on screen**.

### Measured baseline

| | |
|---|---|
| Machine | Mac mini **M4** |
| Speakers setting | **2** |
| Episode length | **31 minutes** |
| Time to finish | **9 minutes 23 seconds** |

That is about **18 seconds of wait per minute of show**, or roughly **one-third** the length of the episode.

### Ballpark on that same class of Mac (2 voices)

| Episode length | About this long to strip |
|---|---|
| 15 minutes | ~4–5 minutes |
| 30 minutes | ~9 minutes |
| 60 minutes | ~18 minutes |
| 90 minutes | ~27 minutes |
| 2 hours | ~35–40 minutes |

These are **estimates**, not a promise. Real time moves with:

- **Episode length** (almost linear — twice the show is about twice the wait)
- **Which Mac** (M1/M2 often 1.5–2× the table; Intel much more)
- **First run on a new Mac** — extra time while models download (a couple of GB, **once**)
- **Other apps open**, heat, and power mode
- **Speaker count** — 3–5 voices add a little on “who spoke when.” Pulling music is most of the wait and does not really care how many voices you picked

If a step looks stuck, the status line still ticks the clock. You can cancel.

---

## Fixer Mixer and Lil Leveler

These two are **light** compared with Stripper.

- **Fixer Mixer** — real-time playback and EQ on Apple Silicon. It loads the whole episode into memory, so long shows with several speaker tracks are happier with **16 GB RAM**.
- **Lil Leveler** — one stereo (or mono) mix, loudness measurement and export. Fine on any Mac that meets the OS floor.

You should not need to “wait through” Mixer or Leveler the way you wait through Stripper.

---

## Privacy

Audio is processed **on this Mac**. Files are not uploaded to CougarCalc or to a render server. Speaker detection uses a model you agree to on Hugging Face; that is a one-time login/token, not your episode going to the cloud.

---

## If you are deciding whether to use it

1. Confirm **macOS 14+** and, ideally, **Apple Silicon + 16 GB**.
2. Treat Stripper as a **coffee-break** for a typical interview, and a **longer break** for a two-hour show.
3. Use the lime clock in Stripper as the honest scoreboard on *your* Mac — the table above is a starting point from one M4 Mini.

Questions: hello@cougarcalc.com
