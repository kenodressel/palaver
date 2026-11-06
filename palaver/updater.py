"""Updates from inside the app (#60).

The menu bar app checks the latest release's manifest.json at start, every
hour and when the window opens (unless turned off in Settings), and says so
next to the menu bar icon (↑), in the menu, in the window's top bar, on
Today and in Settings when there is a newer one; a
notification tells about each new release once. Nothing downloads until
the user clicks. Then only what changed is downloaded and checked against the
manifest's sha256: the app always, the runtime when its id changed, a
model the user has when its version changed. The new app is swapped in by
a small script after Palaver quits, only when it is idle: never while it
records, transcribes or writes notes; otherwise at the next idle moment.
Anything failing keeps the version that runs and says why.

No telemetry: a check is one anonymous GET of a public file.

``Updater`` is the state machine (its I/O injected, tested with fakes);
``Installer`` does the downloading and swapping on disk.
"""

from __future__ import annotations

import json
import os
import platform
import shutil
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from . import install_layout, model_store, release

CHECK_EVERY = 3600
# Opening the window looks too, when the last look is this old: a release seen within minutes.
WINDOW_CHECK_AFTER = 10 * 60
RETRY_CHECK = 3600  # after a failed check (offline, rate-limited)

# Waiting for an update to download or for an idle moment; the rest are at rest.
IDLE, CHECKING, UP_TO_DATE, AVAILABLE, DOWNLOADING, READY, INSTALLING, FAILED, UNSUPPORTED = (
    "idle", "checking", "up_to_date", "available", "downloading", "ready", "installing", "failed", "unsupported")


@dataclass
class Staged:
    """An update downloaded and checked, waiting to be swapped in."""
    plan: release.Plan
    app: Path  # the new Palaver.app, unpacked
    models: list[tuple[release.HostedModel, Path]]


class NotIdle(RuntimeError):
    """Palaver got busy right before the swap: the update waits again."""


