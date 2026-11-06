"""Tests for updating from inside the app (#60): the state machine with an
idle gate, and the download, unpacking and swap on disk."""

import io
import json
import subprocess
import tarfile
import time
from pathlib import Path

import pytest

from palaver import daemon, install_layout, release, updater



@pytest.fixture(autouse=True)
def local_release(monkeypatch, tmp_path):
    """Assets here are file:// URLs, which the downloader takes only with a local manifest."""
    monkeypatch.setenv("PALAVER_MANIFEST_URL", (tmp_path / "manifest.json").as_uri())


def asset(name, size=10, sha="a" * 64):
    return release.Asset(name, f"https://example.test/{name}", size, sha)


def manifest(version="0.2.0", runtime_id="rt-1", notes=None):
    return release.Manifest(version=version, app=asset(f"palaver-app-{version}.zip", 5), runtime_id=runtime_id,
                            runtime=asset(f"palaver-runtime-{runtime_id}.tar.gz", 100), notes=notes)


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


def make(*, latest=None, busy=None, enabled=True, stage=None, apply=None, installed="0.1.0", clock=None,
         previous=None):
    calls = {"stage": [], "apply": [], "fetch": 0, "saved": []}
    latest = latest if latest is not None else [manifest()]

    def fetch():
        calls["fetch"] += 1
        if isinstance(latest[0], Exception):
            raise latest[0]
        return latest[0]

    def do_stage(plan, progress):
        calls["stage"].append(plan)
        progress(plan.download_bytes)
        if stage:
            return stage(plan)
        return updater.Staged(plan, Path("/staged/Palaver.app"), [])

    def do_apply(staged):
        calls["apply"].append(staged)
        if apply:
            apply(staged)

    u = updater.Updater(
        installed=lambda: None if installed is None else release.Installed(installed, "rt-1", {}),
        fetch_manifest=fetch, stage=do_stage, apply=do_apply,
        busy=busy or (lambda: None), enabled=lambda: enabled, now=clock or Clock(),
        save=calls["saved"].append, previous=previous)
    return u, calls


def test_a_newer_release_is_available_without_downloading_anything():
    u, calls = make(latest=[manifest(notes="Faster notes.")])
    assert u.due()
    status = u.check()
    assert status["state"] == "available"
    assert status["available"] == {"version": "0.2.0", "notes": "Faster notes.", "download_bytes": 5,
                                   "runtime": False, "models": []}
    assert calls["stage"] == []
    assert updater.menu_title(status) == "Update available (0.2.0)"
    assert calls["saved"][-1]["state"] == "available"  # update.json, for the window


def test_the_same_release_is_up_to_date():
    u, _ = make(latest=[manifest(version="0.1.0")])
    assert u.check()["state"] == "up_to_date"
    assert updater.menu_title(u.status()) == "Check for Updates… (Palaver 0.1.0)"
    assert updater.check_result(u.status()) == ("Palaver is up to date", "Palaver 0.1.0 is the latest version.")


def test_the_menu_says_what_a_check_finds():
    assert updater.menu_title({"state": "unsupported"}) is None  # a checkout: nothing to update
    assert updater.menu_title({"state": "checking", "current": "0.1.0"}) == "Checking for updates…"
    assert updater.check_result({"state": "checking"}) is None
    assert updater.check_result({"state": "idle", "check_error": "offline", "current": "0.1.0"}) == (
        "Could not check for updates", "offline")
    u, _ = make(latest=[manifest()])
    status = u.check()
    assert updater.check_result(status)[0] == "Palaver 0.2.0 is available"


def test_a_new_release_is_announced_once():
    u, calls = make(latest=[manifest()])
    assert u.announce() is None  # nothing known yet
    u.check()
    assert u.announce() == "0.2.0"
    assert calls["saved"][-1]["announced"] == "0.2.0"  # kept in update.json: not again after a restart
    u.check()
    assert u.announce() is None
    assert updater.announcement("0.2.0") == ("Palaver 0.2.0 is available",
                                              "Click to see what's new and install it.")


