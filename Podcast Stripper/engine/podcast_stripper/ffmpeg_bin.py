from __future__ import annotations

import os
import shutil
import subprocess
from functools import lru_cache
from pathlib import Path

FFMPEG_CANDIDATES = (
    "/opt/homebrew/bin/ffmpeg",
    "/usr/local/bin/ffmpeg",
)


class FFmpegError(RuntimeError):
    def __init__(self, message: str, code: str = "missing_ffmpeg") -> None:
        super().__init__(message)
        self.code = code


@lru_cache(maxsize=1)
def find_ffmpeg() -> str:
    env = os.environ.get("IMAGEIO_FFMPEG_EXE") or os.environ.get("FFMPEG_BINARY")
    if env and Path(env).is_file():
        return env

    which = shutil.which("ffmpeg")
    if which:
        return which

    for path in FFMPEG_CANDIDATES:
        if Path(path).is_file():
            return path

    try:
        from imageio_ffmpeg import get_ffmpeg_exe

        exe = get_ffmpeg_exe()
        if exe:
            return exe
    except Exception:
        pass

    raise FFmpegError(
        "ffmpeg was not found. Install it with Homebrew (`brew install ffmpeg`) "
        "or wait for the app to finish installing its bundled copy.",
        "missing_ffmpeg",
    )


def run_ffmpeg(args: list[str], *, timeout: int | None = None) -> None:
    ffmpeg = find_ffmpeg()
    command = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", *args]
    try:
        subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "").strip()
        raise FFmpegError(
            f"ffmpeg failed: {detail or exc}",
            "ffmpeg_failed",
        ) from exc
