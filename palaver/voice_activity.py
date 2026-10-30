"""Who is talking now, from the levels of the two tracks (#42, the < 1 s tier).

No model: the recorder's raw mic and system tracks are read as they grow,
in 100 ms frames. A frame is speech when it is clearly above its track's
noise floor (the quietest frame of the last half minute) and above an
absolute level. The mic track is the user; the system track is everyone
else.

**Without headphones** the others come back on the mic through the
speakers. Mic activity while the others talk counts as the user only when
the mic is clearly louder than the echo would be: the echo's level is
learned as the median of (mic − system) over frames where only the others
talk, and starts out as loud as the system track itself (0 dB) until there
is enough to learn from. So with speakers the user talking over someone is
seen only when clearly louder than the echo: it errs towards "not me",
never towards counting the others' voices as the user's.

From the frames it keeps, for the last ten minutes: who talks now, the
talk share, the current monologue (stretches of the user's speech across
pauses up to 3 s, ended by someone else talking for 1.5 s or more), the
interruptions (one starts while the other talks, and both go on together
for more than 0.5 s) and, for the user's questions (from the stream's
text, ``questions``), how long it stayed quiet until someone answered.

``VoiceMonitor`` reads the growing tracks of a recording on its own thread
(never on the recorder's audio thread) and keeps a snapshot for the
daemon's status.
"""

from __future__ import annotations

import json
import logging
import threading
import time
from collections import deque
from pathlib import Path
from statistics import median
from typing import Any, Callable

import numpy as np

from .coach import BACKCHANNEL_SECONDS, STRETCH_GAP
from .live import SAMPLE_RATE, GrowingTrack
from .paths import RecordingPaths

LOGGER = logging.getLogger(__name__)

FRAME_SECONDS = 0.1
FRAME = int(FRAME_SECONDS * SAMPLE_RATE)
SUBFRAMES = 5
WINDOW_SECONDS = 600.0  # talk share over the last ten minutes
KEEP_SECONDS = 900.0  # segments older than this are dropped
SPEECH_DBFS = -50.0  # speech is never quieter than this
ABOVE_FLOOR_DB = 12.0  # ... and this far above its track's noise floor
FLOOR_FRAMES = 300  # the floor: the quietest 20 ms of the last 30 s ...
FLOOR_CAP_DBFS = -42.0  # ... at most this: a quiet room is quieter, and speech from the start is not the floor
AUDIBLE_DBFS = -60.0  # the system track this loud can come back on the mic
ECHO_FRAMES = 5  # the echo comes back within 0.5 s (Bluetooth speakers ~0.3 s)
ECHO_MARGIN_DB = 10.0  # the user is this much louder than the echo would be
ECHO_DEFAULT_DB = 0.0  # before it is learned: as loud as the system track
ECHO_LEARN_FRAMES = 30  # learned from 3 s of only the others talking
ECHO_KEEP_FRAMES = 600
ONSET_FRAMES = 2  # 0.2 s of speech starts a turn
HANGOVER_FRAMES = 5  # 0.5 s without ends it
OVERLAP_SECONDS = 0.5  # talking over the other this long is an interruption
SHARE_MIN_SECONDS = 30.0  # a talk share needs this much talk in the window
QUESTIONS_KEPT = 50  # decided questions kept for the median wait
QUESTION_OWN_SECONDS = 0.3  # my speech starting this long after my question is me going on
ANSWER_EARLY_SECONDS = 0.5  # an answer may start this much before the question's last word ends
QUESTION_SHOWN_SECONDS = 60.0  # the status says how a question went for this long


