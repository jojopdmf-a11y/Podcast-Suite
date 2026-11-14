# TheStrip sound check — 14 Nov 2026

The gated sound is a hard mute. When a person stops talking, TheStrip sets that speaker's track to real silence, even though the room tone was still in the voice a moment earlier.

On a real pause in the Veterans Day episode, today's track falls from normal speech to complete silence. The original recording only falls about 31 dB, down to ordinary room tone.

Putting that room tone back at its real level removes the hole. Leaving it 20, 30, or 40 dB quieter than the recording still sounds like a gate.

Holding a speaker's track open across gaps shorter than about 2 seconds does the same job on plain talking. On the music opening it lets the wrong sound through, so that trick should not be the only fix.

The watery swirl was barely in these voices. The separation settings we tried did not clean it up, and the slower "higher quality" pass took twice as long for no real change on this episode.

Nothing in the apps was changed. The listening files are in `~/Music/ClubPod/StripTests/2026-11-14/`.

## How TheStrip works

One mixed file goes through four steps. The same Python engine does this for the standalone PodStripper app and for TheStrip inside Pod Lounge.

1. **Make a working copy.** The file is decoded to a 16-bit WAV at the file's own sample rate and channel count. This episode is 44.1 kHz stereo. No sample-rate change yet.

2. **Pull music off the voices.** A model called HTDemucs (`htdemucs`, Demucs 4.1) splits the mix into vocals, drums, bass, and other. The app keeps "vocals" as the voice stem and adds the other three back together as music and effects. On a Mac it runs on the CPU. The model always works at 44.1 kHz, in chunks of 7.8 seconds, with a 25% overlap. It also applies one random time shift (`shifts = 1`). That single shift does not average several passes, so it does not buy the quality the "shift trick" is known for. The stems are saved as 16-bit audio.

3. **Find who spoke when.** A second model, pyannote `speaker-diarization-community-1`, listens to a 16 kHz mono copy of the **full mix** (not the vocal stem). The app's speaker picker defaults to 2 people. The engine then tidies the turns: drop a leftover "speaker" who barely talked, glue turns of the same person that are within 0.05 seconds, and hand very short turns (under 0.35 seconds) to the neighbor. A later "same voice" check exists, but on this Mac it skipped itself (the installed library refused one call). The job still finished, which is what the app does today.

4. **Cut the tracks.** Each speaker gets a copy of the **vocal stem**, multiplied by a gate that is 1 while that person is in a turn and 0 otherwise. The gate opens about 0.1 seconds early and late, and the edge is only a few dozen milliseconds. Where two people talk at once, the main voice stays loud and the other is ducked to about 16% so the tracks are not a full double copy. Speaker tracks are then mixed down to mono (left and right averaged). The music track stays stereo. Sample-rate or bit-depth conversion happens only when the file is written. The app's default is the original rate, 16-bit WAV.

There is no separate denoiser.

## Where the gate comes from

The mute is step 4. The code multiplies the voice by a 0-to-1 mask and writes silence wherever the mask is 0. A pause longer than about a fifth of a second (the 0.1 second hold on each side) becomes a hole.

On this episode the hole is not Demucs removing the room. In a real 2-second pause around 9:08:

| Signal in that pause | Level |
|---|---|
| Original recording | −55 dB (normal room) |
| Vocal stem, before the gate | −55 dB (the room is still there) |
| Music stem in that same pause | −78 dB (much quieter) |
| Today's speaker track | digital silence |

So the room is thrown away. It does not move onto the music track either, because the music track is built from the music stem, and the room stayed in the vocal stem. Solo the speaker track or play the whole split: that pause is a hole.

A second, smaller mute exists for real music beds (it ducks the speaker tracks when the music stem is clearly louder than the voice for 1.5 seconds or more). On these three excerpts that mute never fired. Turning it off changed nothing.

## Where the swirl comes from

