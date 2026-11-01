from __future__ import annotations

import numpy as np
import pytest

from podcast_stripper.consistency import (
    refine_speaker_consistency,
    reassign_mismatched_turns,
    split_conversational_handoffs,
)


def test_outlier_turn_is_reassigned_to_matching_speaker():
    # Two clear speakers; middle turn labeled A but sounds like B.
    segments = [
        (0.0, 2.0, "A"),
        (2.0, 4.0, "A"),  # wrong — embedding is B
        (4.0, 6.0, "A"),
        (6.0, 8.0, "B"),
        (8.0, 10.0, "B"),
    ]
    emb_a = np.array([1.0, 0.0, 0.0])
    emb_b = np.array([0.0, 1.0, 0.0])
    embeddings = [emb_a, emb_b, emb_a, emb_b, emb_b]

    refined, moved = reassign_mismatched_turns(segments, embeddings)
    assert moved == 1
    assert refined[1][2] == "B"
    assert refined[0][2] == "A"
    assert refined[3][2] == "B"


def test_near_tie_is_not_reassigned():
    segments = [
        (0.0, 2.0, "A"),
        (2.0, 4.0, "A"),
        (4.0, 6.0, "B"),
        (6.0, 8.0, "B"),
    ]
    emb_a = np.array([1.0, 0.0])
    # Slightly closer to A still, but almost midway — keep label.
    emb_mid = np.array([0.55, 0.45])
    emb_b = np.array([0.0, 1.0])
    embeddings = [emb_a, emb_mid, emb_b, emb_b]

    refined, moved = reassign_mismatched_turns(segments, embeddings, margin=0.08)
    assert moved == 0
    assert refined[1][2] == "A"


def test_short_turns_untouched_via_none_embedding():
    segments = [
        (0.0, 2.0, "A"),
        (2.0, 2.4, "A"),  # short — no embedding
        (2.4, 4.0, "B"),
        (4.0, 6.0, "B"),
    ]
    emb_a = np.array([1.0, 0.0])
    emb_b = np.array([0.0, 1.0])
    embeddings = [emb_a, None, emb_b, emb_b]

    refined, moved = reassign_mismatched_turns(segments, embeddings)
    assert refined[1][2] == "A"
    assert moved == 0


def test_refine_with_fake_embed_fn_moves_outlier():
    segments = [
        (0.0, 2.0, "A"),
        (2.0, 4.0, "A"),
        (4.0, 6.0, "A"),
        (6.0, 8.0, "B"),
        (8.0, 10.0, "B"),
    ]
    emb_a = np.array([1.0, 0.0, 0.0])
    emb_b = np.array([0.0, 1.0, 0.0])

    def embed_fn(start: float, end: float) -> np.ndarray:
        mid = 0.5 * (start + end)
        if 2.0 <= mid < 4.0 or mid >= 6.0:
            return emb_b
        return emb_a

    refined, stats = refine_speaker_consistency(
        segments,
        embed_fn=embed_fn,
        max_iterations=1,
    )
    assert stats["moved"] == 1
    assert refined[1][2] == "B"


def test_handoff_moves_next_speaker_onset_off_previous_track():
    # Host 0–5s, but the last ~1s is already the guest. Guest continues 5–9.
    segments = [
        (0.0, 5.0, "A"),
        (5.0, 9.0, "B"),
        (9.0, 13.0, "A"),
    ]
    emb_a = np.array([1.0, 0.0])
    emb_b = np.array([0.0, 1.0])

    def embed_fn(start: float, end: float) -> np.ndarray:
        mid = 0.5 * (start + end)
        if 3.9 <= mid < 9.0:
            return emb_b
        return emb_a

    refined, moved = split_conversational_handoffs(segments, embed_fn)
    assert moved == 1
    assert refined[0][2] == "A"
    assert refined[0][1] == pytest.approx(3.9, abs=0.05)
    assert refined[1][2] == "B"
    assert refined[1][0] == pytest.approx(3.9, abs=0.05)


def test_clean_handoff_is_not_split():
    segments = [
        (0.0, 5.0, "A"),
        (5.0, 9.0, "B"),
    ]
    emb_a = np.array([1.0, 0.0])
    emb_b = np.array([0.0, 1.0])

    def embed_fn(start: float, end: float) -> np.ndarray:
        mid = 0.5 * (start + end)
        return emb_a if mid < 5.0 else emb_b

    refined, moved = split_conversational_handoffs(segments, embed_fn)
    assert moved == 0
    assert refined[0] == (0.0, 5.0, "A")
    assert refined[1] == (5.0, 9.0, "B")
