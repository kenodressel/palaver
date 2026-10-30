"""Local usage metrics (#59): an append-only event log that never fails its
caller, and the summary a problem report carries."""

import json
from datetime import datetime, timedelta

from palaver import usage

NOW = datetime(2026, 10, 30, 12, 0).astimezone()


def _at(days_ago: float) -> str:
    return (NOW - timedelta(days=days_ago)).isoformat()


def test_record_appends_one_small_json_line_per_event(tmp_path, monkeypatch):
    monkeypatch.setattr(usage, "PATH", tmp_path / "support" / "usage.jsonl")
    usage.record("action", "meeting.trash")
    usage.record("recording_stop", trigger="teams", seconds=1800.4)
    rows = [json.loads(line) for line in usage.PATH.read_text().splitlines()]
    assert [r["kind"] for r in rows] == ["action", "recording_stop"]
    assert rows[0]["id"] == "meeting.trash"
    assert rows[1]["trigger"] == "teams" and rows[1]["seconds"] == 1800.4
    assert all("ts" in r for r in rows)


def test_record_never_raises(tmp_path, monkeypatch):
    blocker = tmp_path / "file"
    blocker.write_text("")
    monkeypatch.setattr(usage, "PATH", blocker / "usage.jsonl")  # a file where the folder should be
    usage.record("action", "meeting.trash")
    usage.record("action", object())  # not even JSON


def test_long_texts_are_cut_so_events_stay_small(tmp_path, monkeypatch):
    monkeypatch.setattr(usage, "PATH", tmp_path / "usage.jsonl")
    usage.record("error", text="x" * 5000)
    row = json.loads(usage.PATH.read_text())
    assert len(row["text"]) <= usage.MAX_TEXT


def test_read_skips_broken_lines(tmp_path):
    path = tmp_path / "usage.jsonl"
    path.write_text('{"kind": "view", "id": "today", "ts": "2026-10-30T10:00:00+01:00"}\n{"kind": "vi\n[1]\n')
    assert [e["id"] for e in usage.read(path)] == ["today"]


def test_the_summary_counts_features_over_7_and_30_days_and_names_the_unused():
    events = [
        {"ts": _at(1), "kind": "action", "id": "meeting.trash"},
        {"ts": _at(10), "kind": "action", "id": "meeting.trash"},
        {"ts": _at(40), "kind": "action", "id": "meeting.split"},
        {"ts": _at(2), "kind": "view", "id": "people"},
        {"ts": _at(2), "kind": "cli", "id": "doctor", "by": "user"},
        {"ts": _at(2), "kind": "cli", "id": "live", "by": "app"},  # started by the app: no feature use
    ]
    catalog = {"action": ["meeting.trash", "meeting.split", "meeting.joinNext"], "view": ["people", "glossary"],
               "cli": ["doctor", "list"]}
    s = usage.summary(events, catalog, now=NOW)
    assert s["features"]["action:meeting.trash"] == {"7d": 1, "30d": 2, "all": 2}
    assert s["features"]["action:meeting.split"] == {"7d": 0, "30d": 0, "all": 1}
    assert "cli:live" not in s["features"]
    assert s["never_used"] == ["action:meeting.joinNext", "cli:list", "view:glossary"]
    assert s["unused_30d"] == ["action:meeting.joinNext", "action:meeting.split", "cli:list", "view:glossary"]


def test_the_summary_has_recording_notes_and_error_stats():
    events = [
        {"ts": _at(1), "kind": "recording_stop", "trigger": "teams", "seconds": 1800},
        {"ts": _at(3), "kind": "recording_stop", "trigger": "manual", "seconds": 600},
        {"ts": _at(50), "kind": "recording_stop", "trigger": "teams", "seconds": 60},
        {"ts": _at(1), "kind": "notes", "engine": "local", "model": "gemma", "seconds": 40, "ok": True},
        {"ts": _at(1), "kind": "notes", "engine": "local", "model": "gemma", "seconds": 90, "ok": False},
        {"ts": _at(1), "kind": "process", "seconds": 120, "ok": True},
        {"ts": _at(1), "kind": "error", "text": "Not joined: boom"},
    ]
    s = usage.summary(events, {}, now=NOW)
    assert s["recordings"]["30d"] == {"count": 2, "minutes": 40.0, "by_trigger": {"teams": 1, "manual": 1}}
    assert s["notes"]["30d"] == {"runs": 2, "ok": 1, "failed": 1, "median_seconds": 65.0,
                                 "by_model": {"local gemma": 2}}
    assert s["process"]["30d"]["runs"] == 1
    assert s["errors"]["30d"] == 1
    assert s["errors"]["last"] == [{"ts": _at(1), "text": "Not joined: boom"}]


def test_setting_events_name_the_key_never_a_secret():
    assert usage.setting_events("/api/settings", {"realtime": False, "bogus": 3}) == [
        {"id": "realtime", "value": False}]
    assert usage.setting_events("/api/language-model/key", {"provider": "openai", "key": "sk-123"}) == [
        {"id": "key.openai", "removed": False}]
    lm = usage.setting_events("/api/language-model", {"use": {"notes": "claude"}, "provider": "azure",
                                                       "endpoint": "https://x", "auth": "sk-zzz"})
    assert {"id": "use.notes", "value": "claude"} in lm
    assert {"id": "provider.azure", "fields": ["auth", "endpoint"]} in lm
    assert "sk-zzz" not in json.dumps(lm) and "https://x" not in json.dumps(lm)


def test_the_catalog_of_the_window_is_kept_and_merged_with_cli_and_settings(tmp_path, monkeypatch):
    monkeypatch.setattr(usage, "CATALOG_PATH", tmp_path / "features.json")
    usage.save_catalog({"action": ["meeting.trash"], "view": ["today"], "evil": ["x"]})
    catalog = usage.catalog()
    assert catalog["action"] == ["meeting.trash", "menubar.reportProblem"] and "evil" not in catalog
    assert "doctor" in catalog["cli"]
    assert "realtime" in catalog["setting"]
