"""Report a Problem (#59): one zip on the Desktop with everything the
maintainer needs, never a secret; and the maintainer's `report open` and
`report usage`. Everything here is synthetic: a fake home (conftest's
report_home), made-up meetings, logs and crash reports."""

import json
import os
import zipfile
from datetime import datetime, timedelta
from pathlib import Path

import pytest

from palaver import report, usage
from palaver.report import Form

NOW = datetime(2026, 10, 30, 14, 5, 30).astimezone()
OLD = "2026-10-29T10-00-00"
NEW = "2026-10-30T09-00-00"
NOTION = "secret_TOKEN_abcdef123456"
HF = "hf_SECRET_987654321"


def _ts(minutes_ago: float) -> str:
    return (NOW - timedelta(minutes=minutes_ago)).isoformat()


def _jsonl(*rows) -> str:
    return "".join(json.dumps(r) + "\n" for r in rows)


@pytest.fixture
def world(tmp_path, report_home, isolated_config_home):
    rec = tmp_path / "Recordings"
    old, new = rec / OLD, rec / NEW
    for f in (old, new):
        f.mkdir(parents=True)
    (old / "session.log").write_text(_jsonl(
        {"ts": _ts(1700), "level": "INFO", "logger": "palaver", "event": "record_start", "trigger": "teams"},
        {"ts": _ts(1640), "level": "WARNING", "logger": "palaver.capture_recorder", "message": "mic stalled"},
        {"ts": _ts(1600), "level": "INFO", "logger": "palaver", "event": "transcribe_done", "seconds": 41.5,
         "track": "system"},
        {"ts": _ts(1590), "level": "INFO", "logger": "palaver", "event": "notes_failed", "error": "model gone"},
    ))
    (old / "meta.json").write_text(json.dumps({"start_time": "2026-10-29T10:00:00+01:00"}))
    (old / "audio_problems.json").write_text("[]")
    (old / "transcript.json").write_text('[{"text": "the whole transcript"}]')
    (old / "notes.json").write_text('{"title": "Weekly"}')
    (old / "mic.wav").write_bytes(b"RIFF" + b"\0" * 2000)
    (old / "system.wav").write_bytes(b"RIFF" + b"\0" * 3000)
    (old / "my-notes").mkdir()
    (old / "my-notes" / "pasted.png").write_bytes(b"\x89PNG")
    (new / "session.log").write_text(_jsonl(
        {"ts": _ts(60), "level": "INFO", "logger": "palaver", "event": "record_start", "trigger": "manual"}))
    (new / "meta.json").write_text("{}")
    (new / "stream.json").write_text("{}")
    (new / "calendar.json").write_text('{"title": "Standup"}')
    (new / "transcript.json").write_text('[{"text": "the other transcript"}]')
    (new / "system.wav.part").write_bytes(b"\0" * 100)
    (rec / ".jobs").mkdir()
    (rec / ".jobs" / "notes-x.json").write_text('{"pid": 1}')
    (rec / ".trash").mkdir()

    logs = report_home.logs
    logs.mkdir(parents=True)
    (logs / "daemon.log").write_text(
        _jsonl({"ts": _ts(30), "level": "ERROR", "logger": "palaver.daemon", "message": "processing failed",
                "traceback": "Traceback…\nRuntimeError: diarization exploded"})
        + "Writing notes with Gemma…\nwarning: notes failed: the model ran out of memory\n"
        + _jsonl({"ts": _ts(20), "level": "INFO", "logger": "palaver", "event": "app_start", "version": "0.1.0"},
                 {"ts": _ts(60 * 24 * 9), "level": "ERROR", "logger": "palaver", "message": "too old for the timeline"}))
    (logs / "app.log").write_text("just output\n")
    (logs / "crashes.log").write_text(
        f"=== {_ts(10)} webapp pid 7 palaver 0.1.0 argv []\nTraceback (most recent call last):\n"
        "  File x\nKeyError: 'speakers'\n\n")

    crashes = report_home.crashes
    crashes.mkdir(parents=True)
    (crashes / "python3.13-2026-10-29-101010.ips").write_text('{"procPath": "/x/python3.13", "argv": "-m palaver menubar"}')
    (crashes / "Safari-2026-10-29-101010.ips").write_text('{"procPath": "/Applications/Safari.app"}')
    old_crash = crashes / "Palaver-2026-08-01-101010.ips"
    old_crash.write_text("palaver")
    month_ago = (NOW - timedelta(days=60)).timestamp()
    os.utime(old_crash, (month_ago, month_ago))

    config = isolated_config_home / "palaver" / "config.toml"
    config.parent.mkdir(parents=True)
    config.write_text(f'[user]\nname = "Tess"\n[notion]\ntoken = "{NOTION}"\nparent_page_id = "page123"\n'
                      f'[hf]\ntoken = "{HF}"\n[recording]\noutput_dir = "{rec}"\n')
    usage.record("action", "meeting.trash")
    return rec, config


def _create(world, form=Form(), **kwargs):
    rec, config = world
    return report.create(form, output_dir=rec, config_path=config, now=NOW, **kwargs)