class Updater:
    def __init__(self, *, installed: Callable[[], release.Installed | None],
                 fetch_manifest: Callable[[], release.Manifest],
                 stage: Callable[[release.Plan, Callable[[int], None]], Staged],
                 apply: Callable[[Staged], None],
                 busy: Callable[[], str | None] = lambda: None,
                 enabled: Callable[[], bool] = lambda: True,
                 now: Callable[[], float] = time.time,
                 macos: str | None = None,
                 save: Callable[[dict], None] = lambda status: None,
                 previous: dict | None = None):
        """``previous``: update.json as the app before this start left it; a
        swap that failed says so there, and it is said here again."""
        self._installed, self._fetch, self._stage, self._apply = installed, fetch_manifest, stage, apply
        self._busy, self._enabled, self._now, self._macos, self._save = busy, enabled, now, macos, save
        self._lock = threading.RLock()
        self.state = IDLE if installed() is not None else UNSUPPORTED
        self.plan: release.Plan | None = None
        self.staged: Staged | None = None
        self.error: str | None = None
        self.check_error: str | None = None
        self.checked_at: float | None = None
        self.last_try: float | None = None
        self.done_bytes = 0
        self.wanted = False  # the user asked for it: install at the next idle moment
        self.waiting_for: str | None = None
        self.failed_version: str | None = None  # the release whose download or swap failed
        self.announced: str | None = (previous or {}).get("announced")  # the release a notification told about
        if self.state != UNSUPPORTED and previous and previous.get("state") == FAILED and previous.get("from_swap"):
            self.state, self.error = FAILED, str(previous.get("error") or "The update failed.")
            self.failed_version = (previous.get("available") or {}).get("version")

    # --- checking ---------------------------------------------------------------------------

    def due(self, every: float | None = None) -> bool:
        """Time for an automatic check: at start, then every hour (``every``:
        when the last one is older than that, as the window opening asks)."""
        with self._lock:
            if self.state in (UNSUPPORTED, CHECKING, DOWNLOADING, READY, INSTALLING) or not self._enabled():
                return False
            if self.last_try is None:
                return True
            wait = every if every is not None else RETRY_CHECK if self.check_error else CHECK_EVERY
            return self._now() - self.last_try >= wait

    def check(self) -> dict:
        """Ask the latest release. A failed check changes nothing but says why."""
        with self._lock:
            if self.state in (UNSUPPORTED, DOWNLOADING, READY, INSTALLING):
                return self.status()
            before, self.state = self.state, CHECKING
            self.last_try = self._now()
        try:
            manifest = self._fetch()
            plan = release.plan_update(self._installed(), manifest, macos=self._macos)
        except Exception as exc:  # offline, rate-limited, a broken manifest: try again later
            with self._lock:
                self.state, self.check_error = before if before != CHECKING else IDLE, _why(exc)
            return self._changed()
        with self._lock:
            self.check_error, self.checked_at = None, self._now()
            failed_before = before == FAILED and plan is not None and plan.version == self.failed_version
            if plan is None:
                self.state, self.plan, self.error = UP_TO_DATE, None, None
            elif failed_before:  # the error stays until the user tries again
                self.state, self.plan = FAILED, plan
            else:
                self.state, self.plan, self.error = AVAILABLE, plan, None
        return self._changed()

    def announce(self) -> str | None:
        """The release a notification should tell about: an available one
        not told about yet, once (update.json keeps it across restarts)."""
        with self._lock:
            if self.state != AVAILABLE or self.plan is None or self.plan.version == self.announced:
                return None
            self.announced = self.plan.version
        self._changed()
        return self.announced

    # --- installing -------------------------------------------------------------------------

    def request(self) -> bool:
        """The user's click on "Update available": download now (the caller
        runs ``download`` off the main thread). False: nothing to update."""
        with self._lock:
            if self.plan is None or self.state not in (AVAILABLE, FAILED):  # a failed one: after a check
                return False
            self.wanted, self.state, self.error, self.done_bytes = True, DOWNLOADING, None, 0
        self._changed()
        return True

    def download(self) -> dict:
        with self._lock:
            plan = self.plan
            if self.state != DOWNLOADING or plan is None:
                return self.status()
        try:
            staged = self._stage(plan, self._progress)
        except Exception as exc:
            with self._lock:
                self.state, self.error = FAILED, f"Download failed: {_why(exc)}. Palaver {self._current()} stays."
                self.failed_version = plan.version
            return self._changed()
        with self._lock:
            self.staged, self.state = staged, READY
        return self._changed()

    def _progress(self, done: int) -> None:
        with self._lock:
            self.done_bytes = done

    def tick(self) -> bool:
        """Each second on the main thread: swap a downloaded update in when
        Palaver is idle. True: it is applied, the app must quit now."""
        with self._lock:
            if self.state != READY or not self.wanted or self.staged is None:
                return False
            reason = self._busy()
            if reason:
                if reason != self.waiting_for:
                    self.waiting_for = reason
                    self._changed()
                return False
            self.state, self.waiting_for = INSTALLING, None
            staged = self.staged
        try:
            self._apply(staged)
        except NotIdle as exc:  # a call began in between: it is recorded, the update waits
            with self._lock:
                self.state, self.waiting_for = READY, str(exc)
            self._changed()
            return False
        except Exception as exc:
            with self._lock:
                self.state, self.staged = FAILED, None
                self.error = f"Installing failed: {_why(exc)}. Palaver {self._current()} stays."
                self.failed_version = staged.plan.version
            self._changed()
            return False
        self._changed()
        return True

    # --- what it says -----------------------------------------------------------------------

    def _current(self) -> str:
        installed = self._installed()
        return installed.version if installed else "?"

    def status(self) -> dict:
        with self._lock:
            plan = self.plan
            available = None if plan is None else {
                "version": plan.version, "notes": plan.notes, "download_bytes": plan.download_bytes,
                "runtime": plan.runtime is not None, "models": [m.name for m in plan.models]}
            if available is None and self.state == FAILED and self.failed_version:
                available = {"version": self.failed_version, "notes": None, "download_bytes": 0,
                             "runtime": False, "models": []}
            return {
                "state": self.state,
                "current": self._current() if self.state != UNSUPPORTED else None,
                "available": available,
                "done_bytes": self.done_bytes,
                "waiting_for": self.waiting_for,
                "error": self.error,
                "check_error": self.check_error,
                "checked_at": self.checked_at,
                "automatic": self._enabled(),
                "announced": self.announced,
            }

    def _changed(self) -> dict:
        status = self.status()
        try:
            self._save(status)
        except OSError:
            pass
        return status


def _why(exc: Exception) -> str:
    return str(exc).strip() or type(exc).__name__


