"""macOS notifications on pipeline events (issue #10).

Inside Palaver.app the launcher posts them as the app ($PALAVER_NOTIFY), so
a click opens the meeting in Palaver. Elsewhere (run from a terminal) they
go through ``osascript`` — no app bundle or consent needed, but macOS shows
them as Script Editor's. Title and message are passed as script arguments,
never spliced into the script, so quotes in error messages cannot break it.
Failures to notify are ignored.
"""

from __future__ import annotations

import json
import logging
import os
import socket
import subprocess
import threading
from typing import Callable

LOGGER = logging.getLogger(__name__)

_SCRIPT = [
    "-e", "on run argv",
    "-e", "display notification (item 2 of argv) with title (item 1 of argv)",
    "-e", "end run",
]
_MAX_MESSAGE = 200

_enabled = True


def set_enabled(enabled: bool) -> None:
    global _enabled
    _enabled = enabled


def notify(title: str, message: str, meeting: str | None = None) -> None:
    """``meeting``: the recording a click on the notification opens."""
    if not _enabled:
        return
    try:
        _send(title, message[:_MAX_MESSAGE], meeting)
    except Exception:
        LOGGER.debug("notification failed", exc_info=True)


SETTINGS_URL = "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.kenodressel.meeting-transcribe"


def permission() -> str | None:
    """Whether macOS lets Palaver notify: "allowed", "denied" or "not_asked",
    as the app's launcher last asked ($PALAVER_NOTIFY_STATE); None outside
    the app, or before it knows."""
    path = os.environ.get("PALAVER_NOTIFY_STATE")
    try:
        state = open(path).read().strip() if path else None
    except OSError:
        return None
    return state if state in ("allowed", "denied", "not_asked") else None


def _send_via_app(title: str, message: str, meeting: str | None) -> bool:
    path = os.environ.get("PALAVER_NOTIFY")
    if not path:
        return False
    request = json.dumps({"title": title, "message": message, "open": meeting or ""})
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
        try:
            sock.sendto(request.encode(), path)
        except OSError:  # the app is gone
            return False
    return True


def _send_via_osascript(title: str, message: str) -> None:
    subprocess.run(
        ["osascript", *_SCRIPT, title, message],
        check=False,
        capture_output=True,
        timeout=5,
    )


def _send_default(title: str, message: str, meeting: str | None = None) -> None:
    if not _send_via_app(title, message, meeting):
        _send_via_osascript(title, message)


_send = _send_default


def on_click(callback: Callable[[str | None], None]) -> bool:
    """Call ``callback(meeting)`` (None: no particular one) for each click on
    a notification, from a background thread. False outside Palaver.app."""
    fd = os.environ.pop("PALAVER_LAUNCHER_FD", None)
    if fd is None:
        return False
    try:
        sock = socket.socket(fileno=int(fd))
    except (OSError, ValueError):
        return False

    def listen() -> None:
        while data := sock.recv(4096):
            command, _, meeting = data.decode(errors="replace").partition(" ")
            if command == "open":
                try:
                    callback(meeting.strip() or None)
                except Exception:
                    LOGGER.exception("opening a clicked notification failed")

    threading.Thread(target=listen, name="notification-clicks", daemon=True).start()
    return True
