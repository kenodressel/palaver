"""The store locks Python's writers take (Swift's StoreLock takes the same files)."""

from __future__ import annotations

import fcntl
import json
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

from palaver import glossary, inference, organizations, people, projects, speakers, undo, voices
from palaver.attribution import Evidence
from palaver.paths import RecordingPaths
from palaver.store_lock import locked, meeting_lock

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / "native" / ".build" / "debug" / "palaver-parity"
ID = "2026-10-20T14-35-17"


def _probe_held(lock: Path) -> bool:
    """Is ``lock`` held by someone (this process included: a new open file description conflicts)?"""
    fd = os.open(lock, os.O_WRONLY | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return True
    else:
        fcntl.flock(fd, fcntl.LOCK_UN)
        return False
    finally:
        os.close(fd)


CHILD = """
import sys, time
from pathlib import Path
from palaver.store_lock import locked
with locked(Path(sys.argv[1])):
    Path(sys.argv[2]).write_text("held")
    time.sleep(float(sys.argv[3]))
"""


def test_the_lock_file_sits_beside_the_store(tmp_path):
    with locked(tmp_path / "projects.json"):
        assert (tmp_path / "projects.json.lock").exists()
    with locked(tmp_path / "voices"):
        assert (tmp_path / "voices.lock").exists()
    with meeting_lock(tmp_path / ID):  # the folder is made when it is missing
        assert (tmp_path / ID / ".speakers.lock").exists()
    umask = os.umask(0)
    os.umask(umask)
    assert (tmp_path / "voices.lock").stat().st_mode & 0o777 == 0o644 & ~umask
    assert not _probe_held(tmp_path / "voices.lock")  # let go again


def test_two_processes_take_turns(tmp_path):
    store, flag = tmp_path / "glossary.json", tmp_path / "flag"
    child = subprocess.Popen([sys.executable, "-c", CHILD, str(store), str(flag), "0.6"], cwd=ROOT)
    try:
        deadline = time.monotonic() + 20
        while not flag.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        assert flag.exists(), "the other process never took the lock"
        started = time.monotonic()
        with locked(store):
            waited = time.monotonic() - started
        assert waited > 0.2
    finally:
        child.wait(timeout=20)


def test_lock_is_reentrant_in_one_thread(tmp_path):
    store = tmp_path / "projects.json"
    with locked(store):
        with locked(store):  # no deadlock
            assert _probe_held(tmp_path / "projects.json.lock")
        assert _probe_held(tmp_path / "projects.json.lock")  # the inner exit did not let go
    assert not _probe_held(tmp_path / "projects.json.lock")


def test_one_thread_never_holds_two_different_locks(tmp_path):
    with locked(tmp_path / "a.json"), pytest.raises(AssertionError):
        with locked(tmp_path / "b.json"):
            pass
    with locked(tmp_path / "a.json"):  # and the failed attempt left the first one working
        pass


def test_a_lock_that_cannot_be_taken_raises_and_the_body_never_runs(tmp_path):
    (tmp_path / "projects.json.lock").mkdir()  # a directory cannot be opened for writing
    ran = []
    with pytest.raises(OSError):
        with locked(tmp_path / "projects.json"):
            ran.append(1)
    assert not ran
    with pytest.raises(OSError):
        projects.ProjectStore(tmp_path / "projects.json").save()
    assert not (tmp_path / "projects.json").exists()


def test_projects_suggest_reloads_under_the_lock(tmp_path):
    folder = RecordingPaths(tmp_path / "rec" / ID)
    folder.folder.mkdir(parents=True)
    folder.meta.write_text(json.dumps({"start_time": "2026-10-20T14:35:17+02:00", "duration_seconds": 60}))
    folder.transcript_json.write_text("[]")
    path = tmp_path / "projects.json"
    store = projects.ProjectStore(path)
    pid = store.create("Foundry")
    store.save()
    held_during_run = []

    def run(prompt, schema):
        held_during_run.append(_probe_held(tmp_path / "projects.json.lock"))
        other = projects.ProjectStore(path)  # the window renames while the model "thinks"
        other.update(pid, name="Foundry Migration")
        other.save()
        return {"new_projects": [{"key": "n1", "name": "Hiring", "description": ""}],
                "assignments": [{"meeting": ID, "projects": ["n1"]}], "descriptions": []}

    added = projects.suggest_with_model(tmp_path / "rec", store, run, user_name="Timo")
    assert held_during_run == [False]  # never a lock during the model run
    saved = projects.ProjectStore(path)
    assert saved.projects()[pid]["name"] == "Foundry Migration"  # their change survived
    assert saved.find("Hiring") and added == [(ID, saved.find("Hiring"))]  # and ours


def test_a_change_made_since_the_store_was_read_survives_the_helpers(tmp_path):
    """The helpers never write back this process's older copy before the model runs."""
    folder = RecordingPaths(tmp_path / "rec" / ID)
    folder.folder.mkdir(parents=True)
    folder.meta.write_text(json.dumps({"start_time": "2026-10-20T14:35:17+02:00", "duration_seconds": 60}))
    folder.transcript_json.write_text("[]")
    path = tmp_path / "projects.json"
    first = projects.ProjectStore(path)
    pid = first.create("Foundry")
    first.assign(ID, pid)
    first.save()
    other_id = first.create("Hiring")
    first.save()
    stale = projects.ProjectStore(path)  # read here, before the window changes things
    window = projects.ProjectStore(path)
    window.update(pid, name="Foundry Migration")
    window.save()
    seen = []

    def run(prompt, schema):
        seen.append(json.loads(path.read_text())["projects"][pid]["name"])  # still the window's
        return {"description": "About it.", "new_projects": [], "assignments": [], "descriptions": []}

    projects.describe_with_model(tmp_path / "rec", stale, pid, run, user_name="Timo")
    assert seen == ["Foundry Migration"]
    assert projects.ProjectStore(path).projects()[pid]["name"] == "Foundry Migration"
    stale = projects.ProjectStore(path)
    window = projects.ProjectStore(path)
    window.update(other_id, name="Recruiting")
    window.save()
    seen.clear()
    stale._data["meetings"].pop(ID)  # a meeting the model is asked about
    projects.suggest_with_model(tmp_path / "rec", stale, run, user_name="Timo")
    assert seen == ["Foundry Migration"]
    assert projects.ProjectStore(path).projects()[other_id]["name"] == "Recruiting"


def test_describe_reloads_under_the_lock_too(tmp_path):
    folder = RecordingPaths(tmp_path / "rec" / ID)
    folder.folder.mkdir(parents=True)
    folder.meta.write_text(json.dumps({"start_time": "2026-10-20T14:35:17+02:00", "duration_seconds": 60}))
    folder.transcript_json.write_text("[]")
    path = tmp_path / "projects.json"
    store = projects.ProjectStore(path)
    pid = store.create("Foundry")
    other_pid = store.create("Other")
    store.assign(ID, pid)
    store.save()

    def run(prompt, schema):
        other = projects.ProjectStore(path)
        other.update(other_pid, name="Renamed")
        other.save()
        return {"description": "About foundry."}

    projects.describe_with_model(tmp_path / "rec", store, pid, run, user_name="Timo")
    saved = projects.ProjectStore(path)
    assert saved.projects()[pid]["description"] == "About foundry."
    assert saved.projects()[other_pid]["name"] == "Renamed"


def test_undo_ignores_the_speakers_lock(tmp_path):
    folder = tmp_path / ID
    folder.mkdir()
    paths = RecordingPaths(folder)
    paths.meta.write_text(json.dumps({"start_time": "2026-10-20T14:35:17+02:00", "duration_seconds": 1}))
    paths.speakers.write_text(json.dumps({"SPEAKER_00": "Anna"}))
    token = undo.take(tmp_path, "rename", meetings=[ID])
    paths.speakers.write_text(json.dumps({"SPEAKER_00": "Bob"}))
    undo.sealed(tmp_path, token)
    with meeting_lock(folder):  # a writer leaves the lock file behind
        pass
    assert (folder / ".speakers.lock").exists()
    assert undo.restore(tmp_path, token) == [ID]
    assert json.loads(paths.speakers.read_text()) == {"SPEAKER_00": "Anna"}


# --- every writer -------------------------------------------------------------------------


def _lock_of(file: Path) -> Path:
    """The lock a write to ``file`` belongs under."""
    name = file.name.removesuffix(".tmp")
    if file.parent.name == "voices":
        return file.parent.parent / "voices.lock"
    if name.startswith(("speakers", "transcript", "meta")) or (file.parent / ".speakers.lock").exists():
        return file.parent / ".speakers.lock"
    return file.parent / (name + ".lock")


@pytest.fixture
def writes(monkeypatch):
    """Every write_text/unlink/replace under the test's folders, with whether its lock was held."""
    seen: list[tuple[str, Path, bool]] = []
    for method in ("write_text", "unlink", "replace"):
        original = getattr(Path, method)

        def spy(self, *a, _original=original, _method=method, **k):
            if not self.name.endswith(".lock"):
                seen.append((_method, self, _probe_held(_lock_of(self))))
            return _original(self, *a, **k)

        monkeypatch.setattr(Path, method, spy)
    return seen


def _meeting(root: Path) -> RecordingPaths:
    paths = RecordingPaths(root / ID)
    paths.folder.mkdir(parents=True)
    paths.meta.write_text(json.dumps({"start_time": "2026-10-20T14:35:17+02:00", "duration_seconds": 60}))
    paths.system_turns.write_text(json.dumps([{"speaker": "SPEAKER_00", "start": 0, "end": 5},
                                              {"speaker": "SPEAKER_01", "start": 5, "end": 9}]))
    paths.transcript_json.write_text("[]")
    paths.speaker_embeddings.write_text(json.dumps({"SPEAKER_00": [1.0, 0.0], "SPEAKER_01": [0.0, 1.0]}))
    paths.live.write_text(json.dumps({"embeddings": {"L0": [1.0, 0.0]}}))
    return paths


def test_every_store_writer_takes_its_lock(tmp_path, isolated_config_home, writes):
    root = tmp_path / "rec"
    paths = _meeting(root)
    bank = voices.VoiceBank()
    config = isolated_config_home / "palaver"

    def store_saves():
        g = glossary.Glossary(config / "glossary.json")
        g.add("Contoso")
        g.save()
        o = organizations.Organizations(config / "organizations.json")
        o.rename("contoso", "Contoso Ltd")
        o.save()
        e = Evidence(config / "attributions.json")
        e.save()
        s = projects.ProjectStore(config / "projects.json")
        s.create("Foundry")
        s.save()

    def voice_bank():
        bank.add("Anna Müller", [1.0, 0.0], source=f"{ID}:SPEAKER_00")
        bank.add("Anna Müller", [0.9, 0.1], source=f"{ID}:SPEAKER_01")
        bank.rename("Anna Müller", "Anna Mueller")
        bank.rename("Anna Mueller", "Anna Berg")
        bank.remove_source(f"{ID}:SPEAKER_01")
        bank.remove_meeting(ID)
        bank.add("Timo Strauss", [0.0, 1.0], source="x:y")
        bank.forget("Timo Strauss")

    def speaker_files():
        speakers.set_ignored(paths, "SPEAKER_01")
        speakers.set_ignored(paths, "SPEAKER_01", False)
        speakers.set_unknown(paths, "SPEAKER_01")
        speakers.set_rejected_name(paths, "SPEAKER_00", "Tom")
        speakers.save_speaker_names(paths, {"SPEAKER_00": "Valerie"}, bank)
        speakers.merge_speakers(paths, "SPEAKER_01", "SPEAKER_00", bank)
        speakers.merge_speakers(paths, "SPEAKER_01", None, bank)
        speakers.name_live_speaker(paths, "L0", "Valerie")
        speakers.adopt_live_names(paths)

    def people_and_inference():
        people.rename_person(root, "Valerie", "Valerie Northwind")
        people.refresh_recognition(root, bank)
        inference.refresh(root, bank=bank)

    for writer in (store_saves, voice_bank, speaker_files, people_and_inference):
        before = len(writes)
        writer()
        mine = writes[before:]
        assert mine, f"{writer.__name__} wrote nothing"
        unlocked = [(m, str(p.relative_to(tmp_path)) if tmp_path in p.parents else str(p)) for m, p, held in mine if not held]
        assert unlocked == [], f"{writer.__name__} wrote without its lock: {unlocked}"
    names = {p.name for _, p, _ in writes}
    assert {"glossary.json.tmp", "organizations.json.tmp", "attributions.json.tmp", "projects.json.tmp",
            "speakers_ignored.json", "speakers_merged.json", "speakers.json", "speakers_live.json",
            "transcript.json"} <= names


@pytest.mark.skipif(not BIN.exists(), reason="native/.build/debug/palaver-parity is not built (make parity-helper)")
def test_python_waits_for_swift(tmp_path):
    from tools.parity import run

    py, sw = run.prepare(tmp_path, now=datetime(2026, 11, 4, 9, 0, tzinfo=ZoneInfo("Europe/Berlin")))
    store = sw / "config" / "palaver" / "projects.json"
    store.parent.mkdir(parents=True, exist_ok=True)
    env = {**os.environ, **run.ops.environment(sw)}
    child = subprocess.Popen([str(BIN), "hold-lock", "--side", str(sw), "--args",
                              json.dumps({"target": "config/palaver/projects.json"})],
                             env=env, stdout=subprocess.PIPE, text=True)
    try:
        lock = store.parent / "projects.json.lock"
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and not (lock.exists() and _probe_held(lock)):
            time.sleep(0.005)
        assert _probe_held(lock), "Swift never took the lock"
        started = time.monotonic()
        projects.ProjectStore(store).save()
        assert time.monotonic() - started > 0.15  # it waited for Swift's half second
        assert json.loads(child.communicate(timeout=20)[0]) == {"held": True}
    finally:
        child.kill()


def test_the_python_hold_lock_op_resolves_against_the_side_root(tmp_path):
    from tools.parity import ops

    side = ops.Side(tmp_path, tmp_path / "Recordings", tmp_path / "config" / "palaver", tmp_path / "home", "", [])
    started = time.monotonic()
    assert ops.hold_lock(side, {"target": "config/palaver/projects.json"}) == {"held": True}
    assert time.monotonic() - started >= 0.5
    assert (tmp_path / "config" / "palaver" / "projects.json.lock").exists()
    (tmp_path / "Recordings" / ID).mkdir(parents=True)
    ops.hold_lock(side, {"target": f"Recordings/{ID}", "meeting": True})
    assert (tmp_path / "Recordings" / ID / ".speakers.lock").exists()
