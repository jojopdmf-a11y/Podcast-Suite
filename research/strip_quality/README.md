# TheStrip sound-quality harness

Offline experiments for speaker-track gating and separation swirl. This does not change PodStripper, Pod Lounge, or any shipped app.

Run it with the engine's existing virtualenv (no extra installs):

```bash
cd "/Users/jjstudios/GrokBot/pod-limiter"
HF_HUB_OFFLINE=1 \
  "Podcast Stripper/engine/.venv/bin/python" \
  research/strip_quality/harness.py all
```

Scratch audio is written under `/tmp/strip-quality-scratch` and is not part of the repo. Delete that folder when the listening pack and the report are done. The pack goes to `~/Music/ClubPod/StripTests/2026-11-14/`. Metrics land in `.ppjob/strip-quality-metrics.json` (that folder is gitignored).

Stages: `probe`, `diarize`, `separate`, `render`, `pack`, `all`.
`pack` only works after `separate` has cached stems.

The source episode is opened read-only.
