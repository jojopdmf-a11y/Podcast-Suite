from __future__ import annotations

import inspect
import os
import sys
from pathlib import Path
from typing import Callable

import numpy as np

from podcast_stripper.export import load_wav, save_wav
from podcast_stripper.progress import heartbeat

ProgressFn = Callable[[str, float, str], None]


class SeparationError(RuntimeError):
    def __init__(self, message: str, code: str = "separation_failed") -> None:
        super().__init__(message)
        self.code = code


def _pick_device():
    """Choose a Demucs device that actually finishes on a Mac.

    Apple Silicon MPS + Demucs often hangs inside Metal with no error, which is
    what made the app look frozen at "Pulling music…". CPU is slower but it
    returns. Override with PODCAST_STRIPPER_DEMUCS_DEVICE=cpu|mps|cuda.
    """
    import torch

    override = os.environ.get("PODCAST_STRIPPER_DEMUCS_DEVICE", "").strip().lower()
    if override in {"cpu", "mps", "cuda"}:
        if override == "mps" and not torch.backends.mps.is_available():
            return torch.device("cpu")
        if override == "cuda" and not torch.cuda.is_available():
            return torch.device("cpu")
        return torch.device(override)

    if sys.platform == "darwin":
        return torch.device("cpu")
    if torch.cuda.is_available():
        return torch.device("cuda")
    if torch.backends.mps.is_available():
        return torch.device("cpu")
    return torch.device("cpu")


def _apply_model_kwargs(apply_model, device) -> dict:
    """Demucs 4.x accepts num_workers; keep it at 0 so Mac never deadlocks a pool."""
    kwargs: dict = {
        "device": device,
        "split": True,
        "overlap": 0.25,
        "progress": False,
    }
    try:
        params = inspect.signature(apply_model).parameters
    except (TypeError, ValueError):
        params = {}
    if "num_workers" in params:
        kwargs["num_workers"] = 0
    if "shifts" in params:
        kwargs["shifts"] = 1
    return kwargs


def _align_channels(audio: np.ndarray, channels: int) -> np.ndarray:
    if audio.ndim == 1:
        audio = audio.reshape(-1, 1)
    have = audio.shape[1]
    if have == channels:
        return audio
    if channels == 1:
        return np.mean(audio.astype(np.float32), axis=1, keepdims=True).astype(audio.dtype)
    if have == 1:
        return np.repeat(audio, channels, axis=1)
    extra = np.zeros((audio.shape[0], channels), dtype=audio.dtype)
    extra[:, : min(have, channels)] = audio[:, : min(have, channels)]
    return extra


def align_to_reference(audio: np.ndarray, reference: np.ndarray) -> np.ndarray:
    audio = _align_channels(audio, reference.shape[1])
    target = reference.shape[0]
    if audio.shape[0] == target:
        return audio
    if audio.shape[0] < target:
        pad = np.zeros((target - audio.shape[0], audio.shape[1]), dtype=audio.dtype)
        return np.concatenate([audio, pad], axis=0)
    return audio[:target]


def separate_vocals(
    original_wav: Path,
    work_dir: Path,
    *,
    on_progress: ProgressFn | None = None,
    heartbeat_interval: float = 3.0,
) -> tuple[Path, Path]:
    """Split a mix into vocals and everything else (music, beds, sound effects)."""
    import torch

    try:
        from podcast_stripper.token_store import resolve_token

        os.environ.setdefault("HF_TOKEN", resolve_token())
    except Exception:
        pass

    try:
        from demucs.apply import apply_model
        from demucs.audio import convert_audio
        from demucs.pretrained import get_model
    except ImportError as exc:
        raise SeparationError(
            "Music separation is not installed. Run scripts/setup.sh again.",
            "missing_demucs",
        ) from exc

    if on_progress:
        on_progress(
            "separate",
            16,
            "Loading the music separator (first run may download a model)…",
        )

    original, sample_rate = load_wav(original_wav)
    channels = original.shape[1]
    mix = torch.from_numpy(original.T.astype(np.float32) / 32768.0)

    device = _pick_device()
    model = get_model("htdemucs")
    model.eval()
    try:
        model.to(device)
    except Exception:
        device = torch.device("cpu")
        model.to(device)

    mix = convert_audio(mix, sample_rate, model.samplerate, model.audio_channels)
    if on_progress:
        on_progress(
            "separate",
            22,
            "Pulling music and sound effects off the voices. This can take several minutes…",
        )

    names = list(model.sources)
    model_rate = int(model.samplerate)
    apply_kwargs = _apply_model_kwargs(apply_model, device)
    try:
        with torch.no_grad():
            with heartbeat(
                on_progress,
                stage="separate",
                start_percent=22,
                cap_percent=40,
                interval=heartbeat_interval,
                message="Still pulling music and sound effects off the voices…",
            ):
                sources = apply_model(model, mix[None], **apply_kwargs)[0]
    except Exception as exc:
        raise SeparationError(f"Music separation failed: {exc}") from exc
    finally:
        try:
            model.to("cpu")
        except Exception:
            pass
        del model
        if str(device) == "mps":
            try:
                torch.mps.empty_cache()
            except Exception:
                pass

    vocals_index = names.index("vocals")
    vocals = sources[vocals_index]
    accompaniment = sources.sum(dim=0) - vocals

    vocals = convert_audio(vocals, model_rate, sample_rate, channels)
    accompaniment = convert_audio(accompaniment, model_rate, sample_rate, channels)

    vocals_pcm = np.clip(vocals.detach().cpu().numpy().T, -1.0, 1.0)
    other_pcm = np.clip(accompaniment.detach().cpu().numpy().T, -1.0, 1.0)
    vocals_pcm = align_to_reference((vocals_pcm * 32767.0).astype(np.int16), original)
    other_pcm = align_to_reference((other_pcm * 32767.0).astype(np.int16), original)

    work_dir.mkdir(parents=True, exist_ok=True)
    vocals_path = work_dir / "vocals.wav"
    other_path = work_dir / "music_and_sfx.wav"
    save_wav(vocals_path, vocals_pcm, sample_rate)
    save_wav(other_path, other_pcm, sample_rate)
    if on_progress:
        on_progress("separate", 42, "Separated music and sound effects.")
    return vocals_path, other_path
