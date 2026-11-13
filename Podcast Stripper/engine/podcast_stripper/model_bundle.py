"""Find the speaker model on disk.

The usual path is a folder copied into the app at build time. A developer
cache under Application Support is the same folder before it is packaged.
A Hugging Face token is only a backup when that folder is missing.
"""

from __future__ import annotations

import os
from pathlib import Path

from podcast_stripper.token_store import token_is_set

MODEL_ID = "pyannote/speaker-diarization-community-1"
MODEL_DIR_NAME = "speaker-diarization-community-1"
MODEL_TERMS_URL = "https://huggingface.co/pyannote/speaker-diarization-community-1"

# Real weights are tens of megabytes. Tiny stand-ins do not count as loadable.
_REQUIRED: tuple[tuple[str, int], ...] = (
    ("config.yaml", 100),
    ("segmentation/pytorch_model.bin", 1_000_000),
    ("embedding/pytorch_model.bin", 1_000_000),
    ("plda/plda.npz", 1_000),
    ("plda/xvec_transform.npz", 1_000),
)
_CONFIG_MARKERS = ("$model/segmentation", "$model/embedding", "$model/plda")


class SpeakerModelError(RuntimeError):
    def __init__(self, message: str, code: str = "missing_model") -> None:
        super().__init__(message)
        self.code = code


def default_model_cache_dir() -> Path:
    return (
        Path.home()
        / "Library/Application Support/CougarCalc/Podcast Stripper/models"
        / MODEL_DIR_NAME
    )


def model_dir_is_complete(path: Path) -> bool:
    if not path.is_dir():
        return False
    for relative, minimum in _REQUIRED:
        file = path / relative
        try:
            if not file.is_file() or file.stat().st_size < minimum:
                return False
        except OSError:
            return False
    try:
        config = (path / "config.yaml").read_text(encoding="utf-8")
    except OSError:
        return False
    return all(marker in config for marker in _CONFIG_MARKERS)


def _bundled_model_dir() -> Path | None:
    """Resources/models next to a copied engine (PodStripper.app or Pod Lounge)."""
    here = Path(__file__).resolve()
    try:
        engine_dir = here.parents[1]
        resources = here.parents[2]
    except IndexError:
        return None
    if engine_dir.name != "engine":
        return None
    candidate = resources / "models" / MODEL_DIR_NAME
    if model_dir_is_complete(candidate):
        return candidate
    return None


def find_local_model() -> Path | None:
    """Local model folder, or None when the backup token path has to be used.

    ``PODSTRIPPER_SPEAKER_MODEL`` wins and does not fall through. That keeps a
    bad override from silently downloading a different copy.
    """
    override = os.environ.get("PODSTRIPPER_SPEAKER_MODEL", "").strip()
    if override:
        path = Path(override).expanduser()
        if model_dir_is_complete(path):
            return path
        return None

    bundled = _bundled_model_dir()
    if bundled is not None:
        return bundled

    cache = default_model_cache_dir()
    if model_dir_is_complete(cache):
        return cache
    return None


def model_source_name(path: Path) -> str:
    override = os.environ.get("PODSTRIPPER_SPEAKER_MODEL", "").strip()
    if override:
        try:
            if path.resolve() == Path(override).expanduser().resolve():
                return "env"
        except OSError:
            return "env"
    try:
        parts = path.resolve().parts
    except OSError:
        parts = path.parts
    if any(part.endswith(".app") for part in parts):
        return "bundle"
    return "cache"


def speaker_model_status(explicit_token: str | None = None) -> dict[str, object]:
    local = find_local_model()
    has_token = bool(explicit_token and explicit_token.strip()) or token_is_set()
    if local is not None:
        source = model_source_name(local)
        ready = True
        model_path: str | None = str(local)
    elif has_token:
        source = "token"
        ready = True
        model_path = None
    else:
        source = "missing"
        ready = False
        model_path = None
    return {
        "ready": ready,
        "source": source,
        "path": model_path,
        "token_ok": has_token,
    }


def ensure_speaker_model_ready(explicit_token: str | None = None) -> None:
    """Fail before Demucs or any other long step when a split cannot detect speakers."""
    status = speaker_model_status(explicit_token)
    if status["ready"]:
        return
    raise SpeakerModelError(
        "The speaker model is not in this copy of PodStripper, and no backup "
        "Hugging Face token is saved. Re-download PodStripper. A token in Settings "
        "is only a backup for a copy that is missing the included model.",
        "missing_model",
    )
