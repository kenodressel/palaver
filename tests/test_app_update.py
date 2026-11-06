"""The Python commands the native app runs for housekeeping, calendar attach and updates
(`palaver app housekeeping|update|uninstall-start`, `palaver calendar attach`). Fakes only:
no network, no EventKit, no real swap."""

import json
from datetime import datetime, timedelta
from pathlib import Path
from types import SimpleNamespace

import pytest

from palaver import app_update, install_layout, release, updater
from palaver.cli import main


@pytest.fixture(autouse=True)
def home(tmp_path, monkeypatch) -> Path:
    h = tmp_path / "home"
    h.mkdir()
    monkeypatch.setenv("HOME", str(h))
    monkeypatch.delenv("PALAVER_APP", raising=False)
    return h


def _cfg(tmp_path: Path, **kw):
    return SimpleNamespace(output_dir=tmp_path / "out", calendar_enabled=True, user_name="Timo Strauß", **kw)


def _run(capfd, command, opts, cfg):
    rc = app_update.run(command, opts, cfg)
    lines = [json.loads(line) for line in capfd.readouterr().out.splitlines()]
    return rc, lines


def _asset(name, size=10):
    return release.Asset(name, f"https://example.test/{name}", size, "a" * 64)


def _manifest(version="0.2.0", runtime_id="rt-1"):
    return release.Manifest(version=version, app=_asset("app.zip", 5), runtime_id=runtime_id,
                            runtime=_asset("rt.tar.gz", 100), notes="Faster.")


def _installed(version="0.1.0"):
    return release.Installed(version, "rt-1", {})


# --- update check / status ---------------------------------------------------------------------

def test_check_says_what_a_newer_release_downloads(tmp_path, monkeypatch, capfd):
    monkeypatch.setattr(updater, "installed_now", lambda home=None: _installed())
    monkeypatch.setattr("palaver.downloader.fetch_manifest", lambda: _manifest())
    rc, out = _run(capfd, "update-check", {}, _cfg(tmp_path))
    assert rc == 0
    assert out == [{"plan": {"version": "0.2.0", "notes": "Faster.", "download_bytes": 5,
                             "runtime": False, "models": []}}]


def test_check_of_the_same_release_has_no_plan(tmp_path, monkeypatch, capfd):
    monkeypatch.setattr(updater, "installed_now", lambda home=None: _installed("0.2.0"))
    monkeypatch.setattr("palaver.downloader.fetch_manifest", lambda: _manifest())
    assert _run(capfd, "update-check", {}, _cfg(tmp_path)) == (0, [{"plan": None}])


def test_a_failed_check_is_an_error_answer(tmp_path, monkeypatch, capfd):
    monkeypatch.setattr(updater, "installed_now", lambda home=None: _installed())

    def offline():
        raise OSError("offline")

    monkeypatch.setattr("palaver.downloader.fetch_manifest", offline)
    rc, out = _run(capfd, "update-check", {}, _cfg(tmp_path))
    assert rc == 1 and out == [{"error": "offline"}]


def test_a_checkout_has_nothing_to_check(tmp_path, monkeypatch, capfd):
    monkeypatch.setattr(updater, "installed_now", lambda home=None: None)
    assert _run(capfd, "update-check", {}, _cfg(tmp_path)) == (0, [{"plan": None, "unsupported": True}])


def test_status_is_the_installed_release_and_update_json_as_the_last_run_left_it(tmp_path, monkeypatch, capfd):
    monkeypatch.setattr(updater, "installed_now", lambda home=None: _installed())
    updater.write_status({"state": "failed", "from_swap": True, "error": "x"})
    rc, out = _run(capfd, "update-status", {}, _cfg(tmp_path))
    assert rc == 0
    assert out[0]["installed"] == {"version": "0.1.0", "runtime": "rt-1"}
    assert out[0]["previous"]["from_swap"] is True
    assert out[0]["macos"] == updater.macos_version()


