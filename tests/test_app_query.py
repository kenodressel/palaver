"""`palaver app query`: what the native app asks of the Python side. Fakes only:
no EventKit access, no real meetings."""

import json
from datetime import datetime, timedelta
from pathlib import Path
from types import SimpleNamespace

import pytest

from palaver import app_query
from palaver.calendar_events import Attendee, Event
from palaver.cli import main


def _cfg(tmp_path: Path, **kw):
    return SimpleNamespace(output_dir=tmp_path, calendar_enabled=True, **kw)


def _run(capsys, what, args, cfg):
    rc = app_query.run(what, args, cfg)
    out = capsys.readouterr().out
    return rc, json.loads(out)


def test_missing_models_lists_the_labels(tmp_path, monkeypatch, capsys):
    from palaver import process_state

    seen = {}
    monkeypatch.setattr(process_state, "missing_models",
                        lambda cfg, paths: seen.setdefault("folder", paths.folder) and ["Speech models"])
    rc, out = _run(capsys, "missing-models", [str(tmp_path / "m")], _cfg(tmp_path))
    assert rc == 0 and out == {"missing": ["Speech models"]} and seen["folder"] == tmp_path / "m"


def test_index_stale_lists_folders(tmp_path, monkeypatch, capsys):
    from palaver import semantic
    from palaver.paths import RecordingPaths

    monkeypatch.setattr(semantic, "stale", lambda d: [RecordingPaths(d / "2026-10-21T16-29-29")])
    monkeypatch.setattr(semantic.embeddings, "model_folder", lambda download: None)
    rc, out = _run(capsys, "index-stale", [], _cfg(tmp_path))
    assert rc == 0 and out == {"stale": [str(tmp_path / "2026-10-21T16-29-29")], "model_ready": False}
    monkeypatch.setattr(semantic.embeddings, "model_folder", lambda download: tmp_path)
    assert _run(capsys, "index-stale", [], _cfg(tmp_path))[1]["model_ready"] is True


def test_notion_auto_sync_is_the_configs_with_the_keychain_token(tmp_path, monkeypatch, capsys):
    """The Swift app can't see a Notion token kept in the Keychain: Python's Config says
    whether a recording is run (uploaded) or processed and its notes written apart."""
    rc, out = _run(capsys, "notion-auto-sync", [], _cfg(tmp_path, notion_auto_sync=True, notes_enabled=False))
    assert rc == 0 and out == {"auto_sync": True, "notes": False}
    rc, out = _run(capsys, "notion-auto-sync", [], _cfg(tmp_path, notion_auto_sync=False, notes_enabled=True))
    assert out == {"auto_sync": False, "notes": True}


def test_notes_memory_gives_gb(tmp_path, monkeypatch, capsys):
    from palaver import llm

    monkeypatch.setattr(llm, "notes_memory_gb", lambda cfg, folder: 7.5)
    rc, out = _run(capsys, "notes-memory", [str(tmp_path)], _cfg(tmp_path))
    assert rc == 0 and out == {"gb": 7.5}


def _event(title, start, uid="u1", all_day=False):
    return Event(title=title, start=start, end=start + timedelta(hours=1), uid=uid, all_day=all_day,
                 attendees=(Attendee(name="Timo Strauß"),))


def test_next_event_is_the_first_timed_event_to_come(tmp_path, monkeypatch, capsys):
    now = datetime.now().astimezone()
    events = [_event("Past", now - timedelta(hours=1), "p"), _event("Holiday", now + timedelta(hours=1), "h", True),
              _event("Later", now + timedelta(hours=5), "l"), _event("Sync KLOUD", now + timedelta(hours=2), "s")]
    monkeypatch.setattr(app_query, "_events", lambda cfg, a, b: events)
    rc, out = _run(capsys, "next-event", [], _cfg(tmp_path))
    assert rc == 0 and out["event"]["title"] == "Sync KLOUD" and out["event"]["key"].startswith("s|")


def test_next_event_without_calendar_access_is_null(tmp_path, monkeypatch, capsys):
    from palaver import calendar_eventkit

    monkeypatch.setattr(calendar_eventkit, "has_access", lambda: False)
    rc, out = _run(capsys, "next-event", [], _cfg(tmp_path))
    assert rc == 0 and out == {"event": None}
    rc, out = _run(capsys, "next-event", [], SimpleNamespace(calendar_enabled=False))
    assert out == {"event": None}


