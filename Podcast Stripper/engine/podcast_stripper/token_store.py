from __future__ import annotations

import os
import subprocess
from pathlib import Path

KEYCHAIN_SERVICE = "com.podcaststripper.huggingface"
KEYCHAIN_ACCOUNT = "hf_token"
CONFIG_PATH = Path.home() / ".config" / "podcast-stripper" / "hf_token"


class TokenError(RuntimeError):
    def __init__(self, message: str, code: str = "missing_token") -> None:
        super().__init__(message)
        self.code = code


def token_is_set() -> bool:
    try:
        return bool(resolve_token(explicit=None))
    except TokenError:
        return False


def resolve_token(explicit: str | None = None) -> str:
    if explicit and explicit.strip():
        return explicit.strip()

    env = os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN")
    if env and env.strip():
        return env.strip()

    keychain = _read_keychain()
    if keychain:
        return keychain

    if CONFIG_PATH.is_file():
        value = CONFIG_PATH.read_text(encoding="utf-8").strip()
        if value:
            return value

    raise TokenError(
        "No Hugging Face token found. Open the app Settings, or run "
        "`podcast-stripper --save-token YOUR_TOKEN`. You also need to accept "
        "the model terms at https://huggingface.co/pyannote/speaker-diarization-community-1",
        "missing_token",
    )


def save_token(token: str) -> str:
    token = token.strip()
    if not token:
        raise TokenError("Token cannot be empty.")
    where = _write_keychain(token)
    if where == "keychain":
        return "Saved Hugging Face token to the macOS Keychain."
    _write_config_file(token)
    return f"Saved Hugging Face token to {CONFIG_PATH}"


def _read_keychain() -> str | None:
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
        )
    except OSError:
        return None
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return value or None


def _write_keychain(token: str) -> str | None:
    try:
        result = subprocess.run(
            [
                "security",
                "add-generic-password",
                "-U",
                "-s",
                KEYCHAIN_SERVICE,
                "-a",
                KEYCHAIN_ACCOUNT,
                "-w",
                token,
            ],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        return None
    if result.returncode != 0:
        return None
    return "keychain"


def _write_config_file(token: str) -> None:
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text(token + "\n", encoding="utf-8")
    os.chmod(CONFIG_PATH, 0o600)
