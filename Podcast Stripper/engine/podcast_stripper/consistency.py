"""Post-diarization check: same voice on each speaker track.

Embeds long-enough turns, builds per-speaker centroids, and reassigns clear
outliers to the better-matching speaker. Conservative on purpose — near ties
stay put.
"""

from __future__ import annotations

import sys
from collections import defaultdict
from typing import Callable

import numpy as np

Segment = tuple[float, float, str]
EmbedFn = Callable[[float, float], np.ndarray]
ProgressFn = Callable[[str, float, str], None]

MIN_TURN_SECONDS = 0.8
SIM_MARGIN = 0.08
MIN_BEST_SIM = 0.25
MAX_ITERATIONS = 2


def cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
    a = np.asarray(a, dtype=np.float64).reshape(-1)
    b = np.asarray(b, dtype=np.float64).reshape(-1)
    denom = float(np.linalg.norm(a) * np.linalg.norm(b)) or 1.0
    return float(np.dot(a, b) / denom)


def duration_weighted_centroids(
    labels: list[str],
    durations: list[float],
    embeddings: list[np.ndarray],
) -> dict[str, np.ndarray]:
    sums: dict[str, np.ndarray] = {}
    weights: dict[str, float] = defaultdict(float)
    for label, duration, emb in zip(labels, durations, embeddings):
        if emb is None:
            continue
        vec = np.asarray(emb, dtype=np.float64).reshape(-1)
        if label not in sums:
            sums[label] = np.zeros_like(vec)
        sums[label] = sums[label] + vec * duration
        weights[label] += duration
    centroids: dict[str, np.ndarray] = {}
    for label, total in sums.items():
        w = weights[label] or 1.0
        centroids[label] = total / w
    return centroids


def reassign_mismatched_turns(
    segments: list[Segment],
    embeddings: list[np.ndarray | None],
    *,
    margin: float = SIM_MARGIN,
    min_best_sim: float = MIN_BEST_SIM,
) -> tuple[list[Segment], int]:
    """Reassign turns whose embedding clearly matches another speaker better.

    ``embeddings[i]`` aligns with ``segments[i]`` (None = skip that turn).
    Own-speaker similarity uses a leave-one-out centroid so outliers are not
    compared against a centroid they themselves polluted.
    """
    if len(segments) != len(embeddings) or len(segments) < 2:
        return list(segments), 0

    speakers = {speaker for _, _, speaker in segments}
    if len(speakers) < 2:
        return list(segments), 0

    usable = [
        (index, start, end, speaker, emb)
        for index, ((start, end, speaker), emb) in enumerate(zip(segments, embeddings))
        if emb is not None
    ]
    if len(usable) < 2:
        return list(segments), 0

    # Group usable turns by speaker for leave-one-out centroids.
    by_speaker: dict[str, list[tuple[int, float, np.ndarray]]] = defaultdict(list)
    for index, start, end, speaker, emb in usable:
        by_speaker[speaker].append((index, end - start, emb))

    full_centroids = duration_weighted_centroids(
        [item[3] for item in usable],
        [item[2] - item[1] for item in usable],
        [item[4] for item in usable],
    )
    if len(full_centroids) < 2:
        return list(segments), 0

    def leave_one_out_centroid(speaker: str, skip_index: int) -> np.ndarray | None:
        others = [
            (duration, emb)
            for index, duration, emb in by_speaker[speaker]
            if index != skip_index
        ]
        if not others:
            return full_centroids.get(speaker)
        labels = [speaker] * len(others)
        durations = [item[0] for item in others]
        embs = [item[1] for item in others]
        return duration_weighted_centroids(labels, durations, embs).get(speaker)

    own_sim_by_index: dict[int, float] = {}
    own_sims_by_speaker: dict[str, list[float]] = defaultdict(list)
    for index, _start, _end, speaker, emb in usable:
        own_centroid = leave_one_out_centroid(speaker, index)
        if own_centroid is None:
            continue
        sim = cosine_similarity(emb, own_centroid)
        own_sim_by_index[index] = sim
        own_sims_by_speaker[speaker].append(sim)

    medians = {
        speaker: float(np.median(values)) if values else 0.0
        for speaker, values in own_sims_by_speaker.items()
    }

    result = list(segments)
    moved = 0
    for index, _start, _end, speaker, emb in usable:
        own_sim = own_sim_by_index.get(index)
        if own_sim is None:
            continue
        # Only touch turns weaker than typical for this speaker (or sole turn).
        speaker_sims = own_sims_by_speaker.get(speaker) or []
        if len(speaker_sims) > 1 and own_sim >= medians.get(speaker, own_sim):
            continue

        best_speaker = speaker
        best_sim = own_sim
        for other, centroid in full_centroids.items():
            if other == speaker:
                continue
            sim = cosine_similarity(emb, centroid)
            if sim > best_sim:
                best_sim = sim
                best_speaker = other

        if (
            best_speaker != speaker
            and best_sim >= min_best_sim
            and (best_sim - own_sim) >= margin
        ):
            start, end, _ = result[index]
            result[index] = (start, end, best_speaker)
            moved += 1

    return result, moved


