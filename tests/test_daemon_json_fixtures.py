"""daemon.json across the two apps (phase 2, Task 8).

- tests/fixtures/python_daemon/: written by the Python app's Daemon (tools/make_daemon_json_fixture.py);
  the Swift daemon's tests compare its keys and value shapes with them and take over its queue,
  cut and ignored holds (`daemonJsonKeysMatchPython`, `restoresPythonDaemonJson`).
- tests/fixtures/swift_daemon/daemon.json: written by the Swift daemon (native/Tests/PalaverDaemonTests
  `swiftDaemonJsonFixture`, byte for byte); read here through Python's readers: the window's
  server (webapp/remote.py), doctor, `recording_into` (process), `read_status` and `busy_reason`.
Fictional folders only."""

from __future__ import annotations

import json
import os
from datetime import datetime, timedelta
from pathlib import Path

import pytest

from palaver import daemon, doctor
from palaver.memory import Budgets
from palaver.webapp.remote import RemoteRecording

FIXTURES = Path(__file__).parent / "fixtures"
SWIFT = FIXTURES / "swift_daemon" / "daemon.json"
FOLDER = "/Users/timo/Meetings/Recordings/2026-11-04T09-00-00"
UPDATED = datetime.fromisoformat("2026-11-04T09:10:20+01:00")


def _swift(tmp_path: Path, **changes) -> Path:
    state = json.loads(SWIFT.read_text())
    state.update(changes)
    path = tmp_path / "daemon.json"
    path.write_text(json.dumps(state, indent=2))
    return path


def test_the_python_fixtures_are_what_the_python_daemon_writes(tmp_path):
    import importlib.util

    spec = importlib.util.spec_from_file_location("make_fixture", Path(__file__).parent.parent / "tools" / "make_daemon_json_fixture.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.make(tmp_path)
    for name in ("recording.json", "stopped.json"):
        assert (tmp_path / name).read_text() == (FIXTURES / "python_daemon" / name).read_text(), name


def test_the_swift_daemon_json_has_the_python_keys_in_their_order():
    swift = json.loads(SWIFT.read_text())
    python = json.loads((FIXTURES / "python_daemon" / "recording.json").read_text())
    assert list(swift) == list(python)
    assert list(swift["why"])[:5] == list(python["why"])[:5]


def test_the_window_reads_the_swift_daemon_json(tmp_path):
    state = json.loads(SWIFT.read_text())
    remote = RemoteRecording(state_path=_swift(tmp_path), socket_path=tmp_path / "app.sock",
                             now=lambda: UPDATED + timedelta(seconds=5), alive=lambda pid: pid == 4242)
    assert remote.question() == {"meeting": "2026-11-04T09-00-00", "reason": "silence", "minutes": 10,
                                 "message": "You started this recording yourself, and it has been silent for 10 minutes. "
                                            "Stop recording?"}
    assert remote.recording() == {"meeting": "2026-11-04T09-00-00", "text": state["why_text"],
                                  "warnings": ["No system audio is arriving"], "hints": []}
    assert remote.recording()["text"].startswith("Recording · started by you at 09:00 · mic MacBook Pro Microphone (48 kHz)")
    assert remote.memory()["total"] == 1610612736 and remote.memory()["workers"][0]["label"] == "Transcription"
    assert remote.indexing() == {"indexing": False, "downloading": False}
    assert remote.coach() is None  # no coach before Task 13
    assert remote.busy() is True


def test_a_stale_or_stopped_swift_daemon_json_is_not_live(tmp_path):
    stale = RemoteRecording(state_path=_swift(tmp_path), socket_path=tmp_path / "app.sock",
                            now=lambda: UPDATED + timedelta(seconds=31), alive=lambda pid: True)
    assert stale.question() is None and stale.busy() is True  # hung: as if busy
    stopped = RemoteRecording(state_path=_swift(tmp_path, state="stopped"), socket_path=tmp_path / "app.sock",
                              now=lambda: UPDATED, alive=lambda pid: True)
    assert stopped.question() is None and stopped.busy() is False


def test_doctor_reads_the_swift_daemons_memory(tmp_path, monkeypatch):
    monkeypatch.setattr(daemon, "STATE_PATH", _swift(tmp_path))
    monkeypatch.setattr(daemon, "palaver_alive", lambda pid: pid == 4242)
    running = doctor._running_memory()
    assert running["total"] == 1610612736
    check = doctor.check_memory(Budgets(), 64.0, running)
    assert check.status == "ok" and "Palaver uses 1.5 GB now" in check.detail


def test_process_sees_the_swift_daemon_recording_into_a_folder(tmp_path, monkeypatch):
    folder = tmp_path / "2026-11-04T09-00-00"
    folder.mkdir()
    monkeypatch.setattr(daemon, "STATE_PATH", _swift(tmp_path, folder=str(folder)))
    monkeypatch.setattr(daemon, "palaver_alive", lambda pid: pid == 4242)
    assert daemon.recording_into(folder)
    assert not daemon.recording_into(tmp_path / "2026-11-04T08-00-00")


def test_status_and_busy_reason_read_the_swift_daemon_json(tmp_path):
    path = _swift(tmp_path, pid=os.getpid())
    line = daemon.read_status(path)
    assert line.startswith(f"daemon running (pid {os.getpid()}): recording since 2026-11-04T09:00:00+01:00 → {FOLDER}")
    assert daemon.busy_reason(json.loads(path.read_text())) == "recording"


def test_the_python_app_takes_a_swift_recording_back_after_a_crash(tmp_path):
    """Going back to the Python app after the Swift one died recording: the manual recording is queued."""
    folder = tmp_path / "2026-11-04T09-00-00"
    folder.mkdir()
    path = _swift(tmp_path, folder=str(folder), pid=None)
    d = daemon.Daemon(detect=lambda: False, new_session=lambda trigger: None, launch_processing=lambda folder: None,
                      trigger=daemon.Trigger(start_after=4, grace=10, max_session=3600), state_path=path)
    assert d._queue == [folder]


@pytest.mark.parametrize("name", ["recording.json", "stopped.json"])
def test_the_python_fixtures_are_fictional(name):
    text = (FIXTURES / "python_daemon" / name).read_text()
    assert "/tmp/palaver-fixture/Recordings/" in text and "/Users/" not in text
