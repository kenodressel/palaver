"""Tests for the Teams auto-record daemon (issue #9)."""

import json
from datetime import datetime, timedelta
from pathlib import Path

import pytest

from palaver.daemon import Daemon, Trigger
from palaver.teams_detector import AudioProcess, CallDetector, teams_mic_active


def _proc(bundle, inp, out=False):
    return AudioProcess(pid=1, bundle_id=bundle, running_input=inp, running_output=out)


def test_teams_mic_active_only_counts_teams_input():
    assert teams_mic_active(lambda: [_proc("com.microsoft.teams2.helper", True)])
    assert not teams_mic_active(lambda: [_proc("com.microsoft.teams2.helper", False)])
    # Our own recorder's mic shows up under ScreenCaptureKit's replayd.
    assert not teams_mic_active(lambda: [_proc("com.apple.replayd", True)])


def test_call_detector_tells_teams_and_slack_apart_and_keeps_a_muted_huddle():
    now = []
    detect = CallDetector(lambda: now)
    now[:] = [_proc("com.tinyspeck.slackmacgap", False, out=True)]
    assert detect() is None  # a notification sound starts nothing
    now[:] = [_proc("com.tinyspeck.slackmacgap.helper", True, out=True)]
    assert detect() == "slack"
    now[:] = [_proc("com.tinyspeck.slackmacgap.helper", False, out=True)]
    assert detect() == "slack"  # muted in the huddle: the others still play
    now[:] = [_proc("com.tinyspeck.slackmacgap.helper", False)]
    assert detect() is None
    now[:] = [_proc("com.tinyspeck.slackmacgap.helper", False, out=True)]
    assert detect() is None  # the huddle ended: sound alone again
    now[:] = [_proc("com.microsoft.teams2.helper", True), _proc("com.tinyspeck.slackmacgap", True)]
    assert detect() == "teams"
    assert CallDetector(lambda: [_proc("com.tinyspeck.slackmacgap", True)], slack=lambda: False)() is None


def test_the_detector_logs_each_change_of_a_call_apps_audio(caplog):
    # When did Teams release the mic after the user hung up? The log says.
    now = [_proc("com.microsoft.teams2.helper", True, out=True)]
    detect = CallDetector(lambda: now)
    with caplog.at_level("INFO", logger="palaver.teams_detector"):
        detect()
        detect()  # no change: no line
        now[:] = [_proc("com.microsoft.teams2.helper", True)]
        detect()
        now[:] = []
        detect()
    lines = [r.getMessage() for r in caplog.records]
    assert lines == ["call apps' audio: com.microsoft.teams2.helper mic+speaker",
                     "call apps' audio: com.microsoft.teams2.helper mic",
                     "call apps' audio: none"]


def test_detector_skips_disabled_apps():
    teams, slack = [_proc("com.microsoft.teams2.helper", True)], [_proc("com.tinyspeck.slackmacgap", True)]
    assert CallDetector(lambda: teams, teams=lambda: False)() is None
    assert CallDetector(lambda: slack, slack=lambda: False)() is None
    assert CallDetector(lambda: teams + slack, teams=lambda: False)() == "slack"
    assert CallDetector(lambda: teams)() == "teams"


def test_the_app_that_took_the_mic_last_is_the_call():
    """Teams may hold the mic after hanging up: a huddle started since is the call."""
    now, clock = [], [0.0]
    detect = CallDetector(lambda: now, clock=lambda: clock[0])
    teams, huddle = _proc("com.microsoft.teams2.helper", True), _proc("com.tinyspeck.slackmacgap.helper", True)
    now[:] = [teams]
    assert detect() == "teams"
    clock[0] = 60
    now[:] = [teams, huddle]
    assert detect() == "slack"
    clock[0] = 70
    now[:] = [huddle, teams]
    assert detect() == "slack"  # the same two holders later: still the huddle
    now[:] = [huddle]
    clock[0] = 80
    assert detect() == "slack"
    now[:] = [huddle, teams]
    clock[0] = 90
    assert detect() == "teams"


def _run(trigger: Trigger, timeline: list[tuple[float, bool]]) -> list[tuple[float, str]]:
    out = []
    for now, active in timeline:
        for action in trigger.update(now, active):
            out.append((now, action))
    return out


def test_trigger_starts_after_debounce_and_stops_after_grace():
    t = Trigger(start_after=4, grace=10, max_session=4 * 3600)
    timeline = [(0, True), (2, True), (4, True), (6, True), (8, False), (16, False), (18, False)]
    assert _run(t, timeline) == [(4, "start"), (18, "stop")]


def test_brief_mic_use_does_not_start():
    t = Trigger(start_after=4, grace=10, max_session=3600)
    assert _run(t, [(0, True), (2, True), (3, False), (5, True), (7, False)]) == []


def test_short_release_within_grace_keeps_recording():
    """Device switch or a Teams audio restart briefly releases the mic."""
    t = Trigger(start_after=4, grace=10, max_session=3600)
    timeline = [(0, True), (4, True), (10, False), (14, False), (16, True), (30, True)]
    assert _run(t, timeline) == [(4, "start")]


def test_max_duration_stops_and_waits_for_release():
    t = Trigger(start_after=0, grace=10, max_session=100)
    timeline = [(0, True), (50, True), (100, True), (150, True), (160, False), (170, True)]
    assert _run(t, timeline) == [(0, "start"), (100, "stop"), (170, "start")]


class _FakeSession:
    def __init__(self, folder: Path, duration: float):
        self.folder, self.duration = folder, duration
        self.started = self.stopped = False
        self.stop_reason = None

    def start(self):
        self.started = True
        self.folder.mkdir(exist_ok=True)
        return self.folder

    def stop(self, reason=None):
        self.stopped, self.stop_reason = True, reason
        return self.duration


# The wall clock at the fake clock's 0: what daemon.json and the status show.
WALL0 = datetime.fromisoformat("2026-10-29T12:06:00+01:00")


def _daemon(tmp_path, activity, *, duration=600.0, sessions=None, start=0.0, **kwargs):
    """``start``: where the fake clock starts — a daemon started again after
    a restart goes on from where the last one quit (same ``sessions``)."""
    sessions = sessions if sessions is not None else []
    launched = []
    clock = [start]
    kwargs.setdefault("wall", lambda: WALL0 + timedelta(seconds=clock[0]))
    kwargs.setdefault("trigger", Trigger(start_after=4, grace=10, max_session=3600))

    def _new_session(trigger):
        s = _FakeSession(tmp_path / f"rec{len(sessions)}", duration)
        s.trigger = trigger
        sessions.append(s)
        return s

    def _sleep(seconds):
        clock[0] += seconds

    d = Daemon(
        detect=lambda: activity(clock[0]),
        new_session=_new_session,
        launch_processing=lambda folder: launched.append(folder) or _Done(),
        state_path=tmp_path / "state.json",
        poll_seconds=2,
        clock=lambda: clock[0],
        sleep=_sleep,
        **kwargs,
    )
    return d, sessions, launched


class _Done:
    def poll(self):
        return 0


def test_daemon_records_a_meeting_and_queues_processing(tmp_path: Path, sent_notifications):
    d, sessions, launched = _daemon(tmp_path, lambda now: 10 <= now < 700)
    d.run(until=lambda: d.now() > 760)

    assert len(sessions) == 1 and sessions[0].started and sessions[0].stopped
    assert launched == [tmp_path / "rec0"]
    assert [title for title, _ in sent_notifications] == ["Recording meeting", "Meeting recorded"]
    assert json.loads((tmp_path / "state.json").read_text())["state"] == "idle"


def test_daemon_skips_processing_very_short_sessions(tmp_path: Path):
    d, sessions, launched = _daemon(tmp_path, lambda now: 10 <= now < 40, duration=30.0)
    d.run(until=lambda: d.now() > 80)
    assert len(sessions) == 1 and launched == []


def test_daemon_survives_detector_errors(tmp_path: Path):
    def flaky(now):
        if 20 <= now < 26:
            raise OSError("coreaudiod restarting")
        return 10 <= now < 300

    d, sessions, _ = _daemon(tmp_path, flaky)
    d.run(until=lambda: d.now() > 360)
    assert len(sessions) == 1  # errors are treated as "no change", not as release


def test_daemon_stops_recording_on_shutdown(tmp_path: Path):
    d, sessions, launched = _daemon(tmp_path, lambda now: now >= 10)
    d.run(until=lambda: d.now() > 100)
    d.shutdown()
    assert sessions[0].stopped
    # Held back for the next start to continue (issue #47), not processed yet.
    assert launched == [] and json.loads((tmp_path / "state.json").read_text())["cut"]["folders"] == [str(tmp_path / "rec0")]


