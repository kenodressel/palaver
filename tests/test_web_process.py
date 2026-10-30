"""The Meetings window's server in its own process (#57): the menu bar app
starts it, restarts it when it crashes (with backoff) or when asked, and
stops it when it quits. The listening socket stays with the app, so the
port never changes and the window keeps working. Killing the server never
touches a recording. Fake children and fake capture only: no mic, no sound."""

from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import urllib.request
from datetime import datetime
from pathlib import Path

import pytest

from palaver import appctl
from palaver.daemon import Daemon, Trigger
from palaver.webapp import process

# A stand-in server: answers every request with its pid. MODE: "serve";
# "crash" (exits 1 after a moment); "crash-once" (crashes on its first run,
# counted in COUNT, then serves); "stubborn" (serves, ignores SIGTERM).
FAKE_CHILD = textwrap.dedent("""
    import os, signal, socket, sys, time
    mode, count, listen_fd, ready_fd = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    runs = int(open(count).read() or 0) if os.path.exists(count) else 0
    open(count, "w").write(str(runs + 1))
    if mode == "stubborn":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    if mode == "hang" or (mode == "hang-once" and runs == 0):
        time.sleep(60)  # never says it serves
    if mode == "slow-ready":
        time.sleep(0.3)
    if mode == "crash" or (mode == "crash-once" and runs == 0):
        os.write(ready_fd, b"ready\\n")
        time.sleep(0.1)
        sys.exit(1)
    sock = socket.socket(fileno=listen_fd)
    os.write(ready_fd, b"ready\\n")
    os.close(ready_fd)
    while True:
        conn, _ = sock.accept()
        conn.recv(65536)
        body = str(os.getpid()).encode()
        conn.sendall(b"HTTP/1.0 200 OK\\r\\nContent-Length: %d\\r\\n\\r\\n%s" % (len(body), body))
        conn.close()
""")


@pytest.fixture
def fake(tmp_path):
    script = tmp_path / "fake_child.py"
    script.write_text(FAKE_CHILD)
    supervisors = []

    def make(mode="serve", **kw):
        listener = process.listen()
        events = []
        kw.setdefault("backoff", (0.05, 0.2, 0.4))
        sup = process.WebSupervisor(
            lambda listen_fd, ready_fd: [sys.executable, str(script), mode, str(tmp_path / "count"),
                                         str(listen_fd), str(ready_fd)],
            listener=listener, on_ready=events.append, **kw)
        sup.events = events
        supervisors.append(sup)
        return sup

    make.runs = lambda: int((tmp_path / "count").read_text() or 0) if (tmp_path / "count").exists() else 0
    yield make
    for sup in supervisors:
        sup.stop()
        sup.listener.close()


def _until(condition, timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.02)
    return condition()


def _get(url, timeout=5.0) -> str:
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return resp.read().decode()


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def test_the_server_runs_as_a_child_on_the_apps_port(fake):
    sup = fake()
    sup.start()
    assert _until(lambda: sup.events == [False])
    assert sup.url() == f"http://127.0.0.1:{sup.port}/"
    assert sup.url("2026-10-30T08-02-13") == f"http://127.0.0.1:{sup.port}/#/2026-10-30T08-02-13"
    assert _get(sup.url()) == str(sup.pid) and sup.pid != os.getpid()


def test_a_crashed_server_is_started_again_on_the_same_port(fake):
    sup = fake("crash-once")
    sup.start()
    assert _until(lambda: sup.events == [False, True])
    assert _get(sup.url()) == str(sup.pid)
    assert fake.runs() == 2


def test_a_server_that_keeps_crashing_waits_longer_each_time(fake):
    waits = []
    sup = fake("crash", backoff=(0.05, 0.1, 0.2))
    real_wait = sup._wake.wait
    sup._wake.wait = lambda seconds: waits.append(seconds) or real_wait(seconds)
    sup.start()
    assert _until(lambda: len(waits) >= 4)
    sup.stop()
    assert waits[:4] == [0.05, 0.1, 0.2, 0.2]


def test_a_server_that_ran_a_while_before_crashing_starts_over_at_the_shortest_wait():
    delays = process.backoff_delays((1, 5, 30), stable_after=60)
    assert delays.next(ran_for=0.5) == 1
    assert delays.next(ran_for=0.5) == 5
    assert delays.next(ran_for=0.5) == 30
    assert delays.next(ran_for=0.5) == 30
    assert delays.next(ran_for=120) == 1
    delays.reset()
    assert delays.next(ran_for=0.5) == 1


