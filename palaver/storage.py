"""What Palaver keeps on this Mac and the space it takes (#9): the meetings,
their audio and the models. A transcribed meeting's audio can go, for one
meeting or on its own after some days; its transcript and notes stay. Without
the audio it can't be played or transcribed again."""

from __future__ import annotations

import json
import logging
import shutil
import threading
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Callable

from . import settings

LOGGER = logging.getLogger(__name__)
from .paths import RecordingPaths, is_recording_folder_name, recording_folder_timestamp

AUDIO = ("mic_raw_wav", "mic_wav", "system_wav")
DAYS = (0, 7, 14, 30, 90)  # how long a transcribed meeting keeps its audio; 0: always
KEY = "audio_days"  # in settings.json
DELETED = "audio_deleted.json"
CLEANUP_EVERY = 3600.0


def audio_files(paths: RecordingPaths) -> list[Path]:
    return [f for f in (getattr(paths, a) for a in AUDIO) if f.exists()]


def audio_bytes(paths: RecordingPaths) -> int:
    return sum(_size(f) for f in audio_files(paths))


def deleted(paths: RecordingPaths) -> dict | None:
    """{"at", "bytes"} once the meeting's audio was deleted; None before."""
    try:
        data = json.loads((paths.folder / DELETED).read_text())
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def can_drop(paths: RecordingPaths) -> bool:
    """Only a finished, transcribed meeting: never one still being written."""
    parts = any(Path(str(getattr(paths, a)) + ".part").exists() for a in AUDIO)
    return paths.transcript_json.exists() and not parts and bool(audio_files(paths))


def drop_audio(paths: RecordingPaths) -> int:
    """Delete the meeting's audio; the bytes freed. ValueError when it has no
    transcript yet (or no audio)."""
    if not can_drop(paths):
        raise ValueError("only a transcribed meeting's audio can be deleted")
    freed = 0
    for f in audio_files(paths):
        size = _size(f)
        f.unlink(missing_ok=True)
        freed += size
    before = (deleted(paths) or {}).get("bytes", 0)
    (paths.folder / DELETED).write_text(json.dumps(
        {"at": datetime.now().astimezone().isoformat(timespec="seconds"), "bytes": before + freed}, indent=2))
    return freed


def audio_days() -> int:
    value = settings.read_raw().get(KEY)
    return value if isinstance(value, int) and not isinstance(value, bool) and value in DAYS else 0


def set_audio_days(days: Any) -> None:
    if isinstance(days, bool) or days not in DAYS:
        raise ValueError(f"{KEY} must be one of {', '.join(map(str, DAYS))}")
    settings.update({KEY: days})


def meetings(output_dir: Path) -> list[RecordingPaths]:
    try:
        return [RecordingPaths(f) for f in sorted(output_dir.iterdir())
                if f.is_dir() and is_recording_folder_name(f.name)]
    except OSError:
        return []


def older_than(output_dir: Path, days: int, now: datetime | None = None) -> list[RecordingPaths]:
    """The meetings started more than ``days`` ago whose audio can go."""
    cutoff = (now or datetime.now()) - timedelta(days=days)
    return [p for p in meetings(output_dir) if _started(p) < cutoff and can_drop(p)]


def drop_old_audio(output_dir: Path, days: int, now: datetime | None = None) -> tuple[int, int]:
    """Delete the audio of the meetings older than ``days``: (meetings, bytes)."""
    count = freed = 0
    for p in older_than(output_dir, days, now) if days > 0 else []:
        try:
            freed += drop_audio(p)
            count += 1
        except (OSError, ValueError):
            continue
    return count, freed