def menu_title(status: dict) -> str | None:
    """The menu's update line, always there in an installed Palaver (with its
    version, so the menu says which one runs); None from a checkout."""
    state, available = status.get("state"), status.get("available") or {}
    version = available.get("version")
    if state == UNSUPPORTED:
        return None
    if state == CHECKING:
        return "Checking for updates…"
    if state == AVAILABLE:
        return f"Update available ({version})"
    if state == DOWNLOADING:
        total = available.get("download_bytes") or 0
        share = f" {min(99, int(100 * status.get('done_bytes', 0) / total))} %" if total else ""
        return f"Downloading update {version}…{share}"
    if state == READY:
        waiting = status.get("waiting_for")
        return f"Update {version} installs when Palaver is idle ({waiting})" if waiting else f"Installing update {version}…"
    if state == INSTALLING:
        return f"Installing update {version}…"
    if state == FAILED and version:
        return f"Update {version} failed — try again"
    return f"Check for Updates… (Palaver {status.get('current')})" if status.get("current") else "Check for Updates…"


def check_result(status: dict) -> tuple[str, str] | None:
    """What a check the user asked for found, for a notification; None
    while it still runs."""
    state, version = status.get("state"), (status.get("available") or {}).get("version")
    if state == CHECKING:
        return None
    if status.get("check_error"):
        return "Could not check for updates", str(status["check_error"])
    if state in (AVAILABLE, FAILED) and version:
        return f"Palaver {version} is available", "Choose “Update available” in Palaver's menu to install it."
    return "Palaver is up to date", f"Palaver {status.get('current')} is the latest version."


def announcement(version: str) -> tuple[str, str]:
    """The notification an automatic check sends for a new release; a click
    opens the window's Settings at Updates."""
    return f"Palaver {version} is available", "Click to see what's new and install it."


# --- on disk ---------------------------------------------------------------------------------

def installed_now(home: Path | None = None) -> release.Installed | None:
    """The running release: its version and runtime, and the hosted models
    here. None from a checkout (nothing to update)."""
    info = install_layout.bundle_info()
    if not info.get("version"):
        return None
    try:
        runtimes = frozenset(p.name for p in install_layout.runtimes_dir(home).iterdir()
                             if not p.name.startswith(".") and (p / "bin" / "python3").exists())
    except OSError:
        runtimes = frozenset()
    return release.Installed(version=str(info["version"]), runtime_id=info.get("runtime"),
                             models=model_store.installed(home), runtimes=runtimes)


def macos_version() -> str | None:
    return platform.mac_ver()[0] or None


def write_status(status: dict, home: Path | None = None) -> None:
    path = install_layout.update_state_path(home)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(status, indent=2))
    tmp.replace(path)


def read_status(home: Path | None = None) -> dict | None:
    try:
        data = json.loads(install_layout.update_state_path(home).read_text())
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def unpack_runtime(archive: Path, runtime_id: str, home: Path | None = None) -> Path:
    """A runtime archive (one folder named by its id) into runtime/<id>,
    whole or not at all. One that is there already is kept."""
    import tarfile

    root = install_layout.runtimes_dir(home)
    target = root / runtime_id
    if (target / "bin" / "python3").exists():
        return target
    root.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{runtime_id}.", dir=root))
    try:
        with tarfile.open(archive) as tar:
            # AppleDouble "._*" files from macOS tar carry no runtime content: never unpacked.
            members = [m for m in tar.getmembers() if not Path(m.name).name.startswith("._")]
            for member in members:
                parts = Path(member.name).parts
                if not parts or parts[0] != runtime_id or ".." in parts or member.name.startswith("/"):
                    raise release.ManifestError(f"unexpected path in the runtime archive: {member.name}")
                if member.issym() or member.islnk():  # links stay inside the runtime's own folder
                    base = os.path.dirname(member.name) if member.issym() else ""
                    points_to = os.path.normpath(os.path.join(base, member.linkname))
                    if member.linkname.startswith("/") or Path(points_to).parts[:1] != (runtime_id,):
                        raise release.ManifestError(f"a link out of the runtime in its archive: {member.name}")
            tar.extractall(staging, members=members, filter="data")  # its own symlinks (python3 -> python3.13) are kept
        if not (staging / runtime_id / "bin" / "python3").exists():
            raise release.ManifestError("the runtime archive has no bin/python3")
        shutil.rmtree(target, ignore_errors=True)  # a broken one from before
        (staging / runtime_id).rename(target)
        return target
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def runtimes_to_remove(present: list[str], *, current: str, previous: str | None) -> list[str]:
    """Every runtime but the one in use and the one before it (for going back)."""
    keep = {current, previous}
    return sorted(r for r in present if r not in keep and not r.startswith("."))


