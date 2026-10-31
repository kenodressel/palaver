"""The language model's jobs the Meetings window starts — writing a
meeting's notes, sorting or describing projects — recorded on disk with
their pid (#57), in ``<recordings>/.jobs/``.

The menu bar app starts the helper (``launch``), so it is the app's
descendant (the memory watchdog counts it during calls) and outlives a
restart of the window's server. Its record says it runs until it exits,
then its exit code. A restarted server reads the records: it shows a
running job again, never starts a second one, and finishes what the old
server could not (a sort's undo snapshot, ``pending_undo``). A record
whose pid is gone without an exit code (the app quit) is stale.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Callable, Iterable

from .paths import is_recording_folder_name

KINDS = ("notes", "projects")
_KEY = re.compile(r"[A-Za-z0-9_.-]{1,80}")
_PROJECT_ID = re.compile(r"[0-9a-f]{1,64}")
POLL_SECONDS = 0.2


def jobs_root(output_dir: Path) -> Path:
    return Path(output_dir) / ".jobs"


def _alive(pid) -> bool:
    try:
        os.kill(int(pid), 0)
    except (TypeError, ValueError, ProcessLookupError):
        return False
    except PermissionError:
        return True
    return True


def _path(root: Path, kind: str, key: str) -> Path:
    if kind not in KINDS or not _KEY.fullmatch(key) or key.startswith("."):
        raise ValueError(f"not a job: {kind} {key}")
    return root / f"{kind}-{key}.json"


def _write_json(target: Path, data: dict) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=target.parent, prefix=target.name + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f)
        os.replace(tmp, target)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def _read_json(target: Path) -> dict | None:
    try:
        data = json.loads(target.read_text())
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def write(root: Path, job: dict) -> None:
    _write_json(_path(root, job["kind"], job["key"]), job)


def read(root: Path, kind: str, key: str, *, alive: Callable[[int], bool] = _alive) -> dict | None:
    """The job's record; ``stale`` when it says running but its pid is gone."""
    job = _read_json(_path(root, kind, key))
    if job is None:
        return None
    if job.get("state") == "running" and not alive(job.get("pid")):
        job["stale"] = True
    return job


def log_path(root: Path, kind: str, key: str) -> Path:
    """What the helper printed, its last run's (kept after the record, for the
    window's error and a problem report)."""
    return _path(root, kind, key).with_suffix(".log")


def last_error(root: Path, kind: str, key: str) -> str | None:
    """The line that says why the helper's last run failed: its last
    "error: …" line, else the exception a traceback ended with."""
    try:
        lines = [x.strip() for x in log_path(root, kind, key).read_text(errors="replace").splitlines() if x.strip()]
    except (OSError, ValueError):
        return None
    said = [x for x in lines if x.lower().startswith("error:")]
    if said:
        return said[-1][len("error:"):].strip()[:300] or None
    if any(x.startswith("Traceback") for x in lines):
        return lines[-1][:300]
    return None


def clear(root: Path, kind: str, key: str) -> None:
    _path(root, kind, key).unlink(missing_ok=True)


def running(root: Path, *, alive: Callable[[int], bool] = _alive) -> list[dict]:
    """The jobs running now, oldest first."""
    out = []
    for f in sorted(Path(root).glob("*.json")) if Path(root).is_dir() else []:
        kind, _, key = f.stem.partition("-")
        if kind not in KINDS:
            continue
        job = read(root, kind, key, alive=alive)
        if job and job.get("state") == "running" and not job.get("stale"):
            out.append(job)
    return sorted(out, key=lambda j: j.get("started") or 0)