def test_status_of_a_checkout_has_no_installed_release(tmp_path, monkeypatch, capfd):
    monkeypatch.setattr(updater, "installed_now", lambda home=None: None)
    rc, out = _run(capfd, "update-status", {}, _cfg(tmp_path))
    assert out[0]["installed"] is None and out[0]["previous"] is None


# --- download ----------------------------------------------------------------------------------

def test_download_reports_progress_then_the_staged_update(tmp_path, monkeypatch, capfd):
    monkeypatch.setattr(updater, "installed_now", lambda home=None: _installed())
    monkeypatch.setattr("palaver.downloader.fetch_manifest", lambda: _manifest())

    def stage(self, plan, progress=lambda n: None):
        progress(40)
        progress(105)
        return updater.Staged(plan, Path("/staged/Palaver.app"), [])

    monkeypatch.setattr(updater.Installer, "stage", stage)
    rc, out = _run(capfd, "update-download", {"version": "0.2.0"}, _cfg(tmp_path))
    assert rc == 0
    assert out == [{"progress": 40}, {"progress": 105}, {"ok": True, "version": "0.2.0"}]
    staged = app_update.read_staged()
    assert staged.plan.version == "0.2.0" and staged.app == Path("/staged/Palaver.app")


def test_download_of_another_release_than_asked_is_refused(tmp_path, monkeypatch, capfd):
    monkeypatch.setattr(updater, "installed_now", lambda home=None: _installed())
    monkeypatch.setattr("palaver.downloader.fetch_manifest", lambda: _manifest("0.3.0"))
    monkeypatch.setattr(updater.Installer, "stage", lambda *a, **k: pytest.fail("must not download"))
    rc, out = _run(capfd, "update-download", {"version": "0.2.0"}, _cfg(tmp_path))
    assert rc == 1 and "0.3.0" in out[0]["error"]


def test_a_failed_download_says_why(tmp_path, monkeypatch, capfd):
    monkeypatch.setattr(updater, "installed_now", lambda home=None: _installed())
    monkeypatch.setattr("palaver.downloader.fetch_manifest", lambda: _manifest())

    def broken(self, plan, progress=lambda n: None):
        raise RuntimeError("checksum differs")

    monkeypatch.setattr(updater.Installer, "stage", broken)
    rc, out = _run(capfd, "update-download", {"version": "0.2.0"}, _cfg(tmp_path))
    assert rc == 1 and out == [{"error": "checksum differs"}]
    assert app_update.read_staged() is None


# --- prepare / commit (the swap, started by the app) ---------------------------------------------

def test_prepare_and_commit_are_the_installers_halves_on_the_staged_update(tmp_path, monkeypatch, capfd, home):
    plan = release.Plan("0.2.0", _asset("app.zip"), "rt-1", None, ())
    app_update.write_staged(updater.Staged(plan, Path("/staged/Palaver.app"), []))
    seen = []
    monkeypatch.setattr(updater.Installer, "prepare",
                        lambda self, staged, wait_for=(), still_busy=None: seen.append(("prepare", staged.plan.version, list(wait_for))) or Path("/x/swap.sh"))
    monkeypatch.setattr(updater.Installer, "commit", lambda self, staged: seen.append(("commit", staged.plan.version)))
    rc, out = _run(capfd, "update-prepare", {"wait_for": [123]}, _cfg(tmp_path))
    assert rc == 0 and out == [{"script": "/x/swap.sh"}]
    assert _run(capfd, "update-commit", {}, _cfg(tmp_path)) == (0, [{"ok": True}])
    assert seen == [("prepare", "0.2.0", [123]), ("commit", "0.2.0")]


def test_prepare_without_a_staged_update_is_an_error(tmp_path, capfd):
    rc, out = _run(capfd, "update-prepare", {"wait_for": []}, _cfg(tmp_path))
    assert rc == 1 and "no downloaded update" in out[0]["error"]


