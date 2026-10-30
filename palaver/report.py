"""Report a Problem (#59): one zip with everything the maintainer needs to
analyse a tester's problem (or wish), so nobody has to ask back.

Testing is internal: completeness wins over privacy. The one exception is
secrets. Settings go in with every key that names a token, key, secret or
password replaced by "(set)" / "(not set)", and every secret value the
config holds is scrubbed from every text file before it goes into the zip.

The window (an API call in its server) and `palaver report create` build
the same zip; `report open` and `report usage` are the maintainer's side.
Everything that asks this Mac something (doctor, devices, models, git)
goes through a ``Probe``; each answer that fails says so in the zip
instead of failing the report.
"""

from __future__ import annotations

import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import tomllib
import zipfile
from dataclasses import asdict, dataclass, is_dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Iterable

from . import __version__, runlog, usage
from .paths import is_recording_folder_name

DESKTOP = Path.home() / "Desktop"
LOG_DIR = runlog.LOG_DIR
CRASH_DIR = Path.home() / "Library" / "Logs" / "DiagnosticReports"
CRASH_DAYS = 30
TIMELINE_DAYS = 7
OPEN_TIMELINE = 50  # lines `report open` shows
# Every meeting's small files: what happened while recording and processing it.
SMALL_FILES = ("session.log", "meta.json", "audio_problems.json", "stream.json", "calendar.json")
AUDIO_SUFFIXES = (".wav", ".wav.part", ".m4a", ".mp3", ".flac", ".caf", ".aif", ".aiff")
SECRET_WORDS = ("token", "key", "secret", "password")
SCRUBBED = b"(secret removed)"
MAX_TEXT = 20_000


@dataclass(frozen=True)
class Form:
    """What the tester said: a bug or a wish, what happened, the meeting it
    is about (None: none) and whether that meeting's audio goes in."""

    kind: str = "bug"
    text: str = ""
    meeting: str | None = None
    audio: bool = False

    @classmethod
    def from_dict(cls, body: dict) -> "Form":
        kind = body.get("kind", "bug")
        if kind not in ("bug", "wish"):
            raise ValueError("kind is bug or wish")
        text = body.get("text", "")
        meeting = body.get("meeting")
        if not isinstance(text, str) or not isinstance(meeting, (str, type(None))):
            raise ValueError("text and meeting are text")
        if not isinstance(body.get("audio", False), bool):
            raise ValueError("audio is true or false")
        return cls(kind, text[:MAX_TEXT], meeting or None, bool(body.get("audio", False)))


# --- secrets --------------------------------------------------------------------------

def is_secret(name: str) -> bool:
    return any(word in str(name).lower() for word in SECRET_WORDS)


def redact(value, secrets: list[str] | None = None):
    """``value`` with every secret-named key's value replaced by "(set)" or
    "(not set)"; the values taken out go into ``secrets``."""
    if is_dataclass(value) and not isinstance(value, type):
        value = asdict(value)
    if isinstance(value, dict):
        out = {}
        for k, v in value.items():
            if is_secret(k):
                if secrets is not None:
                    secrets.extend(_strings(v))
                out[k] = "(set)" if v not in (None, "", {}, []) else "(not set)"
            else:
                out[k] = redact(v, secrets)
        return out
    if isinstance(value, (list, tuple)):
        return [redact(v, secrets) for v in value]
    if isinstance(value, Path):
        return str(value)
    return value


def _strings(value) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        return [s for v in value.values() for s in _strings(v)]
    if isinstance(value, (list, tuple)):
        return [s for v in value for s in _strings(v)]
    return []


def settings_snapshot(config_path: Path) -> tuple[dict, list[str]]:
    """The settings as Palaver reads them (the config loader), config.toml
    as written and settings.json, all redacted; and the secret values."""
    from . import settings
    from .config import load_config

    secrets: list[str] = []
    out: dict = {"config_path": str(config_path)}
    try:
        out["config"] = redact(load_config(config_path), secrets)
    except Exception as exc:
        out["config_error"] = f"{type(exc).__name__}: {exc}"
    try:
        with open(config_path, "rb") as f:
            out["config_toml"] = redact(tomllib.load(f), secrets)
    except Exception as exc:
        out["config_toml_error"] = f"{type(exc).__name__}: {exc}"
    out["settings_json"] = redact(settings.read_raw(), secrets)
    env = {name: "(set)" for name in os.environ if is_secret(name) and name.isupper()}
    secrets += [os.environ[name] for name in env]
    out["secret_environment"] = dict(sorted(env.items()))
    return out, sorted({s for s in secrets if isinstance(s, str) and len(s) >= 6}, key=len, reverse=True)


