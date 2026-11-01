from __future__ import annotations

from pathlib import Path

from podcast_stripper.ffmpeg_bin import run_ffmpeg

SUPPORTED_SUFFIXES = {".mp3", ".m4a", ".wav", ".aiff", ".aif", ".flac", ".ogg", ".caf"}

# Working copy stays 16-bit WAV at the source rate. Convert only when writing the finished tracks.
EXPORT_FORMATS = {
    "wav16": (".wav", "pcm_s16le"),
    "wav24": (".wav", "pcm_s24le"),
    "aiff24": (".aiff", "pcm_s24be"),
}
EXPORT_SAMPLE_RATES = {44100, 48000, 88200, 96000, 176400, 192000}


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


def parse_export_sample_rate(value: str | int | None) -> int | None:
    """None means keep the file’s native rate."""
    if value is None:
        return None
    if isinstance(value, int):
        if value <= 0:
            return None
        if value not in EXPORT_SAMPLE_RATES:
            raise ValueError(f"Unsupported export sample rate: {value}")
        return value
    text = str(value).strip().lower()
    if text in {"", "native", "source", "0"}:
        return None
    try:
        rate = int(text)
    except ValueError as exc:
        raise ValueError(f"Unsupported export sample rate: {value}") from exc
    if rate not in EXPORT_SAMPLE_RATES:
        raise ValueError(f"Unsupported export sample rate: {value}")
    return rate


def parse_export_audio_format(value: str | None) -> str:
    text = (value or "wav16").strip().lower()
    if text not in EXPORT_FORMATS:
        raise ValueError(f"Unsupported export format: {value}. Use wav16, wav24, or aiff24.")
    return text


def export_suffix(audio_format: str) -> str:
    return EXPORT_FORMATS[parse_export_audio_format(audio_format)][0]


def encode_export_file(
    src: Path,
    dest: Path,
    *,
    sample_rate: int | None,
    audio_format: str,
) -> Path:
    """Write dest from a working WAV, converting rate/format only at this step."""
    fmt = parse_export_audio_format(audio_format)
    ext, codec = EXPORT_FORMATS[fmt]
    dest = dest.with_suffix(ext)
    dest.parent.mkdir(parents=True, exist_ok=True)
    args = ["-i", str(src), "-vn"]
    if sample_rate:
        args += ["-ar", str(sample_rate)]
    args += ["-acodec", codec, str(dest)]
    run_ffmpeg(args)
    return dest


def is_supported_audio(path: Path) -> bool:
    return path.suffix.lower() in SUPPORTED_SUFFIXES
