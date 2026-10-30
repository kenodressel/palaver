"""Tests for `palaver doctor`."""

import json
from datetime import datetime
from pathlib import Path

from palaver import doctor
from palaver.doctor import Check, format_report


def test_format_report_marks_and_hints():
    report = format_report([
        Check("macOS", "ok", "26.1"),
        Check("Microphone permission", "fail", "denied",
              "System Settings → Privacy & Security → Microphone"),
        Check("Parakeet model", "warn", "not downloaded yet", "downloads on first process"),
    ])
    lines = report.splitlines()
    assert lines[0] == "✓ macOS: 26.1"
    assert lines[1] == "✗ Microphone permission: denied"
    assert lines[2].strip() == "→ System Settings → Privacy & Security → Microphone"
    assert lines[3] == "! Parakeet model: not downloaded yet"


def test_disk_space_check():
    gb = 1024**3
    assert doctor.check_disk(Path("/"), free_bytes=50 * gb).status == "ok"
    assert doctor.check_disk(Path("/"), free_bytes=5 * gb).status == "warn"
    assert doctor.check_disk(Path("/"), free_bytes=1 * gb).status == "fail"


def test_mic_permission_states():
    assert doctor.check_microphone(status=3).status == "ok"
    assert doctor.check_microphone(status=0).status == "warn"  # asked on first record
    denied = doctor.check_microphone(status=2)
    assert denied.status == "fail" and "Microphone" in denied.fix


def test_system_audio_permission_from_last_recording(tmp_path: Path):
    rec = tmp_path / "2026-10-20T14-35-17"
    rec.mkdir()
    (rec / "session.log").write_text(json.dumps({"event": "record_start", "system_source": "process-tap"}) + "\n")
    assert doctor.check_system_audio(tmp_path).status == "ok"

    (rec / "session.log").write_text(json.dumps({"event": "record_start", "system_source": "scstream"}) + "\n")
    fallback = doctor.check_system_audio(tmp_path)
    assert fallback.status == "warn" and "System Audio" in fallback.fix

    assert doctor.check_system_audio(tmp_path / "empty").status == "warn"


def test_system_audio_names_the_meeting_not_its_folder(tmp_path: Path):
    """The check says which meeting, as a person reads it (setup assistant and CLI)."""
    rec = tmp_path / "2026-10-29T16-07-55"
    rec.mkdir()
    (rec / "session.log").write_text(json.dumps({"event": "record_start", "system_source": "process-tap"}) + "\n")
    assert doctor.check_system_audio(tmp_path).detail == "Process Tap worked in the meeting on 29\u00a0Oct, 16:07"

    (rec / "notes.json").write_text(json.dumps({"title": "Budget review"}))
    assert doctor.check_system_audio(tmp_path).detail == "Process Tap worked in “Budget review” on 29\u00a0Oct, 16:07"
    (rec / "calendar.json").write_text(json.dumps({"title": "Weekly sync", "start": "x", "end": "y"}))
    assert doctor.check_system_audio(tmp_path).detail == "Process Tap worked in “Weekly sync” on 29\u00a0Oct, 16:07"
    (rec / "title.json").write_text(json.dumps({"title": "Budget with Anna"}))  # renamed by the user
    assert doctor.check_system_audio(tmp_path).detail == "Process Tap worked in “Budget with Anna” on 29\u00a0Oct, 16:07"
    (rec / "title.json").unlink()

    (rec / "session.log").write_text(json.dumps({"event": "record_start", "system_source": "scstream"}) + "\n")
    assert doctor.check_system_audio(tmp_path).detail == "fell back to ScreenCaptureKit in “Weekly sync” on 29\u00a0Oct, 16:07"

    # The start the Meetings window shows (meta.json), which can be earlier than the folder's name.
    start = datetime(2026, 10, 29, 16, 6, 25).astimezone()
    (rec / "meta.json").write_text(json.dumps({"start_time": start.isoformat()}))
    assert doctor.check_system_audio(tmp_path).detail.endswith("on 29\u00a0Oct, 16:06")


def test_notion_check_reports_invalid_token(monkeypatch):
    class _Resp:
        def __init__(self, status):
            self.status_code = status

    monkeypatch.setattr(doctor.requests, "get", lambda url, **kw: _Resp(401))
    c = doctor.check_notion("ntn_bad", "page", "abc", None)
    assert c.status == "fail" and "token" in c.detail

    responses = iter([_Resp(200), _Resp(404)])
    monkeypatch.setattr(doctor.requests, "get", lambda url, **kw: next(responses))
    c = doctor.check_notion("ntn_ok", "page", "abc", None)
    assert c.status == "fail" and "share" in c.fix.lower()