def make_pipeline_embed_fn(pipeline, audio_file) -> EmbedFn:
    """Build an embed_fn(start, end) using the diarization pipeline's embedding model."""
    from pyannote.audio import Inference
    from pyannote.core import Segment as TimeSegment

    model = getattr(pipeline, "_embedding", None)
    if model is None:
        model = getattr(pipeline, "embedding", None)
    if model is None:
        raise RuntimeError("Diarization pipeline has no embedding model.")

    if hasattr(model, "crop"):
        inference = model
    else:
        inference = Inference(model, window="whole")

    def embed_fn(start: float, end: float) -> np.ndarray:
        output = inference.crop(audio_file, TimeSegment(float(start), float(end)))
        if isinstance(output, tuple):
            output = output[0]
        if hasattr(output, "data"):
            output = output.data
        vec = np.asarray(output, dtype=np.float64).reshape(-1)
        if vec.size == 0:
            raise RuntimeError("Empty embedding")
        return vec

    return embed_fn


def embed_segments(
    segments: list[Segment],
    embed_fn: EmbedFn,
    *,
    min_duration: float = MIN_TURN_SECONDS,
) -> list[np.ndarray | None]:
    embeddings: list[np.ndarray | None] = []
    for start, end, _speaker in segments:
        if (end - start) < min_duration:
            embeddings.append(None)
            continue
        try:
            embeddings.append(embed_fn(start, end))
        except Exception:
            embeddings.append(None)
    return embeddings


def refine_speaker_consistency(
    segments: list[Segment],
    *,
    embed_fn: EmbedFn | None = None,
    pipeline=None,
    audio_file=None,
    min_duration: float = MIN_TURN_SECONDS,
    margin: float = SIM_MARGIN,
    min_best_sim: float = MIN_BEST_SIM,
    max_iterations: int = MAX_ITERATIONS,
    on_progress: ProgressFn | None = None,
) -> tuple[list[Segment], dict]:
    """
    Return (refined_segments, stats).

    On any hard failure, returns the original segments unchanged.
    """
    stats = {"moved": 0, "iterations": 0, "skipped": False, "reason": None}
    if len(segments) < 2:
        stats["skipped"] = True
        stats["reason"] = "too_few_segments"
        return segments, stats

    speakers = {speaker for _, _, speaker in segments}
    if len(speakers) < 2:
        stats["skipped"] = True
        stats["reason"] = "single_speaker"
        return segments, stats

    try:
        if embed_fn is None:
            if pipeline is None or audio_file is None:
                raise RuntimeError("Need embed_fn or pipeline+audio_file")
            embed_fn = make_pipeline_embed_fn(pipeline, audio_file)
    except Exception as exc:
        stats["skipped"] = True
        stats["reason"] = f"embed_setup:{type(exc).__name__}"
        sys.stderr.write(f"voice consistency skipped: {exc}\n")
        return segments, stats

    if on_progress:
        on_progress("diarize", 86, "Checking speaker tracks for mixed voices…")

    current = list(segments)
    total_moved = 0
    try:
        for iteration in range(max_iterations):
            embeddings = embed_segments(current, embed_fn, min_duration=min_duration)
            if sum(emb is not None for emb in embeddings) < 2:
                stats["reason"] = "too_few_embeddings"
                break
            updated, moved = reassign_mismatched_turns(
                current,
                embeddings,
                margin=margin,
                min_best_sim=min_best_sim,
            )
            stats["iterations"] = iteration + 1
            total_moved += moved
            current = updated
            if moved == 0:
                break
    except Exception as exc:
        stats["skipped"] = True
        stats["reason"] = f"embed_failed:{type(exc).__name__}"
        sys.stderr.write(f"voice consistency failed, keeping original turns: {exc}\n")
        return segments, stats

    stats["moved"] = total_moved
    if on_progress:
        if total_moved:
            on_progress(
                "diarize",
                90,
                f"Moved {total_moved} turn{'s' if total_moved != 1 else ''} to the matching speaker.",
            )
        else:
            on_progress("diarize", 90, "Speaker tracks look consistent.")
    return current, stats
