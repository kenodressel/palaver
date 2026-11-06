"""What Palaver's workers cost in memory, and what happens when one costs
too much (issue #49).

Memory is measured as macOS counts it: the phys_footprint, Activity
Monitor's "Memory". RSS misses what a model keeps on the GPU, which
was most of a live worker's 7.9 GB during a call.

The daemon starts four kinds of worker, each with a budget in GB
(``[memory]`` in config.toml). ``Watchdog`` samples them and decides; the
daemon acts:

- live, stream (they run during calls): over budget for OVER_SECONDS and
  OVER_SAMPLES samples → restarted (MAX_RESTARTS per meeting, then
  stopped: `process` does their work after the call). The recording goes
  on: capture runs in the recorder, not in a worker.
- notes, process, the search index: over budget → logged and notified once; they finish.
  Only when the Mac itself runs low on memory (under PRESSURE_GB free,
  sustained the same way) while one is over budget is it stopped and
  queued again with a backoff; the third time it is given up with a
  notification that says what to do. Never silently.

Every decision is logged; each kind of news is notified once per meeting.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import logging
import os
import time
from dataclasses import asdict, dataclass, field, fields
from pathlib import Path
from typing import Callable, Iterable

LOGGER = logging.getLogger(__name__)

GB = 1024**3
# A worker must stay over its budget this long, and this many samples,
# before it is acted on: a snapshot or a model load passes in a moment.
OVER_SECONDS = 10.0
OVER_SAMPLES = 3
MAX_RESTARTS = 2  # a live or stream worker restarted more often in one meeting is stopped
MAX_REQUEUES = 2  # notes or `process` stopped for low memory more often are given up (the 3rd time)
# The Mac is low on memory below this much free (daemon.available_memory_gb):
# only then are notes and `process` over budget stopped.
PRESSURE_GB = 1.5
# Speech and speakers run in the Swift engine (CoreML), a child of the worker,
# so a worker's footprint is the tree's: the process plus the engine. Gemma 4
# 12B writing notes ~12 GB (measured 2026-10-29). The speech budgets are for
# the engine; the budgets are the tree's, with headroom.
DEFAULT_LIVE_GB = 2.0
DEFAULT_STREAM_GB = 1.5
DEFAULT_PROCESS_GB = 4.0  # a 73-min meeting peaked at 2.5 GB (process plus engine)
DEFAULT_INDEX_GB = 1.0  # the search index (#46): a small embedding model
CLOUD_NOTES_GB = 2.0  # notes written by a cloud model: the model runs elsewhere

LABELS = {"live": "Live transcription", "stream": "Realtime transcription", "process": "Transcription",
          "notes": "Notes", "index": "Search index", "question": "Best next question"}
INDEX_FOLDER = Path("search index")  # the index worker is about no one meeting
KINDS = tuple(LABELS)


# --- measuring -----------------------------------------------------------------------------

_RUSAGE_INFO_V2 = 2


class _RusageV2(ctypes.Structure):
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16)] + [(n, ctypes.c_uint64) for n in (
        "ri_user_time", "ri_system_time", "ri_pkg_idle_wkups", "ri_interrupt_wkups", "ri_pageins",
        "ri_wired_size", "ri_resident_size", "ri_phys_footprint", "ri_proc_start_abstime",
        "ri_proc_exit_abstime", "ri_child_user_time", "ri_child_system_time", "ri_child_pkg_idle_wkups",
        "ri_child_interrupt_wkups", "ri_child_pageins", "ri_child_elapsed_abstime",
        "ri_diskio_bytesread", "ri_diskio_byteswritten")]


_LIB = None


def _lib():
    global _LIB
    if _LIB is None:
        _LIB = ctypes.CDLL(ctypes.util.find_library("proc"), use_errno=True)
    return _LIB


def footprint(pid: int) -> int | None:
    """The phys_footprint of ``pid`` in bytes; None when it is gone (or not
    ours to read)."""
    info = _RusageV2()
    try:
        if _lib().proc_pid_rusage(int(pid), _RUSAGE_INFO_V2, ctypes.byref(info)) != 0:
            return None
    except (OSError, AttributeError, TypeError, ValueError):
        return None
    return int(info.ri_phys_footprint)


def children(pid: int) -> list[int]:
    """The pids whose parent is ``pid``."""
    buffer = (ctypes.c_int * 1024)()
    try:
        n = _lib().proc_listchildpids(int(pid), buffer, ctypes.sizeof(buffer))
    except (OSError, AttributeError, TypeError, ValueError):
        return []
    return [p for p in buffer[:max(0, n)] if p > 0]


def tree_footprint(pid: int, *, sample: Callable[[int], int | None] = footprint,
                   children: Callable[[int], list[int] | None] = children) -> int | None:
    """``pid`` and everything it started (a worker's helpers count as the
    worker); None when ``pid`` is gone."""
    own = sample(pid)
    if own is None:
        return None
    return own + sum(tree_footprint(c, sample=sample, children=children) or 0 for c in children(pid) or [])


def size_text(used: float | None) -> str:
    """"5.4 GB", "12 GB", "317 MB"."""
    if used is None:
        return "—"
    if used < GB:
        return f"{used / 2**20:.0f} MB"
    gb = used / GB
    return f"{gb:.0f} GB" if gb >= 10 or abs(gb - round(gb)) < 0.05 else f"{gb:.1f} GB"


def cost_text(status: dict | None) -> str | None:
    """"Palaver 5.4 GB", for the recording status line."""
    if not status or status.get("total") is None:
        return None
    return f"Palaver {size_text(status['total'])}"


# --- budgets -------------------------------------------------------------------------------

@dataclass(frozen=True)
class Budgets:
    """GB of phys_footprint each kind of worker may use."""

    live: float = DEFAULT_LIVE_GB
    stream: float = DEFAULT_STREAM_GB
    process: float = DEFAULT_PROCESS_GB
    notes: float = 14.0
    index: float = DEFAULT_INDEX_GB

    def of(self, kind: str) -> float:
        # The best next question (#41) runs the notes' model: the notes' budget.
        return getattr(self, "notes" if kind == "question" else kind)


_KEYS = {f"{f.name}_gb": f.name for f in fields(Budgets)}


def parse_budgets(table: dict) -> dict[str, float]:
    """``[memory]`` of config.toml (``live_gb = 5``, ...) as Budgets fields.
    Called once, by load_config (Config.memory holds the result); a
    ValueError says what is wrong."""
    if not isinstance(table, dict):
        raise ValueError("[memory] must be a table")
    out = {}
    for key, value in table.items():
        if key not in _KEYS:
            raise ValueError(f"[memory].{key} is not known; use one of {', '.join(sorted(_KEYS))}")
        if isinstance(value, bool) or not isinstance(value, (int, float)) or value <= 0:
            raise ValueError(f"[memory].{key} must be a number of GB above 0")
        out[_KEYS[key]] = float(value)
    return out


def _notes_need(cfg, folder: Path | None = None) -> float:
    """Free memory the notes model needs (``llm.notes_memory_gb``: the model
    chosen in Settings for ``folder``); 0 for a cloud model."""
    from . import llm

    try:
        return float(llm.notes_memory_gb(cfg, folder))
    except Exception:
        LOGGER.debug("asking the notes model's memory failed", exc_info=True)
        from .notes import NOTES_MEMORY_GB

        return NOTES_MEMORY_GB


def budgets_for(cfg) -> Budgets:
    """The budgets ``cfg.memory`` sets (parsed by load_config), the defaults
    for the rest. The notes' default is what the notes model needs."""
    values = {"notes": _notes_need(cfg) or CLOUD_NOTES_GB, **(getattr(cfg, "memory", None) or {})}
    return Budgets(**values)


