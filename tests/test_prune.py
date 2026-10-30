"""Tests for `prune` (issue #3)."""

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

from palaver.prune import plan_prune, prune

NOW = datetime(2026, 10, 20, 12, 0, tzinfo=timezone.utc)


def _recording(root: Path, name: str, *, synced: bool, start: datetime | None = None) -> Path:
    folder = root / name
    folder.mkdir()
    (folder / "mic_raw.wav").write_bytes(b"\0" * 1000)
    if start is not None:
        (folder / "meta.json").write_text(json.dumps({"start_time": start.isoformat()}))
    if synced:
        (folder / "transcript.json").write_text("[]")
        (folder / "notion.json").write_text("{}")
    return folder


def test_plan_deletes_only_old_synced_recordings(tmp_path: Path):
    old = NOW - timedelta(days=20)
    _recording(tmp_path, "2026-09-30T10-00-00", synced=True, start=old)
    _recording(tmp_path, "2026-09-30T11-00-00", synced=False, start=old)
    _recording(tmp_path, "2026-10-19T10-00-00", synced=True, start=NOW - timedelta(days=1))
    (tmp_path / "notes").mkdir()  # not a recording folder: never touched
    (tmp_path / "2026-09-01T10-00-00.txt").write_text("file, not folder")

    plan = plan_prune(tmp_path, retention_days=14, now=NOW)

    assert [f.name for f in plan.delete] == ["2026-09-30T10-00-00"]
    assert [f.name for f in plan.kept_unsynced] == ["2026-09-30T11-00-00"]


def test_include_unsynced(tmp_path: Path):
    old = NOW - timedelta(days=20)
    _recording(tmp_path, "2026-09-30T11-00-00", synced=False, start=old)
    plan = plan_prune(tmp_path, retention_days=14, now=NOW, include_unsynced=True)
    assert [f.name for f in plan.delete] == ["2026-09-30T11-00-00"]


def test_age_falls_back_to_folder_name(tmp_path: Path):
    _recording(tmp_path, "2026-09-01T10-00-00-2", synced=True)  # no meta.json, suffixed
    plan = plan_prune(tmp_path, retention_days=14, now=NOW)
    assert [f.name for f in plan.delete] == ["2026-09-01T10-00-00-2"]


def test_prune_dry_run_deletes_nothing(tmp_path: Path, capsys):
    folder = _recording(tmp_path, "2026-09-30T10-00-00", synced=True, start=NOW - timedelta(days=20))
    prune(tmp_path, retention_days=14, now=NOW, dry_run=True)
    assert folder.exists()
    assert "would delete" in capsys.readouterr().out


def test_prune_deletes_and_reports_freed_space(tmp_path: Path, capsys):
    folder = _recording(tmp_path, "2026-09-30T10-00-00", synced=True, start=NOW - timedelta(days=20))
    deleted = prune(tmp_path, retention_days=14, now=NOW)
    assert deleted == [folder]
    assert not folder.exists()
    assert "deleted 2026-09-30T10-00-00" in capsys.readouterr().out


def test_prune_missing_output_dir_is_noop(tmp_path: Path):
    assert prune(tmp_path / "missing", retention_days=14, now=NOW) == []


def test_naive_meta_timestamp_is_treated_as_local(tmp_path: Path):
    folder = _recording(tmp_path, "2026-09-30T10-00-00", synced=True)
    (folder / "meta.json").write_text(json.dumps({"start_time": "2026-09-30T10:00:00"}))
    assert [f.name for f in plan_prune(tmp_path, 14, now=NOW).delete] == ["2026-09-30T10-00-00"]
