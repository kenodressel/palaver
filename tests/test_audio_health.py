"""The recorder's health monitor (issue #50): thresholds and incidents."""

from datetime import datetime, timedelta

import numpy as np

from palaver import audio_health
from palaver.audio_health import AudioHealth

TONE = (0.2 * np.sin(np.arange(480) / 5)).astype(np.float32)
ZEROS = np.zeros(480, dtype=np.float32)
WALL0 = datetime.fromisoformat("2026-10-29T12:06:00+01:00")


def _health(started=0.0):
    return AudioHealth(started=started, wall=lambda: WALL0)


def _check(h, now, **kw):
    kw.setdefault("written", {})
    kw.setdefault("start_pts", None)
    kw.setdefault("access", {})
    kw.setdefault("stalled", False)
    return h.check(now, **kw)


def _deliver(h, track, t0, t1, *, stamp_rate=1.0, declared=48_000, n=480, now=None, samples=None):
    """Chunks of ``n`` samples declared at ``declared`` Hz, arriving every
    10 ms of the clock from ``t0`` to ``t1``; their stamps advance
    ``stamp_rate`` times as fast as the samples say."""
    k = 0
    while t0 + k * 0.01 < t1:
        t = t0 + k * 0.01
        pts = t0 + k * (n / declared) * stamp_rate
        h.chunk(track, t, pts, TONE[:n] if samples is None else samples, declared)
        k += 1


def test_steady_delivery_at_the_declared_rate_is_healthy():
    h = _health()
    _deliver(h, "system", 100.0, 130.0)
    assert _check(h, 130.0) == ([], [])


def test_stamps_twice_as_fast_as_the_samples_is_a_wrong_speed_that_ends_once_fixed():
    """The 2026-10-29 bug: AirPods at 24 kHz read as 48 kHz."""
    h = _health()
    _deliver(h, "system", 100.0, 110.0)
    _deliver(h, "system", 110.0, 117.0, n=240, stamp_rate=2.0)
    opened = []
    for second in range(111, 118):
        opened += _check(h, float(second))[0]
    assert [(p["kind"], p["track"]) for p in opened] == [("speed", "system")]
    assert opened[0]["start"] == 110.0  # dated from its first bad second
    # Fixed at 117: the warning goes once the last seconds are clean, and
    # it ended when the speed was right again.
    closed = []
    for second in range(117, 130):
        _deliver(h, "system", float(second), second + 1.0)
        closed += _check(h, second + 1.0)[1]
    assert [p["kind"] for p in closed] == ["speed"]
    assert closed[0]["end"] == 117.0
    assert h.open_problems() == []


def test_a_second_or_two_of_wrong_speed_after_a_switch_is_not_a_warning():
    """AirPods switching to HFP: until the route watcher reads the new rate
    (up to a second), the stamps run fast. That alone is no incident."""
    h = _health()
    for second in range(100, 140):
        if second == 120:
            _deliver(h, "system", 120.0, 121.5, n=240, stamp_rate=2.0)
            _deliver(h, "system", 121.5, 122.0)
        elif second != 121:
            _deliver(h, "system", float(second), second + 1.0)
        assert _check(h, second + 1.0)[0] == []


def test_pauses_and_lost_cycles_are_not_a_wrong_speed():
    """The tap is quiet while nothing plays; Bluetooth stalls for 30-80 ms;
    an IO cycle gets lost now and then. None of it is a wrong speed."""
    h = _health()
    rng = np.random.default_rng(1)
    t, pts = 100.0, 100.0
    while t < 160.0:
        if rng.random() < 0.005:
            pts += 0.01  # a lost cycle
        elif rng.random() < 0.01:
            pts += rng.uniform(0.03, 0.08)  # a stall
        elif rng.random() < 0.002:
            pts += 3.0  # nothing played for a while
        h.chunk("system", t, pts + rng.uniform(-0.005, 0.005), TONE, 48_000)
        t, pts = t + 0.01, pts + 0.01
        if abs(t - round(t)) < 0.005:
            assert _check(h, t)[0] == []


def test_access_and_device_problems_open_only_once_they_last():
    h = _health(started=1000.0)
    assert _check(h, 1010.0, access={"mic": "device"}) == ([], [])
    assert _check(h, 1011.0, access={"mic": None}) == ([], [])  # a blip while AirPods switch
    _check(h, 1020.0, access={"mic": "access", "system": "device"})
    opened, _ = _check(h, 1024.5, access={"mic": "access", "system": "device"})
    assert [(p["id"], p["kind"], p["track"], p["start"]) for p in opened] == [
        (1, "access", "mic", 20.0), (2, "device", "system", 20.0)]
    # Wall-clock time of when it began, not of when it was believed.
    assert opened[0]["at"] == (WALL0 - timedelta(seconds=4.5)).isoformat(timespec="seconds")
    _, closed = _check(h, 1030.0, access={})
    assert [(p["kind"], p["end"]) for p in closed] == [("access", 30.0), ("device", 30.0)]


def test_close_all_ends_what_is_open():
    h = _health(started=1000.0)
    _check(h, 1040.0, stalled=True)
    h.close_all(1050.0)
    assert [(p["kind"], p["start"], p["end"]) for p in h.problems()] == [("stalled", 40.0, 50.0)]


