"""Soft gates, music-bed keep-original, and trailing garbage trim.

These cleanup steps run the same way for every export.
"""

from __future__ import annotations

from typing import Iterable

import numpy as np

Segment = tuple[float, float, str]


def _clamp_index(seconds: float, sample_rate: int, total: int) -> int:
    index = int(round(seconds * sample_rate))
    return max(0, min(total, index))


def soft_activity_mask(
    length: int,
    sample_rate: int,
    turns: list[tuple[float, float]],
    *,
    fade_ms: float = 15,
    hold_ms: float = 100,
) -> np.ndarray:
    """1.0 during activity (with hold), soft fade at edges."""
    mask = np.zeros(length, dtype=np.float64)
    fade = max(1, int(sample_rate * fade_ms / 1000.0))
    hold = max(0, int(sample_rate * hold_ms / 1000.0))
    for start, end in turns:
        start_index = max(0, _clamp_index(start, sample_rate, length) - hold)
        end_index = min(length, _clamp_index(end, sample_rate, length) + hold)
        if end_index > start_index:
            mask[start_index:end_index] = 1.0
    if fade > 1 and np.any(mask):
        kernel = np.hanning(fade * 2 + 1)
        kernel = kernel / kernel.sum()
        mask = np.clip(np.convolve(mask, kernel, mode="same"), 0.0, 1.0)
    return mask


def speech_mask_from_segments(
    length: int,
    sample_rate: int,
    segments: Iterable[Segment],
    *,
    fade_ms: float = 20,
    hold_ms: float = 40,
) -> np.ndarray:
    turns = [(start, end) for start, end, _ in segments]
    return soft_activity_mask(length, sample_rate, turns, fade_ms=fade_ms, hold_ms=hold_ms)


def frame_rms(
    audio: np.ndarray,
    sample_rate: int,
    window_ms: float = 80,
    hop_ms: float = 40,
) -> tuple[np.ndarray, int]:
    mono = audio.astype(np.float64)
    if mono.ndim > 1:
        mono = np.mean(mono, axis=1)
    window = max(1, int(sample_rate * window_ms / 1000.0))
    hop = max(1, int(sample_rate * hop_ms / 1000.0))
    if mono.size < window:
        rms = float(np.sqrt(np.mean(mono**2))) if mono.size else 0.0
        return np.array([rms], dtype=np.float64), hop
    values = [
        float(np.sqrt(np.mean(mono[start : start + window] ** 2)))
        for start in range(0, mono.size - window + 1, hop)
    ]
    return np.asarray(values, dtype=np.float64), hop


def upsample_mask(frame_mask: np.ndarray, hop: int, length: int) -> np.ndarray:
    if frame_mask.size == 0:
        return np.zeros(length, dtype=np.float64)
    expanded = np.repeat(frame_mask, hop)
    if expanded.size < length:
        expanded = np.pad(expanded, (0, length - expanded.size))
    return expanded[:length]


def _drop_short_runs(mask: np.ndarray, min_len: int) -> np.ndarray:
    out = mask.copy()
    n = out.size
    i = 0
    while i < n:
        if out[i] < 0.5:
            i += 1
            continue
        j = i
        while j < n and out[j] >= 0.5:
            j += 1
        if (j - i) < min_len:
            out[i:j] = 0.0
        i = j
    return out


def music_activity_mask(
    accompaniment: np.ndarray,
    sample_rate: int,
    *,
    vocals: np.ndarray | None = None,
    relative_floor: float = 0.28,
    other_over_vocal: float = 2.2,
    min_seconds: float = 1.5,
) -> np.ndarray:
    """Where Demucs 'other' is a real music/SFX bed — not speech bleed.

    Demucs leaves residual energy in 'other' during talk, so a low energy floor
    alone marks most of a podcast as music. Prefer regions where other is strong
    *and* clearly louder than the vocal stem, for a sustained stretch.
    """
    rms, hop = frame_rms(accompaniment, sample_rate)
    if rms.size == 0:
        return np.zeros(accompaniment.shape[0], dtype=np.float64)
    peak = float(np.percentile(rms, 95)) or 1.0
    strong = rms >= peak * relative_floor

    if vocals is not None:
        vocal_rms, _ = frame_rms(vocals, sample_rate)
        n = min(rms.size, vocal_rms.size)
        rms = rms[:n]
        vocal_rms = vocal_rms[:n]
        strong = strong[:n]
        ratio = rms / (vocal_rms + peak * 0.02)
        active = (strong & (ratio >= other_over_vocal)).astype(np.float64)
    else:
        # Without vocals, stay conservative: higher floor + longer runs only.
        active = (rms >= peak * max(relative_floor, 0.4)).astype(np.float64)

    min_frames = max(1, int(min_seconds * sample_rate / hop))
    active = _drop_short_runs(active, min_frames)
    return upsample_mask(active, hop, accompaniment.shape[0])


