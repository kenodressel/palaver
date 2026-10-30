"""Tests for undo snapshots."""

import json
import os
import shutil
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from palaver import cutting, undo
from palaver.paths import RecordingPaths

SR = 16_000
ID = "2026-10-20T14-35-17"


def _recording(root: Path, id_: str = ID) -> RecordingPaths:
    paths = RecordingPaths(root / id_)
    paths.folder.mkdir(parents=True)
    tone = np.zeros(SR, np.int16)
    for track in (paths.mic_raw_wav, paths.mic_wav, paths.system_wav):
        sf.write(str(track), tone, SR, subtype="PCM_16")
    paths.meta.write_text(json.dumps({"start_time": "2026-10-20T14:35:17+02:00", "duration_seconds": 1}))
    paths.system_turns.write_text(json.dumps([{"speaker": "SPEAKER_00", "start": 0, "end": 1}]))
    paths.system_segments.write_text("[]")
    paths.mic_segments.write_text("[]")
    paths.transcript_json.write_text("[]")
    paths.speakers.write_text(json.dumps({"SPEAKER_00": "Anna"}))
    return paths


def _later(path: Path, seconds: float = 5) -> None:
    t = path.stat().st_mtime + seconds
    os.utime(path, (t, t))


def test_take_and_restore_metadata_only(tmp_path):
    paths = _recording(tmp_path)
    token = undo.take(tmp_path, "rename", meetings=[ID])
    assert not list((tmp_path / ".trash" / ".undo" / token).rglob("*.wav"))
    paths.speakers.write_text(json.dumps({"SPEAKER_00": "Bob"}))
    undo.sealed(tmp_path, token)
    assert undo.restore(tmp_path, token) == [ID]
    assert json.loads(paths.speakers.read_text()) == {"SPEAKER_00": "Anna"}
    assert paths.system_wav.exists()  # the audio was never copied, and is still there
    assert not (tmp_path / ".trash" / ".undo" / token).exists()


def test_metadata_only_restore_moves_the_audio_instead_of_copying_it(tmp_path):
    paths = _recording(tmp_path)
    sf.write(str(paths.system_wav), np.arange(SR, dtype=np.int16), SR, subtype="PCM_16")  # bytes to recognise
    audio = {p.name: p.read_bytes() for p in paths.folder.glob("*.wav")}
    token = undo.take(tmp_path, "event", meetings=[ID])
    paths.speakers.write_text(json.dumps({"SPEAKER_00": "Bob"}))
    undo.sealed(tmp_path, token)
    undo.restore(tmp_path, token)
    assert json.loads(paths.speakers.read_text()) == {"SPEAKER_00": "Anna"}
    assert {p.name: p.read_bytes() for p in paths.folder.glob("*.wav")} == audio
    replaced = tmp_path / ".trash" / f"{ID}.undone-{token[:8]}"
    assert replaced.is_dir() and (replaced / "speakers.json").exists()
    assert not list(replaced.glob("*.wav"))  # no second copy of the audio in the trash


def test_restore_moves_back_a_trashed_meeting(tmp_path):
    paths = _recording(tmp_path)
    token = undo.take(tmp_path, "delete", meetings=[ID])
    dst = cutting.trash(paths)
    undo.moved(tmp_path, token, paths.folder, dst)
    undo.restore(tmp_path, token)
    assert paths.folder.is_dir() and paths.system_wav.exists() and paths.speakers.exists()
    assert not (tmp_path / ".trash" / ID).exists()


def test_restore_trashes_created_meetings(tmp_path):
    _recording(tmp_path)
    _recording(tmp_path, "2026-10-20T15-00-00")
    token = undo.take(tmp_path, "split", meetings=[ID])
    undo.created(tmp_path, token, ["2026-10-20T15-00-00"])
    undo.restore(tmp_path, token)
    assert not (tmp_path / "2026-10-20T15-00-00").exists()
    assert (tmp_path / ".trash" / "2026-10-20T15-00-00").is_dir()


def test_restore_puts_back_store_files(tmp_path):
    store = tmp_path / "projects.json"
    store.write_text('{"a": 1}')
    token = undo.take(tmp_path, "projects", stores=[store])
    store.write_text('{"a": 2}')
    undo.restore(tmp_path, token)
    assert store.read_text() == '{"a": 1}'


def test_restore_removes_a_store_file_that_did_not_exist(tmp_path):
    store = tmp_path / "projects.json"
    token = undo.take(tmp_path, "projects", stores=[store])
    store.write_text("{}")
    undo.restore(tmp_path, token)
    assert not store.exists()