STALE_STAGING_SECONDS = 3600


def sweep_staging(home: Path | None = None, *, older_than: float = STALE_STAGING_SECONDS) -> list[Path]:
    """Unpackings that never finished (a crash, a lost power): the hidden
    folders next to the runtimes and the models, older than an hour."""
    gone = []
    now = time.time()
    for root in (install_layout.runtimes_dir(home), install_layout.models_dir(home)):
        try:
            entries = list(root.iterdir())
        except OSError:
            continue
        for p in entries:
            try:
                if p.name.startswith(".") and p.is_dir() and now - p.stat().st_mtime > older_than:
                    shutil.rmtree(p, ignore_errors=True)
                    gone.append(p)
            except OSError:
                continue
    return gone


def prune_runtimes(current: str, home: Path | None = None) -> list[str]:
    sweep_staging(home)
    root = install_layout.runtimes_dir(home)
    try:
        previous = (root / ".previous").read_text().strip() or None
        present = [p.name for p in root.iterdir() if p.is_dir()]
    except OSError:
        return []
    gone = runtimes_to_remove(present, current=current, previous=previous)
    for rid in gone:
        shutil.rmtree(root / rid, ignore_errors=True)
    return gone


# The swap, run by /bin/sh after Palaver has quit (it is not Palaver's child:
# it outlives the app). The old app goes aside into previous-app, the new one
# takes its place and opens; once the new one says it started (its
# started-ok mark), the old one goes. If it does not start, or the swap
# fails, the old one comes back, opens, and update.json says why.
_SWAP = """#!/bin/sh
# Palaver's update from {current} to {version}.
target={target}
staged={staged}
keep={keep}
ok={ok}
status={status}
reopen() {{ {open} "$target"; }}
failed() {{ printf '%s\\n' "$1" > "$status"; }}

# The app quits first: wait as long as it takes, a recording is finished on the way.
for pid in {pids}; do
  while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
done
# Anything else still running from this app (its window's server stopping): a little longer.
n=0
while pgrep -f "$target/Contents/MacOS/" >/dev/null 2>&1 && [ "$n" -lt 300 ]; do sleep 0.2; n=$((n + 1)); done

rm -rf "$keep" && mkdir -p "$keep" || {{ failed '{not_replaced}'; reopen; exit 1; }}
if ! mv "$target" "$keep/Palaver.app"; then
  failed '{not_replaced}'; reopen; exit 1
fi
if ! mv "$staged" "$target"; then
  mv "$keep/Palaver.app" "$target"; failed '{not_replaced}'; reopen; exit 1
fi
rm -f "$ok"
reopen
n=0
while [ "$n" -lt {start_ticks} ]; do
  if [ "$(cat "$ok" 2>/dev/null)" = {version_sh} ]; then
    rm -rf "$keep"
    exit 0
  fi
  sleep 0.2; n=$((n + 1))
done
# The new version did not start: the one before comes back. The app itself is ended (the Swift app,
# or the launcher of a version before 0.5), never a worker: they stop with it.
pkill -TERM -f "$target/Contents/MacOS/(palaver-launcher|Palaver)\\$" 2>/dev/null
n=0
while pgrep -f "$target/Contents/MacOS/" >/dev/null 2>&1 && [ "$n" -lt 150 ]; do sleep 0.2; n=$((n + 1)); done
rm -rf "$keep/failed.app"
mv "$target" "$keep/failed.app" && mv "$keep/Palaver.app" "$target" && rm -rf "$keep"
failed '{did_not_start}'
reopen
"""


def _sh(value) -> str:
    return "'" + str(value).replace("'", "'\\''") + "'"


