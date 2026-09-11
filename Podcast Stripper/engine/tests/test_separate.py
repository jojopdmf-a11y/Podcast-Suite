from __future__ import annotations

import math
import sys
import time
import types
from pathlib import Path

import numpy as np
import pytest

from podcast_stripper.export import save_wav
from podcast_stripper.progress import format_elapsed, heartbeat
from podcast_stripper.separate import (
    _apply_model_kwargs,
    _pick_device,
    separate_vocals,
)


def _sine(frequency: float, seconds: float, sample_rate: int, amplitude: float = 0.3) -> np.ndarray:
    times = np.arange(int(seconds * sample_rate), dtype=np.float64) / sample_rate
    samples = (amplitude * np.sin(2 * math.pi * frequency * times) * 32767).astype(np.int16)
    return samples.reshape(-1, 1)


def _write_wav(path: Path, chunks: list[np.ndarray], sample_rate: int) -> None:
    audio = np.concatenate(chunks, axis=0)
    save_wav(path, audio, sample_rate)


def test_format_elapsed():
    assert format_elapsed(7) == "7s"
    assert format_elapsed(65) == "1m 05s"


def test_heartbeat_keeps_status_moving():
    events: list[tuple[str, float, str]] = []

    def on_progress(stage: str, percent: float, message: str) -> None:
        events.append((stage, percent, message))

    with heartbeat(
        on_progress,
        stage="separate",
        start_percent=22,
        cap_percent=40,
        interval=0.05,
        message="Still pulling music and sound effects off the voices…",
    ):
        time.sleep(0.18)

    assert events
    assert all(stage == "separate" for stage, _, _ in events)
    assert any("Still pulling music" in message for _, _, message in events)
    assert all(22 <= percent <= 40 for _, percent, _ in events)


def test_apply_model_kwargs_force_single_worker():
    def apply_model(model, mix, device=None, split=True, overlap=0.25, progress=False, num_workers=8, shifts=1):
        return mix

    kwargs = _apply_model_kwargs(apply_model, "cpu")
    assert kwargs["num_workers"] == 0
    assert kwargs["progress"] is False
    assert kwargs["device"] == "cpu"


def test_macos_defaults_to_cpu_even_when_mps_exists(monkeypatch):
    fake = types.ModuleType("torch")

    class _MPS:
        @staticmethod
        def is_available() -> bool:
            return True

    class _CUDA:
        @staticmethod
        def is_available() -> bool:
            return False

    class _Backends:
        mps = _MPS()

    class _Device:
        def __init__(self, name: str) -> None:
            self.type = name

        def __str__(self) -> str:
            return self.type

    fake.backends = _Backends()
    fake.cuda = _CUDA()
    fake.device = _Device
    monkeypatch.setitem(sys.modules, "torch", fake)
    monkeypatch.setattr(sys, "platform", "darwin")
    monkeypatch.delenv("PODCAST_STRIPPER_DEMUCS_DEVICE", raising=False)
    assert str(_pick_device()) == "cpu"


def test_device_override_honors_env(monkeypatch):
    fake = types.ModuleType("torch")

    class _MPS:
        @staticmethod
        def is_available() -> bool:
            return True

    class _CUDA:
        @staticmethod
        def is_available() -> bool:
            return False

    class _Backends:
        mps = _MPS()

    class _Device:
        def __init__(self, name: str) -> None:
            self.type = name

        def __str__(self) -> str:
            return self.type

    fake.backends = _Backends()
    fake.cuda = _CUDA()
    fake.device = _Device
    monkeypatch.setitem(sys.modules, "torch", fake)
    monkeypatch.setattr(sys, "platform", "darwin")
    monkeypatch.setenv("PODCAST_STRIPPER_DEMUCS_DEVICE", "mps")
    assert str(_pick_device()) == "mps"


