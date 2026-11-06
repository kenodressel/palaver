"""Record Teams meetings automatically (issue #9).

Polls whether Teams has the microphone open (``teams_detector``), records
while it does, and queues ``palaver run`` for each finished
recording. Runs in the foreground (``palaver daemon``) so it
inherits the terminal's microphone / system-audio permissions — a
launchd agent would run as a different TCC client without them.
"""

from __future__ import annotations

import contextlib
import json
import logging
import os
import re
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Callable, Protocol

from . import continuation, lifecycle, memory, notify, process_state
from .notes import NOTES_MEMORY_GB
from .paths import RecordingPaths, is_recording_folder_name

LOGGER = logging.getLogger(__name__)

STATE_PATH = Path.home() / "Library" / "Application Support" / "palaver" / "daemon.json"
LOG_PATH = Path.home() / "Library" / "Logs" / "palaver" / "daemon.log"

# Teams briefly opens the mic for device tests and pre-join previews.
START_AFTER_SECONDS = 4.0
# Shorter recordings are kept but not transcribed (accidental triggers).
MIN_PROCESS_SECONDS = 60.0
# A live worker finishes within a minute or two of the recording stopping;
# one still busy after this is stuck and `run` takes over.
LIVE_FINISH_TIMEOUT = 15 * 60.0
# Notes wait for the free memory their model needs (``llm.notes_memory_gb``:
# none for a cloud model, NOTES_MEMORY_GB for a local model not known), and
# never run while a call is recorded.
TASKPOLICY = Path("/usr/sbin/taskpolicy")
# The search index (#46): asked whether a meeting needs one this often when
# nothing else runs; after a failed run (offline: the model is not
# downloaded yet) only this much later.
INDEX_CHECK_SECONDS = 5 * 60.0
INDEX_RETRY_SECONDS = 60 * 60.0
INDEX_MEMORY_GB = 1.0
# A manual recording without a call asks to stop after this much silence;
# "Keep recording" makes it wait this long (issue #52).
SILENCE_ASK_SECONDS = 10 * 60
KEEP_QUIET_SECONDS = 30 * 60
# A call recorded automatically that nothing of the others is heard of on
# this Mac (#7): a huddle taken on the phone, while Slack keeps the Mac's
# microphone. Asked after SILENCE_ASK_SECONDS of a silent system track;
# stopped after this long with both tracks silent, unless the user said keep.
SILENT_CALL_STOP_SECONDS = 30 * 60
# A manual start this soon after a stop is a double click on the menu item.
DOUBLE_CLICK_SECONDS = 3.0
# A recording cut by Palaver quitting is continued by the next one of the
# same kind (the same call app, or manual) that starts this soon after the
# quit; until then it is held back from processing (issue #47).
CONTINUE_WITHIN = 5 * 60.0
# Audio incidents opening this soon after one that was notified share its
# notification: one cause, one notification (issue #50).
NOTIFY_GROUP_SECONDS = 30.0
# Only recordings of a call are continued; a manual one is processed at once.
CALL_TRIGGERS = ("teams", "slack")
# `process` exits with this while a live worker or a part is still busy: the
# meeting is tried again after RETRY_SECONDS, doubling up to LIVE_FINISH_TIMEOUT.
EXIT_BUSY = 3
RETRY_SECONDS = 60.0
# A meeting waiting for its models looks again this often whether they are here.
MODELS_CHECK_SECONDS = 30.0
# A stuck live worker asked to stop gets this long to exit before `process` runs.
STOP_GRACE = 60.0
# A worker stopped for its memory (#49) is killed if it has not exited after this long.
KILL_AFTER = 10.0


class Trigger:
    """Pure start/stop decisions from a stream of (time, mic-active) samples.

    idle → recording once active for ``start_after`` seconds; recording →
    idle once released for ``grace`` seconds (device switches and audio
    restarts release the mic briefly). After ``max_session`` seconds the
    session is force-stopped and nothing restarts until Teams releases the
    mic — guards against a hung detector or a laptop that slept.

    ``app``: the app the call is in ("teams", "slack"). When another app
    holds the call for ``start_after`` seconds, the meeting ends and the
    new app's starts ("stop", "start"); a moment of it splits nothing.
    """

    def __init__(self, *, start_after: float, grace: float, max_session: float):
        self.start_after = start_after
        self.grace = grace
        self.max_session = max_session
        self.state = "idle"  # idle | recording | blocked
        self._active_since: float | None = None
        self._released_since: float | None = None
        self._started: float = 0.0
        self.stopped_because: str | None = None  # "max_length" | "call_ended", for the last "stop"
        self.app: str | None = None  # the app of the call recording now
        self._switched_since: float | None = None

    def block_until_released(self) -> None:
        self.state = "blocked"

    def started_at(self, when: float) -> None:
        """The running session counts from ``when``: a meeting continued
        after a restart is as long as all its parts (``max_session``)."""
        self._started = when

    def reset(self) -> None:
        self.state, self._active_since, self._released_since = "idle", None, None
        self.app, self._switched_since = None, None

    def update(self, now: float, active: bool, app: str | None = None) -> list[str]:
        if self.state == "blocked":
            if not active:
                self.state, self._active_since = "idle", None
            return []
        if self.state == "idle":
            if not active:
                self._active_since = None
                return []
            if self._active_since is None:
                self._active_since = now
            if now - self._active_since >= self.start_after:
                self.state, self._started, self._released_since = "recording", now, None
                self.app, self._switched_since = app, None
                return ["start"]
            return []
        if now - self._started >= self.max_session:
            self.state = "blocked" if active else "idle"
            self._active_since = None
            self.stopped_because = "max_length"
            return ["stop"]
        if active:
            self._released_since = None
            return self._switch(now, app)
        self._switched_since = None
        if self._released_since is None:
            self._released_since = now
        if now - self._released_since >= self.grace:
            self.state, self._active_since = "idle", None
            self.stopped_because = "call_ended"
            return ["stop"]
        return []


    def _switch(self, now: float, app: str | None) -> list[str]:
        if app is None or self.app is None:
            self.app = self.app or app  # a session continued after a restart learns its app
            return []
        if app == self.app:
            self._switched_since = None
            return []
        if self._switched_since is None:
            self._switched_since = now
        if now - self._switched_since < self.start_after:
            return []
        self.app, self._started, self._switched_since = app, now, None
        self.stopped_because = "call_ended"
        return ["stop", "start"]

_CALL_NAMES = {"teams": "Teams call", "slack": "Slack huddle"}


def stop_question_text(reason: str, minutes: int, app: str | None = None) -> str:
    """The question for a manual recording that ran on: ``reason`` is the
    call app that ended ("teams", "slack") or "silence"; "silent_call" for a
    call recorded automatically that nothing is heard of (``app``)."""
    if reason == "silent_call":
        return (f"Nothing has been heard from the others in your {_CALL_NAMES.get(app or '', 'call')} on this Mac "
                f"for {minutes} minutes. Taken on another device? Stop recording?")
    if reason in _CALL_NAMES:
        return f"You started this recording yourself, and your {_CALL_NAMES[reason]} just ended. Stop recording?"
    return f"You started this recording yourself, and it has been silent for {minutes} minutes. Stop recording?"


def stop_question_title(reason: str, minutes: int) -> str:
    """The notification's title for the same question."""
    return "Call ended — still recording" if reason in _CALL_NAMES else f"Silent for {minutes} min — still recording"


class StopQuestion:
    """Whether to ask if a manual recording should stop (issue #52). Pure:
    fed (time, call app or None, seconds both tracks were silent or None).

    Asks once when a call seen during the recording has been released for
    ``grace`` seconds (as the auto Trigger stops), or after ``silence_after``
    seconds of silence when no call was seen. "Keep recording" (``keep``)
    waits for the next call to end, or for ``quiet_after_keep`` seconds of
    silence counted from the answer. A call coming back closes the question.
    It never decides to stop: that is the user's answer.
    """

    def __init__(self, *, grace: float, silence_after: float = SILENCE_ASK_SECONDS,
                 quiet_after_keep: float = KEEP_QUIET_SECONDS):
        self.grace = grace
        self.silence_after = silence_after
        self.quiet_after_keep = quiet_after_keep
        self.open: str | None = None  # the reason of the question asked, until answered
        self.minutes = 0  # of silence, for a "silence" question
        self._call: str | None = None  # the call app seen, until it is asked about
        self._seen_call = False
        self._released_since: float | None = None
        self._kept_at: float | None = None

    def keep(self, now: float) -> None:
        self.open, self._kept_at = None, now

    def update(self, now: float, call: str | None, silent_for: float | None) -> str | None:
        """The reason when a question is to be asked now, else None."""
        if call:
            self._call, self._seen_call, self._released_since = call, True, None
            self.open = None  # the call is back on: nothing ended
            return None
        if self.open:
            return None
        if self._call:
            if self._released_since is None:
                self._released_since = now
            if now - self._released_since >= self.grace:
                return self._ask(self._call)
            return None
        if silent_for is None or (self._seen_call and self._kept_at is None):
            return None
        threshold = self.silence_after if self._kept_at is None else self.quiet_after_keep
        quiet = silent_for if self._kept_at is None else min(silent_for, now - self._kept_at)
        if quiet >= threshold:
            self.minutes = round(threshold / 60)
            return self._ask("silence")
        return None

    def _ask(self, reason: str) -> str:
        self.open, self._call, self._released_since = reason, None, None
        return reason