def launch(root: Path, kind: str, key: str, argv: list[str], *, popen=subprocess.Popen) -> int:
    """Start the helper ``argv`` in its own process group and record it;
    the pid of the job already running under ``kind``/``key`` instead, if
    there is one (never a second run)."""
    with _launch_lock:
        job = read(root, kind, key)
        if job and job.get("state") == "running" and not job.get("stale"):
            return int(job["pid"])
        log = log_path(root, kind, key)  # a bad key fails before anything starts
        log.parent.mkdir(parents=True, exist_ok=True)
        with log.open("wb") as out:
            proc = popen(argv, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT,
                         start_new_session=True)
        write(root, {"kind": kind, "key": key, "pid": proc.pid, "state": "running", "started": time.time()})

    def reap():
        code = proc.wait()
        job = read(root, kind, key) or {"kind": kind, "key": key, "pid": proc.pid, "started": None}
        if job.get("pid") == proc.pid:
            write(root, {**job, "state": "done", "returncode": code, "ended": time.time(), "stale": False})

    threading.Thread(target=reap, name=f"{kind}-helper", daemon=True).start()
    return proc.pid


_launch_lock = threading.Lock()


def wait(root: Path, kind: str, key: str, *, poll: float = POLL_SECONDS,
         alive: Callable[[int], bool] = _alive) -> dict:
    """The job's record once it is no longer running (done, stale or gone)."""
    while True:
        job = read(root, kind, key, alive=alive)
        if job is None:
            return {"kind": kind, "key": key, "state": "gone"}
        if job.get("state") != "running" or job.get("stale"):
            return job
        time.sleep(poll)


def helper_argv(kind: str, args: Iterable[str], cli_options: Iterable[str], *, output_dir: Path) -> list[str]:
    """The command of a helper the window may have the app start: `palaver
    notes <a meeting> --force` or `palaver projects --no-wait suggest |
    describe <id>`; ValueError for anything else."""
    from .daemon import TASKPOLICY

    args = [str(a) for a in args]
    if kind == "notes":
        if len(args) != 2 or args[1] != "--force":
            raise ValueError("not a notes helper")
        folder = Path(args[0])
        if (folder.parent.resolve() != Path(output_dir).resolve() or not is_recording_folder_name(folder.name)):
            raise ValueError("not a meeting's folder")
    elif kind == "projects":
        if not (args in (["--no-wait", "suggest"],)
                or (len(args) == 3 and args[:2] == ["--no-wait", "describe"] and _PROJECT_ID.fullmatch(args[2]))):
            raise ValueError("not a projects helper")
    else:
        raise ValueError(f"not a helper: {kind}")
    argv = [sys.executable, "-m", "palaver", *cli_options, "--no-notify", kind, *args]
    if TASKPOLICY.exists():
        argv = [str(TASKPOLICY), "-c", "utility", *argv]
    return argv


# --- a sort's undo snapshot, finished by whichever server sees the job end --------------

def _undo_path(root: Path, token: str) -> Path:
    if not _KEY.fullmatch(token):
        raise ValueError("not an undo token")
    return root / "undo" / f"{token}.json"


def pending_undo(root: Path, token: str, label: str, *, owner: int | None = None) -> None:
    """The snapshot ``token`` was taken for a model change about to run."""
    _write_json(_undo_path(root, token), {"token": token, "label": label, "owner": owner or os.getpid(),
                                         "state": "pending"})


def _undos(root: Path, state: str) -> list[dict]:
    folder = Path(root) / "undo"
    if not folder.is_dir():
        return []
    out = []
    for f in sorted(folder.glob("*.json")):
        u = _read_json(f)
        if u and u.get("state") == state:
            out.append(u)
    return out


def pending_undos(root: Path) -> list[dict]:
    return _undos(root, "pending")


def finish_undo(root: Path, token: str, *, ok: bool, told: bool = False) -> None:
    """The change is done (``ok``) or rolled back. ``told``: the page got the
    token in its answer already; else it is kept for the page to fetch."""
    path = _undo_path(root, token)
    if told:
        path.unlink(missing_ok=True)
        return
    u = _read_json(path) or {"token": token, "label": ""}
    _write_json(path, {"token": token, "label": u.get("label", ""), "ok": ok, "state": "finished"})


def finished_undos(root: Path) -> list[dict]:
    """Model changes finished after the server that ran them was gone: the
    page puts their undo in its history."""
    return [{"token": u["token"], "label": u.get("label", ""), "ok": bool(u.get("ok"))}
            for u in _undos(root, "finished")]


def seen(root: Path, token: str) -> None:
    _undo_path(root, token).unlink(missing_ok=True)