def _notes_in_run(cfg) -> bool:
    """Whether the daemon runs `run`, which writes the notes in the same process."""
    return bool(getattr(cfg, "notion_auto_sync", False) and getattr(cfg, "notes_enabled", True))


def budget_hook(cfg) -> Callable[[str, Path], float | None]:
    """The budgets that depend on the meeting: the notes' follows the model
    chosen for it (unless notes_gb is set); with the Notion upload on,
    `run` writes the notes too, so its budget is at least their need."""
    configured = getattr(cfg, "memory", None) or {}
    process = configured.get("process", DEFAULT_PROCESS_GB)

    def hook(kind: str, folder: Path) -> float | None:
        if kind in ("notes", "question") and "notes" not in configured:
            return _notes_need(cfg, folder) or CLOUD_NOTES_GB
        if kind == "process" and _notes_in_run(cfg):
            return max(process, _notes_need(cfg, folder))
        return None

    return hook


# --- the watchdog ----------------------------------------------------------------------------

@dataclass(frozen=True)
class Action:
    """What the daemon is to do with a worker. ``what``: "restart" (live,
    stream), "stop" (live, stream: no more restarts), "requeue" (notes,
    process, the Mac low on memory: stop it, the meeting waits in its queue),
    "drop" (the same, the last time: stop it and give up) or "warn" (over
    budget with memory to spare: nothing to do). ``title``: the
    notification, empty when it was already given for the meeting."""

    what: str
    kind: str
    folder: Path
    process: object
    used: int
    limit: float
    title: str = ""
    message: str = ""