def scrub(data: bytes, secrets: Iterable[str]) -> bytes:
    for secret in secrets:
        data = data.replace(secret.encode(), SCRUBBED)
    return data


# --- this Mac ---------------------------------------------------------------------------

def _run(argv: list[str], timeout: float = 20) -> str:
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout).stdout.strip()


def _safely(fn, *args):
    """``fn(*args)``, or what went wrong: one question failing never fails the report."""
    try:
        return fn(*args)
    except Exception as exc:
        return {"error": f"{type(exc).__name__}: {exc}"}


class Probe:
    """What a report asks this Mac."""

    def doctor(self, config_path: Path) -> str:
        from . import doctor

        checks = doctor.run_checks(config_path=config_path, offline=False)
        failed = sum(c.status == "fail" for c in checks)
        return doctor.format_report(checks) + (f"\n\n{failed} problem(s) to fix." if failed else "\n\nAll set.")

    def hardware(self) -> dict:
        mem = int(_run(["sysctl", "-n", "hw.memsize"]) or 0)
        return {"chip": _run(["sysctl", "-n", "machdep.cpu.brand_string"]), "model": _run(["sysctl", "-n", "hw.model"]),
                "ram_gb": round(mem / 1024**3, 1), "macos": platform.mac_ver()[0],
                "macos_build": _run(["sw_vers", "-buildVersion"]), "arch": platform.machine()}

    def models(self) -> list[dict]:
        from huggingface_hub import scan_cache_dir

        info = scan_cache_dir()
        return [{"repo": r.repo_id, "type": r.repo_type, "gb": round(r.size_on_disk / 1024**3, 2),
                 "files": r.nb_files, "last_modified": datetime.fromtimestamp(r.last_modified).isoformat(timespec="seconds")}
                for r in sorted(info.repos, key=lambda r: r.repo_id)]

    def audio_devices(self) -> dict:
        from . import doctor

        defaults = _safely(doctor._default_devices)
        try:
            listed = json.loads(_run(["system_profiler", "SPAudioDataType", "-json"], timeout=30) or "{}")
        except ValueError:
            listed = {}
        return {"default": defaults, "system_profiler": listed}

    def permissions(self, output_dir: Path) -> dict:
        from . import doctor
        from .calendar_eventkit import has_access

        return {"microphone": _safely(lambda: asdict(doctor.check_microphone())),
                "system_audio": _safely(lambda: asdict(doctor.check_system_audio(output_dir))),
                "calendar": _safely(has_access)}

    def memory(self, config_path: Path) -> dict:
        from .config import load_config
        from .daemon import available_memory_gb
        from .memory import budgets_for

        out = {"available_gb": round(available_memory_gb(), 1)}
        out["budgets_gb"] = _safely(lambda: asdict(budgets_for(load_config(config_path))))
        return out

    def processes(self) -> str:
        rows = _run(["ps", "-axo", "pid,ppid,rss,etime,command"]).splitlines()
        return "\n".join(rows[:1] + [r for r in rows[1:] if "palaver" in r.lower()])

    def git(self) -> dict:
        return runlog.git_info()


class QuietProbe(Probe):
    """The probe of the tests: fixed answers, nothing asked of the Mac."""

    def doctor(self, config_path: Path) -> str:
        return "✓ macOS: (not asked in tests)"

    def hardware(self) -> dict:
        return {"chip": "Test chip", "model": "Mac", "ram_gb": 16.0, "macos": "15.0", "macos_build": "", "arch": "arm64"}

    def models(self) -> list[dict]:
        return []

    def audio_devices(self) -> dict:
        return {"default": {"input": ["Test Mic", 48000.0], "output": ["Test Speakers", 48000.0]}}

    def permissions(self, output_dir: Path) -> dict:
        return {"microphone": {"status": "ok"}}

    def memory(self, config_path: Path) -> dict:
        return {"available_gb": 8.0}

    def processes(self) -> str:
        return ""

    def git(self) -> dict:
        return {}


def _disk(path: Path) -> dict:
    probe = path if path.exists() else Path.home()
    d = shutil.disk_usage(probe)
    return {"path": str(probe), "free_gb": round(d.free / 1024**3, 1), "total_gb": round(d.total / 1024**3, 1)}


