from __future__ import annotations

from collections import defaultdict
from pathlib import Path
from typing import Iterable

import numpy as np

from podcast_stripper.cleanup import (
    apply_gate,
    build_music_and_sfx,
    music_activity_mask,
    shared_speaker_gates,
)
from podcast_stripper.convert import convert_for_export

Segment = tuple[float, float, str]


def load_wav(path: Path) -> tuple[np.ndarray, int]:
    import wave

    with wave.open(str(path), "rb") as handle:
        channels = handle.getnchannels()
        sample_width = handle.getsampwidth()
        sample_rate = handle.getframerate()
        frames = handle.getnframes()
        raw = handle.readframes(frames)

    if sample_width != 2:
        raise RuntimeError(f"Expected 16-bit WAV, got sample width {sample_width}")

    audio = np.frombuffer(raw, dtype=np.int16)
    if channels > 1:
        audio = audio.reshape(-1, channels)
    else:
        audio = audio.reshape(-1, 1)
    return audio.copy(), sample_rate


def save_wav(path: Path, audio: np.ndarray, sample_rate: int) -> None:
    import wave

    path.parent.mkdir(parents=True, exist_ok=True)
    if audio.ndim == 1:
        audio = audio.reshape(-1, 1)
    channels = audio.shape[1]
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(channels)
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        handle.writeframes(np.ascontiguousarray(audio, dtype=np.int16).tobytes())


def group_segments(segments: Iterable[Segment]) -> dict[str, list[tuple[float, float]]]:
    grouped: dict[str, list[tuple[float, float]]] = defaultdict(list)
    for start, end, speaker in segments:
        if end <= start:
            continue
        grouped[str(speaker)].append((float(start), float(end)))
    return dict(grouped)


def speaker_label(index: int) -> str:
    return f"Speaker {index + 1}"


MUSIC_LABEL = "Music and SFX"
MUSIC_FILENAME = "Music_and_SFX.wav"


def build_speaker_track(
    audio: np.ndarray,
    sample_rate: int,
    turns: list[tuple[float, float]],
) -> np.ndarray:
    track = np.zeros_like(audio)
    total = audio.shape[0]
    for start, end in turns:
        start_index = _clamp_index(start, sample_rate, total)
        end_index = _clamp_index(end, sample_rate, total)
        if end_index > start_index:
            track[start_index:end_index] = audio[start_index:end_index]
    return track


def _clamp_index(seconds: float, sample_rate: int, total: int) -> int:
    index = int(round(seconds * sample_rate))
    return max(0, min(total, index))


def build_nonvoice_track(
    audio: np.ndarray,
    sample_rate: int,
    segments: Iterable[Segment],
) -> np.ndarray:
    """Keep audio that is not assigned to a speaker: intros, gaps, stingers."""
    track = audio.copy()
    total = audio.shape[0]
    for start, end, _speaker in segments:
        start_index = _clamp_index(start, sample_rate, total)
        end_index = _clamp_index(end, sample_rate, total)
        if end_index > start_index:
            track[start_index:end_index] = 0
    return track


def export_speaker_tracks(
    source_audio: Path,
    output_dir: Path,
    segments: list[Segment],
    *,
    work_wav: Path | None = None,
    voice_wav: Path | None = None,
    music_wav: Path | None = None,
) -> dict:
    if work_wav is None:
        work_wav = output_dir / "_original.wav"
        convert_for_export(source_audio, work_wav)

    audio, sample_rate = load_wav(work_wav)
    duration = audio.shape[0] / float(sample_rate)
    voice_audio = audio
    if voice_wav is not None:
        loaded_voice, voice_rate = load_wav(voice_wav)
        if voice_rate != sample_rate:
            raise RuntimeError("Voice stem sample rate does not match the original audio.")
        from podcast_stripper.separate import align_to_reference

        voice_audio = align_to_reference(loaded_voice, audio)

    grouped = group_segments(segments)
    speakers = sorted(grouped.keys())

    accompaniment = None
    music_mute = None
    if music_wav is not None:
        loaded_music, music_rate = load_wav(music_wav)
        if music_rate != sample_rate:
            raise RuntimeError("Music stem sample rate does not match the original audio.")
        from podcast_stripper.separate import align_to_reference

        accompaniment = align_to_reference(loaded_music, audio)
        # Only mute speakers on *real* beds (vocals keep the detector honest).
        music_mute = music_activity_mask(
            accompaniment,
            sample_rate,
            vocals=voice_audio if voice_wav is not None else None,
        )

    tracks: list[dict] = []
    speaker_turns = [grouped[speaker] for speaker in speakers]
    gates = shared_speaker_gates(
        voice_audio.shape[0],
        sample_rate,
        speaker_turns,
        mute_mask=music_mute,
    )
    for index, speaker in enumerate(speakers):
        label = speaker_label(index)
        filename = f"{label.replace(' ', '_')}.wav"
        dest = output_dir / filename
        track = apply_gate(voice_audio, gates[index])
        save_wav(dest, track, sample_rate)
        tracks.append(
            {
                "id": speaker,
                "label": label,
                "path": str(dest),
                "turns": [
                    {"start": round(start, 3), "end": round(end, 3)}
                    for start, end in grouped[speaker]
                ],
            }
        )

    music_audio, music_meta = build_music_and_sfx(
        audio,
        accompaniment,
        sample_rate,
        segments,
        vocals=voice_audio if voice_wav is not None else None,
    )
    music_path = output_dir / MUSIC_FILENAME
    save_wav(music_path, music_audio, sample_rate)
    music_info = {
        "id": "music_and_sfx",
        "label": MUSIC_LABEL,
        "path": str(music_path),
        **music_meta,
    }

    manifest = {
        "source": str(source_audio),
        "sample_rate": sample_rate,
        "duration": round(duration, 3),
        "speakers": tracks,
        "music": music_info,
    }
    return manifest


def mix_aligned_wavs(paths: list[Path], dest: Path) -> Path:
    """Sum aligned tracks with no extra gain (do not use ffmpeg amix normalize)."""
    if not paths:
        raise RuntimeError("No tracks to mix.")
    mixed: np.ndarray | None = None
    sample_rate = None
    for path in paths:
        audio, rate = load_wav(path)
        if sample_rate is None:
            sample_rate = rate
            mixed = audio.astype(np.int32)
            continue
        if rate != sample_rate:
            raise RuntimeError(f"Sample rate mismatch in {path}")
        if audio.shape != mixed.shape:
            from podcast_stripper.separate import align_to_reference

            audio = align_to_reference(audio, mixed)
        mixed = mixed + audio.astype(np.int32)
    clipped = np.clip(mixed, -32768, 32767).astype(np.int16)
    save_wav(dest, clipped, sample_rate)
    return dest


def reconstruction_stats(original: Path, remix: Path) -> dict:
    left, left_sr = load_wav(original)
    right, right_sr = load_wav(remix)
    if left_sr != right_sr:
        raise RuntimeError("Original and remix sample rates differ.")
    if left.shape != right.shape:
        from podcast_stripper.separate import align_to_reference

        right = align_to_reference(right, left)
    a = left.astype(np.float64)
    b = right.astype(np.float64)
    denom = float(np.sqrt(np.mean(a**2) * np.mean(b**2))) or 1.0
    correlation = float(np.mean(a * b) / denom)
    return {
        "correlation": round(correlation, 4),
        "original_rms": round(float(np.sqrt(np.mean(a**2))), 1),
        "remix_rms": round(float(np.sqrt(np.mean(b**2))), 1),
        "mean_abs_diff": round(float(np.mean(np.abs(a - b))), 1),
    }