def test_an_announced_release_stays_announced_after_a_restart_and_a_newer_one_is_new():
    latest = [manifest()]
    u, _ = make(latest=latest, previous={"state": "available", "announced": "0.2.0"})
    u.check()
    assert u.announce() is None
    latest[0] = manifest(version="0.3.0")
    u.check()
    assert u.announce() == "0.3.0"


def test_nothing_is_announced_when_up_to_date_or_from_a_checkout():
    u, _ = make(latest=[manifest(version="0.1.0")])
    u.check()
    assert u.announce() is None
    u, _ = make(installed=None)
    assert u.announce() is None


def test_it_checks_at_start_and_then_every_hour():
    clock = Clock()
    u, calls = make(clock=clock)
    assert u.due()
    u.check()
    clock.t += 3599
    assert not u.due()
    clock.t += 1
    assert u.due()


def test_opening_the_window_checks_unless_a_check_was_just_made():
    clock = Clock()
    u, _ = make(clock=clock)
    u.check()
    clock.t += updater.WINDOW_CHECK_AFTER - 1
    assert not u.due(every=updater.WINDOW_CHECK_AFTER)
    clock.t += 1
    assert u.due(every=updater.WINDOW_CHECK_AFTER) and not u.due()  # the hourly one is not due yet


def test_automatic_checks_can_be_turned_off():
    u, _ = make(enabled=False)
    assert not u.due()
    assert u.check()["state"] == "available"  # "Check now" still works


def test_a_failed_check_changes_nothing_and_is_tried_again_in_an_hour():
    clock = Clock()
    u, _ = make(latest=[OSError("offline")], clock=clock)
    status = u.check()
    assert status["state"] == "idle" and status["check_error"] == "offline"
    clock.t += 1800
    assert not u.due()
    clock.t += 1800
    assert u.due()


def test_a_click_downloads_and_installs_at_once_when_idle():
    u, calls = make()
    u.check()
    assert u.request()
    assert u.status()["state"] == "downloading"
    assert u.download()["state"] == "ready"
    assert u.tick() is True  # applied: the app quits for the swap
    assert len(calls["apply"]) == 1 and u.status()["state"] == "installing"


def test_an_update_never_installs_while_recording_or_processing():
    reason = ["recording"]
    u, calls = make(busy=lambda: reason[0])
    u.check()
    u.request()
    u.download()
    assert u.tick() is False and u.tick() is False
    assert calls["apply"] == []
    status = u.status()
    assert status["state"] == "ready" and status["waiting_for"] == "recording"
    assert updater.menu_title(status) == "Update 0.2.0 installs when Palaver is idle (recording)"
    reason[0] = "transcribing"
    assert u.tick() is False
    reason[0] = None  # the next idle moment
    assert u.tick() is True and len(calls["apply"]) == 1


def test_a_failed_download_keeps_the_running_version_and_says_why():
    def stage(plan):
        raise RuntimeError("palaver-app-0.2.0.zip arrived damaged (checksum mismatch)")

    u, calls = make(stage=stage)
    u.check()
    u.request()
    status = u.download()
    assert status["state"] == "failed"
    assert status["error"] == ("Download failed: palaver-app-0.2.0.zip arrived damaged (checksum mismatch). "
                               "Palaver 0.1.0 stays.")
    assert u.tick() is False and calls["apply"] == []
    assert updater.menu_title(status) == "Update 0.2.0 failed — try again"
    u.check()  # a later check keeps saying it failed
    assert u.status()["state"] == "failed"
    assert u.request() and u.status()["error"] is None  # trying again


def test_a_failed_swap_keeps_the_running_version():
    def apply(staged):
        raise OSError("disk full")

    u, _ = make(apply=apply)
    u.check()
    u.request()
    u.download()
    assert u.tick() is False
    assert u.status()["state"] == "failed" and "disk full" in u.status()["error"]


def test_a_checkout_has_nothing_to_update():
    u, calls = make(installed=None)
    assert u.status()["state"] == "unsupported"
    assert not u.due()
    u.check()
    assert calls["fetch"] == 0


