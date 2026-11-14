#!/usr/bin/env python3
"""Offline TheStrip sound experiments.

Reuses the shipped engine for the current speaker split, then renders
alternate gates and separation settings. Does not modify the apps.

Stages: probe, prepare, separate, render, pack, all.
Cached under /tmp/strip-quality-scratch so a rerun can resume.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import subprocess
import sys
import time
import wave
from pathlib import Path

import numpy as np

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("PYANNOTE_METRICS_ENABLED", "0")
os.environ.setdefault("PODCAST_STRIPPER_DEMUCS_DEVICE", "cpu")

REPO = Path(__file__).resolve().parents[2]
ENGINE = REPO / "Podcast Stripper" / "engine"
SCRATCH = Path("/tmp/strip-quality-scratch")
PACK_DIR = Path.home() / "Music/ClubPod/StripTests/2026-11-14"
REPORT_DIR = REPO / ".ppjob"
SOURCE = Path.home() / "Music/ClubPod/Audio/The Macro Dirt Podcast - Veterans Day Macro Dirt.mp3"
ALT_SOURCE = Path.home() / "Music/ClubPod/Audio/LevelUpOct26mixed.aiff"

EXCERPT_SECONDS = 90.0
LISTEN_SECONDS = 48.0
FRAME_HOP = 0.05


def log(message: str) -> None:
    stamp = time.strftime("%H:%M:%S")
    line = f"[{stamp}] {message}"
    print(line, flush=True)
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    with (REPORT_DIR / "strip-quality-run.log").open("a", encoding="utf-8") as handle:
        handle.write(line + "\n")


def ffmpeg_exe() -> str:
    from podcast_stripper.ffmpeg_bin import find_ffmpeg

    return find_ffmpeg()


def run_ffmpeg(args: list[str]) -> None:
    command = [ffmpeg_exe(), "-hide_banner", "-loglevel", "error", "-y", *args]
    subprocess.run(command, check=True, capture_output=True)


def source_duration_and_rate(path: Path) -> tuple[float, int, int]:
    """Return duration seconds, sample rate, channels. Does not modify path."""
    probe = subprocess.run(
        [ffmpeg_exe(), "-hide_banner", "-i", str(path)],
        capture_output=True,
        text=True,
    )
    text = (probe.stderr or "") + (probe.stdout or "")
    rate = 44100
    channels = 2
    duration = 0.0
    for line in text.splitlines():
        if "Audio:" in line:
            # e.g. Audio: mp3, 44100 Hz, stereo, fltp, 128 kb/s
            parts = line.replace(",", " ").split()
            for index, token in enumerate(parts):
                if token == "Hz" and index:
                    try:
                        rate = int(parts[index - 1])
                    except ValueError:
                        pass
            if "mono" in line:
                channels = 1
            elif "stereo" in line:
                channels = 2
        if "Duration:" in line:
            raw = line.split("Duration:", 1)[1].split(",", 1)[0].strip()
            hours, minutes, seconds = raw.split(":")
            duration = int(hours) * 3600 + int(minutes) * 60 + float(seconds)
    if duration <= 0:
        raise RuntimeError(f"Could not read duration for {path.name}")
    return duration, rate, channels


def decode_analysis(src: Path, dest: Path) -> tuple[np.ndarray, int]:
    """Low-rate stereo float WAV for picking excerpts. Read-only on src."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    if not dest.exists():
        run_ffmpeg(
            [
                "-i",
                str(src),
                "-vn",
                "-ac",
                "2",
                "-ar",
                "8000",
                "-c:a",
                "pcm_f32le",
                str(dest),
            ]
        )
    from scipy.io import wavfile

    rate, audio = wavfile.read(dest)
    audio = np.asarray(audio, dtype=np.float32)
    if audio.ndim == 1:
        audio = audio.reshape(-1, 1)
    return audio, int(rate)


def frame_features(audio: np.ndarray, rate: int) -> dict:
    hop = max(1, int(round(rate * FRAME_HOP)))
    frames = audio.shape[0] // hop
    mid_db = np.empty(frames, dtype=np.float64)
    width = np.empty(frames, dtype=np.float64)
    for index in range(frames):
        chunk = audio[index * hop : (index + 1) * hop]
        if chunk.shape[1] == 1:
            mid = chunk[:, 0]
            side = np.zeros_like(mid)
        else:
            mid = 0.5 * (chunk[:, 0] + chunk[:, 1])
            side = 0.5 * (chunk[:, 0] - chunk[:, 1])
        mid_rms = float(np.sqrt(np.mean(mid.astype(np.float64) ** 2)) + 1e-12)
        side_rms = float(np.sqrt(np.mean(side.astype(np.float64) ** 2)) + 1e-12)
        mid_db[index] = 20.0 * np.log10(mid_rms)
        width[index] = side_rms / (mid_rms + 1e-12)
    return {"hop": FRAME_HOP, "mid_db": mid_db, "width": width}


