"""Contract: palaver.notify speaks to the Swift notify socket (native/Sources/PalaverCore/Notifications.swift).

A test-only Swift helper binds the socket with a recording fake center (no UserNotifications, no
prompts); Python sends through $PALAVER_NOTIFY and the helper records what the center would post.
Build the helper with `make notify-helper` (``make engine-test`` builds it too).
"""

import json
import os
import signal
import stat
import subprocess
import time
from pathlib import Path

import pytest

from palaver import notify

HELPER = Path(__file__).resolve().parent.parent / "native" / ".build" / "debug" / "palaver-notify-helper"

pytestmark = pytest.mark.skipif(
    not HELPER.exists(), reason="Swift test helper not built: run `make notify-helper` (or `make engine-test`)"
)


@pytest.fixture
def helper(tmp_path, monkeypatch):
    record = tmp_path / "record.jsonl"
    # a short directory: unix socket paths are limited to ~104 bytes
    sockdir = Path(os.environ.get("PALAVER_TEST_SOCKDIR", "/tmp")) / f"pn-{os.getpid()}-{time.monotonic_ns() % 10**6}"
    sockdir.mkdir()
    proc = subprocess.Popen([str(HELPER), str(sockdir), str(record)], stdout=subprocess.PIPE, text=True)
    sock = proc.stdout.readline().strip()
    state = proc.stdout.readline().strip()
    assert sock and state, "helper did not start"
    monkeypatch.setenv("PALAVER_NOTIFY", sock)
    monkeypatch.setenv("PALAVER_NOTIFY_STATE", state)
    monkeypatch.setattr(notify, "_enabled", True)
    monkeypatch.setattr(notify, "_send", notify._send_default)  # conftest stubs it
    yield sock, state, record
    proc.send_signal(signal.SIGTERM)
    proc.wait(timeout=5)
    assert not os.path.exists(sock)  # cleaned up on stop
    try:
        sockdir.rmdir()
    except OSError:
        pass


def _wait_records(record: Path, count: int) -> list[dict]:
    for _ in range(100):
        lines = [json.loads(x) for x in record.read_text().splitlines() if x]
        if len(lines) >= count:
            return lines
        time.sleep(0.05)
    return [json.loads(x) for x in record.read_text().splitlines() if x]


def test_notification_reaches_the_swift_center(helper):
    _, _, record = helper
    notify.notify("Notes ready", 'He said "hi"', meeting="2026-10-21T16-29-29")
    assert _wait_records(record, 1) == [
        {"title": "Notes ready", "message": 'He said "hi"', "open": "2026-10-21T16-29-29"}
    ]


def test_without_a_meeting_open_is_empty(helper):
    _, _, record = helper
    notify.notify("Palaver", "Recording started")
    assert _wait_records(record, 1)[0]["open"] == ""


def test_socket_is_private(helper):
    sock, _, _ = helper
    assert stat.S_IMODE(os.stat(sock).st_mode) == 0o600


def test_permission_state_file_is_read_by_python(helper):
    # the fake center says "not asked"; the helper writes that on start
    for _ in range(100):
        if notify.permission():
            break
        time.sleep(0.05)
    assert notify.permission() == "not_asked"