def test_the_installer_halves_equal_apply(tmp_path, monkeypatch, home):
    """apply = prepare, the idle gate once more, commit, launch: split between two processes, the
    same steps."""
    steps = []
    inst = updater.Installer(home, spawn=lambda argv: steps.append(("spawn", argv[0])))
    monkeypatch.setattr(inst, "prepare", lambda staged, wait_for=(), still_busy=None: steps.append("prepare") or Path("s.sh"))
    monkeypatch.setattr(inst, "commit", lambda staged: steps.append("commit"))
    inst.apply(object(), still_busy=lambda: steps.append("busy") or None)
    assert steps == ["prepare", "busy", "commit", ("spawn", "/bin/sh")]


# --- housekeeping ------------------------------------------------------------------------------

def test_housekeeping_at_start_drops_retired_models_moves_mcp_entries_and_prunes_runtimes(tmp_path, monkeypatch, capfd):
    from palaver import mcp_access, storage

    calls = []
    monkeypatch.setattr(storage, "drop_retired", lambda cfg: calls.append("retired") or 1234)
    monkeypatch.setattr(install_layout, "stable_python", lambda: "/app/bin/python")
    monkeypatch.setattr(mcp_access, "migrate", lambda exe: calls.append(("mcp", exe)) or ["code"])
    monkeypatch.setattr(install_layout, "bundle_info", lambda app=None: {"version": "0.3", "runtime": "rt-9"})
    monkeypatch.setattr(updater, "prune_runtimes", lambda current, home=None: calls.append(("prune", current)) or ["rt-1"])
    rc, out = _run(capfd, "housekeeping", {"hourly": False}, _cfg(tmp_path))
    assert rc == 0
    assert calls == ["retired", ("mcp", "/app/bin/python"), ("prune", "rt-9")]
    assert out == [{"freed": 1234, "mcp_moved": ["code"], "runtimes_pruned": ["rt-1"]}]


def test_housekeeping_from_a_checkout_prunes_nothing(tmp_path, monkeypatch, capfd):
    from palaver import mcp_access, storage

    monkeypatch.setattr(storage, "drop_retired", lambda cfg: 0)
    monkeypatch.setattr(mcp_access, "migrate", lambda exe: [])
    monkeypatch.setattr(install_layout, "bundle_info", lambda app=None: {})
    monkeypatch.setattr(updater, "prune_runtimes", lambda *a, **k: pytest.fail("a checkout has no runtimes"))
    assert _run(capfd, "housekeeping", {"hourly": False}, _cfg(tmp_path))[0] == 0


def test_a_checkout_does_not_touch_claudes_mcp_entries(tmp_path, monkeypatch, capfd):
    """_move_mcp_entries ran only from an installed app: from a checkout the entries (pointing at the
    developer's own python) stay."""
    from palaver import mcp_access, storage

    monkeypatch.setattr(storage, "drop_retired", lambda cfg: 0)
    monkeypatch.setattr(install_layout, "bundle_info", lambda app=None: {})
    monkeypatch.setattr(mcp_access, "migrate", lambda exe: pytest.fail("a checkout moves nothing"))
    rc, out = _run(capfd, "housekeeping", {"hourly": False}, _cfg(tmp_path))
    assert rc == 0 and out[0]["mcp_moved"] == []


def test_a_failing_mcp_move_does_not_stop_the_rest(tmp_path, monkeypatch, capfd):
    from palaver import mcp_access, storage

    monkeypatch.setattr(storage, "drop_retired", lambda cfg: 5)

    def broken(exe):
        raise OSError("read-only")

    monkeypatch.setattr(mcp_access, "migrate", broken)
    monkeypatch.setattr(install_layout, "bundle_info", lambda app=None: {"version": "0.3"})
    rc, out = _run(capfd, "housekeeping", {"hourly": False}, _cfg(tmp_path))
    assert rc == 0 and out[0]["freed"] == 5 and out[0]["mcp_moved"] == []


