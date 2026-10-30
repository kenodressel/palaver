"""The Meetings window's server in its own process (#57), so a change to
the window or its API needs only this process restarted, at any time,
also during a call: the recording runs in the menu bar app and is never
touched.

The menu bar app keeps the listening socket and hands it to each server
process it starts (``palaver webapp-serve --listen-fd N``): the port never
changes, and a request made while one server stops and the next starts
waits in the socket's queue instead of failing. The app restarts a crashed
server with backoff, a requested one (``palaver app restart-web``) at once,
and stops it when it quits. The server exits by itself when the app is
gone (its stdin, a pipe from the app, closes).
"""

from __future__ import annotations

import logging
import os
import select
import signal
import socket
import subprocess
import sys
import threading
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Callable, Iterable, Mapping

LOGGER = logging.getLogger(__name__)

# Seconds to wait before starting a crashed server again, one step per
# crash in a row; a server that ran this long before it crashed starts over.
BACKOFF = (1.0, 2.0, 5.0, 15.0, 30.0)
STABLE_AFTER = 60.0
READY_TIMEOUT = 20.0  # a server not serving by then is ended and started again
# A stopping server lets the changes being made finish this long (a cut or
# a join moves audio); the language model's runs are the app's and go on.
DRAIN_SECONDS = 60.0
STOP_TIMEOUT = DRAIN_SECONDS + 5.0  # SIGTERM, then SIGKILL


def listen(port: int = 0) -> socket.socket:
    """The window's listening socket on 127.0.0.1, kept by the menu bar app."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", port))
    sock.listen(128)
    return sock


def child_argv(cli_options: Iterable[str], *, listen_fd: int, ready_fd: int, app_socket: Path) -> list[str]:
    return [sys.executable, "-m", "palaver", *cli_options, "webapp-serve", "--listen-fd", str(listen_fd),
            "--ready-fd", str(ready_fd), "--app-socket", str(app_socket)]


def child_env(environ: Mapping[str, str]) -> dict[str, str]:
    """The server's environment: it posts notifications through the
    launcher like the app ($PALAVER_NOTIFY), but clicks on them stay the
    app's (it opens the window)."""
    return {k: v for k, v in environ.items() if k != "PALAVER_LAUNCHER_FD"}


class Inflight:
    """The changes (POSTs) a server is making now, so a requested stop lets
    them finish. A request that only waits for the language model's job
    (``detached``) is not one: the job is the app's and survives."""

    def __init__(self):
        self.count = 0
        self._cond = threading.Condition()
        self._local = threading.local()

    @contextmanager
    def change(self):
        with self._cond:
            self.count += 1
        self._local.counted = True
        try:
            yield
        finally:
            if getattr(self._local, "counted", False):
                self._leave()
            self._local.counted = False

    @contextmanager
    def detached(self):
        was = getattr(self._local, "counted", False)
        if was:
            self._leave()
            self._local.counted = False
        try:
            yield
        finally:
            if was:
                with self._cond:
                    self.count += 1
                self._local.counted = True

    def _leave(self):
        with self._cond:
            self.count -= 1
            self._cond.notify_all()

    def wait_idle(self, timeout: float) -> bool:
        with self._cond:
            return self._cond.wait_for(lambda: self.count <= 0, timeout)


def stop_in_background(web) -> threading.Thread:
    """``web.stop()`` off the caller's thread: quitting never waits for a
    server finishing its last change."""
    t = threading.Thread(target=web.stop, name="web-stop", daemon=True)
    t.start()
    return t


class backoff_delays:  # noqa: N801  (used like a function's result)
    """The wait before each restart of a crashed server."""

    def __init__(self, steps: Iterable[float] = BACKOFF, stable_after: float = STABLE_AFTER):
        self._steps = tuple(steps)
        self._stable_after = stable_after
        self._crashes = 0

    def next(self, *, ran_for: float) -> float:
        if ran_for >= self._stable_after:
            self._crashes = 0
        delay = self._steps[min(self._crashes, len(self._steps) - 1)]
        self._crashes += 1
        return delay

    def reset(self) -> None:
        self._crashes = 0


