"""The window server's view of the recording process (#57): the server runs
in its own process, so what the menu bar app's daemon knows comes from
daemon.json (written on every tick) and what it does goes through the app
socket (appctl). The same methods ``App.recording`` had when the server
ran inside the menu bar app.

When the recording process does not answer — not running, quit, or hung —
the page still shows: without the live bits, and an action says why it
did not happen.
"""

from __future__ import annotations

import json
import logging
import os
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

from .. import appctl

LOGGER = logging.getLogger(__name__)

# daemon.json is written every second while the app runs; older than this,
# the app is hung or gone.
STALE_SECONDS = 30.0
# Stopping a recording finishes its files on the app's main thread, which
# waits appctl.MAIN_THREAD_TIMEOUT for it: wait longer here, so the app's
# own answer (done, or busy) arrives.
ANSWER_TIMEOUT = appctl.MAIN_THREAD_TIMEOUT + 2.0
NO_ANSWER = "Palaver's menu bar app did not answer; try again in a moment."


def _pid_alive(pid) -> bool:
    try:
        os.kill(int(pid), 0)
    except (TypeError, ValueError, ProcessLookupError):
        return False
    except PermissionError:
        return True
    return True


def recording_view(status: dict | None) -> dict | None:
    """Why the running recording records (issue #47) and what is wrong with
    its audio (issue #50), or None."""
    if not status or not status.get("folder") or not status.get("why_text"):
        return None
    return {"meeting": Path(status["folder"]).name, "text": status["why_text"],
            "warnings": status.get("warnings") or [], "hints": status.get("hints") or []}


def coach_view(status: dict | None) -> dict | None:
    """Who talks in the running recording and the coach's nudge (#41), or None."""
    if not status or not status.get("folder") or not status.get("talk"):
        return None
    return {"meeting": Path(status["folder"]).name, "talk": status["talk"],
            "text": status.get("talk_text"), "nudge": status.get("nudge"), "quiet": status.get("quiet") or []}


class RemoteRecording:
    """``App.recording`` for a server in its own process."""

    def __init__(self, *, state_path: Path | None = None, socket_path: Path | None = None,
                 now: Callable[[], datetime] = lambda: datetime.now().astimezone(),
                 alive: Callable[[Any], bool] = _pid_alive):
        if state_path is None:
            from ..daemon import STATE_PATH

            state_path = STATE_PATH
        self._state_path = state_path
        self._socket_path = socket_path or appctl.APP_SOCKET
        self._now = now
        self._alive = alive

    # --- what daemon.json says ---------------------------------------------------------

    def _read(self) -> tuple[str, dict | None]:
        """("live", status) while the recording process runs and writes it;
        ("gone", None) when it does not run (or never ran); ("unknown", None)
        when it runs but has not written for a while."""
        try:
            status = json.loads(self._state_path.read_text())
        except (OSError, ValueError):
            return "gone", None
        if not isinstance(status, dict) or status.get("state") in (None, "stopped"):
            return "gone", None
        if not self._alive(status.get("pid")):
            return "gone", None
        try:
            age = (self._now() - datetime.fromisoformat(status["updated"])).total_seconds()
        except (KeyError, TypeError, ValueError):
            return "unknown", None
        if age > STALE_SECONDS:
            return "unknown", None
        return "live", status

    def _status(self) -> dict | None:
        return self._read()[1]

    def question(self) -> dict | None:
        status = self._status()
        return status.get("stop_question") if status else None

    def recording(self) -> dict | None:
        return recording_view(self._status())

    def coach(self) -> dict | None:
        return coach_view(self._status())

    def memory(self) -> dict | None:
        """What Palaver costs in memory now (#49), or None."""
        status = self._status()
        return status.get("memory") if status else None

    def indexing(self) -> dict:
        """Whether the search index is being built, and its model downloaded (#46)."""
        status = self._status() or {}
        return {"indexing": bool(status.get("indexing")), "downloading": bool(status.get("index_downloading"))}

    def busy(self) -> bool:
        """A recording or its processing runs: background work waits (#46).
        Not known (the app does not answer): as if busy."""
        how, status = self._read()
        if how == "unknown":
            return True
        return bool(status) and (status.get("state") == "recording" or bool(status.get("transcribing")))

    # --- what the recording process does -----------------------------------------------

    def answer(self, choice: str, meeting: str) -> bool:
        """"stop" or "keep" the manual recording ``meeting``; False when it no
        longer runs. Raises api.Refused when the app does not answer."""
        from .api import Refused

        try:
            return bool(appctl.call("answer", {"choice": choice, "meeting": meeting}, path=self._socket_path,
                                    timeout=ANSWER_TIMEOUT))
        except appctl.CallRefused as exc:
            raise Refused(str(exc)) from None
        except appctl.CallFailed:
            raise Refused(NO_ANSWER) from None

    def watch(self, folder: Path, process) -> None:
        """A best-next-question helper this server started (#41): the
        daemon watches its memory like notes (#49). Without the app it runs
        unwatched."""
        try:
            appctl.call("watch", {"folder": str(folder), "pid": int(process.pid)}, path=self._socket_path)
        except (appctl.CallFailed, appctl.CallRefused):
            LOGGER.info("the helper %s runs without the memory watchdog: the app did not answer", process.pid)

    def start_helper(self, kind: str, key: str, args: list[str]) -> int:
        """Have the app start a language model's helper (model_jobs), so it
        outlives a restart of this server; its pid. CallFailed when the app
        does not answer, CallRefused when it will not."""
        answer = appctl.call("start_helper", {"kind": kind, "key": key, "args": list(args)}, path=self._socket_path,
                             timeout=ANSWER_TIMEOUT)
        return int(answer["pid"])

    def switched_off(self, app: str) -> None:
        """A record switch turned off in Settings: that app's call stops now,
        as from the menu. Without the app, the daemon sees the switch on its
        next start."""
        try:
            appctl.call("switched_off", {"app": app}, path=self._socket_path, timeout=ANSWER_TIMEOUT)
        except (appctl.CallFailed, appctl.CallRefused):
            LOGGER.info("the app did not answer the record switch %s", app)


class RemoteTest:
    """The setup assistant's test recording (#55), recorded by the
    recording process: the server needs no mic or system audio permission,
    and a meeting starting stops the test there at once."""

    MAX_SECONDS = 20.0

    def __init__(self, socket_path: Path | None = None):
        self._socket_path = socket_path or appctl.APP_SOCKET

    def _call(self, args: dict, timeout: float = appctl.TIMEOUT) -> dict:
        return appctl.call("test", args, path=self._socket_path, timeout=timeout)

    def _idle(self) -> dict:
        return {"state": "idle", "max_seconds": self.MAX_SECONDS}

    def start(self, *, busy: Callable[[], bool] | bool = False, mode: dict | None = None) -> dict:
        if busy() if callable(busy) else busy:
            raise ValueError("a meeting is being recorded; try the test after it")
        try:
            return self._call({"action": "start", "mode": mode or {}}, timeout=ANSWER_TIMEOUT)
        except appctl.CallRefused as exc:
            raise ValueError(str(exc)) from None
        except appctl.CallFailed:
            raise ValueError(NO_ANSWER) from None

    def stop(self) -> dict:
        try:
            return self._call({"action": "stop"}, timeout=ANSWER_TIMEOUT)
        except (appctl.CallFailed, appctl.CallRefused):
            return self._idle()

    def status(self) -> dict:
        try:
            return self._call({})
        except (appctl.CallFailed, appctl.CallRefused):
            return self._idle()
