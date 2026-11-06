"""Lines the Swift app writes (native SessionLog, AudioHealthMonitor) read through Python's readers.

The fixtures in tests/fixtures/swift_session/ have the exact shape native/Tests/PalaverCoreTests/SessionLogTests.swift
pins byte for byte: Python's ``session_log`` format, with the audio health events of capture_recorder.py."""

import json
import shutil
from datetime import datetime
from pathlib import Path

from palaver import doctor, lifecycle, report
from palaver.cli import _fold_audio_problems
from palaver.paths import RecordingPaths

FIXTURES = Path(__file__).parent / "fixtures" / "swift_session"
SINCE = datetime.fromisoformat("2026-10-29T00:00:00+01:00")


def _rows() -> list[dict]:
    return [json.loads(line) for line in (FIXTURES / "session.log").read_text().splitlines()]


def test_every_line_is_json_with_pythons_leading_keys():
    for row in _rows():
        assert list(row)[:3] == ["ts", "level", "logger"]
        assert report._parse_ts(row["ts"]) is not None
        assert row["logger"] == "palaver.capture_recorder"
        assert ("event" in row) != ("message" in row)


def test_report_timeline_reads_the_events_and_the_warning():
    entries = report.timeline_entries("session.log", (FIXTURES / "session.log").read_text(), SINCE)
    levels = [(level, text.split(" ")[0]) for _, level, _, text in entries]
    assert ("EVENT", "record_start") in levels and ("EVENT", "audio_problem_over") in levels
    assert ("WARNING", "audio_problem") in levels  # a WARNING event keeps its level
    assert any(level == "WARNING" and "cannot write the microphone track" in text for _, level, _, text in entries)
    problem = next(text for _, level, _, text in entries if text.startswith("audio_problem "))
    assert "kind=speed" in problem and "track=system" in problem and "reanchors_per_minute=3" in problem


def test_report_pipeline_lists_the_record_events():
    steps = report.pipeline((FIXTURES / "session.log").read_text())
    assert any("record_start" in s for s in steps) and any("record_stop" in s for s in steps)
    assert any("cannot write the microphone track" in s for s in steps)  # the WARNING message line


def test_doctor_reads_the_record_start_line(tmp_path: Path):
    folder = tmp_path / "2026-10-29T12-06-00"
    folder.mkdir()
    shutil.copy(FIXTURES / "session.log", folder / "session.log")
    check = doctor.check_system_audio(tmp_path)
    assert check.status == "ok" and "Process Tap worked" in check.detail


def test_the_kept_problems_fold_into_meta_and_read_in_words(tmp_path: Path):
    paths = RecordingPaths(tmp_path)
    shutil.copy(FIXTURES / "audio_problems.json", paths.audio_problems)
    paths.meta.write_text(json.dumps({"start_time": "2026-10-29T12:06:00+01:00", "duration_seconds": 180.0}))
    _fold_audio_problems(paths)
    problems = json.loads(paths.meta.read_text())["audio_problems"]
    assert [(p["kind"], p["track"], p["end"]) for p in problems] == [("speed", "system", 60.0), ("write", "mic", 180.0)]
    start = datetime.fromisoformat("2026-10-29T12:06:00+01:00")
    assert lifecycle.problem_text(problems[0], start) == "Audio problem at 12:06 (system audio played at the wrong speed)"
    # The kinds only Swift writes have words too.
    assert lifecycle.problem_text(problems[1], start) == "Audio problem at 12:08 (microphone could not be written to disk)"
    assert lifecycle.problem_warning(problems[1]) == (
        "Microphone cannot be written to disk; audio is being lost — is the disk full?")
    assert lifecycle.problem_warning({"kind": "dropped", "track": "system"}) == (
        "System audio is losing audio: the recorder cannot keep up")
