"""The window's server, in its own process (#57), asks the recording
process what it needs: the running recording from daemon.json, actions
through the app socket. When the recording process does not answer, the
page still shows, without the live bits. Fakes only."""

from __future__ import annotations

import json
import os
import shutil
import tempfile
import threading
import time
from datetime import datetime, timedelta
from pathlib import Path

import pytest

from palaver import appctl
from palaver.webapp import api
from palaver.webapp.remote import RemoteCalendar, RemoteRecording, RemoteTest
from palaver.webapp.server import App, make_server

from .test_webapp import MEETING, _meeting, _post, _req

NOW = datetime.fromisoformat("2026-10-30T09:00:00+01:00")
FOLDER = f"/m/{MEETING}"

STATUS = {
    "state": "recording", "manual": True, "folder": FOLDER, "transcribing": False,
    "indexing": True, "index_downloading": False,
    "stop_question": {"meeting": MEETING, "reason": "silence", "minutes": 10, "message": "Silent for 10 min"},
    "why_text": "Recording · manual since 08:02 · mic MacBook (48 kHz)",
    "warnings": ["The mic was silent for 2 min"], "hints": ["Wear headphones? never"],
    "memory": {"app": 300, "workers": []},
    "talk": {"speaking": "me", "share": 0.4}, "talk_text": "You 40 %", "nudge": None, "quiet": ["Rico"],
    "pid": os.getpid(), "updated": NOW.isoformat(timespec="seconds"),
}


@pytest.fixture
def short_dir():
    folder = Path(tempfile.mkdtemp(prefix="pv"))
    yield folder
    shutil.rmtree(folder, ignore_errors=True)


def _remote(folder: Path, status: dict | None = STATUS, *, now=NOW, alive=lambda pid: True, **kw) -> RemoteRecording:
    state = folder / "daemon.json"
    if status is not None:
        state.write_text(json.dumps(status))
    return RemoteRecording(state_path=state, socket_path=folder / "app.sock", now=lambda: now, alive=alive, **kw)


def test_the_running_recording_comes_from_daemon_json(short_dir):
    r = _remote(short_dir)
    assert r.question() == STATUS["stop_question"]
    assert r.recording() == {"meeting": MEETING, "text": STATUS["why_text"], "warnings": STATUS["warnings"],
                             "hints": STATUS["hints"]}
    assert r.coach() == {"meeting": MEETING, "talk": STATUS["talk"], "text": "You 40 %", "nudge": None,
                         "quiet": ["Rico"]}
    assert r.memory() == {"app": 300, "workers": []}
    assert r.indexing() == {"indexing": True, "downloading": False}
    assert r.busy() is True


def test_idle_has_nothing_live(short_dir):
    idle = {**STATUS, "state": "idle", "folder": None, "why_text": None, "stop_question": None, "talk": None,
            "indexing": False}
    r = _remote(short_dir, idle)
    assert (r.question(), r.recording(), r.coach()) == (None, None, None)
    assert r.busy() is False
    assert _remote(short_dir, {**idle, "transcribing": True}).busy() is True


@pytest.mark.parametrize("case", ["missing", "broken", "stopped", "dead", "stale"])
def test_without_a_recording_process_the_live_bits_are_left_out(short_dir, case):
    status, alive, now = STATUS, (lambda pid: True), NOW
    if case == "missing":
        status = None
    elif case == "stopped":
        status = {**STATUS, "state": "stopped"}
    elif case == "dead":
        alive = lambda pid: False  # noqa: E731
    elif case == "stale":
        now = NOW + timedelta(minutes=5)
    r = _remote(short_dir, status, now=now, alive=alive)
    if case == "broken":
        (short_dir / "daemon.json").write_text("{not json")
    assert (r.question(), r.recording(), r.coach(), r.memory()) == (None, None, None, None)
    assert r.indexing() == {"indexing": False, "downloading": False}
    # Background work waits while it is not known whether a call is recorded.
    assert r.busy() is (case == "stale")


def test_answer_goes_to_the_recording_process(short_dir):
    got = []
    srv = appctl.serve(short_dir / "app.sock", {"answer": lambda args: got.append(args) or True})
    try:
        assert _remote(short_dir).answer("stop", MEETING) is True
        assert got == [{"choice": "stop", "meeting": MEETING}]
    finally:
        srv.close()


def test_answer_without_a_recording_process_is_refused_with_a_reason(short_dir):
    with pytest.raises(api.Refused, match="did not answer"):
        _remote(short_dir).answer("stop", MEETING)


