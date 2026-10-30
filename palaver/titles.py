"""A meeting's title, decided in one place: the one the user gave it
(title.json), else the one a colleague gave the meeting they sent
(imported.json, #58), else its calendar event's, else the one the notes
model wrote; without any, "Meeting at 12:04".

The user's title is a choice like a name given to a speaker: it wins over
what the calendar or the model say. It is a file of its own in the meeting
folder, written by nothing else, so a meeting can be renamed while it is
still being recorded.
"""

from __future__ import annotations

import json
import os
from datetime import datetime
from typing import Any

from . import calendar_events, glossary, notes
from .paths import RecordingPaths

MAX_LENGTH = 200
YOU, IMPORTED, CALENDAR, NOTES = "you", "imported", "calendar", "notes"

_UNREAD: Any = object()


def clean(title: Any) -> str:
    """A title as typed, on one line, at most ``MAX_LENGTH`` characters;
    "" says: no title of the user's own."""
    if not isinstance(title, str):
        raise ValueError("a title is text")
    return " ".join(title.split())[:MAX_LENGTH].rstrip()


def load(paths: RecordingPaths) -> str | None:
    """The user's own title, or None."""
    try:
        title = json.loads(paths.title.read_text()).get("title")
    except (OSError, ValueError, AttributeError):
        return None
    return (title.strip() or None) if isinstance(title, str) else None


def save(paths: RecordingPaths, title: str) -> None:
    """Keep the user's title; "" removes it."""
    if not title:
        paths.title.unlink(missing_ok=True)
        return
    tmp = paths.title.with_name(paths.title.name + ".tmp")
    tmp.write_text(json.dumps({"title": title}, ensure_ascii=False))
    os.replace(tmp, paths.title)


def imported(paths: RecordingPaths) -> str | None:
    """The title the sender of an imported meeting gave it, or None."""
    try:
        title = json.loads(paths.imported.read_text()).get("title")
    except (OSError, ValueError, AttributeError):
        return None
    return (clean(title) or None) if isinstance(title, str) else None


def resolve(paths: RecordingPaths, *, event: Any = _UNREAD, meeting_notes: Any = _UNREAD) -> tuple[str | None, str | None]:
    """The title and where it came from ("you", "imported", "calendar",
    "notes"), or (None, None). ``event`` and ``meeting_notes``: what the
    caller read already (None: there is none), so nothing is read twice."""
    own = load(paths)
    if own:
        return own, YOU
    theirs = imported(paths)
    if theirs:
        return theirs, IMPORTED
    if event is _UNREAD:
        event = calendar_events.load(paths)
    if event is not None and event.title:
        return event.title, CALENDAR
    if meeting_notes is _UNREAD:
        meeting_notes = notes.load(paths)
    written = glossary.current().apply((meeting_notes or {}).get("title") or "")
    return (written, NOTES) if written else (None, None)


def fallback(start: str | None) -> str:
    """What a meeting without any title is called: "Meeting at 12:04"."""
    try:
        return f"Meeting at {datetime.fromisoformat(start).astimezone():%H:%M}" if start else "Meeting"
    except ValueError:
        return "Meeting"
