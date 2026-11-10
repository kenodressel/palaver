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


def test_info_plist_lets_plain_http_reach_only_the_local_network():
    ats = app_bundle.info_plist()["NSAppTransportSecurity"]
    assert ats == {"NSAllowsLocalNetworking": True,
                   "NSExceptionDomains": {d: {"NSIncludesSubdomains": True, "NSExceptionAllowsInsecureHTTPLoads": True}
                                          for d in ("lan", "home.arpa")}}
    assert "NSAllowsArbitraryLoads" not in ats  # public hosts stay https only


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


def _build_release():
    import importlib.util

    root = Path(__file__).resolve().parent.parent
    spec = importlib.util.spec_from_file_location("build_release", root / "tools" / "build_release.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _programs(tmp_path: Path) -> dict[str, Path]:
    """Stand-ins for the built Swift programs: real Mach-O files to sign (never run here)."""
    out = {}
    (tmp_path / "built").mkdir(parents=True, exist_ok=True)
    for name in ("Palaver", "palaver-engine", "palaver-server", "palaver-worker", "palaver-lm", "palaver-cli"):
        out[name] = tmp_path / "built" / name
        out[name].parent.mkdir(exist_ok=True)
        shutil.copy("/usr/bin/true", out[name])
    return out


def _lm_resources(tmp_path: Path) -> list[Path]:
    """What xcodebuild leaves beside palaver-lm: MLX's shaders and swift-transformers' resource bundle."""
    shaders = tmp_path / "built" / "mlx-swift_Cmlx.bundle" / "Contents" / "Resources" / "default.metallib"
    shaders.parent.mkdir(parents=True)
    shaders.write_bytes(b"MTLB" + bytes(12))
    hub = tmp_path / "built" / "swift-transformers_Hub.bundle"
    (hub / "Contents" / "Resources").mkdir(parents=True)
    (hub / "Contents" / "Resources" / "gpt2_tokenizer_config.json").write_text("{}")
    (hub / "Contents" / "Info.plist").write_bytes(b"<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>")
    return [shaders, hub]


def _resources(tmp_path: Path) -> Path:
    """The domain's resources as native/Sources/PalaverDomain/Resources holds them."""
    folder = tmp_path / "domain-resources"
    folder.mkdir()
    (folder / "zipf.bin").write_bytes(b"ZIPF" + bytes(range(16)))
    return folder


ROOT = Path(__file__).resolve().parent.parent
MCP_SHIM = ROOT / "native" / "Bundle" / "bin" / "python"
WEB = ROOT / "palaver" / "webapp" / "static"


def _release_app(tmp_path: Path, version: str = "1.0") -> Path:
    built = _programs(tmp_path)
    licenses = tmp_path / "THIRD_PARTY_LICENSES.md"
    licenses.write_text("# Third-party\n\nswift-nio: Apache-2.0\n")
    return app_bundle.build_release_app(
        tmp_path / "dist", app_binary=built["Palaver"], engine=built["palaver-engine"], server=built["palaver-server"],
        worker=built["palaver-worker"], lm=built["palaver-lm"], cli=built["palaver-cli"], mcp_shim=MCP_SHIM, web=WEB,
        lm_resources=_lm_resources(tmp_path), domain_resources=_resources(tmp_path), licenses=licenses,
        version=version)


@pytest.mark.skipif(shutil.which("codesign") is None, reason="macOS only")
def test_a_release_app_is_the_swift_programs_and_nothing_of_python(tmp_path: Path):
    """0.6: the Swift app as Palaver.app's executable, the programs beside it, the palaver command in
    Contents/Resources/bin (where ~/.local/bin/palaver links), the one-release MCP shim beside it, the window's
    page files in Contents/Resources/web; no palaver-python, no Contents/Resources/python, no .py file."""
    import json

    app = _release_app(tmp_path, version="9.9.9")
    macos, resources = app / "Contents" / "MacOS", app / "Contents" / "Resources"
    info = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
    assert info["CFBundleExecutable"] == "Palaver" and info["CFBundleIdentifier"] == app_bundle.BUNDLE_ID
    assert "PalaverRuntimeID" not in info and info["CFBundleShortVersionString"] == app_bundle.__version__
    assert sorted(p.name for p in macos.iterdir()) == [
        "Palaver", "palaver-engine", "palaver-lm", "palaver-server", "palaver-worker"]
    assert sorted(p.name for p in (resources / "bin").iterdir()) == ["palaver", "python"]
    assert (resources / "bin" / "palaver").read_bytes()[:4] in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe")  # palaver-cli
    assert (resources / "bin" / "palaver").stat().st_mode & 0o111
    assert (resources / "bin" / "python").read_text() == MCP_SHIM.read_text()
    assert (resources / "bin" / "python").stat().st_mode & 0o111
    assert (resources / "web" / "index.html").read_text() == (WEB / "index.html").read_text()
    assert (resources / "web" / "fonts" / "OFL-InstrumentSans.txt").exists()
    assert json.loads((resources / "runtime.json").read_text()) == {"version": "9.9.9", "runtime": "no-python-1"}
    assert (resources / "menubar.png").read_bytes() == app_bundle.MENUBAR_ICON.read_bytes()
    assert (resources / "Palaver.icns").exists()
    names = [p.relative_to(app).as_posix() for p in app.rglob("*")]
    assert not [n for n in names if n.endswith((".py", ".pyc")) or "palaver-python" in n or n.startswith("Contents/Resources/python")]
    assert [n for n in names if "python" in n.lower()] == ["Contents/Resources/bin/python"]  # the shim only
    assert _build_release().bundle_problems(app) == []


@pytest.mark.skipif(shutil.which("codesign") is None, reason="macOS only")
def test_every_program_is_signed_as_0_5_was_without_the_hardened_runtime(tmp_path: Path):
    """0.6.0rc1 signs as 0.5 did (Keno's ruling): one identity on every program, no hardened runtime and so no
    entitlements, until notarization turns HARDENED_RUNTIME on."""
    assert app_bundle.HARDENED_RUNTIME is False
    app = _release_app(tmp_path)
    programs = [*sorted((app / "Contents" / "MacOS").iterdir()), app / "Contents" / "Resources" / "bin" / "palaver"]
    for program in programs:
        proc = subprocess.run(["codesign", "--verify", "--strict", str(program)], capture_output=True, text=True)
        assert proc.returncode == 0, (program.name, proc.stderr)
        shown = subprocess.run(["codesign", "-d", "--verbose=2", "--entitlements", "-", "--xml", str(program)],
                               capture_output=True, text=True)
        assert "runtime)" not in next(line for line in shown.stderr.splitlines() if "flags=" in line), program.name
        assert "com.apple.security.device.audio-input" not in shown.stdout, program.name
    assert subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], capture_output=True).returncode == 0