def test_nothing_happens_without_the_users_click():
    u, calls = make()
    u.check()
    for _ in range(3):
        assert u.tick() is False
    assert calls["stage"] == [] and calls["apply"] == []


@pytest.mark.parametrize("status, reason", [
    ({"state": "recording"}, "recording"),
    ({"state": "idle", "transcribing": True}, "transcribing"),
    ({"state": "idle", "queued": ["/m/a"]}, "transcribing"),
    ({"state": "idle", "writing_notes": "/m/a"}, "writing notes"),
    ({"state": "idle", "notes_queued": ["/m/a"]}, "writing notes"),
    ({"state": "idle", "indexing": True}, None),  # stopped when Palaver quits
    ({"state": "idle", "teams_active": True}, "a call"),  # about to record
    ({"state": "paused"}, None),
])
def test_the_daemon_says_what_keeps_it_busy(status, reason):
    assert daemon.busy_reason(status) == reason


# --- on disk ---------------------------------------------------------------------------------

def test_only_the_runtime_in_use_and_the_one_before_are_kept():
    assert updater.runtimes_to_remove(["a", "b", "c", ".a.tmp"], current="c", previous="b") == ["a"]
    assert updater.runtimes_to_remove(["a", "c"], current="c", previous=None) == ["a"]


def _runtime_archive(tmp_path: Path, rid: str) -> Path:
    root = tmp_path / "rt-build" / rid / "bin"
    root.mkdir(parents=True)
    (root / "python3.13").write_text("#!/bin/sh\n")
    (root / "python3").symlink_to("python3.13")
    archive = tmp_path / f"palaver-runtime-{rid}.tar.gz"
    with tarfile.open(archive, "w:gz") as tar:
        tar.add(tmp_path / "rt-build" / rid, arcname=rid)
    return archive


def _app_zip(tmp_path: Path, version: str, rid: str) -> Path:
    app = tmp_path / "app-build" / "Palaver.app" / "Contents" / "Resources"
    app.mkdir(parents=True)
    (app / "runtime.json").write_text(json.dumps({"version": version, "runtime": rid}))
    archive = tmp_path / f"palaver-app-{version}.zip"
    subprocess.run(["ditto", "-ck", "--keepParent", str(app.parent.parent), str(archive)], check=True)
    return archive


def _file_asset(path: Path, sha=None) -> release.Asset:
    return release.Asset(path.name, path.as_uri(), path.stat().st_size, sha or release.sha256_file(path))


def test_staging_unpacks_a_new_runtime_whole_and_the_app_beside_the_installed_one(tmp_path):
    home = tmp_path / "home"
    plan = release.Plan("0.2.0", _file_asset(_app_zip(tmp_path, "0.2.0", "rt-2")), "rt-2",
                        _file_asset(_runtime_archive(tmp_path, "rt-2")), ())
    seen = []
    staged = updater.Installer(home).stage(plan, seen.append)
    runtime = install_layout.runtime_dir("rt-2", home)
    assert (runtime / "bin" / "python3").is_symlink() and (runtime / "bin" / "python3").exists()
    assert install_layout.bundle_info(staged.app) == {"version": "0.2.0", "runtime": "rt-2"}
    assert not install_layout.app_path(home).exists()  # nothing swapped yet
    assert seen and seen[-1] == plan.download_bytes


def test_a_damaged_download_stages_nothing(tmp_path):
    from palaver import downloader

    home = tmp_path / "home"
    plan = release.Plan("0.2.0", _file_asset(_app_zip(tmp_path, "0.2.0", "rt-2"), sha="0" * 64), "rt-1", None, ())
    with pytest.raises(downloader.DownloadError, match="damaged"):
        updater.Installer(home).stage(plan)
    assert not (install_layout.support_dir(home) / "updates").exists()


def test_an_app_of_another_version_is_refused(tmp_path):
    plan = release.Plan("0.2.0", _file_asset(_app_zip(tmp_path, "0.1.9", "rt-1")), "rt-1", None, ())
    with pytest.raises(release.ManifestError, match="not Palaver 0.2.0"):
        updater.Installer(tmp_path / "home").stage(plan)