class _Sustained:
    """A condition that must hold OVER_SAMPLES samples and OVER_SECONDS."""

    def __init__(self):
        self.since: float | None = None
        self.samples = 0

    def update(self, holds: bool, now: float) -> bool:
        if not holds:
            self.since, self.samples = None, 0
            return False
        if self.since is None:
            self.since = now
        self.samples += 1
        return self.samples >= OVER_SAMPLES and now - self.since >= OVER_SECONDS


@dataclass
class _Seen:
    kind: str
    folder: Path
    pid: int
    used: int = 0
    over: _Sustained = field(default_factory=_Sustained)
    pressure: _Sustained = field(default_factory=_Sustained)
    acted: str | None = None
    warned: bool = False


_ACTING = {"restart": "restarting", "stop": "stopping", "requeue": "stopping", "drop": "stopping"}


class Watchdog:
    """Samples the workers the daemon started and decides what to do with
    the ones over budget. Pure apart from ``sample`` (bytes of a pid, None
    when gone), ``own`` (the app process's bytes), ``others`` (bytes of the
    app's other children, given the workers' pids), ``free_gb`` (memory the
    Mac can hand out, asked only while a notes or process worker is over
    budget), ``budget_for`` (a budget that depends on the meeting, or None)
    and ``clock``."""

    def __init__(self, budgets: Budgets = Budgets(), *, sample: Callable[[int], int | None] = tree_footprint,
                 own: Callable[[], int | None] = lambda: footprint(os.getpid()),
                 others: Callable[[set[int]], int] | None = None,
                 free_gb: Callable[[], float] = lambda: float("inf"),
                 budget_for: Callable[[str, Path], float | None] | None = None,
                 clock: Callable[[], float] = time.monotonic):
        self.budgets = budgets
        self._sample = sample
        self._own = own
        self._others = others if others is not None else _other_children
        self._free_gb = free_gb
        self._budget_for = budget_for
        self._clock = clock
        self._seen: dict[int, _Seen] = {}
        self._restarts: dict[tuple[str, Path], int] = {}
        self._requeues: dict[tuple[str, Path], int] = {}
        self._notified: set[tuple[str, Path, str]] = set()
        self._app: int | None = None
        self._other: int = 0
        self._free: float | None = None  # asked once per check, when needed

    def budget(self, kind: str, folder: Path) -> float:
        if self._budget_for is not None:
            try:
                special = self._budget_for(kind, folder)
            except Exception:
                LOGGER.debug("the budget of %s failed", kind, exc_info=True)
                special = None
            if special is not None:
                return float(special)
        return self.budgets.of(kind)

    def check(self, workers: Iterable[tuple[str, Path, object]], now: float | None = None) -> list[Action]:
        """Sample ``workers`` ((kind, folder, process) with a ``pid``) and
        return what to do with the ones over budget."""
        now = self._clock() if now is None else now
        seen: dict[int, _Seen] = {}
        actions = []
        self._free = None
        for kind, folder, process in workers:
            pid = getattr(process, "pid", None)
            if not isinstance(pid, int):
                continue
            used = self._sample(pid)
            if used is None:
                continue
            s = self._seen.get(pid)
            if s is None or s.kind != kind or s.folder != folder:
                s = _Seen(kind, folder, pid)
            s.used = used
            seen[pid] = s
            action = self._judge(s, process, now)
            if action is not None:
                actions.append(action)
        self._seen = seen
        self._app = self._own()
        try:
            self._other = self._others(set(seen))
        except Exception:
            LOGGER.debug("measuring other children failed", exc_info=True)
            self._other = 0
        return actions

    def _free_now(self) -> float:
        if self._free is None:
            try:
                self._free = float(self._free_gb())
            except Exception:
                self._free = float("inf")
        return self._free

    def _judge(self, s: _Seen, process, now: float) -> Action | None:
        limit = self.budget(s.kind, s.folder)
        over = s.over.update(s.used / GB > limit, now)
        if s.acted is not None:
            return None
        if s.kind in ("live", "stream"):
            if not over:
                return None
            return self._act(s, process, "restart" if self._count(self._restarts, s, MAX_RESTARTS) else "stop", limit)
        # Notes and `process` are only stopped when the Mac itself runs low
        # on memory while they are over budget; else they finish.
        pressed = s.pressure.update(s.over.samples > 0 and self._free_now() < PRESSURE_GB, now)
        if s.kind == "question":
            # The user's click, not queued work: stopped when the Mac runs low,
            # counted against nothing (never the meeting's notes), told in the window.
            return self._act(s, process, "stop", limit, quiet=True) if over and pressed else None
        if over and pressed:
            return self._act(s, process, "requeue" if self._count(self._requeues, s, MAX_REQUEUES) else "drop",
                             limit)
        if over and not s.warned:
            s.warned = True
            return self._act(s, process, "warn", limit)
        return None

    @staticmethod
    def _count(counts: dict, s: _Seen, most: int) -> bool:
        """Count one more; whether it is still within ``most``."""
        key = (s.kind, s.folder)
        counts[key] = counts.get(key, 0) + 1
        return counts[key] <= most

    def _act(self, s: _Seen, process, what: str, limit: float, *, quiet: bool = False) -> Action:
        if what != "warn":
            s.acted = what
        free = self._free if self._free is not None and self._free != float("inf") else None
        title, message = ("", "") if quiet else _texts(s.kind, what, s.used, limit, s.folder.name, free)
        LOGGER.warning("%s of %s uses %s, over its %s budget%s; %s", LABELS[s.kind].lower(), s.folder.name,
                       size_text(s.used), size_text(limit * GB),
                       f", {size_text(free * GB)} free" if free is not None and what in ("requeue", "drop") else "",
                       _LOGGED[what])
        # Each kind of news once per meeting; giving up is always said.
        key = (s.kind, s.folder, "stopped" if what in ("requeue", "drop") else what)
        if key in self._notified and what not in ("stop", "drop"):
            title = message = ""
        self._notified.add(key)
        return Action(what, s.kind, s.folder, process, s.used, limit, title, message)

    def status(self) -> dict:
        """What Palaver costs now: ``total`` bytes (the app, its workers and
        its other children), ``app``, and each worker's state."""
        workers = []
        for s in self._seen.values():
            limit = self.budget(s.kind, s.folder)
            state = _ACTING.get(s.acted or "") or ("over budget" if s.used / GB > limit else "running")
            workers.append({"kind": s.kind, "label": LABELS[s.kind], "meeting": s.folder.name, "pid": s.pid,
                            "used": s.used, "budget": limit, "state": state})
        total = None
        if self._app is not None:
            total = self._app + sum(w["used"] for w in workers) + self._other
        return {"total": total, "app": self._app, "workers": workers, "budgets": asdict(self.budgets)}