def test_remove_empty_output_dir_only_when_we_created_it(tmp_path: Path):
    from podcast_stripper.cli import _remove_empty_output_dir

    created = tmp_path / "new_speakers"
    created.mkdir()
    _remove_empty_output_dir(created, created=True)
    assert not created.exists()

    existing = tmp_path / "already_there"
    existing.mkdir()
    _remove_empty_output_dir(existing, created=False)
    assert existing.exists()

    kept = tmp_path / "has_file"
    kept.mkdir()
    (kept / "keep.txt").write_text("hi", encoding="utf-8")
    _remove_empty_output_dir(kept, created=True)
    assert (kept / "keep.txt").is_file()


def test_failed_job_does_not_leave_empty_output_folder(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    from podcast_stripper.cli import main
    from podcast_stripper import cli as cli_mod

    source = tmp_path / "episode.wav"
    _write_wav(source, [_sine(440, 0.4, 16000)], 16000)
    output_dir = tmp_path / "episode_speakers"

    def fake_export_convert(input_path: Path, output_wav: Path) -> None:
        output_wav.write_bytes(source.read_bytes())

    def fake_diarize_convert(input_path: Path, output_wav: Path) -> None:
        output_wav.write_bytes(source.read_bytes())

    def boom(*_args, **_kwargs):
        raise RuntimeError("speaker model exploded")

    monkeypatch.setattr(cli_mod, "convert_for_export", fake_export_convert)
    monkeypatch.setattr(cli_mod, "convert_for_diarization", fake_diarize_convert)
    monkeypatch.setattr(cli_mod, "find_ffmpeg", lambda: "/usr/bin/true")
    monkeypatch.setattr(cli_mod, "resolve_token", lambda *_args, **_kwargs: "hf_test")
    monkeypatch.setattr("podcast_stripper.diarize.run_diarization", boom)

    code = main(
        [
            str(source),
            "-o",
            str(output_dir),
            "--skip-separate",
            "--json-progress",
        ]
    )
    assert code != 0
    assert not output_dir.exists()


def test_separate_uses_cpu_zero_workers_and_heartbeats(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    torch = pytest.importorskip("torch")

    source = tmp_path / "mix.wav"
    _write_wav(source, [_sine(440, 0.2, 16000), _sine(90, 0.2, 16000)], 16000)

    captured: dict = {}
    progress: list[tuple[str, float, str]] = []

    class FakeModel:
        sources = ["drums", "bass", "other", "vocals"]
        samplerate = 16000
        audio_channels = 1

        def eval(self):
            return self

        def to(self, device):
            return self

    def fake_get_model(_name: str) -> FakeModel:
        return FakeModel()

    def fake_convert_audio(wav, from_sr, to_sr, channels):
        return wav

    def fake_apply_model(model, mix, device=None, split=True, overlap=0.25, progress=False, num_workers=8, shifts=1):
        captured.update(
            {
                "device": str(device),
                "num_workers": num_workers,
                "progress": progress,
            }
        )
        time.sleep(0.22)
        batch, channels, frames = mix.shape
        out = torch.zeros(batch, 4, channels, frames)
        out[:, 3] = mix
        return out

    demucs_apply = types.ModuleType("demucs.apply")
    demucs_apply.apply_model = fake_apply_model
    demucs_audio = types.ModuleType("demucs.audio")
    demucs_audio.convert_audio = fake_convert_audio
    demucs_pretrained = types.ModuleType("demucs.pretrained")
    demucs_pretrained.get_model = fake_get_model
    demucs = types.ModuleType("demucs")
    monkeypatch.setitem(sys.modules, "demucs", demucs)
    monkeypatch.setitem(sys.modules, "demucs.apply", demucs_apply)
    monkeypatch.setitem(sys.modules, "demucs.audio", demucs_audio)
    monkeypatch.setitem(sys.modules, "demucs.pretrained", demucs_pretrained)
    monkeypatch.setattr(sys, "platform", "darwin")
    monkeypatch.delenv("PODCAST_STRIPPER_DEMUCS_DEVICE", raising=False)

    vocals, other = separate_vocals(
        source,
        tmp_path / "stems",
        on_progress=lambda stage, percent, message: progress.append((stage, percent, message)),
        heartbeat_interval=0.05,
    )
    assert vocals.is_file()
    assert other.is_file()
    assert captured["num_workers"] == 0
    assert "cpu" in captured["device"]
    assert any("Still pulling music" in message for _, _, message in progress)
