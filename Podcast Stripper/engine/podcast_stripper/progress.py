from __future__ import annotations

import json
import sys
import threading
import time
from contextlib import contextmanager
from typing import Any, Callable, Iterator

ProgressFn = Callable[[str, float, str], None]


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


def format_elapsed(seconds: float) -> str:
    elapsed = max(0, int(seconds))
    minutes, secs = divmod(elapsed, 60)
    if minutes:
        return f"{minutes}m {secs:02d}s"
    return f"{secs}s"


@contextmanager
def heartbeat(
    on_progress: ProgressFn | None,
    *,
    stage: str,
    start_percent: float,
    cap_percent: float,
    message: str,
    interval: float = 3.0,
) -> Iterator[None]:
    """Keep the Mac app moving during long native steps that otherwise go silent."""
    if on_progress is None or interval <= 0:
        yield
        return

    stop = threading.Event()
    started = time.monotonic()
    lock = threading.Lock()

    def beat() -> None:
        while not stop.wait(interval):
            elapsed = time.monotonic() - started
            crawled = min(cap_percent, start_percent + elapsed / 45.0)
            clock = format_elapsed(elapsed)
            with lock:
                on_progress(stage, crawled, f"{message} {clock}.")

    thread = threading.Thread(target=beat, name=f"{stage}-heartbeat", daemon=True)
    thread.start()
    try:
        yield
    finally:
        stop.set()
        thread.join(timeout=1.0)