def summary(output_dir: Path, cfg=None, now: datetime | None = None) -> dict[str, Any]:
    """The Settings page's Storage section."""
    total = audio = with_audio = count = 0
    olds: dict[int, list[int]] = {d: [0, 0] for d in DAYS if d}
    now = now or datetime.now()
    for p in meetings(output_dir):
        count += 1
        size = _tree_size(p.folder)
        total += size
        mine = audio_bytes(p)
        audio += mine
        with_audio += bool(mine)
        if mine and can_drop(p):
            age = now - _started(p)
            for d in olds:
                if age > timedelta(days=d):
                    olds[d][0] += 1
                    olds[d][1] += mine
    return {
        "folder": str(output_dir),
        "meetings": count,
        "bytes": total,
        "audio_bytes": audio,
        "audio_meetings": with_audio,
        "audio_days": audio_days(),
        "days": list(DAYS),
        "older": {str(d): {"meetings": n, "bytes": b} for d, (n, b) in olds.items()},
        "models": models(cfg),
    }


def models(cfg=None) -> list[dict[str, Any]]:
    """The downloaded models, their size, and whether one can be deleted:
    only a notes model Palaver doesn't use now, or one no longer offered."""
    from . import llm, model_store, onboarding

    local = llm.local_model(cfg)
    out = []
    for m in (*onboarding.MODELS.values(), *onboarding.RETIRED.values()):
        repo = onboarding.repo_for(cfg, m)
        folder = model_store.local_path(repo)
        size = _tree_size(folder) if folder is not None else onboarding.cached_bytes(repo)
        if not size:
            continue
        spare = (m.id in onboarding.NOTES_MODELS.values() or m.id in onboarding.RETIRED) and repo != local
        out.append({"id": m.id, "label": m.label, "purpose": m.purpose, "bytes": size, "deletable": spare})
    return out


def delete_model(cfg, mid: str) -> int:
    """Delete a notes model Palaver doesn't use; the bytes freed."""
    from . import onboarding

    entry = next((m for m in models(cfg) if m["id"] == mid), None)
    if entry is None or not entry["deletable"]:
        raise ValueError("only a notes model Palaver doesn't use can be deleted")
    model = onboarding.MODELS.get(mid) or onboarding.RETIRED[mid]
    shutil.rmtree(onboarding._cache_dir(model.repo), ignore_errors=True)
    return entry["bytes"]


def drop_retired(cfg) -> int:
    """At start: delete the models no longer offered (Qwen3 30B A3B), unless
    config.toml still names one; the bytes freed. Nothing uses them: a choice
    of one saved in Settings writes with the default now."""
    from . import llm, onboarding

    freed = 0
    for m in onboarding.RETIRED.values():
        folder = onboarding._cache_dir(m.repo)
        if m.repo == llm.local_model(cfg) or not folder.exists():
            continue
        size = onboarding.cached_bytes(m.repo)
        shutil.rmtree(folder, ignore_errors=True)
        LOGGER.info("deleted %s, no longer offered: %.1f GB free again", m.label, size / 1e9)
        freed += size
    return freed


class Cleanup:
    """In the menu bar app: once an hour, in the background, delete the
    audio older than Settings say."""

    def __init__(self, output_dir: Path, *, every: float = CLEANUP_EVERY,
                 days: Callable[[], int] = audio_days, clock: Callable[[], float] = time.monotonic):
        self._output_dir, self._every, self._days, self._clock = output_dir, every, days, clock
        self._last: float | None = None
        self._thread: threading.Thread | None = None

    def tick(self) -> None:
        now = self._clock()
        if self._last is not None and now - self._last < self._every:
            return
        if self._thread is not None and self._thread.is_alive():
            return
        self._last = now
        days = self._days()
        if days:
            self._thread = threading.Thread(target=drop_old_audio, args=(self._output_dir, days),
                                            name="audio-cleanup", daemon=True)
            self._thread.start()


def _started(p: RecordingPaths) -> datetime:
    stamp = recording_folder_timestamp(p.folder.name) or ""
    try:
        return datetime.strptime(stamp, "%Y-%m-%dT%H-%M-%S")
    except ValueError:
        return datetime.max


def _size(f: Path) -> int:
    try:
        return f.stat().st_size
    except OSError:
        return 0


def _tree_size(folder: Path) -> int:
    try:
        return sum(_size(f) for f in folder.rglob("*") if f.is_file())
    except OSError:
        return 0
