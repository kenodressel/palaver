"""Detect, don't trust (issue #50): the recorder's health monitor.

Audio setups keep finding new ways to break a recording quietly (AirPods
dropping to 24 kHz while the tap's format said 48, an output switch that
left the tap quiet). The recorder feeds this monitor what it sees, and the
monitor opens an *incident* when a threshold is crossed:

- ``speed``: a track's stamps disagree with its sample count. Each second,
  the stamps' advance is compared with the duration of the samples that
  came, over consecutive chunks. A pair whose stamps jump further than
  ``max(2.5 d, d + JUMP_SECONDS)`` (a pause of the source, a Bluetooth
  stall) is left out. A jump of exactly a whole number of chunks is a lost
  IO cycle — unless most pairs of that second jump so: then it is the rule,
  a rate misread by that factor (AirPods at 24 kHz read as 48). It is a
  wrong speed when, in SPEED_BAD_SECONDS of the last SPEED_WINDOW seconds,
  the two differ by more than SPEED_TOLERANCE. A device switch costs a second
  or two until the route watcher reads the new rate; a rate read wrong
  costs every second (44.1 vs 48 kHz is 9 % off, 24 vs 48 kHz 100 %).
  Jitter of ±5 ms and 0.5 % lost cycles stay within 2 %. The incident ends
  once most of the last seconds are clean, dated when they became clean.
- ``length``: a delivering track's written length disagrees with the clock
  by more than LENGTH_TOLERANCE seconds. Stamps are host time, like the
  clock, so a healthy track is off by its buffer latency (milliseconds).
- ``stalled``: no microphone buffers for MIC_STALL_SECONDS (the recorder's
  watchdog, issue #18), or no system-audio buffers from the tap for
  SYSTEM_STALL_SECONDS: a track that never delivers has no speed or length
  to measure.
- ``access`` / ``device``: a capture source reports a denied permission,
  or a device it can't use. Opened only once it lasted OPEN_AFTER seconds:
  devices disappear for a moment while AirPods switch.

A microphone sending digital silence (not a quiet room: that still has a
noise floor) for SILENT_SECONDS while the other side is heard is no
incident: it is mostly a muted mic. It is a soft *hint*, shown once per
recording, and kept as a problem only when it lasted to the end.

Times: ``start``/``end`` are seconds from the recording's start on the
recorder's clock (where the audio is); ``at`` is the wall-clock time it
began, taken when it was seen.
"""

from __future__ import annotations

import threading
from collections import deque
from datetime import datetime, timedelta
from typing import Callable

import numpy as np

SPEED_TOLERANCE = 0.04
SPEED_WINDOW = 10  # seconds looked at
SPEED_BAD_SECONDS = 5  # of them off by more than the tolerance
SPEED_MIN_AUDIO = 0.25  # seconds of audio a second needs to be judged
JUMP_SECONDS = 0.02  # with 2.5 chunks: a stamp jump beyond both is a discontinuity
WHOLE_CYCLES = 0.0005  # a jump within this of k chunks (k >= 2) is k - 1 lost cycles
LENGTH_TOLERANCE = 3.0
RECENT_SECONDS = 1.0  # a track that delivered this recently is measured for its length
SILENT_SECONDS = 60.0
DIGITAL_SILENCE = 1.0 / 32_768  # below one 16-bit step
AUDIBLE = 0.01  # about -40 dBFS: the other side is heard
OPEN_AFTER = {"access": 4.0, "device": 4.0}  # seconds a condition must last before it is an incident
CLOSE_AFTER = {"length": 5.0}  # seconds it must be fine before the incident ends (others: at once)

TRACKS = ("mic", "system")


