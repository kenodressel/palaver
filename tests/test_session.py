"""Tests for RecordingSession (shared by `record` and the daemon)."""

import json
from pathlib import Path

import pytest

from palaver.session import RecordingSession


class _FakeCapture:
    system_source = "process-tap"

    def __init__(self, paths, fail=False):
        self.paths, self.fail = paths, fail

    def start(self):
        if self.fail:
            raise RuntimeError("SCStream startCapture failed")

    def stop(self):
        for wav in (self.paths.mic_raw_wav, self.paths.system_wav):
            wav.write_bytes(b"")


def test_session_writes_meta_and_session_log(tmp_path: Path):
    s = RecordingSession(tmp_path, trigger="teams", capture_factory=_FakeCapture)
    folder = s.start()
    assert s.system_source == "process-tap" and s.recording
    duration = s.stop()
    assert not s.recording

    assert folder.parent == tmp_path
    assert duration >= 0
    meta = json.loads((folder / "meta.json").read_text())
    assert meta["duration_seconds"] == duration
    assert meta["trigger"] == "teams"
    events = [json.loads(l).get("event") for l in (folder / "session.log").read_text().splitlines()]
    assert events == ["record_start", "record_stop"]
    assert json.loads((folder / "session.log").read_text().splitlines()[0])["trigger"] == "teams"


def test_failed_start_detaches_log_and_raises(tmp_path: Path):
    import logging

    before = list(logging.getLogger("palaver").handlers)
    s = RecordingSession(tmp_path, capture_factory=lambda p: _FakeCapture(p, fail=True))
    with pytest.raises(RuntimeError, match="startCapture"):
        s.start()
    assert not s.recording
    assert logging.getLogger("palaver").handlers == before


def test_session_keeps_why_it_stopped_and_what_it_records_with(tmp_path: Path):
    class _Capture(_FakeCapture):
        mic_device, mic_rate, system_rate = "AirPods", 24000.0, 48000.0

    s = RecordingSession(tmp_path, trigger="teams", capture_factory=_Capture)
    folder = s.start()
    assert (s.mic_device, s.mic_rate, s.system_rate) == ("AirPods", 24000.0, 48000.0)
    s.stop("call_ended")
    assert json.loads((folder / "meta.json").read_text())["stop_reason"] == "call_ended"


def test_audio_problems_go_into_meta_json(tmp_path: Path):
    """Issue #50: the meeting page shows "Audio problem at 12:14 (…)"."""
    class _Capture(_FakeCapture):
        system_device = "AirPods Pro"
        problems = [{"id": 1, "kind": "speed", "track": "system", "start": 480.0, "end": 600.0}]

    s = RecordingSession(tmp_path, trigger="teams", capture_factory=_Capture)
    folder = s.start()
    assert s.system_device == "AirPods Pro" and s.problems == _Capture.problems
    (folder / "audio_problems.json").write_text("[]")  # what the recorder kept for a crash
    s.stop()
    meta = json.loads((folder / "meta.json").read_text())
    assert meta["audio_problems"] == [{"kind": "speed", "track": "system", "start": 480.0, "end": 600.0}]
    assert not (folder / "audio_problems.json").exists()  # folded in


def test_no_audio_problems_no_key(tmp_path: Path):
    s = RecordingSession(tmp_path, trigger="teams", capture_factory=_FakeCapture)
    folder = s.start()
    s.stop()
    assert "audio_problems" not in json.loads((folder / "meta.json").read_text())