def strip_trailing_garbage(
    audio: np.ndarray,
    sample_rate: int,
    keep_mask: np.ndarray,
    *,
    pad_ms: float = 600,
) -> tuple[np.ndarray, float | None]:
    """Zero everything after the last useful region (plus a short pad)."""
    useful = np.flatnonzero(keep_mask > 0.2)
    if useful.size == 0:
        return np.zeros_like(audio), None
    last = int(useful[-1])
    pad = int(sample_rate * pad_ms / 1000.0)
    cut = min(audio.shape[0], last + pad)
    cleaned = audio.copy()
    if cut < cleaned.shape[0]:
        cleaned[cut:] = 0
    return cleaned, cut / float(sample_rate)


def apply_gate(audio: np.ndarray, mask: np.ndarray) -> np.ndarray:
    """Multiply audio by a 0…1 gate and return 16-bit samples."""
    gate = mask
    if audio.ndim > 1:
        gate = mask.reshape(-1, 1)
    gated = audio.astype(np.float64) * gate
    return np.clip(gated, -32768, 32767).astype(np.int16)


def build_speaker_track_soft(
    audio: np.ndarray,
    sample_rate: int,
    turns: list[tuple[float, float]],
    *,
    fade_ms: float = 15,
    hold_ms: float = 100,
    mute_mask: np.ndarray | None = None,
) -> np.ndarray:
    """Gate a speaker with soft edges. mute_mask pulls level down (e.g. during music beds)."""
    mask = soft_activity_mask(
        audio.shape[0],
        sample_rate,
        turns,
        fade_ms=fade_ms,
        hold_ms=hold_ms,
    )
    if mute_mask is not None:
        mask = mask * (1.0 - np.clip(mute_mask[: mask.size], 0.0, 1.0))
    return apply_gate(audio, mask)


def _hop_samples(sample_rate: int, hop_ms: float = 20.0) -> int:
    return max(1, int(round(sample_rate * hop_ms / 1000.0)))


def _frame_mean(mask: np.ndarray, hop: int, n_frames: int) -> np.ndarray:
    padded = np.zeros(n_frames * hop, dtype=np.float64)
    n = min(mask.size, padded.size)
    padded[:n] = mask[:n]
    return padded.reshape(n_frames, hop).mean(axis=1)


def _turns_to_framed_mask(
    n_frames: int,
    hop: int,
    sample_rate: int,
    turns: list[tuple[float, float]],
    *,
    fade_ms: float,
    hold_ms: float,
) -> np.ndarray:
    hop_ms = 1000.0 * hop / float(sample_rate)
    hold_frames = max(0, int(round(hold_ms / hop_ms))) if hop_ms > 0 else 0
    mask = np.zeros(n_frames, dtype=np.float64)
    for start, end in turns:
        start_index = int(round(start * sample_rate / hop)) - hold_frames
        end_index = int(round(end * sample_rate / hop)) + hold_frames
        start_index = max(0, start_index)
        end_index = min(n_frames, end_index)
        if end_index > start_index:
            mask[start_index:end_index] = 1.0
    fade_frames = max(1, int(round(fade_ms / hop_ms))) if hop_ms > 0 else 1
    if fade_frames > 1 and np.any(mask):
        kernel = np.hanning(fade_frames * 2 + 1)
        kernel = kernel / kernel.sum()
        mask = np.clip(np.convolve(mask, kernel, mode="same"), 0.0, 1.0)
    return mask


def _share_framed_masks(
    stack: np.ndarray,
    *,
    bleed: float = 0.16,
    min_dom: float = 0.68,
    active: float = 0.12,
) -> np.ndarray:
    """When several speakers are on, keep the main one loud and duck extras so gains sum to ~1."""
    speakers, frames = stack.shape
    if speakers < 2:
        return stack.copy()
    decay = 0.88
    recency = np.empty_like(stack)
    recency[:, 0] = stack[:, 0]
    keep = 1.0 - decay
    for frame in range(1, frames):
        recency[:, frame] = decay * recency[:, frame - 1] + keep * stack[:, frame]
    n_active = (stack > active).sum(axis=0)
    overlap = n_active >= 2
    out = stack.copy()
    if not np.any(overlap):
        return out
    dominant = np.argmax(recency, axis=0)
    idx = np.flatnonzero(overlap)
    extra_n = np.maximum(n_active[idx].astype(np.float64) - 1.0, 1.0)
    extra_gain = np.minimum(bleed, (1.0 - min_dom) / extra_n)
    dom_gain = np.clip(1.0 - extra_n * extra_gain, min_dom, 1.0)
    out[:, idx] = stack[:, idx] * extra_gain
    out[dominant[idx], idx] = stack[dominant[idx], idx] * dom_gain
    return np.clip(out, 0.0, 1.0)


