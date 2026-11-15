The pauses keep the real room now, instead of dropping to a hole.
The music opening, including the voice clips in it, stays on Music/SFX.
The hosts after that opening still get their own tracks.
Room tone is on the shared TheStrip screen, full by default, and can go down to off.
Pull request: https://github.com/jojopdmf-a11y/Podcast-Suite/pull/78

## What changed

Both apps use one screen and one Python engine. The change is in that engine, and the screen gained two controls.

Room tone. When nobody is talking, each speaker track fades to the separated voice stem's own room, at that room's real level, over about 165 ms, and fades back when someone starts. The words stay at the same level. Off is today's hard mute. The slider's middle is about −20 dB under the real room. Natural is the default. The fade is drawn on the edges only. The old blur on the words was left alone, because turning that up made the hole worse.

The room is on every speaker track so a solo sounds like the room you recorded. The music track does not also keep a copy of that pause. If you play every speaker track at once during a pause, the room is louder than the original, once for each speaker. That is the solo sound J.j. picked. An intro does not do this: see below.

Intro. Anything before the first stretch of dry talking (about 8 seconds where the voices are up and the music stem has fallen away) stays on Music/SFX as the original mix, and the speaker tracks are quiet there. A later hit where the music stem is really present, including a short voice on top of it, also stays on Music/SFX, unless two people are both talking through it. Then it is treated as conversation with a bed and the voices stay on the speakers.

Intro ends is an optional time, empty by default. `1:05` or `65` forces the opening to end there and replaces the automatic opening. It does not turn off the later "voice over a music hit" rule.

Speaker tracks are still mono. Music/SFX is still stereo. The bundled speaker model, the Settings token field, naming, auto-add to the depot, CHOOSE…, and the depot on the right are unchanged.

The shared engine copy in Application Support was reinstalled from the new PodStripper bundle, the same way the app does it on launch when the engine source changes.

## How the intro rule works, and where it fails

On the Veterans Day episode the first 20 seconds are voice clips with music under them. Demucs leaves both stems loud there, so the old "music must be 2.2× the vocal" test never called it a bed, and the speaker model labeled that whole stretch as one person. The bass music after that (about 0:20–0:37) is obvious. Dry talking starts at 0:45.12. The rule puts everything before 0:45 on Music/SFX. The host who starts at 0:45 stays on a speaker track. Requiring two people before ending the intro would have sent that host's first minute to Music, so the cut is "first sustained dry speech," not "first time both people have spoken."

Where it fails:

- One person talking while the music stem is genuinely loud is moved to Music/SFX. That is the voice-over rule. A solo host over a loud bed can be caught by it. Two people over that same bed are left on the speakers.
- If a show never has about 8 seconds of dry speech, there is no automatic opening. Use Intro ends. Two people over a loud bed are still protected.
- A music hit shorter than about 1.2 seconds can stay split.
- On LevelUp's first 90 seconds, the first 2 seconds have a music stem as loud as the voice, so those 2 seconds go to Music/SFX. A 16-second swell under both people stayed on the speakers. A later conversation window (about 10:00–11:10) sent nothing to Music.
- Clip C in the listening pack is only long enough for one host. The second host starts just after 1:00, so that 48-second file has one speaker track. On the longer opening, the cut is still 0:45.

Nothing in an intro is thrown away. Speakers are quiet and Music/SFX is the original mix, so those parts add back to the show.

## Metrics before and after

Same engine, same speaker turns. "Current" is room tone off and no intro routing. "New" is the default. Levels below are dB of the sample values (digital silence is −120). The Veterans Day listening files are 48 kHz.

Clip A, pause at about 0:23 of the file (episode ~9:08), the person who had just been talking:

| | Words | Pause | Drop |
|---|---|---|---|
| Current | 56.5 | silence | 176 dB |
| New | 56.5 | 24.6 | 31.9 dB |

The words did not change. The old report's target drop for this pause was 31 dB. Both speaker tracks carry that room in the pause (about 25 dB). The other person's words stay off this track.

Clip B has no pause longer than 0.8 seconds. In a 0.6-second gap, current is silence and new is about 27 dB of room on both speakers. The words just before it stay at 54.5 dB in both versions.

Clip C, episode 0:20–0:37 (the bass music), inside the 0:12–1:00 file:

| | Speaker | Music/SFX |
|---|---|---|
| Current | 26.4 | 68.8 |
| New | silence | 68.9 |

The whole opening of that file, up to the host (0:12–0:45 of the episode):

| | Speaker | Music/SFX |
|---|---|---|
| Current | 57.8 | 65.9 |
| New | 15.4 | 66.9 |

The host after the cut stays at about 63 dB on the speaker in both versions. Music/SFX under that dry talk is quiet, same as today. The automatic cut landed at 0:45.12.

LevelUp, read-only: no long bass-music section. Conversation around 10:00 was not sent to Music. The opening's first 2 seconds were.

Engine tests: 64 passed, including the new room-tone fade tests and the intro tests (voice-over moves and still sums, a quiet bed stays on the speakers, a loud bed under two people is not stolen, Off is silence, a typed intro time overrides the automatic cut). The Room tone and Intro ends parsers passed their Swift tests. Tests delete the files they create.

## PR and the rebuilt apps

https://github.com/jojopdmf-a11y/Podcast-Suite/pull/78

Not merged.

- Standalone: `Podcast Stripper/dist/PodStripper.app`
- Lounge: `PodLounge/dist/PodLounge.app`

Listening pack: `~/Music/ClubPod/StripTests/2026-11-14-v2/` (about 97 MB). Nothing was written to the Desktop.

## Click-test

1. Open Pod Lounge, open a project, select the Veterans Day episode in the depot, and go to TheStrip.
2. Leave Room tone on Natural and Intro ends empty. Split.
3. Play a speaker track across a pause. You should hear the room, not a hole. The words should be as loud as before.
4. Play Music/SFX from the start. The voice clips and the music should be there. The speaker track should stay quiet until the host comes in after the silent gap.
5. Drag Room tone to Off and split again. The same pause should be silent.
6. Open standalone PodStripper and confirm the same Room tone slider and Intro ends field are on that screen. Speakers, sample rate, format, CHOOSE…, and the depot are still there.
