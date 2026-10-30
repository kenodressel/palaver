"""Per-recording JSON-lines log at ``<folder>/session.log`` (issue #2).

Every ``palaver.*`` logger record — capture warnings (mic stall,
tap fallback/rebuild, input-rate change) and pipeline events — is appended
as one JSON object per line while a command runs. Warnings are also shown on
stderr; on a terminal the live level meter's line is cleared first.
"""

from __future__ import annotations

import json
import logging
import sys
import time
import traceback
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from typing import Iterator

LOGGER = logging.getLogger("palaver")


class _JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        row = {
            "ts": datetime.fromtimestamp(record.created).astimezone().isoformat(),
            "level": record.levelname,
            "logger": record.name,
        }
        event = getattr(record, "event", None)
        if event is not None:
            row["event"] = event
        else:
            row["message"] = record.getMessage()
        row.update(getattr(record, "fields", {}))
        if record.exc_info:
            row["traceback"] = "".join(traceback.format_exception(*record.exc_info))
        return json.dumps(row, default=str)


class _StderrHandler(logging.StreamHandler):
    """Warnings to stderr, clearing a carriage-return status line first."""

    def __init__(self):
        super().__init__(sys.stderr)
        prefix = "\r\x1b[K" if sys.stderr.isatty() else ""
        self.setFormatter(logging.Formatter(prefix + "%(message)s"))
        self.setLevel(logging.WARNING)


class _Repeats(logging.Filter):
    """DEBUG is on (#59), also where a failure may repeat every tick or
    chunk: such a line is written once per REPEAT_SECONDS, not a thousand times."""

    REPEAT_SECONDS = 60.0

    def __init__(self):
        super().__init__()
        self._seen: dict[tuple, float] = {}

    def filter(self, record: logging.LogRecord) -> bool:
        if record.levelno > logging.DEBUG:
            return True
        key = (record.name, record.pathname, record.lineno, str(record.msg))
        last = self._seen.get(key)
        if last is not None and record.created - last < self.REPEAT_SECONDS:
            return False
        self._seen[key] = record.created
        return True


# The start of a process or a recording: stamped with which Palaver it is (#59).
STAMPED = {"process_start", "record_start", "live_start", "stream_start", "notes_start", "notion_upload_start",
           "daemon_start", "app_start", "webapp_start"}


def event(name: str, **fields) -> None:
    """Record a structured pipeline event."""
    if name in STAMPED:
        from .runlog import stamp

        fields = {**stamp(), **fields}
    LOGGER.info(name, extra={"event": name, "fields": fields})


@contextmanager
def session_log(path: Path) -> Iterator[None]:
    file_handler = logging.FileHandler(path, mode="a", encoding="utf-8")
    file_handler.setFormatter(_JsonFormatter())
    file_handler.addFilter(_Repeats())
    # Nested sessions (daemon.log + a recording's session.log) share the
    # outer stderr handler so warnings are printed once.
    nested = any(isinstance(h, _StderrHandler) for h in LOGGER.handlers)
    stderr_handler = None if nested else _StderrHandler()
    previous_level = LOGGER.level
    LOGGER.setLevel(logging.DEBUG)  # verbose while testing is internal (#59); never rotated
    LOGGER.addHandler(file_handler)
    if stderr_handler is not None:
        LOGGER.addHandler(stderr_handler)
    try:
        yield
    except BaseException as exc:
        if not isinstance(exc, (KeyboardInterrupt, SystemExit)):
            # Into the file only; the exception itself still propagates.
            if stderr_handler is not None:
                LOGGER.removeHandler(stderr_handler)
            LOGGER.error("command failed", exc_info=True)
        raise
    finally:
        for handler in (file_handler, stderr_handler):
            if handler is not None:
                LOGGER.removeHandler(handler)
        file_handler.close()
        LOGGER.setLevel(previous_level)


@contextmanager
def stage(name: str, **fields) -> Iterator[dict]:
    """Time a pipeline stage; logs ``<name>_start`` and ``<name>_done`` (with
    ``seconds`` and any fields the caller adds to the yielded dict), which is
    what the menu bar's progress display reads."""
    info = dict(fields)
    event(f"{name}_start", **fields)
    started = time.monotonic()
    yield info
    event(f"{name}_done", seconds=round(time.monotonic() - started, 1), **info)
