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
    keep_original_mask: np.ndarray | None = None,
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
    keep = _fit_mask(keep_original_mask, length)

    if accompaniment is None:
        # Gaps stay on this track. An intro mask also keeps the original there,
        # including any voice that belongs with the music.
        stay = np.maximum(1.0 - speech, keep)
        if original.ndim > 1:
            stay_2d = stay.reshape(-1, 1)
        else:
            stay_2d = stay
        music = original.astype(np.float64) * stay_2d
        music_i16 = np.clip(music, -32768, 32767).astype(np.int16)
        cleaned, cut_at = strip_trailing_garbage(music_i16, sample_rate, stay)
        return cleaned, {"method": "gaps", "garbage_cut_at": cut_at}

    music_active = music_activity_mask(accompaniment, sample_rate, vocals=vocals)
    # Intro / voice-over regions keep the untouched mix, even where a voice
    # would otherwise be peeled off the music stem.
    keep_bed = np.maximum(music_active, keep)
    if original.ndim > 1:
        music_2d = keep_bed.reshape(-1, 1)
    else:
        music_2d = keep_bed

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
    useful = np.maximum(useful, keep)
    cleaned, cut_at = strip_trailing_garbage(music_i16, sample_rate, useful, pad_ms=600)
    return cleaned, {
        "method": "music_aware",
        "garbage_cut_at": cut_at,
        "music_coverage": round(float(np.mean(music_active > 0.2)), 4),
    }


# Natural room sits at the separated vocal's own level. Off is today's mute.
ROOM_TONE_FADE_MS = 165.0
# A dry stretch this long, after the music has fallen away, ends the intro.
DRY_SPEECH_MIN_SECONDS = 8.0
DRY_SPEECH_RATIO = 0.22
DRY_SPEECH_BRIDGE_SECONDS = 1.5
# Music stem is really there (not the quiet copy Demucs leaves under talk).
MUSIC_PRESENT_VOCAL_RATIO = 0.30
MUSIC_PRESENT_PEAK_FRACTION = 0.10
MUSIC_PRESENT_BRIDGE_SECONDS = 2.5
MUSIC_PRESENT_MIN_SECONDS = 1.2
# Two people each talking this long inside a music region means a bed, not an intro.
CONVERSATION_GUARD_SECONDS = 2.0


def _fit_mask(mask: np.ndarray | None, length: int) -> np.ndarray:
    if mask is None or length <= 0:
        return np.zeros(length, dtype=np.float64)
    fitted = np.asarray(mask, dtype=np.float64).reshape(-1)
    if fitted.size < length:
        fitted = np.pad(fitted, (0, length - fitted.size))
    return np.clip(fitted[:length], 0.0, 1.0)


def parse_room_tone(value: str | float | None) -> float | None:
    """dB under the natural room. None means today's hard mute.

    ``natural`` / ``0`` keep the separated room at full level.
    ``off`` mutes pauses. A negative number such as ``-20`` is that many dB down.
    """
    if value is None:
        return 0.0
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        db = float(value)
    else:
        text = str(value).strip().lower()
        if text in {"", "natural", "full", "on"}:
            return 0.0
        if text in {"off", "mute", "none"}:
            return None
        try:
            db = float(text)
        except ValueError as exc:
            raise ValueError("Room tone must be natural, off, or a negative dB level.") from exc
    if db > 0.05:
        raise ValueError("Room tone is natural (0 dB), off, or a negative dB level.")
    if db < -80.0:
        return None
    return db


def parse_intro_end(value: str | float | None) -> float | None:
    """Seconds from ``1:05``, ``65``, or empty. Empty means no manual cut."""
    if value is None:
        return None
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        seconds = float(value)
    else:
        text = str(value).strip()
        if not text:
            return None
        if ":" in text:
            parts = text.split(":")
            if len(parts) != 2:
                raise ValueError("Intro end must look like 1:05 or a number of seconds.")
            try:
                minutes = float(parts[0])
                secs = float(parts[1])
            except ValueError as exc:
                raise ValueError("Intro end must look like 1:05 or a number of seconds.") from exc
            if minutes < 0 or secs < 0 or secs >= 60:
                raise ValueError("Intro end must look like 1:05 (seconds under 60).")
            seconds = minutes * 60.0 + secs
        else:
            try:
                seconds = float(text)
            except ValueError as exc:
                raise ValueError("Intro end must look like 1:05 or a number of seconds.") from exc
    if seconds < 0:
        raise ValueError("Intro end cannot be negative.")
    return seconds