def test_the_entitlements_grant_the_microphone_and_the_calendar():
    granted = plistlib.loads(app_bundle.ENTITLEMENTS.read_bytes())
    assert granted == {"com.apple.security.device.audio-input": True,
                       "com.apple.security.personal-information.calendars": True,
                       "com.apple.security.automation.apple-events": True}


@pytest.mark.skipif(shutil.which("codesign") is None, reason="macOS only")
def test_bundle_has_the_language_models_shaders_and_resources(tmp_path: Path):
    """palaver-server, palaver-worker and palaver-lm sit in Contents/MacOS, where the app looks for them
    (AppLocation.binary) and the server and the worker find palaver-lm (beside themselves); MLX's shaders are
    Contents/Resources/mlx.metallib (MLXLocal.useBundledMetallib) and swift-transformers' resource bundle is there
    too (its Bundle.module, through the app's main bundle)."""
    app = _release_app(tmp_path)
    resources = app / "Contents" / "Resources"
    assert (resources / "mlx.metallib").read_bytes() == b"MTLB" + bytes(12)
    assert (resources / "swift-transformers_Hub.bundle" / "Contents" / "Resources" / "gpt2_tokenizer_config.json").is_file()


@pytest.mark.skipif(shutil.which("codesign") is None, reason="macOS only")
def test_bundle_has_the_domain_resources(tmp_path: Path):
    """zipf.bin lies flat in Contents/Resources, where DomainResources.url finds it in the app; the third-party
    notices (the WebRTC code linked into palaver-worker among them) ship with the binaries."""
    app = _release_app(tmp_path)
    resources = app / "Contents" / "Resources"
    assert (resources / "zipf.bin").read_bytes() == (tmp_path / "domain-resources" / "zipf.bin").read_bytes()
    assert (resources / "THIRD_PARTY_LICENSES.md").read_text() == (tmp_path / "THIRD_PARTY_LICENSES.md").read_text()