class WebSupervisor:
    """Starts the server process with ``command(listen_fd, ready_fd)`` and
    keeps it running. ``on_ready(restarted)`` is called (from a background
    thread) each time a server is up: ``restarted`` for every one after
    the first, so the window can load the page again."""

    def __init__(self, command: Callable[[int, int], list[str]], *, listener: socket.socket,
                 env: Mapping[str, str] | None = None, on_ready: Callable[[bool], None] = lambda restarted: None,
                 backoff: Iterable[float] = BACKOFF, stable_after: float = STABLE_AFTER,
                 stop_timeout: float = STOP_TIMEOUT, ready_timeout: float = READY_TIMEOUT):
        self.listener = listener
        self.port = listener.getsockname()[1]
        self._command = command
        self._env = dict(env) if env is not None else None
        self._on_ready = on_ready
        self._delays = backoff_delays(backoff, stable_after)
        self._stop_timeout = stop_timeout
        self._ready_timeout = ready_timeout
        self._lock = threading.Lock()
        self._ready = threading.Condition()
        self._spawned = 0  # servers started
        self._up = 0  # the number of the last server that said it serves
        self._proc: subprocess.Popen | None = None
        self._stopping = False
        self._restart_wanted = False
        self._wake = threading.Event()
        self._thread: threading.Thread | None = None

    @property
    def pid(self) -> int | None:
        proc = self._proc
        return proc.pid if proc is not None and proc.poll() is None else None

    def url(self, meeting_id: str | None = None) -> str:
        return f"http://127.0.0.1:{self.port}/" + (f"#/{meeting_id}" if meeting_id else "")

    def start(self) -> None:
        self._thread = threading.Thread(target=self._run, name="web-supervisor", daemon=True)
        self._thread.start()

    def restart(self, timeout: float | None = None) -> int | None:
        """A new server now (no backoff), after the running one finished its
        changes; returns the new one's pid once it is up (None if it is not)."""
        with self._lock:
            if self._stopping:
                return None
            self._restart_wanted = True
            proc = self._proc
            target = self._spawned + 1  # the server started after this one, not this one coming up
            self._wake.set()
        if proc is not None:
            self._end(proc)
        with self._ready:
            self._ready.wait_for(lambda: self._up >= target or self._stopping,
                                 self._ready_timeout if timeout is None else timeout)
            up = self._up >= target
        return self.pid if up else None

    def stop(self) -> None:
        """The app quits: stop the server, start no other."""
        with self._lock:
            self._stopping = True
            proc = self._proc
            self._wake.set()
        if proc is not None:
            self._end(proc)
        with self._ready:
            self._ready.notify_all()
        if self._thread is not None and self._thread is not threading.current_thread():
            self._thread.join(self._stop_timeout + 2)

    def _end(self, proc: subprocess.Popen) -> None:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(self._stop_timeout)
            except subprocess.TimeoutExpired:
                LOGGER.warning("the window's server did not stop; killing it")
                proc.kill()
                proc.wait()
        self._close_stdin(proc)

    @staticmethod
    def _close_stdin(proc: subprocess.Popen) -> None:
        try:
            if proc.stdin is not None:
                proc.stdin.close()
        except OSError:
            pass

    def _spawn(self) -> tuple[subprocess.Popen, int]:
        read, write = os.pipe()
        fd = self.listener.fileno()
        try:
            # Its own session: a Ctrl+C meant for `palaver menubar` in a terminal
            # reaches the app, which then stops the server itself.
            proc = subprocess.Popen(self._command(fd, write), stdin=subprocess.PIPE, env=self._env,
                                    pass_fds=(fd, write), start_new_session=True)
        except BaseException:
            os.close(read)
            raise
        finally:
            os.close(write)
        return proc, read

    def _wait_ready(self, read: int) -> bool:
        """Whether the server said it serves; False when it exited first."""
        deadline = time.monotonic() + self._ready_timeout
        got = b""
        try:
            while b"\n" not in got:
                left = deadline - time.monotonic()
                if left <= 0 or self._stopping:
                    return False
                if select.select([read], [], [], min(left, 0.5))[0]:
                    chunk = os.read(read, 64)
                    if not chunk:
                        return False
                    got += chunk
            return got.startswith(b"ready")
        finally:
            os.close(read)

    def _run(self) -> None:
        restarted = False
        while True:
            with self._lock:
                if self._stopping:
                    return
                self._restart_wanted = False
                self._wake.clear()
                try:
                    proc, read = self._spawn()
                except OSError:
                    LOGGER.exception("could not start the window's server")
                    proc, read = None, None
                self._proc = proc
                self._spawned += 1
                number = self._spawned
            started = time.monotonic()
            if proc is not None:
                if self._wait_ready(read):
                    if not self._stopping:
                        with self._ready:
                            self._up = number
                            self._ready.notify_all()
                        try:
                            self._on_ready(restarted)
                        except Exception:
                            LOGGER.exception("after the window's server started")
                elif proc.poll() is None:  # it never said it serves: hung while starting
                    LOGGER.warning("the window's server did not start within %.0f s; ending it", self._ready_timeout)
                    proc.kill()
                proc.wait()
                self._close_stdin(proc)
            with self._lock:
                if self._stopping:
                    return
                wanted = self._restart_wanted
            restarted = True
            if wanted:
                self._delays.reset()
                continue
            delay = self._delays.next(ran_for=time.monotonic() - started)
            LOGGER.warning("the window's server exited (%s); starting it again in %.1f s",
                           None if proc is None else proc.returncode, delay)
            self._wake.wait(delay)


