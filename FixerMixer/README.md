# Fixer Mixer

Mac mixer for **Podcast Stripper** exports **or any audio files you drop**: speaker strips plus an optional stereo Music/SFX channel.

Native DSP (inspired by, not affiliated with): De-verb, Wetter (Drum / Studio / Stage rooms for dry voices), Leveler, **EQ 2520** (10-band graphic with 560-style proportional Q and extra fader travel in ±4 dB), plus a speaker-only proportional-Q parametric band (Notch / Narrow / Wide).

## Test an update

In the Podcast Suite folder, double-click **`Update Fixer Mixer.command`**. That pulls GitHub, rebuilds, and launches the app.

Needs **macOS 14 Sonoma or newer**. Mixer is light compared with Stripper; any Apple Silicon Mac with 16 GB RAM is a comfortable match. See the suite README for the full Mac notes.

## Use

1. Drop a Podcast Stripper `_speakers` folder, **or** drop one or more audio files (WAV, AIFF, MP3, M4A…)
2. Each audio file becomes a channel. A file with “music” or “sfx” in the name becomes the MUSIC strip; everything else is a speaker strip (stereo files are summed to mono for that strip).
3. Tweak per-channel processing. **ADD TRACKS…** (or drop more files) adds channels to the mix that’s already open.
4. **SAVE MIX** writes `FixerMixer.mix.json` into the folder — drop that folder later and the mix comes back
5. Play to audition, then **Bounce** for processed stems + `mix.wav`