@pytest.mark.skipif(shutil.which("codesign") is None, reason="macOS only")
def test_the_bundle_check_finds_python_a_path_of_this_mac_and_a_wrong_runtime(tmp_path: Path):
    """tools/build_release.py check_bundle: `make release` refuses such a bundle."""
    import json

    br = _build_release()
    app = _release_app(tmp_path)
    resources = app / "Contents" / "Resources"
    (resources / "python" / "palaver").mkdir(parents=True)
    (resources / "python" / "palaver" / "__init__.py").write_text("")
    (app / "Contents" / "MacOS" / "palaver-python").write_bytes(b"\xcf\xfa\xed\xfe")
    (resources / "web" / "leak.txt").write_text(f"built in {tmp_path}/checkout/x")
    (resources / "runtime.json").write_text(json.dumps({"version": "1.0", "runtime": "3.13.18-arm64-abc"}))
    problems = br.bundle_problems(app, home=str(tmp_path), checkout=tmp_path / "checkout")
    text = "\n".join(problems)
    assert "Contents/Resources/python: named like Python" in text and "__init__.py: Python code" in text
    assert "palaver-python: named like Python" in text and "leak.txt: names" in text
    assert "runtime.json names '3.13.18-arm64-abc'" in text
    with pytest.raises(SystemExit, match="no release without Python"):
        br.check_bundle(app)
    # The shim must stay a small shell script: an interpreter under its name is refused.
    clean = _release_app(tmp_path / "again")
    shutil.copy("/usr/bin/true", clean / "Contents" / "Resources" / "bin" / "python")
    assert any("not the shell shim" in p for p in br.bundle_problems(clean, home="/nonexistent-home"))


def test_a_built_release_in_dist_has_no_python(tmp_path: Path):
    """The bundle `make release` left in dist/app (when there is one): the same check as the build's."""
    app = ROOT / "dist" / "app" / "Palaver.app"
    if not app.is_dir():
        pytest.skip("no release built in dist/ (make release)")
    assert _build_release().bundle_problems(app) == []


def test_the_third_party_notices_name_what_the_new_binaries_link():
    """palaver-server links swift-nio, palaver-worker the WebRTC echo canceller: their notices are in the file the
    bundle carries."""
    text = (Path(__file__).resolve().parent.parent / "THIRD_PARTY_LICENSES.md").read_text()
    for needle in ("swift-nio", "Apache License 2.0", "WebRTC", "BSD-3-Clause", "project-raven", "libogg", "libopus",
                   "wordfreq", "mlx-swift", "mlx-swift-lm", "swift-transformers", "swift-jinja", "yyjson"):
        assert needle in text, needle
    # The Apache License's own text, not only a link to it (FluidAudio, SwiftNIO and its packages are under it).
    assert "TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION" in text
    assert "END OF TERMS AND CONDITIONS" in text


def test_build_app_refuses_without_a_program(tmp_path: Path):
    built = _programs(tmp_path)
    resources = tuple(_lm_resources(tmp_path))
    programs = {"engine": built["palaver-engine"], "app_binary": built["Palaver"], "server": built["palaver-server"],
                "worker": built["palaver-worker"], "lm": built["palaver-lm"], "cli": built["palaver-cli"]}
    targets = {"engine": "engine", "app_binary": "app-swift", "server": "server", "worker": "worker", "lm": "lm",
               "cli": "cli"}
    for missing, target in targets.items():
        with pytest.raises(SystemExit, match=f"make {target}"):
            _build_release().build_app(tmp_path, lm_resources=resources, **{**programs, missing: tmp_path / "missing"})
    # The shaders are part of palaver-lm: without them it can't run the local model.
    with pytest.raises(SystemExit, match="make lm"):
        _build_release().build_app(tmp_path, lm_resources=(tmp_path / "missing.metallib",), **programs)


def test_a_development_install_keeps_the_launcher_and_the_python_menu_bar_app(tmp_path: Path, monkeypatch):
    """`palaver app install` from a checkout: the ObjC launcher runs the venv's `palaver menubar`."""
    monkeypatch.setattr(app_bundle, "compile_launcher", lambda path, **kw: path.write_text("bin"))
    monkeypatch.setattr(app_bundle.subprocess, "run", lambda argv, **kw: None)
    app = app_bundle.build_app(tmp_path, python=Path("/venv/bin/python"), cli_options=[])
    assert plistlib.loads((app / "Contents" / "Info.plist").read_bytes())["CFBundleExecutable"] == "palaver-launcher"