def bass_music_window(audio: np.ndarray, rate: int, duration: float, pause: dict | None) -> dict | None:
    """Find a theme or music open when the mix is dual-mono and stereo width cannot see it."""
    hop = rate  # 1 second
    mid = audio.mean(axis=1) if audio.ndim > 1 else audio
    seconds = int(mid.size // hop)
    if seconds < 30:
        return None
    ratio = np.empty(seconds, dtype=np.float64)
    level = np.empty(seconds, dtype=np.float64)
    window = np.hanning(hop)
    for index in range(seconds):
        chunk = mid[index * hop : (index + 1) * hop].astype(np.float64)
        level[index] = 20.0 * np.log10(float(np.sqrt(np.mean(chunk**2))) + 1e-12)
        spec = np.abs(np.fft.rfft(chunk * window))
        freqs = np.fft.rfftfreq(hop, 1.0 / rate)
        bass = float(spec[(freqs >= 40) & (freqs < 160)].mean())
        body = float(spec[(freqs >= 400) & (freqs < 2200)].mean()) + 1e-12
        ratio[index] = bass / body
    music = (level > -30.0) & (ratio > 4.0)
    best = None
    index = 0
    while index < seconds:
        if not music[index]:
            index += 1
            continue
        end = index + 1
        while end < seconds and music[end]:
            end += 1
        if end - index >= 8 and (best is None or (end - index) > (best[1] - best[0])):
            best = (index, end)
        index = end
    if best is None:
        return None
    center = 0.5 * (best[0] + best[1])
    start, end = _window_around(center, EXCERPT_SECONDS, duration)
    if pause and min(end, pause["end"]) - max(start, pause["start"]) > 10:
        start, end = 0.0, min(duration, EXCERPT_SECONDS)
    return {
        "id": "C-music",
        "role": "music",
        "start": round(float(start), 3),
        "end": round(float(end), 3),
        "event_start": float(best[0]),
        "event_end": float(best[1]),
        "why": (
            f"bass-heavy music from {best[0]:.0f}s to {best[1]:.0f}s "
            "(the mix is dual-mono, so stereo width does not show it)"
        ),
    }


def _runs(mask: np.ndarray, hop: float) -> list[tuple[float, float]]:
    runs: list[tuple[float, float]] = []
    index = 0
    n = mask.size
    while index < n:
        if not mask[index]:
            index += 1
            continue
        end = index + 1
        while end < n and mask[end]:
            end += 1
        runs.append((index * hop, end * hop))
        index = end
    return runs


def _window_around(center: float, length: float, duration: float) -> tuple[float, float]:
    start = center - length / 2.0
    if start < 0:
        start = 0.0
    if start + length > duration:
        start = max(0.0, duration - length)
    return round(start, 3), round(min(duration, start + length), 3)


def pick_candidates(features: dict, duration: float) -> dict:
    mid_db = features["mid_db"]
    width = features["width"]
    hop = float(features["hop"])
    noise = float(np.percentile(mid_db, 15))
    speech = mid_db > (noise + 12.0)
    music = (width > 0.55) & (mid_db > noise + 8.0)
    pauses = []
    for start, end in _runs(~speech, hop):
        gap = end - start
        if gap < 1.25 or gap > 8.0:
            continue
        before = speech[max(0, int(start / hop) - int(2.0 / hop)) : max(1, int(start / hop))]
        after = speech[int(end / hop) : min(speech.size, int(end / hop) + int(2.0 / hop))]
        if before.size and after.size and float(before.mean()) > 0.4 and float(after.mean()) > 0.4:
            pauses.append({"start": round(start, 3), "end": round(end, 3), "dur": round(gap, 3)})
    pauses.sort(key=lambda item: abs(item["dur"] - 2.2))
    pause_choice = pauses[0] if pauses else None

    music_runs = [
        {"start": round(start, 3), "end": round(end, 3), "dur": round(end - start, 3)}
        for start, end in _runs(music, hop)
        if end - start >= 2.0
    ]
    music_runs.sort(key=lambda item: item["dur"], reverse=True)

    n = speech.size
    win = int(round(EXCERPT_SECONDS / hop))
    music_windows = []
    talk_windows = []
    if n > win:
        for start_i in range(0, n - win, int(5.0 / hop)):
            speech_frac = float(speech[start_i : start_i + win].mean())
            music_frac = float(music[start_i : start_i + win].mean())
            t0 = start_i * hop
            item = {
                "start": round(t0, 3),
                "end": round(t0 + EXCERPT_SECONDS, 3),
                "speech_frac": round(speech_frac, 3),
                "music_frac": round(music_frac, 3),
                "score": round(speech_frac * music_frac, 4),
            }
            if speech_frac > 0.18 and music_frac > 0.12:
                music_windows.append(item)
            if speech_frac > 0.62 and music_frac < 0.25:
                talk_windows.append(item)
    music_windows.sort(key=lambda item: item["score"], reverse=True)
    talk_windows.sort(key=lambda item: item["speech_frac"], reverse=True)

    def overlaps(a0: float, a1: float, b0: float, b1: float) -> bool:
        return min(a1, b1) - max(a0, b0) > 10.0

    chosen_pause = None
    if pause_choice:
        center = 0.5 * (pause_choice["start"] + pause_choice["end"])
        start, end = _window_around(center, EXCERPT_SECONDS, duration)
        chosen_pause = {
            "id": "A-pauses",
            "role": "pauses",
            "start": start,
            "end": end,
            "event_start": pause_choice["start"],
            "event_end": pause_choice["end"],
            "why": f"pause of {pause_choice['dur']:.1f}s with speech on both sides",
        }

    chosen_music = None
    blocked = []
    if chosen_pause:
        blocked.append((chosen_pause["start"], chosen_pause["end"]))
    for item in music_windows:
        if any(overlaps(item["start"], item["end"], a, b) for a, b in blocked):
            continue
        chosen_music = {
            "id": "C-music",
            "role": "music",
            "start": item["start"],
            "end": item["end"],
            "event_start": item["start"],
            "event_end": item["end"],
            "why": (
                f"music-like stereo for {item['music_frac']:.0%} of the window "
                f"and speech for {item['speech_frac']:.0%}"
            ),
            "speech_frac": item["speech_frac"],
            "music_frac": item["music_frac"],
        }
        break

    talk_choices = []
    if chosen_music:
        blocked.append((chosen_music["start"], chosen_music["end"]))
    for item in talk_windows:
        if any(overlaps(item["start"], item["end"], a, b) for a, b in blocked):
            continue
        talk_choices.append(
            {
                "id": f"talk-{len(talk_choices)+1}",
                "role": "crosstalk-candidate",
                "start": item["start"],
                "end": item["end"],
                "event_start": item["start"],
                "event_end": item["end"],
                "why": f"dense speech ({item['speech_frac']:.0%}), little wide stereo",
                "speech_frac": item["speech_frac"],
            }
        )
        blocked.append((item["start"], item["end"]))
        if len(talk_choices) >= 3:
            break

    return {
        "noise_floor_db": round(noise, 2),
        "pause_count": len(pauses),
        "longest_listed_pauses": pauses[:8],
        "music_runs": music_runs[:6],
        "pause": chosen_pause,
        "music": chosen_music,
        "talk_candidates": talk_choices,
    }


def extract_excerpt(src: Path, dest: Path, start: float, duration: float) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and dest.stat().st_size > 1000:
        return
    run_ffmpeg(
        [
            "-ss",
            f"{start:.3f}",
            "-t",
            f"{duration:.3f}",
            "-i",
            str(src),
            "-vn",
            "-c:a",
            "pcm_s16le",
            str(dest),
        ]
    )


def wav_info(path: Path) -> tuple[int, int, int]:
    with wave.open(str(path), "rb") as handle:
        return handle.getframerate(), handle.getnchannels(), handle.getnframes()


def load_float(path: Path) -> tuple[np.ndarray, int]:
    from podcast_stripper.export import load_wav

    audio, rate = load_wav(path)
    return audio.astype(np.float64) / 32768.0, rate


def quantize(audio: np.ndarray) -> np.ndarray:
    scaled = np.clip(np.rint(audio * 32767.0), -32768, 32767).astype(np.int16)
    return scaled.astype(np.float64) / 32768.0


def to_mono(audio: np.ndarray) -> np.ndarray:
    if audio.ndim == 1:
        return audio
    return np.mean(audio.astype(np.float64), axis=1)


def diarize_excerpt(wav_path: Path, pipeline, num_speakers: int = 2) -> list[tuple[float, float, str]]:
    from podcast_stripper.consistency import refine_speaker_consistency
    from podcast_stripper.convert import convert_for_diarization
    from podcast_stripper.diarize import (
        DIARIZE_PROFILE,
        extract_segments,
        load_waveform,
        merge_adjacent_segments,
        reassign_short_interruptions,
        resolve_speaker_count_kwargs,
    )

    diar_wav = wav_path.with_name(wav_path.stem + "-16k.wav")
    if not diar_wav.exists():
        convert_for_diarization(wav_path, diar_wav)
    audio_file = load_waveform(diar_wav)
    kwargs = resolve_speaker_count_kwargs(num_speakers=num_speakers)
    try:
        output = pipeline(audio_file, **kwargs)
    except TypeError:
        output = pipeline(audio_file)
    segments = extract_segments(output)
    try:
        refined, _stats = refine_speaker_consistency(
            segments,
            pipeline=pipeline,
            audio_file=audio_file,
        )
        segments = merge_adjacent_segments(refined)
        segments = reassign_short_interruptions(
            segments, float(DIARIZE_PROFILE["short_turn_seconds"])
        )
    except Exception as exc:
        log(f"consistency pass skipped on {wav_path.name}: {type(exc).__name__}")
    return [(float(start), float(end), str(speaker)) for start, end, speaker in segments]


def overlap_stats(segments: list[tuple[float, float, str]]) -> dict:
    if not segments:
        return {"speakers": 0, "overlap_ratio": 0.0, "speech": 0.0}
    speakers = sorted({speaker for _, _, speaker in segments})
    start = min(item[0] for item in segments)
    end = max(item[1] for item in segments)
    hop = 0.02
    bins = max(1, int(round((end - start) / hop)) + 1)
    counts = np.zeros(bins, dtype=np.int16)
    for seg_start, seg_end, _speaker in segments:
        a = max(0, int(round((seg_start - start) / hop)))
        b = min(bins, int(round((seg_end - start) / hop)))
        if b > a:
            counts[a:b] += 1
    speech = int(np.count_nonzero(counts))
    overlap = int(np.count_nonzero(counts >= 2))
    return {
        "speakers": len(speakers),
        "labels": speakers,
        "speech": round(speech * hop, 2),
        "overlap": round(overlap * hop, 2),
        "overlap_ratio": round(overlap / speech, 4) if speech else 0.0,
    }


def load_demucs():
    import torch
    from demucs.apply import apply_model
    from demucs.audio import convert_audio
    from demucs.pretrained import get_model

    device = torch.device("cpu")
    model = get_model("htdemucs")
    model.eval()
    model.to(device)
    return model, apply_model, convert_audio, torch, device


def separate_file(
    wav_path: Path,
    dest: Path,
    *,
    shifts: int,
    overlap: float,
    segment: float | None,
    model_pack,
) -> dict:
    if dest.exists():
        data = np.load(dest)
        return {
            "seconds": float(data["seconds"]),
            "sample_rate": int(data["sample_rate"]),
            "cached": True,
        }
    from podcast_stripper.export import load_wav
    from podcast_stripper.separate import align_to_reference

    model, apply_model, convert_audio, torch, device = model_pack
    started = time.perf_counter()
    original, sample_rate = load_wav(wav_path)
    channels = original.shape[1]
    mix = torch.from_numpy(np.ascontiguousarray(original.T.astype(np.float32) / 32768.0))
    mix = convert_audio(mix, sample_rate, model.samplerate, model.audio_channels)
    random.seed(0)
    torch.manual_seed(0)
    np.random.seed(0)
    kwargs = {
        "device": device,
        "split": True,
        "overlap": overlap,
        "progress": False,
        "num_workers": 0,
        "shifts": shifts,
    }
    if segment is not None:
        kwargs["segment"] = segment
    with torch.no_grad():
        sources = apply_model(model, mix[None], **kwargs)[0]
    names = list(model.sources)
    vocals = sources[names.index("vocals")]
    other = sources.sum(dim=0) - vocals
    model_rate = int(model.samplerate)
    vocals = convert_audio(vocals, model_rate, sample_rate, channels)
    other = convert_audio(other, model_rate, sample_rate, channels)
    vocals_f = np.clip(vocals.detach().cpu().numpy().T, -1.0, 1.0).astype(np.float32)
    other_f = np.clip(other.detach().cpu().numpy().T, -1.0, 1.0).astype(np.float32)
    vocals_i16 = align_to_reference((vocals_f * 32767.0).astype(np.int16), original)
    other_i16 = align_to_reference((other_f * 32767.0).astype(np.int16), original)
    elapsed = time.perf_counter() - started
    dest.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        dest,
        vocals=vocals_i16.astype(np.float32) / 32768.0,
        other=other_i16.astype(np.float32) / 32768.0,
        vocals_float=align_to_reference(np.clip(vocals_f, -1, 1), original.astype(np.float32) / 32768.0).astype(np.float32),
        sample_rate=np.int32(sample_rate),
        seconds=np.float64(elapsed),
    )
    return {"seconds": elapsed, "sample_rate": sample_rate, "cached": False}