def test_state_file_reports_recording(tmp_path: Path):
    d, _, _ = _daemon(tmp_path, lambda now: now >= 10)
    d.run(until=lambda: d.now() > 30)
    state = json.loads((tmp_path / "state.json").read_text())
    assert state["state"] == "recording"
    assert state["folder"] == str(tmp_path / "rec0")
    d.shutdown()


def test_paused_daemon_ignores_teams_and_stops_running_auto_session(tmp_path: Path):
    d, sessions, launched = _daemon(tmp_path, lambda now: now >= 10)
    d.run(until=lambda: d.now() > 30)
    assert d.status()["state"] == "recording"

    d.set_auto(False)
    assert sessions[0].stopped and launched == [tmp_path / "rec0"]
    d.run(until=lambda: d.now() > 100)
    assert len(sessions) == 1
    assert d.status()["state"] == "paused"

    d.set_auto(True)
    d.run(until=lambda: d.now() > 120)
    assert len(sessions) == 2  # Teams still in a call → records again


def test_manual_session_is_not_stopped_by_teams_trigger(tmp_path: Path):
    d, sessions, launched = _daemon(tmp_path, lambda now: False)  # no Teams call
    d.start_manual()
    d.run(until=lambda: d.now() > 120)
    assert not sessions[0].stopped
    d.stop_manual()
    assert sessions[0].stopped and launched == [tmp_path / "rec0"]


def test_manual_start_while_auto_recording_is_a_noop(tmp_path: Path):
    d, sessions, _ = _daemon(tmp_path, lambda now: now >= 10)
    d.run(until=lambda: d.now() > 30)
    d.start_manual()
    assert len(sessions) == 1
    d.shutdown()


def test_status_snapshot(tmp_path: Path):
    d, _, _ = _daemon(tmp_path, lambda now: False)
    s = d.status()
    assert s["state"] == "idle" and s["auto"] is True and s["folder"] is None


def test_sessions_know_how_they_were_started(tmp_path: Path):
    d, sessions, _ = _daemon(tmp_path, lambda now: 10 <= now < 100)
    d.run(until=lambda: d.now() > 150)
    d.start_manual()
    d.stop_manual()
    assert [s.trigger for s in sessions] == ["teams", "manual"]


def test_queue_survives_restart(tmp_path: Path):
    """Quitting while one recording transcribes and another is queued must
    not lose the queued one."""
    done = tmp_path / "done"
    done.mkdir()
    (done / "notion.json").write_text("{}")
    pending = tmp_path / "pending"
    pending.mkdir()
    (tmp_path / "state.json").write_text(json.dumps(
        {"state": "stopped", "queued": [str(done), str(pending), str(tmp_path / "deleted")]}
    ))

    d, _, launched = _daemon(tmp_path, lambda now: False)
    d.run(until=lambda: d.now() > 4)

    assert launched == [pending]


def test_queue_without_auto_sync_is_done_once_transcribed(tmp_path: Path):
    """Without the Notion upload, a recording is done when its transcript is."""
    done = tmp_path / "done"
    done.mkdir()
    (done / "transcript.md").write_text("")
    pending = tmp_path / "pending"
    pending.mkdir()
    (tmp_path / "state.json").write_text(json.dumps({"state": "stopped", "queued": [str(done), str(pending)]}))

    d, _, launched = _daemon(tmp_path, lambda now: False, done_marker="transcript.md")
    d.run(until=lambda: d.now() > 4)

    assert launched == [pending]


def test_build_daemon_processes_locally_without_auto_sync(monkeypatch, tmp_path: Path):
    import palaver.daemon as daemon
    from palaver.config import Config

    monkeypatch.setattr(daemon, "STATE_PATH", tmp_path / "daemon.json")
    calls = []
    monkeypatch.setattr(daemon, "launch_run", lambda folder, opts, **kw: calls.append(kw.get("cmd", "run")))
    cfg = Config(user_name="K", notion_token="t", notion_parent_page_id="p", hf_token=None,
                 output_dir=tmp_path, retention_days=14, max_session_hours=4, grace_period_seconds=10,
                 transcriber="parakeet-mlx", whisper_repo="w", diarizer_repo="d", language="auto",
                 notion_auto_sync=False)
    daemon.build_daemon(cfg)._launch(tmp_path / "rec")
    assert calls == ["process"]


def test_launch_run_forwards_cli_options(monkeypatch, tmp_path: Path):
    import palaver.daemon as daemon

    calls = []
    monkeypatch.setattr(daemon.subprocess, "Popen", lambda argv, **kw: calls.append(argv))
    daemon.launch_run(tmp_path / "rec", ["--config", "/w.toml", "--no-notify"], log_path=tmp_path / "d.log")
    assert calls[0][-7:] == ["-m", "palaver", "--config", "/w.toml", "--no-notify", "run", str(tmp_path / "rec")]


def test_background_work_runs_at_low_priority(monkeypatch, tmp_path: Path):
    import palaver.daemon as daemon

    calls = []
    monkeypatch.setattr(daemon.subprocess, "Popen", lambda argv, **kw: calls.append(argv))
    daemon.launch_run(tmp_path / "rec", log_path=tmp_path / "d.log")
    daemon.launch_run(tmp_path / "rec", log_path=tmp_path / "d.log", cmd="live", qos="background")
    assert calls[0][:3] == ["/usr/sbin/taskpolicy", "-c", "utility"]
    assert calls[1][:3] == ["/usr/sbin/taskpolicy", "-c", "background"]
    assert calls[1][-2:] == ["live", str(tmp_path / "rec")]


def _live_daemon(tmp_path, live_busy_until):
    d, sessions, launched = _daemon(tmp_path, lambda now: 10 <= now < 700)
    live, stopped = [], []
    d._launch_live = live.append
    d._live_running = lambda folder: d.now() < live_busy_until
    d._stop_live = stopped.append
    return d, launched, live, stopped


def test_daemon_processes_live_and_waits_for_it_before_run(tmp_path: Path):
    """`run` after the live worker has written the transcript: it only merges."""
    d, launched, live, stopped = _live_daemon(tmp_path, live_busy_until=760)
    d.run(until=lambda: d.now() > 740)
    assert live == [tmp_path / "rec0"]  # started with the recording
    assert launched == []  # recording stopped at ~710, worker still finishing
    d.run(until=lambda: d.now() > 780)
    assert launched == [tmp_path / "rec0"] and stopped == []


def test_daemon_stops_a_stuck_live_worker(tmp_path: Path):
    d, launched, _, stopped = _live_daemon(tmp_path, live_busy_until=10**9)
    d.run(until=lambda: d.now() > 710 + 15 * 60 + 10)
    assert stopped == [tmp_path / "rec0"]
    assert launched == []  # waits for it to exit first
    d.run(until=lambda: d.now() > 710 + 15 * 60 + 80)
    assert stopped == [tmp_path / "rec0"]  # asked once
    assert launched == [tmp_path / "rec0"]  # it would not go: `process` decides (and is retried)


def test_daemon_warns_when_a_track_is_missing(tmp_path: Path, sent_notifications):
    """Recording continues with one track; the user must know right away."""
    d, sessions, _ = _daemon(tmp_path, lambda now: now >= 10)
    original = d._new_session

    def _degraded(trigger):
        s = original(trigger)
        s.missing = ["microphone"]
        return s

    d._new_session = _degraded
    d.run(until=lambda: d.now() > 30)
    titles = [t for t, _ in sent_notifications]
    assert "Recording without the microphone" in titles
    assert d.status()["missing"] == ["microphone"]
    d.shutdown()


def test_switching_from_teams_to_slack_records_two_meetings(tmp_path: Path, sent_notifications):
    def call(now):
        return "teams" if 10 <= now < 300 else "slack" if 300 <= now < 700 else None
    d, sessions, launched = _daemon(tmp_path, call)
    d.run(until=lambda: d.now() > 760)
    assert [s.trigger for s in sessions] == ["teams", "slack"]
    assert all(s.started and s.stopped for s in sessions)
    assert launched == [tmp_path / "rec0", tmp_path / "rec1"]


def test_a_slack_huddle_is_recorded_as_one(tmp_path: Path, sent_notifications):
    d, sessions, launched = _daemon(tmp_path, lambda now: "slack" if 10 <= now < 700 else None)
    d.run(until=lambda: d.now() > 760)
    assert [s.trigger for s in sessions] == ["slack"]


def test_daemon_starts_stream_only_when_realtime(tmp_path: Path):
    on = [True]
    d, sessions, launched = _daemon(tmp_path, lambda now: 10 <= now < 100 or 200 <= now < 300)
    streams = []
    d._launch_stream = streams.append
    d._realtime = lambda: on[0]
    d.run(until=lambda: d.now() > 150)
    on[0] = False
    d.run(until=lambda: d.now() > 400)
    assert len(sessions) == 2
    assert streams == [tmp_path / "rec0"]