def test_track_length_against_the_clock():
    h = _health()
    h.chunk("mic", 100.004, 100.0, TONE, 48_000)  # arrives 4 ms after its stamp
    for now, written in ((130.0, 29.99), (140.0, 39.9)):
        h.chunk("mic", now, now - 0.004, TONE, 48_000)
        assert _check(h, now, written={"mic": written}, start_pts=100.0)[0] == []
    h.chunk("mic", 150.0, 150.0 - 0.004, TONE, 48_000)
    opened, _ = _check(h, 150.0, written={"mic": 50.0 - audio_health.LENGTH_TOLERANCE - 0.5}, start_pts=100.0)
    assert [(p["kind"], p["track"]) for p in opened] == [("length", "mic")]


def test_a_track_that_is_not_delivering_is_not_measured():
    """System audio is quiet while nothing plays; its file catches up when
    sound comes back."""
    h = _health()
    h.chunk("system", 100.0, 100.0, TONE, 48_000)
    assert _check(h, 200.0, written={"system": 0.01}, start_pts=100.0)[0] == []


def test_a_silent_mic_is_a_soft_hint_shown_once_and_an_incident_only_when_it_lasts_to_the_end():
    h = _health()
    for t in range(0, 200):
        h.chunk("mic", float(t), float(t), ZEROS, 48_000)  # nobody plays anything
    assert _check(h, 200.0) == ([], []) and h.hints() == []
    for t in range(200, 262):
        h.chunk("mic", float(t), float(t), ZEROS, 48_000)
        h.chunk("system", float(t), float(t), TONE, 48_000)
    assert _check(h, 261.0) == ([], [])  # never an incident while it lasts
    assert h.hints() == [{"kind": "silent", "track": "mic"}]
    h.chunk("mic", 262.0, 262.0, TONE, 48_000)  # unmuted
    _check(h, 262.0)
    assert h.hints() == [] and h.problems() == []
    for t in range(263, 400):  # muted again: no second hint
        h.chunk("mic", float(t), float(t), ZEROS, 48_000)
        h.chunk("system", float(t), float(t), TONE, 48_000)
    _check(h, 399.0)
    assert h.hints() == []
    h.close_all(400.0)  # silent to the end: that is a problem worth keeping
    assert [(p["kind"], p["track"], p["start"], p["end"]) for p in h.problems()] == [("silent", "mic", 263.0, 400.0)]


def test_a_stalled_microphone_is_an_incident_that_ends_when_it_resumes():
    h = _health()
    opened, _ = _check(h, 40.0, stalled=True)
    assert [(p["kind"], p["track"]) for p in opened] == [("stalled", "mic")]
    _, closed = _check(h, 41.0, stalled=False)
    assert [(p["kind"], p["end"]) for p in closed] == [("stalled", 41.0)]


def test_system_audio_that_never_arrives_is_a_stalled_incident():
    """The tap delivered nothing for a whole call and nothing warned: a
    track that never delivers has no speed or length to measure."""
    h = _health()
    opened, _ = _check(h, 31.0, system_stalled=True)
    assert [(p["kind"], p["track"]) for p in opened] == [("stalled", "system")]
    _deliver(h, "system", 31.0, 32.0)
    _, closed = _check(h, 32.0)
    assert [(p["kind"], p["track"], p["end"]) for p in closed] == [("stalled", "system", 32.0)]


def test_wall_clock_time_is_taken_when_an_incident_opens():
    wall = [WALL0]
    h = AudioHealth(started=0.0, wall=lambda: wall[0])
    wall[0] = WALL0 + timedelta(minutes=8)  # e.g. after a sleep the monotonic clock did not see
    opened, _ = _check(h, 60.0, stalled=True)
    assert opened[0]["at"] == (WALL0 + timedelta(minutes=8)).isoformat(timespec="seconds")


def test_a_short_stretch_of_wrong_speed_starts_where_it_began_and_ends_after_it():
    """5 s of audio 10 % fast: the incident is dated from its first bad
    second, and never ends before it starts."""
    h = _health()
    seen = []
    for second in range(100, 130):
        fast = 105 <= second < 110
        _deliver(h, "system", float(second), second + 1.0, stamp_rate=1 / 1.1 if fast else 1.0)
        opened, closed = _check(h, second + 1.0)
        seen += opened + closed
    problems = h.problems()
    assert [(p["kind"], p["start"], p["end"]) for p in problems] == [("speed", 105.0, 110.0)]
    assert all(p["end"] >= p["start"] for p in problems)


def test_exact_whole_cycle_jumps_are_lost_cycles_unless_they_are_the_rule():
    h = _health()
    rng = np.random.default_rng(3)
    pts = 100.0
    for k in range(3000):  # 30 s, 5 % lost cycles, exact stamps
        if rng.random() < 0.05:
            pts += 0.01
        h.chunk("system", 100.0 + k * 0.01, pts, TONE, 48_000)
        pts += 0.01
        if k % 100 == 99:
            assert _check(h, 100.0 + (k + 1) * 0.01)[0] == []