def stem_key(shifts: int, overlap: float, segment: float | None) -> str:
    seg = "default" if segment is None else f"{segment:.1f}"
    return f"s{shifts}_o{int(round(overlap * 100)):02d}_seg{seg}"


def load_stem(path: Path) -> dict:
    data = np.load(path)
    return {
        "vocals": data["vocals"].astype(np.float64),
        "other": data["other"].astype(np.float64),
        "vocals_float": data["vocals_float"].astype(np.float64) if "vocals_float" in data.files else None,
        "sample_rate": int(data["sample_rate"]),
        "seconds": float(data["seconds"]),
    }


def group_turns(segments: list[tuple[float, float, str]]) -> list[tuple[str, list[tuple[float, float]]]]:
    grouped: dict[str, list[tuple[float, float]]] = {}
    for start, end, speaker in segments:
        grouped.setdefault(speaker, []).append((start, end))
    ordered = []
    for speaker in sorted(grouped):
        turns = sorted(grouped[speaker])
        ordered.append((speaker, turns))
    return ordered


def merge_turns(turns: list[tuple[float, float]], gap: float) -> list[tuple[float, float]]:
    if not turns:
        return []
    ordered = sorted(turns)
    merged = [list(ordered[0])]
    for start, end in ordered[1:]:
        if start <= merged[-1][1] + gap:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    return [(item[0], item[1]) for item in merged]


