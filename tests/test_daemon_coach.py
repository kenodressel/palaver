"""The live coach in the daemon (#41, #42): started with each recording,
stopped with it, its talk line and nudge in the status."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from palaver.capture_recorder import _IncrementalTrackWriter
from palaver.daemon import read_status
from palaver.live_coach import LiveCoach
from palaver.paths import RecordingPaths

from .test_daemon import _daemon


class _FakeCoach:
    def __init__(self, folder):
        self.folder = folder
        self.started = self.stopped = False

    def start(self):
        self.started = True

    def stop(self):
        self.stopped = True

    def status(self):
        return {"talk": {"share": 0.7, "speaking": "me"}, "talk_text": "You 70 % of the last 10 min",
                "nudge": {"kind": "talk_share", "text": "You've talked 70 % of the last 10 min", "at": 640.0}}


def test_the_coach_runs_with_the_recording(tmp_path: Path):
    coaches = []
    d, sessions, _ = _daemon(tmp_path, lambda now: 10 <= now < 100,
                             live_coach=lambda folder: coaches.append(_FakeCoach(folder)) or coaches[-1])
    d.run(until=lambda: d.now() > 30)
    assert [c.folder for c in coaches] == [tmp_path / "rec0"]
    assert coaches[0].started and not coaches[0].stopped
    status = d.status()
    assert status["talk_text"] == "You 70 % of the last 10 min"
    assert status["nudge"]["text"] == "You've talked 70 % of the last 10 min"
    assert status["talk"]["speaking"] == "me"
    d.run(until=lambda: d.now() > 150)
    assert coaches[0].stopped
    assert d.status()["talk_text"] is None and d.status()["nudge"] is None


def test_a_coach_that_fails_to_start_does_not_stop_the_recording(tmp_path: Path):
    def broken(folder):
        raise RuntimeError("no")

    d, sessions, _ = _daemon(tmp_path, lambda now: 10 <= now < 100, live_coach=broken)
    d.run(until=lambda: d.now() > 30)
    assert d.status()["state"] == "recording"
    assert d.status()["talk_text"] is None


def test_daemon_status_says_the_talk_line_and_the_nudge(tmp_path: Path):
    import os

    state = tmp_path / "daemon.json"
    state.write_text(json.dumps({"pid": os.getpid(), "state": "recording", "since": "2026-10-30T10:00:00+01:00",
                                 "folder": "/x/2026-10-30T10-00-00", "talk_text": "You 70 % of the last 10 min",
                                 "nudge": {"text": "4-min monologue"}}))
    assert read_status(state).splitlines()[1:] == ["  You 70 % of the last 10 min", "  Coach: 4-min monologue"]


# --- the real coach over a replayed recording --------------------------------------------------

SR = 16_000


def _speech(seconds: float, rng) -> np.ndarray:
    n = int(seconds * SR)
    t = np.arange(n) / SR
    env = (0.55 + 0.45 * np.sin(2 * np.pi * 4 * t)) * ((t % 2.8) < 2.5)
    return rng.standard_normal(n) * env * 2000


def test_a_replayed_monologue_gets_its_nudge(tmp_path: Path):
    """Four minutes of the user talking, written as the recorder would, with
    the others' echo-free system track silent: the coach says so once."""
    rng = np.random.default_rng(3)
    paths = RecordingPaths(tmp_path)
    mic_w, sys_w = _IncrementalTrackWriter(paths.mic_raw_wav), _IncrementalTrackWriter(paths.system_wav)
    clock = [0.0]
    coach = LiveCoach(tmp_path, clock=lambda: clock[0], enabled=lambda: {},
                      names=lambda paths, invitees: ({}, {}))
    mic = np.clip(_speech(250, rng) + rng.standard_normal(250 * SR) * 20, -32768, 32767).astype(np.int16)
    nudges = []
    try:
        step = SR  # a second at a time
        for i in range(0, len(mic), step):
            mic_w.write_chunk_at_offset(i, mic[i:i + step])
            mic_w.flush()
            clock[0] += 1.0
            coach.monitor.poll()
            nudge = coach.status()["nudge"]
            if nudge and (not nudges or nudges[-1] != nudge):
                nudges.append(nudge)
    finally:
        mic_w.abort()
        sys_w.abort()
    assert [n["text"] for n in nudges] == ["3-min monologue"]
    assert nudges[0]["at"] == pytest.approx(180, abs=2)
    assert "talking for 4:" in coach.status()["talk_text"]