def edge_open_mask(mask: np.ndarray, fade_samples: int) -> np.ndarray:
    """Lengthen the open side of a gate with a ramp. Do not lower the interior.

    A blur across the whole gate digs a hole in the words. This only draws
    the ramp on samples that were closed.
    """
    if fade_samples <= 1:
        return np.clip(mask.astype(np.float64), 0.0, 1.0)
    source = np.clip(mask.astype(np.float64), 0.0, 1.0)
    open_region = source >= 0.5
    padded = np.concatenate([[False], open_region, [False]])
    rises = np.flatnonzero(padded[1:] & ~padded[:-1])
    falls = np.flatnonzero(~padded[1:] & padded[:-1])
    out = source.copy()
    for rise in rises:
        start = max(0, int(rise) - fade_samples)
        length = int(rise) - start
        if length <= 0:
            continue
        level = float(source[min(source.size - 1, int(rise))])
        ramp = np.linspace(0.0, level, length, endpoint=False)
        out[start:rise] = np.maximum(out[start:rise], ramp)
    for fall in falls:
        end = min(out.size, int(fall) + fade_samples)
        length = end - int(fall)
        if length <= 0:
            continue
        level = float(source[max(0, int(fall) - 1)])
        ramp = np.linspace(level, 0.0, length, endpoint=False)
        region = out[int(fall) : end]
        out[int(fall) : end] = np.maximum(region, ramp[: region.size])
    return np.clip(out, 0.0, 1.0)


def linear_edge(mask: np.ndarray, fade_samples: int) -> np.ndarray:
    """Soften the edges of a 0/1 mask. Long regions stay fully open."""
    if fade_samples <= 1 or mask.size == 0:
        return np.clip(mask.astype(np.float64), 0.0, 1.0)
    kernel = np.ones(int(fade_samples), dtype=np.float64) / float(fade_samples)
    smoothed = np.convolve(mask.astype(np.float64), kernel, mode="same")
    return np.clip(smoothed, 0.0, 1.0)


def _bridge_short_gaps(mask: np.ndarray, max_hole: int) -> np.ndarray:
    """Fill closed holes up to max_hole samples when both sides are open."""
    if max_hole <= 0 or mask.size == 0:
        return mask
    out = mask.copy()
    n = out.size
    index = 0
    while index < n:
        if out[index] >= 0.5:
            index += 1
            continue
        end = index
        while end < n and out[end] < 0.5:
            end += 1
        left = index > 0 and out[index - 1] >= 0.5
        right = end < n and out[end] >= 0.5
        if left and right and (end - index) <= max_hole:
            out[index:end] = 1.0
        index = end
    return out


def _runs(mask: np.ndarray) -> list[tuple[int, int]]:
    runs: list[tuple[int, int]] = []
    n = mask.size
    index = 0
    while index < n:
        if mask[index] < 0.5:
            index += 1
            continue
        end = index
        while end < n and mask[end] >= 0.5:
            end += 1
        runs.append((index, end))
        index = end
    return runs


def _mono_signal(audio: np.ndarray) -> np.ndarray:
    mono = audio.astype(np.float64)
    if mono.ndim > 1:
        mono = np.mean(mono, axis=1)
    return mono


