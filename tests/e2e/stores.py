"""The files the end-to-end tests set up and check, written and read here directly: a meeting's
folder, the stores in the test's XDG config, the app's files in its home. The formats are the
app's (palaver-server reads and writes the same files); nothing here imports Palaver, which is
the Swift app the tests drive.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import subprocess
import tempfile
import threading
import time
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path


def config_dir() -> Path:
    """The stores' folder: $XDG_CONFIG_HOME/palaver (the test's temporary one, tests/conftest.py)."""
    return Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "palaver"


def support_dir(home: Path) -> Path:
    """The app's Application Support folder in ``home``."""
    return home / "Library" / "Application Support" / "palaver"


def _write_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def _read_json(path: Path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


# --- a meeting's folder -------------------------------------------------------------------------------

class RecordingPaths:
    """The files of one recording folder the tests touch."""

    def __init__(self, folder: Path):
        self.folder = Path(folder)
        f = self.folder
        self.mic_wav, self.system_wav = f / "mic.wav", f / "system.wav"
        self.meta, self.system_turns = f / "meta.json", f / "system_turns.json"
        self.transcript_json, self.notes = f / "transcript.json", f / "notes.json"
        self.speakers, self.speakers_inferred = f / "speakers.json", f / "speakers_inferred.json"
        self.calendar, self.live, self.stream = f / "calendar.json", f / "live.json", f / "stream.json"
        self.session_log, self.failed = f / "session.log", f / "failed.json"


def utterance(speaker: str, start: float, end: float, text: str, unsure: tuple[str, ...] = ()) -> dict:
    """A line of transcript.json."""
    line = {"speaker": speaker, "start": start, "end": end, "text": text}
    if unsure:
        line["unsure"] = list(unsure)
    return line


def transcript_hash(lines: list[dict]) -> str:
    """notes.json's transcript_hash: changes with the words, not with the names given to speakers."""
    h = hashlib.sha256()
    for u in lines:
        h.update(f"{u.get('label') or u['speaker']}\t{u['start']:.2f}\t{u['text']}\n".encode())
    return h.hexdigest()[:16]


def save_notes(paths: RecordingPaths, notes: dict) -> None:
    _write_atomic(paths.notes, json.dumps(notes, indent=2, ensure_ascii=False))


def load_notes(paths: RecordingPaths) -> dict | None:
    return _read_json(paths.notes, None)


# Why a meeting was not transcribed (failed.json).
MODELS = "models"  # waits for its models
ERROR = "error"  # failed


def mark_failed(paths: RecordingPaths, reason: str, *, missing: list[str] = (), error: str | None = None) -> None:
    data = {"reason": reason, "at": datetime.now().astimezone().isoformat(timespec="seconds"),
            "missing": list(missing), "error": error}
    _write_atomic(paths.failed, json.dumps(data, indent=2))


def clear_failed(paths: RecordingPaths) -> None:
    paths.failed.unlink(missing_ok=True)


# --- the language model's runs the app starts (<recordings>/.jobs) ------------------------------------

def jobs_root(output_dir: Path) -> Path:
    return Path(output_dir) / ".jobs"


def launch_job(root: Path, kind: str, key: str, argv: list[str], *, env: dict | None = None) -> int:
    """Starts ``argv`` in a session of its own and records it as the app's HelperJobs do (``<kind>-<key>.json``,
    its output in ``.log``); the record says "done" once it ended."""
    root.mkdir(parents=True, exist_ok=True)
    record, log = root / f"{kind}-{key}.json", root / f"{kind}-{key}.log"
    with log.open("wb") as out:
        proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT,
                                start_new_session=True, env=env)
    started = time.time()
    _write_atomic(record, json.dumps({"kind": kind, "key": key, "pid": proc.pid, "state": "running", "started": started}))

    def reap():
        code = proc.wait()
        _write_atomic(record, json.dumps({"kind": kind, "key": key, "pid": proc.pid, "state": "done", "started": started,
                                          "returncode": code, "ended": time.time(), "stale": False}))

    threading.Thread(target=reap, name=f"{kind}-job", daemon=True).start()
    return proc.pid


# --- the stores (the test's XDG config) ---------------------------------------------------------------

