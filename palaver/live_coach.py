"""The coach during the call (#41): quiet nudges from the live pipeline (#42).

- **Talk share and monologues** come from the voice activity of the two
  tracks (voice_activity.py), within a second.
- **Pace and filler words** come from the stream's text of the user's own
  words (stream.json), over the last five minutes, and are compared with
  the user's own baseline (coach.baseline): a nudge only when clearly above
  it, never against a fixed rule, and none without a baseline.
- **"Valerie hasn't said anything yet"** only when it is sure: every voice
  heard so far has a name (recognized by the voice bank, or named while
  recording) and the invitee is not among them.
- In a meeting whose series shares one microphone (#56: an All Hands
  remembered as such), the others' voices aren't people: no talk share,
  monologue or quiet-invitee nudge. Pace and filler words, the user's own
  track, stay.

At most one nudge every NUDGE_EVERY seconds, shown for NUDGE_SHOWN seconds
as a quiet line (the menu bar, the live page); nothing pops up. A nudge
does not come again until what it said stopped being true. Each kind can
be switched off in Settings.
"""

from __future__ import annotations

import json
import logging
import threading
import time
from pathlib import Path
from typing import Any, Callable

from .coach import TICS, _count, _ENGLISH, _GERMAN, _WORDS
from .voice_activity import VoiceMonitor, talk_text

LOGGER = logging.getLogger(__name__)

NUDGE_EVERY = 180.0  # at most one nudge in this long
NUDGE_SHOWN = 120.0  # a nudge is shown this long
KINDS = ("monologue", "talk_share", "quiet_invitee", "pace", "fillers")  # in this order when several are due
SHARED_KINDS = ("monologue", "talk_share", "quiet_invitee")  # left out where one microphone is shared (#56)
LABELS = {"talk_share": "Talk share", "monologue": "Monologues", "quiet_invitee": "Invitees who haven't spoken",
          "pace": "Speaking pace", "fillers": "Filler words"}
SHARE_MIN_WINDOW = 300.0  # the talk share is said after five minutes ...
SHARE_MIN_ME = 120.0  # ... with two minutes of the user talking
SHARE_DEFAULT = 0.7
SHARE_ABOVE_USUAL = 0.2
SHARE_RANGE = (0.6, 0.85)
SHARE_REARM = 0.1  # said again only after the share fell this far below the threshold
MONOLOGUE_SECONDS = 180.0
SPEECH_WINDOW = 300.0  # pace and fillers over the last five minutes ...
SPEECH_MIN_SECONDS = 90.0  # ... of at least this much of the user's speech
BASELINE_MIN_MEETINGS = 3
PACE_FACTOR, PACE_ABOVE = 1.2, 25.0  # fast: both this much above the usual pace
FILLER_FACTOR, FILLER_ABOVE = 1.5, 1.5  # filler words: both this much above the usual rate
PACE_REARM, FILLER_REARM = 10.0, 0.5  # said again only after falling this far below the threshold
QUIET_AFTER = 600.0  # an invitee is said to be quiet after ten minutes ...
QUIET_MIN_OTHERS = 60.0  # ... of a call with this much of the others talking
MIN_TALK_SECONDS = 10.0  # a voice with less is not worth a name


def speech_kind(invitees: int) -> str | None:
    """"1:1" with one other person invited, "group" with more."""
    return "1:1" if invitees == 1 else "group" if invitees > 1 else None


def share_threshold(baseline: dict | None, kind: str | None) -> float:
    """The talk share worth a nudge: well above what is usual for the user
    in this kind of meeting, within SHARE_RANGE."""
    usual = None
    if baseline and kind:
        usual = baseline.get("share_1on1" if kind == "1:1" else "share_group")
    if usual is None:
        return SHARE_DEFAULT
    return round(min(SHARE_RANGE[1], max(SHARE_RANGE[0], usual + SHARE_ABOVE_USUAL)), 3)


