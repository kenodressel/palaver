"""Commands the native app runs for what it keeps in Python (#60 and the housekeeping of the
menu bar app): `palaver app housekeeping [--hourly]`, `palaver app update
check|download|status|prepare|commit`, `palaver app uninstall-start`, `palaver calendar attach`.

Like `app query`: while the work runs fd 1 points at stderr, so stdout carries JSON lines only
(a download writes {"progress": bytes} lines, then the answer; the others one object). An
error is {"error": text} and exit code 1. The state machine, the timing and the idle gate are
the app's; the network, the staging and the swap script's text are here (updater.py).
"""

from __future__ import annotations

import contextlib
import json
import logging
import os
import sys
import tempfile
from datetime import datetime, timedelta
from pathlib import Path
from typing import Callable

LOGGER = logging.getLogger(__name__)


def run(command: str, opts: dict, cfg) -> int:
    """``cfg``: the Config, or a function that loads it (a malformed config.toml is an error answer)."""
    sys.stdout.flush()
    saved = os.dup(1)
    os.dup2(2, 1)

    def emit(obj: dict) -> None:
        os.write(saved, (json.dumps(obj) + "\n").encode())

    try:
        with contextlib.redirect_stdout(sys.stderr):  # Python's print too, whatever sys.stdout is
            handler = COMMANDS[command]
            result = handler(cfg() if callable(cfg) else cfg, opts, emit)
            rc = 0
    except Exception as exc:
        result, rc = {"error": str(exc).strip() or type(exc).__name__}, 1
    finally:
        sys.stdout.flush()
        os.dup2(saved, 1)
        os.close(saved)
    if result is not None:
        sys.stdout.write(json.dumps(result) + "\n")
        sys.stdout.flush()
    return rc


# --- updates ----------------------------------------------------------------------------------

def _plan_json(plan) -> dict:
    return {"version": plan.version, "notes": plan.notes, "download_bytes": plan.download_bytes,
            "runtime": plan.runtime is not None, "models": [m.name for m in plan.models]}


def _plan(version: str | None = None):
    from . import downloader, release, updater

    installed = updater.installed_now()
    if installed is None:
        return None, True
    manifest = downloader.fetch_manifest()
    plan = release.plan_update(installed, manifest, macos=updater.macos_version())
    if plan is not None and version is not None and plan.version != version:
        raise RuntimeError(f"Palaver {plan.version} came out, not {version}; check again")
    return plan, False


def update_check(cfg, opts, emit) -> dict:
    plan, unsupported = _plan()
    if unsupported:
        return {"plan": None, "unsupported": True}
    return {"plan": None if plan is None else _plan_json(plan)}


def update_status(cfg, opts, emit) -> dict:
    from . import updater

    installed = updater.installed_now()
    return {"installed": None if installed is None else {"version": installed.version, "runtime": installed.runtime_id},
            "previous": updater.read_status(), "macos": updater.macos_version()}


def _staged_file() -> Path:
    from . import install_layout

    return install_layout.support_dir() / "updates" / "staged.json"


def write_staged(staged) -> None:
    """What `download` staged, for `prepare` in another process: the swap needs the new app's
    place, the release's version and runtime, and the models' archives."""
    data = {"version": staged.plan.version, "runtime_id": staged.plan.runtime_id, "app": str(staged.app),
            "models": [{"name": m.name, "version": m.version, "archive": str(path)} for m, path in staged.models]}
    path = _staged_file()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2))


def read_staged():
    from . import release, updater

    try:
        data = json.loads(_staged_file().read_text())
        asset = release.Asset("", "", 0, "")
        plan = release.Plan(data["version"], asset, data["runtime_id"], None, ())
        models = [(release.HostedModel(m["name"], m["version"], "", asset), Path(m["archive"])) for m in data["models"]]
        return updater.Staged(plan, Path(data["app"]), models)
    except (OSError, ValueError, KeyError, TypeError):
        return None


