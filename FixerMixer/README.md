# Fixer Mixer

Mac mixer for **Podcast Stripper** exports **or any audio files you drop**: **up to 8 speaker strips** plus **up to 2 stereo beds** (MUSIC, then SFX). You can also **start empty, Record from your interface, and punch a cough** on the waveform. Still a mixer, not an editor — no cut / copy / paste / ripple.

Native DSP (inspired by, not affiliated with): De-verb, Wetter (Drum / Studio / Stage rooms for dry voices), Leveler, **EQ 2520** (10-band graphic with 560-style proportional Q and extra fader travel in ±4 dB), plus a speaker-only proportional-Q parametric band (Notch / Narrow / Wide).

## Test an update

In the Podcast Suite folder, double-click **`Update Fixer Mixer.command`**. That pulls GitHub, rebuilds, and launches the app.

Needs **macOS 14 Sonoma or newer**. Mixer is light compared with Stripper; any Apple Silicon Mac with 16 GB RAM is a comfortable match. See the suite README for the full Mac notes.

## Use

1. Drop a Podcast Stripper `_speakers` folder, **or** drop one or more audio files (WAV, AIFF, MP3, M4A…), **or** click **NEW SESSION**.
2. **NEW SESSION** opens an empty mixer (no channels) at 48 kHz. **ADD STRIP** for a speaker. Pick **INPUT** (the interface). On each speaker strip pick **IN 1 / IN 2 / …**. Stereo beds have no record. A Desktop folder is created when you Record.
3. **RECORD** writes every armed strip from the playhead. It overwrites that span. The show can grow. **Monitor mics on your interface.** Mixer does not play the mic back (that would be late and confusing).
4. Click the waveform to seek. **ALL TRACKS** stacks every strip in one view (speakers top to bottom, then stereo beds). Extra tracks scroll inside that box; extra speaker strips scroll sideways. Mixer does not grow off the screen. Click a lane to zoom in on that channel. **Shift-drag** paints mute (silence — the show stays the same length). **Option-drag** clears a mute. The strip **MUTE** button is the whole channel; it cannot punch a cough. **SOLO** hears that strip alone (or several, if more than one SOLO is on).
5. Each audio file you drop becomes a channel. A file with “music” or “sfx” in the name becomes a stereo bed (first MUSIC, second SFX — Mixer stops at two). Everything else is a speaker strip, **capped at 8**. Extra files past those caps are skipped, not dumped onto another strip. Stereo files on a speaker strip are summed to mono.
6. Tweak per-channel processing. **ADD TRACKS…** (or drop more files) adds channels to the mix that’s already open. **ADD STRIP** adds an empty speaker strip (still capped at 8).
7. **SAVE MIX** writes `FixerMixer.mix.json` into the folder — mute paints and IN assignments come back when you drop that folder later. Audio stays in the WAV files.
8. Play to audition, then **EXPORT…** for processed stems + `mix.wav`.
