from __future__ import annotations

import argparse
import io
import json
import wave
from pathlib import Path
from unittest.mock import patch

import numpy as np
import pytest

from podcast_stripper.cli import (
    SegmentsError,
    _load_segments,
    _speaker_bounds,
    main,
)


def _write_wav(path: Path, chunks: list[np.ndarray], sample_rate: int) -> None:
    audio = np.concatenate(chunks, axis=0)
    if audio.ndim == 1:
        audio = audio.reshape(-1, 1)
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(audio.shape[1])
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        handle.writeframes(audio.astype(np.int16).tobytes())


def _sine(frequency: float, seconds: float, sample_rate: int, amplitude: float = 0.2) -> np.ndarray:
    times = np.arange(int(seconds * sample_rate), dtype=np.float64) / sample_rate
    samples = (amplitude * np.sin(2 * np.pi * frequency * times) * 32767).astype(np.int16)
    return samples.reshape(-1, 1)


def _patch_cli_converts(monkeypatch: pytest.MonkeyPatch, source: Path):
    from podcast_stripper import cli as cli_mod

    def fake_export_convert(input_path: Path, output_wav: Path) -> None:
        output_wav.write_bytes(source.read_bytes())

    monkeypatch.setattr(cli_mod, "convert_for_export", fake_export_convert)
    monkeypatch.setattr(cli_mod, "find_ffmpeg", lambda: "/usr/bin/true")
    return cli_mod


def test_load_segments_validates_shape_and_fields(tmp_path: Path):
    path = tmp_path / "segments.json"
    path.write_text(
        json.dumps(
            {
                "segments": [
                    {"start": 0.0, "end": 1.0, "speaker": "A"},
                    {"start": 1.0, "end": 2.0, "speaker": "B"},
                ]
            }
        ),
        encoding="utf-8",
    )
    assert _load_segments(path) == [(0.0, 1.0, "A"), (1.0, 2.0, "B")]

    missing = tmp_path / "nope.json"
    with pytest.raises(SegmentsError) as missing_exc:
        _load_segments(missing)
    assert missing_exc.value.code == "missing_segments"

    bad = tmp_path / "bad.json"
    bad.write_text(json.dumps({"segments": {"start": 0}}), encoding="utf-8")
    with pytest.raises(SegmentsError) as bad_exc:
        _load_segments(bad)
    assert bad_exc.value.code == "bad_segments"

    inverted = tmp_path / "inverted.json"
    inverted.write_text(
        json.dumps({"segments": [{"start": 2.0, "end": 1.0, "speaker": "A"}]}),
        encoding="utf-8",
    )
    with pytest.raises(SegmentsError):
        _load_segments(inverted)


def test_speaker_bounds_rejects_zero_and_inverted_range():
    auto = argparse.Namespace(num_speakers=None, min_speakers=None, max_speakers=None)
    assert _speaker_bounds(auto) == {"min_speakers": 1, "max_speakers": 8}

    exact = argparse.Namespace(num_speakers=2, min_speakers=None, max_speakers=None)
    assert _speaker_bounds(exact) == {"num_speakers": 2}

    with pytest.raises(ValueError, match="at least 1"):
        _speaker_bounds(argparse.Namespace(num_speakers=0, min_speakers=None, max_speakers=None))

    with pytest.raises(ValueError, match="cannot be greater"):
        _speaker_bounds(argparse.Namespace(num_speakers=None, min_speakers=4, max_speakers=2))


def test_human_error_prints_once():
    from podcast_stripper.progress import error

    buf = io.StringIO()
    with patch("sys.stderr", buf):
        error("boom", "failed", json_progress=False)
    assert buf.getvalue() == "Error: boom\n"


def test_check_setup_ok():
    code = main(["--check-setup"])
    assert code == 0


def test_cli_bad_segments_exits_2(tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys):
    source = tmp_path / "episode.wav"
    _write_wav(source, [_sine(440, 0.4, 16000)], 16000)
    segments = tmp_path / "segments.json"
    segments.write_text(json.dumps({"segments": "nope"}), encoding="utf-8")
    cli_mod = _patch_cli_converts(monkeypatch, source)

    diarize_calls: list[Path] = []
    monkeypatch.setattr(
        cli_mod,
        "convert_for_diarization",
        lambda *_args, **_kwargs: diarize_calls.append(Path("x")),
    )

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
    assert code == 2
    assert diarize_calls == []
    lines = [json.loads(line) for line in capsys.readouterr().out.strip().splitlines() if line]
    assert any(line.get("code") == "bad_segments" for line in lines)


def test_cli_from_segments_can_still_run_separate(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    """--from-segments no longer implies --skip-separate."""
    source = tmp_path / "episode.wav"
    _write_wav(
        source,
        [_sine(440, 0.5, 16000), _sine(660, 0.5, 16000)],
        16000,
    )
    segments = tmp_path / "segments.json"
    segments.write_text(
        json.dumps(
            {
                "segments": [
                    {"start": 0.0, "end": 0.5, "speaker": "A"},
                    {"start": 0.5, "end": 1.0, "speaker": "B"},
                ]
            }
        ),
        encoding="utf-8",
    )
    output_dir = tmp_path / "tracks"
    cli_mod = _patch_cli_converts(monkeypatch, source)

    separate_calls: list[Path] = []

    def fake_separate(original_wav: Path, stems_dir: Path, on_progress=None):
        separate_calls.append(original_wav)
        voice = stems_dir / "vocals.wav"
        music = stems_dir / "other.wav"
        stems_dir.mkdir(parents=True, exist_ok=True)
        voice.write_bytes(source.read_bytes())
        music.write_bytes(source.read_bytes())
        return voice, music

    monkeypatch.setattr(
        "podcast_stripper.separate.separate_vocals",
        fake_separate,
    )

    # Import path used inside _run_job
    import podcast_stripper.separate as separate_mod

    monkeypatch.setattr(separate_mod, "separate_vocals", fake_separate)

    code = main(
        [
            str(source),
            "-o",
            str(output_dir),
            "--from-segments",
            str(segments),
            "--json-progress",
        ]
    )
    assert code == 0
    assert separate_calls
    assert (output_dir / "speakers.json").is_file()


def test_cli_export_sample_rate_and_format(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    source = tmp_path / "episode.wav"
    _write_wav(
        source,
        [_sine(440, 0.5, 16000), _sine(660, 0.5, 16000)],
        16000,
    )
    segments = tmp_path / "segments.json"
    segments.write_text(
        json.dumps(
            {
                "segments": [
                    {"start": 0.0, "end": 0.5, "speaker": "A"},
                    {"start": 0.5, "end": 1.0, "speaker": "B"},
                ]
            }
        ),
        encoding="utf-8",
    )
    output_dir = tmp_path / "tracks"
    _patch_cli_converts(monkeypatch, source)

    # Real ffmpeg encode path for export conversion.
    code = main(
        [
            str(source),
            "-o",
            str(output_dir),
            "--from-segments",
            str(segments),
            "--skip-separate",
            "--sample-rate",
            "48000",
            "--audio-format",
            "wav24",
            "--json-progress",
        ]
    )
    assert code == 0
    manifest = json.loads((output_dir / "speakers.json").read_text(encoding="utf-8"))
    assert manifest["sample_rate"] == 48000
    assert manifest["audio_format"] == "wav24"
    with wave.open(str(output_dir / "Speaker_1.wav"), "rb") as handle:
        assert handle.getframerate() == 48000
        assert handle.getsampwidth() == 3
