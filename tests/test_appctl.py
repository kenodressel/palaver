"""The local interface between the Meetings window's server (its own
process, #57) and the recording process: a Unix socket in the app support
folder, one JSON request and one JSON answer per connection. Fakes only."""

from __future__ import annotations

import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import pytest

from palaver import appctl


@pytest.fixture
def sock_path():
    # Unix socket paths are limited to 104 bytes: pytest's tmp_path is too long.
    folder = tempfile.mkdtemp(prefix="pv")
    yield Path(folder) / "app.sock"
    shutil.rmtree(folder, ignore_errors=True)


@pytest.fixture
def served(sock_path):
    servers = []

    def serve(calls):
        srv = appctl.serve(sock_path, calls)
        servers.append(srv)
        return srv

    yield serve
    for srv in servers:
        srv.close()


def test_a_call_answers_with_its_result(sock_path, served):
    served({"ping": lambda args: {"pid": 7, "echo": args}})
    assert appctl.call("ping", {"x": 1}, path=sock_path) == {"pid": 7, "echo": {"x": 1}}


def test_only_this_user_can_reach_the_socket(sock_path, served):
    served({"ping": lambda args: None})
    assert stat.S_IMODE(sock_path.stat().st_mode) == 0o600


def test_a_refused_call_says_why(sock_path, served):
    def no(args):
        raise appctl.CallRefused("not now")

    served({"answer": no})
    with pytest.raises(appctl.CallRefused, match="not now"):
        appctl.call("answer", {}, path=sock_path)


def test_an_unknown_call_is_refused(sock_path, served):
    served({})
    with pytest.raises(appctl.CallRefused, match="unknown"):
        appctl.call("nope", {}, path=sock_path)


def test_a_failing_call_is_an_error_not_a_hang(sock_path, served):
    served({"boom": lambda args: 1 / 0})
    with pytest.raises(appctl.CallFailed):
        appctl.call("boom", {}, path=sock_path)


def test_no_recording_process_fails_at_once(sock_path):
    started = time.monotonic()
    with pytest.raises(appctl.CallFailed):
        appctl.call("ping", {}, path=sock_path)
    assert time.monotonic() - started < 0.5


def test_a_recording_process_that_does_not_answer_times_out_quickly(sock_path, served):
    release = threading.Event()
    served({"slow": lambda args: release.wait(5)})
    started = time.monotonic()
    try:
        with pytest.raises(appctl.CallFailed):
            appctl.call("slow", {}, path=sock_path, timeout=0.3)
        assert time.monotonic() - started < 1.0
    finally:
        release.set()


def test_a_stale_socket_file_is_replaced(sock_path, served):
    sock_path.write_text("left over from a crash")
    served({"ping": lambda args: "pong"})
    assert appctl.call("ping", {}, path=sock_path) == "pong"


def test_closing_removes_the_socket(sock_path):
    srv = appctl.serve(sock_path, {})
    srv.close()
    assert not sock_path.exists()


# --- the calls the recording process answers -------------------------------------------

class _Daemon:
    def __init__(self):
        self.answers, self.off, self.helpers = [], [], []
        self.recording = True

    def answer_stop_question(self, choice, meeting=None):
        self.answers.append((choice, meeting))
        return meeting == "2026-10-30T08-02-13"

    def switched_off(self, app):
        self.off.append(app)

    def watch_helper(self, folder, process):
        self.helpers.append((folder, process))

    def transcribe_again(self, folder):
        self.transcribing = [*getattr(self, "transcribing", []), folder]
        return True

    def status(self):
        return {"state": "recording" if self.recording else "idle", "transcribing": False}


class _Test:
    def __init__(self):
        self.started = []

    def start(self, *, busy=False, mode=None):
        if busy():
            raise ValueError("a meeting is being recorded; try the test after it")
        self.started.append(mode)
        return {"state": "recording"}

    def stop(self):
        return {"state": "checking"}

    def status(self):
        return {"state": "idle", "max_seconds": 20.0}


def _calls(daemon, test=None, restarted=None, main=None, launch_helper=None):
    main = main if main is not None else []
    refreshed = []

    def on_main(fn):  # the menu bar's main thread: here, at once, counted
        main.append(fn)
        return fn()

    calls = appctl.app_calls(daemon, on_main=on_main, test_recording=test or _Test(),
                             restart_web=lambda: (restarted.append(1) if restarted is not None else None) or 4321,
                             refresh=lambda: refreshed.append(1), launch_helper=launch_helper)
    return calls, refreshed


