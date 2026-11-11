"""The menu bar app as palaver-server sees it in the end-to-end tests: daemon.json in the
test's home, written several times a second from a ``FakeRecording`` (the question
whether to stop it, the live coach, why it records), and app.sock served here
(``serve``: the app's protocol) in the test's process, so the test changes the fake
directly and sees the calls the server made.

Nothing here talks to the real app: the socket and daemon.json are the test's.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import socketserver
import sys
import tempfile
import threading
import time
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path

from .stores import jobs_root, launch_job

TICK_SECONDS = 0.1  # the real app writes daemon.json every second; the tests wait less


# --- app.sock: one JSON request per connection, one JSON answer ---------------------------------------

MAX_REQUEST = 1 << 20


class CallRefused(Exception):
    """The app answered no; the message says why, for the page."""


class ControlServer:
    def __init__(self, server: socketserver.ThreadingUnixStreamServer, path: Path):
        self._server, self.path = server, path

    def close(self) -> None:
        self._server.shutdown()
        self._server.server_close()
        self.path.unlink(missing_ok=True)


def serve(path: Path, calls: dict) -> ControlServer:
    """Answers ``calls`` (name -> fn(args)) on the Unix socket ``path``: {"call", "args"} in, {"ok": …} or
    {"error", "refused"} out, as the app's AppSocket does."""

    class Handler(socketserver.StreamRequestHandler):
        timeout = 5.0

        def handle(self):
            try:
                request = json.loads(self.rfile.readline(MAX_REQUEST) or b"{}")
                name, args = request.get("call"), request.get("args") or {}
                fn = calls.get(name)
                answer = {"error": f"unknown call {name!r}", "refused": True} if fn is None else {"ok": fn(args)}
            except CallRefused as exc:
                answer = {"error": str(exc), "refused": True}
            except Exception as exc:
                answer = {"error": str(exc) or type(exc).__name__, "refused": False}
            try:
                self.wfile.write(json.dumps(answer, default=str).encode() + b"\n")
            except OSError:
                pass

    path.parent.mkdir(parents=True, exist_ok=True)
    path.unlink(missing_ok=True)
    old = os.umask(0o177)
    try:
        server = socketserver.ThreadingUnixStreamServer(str(path), Handler)
    finally:
        os.umask(old)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, name="app-socket", daemon=True).start()
    return ControlServer(server, path)


# --- the setup assistant's test recording ----------------------------------------------------------------

class FakeRecorder:
    """The test recording's capture: no microphone, no audio files. The result is what ``analyze`` answers."""

    def __init__(self):
        self.started: list[Path] = []
        self.modes: list[dict] = []
        self.stopped = 0
        self.result = {"mic": {"recorded": True, "level_db": -24.0, "text": "This is my test sentence"},
                       "system": {"recorded": True, "level_db": -90.0}}
        self.gate = threading.Event()
        self.gate.set()

    def capture(self, folder: Path):
        self.started.append(folder)

        def stop():
            self.stopped += 1
            return folder / "mic.wav", folder / "system.wav"
        return stop

    def analyze(self, mic, system, mode):
        self.gate.wait(10)
        self.modes.append(mode)
        return self.result


@dataclass
class Check:
    name: str
    status: str  # ok | warn | fail
    detail: str
    fix: str = ""


SPEECH_DB = -50.0  # louder than this on the mic track: someone spoke
QUIET_DB = -60.0  # quieter than this on the system track: nothing played


def test_verdict(result: dict) -> list[Check]:
    """What the test recording found on each track, as the app says it."""
    mic, system = result.get("mic") or {}, result.get("system") or {}
    if not mic.get("recorded"):
        mic_check = Check("Microphone", "fail", "nothing was recorded")
    elif (mic.get("level_db") or -120.0) > SPEECH_DB or mic.get("text"):
        text = (mic.get("text") or "").strip()
        mic_check = Check("Microphone", "ok", f"heard you: “{text}”" if text else "heard you")
    else:
        mic_check = Check("Microphone", "warn", "the microphone track is silent")
    if not system.get("recorded"):
        sys_check = Check("System audio", "fail", "not recorded")
    elif system.get("level_db") is None or system["level_db"] < QUIET_DB:
        sys_check = Check("System audio", "ok", "recorded; quiet, as nothing played")
    else:
        sys_check = Check("System audio", "ok", "recorded, with sound from other apps")
    return [mic_check, sys_check]