def test_doctor_exit_code(monkeypatch, capsys):
    from palaver import cli

    monkeypatch.setattr(doctor, "run_checks", lambda **kw: [Check("x", "ok", "fine")])
    assert cli.main(["doctor", "--offline"]) == 0
    monkeypatch.setattr(doctor, "run_checks", lambda **kw: [Check("x", "fail", "broken")])
    assert cli.main(["doctor", "--offline"]) == 1
    assert "✗ x: broken" in capsys.readouterr().out


# --- device health (issue #50) --------------------------------------------------


def test_audio_devices_check_names_devices_and_rates():
    c = doctor.check_audio_devices({"input": ("AirPods Pro", 24000.0), "output": ("AirPods Pro", 24000.0)})
    assert c.status == "ok"
    assert c.detail == "input AirPods Pro (24 kHz), output AirPods Pro (24 kHz)"
    c = doctor.check_audio_devices({"input": ("MacBook Pro Microphone", 48000.0), "output": (None, None)})
    assert c.status == "warn" and "no output device" in c.detail


def test_audio_devices_check_survives_coreaudio_failing():
    def boom():
        raise RuntimeError("CoreAudio unavailable")

    c = doctor.check_audio_devices(lookup=boom)
    assert c.status == "warn" and "CoreAudio unavailable" in c.detail


def test_last_recordings_audio_problems(tmp_path: Path):
    rec = tmp_path / "2026-10-29T12-06-10"
    rec.mkdir()
    (rec / "meta.json").write_text(json.dumps({"start_time": "2026-10-29T12:06:10+01:00"}))
    assert doctor.check_recent_audio(tmp_path).status == "ok"
    (rec / "meta.json").write_text(json.dumps({"start_time": "2026-10-29T12:06:10+01:00", "audio_problems": [
        {"kind": "speed", "track": "system", "start": 480.0, "end": 600.0}]}))
    c = doctor.check_recent_audio(tmp_path)
    assert c.status == "warn"
    assert c.detail == "2026-10-29T12-06-10: Audio problem at 12:14 (system audio played at the wrong speed)"
    assert "session.log" in c.fix
    assert doctor.check_recent_audio(tmp_path / "none").status == "ok"


# --- memory budgets (#49) ---------------------------------------------------------

def test_memory_check_lists_the_budgets_and_what_palaver_uses():
    from palaver.memory import GB, Budgets

    c = doctor.check_memory(Budgets(), ram_gb=48, running={"total": int(5.4 * GB), "workers": []})
    assert c.status == "ok" and c.name == "Memory budgets"
    assert c.detail == "live 6 GB, realtime 3.5 GB, transcription 8 GB, notes 14 GB, search index 1 GB; Palaver uses 5.4 GB now"
    assert doctor.check_memory(Budgets(), ram_gb=48, running=None).detail.endswith("search index 1 GB")


def test_memory_check_warns_when_a_call_would_take_half_the_mac():
    from palaver.memory import Budgets

    c = doctor.check_memory(Budgets(), ram_gb=16, running=None)
    assert c.status == "warn" and "9.5 GB during a call" in c.detail and "16 GB" in c.detail
    assert "[memory]" in c.fix


def test_memory_check_warns_when_notes_cannot_fit():
    from palaver.memory import Budgets

    c = doctor.check_memory(Budgets(live=2, stream=1, notes=20), ram_gb=24, running=None)
    assert c.status == "warn" and "notes" in c.detail.lower() and "Claude" in c.fix


def test_memory_check_warns_about_a_worker_over_budget_now():
    from palaver.memory import GB, Budgets

    running = {"total": 7 * GB, "workers": [
        {"kind": "live", "label": "Live transcription", "used": int(5.5 * GB), "budget": 5.0, "state": "over budget"}]}
    c = doctor.check_memory(Budgets(), ram_gb=48, running=running)
    assert c.status == "warn" and "Live transcription uses 5.5 GB, over its 5 GB budget" in c.detail


def test_system_audio_check_skips_a_broken_log_line(tmp_path):
    """A line cut short (a crash mid-write) must not break the check (#55)."""
    from palaver.doctor import check_system_audio

    folder = tmp_path / "2026-10-27T10-00-00"
    folder.mkdir()
    (folder / "session.log").write_text('{"event": "record_st\n'
                                         '{"event": "record_start", "system_source": "process-tap"}\n')
    assert check_system_audio(tmp_path).status == "ok"
