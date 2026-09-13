from pathlib import Path

from podcast_stripper.ffmpeg_bin import find_ffmpeg


def test_find_ffmpeg_prefers_resources_copy(tmp_path: Path, monkeypatch) -> None:
    bundled = tmp_path / "ffmpeg"
    bundled.write_text("#!/bin/sh\n")
    bundled.chmod(0o755)
    monkeypatch.delenv("IMAGEIO_FFMPEG_EXE", raising=False)
    monkeypatch.delenv("FFMPEG_BINARY", raising=False)
    monkeypatch.setenv("PODCAST_STRIPPER_RESOURCES", str(tmp_path))
    find_ffmpeg.cache_clear()
    assert find_ffmpeg() == str(bundled)