def test_the_hourly_housekeeping_drops_audio_older_than_the_setting(tmp_path, monkeypatch, capfd):
    from palaver import storage

    seen = []
    monkeypatch.setattr(storage, "audio_days", lambda: 14)
    monkeypatch.setattr(storage, "drop_old_audio", lambda out, days: seen.append((out, days)) or (2, 900))
    monkeypatch.setattr(storage, "drop_retired", lambda cfg: pytest.fail("only at start"))
    cfg = _cfg(tmp_path)
    rc, out = _run(capfd, "housekeeping", {"hourly": True}, cfg)
    assert rc == 0 and seen == [(cfg.output_dir, 14)] and out == [{"meetings": 2, "bytes": 900}]


def test_the_hourly_housekeeping_keeps_audio_when_no_days_are_set(tmp_path, monkeypatch, capfd):
    from palaver import storage

    monkeypatch.setattr(storage, "audio_days", lambda: 0)
    monkeypatch.setattr(storage, "drop_old_audio", lambda *a: pytest.fail("keep forever"))
    assert _run(capfd, "housekeeping", {"hourly": True}, _cfg(tmp_path)) == (0, [{"meetings": 0, "bytes": 0}])


# --- calendar attach ---------------------------------------------------------------------------

def test_attach_gives_recent_recordings_their_events_and_recognizes_voices_again(tmp_path, monkeypatch, capfd):
    from palaver import calendar_eventkit, calendar_events, people, settings

    seen = {}
    monkeypatch.setattr(calendar_eventkit, "has_access", lambda: True)
    monkeypatch.setattr(calendar_events, "attach_all",
                        lambda out, provider, since=None: seen.update(out=out, since=since, provider=provider) or 3)
    monkeypatch.setattr(people, "refresh_recognition", lambda out, user_name="": seen.update(user=user_name))
    monkeypatch.setattr(settings, "current_user_name", lambda d: d)
    cfg = _cfg(tmp_path)
    rc, out = _run(capfd, "calendar-attach", {"since_hours": 36}, cfg)
    assert rc == 0 and out == [{"attached": 3}]
    assert seen["out"] == cfg.output_dir and seen["user"] == "Timo Strauß"
    assert seen["provider"] is calendar_eventkit.events_between
    age = datetime.now().astimezone() - seen["since"]
    assert timedelta(hours=35, minutes=59) < age < timedelta(hours=36, minutes=1)


def test_attach_without_since_looks_at_everything(tmp_path, monkeypatch, capfd):
    from palaver import calendar_eventkit, calendar_events, people

    seen = {}
    monkeypatch.setattr(calendar_eventkit, "has_access", lambda: True)
    monkeypatch.setattr(calendar_events, "attach_all", lambda out, provider, since=None: seen.update(since=since) or 0)
    monkeypatch.setattr(people, "refresh_recognition", lambda *a, **k: pytest.fail("nothing found"))
    assert _run(capfd, "calendar-attach", {"since_hours": None}, _cfg(tmp_path)) == (0, [{"attached": 0}])
    assert seen["since"] is None


def test_attach_does_nothing_without_calendar_access_or_when_it_is_off(tmp_path, monkeypatch, capfd):
    from palaver import calendar_eventkit, calendar_events

    monkeypatch.setattr(calendar_events, "attach_all", lambda *a, **k: pytest.fail("no access"))
    monkeypatch.setattr(calendar_eventkit, "has_access", lambda: False)
    assert _run(capfd, "calendar-attach", {"since_hours": 36}, _cfg(tmp_path)) == (0, [{"attached": 0, "skipped": "no calendar access"}])
    monkeypatch.setattr(calendar_eventkit, "has_access", lambda: True)
    off = SimpleNamespace(output_dir=tmp_path, calendar_enabled=False, user_name="")
    assert _run(capfd, "calendar-attach", {"since_hours": 36}, off) == (0, [{"attached": 0, "skipped": "calendar is off"}])