def edge_fade(mask: np.ndarray, fade_samples: int) -> np.ndarray:
    """Lengthen the open/close of a gate without lowering the interior.

    The shipped fade is only a few dozen milliseconds and already soft, so a
    sample-to-sample diff never looks like a hard edge. Threshold first, then
    extend ramps into the closed side only.
    """
    if fade_samples <= 1:
        return mask
    open_region = mask >= 0.5
    padded = np.concatenate([[False], open_region, [False]])
    rises = np.flatnonzero(padded[1:] & ~padded[:-1])
    falls = np.flatnonzero(~padded[1:] & padded[:-1])
    out = mask.copy()
    for rise in rises:
        start = max(0, int(rise) - fade_samples)
        length = int(rise) - start
        if length <= 0:
            continue
        level = float(mask[min(mask.size - 1, int(rise))])
        ramp = np.linspace(0.0, level, length, endpoint=False)
        out[start:rise] = np.maximum(out[start:rise], ramp)
    for fall in falls:
        # `fall` is the first closed sample.
        end = min(out.size, int(fall) + fade_samples)
        length = end - int(fall)
        if length <= 0:
            continue
        level = float(mask[max(0, int(fall) - 1)])
        ramp = np.linspace(level, 0.0, length, endpoint=False)
        region = out[int(fall) : end]
        out[int(fall) : end] = np.maximum(region, ramp[: region.size])
    return np.clip(out, 0.0, 1.0)


def engine_gates(
    vocals: np.ndarray,
    other: np.ndarray,
    sample_rate: int,
    speaker_turns: list[list[tuple[float, float]]],
    *,
    use_music_mute: bool,
    fade_ms: float = 15,
    hold_ms: float = 100,
) -> tuple[list[np.ndarray], np.ndarray | None]:
    from podcast_stripper.cleanup import music_activity_mask, shared_speaker_gates

    length = vocals.shape[0]
    mute = None
    if use_music_mute:
        # Engine thresholds are relative, so float audio behaves like the int16 path.
        mute = music_activity_mask(other, sample_rate, vocals=vocals)
    gates = shared_speaker_gates(
        length,
        sample_rate,
        speaker_turns,
        mute_mask=mute,
        fade_ms=fade_ms,
        hold_ms=hold_ms,
    )
    return gates, mute


def smooth_mask_time(mask: np.ndarray, sample_rate: int, fade_ms: float) -> np.ndarray:
    fade = max(1, int(sample_rate * fade_ms / 1000.0))
    if fade <= 1:
        return mask
    kernel = np.hanning(fade * 2 + 1)
    kernel = kernel / kernel.sum()
    return np.clip(np.convolve(mask, kernel, mode="same"), 0.0, 1.0)


def phase_lock(
    original: np.ndarray,
    vocals: np.ndarray,
    other: np.ndarray,
    sample_rate: int,
    *,
    time_smooth: int,
    freq_smooth: int,
) -> np.ndarray:
    from scipy.ndimage import uniform_filter
    from scipy.signal import istft, stft

    mix = to_mono(original)
    vocal = to_mono(vocals)
    bed = to_mono(other)
    nperseg = 2048
    noverlap = 1536
    _f, _t, mix_z = stft(mix, fs=sample_rate, nperseg=nperseg, noverlap=noverlap)
    _, _, vocal_z = stft(vocal, fs=sample_rate, nperseg=nperseg, noverlap=noverlap)
    _, _, bed_z = stft(bed, fs=sample_rate, nperseg=nperseg, noverlap=noverlap)
    frames = min(mix_z.shape[1], vocal_z.shape[1], bed_z.shape[1])
    mix_z = mix_z[:, :frames]
    vocal_mag = np.abs(vocal_z[:, :frames])
    bed_mag = np.abs(bed_z[:, :frames])
    mask = vocal_mag / (vocal_mag + bed_mag + 1e-8)
    mask = uniform_filter(mask, size=(max(1, freq_smooth), max(1, time_smooth)), mode="nearest")
    mask = np.clip(mask, 0.0, 1.0)
    rebuilt = mask * np.abs(mix_z) * np.exp(1j * np.angle(mix_z))
    _t, wave = istft(rebuilt, fs=sample_rate, nperseg=nperseg, noverlap=noverlap)
    wave = np.asarray(wave, dtype=np.float64)
    if wave.size < mix.size:
        wave = np.pad(wave, (0, mix.size - wave.size))
    return wave[: mix.size]


def render_variant(
    original: np.ndarray,
    vocals: np.ndarray,
    other: np.ndarray,
    sample_rate: int,
    segments: list[tuple[float, float, str]],
    spec: dict,
) -> list[np.ndarray]:
    """Return one mono float track per speaker, engine sort order."""
    grouped = group_turns(segments)
    turns = []
    gap = float(spec.get("merge_gap", 0.0))
    for _speaker, speaker_turns in grouped:
        edited = merge_turns(speaker_turns, gap) if gap > 0 else list(speaker_turns)
        turns.append(edited)

    vocal_src = vocals
    if spec.get("phase_lock"):
        locked = phase_lock(
            original,
            vocals,
            other,
            sample_rate,
            time_smooth=int(spec.get("time_smooth", 5)),
            freq_smooth=int(spec.get("freq_smooth", 3)),
        )
        vocal_src = locked.reshape(-1, 1)
        if vocals.shape[1] > 1:
            vocal_src = np.repeat(vocal_src, vocals.shape[1], axis=1)

    dry = float(spec.get("dry", 0.0))
    if dry > 0:
        vocal_src = (1.0 - dry) * vocal_src + dry * original

    gates, _mute = engine_gates(
        vocal_src,
        other,
        sample_rate,
        turns,
        use_music_mute=bool(spec.get("music_mute", True)),
        fade_ms=float(spec.get("engine_fade_ms", 15)),
        hold_ms=float(spec.get("hold_ms", 100)),
    )
    fade_ms = float(spec.get("edge_fade_ms", 0.0))
    if fade_ms > 0:
        fade_samples = int(sample_rate * fade_ms / 1000.0)
        gates = [edge_fade(gate, fade_samples) for gate in gates]

    room_db = spec.get("room_db")
    room_mode = spec.get("room_mode", "none")
    room_gain = 0.0 if room_db is None else float(10 ** (float(room_db) / 20.0))
    if room_mode == "natural":
        room_gain = 1.0

    original_mono = to_mono(original)
    n = original_mono.size
    diar_masks = []
    for label, _speaker_turns in grouped:
        diar_masks.append(speaker_activity(segments, label, n, sample_rate).astype(np.float64))
    # Merged gaps count as still "this speaker" so a room bed is not laid under them.
    if float(spec.get("merge_gap", 0.0)) > 0:
        diar_masks = [(gate > 0.5).astype(np.float64) for gate in gates]
    fade_for_others = float(spec.get("room_fade_ms", 120))
    tracks = []
    n_speakers = max(1, len(gates))
    share = 1.0 if spec.get("room_share", "solo") == "solo" else 1.0 / n_speakers
    for index, gate in enumerate(gates):
        mono_vocal = to_mono(vocal_src * gate.reshape(-1, 1))
        bed = np.zeros_like(mono_vocal)
        if room_mode == "always":
            bed = original_mono * room_gain * np.clip(1.0 - gate, 0.0, 1.0)
        elif room_mode in {"global", "natural"}:
            others = np.zeros(n, dtype=np.float64)
            for other_index, mask in enumerate(diar_masks):
                if other_index != index:
                    others = np.maximum(others, mask)
            others = smooth_mask_time(others, sample_rate, fade_for_others)
            # Complementary with this speaker's own gate: vocal falls as the real room rises.
            # Stays shut while somebody else is the one talking.
            bed_env = np.clip(1.0 - gate, 0.0, 1.0) * np.clip(1.0 - others, 0.0, 1.0)
            bed = original_mono * room_gain * bed_env * share
        tracks.append(np.clip(mono_vocal + bed, -1.0, 1.0))
    return tracks


