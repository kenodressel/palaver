"""#19: the live coach's nudges as quiet notifications. One notification per
nudge (the coach's own limit: at most one every 3 minutes), only while the
switch in Settings → Live coach is on, and each nudge's kind and time in the
meeting's session.log (never what was said)."""

from __future__ import annotations

import json
import threading
from pathlib import Path

from palaver import cli, live_coach, settings
from palaver.live_coach import NUDGE_EVERY, LiveCoach, Nudges


def _talk(until=900.0, share=0.5, window=600.0, me=200.0, monologue=0.0):
    return {"until": until, "share": share, "window": window, "me": me, "others": 200.0,
            "monologue": monologue, "speaking": None}


class _Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now


class _Monitor:
    """VoiceMonitor's surface as LiveCoach uses it; the talk is set by the test."""

    def __init__(self, folder, *, clock, on_poll):
        from palaver.paths import RecordingPaths

        self.paths = RecordingPaths(folder)
        self.mine: list[dict] = []
        self.talk: dict | None = None

    def snapshot(self):
        return self.talk

    def start(self):
        pass

    def stop(self, wait=None):
        pass


def _coach(tmp_path, clock, seen):
    return LiveCoach(tmp_path, clock=clock, monitor=_Monitor, on_nudge=seen.append,
                     names=lambda paths, invitees: ({}, {}))


def test_a_new_nudge_is_fresh_once():
    clock = _Clock()
    n = Nudges(clock=clock)
    n.update(_talk(monologue=200))
    assert n.fresh == {"kind": "monologue", "text": "3-min monologue", "at": 900.0}
    clock.now = 60
    assert n.update(_talk(monologue=260))["kind"] == "monologue"  # still shown ...
    assert n.fresh is None  # ... but not new


def test_the_coach_tells_each_nudge_once(tmp_path: Path):
    clock, seen = _Clock(), []
    coach = _coach(tmp_path, clock, seen)
    coach.monitor.talk = _talk(monologue=200)
    for t in (0, 1, 2, 60, 119):
        clock.now = t
        coach._update(coach.monitor)
    assert [n["kind"] for n in seen] == ["monologue"]
    clock.now = NUDGE_EVERY + 1  # the next one only after three minutes
    coach.monitor.talk = _talk(monologue=200, share=0.8)
    coach._update(coach.monitor)
    assert [n["kind"] for n in seen] == ["monologue", "talk_share"]


def test_a_kind_switched_off_is_not_told(tmp_path: Path):
    clock, seen = _Clock(), []
    coach = LiveCoach(tmp_path, clock=clock, monitor=_Monitor, on_nudge=seen.append,
                      enabled=lambda: {"monologue": False}, names=lambda paths, invitees: ({}, {}))
    coach.monitor.talk = _talk(monologue=200)
    coach._update(coach.monitor)
    assert seen == []


def test_a_failing_announcement_does_not_stop_the_coach(tmp_path: Path):
    def boom(nudge):
        raise RuntimeError("no notification center")

    coach = LiveCoach(tmp_path, clock=_Clock(), monitor=_Monitor, on_nudge=boom,
                      names=lambda paths, invitees: ({}, {}))
    coach.monitor.talk = _talk(monologue=200)
    coach._update(coach.monitor)
    assert coach.status()["nudge"]["kind"] == "monologue"


def _log_rows(folder: Path) -> list[dict]:
    return [json.loads(line) for line in (folder / "session.log").read_text().splitlines()]


def test_a_nudge_becomes_a_notification_and_a_log_line(tmp_path: Path):
    folder = tmp_path / "2026-11-07T10-00-00"
    folder.mkdir()
    sent = []
    tell = live_coach.nudge_notifier(folder, show=lambda: True,
                                     send=lambda title, message, meeting: sent.append((title, message, meeting)))
    tell({"kind": "monologue", "text": "4-min monologue", "at": 300.0})
    assert sent == [("Live coach", "4-min monologue", "2026-11-07T10-00-00")]
    tell({"kind": "quiet_invitee", "text": "Valerie hasn't said anything yet", "at": 612.4})
    assert sent[-1] == ("Live coach", "Someone invited hasn't spoken yet", "2026-11-07T10-00-00")
    row = _log_rows(folder)[-1]
    assert row["event"] == "coach_nudge" and row["kind"] == "quiet_invitee" and row["at"] == 612.4
    assert "Valerie" not in json.dumps(row)  # what the nudge said stays out of the log


def test_with_the_switch_off_a_nudge_is_only_logged(tmp_path: Path):
    sent = []
    tell = live_coach.nudge_notifier(tmp_path, show=lambda: False, send=lambda *a: sent.append(a))
    tell({"kind": "monologue", "text": "3-min monologue", "at": 400.0})
    assert sent == []
    assert _log_rows(tmp_path)[-1]["kind"] == "monologue"


def test_nudge_notifications_are_on_by_default_and_follow_settings():
    assert settings.Settings().nudge_notify is True
    show = live_coach.notify_switch(ttl=0)
    assert show() is True
    settings.update({"nudge_notify": False})
    assert show() is False


def test_the_coach_command_tells_its_nudges(tmp_path: Path, monkeypatch):
    got = {}

    def run(folder, *, coach, stop):
        got["coach"] = coach
        return 0

    monkeypatch.setattr(live_coach, "run_coach", run)
    args = cli.build_parser().parse_args(["coach", str(tmp_path)])
    assert args.func(args) == 0
    assert got["coach"]._on_nudge is not None


def test_nudges_are_told_from_a_running_coach_worker(tmp_path: Path):
    """End to end through run_coach with the fake monitor: one announcement."""
    clock, seen = _Clock(), []
    coach = _coach(tmp_path, clock, seen)
    coach.monitor.talk = _talk(monologue=200)
    coach._update(coach.monitor)
    stop = threading.Event()
    stop.set()
    assert live_coach.run_coach(tmp_path, coach=coach, stop=stop, every=0.01, context_after=3600,
                                parent_alive=lambda: True) == 0
    assert len(seen) == 1


def test_no_nudge_notification_names_a_person(tmp_path: Path):
    """A banner is seen by everyone when the whole screen is shared, and stays in Notification
    Center: the quiet-invitee nudge names nobody there (the menu and the meeting page do)."""
    clock = _Clock()
    names = ["Valerie Vogel", "Timo Strauß"]
    n = Nudges(clock=clock)
    sent = []
    tell = live_coach.nudge_notifier(tmp_path, show=lambda: True, send=lambda title, message, meeting: sent.append(
        title + " " + message))
    for i, quiet in enumerate([names[:1], names]):
        clock.now = i * (NUDGE_EVERY + 1)
        nudge = n.update(_talk(until=900.0 + clock.now), quiet=quiet)
        assert quiet[-1].split()[0] in nudge["text"]  # the named text stays for the menu and the page
        tell(n.fresh)
    assert len(sent) == 2
    for text in sent:
        assert not any(part in text for name in names for part in name.split())