# --- the server process ----------------------------------------------------------------

def exit_when_parent_gone(stream, exit: Callable[[int], None] = os._exit) -> threading.Thread:
    """``exit(0)`` once ``stream`` (stdin, a pipe from the menu bar app)
    closes: the app is gone, and with it the window. It reads the raw
    descriptor: a thread blocked in the buffered reader holds its lock, and
    Python aborts on that lock when the server stops on its own (a restart)."""
    fd = stream.fileno()

    def watch():
        try:
            while os.read(fd, 4096):
                pass
        except (OSError, ValueError):
            pass
        exit(0)

    t = threading.Thread(target=watch, name="parent-watch", daemon=True)
    t.start()
    return t


def serve(cfg, cli_options: list[str], *, listen_fd: int | None = None, ready_fd: int | None = None,
          app_socket: Path | None = None, port: int = 0) -> int:
    """`palaver webapp-serve`: the window's server, until SIGTERM (or the app is gone)."""
    from . import api, build_app
    from .remote import RemoteRecording, RemoteTest
    from .server import make_server, sweep_leftovers

    recording = RemoteRecording(socket_path=app_socket)
    app = build_app(cfg, cli_options, recording=recording)
    app.probe.test = RemoteTest(app_socket)  # recorded by the app: this process needs no mic
    sock = socket.socket(fileno=listen_fd) if listen_fd is not None else None
    server = make_server(app, port, sock=sock)

    def stop(*_):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    if listen_fd is not None and not sys.stdin.isatty():
        exit_when_parent_gone(sys.stdin.buffer, exit=stop)  # the app is gone: finish the changes, then go
    # The first search after a start reads every meeting: do that before
    # it is asked, a little later and never during a recording (#46).
    api.start_warming(app.output_dir, user_name=app.user_name, recording=recording)
    LOGGER.info("the window's server (pid %d) serves on port %d", os.getpid(), server.server_address[1])
    if ready_fd is not None:
        os.write(ready_fd, b"ready\n")
        os.close(ready_fd)
    threading.Thread(target=sweep_leftovers, args=(app,), name="sweep", daemon=True).start()  # after: never delays it
    try:
        server.serve_forever()
    finally:
        server.server_close()  # no new requests; the queued ones wait for the next server
        if not app.inflight.wait_idle(DRAIN_SECONDS):
            LOGGER.warning("the window's server stops with %d change(s) unfinished", app.inflight.count)
    return 0