# --- uninstall ---------------------------------------------------------------------------------

def test_uninstall_start_writes_and_starts_the_script_and_lists_what_goes(tmp_path, monkeypatch, capfd, home):
    from palaver import uninstall

    seen = {}
    monkeypatch.setattr(uninstall, "plan",
                        lambda h, **kw: seen.update(plan=kw) or [home / "a", home / "b"])
    monkeypatch.setattr(uninstall, "emptied", lambda h, **kw: [home / "empty"])
    monkeypatch.setattr(uninstall, "start", lambda paths, **kw: seen.update(start=(paths, kw)))
    cfg = _cfg(tmp_path)
    rc, out = _run(capfd, "uninstall-start", {"models": True, "recordings": True, "wait_for": [42]}, cfg)
    assert rc == 0 and out == [{"removing": [str(home / "a"), str(home / "b")]}]
    assert seen["plan"] == {"output_dir": cfg.output_dir, "models": True, "recordings": True}
    paths, kw = seen["start"]
    assert kw["wait_for"] == [42] and kw["then_if_empty"] == [home / "empty"]


# --- the command line ----------------------------------------------------------------------------

def test_the_cli_routes_the_commands(tmp_path, monkeypatch, capfd):
    cfg = tmp_path / "config.toml"
    cfg.write_text(f'[recording]\noutput_dir = "{tmp_path / "out"}"\n')
    seen = []
    monkeypatch.setattr(app_update, "run", lambda command, opts, cfg: seen.append((command, opts)) or 0)
    for argv in (["app", "housekeeping", "--hourly"], ["app", "update", "check", "--json"],
                 ["app", "update", "download", "--version", "0.2.0", "--json"],
                 ["app", "update", "prepare", "--wait-for", "7", "8", "--json"], ["app", "update", "commit", "--json"],
                 ["app", "update", "status", "--json"],
                 ["app", "uninstall-start", "--models", "--wait-for", "9"],
                 ["calendar", "attach", "--since", "36"], ["calendar", "attach"]):
        assert main(["--config", str(cfg), *argv]) == 0
    assert seen == [
        ("housekeeping", {"hourly": True}), ("update-check", {}), ("update-download", {"version": "0.2.0"}),
        ("update-prepare", {"wait_for": [7, 8]}), ("update-commit", {}), ("update-status", {}),
        ("uninstall-start", {"models": True, "recordings": False, "wait_for": [9]}),
        ("calendar-attach", {"since_hours": 36.0}), ("calendar-attach", {"since_hours": None})]


def test_the_apps_commands_load_the_config_without_the_keychain(tmp_path, monkeypatch, capfd):
    """Run by the app at every start and every hour: a Keychain read can be a prompt each time, and
    none of them needs a token."""
    import keyring

    asked = []
    monkeypatch.setattr(keyring, "get_password", lambda service, name: asked.append(name))
    monkeypatch.delenv("NOTION_TOKEN", raising=False)
    monkeypatch.delenv("HF_TOKEN", raising=False)
    cfg = tmp_path / "config.toml"
    cfg.write_text(f'[recording]\noutput_dir = "{tmp_path / "out"}"\n[notion]\nparent_page_id = "abc"\n')
    loaded = []
    monkeypatch.setattr(app_update, "run", lambda command, opts, load: loaded.append(load()) or 0)
    for argv in (["app", "housekeeping", "--hourly"], ["app", "update", "check", "--json"],
                 ["app", "update", "status", "--json"], ["app", "uninstall-start", "--wait-for", "9"],
                 ["calendar", "attach"]):
        assert main(["--config", str(cfg), *argv]) == 0
    assert len(loaded) == 5 and all(c.output_dir == tmp_path / "out" for c in loaded)
    assert asked == []