def test_restart_starts_a_new_server_at_once_and_the_window_reloads(fake):
    sup = fake(backoff=(30,))  # a restart never waits out the backoff
    sup.start()
    assert _until(lambda: sup.events == [False])
    first = sup.pid
    started = time.monotonic()
    new = sup.restart()
    assert time.monotonic() - started < 5
    assert new == sup.pid != first and not _until(lambda: _alive(first) is True, 0.5)
    assert sup.events == [False, True]
    assert _get(sup.url()) == str(new)


def test_stop_ends_the_server_and_starts_no_other(fake):
    sup = fake()
    sup.start()
    assert _until(lambda: sup.events == [False])
    pid = sup.pid
    sup.stop()
    assert not _alive(pid)
    time.sleep(0.3)
    assert fake.runs() == 1 and sup.pid is None


def test_stop_kills_a_server_that_ignores_sigterm(fake):
    sup = fake("stubborn", stop_timeout=0.5)
    sup.start()
    assert _until(lambda: sup.events == [False])
    pid = sup.pid
    started = time.monotonic()
    sup.stop()
    assert not _alive(pid) and time.monotonic() - started < 3


def test_the_server_gets_the_notification_socket_but_not_the_launchers_clicks():
    env = process.child_env({"PALAVER_NOTIFY": "/tmp/n.sock", "PALAVER_LAUNCHER_FD": "3", "HOME": "/Users/x"})
    assert env == {"PALAVER_NOTIFY": "/tmp/n.sock", "HOME": "/Users/x"}


def test_the_child_command(tmp_path):
    argv = process.child_argv(["--config", "/c.toml"], listen_fd=5, ready_fd=6, app_socket=Path("/s/app.sock"))
    assert argv[:3] == [sys.executable, "-m", "palaver"]
    assert argv[3:] == ["--config", "/c.toml", "webapp-serve", "--listen-fd", "5", "--ready-fd", "6",
                        "--app-socket", "/s/app.sock"]


def test_the_child_exits_when_the_app_is_gone():
    read, write = os.pipe()
    exited = []
    with os.fdopen(read, "rb") as stream:
        t = process.exit_when_parent_gone(stream, exit=exited.append)
        assert not exited
        os.close(write)
        t.join(5)
    assert exited == [0]