@contextmanager
def _locked(path: Path):
    """The lock file palaver-server takes around a store's change (`<file>.lock`, flock)."""
    lock = path.with_name(path.name + ".lock")
    lock.parent.mkdir(parents=True, exist_ok=True)
    with open(lock, "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def settings_path() -> Path:
    return config_dir() / "settings.json"


def read_settings() -> dict:
    data = _read_json(settings_path(), {})
    return data if isinstance(data, dict) else {}


def update_settings(changes: dict) -> None:
    """Merged into settings.json as it is (what is not there keeps following config.toml)."""
    with _locked(settings_path()):
        _write_atomic(settings_path(), json.dumps({**read_settings(), **changes}, indent=2) + "\n")


PENDING = "pending"  # an engine not chosen yet (settings.json "engines")


def add_project(name: str, meetings: dict[str, dict] | None = None) -> str:
    """A project in projects.json, with ``meetings`` (id → {"by", "why", "confidence"?}) in it; its id."""
    path = config_dir() / "projects.json"
    with _locked(path):
        data = _read_json(path, {})
        data.setdefault("projects", {})
        data.setdefault("meetings", {})
        pid = hashlib.sha256(name.encode()).hexdigest()[:8]
        data["projects"][pid] = {"name": name, "description": "", "description_by": None}
        for meeting, how in (meetings or {}).items():
            entry = data["meetings"].setdefault(meeting, {"assigned": {}, "rejected": []})
            entry["assigned"][pid] = {"by": "you", "why": "", **how}
        _write_atomic(path, json.dumps(data, indent=2, ensure_ascii=False))
    return pid


def attributions_path() -> Path:
    """What corrections taught about calendar events (attributions.json)."""
    return config_dir() / "attributions.json"


def reject_event(series: str, title: str, meetings: list[str]) -> None:
    """The user said these recordings are not this event series (by its uid, else its title)."""
    path = attributions_path()
    with _locked(path):
        data = _read_json(path, {})
        entry = data.setdefault("events", {}).setdefault(series, {"rejected": [], "chosen": []})
        entry["title"] = title
        entry["rejected"] += [m for m in meetings if m not in entry["rejected"]]
        _write_atomic(path, json.dumps(data, indent=2, ensure_ascii=False))


def rejected_events() -> dict[str, list[str]]:
    """series → the recordings said not to be it."""
    return {series: e.get("rejected", []) for series, e in _read_json(attributions_path(), {}).get("events", {}).items()}


def prepared_notes_folder(key: str) -> Path:
    """Where the notes for a calendar event (``<uid>|<day>``) wait until it is recorded."""
    return config_dir() / "prepared-notes" / hashlib.sha256(key.encode()).hexdigest()[:24]


def save_my_notes(folder: Path, paragraphs: list[dict]) -> None:
    """my-notes.json: paragraphs {"text", "at"}."""
    _write_atomic(Path(folder) / "my-notes.json", json.dumps(paragraphs, indent=1, ensure_ascii=False))


def event(title: str, start: datetime, end: datetime, attendees: list[dict] = (), uid: str = "") -> dict:
    """A calendar event as calendar.json and the test probe's calendar hold it."""
    return {"title": title, "start": start.isoformat(), "end": end.isoformat(), "attendees": list(attendees),
            "all_day": False, "source": "", "uid": uid, "series": False, "location": ""}


def attendee(name: str, email: str | None = None, *, is_self: bool = False) -> dict:
    return {"name": name, "email": email, "organizer": False, "response": "unknown", "is_self": is_self,
            "is_room": False}


# --- the app's files in its home ----------------------------------------------------------------------

def write_update_status(status: dict, home: Path) -> None:
    """update.json as the app's updater writes it."""
    _write_atomic(support_dir(home) / "update.json", json.dumps(status, indent=2))


def read_usage(path: Path) -> list[dict]:
    """usage.jsonl's events, skipping lines that are not one."""
    out = []
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return []
    for line in text.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict) and isinstance(row.get("kind"), str) and isinstance(row.get("ts"), str):
            out.append(row)
    return out


GEMMA = "mlx-community/gemma-4-12B-it-OptiQ-4bit"  # the local notes model the setup offers
QWEN = "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"  # a notes model no longer offered
NOTIFICATIONS_SETTINGS_URL = ("x-apple.systempreferences:com.apple.Notifications-Settings.extension"
                              "?id=com.kenodressel.meeting-transcribe")
