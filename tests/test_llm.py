"""Which language model runs a feature (palaver/llm.py): local by default,
a cloud provider only when the user chose it, never for a meeting kept
on this Mac; the context window; the access log."""

import json
from pathlib import Path

import pytest

from palaver import access_log, cloud_llm, keychain, llm, notes, providers, settings
from palaver.cloud_llm import Response

KEY = "sk-ant-api03-SECRET-abcdefghijklmnop"
NOTES_ANSWER = {"title": "T", "summary": "S", "sections": [], "next_steps": [], "decisions": [],
                "speaker_names": []}


def cfg(**kw):
    values = {"user_name": "Timo", "notes_engine": "local", "notes_local_model": "repo/x", "notes_model": "sonnet",
              "claude_path": None}
    return type("Cfg", (), {**values, **kw})()


@pytest.fixture
def local_calls(monkeypatch):
    calls = []

    def local_runner(repo, **kw):
        def run(prompt, schema):
            calls.append((repo, prompt))
            return {"local": True}
        return run

    monkeypatch.setattr(notes, "local_runner", local_runner)
    return calls


@pytest.fixture
def anthropic_api(monkeypatch):
    """Anthropic chosen for notes, with a key; requests go to a fake."""
    keychain.set(providers.key_account("anthropic"), KEY)
    providers.choose("notes", "anthropic")
    sent = []

    def transport(request):
        sent.append(request)
        return Response(200, {}, json.dumps({"content": [{"type": "text", "text": json.dumps(NOTES_ANSWER)}],
                                             "stop_reason": "end_turn"}).encode())

    monkeypatch.setattr(cloud_llm, "default_transport", transport)
    return sent


def test_local_by_default(local_calls):
    engine = llm.engine(cfg(), "notes")
    assert engine.choice == "local" and not engine.cloud and engine.model == "repo/x"
    assert engine.run("PROMPT", {}) == {"local": True}
    assert local_calls == [("repo/x", "PROMPT")]
    assert access_log.recent() == []  # nothing left the Mac
    assert llm.engine(cfg(), "projects").choice == "local"


def test_config_toml_claude_still_means_the_claude_cli(monkeypatch):
    monkeypatch.setattr(notes, "find_claude", lambda configured=None: "/bin/claude")
    monkeypatch.setattr(notes, "claude_runner", lambda claude, model: lambda p, s: {"cli": model})
    engine = llm.engine(cfg(notes_engine="claude", notes_model="opus"), "notes")
    assert engine.choice == "claude-cli" and engine.cloud and engine.model == "opus"
    assert engine.run("P", {}) == {"cli": "opus"}
    (entry,) = access_log.recent()
    assert entry["provider"] == "claude-cli" and entry["feature"] == "notes"


def test_the_claude_cli_missing_is_said(monkeypatch):
    with pytest.raises(llm.Unavailable, match="Claude Code"):
        llm.engine(cfg(notes_engine="claude"), "notes")


def test_a_chosen_cloud_provider_runs_and_is_logged(anthropic_api, local_calls, tmp_path: Path, fake_keychain):
    meeting = tmp_path / "2026-10-27T16-03-07"
    meeting.mkdir()
    engine = llm.engine(cfg(), "notes", meetings=[meeting])
    assert engine.choice == "anthropic" and engine.cloud and engine.model == "claude-opus-5-5"
    assert engine.run("PROMPT " * 10, notes.SCHEMA)["title"] == "T"
    assert local_calls == [] and len(anthropic_api) == 1
    (entry,) = access_log.recent()
    assert entry == {**entry, "provider": "anthropic", "host": "api.anthropic.com", "model": "claude-opus-5-5",
                     "feature": "notes", "meetings": ["2026-10-27T16-03-07"], "ok": True}
    assert entry["chars"] >= len("PROMPT " * 10)
    assert KEY not in access_log.path().read_text()
    # Projects were not chosen: they stay local.
    assert llm.engine(cfg(), "projects").choice == "local"


def test_a_meeting_kept_on_this_mac_overrides_the_cloud(anthropic_api, local_calls, tmp_path: Path):
    meeting = tmp_path / "m"
    meeting.mkdir()
    llm.set_local_only(meeting, True)
    assert llm.is_local_only(meeting)
    engine = llm.engine(cfg(), "notes", meetings=[meeting])
    assert engine.choice == "local"
    engine.run("P", {})
    assert anthropic_api == [] and len(local_calls) == 1
    llm.set_local_only(meeting, False)
    assert not llm.is_local_only(meeting)
    assert llm.engine(cfg(), "notes", meetings=[meeting]).choice == "anthropic"


def test_no_silent_fallback_when_the_chosen_provider_is_not_ready(anthropic_api, local_calls, fake_keychain):
    fake_keychain.clear()  # the key was removed after choosing
    with pytest.raises(llm.Unavailable) as err:
        llm.engine(cfg(), "notes")
    assert "Anthropic" in str(err.value) and "API key" in str(err.value)
    assert local_calls == [] and anthropic_api == []


def test_a_failed_cloud_call_is_logged_without_the_key(monkeypatch, anthropic_api):
    monkeypatch.setattr(cloud_llm, "default_transport",
                        lambda req: Response(401, {}, json.dumps({"error": {"message": f"bad {KEY}"}}).encode()))
    engine = llm.engine(cfg(), "notes")
    with pytest.raises(cloud_llm.CloudError):
        engine.run("P", notes.SCHEMA)
    (entry,) = access_log.recent()
    assert entry["ok"] is False and "401" in entry["error"]
    assert KEY not in access_log.path().read_text()