def pace_and_fillers(mine: list[dict], until: float, window: float = SPEECH_WINDOW) -> dict[str, Any] | None:
    """Words a minute and filler words a minute of the user's sentences
    (the stream's mic track) in the last ``window`` seconds; None with
    less than SPEECH_MIN_SECONDS of them."""
    recent = [s for s in mine if s["end"] >= until - window]
    seconds = sum(max(0.0, s["end"] - s["start"]) for s in recent)
    if seconds < SPEECH_MIN_SECONDS:
        return None
    text = " ".join(s["text"] for s in recent)
    words = len(_WORDS.findall(text))
    tics = sorted(((t, _count(text, t)) for t in TICS), key=lambda x: -x[1])
    german = sum(_count(text, w) for w in _GERMAN) >= sum(_count(text, w) for w in _ENGLISH)
    return {"seconds": round(seconds, 1), "wpm": round(words / seconds * 60),
            "fillers_per_minute": round(sum(n for _, n in tics) / seconds * 60, 1),
            "top": tics[0][0] if tics and tics[0][1] else None, "language": "de" if german else "en"}


def quiet_invitees(invitees: list[str], talk: dict[str, float], names: dict[str, str], *,
                   elapsed: float) -> list[str]:
    """Invitees who have not said anything, when that is sure: the call has
    run QUIET_AFTER seconds with the others talking, every voice heard has a
    name (``names``: label → name), and the invitee is none of them."""
    from .calendar_events import resolve

    if elapsed < QUIET_AFTER or sum(talk.values()) < QUIET_MIN_OTHERS:
        return []
    voices = [label for label, seconds in talk.items() if seconds >= MIN_TALK_SECONDS]
    if any(label not in names for label in voices):
        return []
    if len({names[label] for label in voices}) < len(voices):  # two voices, one name: not sure who is who
        return []
    heard = sorted({names[label] for label in voices})
    return [person for person in invitees
            if resolve(person, heard) is None and not any(person.casefold() == h.casefold() for h in heard)]


def _names_text(names: list[str]) -> str:
    return names[0] if len(names) == 1 else ", ".join(names[:-1]) + " and " + names[-1]