def _old_app(app: Path, version="0.1.0") -> Path:
    (app / "Contents" / "Resources").mkdir(parents=True)
    (app / "Contents" / "Resources" / "runtime.json").write_text(json.dumps({"version": version, "runtime": "rt-1"}))
    (app / "Contents" / "old.txt").write_text("old")
    return app


def _opener(tmp_path: Path, home: Path, *, starts: bool) -> tuple[Path, Path]:
    """`open` for the swap script: records what it opened; when the app
    ``starts``, it writes the started-ok mark as the new menu bar app does."""
    opened = tmp_path / "opened.txt"
    opener = tmp_path / "open"
    ok = install_layout.started_ok_path(home)
    mark = (f'plutil -extract version raw -o - "$1/Contents/Resources/runtime.json" > "{ok}"\n' if starts else "")
    opener.write_text(f'#!/bin/sh\necho "$1" >> "{opened}"\n{mark}')
    opener.chmod(0o755)
    return opener, opened


def _swap(tmp_path, monkeypatch, *, app: Path, starts: bool, wait_for=()):
    home = tmp_path / "home"
    monkeypatch.setenv("PALAVER_APP", str(app))
    plan = release.Plan("0.2.0", _file_asset(_app_zip(tmp_path, "0.2.0", "rt-1")), "rt-1", None, ())
    opener, opened = _opener(tmp_path, home, starts=starts)
    spawned = []
    inst = updater.Installer(home, open_command=str(opener), spawn=spawned.append, start_timeout=2.0)
    inst.apply(inst.stage(plan), wait_for=list(wait_for))
    return spawned[0], opened, home


def test_the_swap_waits_for_the_app_to_quit_replaces_it_and_opens_it(tmp_path, monkeypatch):
    import threading

    app = _old_app(install_layout.app_path(tmp_path / "home"))
    sleeper = subprocess.Popen(["sleep", "0.5"])  # the app, still quitting
    threading.Thread(target=sleeper.wait, daemon=True).start()  # reaped, as the launcher reaps the app
    script, opened, home = _swap(tmp_path, monkeypatch, app=app, starts=True, wait_for=[sleeper.pid])
    started = time.monotonic()
    subprocess.run(script, check=True, timeout=20)
    assert time.monotonic() - started >= 0.3  # it waited for the app to quit
    assert install_layout.bundle_info(app)["version"] == "0.2.0"
    assert not (app / "Contents" / "old.txt").exists()
    assert opened.read_text().split() == [str(app)]
    assert [p.name for p in app.parent.iterdir()] == ["Palaver.app"]
    assert not install_layout.previous_app_dir(home).exists()  # it started: the old one is not needed


def test_the_swap_replaces_the_bundle_that_runs_wherever_it_is(tmp_path, monkeypatch):
    app = _old_app(tmp_path / "Elsewhere" / "Palaver.app")
    script, opened, home = _swap(tmp_path, monkeypatch, app=app, starts=True)
    subprocess.run(script, check=True, timeout=20)
    assert install_layout.bundle_info(app)["version"] == "0.2.0"
    assert not install_layout.app_path(home).exists()


def test_a_new_version_that_does_not_start_is_replaced_by_the_one_before(tmp_path, monkeypatch):
    app = _old_app(install_layout.app_path(tmp_path / "home"))
    script, opened, home = _swap(tmp_path, monkeypatch, app=app, starts=False)
    subprocess.run(script, check=True, timeout=30)
    assert install_layout.bundle_info(app)["version"] == "0.1.0"  # back
    assert opened.read_text().split() == [str(app), str(app)]  # the new one, then the old one again
    status = updater.read_status(home)
    assert status["state"] == "failed" and status["from_swap"] is True
    assert status["error"] == "Palaver 0.2.0 did not start; 0.1.0 is back."
    assert status["available"]["version"] == "0.2.0"