VARIANTS: list[dict] = [
    {"id": "current", "music_mute": True},
    {"id": "no-music-mute", "music_mute": False},
    {"id": "engine-fade-400", "engine_fade_ms": 400},
    {"id": "edge-fade-50", "edge_fade_ms": 50},
    {"id": "edge-fade-150", "edge_fade_ms": 150},
    {"id": "edge-fade-400", "edge_fade_ms": 400},
    {"id": "gap-merge-0.5", "merge_gap": 0.5},
    {"id": "gap-merge-1.0", "merge_gap": 1.0},
    {"id": "gap-merge-2.0", "merge_gap": 2.0},
    {"id": "room-global-20", "room_mode": "global", "room_db": -20, "edge_fade_ms": 120, "room_fade_ms": 120},
    {"id": "room-global-30", "room_mode": "global", "room_db": -30, "edge_fade_ms": 120, "room_fade_ms": 120},
    {"id": "room-global-40", "room_mode": "global", "room_db": -40, "edge_fade_ms": 120, "room_fade_ms": 120},
    {
        "id": "room-natural",
        "room_mode": "natural",
        "edge_fade_ms": 120,
        "room_fade_ms": 120,
    },
    {
        "id": "room-natural-shared",
        "room_mode": "natural",
        "room_share": "split",
        "edge_fade_ms": 120,
        "room_fade_ms": 120,
    },
    {"id": "room-always-30", "room_mode": "always", "room_db": -30, "edge_fade_ms": 120},
    {
        "id": "gap1-room-natural",
        "merge_gap": 1.0,
        "room_mode": "natural",
        "edge_fade_ms": 120,
        "room_fade_ms": 120,
    },
    {"id": "phase-lock", "phase_lock": True, "time_smooth": 5, "freq_smooth": 3},
    {"id": "phase-lock-wide", "phase_lock": True, "time_smooth": 9, "freq_smooth": 5},
    {"id": "dry-08", "dry": 0.08},
    {"id": "dry-15", "dry": 0.15},
    {"id": "dry-25", "dry": 0.25},
    {
        "id": "combo-room-phaselock",
        "phase_lock": True,
        "time_smooth": 5,
        "freq_smooth": 3,
        "room_mode": "natural",
        "edge_fade_ms": 120,
        "room_fade_ms": 120,
        "merge_gap": 0.8,
    },
    {
        "id": "combo-room-dry15",
        "dry": 0.15,
        "room_mode": "natural",
        "edge_fade_ms": 120,
        "room_fade_ms": 120,
        "merge_gap": 0.8,
    },
]


def db(values: np.ndarray) -> float:
    rms = float(np.sqrt(np.mean(np.square(values.astype(np.float64))))) if values.size else 0.0
    if rms < 1e-10:
        return -120.0
    return float(20.0 * np.log10(rms))


def speaker_activity(segments: list[tuple[float, float, str]], speaker: str, n: int, sr: int) -> np.ndarray:
    mask = np.zeros(n, dtype=bool)
    for start, end, label in segments:
        if label != speaker:
            continue
        a = max(0, int(round(start * sr)))
        b = min(n, int(round(end * sr)))
        if b > a:
            mask[a:b] = True
    return mask


def global_pause_spans(segments: list[tuple[float, float, str]], duration: float, min_gap: float = 1.0) -> list[tuple[float, float]]:
    edges = []
    for start, end, _speaker in segments:
        edges.append((start, 1))
        edges.append((end, -1))
    edges.sort()
    spans = []
    level = 0
    cursor = 0.0
    for time_s, delta in edges:
        if level == 0 and time_s - cursor >= min_gap and cursor > 0.05:
            spans.append((cursor, time_s))
        level += delta
        cursor = time_s
    if level == 0 and duration - cursor >= min_gap:
        spans.append((cursor, duration))
    return spans


