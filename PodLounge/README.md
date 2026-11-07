# Pod Lounge

Pod Lounge is the project home for Stripper, Fixer, Trimmer, and Limiter. This build is a native macOS shell plus a self-contained project folder. The four cards open inside the same window. Limiter hosts the real PodLeveler UI and can save a leveled file into the depot. Stripper, Fixer, and Trimmer do not process audio, and nothing here launches the other apps.

Placeholder names (Stripper, Fixer, Trimmer, Limiter) are fine until the tools are connected.

## Project folder

A project is a directory ending in `.podlounge`:

```
ShowName.podlounge/
  manifest.json                 formatVersion 1, written atomically
  depot/originals/<name>.<ext>  imported copies, readable file name, id stays a UUID
  depot/results/<name>.<ext>    Limiter results, same naming; " 2", " 3" on collisions
  workspaces/limiter.json       Limiter preset, meters, and output choices
  workspaces/*.json             other cards stay empty stubs; manifest holds notes
  recovery/                     reserved for future long recordings
```

`manifest.json` is the source of truth. Media references are package-relative paths (`depot/originals/Morning Show.wav`), never absolute paths and never `..`. New imports and Limiter results are stored under the sanitized display name. A second file with the same name gets " 2", " 3", and so on. Asset ids stay UUIDs. Older projects whose files are still named with those UUIDs open unchanged; nothing renames them. The file you picked is only read.

**Save Project** updates the manifest (name, notes, selection) and `workspaces/limiter.json` with a temp file and rename. It does not rewrite depot audio and it does not make another copy.

**Save As** copies the folder once, then writes the manifest on the copy. Moving the folder does not break the relative paths.

**Save Result to Depot** in the Limiter workspace writes a new file into `depot/results` (`producedBy` is `limiter`). The depot selection stays on the file you were leveling. The depot file you leveled is not modified.

Opening a newer `formatVersion`, a broken manifest, or a path that escapes the folder fails and leaves the folder untouched. A missing depot file stays listed as missing. Save does not recreate it.

## Future Fixer recording

When Fixer can record, the user stays in Fixer until they press Stop. Lounge navigation — Back to Lounge, switching cards, New, Open, Save — must never stop or discard a take. This build has no recorder. The Fixer screen only says that the rule exists; it does not pretend a take is in progress.

## Build

Requires macOS 14 or newer and the command-line developer tools.

```bash
cd PodLounge/app
swift test
SKIP_REVEAL=1 ./scripts/build_app.sh
```

The app bundle is `PodLounge/dist/PodLounge.app` (not committed). Launch it from Finder when you want the window. Bundle id: `com.cougarcalc.podlounge`.

## What is not in this build

- No Stripper, Fixer, or Trimmer engines. Limiter is the real PodLeveler, including its playback.
- No recording. Fixer still does not record.
- Depot length is read from the file header when AudioToolbox can do that; otherwise the row shows an em dash
- No licensing or shipping packaging
