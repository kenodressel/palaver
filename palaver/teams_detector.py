"""Is Microsoft Teams — or Slack — in a call? (issues #9, #39)

Answered from CoreAudio's per-process audio objects (macOS 14.4+): a Teams
process (bundle ID ``com.microsoft.teams*``) with its microphone input
running means a call — Teams keeps the input running while muted, so muting
does not end the session. Slack (``com.tinyspeck.slackmacgap*``, huddles)
starts a call the same way; since it may close the microphone while muted,
a huddle goes on as long as Slack still plays sound. Sound alone (a
notification) starts nothing. Read-only property queries; nothing is
captured.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import logging
from dataclasses import dataclass
from typing import Callable

LOGGER = logging.getLogger(__name__)

_SYSTEM_OBJECT = 1  # kAudioObjectSystemObject
_GLOBAL_SCOPE = 0x676C6F62  # 'glob'
_MAIN_ELEMENT = 0
_PROCESS_OBJECT_LIST = 0x70727323  # 'prs#'
_PROCESS_BUNDLE_ID = 0x70626964  # 'pbid'
_PROCESS_PID = 0x70706964  # 'ppid'
_PROCESS_RUNNING_INPUT = 0x70697269  # 'piri'
_PROCESS_RUNNING_OUTPUT = 0x7069726F  # 'piro'

TEAMS_BUNDLE_PREFIXES = ("com.microsoft.teams",)
SLACK_BUNDLE_PREFIXES = ("com.tinyspeck.slackmacgap",)


class _Address(ctypes.Structure):
    _fields_ = [
        ("mSelector", ctypes.c_uint32),
        ("mScope", ctypes.c_uint32),
        ("mElement", ctypes.c_uint32),
    ]


@dataclass(frozen=True)
class AudioProcess:
    pid: int
    bundle_id: str
    running_input: bool
    running_output: bool


class _CoreAudio:
    def __init__(self):
        self._ca = ctypes.CDLL(ctypes.util.find_library("CoreAudio"))
        self._cf = ctypes.CDLL(ctypes.util.find_library("CoreFoundation"))
        self._ca.AudioObjectGetPropertyDataSize.argtypes = [
            ctypes.c_uint32, ctypes.POINTER(_Address), ctypes.c_uint32,
            ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32),
        ]
        self._ca.AudioObjectGetPropertyData.argtypes = [
            ctypes.c_uint32, ctypes.POINTER(_Address), ctypes.c_uint32,
            ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32), ctypes.c_void_p,
        ]
        self._cf.CFStringGetCString.argtypes = [
            ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32,
        ]
        self._cf.CFStringGetCString.restype = ctypes.c_bool
        self._cf.CFRelease.argtypes = [ctypes.c_void_p]

    def _get(self, obj: int, selector: int, out, size: int) -> bool:
        address = _Address(selector, _GLOBAL_SCOPE, _MAIN_ELEMENT)
        io_size = ctypes.c_uint32(size)
        status = self._ca.AudioObjectGetPropertyData(
            obj, ctypes.byref(address), 0, None, ctypes.byref(io_size), ctypes.byref(out)
        )
        return status == 0

    def process_objects(self) -> list[int]:
        address = _Address(_PROCESS_OBJECT_LIST, _GLOBAL_SCOPE, _MAIN_ELEMENT)
        size = ctypes.c_uint32(0)
        if self._ca.AudioObjectGetPropertyDataSize(
            _SYSTEM_OBJECT, ctypes.byref(address), 0, None, ctypes.byref(size)
        ):
            return []
        ids = (ctypes.c_uint32 * (size.value // 4))()
        if not self._get(_SYSTEM_OBJECT, _PROCESS_OBJECT_LIST, ids, size.value):
            return []
        return list(ids)

    def _uint32(self, obj: int, selector: int) -> int | None:
        value = ctypes.c_uint32(0)
        return value.value if self._get(obj, selector, value, 4) else None

    def _int32(self, obj: int, selector: int) -> int | None:
        value = ctypes.c_int32(0)
        return value.value if self._get(obj, selector, value, 4) else None

    def _string(self, obj: int, selector: int) -> str:
        ref = ctypes.c_void_p(0)
        if not self._get(obj, selector, ref, ctypes.sizeof(ref)) or not ref.value:
            return ""
        try:
            buf = ctypes.create_string_buffer(1024)
            ok = self._cf.CFStringGetCString(ref.value, buf, len(buf), 0x08000100)  # UTF-8
            return buf.value.decode("utf-8") if ok else ""
        finally:
            self._cf.CFRelease(ref.value)

    def processes(self) -> list[AudioProcess]:
        out = []
        for obj in self.process_objects():
            out.append(
                AudioProcess(
                    pid=self._int32(obj, _PROCESS_PID) or 0,
                    bundle_id=self._string(obj, _PROCESS_BUNDLE_ID),
                    running_input=bool(self._uint32(obj, _PROCESS_RUNNING_INPUT)),
                    running_output=bool(self._uint32(obj, _PROCESS_RUNNING_OUTPUT)),
                )
            )
        return out


def audio_processes() -> list[AudioProcess]:
    return _CoreAudio().processes()


def teams_mic_active(
    list_processes: Callable[[], list[AudioProcess]] = audio_processes,
) -> bool:
    """True while a Teams process has microphone input running."""
    return any(
        p.running_input and p.bundle_id.lower().startswith(TEAMS_BUNDLE_PREFIXES)
        for p in list_processes()
    )


def _app(process: AudioProcess, prefixes: tuple[str, ...]) -> bool:
    return process.bundle_id.lower().startswith(prefixes)


class CallDetector:
    """Which app is in a call right now: "teams", "slack" or None."""

    def __init__(self, list_processes: Callable[[], list[AudioProcess]] = audio_processes, *,
                 teams: Callable[[], bool] = lambda: True, slack: Callable[[], bool] = lambda: True):
        self._list = list_processes
        self._teams = teams  # asked on every check: a switch applies at once
        self._slack = slack
        self._in_huddle = False
        self._audio: str | None = None

    def __call__(self) -> str | None:
        processes = self._list()
        self._log_changes(processes)
        if self._teams() and any(p.running_input and _app(p, TEAMS_BUNDLE_PREFIXES) for p in processes):
            return "teams"
        if not self._slack():
            return None
        slack = [p for p in processes if _app(p, SLACK_BUNDLE_PREFIXES)]
        if any(p.running_input for p in slack):
            self._in_huddle = True
            return "slack"
        if self._in_huddle and any(p.running_output for p in slack):
            return "slack"  # muted: the others still play
        self._in_huddle = False
        return None

    def _log_changes(self, processes: list[AudioProcess]) -> None:
        """Each change in what the call apps' processes play or record: when
        Teams let go of the mic after a hang-up is otherwise nowhere."""
        audio = ", ".join(sorted(
            f"{p.bundle_id} " + "+".join(n for n, on in (("mic", p.running_input), ("speaker", p.running_output)) if on)
            for p in processes
            if (_app(p, TEAMS_BUNDLE_PREFIXES) or _app(p, SLACK_BUNDLE_PREFIXES)) and (p.running_input or p.running_output)
        )) or "none"
        if audio != self._audio:
            LOGGER.info("call apps' audio: %s", audio)
            self._audio = audio
