"""A Mac for the setup assistant's tests: what it detects is given, its
downloads and its test recording are fakes. Nothing here looks at the
real Mac, downloads a model, opens the microphone or plays a sound."""

from __future__ import annotations

import threading
from pathlib import Path

from palaver import onboarding as ob


class FakeRecorder:
    """The test recording's capture: no microphone, no audio files. The
    result is what ``analyze`` answers."""

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


class FakeCalendar(ob.Calendar):
    """The fake Mac's calendar permission: asking for it is a click on Allow."""

    def __init__(self, permissions: dict):
        self._permissions = permissions
        self.asked = self.opened_settings = 0
        super().__init__(ask=self._allow, open_settings=self._open)

    def status(self) -> dict:
        return dict(self._permissions["calendar"])

    def grant(self) -> None:  # as from the menu bar, or System Settings
        self._permissions["calendar"] = {"state": "granted", "detail": "connected (read only)"}

    def _allow(self) -> None:
        self.asked += 1
        self.grant()

    def _open(self) -> None:
        self.opened_settings += 1


class FakeProbe:
    def __init__(self, hardware: ob.Hardware | None = None, installed: ob.Installed | None = None,
                 downloaded: frozenset[str] = frozenset(), permissions: dict | None = None,
                 full_name: str = "Timo Strauss"):
        self._hardware = hardware or ob.Hardware("Apple M4 Pro", 48, 120)
        self._installed = installed or ob.Installed(teams=True, slack=False, claude_code=True)
        self._downloaded = set(downloaded)
        self._permissions = permissions or {
            "microphone": {"state": "granted", "detail": "allowed"},
            "system_audio": {"state": "unverified", "detail": "not verified yet"},
            "calendar": {"state": "not_asked", "detail": "not connected"},
            "notifications": {"state": "unknown", "detail": "Palaver can't check this itself"},
        }
        self._name = full_name
        self.autostart_on = False
        self.fetched: list[str] = []
        self.fail_once: set[str] = set()  # these fail on their first try
        self.fetch_gate = threading.Event()
        self.fetch_gate.set()
        self.recorder = FakeRecorder()
        self.downloads = ob.Downloads(fetch=self._fetch, progress=lambda repo: 0, done=lambda m: True)
        self.test = ob.TestRecording(capture=self.recorder.capture, analyze=self.recorder.analyze)
        self.calendar = FakeCalendar(self._permissions)
        self.hardware_calls = 0
        self.cfg = None

    def _fetch(self, model: ob.Model) -> None:
        self.fetch_gate.wait(10)
        self.fetched.append(model.id)
        if model.id in self.fail_once:
            self.fail_once.discard(model.id)
            raise RuntimeError("connection reset")
        self._downloaded.add(model.id)

    def hardware(self) -> ob.Hardware:
        self.hardware_calls += 1
        return self._hardware

    def installed(self) -> ob.Installed:
        return self._installed

    def permissions(self, output_dir: Path) -> dict:
        return self._permissions

    def downloaded(self) -> frozenset[str]:
        return frozenset(self._downloaded)

    def full_name(self) -> str:
        return self._name

    def repo_of(self, m: ob.Model) -> str:
        return m.repo

    def autostart(self) -> bool:
        return self.autostart_on

    def set_autostart(self, on: bool) -> None:
        self.autostart_on = on
