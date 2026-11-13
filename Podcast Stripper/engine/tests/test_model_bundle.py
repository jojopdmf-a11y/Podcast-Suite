"""Speaker model is local. A split must not start the long work without it."""

from __future__ import annotations

import json
import wave
from pathlib import Path

import numpy as np

from podcast_stripper.cli import main
from podcast_stripper.model_bundle import (
    SpeakerModelError,
    ensure_speaker_model_ready,
    find_local_model,
    model_dir_is_complete,
    speaker_model_status,
)


def _write_wav(path: Path, seconds: float = 0.2, sample_rate: int = 16000) -> None:
    samples = np.zeros((int(seconds * sample_rate), 1), dtype=np.int16)
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        handle.writeframes(samples.tobytes())


def _complete_model(path: Path) -> Path:
    config = (
        "pipeline:\n"
        "  params:\n"
        "    segmentation: $model/segmentation\n"
        "    embedding: $model/embedding\n"
        "    plda: $model/plda\n"
        "# pad so the config clears the minimum size used to reject empty stand-ins\n"
    )
    (path / "config.yaml").parent.mkdir(parents=True, exist_ok=True)
    (path / "config.yaml").write_text(config, encoding="utf-8")
    for relative, size in (
        ("segmentation/pytorch_model.bin", 1_000_000),
        ("embedding/pytorch_model.bin", 1_000_000),
        ("plda/plda.npz", 1_000),
        ("plda/xvec_transform.npz", 1_000),
    ):
        file = path / relative
        file.parent.mkdir(parents=True, exist_ok=True)
        with file.open("wb") as handle:
            handle.truncate(size)
    return path


def test_incomplete_model_dir_is_not_loadable(tmp_path: Path):
    model = tmp_path / "speaker-diarization-community-1"
    model.mkdir()
    (model / "config.yaml").write_text("segmentation: $model/segmentation\n", encoding="utf-8")
    assert model_dir_is_complete(model) is False


def test_complete_model_dir_is_loadable(tmp_path: Path):
    assert model_dir_is_complete(_complete_model(tmp_path / "model")) is True


def test_env_override_does_not_fall_through_to_cache(tmp_path: Path, monkeypatch):
    cache = _complete_model(tmp_path / "cache")
    monkeypatch.setenv("PODSTRIPPER_SPEAKER_MODEL", str(tmp_path / "missing"))
    monkeypatch.setattr("podcast_stripper.model_bundle._bundled_model_dir", lambda: None)
    monkeypatch.setattr("podcast_stripper.model_bundle.default_model_cache_dir", lambda: cache)
    assert find_local_model() is None


def test_bundle_is_preferred_over_cache(tmp_path: Path, monkeypatch):
    bundle = _complete_model(tmp_path / "bundle")
    cache = _complete_model(tmp_path / "cache")
    monkeypatch.delenv("PODSTRIPPER_SPEAKER_MODEL", raising=False)
    monkeypatch.setattr("podcast_stripper.model_bundle._bundled_model_dir", lambda: bundle)
    monkeypatch.setattr("podcast_stripper.model_bundle.default_model_cache_dir", lambda: cache)
    assert find_local_model() == bundle


def test_missing_model_and_token_is_not_ready(monkeypatch):
    monkeypatch.setattr("podcast_stripper.model_bundle.find_local_model", lambda: None)
    monkeypatch.setattr("podcast_stripper.model_bundle.token_is_set", lambda: False)
    status = speaker_model_status()
    assert status["ready"] is False
    assert status["source"] == "missing"
    try:
        ensure_speaker_model_ready()
    except SpeakerModelError as exc:
        assert exc.code == "missing_model"
        assert "Hugging Face" in str(exc)
        assert "hf_" not in str(exc)
    else:
        raise AssertionError("expected SpeakerModelError")


def test_saved_token_is_a_backup_when_the_bundle_is_missing(monkeypatch):
    monkeypatch.setattr("podcast_stripper.model_bundle.find_local_model", lambda: None)
    monkeypatch.setattr("podcast_stripper.model_bundle.token_is_set", lambda: True)
    status = speaker_model_status()
    assert status["ready"] is True
    assert status["source"] == "token"
    ensure_speaker_model_ready()


def test_split_stops_before_audio_work_without_model_or_token(tmp_path: Path, monkeypatch, capsys):
    source = tmp_path / "episode.wav"
    _write_wav(source)
    calls: list[str] = []

    monkeypatch.setattr("podcast_stripper.model_bundle.find_local_model", lambda: None)
    monkeypatch.setattr("podcast_stripper.model_bundle.token_is_set", lambda: False)
    monkeypatch.setattr("podcast_stripper.cli.find_ffmpeg", lambda: "/usr/bin/true")
    monkeypatch.setattr(
        "podcast_stripper.cli.convert_for_export",
        lambda *_args, **_kwargs: calls.append("convert"),
    )

    code = main(
        [
            str(source),
            "-o",
            str(tmp_path / "out"),
            "--json-progress",
        ]
    )
    assert code == 2
    assert calls == []
    assert not (tmp_path / "out").exists()
    lines = [json.loads(line) for line in capsys.readouterr().out.strip().splitlines() if line]
    assert any(line.get("code") == "missing_model" for line in lines)


def test_from_segments_does_not_need_the_speaker_model(tmp_path: Path, monkeypatch):
    source = tmp_path / "episode.wav"
    _write_wav(source, seconds=0.4)
    segments = tmp_path / "segments.json"
    segments.write_text(
        json.dumps({"segments": [{"start": 0.0, "end": 0.4, "speaker": "A"}]}),
        encoding="utf-8",
    )
    monkeypatch.setattr("podcast_stripper.model_bundle.find_local_model", lambda: None)
    monkeypatch.setattr("podcast_stripper.model_bundle.token_is_set", lambda: False)

    def fake_export_convert(input_path: Path, output_wav: Path) -> None:
        output_wav.write_bytes(source.read_bytes())

    monkeypatch.setattr("podcast_stripper.cli.convert_for_export", fake_export_convert)
    monkeypatch.setattr("podcast_stripper.cli.find_ffmpeg", lambda: "/usr/bin/true")

    code = main(
        [
            str(source),
            "-o",
            str(tmp_path / "out"),
            "--from-segments",
            str(segments),
            "--skip-separate",
            "--json-progress",
        ]
    )
    assert code == 0


def test_check_setup_reports_model_readiness(monkeypatch, capsys):
    monkeypatch.setattr("podcast_stripper.model_bundle.find_local_model", lambda: None)
    monkeypatch.setattr("podcast_stripper.model_bundle.token_is_set", lambda: False)
    monkeypatch.setattr("podcast_stripper.cli.token_is_set", lambda: False)
    code = main(["--check-setup", "--json-progress"])
    payload = json.loads(capsys.readouterr().out.strip().splitlines()[-1])
    assert payload["event"] == "setup"
    assert payload["model_ok"] is False
    assert payload["model_source"] == "missing"
    assert payload["model_path"] is None
    assert payload["token_ok"] is False
    assert payload["model"] == "pyannote/speaker-diarization-community-1"
    assert payload["model_license"] == "cc-by-4.0"
    assert code in (0, 1)
