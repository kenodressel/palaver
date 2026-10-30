"""Tests for install.sh (#60), run against tiny fake release assets in a
throwaway home: it waits for Palaver to finish what it does, quits only the
menu bar app, and opens it again when it ran before."""

import json
import os
import shutil
import signal
import subprocess
import tarfile
import time
from pathlib import Path

import pytest

from palaver import release

ROOT = Path(__file__).resolve().parent.parent
RID = "3.13.18-arm64-aaaaaaaaaaaa"

pytestmark = pytest.mark.skipif(shutil.which("ditto") is None, reason="macOS only")


def _asset(path: Path) -> release.Asset:
    return release.Asset(path.name, f"https://example.test/{path.name}", path.stat().st_size,
                         release.sha256_file(path))


def _app(root: Path, version: str) -> Path:
    app = root / "Palaver.app"
    (app / "Contents" / "MacOS").mkdir(parents=True)
    (app / "Contents" / "Resources" / "bin").mkdir(parents=True)
    (app / "Contents" / "Resources" / "runtime.json").write_text(json.dumps({"version": version, "runtime": RID}))
    for name in ("Contents/MacOS/palaver-launcher", "Contents/MacOS/Palaver", "Contents/Resources/bin/palaver"):
        # The launcher sleeps until SIGTERM, as the app does until it quit.
        (app / name).write_text('#!/bin/sh\ntrap "exit 0" TERM\nwhile :; do sleep 0.1; done\n')
        (app / name).chmod(0o755)
    return app


def build_assets(dist: Path, version: str) -> Path:
    dist.mkdir(parents=True)
    work = dist / "work"
    (work / RID / "bin").mkdir(parents=True)
    (work / RID / "bin" / "python3").write_text("#!/bin/sh\n")
    (work / RID / "bin" / "python3").chmod(0o755)
    runtime = dist / f"palaver-runtime-{RID}.tar.gz"
    with tarfile.open(runtime, "w:gz") as tar:
        tar.add(work / RID, arcname=RID)
    app = _app(work / "app", version)
    zipped = dist / f"palaver-app-{version}.zip"
    subprocess.run(["ditto", "-ck", "--keepParent", str(app), str(zipped)], check=True)
    shutil.rmtree(work)
    m = release.Manifest(version=version, app=_asset(zipped), runtime_id=RID, runtime=_asset(runtime))
    (dist / "manifest.json").write_text(release.manifest_json(m))
    return dist


@pytest.fixture
def home(tmp_path) -> Path:
    h = tmp_path / "home"
    (h / ".local" / "bin").mkdir(parents=True)
    return h


def run_install(home: Path, dist: Path, *args, opened: Path | None = None, background=False, path_bin=True):
    env = {"HOME": str(home), "PATH": (f"{home}/.local/bin:" if path_bin else "") + "/usr/bin:/bin:/usr/sbin:/sbin",
           "PALAVER_ASSETS_DIR": str(dist), "PALAVER_WAIT_SECONDS": "0.2", "LANG": "en_US.UTF-8"}
    if opened is not None:
        opener = home.parent / "open"
        opener.write_text(f'#!/bin/sh\necho "$@" >> "{opened}"\n')
        opener.chmod(0o755)
        env["PALAVER_OPEN_COMMAND"] = str(opener)
    argv = ["/bin/sh", str(ROOT / "install.sh"), *args]
    if background:
        return subprocess.Popen(argv, env=env, cwd=home, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return subprocess.run(argv, env=env, cwd=home, capture_output=True, text=True, timeout=60)


def installed_version(home: Path) -> str | None:
    try:
        return json.loads((home / "Applications" / "Palaver.app" / "Contents" / "Resources" /
                           "runtime.json").read_text())["version"]
    except OSError:
        return None


def test_a_fresh_install_puts_the_layers_in_the_home_folder_and_opens_nothing(home, tmp_path):
    opened = tmp_path / "opened.txt"
    proc = run_install(home, build_assets(tmp_path / "d1", "0.1.0"), opened=opened)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert installed_version(home) == "0.1.0"
    assert (home / "Library" / "Application Support" / "palaver" / "runtime" / RID / "bin" / "python3").exists()
    assert not opened.exists()


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
        time.sleep(2.0)
        assert proc.poll() is None and installed_version(home) == "0.1.0"  # it waits
        assert work.poll() is None and launcher.poll() is None  # nothing killed
        state.write_text(json.dumps({"state": "idle", "transcribing": False, "pid": launcher.pid}))
        time.sleep(1.0)
        assert proc.poll() is None and work.poll() is None  # the transcription still runs: still waiting
        work.terminate()
        work.wait(5)
        out, _ = proc.communicate(timeout=30)
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


def test_a_runtime_archive_with_a_link_out_of_its_folder_is_refused(home, tmp_path):
    dist = build_assets(tmp_path / "d1", "0.1.0")
    work = tmp_path / "evil"
    (work / RID / "bin").mkdir(parents=True)
    (work / RID / "bin" / "python3").write_text("#!/bin/sh\n")
    (work / RID / "bin" / "python3").chmod(0o755)
    (work / RID / "bin" / "evil").symlink_to("../../../../outside")
    runtime = dist / f"palaver-runtime-{RID}.tar.gz"
    with tarfile.open(runtime, "w:gz") as tar:
        tar.add(work / RID, arcname=RID)
    m = release.parse_manifest((dist / "manifest.json").read_text())
    m = release.Manifest(version=m.version, app=m.app, runtime_id=RID, runtime=_asset(runtime))
    (dist / "manifest.json").write_text(release.manifest_json(m))
    proc = run_install(home, dist)
    assert proc.returncode != 0 and "link" in proc.stderr
    assert not (home / "Library" / "Application Support" / "palaver" / "runtime" / RID).exists()
    assert not (home / "Applications" / "Palaver.app").exists()


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