def _daemon() -> tuple[str, dict | None]:
    from . import daemon

    try:
        state = json.loads(daemon.STATE_PATH.read_text())
    except (OSError, ValueError):
        state = None
    return daemon.read_status(), state


# --- the timeline --------------------------------------------------------------------------

_LEVELS = ("WARNING", "ERROR", "CRITICAL")
_PLAIN_PROBLEM = re.compile(r"(^|\b)(warning|error|traceback|exception|failed)\b", re.I)
_QUIET_FIELDS = {"ts", "level", "logger", "event", "message", "argv", "python", "pid", "traceback"}


def _parse_ts(text) -> datetime | None:
    try:
        ts = datetime.fromisoformat(str(text))
    except ValueError:
        return None
    return ts if ts.tzinfo else ts.astimezone()


def _fields_text(row: dict) -> str:
    parts = [f"{k}={json.dumps(v, ensure_ascii=False, default=str) if not isinstance(v, str) else v}"
             for k, v in row.items() if k not in _QUIET_FIELDS]
    return " ".join(parts)


def _last_line(traceback_text: str) -> str:
    lines = [line for line in str(traceback_text).splitlines() if line.strip()]
    return lines[-1].strip() if lines else ""


def timeline_entries(source: str, text: str, since: datetime) -> list[tuple[datetime, str, str, str]]:
    """(when, level, source, text) of a log's warnings, errors and events
    since ``since``. Plain lines (a helper's output in daemon.log, app.log)
    that look like a problem take the time of the JSON line before them."""
    out = []
    last: datetime | None = None
    crash_head: tuple[datetime, str] | None = None
    crash_lines: list[str] = []

    def close_crash():
        if crash_head:
            out.append((crash_head[0], "CRASH", source, f"{crash_head[1]}: {_last_line(chr(10).join(crash_lines))}"))

    for line in text.splitlines():
        if line.startswith("=== "):  # crashes.log: "=== <ts> <where> pid …", then the traceback
            close_crash()
            parts = line[4:].split(" ", 1)
            ts = _parse_ts(parts[0])
            crash_head, crash_lines = ((ts, parts[1] if len(parts) > 1 else "") if ts else None), []
            if ts:
                last = ts
            continue
        if crash_head is not None:
            crash_lines.append(line)
            continue
        row = None
        if line.startswith("{"):
            try:
                row = json.loads(line)
            except ValueError:
                row = None
        if isinstance(row, dict) and row.get("ts"):
            ts = _parse_ts(row["ts"])
            if ts is None:
                continue
            last = ts
            level = str(row.get("level") or "INFO")
            if row.get("event"):
                body = f"{row['event']} {_fields_text(row)}".strip()
                out.append((ts, "EVENT" if level not in _LEVELS else level, source, body))
            elif level in _LEVELS:
                body = f"{row.get('logger', '')}: {row.get('message', '')}"
                if row.get("traceback"):
                    body += f" ↳ {_last_line(row['traceback'])}"
                out.append((ts, level, source, body))
        elif last is not None and _PLAIN_PROBLEM.search(line):
            out.append((last, "OUTPUT", source, f"≈ {line.strip()}"))
    close_crash()
    return [e for e in out if e[0] >= since]


def collapse_repeats(lines: list[str]) -> list[str]:
    """Timeline lines with a run of the same message (a poll failing every
    10 s) as its first line, "×N until <time>": the rest stays readable."""
    out: list[str] = []
    run_key, count, last_time = None, 0, ""
    for line in lines:
        key = line[21:]  # after "YYYY-MM-DD HH:MM:SS  "
        if key == run_key:
            count += 1
            last_time = line[11:19]
            continue
        if count > 1:
            out[-1] += f"  (×{count}, until {last_time})"
        out.append(line)
        run_key, count = key, 1
    if count > 1:
        out[-1] += f"  (×{count}, until {last_time})"
    return out


def timeline(sources: list[tuple[str, str]], since: datetime) -> list[str]:
    """Every source's entries, merged and sorted by time, each line once
    (a recording's lines are in its session.log and in daemon.log)."""
    seen, entries = set(), []
    for source, text in sources:
        for e in timeline_entries(source, text, since):
            key = (e[0], e[1], e[3])
            if key not in seen:
                seen.add(key)
                entries.append(e)
    entries.sort(key=lambda e: e[0])
    return [f"{when.strftime('%Y-%m-%d %H:%M:%S')}  {level:<8} {source:<36} {body[:600]}"
            for when, level, source, body in entries]