def test_answer_runs_on_the_main_thread_and_refreshes_the_menu(sock_path, served):
    daemon, main = _Daemon(), []
    calls, refreshed = _calls(daemon, main=main)
    served(calls)
    assert appctl.call("answer", {"choice": "stop", "meeting": "2026-10-30T08-02-13"}, path=sock_path) is True
    assert appctl.call("answer", {"choice": "keep", "meeting": "other"}, path=sock_path) is False
    assert daemon.answers == [("stop", "2026-10-30T08-02-13"), ("keep", "other")]
    assert len(main) == 2 and refreshed


def test_switched_off_stops_that_apps_recording_on_the_main_thread(sock_path, served):
    daemon, main = _Daemon(), []
    calls, _ = _calls(daemon, main=main)
    served(calls)
    appctl.call("switched_off", {"app": "teams"}, path=sock_path)
    assert daemon.off == ["teams"] and main
    with pytest.raises(appctl.CallRefused):
        appctl.call("switched_off", {"app": "zoom"}, path=sock_path)


def test_watch_hands_the_helper_over_by_its_pid(sock_path, served):
    daemon = _Daemon()
    calls, _ = _calls(daemon)
    served(calls)
    # The window's server started it: a descendant of the app (here: this process's child).
    helper = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"], start_new_session=True)
    try:
        appctl.call("watch", {"folder": "/m/2026-10-30T08-02-13", "pid": helper.pid}, path=sock_path)
        [(folder, process)] = daemon.helpers
        assert folder == Path("/m/2026-10-30T08-02-13") and process.pid == helper.pid
        assert process.poll() is None
        process.terminate()
        helper.wait(5)
        assert process.poll() is not None
    finally:
        helper.kill()
        helper.wait()


def test_the_setup_test_recording_runs_in_the_recording_process(sock_path, served):
    daemon, test = _Daemon(), _Test()
    calls, _ = _calls(daemon, test=test)
    served(calls)
    with pytest.raises(appctl.CallRefused, match="meeting is being recorded"):
        appctl.call("test", {"action": "start", "mode": {"transcribe": "local"}}, path=sock_path)
    daemon.recording = False
    assert appctl.call("test", {"action": "start", "mode": {"transcribe": "local"}}, path=sock_path) == {
        "state": "recording"}
    assert test.started == [{"transcribe": "local"}]
    assert appctl.call("test", {"action": "stop"}, path=sock_path) == {"state": "checking"}
    assert appctl.call("test", {}, path=sock_path) == {"state": "idle", "max_seconds": 20.0}


def test_transcribe_again_queues_the_folder_on_the_main_thread(sock_path, served, tmp_path):
    daemon, main = _Daemon(), []
    calls, refreshed = _calls(daemon, main=main)
    served(calls)
    assert appctl.call("transcribe", {"folder": str(tmp_path)}, path=sock_path) is True
    assert daemon.transcribing == [tmp_path] and main and refreshed
    with pytest.raises(appctl.CallRefused, match="no recording"):
        appctl.call("transcribe", {"folder": str(tmp_path / "gone")}, path=sock_path)


class _Recorder(_Daemon):
    """Records by hand into /m/<time>, as the menu's Start Recording."""

    def __init__(self, fails=False):
        super().__init__()
        self.recording, self.fails, self.folder = False, fails, None

    def start_manual(self):
        if self.fails:
            return False
        self.recording, self.folder = True, "/m/2026-11-03T14-00-00"
        return True

    def stop_manual(self):
        self.recording, self.folder = False, None

    def status(self):
        return {**super().status(), "folder": self.folder}


def test_the_window_starts_and_stops_a_recording_on_the_main_thread(sock_path, served):
    """#11: the window's Start Recording / Stop, as the menu's."""
    daemon, main = _Recorder(), []
    calls, refreshed = _calls(daemon, main=main)
    served(calls)
    assert appctl.call("record", {"action": "start"}, path=sock_path) == {"meeting": "2026-11-03T14-00-00"}
    assert daemon.recording and main and refreshed
    with pytest.raises(appctl.CallRefused, match="recording already"):
        appctl.call("record", {"action": "start"}, path=sock_path)
    with pytest.raises(appctl.CallRefused, match="no longer running"):  # the page showed another one
        appctl.call("record", {"action": "stop", "meeting": "2026-11-03T09-00-00"}, path=sock_path)
    assert appctl.call("record", {"action": "stop", "meeting": "2026-11-03T14-00-00"}, path=sock_path) == {
        "stopped": "2026-11-03T14-00-00"}
    assert not daemon.recording
    with pytest.raises(appctl.CallRefused, match="no longer running"):
        appctl.call("record", {"action": "stop"}, path=sock_path)
    with pytest.raises(appctl.CallRefused):
        appctl.call("record", {"action": "pause"}, path=sock_path)