def test_watch_and_switched_off_go_to_the_recording_process(short_dir):
    got = []
    srv = appctl.serve(short_dir / "app.sock", {"watch": lambda args: got.append(("watch", args)),
                                                "switched_off": lambda args: got.append(("off", args))})

    class Helper:
        pid = 4242

    try:
        r = _remote(short_dir)
        r.watch(Path(FOLDER), Helper())
        r.switched_off("slack")
        assert got == [("watch", {"folder": FOLDER, "pid": 4242}), ("off", {"app": "slack"})]
    finally:
        srv.close()


def test_watch_and_switched_off_without_a_recording_process_change_nothing(short_dir):
    r = _remote(short_dir)

    class Helper:
        pid = 4242

    r.watch(Path(FOLDER), Helper())  # no error: the helper runs unwatched
    r.switched_off("teams")


def test_the_setup_test_recording_goes_to_the_recording_process(short_dir):
    got = []

    def test(args):
        got.append(args)
        return {"state": "recording" if args.get("action") == "start" else "idle"}

    srv = appctl.serve(short_dir / "app.sock", {"test": test})
    try:
        t = RemoteTest(short_dir / "app.sock")
        assert t.start(busy=lambda: False, mode={"transcribe": "local"}) == {"state": "recording"}
        assert t.status() == {"state": "idle"}
        assert got[0] == {"action": "start", "mode": {"transcribe": "local"}}
        with pytest.raises(ValueError, match="meeting is being recorded"):
            t.start(busy=lambda: True)
    finally:
        srv.close()


def test_the_calendar_is_asked_for_by_the_recording_process(short_dir):
    got = []

    def calendar(args):
        got.append(args)
        return {"state": "granted" if got[-1] else "not_asked"}

    srv = appctl.serve(short_dir / "app.sock", {"calendar": calendar})
    try:
        c = RemoteCalendar(short_dir / "app.sock")
        assert c.status() == {"state": "not_asked"}
        assert c.connect() == {"state": "granted"}
        assert got == [{}, {"action": "connect"}]
    finally:
        srv.close()


def test_the_calendar_without_a_recording_process(short_dir, monkeypatch):
    from palaver import onboarding

    monkeypatch.setattr(onboarding, "calendar_permission", lambda: {"state": "granted", "detail": "here"})
    c = RemoteCalendar(short_dir / "app.sock")
    assert c.status()["state"] == "granted"  # the page still shows what this process sees
    with pytest.raises(ValueError, match="did not answer"):
        c.connect()


def test_the_setup_test_without_a_recording_process(short_dir):
    t = RemoteTest(short_dir / "app.sock")
    assert t.status()["state"] == "idle"  # the setup page still shows
    with pytest.raises(ValueError, match="did not answer"):
        t.start(busy=lambda: False)
    assert t.stop()["state"] == "idle"


# --- over HTTP: the page never errors ----------------------------------------------------

def _server(tmp_path: Path, recording):
    _meeting(tmp_path)
    srv = make_server(App(tmp_path, "Timo", recording=recording), port=0)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def test_http_without_a_recording_process_shows_the_page_without_live_bits(tmp_path, short_dir):
    srv = _server(tmp_path, _remote(short_dir, None))
    try:
        assert json.loads(_req(srv, "/api/recording/question")[2]) == {"question": None, "recording": None}
        assert json.loads(_req(srv, "/api/recording/coach")[2]) == {"coach": None}
        assert json.loads(_req(srv, "/api/memory")[2]) == {"memory": None}
        assert json.loads(_req(srv, "/api/search/status")[2]) == {"indexing": False, "downloading": False}
        assert _req(srv, "/")[0] == 200
        status, answer = _post(srv, "/api/recording/stop", {"meeting": MEETING})
        assert status == 400 and "did not answer" in answer["error"]
    finally:
        srv.shutdown()
        srv.server_close()


def test_http_live_bits_from_the_recording_process(tmp_path, short_dir):
    srv = _server(tmp_path, _remote(short_dir))
    try:
        answer = json.loads(_req(srv, "/api/recording/question")[2])
        assert answer["question"]["reason"] == "silence" and answer["recording"]["meeting"] == MEETING
    finally:
        srv.shutdown()
        srv.server_close()