# --- building the zip -------------------------------------------------------------------------

class _Zip:
    """The zip being written, and its manifest; text goes in scrubbed of secrets."""

    def __init__(self, f, secrets: list[str]):
        self.zip = zipfile.ZipFile(f, "w", zipfile.ZIP_DEFLATED, allowZip64=True)
        self.secrets = secrets
        self.manifest: list[tuple[str, int, str]] = []
        self.names: set[str] = set()

    def add_bytes(self, arcname: str, data: bytes, what: str) -> None:
        if arcname in self.names:
            return
        data = scrub(data, self.secrets)
        self.zip.writestr(arcname, data)
        self.names.add(arcname)
        self.manifest.append((arcname, len(data), what))

    def add_text(self, arcname: str, text: str, what: str) -> None:
        self.add_bytes(arcname, text.encode(), what)

    def add_json(self, arcname: str, data, what: str) -> None:
        self.add_text(arcname, json.dumps(data, indent=2, ensure_ascii=False, default=str) + "\n", what)

    def add_file(self, arcname: str, path: Path, what: str, *, audio: bool = False) -> None:
        try:
            if audio:  # large and binary: streamed, stored as it is
                if arcname in self.names:
                    return
                self.zip.write(path, arcname, compress_type=zipfile.ZIP_STORED)
                self.names.add(arcname)
                self.manifest.append((arcname, path.stat().st_size, what))
            else:
                self.add_bytes(arcname, path.read_bytes(), what)
        except OSError as exc:
            self.manifest.append((arcname, 0, f"{what} — not readable: {exc}"))


def is_audio(path: Path) -> bool:
    return path.name.lower().endswith(AUDIO_SUFFIXES)


def _meeting_folders(output_dir: Path) -> list[Path]:
    try:
        return sorted(p for p in output_dir.iterdir() if p.is_dir() and is_recording_folder_name(p.name))
    except OSError:
        return []


def latest_meeting(output_dir: Path) -> str | None:
    folders = _meeting_folders(output_dir)
    return folders[-1].name if folders else None


def _listing(folders: list[Path]) -> str:
    lines = []
    for folder in folders:
        lines.append(f"{folder.name}/")
        for p in sorted(folder.rglob("*")):
            if p.is_file():
                try:
                    size = p.stat().st_size
                except OSError:
                    size = -1
                lines.append(f"  {p.relative_to(folder)}  {size:,} B")
    return "\n".join(lines) + "\n"


def _crash_reports(now: datetime) -> list[Path]:
    """macOS crash reports of Palaver's processes from the last CRASH_DAYS:
    named after it, or a Python's that mentions it."""
    since = (now - timedelta(days=CRASH_DAYS)).timestamp()
    found = []
    try:
        candidates = [p for p in CRASH_DIR.iterdir() if p.is_file()]
    except OSError:
        return []
    for p in sorted(candidates):
        try:
            if p.stat().st_mtime < since:
                continue
            if "palaver" in p.name.lower() or b"palaver" in p.read_bytes().lower():
                found.append(p)
        except OSError:
            continue
    return found


def config_path_from(cli_options: list[str]) -> Path:
    """The config.toml the app was started with (its --config), else the default."""
    from .config import default_config_path

    options = list(cli_options)
    if "--config" in options and options.index("--config") + 1 < len(options):
        return Path(options[options.index("--config") + 1]).expanduser()
    return default_config_path()


def output_dir_for(config_path: Path) -> Path:
    """The recordings folder, also when config.toml does not load (a
    missing token is a problem worth reporting, not a reason not to)."""
    from .config import load_config

    try:
        return load_config(config_path).output_dir
    except Exception:
        pass
    try:
        with open(config_path, "rb") as f:
            folder = tomllib.load(f).get("recording", {}).get("output_dir")
        if isinstance(folder, str):
            return Path(folder).expanduser()
    except Exception:
        pass
    return Path.home() / "Meetings" / "Recordings"


def report_name(now: datetime) -> str:
    return f"Palaver report {now:%Y-%m-%d %H-%M}.zip"


def _target(now: datetime) -> Path:
    target = DESKTOP / report_name(now)
    n = 2
    while target.exists():
        target = DESKTOP / f"{report_name(now)[:-4]} ({n}).zip"
        n += 1
    return target