def test_a_recording_that_does_not_start_says_so(sock_path, served):
    calls, _ = _calls(_Recorder(fails=True))
    served(calls)
    with pytest.raises(appctl.CallRefused, match="did not start"):
        appctl.call("record", {"action": "start"}, path=sock_path)


def test_restart_web_restarts_only_the_server(sock_path, served):
    restarted = []
    calls, _ = _calls(_Daemon(), restarted=restarted)
    served(calls)
    assert appctl.call("restart_web", {}, path=sock_path) == {"pid": 4321}
    assert restarted == [1]


def test_ping_names_the_recording_process(sock_path, served):
    calls, _ = _calls(_Daemon())
    served(calls)
    assert appctl.call("ping", {}, path=sock_path) == {"pid": os.getpid()}


def test_a_helper_that_is_gone_is_done():
    gone = subprocess.Popen([sys.executable, "-c", "pass"])
    gone.wait()
    assert appctl.PidProcess(gone.pid).poll() is not None
    assert appctl.PidProcess(gone.pid).terminate() is None  # nothing to stop: no error


def test_pid_process_kill_sends_sigkill():
    helper = subprocess.Popen([sys.executable, "-c",
                               "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)"])
    try:
        time.sleep(0.2)
        appctl.PidProcess(helper.pid).kill()
        assert helper.wait(5) == -signal.SIGKILL
    finally:
        helper.kill()
        helper.wait()


def test_watch_takes_only_a_descendant_of_the_app(sock_path, served):
    daemon = _Daemon()
    calls, _ = _calls(daemon)
    served(calls)
    stranger = subprocess.Popen(["/bin/sleep", "30"], start_new_session=True)
    try:
        # Not a descendant of this process: a pid from somewhere else is not watched (or signalled).
        for pid in (0, 1, -5, os.getpid(), os.getppid()):
            with pytest.raises(appctl.CallRefused):
                appctl.call("watch", {"folder": "/m/x", "pid": pid}, path=sock_path)
        assert daemon.helpers == []
        appctl.call("watch", {"folder": "/m/x", "pid": stranger.pid}, path=sock_path)  # our child: fine
        assert [p.pid for _, p in daemon.helpers] == [stranger.pid]
    finally:
        stranger.kill()
        stranger.wait()


def test_a_descendant_further_down_counts():
    outer = subprocess.Popen([sys.executable, "-c",
                              "import subprocess, sys, time; p = subprocess.Popen(['/bin/sleep', '30']); "
                              "print(p.pid, flush=True); time.sleep(30)"], stdout=subprocess.PIPE, text=True)
    try:
        inner = int(outer.stdout.readline())
        assert appctl.descendant(inner)
        assert appctl.descendant(outer.pid)
        assert not appctl.descendant(os.getppid())
        assert not appctl.descendant(1)
    finally:
        subprocess.run(["pkill", "-P", str(outer.pid)])
        outer.kill()
        outer.wait()


def test_start_helper_starts_the_language_models_helper_in_the_app(sock_path, served):
    started = []
    calls, _ = _calls(_Daemon(), launch_helper=lambda kind, key, args: started.append((kind, key, args)) or 777)
    served(calls)
    assert appctl.call("start_helper", {"kind": "notes", "key": "2026-10-30T08-02-13",
                                        "args": ["/m/2026-10-30T08-02-13", "--force"]}, path=sock_path) == {"pid": 777}
    assert started == [("notes", "2026-10-30T08-02-13", ["/m/2026-10-30T08-02-13", "--force"])]


def test_start_helper_refuses_what_it_does_not_run(sock_path, served):
    def launch(kind, key, args):
        raise ValueError(f"not a helper: {kind}")

    calls, _ = _calls(_Daemon(), launch_helper=launch)
    served(calls)
    with pytest.raises(appctl.CallRefused, match="not a helper"):
        appctl.call("start_helper", {"kind": "run", "key": "x", "args": []}, path=sock_path)


def test_the_window_waits_longer_for_an_answer_than_the_app_waits_for_its_main_thread():
    from palaver.webapp import remote

    assert remote.ANSWER_TIMEOUT > appctl.MAIN_THREAD_TIMEOUT