class TestRecording:
    """The app's test recording with a fake capture: started and stopped by the page's clicks (or after
    MAX_SECONDS), checked by ``analyze`` in the background."""

    __test__ = False  # not a pytest class
    MAX_SECONDS = 20.0

    def __init__(self, capture, analyze):
        self._capture, self._analyze = capture, analyze
        self._lock = threading.Lock()
        self._state, self._started = "idle", 0.0
        self._stop = self._folder = self._result = self._error = self._timer = None
        self._mode: dict = {}

    def start(self, *, mode: dict | None = None) -> dict:
        with self._lock:
            if self._state in ("recording", "checking"):
                return self._status()
            self._folder = Path(tempfile.mkdtemp(prefix="palaver-test-"))
            self._stop = self._capture(self._folder)
            self._state, self._started, self._result, self._error = "recording", time.monotonic(), None, None
            self._mode = dict(mode or {})
            self._timer = threading.Timer(self.MAX_SECONDS, self.stop)
            self._timer.daemon = True
            self._timer.start()
            return self._status()

    def stop(self) -> dict:
        with self._lock:
            taken = None
            if self._state == "recording":
                self._timer.cancel()
                self._state = "checking"
                taken = (self._stop, self._folder)
        if taken:
            threading.Thread(target=self._finish, args=taken, daemon=True).start()
        return self.status()

    def _finish(self, stop, folder: Path) -> None:
        try:
            mic, system = stop()
            result, error = self._analyze(mic, system, self._mode), None
        except Exception as exc:
            result, error = None, f"the test failed: {exc}"
        finally:
            shutil.rmtree(folder, ignore_errors=True)
        with self._lock:
            self._state = "failed" if error else "done"
            self._result, self._error = result, error

    def _status(self) -> dict:
        out = {"state": self._state, "max_seconds": self.MAX_SECONDS}
        if self._state == "recording":
            out["seconds"] = round(time.monotonic() - self._started, 1)
        if self._result is not None:
            out["checks"] = [asdict(c) for c in test_verdict(self._result)]
        if self._error:
            out["error"] = self._error
        return out

    def status(self) -> dict:
        with self._lock:
            return self._status()


# --- the language model's helpers the window has the app start -------------------------------------------

_PROJECT_ID = re.compile(r"[0-9a-f]{1,64}")
_FOLDER_NAME = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}(-\d+)?")


def helper_argv(lm: Path, kind: str, args: list[str], cli_options: list[str], *, output_dir: Path) -> list[str]:
    """`palaver-lm <options> --no-notify notes <a meeting> --force` or `… projects --no-wait suggest | describe <id>`,
    as the app's HelperJobs make it (without taskpolicy); ValueError for anything else."""
    if kind == "notes":
        if len(args) != 2 or args[1] != "--force":
            raise ValueError("not a notes helper")
        folder = Path(args[0])
        if folder.parent.resolve() != Path(output_dir).resolve() or not _FOLDER_NAME.fullmatch(folder.name):
            raise ValueError("not a meeting's folder")
    elif kind == "projects":
        if not (args == ["--no-wait", "suggest"]
                or (len(args) == 3 and args[:2] == ["--no-wait", "describe"] and _PROJECT_ID.fullmatch(args[2]))):
            raise ValueError("not a projects helper")
    else:
        raise ValueError(f"not a helper: {kind}")
    return [str(lm), *cli_options, "--no-notify", kind, *args]