def test_build_daemon_wires_stream_and_the_switches(monkeypatch, tmp_path: Path):
    import palaver.daemon as daemon
    from palaver import settings
    from palaver.config import Config
    import os

    monkeypatch.setattr(daemon, "STATE_PATH", tmp_path / "daemon.json")
    calls = []
    monkeypatch.setattr(daemon, "launch_run", lambda folder, opts, **kw: calls.append(kw))
    cfg = Config(user_name="K", notion_token="t", notion_parent_page_id="p", hf_token=None,
                 output_dir=tmp_path, retention_days=14, max_session_hours=4, grace_period_seconds=10,
                 transcriber="parakeet-mlx", whisper_repo="w", diarizer_repo="d", language="auto",
                 live_processing=False, record_slack=False)
    d = daemon.build_daemon(cfg)
    assert d._realtime() is True
    d._launch_stream(tmp_path / "rec")
    assert calls == [{"cmd": "stream", "qos": "utility"}]  # also without live processing
    settings.save(settings.Settings(realtime=False, record_slack=False))
    assert d._realtime() is False
    slack = [AudioProcess(pid=1, bundle_id="com.tinyspeck.slackmacgap", running_input=True, running_output=False)]
    d._detect._list = lambda: slack
    assert d._detect() is None  # the file says no Slack
    settings.save(settings.Settings(record_slack=True))
    p = settings.path()
    os.utime(p, (p.stat().st_atime + 5, p.stat().st_mtime + 5))
    assert d._detect() == "slack"  # the settings file wins, no restart


def test_build_daemon_live_processing_follows_the_settings_file(tmp_path: Path, monkeypatch):
    """#55: live processing is switched in the app (settings.json), read at
    each recording's start; config.toml's [processing].live is the default."""
    import os

    import palaver.daemon as daemon
    from palaver import settings
    from palaver.config import Config

    monkeypatch.setattr(daemon, "STATE_PATH", tmp_path / "daemon.json")
    calls = []
    monkeypatch.setattr(daemon, "launch_run", lambda folder, opts, **kw: calls.append(kw))
    cfg = Config(user_name="K", notion_token="t", notion_parent_page_id="p", hf_token=None,
                 output_dir=tmp_path, retention_days=14, max_session_hours=4, grace_period_seconds=10,
                 transcriber="parakeet-mlx", whisper_repo="w", diarizer_repo="d", language="auto",
                 live_processing=False)
    d = daemon.build_daemon(cfg)
    assert d._live() is False  # config.toml's default
    settings.update({"live_processing": True})
    p = settings.path()
    os.utime(p, (p.stat().st_atime + 5, p.stat().st_mtime + 5))
    assert d._live() is True
    d._launch_live(tmp_path / "rec")
    assert calls == [{"cmd": "live", "qos": "background"}]


def test_daemon_skips_live_processing_when_switched_off(tmp_path: Path):
    d, launched, live, stopped = _live_daemon(tmp_path, live_busy_until=0)
    d._live = lambda: True  # the control: switched on, it starts
    d.run(until=lambda: d.now() > 740)
    assert live == [tmp_path / "rec0"]
    (tmp_path / "off").mkdir()
    d, launched, live, stopped = _live_daemon(tmp_path / "off", live_busy_until=0)
    d._live = lambda: False
    d.run(until=lambda: d.now() > 740)
    assert live == []


def test_daemon_lets_a_test_recording_go_before_a_meeting(tmp_path: Path):
    """#55: the setup assistant's test recording stops before a meeting's starts."""
    order = []
    d, sessions, launched = _daemon(tmp_path, lambda now: 10 <= now < 700)
    d._before_record = lambda: _Gate(order)
    real = d._new_session

    def new_session(trigger):
        s = real(trigger)
        start = s.start
        s.start = lambda: order.append("start") or start()
        return s

    d._new_session = new_session
    d.run(until=lambda: d.now() > 40)
    assert order[:3] == ["test stopped", "start", "gate open"]


class _Gate:
    def __init__(self, order):
        self.order = order

    def __enter__(self):
        self.order.append("test stopped")

    def __exit__(self, *exc):
        self.order.append("gate open")


class _Running:
    """A background process that runs until ``done`` says otherwise."""

    def __init__(self, done=lambda: False, rc=0):
        self.done, self.rc, self.terminated = done, rc, False

    def poll(self):
        return self.rc if self.terminated or self.done() else None

    def terminate(self):
        self.terminated = True


def _notes_daemon(tmp_path, activity, *, processing_until=0.0, memory=lambda: 40.0, **kwargs):
    d, sessions, launched = _daemon(tmp_path, activity, memory_free_gb=memory, **kwargs)
    notes = []

    def _launch_notes(folder):
        p = _Running()
        notes.append((folder, p))
        return p

    d._launch = lambda folder: launched.append(folder) or _Running(lambda: d.now() >= processing_until)
    d._launch_notes = _launch_notes
    return d, sessions, launched, notes


def test_notes_wait_while_a_call_is_recorded(tmp_path: Path):
    """Back-to-back calls: the notes model (~10–18 GB) must not run during the next call."""
    d, sessions, launched, notes = _notes_daemon(
        tmp_path, lambda now: 10 <= now < 700 or 720 <= now < 1500, processing_until=800)
    d.run(until=lambda: d.now() > 1400)
    assert launched == [tmp_path / "rec0"]
    assert notes == []  # the transcript is done, the second call still records
    d.run(until=lambda: d.now() > 1560)
    assert [f for f, _ in notes] == [tmp_path / "rec0"]


def test_notes_wait_for_enough_free_memory(tmp_path: Path):
    free = [5.0]
    d, _, _, notes = _notes_daemon(tmp_path, lambda now: 10 <= now < 700, memory=lambda: free[0])
    d.run(until=lambda: d.now() > 800)
    assert notes == []
    free[0] = 30.0
    d.run(until=lambda: d.now() > 820)
    assert [f for f, _ in notes] == [tmp_path / "rec0"]



def test_notes_wait_for_the_memory_their_model_needs(tmp_path: Path):
    free = [15.0]
    d, _, _, notes = _notes_daemon(tmp_path, lambda now: 10 <= now < 700, memory=lambda: free[0])
    d._notes_memory_gb = 20.0
    d.run(until=lambda: d.now() > 800)
    assert notes == []  # a large model: 15 GB free is not enough
    d._notes_memory_gb = 12.0
    d.run(until=lambda: d.now() > 820)
    assert [f for f, _ in notes] == [tmp_path / "rec0"]


def test_claude_notes_never_wait_for_memory(tmp_path: Path):
    d, _, _, notes = _notes_daemon(tmp_path, lambda now: 10 <= now < 700, memory=lambda: 0.5,
                                   notes_memory_gb=0.0)
    d.run(until=lambda: d.now() > 800)
    assert [f for f, _ in notes] == [tmp_path / "rec0"]


@pytest.mark.parametrize("engine, model, needed", [
    ("local", "mlx-community/gemma-4-12B-it-OptiQ-4bit", 14.0),
    ("local", "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit", 20.0),
    ("local", "someone/unknown-model", 20.0),
    ("claude", "mlx-community/gemma-4-12B-it-OptiQ-4bit", 0.0),
])
def test_build_daemon_waits_for_the_configured_notes_model(monkeypatch, tmp_path: Path, engine, model, needed):
    import palaver.daemon as daemon
    from palaver.config import Config

    monkeypatch.setattr(daemon, "STATE_PATH", tmp_path / "daemon.json")
    cfg = Config(user_name="K", notion_token="t", notion_parent_page_id="p", hf_token=None,
                 output_dir=tmp_path, retention_days=14, max_session_hours=4, grace_period_seconds=10,
                 transcriber="parakeet-mlx", whisper_repo="w", diarizer_repo="d", language="auto",
                 notion_auto_sync=False, notes_engine=engine, notes_local_model=model)
    assert daemon.build_daemon(cfg)._memory_needed(tmp_path / "rec") == needed