def metric_bundle(
    tracks: list[np.ndarray],
    original: np.ndarray,
    vocals: np.ndarray,
    other: np.ndarray,
    segments: list[tuple[float, float, str]],
    sample_rate: int,
) -> dict:
    original_mono = to_mono(original)
    n = original_mono.size
    grouped = group_turns(segments)
    pauses = global_pause_spans(segments, n / sample_rate, min_gap=1.0)
    drops = []
    natural_drops = []
    room_match = []
    stem_room = []
    vocal_mono = to_mono(vocals)
    for span_start, span_end in pauses:
        speech_a = int(round((span_start - 0.70) * sample_rate))
        speech_b = int(round((span_start - 0.40) * sample_rate))
        if speech_b <= speech_a or speech_a < 0:
            continue
        mid_a = int(round((span_start + 0.25 * (span_end - span_start)) * sample_rate))
        mid_b = int(round((span_start + 0.75 * (span_end - span_start)) * sample_rate))
        mid_a = max(0, min(n, mid_a))
        mid_b = max(0, min(n, mid_b))
        if mid_b - mid_a < int(0.2 * sample_rate):
            continue
        if db(original_mono[mid_a:mid_b]) < -80.0:
            # Digital silence already in the file, not a room-tone pause.
            continue
        natural = db(original_mono[speech_a:speech_b]) - db(original_mono[mid_a:mid_b])
        natural_drops.append(natural)
        stem_room.append(db(vocal_mono[mid_a:mid_b]) - db(original_mono[mid_a:mid_b]))
        # The speaker who was talking just before the pause.
        owner = None
        best_end = -1.0
        for label, _turns in grouped:
            for start, end in _turns:
                if end <= span_start + 0.05 and end > best_end:
                    best_end = end
                    owner = label
        if owner is None:
            continue
        index = [label for label, _turns in grouped].index(owner)
        if index >= len(tracks):
            continue
        track = tracks[index]
        drops.append(db(track[speech_a:speech_b]) - db(track[mid_a:mid_b]))
        room_match.append(db(track[mid_a:mid_b]) - db(original_mono[mid_a:mid_b]))

    hop = max(1, int(0.02 * sample_rate))
    abrupt = 0
    frames_n = 0
    for track in tracks:
        usable = track.size - (track.size % hop)
        if usable < hop * 2:
            continue
        frames = track[:usable].reshape(-1, hop)
        power = np.maximum(np.mean(frames * frames, axis=1), 1e-20)
        levels = 10.0 * np.log10(power)
        frames_n += int(levels.size)
        abrupt += int(np.count_nonzero(np.diff(levels) < -15.0))

    # Crosstalk: exclusive regions of the other speakers, from diarization.
    leak_bits = []
    voice_delta = []
    for index, (label, _turns) in enumerate(grouped):
        if index >= len(tracks):
            break
        mine = speaker_activity(segments, label, n, sample_rate)
        others = np.zeros(n, dtype=bool)
        for other_label, _other_turns in grouped:
            if other_label == label:
                continue
            others |= speaker_activity(segments, other_label, n, sample_rate)
        exclusive_other = others & ~mine
        if int(exclusive_other.sum()) > sample_rate:
            leak_bits.append(db(tracks[index][exclusive_other]) - db(original_mono[exclusive_other]))
        exclusive_mine = mine & ~others
        if int(exclusive_mine.sum()) > sample_rate:
            voice_delta.append(db(tracks[index][exclusive_mine]))

    # Swirl proxy on the vocal interior, away from edit edges.
    flux_vals = []
    speckle_vals = []
    from scipy.signal import stft

    for index, (label, _turns) in enumerate(grouped):
        if index >= len(tracks):
            break
        mine = speaker_activity(segments, label, n, sample_rate)
        # Erode 150 ms so fades and breaths do not dominate the proxy.
        erode = int(0.15 * sample_rate)
        if erode > 0 and mine.any():
            kernel = np.ones(erode, dtype=np.int32)
            # Keep samples whose whole neighborhood is active.
            padded = np.convolve(mine.astype(np.int32), kernel, mode="same")
            mine = padded >= erode
        if int(mine.sum()) < sample_rate:
            continue
        piece = tracks[index].copy()
        piece[~mine] = 0.0
        _f, _t, spec = stft(piece, fs=sample_rate, nperseg=2048, noverlap=1536)
        mag = np.abs(spec)
        if mag.shape[1] < 8:
            continue
        denom = np.linalg.norm(mag[:, 1:], axis=0) + 1e-9
        flux = np.linalg.norm(np.diff(mag, axis=1), axis=0) / denom
        from scipy.ndimage import median_filter

        smooth = median_filter(mag, size=(1, 7))
        speckle = np.maximum(mag - smooth, 0.0)
        # Weight frames that actually contain energy.
        frame_energy = mag.mean(axis=0)
        hot = frame_energy > np.percentile(frame_energy, 60)
        if int(hot.sum()) < 5:
            continue
        flux_vals.append(float(np.mean(flux[hot[1:]])))
        speckle_vals.append(float(np.mean(speckle[:, hot]) / (np.mean(mag[:, hot]) + 1e-9)))

    stem = vocals + other
    if stem.shape != original.shape:
        stem = stem[:, : original.shape[1]]
    err = original - stem
    recon = 10.0 * np.log10((np.mean(original**2) + 1e-20) / (np.mean(err**2) + 1e-20))

    return {
        "pause_drop_db": round(float(np.mean(drops)), 2) if drops else None,
        "natural_pause_drop_db": round(float(np.mean(natural_drops)), 2) if natural_drops else None,
        "room_match_db": round(float(np.mean(room_match)), 2) if room_match else None,
        "vocal_stem_room_match_db": round(float(np.mean(stem_room)), 2) if stem_room else None,
        "pause_count": len(drops),
        "abrupt_drops": abrupt,
        "abrupt_per_min": round(abrupt / max(1e-6, (n / sample_rate) / 60.0), 2),
        "crosstalk_db": round(float(np.mean(leak_bits)), 2) if leak_bits else None,
        "voice_level_db": round(float(np.mean(voice_delta)), 2) if voice_delta else None,
        "spectral_flux": round(float(np.mean(flux_vals)), 4) if flux_vals else None,
        "musical_noise": round(float(np.mean(speckle_vals)), 4) if speckle_vals else None,
        "stem_recon_db": round(float(recon), 2),
    }


def listen_span(excerpt: dict, duration: float) -> tuple[float, float]:
    event_mid = 0.5 * (float(excerpt.get("event_start", excerpt["start"])) + float(excerpt.get("event_end", excerpt["end"])))
    rel = event_mid - float(excerpt["start"])
    start = rel - LISTEN_SECONDS / 2.0
    start = max(0.0, min(start, max(0.0, duration - LISTEN_SECONDS)))
    return round(start, 3), round(min(duration, start + LISTEN_SECONDS), 3)


def write_listen(audio: np.ndarray, sample_rate: int, dest: Path) -> None:
    from scipy.io import wavfile

    dest.parent.mkdir(parents=True, exist_ok=True)
    temp = dest.with_suffix(".f32.wav")
    clipped = np.clip(audio, -1.0, 1.0).astype(np.float32)
    wavfile.write(temp, sample_rate, clipped)
    run_ffmpeg(["-i", str(temp), "-ar", "48000", "-ac", "1", "-c:a", "pcm_s16le", str(dest)])
    temp.unlink(missing_ok=True)


def stage_probe(src: Path) -> dict:
    SCRATCH.mkdir(parents=True, exist_ok=True)
    duration, rate, channels = source_duration_and_rate(src)
    log(f"Source {src.name}: {duration:.1f}s, {rate} Hz, {channels} ch")
    analysis, analysis_rate = decode_analysis(src, SCRATCH / "analysis.wav")
    features = frame_features(analysis, analysis_rate)
    choices = pick_candidates(features, duration)
    if choices.get("music") is None:
        music = bass_music_window(analysis, analysis_rate, duration, choices.get("pause"))
        if music is not None:
            choices["music"] = music
            log("Music window came from the bass-heavy opening, not from stereo width.")
    choices["source"] = str(src)
    choices["duration"] = duration
    choices["sample_rate"] = rate
    choices["channels"] = channels
    (SCRATCH / "candidates.json").write_text(json.dumps(choices, indent=2), encoding="utf-8")
    log(
        "Probe pauses={n} music_window={m} talk_candidates={t}".format(
            n=choices["pause_count"],
            m="yes" if choices["music"] else "no",
            t=len(choices["talk_candidates"]),
        )
    )
    return choices


def ensure_pipeline():
    from podcast_stripper.diarize import load_pipeline
    from podcast_stripper.model_bundle import find_local_model

    local = find_local_model()
    if local is None:
        raise RuntimeError("Bundled speaker model was not found. Refusing to download or use a token.")
    log(f"Speaker model: {local}")
    pipeline, device = load_pipeline(model_path=local)
    log(f"Diarization device: {device}")
    return pipeline