def update_download(cfg, opts, emit) -> dict:
    from . import updater

    plan, unsupported = _plan(opts.get("version"))
    if unsupported or plan is None:
        raise RuntimeError("there is nothing to download")
    _staged_file().unlink(missing_ok=True)
    staged = updater.Installer().stage(plan, lambda done: emit({"progress": int(done)}))
    write_staged(staged)
    return {"ok": True, "version": plan.version}


def _staged_or_raise():
    staged = read_staged()
    if staged is None:
        raise RuntimeError("no downloaded update to install")
    return staged


def update_prepare(cfg, opts, emit) -> dict:
    from . import updater

    script = updater.Installer().prepare(_staged_or_raise(), wait_for=list(opts.get("wait_for") or []))
    return {"script": str(script)}


def update_commit(cfg, opts, emit) -> dict:
    from . import updater

    updater.Installer().commit(_staged_or_raise())
    return {"ok": True}


# --- housekeeping -------------------------------------------------------------------------------

def housekeeping(cfg, opts, emit) -> dict:
    """At start: the retired models go, Claude's MCP entries move to this app's python, runtimes
    before the one before go. Hourly: the audio older than Settings say."""
    from . import install_layout, mcp_access, storage, updater

    if opts.get("hourly"):
        days = storage.audio_days()
        meetings, size = storage.drop_old_audio(cfg.output_dir, days) if days else (0, 0)
        return {"meetings": meetings, "bytes": size}
    freed = storage.drop_retired(cfg)
    info = install_layout.bundle_info()  # {} from a checkout: its python is the developer's, nothing moves
    moved: list[str] = []
    if info:
        try:
            moved = mcp_access.migrate(install_layout.stable_python())
        except Exception:
            LOGGER.warning("moving Claude's MCP entries failed", exc_info=True)
    pruned: list[str] = []
    if info.get("runtime"):
        pruned = updater.prune_runtimes(info["runtime"])
    if moved:
        LOGGER.info("moved the MCP server's entries for %s to this app's python", ", ".join(moved))
    return {"freed": freed, "mcp_moved": moved, "runtimes_pruned": pruned}


# --- calendar -----------------------------------------------------------------------------------

def calendar_attach(cfg, opts, emit) -> dict:
    """Give earlier recordings their calendar events (those started in the last ``since_hours``
    hours; all when None), then recognize voices again with the invitees known. The app skips
    this while it transcribes: processing looks the event up itself."""
    from . import calendar_eventkit, calendar_events, people, settings

    if not getattr(cfg, "calendar_enabled", False):
        return {"attached": 0, "skipped": "calendar is off"}
    if not calendar_eventkit.has_access():
        return {"attached": 0, "skipped": "no calendar access"}
    hours = opts.get("since_hours")
    since = datetime.now().astimezone() - timedelta(hours=hours) if hours else None
    found = calendar_events.attach_all(cfg.output_dir, calendar_eventkit.events_between, since)
    if found:
        people.refresh_recognition(cfg.output_dir, user_name=settings.current_user_name(cfg.user_name))
    return {"attached": found}


# --- uninstall ----------------------------------------------------------------------------------

def uninstall_start(cfg, opts, emit) -> dict:
    """Write uninstall.py's script and start it; it waits for the app (``wait_for``) to quit."""
    from . import uninstall

    home = Path.home()
    models, recordings = bool(opts.get("models")), bool(opts.get("recordings"))
    paths = uninstall.plan(home, output_dir=cfg.output_dir, models=models, recordings=recordings)
    uninstall.start(paths, wait_for=list(opts.get("wait_for") or []), work=Path(tempfile.gettempdir()),
                    then_if_empty=uninstall.emptied(home, output_dir=cfg.output_dir) if recordings else [])
    return {"removing": [str(p) for p in paths]}


COMMANDS: dict[str, Callable] = {
    "update-check": update_check, "update-status": update_status, "update-download": update_download,
    "update-prepare": update_prepare, "update-commit": update_commit, "housekeeping": housekeeping,
    "calendar-attach": calendar_attach, "uninstall-start": uninstall_start,
}