def test_build_daemon_follows_the_notes_choice_made_in_settings(monkeypatch, tmp_path: Path):
    """The window changes the notes model while the daemon runs: the memory
    gate asks each time, per meeting (one kept on this Mac needs the local model)."""
    import palaver.daemon as daemon
    from palaver import keychain, llm, providers
    from palaver.config import Config

    monkeypatch.setattr(daemon, "STATE_PATH", tmp_path / "daemon.json")
    cfg = Config(user_name="K", notion_token="t", notion_parent_page_id="p", hf_token=None,
                 output_dir=tmp_path, retention_days=14, max_session_hours=4, grace_period_seconds=10,
                 transcriber="parakeet-mlx", whisper_repo="w", diarizer_repo="d", language="auto",
                 notion_auto_sync=False)
    d = daemon.build_daemon(cfg)
    rec, private = tmp_path / "rec", tmp_path / "private"
    rec.mkdir()
    private.mkdir()
    assert d._memory_needed(rec) == 14.0
    keychain.set(providers.key_account("anthropic"), "sk-ant-test-key-0123456789")
    providers.choose("notes", "anthropic")
    llm.set_local_only(private, True)
    assert d._memory_needed(rec) == 0.0
    assert d._memory_needed(private) == 14.0


def test_notes_wait_for_the_memory_of_the_meeting_next_in_line(tmp_path: Path):
    d, _, _, notes = _notes_daemon(tmp_path, lambda now: 10 <= now < 700, memory=lambda: 0.5,
                                   notes_memory_gb=lambda folder: 0.0 if folder.name == "rec0" else 20.0)
    d.run(until=lambda: d.now() > 800)
    assert [f for f, _ in notes] == [tmp_path / "rec0"]


def test_build_daemon_keeps_its_state_at_STATE_PATH(monkeypatch, tmp_path: Path):
    import palaver.daemon as daemon
    from palaver.config import Config

    rec = tmp_path / "rec"
    rec.mkdir()
    (rec / "transcript.md").write_text("")
    state = tmp_path / "daemon.json"
    state.write_text(json.dumps({"state": "idle", "queued": [], "notes_queued": [str(rec)]}))
    monkeypatch.setattr(daemon, "STATE_PATH", state)
    cfg = Config(user_name="K", notion_token="t", notion_parent_page_id="p", hf_token=None,
                 output_dir=tmp_path, retention_days=14, max_session_hours=4, grace_period_seconds=10,
                 transcriber="parakeet-mlx", whisper_repo="w", diarizer_repo="d", language="auto",
                 notion_auto_sync=False)
    d = daemon.build_daemon(cfg)
    assert d._state_path == state and d._notes_queue == [rec]


def test_a_call_starting_pauses_the_notes_and_they_resume_after(tmp_path: Path):
    d, _, _, notes = _notes_daemon(tmp_path, lambda now: 10 <= now < 700 or 900 <= now < 1500)
    d.run(until=lambda: d.now() > 800)
    first = notes[0][1]
    d.run(until=lambda: d.now() > 1000)
    assert first.terminated
    assert len(notes) == 1  # not again while the second call records
    d.run(until=lambda: d.now() > 1560)
    assert [f for f, _ in notes] == [tmp_path / "rec0", tmp_path / "rec0"]


def test_failed_processing_leaves_no_notes_to_write(tmp_path: Path):
    d, _, launched, notes = _notes_daemon(tmp_path, lambda now: 10 <= now < 700)
    d._launch = lambda folder: launched.append(folder) or _Running(lambda: True, rc=1)
    d.run(until=lambda: d.now() > 800)
    assert notes == []


def test_notes_still_to_write_survive_a_restart(tmp_path: Path):
    rec = tmp_path / "rec"
    rec.mkdir()
    (rec / "transcript.md").write_text("")
    (tmp_path / "state.json").write_text(json.dumps({"state": "idle", "queued": [], "notes_queued": [str(rec)]}))
    d, _, _, notes = _notes_daemon(tmp_path, lambda now: False)
    d.run(until=lambda: d.now() > 4)
    assert [f for f, _ in notes] == [rec]


def test_build_daemon_leaves_the_notes_for_later(monkeypatch, tmp_path: Path):
    import palaver.daemon as daemon
    from palaver.config import Config

    monkeypatch.setattr(daemon, "STATE_PATH", tmp_path / "daemon.json")
    calls = []
    monkeypatch.setattr(daemon, "launch_run", lambda folder, opts, **kw: calls.append(kw))
    cfg = Config(user_name="K", notion_token="t", notion_parent_page_id="p", hf_token=None,
                 output_dir=tmp_path, retention_days=14, max_session_hours=4, grace_period_seconds=10,
                 transcriber="parakeet-mlx", whisper_repo="w", diarizer_repo="d", language="auto",
                 notion_auto_sync=False)
    d = daemon.build_daemon(cfg)
    d._launch(tmp_path / "rec")
    d._launch_notes(tmp_path / "rec")
    assert calls == [{"cmd": "process", "extra": ["--no-notes"]}, {"cmd": "notes"}]


def test_available_memory_reads_vm_stat(monkeypatch):
    import palaver.daemon as daemon

    out = ("Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free:  1000.\n"
           "Pages active:  5000.\nPages inactive:  500.\nPages speculative:  12.\nPages purgeable:  20.\n")
    monkeypatch.setattr(daemon.subprocess, "run", lambda *a, **kw: type("R", (), {"stdout": out})())
    assert daemon.available_memory_gb() == (1000 + 500 + 12 + 20) * 16384 / 2**30


# --- a manual recording whose call has ended (issue #52) -----------------------

from palaver.daemon import StopQuestion, stop_question_text  # noqa: E402


def _ask(q: StopQuestion, timeline) -> list[tuple[float, str]]:
    """``timeline``: (time, call app or None, seconds both tracks were silent or None)."""
    out = []
    for now, call, silent in timeline:
        reason = q.update(now, call, silent)
        if reason:
            out.append((now, reason))
    return out


def test_stop_question_asks_once_when_the_call_has_been_released_for_the_grace():
    q = StopQuestion(grace=10)
    timeline = [(0, None, None), (5, "teams", None), (100, "teams", None),
                (102, None, None), (110, None, None), (112, None, None), (200, None, None), (900, None, None)]
    assert _ask(q, timeline) == [(112, "teams")]
    assert q.open == "teams"


def test_stop_question_ignores_a_brief_release_and_names_slack():
    q = StopQuestion(grace=10)
    timeline = [(0, "slack", None), (20, None, None), (25, "slack", None), (40, None, None), (50, None, None)]
    assert _ask(q, timeline) == [(50, "slack")]


def test_stop_question_closes_when_the_call_comes_back():
    q = StopQuestion(grace=10)
    _ask(q, [(0, "teams", None), (10, None, None), (20, None, None)])
    assert q.open == "teams"
    _ask(q, [(30, "teams", None)])
    assert q.open is None
    assert _ask(q, [(40, None, None), (50, None, None)]) == [(50, "teams")]  # asks again after this call


def test_stop_question_asks_after_ten_silent_minutes_only_without_a_call():
    q = StopQuestion(grace=10)
    assert _ask(q, [(0, None, 0), (599, None, 599), (600, None, 600), (700, None, 700)]) == [(600, "silence")]
    assert q.minutes == 10
    seen = StopQuestion(grace=10)
    # A muted Teams call is silent too; once a call was seen, its end is the question.
    assert _ask(seen, [(0, "teams", 0), (300, "teams", 300), (700, "teams", 700)]) == []
    assert _ask(StopQuestion(grace=10), [(0, None, None), (900, None, None)]) == []  # no level known


def test_keep_recording_is_quiet_until_the_next_call_ends():
    q = StopQuestion(grace=10)
    _ask(q, [(0, "teams", 0), (100, None, 0), (110, None, 10)])
    q.keep(120)
    assert q.open is None
    assert _ask(q, [(130, None, 20), (600, None, 500), (1000, None, 900)]) == []
    assert _ask(q, [(1100, "slack", 0), (1200, None, 0), (1210, None, 10)]) == [(1210, "slack")]


def test_keep_recording_is_quiet_for_thirty_silent_minutes():
    q = StopQuestion(grace=10)
    assert _ask(q, [(0, None, 0), (600, None, 600)]) == [(600, "silence")]
    q.keep(610)
    # Silent all along: 30 min counted from the answer, not from when it went quiet.
    assert _ask(q, [(1000, None, 1000), (610 + 1799, None, 2409)]) == []
    assert _ask(q, [(610 + 1800, None, 2410)]) == [(2410, "silence")]
    assert q.minutes == 30
    q.keep(2420)
    assert _ask(q, [(3000, None, 5), (2420 + 1800, None, 1795)]) == []  # someone spoke meanwhile


def test_stop_question_text_names_the_call():
    assert stop_question_text("teams", 10) == (
        "You started this recording yourself, and your Teams call just ended. Stop recording?")
    assert "your Slack huddle just ended" in stop_question_text("slack", 10)
    assert stop_question_text("silence", 10) == (
        "You started this recording yourself, and it has been silent for 10 minutes. Stop recording?")


def _capture_notifications(monkeypatch) -> list[tuple[str, str, str | None]]:
    sent = []
    monkeypatch.setattr("palaver.notify._send", lambda title, message, meeting=None: sent.append((title, message, meeting)))
    return sent