class Installer:
    """Downloads and swaps on disk, under ``home``."""

    def __init__(self, home: Path | None = None, *, download: Callable | None = None,
                 open_command: str = "/usr/bin/open", spawn: Callable | None = None,
                 start_timeout: float = 120.0):
        from . import downloader

        self.home = home or Path.home()
        self._download = download or downloader.download
        self._open = open_command
        self._start_timeout = start_timeout  # for the new version's started-ok mark
        self._spawn = spawn or (lambda argv: subprocess.Popen(argv, start_new_session=True,
                                                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))

    @property
    def updates_dir(self) -> Path:
        return install_layout.support_dir(self.home) / "updates"

    def stage(self, plan: release.Plan, progress: Callable[[int], None] = lambda n: None) -> Staged:
        work = self.updates_dir
        shutil.rmtree(work, ignore_errors=True)
        work.mkdir(parents=True)
        done = 0

        def fetch(asset: release.Asset) -> Path:
            nonlocal done
            base = done
            path = self._download(asset, work / (asset.name + ".part"), on_progress=lambda n: progress(base + n))
            done += asset.size
            return path

        try:
            if plan.runtime is not None:  # a runtime is used by its id only: it may go in now
                archive = fetch(plan.runtime)
                unpack_runtime(archive, plan.runtime_id, self.home)
                archive.unlink()
            models = [(m, fetch(m.asset)) for m in plan.models]
            app = self._unpack_app(fetch(plan.app), work, plan)
        except Exception:
            shutil.rmtree(work, ignore_errors=True)
            raise
        return Staged(plan, app, models)

    def _unpack_app(self, archive: Path, work: Path, plan: release.Plan) -> Path:
        out = work / "app"
        subprocess.run(["/usr/bin/ditto", "-xk", str(archive), str(out)], check=True, capture_output=True)
        archive.unlink()
        app = out / install_layout.APP_NAME
        info = install_layout.bundle_info(app)
        if info.get("version") != plan.version or info.get("runtime") != plan.runtime_id:
            raise release.ManifestError(f"the downloaded app is not Palaver {plan.version}")
        subprocess.run(["/usr/bin/xattr", "-dr", "com.apple.quarantine", str(app)], capture_output=True)
        return app

    def apply(self, staged: Staged, *, wait_for: list[int] = (),
              still_busy: Callable[[], str | None] = lambda: None) -> None:
        """The models in now (Palaver is idle), the app by the swap script
        once the processes in ``wait_for`` (this app) have quit. Raises
        NotIdle when ``still_busy()``, asked last, says Palaver got busy:
        then no swap starts."""
        script = self.prepare(staged, wait_for=wait_for, still_busy=still_busy)
        reason = still_busy()  # asked last: a call that began meanwhile is recorded, not quit
        if reason:
            raise NotIdle(reason)
        self.commit(staged)
        self.launch(script)

    def prepare(self, staged: Staged, *, wait_for: list[int] = (),
                still_busy: Callable[[], str | None] = lambda: None) -> Path:
        """The first half of ``apply``: the models in, the swap script written (its path).
        The native app asks the idle gate between this and ``commit``."""
        reason = still_busy()
        if reason:
            raise NotIdle(reason)
        for model, archive in staged.models:
            model_store.install_archive(archive, name=model.name, version=model.version, home=self.home)
        plan = staged.plan
        current = install_layout.bundle_info()
        target = install_layout.bundle() or install_layout.app_path(self.home)  # the bundle that runs

        def failure(error: str) -> str:
            return json.dumps({"state": FAILED, "from_swap": True, "error": error,
                               "available": {"version": plan.version}}).replace("'", "")

        old = current.get("version") or "the version before"
        script = _SWAP.format(
            current=old, version=plan.version, version_sh=_sh(plan.version),
            pids=" ".join(str(int(p)) for p in wait_for), target=_sh(target), staged=_sh(staged.app),
            keep=_sh(install_layout.previous_app_dir(self.home)), ok=_sh(install_layout.started_ok_path(self.home)),
            status=_sh(install_layout.update_state_path(self.home)), open=self._open,
            start_ticks=max(1, int(self._start_timeout / 0.2)),
            not_replaced=failure(f"Palaver {plan.version} could not replace the app; {old} stays."),
            did_not_start=failure(f"Palaver {plan.version} did not start; {old} is back."))
        path = self.updates_dir / "swap.sh"
        path.write_text(script)
        return path

    def commit(self, staged: Staged) -> None:
        """The swap is certain now: the permissions are asked again at the restart, the runtime
        in use is remembered for going back."""
        current = install_layout.bundle_info()
        plan = staged.plan
        # A new build is a new signature to macOS: the restarted app asks for
        # its permissions at once, while idle, not in the middle of the next call.
        install_layout.permissions_marker(self.home).unlink(missing_ok=True)
        if current.get("runtime") and current["runtime"] != plan.runtime_id:
            root = install_layout.runtimes_dir(self.home)
            root.mkdir(parents=True, exist_ok=True)
            (root / ".previous").write_text(current["runtime"] + "\n")

    def launch(self, script: Path) -> None:
        self._spawn(["/bin/sh", str(script)])
