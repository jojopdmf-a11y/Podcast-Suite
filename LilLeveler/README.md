# Lil Leveler

Mac loudness finisher for podcast finals: drop a mix → pick a platform target → export a file that hits that integrated LUFS + true-peak ceiling.

Companion to **Podcast Stripper** and **Fixer Mixer**. Same dark cyan neon look.

## Test an update

In the Podcast Suite folder, double-click **`Update Lil Leveler.command`**. That pulls GitHub, rebuilds, and launches the app.

Needs **macOS 14 Sonoma or newer**. Leveler is the lightest of the three apps. See the suite README for Mac recommendations.

## Build

```bash
chmod +x app/scripts/build_app.sh
./app/scripts/build_app.sh
```

Opens `dist/Lil Leveler.app`.

## Use

1. Bounce a final mix from Fixer Mixer (or any stereo/mono master)
2. Drop it onto Lil Leveler (WAV, AIFF, MP3, M4A, CAF, FLAC, …)
3. Pick a platform preset, or **CUSTOM** then **SAVE PRESET** to keep your own LUFS / true-peak target
4. Watch the PRE / POST Dorrough meters while you play, then read the **FILE LOUDNESS** cards (integrated, short-term, momentary, true peak, sample peak)
5. Hit **PLAY**, drag the time slider, flip **A/B** between PRE (original) and POST (leveled)
6. **Export leveled** → `{name}_leveled.wav` (PCM WAV for host compatibility)

## Platform targets (v0.1)

| Preset | Integrated | True peak | Notes |
|---|---|---|---|
| Universal Podcast | −16 LUFS | −1.0 dBTP | Safe single master (Apple-aligned) |
| Apple Podcasts | −16 LUFS | −1.0 dBTP | Apple’s published podcast target |
| Spotify | −14 LUFS | −1.0 dBTP | Matches Spotify-style normalization |
| YouTube | −14 LUFS | −1.0 dBTP | Video / podcast upload norm |
| Amazon Music | −14 LUFS | −2.0 dBTP | Extra TP headroom |
| Mono Podcast | −19 LUFS | −1.0 dBTP | Mono ≈ stereo −16 perceived |
| Custom | user | user | Manual LUFS + TP |

Measurement uses an ITU-R BS.1770–style K-weighted integrated loudness with gating, plus a true-peak estimate and brickwall soft limit on export.

## Cross-platform later

Today the suite is **native macOS SwiftUI** (fast DSP, shared look). To ship Windows/Linux without rewriting three UIs:

1. Keep a **portable loudness core** (Swift → C or Rust) for measure / gain / true-peak
2. Thin UI shells per OS (SwiftUI Mac first; later Tauri/Flutter/WinUI)
3. Or a single **Tauri + Rust** app if you want one binary family sooner

Lil Leveler’s DSP is intentionally small so it’s the easiest candidate to extract first.