_LOGGED = {"restart": "restarting it", "stop": "stopping it for this meeting",
           "requeue": "the Mac is low on memory: stopping it, tried again later",
           "drop": "the Mac is low on memory again: stopping it for good", "warn": "letting it finish"}
_TRIES = MAX_REQUEUES + 1


def _texts(kind: str, what: str, used: int, limit: float, meeting: str, free: float | None) -> tuple[str, str]:
    over = f"It used {size_text(used)}, over its {size_text(limit * GB)} budget."
    low = f"It used {size_text(used)} (budget {size_text(limit * GB)})" + (
        f" while only {size_text(free * GB)} were free." if free is not None else " while the Mac ran low on memory.")
    if kind in ("live", "stream"):
        label = LABELS[kind]
        if what == "restart":
            return f"{label} restarted", f"{over} The recording goes on."
        later = "The transcript is written after the call." if kind == "live" else "The transcript comes after the call."
        return f"{label} stopped", f"{over} It kept passing its budget; the recording goes on. {later}"
    if kind == "notes":
        if what == "warn":
            return "Notes use more memory than planned", f"{over} They finish unless the Mac runs low on memory."
        if what == "requeue":
            return "Notes paused: the Mac is low on memory", f"{low} They are written again later."
        return ("Notes not written: the Mac kept running low on memory",
                f"{meeting}: stopped {_TRIES} times. Close other apps, then use Write notes on the meeting "
                "in the Meetings window.")
    if kind == "index":
        if what == "warn":
            return "The search index uses more memory than planned", f"{over} It finishes unless the Mac runs low on memory."
        if what == "requeue":
            return "Search index paused: the Mac is low on memory", f"{low} It goes on later."
        return ("Search index paused: the Mac kept running low on memory",
                f"Stopped {_TRIES} times. It is built again when Palaver starts next; search by words works meanwhile.")
    if what == "warn":
        return "Transcription uses more memory than planned", f"{over} It finishes unless the Mac runs low on memory."
    if what == "requeue":
        return "Transcription paused: the Mac is low on memory", f"{low} Palaver tries again in a few minutes."
    return ("Transcription stopped: the Mac kept running low on memory",
            f"{meeting}: stopped {_TRIES} times. Close other apps, then run `palaver process` on it.")


