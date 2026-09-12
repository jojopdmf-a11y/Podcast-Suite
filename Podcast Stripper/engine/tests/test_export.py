from __future__ import annotations

import json
import math
import wave
from pathlib import Path

import numpy as np
import pytest

from podcast_stripper.export import (
    build_nonvoice_track,
    build_speaker_track,
    export_speaker_tracks,
    load_wav,
    save_wav,
)


def test_prune_tiny_speakers_drops_almost_empty_cluster():
    from podcast_stripper.diarize import prune_tiny_speakers

    segments = [
        (0.0, 20.0, "SPEAKER_00"),
        (20.0, 40.0, "SPEAKER_01"),
        (40.05, 40.2, "SPEAKER_02"),
    ]
    kept = prune_tiny_speakers(segments, min_seconds=3.0, min_ratio=0.03)
    speakers = {speaker for _, _, speaker in kept}
    assert speakers == {"SPEAKER_00", "SPEAKER_01"}



def test_load_waveform_is_channels_first_float(tmp_path: Path):
    from podcast_stripper.diarize import load_waveform

    source = tmp_path / "tone.wav"
    _write_wav(source, [_sine(440, 0.25, 16000)], 16000)
    payload = load_waveform(source)
    assert payload["sample_rate"] == 16000
    assert payload["waveform"].ndim == 2
    assert payload["waveform"].shape[0] == 1
    assert payload["waveform"].shape[1] == 4000



def _sine(frequency: float, seconds: float, sample_rate: int, amplitude: float = 0.3) -> np.ndarray:
    times = np.arange(int(seconds * sample_rate), dtype=np.float64) / sample_rate
    samples = (amplitude * np.sin(2 * math.pi * frequency * times) * 32767).astype(np.int16)
    return samples.reshape(-1, 1)


def _write_wav(path: Path, chunks: list[np.ndarray], sample_rate: int) -> None:
    audio = np.concatenate(chunks, axis=0)
    save_wav(path, audio, sample_rate)


def test_build_speaker_track_keeps_only_that_speakers_turns():
    sample_rate = 16000
    audio = np.concatenate(
        [
            _sine(440, 1.0, sample_rate),
            np.zeros((sample_rate, 1), dtype=np.int16),
            _sine(880, 1.0, sample_rate),
        ]
    )
    speaker_a = build_speaker_track(audio, sample_rate, [(0.0, 1.0)])
    speaker_b = build_speaker_track(audio, sample_rate, [(2.0, 3.0)])

    assert speaker_a.shape == audio.shape
    assert speaker_b.shape == audio.shape
    assert np.max(np.abs(speaker_a[:sample_rate])) > 1000
    assert np.max(np.abs(speaker_a[sample_rate : 2 * sample_rate])) == 0
    assert np.max(np.abs(speaker_b[2 * sample_rate :])) > 1000
    assert np.max(np.abs(speaker_b[: 2 * sample_rate])) == 0


