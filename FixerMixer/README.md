# Fixer Mixer

Mac mixer for Podcast Stripper exports: **5 mono speaker channels** + **1 stereo Music/SFX** channel.

Native DSP (inspired by, not affiliated with): De-verb, Wetter (Drum / Studio / Stage rooms for dry voices), Leveler, **EQ 2520** (10-band graphic with 560-style proportional Q and extra fader travel in ±4 dB), plus a speaker-only proportional-Q parametric band (Notch / Narrow / Wide).

## Test an update

In the Podcast Suite folder, double-click **`Update Fixer Mixer.command`**. That pulls GitHub, rebuilds, and launches the app.

Needs **macOS 14 Sonoma or newer**. Mixer is light compared with Stripper; any Apple Silicon Mac with 16 GB RAM is a comfortable match. See the suite README for the full Mac notes.

## Use

1. Run Podcast Stripper on an episode
2. Drop the `_speakers` folder onto Fixer Mixer
3. Tweak per-channel processing
4. Play to audition, then **Bounce** for processed stems + `mix.wav`
