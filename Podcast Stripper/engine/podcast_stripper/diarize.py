from __future__ import annotations

import os
import threading
from pathlib import Path
from typing import Callable

from podcast_stripper.progress import heartbeat
from podcast_stripper.token_store import resolve_token

MODEL_ID = "pyannote/speaker-diarization-community-1"
Segment = tuple[float, float, str]
ProgressFn = Callable[[str, float, str], None]

# Single sweet-spot profile (former "stronger"): exact speaker count when set,
# mild short-turn cleanup, community-1 middle clustering knobs.
DIARIZE_PROFILE = {
    "threshold": 0.50,
    "Fa": 0.07,
    "Fb": 0.8,
    "short_turn_seconds": 0.35,
}


class DiarizationError(RuntimeError):
    def __init__(self, message: str, code: str = "diarization_failed") -> None:
        super().__init__(message)
        self.code = code


def resolve_speaker_count_kwargs(
    *,
    num_speakers: int | None = None,
    min_speakers: int | None = None,
    max_speakers: int | None = None,
) -> dict[str, int]:
    """Map Speakers UI/CLI into pyannote kwargs. Exact N when a count is given."""
    if min_speakers is not None or max_speakers is not None:
        kwargs: dict[str, int] = {}
        if num_speakers is not None:
            kwargs["num_speakers"] = num_speakers
        if min_speakers is not None:
            kwargs["min_speakers"] = min_speakers
        if max_speakers is not None:
            kwargs["max_speakers"] = max_speakers
        return kwargs

    if num_speakers is None:
        return {}
    return {"num_speakers": num_speakers}


def pick_device():
    import torch

    if torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def load_pipeline(token: str):
    import torch
    from pyannote.audio import Pipeline

    os.environ.setdefault("PYANNOTE_METRICS_ENABLED", "0")
    pipeline = Pipeline.from_pretrained(MODEL_ID, token=token)
    _apply_diarize_settings(pipeline)
    device = pick_device()
    try:
        pipeline.to(device)
    except Exception:
        pipeline.to(torch.device("cpu"))
        device = torch.device("cpu")
    return pipeline, str(device)


def iter_turns(diarization) -> list[Segment]:
    segments: list[Segment] = []
    if diarization is None:
        return segments

    if hasattr(diarization, "itertracks"):
        for turn, _, speaker in diarization.itertracks(yield_label=True):
            segments.append((float(turn.start), float(turn.end), str(speaker)))
        return segments

    for item in diarization:
        if not isinstance(item, tuple):
            continue
        if len(item) == 2:
            turn, speaker = item
            segments.append((float(turn.start), float(turn.end), str(speaker)))
        elif len(item) >= 3:
            turn, _, speaker = item[0], item[1], item[2]
            segments.append((float(turn.start), float(turn.end), str(speaker)))
    return segments


def load_waveform(wav_path: Path):
    """Load a WAV as the in-memory dict pyannote accepts, skipping torchcodec/FFmpeg dylibs."""
    import numpy as np
    import torch

    from podcast_stripper.export import load_wav

    audio, sample_rate = load_wav(wav_path)
    waveform = torch.from_numpy(audio.T.astype(np.float32) / 32768.0)
    return {"waveform": waveform, "sample_rate": int(sample_rate)}


def _apply_diarize_settings(pipeline) -> None:
    params = {
        "segmentation": {"min_duration_off": 0.0},
        "clustering": {
            "threshold": DIARIZE_PROFILE["threshold"],
            "Fa": DIARIZE_PROFILE["Fa"],
            "Fb": DIARIZE_PROFILE["Fb"],
        },
    }
    try:
        pipeline.instantiate(params)
    except Exception:
        clustering = getattr(pipeline, "clustering", None)
        if clustering is not None:
            for key in ("threshold", "Fa", "Fb"):
                if hasattr(clustering, key):
                    setattr(clustering, key, DIARIZE_PROFILE[key])


def prune_tiny_speakers(
    segments: list[Segment],
    *,
    min_seconds: float = 3.0,
    min_ratio: float = 0.03,
) -> list[Segment]:
    """Drop leftover clusters that are almost empty (noise treated as a speaker)."""
    totals: dict[str, float] = {}
    for start, end, speaker in segments:
        totals[speaker] = totals.get(speaker, 0.0) + max(0.0, end - start)
    if len(totals) <= 1:
        return segments
    speech = sum(totals.values()) or 1.0
    cutoff = max(min_seconds, min_ratio * speech)
    keep = {speaker for speaker, duration in totals.items() if duration >= cutoff}
    if not keep:
        keep = {max(totals, key=totals.get)}
    if keep == set(totals):
        return segments
    return [(start, end, speaker) for start, end, speaker in segments if speaker in keep]


def merge_adjacent_segments(segments: list[Segment], *, gap: float = 0.05) -> list[Segment]:
    if not segments:
        return []
    ordered = sorted(segments, key=lambda item: (item[0], item[1], item[2]))
    merged: list[Segment] = [ordered[0]]
    for start, end, speaker in ordered[1:]:
        prev_start, prev_end, prev_speaker = merged[-1]
        if speaker == prev_speaker and start <= prev_end + gap:
            merged[-1] = (prev_start, max(prev_end, end), speaker)
        else:
            merged.append((start, end, speaker))
    return merged


