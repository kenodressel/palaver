"""The window's side of #59: the report form's API, and what the page and
the Settings page count in the usage log."""

import json
import zipfile
from pathlib import Path

from palaver import usage

from tests.test_webapp import MEETING, _post, server  # noqa: F401 (the fixture)


def test_http_report_writes_the_zip_and_shows_it_in_finder(server, report_home):  # noqa: F811
    status, answer = _post(server, "/api/report", {"kind": "bug", "text": "Speakers mixed up",
                                                   "meeting": MEETING, "audio": False})
    assert status == 200
    path = Path(answer["path"])
    assert path.parent == report_home.desktop and path.is_file()
    assert report_home.revealed == [path]
    assert answer["size"] == path.stat().st_size and answer["size_text"].endswith(("KB", "MB"))
    with zipfile.ZipFile(path) as z:
        assert json.loads(z.read("report.json"))["form"]["text"] == "Speakers mixed up"
        assert f"meetings/{MEETING}/transcript.json" in z.namelist()
        assert not [n for n in z.namelist() if n.endswith(".wav")]


def test_http_report_refuses_a_bad_form(server, report_home):  # noqa: F811
    assert _post(server, "/api/report", {"kind": "rant"})[0] == 400
    assert _post(server, "/api/report", {"meeting": "../secrets"})[0] == 400
    assert not report_home.desktop.exists() or not list(report_home.desktop.iterdir())


def test_http_usage_records_the_pages_events_and_keeps_its_catalog(server):  # noqa: F811
    status, _ = _post(server, "/api/usage", {
        "events": [{"kind": "action", "id": "meeting.trash"}, {"kind": "view", "id": "people"},
                   {"kind": "error", "text": "Not joined: boom"}, {"kind": "recording_stop", "seconds": 1},
                   "nonsense"],
        "catalog": {"action": ["meeting.trash", "meeting.split"]}})
    assert status == 200
    events = usage.read()
    assert [(e["kind"], e.get("id")) for e in events] == [("action", "meeting.trash"), ("view", "people"),
                                                          ("error", None)]
    assert events[2]["text"] == "Not joined: boom"
    assert usage.catalog()["action"] == ["meeting.split", "meeting.trash", "menubar.reportProblem"]


def _log(tmp_path, *rows):
    from palaver.paths import RecordingPaths

    paths = RecordingPaths(tmp_path / "m")
    paths.folder.mkdir(exist_ok=True)
    paths.session_log.write_text("".join(json.dumps(r) + "\n" for r in rows))
    return paths


def test_a_failed_run_is_found_until_it_is_done_right(tmp_path):
    from palaver.webapp.api import last_failure

    ok = [{"event": "process_start"}, {"event": "notes_start"}, {"event": "notes_done"}, {"event": "process_done", "rc": 0}]
    assert last_failure(_log(tmp_path, *ok)) is None
    notes = _log(tmp_path, {"event": "process_start"}, {"event": "notes_start"},
                 {"event": "notes_failed", "error": "the model ran out of memory"}, {"event": "process_done", "rc": 0})
    assert last_failure(notes)["step"] == "notes"
    assert last_failure(notes)["error"] == "the model ran out of memory"
    crashed = _log(tmp_path, {"event": "process_start"}, {"event": "transcribe_start"},
                   {"level": "ERROR", "message": "command failed", "traceback": "Traceback…\nRuntimeError: no GPU"})
    assert last_failure(crashed) == {"step": "process", "error": "RuntimeError: no GPU", "at": None}
    again = _log(tmp_path, {"event": "process_done", "rc": 3}, {"event": "process_start"},
                 {"event": "process_done", "rc": 0})
    assert last_failure(again) is None


def test_http_a_settings_change_is_counted_by_its_key(server):  # noqa: F811
    assert _post(server, "/api/settings", {"realtime": False})[0] == 200
    [e] = [e for e in usage.read() if e["kind"] == "setting"]
    assert e["id"] == "realtime" and e["value"] is False
