"""`palaver doctor`: check setup and say exactly what to fix.

Permission checks describe the process that runs them — the terminal when
run from a shell, the app when run from Palaver.app.
"""

from __future__ import annotations

import json
import platform
import shutil
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import requests

from .paths import is_recording_folder_name

_SETTINGS = "System Settings → Privacy & Security → "


@dataclass(frozen=True)
class Check:
    name: str
    status: str  # ok | warn | fail
    detail: str
    fix: str = ""


_MARK = {"ok": "✓", "warn": "!", "fail": "✗"}


def format_report(checks: list[Check]) -> str:
    lines = []
    for c in checks:
        lines.append(f"{_MARK[c.status]} {c.name}: {c.detail}")
        if c.fix and c.status != "ok":
            lines.append(f"    → {c.fix}")
    return "\n".join(lines)


def check_macos() -> Check:
    version = platform.mac_ver()[0] or "unknown"
    parts = tuple(int(p) for p in version.split(".")[:2] if p.isdigit())
    if parts and parts < (15, 0):
        return Check("macOS", "fail", version, "Palaver needs macOS 15+")
    return Check("macOS", "ok", version)


def check_config(path: Path):
    from .config import load_config

    try:
        return Check("Config", "ok", str(path) if path.exists() else "none: the defaults"), load_config(path)
    except FileNotFoundError:
        return Check("Config", "fail", f"{path} not found", "create it as shown in the README"), None
    except ValueError as exc:
        return Check("Config", "fail", str(exc), f"edit {path} or export the token"), None


def check_notion(token: str, mode: str, parent_page_id: str | None, database_id: str | None) -> Check:
    headers = {"Authorization": f"Bearer {token}", "Notion-Version": "2022-06-28"}
    try:
        me = requests.get("https://api.notion.com/v1/users/me", headers=headers, timeout=10)
    except requests.RequestException as exc:
        return Check("Notion", "warn", f"not reachable ({type(exc).__name__})", "check the network")
    if me.status_code == 401:
        return Check("Notion", "fail", "token rejected", "create a new internal integration token")
    if me.status_code != 200:
        return Check("Notion", "warn", f"unexpected status {me.status_code}")
    kind, target = ("databases", database_id) if mode == "database" else ("pages", parent_page_id)
    page = requests.get(f"https://api.notion.com/v1/{kind}/{target}", headers=headers, timeout=10)
    if page.status_code != 200:
        return Check(
            "Notion", "fail", f"{kind[:-1]} {target} not accessible ({page.status_code})",
            f"share the {kind[:-1]} with your integration (••• → Connections)",
        )
    return Check("Notion", "ok", f"token valid, {kind[:-1]} accessible")


def check_model(name: str, repo: str, probe_file: str, size: str) -> Check:
    from huggingface_hub import try_to_load_from_cache

    if isinstance(try_to_load_from_cache(repo, probe_file), str):
        return Check(name, "ok", "downloaded")
    return Check(name, "warn", "not downloaded yet", f"downloads on first `process` (~{size})")


def check_speech_models() -> Check:
    """Parakeet and the diarizer, palaver-engine's: asked of the engine itself
    (``hello``), which knows when its models are complete. Without the engine
    built, the files say."""
    from . import install_layout, onboarding
    from .engine import Engine, EngineError, engine_path

    try:
        if not engine_path().exists():
            raise EngineError("the speech engine is missing: reinstall Palaver" if install_layout.bundle() is not None
                              else "the speech engine is missing: run `make engine`")
    except EngineError as exc:  # not built: the files say
        if onboarding.speech_files_here():
            return Check("Speech models", "ok", "downloaded (the engine is not built, files checked)")
        return Check("Speech models", "warn", f"not downloaded yet ({exc})",
                     "download them in the setup assistant (about 0.5 GB), or "
                     + ("reinstall Palaver" if install_layout.bundle() is not None else "run `make engine` first"))
    engine = Engine(idle_timeout=30)
    try:
        models = engine.call("hello").get("models") or {}
    except EngineError as exc:  # built, but it does not run
        first = str(exc).strip().splitlines()[0] if str(exc).strip() else "no answer"
        return Check("Speech models", "fail", f"the speech engine does not run ({first})",
                     "run `palaver doctor` again after `make engine`, or reinstall Palaver")
    finally:
        engine.close()
    missing = [{"asr": "transcription", "diarizer": "speakers"}.get(n, n) for n, ready in models.items() if not ready]
    if not models or missing:
        return Check("Speech models", "warn", f"not downloaded yet ({' and '.join(missing) or 'unknown'})",
                     "download them in the setup assistant (about 0.5 GB); meetings recorded before wait for them")
    return Check("Speech models", "ok", "downloaded")


def check_aec() -> Check:
    from . import aec

    try:
        aec._load_lib()
    except (RuntimeError, OSError) as exc:
        return Check("Echo cancellation library", "fail", str(exc).split(". ")[0],
                     "build it with make aec, as described in CONTRIBUTING.md (cmake, Xcode Command Line Tools)")
    return Check("Echo cancellation library", "ok", "loaded")