def frame_db(samples: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """dBFS of each whole 100 ms frame of int16 ``samples``, and of its
    quietest 20 ms (what the noise floor is taken from: speech has short
    dips even without a pause)."""
    n = len(samples) // FRAME
    if not n:
        return np.zeros(0), np.zeros(0)
    x = samples[: n * FRAME].astype(np.float32).reshape(n, SUBFRAMES, FRAME // SUBFRAMES) / 32768.0
    power = np.mean(x * x, axis=2, dtype=np.float64)
    return 10 * np.log10(power.mean(axis=1) + 1e-12), 10 * np.log10(power.min(axis=1) + 1e-12)


class _Party:
    """One side's turns: a turn starts after ONSET_FRAMES of speech and ends
    after HANGOVER_FRAMES without."""

    def __init__(self):
        self.segments: deque[list[float]] = deque()  # [start, end], closed
        self.open_start: float | None = None
        self.last_end = 0.0  # end of the last frame of speech
        self._run = 0  # frames of speech in a row
        self._run_start = 0.0
        self._silent = 0
        self.started = False  # a turn started with the frame just taken

    def take(self, active: bool, t: float) -> None:
        self.started = False
        if active:
            if self._run == 0:
                self._run_start = t
            self._run += 1
            self._silent = 0
            if self.open_start is None and self._run >= ONSET_FRAMES:
                self.open_start = self._run_start
                self.started = True
            if self.open_start is not None:
                self.last_end = t + FRAME_SECONDS
        else:
            self._run = 0
            self._silent += 1
            if self.open_start is not None and self._silent >= HANGOVER_FRAMES:
                self.segments.append([self.open_start, self.last_end])
                self.open_start = None

    @property
    def talking(self) -> bool:
        return self.open_start is not None

    def all(self) -> list[list[float]]:
        return list(self.segments) + ([[self.open_start, self.last_end]] if self.open_start is not None else [])

    def seconds(self, since: float) -> float:
        return sum(max(0.0, end - max(start, since)) for start, end in self.all())

    def prune(self, before: float) -> None:
        while self.segments and self.segments[0][1] < before:
            self.segments.popleft()


class VoiceActivity:
    """Frames in (``add``), who talks and for how long out (``snapshot``).
    Times are seconds of the recording."""

    def __init__(self, start: float = 0.0):
        self._t = start  # time of the next frame
        self._start = start
        self._pending = (np.zeros(0, np.int16), np.zeros(0, np.int16))
        self._floors = (deque(maxlen=FLOOR_FRAMES), deque(maxlen=FLOOR_FRAMES))
        self._recent_system: deque[float] = deque(maxlen=ECHO_FRAMES)
        self._echo: deque[float] = deque(maxlen=ECHO_KEEP_FRAMES)
        self._echo_db = ECHO_DEFAULT_DB
        self.me, self.others = _Party(), _Party()
        # Monologues: my stretch now [start, end], broken by the others.
        self._stretch: list[float] | None = None
        self._broken = False
        self._longest = 0.0
        self._watch: list[tuple[str, float]] = []  # turns started over the other's, to time the overlap
        self._interruptions = {"by_me": 0, "of_me": 0}
        # My questions (their end times): waiting for an answer, and decided
        # (answered or I went on), kept with their wait so pruned turns never change it.
        self._waiting: list[float] = []
        self._decided: deque[dict] = deque(maxlen=QUESTIONS_KEPT)
        self._seen: set[float] = set()

    # --- frames ------------------------------------------------------------------------

    def add(self, mic: np.ndarray, system: np.ndarray) -> None:
        """The next samples of both tracks, from the same moment on (the
        shorter one is silence for the rest)."""
        n = max(len(mic), len(system))
        mic = np.concatenate([self._pending[0], np.pad(np.asarray(mic, np.int16), (0, n - len(mic)))])
        system = np.concatenate([self._pending[1], np.pad(np.asarray(system, np.int16), (0, n - len(system)))])
        whole = len(mic) // FRAME * FRAME
        self._pending = (mic[whole:], system[whole:])
        (mic_db, mic_low), (system_db, system_low) = frame_db(mic[:whole]), frame_db(system[:whole])
        for i in range(len(mic_db)):
            self._frame(float(mic_db[i]), float(mic_low[i]), float(system_db[i]), float(system_low[i]))

    def skip_to(self, t: float) -> None:
        """Start (or go on) at ``t`` without frames before it: a monitor that
        starts late reads only the last minutes."""
        self._t = self._start = max(self._t, t)

    @staticmethod
    def _active(db: float, low: float, floor: deque) -> bool:
        floor.append(low)
        return db > max(SPEECH_DBFS, min(min(floor), FLOOR_CAP_DBFS) + ABOVE_FLOOR_DB)

    def _frame(self, mic_db: float, mic_low: float, system_db: float, system_low: float) -> None:
        t = self._t
        others = self._active(system_db, system_low, self._floors[1])
        mic_speech = self._active(mic_db, mic_low, self._floors[0])
        self._recent_system.append(system_db)
        echo_window = max(self._recent_system)
        if echo_window > AUDIBLE_DBFS:
            # The call played within the echo's delay: the mic is mine only
            # when clearly louder than its echo would be.
            me = mic_speech and mic_db > echo_window + self._echo_db + ECHO_MARGIN_DB
            if not me and min(self._recent_system) > SPEECH_DBFS:
                self._echo.append(mic_db - echo_window)
                if len(self._echo) >= ECHO_LEARN_FRAMES:
                    self._echo_db = median(self._echo)
        else:
            me = mic_speech
        self.me.take(me, t)
        self.others.take(others, t)
        self._t = t + FRAME_SECONDS
        self._follow(t)

    def _follow(self, t: float) -> None:
        me, others = self.me, self.others
        # Interruptions: a turn that starts while the other's runs, timed
        # until both have talked together for OVERLAP_SECONDS.
        for who, party, other in (("me", me, others), ("others", others, me)):
            if party.started and other.talking and other.open_start < party.open_start:
                self._watch.append((who, party.open_start))
        still = []
        for who, since in self._watch:
            party, other = (me, others) if who == "me" else (others, me)
            if party.open_start != since or not other.talking:
                continue
            if min(party.last_end, other.last_end) - since > OVERLAP_SECONDS:
                self._interruptions["by_me" if who == "me" else "of_me"] += 1
            else:
                still.append((who, since))
        self._watch = still
        # My stretch: my turns across pauses up to STRETCH_GAP; someone else
        # talking BACKCHANNEL_SECONDS or more ends it.
        if me.started:
            if self._stretch and not self._broken and me.open_start - self._stretch[1] <= STRETCH_GAP:
                pass
            else:
                self._stretch, self._broken = [me.open_start, me.last_end], False
        if self._stretch and not self._broken:
            if me.talking:
                self._stretch[1] = me.last_end
            if others.talking and others.last_end - others.open_start >= BACKCHANNEL_SECONDS \
                    and others.last_end > self._stretch[1]:
                self._broken = True
            self._longest = max(self._longest, self._stretch[1] - self._stretch[0])
        if int(t / FRAME_SECONDS) % 100 == 0:
            me.prune(t - KEEP_SECONDS)
            others.prune(t - KEEP_SECONDS)

    # --- questions -----------------------------------------------------------------------

    def questions(self, ends: list[float]) -> None:
        """When each of the user's questions ended (from the stream's text);
        one already seen is not taken again."""
        new = {round(float(e), 2) for e in ends} - self._seen
        self._seen |= new
        self._waiting = sorted(set(self._waiting) | new)
        self._decide()

    def _decide(self) -> None:
        """Questions answered (or followed by more of mine) are decided once,
        with their wait; one never answered is dropped with the old turns."""
        still = []
        for at in self._waiting:
            q = self._question(at)
            if q["answered"] or q["kept_talking"]:
                self._decided.append(q)
            elif self._t - at <= KEEP_SECONDS:
                still.append(at)
        self._waiting = still
        self._seen = {at for at in self._seen if self._t - at <= 2 * KEEP_SECONDS} | set(self._waiting)

    def _question(self, at: float) -> dict[str, Any]:
        mine = next((s for s, _ in self.me.all() if s > at + QUESTION_OWN_SECONDS), None)
        answer = next((s for s, _ in self.others.all() if s >= at - ANSWER_EARLY_SECONDS), None)
        if answer is not None and (mine is None or answer <= mine):
            return {"at": at, "wait": round(max(0.0, answer - at), 1), "answered": True, "kept_talking": False}
        if mine is not None:
            return {"at": at, "wait": round(mine - at, 1), "answered": False, "kept_talking": True}
        return {"at": at, "wait": round(max(0.0, self._t - at), 1), "answered": False, "kept_talking": False}

    # --- the snapshot ---------------------------------------------------------------------

    @property
    def until(self) -> float:
        return round(self._t, 2)

    def snapshot(self) -> dict[str, Any]:
        now = self._t
        since = max(self._start, now - WINDOW_SECONDS)
        me, others = self.me.seconds(since), self.others.seconds(since)
        talking = {"me": self.me.talking, "others": self.others.talking}
        speaking = "both" if all(talking.values()) else next((k for k, v in talking.items() if v), None)
        stretch = self._stretch
        ongoing = stretch is not None and not self._broken and (self.me.talking or now - stretch[1] <= STRETCH_GAP)
        self._decide()
        answered = [q for q in self._decided if q["answered"]]
        last = max([*self._decided, *(self._question(at) for at in self._waiting[-1:])],
                   key=lambda q: q["at"], default=None)
        return {
            "until": self.until,
            "speaking": speaking,
            "window": round(now - since, 1),
            "me": round(me, 1),
            "others": round(others, 1),
            "share": round(me / (me + others), 3) if me + others >= SHARE_MIN_SECONDS else None,
            "monologue": round(stretch[1] - stretch[0], 1) if ongoing else 0,
            "longest": round(self._longest, 1),
            "interruptions": dict(self._interruptions),
            "question": last,
            "questions": len(self._decided) + len(self._waiting),
            "median_wait": round(median(q["wait"] for q in answered), 1) if answered else None,
            "echo_db": round(self._echo_db, 1) if len(self._echo) >= ECHO_LEARN_FRAMES else None,
        }


def _mmss(seconds: float) -> str:
    seconds = int(round(seconds))
    return f"{seconds // 60}:{seconds % 60:02d}"


def talk_text(s: dict[str, Any] | None) -> str | None:
    """"You 62 % of the last 10 min · talking for 2:10": the status line."""
    if not s:
        return None
    parts = []
    if s.get("share") is not None:
        parts.append(f"You {round(100 * s['share'])} % of the last {max(1, round(s['window'] / 60))} min")
    if s.get("speaking") in ("me", "both") and s.get("monologue", 0) >= 60:
        parts.append(f"talking for {_mmss(s['monologue'])}")
    by_me = (s.get("interruptions") or {}).get("by_me", 0)
    if by_me:
        parts.append(f"{by_me} interruption{'s' if by_me != 1 else ''} by you")
    q = s.get("question")
    if q and ("until" not in s or s["until"] - q["at"] <= QUESTION_SHOWN_SECONDS + q["wait"]):
        if q["answered"]:
            parts.append(f"answered {int(q['wait'] + 0.5)} s after your question")
        elif not q["kept_talking"] and q["wait"] >= 2:
            parts.append(f"quiet for {int(q['wait'] + 0.5)} s since your question")
    if not parts:
        return None
    text = " · ".join(parts)
    return text[0].upper() + text[1:]


# --- the monitor -----------------------------------------------------------------------------

LAG_SECONDS = 0.3  # read up to this far behind what the older track has written ...
STALE_SECONDS = 0.8  # ... unless it has written nothing this long: then it is silent (the tap writes nothing then)
POLL_SECONDS = 0.25
STREAM_CHECK_SECONDS = 2.0
MAX_READ_SECONDS = 60.0  # read at most this much per poll


class VoiceMonitor:
    """Reads a recording's growing tracks and keeps ``VoiceActivity`` up to
    date: ``poll`` once, or ``start`` a thread that polls every 0.25 s."""

    def __init__(self, folder: Path, *, clock: Callable[[], float] = time.monotonic,
                 on_poll: Callable[["VoiceMonitor"], None] | None = None):
        self.paths = RecordingPaths(Path(folder))
        self._mic = GrowingTrack(self.paths.mic_raw_wav)
        self._system = GrowingTrack(self.paths.system_wav)
        self._clock = clock
        self._on_poll = on_poll  # e.g. the nudges, on the same thread
        self.activity: VoiceActivity | None = None
        self._done = 0
        self.read_samples = 0
        self._stream_key = None
        self._stream_checked = -1e9
        self.mine: list[dict] = []  # my sentences from the stream: start, end, text
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._snapshot: dict[str, Any] | None = None

    def poll(self) -> bool:
        """Take in what was written since the last poll; whether anything was."""
        written = (self._mic.available(), self._system.available())
        # A track flushed late is not silence: wait for it, but not longer than STALE_SECONDS.
        frontier = max(0, min(written) - int(LAG_SECONDS * SAMPLE_RATE),
                       max(written) - int(STALE_SECONDS * SAMPLE_RATE))
        frontier -= frontier % FRAME
        if self.activity is None:
            start = max(0, frontier - int(WINDOW_SECONDS * SAMPLE_RATE))
            start -= start % FRAME
            self.activity = VoiceActivity(start / SAMPLE_RATE)
            self._done = start
        progressed = False
        while self._done < frontier:
            end = min(frontier, self._done + int(MAX_READ_SECONDS * SAMPLE_RATE))
            mic, system = self._mic.read(self._done, end), self._system.read(self._done, end)
            with self._lock:
                self.activity.add(mic, system)
            self.read_samples += end - self._done
            self._done = end
            progressed = True
        self._read_stream()
        with self._lock:
            self._snapshot = self.activity.snapshot()
        if self._on_poll is not None:
            try:
                self._on_poll(self)
            except Exception:
                LOGGER.exception("live coach update failed")
        return progressed

    def _read_stream(self) -> None:
        now = self._clock()
        if now - self._stream_checked < STREAM_CHECK_SECONDS:
            return
        self._stream_checked = now
        try:
            st = self.paths.stream.stat()
        except OSError:
            return
        key = (st.st_mtime_ns, st.st_size)
        if key == self._stream_key:
            return
        self._stream_key = key
        try:
            data = json.loads(self.paths.stream.read_text())
        except (OSError, ValueError):
            return
        mine = [{"start": float(s["start"]), "end": float(s["end"]), "text": s["text"]}
                for s in (data.get("mic") or []) if isinstance(s, dict) and isinstance(s.get("text"), str)
                and isinstance(s.get("start"), (int, float)) and isinstance(s.get("end"), (int, float))]
        self.mine = mine
        with self._lock:
            self.activity.questions([s["end"] for s in mine if s["text"].rstrip().endswith("?")])

    def snapshot(self) -> dict[str, Any] | None:
        with self._lock:
            return dict(self._snapshot) if self._snapshot else None

    # --- the thread ----------------------------------------------------------------------

    def start(self, interval: float = POLL_SECONDS) -> None:
        def run():
            while not self._stop.wait(interval):
                try:
                    self.poll()
                except Exception:
                    LOGGER.exception("voice activity failed")
        self._thread = threading.Thread(target=run, name="voice-activity", daemon=True)
        self._thread.start()

    def stop(self, *, wait: float = 2.0) -> None:
        """Ask the thread to end; wait at most ``wait`` seconds for it."""
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=wait)
            if not self._thread.is_alive():
                self._thread = None