def create(form: Form, *, output_dir: Path, config_path: Path, via: str = "window",
           now: datetime | None = None, probe: Probe | None = None) -> dict:
    """Write the report to the Desktop (atomically: a zip appears whole or
    not at all). Returns its path, size and the files in it."""
    now = now or datetime.now().astimezone()
    probe = probe or Probe()
    output_dir = Path(output_dir)
    if form.meeting is not None and not (is_recording_folder_name(form.meeting)
                                         and (output_dir / form.meeting).is_dir()):
        raise ValueError(f"no meeting {form.meeting}")
    settings_data, secrets = settings_snapshot(config_path)
    DESKTOP.mkdir(parents=True, exist_ok=True)
    target = _target(now)
    tmp = target.with_name(f".{target.name}.{os.getpid()}.tmp")
    try:
        with open(tmp, "wb") as f:
            z = _Zip(f, secrets)
            _fill(z, form, output_dir=output_dir, config_path=config_path, via=via, now=now, probe=probe,
                  settings_data=settings_data)
            z.zip.close()
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, target)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise
    size = target.stat().st_size
    usage.record("report", what=form.kind, audio=form.audio, meeting=bool(form.meeting), via=via, mb=size / 1e6)
    return {"path": str(target), "name": target.name, "size": size, "files": len(z.manifest) + 1}


def _fill(z: _Zip, form: Form, *, output_dir: Path, config_path: Path, via: str, now: datetime, probe: Probe,
          settings_data: dict) -> None:
    git = _safely(probe.git)
    status, state = _daemon()
    folders = _meeting_folders(output_dir)
    since = now - timedelta(days=TIMELINE_DAYS)

    # Logs, complete; the sources of the timeline as they go in.
    sources: list[tuple[str, str]] = []
    if LOG_DIR.is_dir():
        for p in sorted(LOG_DIR.rglob("*")):
            if p.is_file():
                rel = p.relative_to(LOG_DIR).as_posix()
                z.add_file(f"logs/{rel}", p, "Palaver's log, complete (app, window's server, daemon, crashes)")
                sources.append((rel, _read_text(p)))
    for p in _crash_reports(now):
        z.add_file(f"crash-reports/{p.name}", p, "macOS crash report of a Palaver process")
    from . import access_log, mcp_access

    for p, what in ((access_log.path(), "what left the Mac: calls to cloud models and services"),
                    (mcp_access.LOG_PATH, "what MCP clients read"),
                    (mcp_access._old(mcp_access.LOG_PATH), "what MCP clients read, from before")):
        if p.is_file():
            z.add_file(f"data/{p.name}", p, what)

    # Every meeting's small files; the chosen one complete, its audio when asked.
    for folder in folders:
        for name in SMALL_FILES:
            p = folder / name
            if p.is_file():
                z.add_file(f"meetings/{folder.name}/{name}", p, "every meeting's log and state")
        log = folder / "session.log"
        if log.is_file():
            sources.append((f"meetings/{folder.name}", _read_text(log)))
    if form.meeting:
        chosen = output_dir / form.meeting
        for p in sorted(chosen.rglob("*")):
            if not p.is_file():
                continue
            rel = p.relative_to(chosen).as_posix()
            if is_audio(p):
                if form.audio:
                    z.add_file(f"meetings/{form.meeting}/{rel}", p, "the chosen meeting's audio", audio=True)
                continue
            z.add_file(f"meetings/{form.meeting}/{rel}", p, "the chosen meeting, complete")
    z.add_text("meetings/LISTING.txt", _listing(folders), "every meeting's files and their sizes")
    jobs = output_dir / ".jobs"
    if jobs.is_dir():
        for p in sorted(jobs.rglob("*")):
            if p.is_file():
                z.add_file(f"jobs/{p.relative_to(jobs).as_posix()}", p, "the language model's job records")

    lines = timeline(sources, since)
    z.add_text("timeline.txt", "\n".join(lines) + "\n",
               f"warnings, errors and events of the last {TIMELINE_DAYS} days across the logs, by time")

    # Settings, this Mac, the usage.
    z.add_json("settings.json", settings_data, "settings (config loader, config.toml, settings.json); secrets redacted")
    z.add_text("doctor.txt", _text_or_error(probe.doctor, config_path), "`palaver doctor`")
    hardware = _safely(probe.hardware)
    devices = _safely(probe.audio_devices)
    z.add_json("system/audio-devices.json", devices, "audio devices: the defaults and every device macOS lists")
    z.add_json("system/permissions.json", _safely(probe.permissions, output_dir), "microphone, system audio, calendar")
    z.add_json("system/memory.json", _safely(probe.memory, config_path), "free memory and the workers' budgets")
    if state is not None:
        z.add_json("system/daemon.json", state, "the running app's state: recording, warnings, memory")
    z.add_text("system/processes.txt", _text_or_error(probe.processes), "Palaver's processes now")
    events = usage.read()
    catalog = usage.catalog()
    if usage.PATH.is_file():
        z.add_file("usage/usage.jsonl", usage.PATH, "the raw usage log")
    z.add_json("usage-summary.json", usage.summary(events, catalog, now=now),
               "features used over 7 and 30 days, never used, recordings and notes")

    report = {
        "form": asdict(form),
        "created": now.isoformat(timespec="seconds"),
        "via": via,
        "user": settings_data.get("config", {}).get("user_name") if isinstance(settings_data.get("config"), dict) else None,
        "host": socket.gethostname(),
        "palaver": {"version": __version__, **({k: git.get(k) for k in ("commit", "dirty", "branch")}
                                               if isinstance(git, dict) and "error" not in git else {})},
        "python": platform.python_version(),
        "python_path": sys.executable,
        "hardware": hardware,
        "disk": _safely(_disk, output_dir),
        "models": _safely(probe.models),
        "daemon": status,
        "recordings": {"folder": str(output_dir), "meetings": len(folders)},
        "last_errors": collapse_repeats([line for line in lines if "  EVENT " not in line])[-30:],
    }
    z.add_json("report.json", report, "the form, versions, this Mac, models, the daemon, the last errors")
    manifest = [f"Palaver report, {now:%Y-%m-%d %H:%M} — {form.kind}", ""]
    width = max([len(n) for n, _, _ in z.manifest] + [12])
    manifest += [f"{name:<{width}}  {size:>12,} B  {what}" for name, size, what in sorted(z.manifest)]
    manifest.append(f"{'MANIFEST.txt':<{width}}  {'':>14}  this list")
    z.add_text("MANIFEST.txt", "\n".join(manifest) + "\n", "this list")


