"""`palaver coach <folder>` (Task 13): the live coach as a worker of its own. It writes
<folder>/coach.json every second with the status the daemon shows (talk, talk_text, nudge,
quiet) and ends with the recording or on SIGTERM. Synthetic audio only, no calendar."""

from __future__ import annotations

import json
import threading
import time
from pathlib import Path

import numpy as np

from palaver import cli, live_coach
from palaver.capture_recorder import _IncrementalTrackWriter
from palaver.live_coach import LiveCoach
from palaver.paths import RecordingPaths

SR = 16_000


def _speech(seconds: float, rng) -> np.ndarray:
    n = int(seconds * SR)
    t = np.arange(n) / SR
    env = (0.55 + 0.45 * np.sin(2 * np.pi * 4 * t)) * ((t % 2.8) < 2.5)
    return rng.standard_normal(n) * env * 2000


def _wait(cond, timeout=10.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        value = cond()
        if value:
            return value
        time.sleep(0.02)
    raise AssertionError("timed out")


def _read(path: Path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def test_coach_worker_writes_status(tmp_path: Path):
    rng = np.random.default_rng(5)
    paths = RecordingPaths(tmp_path)
    mic_w, sys_w = _IncrementalTrackWriter(paths.mic_raw_wav), _IncrementalTrackWriter(paths.system_wav)
    mic = np.clip(_speech(20, rng) + rng.standard_normal(20 * SR) * 20, -32768, 32767).astype(np.int16)
    mic_w.write_chunk_at_offset(0, mic)
    sys_w.write_chunk_at_offset(0, np.zeros(20 * SR, dtype=np.int16))
    mic_w.flush()
    sys_w.flush()
    coach = LiveCoach(tmp_path, enabled=lambda: {}, names=lambda paths, invitees: ({}, {}))
    stop = threading.Event()
    result = []
    t = threading.Thread(target=lambda: result.append(live_coach.run_coach(
        tmp_path, coach=coach, stop=stop, every=0.05, context_after=3600)))
    t.start()
    try:
        status = _wait(lambda: (s := _read(paths.folder / "coach.json")) and s["talk"] and s)
        assert sorted(status) == ["nudge", "quiet", "talk", "talk_text"]
        assert status["talk"]["speaking"] == "me"
        assert status["talk_text"] == live_coach.talk_text(status["talk"]) and status["nudge"] is None and status["quiet"] == []
        assert not list(tmp_path.glob("*.tmp"))  # written atomically
        # The recording ends: both tracks final, meta.json there: the worker ends by itself.
        mic_w.finalize_to(20 * SR)
        sys_w.finalize_to(20 * SR)
        (tmp_path / "meta.json").write_text("{}")
        t.join(timeout=10)
        assert not t.is_alive() and result == [0]
        assert not (tmp_path / "coach.json").exists()
    finally:
        stop.set()
        t.join(timeout=5)


def test_coach_worker_ends_on_sigterm_flag(tmp_path: Path):
    paths = RecordingPaths(tmp_path)
    w = _IncrementalTrackWriter(paths.mic_raw_wav)
    coach = LiveCoach(tmp_path, names=lambda paths, invitees: ({}, {}))
    stop = threading.Event()
    t = threading.Thread(target=lambda: live_coach.run_coach(tmp_path, coach=coach, stop=stop, every=0.05,
                                                             context_after=3600))
    t.start()
    _wait(lambda: (tmp_path / "coach.json").exists())
    assert _read(tmp_path / "coach.json") == {"talk": None, "talk_text": None, "nudge": None, "quiet": []}
    stop.set()
    t.join(timeout=10)
    assert not t.is_alive()
    w.abort()


def test_nudge_switches_come_from_settings(tmp_path: Path, monkeypatch):
    from palaver import settings

    monkeypatch.setattr(settings, "settings_path", lambda: tmp_path / "settings.json", raising=False)
    s = settings.Settings(nudge_monologue=False)
    assert live_coach.enabled_kinds(s)["monologue"] is False
    assert callable(live_coach.settings_switches)


def test_the_coach_command_is_parsed():
    args = cli.build_parser().parse_args(["coach", "/x/rec"])
    assert args.func is cli._cmd_coach and args.folder == "/x/rec"


def _orphan_run(tmp_path, **kw):
    paths = RecordingPaths(tmp_path)
    w = _IncrementalTrackWriter(paths.mic_raw_wav)
    w.flush()
    coach = LiveCoach(tmp_path, names=lambda paths, invitees: ({}, {}))
    stop = threading.Event()
    result = []
    t = threading.Thread(target=lambda: result.append(live_coach.run_coach(
        tmp_path, coach=coach, stop=stop, every=0.02, context_after=3600, **kw)))
    t.start()
    return t, stop, w, result


def test_coach_worker_ends_when_its_parent_is_gone(tmp_path: Path):
    alive = [True]
    t, stop, w, result = _orphan_run(tmp_path, parent_alive=lambda: alive[0])
    try:
        _wait(lambda: (tmp_path / "coach.json").exists())
        alive[0] = False
        t.join(timeout=10)
        assert not t.is_alive() and result == [0]
        assert not (tmp_path / "coach.json").exists()
    finally:
        stop.set()
        t.join(timeout=5)
        w.abort()


def test_coach_worker_ends_when_the_recording_stops_growing(tmp_path: Path):
    t, stop, w, result = _orphan_run(tmp_path, stall=0.3, parent_alive=lambda: True)
    try:
        t.join(timeout=10)  # the .part never grows and is never finished
        assert not t.is_alive() and result == [0]
        assert not (tmp_path / "coach.json").exists()
    finally:
        stop.set()
        t.join(timeout=5)
        w.abort()


def test_coach_worker_keeps_going_while_the_recording_grows(tmp_path: Path):
    t, stop, w, result = _orphan_run(tmp_path, stall=0.5, parent_alive=lambda: True)
    try:
        for i in range(30):
            w.write_chunk_at_offset(i * 160, np.zeros(160, dtype=np.int16))
            w.flush()
            time.sleep(0.03)
        assert t.is_alive()
    finally:
        stop.set()
        t.join(timeout=5)
        w.abort()


def test_coach_worker_ends_when_the_folder_is_gone(tmp_path: Path):
    import shutil

    folder = tmp_path / "rec"
    folder.mkdir()
    t, stop, w, result = _orphan_run(folder, parent_alive=lambda: True)
    try:
        _wait(lambda: (folder / "coach.json").exists())
        w._fh.close()
        shutil.rmtree(folder)
        t.join(timeout=10)
        assert not t.is_alive()
        assert not (folder / "coach.json").exists()
    finally:
        stop.set()
        t.join(timeout=5)
