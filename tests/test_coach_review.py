"""Review fixes of the live coach (#41, #42): "Keep on This Mac" never
leaks through the best next question, the coach's model is chosen on its
own (local by default), the button says which model runs and where, and
the local model during a call needs a second click."""

from __future__ import annotations

import io
import json
from pathlib import Path

import pytest

from palaver import llm, next_question as nq, providers, settings
from palaver.webapp import api

from .test_webapp import MEETING, _meeting

EARLIER = "2026-10-20T16-03-07"


def _earlier(root: Path, *, local_only: bool) -> None:
    paths = _meeting(root, EARLIER)
    if local_only:
        llm.set_local_only(paths.folder, True)


def _last_time(monkeypatch):
    """prep.context finds the earlier meeting with the same people."""
    from palaver import prep

    monkeypatch.setattr(prep, "context", lambda event, output_dir, **kw: [
        {"id": EARLIER, "title": "Hiring", "start": "2026-10-20T16:03:07+01:00", "why": "same people",
         "summary": "SECRET kept on this Mac", "next_steps": [{"task": "Check the band", "owner": "Rico"}]}])
    from datetime import datetime

    from palaver.calendar_events import Event

    at = datetime.fromisoformat("2026-10-27T16:00:00+01:00")
    monkeypatch.setattr(api, "_event_of", lambda paths, calendar: Event("Hiring", at, at))


def _cloud(monkeypatch):
    settings.update({"engines": {"coach": "anthropic"}})
    monkeypatch.setattr(providers, "problem", lambda pid, **kw: None)


# --- 1. Keep on This Mac --------------------------------------------------------------------


def test_a_cloud_engine_never_gets_a_meeting_kept_on_this_mac(tmp_path, monkeypatch):
    _meeting(tmp_path)
    _earlier(tmp_path, local_only=True)
    _last_time(monkeypatch)
    _cloud(monkeypatch)
    inputs = api.next_question_inputs(tmp_path, MEETING, user_name="Timo", cfg=None)
    assert inputs["last_time"] == []
    assert "SECRET" not in json.dumps(inputs)
    assert inputs["meetings"] == [MEETING]


def test_the_local_engine_may_read_it(tmp_path, monkeypatch):
    _meeting(tmp_path)
    _earlier(tmp_path, local_only=True)
    _last_time(monkeypatch)
    inputs = api.next_question_inputs(tmp_path, MEETING, user_name="Timo", cfg=None)
    assert [m["id"] for m in inputs["last_time"]] == [EARLIER]
    assert inputs["meetings"] == [MEETING, EARLIER]


def test_a_meeting_not_kept_here_goes_to_the_cloud_with_its_name_in_the_log(tmp_path, monkeypatch):
    _meeting(tmp_path)
    _earlier(tmp_path, local_only=False)
    _last_time(monkeypatch)
    _cloud(monkeypatch)
    inputs = api.next_question_inputs(tmp_path, MEETING, user_name="Timo", cfg=None)
    assert inputs["meetings"] == [MEETING, EARLIER]


def _cli(monkeypatch, tmp_path, inputs, *, cloud=True):
    from palaver import cli

    cfg = type("Cfg", (), {"output_dir": tmp_path})()
    monkeypatch.setattr(cli, "_load_cfg", lambda args: cfg)
    if cloud:
        _cloud(monkeypatch)
    seen = {}

    def engine(c, feature, *, parse=None, meetings=()):
        seen["meetings"] = [Path(m).name for m in meetings]
        return llm.Engine("anthropic" if cloud else "local", "Anthropic API", "claude-opus-5-5", cloud, 100_000,
                          lambda prompt, schema: seen.setdefault("prompt", prompt) and {"questions": []})

    monkeypatch.setattr(llm, "engine", engine)
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(inputs)))
    assert cli.main(["next-question", str(tmp_path / MEETING)]) == 0
    return seen