class AudioHealth:
    """Thread-safe: fed by the recorder's writer thread, read by the
    daemon's status."""

    def __init__(self, started: float, wall: Callable[[], datetime] | None = None):
        self._started = started
        self._wall = wall or (lambda: datetime.now().astimezone())
        self._lock = threading.Lock()
        self._incidents: list[dict] = []
        self._open: dict[tuple[str, str], dict] = {}
        self._bad_since: dict[tuple[str, str], float] = {}
        self._fine_since: dict[tuple[str, str], float] = {}
        # speed: per track, the last chunk (stamp, duration) and per second
        # [second, advance, duration, n] of continuous pairs, then the same
        # of whole-cycle jumps
        self._prev: dict[str, tuple[float, float]] = {}
        self._seconds: dict[str, deque[list]] = {t: deque() for t in TRACKS}
        self._reanchors: dict[str, deque[float]] = {t: deque() for t in TRACKS}
        self._first_offset: dict[str, float] = {}  # arrival clock minus stamp, at a track's first chunk
        self._last_arrival: dict[str, float] = {}
        self._mic_zero_since: float | None = None
        self._system_heard: float | None = None
        self._hint_shown = False  # the silent-mic hint, once per recording
        self._hint_on = False

    # ---------------- fed by the recorder ----------------

    def chunk(self, track: str, now: float, pts: float, samples: np.ndarray, rate: float) -> None:
        """A chunk arrived (before resampling), declared at ``rate``."""
        peak = float(np.max(np.abs(samples))) if len(samples) else 0.0
        duration = len(samples) / rate if rate > 0 else 0.0
        with self._lock:
            self._first_offset.setdefault(track, now - pts)
            self._last_arrival[track] = now
            prev = self._prev.get(track)
            self._prev[track] = (pts, duration)
            if prev is not None and prev[1] > 0:
                advance, d = pts - prev[0], prev[1]
                if 0 < advance <= max(2.5 * d, d + JUMP_SECONDS):
                    seconds = self._seconds[track]
                    if not seconds or seconds[-1][0] != int(now):
                        seconds.append([int(now), 0.0, 0.0, 0, 0.0, 0.0, 0])
                        while seconds[0][0] < int(now) - SPEED_WINDOW:
                            seconds.popleft()
                    k = round(advance / d)
                    at = 4 if k >= 2 and abs(advance - k * d) <= WHOLE_CYCLES else 1
                    seconds[-1][at] += advance
                    seconds[-1][at + 1] += d
                    seconds[-1][at + 2] += 1
            if track == "mic":
                if peak > DIGITAL_SILENCE:
                    self._mic_zero_since = None
                elif self._mic_zero_since is None:
                    self._mic_zero_since = now
            elif peak >= AUDIBLE:
                self._system_heard = now

    def reanchor(self, track: str, now: float, drift: float) -> None:
        """The resampler re-anchored (for the log: re-anchors a minute)."""
        with self._lock:
            times = self._reanchors[track]
            times.append(now)
            while times and times[0] < now - 60.0:
                times.popleft()

    def reanchors_per_minute(self, track: str) -> int:
        with self._lock:
            return len(self._reanchors[track])

    def check(
        self,
        now: float,
        *,
        written: dict[str, float],
        start_pts: float | None,
        access: dict[str, str | None],
        stalled: bool,
        system_stalled: bool = False,
    ) -> tuple[list[dict], list[dict]]:
        """Evaluate every threshold. ``written``: seconds on disk per track
        since ``start_pts`` (None until the tracks are aligned); ``access``:
        "access" or "device" per capture source that reports a problem;
        ``stalled``: the microphone stopped delivering, ``system_stalled``:
        the system audio did. Returns the incidents opened and those that
        ended, as copies."""
        with self._lock:
            conditions: dict[tuple[str, str], bool] = {}
            ended_at: dict[tuple[str, str], float] = {}
            began_at: dict[tuple[str, str], float] = {}
            for track in TRACKS:
                bad, first_bad, last_bad = self._speed(track, now)
                conditions[("speed", track)] = bad
                if first_bad is not None:
                    began_at[("speed", track)] = first_bad
                    ended_at[("speed", track)] = last_bad + 1.0
            if start_pts is not None:
                for track, length in written.items():
                    last = self._last_arrival.get(track)
                    if last is None or now - last > RECENT_SECONDS:
                        continue  # not delivering: nothing to measure
                    expected = now - self._first_offset[track] - start_pts
                    conditions[("length", track)] = abs(expected - length) > LENGTH_TOLERANCE
            conditions[("stalled", "mic")] = stalled
            conditions[("stalled", "system")] = system_stalled
            for track in TRACKS:
                for kind in ("access", "device"):
                    conditions[(kind, track)] = access.get(track) == kind
            silent = self._silent(now)
            if silent and not self._hint_shown:
                self._hint_shown = self._hint_on = True
            elif not silent and self._hint_on:
                self._hint_on = False
            return self._apply(now, conditions, ended_at, began_at)

    def close_all(self, now: float) -> None:
        """The recording stopped: what is still open ends now. A mic that
        stayed silent to the end is kept as a problem."""
        with self._lock:
            for incident in self._open.values():
                incident["end"] = self._at(now)
            self._open.clear()
            self._bad_since.clear()
            self._fine_since.clear()
            if self._silent(now):
                start = self._mic_zero_since
                self._incidents.append(self._incident("silent", "mic", start, now, end=now))
            self._hint_on = False

    # ---------------- read by the status ----------------

    def is_open(self, kind: str, track: str) -> bool:
        with self._lock:
            return (kind, track) in self._open

    def problems(self) -> list[dict]:
        """Every incident so far: ``{"id", "kind", "track", "start", "end",
        "at"}`` (``end`` None while open)."""
        with self._lock:
            return [dict(i) for i in self._incidents]

    def open_problems(self) -> list[dict]:
        return [p for p in self.problems() if p["end"] is None]

    def hints(self) -> list[dict]:
        """Soft hints to show now: ``[{"kind": "silent", "track": "mic"}]``."""
        with self._lock:
            return [{"kind": "silent", "track": "mic"}] if self._hint_on else []

    # ---------------- internals ----------------

    def _at(self, now: float) -> float:
        return round(now - self._started, 2)

    def _incident(self, kind: str, track: str, began: float, now: float, end: float | None = None) -> dict:
        at = self._wall() - timedelta(seconds=max(0.0, now - began))
        return {"id": len(self._incidents) + 1, "kind": kind, "track": track, "start": self._at(began),
                "end": None if end is None else self._at(end), "at": at.isoformat(timespec="seconds")}

    def _speed(self, track: str, now: float) -> tuple[bool, float | None, float | None]:
        """Whether the track runs at the wrong speed, and the first and last
        second of the window it did."""
        current = int(now)
        bad, first_bad, last_bad = 0, None, None
        for second, advance, duration, n, jumps, jumped, n_jumps in self._seconds[track]:
            if not current - SPEED_WINDOW <= second < current:
                continue
            if n_jumps > n:  # whole-cycle jumps are the rule: a misread rate
                advance, duration = advance + jumps, duration + jumped
            if duration < SPEED_MIN_AUDIO:
                continue
            if abs(advance / duration - 1.0) > SPEED_TOLERANCE:
                bad += 1
                first_bad = float(second) if first_bad is None else first_bad
                last_bad = float(second)
        return bad >= SPEED_BAD_SECONDS, first_bad, last_bad

    def _silent(self, now: float) -> bool:
        zero = self._mic_zero_since
        return (zero is not None and now - zero >= SILENT_SECONDS
                and self._system_heard is not None and self._system_heard >= zero)

    def _apply(self, now: float, conditions: dict[tuple[str, str], bool],
               ended_at: dict[tuple[str, str], float],
               began_at: dict[tuple[str, str], float]) -> tuple[list[dict], list[dict]]:
        """``began_at``: when a condition really began, if known better than
        when it was first seen (speed: its first bad second); ``ended_at``:
        when it really ended (speed: after its last bad second)."""
        opened, closed = [], []
        for key, bad in conditions.items():
            kind, track = key
            if bad:
                self._fine_since.pop(key, None)
                since = self._bad_since.setdefault(key, now)
                if key not in self._open and now - since >= OPEN_AFTER.get(kind, 0.0):
                    incident = self._incident(kind, track, min(since, began_at.get(key, since)), now)
                    self._incidents.append(incident)
                    self._open[key] = incident
                    opened.append(dict(incident))
                continue
            self._bad_since.pop(key, None)
            if key not in self._open:
                continue
            fine = self._fine_since.setdefault(key, now)
            if now - fine >= CLOSE_AFTER.get(kind, 0.0):
                incident = self._open.pop(key)
                incident["end"] = max(incident["start"], self._at(min(ended_at.get(key, fine), fine)))
                del self._fine_since[key]
                closed.append(dict(incident))
        return opened, closed