class SilentCall:
    """Whether a call recorded automatically runs on this Mac (#7): the app
    holds the microphone, but nothing of the others is heard. Pure: fed
    (time, seconds the system track was silent, seconds both were; None:
    not known). Asks after ``ask_after`` without the others, even while the
    user talks (a huddle on the phone, next to the Mac); stops by itself only
    after ``stop_after`` with both silent, so a long talk of the user's is
    never cut. Kept, it asks again after ``quiet_after_keep`` counted from
    the answer, and never stops by itself."""

    def __init__(self, *, ask_after: float = SILENCE_ASK_SECONDS, stop_after: float = SILENT_CALL_STOP_SECONDS,
                 quiet_after_keep: float = KEEP_QUIET_SECONDS):
        self.ask_after, self.stop_after, self.quiet_after_keep = ask_after, stop_after, quiet_after_keep
        self.open: str | None = None  # "silent_call" while asked, until answered or sound comes back
        self.minutes = round(ask_after / 60)
        self._asked = False
        self._kept_at: float | None = None

    def keep(self, now: float) -> None:
        self.open, self._asked, self._kept_at = None, False, now

    def update(self, now: float, others_silent: float | None, all_silent: float | None = None) -> str | None:
        """"ask" or "stop" when that is to happen now, else None."""
        if others_silent is None:
            return None
        if self._kept_at is not None:
            others_silent = min(others_silent, now - self._kept_at)
            threshold = self.quiet_after_keep
        else:
            threshold = self.ask_after
        if others_silent < threshold:
            self.open, self._asked = None, False  # the others are heard: nothing to ask
            return None
        if self._kept_at is None and all_silent is not None and all_silent >= self.stop_after:
            return "stop"
        if self._asked:
            return None
        self.open, self._asked, self.minutes = "silent_call", True, round(threshold / 60)
        return "ask"


class DaemonRunning(RuntimeError):
    """Another Palaver is running: a second one must not touch its recording or queue."""


def palaver_alive(pid) -> bool:
    """Whether ``pid`` is a running Palaver that owns a recording: the
    Swift app (``Palaver.app/Contents/MacOS/Palaver``, or a development
    build in ``.build/…/Palaver``), the Python menu bar app or `palaver
    daemon`; a pid the system gave to another program since is not."""
    try:
        pid = int(pid)
        os.kill(pid, 0)
    except (TypeError, ValueError, ProcessLookupError):
        return False
    except PermissionError:
        return True
    try:
        command = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True,
                                 timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return True  # alive, and nothing says it is not Palaver
    # Only the app or `palaver daemon` own a recording: a reused pid can land
    # on `palaver mcp` or `palaver process` (or the bundle's palaver-python
    # running one), which must not block a start.
    return _OWNS_RECORDING.search(command.lower()) is not None


# The command lines of a Palaver that records (lowercased); Processes.palaverAlive in Swift matches the same.
# Up to 0.3.14 Contents/MacOS/Palaver was the Python host: `…/MacOS/Palaver -m palaver process …` is a
# worker of that release, not the app (its menu bar app still matches by `palaver menubar`).
_OWNS_RECORDING = re.compile(r"\bpalaver\s+(menubar|daemon)\b"
                             r"|/contents/macos/palaver(?!\S)(?!.*\s-m\s+palaver\b)"
                             r"|/\.build/(\S+/)?(debug|release)/palaver(?!\S)(?!.*\s-m\s+palaver\b)")