class Nudges:
    """Which nudge to show now, from the voice activity (``talk``), the
    user's speech (``speech``: pace_and_fillers) and the invitees not heard
    (``quiet``)."""

    def __init__(self, *, baseline: dict | None = None, kind: str | None = None, shared: bool = False,
                 clock: Callable[[], float] = time.monotonic):
        self.baseline = baseline
        self.kind = kind
        self.shared = shared
        self._clock = clock
        self._current: dict | None = None
        self._last_at: float | None = None
        self._armed = {k: True for k in KINDS}
        self._told: set[str] = set()  # invitees already said to be quiet

    def update(self, talk: dict | None, *, speech: dict | None = None, quiet: list[str] = (),
               enabled: dict[str, bool] | None = None) -> dict | None:
        now = self._clock()
        due = self._due(talk or {}, speech, list(quiet))
        if self._current and now - self._current["shown_at"] > NUDGE_SHOWN:
            self._current = None
        if self._last_at is None or now - self._last_at >= NUDGE_EVERY:
            for kind in KINDS:
                if kind in due and (enabled or {}).get(kind, True) and self._armed[kind] \
                        and not (self.shared and kind in SHARED_KINDS):
                    text = due[kind]
                    self._armed[kind] = kind == "quiet_invitee"  # the next name may come later
                    if kind == "quiet_invitee":
                        self._told |= set(quiet)
                    self._current = {"kind": kind, "text": text, "shown_at": now,
                                     "at": (talk or {}).get("until")}
                    self._last_at = now
                    break
        return {k: v for k, v in self._current.items() if k != "shown_at"} if self._current else None

    def _due(self, talk: dict, speech: dict | None, quiet: list[str]) -> dict[str, str]:
        """What would be said now, by kind; re-arms what is no longer true."""
        due = {}
        share, threshold = talk.get("share"), share_threshold(self.baseline, self.kind)
        if share is not None and talk.get("window", 0) >= SHARE_MIN_WINDOW and talk.get("me", 0) >= SHARE_MIN_ME \
                and share >= threshold:
            due["talk_share"] = f"You've talked {round(100 * share)} % of the last {round(talk['window'] / 60)} min"
        elif share is None or share < threshold - SHARE_REARM:
            self._armed["talk_share"] = True
        monologue = talk.get("monologue", 0)
        if monologue >= MONOLOGUE_SECONDS:
            due["monologue"] = f"{int(monologue // 60)}-min monologue"
        elif monologue == 0:
            self._armed["monologue"] = True
        new = [name for name in quiet if name not in self._told]
        if new:
            due["quiet_invitee"] = f"{_names_text(new)} {'hasn' if len(new) == 1 else 'haven'}'t said anything yet"
        base = self.baseline or {}
        if speech and base.get("meetings", 0) >= BASELINE_MIN_MEETINGS:
            usual = base.get("wpm")
            limit = max(usual * PACE_FACTOR, usual + PACE_ABOVE) if usual else None
            if limit and speech["wpm"] >= limit:
                due["pace"] = f"You're speaking fast: {speech['wpm']} words a minute (usual {round(usual)})"
            elif limit and speech["wpm"] < limit - PACE_REARM:
                self._armed["pace"] = True
            usual = (base.get("fillers_per_minute") or {}).get(speech["language"])
            rate = speech["fillers_per_minute"]
            limit = max(usual * FILLER_FACTOR, usual + FILLER_ABOVE) if usual else None
            if limit and speech.get("top") and rate >= limit:
                due["fillers"] = (f"More filler words than usual: {rate:.1f} a minute (usual {usual:.1f}), "
                                  f"mostly “{speech['top']}”")
            elif limit and rate < limit - FILLER_REARM:
                self._armed["fillers"] = True
        return due


def enabled_kinds(s) -> dict[str, bool]:
    """The nudge kinds switched on in Settings (settings.Settings)."""
    return {kind: bool(getattr(s, f"nudge_{kind}", True)) for kind in KINDS}


def meeting_context(event, *, user_name: str, baseline: dict | None, voices: list[str] = ()) -> dict[str, Any]:
    """What the nudges need to know of the meeting: its kind (by who was
    invited and did not decline), the invitees whose silence is worth
    saying: who accepted, when the calendar gives responses; else only
    those whose voice is known (``voices``: the voice bank's names), and
    whether its series shares one microphone (#56)."""
    from .calendar_events import candidates, resolve
    from .shared_mic import remembered

    people = candidates(event, user_name=user_name) if event is not None else []
    if event is not None and any(a.response != "unknown" for a in event.attendees):
        watched = [a.name for a in people if a.response == "accepted"]
    else:
        watched = [a.name for a in people if resolve(a.name, list(voices))]
    out = {"invitees": watched, "kind": speech_kind(len(people)), "baseline": baseline}
    return {**out, "shared": True} if remembered(event) else out


# --- one recording's live coach ---------------------------------------------------------

QUIET_CHECK_SECONDS = 30.0  # who has spoken: live.json is read this often
SPEECH_EVERY = 1.0  # pace and fillers are read from the stream's text this often
STOP_WAIT = 5.0  # a stopped coach's threads get this long to end
CONTEXT_AFTER = 60.0  # the context (and the baseline over every meeting) is loaded this long after the start


