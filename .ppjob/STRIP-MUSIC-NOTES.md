Nine stretches of host speech were sitting on Music/SFX. They are on the speaker tracks now.
The opening, including the voice clips on the music, still stays on Music/SFX until 0:45.
The music at the end of the episode still stays on Music/SFX. No host is in it.
Room tone, Intro ends, and mono speakers with stereo music were left as they are.
Pull request: https://github.com/jojopdmf-a11y/Podcast-Suite/pull/78

## What was on Music/SFX

Scanned the Music & SFX WAV from the Natural split against Tony, Jared, and the original episode. A stretch counts when the music track is carrying the words and both host tracks are quiet.

The opening and the ending music are supposed to be there. The nine in the table are not. That is the "about ten times" from the listen.

| When | Length | Who | Music under it? | Cause |
|---|---|---|---|---|
| 0:00–0:45 | opening | Jared's voice clips, then bass music, then a gap | Yes, through about 0:37 | The intro rule. Leave this. |
| 4:09.6–4:11.0 | 1.4 s | Jared | No. Same mono speech as the lines around it | Voice-over rule, bridged spike |
| 6:59.3–7:00.4 | 1.1 s | Jared | No | Voice-over rule, bridged spike |
| 7:31.1–7:33.5 and 7:35.4–7:37.1 | 2.4 s and 1.7 s | Jared | No. One quiet gap between them | Voice-over rule. Two spikes 2 seconds apart were joined into one 5.7 s mute |
| 7:53.1–7:54.5 | 1.3 s | nobody | No. The moment is almost silent | Same rule, on pause noise. Not one of the voices. Room on the hosts was muted here |
| 16:23.8–16:24.7 | 0.9 s | Jared | No. A short line of his | Voice-over rule, bridged spike |
| 25:05.5–25:06.2 | 0.7 s | Tony | No. A short loud line | Voice-over rule, bridged spike |
| 27:19.3–27:20.2 and 27:21.9–27:23.5 | 0.9 s and 1.6 s | Jared, with a little Tony at the edge of the second | No | Voice-over rule. Joined into one 5.1 s mute |
| 27:43.4–27:45.0 | 1.7 s | Jared | No. Same speech as the lines around it | Voice-over rule, bridged spike |
| 28:05–28:12 | ending | nobody | Yes. Stereo music, no host | Real music. Leave this |

Checked in the separator, not guessed. On a fresh music separation of this episode, the music stem inside those nine stretches is about 1% of the vocal stem. Only a few frames actually passed the "this is music" test. The rest of each stretch was filled in by a 2.5 second bridge. The conversation guard did not save them, because only one person was talking. The original mix, words included, was copied onto Music/SFX and that host was muted.

It is not the intro cut. That still lands at 0:45.12. It is not the stricter music-bed test (music has to be more than twice the voice). It is not the speaker model dropping the line: the turns are there. It is not leftover separation bleed: the vocal stem still holds the words, and the music stem does not match the voice.

Why the test misfired: on a talk show the 95th percentile of the music stem is leftover voice, not a song. Ten percent of that is almost silence, so a spike or a quiet pause passed. The bridge then painted the sentence between two spikes as music.

## What changed

In the shared engine, the "voice over music" test now uses the 99th percentile, so the bar is a real music event. The music stem also has to clear a fraction of the loud vocal level, so pause noise cannot pass while both stems are near silence. The bridge that fills gaps inside a bed is 0.45 seconds instead of 2.5, so two spikes cannot swallow the sentence between them.

A real hit still stays on Music/SFX: one voice over music that is actually loud, the opening, and the ending music. Two people over a loud bed still stay on the speakers. A quiet bed still stays off Music/SFX.

Tests: 67 passed, including three new ones (spikes must not steal the sentence, a later voice over a real hit stays on Music/SFX and still sums, a quiet pause is not sent to Music). The tests delete their own files.

## Before and after

Same speaker turns as the Natural split. The music separator was run again, then the fixed engine wrote the tracks.

Speech stretches on Music/SFX, not counting the opening or the ending music: 9 before, 0 after.

The opening is still on Music/SFX through 0:45, and both hosts are quiet there. The host who starts after that is on his own track. The ending music from 28:05 is still on Music/SFX, with no host under it.

At each of the nine spots the words are now on that host, at the same level they used to be on Music/SFX, and Music/SFX is quiet there.

## Still not perfect

A music hit shorter than about 1.2 seconds can still be split, same as before. A solo host over a bed that is genuinely loud still goes to Music/SFX. That is the voice-over-music case, and the opening of this episode is that case. Two people over that kind of bed stay on the speakers.

The music separator still shifts the audio by a random fraction of a second each run. That is existing behavior. It does not put the words back on Music/SFX.

## Click-test

1. Open Pod Lounge and the new build. Open the Veterans Day episode on TheStrip. Leave Room tone on Natural and Intro ends empty. Split.
2. Play Music/SFX from the start. The voice clips and the bass music should still be there. The host track should stay quiet until he comes in after the gap, just past 0:45.
3. On Jared, listen around 4:10, 6:59, 7:31, and 27:43. Those words should be on Jared. Music/SFX should be quiet there.
4. On Tony, listen around 25:05. That short line should be on Tony, not on Music/SFX.
5. Play the music at the very end (about 28:05). It should still be on Music/SFX.
6. Play a normal pause on a host track. The room should still be there. Drag Room tone to Off, split again, and that pause should be silent.

Listening pack: ~/Music/ClubPod/StripTests/2026-11-14-v3/ (about 62 MB). Nothing was written to the Desktop.

The shared engine in Application Support was reinstalled from this fix. Both apps were rebuilt:

- `Podcast Stripper/dist/PodStripper.app`
- `PodLounge/dist/PodLounge.app`

Not merged.