def test_http_a_record_switch_turned_off_stops_its_call_now(tmp_path, short_dir):
    off = []

    class Recording:
        def question(self):
            return None

        def switched_off(self, app):
            off.append(app)

    srv = _server(tmp_path, Recording())
    try:
        assert _post(srv, "/api/settings", {"record_teams": False})[0] == 200
        assert _post(srv, "/api/settings", {"record_slack": True})[0] == 200
        assert _post(srv, "/api/settings", {"record_slack": False, "realtime": False})[0] == 200
        assert off == ["teams", "slack"]
    finally:
        srv.shutdown()
        srv.server_close()


# --- the language model's jobs across a server restart ----------------------------------

def _jobs(srv):
    return json.loads(_req(srv, "/api/model-jobs")[2])


def test_http_a_notes_run_of_an_earlier_server_shows_and_is_not_started_again(tmp_path):
    import subprocess
    import sys

    from palaver import model_jobs

    written = []
    _meeting(tmp_path)
    root = tmp_path / ".jobs"
    # The earlier server's run, still going: recorded by whoever started it.
    model_jobs.launch(root, "notes", MEETING, [sys.executable, "-c", "import time; time.sleep(1)"])
    srv = make_server(App(tmp_path, "Timo", write_notes=lambda mid: written.append(mid) or True), port=0)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        assert [(j["kind"], j["key"]) for j in _jobs(srv)["running"]] == [("notes", MEETING)]
        status, _ = _post(srv, f"/api/meetings/{MEETING}/notes")
        assert status == 200 and written == []  # it waited for that run
        assert _jobs(srv)["running"] == []
        assert model_jobs.read(root, "notes", MEETING) is None  # cleared once seen done
    finally:
        srv.shutdown()
        srv.server_close()
    del subprocess


def test_http_a_failed_notes_run_of_an_earlier_server_says_so(tmp_path):
    import sys

    from palaver import model_jobs

    _meeting(tmp_path)
    model_jobs.launch(tmp_path / ".jobs", "notes", MEETING, [sys.executable, "-c", "raise SystemExit(1)"])
    srv = make_server(App(tmp_path, "Timo", write_notes=lambda mid: True), port=0)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        status, answer = _post(srv, f"/api/meetings/{MEETING}/notes")
        assert status == 502 and "could not write" in answer["error"]
    finally:
        srv.shutdown()
        srv.server_close()


def test_http_a_sort_finished_after_a_restart_still_hands_its_undo_to_the_page(tmp_path):
    from palaver import model_jobs, projects, undo

    _meeting(tmp_path)
    root = tmp_path / ".jobs"
    # The earlier server took the snapshot, the app ran the sort to its end, then that server was gone.
    token = undo.take(tmp_path, "sort projects", stores=api._store_paths("projects"))
    model_jobs.pending_undo(root, token, "Meetings sorted by the model", owner=999999)
    model_jobs.write(root, {"kind": "projects", "key": "projects", "pid": 999999, "state": "done",
                            "returncode": 0, "started": 0})
    store = projects.ProjectStore()
    store.assign(MEETING, store.create("Hiring"), by="model", why="the title")
    store.save()
    srv = make_server(App(tmp_path, "Timo", run_projects=lambda args: True), port=0)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        jobs = _jobs(srv)
        assert jobs["finished"] == [{"token": token, "label": "Meetings sorted by the model", "ok": True}]
        assert _post(srv, "/api/model-jobs/seen", {"token": token})[0] == 200
        assert _jobs(srv)["finished"] == []
        assert _post(srv, "/api/undo", {"token": token})[0] == 200  # the undo works
        assert json.loads(_req(srv, "/api/projects")[2])["projects"] == []
    finally:
        srv.shutdown()
        srv.server_close()


def test_http_a_sort_that_failed_after_a_restart_is_rolled_back(tmp_path):
    from palaver import model_jobs, projects, undo

    _meeting(tmp_path)
    root = tmp_path / ".jobs"
    token = undo.take(tmp_path, "sort projects", stores=api._store_paths("projects"))
    model_jobs.pending_undo(root, token, "Meetings sorted by the model", owner=999999)
    model_jobs.write(root, {"kind": "projects", "key": "projects", "pid": 999999, "state": "done",
                            "returncode": 1, "started": 0})
    store = projects.ProjectStore()
    store.create("Half done")
    store.save()
    srv = make_server(App(tmp_path, "Timo", run_projects=lambda args: True), port=0)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        assert _jobs(srv)["finished"] == [{"token": token, "label": "Meetings sorted by the model", "ok": False}]
        assert json.loads(_req(srv, "/api/projects")[2])["projects"] == []
    finally:
        srv.shutdown()
        srv.server_close()