def test_a_swap_that_puts_the_old_version_back_ends_the_new_app_never_its_workers(tmp_path):
    """The app quits: the Swift app (or the launcher of a version before 0.5) gets SIGTERM;
    palaver-python's workers, and the old host's ("Palaver -m palaver ..."), stop on their own."""
    target = tmp_path / "Palaver.app"
    macos = target / "Contents" / "MacOS"
    macos.mkdir(parents=True)
    for name in ("Palaver", "palaver-launcher", "palaver-python"):  # all written first: macOS guards a bundle once run
        (macos / name).write_text("#!/bin/sh\nwhile :; do sleep 0.1; done\n")
        (macos / name).chmod(0o755)
    line = next(x for x in updater._SWAP.splitlines() if x.startswith("pkill"))
    procs = {"app": [macos / "Palaver"], "launcher": [macos / "palaver-launcher"],
             "worker": [macos / "palaver-python", "-m", "palaver", "process", "/m/a"],
             "old worker": [macos / "Palaver", "-m", "palaver", "process", "/m/a"]}
    running = {k: subprocess.Popen([str(a) for a in argv]) for k, argv in procs.items()}
    try:
        time.sleep(0.3)
        subprocess.run(["/bin/sh", "-c", f"target={updater._sh(target)}\n{line}"], check=False, timeout=10)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not all(running[k].poll() is not None for k in ("app", "launcher")):
            time.sleep(0.05)
        assert {k for k, p in running.items() if p.poll() is not None} == {"app", "launcher"}
    finally:
        for p in running.values():
            if p.poll() is None:
                p.kill()
            p.wait()


def test_a_failed_swap_is_still_said_after_the_app_reopened():
    previous = {"state": "failed", "from_swap": True, "error": "Palaver 0.2.0 did not start; 0.1.0 is back.",
                "available": {"version": "0.2.0"}}
    u, _ = make(previous=previous)
    status = u.status()
    assert status["state"] == "failed" and status["error"] == previous["error"]
    assert u.check()["state"] == "failed"  # the same release: the error stays until the user tries again
    assert u.status()["error"] == previous["error"]
    assert u.request() and u.status()["error"] is None


def test_an_update_that_did_not_fail_leaves_no_error_after_the_restart():
    u, _ = make(previous={"state": "installing", "available": {"version": "0.2.0"}})
    assert u.status()["state"] == "idle" and u.status()["error"] is None


def test_an_update_asks_for_the_permissions_at_its_restart_not_in_the_next_call(tmp_path, monkeypatch):
    """A new build is a new signature to macOS: the restarted app asks for
    Microphone and System Audio Recording at once, while Palaver is idle."""
    home = tmp_path / "home"
    marker = install_layout.permissions_marker(home)
    marker.parent.mkdir(parents=True)
    marker.write_text("1")
    monkeypatch.setenv("PALAVER_APP", str(install_layout.app_path(home)))
    plan = release.Plan("0.2.0", _file_asset(_app_zip(tmp_path, "0.2.0", "rt-1")), "rt-1", None, ())
    inst = updater.Installer(home, spawn=lambda argv: None)
    inst.apply(inst.stage(plan))
    assert not marker.exists()


def test_a_call_starting_at_the_last_moment_wins_over_the_update():
    """The idle gate is asked again right before the swap is started: a
    call that began in between is recorded, the update waits."""
    reason = [None]

    def apply(staged):
        reason[0] = "a call"
        raise updater.NotIdle("a call")

    u, calls = make(busy=lambda: reason[0], apply=apply)
    u.check()
    u.request()
    u.download()
    assert u.tick() is False  # nothing quits
    status = u.status()
    assert status["state"] == "ready" and status["waiting_for"] == "a call" and status["error"] is None
    reason[0] = None
    calls["apply"].clear()


def test_the_swap_is_not_started_when_palaver_got_busy(tmp_path, monkeypatch):
    home = tmp_path / "home"
    monkeypatch.setenv("PALAVER_APP", str(install_layout.app_path(home)))
    plan = release.Plan("0.2.0", _file_asset(_app_zip(tmp_path, "0.2.0", "rt-1")), "rt-1", None, ())
    spawned = []
    inst = updater.Installer(home, spawn=spawned.append)
    staged = inst.stage(plan)
    with pytest.raises(updater.NotIdle, match="recording"):
        inst.apply(staged, still_busy=lambda: "recording")
    assert spawned == []
    inst.apply(staged, still_busy=lambda: None)
    assert len(spawned) == 1


