from __future__ import annotations

import argparse
import json
import sys
import tempfile
from pathlib import Path

from podcast_stripper import __version__
from podcast_stripper.convert import convert_for_diarization, convert_for_export, is_supported_audio
from podcast_stripper.export import export_speaker_tracks
from podcast_stripper.ffmpeg_bin import FFmpegError, find_ffmpeg
from podcast_stripper.progress import done, error, heartbeat, status
from podcast_stripper.token_store import TokenError, resolve_token, save_token, token_is_set


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    json_progress = bool(args.json_progress)

    if args.check_setup:
        return _print_setup(json_progress=json_progress)

    if args.save_token is not None:
        try:
            message = save_token(args.save_token)
        except TokenError as exc:
            error(str(exc), exc.code, json_progress=json_progress)
            return 2
        status("setup", 100, message, json_progress=json_progress)
        return 0

    if not args.input:
        parser.print_help()
        return 2

    cleaned = str(args.input).strip().strip("'\"")
    input_path = Path(cleaned).expanduser().resolve()
    if not input_path.is_file():
        error(f"Could not find that audio file: {input_path}", "missing_input", json_progress=json_progress)
        return 2
    if not is_supported_audio(input_path):
        error(
            f"Unsupported file type: {input_path.suffix}. Use mp3, m4a, wav, aiff, or flac.",
            "unsupported_format",
            json_progress=json_progress,
        )
        return 2

    output_dir = (
        Path(args.output).expanduser().resolve()
        if args.output
        else input_path.parent / f"{input_path.stem}_speakers"
    )
    output_existed = output_dir.exists()

    try:
        find_ffmpeg()
    except FFmpegError as exc:
        error(str(exc), exc.code, json_progress=json_progress)
        return 2

    try:
        manifest = _run_job(
            input_path=input_path,
            output_dir=output_dir,
            args=args,
            json_progress=json_progress,
        )
    except TokenError as exc:
        error(str(exc), exc.code, json_progress=json_progress)
        _remove_empty_output_dir(output_dir, created=not output_existed)
        return 2
    except FFmpegError as exc:
        error(str(exc), exc.code, json_progress=json_progress)
        _remove_empty_output_dir(output_dir, created=not output_existed)
        return 2
    except Exception as exc:
        code = getattr(exc, "code", "failed")
        error(str(exc), str(code), json_progress=json_progress)
        _remove_empty_output_dir(output_dir, created=not output_existed)
        return 1

    done(
        {
            "output_dir": str(manifest.get("output_dir") or output_dir),
            "tracks": [item["path"] for item in manifest.get("speakers") or []]
            + ([manifest["music"]["path"]] if manifest.get("music") else []),
            "speakers": manifest.get("speakers") or [],
            "music": manifest.get("music"),
            "duration": manifest.get("duration"),
        },
        json_progress=json_progress,
    )
    return 0


def _run_job(input_path: Path, output_dir: Path, args: argparse.Namespace, json_progress: bool) -> dict:
    def report(stage: str, percent: float, message: str) -> None:
        status(stage, percent, message, json_progress=json_progress)

    with tempfile.TemporaryDirectory(prefix="podcast-stripper-") as tmp:
        tmp_dir = Path(tmp)
        original_wav = tmp_dir / "original.wav"
        diarize_wav = tmp_dir / "diarize.wav"
        voice_wav = None
        music_wav = None

        report("convert", 6, "Preparing a working copy of your audio…")
        with heartbeat(
            report,
            stage="convert",
            start_percent=6,
            cap_percent=14,
            message="Still preparing a working copy of your audio…",
        ):
            convert_for_export(input_path, original_wav)

        skip_separate = args.from_segments or args.skip_separate
        if not skip_separate:
            try:
                from podcast_stripper.separate import separate_vocals

                vocals_path, other_path = separate_vocals(
                    original_wav,
                    tmp_dir / "stems",
                    on_progress=report,
                )
                voice_wav = vocals_path
                music_wav = other_path
            except Exception as exc:
                report(
                    "separate",
                    44,
                    "Could not fully unmix music under speech; keeping intros and gaps instead.",
                )
                sys.stderr.write(f"music separation fallback: {type(exc).__name__}: {str(exc)[:300]}\n")
                voice_wav = None
                music_wav = None

        report("convert", 46, "Preparing audio for speaker detection…")
        with heartbeat(
            report,
            stage="convert",
            start_percent=46,
            cap_percent=54,
            message="Still preparing audio for speaker detection…",
        ):
            convert_for_diarization(original_wav, diarize_wav)

        if args.from_segments:
            segments = _load_segments(Path(args.from_segments))
            report("diarize", 80, "Using provided speaker turns…")
        else:
            from podcast_stripper.diarize import run_diarization

            token = resolve_token(args.hf_token)
            bounds = _speaker_bounds(args)
            segments = run_diarization(
                diarize_wav,
                token=token,
                on_progress=report,
                **bounds,
            )

        report("export", 88, "Writing speaker tracks and a music/SFX track…")
        with heartbeat(
            report,
            stage="export",
            start_percent=88,
            cap_percent=96,
            message="Still writing speaker tracks and a music/SFX track…",
        ):
            manifest = export_speaker_tracks(
                input_path,
                output_dir,
                segments,
                work_wav=original_wav,
                voice_wav=voice_wav,
                music_wav=music_wav,
            )

    manifest_path = output_dir / "speakers.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    report("export", 100, "Done.")
    return manifest