Swirl is the usual side effect of a spectral separator: HTDemucs builds the vocal stem with time-frequency masks, and a bad mask sounds watery or phasey.

On **this** episode the voices are dry and centered (the file is essentially dual-mono). During speech, the vocal stem matches the original level within 0.1 dB, and a "musical noise" measure matches the original to three decimal places. Demucs is mostly letting the speech through. The reconstruction of vocal stem plus music stem versus the original is about 41 dB on the talking excerpts (a small error) and about 31 dB on the music opening.

The opening music is the place a residue shows up. From 0:20 to 0:37 the original is about −21 dB and the vocal stem is about −42 dB, with a small rise in the speckle measure (0.181 on the original, 0.209 on the vocal stem). That is a quiet leftover of the music, not a mangled voice.

Changing the separator did not help:

| Setting | Time per minute of audio | Difference from today's vocal stem | Speckle on the music |
|---|---|---|---|
| Today (`shifts` 1, overlap 0.25, 7.8 s chunks) | 16 s | — | 0.209 |
| Two shifts (the averaging trick) | 33 s | 35 to 47 dB down (tiny) | 0.210 |
| Overlap 0.50 | 24 s | 29 to 45 dB down | 0.216 |
| Shorter 5 s chunks | slower than 7.8 s chunks | audibly different, and not cleaner | 0.215 |
| 10 s chunks | fails | the model rejects anything longer than 7.8 s | — |
| Smooth the mask and reuse the original phase | same as today | speckle unchanged or slightly worse | — |
| Mix 8–25% of the original back into the voice | same as today | no change on these voices | — |

The 16-bit save of the stems is about 67 dB cleaner than the float result. A 48 kHz file run down to 44.1 kHz and back (what would happen on a 48 kHz show, because the model is locked at 44.1) measured 62 dB. This episode is already 44.1 kHz, so TheStrip does not resample it for Demucs at all. Neither the bit depth nor a resample is the swirl.

A heavier model (`htdemucs_ft`, four models) was not run. It would be several times slower and is a separate download. It is the main untried option if a later episode still sounds watery after the gate is fixed.

## Parameters that change the sound

| What | Value today | What it does to the sound |
|---|---|---|
| Speaker count | App defaults to 2. Auto is 1–8 and is slower. | Wrong count splits one person or glues two people together. |
| Clustering threshold | Engine sets 0.50. The model file ships 0.60. Fa 0.07, Fb 0.8, unchanged. | Who gets grouped as the same person. Does not set the silence. |
| Minimum gap inside the detector | 0.0 seconds | The detector is allowed to open and close on very small gaps. |
| Short-turn handoff | under 0.35 s | A brief interjection can move to the other person. |
| Glue same-speaker turns | gap under 0.05 s | Only the tiniest gaps stay open. A 1 second pause still closes. |
| Gate hold | 100 ms before and after each turn | Pauses longer than about 0.2 s still fall to silence. |
| Gate fade | about 15 ms, plus a 12 ms blur, on 20 ms steps | The return of the voice is a snap, not a crossfade. |
| Overlap ducking | other voice about 16%, main voice at least 68% | Stops a full copy of both people during crosstalk. |
| Music-bed mute | music stem strong, and at least 2.2× the vocal, for 1.5 s | Can mute speakers under a real bed. Did not trigger here. |
| Demucs model / rate / chunk | htdemucs, 44.1 kHz, 7.8 s, overlap 0.25, shifts 1, CPU | Sets swirl and how long a split takes. |
| Speaker export | mono average of the channels | One-channel speaker strips. Left as it is. |
| Music export | original stereo layout | Left as it is. |
| Working format | 16-bit WAV, file's own rate | Conversion to 48 kHz or 24-bit happens only at the end, if chosen. |

Cranking the built-in fade number to 400 ms is the wrong knob. That blur made the measured hole **deeper** on the pause excerpt (room match went from −57 dB to −111 dB) while the words stayed the same loudness. A real fade has to be drawn on the edges only, without smearing the middle of a turn.