def test_http_a_sort_while_one_runs_is_refused(tmp_path):
    import sys

    from palaver import model_jobs

    _meeting(tmp_path)
    model_jobs.launch(tmp_path / ".jobs", "projects", "projects", [sys.executable, "-c", "import time; time.sleep(2)"])
    runs = []
    srv = make_server(App(tmp_path, "Timo", run_projects=lambda args: runs.append(args) or True), port=0)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        assert [j["kind"] for j in _jobs(srv)["running"]] == ["projects"]
        status, _ = _post(srv, "/api/projects/suggest")
        assert status == 409 and runs == []
    finally:
        srv.shutdown()
        srv.server_close()


def test_http_changes_count_for_the_drain_and_ping_answers(tmp_path, monkeypatch):
    _meeting(tmp_path)
    app = App(tmp_path, "Timo")
    seen = []
    real = api.trash_meeting
    monkeypatch.setattr(api, "trash_meeting", lambda *a, **kw: seen.append(app.inflight.count) or real(*a, **kw))
    srv = make_server(app, port=0)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        assert _req(srv, "/api/ping")[0] == 200
        assert _post(srv, f"/api/meetings/{MEETING}/trash")[0] == 200
        assert seen == [1]
        # The answer is sent from inside the change: it ends right after, maybe after the client read it.
        deadline = time.monotonic() + 5
        while app.inflight.count and time.monotonic() < deadline:
            time.sleep(0.01)
        assert app.inflight.count == 0
    finally:
        srv.shutdown()
        srv.server_close()


def test_start_helper_goes_to_the_app(short_dir):
    got = []
    srv = appctl.serve(short_dir / "app.sock", {"start_helper": lambda args: got.append(args) or {"pid": 42}})
    try:
        assert _remote(short_dir).start_helper("notes", MEETING, ["/m", "--force"]) == 42
        assert got == [{"kind": "notes", "key": MEETING, "args": ["/m", "--force"]}]
    finally:
        srv.close()
    with pytest.raises(appctl.CallFailed):
        _remote(short_dir).start_helper("notes", MEETING, ["/m", "--force"])


def _cfg(tmp_path):
    from palaver.config import Config

    return Config(user_name="Timo", notion_token="t", notion_parent_page_id="p", hf_token=None, output_dir=tmp_path,
                  retention_days=14, max_session_hours=4, grace_period_seconds=10, transcriber="parakeet-mlx",
                  whisper_repo="w", diarizer_repo="d", language="auto", calendar_enabled=False)


def test_build_app_has_the_app_start_the_notes_helper(tmp_path, monkeypatch):
    import sys

    from palaver import model_jobs, webapp

    _meeting(tmp_path)
    asked = []

    class Recording:
        def question(self):
            return None

        def start_helper(self, kind, key, args):
            asked.append((kind, key, args))
            return model_jobs.launch(tmp_path / ".jobs", kind, key, [sys.executable, "-c", "pass"])

    app = webapp.build_app(_cfg(tmp_path), ["--config", "/c.toml"], recording=Recording())
    assert app.write_notes(MEETING) is True
    assert asked == [("notes", MEETING, [str(tmp_path / MEETING), "--force"])]
    assert app.run_projects(["suggest"]) is True
    assert asked[1] == ("projects", "projects", ["--no-wait", "suggest"])


def test_build_app_runs_the_helper_itself_when_the_app_does_not_answer(tmp_path, monkeypatch):
    import sys

    from palaver import model_jobs, webapp

    _meeting(tmp_path)
    started = []

    class Recording:
        def question(self):
            return None

        def start_helper(self, kind, key, args):
            raise appctl.CallFailed("gone")

    monkeypatch.setattr(model_jobs, "helper_argv",
                        lambda kind, args, cli, *, output_dir: started.append(args) or [sys.executable, "-c", "pass"])
    app = webapp.build_app(_cfg(tmp_path), [], recording=Recording())
    assert app.write_notes(MEETING) is True
    assert started == [[str(tmp_path / MEETING), "--force"]]


def test_build_app_model_busy(tmp_path):
    import sys

    from palaver import model_jobs, webapp
    from palaver.cli import ModelBusy

    class Recording:
        def question(self):
            return None

        def start_helper(self, kind, key, args):
            return model_jobs.launch(tmp_path / ".jobs", kind, key, [sys.executable, "-c", "raise SystemExit(75)"])

    app = webapp.build_app(_cfg(tmp_path), [], recording=Recording())
    with pytest.raises(ModelBusy):
        app.run_projects(["suggest"])