def live_names(paths, invitees: list[str]) -> tuple[dict[str, float], dict[str, str]]:
    """(talk seconds, name) of the voices the live worker has clustered so
    far (live.json): names from the voice bank (the invitees first) and
    those given while recording."""
    from .calendar_events import resolve
    from .models import SpeakerTurn
    from .speakers import load_live_names, match_live_names, talk_seconds
    from .voices import VoiceBank, recognize

    try:
        live = json.loads(paths.live.read_text())
    except (OSError, ValueError):
        return {}, {}
    turns = [SpeakerTurn.from_dict(d) for d in live.get("turns", [])]
    talk = talk_seconds(turns)
    embeddings = live.get("embeddings") or {}
    if not embeddings:
        return talk, {}
    bank = VoiceBank()
    known = list(bank.names())
    invited = [r for r in (resolve(i, known) for i in invitees) if r]
    names = {label: name for label, (name, _) in recognize(embeddings, talk, bank, invited=invited).items()}
    names.update(match_live_names(embeddings, load_live_names(paths)))
    return talk, names


class LiveCoach:
    """The voice activity and nudges of the recording in ``folder``.

    ``enabled()``: the nudge kinds switched on (Settings); ``context()``:
    the meeting's invitees (names), its kind ("1:1", "group") and the
    user's baseline (coach.baseline), loaded once on a thread of its own:
    the baseline reads every meeting."""

    def __init__(self, folder: Path, *, enabled: Callable[[], dict[str, bool]] = lambda: {},
                 context: Callable[[], dict] = lambda: {}, clock: Callable[[], float] = time.monotonic,
                 monitor: Callable[..., VoiceMonitor] = VoiceMonitor,
                 names: Callable[[Any, list[str]], tuple[dict, dict]] = live_names):
        self._enabled = enabled
        self._context_fn = context
        self._clock = clock
        self._names = names
        self.monitor = monitor(folder, clock=clock, on_poll=self._update)
        self.nudges = Nudges(clock=clock)
        self._invitees: list[str] = []
        self._quiet: list[str] = []
        self._quiet_checked = -1e9
        self._nudge: dict | None = None
        self._lock = threading.Lock()
        self._stopped = threading.Event()  # asked to stop
        self.stopped = threading.Event()  # ... and both threads have ended
        self._context_thread: threading.Thread | None = None
        self._speech: dict | None = None
        self._speech_at = -1e9

    def start(self, context_after: float = CONTEXT_AFTER) -> None:
        self._context_thread = threading.Thread(target=self._load_context, args=(context_after,),
                                                name="coach-context", daemon=True)
        self._context_thread.start()
        self.monitor.start()

    def stop(self) -> None:
        """Returns at once (the daemon's tick must not wait): the threads are
        joined on a thread of their own; ``stopped`` is set once they ended."""
        self._stopped.set()

        def join():
            self.monitor.stop(wait=STOP_WAIT)
            if self._context_thread is not None:
                self._context_thread.join(timeout=STOP_WAIT)
            self.stopped.set()

        threading.Thread(target=join, name="coach-stop", daemon=True).start()

    def _load_context(self, after: float = 0.0) -> None:
        # Not in the first minute: the recording is starting, and the
        # baseline reads every meeting (nothing needs it before 3 minutes).
        if self._stopped.wait(after):
            return
        try:
            ctx = self._context_fn() or {}
            if self._stopped.is_set():
                return
        except Exception:
            LOGGER.exception("could not load the coach's context")
            return
        self.nudges.shared = bool(ctx.get("shared"))
        self._invitees = [] if self.nudges.shared else list(ctx.get("invitees") or [])
        self.nudges.baseline = ctx.get("baseline")
        self.nudges.kind = ctx.get("kind")

    def _update(self, monitor: VoiceMonitor) -> None:
        talk = monitor.snapshot()
        if not talk:
            return
        now = self._clock()
        if self._invitees and now - self._quiet_checked >= QUIET_CHECK_SECONDS:
            self._quiet_checked = now
            talk_by_voice, names = self._names(monitor.paths, self._invitees)
            self._quiet = quiet_invitees(self._invitees, talk_by_voice, names, elapsed=talk["until"])
        if now - self._speech_at >= SPEECH_EVERY:  # the text changes every second at most
            self._speech_at = now
            self._speech = pace_and_fillers(monitor.mine, talk["until"])
        speech = self._speech
        nudge = self.nudges.update(talk, speech=speech, quiet=self._quiet, enabled=self._enabled())
        with self._lock:
            self._nudge = nudge

    def status(self) -> dict[str, Any]:
        talk = self.monitor.snapshot()
        with self._lock:
            nudge = self._nudge
        return {"talk": talk, "talk_text": talk_text(talk), "nudge": nudge, "quiet": list(self._quiet)}


