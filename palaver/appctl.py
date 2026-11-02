"""The small local interface between the recording process (the menu bar
app) and the Meetings window's server, which runs in its own process
(#57) so it can be restarted at any time without touching a recording.

What the server only reads (the state of the running recording, its stop
question, live coach, memory) it reads from daemon.json, which the daemon
writes on every tick. What it asks the recording process to do goes
through a Unix socket in the app support folder: one JSON request
``{"call": name, "args": {...}}`` and one JSON answer per connection
(``{"ok": result}`` or ``{"error": message, "refused": bool}``). Only
this user can open the socket (mode 0600, in their own Library).

Timeouts are short: a recording process that does not answer is a
``CallFailed``, and the server carries on without it.
"""

from __future__ import annotations

import json
import logging
import os
import signal
import socket
import socketserver
import threading
from pathlib import Path
from typing import Any, Callable

LOGGER = logging.getLogger(__name__)

APP_SOCKET = Path.home() / "Library" / "Application Support" / "palaver" / "app.sock"
TIMEOUT = 1.0  # seconds: the window polls; an app that does not answer this fast is left out
MAIN_THREAD_TIMEOUT = 10.0  # what runs on the menu bar's main thread waits for it this long at most
MAX_REQUEST = 64 * 1024

# The record switches as the daemon names a call's app (menu bar and Settings page).
SWITCH_APP = {"record_teams": "teams", "record_slack": "slack"}


class CallFailed(Exception):
    """The recording process is not there or did not answer in time."""


class CallRefused(Exception):
    """The recording process answered no; the message says why, for the page."""


# --- the recording process's side -------------------------------------------------------

class ControlServer:
    """The socket, served from a background thread until ``close()``."""

    def __init__(self, server: socketserver.ThreadingUnixStreamServer, path: Path):
        self._server = server
        self.path = path

    def close(self) -> None:
        self._server.shutdown()
        self._server.server_close()
        try:
            self.path.unlink()
        except FileNotFoundError:
            pass


def serve(path: Path, calls: dict[str, Callable[[dict], Any]]) -> ControlServer:
    """Answer ``calls`` (name -> fn(args)) on the Unix socket ``path``."""

    class Handler(socketserver.StreamRequestHandler):
        timeout = 5.0  # a client that sends nothing

        def handle(self):
            try:
                request = json.loads(self.rfile.readline(MAX_REQUEST) or b"{}")
                name, args = request.get("call"), request.get("args") or {}
                fn = calls.get(name)
                if fn is None:
                    answer = {"error": f"unknown call {name!r}", "refused": True}
                else:
                    answer = {"ok": fn(args)}
            except CallRefused as exc:
                answer = {"error": str(exc), "refused": True}
            except Exception as exc:
                LOGGER.exception("the app socket's call failed")
                answer = {"error": str(exc) or type(exc).__name__, "refused": False}
            try:
                self.wfile.write(json.dumps(answer, default=str).encode() + b"\n")
            except OSError:  # the caller gave up
                pass

    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        path.unlink()  # left over from a crash
    except FileNotFoundError:
        pass
    old = os.umask(0o177)
    try:
        server = socketserver.ThreadingUnixStreamServer(str(path), Handler)
    finally:
        os.umask(old)
    os.chmod(path, 0o600)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, name="app-socket", daemon=True).start()
    return ControlServer(server, path)