## What we ran

Source, read-only: `The Macro Dirt Podcast - Veterans Day Macro Dirt.mp3`. 28:12, 44.1 kHz, stereo, but the two channels are the same signal (dual-mono). A second file, `LevelUpOct26mixed.aiff` (41 minutes, 48 kHz), was checked for a music bed. Its stereo width stays narrow and it has no long bass-heavy music section, so the tests stayed on the Veterans Day episode.

Three 90-second excerpts, speaker count fixed at 2:

| Clip | Where in the episode | Why this piece |
|---|---|---|
| A-pauses | centered on a 2.1 s pause at about 9:08 | Speech, then a real pause, then speech. |
| B-crosstalk | about 3:35–5:05 | Fast back-and-forth. Overlap is only a couple of seconds; they mostly take turns. This is the most overlap the detector found. |
| C-music | 0:00–1:30 | The only real music: a bass-heavy open from about 0:20–0:37, then a gap that is **already silent in the file** around 0:38, then the hosts. |

Speaker detection on a 90-second clip took 4–6 seconds (about 4 seconds per minute). Separation took 16 seconds per minute. A full 28-minute episode at today's settings is on the order of 8 minutes of separation plus about 2 minutes of speaker detection on this Mac. The room-tone change itself is a fraction of a second per minute.

### The numbers

"Drop" is how many dB the active speaker's track falls from the words just before a pause to the middle of the pause. The original recording's own drop is the target. "Room match" is the pause on the track compared with the pause in the original (0 dB means the room is back at the real level). "Leak" is the other person's voice on this track while they are the one talking; more negative is cleaner. "Abrupt" counts 20 ms steps that fall more than 15 dB. Voice loudness during the words stayed at about −29 dB on A for every fix below, so the words were not turned down.

| Version | A drop (target 31 dB) | A room match | A leak | A abrupt | B drop (target 38) | B leak | C drop (target 6) | C leak |
|---|---|---|---|---|---|---|---|---|
| Today | 88 dB | −57 dB | −32 dB | 22 | 93 dB | −30 dB | 94 dB | −43 dB |
| Fade knob at 400 ms | 142 dB | −111 dB | −33 dB | 14 | 76 dB | −36 dB | 94 dB | −35 dB |
| Room at −40 dB | 71 | −40 | −32 | 39 | 78 | −30 | 46 | −43 |
| Room at −30 dB | 61 | −30 | −32 | 36 | 68 | −30 | 36 | −43 |
| Room at −20 dB | 51 | −20 | −32 | 31 | 58 | −30 | 26 | −43 |
| Room at the real level | 31 | 0 | −26 dB | 25 | 38 | −26 dB | 6 | −33 dB |
| Hold the gate open for gaps under 2 s | 33 | −2 dB | −31 dB | 13 | 41 | −27 dB | 55 | **−12 dB** |
| Smoother mask, or mix the original back in | same as today | same | same | same | same | same | same | same |

The files in the listening pack match this. On clip A, Speaker 1's words are −32 dB in all three versions. In the pause, today's file is digital silence, natural-room is −63 dB (a 31 dB drop, the real one), and hold-open is −65 dB.

### What the meters cannot say

- The drop and room-match numbers describe level, not whether a crossfade feels smooth. The abrupt counter went **up** for the natural-room version even though the hole is gone. Plosives and the handoff from voice to room both trip a 15 dB step. Listen to the files.
- Leak uses the detector's turns as truth. If the detector is early or late, some "leak" is just the boundary.
- The swirl meters (spectral flux and speckle) did not move, and on the speech they match the original. They would not catch a mild watery tone that is already in the recording. They also did not reward any separator tweak, which agrees with the stems being almost identical.
- Crosstalk on this show is short. A show where two people talk over each other for long stretches was not in these files.
- The "same voice" tidy-up pass did not run.

## What to adopt