def signal_group(process, sig: int) -> None:
    """Send ``sig`` to a worker and everything it started: workers run in
    their own session (start_new_session), so their pid is their group."""
    import signal as _signal

    pid = getattr(process, "pid", None)
    try:
        if isinstance(pid, int) and process.poll() is None and os.getpgid(pid) == pid:
            os.killpg(pid, sig)
            return
    except (OSError, ProcessLookupError):
        pass
    (process.kill if sig == _signal.SIGKILL else process.terminate)()


def _other_children(known: set[int], *, own: int | None = None,
                    sample: Callable[[int], int | None] = footprint,
                    children: Callable[[int], list[int] | None] = children) -> int:
    """Bytes of this process's children that are not known workers (the
    Meetings window's server process and its notes helper, a bench). A known
    worker further down (the window's best-next-question helper, #41) is
    counted as that worker, not twice."""
    def tree(pid: int) -> int:
        used = sample(pid)
        if used is None:
            return 0
        return used + sum(tree(c) for c in children(pid) or [] if c not in known)

    return sum(tree(c) for c in children(os.getpid() if own is None else own) or [] if c not in known)


class PeakTracker:
    """Footprint samples per label: the peak and the median (the soak test)."""

    def __init__(self, sample: Callable[[int], int | None] = tree_footprint):
        self._sample = sample
        self._values: dict[str, list[int]] = {}

    def sample(self, label: str, pid: int) -> int | None:
        used = self._sample(pid)
        if used is not None:
            self._values.setdefault(label, []).append(used)
        return used

    def peak(self, label: str) -> int:
        return max(self._values.get(label) or [0])

    def median(self, label: str) -> int:
        values = sorted(self._values.get(label) or [0])
        return values[len(values) // 2]

    def summary(self) -> dict[str, dict[str, int]]:
        return {k: {"peak": self.peak(k), "median": self.median(k), "samples": len(v)}
                for k, v in self._values.items()}
