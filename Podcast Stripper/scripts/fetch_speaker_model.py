#!/usr/bin/env python3
"""Download the speaker model once, for a developer build.

Reads a Hugging Face token from the environment (HF_TOKEN or
HUGGING_FACE_HUB_TOKEN) or from the macOS Keychain. The token stays in
memory for this process. It is not printed, logged, or written into the
model folder, the app, or git.

Customers never run this. The build script copies the downloaded folder
into PodStripper.app.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ID = "pyannote/speaker-diarization-community-1"
MODEL_DIR_NAME = "speaker-diarization-community-1"
# "About 2 GB" — stop before a build copies a huge folder into the app.
SIZE_LIMIT_BYTES = 2_200_000_000
KEYCHAIN_SERVICE = "com.podcaststripper.huggingface"
KEYCHAIN_ACCOUNT = "hf_token"
REQUIRED = (
    "config.yaml",
    "segmentation/pytorch_model.bin",
    "embedding/pytorch_model.bin",
    "plda/plda.npz",
    "plda/xvec_transform.npz",
)
TOKEN_RE = re.compile(r"hf_[A-Za-z0-9]{8,}")


def default_cache_dir() -> Path:
    return (
        Path.home()
        / "Library/Application Support/CougarCalc/Podcast Stripper/models"
        / MODEL_DIR_NAME
    )


def redact(text: str) -> str:
    return TOKEN_RE.sub("[redacted]", text)


def eprint(message: str) -> None:
    print(redact(message), file=sys.stderr)


def read_keychain_token() -> str | None:
    try:
        result = subprocess.run(
            [
                "security",
                "find-generic-password",
                "-s",
                KEYCHAIN_SERVICE,
                "-a",
                KEYCHAIN_ACCOUNT,
                "-w",
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=20,
        )
    except subprocess.TimeoutExpired:
        eprint(
            "macOS Keychain did not return the developer token within 20 seconds. "
            "A login prompt may be waiting. Allow Keychain access for this Terminal, then run the download again."
        )
        raise SystemExit(3)
    except OSError as exc:
        eprint(f"Could not run the Keychain tool: {exc}")
        raise SystemExit(3)
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return value or None


def resolve_download_token() -> str:
    for name in ("HF_TOKEN", "HUGGING_FACE_HUB_TOKEN"):
        value = os.environ.get(name, "").strip()
        if value:
            return value
    keychain = read_keychain_token()
    if keychain:
        return keychain
    eprint(
        "No developer Hugging Face token found. Save one in the macOS Keychain "
        f"(service {KEYCHAIN_SERVICE}, account {KEYCHAIN_ACCOUNT}) or set HF_TOKEN "
        "for this command only. The token is not stored in the app."
    )
    raise SystemExit(3)


def directory_bytes(path: Path) -> int:
    """Bytes we would copy into the app. Skips the Hugging Face download cache and the demo GIF."""
    total = 0
    if not path.exists():
        return 0
    for item in path.rglob("*"):
        if not item.is_file():
            continue
        relative = item.relative_to(path)
        if ".cache" in relative.parts or relative.name == "diarization.gif":
            continue
        try:
            total += item.stat().st_size
        except OSError:
            continue
    return total


def missing_files(path: Path) -> list[str]:
    missing = []
    for relative in REQUIRED:
        file = path / relative
        if not file.is_file() or file.stat().st_size < 32:
            missing.append(relative)
    return missing


def write_bundle_info(path: Path, info: dict) -> None:
    # Sits beside the weights so a later build can see revision and size.
    # No token, ever.
    payload = {key: info[key] for key in info if key != "token"}
    (path.parent / "speaker-model-info.json").write_text(
        json.dumps(payload, indent=2) + "\n",
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Download the bundled speaker model.")
    parser.add_argument(
        "--dest",
        type=Path,
        default=default_cache_dir(),
        help="Folder that will contain config.yaml and the weight files",
    )
    args = parser.parse_args()
    dest = args.dest.expanduser().resolve()

    if not missing_files(dest):
        size = directory_bytes(dest)
        summary = {
            "repo_id": REPO_ID,
            "path": str(dest),
            "bytes": size,
            "cached": True,
            "over_limit": size > SIZE_LIMIT_BYTES,
        }
        print(json.dumps(summary, indent=2))
        if size > SIZE_LIMIT_BYTES:
            eprint(f"Cached model is {size} bytes, over the {SIZE_LIMIT_BYTES} byte limit.")
            return 2
        return 0

    token = resolve_download_token()
    # Keep the token out of huggingface_hub's verbose errors as much as we can.
    os.environ["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"

    try:
        from huggingface_hub import HfApi, snapshot_download
        from huggingface_hub.errors import GatedRepoError, HfHubHTTPError
    except ImportError:
        try:
            from huggingface_hub import HfApi, snapshot_download
            from huggingface_hub.utils import GatedRepoError, HfHubHTTPError
        except ImportError as exc:
            eprint(
                "huggingface_hub is not installed. From Podcast Stripper/, run "
                "`uv run --project engine python scripts/fetch_speaker_model.py`."
            )
            eprint(str(exc))
            return 1

    try:
        info = HfApi(token=token).model_info(REPO_ID)
        dest.parent.mkdir(parents=True, exist_ok=True)
        snapshot_download(
            REPO_ID,
            repo_type="model",
            revision=getattr(info, "sha", None),
            local_dir=str(dest),
            token=token,
        )
    except SystemExit:
        raise
    except Exception as exc:
        name = exc.__class__.__name__
        message = redact(str(exc))
        gated = name in {"GatedRepoError", "RepositoryNotFoundError"} or any(
            needle in message.lower()
            for needle in ("401", "403", "gated", "restricted", "accept", "unauthorized")
        )
        if gated:
            eprint(
                "Hugging Face refused the speaker-model download. The developer account "
                "must open https://huggingface.co/pyannote/speaker-diarization-community-1 "
                "and accept the terms, and the Keychain token must be a read token. "
                f"({name})"
            )
            return 4
        eprint(f"Speaker model download failed ({name}): {message}")
        return 1

    missing = missing_files(dest)
    size = directory_bytes(dest)
    card = getattr(info, "card_data", None)
    license_name = None
    if card is not None:
        license_name = getattr(card, "license", None) or (
            card.get("license") if isinstance(card, dict) else None
        )
    summary = {
        "repo_id": REPO_ID,
        "revision": getattr(info, "sha", None),
        "license": license_name,
        "path": str(dest),
        "bytes": size,
        "missing": missing,
        "cached": False,
        "over_limit": size > SIZE_LIMIT_BYTES,
        "size_limit_bytes": SIZE_LIMIT_BYTES,
    }
    write_bundle_info(dest, summary)
    print(json.dumps(summary, indent=2))
    if missing:
        eprint("Download finished but required model files are missing: " + ", ".join(missing))
        return 1
    if size > SIZE_LIMIT_BYTES:
        eprint(
            f"Speaker model is {size} bytes (limit {SIZE_LIMIT_BYTES}). "
            "Do not copy it into the app."
        )
        return 2
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception as exc:
        eprint(f"Speaker model download failed: {redact(str(exc))}")
        raise SystemExit(1)
