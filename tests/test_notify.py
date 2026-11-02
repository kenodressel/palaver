"""Tests for macOS notifications on pipeline events (issue #10)."""

import json
import os
import socket
import tempfile
import threading
from pathlib import Path

import pytest

from palaver import cli, notify

from .test_cli import _fake_models, _ns, _recording_folder


def test_send_passes_text_as_arguments_not_script(monkeypatch):
    """Quotes in an error message must not be able to break the AppleScript."""
    calls = []
    monkeypatch.delenv("PALAVER_NOTIFY", raising=False)
    monkeypatch.setattr(notify, "_send", notify._send_default)
    monkeypatch.setattr(notify.subprocess, "run", lambda argv, **kw: calls.append(argv))
    notify.notify('Title "x"', 'it said "boom" & quit')
    argv = calls[0]
    assert argv[0] == "osascript"
    assert argv[-2:] == ['Title "x"', 'it said "boom" & quit']
    assert not any("boom" in a for a in argv[:-2])


def test_inside_the_app_the_launcher_posts_them(monkeypatch):
    """So a click opens Palaver, not Script Editor."""
    calls = []
    monkeypatch.setattr(notify.subprocess, "run", lambda argv, **kw: calls.append(argv))
    monkeypatch.setattr(notify, "_send", notify._send_default)
    with tempfile.TemporaryDirectory() as tmp, socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as app:
        path = os.path.join(tmp, "n.sock")  # short: socket paths are limited to 104 bytes
        app.bind(path)
        monkeypatch.setenv("PALAVER_NOTIFY", path)
        notify.notify("Transcript ready", "2026-10-20T14-35-17", "2026-10-20T14-35-17")
        assert json.loads(app.recv(8192)) == {
            "title": "Transcript ready", "message": "2026-10-20T14-35-17", "open": "2026-10-20T14-35-17"}
    assert calls == []


def test_without_the_app_osascript_takes_over(monkeypatch):
    calls = []
    monkeypatch.setattr(notify.subprocess, "run", lambda argv, **kw: calls.append(argv))
    monkeypatch.setattr(notify, "_send", notify._send_default)
    monkeypatch.setenv("PALAVER_NOTIFY", "/nonexistent/palaver.sock")
    notify.notify("t", "m")
    assert calls[0][0] == "osascript"


def test_clicks_from_the_launcher_reach_the_app(monkeypatch):
    launcher, app = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
    monkeypatch.setenv("PALAVER_LAUNCHER_FD", str(app.detach()))
    opened, done = [], threading.Event()

    def on_open(meeting):
        opened.append(meeting)
        if len(opened) == 2:
            done.set()

    assert notify.on_click(on_open)
    assert "PALAVER_LAUNCHER_FD" not in os.environ  # not for processes it starts
    launcher.send(b"open 2026-10-20T14-35-17")
    launcher.send(b"open ")
    assert done.wait(5)
    assert opened == ["2026-10-20T14-35-17", None]
    launcher.close()


def test_no_clicks_outside_the_app(monkeypatch):
    monkeypatch.delenv("PALAVER_LAUNCHER_FD", raising=False)
    assert not notify.on_click(lambda meeting: None)


def test_notify_never_raises(monkeypatch):
    def _boom(*_):
        raise OSError("no osascript")

    monkeypatch.setattr(notify, "_send", _boom)
    notify.notify("t", "m")  # must not raise


def test_disabled_notifications_are_dropped(sent_notifications):
    notify.set_enabled(False)
    notify.notify("t", "m")
    assert sent_notifications == []


def test_process_notifies_transcript_ready(tmp_path: Path, monkeypatch, sent_notifications):
    _recording_folder(tmp_path / "2026-10-20T14-35-17")
    _fake_models(monkeypatch)
    args = _ns(tmp_path / "2026-10-20T14-35-17")
    args.cmd = "process"
    assert cli._cmd_process(args) == 0
    assert sent_notifications == [("Transcript ready", "2026-10-20T14-35-17")]


def test_run_notifies_only_the_upload(tmp_path: Path, monkeypatch, sent_notifications):
    folder = tmp_path / "2026-10-20T14-35-17"
    _recording_folder(folder)
    _fake_models(monkeypatch)
    monkeypatch.setattr(
        "palaver.notion_client.NotionClient.create_page",
        lambda self, **kw: "https://notion.so/p",
    )
    args = _ns(folder)
    args.cmd = "run"
    assert cli._cmd_run(args) == 0
    assert sent_notifications == [("Uploaded to Notion", "https://notion.so/p")]


def test_main_notifies_failures(monkeypatch, sent_notifications):
    def _explode(args):
        raise RuntimeError("diarization exploded")

    monkeypatch.setattr(cli, "_cmd_process", _explode)
    with pytest.raises(RuntimeError):
        cli.main(["process", "/x"])
    assert sent_notifications == [("palaver process failed", "diarization exploded")]


def test_main_notifies_nonzero_exit(monkeypatch, sent_notifications):
    monkeypatch.setattr(cli, "_cmd_sync", lambda args: 2)
    assert cli.main(["sync", "/x"]) == 2
    assert sent_notifications[0][0] == "palaver sync failed"


def test_no_notify_flag(monkeypatch, sent_notifications):
    monkeypatch.setattr(cli, "_cmd_sync", lambda args: 2)
    cli.main(["--no-notify", "sync", "/x"])
    assert sent_notifications == []


def test_permission_is_what_the_launcher_last_wrote(tmp_path, monkeypatch):
    state = tmp_path / "palaver-1.notifications"
    monkeypatch.delenv("PALAVER_NOTIFY_STATE", raising=False)
    assert notify.permission() is None  # outside the app
    monkeypatch.setenv("PALAVER_NOTIFY_STATE", str(state))
    assert notify.permission() is None  # not written yet
    for value in ("allowed", "denied", "not_asked"):
        state.write_text(value)
        assert notify.permission() == value
    state.write_text("garbage")
    assert notify.permission() is None


def test_the_setup_assistant_and_settings_see_it(tmp_path, monkeypatch):
    from palaver import onboarding
    from palaver.webapp import api

    state = tmp_path / "palaver-1.notifications"
    monkeypatch.setenv("PALAVER_NOTIFY_STATE", str(state))
    state.write_text("denied")
    assert onboarding.notifications_permission()["state"] == "denied"
    state.write_text("allowed")
    assert api.notifications_status() == {"state": "granted", "detail": "allowed"}
    monkeypatch.delenv("PALAVER_NOTIFY_STATE")
    assert api.notifications_status()["state"] == "unknown"
    opened = []
    monkeypatch.setattr("subprocess.run", lambda cmd, check=False: opened.append(cmd))
    api.open_notification_settings()
    assert opened == [["open", notify.SETTINGS_URL]]
