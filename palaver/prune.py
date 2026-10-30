"""Retention: delete recording folders older than ``retention_days`` (#3).

Only folders named like ``new_recording_folder`` creates them are
considered. By default only synced recordings — whose transcript is safely in
Notion — are deleted; old unsynced ones are reported and kept.
"""

from __future__ import annotations

import json
import shutil
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path

from .paths import RecordingPaths, recording_folder_timestamp


@dataclass
class PrunePlan:
    delete: list[Path] = field(default_factory=list)
    kept_unsynced: list[Path] = field(default_factory=list)


def _start_time(folder: Path, stamp: str) -> datetime:
    meta = RecordingPaths(folder).meta
    try:
        start = datetime.fromisoformat(json.loads(meta.read_text())["start_time"])
    except (OSError, ValueError, KeyError, TypeError):
        start = datetime.strptime(stamp, "%Y-%m-%dT%H-%M-%S")
    return start if start.tzinfo else start.astimezone()


def plan_prune(
    output_dir: Path,
    retention_days: int,
    *,
    now: datetime | None = None,
    include_unsynced: bool = False,
) -> PrunePlan:
    now = now or datetime.now().astimezone()
    cutoff = now - timedelta(days=retention_days)
    plan = PrunePlan()
    if not output_dir.is_dir():
        return plan
    for folder in sorted(output_dir.iterdir()):
        stamp = recording_folder_timestamp(folder.name)
        if stamp is None or not folder.is_dir() or folder.is_symlink():
            continue
        if _start_time(folder, stamp) >= cutoff:
            continue
        if include_unsynced or RecordingPaths(folder).notion_info.exists():
            plan.delete.append(folder)
        else:
            plan.kept_unsynced.append(folder)
    return plan


def _size_mb(folder: Path) -> float:
    return sum(f.stat().st_size for f in folder.rglob("*") if f.is_file()) / 1e6


def prune(
    output_dir: Path,
    retention_days: int,
    *,
    now: datetime | None = None,
    dry_run: bool = False,
    include_unsynced: bool = False,
) -> list[Path]:
    """Apply (or with ``dry_run`` only print) the retention plan."""
    plan = plan_prune(
        output_dir, retention_days, now=now, include_unsynced=include_unsynced
    )
    verb = "would delete" if dry_run else "deleted"
    freed = 0.0
    for folder in plan.delete:
        size = _size_mb(folder)
        if not dry_run:
            shutil.rmtree(folder)
        freed += size
        print(f"{verb} {folder.name} ({size:.0f} MB)")
    for folder in plan.kept_unsynced:
        print(f"kept {folder.name}: older than {retention_days} days but not synced "
              f"(use --include-unsynced to delete)")
    if not plan.delete:
        print(f"nothing older than {retention_days} days to delete")
    else:
        print(f"{verb} {len(plan.delete)} recording(s), {freed:.0f} MB")
    return [] if dry_run else plan.delete