def test_speaker_files_of_all_meetings_only(tmp_path):
    a, b = _recording(tmp_path), _recording(tmp_path, "2026-10-20T15-00-00")
    token = undo.take(tmp_path, "voices", speaker_files_of_all=True)
    snap = tmp_path / ".trash" / ".undo" / token / "meetings"
    assert sorted(p.name for p in snap.rglob("*") if p.is_file()) == ["speakers.json", "speakers.json"]
    a.speakers.write_text("{}")
    b.speakers.unlink()
    undo.sealed(tmp_path, token)
    undo.restore(tmp_path, token)
    assert json.loads(a.speakers.read_text()) == {"SPEAKER_00": "Anna"} and b.speakers.exists()
    assert a.transcript_json.exists()


def test_restore_unknown_token_raises_not_found(tmp_path):
    with pytest.raises(undo.Gone):
        undo.restore(tmp_path, "0" * 32)
    with pytest.raises(undo.Gone):
        undo.restore(tmp_path, "../../x")


def test_restore_refused_when_meeting_changed_since(tmp_path):
    paths = _recording(tmp_path)
    token = undo.take(tmp_path, "rename", meetings=[ID])
    paths.speakers.write_text("{}")
    _later(paths.speakers)
    with pytest.raises(undo.Changed):
        undo.restore(tmp_path, token)
    assert paths.speakers.read_text() == "{}"
    assert (tmp_path / ".trash" / ".undo" / token).exists()


def test_the_my_notes_lock_is_no_change_to_a_meeting(tmp_path):
    """Writing my notes (#44) leaves a lock file behind; an undo of an earlier change still works."""
    paths = _recording(tmp_path)
    token = undo.take(tmp_path, "rename", meetings=[ID])
    paths.speakers.write_text(json.dumps({"SPEAKER_00": "Bob"}))
    undo.sealed(tmp_path, token)
    (paths.folder / ".my-notes.lock").touch()
    assert undo.restore(tmp_path, token) == [ID]


def test_a_write_in_progress_is_no_part_of_a_snapshot(tmp_path, monkeypatch):
    """My notes save while you type: their temporary file can vanish while
    a change takes its snapshot, which must not fail the change."""
    paths = _recording(tmp_path)
    (paths.folder / ".my-notes.json.123.tmp").write_text("[]")
    copytree = shutil.copytree

    def racing(src, dst, *a, **k):
        def copy(s, d, **kw):  # the save finishes while the folder is copied
            if s.endswith(".tmp"):
                Path(s).unlink(missing_ok=True)
            return shutil.copy2(s, d, **kw)
        return copytree(src, dst, *a, copy_function=copy, **k)

    monkeypatch.setattr(shutil, "copytree", racing)
    token = undo.take(tmp_path, "event", meetings=[ID])
    undo.sealed(tmp_path, token)
    assert undo.restore(tmp_path, token) == [ID]


def test_restore_refused_when_meeting_changed_after_the_change(tmp_path):
    paths = _recording(tmp_path)
    token = undo.take(tmp_path, "rename", meetings=[ID])
    paths.speakers.write_text("{}")
    undo.sealed(tmp_path, token)
    paths.notes.write_text("{}")
    _later(paths.notes)
    with pytest.raises(undo.Changed):
        undo.restore(tmp_path, token)


def test_older_undo_works_after_a_later_change_was_undone(tmp_path):
    paths = _recording(tmp_path)
    first = undo.take(tmp_path, "rename", meetings=[ID])
    paths.speakers.write_text(json.dumps({"SPEAKER_00": "Bob"}))
    undo.sealed(tmp_path, first)
    second = undo.take(tmp_path, "rename", meetings=[ID])
    paths.speakers.write_text(json.dumps({"SPEAKER_00": "Carl"}))
    undo.sealed(tmp_path, second)
    undo.restore(tmp_path, second)  # files rewritten with the same content: newer mtimes, no change
    for f in paths.folder.iterdir():
        _later(f)
    assert undo.restore(tmp_path, first) == [ID]
    assert json.loads(paths.speakers.read_text()) == {"SPEAKER_00": "Anna"}


def test_restore_refused_after_a_later_edit_of_the_same_size(tmp_path):
    paths = _recording(tmp_path)
    token = undo.take(tmp_path, "rename", meetings=[ID])
    paths.speakers.write_text(json.dumps({"SPEAKER_00": "Bob"}))
    undo.sealed(tmp_path, token)
    paths.speakers.write_text(json.dumps({"SPEAKER_00": "Rob"}))  # same size, other content, same mtime
    os.utime(paths.speakers, (0, 0))
    with pytest.raises(undo.Changed):
        undo.restore(tmp_path, token)


