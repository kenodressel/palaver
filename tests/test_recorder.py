"""Tests for the recording coordinator."""

import json
from datetime import datetime, timezone
from pathlib import Path

import pytest

from palaver.paths import RecordingPaths
from palaver.recorder import Recorder


class _DummyRec:
    def __init__(self, path: Path):
        self.path = path
        self.started = False
        self.stopped = False

    def start(self):
        self.started = True
        self.path.write_bytes(b"RIFF...")  # pretend WAV

    def stop(self):
        self.stopped = True


def _fixed_now_factory(values):
    it = iter(values)
    return lambda: next(it)


def test_recorder_writes_meta_json(tmp_path: Path):
    paths = RecordingPaths(tmp_path)
    capture = _DummyRec(paths.mic_raw_wav)

    start_time = datetime(2026, 4, 17, 14, 30, 0, tzinfo=timezone.utc)
    stop_time = datetime(2026, 4, 17, 14, 35, 0, tzinfo=timezone.utc)
    now = _fixed_now_factory([start_time, stop_time])

    r = Recorder(capture=capture, paths=paths, now=now)
    r.start()
    assert capture.started

    r.stop()
    assert capture.stopped

    meta = json.loads(paths.meta.read_text())
    assert meta["start_time"] == start_time.isoformat()
    assert meta["end_time"] == stop_time.isoformat()
    assert meta["duration_seconds"] == 300.0
