"""The live coach in the window (#41): who talks and the nudge, and the
best next question, through the app's HTTP API. Fake recordings and fake
language models only."""

from __future__ import annotations

import json
import threading
from pathlib import Path

from palaver.webapp import api
from palaver.webapp.server import App, make_server

from .test_webapp import MEETING, _meeting, _post, _req

COACH = {"meeting": MEETING, "talk": {"speaking": "me", "share": 0.62}, "text": "You 62 % of the last 10 min",
         "nudge": {"kind": "monologue", "text": "4-min monologue", "at": 610.0}}


class _Recording:
    def __init__(self, coach=None):
        self.live = coach

    def question(self):
        return None

    def coach(self):
        return self.live


def _server(tmp_path: Path, recording, **kw):
    _meeting(tmp_path)
    srv = make_server(App(tmp_path, "Timo", recording=recording, **kw), port=0)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def test_http_the_live_coach_of_the_running_recording(tmp_path: Path):
    srv = _server(tmp_path, _Recording(COACH))
    try:
        status, _, body = _req(srv, "/api/recording/coach")
        assert status == 200 and json.loads(body) == {"coach": COACH}
    finally:
        srv.shutdown()
        srv.server_close()


def test_no_live_coach_outside_the_menu_bar_app():
    assert api.live_coach(None) == {"coach": None}
    assert api.live_coach(object()) == {"coach": None}  # an app without one


# --- best next question ----------------------------------------------------------------

ANSWER = {"questions": [{"question": "Who owns the salary band?", "why": "It was called fine, without an owner."}],
          "engine": "Fake model"}


class _Model:
    def __init__(self, answer=ANSWER):
        self.answer = answer
        self.inputs = []

    def __call__(self, meeting_id, inputs):
        self.inputs.append((meeting_id, inputs))
        if isinstance(self.answer, Exception):
            raise self.answer
        return self.answer


def test_http_best_next_question(tmp_path: Path):
    model = _Model()
    srv = _server(tmp_path, _Recording(COACH), ask_model=model, free_memory_gb=lambda: 64.0)
    try:
        status, answer = _post(srv, f"/api/meetings/{MEETING}/next-question")
    finally:
        srv.shutdown()
        srv.server_close()
    assert status == 200 and answer == ANSWER
    meeting, inputs = model.inputs[0]
    assert meeting == MEETING
    assert [line["text"] for line in inputs["lines"]][-1] == "Thanks Rico, the salary band is fine."
    assert inputs["user"] == "Timo" and inputs["now"] == 15.0


def test_the_local_model_does_not_start_without_its_memory_during_a_call(tmp_path: Path, monkeypatch):
    model = _Model()
    monkeypatch.setattr(api, "_status", lambda paths: "recording")
    srv = _server(tmp_path, _Recording(COACH), ask_model=model, free_memory_gb=lambda: 6.0)
    try:
        status, answer = _post(srv, f"/api/meetings/{MEETING}/next-question")
    finally:
        srv.shutdown()
        srv.server_close()
    assert status == 400
    assert answer["error"] == ("Not enough free memory for the local model during the call; choose a cloud model "
                               "in Settings → Language model, or ask after the call")
    assert model.inputs == []


def test_a_cloud_model_needs_no_free_memory(tmp_path: Path, monkeypatch):
    from palaver import llm

    model = _Model()
    monkeypatch.setattr(api, "_status", lambda paths: "recording")
    monkeypatch.setattr(llm, "choice_for", lambda cfg, feature, meetings=(): "anthropic")
    srv = _server(tmp_path, _Recording(COACH), ask_model=model, free_memory_gb=lambda: 1.0)
    try:
        status, answer = _post(srv, f"/api/meetings/{MEETING}/next-question")
    finally:
        srv.shutdown()
        srv.server_close()
    assert status == 200 and model.inputs


def test_keep_on_this_mac_keeps_it_local(tmp_path: Path):
    """A meeting kept on this Mac is never sent to a cloud model, whatever
    the coach's choice: the local model's memory check applies."""
    from palaver import llm, providers

    paths = _meeting(tmp_path)
    llm.set_local_only(paths.folder, True)
    from palaver import settings
    settings.update({"engines": {"coach": "claude-cli"}})
    assert llm.choice_for(None, "coach", [paths.folder]) == "local"
    assert llm.memory_gb(None, "coach", paths.folder) == 14.0


def test_a_model_that_fails_says_why(tmp_path: Path):
    from palaver.notes import NotesError

    srv = _server(tmp_path, _Recording(COACH), ask_model=_Model(NotesError("Anthropic API: the key was refused")),
                  free_memory_gb=lambda: 64.0)
    try:
        status, answer = _post(srv, f"/api/meetings/{MEETING}/next-question")
    finally:
        srv.shutdown()
        srv.server_close()
    assert status == 502 and answer["error"] == "Anthropic API: the key was refused"


def test_no_question_without_a_language_model(tmp_path: Path):
    srv = _server(tmp_path, _Recording(COACH))
    try:
        status, answer = _post(srv, f"/api/meetings/{MEETING}/next-question")
    finally:
        srv.shutdown()
        srv.server_close()
    assert status == 503 and "turned off" in answer["error"]