def test_partial_snapshot_checks_only_the_speaker_files(tmp_path):
    paths = _recording(tmp_path)
    other = _recording(tmp_path, "2026-10-20T15-00-00")
    token = undo.take(tmp_path, "voices", meetings=[ID], speaker_files_of_all=True)
    undo.sealed(tmp_path, token)
    other.notes.write_text("{}")  # not a speaker file: no reason to refuse
    assert "2026-10-20T15-00-00" in undo.restore(tmp_path, token)
    token = undo.take(tmp_path, "voices", meetings=[ID], speaker_files_of_all=True)
    undo.sealed(tmp_path, token)
    other.speakers.write_text(json.dumps({"SPEAKER_00": "Zoe"}))
    with pytest.raises(undo.Changed):
        undo.restore(tmp_path, token)


def test_snapshot_from_before_fingerprints_still_checks_mtimes(tmp_path):
    paths = _recording(tmp_path)
    token = undo.take(tmp_path, "rename", meetings=[ID])
    undo.sealed(tmp_path, token)
    manifest = tmp_path / ".trash" / ".undo" / token / "manifest.json"
    data = json.loads(manifest.read_text())
    data["meetings"][ID] = {"partial": False, "audio": False, "mtime": 0.0}
    manifest.write_text(json.dumps(data))
    with pytest.raises(undo.Changed):
        undo.restore(tmp_path, token)


def test_trash_twice_does_not_nest(tmp_path):
    paths = _recording(tmp_path)
    (tmp_path / ".trash" / ID).mkdir(parents=True)
    target = cutting.trash(paths)
    assert target == tmp_path / ".trash" / f"{ID}-2"
    assert not (tmp_path / ".trash" / ID / ID).exists()


def _set_time(tmp_path, token, when):
    manifest = tmp_path / ".trash" / ".undo" / token / "manifest.json"
    data = json.loads(manifest.read_text())
    data["time"] = when.isoformat()
    manifest.write_text(json.dumps(data))


def test_prune_keeps_newest_20_and_drops_old(tmp_path):
    now = datetime.now().astimezone()
    tokens = [undo.take(tmp_path, f"n{i}") for i in range(22)]
    for i, token in enumerate(tokens):
        _set_time(tmp_path, token, now - timedelta(minutes=30 - i))
    old = undo.take(tmp_path, "old")
    _set_time(tmp_path, old, now - timedelta(hours=25))
    undo.prune(tmp_path)
    left = {p.name for p in (tmp_path / ".trash" / ".undo").iterdir()}
    assert len(left) == 20 and old not in left
    assert left == set(tokens[2:])


def test_prune_leaves_a_snapshot_still_being_taken(tmp_path):
    fresh = tmp_path / ".trash" / ".undo" / ("a" * 32)
    (fresh / "meetings").mkdir(parents=True)
    stale = tmp_path / ".trash" / ".undo" / ("b" * 32)
    stale.mkdir()
    os.utime(stale, (1, 1))
    undo.prune(tmp_path)
    assert fresh.exists() and not stale.exists()


def test_restore_moves_replaced_files_to_the_trash(tmp_path):
    paths = _recording(tmp_path)
    store = tmp_path / "projects"
    store.mkdir()
    (store / "a.json").write_text("1")
    token = undo.take(tmp_path, "x", speaker_files_of_all=True, stores=[store])
    paths.speakers.write_text('{"edited": 1}')
    (store / "a.json").write_text("2")
    undo.sealed(tmp_path, token)
    undo.restore(tmp_path, token)
    aside = tmp_path / ".trash" / f"undone-{token[:8]}"
    assert json.loads((aside / ID / "speakers.json").read_text()) == {"edited": 1}
    assert (aside / "stores" / "0" / "projects" / "a.json").read_text() == "2"
    assert (store / "a.json").read_text() == "1"


# --- stores and made folders are checked too; the undone audio is dropped -------------

def test_restore_refused_when_a_store_changed_after_the_change(tmp_path):
    store = tmp_path / "projects.json"
    store.write_text(json.dumps({"assign": {"A": "x"}}))
    token = undo.take(tmp_path, "trash", stores=[store])
    store.write_text(json.dumps({"assign": {}}))  # the change
    undo.sealed(tmp_path, token)
    store.write_text(json.dumps({"assign": {"B": "y"}}))  # an unrelated later edit
    with pytest.raises(undo.Changed):
        undo.restore(tmp_path, token)
    assert json.loads(store.read_text()) == {"assign": {"B": "y"}}  # nothing lost
    assert (tmp_path / ".trash" / ".undo" / token).exists()


