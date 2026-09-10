from __future__ import annotations

from podcast_stripper.diarize import (
    DIARIZE_PROFILE,
    reassign_short_interruptions,
    resolve_speaker_count_kwargs,
)


def test_diarize_profile_is_sweet_spot():
    assert DIARIZE_PROFILE["threshold"] == 0.50
    assert DIARIZE_PROFILE["Fa"] == 0.07
    assert DIARIZE_PROFILE["Fb"] == 0.8
    assert DIARIZE_PROFILE["short_turn_seconds"] == 0.35


def test_speaker_count_is_exact_when_set():
    assert resolve_speaker_count_kwargs(num_speakers=3) == {"num_speakers": 3}
    assert resolve_speaker_count_kwargs(min_speakers=1, max_speakers=8) == {
        "min_speakers": 1,
        "max_speakers": 8,
    }


def test_short_interruption_reassignment():
    segments = [
        (0.0, 2.0, "A"),
        (2.0, 2.3, "B"),
        (2.3, 4.0, "A"),
    ]
    cleaned = reassign_short_interruptions(segments, max_seconds=0.35)
    assert all(speaker == "A" for _, _, speaker in cleaned)
    assert len(cleaned) == 1


def test_short_interruption_keep_when_disabled():
    segments = [
        (0.0, 2.0, "A"),
        (2.0, 2.3, "B"),
        (2.3, 4.0, "A"),
    ]
    assert reassign_short_interruptions(segments, max_seconds=0.0) == segments