def test_the_question_inputs_carry_the_prep(tmp_path: Path):
    from datetime import datetime

    from palaver import calendar_events
    from palaver.calendar_events import Attendee, Event

    paths = _meeting(tmp_path)
    (paths.folder / "my-notes.json").write_text(json.dumps([{"text": "ask about the budget", "at": None},
                                                            {"text": "", "at": 3}]))
    at = datetime.fromisoformat("2026-10-27T16:00:00+01:00")
    calendar_events.save(paths, Event("Hiring debrief", at, at.replace(hour=17), attendees=(
        Attendee("Timo", is_self=True), Attendee("Rico Lanza"), Attendee("Valerie Vogel"))))
    inputs = api.next_question_inputs(tmp_path, MEETING, user_name="Timo", calendar=None,
                                      coach={"quiet": ["Valerie Vogel"]})
    assert inputs["title"] == "Hiring debrief"
    assert inputs["invitees"] == ["Rico Lanza", "Valerie Vogel"]
    assert inputs["quiet"] == ["Valerie Vogel"]
    assert inputs["my_notes"] == ["ask about the budget"]
    assert inputs["last_time"] == []


def test_the_app_asks_in_a_helper_process(tmp_path: Path, monkeypatch):
    import subprocess

    from palaver import webapp
    from palaver.config import Config
    from palaver.notes import NotesError

    cfg = Config(user_name="Timo", notion_token="t", notion_parent_page_id="p", hf_token=None, output_dir=tmp_path,
                 retention_days=14, max_session_hours=4, grace_period_seconds=10, transcriber="parakeet-mlx",
                 whisper_repo="w", language="auto", calendar_enabled=False)
    _meeting(tmp_path)
    runs = []

    class _Popen:
        def __init__(self, argv, **kw):
            runs.append((argv, kw))
            self.argv, self.returncode = argv, None
            self.out, self.rc = outcome[0]

        def communicate(self, input=None, timeout=None):
            self.input, self.returncode = input, self.rc
            return self.out, ""

        def poll(self):
            return self.returncode

    class _Recording:
        watched = []

        def question(self):
            return None

        def watch(self, folder, process):
            self.watched.append((folder, process))

    outcome = [(json.dumps(ANSWER) + "\n", 0)]
    monkeypatch.setattr(webapp, "_popen", _Popen)
    rec = _Recording()
    app = webapp.build_app(cfg, ["--config", "/c.toml"], recording=rec)
    assert app.ask_model(MEETING, {"lines": []}) == ANSWER
    argv, kw = runs[0]
    assert argv[-2:] == ["next-question", str(tmp_path / MEETING)] and "--config" in argv
    assert kw.get("start_new_session") is True
    assert [(f.name, p.argv) for f, p in rec.watched] == [(MEETING, argv)]  # the notes' memory budget (#49)
    assert json.loads(rec.watched[0][1].input) == {"lines": []}
    for out, rc, said in [(json.dumps({"error": "Anthropic API: no key"}), 1, "Anthropic API: no key"),
                          ("", -15, "The local model was stopped: the Mac ran low on memory.")]:
        outcome[0] = (out, rc)
        try:
            app.ask_model(MEETING, {})
            raise AssertionError("no error")
        except NotesError as exc:
            assert str(exc) == said
    assert app.free_memory_gb() > 0


def test_http_the_button_says_which_model(tmp_path: Path):
    srv = _server(tmp_path, _Recording(COACH), ask_model=_Model(), free_memory_gb=lambda: 64.0)
    try:
        status, _, body = _req(srv, f"/api/meetings/{MEETING}/next-question")
    finally:
        srv.shutdown()
        srv.server_close()
    assert status == 200 and json.loads(body)["label"] == "Best next question (Gemma, on this Mac)"


def test_the_local_model_during_a_call_needs_a_second_click(tmp_path: Path, monkeypatch):
    model = _Model()
    monkeypatch.setattr(api, "_status", lambda paths: "recording")
    srv = _server(tmp_path, _Recording(COACH), ask_model=model, free_memory_gb=lambda: 64.0)
    try:
        status, answer = _post(srv, f"/api/meetings/{MEETING}/next-question")
        assert status == 409 and answer["error"].startswith("Runs Gemma on this Mac during the call")
        assert model.inputs == []
        status, answer = _post(srv, f"/api/meetings/{MEETING}/next-question", {"confirmed": True})
        assert status == 200 and model.inputs
    finally:
        srv.shutdown()
        srv.server_close()


def test_no_helper_without_a_model_chosen(tmp_path: Path):
    from palaver import providers, settings

    model = _Model()
    settings.update({"engines": {"coach": providers.PENDING}})
    srv = _server(tmp_path, _Recording(COACH), ask_model=model, free_memory_gb=lambda: 64.0)
    try:
        status, answer = _post(srv, f"/api/meetings/{MEETING}/next-question", {"confirmed": True})
    finally:
        srv.shutdown()
        srv.server_close()
    assert status == 400 and "No model yet" in answer["error"] and model.inputs == []
