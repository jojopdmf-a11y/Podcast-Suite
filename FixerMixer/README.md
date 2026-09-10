# Fixer Mixer

Mac mixer for Podcast Stripper exports: **5 mono speaker channels** + **1 stereo Music/SFX** channel.

Native DSP (inspired by, not affiliated with): De-verb, Wetter, Leveler, graphic EQ.

## Build

```bash
chmod +x app/scripts/build_app.sh
./app/scripts/build_app.sh
```

Opens `dist/Fixer Mixer.app`. Keep the app inside this project folder.

## Use

1. Run Podcast Stripper on an episode
2. Drop the `_speakers` folder onto Fixer Mixer
3. Tweak per-channel processing
4. Play to audition, then **Bounce** for processed stems + `mix.wav`