Use **natural room tone in true pauses** as the new default. When the detector says nobody is talking, crossfade each speaker track to the original audio over about 150–180 ms, at the original level, and crossfade back when someone starts. On these clips that makes the pause drop match the recording (31 dB, 38 dB, and 6 dB) and leaves the words at the same loudness. The other person gets a few decibels more audible at the edges (about −32 dB down becomes about −26 dB on the pause clip). That is still quiet.

Do not ship −20 / −30 / −40 dB as the fix. Those still leave a 50–70 dB hole on the pause clip. They are useful only as lower settings on a slider.

Do not rely on "hold open for 2 seconds" alone. On plain talking it is excellent: the room is already in the vocal stem, leak barely changes, and the abrupt count falls (22 down to 13). On the music opening, leakage jumped to about −12 dB, which is easy to hear, and the room still did not fully come back. A short hold (under a second, to keep breaths) can sit **with** the room-tone fill. A 2 second hold should not be the whole fix.

Give it a slider, defaulted to full / natural, not buried. Something labeled **Room tone**, from Off (today's mute) to Natural. The middle of the slider can be the −20 dB bed if a later mix needs less room, but the default should be Natural, because Off is the complaint. One slider is enough. It does not need to be a separate "smoothness" control unless you also want the short breath-hold as its own step.

Do not change the Demucs defaults for swirl. Two shifts double the wait (16 s per minute becomes 33 s) and the vocal stem only differs by 35–47 dB. Overlap, chunk length, mask smoothing, and mixing the dry signal back in did not reduce the speckle. Speaker tracks stay mono. The music track stays stereo.

If a later episode still sounds watery after the room tone is in, the next experiment is a different separator (the fine-tuned Demucs bag), not these knobs. That was not run here.

## What to change later, in both apps

Do this in the Python engine only, in the step that builds the speaker gates (`cleanup.py` / the export that applies them). Standalone PodStripper and TheStrip in the Lounge call that same engine.

- Add the room-tone crossfade described above. Keep today's gate for the words.
- Pass the amount in from the app as one new option (for example how many dB under the original, where 0 dB means natural and "off" means today's mute).
- Draw fades on the edges of the gate. Leave the existing `fade_ms` blur alone; turning it up made the hole worse.
- Optional and secondary: glue same-speaker gaps out to about 0.5–1.0 seconds so breaths stay. Do not glue 2 second gaps by default.
- When both speaker tracks carry the full room, playing every track together makes the room louder than the original, because the pause is no longer only on one stem. The music track should give up that same pause (it is nearly empty there today anyway), or each speaker should carry `1 / number of speakers` of the room **if** the tracks are always summed. For someone soloing a track in the Lounge or a DAW, full room on each track is what sounds natural. The slider's "natural" should be the solo sound, and the music track should not also keep a copy of that pause.

Both apps already share this. Pod Lounge's TheStrip screen is the shared PodStripper screen. The engine source is copied into each app when that app is built. The installed Python environment is the one folder `~/Library/Application Support/CougarCalc/Podcast Stripper/`. On launch, the app hashes the bundled engine source. A new build with the edited engine gets a new hash, and the next open reinstalls that package into the shared folder. Shipping the fix means rebuilding **both** PodStripper and Pod Lounge so each bundle contains the new engine. Editing the repo, or editing only one app, leaves the other app on the old mute. No Application Support folder was modified in this job, and the apps in `dist` were not rebuilt.

A Room tone slider belongs on the shared strip screen, next to the speaker count. That one control shows up in both apps.

## Unverified

- No one has listened yet. The pack is there for that. Levels in the files match the table.
- `htdemucs_ft` and any separator other than HTDemucs.
- A show where music really sits under the voices the whole time. This episode's music is the open, then dry talking.
- The skipped "same voice" pass. It fails closed and does not change today's mute.
- Whether a 150 ms crossfade feels smoother than the abrupt-step counter suggests. The files are the check.