def mix_speaker_waves(
    vocal: np.ndarray,
    gates: list[np.ndarray],
    sample_rate: int,
    *,
    room_db: float | None,
    blocked: np.ndarray | None = None,
    fade_ms: float = ROOM_TONE_FADE_MS,
) -> list[np.ndarray]:
    """Speaker waveforms with room tone in true pauses.

    ``room_db`` None is today's mute. ``0`` is the separated signal at its
    own level wherever nobody is talking. A negative value is that many dB
    quieter. ``blocked`` (an intro or a real music bed) stays off every
    speaker so that sound can live on the Music/SFX track instead.
    """
    if vocal.ndim == 1:
        vocal = vocal.reshape(-1, 1)
    length = vocal.shape[0]
    fade_samples = max(1, int(round(sample_rate * fade_ms / 1000.0)))
    blocked_env = linear_edge(_fit_mask(blocked, length), fade_samples)
    open_gates = [np.clip(_fit_mask(gate, length), 0.0, 1.0) for gate in gates]
    if room_db is not None:
        open_gates = [edge_open_mask(gate, fade_samples) for gate in open_gates]
    gain = 0.0 if room_db is None else float(10.0 ** (float(room_db) / 20.0))
    vocal_f = vocal.astype(np.float64)
    tracks: list[np.ndarray] = []
    for index, gate in enumerate(open_gates):
        if room_db is None:
            env = gate * (1.0 - blocked_env)
        else:
            others = np.zeros(length, dtype=np.float64)
            for other_index, other in enumerate(open_gates):
                if other_index != index:
                    others = np.maximum(others, other)
            room_env = (
                np.clip(1.0 - gate, 0.0, 1.0)
                * np.clip(1.0 - others, 0.0, 1.0)
                * np.clip(1.0 - blocked_env, 0.0, 1.0)
            )
            speech_env = gate * np.clip(1.0 - blocked_env, 0.0, 1.0)
            env = speech_env + room_env * gain
        shaped = vocal_f * env.reshape(-1, 1)
        tracks.append(shaped)
    return tracks


def _frame_clock(hop: int, sample_rate: int) -> float:
    return hop / float(sample_rate)


def first_dry_speech_start(
    vocals: np.ndarray,
    accompaniment: np.ndarray,
    sample_rate: int,
    *,
    min_seconds: float = DRY_SPEECH_MIN_SECONDS,
    dry_ratio: float = DRY_SPEECH_RATIO,
    bridge_seconds: float = DRY_SPEECH_BRIDGE_SECONDS,
) -> float | None:
    """When the voices become dry talk, after music and voice-over have stopped.

    A frame counts as dry when the vocal stem is at speech level and the
    music stem is far quieter. Short spikes are bridged so one loud moment
    does not push the cut later. Returns None when the file never settles
    into that stretch (a bed under the whole show is left alone).
    """
    vocal_rms, hop = frame_rms(vocals, sample_rate)
    other_rms, _ = frame_rms(accompaniment, sample_rate)
    n = min(vocal_rms.size, other_rms.size)
    if n == 0:
        return None
    vocal_rms = vocal_rms[:n]
    other_rms = other_rms[:n]
    # A fraction of the loud vocal frames. Silence and music-only bleed stay below it.
    speech_floor = max(float(np.percentile(vocal_rms, 95)) * 0.20, 1.0)
    speech = vocal_rms >= speech_floor
    dry = speech & (other_rms <= vocal_rms * dry_ratio + 1.0)
    bridge = max(0, int(round(bridge_seconds / _frame_clock(hop, sample_rate))))
    dry = _bridge_short_gaps(dry.astype(np.float64), bridge) >= 0.5
    need = max(1, int(round(min_seconds / _frame_clock(hop, sample_rate))))
    for start, end in _runs(dry.astype(np.float64)):
        if (end - start) >= need:
            return float(start * hop) / float(sample_rate)
    return None


def music_present_mask(
    vocals: np.ndarray,
    accompaniment: np.ndarray,
    sample_rate: int,
    *,
    vocal_ratio: float = MUSIC_PRESENT_VOCAL_RATIO,
    peak_fraction: float = MUSIC_PRESENT_PEAK_FRACTION,
    bridge_seconds: float = MUSIC_PRESENT_BRIDGE_SECONDS,
    min_seconds: float = MUSIC_PRESENT_MIN_SECONDS,
) -> np.ndarray:
    """Sample mask where the music stem is a real music event, including short voice-overs.

    Speech bleed stays off: the music stem has to be both loud in the file
    and not tiny next to the vocal.
    """
    length = accompaniment.shape[0]
    vocal_rms, hop = frame_rms(vocals, sample_rate)
    other_rms, _ = frame_rms(accompaniment, sample_rate)
    n = min(vocal_rms.size, other_rms.size)
    if n == 0:
        return np.zeros(length, dtype=np.float64)
    vocal_rms = vocal_rms[:n]
    other_rms = other_rms[:n]
    peak = float(np.percentile(other_rms, 95)) or 1.0
    present = (other_rms >= peak * peak_fraction) & (other_rms >= vocal_rms * vocal_ratio + peak * 0.01)
    bridge = max(0, int(round(bridge_seconds / _frame_clock(hop, sample_rate))))
    present = _bridge_short_gaps(present.astype(np.float64), bridge)
    min_frames = max(1, int(round(min_seconds / _frame_clock(hop, sample_rate))))
    present = _drop_short_runs(present, min_frames)
    return upsample_mask(present, hop, length)


