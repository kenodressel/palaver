"""Tests for the window's side of updating and uninstalling (#60): it asks
the menu bar app, which does both."""

import pytest

from palaver import appctl, install_layout, settings
from palaver.webapp import api


def test_settings_show_what_the_updater_knows_and_whether_it_checks_by_itself():
    status = api.update_status(lambda: {"state": "available", "available": {"version": "0.2.0", "notes": "n"}})
    assert status["state"] == "available" and status["available"]["version"] == "0.2.0"
    assert status["check_updates"] is True
    settings.update({"check_updates": False})
    assert api.update_status(lambda: None) == {"state": "unsupported", "check_updates": False}


def test_check_and_install_go_to_the_menu_bar_app():
    calls = []
    answer = api.update_action("install", call=lambda name, args, **kw: calls.append(name) or {"state": "downloading"})
    assert answer == {"state": "downloading"} and calls == ["update_install"]
    with pytest.raises(api.Refused):
        api.update_action("rm -rf", call=lambda *a, **k: {})


def test_without_the_menu_bar_app_the_window_says_so():
    def gone(*args, **kwargs):
        raise appctl.CallFailed("no socket")

    with pytest.raises(api.Refused, match="does not answer"):
        api.update_action("check", call=gone)


def test_uninstalling_needs_a_confirmation_and_keeps_recordings_unless_ticked():
    calls = []

    def call(name, args, **kw):
        calls.append((name, args))
        return {"removing": []}

    with pytest.raises(api.Refused, match="confirmation"):
        api.uninstall_palaver({"models": True}, call=call)
    api.uninstall_palaver({"confirm": True}, call=call)
    api.uninstall_palaver({"confirm": True, "models": True, "recordings": "yes"}, call=call)
    assert calls == [("uninstall", {"models": False, "recordings": False}),
                     ("uninstall", {"models": True, "recordings": False})]  # only a real tick counts


def test_claude_is_given_the_apps_own_python_which_survives_a_runtime_update(tmp_path, monkeypatch):
    app = tmp_path / "Palaver.app"
    wrapper = app / "Contents" / "Resources" / "bin" / "python"
    wrapper.parent.mkdir(parents=True)
    wrapper.write_text("#!/bin/sh\n")
    monkeypatch.setenv("PALAVER_APP", str(app))
    assert install_layout.stable_python() == str(wrapper)
    monkeypatch.delenv("PALAVER_APP")
    import sys

    assert install_layout.stable_python() == sys.executable  # a checkout: its venv's python