def palaver_processes() -> list[str]:
    """The command lines of the running `palaver` processes."""
    try:
        out = subprocess.run(["ps", "-axo", "command="], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    return [line for line in out.splitlines() if re.search(r"\bpalaver\b", line)]


def recording_into(folder: Path) -> bool:
    """Whether a running daemon records into ``folder`` (its daemon.json)."""
    state = _read_state(STATE_PATH)
    if state.get("state") in (None, "stopped") or not state.get("folder"):
        return False
    try:
        same = Path(state["folder"]).resolve() == folder.resolve()
    except (OSError, TypeError):
        return False
    return same and palaver_alive(state.get("pid"))


def _read_state(state_path: Path) -> dict:
    try:
        state = json.loads(state_path.read_text())
    except (OSError, ValueError):
        return {}
    return state if isinstance(state, dict) else {}


def _restore_cut(state_path: Path) -> dict | None:
    """The recording a previous daemon held back when it quit, to be
    continued (see Daemon._stop)."""
    try:
        cut = json.loads(state_path.read_text()).get("cut")
        datetime.fromisoformat(cut["at"]), datetime.fromisoformat(cut["since"])
        if not (cut["folders"] and all(isinstance(f, str) for f in cut["folders"])):
            return None
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        return None
    return cut


def _restore_queue(state_path: Path, done_marker: str, key: str = "queued") -> list[Path]:
    """Recordings a previous daemon queued but never finished."""
    try:
        queued = json.loads(state_path.read_text()).get(key, [])
    except (OSError, ValueError):
        return []
    return [
        Path(f) for f in queued
        if Path(f).is_dir() and not (Path(f) / done_marker).exists()
    ]


def available_memory_gb() -> float:
    """Memory macOS can hand out without swapping (free, inactive,
    speculative and purgeable pages); unknown counts as plenty."""
    try:
        out = subprocess.run(["vm_stat"], capture_output=True, text=True, timeout=5).stdout
        page = int(re.search(r"page size of (\d+)", out).group(1))
        pages = {k.strip(): int(v.strip().rstrip(".")) for k, v in
                 (line.split(":", 1) for line in out.splitlines()[1:] if ":" in line)}
    except (OSError, ValueError, AttributeError, subprocess.SubprocessError):
        return float("inf")
    kinds = ("Pages free", "Pages inactive", "Pages speculative", "Pages purgeable")
    return sum(pages.get(k, 0) for k in kinds) * page / 2**30


class Session(Protocol):
    def start(self) -> Path: ...
    def stop(self, reason: str | None = None) -> float: ...


class _Process(Protocol):
    def poll(self) -> int | None: ...
    def terminate(self) -> None: ...


def _command(cmd: str, folder: Path | None, cli_options: list[str], qos: str, extra: list[str] = ()) -> list[str]:
    """``palaver [options] <cmd> <folder>``, clamped to a macOS QoS
    tier: "background" keeps to the efficiency cores and yields to everything
    else (Teams during a call), "utility" is throttled but finishes sooner."""
    argv = [sys.executable, "-m", "palaver", *cli_options, cmd, *([str(folder)] if folder else []), *extra]
    if TASKPOLICY.exists():
        argv = [str(TASKPOLICY), "-c", qos, *argv]
    return argv


def launch_run(
    folder: Path | None, cli_options: list[str] = (), log_path: Path = LOG_PATH, cmd: str = "run",
    qos: str = "utility", extra: list[str] = (),
) -> subprocess.Popen:
    """``palaver [options] run <folder>`` in the background, with
    the global options (--config, --dictionary, --no-notify) the daemon got."""
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with open(log_path, "a") as log:
        return subprocess.Popen(
            _command(cmd, folder, list(cli_options), qos, list(extra)),
            stdout=log,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )


class Daemon:
    def __init__(
        self,
        *,
        detect: Callable[[], bool],
        new_session: Callable[[str], Session],
        launch_processing: Callable[[Path], _Process],
        trigger: Trigger,
        launch_live: Callable[[Path], object] | None = None,
        launch_stream: Callable[[Path], object] | None = None,
        live_coach: Callable[[Path], object] | None = None,
        launch_notes: Callable[[Path], _Process] | None = None,
        memory_free_gb: Callable[[], float] = lambda: float("inf"),
        notes_memory_gb: float | Callable[[Path], float] = NOTES_MEMORY_GB,
        launch_index: Callable[[], _Process] | None = None,
        index_wanted: Callable[[], bool] = lambda: False,
        index_model_ready: Callable[[], bool] = lambda: True,
        models_ready: Callable[[Path], bool] = lambda folder: True,
        realtime: Callable[[], bool] = lambda: False,
        live: Callable[[], bool] = lambda: True,
        before_record: Callable[[], Any] = contextlib.nullcontext,
        silence: Callable[[], float | None] = lambda: None,
        others_silence: Callable[[], float | None] = lambda: None,
        live_running: Callable[[Path], bool] = lambda folder: False,
        stop_live: Callable[[Path], None] = lambda folder: None,
        done_marker: str = "notion.json",
        output_dir: Path | None = None,  # where recordings are; at start, those left behind are marked
        processes: Callable[[], list[str]] = lambda: [],  # the command lines of Palaver's running processes
        state_path: Path | None = None,  # STATE_PATH, read when the daemon is made
        poll_seconds: float = 2.0,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
        wall: Callable[[], datetime] = lambda: datetime.now().astimezone(),
        calendar_event_at: Callable[[datetime], str | None] = lambda when: None,
        watchdog: memory.Watchdog | None = None,
        signal_worker: Callable[[object, int], None] = lambda p, sig: (
            p.kill if sig == signal.SIGKILL else p.terminate)(),
    ):
        self._detect = detect
        self._new_session = new_session
        self._launch = launch_processing
        self._launch_live = launch_live
        self._launch_stream = launch_stream
        self._new_coach = live_coach  # the voice activity and nudges of a recording (#41, #42)
        self._coach = None
        # The best next question's helpers (#41), started by the window: watched with the notes' budget.
        self._helpers: list[tuple[Path, object]] = []
        self._helpers_lock = threading.Lock()
        self._launch_notes = launch_notes
        self._memory_free_gb = memory_free_gb
        self._notes_memory_gb = notes_memory_gb
        self._realtime = realtime
        self._live = live  # live processing wanted: read at each recording's start
        # Held around a recording's start: the setup assistant's test recording gives way (#55).
        self._before_record = before_record
        self._silence = silence  # seconds both tracks were silent; None: not known
        self._others_silence = others_silence  # seconds the system track was (#7)
        self._live_running = live_running
        self._stop_live = stop_live
        self._waiting_since: dict[Path, float] = {}
        self._trigger = trigger
        state_path = state_path or STATE_PATH
        self._state_path = state_path
        self._poll = poll_seconds
        self._clock = clock
        self._sleep = sleep
        self._wall = wall  # survives a restart, unlike ``clock``
        self._calendar_event_at = calendar_event_at  # the calendar event's key at a moment, if any
        self._retry_at: dict[Path, float] = {}  # a meeting `process` refused, and when to try again
        self._retries: dict[Path, int] = {}
        # Recorded before the setup's downloads finished: transcribed once its models are here.
        self._models_ready = models_ready
        self._waiting_models: set[Path] = set()
        self._stop_sent: dict[Path, float] = {}  # stuck live workers asked to stop, by meeting
        self._children: dict[Path, list] = {}  # live and stream processes we started, by folder
        self._kinds: dict[int, str] = {}  # id of a child → "live" or "stream"
        # Memory budgets per worker (#49): the workers stopped for their
        # memory, until they have exited, and what that meant for the queues.
        self._watchdog = watchdog
        self._ending: list[dict] = []
        self._memory_ended: dict[int, str] = {}  # id of a `process` stopped for its memory → "requeue" | "drop"
        self._notes_retry_at: dict[Path, float] = {}  # notes stopped for low memory, and when to try again
        self._notes_retries: dict[Path, int] = {}
        self._signal_worker = signal_worker
        self._index_tries = 0  # search index runs stopped for low memory
        self._index_resume_at = 0.0  # ... and when it may run again (inf: not before the next start)
        self._notes_waiting: dict | None = None  # the notes waiting for free memory now
        self._session: Session | None = None
        self._folder: Path | None = None
        self._since = wall()
        self._trigger_name: str | None = None  # "teams", "slack" or "manual": the running recording's
        # A recording cut when Palaver quit, held back to be continued (issue #47).
        self._cut: dict | None = _restore_cut(state_path)
        self._parts: list[Path] = []  # the earlier parts the running recording continues
        self._parts_seconds = 0.0
        self._last_stop: dict | None = None
        self._queue: list[Path] = _restore_queue(state_path, done_marker)
        if self._queue:
            LOGGER.info("resuming %d queued transcription(s)", len(self._queue))
        self._processing: _Process | None = None
        self._processing_folder: Path | None = None
        # Notes are written apart from processing, when no call is recorded.
        self._notes_queue: list[Path] = _restore_queue(state_path, "notes.json", "notes_queued")
        self._notes: _Process | None = None
        self._notes_folder: Path | None = None
        self._notes_waiting_logged = False
        # The search index is built apart too, when nothing else runs.
        self._launch_index = launch_index
        self._index_wanted = index_wanted
        self._index_model_ready = index_model_ready
        self._index_downloading = False  # the indexer's first run fetches the model
        self._index_check_seconds = INDEX_CHECK_SECONDS
        self._indexer: _Process | None = None
        self._index_next: float | None = None  # when to ask again; None: at the next quiet moment
        self._last_active = False
        self._last_call: str | None = None
        self._detector_failing = False
        self._call_app = "teams"  # which app the current or next call is in
        self._auto = True  # record Teams calls automatically
        self._manual = False  # current session was started by hand
        self._question: StopQuestion | None = None  # whether to ask to stop a manual one
        self._silent: SilentCall | None = None  # whether a call recorded automatically is heard here (#7)
        self._stopped_at: float | None = None  # when a recording last stopped
        self._notified_problems: set[int] = set()  # audio incidents of the running recording seen
        self._notified_at: float | None = None  # the start of the last one a notification was sent for
        state = _read_state(state_path)
        pid = state.get("pid")
        if state.get("state") not in (None, "stopped") and pid != os.getpid() and palaver_alive(pid):
            raise DaemonRunning(f"Palaver is already running (pid {pid}); quit it before starting another one.")
        self._recover_crash(state)
        self._mark_left_behind(output_dir, processes)
        for app in state.get("ignored") or []:  # an app's stale hold on the mic, across a restart (#7)
            self._ignore(app)

    def now(self) -> float:
        return self._clock()

    def run(self, until: Callable[[], bool] = lambda: False) -> None:
        LOGGER.info("daemon started; waiting for a Teams call")
        self._write_state()
        while not until():
            self.tick()
            self._sleep(self._poll)

    def tick(self) -> None:
        self._reap_children()
        self._watch_memory()
        self._release_cut()
        if self._manual:
            self._watch_manual()
        elif self._auto:
            active = self._detect_safely()
            for action in self._trigger.update(self.now(), active, self._last_call):
                if action == "start":
                    self._call_app = self._trigger.app or self._call_app
                    self._start()
                else:
                    self._stop(self._trigger.stopped_because)
        self._watch_silent_call()
        self._watch_audio()
        self._pump_processing()
        self._write_state()

    def _watch_silent_call(self) -> None:
        """A call recorded automatically that nothing is heard of on this Mac
        (#7): asked about, then stopped; no new recording until the app lets
        go of the microphone."""
        if self._session is None or self._manual or self._folder is None:
            self._silent = None
            return
        if self._silent is None:
            self._silent = SilentCall()
        try:
            others, silent_for = self._others_silence(), self._silence()
        except Exception:
            LOGGER.debug("reading the silence failed", exc_info=True)
            others = silent_for = None
        action = self._silent.update(self.now(), others, silent_for)
        app = self._call_app
        name = _CALL_NAMES.get(app, "call")
        if action == "ask":
            minutes = self._silent.minutes
            LOGGER.info("asking whether to stop %s: silent for %d min", self._folder.name, minutes)
            notify.notify(stop_question_title("silence", minutes),
                          stop_question_text("silent_call", minutes, self._call_app), self._folder.name)
        elif action == "stop":
            LOGGER.info("stopping %s: silent for %d min", self._folder.name, round(silent_for / 60))
            self._stop("silence")
            self._release_hold(app)
            notify.notify("Recording stopped: nothing heard",
                          f"Your {name} was silent on this Mac for {round(SILENT_CALL_STOP_SECONDS / 60)} minutes. "
                          f"Palaver records {name}s again once the app lets go of the microphone; other calls as "
                          "always.")

    def _ignore(self, app: str | None) -> bool:
        ignore = getattr(self._detect, "ignore", None)
        if ignore is None or app is None:
            return False
        ignore(app)
        return True

    def _release_hold(self, app: str | None) -> None:
        """A call stopped while ``app`` keeps the mic: that app's hold is no
        call until it lets go; another app's call records as always. A
        detector that can't tell apps apart blocks until the mic is free."""
        if self._ignore(app):
            self._trigger.reset()
        else:
            self._trigger.block_until_released()

    def _watch_audio(self) -> None:
        """One notification per cause of audio trouble in the running
        recording (issue #50): incidents opening within NOTIFY_GROUP_SECONDS
        of one already told of are the same cause. The status shows each as
        long as it lasts; soft hints are never notified."""
        if self._session is None or self._folder is None:
            return
        for problem in getattr(self._session, "problems", []):
            if problem["id"] in self._notified_problems:
                continue
            self._notified_problems.add(problem["id"])
            start = float(problem.get("start") or 0.0)
            if self._notified_at is not None and start - self._notified_at < NOTIFY_GROUP_SECONDS:
                continue
            self._notified_at = start
            notify.notify("Audio problem while recording", lifecycle.problem_warning(problem), self._folder.name)

    def set_auto(self, enabled: bool) -> None:
        """Pause or resume automatic Teams recording. Pausing stops an
        automatic session now; a manual one keeps running."""
        self._auto = enabled
        if not enabled and self._session is not None and not self._manual:
            self._stop("auto_off")
        self._trigger.reset()
        self._pump_processing()
        self._write_state()

    def switched_off(self, app: str) -> None:
        """A record switch turned off in the menu (``app``: "teams", "slack"):
        an automatic recording of a call in that app stops now."""
        if self._session is not None and not self._manual and self._call_app == app:
            self._stop("auto_off")
            self._trigger.reset()
            self._pump_processing()
            self._write_state()

    def start_manual(self) -> bool:
        """Record now, regardless of Teams (e.g. a Zoom or in-person meeting).
        False when nothing started: already recording, a double click right
        after a stop, or the recording failed."""
        if self._session is not None:
            return False
        if self._stopped_at is not None and self.now() - self._stopped_at < DOUBLE_CLICK_SECONDS:
            LOGGER.info("ignored a manual start %.1f s after a recording stopped (a double click)",
                        self.now() - self._stopped_at)
            return False
        self._manual = True
        self._start()
        if self._session is None:
            self._manual = False
        else:
            self._question = StopQuestion(grace=self._trigger.grace)
        self._write_state()
        return self._session is not None

    def stop_manual(self) -> None:
        """Stop whatever is recording; don't restart until the call app
        releases the mic (another app's call records, #7)."""
        call = self._session is not None and not self._manual
        if self._session is not None:
            self._stop("by_you")
        self._manual = False
        if call:
            self._release_hold(self._call_app)
        else:
            self._trigger.block_until_released()
        self._pump_processing()
        self._write_state()

    def stop_question(self) -> dict | None:
        """The open question whether to stop the manual recording, or None."""
        q, folder = self._question if self._manual else self._silent, self._folder
        if q is None or not q.open or folder is None:
            return None
        return {"meeting": folder.name, "reason": q.open, "minutes": q.minutes,
                "message": stop_question_text(q.open, q.minutes, self._call_app)}

    def answer_stop_question(self, choice: str, meeting: str | None = None) -> bool:
        """"stop" or "keep", for the manual recording ``meeting`` (None: the
        one running). False when that recording is no longer running (or
        no question is open, for "keep")."""
        if choice not in ("stop", "keep") or self._folder is None:
            return False
        if not self._manual and (self._silent is None or not self._silent.open):
            return False  # an automatic recording is asked about only when silent (#7)
        if meeting is not None and meeting != self._folder.name:
            return False
        if choice == "stop":
            LOGGER.info("stopping the recording %s as asked", self._folder.name)
            self.stop_manual()
            return True
        q = self._question if self._manual else self._silent
        if q is None or not q.open:
            return False
        LOGGER.info("keeping the recording %s", self._folder.name)
        q.keep(self.now())
        self._write_state()
        return True

    def _why(self) -> dict | None:
        """Why it records, and with what (issue #47)."""
        s = self._session
        if s is None:
            return None

        def known(**fields) -> dict:
            return {k: v for k, v in fields.items() if v}

        why = {
            "trigger": self._trigger_name,
            "since": self._since.isoformat(timespec="seconds"),
            "restarts": len(self._parts),
            "mic": known(device=getattr(s, "mic_device", None), rate=getattr(s, "mic_rate", None),
                         source=getattr(s, "mic_source", None)),
            "system": known(device=getattr(s, "system_device", None), rate=getattr(s, "system_rate", None),
                            source=getattr(s, "system_source", None)),
        }
        # What is wrong with its audio right now (issue #50).
        problems = [{k: p[k] for k in ("kind", "track", "start")}
                    for p in getattr(s, "problems", []) if p.get("end") is None]
        if problems:
            why["problems"] = problems
        hints = [{k: h[k] for k in ("kind", "track")} for h in getattr(s, "hints", [])]
        if hints:  # soft: no notification, no ⚠ (a muted mic)
            why["hints"] = hints
        return why

    def _coach_status(self) -> dict:
        """Who talks now and the nudge shown (#41, #42); empty while not recording."""
        if self._coach is None:
            return {"talk": None, "talk_text": None, "nudge": None, "quiet": []}
        try:
            return {"quiet": [], **self._coach.status()}
        except Exception:
            LOGGER.debug("the live coach's status failed", exc_info=True)
            return {"talk": None, "talk_text": None, "nudge": None, "quiet": []}

    def status(self) -> dict:
        why = self._why()
        if self._session is not None:
            state = "recording"
        elif not self._auto:
            state = "paused"
        else:
            state = "idle"
        return {
            "state": state,
            "auto": self._auto,
            "manual": self._manual,
            "since": self._since.isoformat(timespec="seconds"),
            "folder": str(self._folder) if self._folder else None,
            "queued": [str(f) for f in self._queue],
            "transcribing": self._processing is not None,
            "transcribing_folder": str(self._processing_folder) if self._processing_folder else None,
            "notes_queued": [str(f) for f in ([self._notes_folder] if self._notes_folder else []) + self._notes_queue],
            "writing_notes": str(self._notes_folder) if self._notes_folder else None,
            "indexing": self._indexer is not None,
            "index_downloading": self._indexer is not None and self._index_downloading,
            "system_source": getattr(self._session, "system_source", None),
            "mic_source": getattr(self._session, "mic_source", None),
            "missing": list(getattr(self._session, "missing", [])),
            "teams_active": self._last_active,
            "stop_question": self.stop_question(),
            "ignored": sorted(getattr(self._detect, "ignored", ())),  # kept across a restart (#7)
            "why": why,
            "why_text": self._why_text(why),
            "warnings": lifecycle.recording_warnings(why),
            "hints": lifecycle.recording_hints(why),
            "memory": self._memory_status(),
            **self._coach_status(),
            "last_stop": self._last_stop,
            "continues": [str(f) for f in self._parts],
            "cut": self._cut,
            "pid": os.getpid(),
            "updated": self._wall().isoformat(timespec="seconds"),
        }

    def _why_text(self, why: dict | None) -> str | None:
        """"Recording · Teams call since 12:06 · mic AirPods (24 kHz) · Palaver 5.4 GB"."""
        if not why:
            return None
        cost = memory.cost_text(self._watchdog.status()) if self._watchdog is not None else None
        return " · ".join(p for p in (lifecycle.recording_text(why), cost) if p)

    def _memory_status(self) -> dict | None:
        """What Palaver costs now and each worker's state (#49); None
        without a watchdog."""
        if self._watchdog is None:
            return None
        status = self._watchdog.status()
        if self._notes_waiting is not None:
            status["workers"].append({"kind": "notes", "label": memory.LABELS["notes"], **self._notes_waiting,
                                      "state": "waiting for memory"})
        return status

    def shutdown(self, reason: str = "restart") -> None:
        """Finalize a running recording before exiting. ``reason``:
        "restart" when Palaver is quit from outside (an update, a launcher
        restart): a call's recording is held back for the next start to
        continue (issue #47); "by_you" for the menu's Quit: it is processed
        as any recording stopped by hand."""
        if self._session is not None:
            self._stop(reason)
        self._pump_processing()
        if self._indexer is not None:  # it goes on after the next start; never on the old code (#60)
            self._indexer.terminate()
            self._indexer = None
        self._write_state(state="stopped")

    def _detect_safely(self) -> bool:
        """Whether a call is on; the app it is in ("teams", "slack") is kept
        for the recording."""
        call = self._detect_call()
        if call and self._session is None:  # a call's app is fixed once it records
            self._call_app = call
        return call is not None

    def _detect_call(self) -> str | None:
        """The app a call is on in ("teams", "slack"), or None. A detector
        may answer True for Teams; when it fails, the last answer stands."""
        try:
            found = self._detect()
        except Exception:
            if not self._detector_failing:
                LOGGER.warning("call detection failed; keeping the last state", exc_info=True)
            self._detector_failing = True
            return self._last_call
        if self._detector_failing:
            LOGGER.info("call detection recovered")
        self._detector_failing = False
        call = (found if isinstance(found, str) else "teams") if found else None
        self._last_call, self._last_active = call, call is not None
        return call

    def _watch_manual(self) -> None:
        """A manual recording runs on: ask once whether to stop it when its
        call has ended or it has been silent long (issue #52)."""
        if self._question is None or self._folder is None:
            return
        call = self._detect_call()
        try:
            silent_for = self._silence()
        except Exception:
            LOGGER.debug("reading the silence failed", exc_info=True)
            silent_for = None
        reason = self._question.update(self.now(), call, silent_for)
        if reason is None:
            return
        minutes = self._question.minutes
        LOGGER.info("asking whether to stop the manual recording %s (%s)", self._folder.name, reason)
        notify.notify(stop_question_title(reason, minutes), stop_question_text(reason, minutes), self._folder.name)

    def _recover_crash(self, state: dict) -> None:
        """The last run died (SIGKILL, a crash, out of memory) while it
        recorded: what it recorded is held back like a quit's, to be
        continued, or queued — never left behind."""
        if state.get("state") in (None, "stopped") or not state.get("folder"):
            return
        folders = [Path(f) for f in state.get("continues") or []] + [Path(state["folder"])]
        why = state.get("why") or {}
        trigger = why.get("trigger") or ("manual" if state.get("manual") else None)
        try:
            at = datetime.fromisoformat(state["updated"])
            since = datetime.fromisoformat(why.get("since") or state["since"])
        except (KeyError, TypeError, ValueError):
            at = since = self._wall()
        LOGGER.warning("the last run ended while recording %s; recovering it", folders[-1].name)
        seconds = max(0.0, (at - since).total_seconds())
        if trigger in CALL_TRIGGERS:
            self._release_cut(now=True)
            self._cut = {"folders": [str(f) for f in folders], "trigger": trigger, "at": at.isoformat(),
                         "since": since.isoformat(), "seconds": seconds}
        else:
            self._queue_meeting(folders, seconds)

    def _event_at(self, when: datetime) -> str | None:
        try:
            return self._calendar_event_at(when)
        except Exception:
            LOGGER.debug("looking up the calendar failed", exc_info=True)
            return None

    def _continues(self, trigger: str) -> bool:
        """Whether a recording of ``trigger`` starting now continues the one
        cut when Palaver quit: a call in the same app, soon enough, with a
        part of it still there — and not the next calendar event's call."""
        cut = self._cut
        if (cut is None or trigger not in CALL_TRIGGERS or cut.get("trigger") != trigger
                or self._cut_expired(cut) or not any(Path(f).is_dir() for f in cut["folders"])):
            return False
        then, now = self._event_at(datetime.fromisoformat(cut["at"])), self._event_at(self._wall())
        if then and now and then != now:
            LOGGER.info("a call in another calendar event: not continuing %s", Path(cut["folders"][0]).name)
            return False
        return True

    def _cut_expired(self, cut: dict) -> bool:
        return (self._wall() - datetime.fromisoformat(cut["at"])).total_seconds() > CONTINUE_WITHIN

    def _release_cut(self, *, now: bool = False) -> None:
        """Process the recording cut when Palaver quit on its own once it can
        no longer be continued (``now``: it can't anyway)."""
        cut = self._cut
        if cut is None or not (now or self._cut_expired(cut)):
            return
        self._cut = None
        head = self._queue_meeting([Path(f) for f in cut["folders"]], float(cut.get("seconds", 0.0)))
        if head is not None:
            LOGGER.info("%s was not continued after the restart; transcribing it", head.name)

    def _mark_left_behind(self, output_dir: Path | None, processes: Callable[[], list[str]]) -> None:
        """At start: a recording without a transcript that nothing will
        transcribe — it failed before failed.json existed, or its `process`
        died with the Mac — is marked not transcribed. The window then offers
        Transcribe Again; before, it showed it transcribing for ever."""
        if output_dir is None:
            return
        try:
            folders = [f for f in output_dir.iterdir() if f.is_dir() and is_recording_folder_name(f.name)]
        except OSError:
            return
        held = {*self._queue, *(Path(f) for f in (self._cut or {}).get("folders", []))}
        held |= {p for f in folders for p in continuation.parts(f)}
        running = None
        for folder in sorted(folders):
            paths = RecordingPaths(folder)
            recorded = (paths.mic_wav.exists() or paths.mic_raw_wav.exists()) and paths.system_wav.exists()
            if (folder in held or not recorded or paths.transcript_json.exists()
                    or process_state.read(paths) is not None or self._live_running(folder)):
                continue
            if running is None:
                running = processes()
            if any(str(folder) in command for command in running):
                continue  # a `process` from before the restart still runs
            LOGGER.info("%s has no transcript and nothing transcribes it; marked not transcribed", folder.name)
            process_state.mark(paths, process_state.ERROR)

    def _queue_meeting(self, folders: list[Path], seconds: float | None = None) -> Path | None:
        """Queue the meeting recorded in ``folders`` (its parts, in order):
        the first one still there, with the others listed as its parts.
        Returns it; None when nothing is left or it is too short."""
        alive = [f for f in folders if f.is_dir()]
        if not alive:
            return None
        if seconds is not None and seconds < MIN_PROCESS_SECONDS:
            LOGGER.info("recording %s too short (%.0f s); not transcribing", alive[0].name, seconds)
            process_state.mark(RecordingPaths(alive[0]), process_state.ERROR, error="shorter than a minute")
            return None
        head, alone = alive[0], []
        for part in alive[1:]:
            try:
                continuation.add_part(head, part)
            except OSError:
                LOGGER.exception("could not list %s as a part of %s; processing it alone", part.name, head.name)
                alone.append(part)
        for folder in [head, *alone]:
            if folder not in self._queue:
                self._queue.append(folder)
        return head

    def _start(self) -> None:
        trigger = "manual" if self._manual else self._call_app
        continues = self._continues(trigger)
        session = self._new_session(trigger)
        try:
            with self._before_record():
                folder = session.start()
        except Exception as exc:
            LOGGER.exception("could not start recording")
            notify.notify("Meeting recording failed", str(exc) or type(exc).__name__)
            self._trigger.block_until_released()
            return
        self._session, self._folder, self._trigger_name = session, folder, trigger
        self._notified_problems, self._notified_at = set(), None
        self._since = self._wall()
        if self._manual:
            LOGGER.info("recording started by you; recording to %s", folder)
        else:
            LOGGER.info("%s call detected; recording to %s", self._call_app.capitalize(), folder)
        if continues:
            cut, self._cut = self._cut, None
            parts = [Path(f) for f in cut["folders"] if Path(f).is_dir()]
            try:
                for part in [*parts[1:], folder]:
                    continuation.add_part(parts[0], part)
            except OSError:
                # Not one meeting then: the earlier parts on their own, this one as its own.
                LOGGER.exception("could not mark %s as continuing %s", folder.name, parts[0].name)
                self._queue_meeting(parts, float(cut.get("seconds", 0.0)))
                continues = False
            else:
                self._parts, self._parts_seconds = parts, float(cut.get("seconds", 0.0))
                self._since = datetime.fromisoformat(cut["since"])
                # The maximum length is the whole meeting's.
                self._trigger.started_at(self.now() - (self._wall() - self._since).total_seconds())
                LOGGER.info("%s continues %s (cut when Palaver quit)", folder.name, parts[0].name)
        missing = list(getattr(session, "missing", []))
        if missing:
            notify.notify(
                f"Recording without the {missing[0]}",
                "Check Privacy & Security settings, then run `palaver doctor`.",
                folder.name,
            )
        elif continues:
            notify.notify("Recording continued", "Palaver restarted during the call; it stays one meeting.",
                          self._parts[0].name)
        else:
            notify.notify("Recording meeting", folder.name, folder.name)
        if self._launch_live is not None and self._live():
            try:
                self._keep_child(folder, self._launch_live(folder), "live")
            except Exception:
                LOGGER.exception("could not start live processing; transcribing after the call")
        # Calls only: a manual recording may be in person, with nobody on the system track.
        if self._new_coach is not None and trigger in CALL_TRIGGERS:
            try:
                self._coach = self._new_coach(folder)
                self._coach.start()
            except Exception:
                LOGGER.exception("could not start the live coach")
                self._coach = None
        if self._launch_stream is not None and self._realtime():  # read now: applies from this recording
            try:
                self._keep_child(folder, self._launch_stream(folder), "stream")
            except Exception:
                LOGGER.exception("could not start the live stream")

    def _keep_child(self, folder: Path, process, kind: str = "live") -> None:
        """Kept to reap it once it exits: an exited child left unwaited is a
        zombie, which still looks alive to `process`."""
        if hasattr(process, "poll"):
            self._children.setdefault(folder, []).append(process)
            self._kinds[id(process)] = kind

    def _reap_children(self) -> None:
        for folder in list(self._children):
            running = [p for p in self._children[folder] if p.poll() is None]  # poll reaps
            for p in self._children[folder]:
                if p not in running:
                    self._kinds.pop(id(p), None)
            if running:
                self._children[folder] = running
            else:
                del self._children[folder]

    # --- memory budgets (#49) ---------------------------------------------------------

    def watch_helper(self, folder: Path, process) -> None:
        """A best-next-question helper (#41) the window started: watched like
        notes, per meeting (#49), as its own kind ("question"): stopping it
        never counts against that meeting's notes. Safe from any thread."""
        with self._helpers_lock:
            self._helpers.append((Path(folder), process))

    def _running_helpers(self) -> list[tuple[Path, object]]:
        with self._helpers_lock:
            self._helpers = [(f, p) for f, p in self._helpers if p.poll() is None]
            return list(self._helpers)

    def _workers(self) -> list[tuple[str, Path, object]]:
        """Every worker this daemon started that may still run, by kind."""
        out = [(self._kinds.get(id(p), "live"), folder, p) for folder, procs in self._children.items() for p in procs]
        out += [("question", folder, p) for folder, p in self._running_helpers()]
        if self._processing is not None and self._processing_folder is not None:
            out.append(("process", self._processing_folder, self._processing))
        if self._notes is not None and self._notes_folder is not None:
            out.append(("notes", self._notes_folder, self._notes))
        if self._indexer is not None:
            out.append(("index", memory.INDEX_FOLDER, self._indexer))
        listed = {id(p) for _, _, p in out}
        out += [(e["kind"], e["folder"], e["process"]) for e in self._ending if id(e["process"]) not in listed]
        return out

    def _watch_memory(self) -> None:
        """Sample the workers; restart a live or stream worker over budget,
        stop notes or `process` over budget while the Mac is low on memory.
        The recording itself is never touched: capture runs in this process."""
        if self._watchdog is None:
            return
        try:
            actions = self._watchdog.check(self._workers(), self.now())
        except Exception:
            LOGGER.exception("measuring the workers' memory failed")
            actions = []
        for a in actions:
            if a.kind == "question":  # stopped, nothing queued, no notification: the window says so
                self._ending.append({"kind": a.kind, "folder": a.folder, "process": a.process, "since": self.now(),
                                     "restart": False, "told": ("", "")})
                try:
                    self._signal_worker(a.process, signal.SIGTERM)
                except Exception:
                    LOGGER.debug("asking a helper to stop failed", exc_info=True)
                continue
            if a.title and a.what != "restart":  # a restart is told once it happened
                notify.notify(a.title, a.message, None if a.kind == "index" else a.folder.name)
            if a.what == "warn":
                continue
            if a.kind == "process":
                self._memory_ended[id(a.process)] = a.what
                if a.what == "requeue":
                    self._retry_later(a.folder, why="was stopped: the Mac is low on memory")
                elif a.what == "drop":  # given up: the window offers to try again
                    process_state.mark(RecordingPaths(a.folder), process_state.ERROR,
                                       error="stopped too often: the Mac was low on memory")
            elif a.kind == "index":
                if self._indexer is a.process:
                    self._indexer = None
                self._index_later(a.what)
            elif a.kind == "notes":
                if self._notes is a.process:
                    self._notes, self._notes_folder = None, None
                if a.what == "requeue":
                    self._notes_later(a.folder)
            self._ending.append({"kind": a.kind, "folder": a.folder, "process": a.process, "since": self.now(),
                                 "restart": a.what == "restart", "told": (a.title, a.message)})
            try:
                self._signal_worker(a.process, signal.SIGTERM)
            except Exception:
                LOGGER.debug("asking a worker to stop failed", exc_info=True)
        self._finish_ending()

    def _index_later(self, what: str) -> None:
        """The search index stopped for low memory goes on after a backoff;
        the last time, not before Palaver starts again."""
        if what == "drop":
            self._index_resume_at = float("inf")
            LOGGER.warning("the search index was stopped too often for low memory; not before the next start")
            return
        self._index_tries += 1
        delay = min(RETRY_SECONDS * 2 ** (self._index_tries - 1), LIVE_FINISH_TIMEOUT)
        self._index_resume_at = self.now() + delay
        LOGGER.info("the search index was stopped: the Mac is low on memory; trying again in %.0f s", delay)

    def _notes_later(self, folder: Path) -> None:
        """Notes stopped for low memory wait in the queue, with a backoff,
        then for the free memory their model needs as any notes do."""
        n = self._notes_retries[folder] = self._notes_retries.get(folder, 0) + 1
        delay = min(RETRY_SECONDS * 2 ** (n - 1), LIVE_FINISH_TIMEOUT)
        self._notes_retry_at[folder] = self.now() + delay
        if folder not in self._notes_queue:
            self._notes_queue.append(folder)
        LOGGER.info("notes of %s were stopped: the Mac is low on memory; trying again in %.0f s", folder.name, delay)

    def _finish_ending(self) -> None:
        """Kill the workers stopped for their memory that did not exit in
        time; start a live or stream worker again once its old one is gone,
        while its recording still runs."""
        for e in list(self._ending):
            process = e["process"]
            if process.poll() is None:
                if self.now() - e["since"] >= KILL_AFTER and not e.get("killed"):
                    LOGGER.warning("%s of %s did not exit; killing it", memory.LABELS[e["kind"]].lower(),
                                   e["folder"].name)
                    try:
                        self._signal_worker(process, signal.SIGKILL)
                    except Exception:
                        LOGGER.debug("killing a worker failed", exc_info=True)
                    e["killed"] = True
                continue
            self._ending.remove(e)
            folder, kind = e["folder"], e["kind"]
            if not e["restart"]:
                continue
            if self._session is None or self._folder != folder:
                LOGGER.info("%s of %s not started again: the recording stopped; `process` does the rest",
                            memory.LABELS[kind].lower(), folder.name)
                continue
            launch = self._launch_live if kind == "live" else self._launch_stream
            if launch is None:
                continue
            LOGGER.info("starting %s of %s again", memory.LABELS[kind].lower(), folder.name)
            try:
                self._keep_child(folder, launch(folder), kind)
            except Exception:
                LOGGER.exception("could not start %s again", memory.LABELS[kind].lower())
                continue
            title, message = e["told"]
            if title:
                notify.notify(title, message, folder.name)

    def _worker_busy(self, folder: Path) -> bool:
        self._reap_children()
        return self._live_running(folder)

    def _stop(self, reason: str | None = None) -> None:
        """``reason``: "call_ended", "max_length", "by_you", "auto_off",
        "silence" (#7) or "restart" (Palaver quits) — kept in meta.json (lifecycle)."""
        session, folder, trigger, since = self._session, self._folder, self._trigger_name, self._since
        parts, before = self._parts, self._parts_seconds
        self._session, self._folder, self._trigger_name = None, None, None
        self._parts, self._parts_seconds = [], 0.0
        coach, self._coach = self._coach, None
        if coach is not None:
            try:
                coach.stop()
            except Exception:
                LOGGER.exception("could not stop the live coach")
        self._manual, self._question, self._silent = False, None, None
        if session is not None:
            self._stopped_at = self.now()
        self._since = self._wall()
        if session is None or folder is None:
            return
        head = parts[0] if parts else folder  # the meeting: its first part
        try:
            duration = session.stop(reason)
        except Exception as exc:
            LOGGER.exception("stopping the recording failed")
            notify.notify("Meeting recording failed", str(exc) or type(exc).__name__)
            # `process` recovers what was written, and joins it to the earlier parts.
            self._queue_meeting([*parts, folder])
            return
        self._last_stop = {"folder": str(folder), "reason": reason,
                           "text": lifecycle.stopped_text(trigger, reason), "at": self._wall().isoformat()}
        if reason == "restart" and trigger in CALL_TRIGGERS:
            # Held back: the next start continues it if the call is still on.
            self._release_cut(now=True)  # only one can be continued
            self._cut = {"folders": [str(f) for f in [*parts, folder]], "trigger": trigger,
                         "at": self._wall().isoformat(), "since": since.isoformat(),
                         "seconds": round(before + duration, 3)}
            LOGGER.info("Palaver quits while recording %s; a call still on within %d min continues it",
                        head.name, CONTINUE_WITHIN // 60)
            return
        duration += before
        minutes = duration / 60
        if self._queue_meeting([*parts, folder], duration) is None:
            notify.notify("Meeting recorded", f"{head.name}: under a minute, not transcribed", head.name)
            return
        LOGGER.info("call ended after %.1f min; queued transcription of %s", minutes, head.name)
        notify.notify("Meeting recorded", f"{minutes:.0f} min — transcribing in the background", head.name)

    def _pump_processing(self) -> None:
        self._pump_notes()
        try:
            self._pump_work()
        finally:
            self._pump_index()

    def _pump_work(self) -> None:
        if self._processing is not None:
            rc = self._processing.poll()
            if rc is None:
                return
            done = self._processing_folder
            stopped = self._memory_ended.pop(id(self._processing), None)
            if stopped is not None:
                # Stopped for its memory: queued again by _watch_memory, or given up.
                if stopped == "drop" and done is not None:
                    self._retries.pop(done, None)
            else:
                if rc == 0 and self._launch_notes is not None and done is not None:
                    self._notes_queue.append(done)
                if rc == EXIT_BUSY and done is not None:
                    self._retry_later(done)
                elif rc == process_state.EXIT_MODELS and done is not None:
                    self._wait_for_models(done)
                elif done is not None:
                    self._retries.pop(done, None)
                    if rc != 0:
                        # Not retried: running it again would fail the same way.
                        LOGGER.error("processing %s failed (exit %s); its session.log says why", done.name, rc)
                        if process_state.read(RecordingPaths(done)) is None:  # killed before it could say so
                            process_state.mark(RecordingPaths(done), process_state.ERROR,
                                               error=f"it stopped unexpectedly, exit {rc}")
                        notify.notify("Transcription failed",
                                      f"{done.name}: open it to see why and to transcribe it again", done.name)
            self._index_next = None  # a new transcript to index
        self._processing = None
        self._processing_folder = None
        now = self.now()
        folder = next((f for f in self._queue if self._retry_at.get(f, now) <= now), None)
        if folder is None:
            return
        if self._waits_for_models(folder):
            if not self._models_ready(folder):
                self._retry_at[folder] = now + MODELS_CHECK_SECONDS
                return
            LOGGER.info("the models of %s are here", folder.name)
            self._waiting_models.discard(folder)
        # A meeting continued after a restart: the live workers of all its parts.
        busy = [f for f in (folder, *continuation.parts(folder)) if self._worker_busy(f)]
        if busy:
            waiting = self._waiting_since.setdefault(folder, now)
            if now - waiting < LIVE_FINISH_TIMEOUT:
                return  # it writes most of the transcript; `run` then merges
            asked = self._stop_sent.get(folder)
            if asked is None:
                for f in busy:
                    LOGGER.warning("live processing of %s is stuck; stopping it", f.name)
                    self._stop_live(f)
                self._stop_sent[folder] = now
                return  # `process` runs once it has exited
            if now - asked < STOP_GRACE:
                return
            LOGGER.warning("live processing of %s did not exit; `process` decides", busy[0].name)
        self._queue.remove(folder)
        for pending in (self._waiting_since, self._stop_sent, self._retry_at):
            pending.pop(folder, None)
        LOGGER.info("transcribing %s", folder.name)
        self._processing = self._launch(folder)
        self._processing_folder = folder

    def _waits_for_models(self, folder: Path) -> bool:
        if folder in self._waiting_models:
            return True
        state = process_state.read(RecordingPaths(folder))  # since before a restart of the app
        return state is not None and state["reason"] == process_state.MODELS

    def _wait_for_models(self, folder: Path) -> None:
        """`process` found models missing: the setup's downloads have not
        finished. The meeting stays queued, never dropped, and is
        transcribed once they are here."""
        if folder not in self._waiting_models:
            self._waiting_models.add(folder)
            LOGGER.info("%s waits for its models to download", folder.name)
            notify.notify("Meeting recorded", f"{folder.name}: transcribed once the models are downloaded", folder.name)
        self._retry_at[folder] = self.now() + MODELS_CHECK_SECONDS
        if folder not in self._queue:
            self._queue.append(folder)

    def transcribe_again(self, folder: Path) -> bool:
        """Transcribe Again in the window: a meeting `process` failed on (or
        that waits for its models) goes first in the queue. False while it
        is being transcribed already."""
        if folder == self._processing_folder:
            return False
        process_state.clear(RecordingPaths(folder))
        self._waiting_models.discard(folder)
        for pending in (self._retry_at, self._retries, self._waiting_since, self._stop_sent):
            pending.pop(folder, None)
        if folder in self._queue:
            self._queue.remove(folder)
        self._queue.insert(0, folder)
        LOGGER.info("transcribing %s again, as asked", folder.name)
        return True

    def _retry_later(self, folder: Path, why: str = "is still busy") -> None:
        """`process` refused: something of the meeting is still busy (or it
        was stopped for its memory). It stays queued and is tried again
        later, never dropped."""
        n = self._retries[folder] = self._retries.get(folder, 0) + 1
        delay = min(RETRY_SECONDS * 2 ** (n - 1), LIVE_FINISH_TIMEOUT)
        self._retry_at[folder] = self.now() + delay
        if folder not in self._queue:
            self._queue.append(folder)
        LOGGER.info("%s %s; trying again in %.0f s", folder.name, why, delay)

    def _pump_notes(self) -> None:
        """Write queued notes one at a time — not while a call is recorded
        (back-to-back calls ran the notes model during the next one), not
        while a recording is processed, and only with enough free memory. A
        call that starts meanwhile stops them; they start over after it."""
        if self._notes is not None:
            if self._notes.poll() is not None:
                self._notes, self._notes_folder = None, None
                self._index_next = None  # new notes to index
            elif self._session is not None:
                LOGGER.info("a call started; writing the notes of %s again after it", self._notes_folder.name)
                self._notes.terminate()
                self._notes_queue.insert(0, self._notes_folder)
                self._notes, self._notes_folder = None, None
            return
        self._notes_waiting = None
        if not self._notes_queue or self._launch_notes is None:
            return
        if self._session is not None or self._processing is not None:
            return
        if any(e["kind"] == "notes" for e in self._ending):
            return  # the run stopped for low memory has not exited yet
        now = self.now()
        if self._notes_retry_at.get(self._notes_queue[0], now) > now:
            ready = [f for f in self._notes_queue if self._notes_retry_at.get(f, now) <= now]
            if not ready:
                return  # stopped for low memory: it waits its backoff
            self._notes_queue.remove(ready[0])
            self._notes_queue.insert(0, ready[0])
        needed = self._memory_needed(self._notes_queue[0])
        free = self._memory_free_gb() if needed > 0 else float("inf")
        if free < needed:
            if not self._notes_waiting_logged:
                LOGGER.info("notes wait for memory: %.0f GB free, %.0f GB needed", free, needed)
                self._notes_waiting_logged = True
            self._notes_waiting = {"meeting": self._notes_queue[0].name, "need": needed, "free": free}
            return
        self._notes_waiting_logged = False
        folder = self._notes_queue.pop(0)
        self._notes_retry_at.pop(folder, None)
        LOGGER.info("writing notes for %s", folder.name)
        self._notes, self._notes_folder = self._launch_notes(folder), folder

    def _pump_index(self) -> None:
        """Build the search index of meetings without one (``palaver
        index``): only when no call is recorded, nothing is transcribed and
        no notes are written or waiting, with free memory. Anything starting
        stops it; it goes on from where it was afterwards."""
        if self._launch_index is None:
            return
        busy = (self._session is not None or self._processing is not None or self._notes is not None
                or bool(self._notes_queue) or bool(self._queue))
        if self._indexer is not None:
            rc = self._indexer.poll()
            if rc is not None:
                self._indexer = None
                wait = self._index_check_seconds if rc == 0 else INDEX_RETRY_SECONDS
                if rc != 0:
                    LOGGER.warning("building the search index failed (exit %s); trying again in %.0f min",
                                   rc, wait / 60)
                self._index_next = self.now() + wait
            elif busy:
                LOGGER.info("pausing the search index while something else runs")
                self._indexer.terminate()
                self._indexer, self._index_next = None, None
            return
        if busy or (self._index_next is not None and self.now() < self._index_next):
            return
        if self.now() < self._index_resume_at or any(e["kind"] == "index" for e in self._ending):
            return  # stopped for low memory (#49): its backoff, or its exit
        self._index_next = self.now() + self._index_check_seconds
        if self._memory_free_gb() < INDEX_MEMORY_GB:
            return
        try:
            wanted = self._index_wanted()
        except Exception:
            LOGGER.debug("asking for the search index failed", exc_info=True)
            return
        if wanted:
            try:
                self._index_downloading = not self._index_model_ready()
            except Exception:
                self._index_downloading = False
            LOGGER.info("building the search index%s", " (downloading its model first)" if self._index_downloading else "")
            self._indexer = self._launch_index()

    def _memory_needed(self, folder: Path) -> float:
        """Free memory the notes of ``folder`` need: what their model needs,
        asked each time (the choice can change in Settings)."""
        need = self._notes_memory_gb
        return float(need(folder) if callable(need) else need)

    def _write_state(self, state: str | None = None) -> None:
        payload = self.status()
        if state is not None:
            payload["state"] = state
        try:
            self._state_path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self._state_path.with_suffix(".tmp")
            tmp.write_text(json.dumps(payload, indent=2))
            tmp.replace(self._state_path)
        except OSError:
            LOGGER.debug("could not write daemon state", exc_info=True)


def quit_reason(signum: int) -> str:
    """Ctrl+C in `palaver daemon` is the user's own stop; SIGTERM comes from
    outside (an update, a restart script) and holds a call's recording."""
    import signal

    return "by_you" if signum == signal.SIGINT else "restart"


def _calendar_lookup(cfg) -> Callable[[datetime], str | None]:
    """The key of the calendar event on at a moment, when the calendar is on."""
    def event_at(when: datetime) -> str | None:
        if not getattr(cfg, "calendar_enabled", False):
            return None
        from . import calendar_eventkit
        from .calendar_events import event_key_at

        if not calendar_eventkit.has_access():
            return None
        return event_key_at(calendar_eventkit.events_between(when - timedelta(hours=2), when + timedelta(hours=2)),
                            when)

    return event_at


def _event_now(cfg):
    """The calendar event on now, when the calendar is on; else None."""
    if not getattr(cfg, "calendar_enabled", False):
        return None
    from . import calendar_eventkit
    from .calendar_events import match

    if not calendar_eventkit.has_access():
        return None
    now = datetime.now().astimezone()
    return match(calendar_eventkit.events_between(now - timedelta(hours=2), now + timedelta(hours=2)),
                 now, now + timedelta(seconds=1))


def _coach_context(cfg) -> dict:
    """The live coach's context (#41): the invitees of the event on now and
    the user's baseline over every meeting."""
    from . import coach, live_coach

    try:
        event = _event_now(cfg)
    except Exception:
        LOGGER.debug("no calendar event for the live coach", exc_info=True)
        event = None
    from .voices import VoiceBank

    # Saved by `process` after the last call: nothing here reads the meetings.
    return live_coach.meeting_context(event, user_name=cfg.user_name, baseline=coach.load_baseline(),
                                      voices=list(VoiceBank().names()))


def busy_reason(status: dict) -> str | None:
    """What keeps Palaver from restarting now (an update waits for it, #60),
    from ``Daemon.status()``: a recording, its processing, notes being
    written or waiting. None: idle. The search index is no reason: it
    stops for anything, quitting too, and goes on from where it was."""
    if status.get("state") == "recording":
        return "recording"
    if status.get("teams_active"):  # a call, maybe recorded in a moment
        return "a call"
    if status.get("transcribing") or status.get("queued"):
        return "transcribing"
    if status.get("writing_notes") or status.get("notes_queued"):
        return "writing notes"
    return None


def read_status(state_path: Path | None = None) -> str:
    """One-line human status for ``daemon status``."""
    state_path = state_path or STATE_PATH
    try:
        state = json.loads(state_path.read_text())
    except (OSError, ValueError):
        return "daemon has never run"
    try:
        os.kill(int(state["pid"]), 0)
        alive = state["state"] != "stopped"
    except (OSError, ValueError, KeyError):
        alive = False
    if not alive:
        return f"daemon not running (last update {state.get('updated')})"
    line = f"daemon running (pid {state['pid']}): {state['state']} since {state['since']}"
    if state.get("folder"):
        line += f" → {state['folder']}"
    if state.get("transcribing") or state.get("queued"):
        line += f"; transcribing, {len(state.get('queued', []))} queued"
    if state.get("talk_text"):
        line += f"\n  {state['talk_text']}"
    if (state.get("nudge") or {}).get("text"):
        line += f"\n  Coach: {state['nudge']['text']}"
    return line


def build_daemon(cfg, cli_options: list[str] = (), silence: Callable[[], float | None] = lambda: None,
                 others_silence: Callable[[], float | None] = lambda: None) -> Daemon:
    """The daemon as `daemon` and `menubar` run it. ``silence``: seconds both
    tracks of the running recording were silent (the menu bar's levels)."""
    from . import live, live_coach, llm, onboarding, semantic, settings
    from .session import RecordingSession
    from .teams_detector import CallDetector

    defaults = settings.Settings(record_slack=getattr(cfg, "record_slack", True),
                                 live_processing=getattr(cfg, "live_processing", True))
    current = settings.Cached(defaults)  # the file is read again when it changes

    return Daemon(
        detect=CallDetector(teams=lambda: current().record_teams, slack=lambda: current().record_slack),
        new_session=lambda trigger: RecordingSession(cfg.output_dir, trigger=trigger),
        # Locally, notes are written apart, when no call is recorded; the
        # Notion upload needs them at once, so `run` keeps writing them itself.
        launch_processing=(
            (lambda folder: launch_run(folder, list(cli_options), cmd="run")) if cfg.notion_auto_sync
            else (lambda folder: launch_run(folder, list(cli_options), cmd="process", extra=["--no-notes"]))
        ),
        launch_notes=(
            (lambda folder: launch_run(folder, list(cli_options), cmd="notes"))
            if not cfg.notion_auto_sync and getattr(cfg, "notes_enabled", True) else None
        ),
        memory_free_gb=available_memory_gb,
        state_path=STATE_PATH,  # looked up now, so tests can move it
        notes_memory_gb=lambda folder: llm.notes_memory_gb(cfg, folder),
        launch_index=lambda: launch_run(None, list(cli_options), cmd="index", qos="background"),
        index_wanted=lambda: current().search_meaning and bool(semantic.stale(cfg.output_dir)),
        index_model_ready=lambda: semantic.embeddings.model_folder(download=False) is not None,
        models_ready=lambda folder: not process_state.missing_models(cfg, RecordingPaths(folder)),
        launch_live=lambda folder: launch_run(folder, list(cli_options), cmd="live", qos="background"),
        live=lambda: current().live_processing,
        before_record=onboarding.meeting_starting,
        launch_stream=lambda folder: launch_run(folder, list(cli_options), cmd="stream", qos="utility"),
        realtime=lambda: current().realtime,
        live_coach=lambda folder: live_coach.LiveCoach(
            folder, enabled=lambda: live_coach.enabled_kinds(current()), context=lambda: _coach_context(cfg)),
        silence=silence,
        others_silence=others_silence,
        calendar_event_at=_calendar_lookup(cfg),
        watchdog=memory.Watchdog(memory.budgets_for(cfg), free_gb=available_memory_gb,
                                 budget_for=memory.budget_hook(cfg)),
        signal_worker=memory.signal_group,
        live_running=live.worker_running,
        stop_live=live.stop_worker,
        done_marker="notion.json" if cfg.notion_auto_sync else "transcript.md",
        output_dir=Path(cfg.output_dir).expanduser(),
        processes=palaver_processes,
        trigger=Trigger(
            start_after=START_AFTER_SECONDS,
            grace=cfg.grace_period_seconds,
            max_session=cfg.max_session_hours * 3600,
        ),
    )


def forwarded_cli_options(args) -> list[str]:
    """Global CLI options to pass on to background `run` processes."""
    options = []
    if getattr(args, "config", None):
        options += ["--config", str(Path(args.config).expanduser().resolve())]
    if getattr(args, "dictionary", None):
        options += ["--dictionary", str(Path(args.dictionary).expanduser().resolve())]
    if getattr(args, "no_notify", False):
        options.append("--no-notify")
    return options