# --- the coach as a worker of its own (`palaver coach <folder>`) ----------------------------

COACH_FILE = "coach.json"
WRITE_EVERY = 1.0  # the status is written this often
SETTINGS_CHECK_SECONDS = 5.0  # the nudge switches are read again this often


def coach_path(folder: Path) -> Path:
    return Path(folder) / COACH_FILE


def settings_switches(ttl: float = SETTINGS_CHECK_SECONDS, clock: Callable[[], float] = time.monotonic
                      ) -> Callable[[], dict[str, bool]]:
    """The nudge kinds switched on in settings.json, read again every ``ttl`` seconds
    (the monitor asks on every poll)."""
    from . import settings

    state: dict[str, Any] = {"at": -1e9, "value": {}}

    def switches() -> dict[str, bool]:
        now = clock()
        if now - state["at"] >= ttl:
            state["at"] = now
            try:
                state["value"] = enabled_kinds(settings.load())
            except Exception:
                LOGGER.debug("could not read the nudge switches", exc_info=True)
        return state["value"]

    return switches


def write_status(folder: Path, status: dict[str, Any]) -> None:
    """coach.json, atomically: the daemon reads it every tick."""
    path = coach_path(folder)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps({k: status.get(k) for k in ("talk", "talk_text", "nudge")}
                              | {"quiet": list(status.get("quiet") or [])}))
    tmp.replace(path)


def run_coach(folder: Path, *, coach: "LiveCoach", stop: threading.Event, every: float = WRITE_EVERY,
              context_after: float = CONTEXT_AFTER,
              finished: Callable[[Any], bool] | None = None, stall: float | None = None,
              clock: Callable[[], float] = time.monotonic,
              parent_alive: Callable[[], bool] | None = None) -> int:
    """Run ``coach`` over the recording in ``folder``, writing coach.json every ``every``
    seconds, until the recording is finished (meta.json, no .part: live.recording_finished)
    or ``stop`` is set (SIGTERM). Also when nothing is left to follow, as the live worker's
    run_live: the tracks stopped growing for ``stall`` (live.STALL_SECONDS) without finishing,
    the app that started this is gone (the parent changed: an orphan is adopted by launchd) or
    the folder is. The file is removed on the way out: no file, no coach."""
    import os

    from .live import STALL_SECONDS, recording_finished

    stall = STALL_SECONDS if stall is None else stall
    if parent_alive is None:
        parent = os.getppid()
        parent_alive = lambda: os.getppid() == parent and parent != 1  # noqa: E731

    finished = finished or recording_finished
    folder = Path(folder)
    paths = coach.monitor.paths

    def size() -> int:
        total = 0
        for p in (paths.mic_raw_wav, paths.system_wav):
            for f in (p, Path(str(p) + ".part")):
                try:
                    total += f.stat().st_size
                except OSError:
                    pass
        return total

    last_size, last_growth = -1, clock()
    coach.start(context_after)
    try:
        while True:
            try:
                write_status(folder, coach.status())
            except Exception:
                LOGGER.debug("could not write the coach's status", exc_info=True)
            if stop.wait(every) or finished(paths):
                break
            if not parent_alive():
                LOGGER.warning("the app that started the coach is gone; ending")
                break
            if not folder.exists():
                break
            now = size()
            if now != last_size:
                last_size, last_growth = now, clock()
            elif clock() - last_growth > stall:
                LOGGER.warning("recording stopped growing without finishing; ending the coach")
                break
    finally:
        coach.stop()
        coach.stopped.wait(STOP_WAIT + 1)
        coach_path(folder).unlink(missing_ok=True)
    return 0