def test_too_long_for_the_context_window_is_said_before_sending(anthropic_api):
    providers.configure("anthropic", context_tokens=1_000)
    engine = llm.engine(cfg(), "notes")
    with pytest.raises(llm.ContextTooLong) as err:
        engine.run("word " * 5_000, notes.SCHEMA)
    assert anthropic_api == []  # nothing sent, nothing cut off
    message = str(err.value)
    assert "1,000" in message and "claude-opus-5-5" in message
    assert access_log.recent() == []


def test_the_local_model_has_a_context_window_too(local_calls):
    engine = llm.engine(cfg(notes_local_model=notes.DEFAULT_LOCAL_MODEL), "notes")
    assert engine.context_tokens == llm.LOCAL_MODELS[notes.DEFAULT_LOCAL_MODEL]["context_tokens"]
    with pytest.raises(llm.ContextTooLong):
        engine.run("x" * (engine.context_tokens * 5), {})
    assert local_calls == []
    assert llm.engine(cfg(notes_local_model="someone/else"), "notes").context_tokens == llm.LOCAL_CONTEXT_TOKENS


def test_estimate_tokens_errs_on_the_high_side():
    assert llm.estimate_tokens("") == 0
    assert llm.estimate_tokens("Guten Morgen zusammen") >= 5
    assert llm.estimate_tokens("x" * 3000) >= 1000


def test_local_model_from_settings(local_calls):
    llm.choose_local_model("mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit")
    assert llm.engine(cfg(), "notes").model == "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"
    with pytest.raises(ValueError):
        llm.choose_local_model("evil/model")


def test_notes_memory_follows_the_choice_and_the_meeting(anthropic_api, tmp_path: Path):
    c = cfg(notes_local_model=notes.DEFAULT_LOCAL_MODEL)
    meeting = tmp_path / "m"
    meeting.mkdir()
    assert llm.notes_memory_gb(c) == 0.0  # Anthropic chosen: nothing to load here
    assert llm.notes_memory_gb(c, meeting) == 0.0
    llm.set_local_only(meeting, True)
    assert llm.notes_memory_gb(c, meeting) == notes.MODEL_MEMORY_GB[notes.DEFAULT_LOCAL_MODEL]
    providers.choose("notes", "local")
    assert llm.notes_memory_gb(c) == notes.MODEL_MEMORY_GB[notes.DEFAULT_LOCAL_MODEL]
    # Chosen in Settings, local wins over config.toml's claude; never chosen, config.toml decides.
    assert llm.notes_memory_gb(cfg(notes_engine="claude", notes_local_model=notes.DEFAULT_LOCAL_MODEL)) > 0
    settings.update({"engines": {}})
    assert llm.notes_memory_gb(cfg(notes_engine="claude")) == 0.0


def test_test_sends_a_tiny_prompt_and_times_it(anthropic_api):
    result = llm.test("anthropic", cfg())
    assert result["answer"] and result["seconds"] >= 0
    body = json.loads(anthropic_api[0].body)
    assert len(body["messages"][0]["content"]) < 200  # no meeting content
    (entry,) = access_log.recent()
    assert entry["feature"] == "test" and entry["meetings"] == []


def test_test_needs_a_ready_provider(fake_keychain):
    with pytest.raises(llm.Unavailable, match="API key"):
        llm.test("anthropic", cfg())


def test_a_failing_access_log_never_costs_the_answer(anthropic_api, monkeypatch, caplog):
    def broken(**entry):
        raise OSError("disk full")

    monkeypatch.setattr(access_log, "record", broken)
    engine = llm.engine(cfg(), "notes")
    assert engine.run("P", notes.SCHEMA)["title"] == "T"
    assert "access log" in caplog.text


def test_an_answer_cut_off_is_an_explained_error_in_the_log(monkeypatch, anthropic_api):
    monkeypatch.setattr(cloud_llm, "default_transport", lambda req: Response(200, {}, json.dumps(
        {"content": [{"type": "text", "text": "{\"title\": \"T"}], "stop_reason": "max_tokens"}).encode()))
    with pytest.raises(cloud_llm.CloudError, match="cut off"):
        llm.engine(cfg(), "notes").run("P", notes.SCHEMA)
    assert "cut off" in access_log.recent()[0]["error"]


def test_notes_waiting_for_a_cloud_model_run_nothing(tmp_path):
    """#55: on a Mac too small for the local model, notes are off until a
    cloud model is set up: no local model, not even for a meeting kept here."""
    from palaver import llm, providers, settings

    providers.choose("notes", providers.PENDING)
    assert settings.read_raw()["engines"]["notes"] == "pending"
    assert llm.choice_for(None, "notes") == providers.PENDING
    (tmp_path / "m").mkdir()
    llm.set_local_only(tmp_path / "m", True)
    assert llm.choice_for(None, "notes", [tmp_path / "m"]) == providers.PENDING
    with pytest.raises(llm.Unavailable, match="set up a cloud model"):
        llm.engine(None, "notes")
    assert llm.notes_memory_gb(None, tmp_path / "m") == 0.0  # nothing waits for memory
    with pytest.raises(ValueError):
        providers.choose("transcription", providers.PENDING)