def _smooth_gate(mask: np.ndarray, sample_rate: int, fade_ms: float = 12) -> np.ndarray:
    fade = max(1, int(sample_rate * fade_ms / 1000.0))
    if fade <= 1 or not np.any(mask):
        return mask
    kernel = np.hanning(fade * 2 + 1)
    kernel = kernel / kernel.sum()
    return np.clip(np.convolve(mask, kernel, mode="same"), 0.0, 1.0)


def shared_speaker_gates(
    length: int,
    sample_rate: int,
    speaker_turns: list[list[tuple[float, float]]],
    *,
    mute_mask: np.ndarray | None = None,
    fade_ms: float = 15,
    hold_ms: float = 100,
) -> list[np.ndarray]:
    """Per-speaker 0…1 gates. Solo regions stay full; talk-over is shared instead of copied."""
    if not speaker_turns:
        return []
    hop = _hop_samples(sample_rate)
    n_frames = max(1, (length + hop - 1) // hop)
    framed = [
        _turns_to_framed_mask(
            n_frames,
            hop,
            sample_rate,
            turns,
            fade_ms=fade_ms,
            hold_ms=hold_ms,
        )
        for turns in speaker_turns
    ]
    if mute_mask is not None:
        mute_frames = _frame_mean(np.clip(mute_mask[:length], 0.0, 1.0), hop, n_frames)
        framed = [row * (1.0 - mute_frames) for row in framed]
    shared = _share_framed_masks(np.stack(framed, axis=0))
    return [_smooth_gate(upsample_mask(row, hop, length), sample_rate) for row in shared]


def build_music_and_sfx(
    original: np.ndarray,
    accompaniment: np.ndarray | None,
    sample_rate: int,
    segments: list[Segment],
    *,
    vocals: np.ndarray | None = None,
) -> tuple[np.ndarray, dict]:
    """
    Real music beds keep the original (music + any voice in the bed).
    Elsewhere use the Demucs other stem, muted under speech.
    Trailing low-level garbage after useful content is zeroed.
    """
    length = original.shape[0]
    speech = speech_mask_from_segments(length, sample_rate, segments)
    if original.ndim > 1:
        speech_2d = speech.reshape(-1, 1)
    else:
        speech_2d = speech

    if accompaniment is None:
        music = original.astype(np.float64) * (1.0 - speech_2d)
        music_i16 = np.clip(music, -32768, 32767).astype(np.int16)
        cleaned, cut_at = strip_trailing_garbage(music_i16, sample_rate, 1.0 - speech)
        return cleaned, {"method": "gaps", "garbage_cut_at": cut_at}

    music_active = music_activity_mask(accompaniment, sample_rate, vocals=vocals)
    if original.ndim > 1:
        music_2d = music_active.reshape(-1, 1)
    else:
        music_2d = music_active

    # Keep original wherever music/SFX is really happening (do not peel voice off the bed).
    bed = original.astype(np.float64) * music_2d
    # Outside music beds, keep Demucs other only when nobody is talking.
    other = accompaniment.astype(np.float64) * (1.0 - music_2d) * (1.0 - speech_2d)
    out = bed + other
    music_i16 = np.clip(out, -32768, 32767).astype(np.int16)

    # Useful content = music beds, or non-speech other that still has energy.
    other_rms, hop = frame_rms(accompaniment, sample_rate)
    peak = float(np.percentile(other_rms, 95)) if other_rms.size else 1.0
    other_active = upsample_mask(
        (other_rms >= max(peak * 0.08, 1.0)).astype(np.float64),
        hop,
        length,
    )
    useful = np.maximum(music_active, other_active * (1.0 - speech))
    cleaned, cut_at = strip_trailing_garbage(music_i16, sample_rate, useful, pad_ms=600)
    return cleaned, {
        "method": "music_aware",
        "garbage_cut_at": cut_at,
        "music_coverage": round(float(np.mean(music_active > 0.2)), 4),
    }
