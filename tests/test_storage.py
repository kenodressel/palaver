"""#9: what the meetings and models take; a transcribed meeting's audio can go."""

import json
from datetime import datetime
from pathlib import Path

import pytest

from palaver import storage
from palaver.paths import RecordingPaths

NOW = datetime(2026, 11, 2, 12, 0)


def _meeting(root: Path, name: str, *, transcribed: bool = True, audio: int = 1000) -> RecordingPaths:
    p = RecordingPaths(root / name)
    p.folder.mkdir(parents=True)
    for f in (p.mic_raw_wav, p.mic_wav, p.system_wav):
        f.write_bytes(b"\0" * audio)
    if transcribed:
        p.transcript_json.write_text("[]")
    p.notes.write_text("{}")
    return p


def test_drop_audio_keeps_the_transcript_and_says_so(tmp_path):
    p = _meeting(tmp_path, "2026-10-01T10-00-00")
    assert storage.drop_audio(p) == 3000
    assert storage.audio_files(p) == [] and p.transcript_json.exists() and p.notes.exists()
    assert storage.deleted(p)["bytes"] == 3000
    assert not storage.can_drop(p)


def test_an_untranscribed_meeting_keeps_its_audio(tmp_path):
    p = _meeting(tmp_path, "2026-10-01T10-00-00", transcribed=False)
    with pytest.raises(ValueError):
        storage.drop_audio(p)
    assert len(storage.audio_files(p)) == 3


def test_a_meeting_still_being_written_keeps_its_audio(tmp_path):
    p = _meeting(tmp_path, "2026-10-01T10-00-00")
    Path(str(p.system_wav) + ".part").write_bytes(b"\0")
    assert not storage.can_drop(p)


def test_drop_old_audio_only_older_than_the_days(tmp_path):
    old = _meeting(tmp_path, "2026-10-01T10-00-00")
    new = _meeting(tmp_path, "2026-10-30T10-00-00")
    pending = _meeting(tmp_path, "2026-09-01T10-00-00", transcribed=False)
    assert storage.drop_old_audio(tmp_path, 14, NOW) == (1, 3000)
    assert storage.audio_files(old) == []
    assert len(storage.audio_files(new)) == 3 and len(storage.audio_files(pending)) == 3
    assert storage.drop_old_audio(tmp_path, 0, NOW) == (0, 0)  # 0: kept


def test_audio_days_are_saved_and_checked():
    assert storage.audio_days() == 0
    storage.set_audio_days(30)
    assert storage.audio_days() == 30
    for wrong in (5, True, "30", None):
        with pytest.raises(ValueError):
            storage.set_audio_days(wrong)


def test_summary_counts_meetings_audio_and_what_would_go(tmp_path, monkeypatch):
    monkeypatch.setattr(storage, "models", lambda cfg=None: [])
    _meeting(tmp_path, "2026-10-01T10-00-00")
    _meeting(tmp_path, "2026-10-30T10-00-00", audio=500)
    (tmp_path / "not-a-meeting").mkdir()
    s = storage.summary(tmp_path, now=NOW)
    assert s["meetings"] == 2 and s["audio_bytes"] == 4500 and s["audio_meetings"] == 2
    assert s["bytes"] > s["audio_bytes"]
    assert s["older"]["14"] == {"meetings": 1, "bytes": 3000}
    assert s["older"]["90"] == {"meetings": 0, "bytes": 0}


def test_only_a_notes_model_not_in_use_can_be_deleted(tmp_path, monkeypatch):
    from palaver import llm, onboarding

    sizes = {onboarding.MODELS["gemma"].repo: 9, onboarding.RETIRED["qwen"].repo: 17,
             onboarding.MODELS["parakeet"].repo: 2}
    monkeypatch.setattr(onboarding, "cached_bytes", lambda repo: sizes.get(repo, 0))
    monkeypatch.setattr(onboarding, "_hub_cache", lambda: tmp_path)
    monkeypatch.setattr(llm, "local_model", lambda cfg: onboarding.MODELS["gemma"].repo)
    rows = {m["id"]: m for m in storage.models()}
    assert set(rows) == {"gemma", "qwen", "parakeet"}
    assert [i for i, m in rows.items() if m["deletable"]] == ["qwen"]
    qwen = onboarding._cache_dir(onboarding.RETIRED["qwen"].repo)
    qwen.mkdir(parents=True)
    assert storage.delete_model(None, "qwen") == 17 and not qwen.exists()
    for mid in ("gemma", "parakeet", "nope"):
        with pytest.raises(ValueError):
            storage.delete_model(None, mid)


def test_cleanup_runs_once_an_hour_and_only_when_asked(tmp_path, monkeypatch):
    runs = []
    monkeypatch.setattr(storage, "drop_old_audio", lambda root, days: runs.append(days))
    clock = [0.0]
    days = [0]
    c = storage.Cleanup(tmp_path, days=lambda: days[0], clock=lambda: clock[0])
    c.tick()
    days[0] = 30
    clock[0] = 10
    c.tick()  # not an hour yet
    clock[0] = 3601
    c.tick()
    c._thread.join()
    assert runs == [30]


def test_deleted_marker_survives_a_second_delete(tmp_path):
    p = _meeting(tmp_path, "2026-10-01T10-00-00")
    storage.drop_audio(p)
    p.mic_raw_wav.write_bytes(b"\0" * 10)  # e.g. put back by hand
    storage.drop_audio(p)
    assert json.loads((p.folder / storage.DELETED).read_text())["bytes"] == 3010


def test_a_model_no_longer_offered_goes_at_start(tmp_path, monkeypatch):
    from types import SimpleNamespace

    from palaver import onboarding

    monkeypatch.setattr(onboarding, "_hub_cache", lambda: tmp_path)
    qwen = onboarding._cache_dir(onboarding.QWEN)
    (qwen / "blobs").mkdir(parents=True)
    (qwen / "blobs" / "abc").write_bytes(b"\0" * 100)
    storage.settings.update({"local_model": onboarding.QWEN})  # chosen before: ignored now
    assert storage.drop_retired(None) == 100 and not qwen.exists()
    assert storage.drop_retired(None) == 0
    (qwen / "blobs").mkdir(parents=True)
    named = SimpleNamespace(notes_local_model=onboarding.QWEN)  # config.toml still names it: kept
    assert storage.drop_retired(named) == 0 and qwen.exists()