def test_restore_refused_when_a_store_folder_changed_after_the_change(tmp_path):
    voices = tmp_path / "voices"
    voices.mkdir()
    (voices / "anna.json").write_text("1")
    token = undo.take(tmp_path, "merge", stores=[voices])
    (voices / "anna.json").write_text("2")
    undo.sealed(tmp_path, token)
    (voices / "bob.json").write_text("3")
    with pytest.raises(undo.Changed):
        undo.restore(tmp_path, token)


def test_restore_refused_when_a_made_folder_changed_after_the_change(tmp_path):
    _recording(tmp_path)
    token = undo.take(tmp_path, "split", meetings=[ID])
    tail = _recording(tmp_path, "2026-10-20T15-00-00")  # the change made it
    undo.created(tmp_path, token, [tail.folder.name])
    undo.sealed(tmp_path, token)
    tail.speakers.write_text(json.dumps({"SPEAKER_00": "Zoe"}))  # named afterwards
    with pytest.raises(undo.Changed):
        undo.restore(tmp_path, token)
    assert tail.folder.is_dir()


def test_a_made_folder_trashed_since_is_no_reason_to_refuse(tmp_path):
    _recording(tmp_path)
    token = undo.take(tmp_path, "split", meetings=[ID])
    tail = _recording(tmp_path, "2026-10-20T15-00-00")
    undo.created(tmp_path, token, [tail.folder.name])
    undo.sealed(tmp_path, token)
    cutting.trash(tail)
    assert undo.restore(tmp_path, token) == [ID]


def test_undoing_store_changes_in_order_still_works(tmp_path):
    store = tmp_path / "projects.json"
    store.write_text('{"v": 1}')
    first = undo.take(tmp_path, "a", stores=[store])
    store.write_text('{"v": 2}')
    undo.sealed(tmp_path, first)
    second = undo.take(tmp_path, "b", stores=[store])
    store.write_text('{"v": 3}')
    undo.sealed(tmp_path, second)
    with pytest.raises(undo.Changed):  # out of order: the second change would be lost
        undo.restore(tmp_path, first)
    undo.restore(tmp_path, second)
    _later(store)  # the same content written again
    undo.restore(tmp_path, first)
    assert store.read_text() == '{"v": 1}'


def test_restore_refused_when_the_meeting_went_to_the_trash_since(tmp_path):
    paths = _recording(tmp_path)
    token = undo.take(tmp_path, "event", meetings=[ID])
    paths.speakers.write_text(json.dumps({"SPEAKER_00": "Bob"}))
    undo.sealed(tmp_path, token)
    cutting.trash(paths)
    with pytest.raises(undo.Changed):
        undo.restore(tmp_path, token)
    assert not paths.folder.exists()  # no audio-less second copy
    assert undo.restore(tmp_path, token, check=False) == [ID]  # a rollback still puts it back


def test_a_meeting_the_change_itself_removed_is_put_back(tmp_path):
    _recording(tmp_path)
    other = _recording(tmp_path, "2026-10-20T15-00-00")
    token = undo.take(tmp_path, "split", meetings=[ID, other.folder.name], audio=True)
    cutting.trash(other)  # e.g. joined into the tail
    undo.sealed(tmp_path, token)
    assert sorted(undo.restore(tmp_path, token)) == sorted([ID, other.folder.name])
    assert other.system_wav.exists()


def test_restore_of_an_audio_snapshot_drops_the_undone_audio(tmp_path):
    paths = _recording(tmp_path)
    token = undo.take(tmp_path, "cut", meetings=[ID], audio=True)
    sf.write(str(paths.system_wav), np.zeros(SR // 2, np.int16), SR, subtype="PCM_16")  # the cut
    paths.transcript_json.write_text('[{"cut": 1}]')
    undo.sealed(tmp_path, token)
    undo.restore(tmp_path, token)
    assert sf.info(str(paths.system_wav)).frames == SR
    replaced = tmp_path / ".trash" / f"{ID}.undone-{token[:8]}"
    assert json.loads((replaced / "transcript.json").read_text()) == [{"cut": 1}]  # the undone state stays
    assert not list(replaced.rglob("*.wav"))  # without its audio