def check_microphone(status: int | None = None) -> Check:
    if status is None:
        import AVFoundation

        status = AVFoundation.AVCaptureDevice.authorizationStatusForMediaType_(AVFoundation.AVMediaTypeAudio)
    if status == 3:
        return Check("Microphone permission", "ok", "granted")
    if status == 0:
        return Check("Microphone permission", "warn", "not asked yet", "macOS asks on the first recording")
    return Check("Microphone permission", "fail", "denied",
                 _SETTINGS + "Microphone → enable this app/terminal")


_MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")


def _title(folder: Path) -> str:
    """The title the user gave the recording, else its calendar event's, else
    the one its notes gave it (as titles.py, without importing the app); ""
    when none."""
    for name in ("title.json", "calendar.json", "notes.json"):
        try:
            title = json.loads((folder / name).read_text()).get("title")
        except (OSError, ValueError, AttributeError):
            continue
        if isinstance(title, str) and title.strip():
            return title.strip()
    return ""


def _start(folder: Path) -> datetime | None:
    """When the recording started (meta.json, as the Meetings window shows it), else its folder's time."""
    try:
        return datetime.fromisoformat(json.loads((folder / "meta.json").read_text())["start_time"]).astimezone()
    except (OSError, ValueError, KeyError, TypeError):
        pass
    try:
        return datetime.strptime(folder.name, "%Y-%m-%dT%H-%M-%S")
    except ValueError:
        return None


def meeting_name(folder: Path) -> str:
    """A recording as a person reads it, not its folder id: “Weekly” on 29 Oct,
    16:07, or the meeting on 29 Oct, 16:07 without a title."""
    when = _start(folder)
    if when is None:
        return folder.name
    stamp = f"{when.day}\u00a0{_MONTHS[when.month - 1]}, {when:%H:%M}"  # a no-break space: "29 Oct" stays on one line
    title = _title(folder)
    return f"“{title}” on {stamp}" if title else f"the meeting on {stamp}"


def check_system_audio(output_dir: Path) -> Check:
    """There is no preflight API for the audio-capture permission; judge by
    how the most recent recording captured system audio."""
    name = "System audio capture"
    folders = sorted(
        p for p in (output_dir.iterdir() if output_dir.is_dir() else [])
        if p.is_dir() and is_recording_folder_name(p.name) and (p / "session.log").exists()
    )
    for folder in reversed(folders):
        for line in (folder / "session.log").read_text().splitlines():
            try:
                row = json.loads(line)
            except ValueError:  # a line cut short
                continue
            if not isinstance(row, dict):
                continue
            if row.get("event") == "record_start" and row.get("system_source"):
                if row["system_source"] == "process-tap":
                    return Check(name, "ok", f"Process Tap worked in {meeting_name(folder)}")
                return Check(name, "warn", f"fell back to ScreenCaptureKit in {meeting_name(folder)}",
                             _SETTINGS + "Screen & System Audio Recording → under System Audio "
                             "Recording Only, allow Palaver / your terminal")
    return Check(name, "warn", "not verified yet", "checked on the first recording")


def _default_devices() -> dict:  # pragma: no cover - reads CoreAudio
    from ._audio.process_tap import _CoreAudioBackend

    backend = _CoreAudioBackend()
    return {"input": backend.default_device("input"), "output": backend.default_device("output")}


def check_audio_devices(devices: dict | None = None, *, lookup=_default_devices) -> Check:
    """The devices a recording would use now, with their rates (issue #50).
    Any of them works; this only says which."""
    name = "Audio devices"
    if devices is None:
        try:
            devices = lookup()
        except Exception as exc:
            return Check(name, "warn", f"could not read them ({exc})")
    found, missing = [], []
    for scope in ("input", "output"):
        device, rate = devices.get(scope) or (None, None)
        if not device:
            missing.append(scope)
        else:
            found.append(f"{scope} {device} ({rate / 1000:g} kHz)" if rate else f"{scope} {device}")
    if missing:
        return Check(name, "warn", ", ".join(found + [f"no {scope} device" for scope in missing]),
                     "pick one in System Settings → Sound")
    return Check(name, "ok", ", ".join(found))


def check_recent_audio(output_dir: Path) -> Check:
    """Whether the latest recording's audio went wrong (issue #50)."""
    from datetime import datetime

    from .lifecycle import problem_text

    name = "Last recording's audio"
    folders = sorted(
        p for p in (output_dir.iterdir() if output_dir.is_dir() else [])
        if p.is_dir() and is_recording_folder_name(p.name) and (p / "meta.json").exists()
    )
    if not folders:
        return Check(name, "ok", "no recordings yet")
    folder = folders[-1]
    try:
        meta = json.loads((folder / "meta.json").read_text())
        problems = meta.get("audio_problems") or []
        start = datetime.fromisoformat(meta["start_time"])
    except (OSError, ValueError, KeyError, TypeError):
        return Check(name, "ok", f"nothing known about {folder.name}")
    if not problems:
        return Check(name, "ok", f"no problems in {folder.name}")
    detail = f"{folder.name}: {problem_text(problems[0], start)}"
    if len(problems) > 1:
        detail += f" (and {len(problems) - 1} more)"
    return Check(name, "warn", detail, f"its session.log has the details: {folder / 'session.log'}")


