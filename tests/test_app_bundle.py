"""Tests for building Palaver.app (menu bar app bundle)."""

import plistlib
import shutil
import signal
import subprocess
import time
from pathlib import Path

import pytest

from palaver import app_bundle


def test_info_plist_declares_menu_bar_app_and_usage_strings():
    info = app_bundle.info_plist()
    assert info["CFBundleIdentifier"] == app_bundle.BUNDLE_ID
    assert info["LSUIElement"] is True  # menu bar only, no Dock icon
    assert "NSMicrophoneUsageDescription" in info
    assert "NSAudioCaptureUsageDescription" in info


def test_launch_agent_opens_the_app_at_login(tmp_path: Path):
    app = tmp_path / "Palaver.app"
    agent = plistlib.loads(app_bundle.launch_agent_plist(app))
    assert agent["ProgramArguments"] == ["/usr/bin/open", "-g", "-a", str(app)]
    assert agent["RunAtLoad"] is True


def test_c_string_escaping():
    assert app_bundle._c_string('a "b" \\ c') == '"a \\"b\\" \\\\ c"'
    assert app_bundle._c_string("Müller") == '"M\\303\\274ller"'


@pytest.mark.skipif(shutil.which("clang") is None, reason="needs Xcode Command Line Tools")
def test_launcher_spawns_child_forwards_exit_code_and_signals(tmp_path: Path):
    marker = tmp_path / "args.txt"
    fake_python = tmp_path / "fake python"  # path with a space
    fake_python.write_text(
        "#!/bin/sh\n"
        f'echo "$@" > "{marker}"\n'
        'trap "exit 7" TERM\n'
        "sleep 30 & wait\n"
    )
    fake_python.chmod(0o755)
    launcher = tmp_path / "launcher"
    app_bundle.compile_launcher(
        launcher,
        python=fake_python,
        cli_options=["--config", "/x y/c.toml"],
        log_path=tmp_path / "app.log",
    )

    proc = subprocess.Popen([str(launcher)])
    deadline = time.monotonic() + 5
    while not marker.exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    assert marker.read_text().strip() == "-m palaver --config /x y/c.toml menubar"
    proc.send_signal(signal.SIGTERM)
    assert proc.wait(timeout=5) == 7


def test_build_app_layout(tmp_path: Path, monkeypatch):
    calls = []
    monkeypatch.setattr(app_bundle, "compile_launcher", lambda path, **kw: path.write_text("bin"))
    monkeypatch.setattr(app_bundle.subprocess, "run", lambda argv, **kw: calls.append(argv))

    app = app_bundle.build_app(tmp_path, python=Path("/venv/bin/python"), cli_options=[])

    assert app == tmp_path / "Palaver.app"
    info = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
    assert (app / "Contents" / "MacOS" / info["CFBundleExecutable"]).exists()
    assert (app / "Contents" / "Resources" / info["CFBundleIconFile"]).stat().st_size > 0
    assert calls[-1][:4] == ["codesign", "--force", "--sign", "-"]


def test_store_tokens_copies_env_tokens_to_keychain(monkeypatch):
    import keyring

    stored = {}
    monkeypatch.setattr(keyring, "set_password", lambda s, n, v: stored.update({(s, n): v}))
    monkeypatch.setenv("NOTION_TOKEN", "ntn_x")
    monkeypatch.delenv("HF_TOKEN", raising=False)
    assert app_bundle.store_tokens_in_keychain() == ["NOTION_TOKEN"]
    assert stored == {("palaver", "NOTION_TOKEN"): "ntn_x"}


@pytest.mark.skipif(shutil.which("clang") is None, reason="needs Xcode Command Line Tools")
def test_release_launcher_resolves_paths_against_home_at_runtime(tmp_path: Path):
    """CI builds the app on another machine: the venv and log paths must be
    resolved from $HOME when the app runs, not baked in at build time."""
    home = tmp_path / "home"
    venv_python = home / "Library" / "Application Support" / "palaver" / "venv" / "bin" / "python"
    venv_python.parent.mkdir(parents=True)
    marker = tmp_path / "ran.txt"
    venv_python.write_text(f'#!/bin/sh\necho "$@" > "{marker}"\n')
    venv_python.chmod(0o755)
    launcher = tmp_path / "launcher"
    app_bundle.compile_launcher(
        launcher,
        python=app_bundle.RELEASE_PYTHON,
        cli_options=[],
        log_path=app_bundle.RELEASE_LOG,
    )

    import os

    env = dict(os.environ, HOME=str(home))
    assert subprocess.run([str(launcher)], env=env, timeout=10).returncode == 0
    assert marker.read_text().strip() == "-m palaver menubar"
    assert (home / "Library" / "Logs" / "palaver" / "app.log").exists()


def test_autostart_toggle(tmp_path: Path, monkeypatch):
    agent = tmp_path / "LaunchAgents" / "agent.plist"
    monkeypatch.setattr(app_bundle, "LAUNCH_AGENT", agent)
    monkeypatch.setattr(app_bundle, "APPS_DIR", tmp_path / "Applications")
    app_bundle.set_autostart(True)
    args = plistlib.loads(agent.read_bytes())["ProgramArguments"]
    assert args[-1] == str(tmp_path / "Applications" / "Palaver.app")
    app_bundle.set_autostart(False)
    assert not agent.exists()


def test_install_replaces_the_app_under_its_old_name(tmp_path: Path, monkeypatch):
    apps, agent = tmp_path / "Applications", tmp_path / "LaunchAgents" / "agent.plist"
    monkeypatch.setattr(app_bundle, "APPS_DIR", apps)
    monkeypatch.setattr(app_bundle, "LAUNCH_AGENT", agent)
    monkeypatch.setattr("palaver.menubar.PERMISSIONS_MARKER", tmp_path / "permissions-requested")
    monkeypatch.setattr(app_bundle, "compile_launcher", lambda path, **kw: path.write_text("bin"))
    quits = []
    monkeypatch.setattr(app_bundle.subprocess, "run", lambda argv, **kw: quits.append(argv))
    old = apps / "Meeting Transcribe.app"
    (old / "Contents").mkdir(parents=True)
    app_bundle.LAUNCH_AGENT.parent.mkdir()
    agent.write_bytes(app_bundle.launch_agent_plist(old))

    app = app_bundle.install(python=Path("/venv/bin/python"), cli_options=[], login=False)

    assert app == apps / "Palaver.app" and not old.exists()
    assert ["osascript", "-e", 'tell application "Meeting Transcribe" to quit'] in quits
    assert plistlib.loads(agent.read_bytes())["ProgramArguments"][-1] == str(app)