def _zip(result) -> zipfile.ZipFile:
    return zipfile.ZipFile(result["path"])


def test_the_zip_lands_on_the_desktop_named_by_the_minute_and_shown_in_finder(world, report_home):
    result = _create(world)
    path = Path(result["path"])
    assert path == report_home.desktop / "Palaver report 2026-10-30 14-05.zip"
    assert result["size"] == path.stat().st_size
    assert [p.name for p in report_home.desktop.iterdir()] == [path.name]  # no temporary file left
    second = Path(_create(world)["path"])
    assert second.name == "Palaver report 2026-10-30 14-05 (2).zip"


def test_the_manifest_lists_every_file_in_the_zip(world):
    with _zip(_create(world)) as z:
        names = set(z.namelist())
        manifest = z.read("MANIFEST.txt").decode()
    for name in names:
        assert name in manifest
    for expected in ("report.json", "settings.json", "doctor.txt", "timeline.txt", "usage-summary.json",
                     "usage/usage.jsonl", "system/audio-devices.json", "system/permissions.json",
                     "system/memory.json", "logs/daemon.log", "logs/app.log", "logs/crashes.log",
                     "jobs/notes-x.json", "meetings/LISTING.txt"):
        assert expected in names


def test_a_config_with_a_token_never_ends_up_in_the_zip(world, report_home):
    """Settings go in with the secrets as "(set)"; a token that leaked into a log is scrubbed too."""
    rec, _ = world
    (report_home.logs / "daemon.log").write_text(f"oops, printed {NOTION} and {HF}\n", encoding="utf-8")
    (rec / NEW / "session.log").write_text(f'{{"ts": "{_ts(5)}", "message": "{HF}"}}\n')
    with _zip(_create(world, Form(meeting=NEW))) as z:
        for name in z.namelist():
            data = z.read(name)
            assert NOTION.encode() not in data and HF.encode() not in data, name
        settings = json.loads(z.read("settings.json"))
    assert settings["config"]["notion_token"] == "(set)"
    assert settings["config"]["hf_token"] == "(set)"
    assert settings["config_toml"]["notion"]["token"] == "(set)"
    assert settings["config_toml"]["notion"]["parent_page_id"] == "page123"  # not a secret: kept
    assert settings["config"]["user_name"] == "Tess"


def test_redact_names_set_and_unset_secrets_by_their_key():
    found = []
    out = report.redact({"api_key": "", "Password": None, "nested": {"client_secret": "abcdefg"}, "keep": 1}, found)
    assert out == {"api_key": "(not set)", "Password": "(not set)", "nested": {"client_secret": "(set)"}, "keep": 1}
    assert found == ["", "abcdefg"]


def test_every_meeting_gives_its_small_files_and_the_chosen_one_all_but_audio(world):
    with _zip(_create(world, Form(meeting=OLD))) as z:
        names = set(z.namelist())
    assert {f"meetings/{NEW}/{n}" for n in ("session.log", "meta.json", "stream.json", "calendar.json")} <= names
    assert f"meetings/{NEW}/transcript.json" not in names  # not chosen
    assert {f"meetings/{OLD}/{n}" for n in ("transcript.json", "notes.json", "audio_problems.json",
                                            "my-notes/pasted.png")} <= names
    assert not [n for n in names if n.endswith((".wav", ".part"))]


def test_the_chosen_meetings_audio_goes_in_only_when_ticked(world):
    with _zip(_create(world, Form(meeting=OLD, audio=True))) as z:
        names = set(z.namelist())
        info = z.getinfo(f"meetings/{OLD}/system.wav")
    assert {f"meetings/{OLD}/mic.wav", f"meetings/{OLD}/system.wav"} <= names
    assert info.compress_type == zipfile.ZIP_STORED
    assert f"meetings/{NEW}/system.wav.part" not in names  # another meeting's audio never


def test_what_left_the_mac_and_what_mcp_clients_read_go_in(world):
    from palaver import access_log, mcp_access

    access_log.record(provider="anthropic", host="h", model="m", feature="notes", meetings=[OLD], chars=10,
                      ok=True, seconds=1)
    mcp_access.append({"tool": "get_meeting", "meetings": [OLD]})
    with _zip(_create(world)) as z:
        assert {"data/access-log.jsonl", "data/mcp-access.jsonl"} <= set(z.namelist())


def test_crash_reports_of_palaver_processes_from_the_last_30_days(world):
    with _zip(_create(world)) as z:
        crashes = sorted(n for n in z.namelist() if n.startswith("crash-reports/"))
    assert crashes == ["crash-reports/python3.13-2026-10-29-101010.ips"]


def test_the_timeline_merges_the_last_weeks_problems_and_events_by_time(world):
    with _zip(_create(world)) as z:
        lines = z.read("timeline.txt").decode().splitlines()
    text = "\n".join(lines)
    assert "too old for the timeline" not in text
    order = [next(i for i, line in enumerate(lines) if needle in line) for needle in
             ("record_start trigger=teams", "mic stalled", "notes_failed", "record_start trigger=manual",
              "diarization exploded", "warning: notes failed", "app_start", "KeyError: 'speakers'")]
    assert order == sorted(order)
    assert any("CRASH" in line and "webapp" in line for line in lines)
    assert f"meetings/{OLD}" in text and "daemon.log" in text