def test_event_key_at_a_time(tmp_path, monkeypatch, capsys):
    when = datetime(2026, 11, 4, 10, 30).astimezone()
    ev = _event("Sync", when - timedelta(minutes=30), "abc")
    monkeypatch.setattr(app_query, "_events", lambda cfg, a, b: [ev])
    rc, out = _run(capsys, "event-key", [when.isoformat()], _cfg(tmp_path))
    assert rc == 0 and out == {"key": ev.key}
    monkeypatch.setattr(app_query, "_events", lambda cfg, a, b: None)
    assert _run(capsys, "event-key", [when.isoformat()], _cfg(tmp_path))[1] == {"key": None}


def test_bad_usage_and_failures_are_json_errors(tmp_path, monkeypatch, capsys):
    rc, out = _run(capsys, "nope", [], _cfg(tmp_path))
    assert rc == 2 and "usage" in out["error"]
    rc, out = _run(capsys, "missing-models", [], _cfg(tmp_path))
    assert rc == 2
    rc, out = _run(capsys, "event-key", ["not a time"], _cfg(tmp_path))
    assert rc == 1 and "error" in out


def test_the_cli_routes_app_query(tmp_path, monkeypatch, capsys):
    from palaver import llm

    cfg = tmp_path / "config.toml"
    cfg.write_text('[user]\nname = "Timo"\n')
    monkeypatch.setattr(llm, "notes_memory_gb", lambda c, f: 3.0)
    assert main(["--config", str(cfg), "app", "query", "notes-memory", str(tmp_path), "--json"]) == 0
    assert json.loads(capsys.readouterr().out) == {"gb": 3.0}


def test_app_autostart_still_rejects_other_words(monkeypatch):
    with pytest.raises(SystemExit):
        main(["app", "autostart", "maybe"])


def test_a_malformed_config_is_still_a_json_error(tmp_path, capsys):
    cfg = tmp_path / "config.toml"
    cfg.write_text("[user\nname = = =\n")
    rc = main(["--config", str(cfg), "app", "query", "index-stale", "--json"])
    out = capsys.readouterr().out
    assert rc != 0 and "error" in json.loads(out) and out.count("\n") == 1


def test_noise_while_answering_never_reaches_stdout(tmp_path, monkeypatch, capfd):
    import os

    from palaver import llm

    def chatty(cfg, folder):
        print("python noise")
        os.write(1, b"native noise\n")
        return 2.0

    monkeypatch.setattr(llm, "notes_memory_gb", chatty)
    assert app_query.run("notes-memory", [str(tmp_path)], _cfg(tmp_path)) == 0
    out, err = capfd.readouterr()
    assert json.loads(out) == {"gb": 2.0}
    assert "python noise" in err and "native noise" in err


def test_queries_never_ask_the_keychain_except_notion_auto_sync(tmp_path, monkeypatch, capsys):
    """The app asks these often: each Keychain read can be a prompt for palaver-python. Only
    notion-auto-sync needs the Notion token (it may be in the Keychain only)."""
    import keyring

    from palaver import llm

    asked = []
    monkeypatch.setattr(keyring, "get_password", lambda service, name: asked.append(name))
    monkeypatch.delenv("NOTION_TOKEN", raising=False)
    monkeypatch.delenv("HF_TOKEN", raising=False)
    monkeypatch.setattr(llm, "notes_memory_gb", lambda c, f: 3.0)
    cfg = tmp_path / "config.toml"
    cfg.write_text('[notion]\nparent_page_id = "abc"\n')
    assert main(["--config", str(cfg), "app", "query", "notes-memory", str(tmp_path), "--json"]) == 0
    assert main(["--config", str(cfg), "app", "query", "next-event", "--json"]) == 0
    assert asked == []
    capsys.readouterr()
    assert main(["--config", str(cfg), "app", "query", "notion-auto-sync", "--json"]) == 0
    assert "NOTION_TOKEN" in asked


def test_app_ping_says_whether_the_running_app_answers_on_app_sock(monkeypatch, capsys):
    """A manual check (docs/swift-app-manual-check.md): the Swift app serves app.sock."""
    from palaver import appctl

    monkeypatch.setattr(appctl, "call", lambda name, args=None, **kw: {"pid": 4242} if name == "ping" else None)
    assert main(["app", "ping"]) == 0
    assert "4242" in capsys.readouterr().out

    def gone(name, args=None, **kw):
        raise appctl.CallFailed("ping: [Errno 2] No such file or directory")

    monkeypatch.setattr(appctl, "call", gone)
    assert main(["app", "ping"]) == 1
    assert "does not answer" in capsys.readouterr().out
