"""Contract: palaver.appctl.call speaks to the Swift app.sock server (native/Sources/PalaverDaemon/AppSocket.swift).

A test-only Swift helper serves the socket with fake handlers for all 13 calls (plus `refuse`,
`explode` and `busy`, which outlives the helper's 1 s main-thread timeout); Python calls it with
the real client. Build the helper with `make appctl-helper` (``make test`` builds it too).
"""

import json
import os
import signal
import socket
import stat
import subprocess
import time
from pathlib import Path

import pytest

from palaver import appctl

HELPER = Path(__file__).resolve().parent.parent / "native" / ".build" / "debug" / "palaver-appctl-helper"

pytestmark = pytest.mark.skipif(
    not HELPER.exists(), reason="Swift test helper not built: run `make appctl-helper` (or `make test`)"
)


@pytest.fixture
def helper(tmp_path):
    sockdir = Path(os.environ.get("PALAVER_TEST_SOCKDIR", "/tmp")) / f"pa-{os.getpid()}-{time.monotonic_ns() % 10**6}"
    sockdir.mkdir()
    path = sockdir / "app.sock"
    proc = subprocess.Popen([str(HELPER), str(path)], stdout=subprocess.PIPE, text=True)
    line = proc.stdout.readline().split()
    assert len(line) == 2, "helper did not start"
    yield path, int(line[1])
    proc.send_signal(signal.SIGTERM)
    proc.wait(timeout=5)
    assert not path.exists()  # cleaned up on stop
    try:
        sockdir.rmdir()
    except OSError:
        pass


def test_socket_is_private(helper):
    path, _ = helper
    assert stat.S_IMODE(path.stat().st_mode) == 0o600


def test_ping_names_the_swift_process(helper):
    path, pid = helper
    assert appctl.call("ping", {}, path=path) == {"pid": pid}


def test_all_calls_answer(helper):
    path, _ = helper
    c = lambda name, args=None: appctl.call(name, args or {}, path=path)  # noqa: E731
    assert c("answer", {"choice": "stop", "meeting": "2026-10-30T08-02-13"}) is True
    assert c("answer", {"choice": "keep", "meeting": "other"}) is False
    assert c("switched_off", {"app": "teams"}) is None
    assert c("start_helper", {"kind": "notes", "key": "k", "args": ["a"]}) == {"pid": 777}
    assert c("transcribe", {"folder": str(path.parent)}) is True
    assert c("restart_web") == {"pid": 4321}
    assert c("test", {"action": "start"}) == {"state": "recording"}
    assert c("test", {"action": "stop"}) == {"state": "checking"}
    assert c("test") == {"state": "idle", "max_seconds": 20.0}
    assert c("calendar", {"action": "connect"}) == {"state": "connected", "echo": {"action": "connect"}}
    assert c("update_check") == {"state": "idle"}
    assert c("update_install") == {"state": "installing"}
    assert c("uninstall", {"models": True}) == {"removing": ["/x/palaver"], "models": True}
    # record: start, again (refused), stop with the wrong page, stop
    assert c("record", {"action": "start"}) == {"meeting": "2026-11-03T14-00-00"}
    with pytest.raises(appctl.CallRefused) as err:
        c("record", {"action": "start"})
    assert str(err.value) == "Palaver is recording already."
    with pytest.raises(appctl.CallRefused, match="^This recording is no longer running.$"):
        c("record", {"action": "stop", "meeting": "2026-11-03T09-00-00"})
    with pytest.raises(appctl.CallRefused, match="a meeting is being recorded"):
        c("test", {"action": "start"})
    assert c("record", {"action": "stop", "meeting": "2026-11-03T14-00-00"}) == {"stopped": "2026-11-03T14-00-00"}


