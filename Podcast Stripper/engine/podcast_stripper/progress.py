from __future__ import annotations

import json
import sys
from typing import Any


def emit(event: dict[str, Any], *, json_progress: bool) -> None:
    """Write a status event. JSON lines on stdout when the Mac app is listening."""
    if json_progress:
        sys.stdout.write(json.dumps(event, ensure_ascii=True) + "\n")
        sys.stdout.flush()
        return
    message = event.get("message")
    if message:
        print(message, file=sys.stderr, flush=True)


def status(
    stage: str,
    percent: float,
    message: str,
    *,
    json_progress: bool,
    **extra: Any,
) -> None:
    payload: dict[str, Any] = {
        "event": "status",
        "stage": stage,
        "percent": max(0, min(100, round(percent, 1))),
        "message": message,
    }
    payload.update(extra)
    emit(payload, json_progress=json_progress)


def done(payload: dict[str, Any], *, json_progress: bool) -> None:
    event = {"event": "done", **payload}
    emit(event, json_progress=json_progress)
    if not json_progress:
        output_dir = payload.get("output_dir")
        tracks = payload.get("tracks") or []
        print(f"Wrote {len(tracks)} track(s) to {output_dir}", file=sys.stderr, flush=True)


def error(message: str, code: str, *, json_progress: bool) -> None:
    emit({"event": "error", "message": message, "code": code}, json_progress=json_progress)
    if not json_progress:
        print(f"Error: {message}", file=sys.stderr, flush=True)
