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


_FAKE_LIBPYTHON = r"""
#include <stdio.h>
#include <stdlib.h>
#include <CoreFoundation/CoreFoundation.h>
int Py_BytesMain(int argc, char **argv) {
    char id[256] = "";
    CFStringRef s = CFBundleGetIdentifier(CFBundleGetMainBundle());
    if (s) CFStringGetCString(s, id, sizeof id, kCFStringEncodingUTF8);
    FILE *f = fopen(getenv("MARKER"), "w");
    for (int i = 1; i < argc; i++) fprintf(f, "%s%s", i > 1 ? " " : "", argv[i]);
    fprintf(f, "|%s|%s|%s|%s\n", getenv("PYTHONPATH"), getenv("PALAVER_APP"), getenv("PYTHONHOME"), id);
    fclose(f);
    return 0;
}
"""


def _fake_runtime(home: Path, runtime_id: str) -> Path:
    """A runtime whose libpython writes down how it was started (to
    $MARKER): its arguments, the environment the host set, and the main
    bundle of the process."""
    runtime = home / "Library" / "Application Support" / "palaver" / "runtime" / runtime_id
    (runtime / "lib").mkdir(parents=True)
    (runtime / "bin").mkdir()
    src = home / "fake.c"
    src.write_text(_FAKE_LIBPYTHON)
    subprocess.run(["clang", "-dynamiclib", "-framework", "CoreFoundation", "-o",
                    str(runtime / "lib" / "libpython3.13.dylib"), str(src)], check=True)
    (runtime / "bin" / "python3").write_text("#!/bin/sh\n")
    (runtime / "bin" / "python3").chmod(0o755)
    return runtime


def _ran(marker: Path) -> tuple[str, str, str, str, str]:
    return tuple(marker.read_text().strip().split("|"))


@pytest.mark.skipif(shutil.which("clang") is None, reason="needs Xcode Command Line Tools")
def test_release_launcher_starts_the_bundles_host_on_the_runtime_found_under_home(tmp_path: Path):
    """The app is built on another Mac: the runtime and log paths are
    resolved from $HOME when the app runs, not baked in at build time."""
    import os

    home, marker = tmp_path / "home", tmp_path / "ran.txt"
    runtime = _fake_runtime(home, "3.13.2-arm64-abc")
    macos = tmp_path / "Fake.app" / "Contents" / "MacOS"  # no Info.plist: no notifications asked for
    macos.mkdir(parents=True)
    app_bundle.compile_launcher(macos / "launcher", python=app_bundle.release_python("3.13.2-arm64-abc"),
                                cli_options=[], log_path=app_bundle.RELEASE_LOG, release=True)
    app_bundle.compile_host(macos / app_bundle.HOST, runtime_id="3.13.2-arm64-abc", python_version="3.13")
    env = dict(os.environ, HOME=str(home), MARKER=str(marker))
    assert subprocess.run([str(macos / "launcher")], env=env, timeout=10).returncode == 0
    args, pythonpath, app, pythonhome, _ = _ran(marker)
    assert args == "-m palaver menubar"
    assert pythonpath == str((tmp_path / "Fake.app" / "Contents" / "Resources" / "python").resolve())
    assert app == str((tmp_path / "Fake.app").resolve()) and pythonhome == str(runtime)
    assert (home / "Library" / "Logs" / "palaver" / "app.log").exists()


@pytest.mark.skipif(shutil.which("clang") is None, reason="needs Xcode Command Line Tools")
def test_a_release_app_runs_its_code_as_palaver_app_and_its_command_does_too(tmp_path: Path):
    """The host in Contents/MacOS makes Palaver.app the process's main
    bundle: the Dock and Activity Monitor say "Palaver", not "Python"."""
    import json
    import os

    code = tmp_path / "wheel"
    (code / "palaver").mkdir(parents=True)
    (code / "palaver" / "__init__.py").write_text("__version__ = '9.9.9'\n")
    app = app_bundle.build_release_app(tmp_path / "dist", runtime_id="3.13.2-arm64-abc", code=code, version="9.9.9")
    resources = app / "Contents" / "Resources"
    assert (resources / "python" / "palaver" / "__init__.py").exists()
    assert json.loads((resources / "runtime.json").read_text()) == {"version": "9.9.9", "runtime": "3.13.2-arm64-abc"}
    assert plistlib.loads((app / "Contents" / "Info.plist").read_bytes())["PalaverRuntimeID"] == "3.13.2-arm64-abc"
    assert subprocess.run(["codesign", "--verify", "--strict", str(app)], capture_output=True).returncode == 0

    home, marker = tmp_path / "home", tmp_path / "ran.txt"
    _fake_runtime(home, "3.13.2-arm64-abc")
    link = tmp_path / "bin" / "palaver"  # ~/.local/bin/palaver links to the command
    link.parent.mkdir()
    link.symlink_to(resources / "bin" / "palaver")
    env = dict(os.environ, HOME=str(home), MARKER=str(marker))
    assert subprocess.run([str(link), "doctor"], env=env, timeout=10).returncode == 0
    args, pythonpath, palaver_app, _, bundle_id = _ran(marker)
    assert args == "-m palaver doctor"
    assert pythonpath == str((resources / "python").resolve())
    assert palaver_app == str(app.resolve())
    assert bundle_id == app_bundle.BUNDLE_ID


def test_without_its_runtime_the_command_says_how_to_get_it_back(tmp_path: Path):
    import os

    code = tmp_path / "wheel"
    (code / "palaver").mkdir(parents=True)
    app = app_bundle.build_release_app(tmp_path / "dist", runtime_id="3.13.2-arm64-gone", code=code, version="1.0")
    proc = subprocess.run([str(app / "Contents" / "Resources" / "bin" / "palaver")],
                          env=dict(os.environ, HOME=str(tmp_path)), capture_output=True, text=True)
    assert proc.returncode == 1 and "install.sh | sh" in proc.stderr


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


def test_the_permissions_marker_is_where_the_menu_bar_app_keeps_it():
    from palaver import install_layout, menubar

    assert menubar.PERMISSIONS_MARKER == install_layout.permissions_marker()