def test_refusal_texts_are_verbatim(helper):
    path, _ = helper
    for name, args, text in [
        ("refuse", {}, "Palaver is recording already."),
        ("nope", {}, "unknown call 'nope'"),
        ("switched_off", {"app": "zoom"}, "no record switch for 'zoom'"),
        ("record", {"action": "pause"}, "no recording action 'pause'"),
        ("start_helper", {"kind": "run", "key": "k"}, "not a helper: run"),
        ("transcribe", {"folder": str(path.parent / "gone")}, f"no recording at {path.parent / 'gone'}"),
        ("watch", {"folder": "/m/x", "pid": 1}, "1 is not a process Palaver started"),
        ("watch", {"folder": "/m/x", "pid": os.getpid()}, f"{os.getpid()} is not a process Palaver started"),
    ]:
        with pytest.raises(appctl.CallRefused) as err:
            appctl.call(name, args, path=path)
        assert str(err.value) == text, name


def test_watch_takes_only_the_helpers_descendants(helper):
    # The helper's own child would pass; this process's child is a stranger to it.
    path, _ = helper
    stranger = subprocess.Popen(["/bin/sleep", "30"])
    try:
        with pytest.raises(appctl.CallRefused, match="is not a process Palaver started"):
            appctl.call("watch", {"folder": "/m/x", "pid": stranger.pid}, path=path)
    finally:
        stranger.kill()
        stranger.wait()


def test_a_failing_call_is_an_error_not_a_refusal(helper):
    path, _ = helper
    with pytest.raises(appctl.CallFailed, match="boom"):
        appctl.call("explode", {}, path=path)
    raw = _raw(path, {"call": "explode", "args": {}})
    assert raw == {"error": "boom", "refused": False}


def test_a_busy_main_thread_is_a_failure_with_its_text(helper):
    path, _ = helper
    started = time.monotonic()
    with pytest.raises(appctl.CallFailed, match="the menu bar app is busy"):
        appctl.call("busy", {}, path=path, timeout=5)
    assert 0.8 < time.monotonic() - started < 3
    assert _raw(path, {"call": "busy", "args": {}}) == {"error": "the menu bar app is busy", "refused": False}


def _raw(path, payload: dict | bytes) -> dict | None:
    data = payload if isinstance(payload, bytes) else json.dumps(payload).encode() + b"\n"
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(5)
        s.connect(str(path))
        buf = b""
        try:
            s.sendall(data)
        except OSError:  # the server answered and closed before it was all sent (oversize)
            pass
        try:
            while not buf.endswith(b"\n"):
                chunk = s.recv(65536)
                if not chunk:
                    break
                buf += chunk
        except ConnectionResetError:
            pass
    return json.loads(buf) if buf else None


def test_raw_reply_shapes(helper):
    path, pid = helper
    assert _raw(path, {"call": "ping", "args": {}}) == {"ok": {"pid": pid}}
    assert _raw(path, {"call": "switched_off", "args": {"app": "slack"}}) == {"ok": None}
    assert _raw(path, {"call": "nope"}) == {"error": "unknown call 'nope'", "refused": True}
    assert _raw(path, {"call": "refuse"}) == {"error": "Palaver is recording already.", "refused": True}
    assert _raw(path, b"{}\n") == {"error": "unknown call None", "refused": True}
    assert _raw(path, b"not json\n")["refused"] is False


def test_an_oversize_request_is_an_error(helper):
    path, _ = helper
    big = json.dumps({"call": "ping", "args": {"pad": "a" * 100_000}}).encode() + b"\n"
    reply = _raw(path, big)
    assert reply is None or (reply["refused"] is False and "ok" not in reply)  # a reset may eat the reply


def test_a_silent_client_is_dropped_and_others_are_served(helper):
    path, pid = helper  # the helper's read timeout is 1 s
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as silent:
        silent.settimeout(5)
        silent.connect(str(path))
        assert appctl.call("ping", {}, path=path) == {"pid": pid}  # not blocked by it
        started = time.monotonic()
        assert silent.recv(100) == b""  # closed after the read timeout, no answer
        assert time.monotonic() - started < 3
