from __future__ import annotations

from pathlib import Path
from typing import Callable

import numpy as np

from podcast_stripper.export import load_wav, save_wav

ProgressFn = Callable[[str, float, str], None]


class SeparationError(RuntimeError):
    def __init__(self, message: str, code: str = "separation_failed") -> None:
        super().__init__(message)
        self.code = code


def _pick_device():
    import torch

    if torch.backends.mps.is_available():
        return torch.device("mps")
    if torch.cuda.is_available():
        return torch.device("cuda")
    return torch.device("cpu")


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
) -> tuple[Path, Path]:
    """Split a mix into vocals and everything else (music, beds, sound effects)."""
    import os
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
        on_progress("separate", 16, "Loading the music separator…")

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
        on_progress("separate", 22, "Pulling music and sound effects off the voices…")

    names = list(model.sources)
    model_rate = int(model.samplerate)
    try:
        with torch.no_grad():
            sources = apply_model(
                model,
                mix[None],
                device=device,
                split=True,
                overlap=0.25,
                progress=False,
            )[0]
    except Exception as exc:
        raise SeparationError(f"Music separation failed: {exc}") from exc
    finally:
        try:
            model.to("cpu")
        except Exception:
            pass
        del model
        if str(device) == "mps":
            torch.mps.empty_cache()

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