def test_a_server_that_stops_while_the_app_lives_exits_cleanly():
    """A restart (SIGTERM) ends the server while its watch on stdin still
    waits: no "Fatal Python error" at shutdown, so no crash report."""
    code = ("import sys, time; from palaver.webapp import process; "
            "process.exit_when_parent_gone(sys.stdin.buffer, exit=lambda c: None); time.sleep(0.3)")
    proc = subprocess.Popen([sys.executable, "-c", code], stdin=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        err = proc.stderr.read()  # the child ends on its own; the app (stdin) is still there
        proc.wait(timeout=30)
    finally:
        proc.stdin.close()
    assert "Fatal Python error" not in err
    assert proc.returncode == 0


# --- the real server process -------------------------------------------------------------

@pytest.fixture
def home():
    """A throwaway HOME for the real server process: never the real
    ~/Meetings, ~/.config/palaver or ~/Library. Short, for the socket."""
    folder = Path(tempfile.mkdtemp(prefix="pv"))
    (folder / "Meetings").mkdir()
    (folder / "config.toml").write_text(textwrap.dedent(f"""
        [notion]
        token = "fake"
        parent_page_id = "fake"
        [hf]
        token = "fake"
        [recording]
        output_dir = "{folder / 'Meetings'}"
    """))
    yield folder
    shutil.rmtree(folder, ignore_errors=True)


def _real_supervisor(home: Path, **kw) -> process.WebSupervisor:
    env = {**process.child_env(os.environ), "HOME": str(home), "XDG_CONFIG_HOME": str(home / ".config")}
    env.pop("PALAVER_NOTIFY", None)
    kw.setdefault("backoff", (0.1,))
    return process.WebSupervisor(
        lambda listen_fd, ready_fd: process.child_argv(["--config", str(home / "config.toml")], listen_fd=listen_fd,
                                                       ready_fd=ready_fd, app_socket=home / "app.sock"),
        listener=process.listen(), env=env, **kw)


def _state_path(home: Path) -> Path:
    return home / "Library" / "Application Support" / "palaver" / "daemon.json"


def test_the_real_server_serves_the_page_and_the_recording_from_its_own_process(home):
    events = []
    sup = _real_supervisor(home, on_ready=events.append)
    state = _state_path(home)
    state.parent.mkdir(parents=True)
    state.write_text(json.dumps({
        "state": "recording", "folder": str(home / "Meetings" / "2026-10-30T08-02-13"), "pid": os.getpid(),
        "updated": datetime.now().astimezone().isoformat(timespec="seconds"), "why_text": "Recording · manual since 08:02",
        "stop_question": None, "warnings": [], "hints": []}))
    sup.start()
    try:
        assert _until(lambda: events == [False], 60), "the server process did not start"
        req = urllib.request.Request(sup.url() + "api/recording/question", headers={"Host": f"127.0.0.1:{sup.port}"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            answer = json.loads(resp.read())
        assert answer["recording"]["meeting"] == "2026-10-30T08-02-13"
        assert "<html" in _get(sup.url()).lower()
    finally:
        sup.stop()
        sup.listener.close()


class _CaptureSession:
    """A recording whose capture is a thread delivering a buffer every 5 ms,
    like the audio callbacks; nothing is recorded."""

    def __init__(self, folder: Path):
        self.folder = folder
        self.buffers: list[float] = []
        self._stop = threading.Event()
        self.stopped = False

    def start(self):
        self.folder.mkdir(parents=True, exist_ok=True)

        def capture():
            while not self._stop.wait(0.005):
                self.buffers.append(time.monotonic())

        threading.Thread(target=capture, daemon=True).start()
        return self.folder

    def stop(self, reason=None):
        self.stopped = True
        self._stop.set()
        return 600.0


def test_killing_the_server_during_a_recording_never_touches_capture(home):
    sessions = []
    state = _state_path(home)
    daemon = Daemon(detect=lambda: False,
                    new_session=lambda trigger: sessions.append(_CaptureSession(home / "Meetings" / "rec")) or sessions[-1],
                    launch_processing=lambda folder: None, trigger=Trigger(start_after=4, grace=10, max_session=3600),
                    state_path=state)
    assert daemon.start_manual()
    capture = sessions[0]
    control = appctl.serve(home / "app.sock", appctl.app_calls(
        daemon, on_main=lambda fn: fn(), test_recording=None, restart_web=lambda: None, refresh=lambda: None))
    events = []
    sup = _real_supervisor(home, on_ready=events.append)
    sup.start()
    try:
        assert _until(lambda: events == [False], 60), "the server process did not start"
        ticks = []
        stop_ticking = threading.Event()

        def menu_bar():  # the menu bar's timer: the daemon ticks on, as in the app
            while not stop_ticking.wait(0.05):
                started = time.monotonic()
                daemon.tick()
                ticks.append(time.monotonic() - started)

        ticker = threading.Thread(target=menu_bar, daemon=True)
        ticker.start()
        time.sleep(0.3)
        before = len(capture.buffers)
        killed_at = time.monotonic()
        os.kill(sup.pid, signal.SIGKILL)
        time.sleep(0.5)
        assert _until(lambda: events == [False, True], 60), "the server was not started again"
        stop_ticking.set()
        ticker.join(5)

        assert not capture.stopped and daemon.status()["state"] == "recording"
        after = [t for t in capture.buffers if t >= killed_at]
        assert len(capture.buffers) > before and after
        gaps = [b - a for a, b in zip(capture.buffers, capture.buffers[1:])]
        assert max(gaps) < 0.25, f"capture stalled for {max(gaps):.3f} s"
        assert ticks and max(ticks) < 0.5, f"a daemon tick took {max(ticks):.3f} s"
        # The new server sees the same recording.
        req = urllib.request.Request(sup.url() + "api/recording/question", headers={"Host": f"127.0.0.1:{sup.port}"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            assert json.loads(resp.read())["recording"]["meeting"] == "rec"
    finally:
        sup.stop()
        sup.listener.close()
        control.close()
        daemon.shutdown("by_you")


def test_a_server_that_never_says_ready_is_ended_and_started_again(fake):
    sup = fake("hang-once", ready_timeout=0.5, backoff=(0.05,))
    sup.start()
    assert _until(lambda: sup.events == [True], 10), "the hanging server was not replaced"
    assert fake.runs() == 2
    assert _get(sup.url()) == str(sup.pid)


def test_the_ready_timeout_is_short_and_the_cli_waits_longer_than_a_restart():
    from palaver import cli

    assert process.READY_TIMEOUT <= 20
    assert cli.RESTART_WEB_TIMEOUT > process.READY_TIMEOUT + process.DRAIN_SECONDS
    assert process.STOP_TIMEOUT > process.DRAIN_SECONDS  # a requested restart lets the drain finish


def test_restart_returns_the_new_server_even_when_the_old_one_comes_up_meanwhile(fake):
    """The old server saying ready while a restart ends it is not the new one."""
    sup = fake("slow-ready")
    sup.start()
    first = None
    end = sup._end

    def end_after_ready(proc):  # the old server comes up just before the restart ends it
        nonlocal first
        first = proc.pid
        _until(lambda: sup.events, 5)
        end(proc)

    sup._end = end_after_ready
    new = sup.restart()
    assert new is not None and new != first and new == sup.pid
    assert _until(lambda: sup.events == [False, True])


def test_stop_in_the_background_returns_at_once():
    class Slow:
        def __init__(self):
            self.stopped = threading.Event()

        def stop(self):
            time.sleep(1.0)
            self.stopped.set()

    web = Slow()
    started = time.monotonic()
    t = process.stop_in_background(web)
    assert time.monotonic() - started < 0.2
    t.join(5)
    assert web.stopped.is_set()


def test_inflight_changes_drain_but_model_waits_do_not():
    inflight = process.Inflight()
    assert inflight.wait_idle(0.1)
    done = threading.Event()

    def change():
        with inflight.change():
            done.wait(5)

    t = threading.Thread(target=change)
    t.start()
    assert _until(lambda: inflight.count == 1, 2)
    started = time.monotonic()
    assert not inflight.wait_idle(0.3)  # a change still runs
    assert time.monotonic() - started >= 0.3
    done.set()
    t.join(5)
    assert inflight.wait_idle(1)

    hold = threading.Event()

    def waits_for_the_model():
        with inflight.change(), inflight.detached():
            hold.wait(5)

    t = threading.Thread(target=waits_for_the_model)
    t.start()
    time.sleep(0.1)
    assert inflight.wait_idle(0.2)  # the job is the app's: the server need not wait for it
    hold.set()
    t.join(5)


def test_a_restart_while_notes_are_written_keeps_the_run(home):
    """Notes run in a helper the app starts (a descendant of the app, not of
    the server): a restarted server shows the run, starts no second one,
    and answers when it is done."""
    from palaver import model_jobs
    from tests.test_webapp import MEETING, _meeting

    output = home / "Meetings"
    _meeting(output)
    root = output / ".jobs"
    launched = []

    def launch_helper(kind, key, args):
        launched.append((kind, key, args))
        return model_jobs.launch(root, kind, key, [sys.executable, "-c", "import time; time.sleep(4)"])

    daemon = Daemon(detect=lambda: False, new_session=lambda trigger: None, launch_processing=lambda folder: None,
                    trigger=Trigger(start_after=4, grace=10, max_session=3600), state_path=_state_path(home))
    daemon.tick()
    control = appctl.serve(home / "app.sock", appctl.app_calls(
        daemon, on_main=lambda fn: fn(), test_recording=None, restart_web=lambda: None, refresh=lambda: None,
        launch_helper=launch_helper))
    events = []
    sup = _real_supervisor(home, on_ready=events.append)
    sup.start()

    def post_notes(answers):
        req = urllib.request.Request(sup.url() + f"api/meetings/{MEETING}/notes", data=b"{}", method="POST",
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                answers.append(resp.status)
        except Exception as exc:  # the first server went away while it waited
            answers.append(type(exc).__name__)

    try:
        assert _until(lambda: events == [False], 60), "the server process did not start"
        first, second = [], []
        threading.Thread(target=post_notes, args=(first,), daemon=True).start()
        assert _until(lambda: model_jobs.running(root), 10), "no notes job started"
        [job] = model_jobs.running(root)
        ppid = int(subprocess.run(["ps", "-o", "ppid=", "-p", str(job["pid"])], capture_output=True,
                                  text=True).stdout)
        assert ppid == os.getpid()  # the app's child, not the server's

        started = time.monotonic()
        assert sup.restart() is not None
        assert time.monotonic() - started < 3, "the restart waited for the notes"
        with urllib.request.urlopen(sup.url() + "api/model-jobs", timeout=5) as resp:
            jobs = json.loads(resp.read())
        assert [(j["kind"], j["key"]) for j in jobs["running"]] == [("notes", MEETING)]

        threading.Thread(target=post_notes, args=(second,), daemon=True).start()
        assert _until(lambda: second, 15)
        assert second == [200] and len(launched) == 1  # waited for the running job: no second run
        assert model_jobs.running(root) == []
    finally:
        sup.stop()
        sup.listener.close()
        control.close()
