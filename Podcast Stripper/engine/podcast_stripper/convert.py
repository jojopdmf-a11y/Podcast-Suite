from __future__ import annotations

from pathlib import Path

from podcast_stripper.ffmpeg_bin import run_ffmpeg

SUPPORTED_SUFFIXES = {".mp3", ".m4a", ".wav", ".aiff", ".aif", ".flac", ".ogg", ".caf"}


def convert_for_export(input_path: Path, output_wav: Path) -> None:
    """Decode the original file to 16-bit WAV, keeping sample rate and channels."""
    output_wav.parent.mkdir(parents=True, exist_ok=True)
    run_ffmpeg(
        [
            "-i",
            str(input_path),
            "-vn",
            "-acodec",
            "pcm_s16le",
            str(output_wav),
        ]
    )


def convert_for_diarization(input_path: Path, output_wav: Path) -> None:
    """Make the 16 kHz mono copy pyannote expects."""
    output_wav.parent.mkdir(parents=True, exist_ok=True)
    run_ffmpeg(
        [
            "-i",
            str(input_path),
            "-vn",
            "-ac",
            "1",
            "-ar",
            "16000",
            "-acodec",
            "pcm_s16le",
            str(output_wav),
        ]
    )


def is_supported_audio(path: Path) -> bool:
    return path.suffix.lower() in SUPPORTED_SUFFIXES
