"""Tests for the per-session JSON-lines log (issue #2)."""

import json
import logging
from pathlib import Path

from palaver.session_log import event, session_log


def _lines(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines()]


def test_events_and_module_warnings_land_in_session_log(tmp_path: Path):
    log = tmp_path / "session.log"
    with session_log(log):
        event("record_start", system_source="process-tap")
        logging.getLogger("palaver.capture_recorder").warning("mic stalled")

    rows = _lines(log)
    assert rows[0]["event"] == "record_start"
    assert rows[0]["system_source"] == "process-tap"
    assert "ts" in rows[0]
    assert rows[1]["level"] == "WARNING"
    assert rows[1]["message"] == "mic stalled"
    assert rows[1]["logger"] == "palaver.capture_recorder"


def test_session_log_appends_across_commands(tmp_path: Path):
    log = tmp_path / "session.log"
    with session_log(log):
        event("record_stop")
    with session_log(log):
        event("process_start")
    assert [r["event"] for r in _lines(log)] == ["record_stop", "process_start"]


def test_exceptions_are_logged_with_traceback(tmp_path: Path):
    log = tmp_path / "session.log"
    try:
        with session_log(log):
            raise RuntimeError("diarization exploded")
    except RuntimeError:
        pass
    row = _lines(log)[-1]
    assert row["level"] == "ERROR"
    assert "diarization exploded" in row["traceback"]


def test_handlers_are_removed_after_session(tmp_path: Path):
    logger = logging.getLogger("palaver")
    before = list(logger.handlers)
    with session_log(tmp_path / "session.log"):
        pass
    assert logger.handlers == before
    event("after")  # must not write anywhere or crash
    assert "after" not in (tmp_path / "session.log").read_text()


def test_nested_sessions_print_each_warning_once(tmp_path: Path, capsys):
    """The daemon keeps daemon.log open while a recording opens its own
    session.log; warnings must not be printed twice."""
    with session_log(tmp_path / "daemon.log"):
        with session_log(tmp_path / "session.log"):
            logging.getLogger("palaver.capture_recorder").warning("mic stalled")
    assert capsys.readouterr().err.count("mic stalled") == 1
    assert "mic stalled" in (tmp_path / "daemon.log").read_text()
    assert "mic stalled" in (tmp_path / "session.log").read_text()


def test_stage_logs_start_and_done(tmp_path: Path):
    from palaver.session_log import stage

    log = tmp_path / "session.log"
    with session_log(log):
        with stage("transcribe", track="mic") as info:
            info.update(segments=3)
    rows = _lines(log)
    assert [r["event"] for r in rows] == ["transcribe_start", "transcribe_done"]
    assert rows[0]["track"] == "mic" and rows[1]["segments"] == 3


def test_start_events_carry_the_version_and_commit(tmp_path: Path, monkeypatch):
    """A log read weeks later says which Palaver wrote it (#59)."""
    from palaver import __version__, runlog

    monkeypatch.setattr(runlog, "git_info", lambda: {"commit": "abc1234def", "dirty": True, "branch": "master"})
    log = tmp_path / "session.log"
    with session_log(log):
        event("record_start", trigger="teams")
        event("transcribe_start", track="mic")
    start, stage_start = _lines(log)
    assert start["version"] == __version__ and start["commit"] == "abc1234def" and start["dirty"] is True
    assert start["pid"] > 0 and start["trigger"] == "teams"
    assert "version" not in stage_start  # a step of a process, not a process


def test_debug_lines_are_logged_and_a_repeating_one_only_once_a_minute(tmp_path: Path):
    log = tmp_path / "session.log"
    with session_log(log):
        for _ in range(50):
            logging.getLogger("palaver.daemon").debug("reading the silence failed")
        logging.getLogger("palaver.daemon").debug("something else")
    rows = _lines(log)
    assert [r["message"] for r in rows] == ["reading the silence failed", "something else"]
    assert rows[0]["level"] == "DEBUG"