def stage_prepare_and_diarize(pipeline) -> list[dict]:
    choices = json.loads((SCRATCH / "candidates.json").read_text(encoding="utf-8"))
    src = Path(choices["source"])
    jobs = []
    if choices.get("pause"):
        jobs.append(choices["pause"])
    if choices.get("music"):
        jobs.append(choices["music"])
    jobs.extend(choices.get("talk_candidates") or [])
    prepared = []
    for job in jobs:
        dest = SCRATCH / "excerpts" / f"{job['id']}.wav"
        extract_excerpt(src, dest, float(job["start"]), float(job["end"]) - float(job["start"]))
        rate, ch, frames = wav_info(dest)
        cache = dest.with_suffix(".segments.json")
        started = time.perf_counter()
        if cache.exists():
            segments = [tuple(item) for item in json.loads(cache.read_text(encoding="utf-8"))]
            elapsed = 0.0
            log(f"Diarize cache {job['id']}")
        else:
            segments = diarize_excerpt(dest, pipeline, num_speakers=2)
            cache.write_text(json.dumps(segments), encoding="utf-8")
            elapsed = time.perf_counter() - started
            log(f"Diarize {job['id']} in {elapsed:.1f}s, turns={len(segments)}")
        stats = overlap_stats(segments)
        record = {
            **job,
            "wav": str(dest),
            "sample_rate": rate,
            "channels": ch,
            "frames": frames,
            "audio_seconds": frames / float(rate),
            "diarize_seconds": elapsed,
            "segments": segments,
            "overlap": stats,
        }
        prepared.append(record)
        log(f"  {job['id']} speakers={stats['speakers']} overlap={stats['overlap_ratio']:.1%} {job['why']}")
    # Lock the three excerpts.
    pause = next((item for item in prepared if item["role"] == "pauses"), None)
    music = next((item for item in prepared if item["role"] == "music"), None)
    talks = [item for item in prepared if item["role"] == "crosstalk-candidate"]
    talks.sort(key=lambda item: item["overlap"]["overlap_ratio"], reverse=True)
    chosen = []
    if pause:
        chosen.append(pause)
    if talks:
        talk = talks[0]
        talk["id"] = "B-crosstalk"
        talk["role"] = "crosstalk"
        talk["why"] = (
            f"most overlap of the dense-speech windows ({talk['overlap']['overlap_ratio']:.0%} of speech)"
        )
        chosen.append(talk)
    if music:
        chosen.append(music)
    (SCRATCH / "chosen.json").write_text(json.dumps(chosen), encoding="utf-8")
    log("Chosen: " + ", ".join(item["id"] for item in chosen))
    return chosen


def stage_separate(chosen: list[dict], settings: list[tuple[int, float, float | None]]) -> None:
    model_pack = load_demucs()
    model = model_pack[0]
    log(
        f"Demucs htdemucs sr={model.samplerate} segment={model.models[0].segment} "
        f"sources={list(model.sources)}"
    )
    for shifts, overlap, segment in settings:
        key = stem_key(shifts, overlap, segment)
        for excerpt in chosen:
            wav = Path(excerpt["wav"])
            dest = SCRATCH / "stems" / excerpt["id"] / f"{key}.npz"
            log(f"Separate {excerpt['id']} {key}")
            try:
                info = separate_file(
                    wav,
                    dest,
                    shifts=shifts,
                    overlap=overlap,
                    segment=segment,
                    model_pack=model_pack,
                )
            except Exception as exc:
                log(f"Separate failed {excerpt['id']} {key}: {type(exc).__name__}: {exc}")
                continue
            minutes = excerpt["audio_seconds"] / 60.0
            log(
                f"  {key} {info['seconds']:.1f}s "
                f"({info['seconds'] / max(minutes, 1e-6):.1f}s per minute)"
                f"{' cached' if info['cached'] else ''}"
            )
    del model_pack


def evaluate(chosen: list[dict], stem: str, variants: list[dict]) -> list[dict]:
    rows = []
    for excerpt in chosen:
        stem_path = SCRATCH / "stems" / excerpt["id"] / f"{stem}.npz"
        if not stem_path.exists():
            log(f"Missing stem {stem_path}")
            continue
        loaded = load_stem(stem_path)
        original, sample_rate = load_float(Path(excerpt["wav"]))
        segments = [tuple(item) for item in excerpt["segments"]]
        minutes = excerpt["audio_seconds"] / 60.0
        for spec in variants:
            started = time.perf_counter()
            tracks = render_variant(
                original,
                loaded["vocals"],
                loaded["other"],
                sample_rate,
                segments,
                spec,
            )
            elapsed = time.perf_counter() - started
            metrics = metric_bundle(
                tracks,
                original,
                loaded["vocals"],
                loaded["other"],
                segments,
                sample_rate,
            )
            current_level = None
            rows.append(
                {
                    "excerpt": excerpt["id"],
                    "stem": stem,
                    "variant": spec["id"],
                    "separate_seconds": loaded["seconds"],
                    "separate_s_per_min": round(loaded["seconds"] / max(minutes, 1e-6), 2),
                    "render_seconds": round(elapsed, 3),
                    "diarize_seconds": excerpt.get("diarize_seconds") or 0,
                    **metrics,
                }
            )
            _ = current_level
            log(
                f"{excerpt['id']} {spec['id']}: drop={metrics['pause_drop_db']} "
                f"room={metrics['room_match_db']} leak={metrics['crosstalk_db']} "
                f"flux={metrics['spectral_flux']} noise={metrics['musical_noise']} "
                f"abrupt={metrics['abrupt_drops']}"
            )
    return rows


def stage_pack() -> None:
    """Write the short listening files. Uses stems and diarization already cached."""
    chosen = json.loads((SCRATCH / "chosen.json").read_text(encoding="utf-8"))
    variants = [
        ("1-current", {"music_mute": True}),
        (
            "2-natural-room",
            {"room_mode": "natural", "edge_fade_ms": 180, "room_fade_ms": 150, "music_mute": True},
        ),
        ("3-hold-open-2s", {"merge_gap": 2.0, "music_mute": True}),
    ]
    PACK_DIR.mkdir(parents=True, exist_ok=True)
    notes = []
    for excerpt in chosen:
        original, sample_rate = load_float(Path(excerpt["wav"]))
        loaded = load_stem(SCRATCH / "stems" / excerpt["id"] / f"{stem_key(1, 0.25, None)}.npz")
        segments = [tuple(item) for item in excerpt["segments"]]
        duration = original.shape[0] / float(sample_rate)
        rel_start, rel_end = _listen_bounds(excerpt, duration)
        a = int(round(rel_start * sample_rate))
        b = int(round(rel_end * sample_rate))
        labels = [label for label, _turns in group_turns(segments)]
        rendered = {}
        for name, spec in variants:
            rendered[name] = render_variant(
                original,
                loaded["vocals"],
                loaded["other"],
                sample_rate,
                segments,
                spec,
            )
        for name, tracks in rendered.items():
            for index, track in enumerate(tracks):
                dest = PACK_DIR / f"{excerpt['id']}_{name}_Speaker{index + 1}.wav"
                write_listen(track[a:b], sample_rate, dest)
                log(f"Wrote {dest.name}")
        pause_at = None
        if excerpt.get("event_start") is not None and excerpt["role"] == "pauses":
            pause_at = (
                float(excerpt["event_start"]) - float(excerpt["start"]) - rel_start,
                float(excerpt["event_end"]) - float(excerpt["start"]) - rel_start,
            )
        notes.append(
            {
                "id": excerpt["id"],
                "role": excerpt["role"],
                "why": excerpt.get("why"),
                "source_start": excerpt["start"],
                "listen_source_start": round(float(excerpt["start"]) + rel_start, 2),
                "listen_source_end": round(float(excerpt["start"]) + rel_end, 2),
                "pause_in_clip": None
                if pause_at is None
                else [round(pause_at[0], 1), round(pause_at[1], 1)],
                "speakers": labels,
                "overlap": excerpt.get("overlap"),
            }
        )
    readme = _readme(notes)
    (PACK_DIR / "README.txt").write_text(readme, encoding="utf-8")
    log(f"Listening pack: {PACK_DIR}")


