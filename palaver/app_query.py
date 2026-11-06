"""`palaver app query <what> [arg] --json`: answers the native app asks of the
Python side while it has no Swift port of them (missing models, the search
index, the notes' memory, the calendar). One JSON object on stdout, nothing else."""

from __future__ import annotations

import contextlib
import json
import sys
from datetime import datetime, timedelta

WHATS = ("missing-models", "index-stale", "notes-memory", "next-event", "event-key", "notion-auto-sync")


def _events(cfg, start: datetime, end: datetime) -> list | None:
    """The calendar's events between two moments; None when the calendar is off
    or has not been allowed (never asks)."""
    if not getattr(cfg, "calendar_enabled", False):
        return None
    from . import calendar_eventkit

    if not calendar_eventkit.has_access():
        return None
    return calendar_eventkit.events_between(start, end)


def answer(what: str, args: list[str], cfg) -> dict:
    from pathlib import Path

    if what == "missing-models":
        from . import process_state
        from .paths import RecordingPaths

        return {"missing": process_state.missing_models(cfg, RecordingPaths(Path(args[0])))}
    if what == "index-stale":
        from . import semantic

        # The model's first run downloads it (the status says so, #46).
        return {"stale": [str(p.folder) for p in semantic.stale(cfg.output_dir)],
                "model_ready": semantic.embeddings.model_folder(download=False) is not None}
    if what == "notes-memory":
        from . import llm

        return {"gb": llm.notes_memory_gb(cfg, Path(args[0]))}
    if what == "next-event":
        now = datetime.now().astimezone()
        events = _events(cfg, now, now + timedelta(hours=24))
        upcoming = sorted((e for e in events or [] if not e.all_day and e.start > now), key=lambda e: e.start)
        if not upcoming:
            return {"event": None}
        e = upcoming[0]
        return {"event": {"title": e.title, "start": e.start.isoformat(), "end": e.end.isoformat(), "key": e.key}}
    if what == "event-key":
        from .calendar_events import event_key_at

        when = datetime.fromisoformat(args[0])
        if when.tzinfo is None:
            when = when.astimezone()
        events = _events(cfg, when - timedelta(hours=2), when + timedelta(hours=2))
        return {"key": event_key_at(events, when) if events else None}
    if what == "notion-auto-sync":
        # Upload after the call (`run`), or `process` and the notes apart: the token may be in
        # the Keychain, which only the Python Config looks at.
        return {"auto_sync": bool(getattr(cfg, "notion_auto_sync", False)),
                "notes": bool(getattr(cfg, "notes_enabled", True))}
    raise ValueError(what)


def run(what: str | None, args: list[str], cfg) -> int:
    """``cfg``: the Config, or a function that loads it (so a malformed config.toml is an
    error answer too). stdout carries the one JSON line only: while the answer is computed
    fd 1 points at stderr, so nothing else (a library's print) can mix into it."""
    import os

    needs = {"missing-models": 1, "notes-memory": 1, "event-key": 1}
    if what not in WHATS or len(args) < needs.get(what, 0):
        print(json.dumps({"error": f"usage: palaver app query {{{'|'.join(WHATS)}}} [folder|time] --json"}))
        return 2
    sys.stdout.flush()
    saved = os.dup(1)
    os.dup2(2, 1)
    try:
        with contextlib.redirect_stdout(sys.stderr):  # Python's print too, whatever sys.stdout is
            result, rc = answer(what, args, cfg() if callable(cfg) else cfg), 0
    except Exception as exc:
        result, rc = {"error": str(exc) or type(exc).__name__}, 1
    finally:
        sys.stdout.flush()
        os.dup2(saved, 1)
        os.close(saved)
    sys.stdout.write(json.dumps(result) + "\n")
    sys.stdout.flush()
    return rc