def _remove_empty_output_dir(output_dir: Path, *, created: bool) -> None:
    """If a job dies mid-run, don't leave an empty output folder."""
    if not created:
        return
    try:
        if output_dir.is_dir() and not any(output_dir.iterdir()):
            output_dir.rmdir()
    except OSError:
        pass


def _speaker_bounds(args: argparse.Namespace) -> dict[str, int | None]:
    """Pass Speakers as exact N, or a wide Auto range."""
    if args.min_speakers is not None or args.max_speakers is not None:
        return {
            "num_speakers": args.num_speakers,
            "min_speakers": args.min_speakers,
            "max_speakers": args.max_speakers,
        }
    if args.num_speakers:
        return {"num_speakers": args.num_speakers}
    return {"min_speakers": 1, "max_speakers": 8}


def _load_segments(path: Path) -> list[tuple[float, float, str]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    rows = data["segments"] if isinstance(data, dict) and "segments" in data else data
    segments: list[tuple[float, float, str]] = []
    for row in rows:
        segments.append((float(row["start"]), float(row["end"]), str(row["speaker"])))
    return segments


def _print_setup(json_progress: bool) -> int:
    ffmpeg_path = None
    ffmpeg_error = None
    try:
        from podcast_stripper.ffmpeg_bin import find_ffmpeg

        ffmpeg_path = find_ffmpeg()
    except Exception as exc:
        ffmpeg_error = str(exc)

    payload = {
        "event": "setup",
        "version": __version__,
        "ffmpeg": ffmpeg_path,
        "ffmpeg_ok": ffmpeg_path is not None,
        "ffmpeg_error": ffmpeg_error,
        "token_ok": token_is_set(),
        "model": "pyannote/speaker-diarization-community-1",
        "model_terms_url": "https://huggingface.co/pyannote/speaker-diarization-community-1",
    }
    if json_progress:
        print(json.dumps(payload), flush=True)
    else:
        print(f"ffmpeg: {'ok — ' + ffmpeg_path if ffmpeg_path else 'missing'}")
        print(f"Hugging Face token: {'saved' if payload['token_ok'] else 'not saved'}")
        print("Accept model terms at", payload["model_terms_url"])
    return 0 if payload["ffmpeg_ok"] else 1


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="podcast-stripper",
        description="Split a mixed podcast into speaker tracks plus a music/SFX track.",
    )
    parser.add_argument("input", nargs="?", help="Path to an mp3, m4a, wav, aiff, or flac file")
    parser.add_argument("-o", "--output", help="Folder for the exported tracks")
    parser.add_argument("--num-speakers", type=int, help="Exact speaker count, if you know it")
    parser.add_argument("--min-speakers", type=int, help="Lowest speaker count to consider")
    parser.add_argument("--max-speakers", type=int, help="Highest speaker count to consider")
    parser.add_argument("--hf-token", help="Hugging Face access token (otherwise Keychain or HF_TOKEN)")
    parser.add_argument("--save-token", metavar="TOKEN", help="Save a Hugging Face token to the Keychain and exit")
    parser.add_argument("--json-progress", action="store_true", help="Print machine-readable progress lines")
    parser.add_argument("--check-setup", action="store_true", help="Check ffmpeg and token, then exit")
    parser.add_argument(
        "--from-segments",
        help="Skip the AI model and split using a JSON file of speaker turns (for tests)",
    )
    parser.add_argument(
        "--skip-separate",
        action="store_true",
        help="Skip music/SFX unmixing; still keep intros and gaps on a Music_and_SFX track",
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    return parser