def test_manual_recording_asks_once_when_its_call_ends_and_never_stops_itself(tmp_path: Path, monkeypatch):
    sent = _capture_notifications(monkeypatch)
    d, sessions, launched = _daemon(tmp_path, lambda now: 20 <= now < 300)
    d.start_manual()
    d.run(until=lambda: d.now() > 4 * 3600)
    assert not sessions[0].stopped and launched == []
    asks = [s for s in sent if "Stop recording?" in s[1]]
    assert asks == [("Call ended — still recording",
                     "You started this recording yourself, and your Teams call just ended. Stop recording?", "rec0")]
    q = d.status()["stop_question"]
    assert q["meeting"] == "rec0" and q["reason"] == "teams" and q["message"] == asks[0][1]
    assert json.loads((tmp_path / "state.json").read_text())["stop_question"]["reason"] == "teams"


def test_answering_stop_stops_the_recording(tmp_path: Path):
    d, sessions, launched = _daemon(tmp_path, lambda now: "slack" if 20 <= now < 300 else None)
    d.start_manual()
    d.run(until=lambda: d.now() > 400)
    assert d.status()["stop_question"]["reason"] == "slack"
    assert not d.answer_stop_question("stop", "rec9")  # not this recording
    assert d.answer_stop_question("stop", "rec0")
    assert sessions[0].stopped and launched == [tmp_path / "rec0"]
    assert d.status()["stop_question"] is None and d.status()["state"] == "idle"


def test_answering_keep_closes_the_question(tmp_path: Path):
    d, sessions, _ = _daemon(tmp_path, lambda now: 20 <= now < 300 or 2000 <= now < 2100)
    d.start_manual()
    d.run(until=lambda: d.now() > 400)
    assert d.answer_stop_question("keep")
    assert d.status()["stop_question"] is None and not sessions[0].stopped
    d.run(until=lambda: d.now() > 1900)
    assert d.status()["stop_question"] is None
    d.run(until=lambda: d.now() > 2200)  # the next call ended
    assert d.status()["stop_question"]["reason"] == "teams"
    assert not d.answer_stop_question("maybe")
    d.shutdown()


def test_manual_recording_asks_after_ten_silent_minutes(tmp_path: Path, sent_notifications):
    d, sessions, _ = _daemon(tmp_path, lambda now: False)
    d._silence = lambda: d.now()  # silent since the start
    d.start_manual()
    d.run(until=lambda: d.now() > 590)
    assert d.status()["stop_question"] is None
    d.run(until=lambda: d.now() > 610)
    assert d.status()["stop_question"]["reason"] == "silence"
    assert ("Silent for 10 min — still recording", stop_question_text("silence", 10)) in sent_notifications
    d.shutdown()


def test_an_automatic_recording_is_never_asked_about(tmp_path: Path, sent_notifications):
    d, _, _ = _daemon(tmp_path, lambda now: 10 <= now < 700)
    d._silence = lambda: 10**6
    d.run(until=lambda: d.now() > 760)
    assert d.status()["stop_question"] is None
    assert not any("Stop recording?" in m for _, m in sent_notifications)


def test_a_start_right_after_a_stop_is_ignored_as_a_double_click(tmp_path: Path, caplog):
    import logging

    caplog.set_level(logging.INFO, logger="palaver.daemon")
    d, sessions, _ = _daemon(tmp_path, lambda now: 10 <= now < 100)
    d.run(until=lambda: d.now() > 111)  # the call's recording stopped at 110 (grace 10)
    assert d.status()["state"] == "idle" and len(sessions) == 1
    assert d.start_manual() is False  # 2 s after the automatic stop
    assert len(sessions) == 1 and d.status()["state"] == "idle"
    assert "double click" in caplog.text
    d.run(until=lambda: d.now() > 114)
    assert d.start_manual() is True
    assert d.status()["state"] == "recording"
    d.stop_manual()
    assert d.start_manual() is False  # also right after a manual stop
    assert len(sessions) == 2


# --- the search index (#46) ---------------------------------------------------------

def _index_daemon(tmp_path, activity, *, wanted=lambda: True, **kwargs):
    d, sessions, launched, notes = _notes_daemon(tmp_path, activity, **kwargs)
    runs = []

    def _launch_index():
        p = _Running()
        runs.append(p)
        return p

    d._launch_index = _launch_index
    d._index_wanted = wanted
    return d, sessions, notes, runs


def test_meetings_are_indexed_after_their_notes_and_never_during_a_call(tmp_path: Path):
    d, _, notes, runs = _index_daemon(tmp_path, lambda now: 10 <= now < 700 or 900 <= now < 1500)
    d.run(until=lambda: d.now() > 690)
    assert len(runs) == 1 and runs[0].terminated  # it ran while idle; the call stopped it
    d.run(until=lambda: d.now() > 720)
    assert [f for f, _ in notes] == [tmp_path / "rec0"] and len(runs) == 1  # the notes come first
    notes[0][1].done = lambda: True
    d.run(until=lambda: d.now() > 740)
    assert len(runs) == 2 and d.status()["indexing"]
    d.run(until=lambda: d.now() > 920)  # a call starts
    assert runs[1].terminated and not d.status()["indexing"]
    d.run(until=lambda: d.now() > 1490)
    assert len(runs) == 2
    d.run(until=lambda: d.now() > 1600)  # the second call's notes are written, then the index again
    assert len(runs) == 2
    notes[-1][1].done = lambda: True
    d.run(until=lambda: d.now() > 1620)
    assert len(runs) == 3


def test_the_index_waits_for_free_memory_and_for_something_to_index(tmp_path: Path):
    free, stale = [0.5], [False]
    d, _, _, runs = _index_daemon(tmp_path, lambda now: False, memory=lambda: free[0], wanted=lambda: stale[0])
    d._index_check_seconds = 60
    d.run(until=lambda: d.now() > 10)
    assert runs == []
    free[0] = 8.0
    d.run(until=lambda: d.now() > 80)
    assert runs == []  # nothing stale
    stale[0] = True
    d.run(until=lambda: d.now() > 100)
    assert runs == []  # asked again only after a minute
    d.run(until=lambda: d.now() > 150)
    assert len(runs) == 1


def test_a_failing_index_is_tried_again_much_later(tmp_path: Path):
    d, _, _, runs = _index_daemon(tmp_path, lambda now: False)
    d._index_check_seconds = 60
    d.run(until=lambda: d.now() > 4)
    runs[0].rc, runs[0].done = 1, (lambda: True)
    d.run(until=lambda: d.now() > 600)
    assert len(runs) == 1  # offline, say: not every minute

# --- a restart never cuts a call (issue #47) ----------------------------------

from palaver import continuation  # noqa: E402


def _state(tmp_path):
    return json.loads((tmp_path / "state.json").read_text())


def _quit_during_a_call(tmp_path, activity, at=400.0):
    """A daemon recording a call that quits ``at`` (SIGTERM → shutdown)."""
    d, sessions, launched = _daemon(tmp_path, activity)
    d.run(until=lambda: d.now() > at)
    d.shutdown()
    return sessions, launched


def test_a_restart_during_a_call_continues_the_recording_and_joins_it_after(tmp_path):
    call = lambda now: 10 <= now < 1000  # noqa: E731
    sessions, launched = _quit_during_a_call(tmp_path, call)
    rec0 = tmp_path / "rec0"
    assert sessions[0].stop_reason == "restart"
    assert launched == []  # held back: not processed (nor its notes written) on its own
    cut = _state(tmp_path)["cut"]
    assert cut["folders"] == [str(rec0)] and cut["trigger"] == "teams"
    assert cut["at"] == (WALL0 + timedelta(seconds=402)).isoformat()

    d, _, launched = _daemon(tmp_path, call, sessions=sessions, start=430)  # started again 28 s later
    d.run(until=lambda: d.now() > 500)
    assert len(sessions) == 2 and sessions[1].trigger == "teams"
    assert continuation.parts(rec0) == [tmp_path / "rec1"]
    status = d.status()
    assert status["continues"] == [str(rec0)] and status["cut"] is None
    assert status["why"]["since"] == (WALL0 + timedelta(seconds=14)).isoformat()  # the meeting's start
    assert status["why"]["restarts"] == 1
    d.run(until=lambda: d.now() > 1100)
    assert sessions[1].stop_reason == "call_ended"
    assert launched == [rec0]  # one meeting, processed once
    assert d.status()["continues"] == []