def _two_person_bed(segments: list[Segment], start: float, end: float, guard_seconds: float) -> bool:
    spoken: dict[str, float] = {}
    for turn_start, turn_end, speaker in segments:
        overlap = min(end, turn_end) - max(start, turn_start)
        if overlap > 0:
            spoken[str(speaker)] = spoken.get(str(speaker), 0.0) + overlap
    long = [seconds for seconds in spoken.values() if seconds >= guard_seconds]
    return len(long) >= 2


def intro_route_mask(
    length: int,
    sample_rate: int,
    segments: list[Segment],
    accompaniment: np.ndarray | None,
    vocals: np.ndarray | None,
    *,
    intro_end: float | None = None,
    detect: bool = True,
    dry_min_seconds: float = DRY_SPEECH_MIN_SECONDS,
    guard_seconds: float = CONVERSATION_GUARD_SECONDS,
) -> tuple[np.ndarray, dict]:
    """Where the original mix stays on Music/SFX and the speaker tracks stay quiet.

    Automatic rule, in order:

    1. Everything before the first sustained dry speech goes to Music/SFX.
       That is the opening: voice clips on top of music, the music itself,
       and the gap before the hosts settle into dry talk. A show that is
       dry from the first second is not an intro.
    2. After that, a later stretch where music is the event (a bumper, or
       one voice over music) also stays on Music/SFX. If two people are
       both talking through it, it is a bed under the conversation and the
       voices stay on the speaker tracks.
    3. A manual ``intro_end`` replaces the automatic opening cut. ``0`` keeps
       no opening. Leave it empty to use the automatic cut.

    Without separated stems, only the manual cut is available.
    """
    mask = np.zeros(length, dtype=np.float64)
    info: dict = {
        "detect": bool(detect),
        "manual_end": None if intro_end is None else round(float(intro_end), 3),
        "auto_end": None,
        "method": "none",
    }
    if length <= 0 or sample_rate <= 0:
        return mask, info

    def stamp(until: float) -> None:
        cut = int(round(max(0.0, until) * sample_rate))
        cut = max(0, min(length, cut))
        if cut > 0:
            mask[:cut] = 1.0

    if intro_end is not None:
        stamp(float(intro_end))
        info["method"] = "manual"
    elif detect and accompaniment is not None and vocals is not None:
        auto = first_dry_speech_start(
            vocals,
            accompaniment,
            sample_rate,
            min_seconds=dry_min_seconds,
        )
        info["auto_end"] = None if auto is None else round(float(auto), 3)
        # A cut in the first fraction of a second is just the show starting dry.
        if auto is not None and auto >= 0.75:
            stamp(auto)
            info["method"] = "dry-speech"

    if detect and accompaniment is not None and vocals is not None:
        present = music_present_mask(vocals, accompaniment, sample_rate)
        # Drop music regions that are really two people talking over a bed.
        cleared = present.copy()
        for start, end in _runs((present > 0.5).astype(np.float64)):
            start_s = start / float(sample_rate)
            end_s = end / float(sample_rate)
            if _two_person_bed(segments, start_s, end_s, guard_seconds):
                cleared[start:end] = 0.0
        added = cleared > 0.5
        if np.any(added):
            mask = np.maximum(mask, added.astype(np.float64))
            if info["method"] == "none":
                info["method"] = "voice-over-music"
            elif info["method"] == "dry-speech":
                info["method"] = "dry-speech+voice-over"
            elif info["method"] == "manual":
                info["method"] = "manual+voice-over"
        info["music_present_coverage"] = round(float(np.mean(added)), 4)
    info["coverage"] = round(float(np.mean(mask > 0.5)), 4)
    return mask, info
