"""Best next question (#41): the prompt, the strict answer, and the memory
check before a local model starts during a call. Fake runners only: no
model runs in these tests."""

from __future__ import annotations

import json

import pytest

from palaver import next_question as nq

LINES = [
    {"speaker": "Timo", "start": 10.0, "text": "Let's look at the Databricks access."},
    {"speaker": "Jasper Costa", "start": 30.0, "text": "Someone needs to request it, we said that last week too."},
    {"speaker": "Timo", "start": 400.0, "text": "And the budget for Q1?"},
    {"speaker": "Others", "start": 420.0, "text": "That depends on the staffing."},
]

INPUTS = {
    "user": "Timo",
    "now": 430.0,
    "lines": LINES,
    "title": "Weekly with Contoso",
    "invitees": ["Jasper Costa", "Valerie Vogel"],
    "quiet": ["Valerie Vogel"],
    "last_time": [{"title": "Weekly with Contoso", "start": "2026-10-23T10:00:00+02:00",
                   "summary": "Staffing was open.", "next_steps": [{"task": "Check the staffing", "owner": "Jasper"}]}],
    "my_notes": ["ask about the budget", "Databricks access?"],
}


def test_the_prompt_holds_the_last_minutes_and_the_context():
    prompt = nq.build_prompt(INPUTS)
    assert "[06:40] Timo: And the budget for Q1?" in prompt
    assert "[00:30] Jasper Costa" not in prompt  # older than five minutes
    assert "Weekly with Contoso" in prompt and "Valerie Vogel" in prompt
    assert "Check the staffing (Jasper)" in prompt
    assert "ask about the budget" in prompt
    assert "Only use what the transcript and the context below show" in prompt


def test_the_prompt_takes_older_lines_when_the_last_minutes_are_empty():
    prompt = nq.build_prompt({**INPUTS, "now": 2000.0})
    assert "And the budget for Q1?" in prompt


def test_no_question_without_a_transcript():
    with pytest.raises(nq.NothingYet):
        nq.build_prompt({**INPUTS, "lines": []})


def test_parse_keeps_one_to_three_questions_with_their_why():
    text = json.dumps({"questions": [
        {"question": "Who requests the Databricks access?", "why": "It came up without a name."},
        {"question": "  ", "why": "empty"},
        {"question": "Valerie, how do you see it?", "why": "She hasn't spoken."},
        {"question": "Where is the staffing?", "why": "Open from last time."},
        {"question": "A fourth?", "why": "too many"}]})
    out = nq.parse(text)
    assert [q["question"] for q in out["questions"]] == [
        "Who requests the Databricks access?", "Valerie, how do you see it?", "Where is the staffing?"]
    assert all(q["why"] for q in out["questions"])


def test_parse_refuses_what_is_not_the_answer():
    with pytest.raises(ValueError):
        nq.parse("I think you should ask about the budget.")
    with pytest.raises(ValueError):
        nq.parse(json.dumps({"questions": "ask about the budget"}))


def test_ask_runs_the_engine_with_the_schema():
    seen = []

    def runner(prompt, schema):
        seen.append((prompt, schema))
        return {"questions": [{"question": "Who owns it?", "why": "No owner was named."}]}

    out = nq.ask(INPUTS, runner)
    assert out == {"questions": [{"question": "Who owns it?", "why": "No owner was named."}]}
    assert seen[0][1] == nq.SCHEMA and seen[0][1]["properties"]["questions"]["maxItems"] == 3


# --- memory: the local model during a call -------------------------------------------------


def test_the_local_model_needs_its_memory():
    assert nq.memory_problem(local=True, free_gb=20.0, need_gb=14.0, recording=True) is None
    assert nq.memory_problem(local=True, free_gb=9.0, need_gb=14.0, recording=True) == (
        "Not enough free memory for the local model during the call; choose a cloud model in "
        "Settings → Language model, or ask after the call")
    assert nq.memory_problem(local=True, free_gb=9.0, need_gb=14.0, recording=False) == (
        "Not enough free memory for the local model right now (9 GB free, it needs 14 GB); choose a cloud "
        "model in Settings → Language model, or try again later")
    assert nq.memory_problem(local=False, free_gb=1.0, need_gb=0.0, recording=True) is None


# --- the helper process: `palaver next-question` ----------------------------------------------


def _engine(run, local=False):
    from palaver.llm import Engine

    return Engine("local" if local else "anthropic", "Gemma 4 12B on this Mac" if local else "Anthropic API",
                  "m", not local, 100_000, run)


def test_the_cli_answers_with_questions(tmp_path, monkeypatch, capsys):
    import io

    from palaver import cli, llm

    monkeypatch.setattr(cli, "_load_cfg", lambda args: None)
    seen = []

    def engine(cfg, feature, *, parse=None, meetings=()):
        seen.append((feature, [str(m) for m in meetings], parse))
        return _engine(lambda prompt, schema: {"questions": [{"question": "Who owns it?", "why": "No owner."}]})

    monkeypatch.setattr(llm, "engine", engine)
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(INPUTS)))
    assert cli.main(["next-question", str(tmp_path)]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out == {"questions": [{"question": "Who owns it?", "why": "No owner."}], "engine": "Anthropic API"}
    assert seen == [("coach", [str(tmp_path)], nq.parse)]


def test_the_cli_says_why_it_failed(tmp_path, monkeypatch, capsys):
    import io

    from palaver import cli, llm
    from palaver.notes import NotesError

    monkeypatch.setattr(cli, "_load_cfg", lambda args: None)

    def fail(prompt, schema):
        raise NotesError("Anthropic API: the key was refused")

    monkeypatch.setattr(llm, "engine", lambda cfg, feature, **kw: _engine(fail))
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(INPUTS)))
    assert cli.main(["next-question", str(tmp_path)]) == 1
    assert json.loads(capsys.readouterr().out) == {"error": "Anthropic API: the key was refused"}


def test_the_cli_waits_for_no_one_with_the_local_model(tmp_path, monkeypatch, capsys, notes_lock_in_tmp):
    """A local model in use elsewhere (notes): busy, at once."""
    import fcntl
    import io

    from palaver import cli, llm

    monkeypatch.setattr(cli, "_load_cfg", lambda args: None)
    monkeypatch.setattr(llm, "engine", lambda cfg, feature, **kw: _engine(lambda p, s: {"questions": []}, local=True))
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(INPUTS)))
    with open(notes_lock_in_tmp, "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        assert cli.main(["next-question", str(tmp_path)]) == cli.EXIT_MODEL_BUSY
    assert "busy" in json.loads(capsys.readouterr().out)["error"]