def test_two_restarts_in_one_call_make_one_meeting(tmp_path):
    """2026-10-29: two restarts split one Teams call into 12:06 / 12:13 / 12:28."""
    call = lambda now: 10 <= now < 3000  # noqa: E731
    sessions, _ = _quit_during_a_call(tmp_path, call, at=400)
    d, _, _ = _daemon(tmp_path, call, sessions=sessions, start=430)
    d.run(until=lambda: d.now() > 1300)
    d.shutdown()
    assert _state(tmp_path)["cut"]["folders"] == [str(tmp_path / "rec0"), str(tmp_path / "rec1")]
    d, _, launched = _daemon(tmp_path, call, sessions=sessions, start=1320)
    d.run(until=lambda: d.now() > 3100)
    assert len(sessions) == 3
    assert continuation.parts(tmp_path / "rec0") == [tmp_path / "rec1", tmp_path / "rec2"]
    assert launched == [tmp_path / "rec0"]


def test_a_cut_recording_is_processed_alone_once_five_minutes_pass(tmp_path):
    sessions, _ = _quit_during_a_call(tmp_path, lambda now: 10 <= now < 410)
    d, _, launched = _daemon(tmp_path, lambda now: False, sessions=sessions, start=430)
    d.run(until=lambda: d.now() > 690)
    assert launched == []  # quit at 402: waits until 702
    d.run(until=lambda: d.now() > 710)
    assert launched == [tmp_path / "rec0"] and d.status()["cut"] is None
    assert len(sessions) == 1


def test_a_cut_part_waits_across_a_quit_while_idle(tmp_path):
    call = lambda now: 10 <= now < 410 or 600 <= now < 900  # noqa: E731
    sessions, _ = _quit_during_a_call(tmp_path, call)
    d, _, _ = _daemon(tmp_path, call, sessions=sessions, start=430)
    d.run(until=lambda: d.now() > 450)
    d.shutdown()  # quit again before the call came back
    assert _state(tmp_path)["cut"]["folders"] == [str(tmp_path / "rec0")]
    d, _, launched = _daemon(tmp_path, call, sessions=sessions, start=460)
    d.run(until=lambda: d.now() > 1000)
    assert continuation.parts(tmp_path / "rec0") == [tmp_path / "rec1"]
    assert launched == [tmp_path / "rec0"]


def test_another_call_app_after_the_restart_is_a_meeting_of_its_own(tmp_path):
    sessions, _ = _quit_during_a_call(tmp_path, lambda now: 10 <= now < 1000)
    d, _, launched = _daemon(tmp_path, lambda now: "slack" if 440 <= now < 1000 else None,
                             sessions=sessions, start=430)
    d.run(until=lambda: d.now() > 1100)
    assert [s.trigger for s in sessions] == ["teams", "slack"]
    assert continuation.parts(tmp_path / "rec0") == []
    assert sorted(launched) == [tmp_path / "rec0", tmp_path / "rec1"]  # each alone; rec0 after 5 min


def test_a_manual_recording_cut_by_a_quit_is_processed_at_once(tmp_path):
    """Only automatic recordings are continued; a manual one is queued (ruling, #47 review)."""
    d, sessions, launched = _daemon(tmp_path, lambda now: False)
    d.start_manual()
    d.run(until=lambda: d.now() > 400)
    d.shutdown()
    assert sessions[0].stop_reason == "restart"
    assert _state(tmp_path)["cut"] is None and launched == [tmp_path / "rec0"]
    d, _, _ = _daemon(tmp_path, lambda now: 440 <= now < 1000, sessions=sessions, start=430)
    d.run(until=lambda: d.now() > 500)
    assert sessions[1].trigger == "teams" and continuation.parts(tmp_path / "rec0") == []
    d.shutdown()


def test_an_automatic_recording_is_not_continued_by_a_manual_one(tmp_path):
    sessions, _ = _quit_during_a_call(tmp_path, lambda now: 10 <= now < 410)
    d, _, _ = _daemon(tmp_path, lambda now: False, sessions=sessions, start=430)
    d.start_manual()
    assert sessions[1].trigger == "manual" and continuation.parts(tmp_path / "rec0") == []
    d.shutdown()


def test_a_manual_recording_started_again_after_a_restart_is_a_meeting_of_its_own(tmp_path):
    d, sessions, _ = _daemon(tmp_path, lambda now: False)
    d.start_manual()
    d.run(until=lambda: d.now() > 400)
    d.shutdown()
    d, _, launched = _daemon(tmp_path, lambda now: False, sessions=sessions, start=430)
    d.start_manual()
    assert continuation.parts(tmp_path / "rec0") == []
    d.stop_manual()
    assert launched == [tmp_path / "rec1"]


def test_a_new_cut_lets_the_older_one_go(tmp_path):
    sessions, _ = _quit_during_a_call(tmp_path, lambda now: 10 <= now < 1000)
    d, _, launched = _daemon(tmp_path, lambda now: "slack" if 440 <= now < 1000 else None,
                             sessions=sessions, start=430)
    d.run(until=lambda: d.now() > 500)
    d.shutdown()  # the Slack huddle is cut now: the Teams part can't be continued any more
    assert _state(tmp_path)["cut"]["folders"] == [str(tmp_path / "rec1")]
    assert launched == [tmp_path / "rec0"]


def test_the_joined_meeting_waits_for_the_live_workers_of_all_parts(tmp_path):
    call = lambda now: 10 <= now < 1000  # noqa: E731
    sessions, _ = _quit_during_a_call(tmp_path, call)
    d, _, launched = _daemon(tmp_path, call, sessions=sessions, start=430)
    d._live_running = lambda folder: folder == tmp_path / "rec1" and d.now() < 1200
    d.run(until=lambda: d.now() > 1100)
    assert launched == []  # the call ended at 1010; rec1's worker still finishes
    d.run(until=lambda: d.now() > 1210)
    assert launched == [tmp_path / "rec0"]


def test_each_recording_knows_why_it_stopped(tmp_path):
    d, sessions, _ = _daemon(tmp_path, lambda now: 10 <= now < 100 or 200 <= now < 900)
    d.run(until=lambda: d.now() > 150)
    assert sessions[0].stop_reason == "call_ended"
    assert d.status()["last_stop"] == {"folder": str(tmp_path / "rec0"), "reason": "call_ended",
                                       "text": "Teams call ended", "at": (WALL0 + timedelta(seconds=110)).isoformat()}
    d.run(until=lambda: d.now() > 300)
    d.set_auto(False)
    assert sessions[1].stop_reason == "auto_off"
    d.run(until=lambda: d.now() > 310)
    d.start_manual()
    d.stop_manual()
    assert sessions[2].stop_reason == "by_you"
    (tmp_path / "x").mkdir()
    d, sessions, _ = _daemon(tmp_path / "x", lambda now: True, trigger=Trigger(start_after=0, grace=10, max_session=100))
    d.run(until=lambda: d.now() > 110)
    assert sessions[0].stop_reason == "max_length"


def test_the_status_says_why_it_records_and_with_which_mic(tmp_path):
    d, sessions, _ = _daemon(tmp_path, lambda now: now >= 10)
    original = d._new_session

    def _with_mic(trigger):
        s = original(trigger)
        s.mic_device, s.mic_rate, s.mic_source = "AirPods", 24000.0, "avcapture"
        s.system_rate, s.system_source = 48000.0, "process-tap"
        return s

    d._new_session = _with_mic
    d.run(until=lambda: d.now() > 30)
    why = d.status()["why"]
    assert why == {"trigger": "teams", "since": (WALL0 + timedelta(seconds=14)).isoformat(), "restarts": 0,
                   "mic": {"device": "AirPods", "rate": 24000.0, "source": "avcapture"},
                   "system": {"rate": 48000.0, "source": "process-tap"}}
    assert d.status()["why_text"] == "Recording · Teams call since 12:06 · mic AirPods (24 kHz)"
    assert _state(tmp_path)["why_text"] == d.status()["why_text"]
    d.shutdown()
    assert d.status()["why"] is None


# --- review of #47: nothing recorded may be orphaned ---------------------------

import shutil  # noqa: E402


def _crashed_state(tmp_path, *, folder, continues=(), trigger="teams", since=14, updated=500, manual=False):
    """daemon.json as a daemon left it that died (SIGKILL, OOM) while recording."""
    for f in (folder, *continues):
        f.mkdir(exist_ok=True)
    (tmp_path / "state.json").write_text(json.dumps({
        "state": "recording", "manual": manual, "folder": str(folder), "continues": [str(f) for f in continues],
        "why": {"trigger": trigger, "since": (WALL0 + timedelta(seconds=since)).isoformat()},
        "cut": None, "queued": [], "updated": (WALL0 + timedelta(seconds=updated)).isoformat()}))