class FakeCalendar:
    """The calendar permission the app answers (its "calendar" call), kept in probe.json's
    ``permissions``: asking for it is a click on Allow."""

    def __init__(self, probe_file: Path):
        self.probe_file = probe_file
        self.asked = self.opened_settings = 0
        self.lock = threading.Lock()

    def _probe(self) -> dict:
        try:
            return json.loads(self.probe_file.read_text())
        except FileNotFoundError:
            return {}

    def status(self) -> dict:
        given = (self._probe().get("permissions") or {}).get("calendar")
        return dict(given) if given else {"state": "not_asked", "detail": "not connected"}

    def grant(self) -> None:  # as from the menu bar, or System Settings
        with self.lock:
            probe = self._probe()
            permissions = probe.get("permissions") or {
                "microphone": {"state": "granted", "detail": "allowed"},
                "system_audio": {"state": "unverified", "detail": "not verified yet"},
                "notifications": {"state": "unknown", "detail": "Palaver can't check this itself"},
            }
            permissions["calendar"] = {"state": "granted", "detail": "connected (read only)"}
            tmp = self.probe_file.with_suffix(".tmp")
            tmp.write_text(json.dumps({**probe, "permissions": permissions}))
            tmp.replace(self.probe_file)

    def connect(self) -> dict:
        """onboarding.Calendar.connect: not asked yet, macOS's dialog (answered Allow); refused,
        System Settings at Calendars (counted in ``opened_settings``, nothing opens)."""
        now = self.status()
        if now["state"] == "not_asked":
            self.asked += 1
            self.grant()
            return {**now, "asked": True}
        if now["state"] == "denied":
            self.opened_settings += 1
            return {**now, "opened_settings": True}
        return now


