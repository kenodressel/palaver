"""Coordinates audio capture; owns meta.json."""

from __future__ import annotations

import json
from datetime import datetime
from typing import Callable, Protocol

from .paths import RecordingPaths


class _WavRecorder(Protocol):
    def start(self) -> None: ...
    def stop(self) -> None: ...


class Recorder:
    def __init__(
        self,
        capture: _WavRecorder,
        paths: RecordingPaths,
        now: Callable[[], datetime] | None = None,
    ):
        self._capture = capture
        self._paths = paths
        self._now = now or (lambda: datetime.now().astimezone())
        self._start_time: datetime | None = None

    def start(self) -> None:
        self._start_time = self._now()
        self._capture.start()

    def stop(self) -> None:
        self._capture.stop()
        end = self._now()
        assert self._start_time is not None
        meta = {
            "start_time": self._start_time.isoformat(),
            "end_time": end.isoformat(),
            "duration_seconds": (end - self._start_time).total_seconds(),
        }
        self._paths.meta.write_text(json.dumps(meta, indent=2))