def test_a_crash_while_a_continued_part_records_can_still_be_continued(tmp_path):
    rec0, rec1 = tmp_path / "rec0", tmp_path / "rec1"
    _crashed_state(tmp_path, folder=rec1, continues=[rec0])
    sessions = [None, None]  # rec0 and rec1 were recorded before the crash
    d, _, launched = _daemon(tmp_path, lambda now: now < 900, sessions=sessions, start=520)
    assert d.status()["cut"]["folders"] == [str(rec0), str(rec1)]
    d.run(until=lambda: d.now() > 1000)
    assert continuation.parts(rec0) == [rec1, tmp_path / "rec2"]
    assert launched == [rec0]


def test_a_crash_while_a_continued_part_records_is_processed_once_the_window_passed(tmp_path):
    rec0, rec1 = tmp_path / "rec0", tmp_path / "rec1"
    _crashed_state(tmp_path, folder=rec1, continues=[rec0])
    d, _, launched = _daemon(tmp_path, lambda now: False, sessions=[None, None], start=900)
    d.run(until=lambda: d.now() > 904)
    assert launched == [rec0] and continuation.parts(rec0) == [rec1]  # `process` joins (and recovers) rec1


def test_a_crash_during_a_plain_recording_is_recovered(tmp_path):
    rec0 = tmp_path / "rec0"
    _crashed_state(tmp_path, folder=rec0, updated=500)
    d, _, launched = _daemon(tmp_path, lambda now: False, sessions=[None], start=1000)
    d.run(until=lambda: d.now() > 1004)
    assert launched == [rec0]  # `process` promotes the .part files and rebuilds meta.json


def test_a_crash_during_a_manual_recording_is_queued_at_once(tmp_path):
    rec0 = tmp_path / "rec0"
    _crashed_state(tmp_path, folder=rec0, trigger="manual", manual=True)
    d, _, launched = _daemon(tmp_path, lambda now: False, sessions=[None], start=520)
    d.run(until=lambda: d.now() > 524)
    assert launched == [rec0] and d.status()["cut"] is None


def test_a_clean_stop_is_not_taken_for_a_crash(tmp_path):
    rec0 = tmp_path / "rec0"
    _crashed_state(tmp_path, folder=rec0)
    state = _state(tmp_path)
    (tmp_path / "state.json").write_text(json.dumps({**state, "state": "stopped", "folder": None}))
    d, _, launched = _daemon(tmp_path, lambda now: False, sessions=[None], start=520)
    d.run(until=lambda: d.now() > 1000)
    assert launched == []


def test_processing_that_refuses_is_tried_again_later(tmp_path):
    """`process` exits 3 while a live worker (or a part) is still busy: the
    meeting stays queued and is tried again, never dropped."""
    d, _, launched = _daemon(tmp_path, lambda now: 10 <= now < 700)
    answers = [3, 0]
    d._launch = lambda folder: launched.append(folder) or _Running(lambda: True, rc=answers.pop(0))
    d.run(until=lambda: d.now() > 720)
    assert launched == [tmp_path / "rec0"]
    assert d.status()["queued"] == [str(tmp_path / "rec0")]
    d.run(until=lambda: d.now() > 720 + 70)
    assert launched == [tmp_path / "rec0", tmp_path / "rec0"]
    assert d.status()["queued"] == []


def test_a_worker_that_exits_after_being_stopped_is_waited_for(tmp_path):
    d, sessions, launched = _daemon(tmp_path, lambda now: 10 <= now < 700)
    stopped = []
    d._live_running = lambda folder: not stopped or d.now() < stopped[0] + 20
    d._stop_live = lambda folder: stopped.append(d.now())
    d.run(until=lambda: d.now() > 710 + 15 * 60 + 4)
    assert len(stopped) == 1 and launched == []
    d.run(until=lambda: d.now() > stopped[0] + 24)
    assert launched == [tmp_path / "rec0"]


def test_the_quit_menu_item_is_a_deliberate_stop(tmp_path):
    d, sessions, launched = _daemon(tmp_path, lambda now: 10 <= now < 1000)
    d.run(until=lambda: d.now() > 400)
    d.shutdown("by_you")
    assert sessions[0].stop_reason == "by_you"
    assert launched == [tmp_path / "rec0"] and _state(tmp_path)["cut"] is None


def test_a_different_calendar_event_after_the_restart_is_a_new_meeting(tmp_path):
    """Back-to-back calls: the next event's call is not the cut one going on."""
    event = lambda when: "standup" if when < WALL0 + timedelta(seconds=600) else "1:1"  # noqa: E731
    sessions, _ = _quit_during_a_call(tmp_path, lambda now: 10 <= now < 410)
    d, _, _ = _daemon(tmp_path, lambda now: 600 <= now < 900, sessions=sessions, start=430, calendar_event_at=event)
    d.run(until=lambda: d.now() > 650)
    assert len(sessions) == 2 and continuation.parts(tmp_path / "rec0") == []
    same = lambda when: "standup"  # noqa: E731
    (tmp_path / "x").mkdir()
    sessions, _ = _quit_during_a_call(tmp_path / "x", lambda now: 10 <= now < 900)
    d, _, _ = _daemon(tmp_path / "x", lambda now: 10 <= now < 900, sessions=sessions, start=430,
                      calendar_event_at=same)
    d.run(until=lambda: d.now() > 500)
    assert continuation.parts(tmp_path / "x" / "rec0") == [tmp_path / "x" / "rec1"]


def test_a_cut_whose_first_part_is_gone_goes_on_from_the_next(tmp_path):
    rec0, rec1, rec2 = tmp_path / "rec0", tmp_path / "rec1", tmp_path / "rec2"
    rec1.mkdir(), rec2.mkdir()
    (tmp_path / "state.json").write_text(json.dumps({"state": "stopped", "queued": [], "cut": {
        "folders": [str(rec0), str(rec1), str(rec2)], "trigger": "teams", "seconds": 900.0,
        "at": (WALL0 + timedelta(seconds=400)).isoformat(), "since": WALL0.isoformat()}}))
    d, _, launched = _daemon(tmp_path, lambda now: False, sessions=[None] * 3, start=800)
    d.run(until=lambda: d.now() > 804)
    assert launched == [rec1] and continuation.parts(rec1) == [rec2]


def test_when_marking_the_continuation_fails_both_parts_are_processed(tmp_path, monkeypatch):
    def broken(head, part):
        raise OSError("disk full")

    sessions, _ = _quit_during_a_call(tmp_path, lambda now: 10 <= now < 1000)
    monkeypatch.setattr(continuation, "add_part", broken)
    d, _, launched = _daemon(tmp_path, lambda now: 10 <= now < 1000, sessions=sessions, start=430)
    d.run(until=lambda: d.now() > 500)
    assert d.status()["continues"] == [] and launched == [tmp_path / "rec0"]  # rec0 on its own, now
    d.run(until=lambda: d.now() > 1100)
    assert launched == [tmp_path / "rec0", tmp_path / "rec1"]


def test_the_maximum_length_counts_the_whole_meeting(tmp_path):
    call = lambda now: now >= 10  # noqa: E731
    sessions, _ = _quit_during_a_call(tmp_path, call, at=2000)
    d, _, _ = _daemon(tmp_path, call, sessions=sessions, start=2030)
    d.run(until=lambda: d.now() > 3700)
    assert sessions[1].stop_reason == "max_length"  # 3600 s after the meeting began at 14, not after 2034


def test_ctrl_c_is_the_users_stop_and_sigterm_a_restart():
    import signal

    from palaver.daemon import quit_reason

    assert quit_reason(signal.SIGINT) == "by_you"
    assert quit_reason(signal.SIGTERM) == "restart"


def test_build_daemon_looks_up_the_calendar_only_when_it_is_on(monkeypatch, tmp_path: Path):
    import palaver.daemon as daemon
    from palaver import calendar_eventkit
    from palaver.calendar_events import Event
    from palaver.config import Config

    cfg = Config(user_name="K", notion_token="t", notion_parent_page_id="p", hf_token=None,
                 output_dir=tmp_path, retention_days=14, max_session_hours=4, grace_period_seconds=10,
                 transcriber="parakeet-mlx", whisper_repo="w", diarizer_repo="d", language="auto",
                 calendar_enabled=False)
    asked = []
    monkeypatch.setattr(calendar_eventkit, "has_access", lambda: True)
    monkeypatch.setattr(calendar_eventkit, "events_between",
                        lambda start, end: asked.append(start) or [Event("Sync", WALL0, WALL0 + timedelta(hours=1), uid="u")])
    assert daemon.build_daemon(cfg)._calendar_event_at(WALL0 + timedelta(minutes=5)) is None and asked == []
    import dataclasses

    cfg = dataclasses.replace(cfg, calendar_enabled=True)
    assert daemon.build_daemon(cfg)._calendar_event_at(WALL0 + timedelta(minutes=5)) == "u|2026-10-29"



