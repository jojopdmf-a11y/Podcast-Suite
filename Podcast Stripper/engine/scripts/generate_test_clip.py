"""Create a short two-speaker mix using macOS voices, or a sine-wave fallback."""

from __future__ import annotations

import argparse
import json
import math
import shutil
import subprocess
import tempfile
from pathlib import Path

import numpy as np

from podcast_stripper.export import load_wav, save_wav


def _sine(frequency: float, seconds: float, sample_rate: int) -> np.ndarray:
    times = np.arange(int(seconds * sample_rate), dtype=np.float64) / sample_rate
    samples = (0.25 * np.sin(2 * math.pi * frequency * times) * 32767).astype(np.int16)
    return samples.reshape(-1, 1)


def _silence(seconds: float, sample_rate: int) -> np.ndarray:
    return np.zeros((int(seconds * sample_rate), 1), dtype=np.int16)


def _say_to_wav(text: str, voice: str, dest: Path, sample_rate: int) -> None:
    aiff = dest.with_suffix(".aiff")
    subprocess.run(
        ["say", "-v", voice, "-r", "180", "-o", str(aiff), text],
        check=True,
    )
    subprocess.run(
        [
            "afconvert",
            "-f",
            "WAVE",
            "-d",
            f"LEI16@{sample_rate}",
            str(aiff),
            str(dest),
        ],
        check=True,
    )
    aiff.unlink(missing_ok=True)


def generate(output: Path, sample_rate: int = 16000) -> tuple[Path, Path]:
    output.parent.mkdir(parents=True, exist_ok=True)
    host_text = (
        "Welcome to the show. Today we are talking about making coffee at home. "
        "Tell me where you like to start."
    )
    guest_text = (
        "I start with fresh beans and a simple kettle. Grind just before you brew, "
        "and give the grounds a little swirl."
    )
    gap = 0.6
    segments: list[dict[str, float | str]]
    mix: np.ndarray

    if shutil.which("say") and shutil.which("afconvert"):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            host = tmp_dir / "host.wav"
            guest = tmp_dir / "guest.wav"
            try:
                _say_to_wav(host_text, "Samantha", host, sample_rate)
                _say_to_wav(guest_text, "Alex", guest, sample_rate)
                host_audio, _ = load_wav(host)
                guest_audio, _ = load_wav(guest)
                host_seconds = host_audio.shape[0] / sample_rate
                guest_start = host_seconds + gap
                guest_seconds = guest_audio.shape[0] / sample_rate
                mix = np.concatenate(
                    [host_audio, _silence(gap, sample_rate), guest_audio, _silence(0.4, sample_rate)],
                    axis=0,
                )
                segments = [
                    {"start": 0.0, "end": round(host_seconds, 3), "speaker": "SPEAKER_00"},
                    {
                        "start": round(guest_start, 3),
                        "end": round(guest_start + guest_seconds, 3),
                        "speaker": "SPEAKER_01",
                    },
                ]
                save_wav(output, mix, sample_rate)
                sidecar = output.with_name(output.stem + "_segments.json")
                sidecar.write_text(json.dumps({"segments": segments}, indent=2) + "\n", encoding="utf-8")
                return output, sidecar
            except (subprocess.CalledProcessError, FileNotFoundError, OSError):
                pass

    mix = np.concatenate(
        [
            _sine(220, 2.5, sample_rate),
            _silence(0.5, sample_rate),
            _sine(440, 2.5, sample_rate),
            _silence(0.3, sample_rate),
        ]
    )
    save_wav(output, mix, sample_rate)
    segments = [
        {"start": 0.0, "end": 2.5, "speaker": "SPEAKER_00"},
        {"start": 3.0, "end": 5.5, "speaker": "SPEAKER_01"},
    ]
    sidecar = output.with_name(output.stem + "_segments.json")
    sidecar.write_text(json.dumps({"segments": segments}, indent=2) + "\n", encoding="utf-8")
    return output, sidecar


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "-o",
        "--output",
        default=str(Path(__file__).resolve().parents[2] / "fixtures" / "two_speakers.wav"),
    )
    args = parser.parse_args()
    wav, sidecar = generate(Path(args.output))
    print(wav)
    print(sidecar)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