def test_the_helper_names_every_meeting_it_sends(tmp_path, monkeypatch):
    _meeting(tmp_path)
    _earlier(tmp_path, local_only=False)
    inputs = {"user": "Timo", "now": 15, "lines": [{"speaker": "Timo", "start": 1, "text": "Hallo?"}],
              "meetings": [MEETING, EARLIER],
              "last_time": [{"id": EARLIER, "title": "Hiring", "summary": "Fine", "next_steps": []}]}
    assert _cli(monkeypatch, tmp_path, inputs)["meetings"] == [MEETING, EARLIER]


def test_the_helper_drops_what_is_kept_on_this_mac_itself(tmp_path, monkeypatch):
    """Even when the inputs came from elsewhere: a cloud engine gets no
    meeting kept on this Mac."""
    _meeting(tmp_path)
    _earlier(tmp_path, local_only=True)
    inputs = {"user": "Timo", "now": 15, "lines": [{"speaker": "Timo", "start": 1, "text": "Hallo?"}],
              "meetings": [MEETING, EARLIER],
              "last_time": [{"id": EARLIER, "title": "Hiring", "summary": "SECRET", "next_steps": []}]}
    seen = _cli(monkeypatch, tmp_path, inputs)
    assert "SECRET" not in seen["prompt"]
    assert seen["meetings"] == [MEETING]


# --- 2. its own choice, local by default -----------------------------------------------------


def test_the_coach_never_inherits_the_notes_engine():
    cfg = type("Cfg", (), {"notes_engine": "claude", "notes_model": "opus", "claude_path": None})()
    assert llm.choice_for(cfg, "notes") == "claude-cli"
    assert llm.choice_for(cfg, "coach") == "local"
    lm = api.language_model(cfg)
    coach = next(f for f in lm["features"] if f["id"] == "coach")
    assert coach["choice"] == "local" and coach["default"] == "local"


def test_the_setup_assistant_leaves_the_coach_alone():
    from palaver import onboarding

    reg = api.setup_registry(None)
    assert "coach" not in reg.features_of(onboarding.LANGUAGE_MODEL)
    assert set(reg.features_of(onboarding.LANGUAGE_MODEL)) == {"notes", "projects"}


def test_the_button_names_the_model_and_where_it_runs(tmp_path, monkeypatch):
    _meeting(tmp_path)
    info = api.next_question_info(None, tmp_path, MEETING, enabled=True)
    assert info == {"ready": True, "reason": None, "label": "Best next question (Gemma, on this Mac)",
                    "local": True, "warning": None}
    monkeypatch.setattr(api, "_status", lambda paths: "recording")
    assert api.next_question_info(None, tmp_path, MEETING, enabled=True)["warning"] == \
        "Runs Gemma on this Mac during the call (about 10 GB, may slow the call)"
    _cloud(monkeypatch)
    info = api.next_question_info(None, tmp_path, MEETING, enabled=True)
    assert info["label"] == "Best next question (Claude Opus 5.5, cloud)" and info["warning"] is None


def test_the_button_is_off_with_the_reason(tmp_path):
    _meeting(tmp_path)
    off = api.next_question_info(None, tmp_path, MEETING, enabled=False)
    assert off["ready"] is False and off["reason"] == "Notes are turned off, and with them the language model."
    settings.update({"engines": {"coach": providers.PENDING}})
    pending = api.next_question_info(None, tmp_path, MEETING, enabled=True)
    assert pending["ready"] is False
    assert pending["reason"] == "No model yet: choose one for Best next question in Settings → Language model."


def test_model_names():
    assert nq.model_name("claude-opus-5-5") == "Claude Opus 5.5"
    assert nq.model_name("claude-sonnet-4-5-20250929") == "Claude Sonnet 4.5"
    assert nq.model_name("sonnet") == "Claude Sonnet"
    assert nq.model_name("gpt-5") == "gpt-5"