def test_a_message_repeating_every_few_seconds_is_one_line_with_its_count():
    lines = [f"2026-10-30 08:58:{s:02d}  ERROR    daemon.log  GET /api/meetings/x failed" for s in (0, 10, 20)]
    lines.append("2026-10-30 08:59:00  WARNING  daemon.log  mic stalled")
    assert report.collapse_repeats(lines) == [
        "2026-10-30 08:58:00  ERROR    daemon.log  GET /api/meetings/x failed  (×3, until 08:58:20)",
        "2026-10-30 08:59:00  WARNING  daemon.log  mic stalled"]


def test_report_json_has_the_form_the_versions_and_this_mac(world, monkeypatch):
    from palaver import __version__

    class Git(report.QuietProbe):
        def git(self):
            return {"commit": "abc1234def", "dirty": True, "branch": "master"}

    with _zip(_create(world, Form(kind="wish", text="A dark menu bar icon", meeting=NEW), probe=Git())) as z:
        r = json.loads(z.read("report.json"))
        summary = json.loads(z.read("usage-summary.json"))
    assert r["form"] == {"kind": "wish", "text": "A dark menu bar icon", "meeting": NEW, "audio": False}
    assert r["palaver"] == {"version": __version__, "commit": "abc1234def", "dirty": True, "branch": "master"}
    assert r["hardware"]["chip"] == "Test chip" and r["python"]
    assert r["disk"]["free_gb"] > 0
    assert r["daemon"] == "daemon has never run"
    assert r["recordings"]["meetings"] == 2
    assert any("diarization exploded" in line for line in r["last_errors"])
    assert summary["features"]["action:meeting.trash"]["all"] == 1


def test_a_question_this_mac_cannot_answer_is_written_down_not_raised(world):
    class Broken(report.QuietProbe):
        def doctor(self, config_path):
            raise RuntimeError("no CoreAudio")

        def hardware(self):
            raise OSError("sysctl gone")

    with _zip(_create(world, probe=Broken())) as z:
        assert "RuntimeError: no CoreAudio" in z.read("doctor.txt").decode()
        assert json.loads(z.read("report.json"))["hardware"] == {"error": "OSError: sysctl gone"}


def test_a_meeting_that_does_not_exist_is_refused(world, report_home):
    with pytest.raises(ValueError):
        _create(world, Form(meeting="../../etc"))
    assert not report_home.desktop.exists() or not list(report_home.desktop.iterdir())


def test_creating_a_report_is_counted(world):
    _create(world, Form(kind="bug", meeting=OLD))
    last = usage.read()[-1]
    assert last["kind"] == "report" and last["meeting"] is True and last["via"] == "window"


def test_the_form_accepts_a_bug_or_a_wish_and_nothing_else():
    assert Form.from_dict({"kind": "wish", "text": "x", "meeting": "", "audio": True}) == Form("wish", "x", None, True)
    for bad in ({"kind": "rant"}, {"text": 3}, {"audio": "yes"}):
        with pytest.raises(ValueError):
            Form.from_dict(bad)


def test_open_unpacks_and_summarizes_versions_form_errors_devices_and_the_pipeline(world, tmp_path):
    result = _create(world, Form(text="The transcript stopped\nhalf way", meeting=OLD))
    dest, text = report.open_report(Path(result["path"]), tmp_path / "out")
    assert (dest / "report.json").is_file() and (dest / "MANIFEST.txt").is_file()
    assert "a bug from Tess" in text
    assert "  The transcript stopped\n  half way" in text
    assert "input Test Mic (48 kHz)" in text
    assert "diarization exploded" in text
    assert f"Pipeline of {OLD}:" in text
    assert "transcribe" in text and "41.5 s" in text and "notes_failed" in text


def test_usage_across_reports_counts_testers_and_uses_from_each_ones_latest_report(world, tmp_path, report_home):
    usage.save_catalog({"action": ["meeting.trash", "meeting.split"]})
    first = Path(_create(world)["path"])
    usage.record("action", "meeting.trash")
    second = Path(report.create(Form(), output_dir=world[0], config_path=world[1], now=NOW + timedelta(hours=1))["path"])
    other = tmp_path / "other.zip"
    with zipfile.ZipFile(second) as src, zipfile.ZipFile(other, "w") as dst:
        for name in src.namelist():
            data = src.read(name)
            if name == "report.json":
                data = json.dumps({**json.loads(data), "user": "Uma"}).encode()
            dst.writestr(name, data)
    table = report.usage_table([first, second, other])
    assert table.splitlines()[0] == "2 tester(s), 3 report(s)"
    row = next(line for line in table.splitlines() if line.startswith("action:meeting.trash"))
    assert row.split()[1:] == ["2", "4"]  # each tester's latest report: 2 uses each
    unused = next(line for line in table.splitlines() if line.startswith("action:meeting.split"))
    assert unused.split()[1:] == ["0", "0"]