def app_calls(daemon, *, on_main: Callable[[Callable[[], Any]], Any], test_recording,
              restart_web: Callable[[], int | None], refresh: Callable[[], None],
              launch_helper: Callable[[str, str, list[str]], int] | None = None) -> dict[str, Callable[[dict], Any]]:
    """What the recording process answers. ``on_main(fn)`` runs ``fn`` on
    the main thread, where the daemon ticks, and returns its result;
    ``test_recording``: the setup assistant's test (onboarding.TestRecording);
    ``restart_web()`` restarts the window's server, returns its new pid;
    ``launch_helper(kind, key, args)`` starts a language model's helper for
    the window (model_jobs.launch), returns its pid; ValueError: not one."""

    def answer(args: dict) -> bool:
        choice, meeting = str(args.get("choice")), args.get("meeting")

        def run():
            done = daemon.answer_stop_question(choice, None if meeting is None else str(meeting))
            refresh()
            return done

        return bool(on_main(run))

    def switched_off(args: dict) -> None:
        app = args.get("app")
        if app not in SWITCH_APP.values():
            raise CallRefused(f"no record switch for {app!r}")

        def run():
            daemon.switched_off(app)
            refresh()

        on_main(run)

    def watch(args: dict) -> None:
        pid = int(args["pid"])
        if not descendant(pid):  # never another program's process: the watchdog may stop it
            raise CallRefused(f"{pid} is not a process Palaver started")
        daemon.watch_helper(Path(str(args["folder"])), PidProcess(pid))

    def start_helper(args: dict) -> dict:
        if launch_helper is None:
            raise CallRefused("this app starts no helpers")
        try:
            pid = launch_helper(str(args.get("kind")), str(args.get("key")), [str(a) for a in args.get("args") or []])
        except ValueError as exc:
            raise CallRefused(str(exc)) from None
        return {"pid": pid}

    def transcribe(args: dict) -> bool:
        folder = Path(str(args.get("folder")))
        if not folder.is_dir():
            raise CallRefused(f"no recording at {folder}")

        def run():
            queued = daemon.transcribe_again(folder)
            refresh()
            return queued

        return bool(on_main(run))

    def recording_now() -> bool:
        return daemon.status()["state"] == "recording"

    def test(args: dict) -> dict:
        action = args.get("action")
        try:
            if action == "start":
                return test_recording.start(busy=recording_now, mode=args.get("mode") or {})
        except ValueError as exc:
            raise CallRefused(str(exc)) from None
        if action == "stop":
            return test_recording.stop()
        return test_recording.status()

    return {
        "ping": lambda args: {"pid": os.getpid()},
        "answer": answer,
        "switched_off": switched_off,
        "watch": watch,
        "start_helper": start_helper,
        "transcribe": transcribe,
        "test": test,
        "restart_web": lambda args: {"pid": restart_web()},
    }


def descendant(pid: int, root: int | None = None,
               children: Callable[[int], list[int] | None] | None = None) -> bool:
    """Whether ``pid`` runs under ``root`` (this process): a child, or a
    child's child (the window server's helpers). Never ``root`` itself,
    launchd or the kernel."""
    if children is None:
        from .memory import children
    root = os.getpid() if root is None else root
    if pid <= 1 or pid == root:
        return False
    seen, todo = {root}, [root]
    while todo:
        for child in children(todo.pop()) or []:
            if child == pid:
                return True
            if child not in seen:
                seen.add(child)
                todo.append(child)
    return False


class PidProcess:
    """A helper the window's server started, as the daemon's memory
    watchdog sees its workers (``pid``, ``poll``, ``terminate``, ``kill``):
    it is not this process's child, so it is known by its pid."""

    def __init__(self, pid: int):
        self.pid = int(pid)
        self.returncode: int | None = None

    def poll(self) -> int | None:
        if self.returncode is None:
            try:
                os.kill(self.pid, 0)
            except ProcessLookupError:
                self.returncode = 0
            except PermissionError:  # someone else's pid now
                self.returncode = 0
        return self.returncode

    def _signal(self, sig: int) -> None:
        if self.poll() is None:
            try:
                os.kill(self.pid, sig)
            except ProcessLookupError:
                self.returncode = 0

    def terminate(self) -> None:
        self._signal(signal.SIGTERM)

    def kill(self) -> None:
        self._signal(signal.SIGKILL)


# --- the window server's side -----------------------------------------------------------

def call(name: str, args: dict | None = None, *, path: Path | None = None, timeout: float = TIMEOUT) -> Any:
    """Ask the recording process; raises CallFailed (not there, too slow) or
    CallRefused (it said no, and why)."""
    path = path or APP_SOCKET
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(timeout)
            sock.connect(str(path))
            sock.sendall(json.dumps({"call": name, "args": args or {}}).encode() + b"\n")
            data = b""
            while not data.endswith(b"\n"):
                chunk = sock.recv(65536)
                if not chunk:
                    break
                data += chunk
    except (OSError, ValueError) as exc:  # socket.timeout is an OSError
        raise CallFailed(f"{name}: {exc}") from None
    try:
        answer = json.loads(data)
    except ValueError:
        raise CallFailed(f"{name}: no answer") from None
    if "ok" in answer:
        return answer["ok"]
    if answer.get("refused"):
        raise CallRefused(str(answer.get("error") or "refused"))
    raise CallFailed(f"{name}: {answer.get('error')}")
