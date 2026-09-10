# Podcast Suite

Local Mac apps for the CougarCalc podcast desk: **Podcast Stripper** → **Fixer Mixer** → **Lil Leveler**.

This repo is the apps. The marketing site and free tools live in [CougarCalc](https://github.com/jojopdmf-a11y/CougarCalc).

## Layout

```
FixerMixer/           # stems → polish → bounce
LilLeveler/           # final mix → platform loudness
Podcast Stripper/      # stereo mix → speaker tracks + music
```

## Build

Each app has `app/scripts/build_app.sh`. Run it from that app folder. Built `.app` bundles land in `dist/` and are not committed.

## Sync across Macs

```bash
git pull
# …edit…
git push
```