def _listen_bounds(excerpt: dict, duration: float) -> tuple[float, float]:
    role = excerpt.get("role")
    if role == "pauses":
        center = 0.5 * (float(excerpt["event_start"]) + float(excerpt["event_end"])) - float(excerpt["start"])
    elif role == "music":
        center = 36.0
    else:
        center = 28.0
    start = max(0.0, min(center - LISTEN_SECONDS / 2.0, max(0.0, duration - LISTEN_SECONDS)))
    return round(start, 3), round(min(duration, start + LISTEN_SECONDS), 3)


def _clock(seconds: float) -> str:
    seconds = max(0, int(round(seconds)))
    return f"{seconds // 60}:{seconds % 60:02d}"


def _readme(notes: list[dict]) -> str:
    lines = [
        "TheStrip listening test — 14 Nov 2026",
        "",
        "These are short speaker tracks made from The Macro Dirt Podcast",
        "(Veterans Day). Nothing here changes the apps. Play them in any",
        "player. Each file is one speaker, 48 kHz, about 48 seconds.",
        "",
        "Same three versions on every clip:",
        "",
        "  1-current",
        "      What TheStrip does today. When someone stops talking, that",
        "      track falls to silence.",
        "",
        "  2-natural-room",
        "      The one to compare against current. In a real pause, the",
        "      track keeps the room sound from the original recording",
        "      instead of going silent. Words should stay the same loudness.",
        "",
        "  3-hold-open-2s",
        "      Another idea: don't close a speaker's track for a gap shorter",
        "      than about 2 seconds. On ordinary talking this also keeps the",
        "      room. On the music opening it can let the wrong sound through.",
        "",
        "Listen for: does the quiet moment still drop to a hole, or does the",
        "room stay? And do you hear the other person leak onto the track?",
        "The watery / swirly tone, if you hear it, was almost unchanged by",
        "the separation settings we tried, so there is no fourth version for that.",
        "",
    ]
    blurbs = {
        "A-pauses": (
            "A pause in the conversation, a bit under 2 seconds, with talking",
            "on both sides. The hole, if it is there, is about {when} into the file.",
        ),
        "B-crosstalk": (
            "Back-and-forth between the two hosts, including a few moments",
            "where they step on each other. Listen for the other voice leaking in.",
        ),
        "C-music": (
            "The opening music, then a gap that is already silent in the",
            "recording itself (around 0:38 of the episode), then the hosts",
            "start. The dead gap in the file is not the gate. Listen to the",
            "music and to the voices after it.",
        ),
    }
    for note in notes:
        lines.append(note["id"])
        lines.append(
            f"  From about {_clock(note['listen_source_start'])} to {_clock(note['listen_source_end'])} in the episode."
        )
        if note["id"] == "A-pauses" and note.get("pause_in_clip"):
            when = _clock(note["pause_in_clip"][0])
            text = " ".join(blurbs["A-pauses"]).format(when=when)
        else:
            text = " ".join(blurbs.get(note["id"], (note.get("why") or "",)))
        lines.append("  " + text)
        lines.append("  Both speakers, in all three versions.")
        lines.append("")
    lines.append("Speaker 1 and Speaker 2 are the two people the detector found.")
    lines.append("They are not named Tony and Jared here; match them by ear.")
    lines.append("")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="TheStrip offline quality experiments")
    parser.add_argument(
        "stage",
        nargs="?",
        default="all",
        choices=["probe", "diarize", "separate", "render", "pack", "all"],
    )
    parser.add_argument("--source", type=Path, default=SOURCE)
    args = parser.parse_args()
    if not args.source.is_file():
        log(f"BLOCKED missing source {args.source}")
        return 2
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    if args.stage == "pack":
        stage_pack()
        return 0
    if args.stage in {"probe", "all"}:
        choices = stage_probe(args.source)
        if choices.get("music") is None:
            log("No obvious music-under-voice window in this file.")
    if args.stage == "probe":
        return 0
    pipeline = ensure_pipeline()
    chosen = stage_prepare_and_diarize(pipeline)
    del pipeline
    if args.stage == "diarize":
        return 0
    settings = [
        (1, 0.25, None),
        (2, 0.25, None),
        (1, 0.50, None),
    ]
    if args.stage in {"separate", "all"}:
        stage_separate(chosen, settings)
    if args.stage == "separate":
        return 0
    rows = []
    rows.extend(evaluate(chosen, stem_key(1, 0.25, None), VARIANTS))
    # Swirl separations: current gate plus the room/phase combo, not every gate.
    swirl_variants = [spec for spec in VARIANTS if spec["id"] in {"current", "combo-room-phaselock", "phase-lock"}]
    rows.extend(evaluate(chosen, stem_key(2, 0.25, None), swirl_variants))
    rows.extend(evaluate(chosen, stem_key(1, 0.50, None), swirl_variants))
    out = REPORT_DIR / "strip-quality-metrics.json"
    out.write_text(json.dumps({"rows": rows, "chosen": chosen}, indent=2), encoding="utf-8")
    log(f"Wrote {out}")
    return 0


def pick_from_saved_analysis(src: Path) -> dict:
    duration, rate, channels = source_duration_and_rate(src)
    analysis, analysis_rate = decode_analysis(src, SCRATCH / "analysis.wav")
    features = frame_features(analysis, analysis_rate)
    choices = pick_candidates(features, duration)
    choices["source"] = str(src)
    choices["duration"] = duration
    choices["sample_rate"] = rate
    choices["channels"] = channels
    return choices


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        log(f"FAILED {type(exc).__name__}: {exc}")
        raise