# --- review round 3 ------------------------------------------------------------


def _palaver_lookalike():
    """A running process whose command line says palaver (as a daemon's does)."""
    import subprocess
    import sys

    return subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", "palaver", "menubar"])


def test_a_second_daemon_leaves_a_running_ones_recording_alone(tmp_path):
    import pytest

    from palaver.daemon import DaemonRunning

    rec0 = tmp_path / "rec0"
    _crashed_state(tmp_path, folder=rec0)
    other = _palaver_lookalike()
    try:
        state = {**_state(tmp_path), "pid": other.pid}
        (tmp_path / "state.json").write_text(json.dumps(state))
        with pytest.raises(DaemonRunning, match=str(other.pid)):
            _daemon(tmp_path, lambda now: False, sessions=[None], start=900)
        assert _state(tmp_path) == state  # untouched
    finally:
        other.kill()
        other.wait()


def test_only_the_app_or_the_daemon_count_as_a_running_palaver():
    import subprocess
    import sys

    from palaver.daemon import palaver_alive

    for args, alive in ((["palaver", "menubar"], True), (["palaver", "daemon"], True),
                        (["palaver", "mcp"], False), (["palaver", "process", "x"], False)):
        p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", *args])
        try:
            assert palaver_alive(p.pid) is alive, args
        finally:
            p.kill()
            p.wait()


def test_a_dead_pid_in_the_state_is_a_crash(tmp_path):
    import subprocess

    rec0 = tmp_path / "rec0"
    _crashed_state(tmp_path, folder=rec0, updated=500)
    gone = subprocess.Popen(["true"])
    gone.wait()
    (tmp_path / "state.json").write_text(json.dumps({**_state(tmp_path), "pid": gone.pid}))
    d, _, launched = _daemon(tmp_path, lambda now: False, sessions=[None], start=1000)
    d.run(until=lambda: d.now() > 1004)
    assert launched == [rec0]


def test_a_failed_transcription_is_reported_and_not_retried(tmp_path, sent_notifications):
    d, _, launched = _daemon(tmp_path, lambda now: 10 <= now < 700)
    d._launch = lambda folder: launched.append(folder) or _Running(lambda: True, rc=1)
    d.run(until=lambda: d.now() > 2000)
    assert launched == [tmp_path / "rec0"] and d.status()["queued"] == []
    assert ("Transcription failed", "rec0: see Open log; run `palaver process` on it to try again") in sent_notifications


def test_exited_live_workers_are_reaped_on_every_tick(tmp_path):
    d, _, _ = _daemon(tmp_path, lambda now: 10 <= now < 50)
    polled = []

    class _Worker:
        def poll(self):
            polled.append(d.now())
            return 0

    d._launch_live = lambda folder: _Worker()
    d.run(until=lambda: d.now() > 20)  # recording: not queued, nothing waits for it
    assert polled and d._children == {}


# --- audio problems while recording (issue #50) --------------------------------


def test_an_audio_problem_shows_in_the_status_and_notifies_once(tmp_path, sent_notifications):
    d, sessions, _ = _daemon(tmp_path, lambda now: now >= 10)
    original = d._new_session

    def _with_devices(trigger):
        s = original(trigger)
        s.system_device, s.system_rate, s.system_source = "AirPods Pro", 24000.0, "process-tap"
        s.problems, s.hints = [], []
        return s

    d._new_session = _with_devices
    d.run(until=lambda: d.now() > 20)
    assert d.status()["warnings"] == [] and "problems" not in d.status()["why"]
    assert d.status()["why"]["system"]["device"] == "AirPods Pro"

    s = sessions[0]
    speed = "System audio is playing at the wrong speed; Palaver is correcting it"
    s.problems = [{"id": 1, "kind": "speed", "track": "system", "start": 6.0, "end": None}]
    d.run(until=lambda: d.now() > 40)
    status = d.status()
    assert status["warnings"] == [speed]
    assert status["why"]["problems"] == [{"kind": "speed", "track": "system", "start": 6.0}]
    assert _state(tmp_path)["warnings"] == status["warnings"]

    def alerts():
        return [m for t, m in sent_notifications if t == "Audio problem while recording"]

    assert alerts() == [speed]

    # The same cause: what opens within 30 s of it is no new notification.
    s.problems.append({"id": 2, "kind": "length", "track": "system", "start": 20.0, "end": None})
    d.run(until=lambda: d.now() > 50)
    assert len(d.status()["warnings"]) == 2 and alerts() == [speed]

    # Later, something else: one more.
    s.problems[0]["end"] = s.problems[1]["end"] = 50.0
    s.problems.append({"id": 3, "kind": "stalled", "track": "mic", "start": 70.0, "end": None})
    d.run(until=lambda: d.now() > 60)
    assert d.status()["warnings"] == ["No microphone audio is arriving"]
    assert alerts() == [speed, "No microphone audio is arriving"]
    d.shutdown()
    assert d.status()["warnings"] == []


def test_a_silent_mic_is_a_soft_hint_without_a_notification(tmp_path, sent_notifications):
    d, sessions, _ = _daemon(tmp_path, lambda now: now >= 10)
    d.run(until=lambda: d.now() > 20)
    sessions[0].problems, sessions[0].hints = [], [{"kind": "silent", "track": "mic"}]
    d.run(until=lambda: d.now() > 30)
    status = d.status()
    assert status["hints"] == ["Your mic sends nothing — muted?"] and status["warnings"] == []
    assert status["why"]["hints"] == [{"kind": "silent", "track": "mic"}]
    assert not [t for t, _ in sent_notifications if t == "Audio problem while recording"]
    d.shutdown()
    assert d.status()["hints"] == []


def test_the_status_says_when_the_index_first_downloads_its_model(tmp_path: Path):
    have = [False]
    d, _, _, runs = _index_daemon(tmp_path, lambda now: False)
    d._index_model_ready = lambda: have[0]
    d._index_check_seconds = 60
    d.run(until=lambda: d.now() > 4)
    assert d.status()["indexing"] and d.status()["index_downloading"]
    runs[0].done = lambda: True
    have[0] = True
    d.run(until=lambda: d.now() > 80)
    assert len(runs) == 2 and d.status()["indexing"] and not d.status()["index_downloading"]


def test_a_record_switch_turned_off_stops_its_call_now(tmp_path):
    d, sessions, _ = _daemon(tmp_path, lambda now: 10 <= now < 900)
    d.run(until=lambda: d.now() > 50)
    d.switched_off("slack")  # another app: the Teams call goes on
    assert d.status()["state"] == "recording"
    d.switched_off("teams")
    assert sessions[0].stop_reason == "auto_off"
    assert d.status()["state"] != "recording"


def test_quitting_stops_the_search_index_so_no_old_process_outlives_an_update(tmp_path: Path):
    """#60: after an update's swap, a process of the old app would import
    the new code; the index is the one worker that runs while idle."""
    d, _, _, runs = _index_daemon(tmp_path, lambda now: False)
    d.run(until=lambda: d.now() > 30)
    assert len(runs) == 1 and not runs[0].terminated
    d.shutdown()
    assert runs[0].terminated and not d.status()["indexing"]


def _run_apps(trigger: Trigger, timeline: list[tuple[float, str | None]]) -> list[tuple[float, str]]:
    out = []
    for now, app in timeline:
        for action in trigger.update(now, app is not None, app):
            out.append((now, action))
    return out


def test_a_call_in_another_app_ends_the_meeting_and_starts_its_own():
    t = Trigger(start_after=4, grace=10, max_session=3600)
    timeline = [(0, "teams"), (4, "teams"), (100, "teams"), (102, "slack"), (104, "slack"), (106, "slack"),
                (200, "slack"), (202, None), (212, None)]
    assert _run_apps(t, timeline) == [(4, "start"), (106, "stop"), (106, "start"), (212, "stop")]
    assert t.state == "idle"


def test_a_moment_of_another_app_inside_a_call_splits_nothing():
    t = Trigger(start_after=4, grace=10, max_session=3600)
    timeline = [(0, "teams"), (4, "teams"), (50, "slack"), (52, "teams"), (54, "slack"), (56, "teams"), (300, "teams")]
    assert _run_apps(t, timeline) == [(4, "start")]


def test_a_switch_is_a_call_ended_for_the_meeting_before():
    t = Trigger(start_after=4, grace=10, max_session=3600)
    _run_apps(t, [(0, "teams"), (4, "teams"), (10, "slack")])
    assert _run_apps(t, [(14, "slack")]) == [(14, "stop"), (14, "start")]
    assert t.stopped_because == "call_ended" and t.app == "slack" and t.state == "recording"