def test_export_writes_aligned_wavs_and_manifest(tmp_path: Path):
    sample_rate = 16000
    source = tmp_path / "mix.wav"
    _write_wav(
        source,
        [
            _sine(440, 1.0, sample_rate),
            np.zeros((sample_rate, 1), dtype=np.int16),
            _sine(220, 1.0, sample_rate),
        ],
        sample_rate,
    )
    output_dir = tmp_path / "out"
    manifest = export_speaker_tracks(
        source,
        output_dir,
        [(0.0, 1.0, "SPEAKER_00"), (2.0, 3.0, "SPEAKER_01")],
        work_wav=source,
    )

    assert len(manifest["speakers"]) == 2
    paths = [Path(item["path"]) for item in manifest["speakers"]]
    assert all(path.is_file() for path in paths)

    first, first_sr = load_wav(paths[0])
    second, second_sr = load_wav(paths[1])
    original, _ = load_wav(source)
    assert first_sr == sample_rate == second_sr
    assert first.shape == original.shape == second.shape
    # Soft gates leave a short hold; the middle of the gap should stay quiet.
    mid = sample_rate + sample_rate // 2
    assert np.max(np.abs(first[mid : mid + 1000])) < 500
    assert np.max(np.abs(second[: sample_rate // 2])) < 500
    music_path = output_dir / "Music_and_SFX.wav"
    assert music_path.is_file()
    music, music_sr = load_wav(music_path)
    assert music_sr == sample_rate
    assert music.shape == original.shape
    assert np.max(np.abs(music[sample_rate // 4 : sample_rate // 2])) < 500
    assert manifest["music"]["method"] in {"gaps", "music_aware"}


def test_nonvoice_track_keeps_intro_and_mutes_speech():
    sample_rate = 16000
    intro = _sine(120, 1.0, sample_rate)
    speech = _sine(440, 1.0, sample_rate)
    audio = np.concatenate([intro, speech])
    music = build_nonvoice_track(audio, sample_rate, [(1.0, 2.0, "SPEAKER_00")])
    assert np.max(np.abs(music[:sample_rate])) > 1000
    assert np.max(np.abs(music[sample_rate:])) == 0


def test_music_bed_keeps_original_and_trims_tail():
    from podcast_stripper.cleanup import build_music_and_sfx

    sample_rate = 16000
    music = _sine(90, 1.5, sample_rate, amplitude=0.4)
    speech = _sine(440, 1.0, sample_rate, amplitude=0.3)
    quiet = np.zeros((sample_rate, 1), dtype=np.int16)
    garbage = (np.random.RandomState(0).randn(sample_rate, 1) * 200).astype(np.int16)
    original = np.concatenate([music, speech, quiet], axis=0)
    accompaniment = np.concatenate([music, np.zeros_like(speech), garbage], axis=0)
    vocals = np.concatenate([np.zeros_like(music), speech, quiet], axis=0)
    out, meta = build_music_and_sfx(
        original,
        accompaniment,
        sample_rate,
        [(1.5, 2.5, "SPEAKER_00")],
        vocals=vocals,
    )
    assert meta["method"] == "music_aware"
    assert meta["music_coverage"] < 0.6
    assert np.max(np.abs(out[:sample_rate])) > 1000
    assert np.max(np.abs(out[-sample_rate // 2 :])) < 50
    assert meta.get("garbage_cut_at") is not None


def test_speech_bleed_is_not_treated_as_music_bed():
    from podcast_stripper.cleanup import music_activity_mask

    sample_rate = 16000
    # Demucs often leaves a quiet residual in "other" under speech.
    speech = _sine(440, 3.0, sample_rate, amplitude=0.35)
    bleed = (speech.astype(np.float64) * 0.15).astype(np.int16)
    mask = music_activity_mask(bleed, sample_rate, vocals=speech)
    assert float(np.mean(mask > 0.2)) < 0.05


def test_soft_gate_fades_instead_of_hard_cut():
    from podcast_stripper.cleanup import build_speaker_track_soft

    sample_rate = 16000
    # Continuous tone so the fade region still has content to pass.
    audio = _sine(440, 2.0, sample_rate)
    hard = build_speaker_track(audio, sample_rate, [(0.0, 1.0)])
    soft = build_speaker_track_soft(audio, sample_rate, [(0.0, 1.0)], fade_ms=40, hold_ms=0)
    edge = sample_rate
    assert np.max(np.abs(hard[edge : edge + 200])) == 0
    assert np.max(np.abs(soft[edge : edge + 200])) > 0


def test_cli_from_segments(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    from podcast_stripper.cli import main

    sample_rate = 16000
    source = tmp_path / "episode.wav"
    _write_wav(
        source,
        [_sine(440, 0.5, sample_rate), _sine(660, 0.5, sample_rate)],
        sample_rate,
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

    monkeypatch.setenv("IMAGEIO_FFMPEG_EXE", "ffmpeg-not-needed-for-this-branch")
    # convert still needs ffmpeg unless we pass from-segments AND convert uses ffmpeg.
    # The CLI always converts with ffmpeg. Skip this if ffmpeg is missing by mocking convert.

    from podcast_stripper import cli as cli_mod

    def fake_export_convert(input_path: Path, output_wav: Path) -> None:
        output_wav.write_bytes(source.read_bytes())

    def fake_diarize_convert(input_path: Path, output_wav: Path) -> None:
        output_wav.write_bytes(source.read_bytes())

    monkeypatch.setattr(cli_mod, "convert_for_export", fake_export_convert)
    monkeypatch.setattr(cli_mod, "convert_for_diarization", fake_diarize_convert)
    monkeypatch.setattr(cli_mod, "find_ffmpeg", lambda: "/usr/bin/true")

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
    assert (output_dir / "speakers.json").is_file()
    assert (output_dir / "Speaker_1.wav").is_file()
    assert (output_dir / "Speaker_2.wav").is_file()
    assert (output_dir / "Music_and_SFX.wav").is_file()

    with wave.open(str(output_dir / "Speaker_1.wav"), "rb") as handle:
        assert handle.getnframes() == sample_rate


def test_mix_aligned_wavs_sums_without_extra_gain(tmp_path: Path):
    from podcast_stripper.export import mix_aligned_wavs, reconstruction_stats

    sample_rate = 16000
    left = tmp_path / "a.wav"
    right = tmp_path / "b.wav"
    _write_wav(left, [_sine(440, 0.5, sample_rate, amplitude=0.2)], sample_rate)
    _write_wav(right, [_sine(440, 0.5, sample_rate, amplitude=0.2)], sample_rate)
    dest = tmp_path / "sum.wav"
    mix_aligned_wavs([left, right], dest)
    mixed, _ = load_wav(dest)
    single, _ = load_wav(left)
    assert mixed.shape == single.shape
    assert np.max(np.abs(mixed)) > np.max(np.abs(single))
    stats = reconstruction_stats(left, left)
    assert stats["correlation"] > 0.99


def test_overlap_share_does_not_double_level():
    from podcast_stripper.cleanup import apply_gate, shared_speaker_gates

    sample_rate = 16000
    tone = _sine(440, 1.0, sample_rate, amplitude=0.3)
    gates = shared_speaker_gates(
        tone.shape[0],
        sample_rate,
        [[(0.0, 1.0)], [(0.0, 1.0)]],
        hold_ms=0,
        fade_ms=10,
    )
    first = apply_gate(tone, gates[0]).astype(np.float64)
    second = apply_gate(tone, gates[1]).astype(np.float64)
    summed = first + second
    original = tone.astype(np.float64)
    mid = slice(sample_rate // 4, 3 * sample_rate // 4)
    rms_sum = float(np.sqrt(np.mean(summed[mid] ** 2)))
    rms_orig = float(np.sqrt(np.mean(original[mid] ** 2)))
    rms_a = float(np.sqrt(np.mean(first[mid] ** 2)))
    rms_b = float(np.sqrt(np.mean(second[mid] ** 2)))
    assert rms_sum / rms_orig < 1.2
    assert max(rms_a, rms_b) > min(rms_a, rms_b) * 2.5


def test_overlap_keeps_prior_speaker_dominant():
    from podcast_stripper.cleanup import shared_speaker_gates

    sample_rate = 16000
    length = sample_rate
    gates = shared_speaker_gates(
        length,
        sample_rate,
        [[(0.0, 0.8)], [(0.4, 1.0)]],
        hold_ms=0,
        fade_ms=10,
    )
    overlap = int(0.6 * sample_rate)
    early = int(0.2 * sample_rate)
    late = int(0.9 * sample_rate)
    assert gates[0][overlap] > gates[1][overlap] * 2
    assert gates[0][early] > 0.9
    assert gates[1][early] < 0.2
    assert gates[1][late] > 0.9
    assert gates[0][late] < 0.25


def test_solo_regions_stay_full_level():
    from podcast_stripper.cleanup import shared_speaker_gates

    sample_rate = 16000
    length = sample_rate
    gates = shared_speaker_gates(
        length,
        sample_rate,
        [[(0.0, 0.45)], [(0.55, 1.0)]],
        hold_ms=0,
        fade_ms=10,
    )
    assert gates[0][int(0.2 * sample_rate)] > 0.95
    assert gates[1][int(0.2 * sample_rate)] < 0.08
    assert gates[1][int(0.8 * sample_rate)] > 0.95
    assert gates[0][int(0.8 * sample_rate)] < 0.08


def test_export_overlap_mixdown_stays_near_original(tmp_path: Path):
    sample_rate = 16000
    source = tmp_path / "overlap.wav"
    _write_wav(source, [_sine(440, 1.0, sample_rate, amplitude=0.3)], sample_rate)
    output_dir = tmp_path / "out"
    export_speaker_tracks(
        source,
        output_dir,
        [(0.0, 1.0, "SPEAKER_00"), (0.0, 1.0, "SPEAKER_01")],
        work_wav=source,
    )
    first, _ = load_wav(output_dir / "Speaker_1.wav")
    second, _ = load_wav(output_dir / "Speaker_2.wav")
    original, _ = load_wav(source)
    summed = first.astype(np.float64) + second.astype(np.float64)
    mid = slice(sample_rate // 4, 3 * sample_rate // 4)
    rms_sum = float(np.sqrt(np.mean(summed[mid] ** 2)))
    rms_orig = float(np.sqrt(np.mean(original.astype(np.float64)[mid] ** 2)))
    assert rms_sum / rms_orig < 1.2
    assert rms_sum / rms_orig > 0.7

