"""Client for palaver-engine, the Swift speech engine (FluidAudio / CoreML).

The engine is a child process speaking JSON lines: one request per line on
its stdin, zero or more progress lines and exactly one reply per request on
its stdout, free-form log lines on its stderr. It answers one request at a
time, so ``call`` is serialised per ``Engine``; two ``Engine`` objects are
two child processes.
"""

from __future__ import annotations

import atexit
import json
import os
import queue
import subprocess
import threading
import weakref
from collections import deque
from pathlib import Path
from typing import Callable

from . import install_layout, session_log

REPO = Path(__file__).resolve().parent.parent
STDERR_KEEP = 20  # lines of the child's stderr kept for error messages
LOG_LINES_PER_CALL = 200
CLOSE_WAIT = 5.0
ENGINE_IDLE_TIMEOUT = 600.0  # seconds without any stdout line before the child is declared hung


MISSING_REASON = "the speech engine is missing"
DRAIN_WAIT = 1.0  # seconds a dead child's stderr is given to be read to its end


class EngineError(RuntimeError):
    """``reason``: one short line for failed.json; the message may carry the stderr tail."""

    def __init__(self, message: str, reason: str | None = None) -> None:
        super().__init__(message)
        self.reason = reason


class ModelsMissing(EngineError):
    pass


def engine_path() -> Path:
    env = os.environ.get("PALAVER_ENGINE")
    if env:
        return Path(env)  # as given: Engine reports it if it can't start
    app = install_layout.bundle()
    if app is not None:
        bundled = app / "Contents" / "MacOS" / "palaver-engine"
        if bundled.exists():
            return bundled
    checkout = REPO / "native" / ".build" / "release" / "palaver-engine"
    if checkout.exists():
        return checkout
    if app is not None:
        raise EngineError("the speech engine is missing: reinstall Palaver", reason=MISSING_REASON)
    raise EngineError("the speech engine is missing: run `make engine`", reason=MISSING_REASON)


_open: "weakref.WeakSet[Engine]" = weakref.WeakSet()
SUCCEEDED: set[str] = set()  # the commands that were answered ok in this process


@atexit.register
def _close_all() -> None:
    for e in list(_open):
        e.close()


def _drain_stderr(stream, tail: deque, counter: list, log: Callable[..., None]) -> None:
    """Runs in a thread that holds no reference to the Engine, so a dropped
    Engine can still be collected (and its __del__ end the child)."""
    try:
        for raw in stream:
            try:
                line = raw.rstrip("\n")
                tail.append(line)
                if counter[0] < LOG_LINES_PER_CALL:
                    counter[0] += 1
                    log("engine_log", line=line)
            except Exception:
                pass
    except (OSError, ValueError):
        pass


def _read_stdout(stream, lines: "queue.Queue[str | None]") -> None:
    try:
        for raw in stream:
            lines.put(raw)
    except (OSError, ValueError):
        pass
    lines.put(None)


class Engine:
    def __init__(self, path: Path | None = None, models: Path | None = None, idle_timeout: float | None = None) -> None:
        self._path = path
        self._models = models
        self._idle = ENGINE_IDLE_TIMEOUT if idle_timeout is None else idle_timeout
        self._proc: subprocess.Popen | None = None
        self._last_pid: int | None = None
        self._lines: "queue.Queue[str | None]" = queue.Queue()
        self._next_id = 0
        self._lock = threading.Lock()
        self._tail: deque[str] = deque(maxlen=STDERR_KEEP)
        self._counter = [0]  # stderr lines logged during the current call
        self._drain: threading.Thread | None = None

    def _start(self) -> subprocess.Popen:
        from . import __version__

        path = self._path or engine_path()
        models = self._models or install_layout.models_dir() / "fluidaudio"
        try:
            proc = subprocess.Popen(
                [str(path), "--models", str(models), "--version", __version__],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
            )
        except OSError as exc:
            raise EngineError(f"the speech engine could not start ({path}): {exc}") from exc
        self._tail = deque(maxlen=STDERR_KEEP)
        self._lines = queue.Queue()
        self._counter = [0]
        self._drain = threading.Thread(target=_drain_stderr, args=(proc.stderr, self._tail, self._counter, session_log.event), daemon=True)
        self._drain.start()
        threading.Thread(target=_read_stdout, args=(proc.stdout, self._lines), daemon=True).start()
        self._proc = proc
        self._last_pid = proc.pid
        _open.add(self)
        return proc

    def _reap(self, proc: subprocess.Popen) -> int:
        try:
            return proc.wait(timeout=CLOSE_WAIT)
        except subprocess.TimeoutExpired:
            proc.kill()
            return proc.wait()

    def _died(self, proc: subprocess.Popen, why: str | None = None) -> EngineError:
        if why is not None:
            proc.kill()
        code = self._reap(proc)
        if self._drain is not None:  # the pipe closes with the child: the drain ends after its last line
            self._drain.join(DRAIN_WAIT)
        tail = "\n".join(self._tail)
        session_log.event("engine_died", exit=code, reason=why or "exited", stderr=tail)
        self._drop(proc)
        message = why or f"the speech engine died (exit {code})"
        return EngineError(f"{message}:\n{tail}", reason=why or f"the speech engine stopped (exit {code})")

    def _drop(self, proc: subprocess.Popen) -> None:
        if self._proc is proc:
            self._proc = None
        _open.discard(self)
        for stream in (proc.stdin, proc.stdout, proc.stderr):
            try:
                stream.close()
            except Exception:
                pass

    def call(self, cmd: str, /, progress: Callable[[float, str], None] | None = None, **args) -> dict:
        with self._lock:
            proc = self._proc
            if proc is not None and proc.poll() is not None:
                raise self._died(proc)
            if proc is None:
                proc = self._start()
            self._counter[0] = 0
            self._next_id += 1
            rid = self._next_id
            line = json.dumps({**args, "id": rid, "cmd": cmd}) + "\n"
            try:
                proc.stdin.write(line)
                proc.stdin.flush()
            except (BrokenPipeError, OSError):
                raise self._died(proc) from None
            while True:
                try:
                    raw = self._lines.get(timeout=self._idle)
                except queue.Empty:
                    raise self._died(proc, f"the speech engine stopped answering ({self._idle:g} s without a line)") from None
                if raw is None:
                    raise self._died(proc)
                try:
                    msg = json.loads(raw)
                except ValueError:
                    continue
                if not isinstance(msg, dict) or msg.get("id") not in (rid, -1):
                    continue
                if "ok" not in msg:
                    if progress is not None and "progress" in msg:
                        try:
                            progress(float(msg["progress"]), str(msg.get("phase", "")))
                        except BaseException:
                            self._kill(proc)
                            raise
                    continue
                if msg["ok"]:
                    SUCCEEDED.add(cmd)
                    return msg
                error = str(msg.get("error", "unknown error"))
                if error.startswith("models missing"):
                    raise ModelsMissing(error)
                raise EngineError(error)

    def _kill(self, proc: subprocess.Popen) -> None:
        proc.kill()
        proc.wait()
        self._drop(proc)

    def close(self) -> None:
        proc = self._proc
        if proc is None:
            return
        if proc.poll() is None:
            try:
                proc.stdin.close()
            except OSError:
                pass
            self._reap(proc)
        self._drop(proc)

    def __del__(self) -> None:
        try:
            self.close()
        except Exception:
            pass