def _read_text(p: Path) -> str:
    try:
        return p.read_text(errors="replace")
    except OSError:
        return ""


def _text_or_error(fn, *args) -> str:
    try:
        return str(fn(*args)) + "\n"
    except Exception as exc:
        return f"(failed: {type(exc).__name__}: {exc})\n"


def reveal(path: Path) -> None:  # pragma: no cover - opens Finder
    """Show the zip in Finder, selected: ready to drag into Slack or Mail."""
    try:
        subprocess.Popen(["open", "-R", str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass


def size_text(size: int) -> str:
    mb = size / 1e6
    return f"{mb:.1f} MB" if mb >= 0.1 else f"{max(1, round(size / 1e3))} KB"


# --- the maintainer's side -----------------------------------------------------------------------

def _member(z: zipfile.ZipFile, name: str) -> bytes | None:
    try:
        return z.read(name)
    except KeyError:
        return None


def _json_member(z: zipfile.ZipFile, name: str):
    data = _member(z, name)
    try:
        return json.loads(data) if data is not None else None
    except ValueError:
        return None


def pipeline(session_log: str) -> list[str]:
    """A meeting's pipeline from its session.log: each step with its time,
    the failures, and the starts of its processes."""
    out = []
    for line in session_log.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if not isinstance(row, dict):
            continue
        ts = str(row.get("ts", ""))[11:19]
        name = row.get("event")
        if name and name.endswith("_done") and "seconds" in row:
            extra = " ".join(f"{k}={row[k]}" for k in ("track", "engine", "model") if row.get(k))
            out.append(f"{ts}  {name[:-5]:<18} {row['seconds']:>7} s  {extra}".rstrip())
        elif name in session_log_starts or (name and (name.endswith("_failed") or name.endswith("_stop"))):
            out.append(f"{ts}  {name:<18}           {_fields_text(row)[:160]}".rstrip())
        elif row.get("level") in _LEVELS:
            out.append(f"{ts}  {row['level']:<18}           {str(row.get('message', ''))[:160]}")
    return out


session_log_starts = {"process_start", "process_done", "record_start", "live_start", "stream_start", "live_done",
                      "stream_done", "notes_skipped"}


def open_report(zip_path: Path, dest: Path | None = None) -> tuple[Path, str]:
    """Unpack a report next to it (or into ``dest``) and say what is in it."""
    zip_path = Path(zip_path)
    dest = Path(dest) if dest else zip_path.with_suffix("")
    with zipfile.ZipFile(zip_path) as z:
        z.extractall(dest)  # zipfile drops absolute paths and ".." from names
        report = _json_member(z, "report.json") or {}
        timeline_text = (_member(z, "timeline.txt") or b"").decode(errors="replace")
        devices = _json_member(z, "system/audio-devices.json") or {}
        form = report.get("form") or {}
        meeting = form.get("meeting")
        log = (_member(z, f"meetings/{meeting}/session.log") or b"").decode(errors="replace") if meeting else ""
    pal = report.get("palaver") or {}
    hw = report.get("hardware") or {}
    disk = report.get("disk") or {}
    version = pal.get("version", "?")
    if pal.get("commit"):
        version += f" ({pal['commit'][:7]}{', dirty' if pal.get('dirty') else ''}{', ' + pal['branch'] if pal.get('branch') else ''})"
    out = [f"{zip_path.name}: a {form.get('kind', '?')} from {report.get('user') or '?'} on {report.get('host') or '?'}, "
           f"{report.get('created', '?')} (via {report.get('via', '?')})",
           f"Palaver {version} · Python {report.get('python', '?')} · macOS {hw.get('macos', '?')} · "
           f"{hw.get('chip', '?')} · {hw.get('ram_gb', '?')} GB RAM · {disk.get('free_gb', '?')} GB free",
           f"Daemon: {report.get('daemon', '?')}",
           f"Meeting: {meeting or 'none'}{' (with audio)' if form.get('audio') else ''}",
           "", "What happened:"]
    out += [f"  {line}" for line in (form.get("text") or "(nothing written)").splitlines()]
    default = devices.get("default") or {}
    out += ["", "Devices: " + ", ".join(f"{scope} {d[0]} ({d[1] / 1000:g} kHz)" if isinstance(d, list) and d[1]
                                        else f"{scope} {d}" for scope, d in default.items() if scope != "error")
            if isinstance(default, dict) else "Devices: ?"]
    problems = collapse_repeats([line for line in timeline_text.splitlines() if line.strip() and "  EVENT " not in line])
    out += ["", f"Warnings and errors (last {min(OPEN_TIMELINE, len(problems))} of {len(problems)}):"]
    out += [f"  {line}" for line in problems[-OPEN_TIMELINE:]] or ["  none"]
    if meeting:
        steps = pipeline(log)
        out += ["", f"Pipeline of {meeting}:"] + ([f"  {s}" for s in steps] or ["  (no session.log)"])
    out += ["", f"Unpacked to {dest}"]
    return dest, "\n".join(out)


def usage_table(zips: list[Path]) -> str:
    """Feature use across reports: per feature, how many testers used it
    and how often. A tester's latest report counts (by user and Mac)."""
    latest: dict[str, tuple[str, list[dict], list[str]]] = {}
    for path in zips:
        with zipfile.ZipFile(path) as z:
            report = _json_member(z, "report.json") or {}
            events = usage.read_lines((_member(z, "usage/usage.jsonl") or b"").decode(errors="replace"))
            summary = _json_member(z, "usage-summary.json") or {}
        who = f"{report.get('user') or '?'}@{report.get('host') or path.name}"
        created = str(report.get("created") or "")
        if who not in latest or created > latest[who][0]:
            latest[who] = (created, events, list(summary.get("never_used") or []))
    users: dict[str, set[str]] = {}
    uses: dict[str, int] = {}
    for who, (_, events, never) in latest.items():
        for e in events:
            name = usage.feature(e)
            if name:
                users.setdefault(name, set()).add(who)
                uses[name] = uses.get(name, 0) + 1
        for name in never:
            users.setdefault(name, set())
            uses.setdefault(name, 0)
    rows = sorted(users, key=lambda f: (-len(users[f]), -uses[f], f))
    width = max([len(f) for f in rows] + [len("feature")])
    out = [f"{len(latest)} tester(s), {len(zips)} report(s)", "",
           f"{'feature':<{width}}  {'users':>5}  {'uses':>6}"]
    out += [f"{f:<{width}}  {len(users[f]):>5}  {uses[f]:>6}" for f in rows]
    return "\n".join(out)