def test_build_daemon_gives_each_recording_a_live_coach(monkeypatch, tmp_path: Path):
    import palaver.daemon as daemon
    from palaver import settings
    from palaver.config import Config

    monkeypatch.setattr(daemon, "STATE_PATH", tmp_path / "daemon.json")
    monkeypatch.setattr(daemon, "_event_now", lambda cfg: None)  # never the real calendar
    cfg = Config(user_name="K", notion_token="t", notion_parent_page_id="p", hf_token=None,
                 output_dir=tmp_path, retention_days=14, max_session_hours=4, grace_period_seconds=10,
                 transcriber="parakeet-mlx", whisper_repo="w", diarizer_repo="d", language="auto",
                 live_processing=False, record_slack=False)
    d = daemon.build_daemon(cfg)
    coach = d._new_coach(tmp_path / "rec")
    assert isinstance(coach, LiveCoach)
    settings.save(settings.Settings(nudge_monologue=False))
    assert coach._enabled()["monologue"] is False
    from palaver import coach as coach_mod

    monkeypatch.setattr(coach_mod, "history", lambda *a, **kw: (_ for _ in ()).throw(AssertionError("read meetings")))
    assert daemon._coach_context(cfg)["baseline"] is None  # nothing saved yet, and no meeting is read
    coach_mod.baseline_path().parent.mkdir(parents=True, exist_ok=True)
    coach_mod.baseline_path().write_text(json.dumps({"baseline": {"meetings": 7}}))
    assert daemon._coach_context(cfg)["baseline"] == {"meetings": 7}


def test_the_context_loads_after_the_first_minute_and_never_after_a_stop(tmp_path: Path):
    import threading

    loaded = threading.Event()
    coach = LiveCoach(tmp_path, context=lambda: loaded.set() or {"invitees": ["Valerie"], "kind": "1:1",
                                                                   "baseline": {"meetings": 3}})
    coach.start(context_after=0.05)
    assert loaded.wait(2)
    import time

    deadline = time.monotonic() + 2
    while coach.nudges.kind is None and time.monotonic() < deadline:
        time.sleep(0.01)
    coach.stop()
    assert coach._invitees == ["Valerie"] and coach.nudges.kind == "1:1"
    late = threading.Event()
    coach = LiveCoach(tmp_path, context=lambda: late.set() or {})
    coach.start(context_after=0.2)
    coach.stop()
    assert not late.wait(0.4)


def test_no_coach_for_a_recording_started_by_hand(tmp_path: Path):
    """A manual recording may be in person, with nobody on the system track:
    no talk share, no nudges."""
    coaches = []
    d, sessions, _ = _daemon(tmp_path, lambda now: False,
                             live_coach=lambda folder: coaches.append(_FakeCoach(folder)) or coaches[-1])
    assert d.start_manual()
    assert coaches == [] and d.status()["talk_text"] is None
    d.stop_manual()


def test_pace_and_fillers_are_read_once_a_second(tmp_path: Path, monkeypatch):
    from palaver import live_coach

    clock = [0.0]
    calls = []
    monkeypatch.setattr(live_coach, "pace_and_fillers", lambda mine, until: calls.append(until))
    coach = LiveCoach(tmp_path, clock=lambda: clock[0], names=lambda paths, invitees: ({}, {}))
    for _ in range(12):  # polled every 0.25 s for 3 s
        coach.monitor.poll()
        clock[0] += 0.25
    assert len(calls) == 3


def test_stopping_the_coach_never_blocks_the_tick(tmp_path: Path):
    import threading
    import time

    entered, release = threading.Event(), threading.Event()
    coach = LiveCoach(tmp_path, context=lambda: release.wait(5) and {}, names=lambda paths, invitees: ({}, {}))

    def slow(monitor):
        entered.set()
        release.wait(5)

    coach.monitor._on_poll = slow
    coach.start(context_after=0.0)
    coach.monitor._interval = 0.01
    assert entered.wait(2)
    started = time.monotonic()
    coach.stop()
    assert time.monotonic() - started < 0.1
    release.set()
    assert coach.stopped.wait(3)  # both threads joined, off the tick