class FakeApp:
    """``recording`` (conftest's FakeRecording) behind ``socket`` and the daemon.json of
    ``home``; ``root``: the recordings; ``helper_env``: the environment of a language
    model's helper the app starts (palaver-lm, ``lm``); ``cli_options``: the app's options."""

    def __init__(self, *, home: Path, socket: Path, root: Path, recording, probe_file: Path,
                 helper_env: dict[str, str], cli_options: list[str], lm: Path):
        self.state_path = home / "Library" / "Application Support" / "palaver" / "daemon.json"
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        self.root = root
        self.recording = recording
        self.helper_env = helper_env
        self.lm = lm
        self.cli_options = list(cli_options)
        self.calendar = FakeCalendar(probe_file)
        self.recorder = FakeRecorder()  # the setup assistant's test recording: no microphone
        self.test_recording = TestRecording(capture=self.recorder.capture, analyze=self.recorder.analyze)
        self.watched: list[tuple[str, int]] = []  # helpers the server asked the watchdog to watch
        self.switched_off: list[str] = []
        self.helpers: list[list[str]] = []  # what the app started for the window
        self.update_actions: list[str] = []  # "check" / "install", as the server asked
        self.update_json = home / "Library" / "Application Support" / "palaver" / "update.json"
        self.since = datetime.now().astimezone().isoformat(timespec="seconds")  # idle since the start
        self._stop = threading.Event()
        self._state_lock = threading.Lock()
        self.write_state()
        self._writer = threading.Thread(target=self._tick, name="fake-daemon-json", daemon=True)
        self._writer.start()
        self.server = serve(socket, self.calls())

    def close(self) -> None:
        self._stop.set()
        self._writer.join(5)
        self.server.close()

    # --- daemon.json ------------------------------------------------------------------

    def state(self) -> dict:
        """daemon.json as the app writes it, from what the fake says now."""
        rec = self.recording
        status = {"state": "idle", "since": self.since, "pid": os.getpid(),
                  "updated": datetime.now().astimezone().isoformat(timespec="seconds"),
                  "stop_question": rec.question()}
        coach = rec.coach()
        if coach:
            status.update(folder=str(self.root / coach["meeting"]), talk=coach.get("talk"),
                          talk_text=coach.get("text"), nudge=coach.get("nudge"), quiet=coach.get("quiet") or [])
        recording = getattr(rec, "recording", None)
        view = recording() if callable(recording) else None
        if view:
            status.setdefault("folder", str(self.root / view["meeting"]))
            status.update(why_text=view.get("text"), warnings=view.get("warnings") or [],
                          hints=view.get("hints") or [])
        return status

    def write_state(self) -> None:
        with self._state_lock:  # never an older state over a newer one
            tmp = self.state_path.with_suffix(".tmp")
            tmp.write_text(json.dumps(self.state(), default=str))
            tmp.replace(self.state_path)

    def _tick(self) -> None:
        while not self._stop.wait(TICK_SECONDS):
            try:
                self.write_state()
            except Exception as exc:  # a test changing the fake meanwhile: the next tick writes it
                print(f"fake app: daemon.json not written: {exc}", file=sys.stderr)

    # --- app.sock ---------------------------------------------------------------------

    def _launch_helper(self, kind: str, key: str, args: list[str]) -> int:
        """As the app's HelperJobs: palaver-lm with the app's options (its model the test's)."""
        argv = helper_argv(self.lm, kind, args, self.cli_options, output_dir=self.root)  # ValueError: not one
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,80}", key) or key.startswith("."):
            raise ValueError(f"not a job: {kind} {key}")
        self.helpers.append(argv)
        job = jobs_root(self.root) / f"{kind}-{key}.json"
        try:
            running = json.loads(job.read_text())
            if running.get("state") == "running":
                os.kill(int(running["pid"]), 0)
                return int(running["pid"])  # never a second run
        except (OSError, ValueError, KeyError, TypeError):
            pass
        return launch_job(jobs_root(self.root), kind, key, argv, env=self.helper_env)

    def calls(self) -> dict:
        rec = self.recording

        def answer(args: dict) -> bool:
            done = bool(rec.answer(str(args.get("choice")), args.get("meeting")))
            self.write_state()  # as the app's refresh(): the page asks again right after
            return done

        def watch(args: dict) -> None:
            self.watched.append((str(args.get("folder")), int(args["pid"])))

        def switched_off(args: dict) -> None:
            self.switched_off.append(str(args.get("app")))
            self.write_state()

        def start_helper(args: dict) -> dict:
            try:
                pid = self._launch_helper(str(args.get("kind")), str(args.get("key")),
                                          [str(a) for a in args.get("args") or []])
            except ValueError as exc:
                raise CallRefused(str(exc)) from None
            return {"pid": pid}

        def transcribe(args: dict) -> bool:
            folder = Path(str(args.get("folder")))
            if not folder.is_dir():
                raise CallRefused(f"no recording at {folder}")
            queued = bool(rec.transcribe(folder))
            self.write_state()
            return queued

        def record(args: dict) -> dict:
            action = args.get("action")
            if action not in ("start", "stop"):
                raise CallRefused(f"no recording action {action!r}")
            answer = rec.record(action, args.get("meeting"))
            self.write_state()
            return answer

        def test(args: dict) -> dict:
            action = args.get("action")
            if action == "start":
                return self.test_recording.start(mode=args.get("mode") or {})
            if action == "stop":
                return self.test_recording.stop()
            return self.test_recording.status()

        def calendar(args: dict) -> dict:
            return self.calendar.connect() if args.get("action") == "connect" else self.calendar.status()

        def update(action: str):
            def call(args: dict) -> dict:
                """Recorded, nothing checked or installed; the answer is update.json as the updater keeps it."""
                self.update_actions.append(action)
                try:
                    return json.loads(self.update_json.read_text())
                except (OSError, ValueError):
                    return {"state": "unsupported"}
            return call

        def no_updates(args: dict):
            raise CallRefused("the e2e fake app installs nothing")

        return {
            "ping": lambda args: {"pid": os.getpid()},
            "answer": answer,
            "switched_off": switched_off,
            "watch": watch,
            "start_helper": start_helper,
            "transcribe": transcribe,
            "record": record,
            "test": test,
            "calendar": calendar,
            "update_check": update("check"),
            "update_install": update("install"),
            "uninstall": no_updates,
            "restart_web": no_updates,
        }
