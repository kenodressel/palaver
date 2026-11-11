"""Tests for install.sh (#60), run against tiny fake release assets in a
throwaway home: it installs the app only (no runtime since 0.6), waits for
Palaver to finish what it does, quits only the menu bar app, and opens it again
when it ran before."""

import json
import os
import shutil
import signal
import subprocess
import tarfile
import threading
import time
from pathlib import Path

import pytest

from tools import release

ROOT = Path(__file__).resolve().parent.parent
RID = "no-python-1"  # the placeholder the manifest names since 0.6 (tools/build_release.py COMPAT_RUNTIME_ID)
OLD_RID = "3.13.18-arm64-155fa76f8b4e"  # 0.5.0rc6's runtime

pytestmark = pytest.mark.skipif(shutil.which("ditto") is None, reason="macOS only")


def _asset(path: Path) -> release.Asset:
    return release.Asset(path.name, f"https://example.test/{path.name}", path.stat().st_size,
                         release.sha256_file(path))


def _app(root: Path, version: str) -> Path:
    app = root / "Palaver.app"
    (app / "Contents" / "MacOS").mkdir(parents=True)
    (app / "Contents" / "Resources" / "bin").mkdir(parents=True)
    (app / "Contents" / "Resources" / "runtime.json").write_text(json.dumps({"version": version, "runtime": RID}))
    for name in ("Contents/MacOS/palaver-launcher", "Contents/MacOS/Palaver", "Contents/MacOS/palaver-python",
                 "Contents/MacOS/palaver-worker", "Contents/MacOS/palaver-server", "Contents/MacOS/palaver-lm",
                 "Contents/Resources/bin/palaver"):
        # The processes of every version an update may find running: up to 0.4 the launcher and the Python host
        # "Palaver"; in 0.5 the Swift app "Palaver" and the host palaver-python, then palaver-worker and
        # palaver-server; since 0.6 no Python. Each sleeps until SIGTERM, as the app does until it quit.
        (app / name).write_text('#!/bin/sh\ntrap "exit 0" TERM\nwhile :; do sleep 0.1; done\n')
        (app / name).chmod(0o755)
    return app


def build_assets(dist: Path, version: str, runtime_id: str = RID) -> Path:
    """A release as 0.6 publishes it: the app and a manifest whose runtime block names the placeholder. The
    placeholder's archive is not among the assets: install.sh must never fetch it."""
    dist.mkdir(parents=True)
    work = dist.parent / f"{dist.name}-work"
    (work / runtime_id / "bin").mkdir(parents=True)
    (work / runtime_id / "bin" / "python3").write_text("#!/bin/sh\nexit 1\n")
    runtime = work / f"palaver-runtime-{runtime_id}.tar.gz"
    with tarfile.open(runtime, "w:gz") as tar:
        tar.add(work / runtime_id, arcname=runtime_id)
    app = _app(work / "app", version)
    data = json.loads((app / "Contents" / "Resources" / "runtime.json").read_text())
    (app / "Contents" / "Resources" / "runtime.json").write_text(json.dumps({**data, "runtime": runtime_id}))
    zipped = dist / f"palaver-app-{version}.zip"
    subprocess.run(["ditto", "-ck", "--keepParent", str(app), str(zipped)], check=True)
    m = release.Manifest(version=version, app=_asset(zipped), runtime_id=runtime_id, runtime=_asset(runtime))
    shutil.rmtree(work)
    (dist / "manifest.json").write_text(release.manifest_json(m))
    return dist


def no_python(tmp_path: Path) -> tuple[Path, Path]:
    """A tools folder first on PATH whose python and python3 only write down that they ran."""
    tools, ran = tmp_path / "no-python", tmp_path / "python-ran.txt"
    tools.mkdir()
    for name in ("python", "python3"):
        (tools / name).write_text(f'#!/bin/sh\necho "$0 $*" >> "{ran}"\nexit 127\n')
        (tools / name).chmod(0o755)
    return tools, ran


@pytest.fixture
def home(tmp_path) -> Path:
    h = tmp_path / "home"
    (h / ".local" / "bin").mkdir(parents=True)
    return h