def reassign_short_interruptions(
    segments: list[Segment],
    max_seconds: float,
) -> list[Segment]:
    """Reassign very short turns to the nearest neighboring longer speaker."""
    if max_seconds <= 0 or len(segments) < 2:
        return segments

    ordered = sorted(segments, key=lambda item: (item[0], item[1]))
    result: list[Segment] = list(ordered)

    for index, (start, end, speaker) in enumerate(ordered):
        duration = end - start
        if duration >= max_seconds:
            continue

        candidates: list[tuple[float, float, str]] = []
        if index > 0:
            prev_start, prev_end, prev_speaker = ordered[index - 1]
            if prev_speaker != speaker:
                candidates.append(
                    (abs(start - prev_end), -(prev_end - prev_start), prev_speaker)
                )
        if index + 1 < len(ordered):
            next_start, next_end, next_speaker = ordered[index + 1]
            if next_speaker != speaker:
                candidates.append(
                    (abs(next_start - end), -(next_end - next_start), next_speaker)
                )
        if not candidates:
            continue
        candidates.sort()
        result[index] = (start, end, candidates[0][2])

    return merge_adjacent_segments(result)


def extract_segments(output) -> list[Segment]:
    # Regular diarization is better for track splitting. Exclusive mode is meant for
    # lining up transcripts and can park two people on one label.
    regular = getattr(output, "speaker_diarization", output)
    exclusive = getattr(output, "exclusive_speaker_diarization", None)
    segments = iter_turns(regular) or iter_turns(exclusive)
    if not segments:
        raise DiarizationError(
            "The model did not find any speakers. Try a longer clip, or set the speaker count.",
            "no_speakers",
        )
    segments = prune_tiny_speakers(segments)
    segments = reassign_short_interruptions(
        segments, float(DIARIZE_PROFILE["short_turn_seconds"])
    )
    return segments


class DiarizeProgressHook:
    """Forward pyannote step updates to the Mac app so the bar keeps moving."""

    def __init__(self, on_progress: ProgressFn | None, *, start: float = 32.0, end: float = 78.0) -> None:
        self.on_progress = on_progress
        self.start = start
        self.end = end
        self._lock = threading.Lock()

    def __call__(self, step_name, step_artifact, file=None, total=None, completed=None, **kwargs) -> None:
        if self.on_progress is None:
            return
        label = str(step_name or "speakers").replace("_", " ")
        if total:
            frac = max(0.0, min(1.0, float(completed or 0) / float(total)))
            extra = f" {int(completed or 0)}/{int(total)}"
        else:
            frac = 0.0
            extra = ""
        percent = self.start + frac * (self.end - self.start)
        with self._lock:
            self.on_progress("diarize", percent, f"Detecting who spoke when ({label}{extra})…")


def run_diarization(
    wav_path: Path,
    *,
    token: str | None = None,
    num_speakers: int | None = None,
    min_speakers: int | None = None,
    max_speakers: int | None = None,
    on_progress: ProgressFn | None = None,
) -> list[Segment]:
    resolved = resolve_token(token)
    if on_progress:
        on_progress("diarize", 18, "Loading speaker model…")
    try:
        with heartbeat(
            on_progress,
            stage="diarize",
            start_percent=18,
            cap_percent=28,
            message="Still loading the speaker model…",
        ):
            pipeline, _device = load_pipeline(resolved)
    except Exception as exc:
        message = str(exc)
        if "401" in message or "gated" in message.lower() or "restricted" in message.lower():
            raise DiarizationError(
                "Could not download the speaker model. Accept the terms at "
                "https://huggingface.co/pyannote/speaker-diarization-community-1 "
                "and check that your Hugging Face token is a read token.",
                "model_access",
            ) from exc
        raise DiarizationError(f"Could not load the speaker model: {exc}") from exc

    kwargs = resolve_speaker_count_kwargs(
        num_speakers=num_speakers,
        min_speakers=min_speakers,
        max_speakers=max_speakers,
    )

    audio_file = load_waveform(wav_path)
    samples = int(audio_file["waveform"].shape[-1])
    minutes = max(1, int(round(samples / float(audio_file["sample_rate"]) / 60.0)))
    auto_note = ""
    if min_speakers is not None and max_speakers is not None:
        auto_note = " Auto is slower than picking 2 or 3."
    if on_progress:
        on_progress(
            "diarize",
            30,
            f"Detecting who spoke when on a {minutes}-minute episode.{auto_note}",
        )

    hook = DiarizeProgressHook(on_progress)
    try:
        with heartbeat(
            on_progress,
            stage="diarize",
            start_percent=30,
            cap_percent=78,
            interval=3.0,
            message="Still detecting who spoke when…",
        ):
            try:
                output = pipeline(audio_file, hook=hook, **kwargs)
            except TypeError:
                output = pipeline(audio_file, **kwargs)
    except Exception as exc:
        raise DiarizationError(_friendly_failure(exc)) from exc

    if on_progress:
        on_progress("diarize", 82, "Assigning speech to speakers…")
    segments = extract_segments(output)

    try:
        from podcast_stripper.consistency import refine_speaker_consistency

        refined, _stats = refine_speaker_consistency(
            segments,
            pipeline=pipeline,
            audio_file=audio_file,
            on_progress=on_progress,
        )
        segments = merge_adjacent_segments(refined)
        segments = reassign_short_interruptions(
            segments, float(DIARIZE_PROFILE["short_turn_seconds"])
        )
    except Exception as exc:
        # Never fail the job because the consistency pass broke.
        import sys

        sys.stderr.write(f"voice consistency skipped: {type(exc).__name__}: {exc}\n")

    return segments


def _friendly_failure(exc: Exception) -> str:
    text = str(exc)
    if "libtorchcodec" in text or "Could not load libtorchcodec" in text:
        return (
            "Speaker detection could not read the audio (missing FFmpeg libraries). "
            "Update Podcast Stripper and try again."
        )
    compact = text.split("The following exceptions were raised", 1)[0].strip()
    if len(compact) > 280:
        compact = compact[:280].rstrip() + "…"
    return f"Speaker detection failed: {compact or exc.__class__.__name__}"