@pytest.mark.parametrize("target", ["../../../outside", "/etc/passwd", "../../other-runtime/bin/python3"])
def test_a_runtime_archive_with_a_link_out_of_its_folder_is_refused(tmp_path, target):
    root = tmp_path / "rt-build" / "rt-3" / "bin"
    root.mkdir(parents=True)
    (root / "python3").write_text("#!/bin/sh\n")
    (root / "evil").symlink_to(target)
    archive = tmp_path / "rt.tar.gz"
    with tarfile.open(archive, "w:gz") as tar:
        tar.add(tmp_path / "rt-build" / "rt-3", arcname="rt-3")
    with pytest.raises(release.ManifestError, match="link"):
        updater.unpack_runtime(archive, "rt-3", tmp_path / "home")
    assert not install_layout.runtime_dir("rt-3", tmp_path / "home").exists()


def test_links_inside_the_runtime_are_kept(tmp_path):
    archive = _runtime_archive(tmp_path, "rt-4")
    runtime = updater.unpack_runtime(archive, "rt-4", tmp_path / "home")
    assert (runtime / "bin" / "python3").resolve() == (runtime / "bin" / "python3.13").resolve()


def test_apple_double_files_in_a_runtime_archive_are_skipped(tmp_path):
    # macOS tar adds "._<id>" at the top and "._<name>" beside files; 0.3.x refused such an archive.
    root = tmp_path / "rt-build" / "rt-5" / "bin"
    root.mkdir(parents=True)
    (root / "python3").write_text("#!/bin/sh\n")
    archive = tmp_path / "rt.tar.gz"
    with tarfile.open(archive, "w:gz") as tar:
        for name in ("._rt-5", "rt-5/bin/._python3"):
            info = tarfile.TarInfo(name)
            info.size = 1
            tar.addfile(info, io.BytesIO(b"x"))
        tar.add(tmp_path / "rt-build" / "rt-5", arcname="rt-5")
    runtime = updater.unpack_runtime(archive, "rt-5", tmp_path / "home")
    assert (runtime / "bin" / "python3").exists()
    assert not (runtime / "bin" / "._python3").exists()


def test_the_installed_release_lists_the_runtimes_on_this_mac(tmp_path, monkeypatch):
    home = tmp_path / "home"
    app = tmp_path / "Palaver.app"
    (app / "Contents" / "Resources").mkdir(parents=True)
    (app / "Contents" / "Resources" / "runtime.json").write_text(json.dumps({"version": "0.2.0", "runtime": "rt-2"}))
    monkeypatch.setenv("PALAVER_APP", str(app))
    for rid in ("rt-1", "rt-2"):
        (install_layout.runtime_dir(rid, home) / "bin").mkdir(parents=True)
        (install_layout.runtime_dir(rid, home) / "bin" / "python3").write_text("")
    (install_layout.runtimes_dir(home) / ".rt-3.abcd").mkdir()  # an unpacking that never finished
    here = updater.installed_now(home)
    assert here.version == "0.2.0" and here.runtime_id == "rt-2" and here.runtimes == frozenset({"rt-1", "rt-2"})


def test_unpackings_that_never_finished_are_swept_after_an_hour(tmp_path):
    import os

    home = tmp_path / "home"
    root = install_layout.runtimes_dir(home)
    stale, fresh = root / ".rt-3.abcd", root / ".rt-4.efgh"
    model = install_layout.models_dir(home) / ".northwind-voices.xyz"
    for d in (stale, fresh, model):
        d.mkdir(parents=True)
    (root / ".previous").write_text("rt-1\n")
    old = time.time() - 7200
    for d in (stale, model):
        os.utime(d, (old, old))
    assert sorted(p.name for p in updater.sweep_staging(home)) == [".northwind-voices.xyz", ".rt-3.abcd"]
    assert fresh.exists() and (root / ".previous").exists()