def check_teams_detection() -> Check:
    from .teams_detector import audio_processes

    try:
        processes = audio_processes()
    except Exception as exc:
        return Check("Teams detection", "fail", f"CoreAudio process list unavailable ({exc})",
                     "needs macOS 14.4+")
    teams = [p for p in processes if p.bundle_id.lower().startswith("com.microsoft.teams")]
    if not Path("/Applications/Microsoft Teams.app").exists():
        return Check("Teams detection", "warn", "Microsoft Teams not installed in /Applications")
    state = "running" if teams else "not running right now"
    return Check("Teams detection", "ok", f"works ({len(processes)} audio processes; Teams {state})")


def check_disk(output_dir: Path, free_bytes: int | None = None) -> Check:
    if free_bytes is None:
        probe = output_dir if output_dir.exists() else Path.home()
        free_bytes = shutil.disk_usage(probe).free
    gb = free_bytes / 1024**3
    detail = f"{gb:.0f} GB free"
    if gb < 2:
        return Check("Disk space", "fail", detail, "a 1 h meeting needs ~250 MB of audio; free up space")
    if gb < 10:
        return Check("Disk space", "warn", detail, "`palaver prune` deletes old synced recordings")
    return Check("Disk space", "ok", detail)


def check_memory(budgets, ram_gb: float, running: dict | None) -> Check:
    """The memory budgets per worker (#49) against this Mac's memory, and
    what the running Palaver (``running``: daemon.json's "memory") uses."""
    from .memory import GB, size_text

    def gb(value: float) -> str:
        return size_text(value * GB)

    detail = (f"live {gb(budgets.live)}, realtime {gb(budgets.stream)}, transcription {gb(budgets.process)}, "
              f"notes {gb(budgets.notes)}, search index {gb(budgets.index)}")
    if running and running.get("total") is not None:
        detail += f"; Palaver uses {size_text(running['total'])} now"
    name = "Memory budgets"
    over = [w for w in (running or {}).get("workers", [])
            if w.get("used") is not None and w.get("budget") and w["used"] > w["budget"] * GB]
    if over:
        w = over[0]
        return Check(name, "warn", f"{w['label']} uses {size_text(w['used'])}, over its {gb(w['budget'])} budget",
                     "Palaver restarts live and realtime transcription on its own, and stops notes or a "
                     "transcription only when the Mac runs low on memory; raise the budget under [memory] in "
                     "config.toml if this happens often")
    call = budgets.live + budgets.stream
    if call >= ram_gb / 2:
        return Check(name, "warn", f"live and realtime transcription may use {gb(call)} during a call, "
                     f"half or more of this Mac's {gb(ram_gb)}",
                     "lower live_gb / stream_gb under [memory] in config.toml, or turn realtime off in Settings")
    if budgets.notes > ram_gb * 0.75:
        return Check(name, "warn", f"notes may use {gb(budgets.notes)}; this Mac has {gb(ram_gb)}",
                     "write notes with Claude ([notes] engine = \"claude\") or a smaller local model")
    if budgets.process > ram_gb * 0.75:
        return Check(name, "warn", f"a transcription may use {gb(budgets.process)}; this Mac has {gb(ram_gb)}",
                     "lower process_gb under [memory] in config.toml")
    return Check(name, "ok", detail)


def _ram_gb() -> float:
    import os

    return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / 1024**3


def _running_memory() -> dict | None:
    """The running Palaver's memory, from its daemon.json."""
    from .daemon import STATE_PATH, palaver_alive

    try:
        state = json.loads(STATE_PATH.read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(state, dict) or state.get("state") in (None, "stopped") or not palaver_alive(state.get("pid")):
        return None
    return state.get("memory")


def run_checks(*, config_path: Path, offline: bool = False) -> list[Check]:
    checks = [check_macos()]
    config_check, cfg = check_config(config_path)
    checks.append(config_check)
    if cfg is not None:
        if not offline and cfg.notion_token:
            checks.append(check_notion(cfg.notion_token, cfg.notion_mode,
                                       cfg.notion_parent_page_id, cfg.notion_database_id))
        checks.append(check_speech_models())
        if cfg.transcriber not in ("parakeet", "parakeet-mlx"):
            checks.append(check_model("Whisper model", cfg.whisper_repo, "config.json", "1.6 GB"))
        from .memory import budgets_for

        checks.append(check_memory(budgets_for(cfg), _ram_gb(), _running_memory()))
    checks += [check_aec(), check_microphone()]
    output_dir = cfg.output_dir if cfg is not None else Path.home() / "Meetings" / "Recordings"
    checks += [check_system_audio(output_dir), check_audio_devices(), check_recent_audio(output_dir),
               check_teams_detection(), check_disk(output_dir)]
    return checks
