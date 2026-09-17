# PodProducer

Mac mixer for **PodStripper** exports **or any audio files you drop**: **up to 8 speaker strips** plus **up to 2 stereo beds** (MUSIC, then SFX). You can also **start empty, Record from your interface, and punch a cough** on the waveform. Still a mixer, not an editor — no cut / copy / paste / ripple.

Native DSP (inspired by, not affiliated with): De-verb, Wetter (Drum / Studio / Stage rooms for dry voices), Leveler, **EQ 2520** (10-band graphic with 560-style proportional Q and extra fader travel in ±4 dB), plus a speaker-only proportional-Q parametric band (Notch / Narrow / Wide).

## Test an update

In the PodStudio folder, double-click **`Update PodProducer.command`**. That pulls GitHub, rebuilds, and launches the app.

Needs **macOS 14 Sonoma or newer**. PodProducer is light compared with PodStripper; any Apple Silicon Mac with 16 GB RAM is a comfortable match. See the suite README for the full Mac notes.

## Use

1. Drop a PodStripper `_speakers` folder, **or** drop one or more audio files (WAV, AIFF, MP3, M4A…), **or** click **NEW SESSION**.
2. **NEW SESSION** opens an empty mixer (no channels) at **your interface’s sample rate** (Audio MIDI / Dante 96 kHz stays 96 kHz). Playback is always that session rate — the file’s native rate. **ADD STRIP** for a speaker; **REMOVE STRIP** (or REMOVE on the strip) if you added one you do not need. Pick **INPUT** (the interface). On each speaker strip pick **IN 1 / IN 2 / …**. Stereo beds have no record. A Desktop folder is created when you Record.
3. **RECORD** writes every armed strip from the playhead. It overwrites that span. The show can grow. **Monitor mics on your interface.** PodProducer does not play the mic back (that would be late and confusing).
4. Click the waveform to seek. Pinch or scroll up/down on the wave to zoom; two-finger swipe left or right to move along the file when zoomed. **RESET** shows the whole file again. **ALL TRACKS** stacks every strip in one view (same order as the mixer). Extra tracks scroll inside that box; extra speaker strips scroll sideways. Mixer does not grow off the screen. Click a lane to zoom in on that channel. **SEL** a strip, then **Shift-drag** the waveform to silence that span (the show stays the same length — not a cut). **Option-drag** clears a mute. The strip **MUTE** button is the whole channel. **SOLO** hears that strip alone (or several, if more than one SOLO is on).
5. Each audio file you drop becomes a channel. A file with “music” or “sfx” in the name becomes a stereo bed (first MUSIC, second SFX — PodProducer stops at two). Everything else is a speaker strip, **capped at 8**. Extra files past those caps are skipped, not dumped onto another strip. Stereo files on a speaker strip are summed to mono.
6. Tweak per-channel processing. **ADD TRACKS…** (or drop more files) adds channels to the mix that’s already open. **ADD STRIP** adds an empty speaker strip (still capped at 8). **REMOVE STRIP** deletes an unused empty speaker strip. **REORDER** then drag a strip onto another strip (same idea as dragging DSP chips).
7. **SAVE MIX** writes `FixerMixer.mix.json` into the folder (same filename as before, so old folders still load) — mute paints and IN assignments come back when you drop that folder later. Audio stays in the WAV files.
8. Play to audition, then **EXPORT…** for processed stems + a 2-mix. Choose **Native** (this session’s rate) or 44.1 / 48 / 96 kHz, and **WAV 16-bit**, **WAV 24-bit**, or **AIFF 24-bit**. Sample-rate conversion happens only on Export.