def run_install(home: Path, dist: Path, *args, opened: Path | None = None, background=False, path_bin=True,
                tools: Path | None = None):
    env = {"HOME": str(home), "PATH": (f"{tools}:" if tools else "") + (f"{home}/.local/bin:" if path_bin else "")
           + "/usr/bin:/bin:/usr/sbin:/sbin",
           "PALAVER_ASSETS_DIR": str(dist), "PALAVER_WAIT_SECONDS": "0.2", "LANG": "en_US.UTF-8"}
    # Never the real `open`: it would start the fake app through Launch Services, where it loops until killed.
    opened = opened if opened is not None else home.parent / "opened-unchecked.txt"
    opener = home.parent / "open"
    opener.write_text(f'#!/bin/sh\necho "$@" >> "{opened}"\n')
    opener.chmod(0o755)
    env["PALAVER_OPEN_COMMAND"] = str(opener)
    argv = ["/bin/sh", str(ROOT / "install.sh"), *args]
    if background:
        return subprocess.Popen(argv, env=env, cwd=home, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return subprocess.run(argv, env=env, cwd=home, capture_output=True, text=True, timeout=60)


class Output:
    """A background install's output, read as it comes: a test waits until install.sh says it waits instead of
    guessing how long it takes to get there (a loaded Mac took more than 2 s)."""

    def __init__(self, proc: subprocess.Popen):
        self.proc = proc
        self.lines: list[str] = []
        self.reader = threading.Thread(target=lambda: self.lines.extend(proc.stdout), daemon=True)
        self.reader.start()

    def wait_for(self, text: str, timeout: float = 30) -> None:
        deadline = time.monotonic() + timeout
        while not any(text in line for line in list(self.lines)):
            assert time.monotonic() < deadline and self.proc.poll() is None, f"never said {text!r}: {''.join(self.lines)}"
            time.sleep(0.05)

    def all(self, timeout: float = 30) -> str:
        self.proc.wait(timeout)
        self.reader.join(5)
        return "".join(self.lines)


def installed_version(home: Path) -> str | None:
    try:
        return json.loads((home / "Applications" / "Palaver.app" / "Contents" / "Resources" /
                           "runtime.json").read_text())["version"]
    except OSError:
        return None


def test_a_support_folder_spelled_with_another_case_is_the_same_folder(home, tmp_path):
    """APFS ignores case: an older Palaver made "Palaver", the installer says
    "palaver"."""
    (home / "Library" / "Application Support" / "Palaver").mkdir(parents=True)
    proc = run_install(home, build_assets(tmp_path / "d1", "0.1.0"))
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert installed_version(home) == "0.1.0"


def test_a_fresh_install_puts_only_the_app_in_the_home_folder_and_needs_no_python(home, tmp_path):
    opened = tmp_path / "opened.txt"
    tools, ran = no_python(tmp_path)
    proc = run_install(home, build_assets(tmp_path / "d1", "0.6.0"), "--autostart", "--cli", opened=opened, tools=tools)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert installed_version(home) == "0.6.0"
    assert not (home / "Library" / "Application Support" / "palaver" / "runtime").exists()  # no runtime at all
    assert "runtime" not in proc.stdout.lower()
    assert not ran.exists()  # no Python started
    assert (home / ".local" / "bin" / "palaver").is_symlink()
    assert (home / "Library" / "LaunchAgents" / "com.kenodressel.meeting-transcribe.plist").exists()
    assert not opened.exists()


def test_an_update_over_0_5_leaves_its_runtime_for_the_app_to_delete(home, tmp_path):
    """0.5.0rc6 installed with its runtime: install.sh puts the 0.6 app in place and downloads nothing else; the old
    runtime stays until the new app has started all the way (its RuntimeCleanup deletes it)."""
    assert run_install(home, build_assets(tmp_path / "d1", "0.5.0rc6", runtime_id=OLD_RID)).returncode != 0  # see below
    old = home / "Library" / "Application Support" / "palaver" / "runtime" / OLD_RID
    (old / "bin").mkdir(parents=True)
    (old / "bin" / "python3").write_text("#!/bin/sh\n")
    (old / "bin" / "python3").chmod(0o755)
    old_app = _app(home / "Applications", "0.5.0rc6")
    (old_app / "Contents" / "Resources" / "runtime.json").write_text(json.dumps({"version": "0.5.0rc6", "runtime": OLD_RID}))
    tools, ran = no_python(tmp_path)
    proc = run_install(home, build_assets(tmp_path / "d2", "0.6.0"), tools=tools)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "Updating Palaver 0.5.0rc6 to 0.6.0" in proc.stdout and installed_version(home) == "0.6.0"
    assert (old / "bin" / "python3").exists() and not ran.exists()
    assert sorted(p.name for p in old.parent.iterdir()) == [OLD_RID]  # nothing unpacked beside it


def test_a_release_that_needs_a_python_runtime_is_sent_to_its_own_installer(home, tmp_path):
    proc = run_install(home, build_assets(tmp_path / "d1", "0.5.0rc6", runtime_id=OLD_RID))
    assert proc.returncode != 0 and "needs a Python runtime" in proc.stderr
    assert "releases/download/v0.5.0rc6/install.sh" in proc.stderr
    assert not (home / "Applications" / "Palaver.app").exists()
    assert not (home / "Library" / "Application Support" / "palaver" / "runtime").exists()


def test_an_app_that_is_not_the_manifests_version_is_refused(home, tmp_path):
    dist = build_assets(tmp_path / "d1", "0.6.0")
    m = release.parse_manifest((dist / "manifest.json").read_text())
    (dist / "manifest.json").write_text(release.manifest_json(release.Manifest(
        version="0.6.1", app=m.app, runtime_id=m.runtime_id, runtime=m.runtime)))
    proc = run_install(home, dist)
    assert proc.returncode != 0 and "is not Palaver 0.6.1" in proc.stderr
    assert not (home / "Applications" / "Palaver.app").exists()


def test_uninstall_removes_the_app_an_old_runtime_the_login_item_and_the_command(home, tmp_path):
    assert run_install(home, build_assets(tmp_path / "d1", "0.6.0"), "--autostart", "--cli").returncode == 0
    support = home / "Library" / "Application Support" / "palaver"
    (support / "runtime" / OLD_RID / "bin").mkdir(parents=True)  # what a version before 0.6 left
    (support / "models").mkdir()
    proc = run_install(home, build_assets(tmp_path / "d2", "0.6.0"), "--uninstall")
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert not (home / "Applications" / "Palaver.app").exists() and not (support / "runtime").exists()
    assert not (home / ".local" / "bin" / "palaver").exists()
    assert not (home / "Library" / "LaunchAgents" / "com.kenodressel.meeting-transcribe.plist").exists()
    assert (support / "models").is_dir()  # kept without --models


def test_an_update_of_an_idle_app_does_not_wait_where_plutil_prints_its_errors_on_stdout(home, tmp_path):
    """macOS 15's plutil says "No value at that key path" on stdout: a key
    daemon.json leaves out is still nothing to wait for."""
    tools = tmp_path / "tools"
    tools.mkdir()
    (tools / "plutil").write_text('#!/bin/sh\nout="$(/usr/bin/plutil "$@" 2>&1)" || '
                                  '{ echo "Could not extract value, error: No value at that key path"; exit 1; }\n'
                                  'printf "%s" "$out"\n')
    (tools / "plutil").chmod(0o755)
    assert run_install(home, build_assets(tmp_path / "d1", "0.1.0")).returncode == 0
    app = home / "Applications" / "Palaver.app"
    launcher = subprocess.Popen([str(app / "Contents" / "MacOS" / "palaver-launcher")])
    state = home / "Library" / "Application Support" / "palaver" / "daemon.json"
    state.write_text(json.dumps({"state": "idle", "pid": launcher.pid}))
    try:
        proc = run_install(home, build_assets(tmp_path / "d2", "0.2.0"), opened=tmp_path / "opened.txt",
                           tools=tools)
        assert proc.returncode == 0, proc.stdout + proc.stderr
        assert "waits until it is done" not in proc.stdout
        assert installed_version(home) == "0.2.0"
    finally:
        if launcher.poll() is None:
            launcher.send_signal(signal.SIGKILL)
            launcher.wait()


def test_an_update_waits_for_processing_quits_only_the_menu_bar_app_and_opens_it_again(home, tmp_path):
    assert run_install(home, build_assets(tmp_path / "d1", "0.1.0")).returncode == 0
    app = home / "Applications" / "Palaver.app"
    launcher = subprocess.Popen([str(app / "Contents" / "MacOS" / "palaver-launcher")])
    work = subprocess.Popen([str(app / "Contents" / "MacOS" / "Palaver"), "-m", "palaver", "process", "/m/a"])
    state = home / "Library" / "Application Support" / "palaver" / "daemon.json"
    state.write_text(json.dumps({"state": "idle", "transcribing": True, "pid": launcher.pid}))
    opened = tmp_path / "opened.txt"
    try:
        proc = run_install(home, build_assets(tmp_path / "d2", "0.2.0"), opened=opened, background=True)
        output = Output(proc)
        output.wait_for("waits until it is done")
        assert proc.poll() is None and installed_version(home) == "0.1.0"  # it waits
        assert work.poll() is None and launcher.poll() is None  # nothing killed
        state.write_text(json.dumps({"state": "idle", "transcribing": False, "pid": launcher.pid}))
        time.sleep(1.0)
        assert proc.poll() is None and work.poll() is None  # the transcription still runs: still waiting
        work.terminate()
        work.wait(5)
        out = output.all()
        assert proc.returncode == 0, out
        assert "waits until it is done" in out
        assert launcher.wait(5) == 0  # quit with SIGTERM, as from the menu
        assert installed_version(home) == "0.2.0"
        assert opened.read_text().split() == [str(app)]  # it ran before: it runs again
    finally:
        for p in (launcher, work):
            if p.poll() is None:
                p.send_signal(signal.SIGKILL)
                p.wait()


def test_an_update_waits_for_the_swift_apps_workers_and_quits_only_the_app(home, tmp_path):
    """Since 0.5 the app is the Swift binary Contents/MacOS/Palaver (run without arguments); its
    workers run as palaver-python. A worker processing a meeting is waited for and never killed."""
    assert run_install(home, build_assets(tmp_path / "d1", "0.1.0")).returncode == 0
    app = home / "Applications" / "Palaver.app"
    swift_app = subprocess.Popen([str(app / "Contents" / "MacOS" / "Palaver")])
    work = subprocess.Popen([str(app / "Contents" / "MacOS" / "palaver-python"), "-m", "palaver", "process", "/m/a"])
    web = subprocess.Popen([str(app / "Contents" / "MacOS" / "palaver-python"), "-m", "palaver", "webapp-serve"])
    state = home / "Library" / "Application Support" / "palaver" / "daemon.json"
    state.write_text(json.dumps({"state": "idle", "pid": swift_app.pid}))
    opened = tmp_path / "opened.txt"
    try:
        proc = run_install(home, build_assets(tmp_path / "d2", "0.2.0"), opened=opened, background=True)
        output = Output(proc)
        output.wait_for("processing a meeting")
        assert proc.poll() is None and installed_version(home) == "0.1.0"  # the worker processes a meeting
        assert work.poll() is None and swift_app.poll() is None
        work.terminate()
        work.wait(5)
        web.terminate()  # the window's server stops with the app
        web.wait(5)
        out = output.all()
        assert proc.returncode == 0, out
        assert "processing a meeting" in out
        assert swift_app.wait(5) == 0  # quit with SIGTERM
        assert installed_version(home) == "0.2.0"
        assert opened.read_text().split() == [str(app)]  # it ran before: it runs again
    finally:
        for p in (swift_app, work, web):
            if p.poll() is None:
                p.send_signal(signal.SIGKILL)
                p.wait()


def test_an_update_waits_for_palaver_worker_processing_a_meeting(home, tmp_path):
    """The pipeline's worker is palaver-worker (phase 3): a `process` of it is waited for like palaver-python's;
    the window's server palaver-server stops with the app."""
    assert run_install(home, build_assets(tmp_path / "d1", "0.1.0")).returncode == 0
    app = home / "Applications" / "Palaver.app"
    macos = app / "Contents" / "MacOS"
    swift_app = subprocess.Popen([str(macos / "Palaver")])
    work = subprocess.Popen([str(macos / "palaver-worker"), "process", "/m/a"])
    web = subprocess.Popen([str(macos / "palaver-server"), "--listen-fd", "3", "--ready-fd", "4"])
    state = home / "Library" / "Application Support" / "palaver" / "daemon.json"
    state.write_text(json.dumps({"state": "idle", "pid": swift_app.pid}))
    try:
        proc = run_install(home, build_assets(tmp_path / "d2", "0.2.0"), background=True)
        output = Output(proc)
        output.wait_for("processing a meeting")
        assert proc.poll() is None and installed_version(home) == "0.1.0"  # the worker processes a meeting
        assert work.poll() is None and swift_app.poll() is None
        work.terminate()
        work.wait(5)
        web.terminate()
        web.wait(5)
        out = output.all()
        assert proc.returncode == 0, out
        assert "processing a meeting" in out
        assert installed_version(home) == "0.2.0"
    finally:
        for p in (swift_app, work, web):
            if p.poll() is None:
                p.send_signal(signal.SIGKILL)
                p.wait()


def test_cli_never_replaces_a_palaver_command_that_is_not_palavers(home, tmp_path):
    mine = home / ".local" / "bin" / "palaver"
    mine.write_text("#!/bin/sh\necho mine\n")
    proc = run_install(home, build_assets(tmp_path / "d1", "0.1.0"), "--cli")
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert mine.read_text() == "#!/bin/sh\necho mine\n" and not mine.is_symlink()
    assert "not Palaver's" in proc.stderr


def test_cli_links_the_command_when_the_place_is_free(home, tmp_path):
    proc = run_install(home, build_assets(tmp_path / "d1", "0.1.0"), "--cli")
    assert proc.returncode == 0, proc.stdout + proc.stderr
    link = home / ".local" / "bin" / "palaver"
    assert link.is_symlink() and str(link.readlink()).endswith("Palaver.app/Contents/Resources/bin/palaver")


def test_unpackings_that_never_finished_are_swept_after_an_hour(home, tmp_path):
    support = home / "Library" / "Application Support" / "palaver"
    stale = [support / "runtime" / ".rt.abcdef", support / ".install.abcdef", home / "Applications" / ".Palaver.app.abcdef"]
    fresh = support / "runtime" / ".rt.fresh"
    for d in (*stale, fresh):
        d.mkdir(parents=True)
    old = time.time() - 7200
    for d in stale:
        os.utime(d, (old, old))
    assert run_install(home, build_assets(tmp_path / "d1", "0.1.0")).returncode == 0
    assert [d for d in stale if d.exists()] == [] and fresh.exists()


def test_a_download_cut_short_runs_nothing(home, tmp_path):
    """curl | sh of a part of the script: everything is in main(), called
    on the last line, so a part does nothing."""
    text = (ROOT / "install.sh").read_text()
    part = tmp_path / "part.sh"
    part.write_text(text[: int(len(text) * 0.9)])
    env = {"HOME": str(home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
           "PALAVER_ASSETS_DIR": str(build_assets(tmp_path / "d1", "0.1.0"))}
    subprocess.run(["/bin/sh", str(part)], env=env, cwd=home, capture_output=True, timeout=30)
    assert sorted(p.name for p in home.iterdir()) == [".local"]
    assert text.rstrip().splitlines()[-1] == 'main "$@"'


def test_the_installer_downloads_over_https_only():
    text = (ROOT / "install.sh").read_text()
    code = [line for line in text.splitlines() if not line.lstrip().startswith("#")]
    curls = [line for line in code if line.strip().startswith("curl ") or " curl " in line]
    assert curls and all("--proto '=https'" in line and "--proto-redir '=https'" in line for line in curls)
