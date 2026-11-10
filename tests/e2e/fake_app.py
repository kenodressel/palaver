"""The menu bar app as palaver-server sees it in the end-to-end tests: daemon.json in the
test's home, written several times a second from a ``FakeRecording`` (the question
whether to stop it, the live coach, why it records), and app.sock served by
``palaver.appctl.serve`` in the test's process, so the test changes the fake directly
and sees the calls the server made.

Nothing here talks to the real app: the socket and daemon.json are the test's.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
from datetime import datetime
from functools import partial
from pathlib import Path

from palaver import appctl, model_jobs
from palaver import onboarding as ob

TICK_SECONDS = 0.1  # the real app writes daemon.json every second; the tests wait less


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
        from tests.fake_probe import FakeRecorder

        self.state_path = home / "Library" / "Application Support" / "palaver" / "daemon.json"
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        self.root = root
        self.recording = recording
        self.helper_env = helper_env
        self.lm = lm
        self.cli_options = list(cli_options)
        self.calendar = FakeCalendar(probe_file)
        self.recorder = FakeRecorder()  # the setup assistant's test recording: no microphone
        self.test_recording = ob.TestRecording(capture=self.recorder.capture, analyze=self.recorder.analyze)
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
        self.server = appctl.serve(socket, self.calls())

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
        argv = model_jobs.helper_argv(kind, args, self.cli_options, output_dir=self.root)  # ValueError: not one
        at = argv.index(sys.executable)
        argv[at:at + 3] = [str(self.lm)]  # `python -m palaver` → palaver-lm
        self.helpers.append(argv)
        return model_jobs.launch(model_jobs.jobs_root(self.root), kind, key, argv,
                                 popen=partial(subprocess.Popen, env=self.helper_env))

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
                raise appctl.CallRefused(str(exc)) from None
            return {"pid": pid}

        def transcribe(args: dict) -> bool:
            folder = Path(str(args.get("folder")))
            if not folder.is_dir():
                raise appctl.CallRefused(f"no recording at {folder}")
            queued = bool(rec.transcribe(folder))
            self.write_state()
            return queued

        def record(args: dict) -> dict:
            action = args.get("action")
            if action not in ("start", "stop"):
                raise appctl.CallRefused(f"no recording action {action!r}")
            answer = rec.record(action, args.get("meeting"))
            self.write_state()
            return answer

        def test(args: dict) -> dict:
            action = args.get("action")
            try:
                if action == "start":
                    return self.test_recording.start(busy=False, mode=args.get("mode") or {})
            except ValueError as exc:
                raise appctl.CallRefused(str(exc)) from None
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
            raise appctl.CallRefused("the e2e fake app installs nothing")

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
