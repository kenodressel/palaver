"""The calendar event a recording belongs to (issue #27).

A recording knows only when it started and ended; the calendar knows the
meeting's title and who was invited. ``attach`` finds the event that
overlaps the recording most and stores it as ``calendar.json``, with how it
was linked (attribution.py): "time match", or "time match, 2 events
overlapped" and unsure. When two events with people invited overlap the
recording about as much, it does not guess: it stores the question, and the
window asks which one it was. A link the user set is never replaced. Invitees
then come first among the names suggested for speakers, and voice
recognition among them may be less strict: if five people were invited,
the voice is almost certainly one of those five.

Events come from a provider: any ``(start, end) -> list[Event]``. The
macOS calendar (EventKit) is in calendar_eventkit.py.
"""

from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass, field, replace
from datetime import datetime, timedelta
from pathlib import Path
from typing import Callable

from .attribution import Evidence, Link
from .paths import RecordingPaths, is_recording_folder_name

# How far around the recording to look for its event: calls start early or late.
SEARCH_MARGIN = timedelta(minutes=45)
# Overlap needed, as a share of the shorter of recording and event.
MIN_OVERLAP_SHARE = 0.3
# A rival overlapping at least this share of the best one's overlap makes it
# a question, unless only one of the two has people invited.
AMBIGUOUS_SHARE = 0.7
# How sure a time match is: the only event in the slot, one of several, and
# how much a rejection of the event (in another recording) takes off.
TIME_MATCH = 0.9
TIME_MATCH_OVERLAPPED = 0.6
TIME_MATCH_NO_RIVAL = 0.8  # the other events have no invitees: blockers, focus time
REJECTED_ONCE = 0.6


@dataclass(frozen=True)
class Attendee:
    name: str
    email: str | None = None
    organizer: bool = False
    response: str = "unknown"  # accepted | tentative | declined | unknown
    is_self: bool = False
    is_room: bool = False


@dataclass(frozen=True)
class Event:
    title: str
    start: datetime
    end: datetime
    attendees: tuple[Attendee, ...] = field(default_factory=tuple)
    all_day: bool = False
    source: str = ""
    uid: str = ""     # the calendar's id for the event, the same on every occurrence
    series: bool = False  # a recurring event
    location: str = ""  # where it is held: a meeting room, a Teams link

    @property
    def series_id(self) -> str:
        """The id every occurrence of a recurring event shares; a changed
        occurrence's own id is "<series id>/RID=<when>"."""
        return self.uid.split("/RID=")[0]

    @property
    def key(self) -> str:
        """This occurrence: the id and the day."""
        return f"{self.uid}|{self.start.date().isoformat()}" if self.uid else ""

    def to_dict(self) -> dict:
        d = asdict(self)
        d["start"], d["end"] = self.start.isoformat(), self.end.isoformat()
        return d

    @classmethod
    def from_dict(cls, d: dict) -> "Event":
        return cls(
            title=d["title"],
            start=datetime.fromisoformat(d["start"]),
            end=datetime.fromisoformat(d["end"]),
            attendees=tuple(_tidy(Attendee(**a)) for a in d.get("attendees", [])),
            all_day=bool(d.get("all_day", False)),
            source=d.get("source", ""),
            uid=d.get("uid", ""),
            series=bool(d.get("series", False)),
            location=str(d.get("location") or ""),
        )


Provider = Callable[[datetime, datetime], list[Event]]

_ROOM = re.compile(r"(room|raum)\b", re.IGNORECASE)  # Meetingroom, Conference Room, Besprechungsraum
_EXTERNAL = re.compile(r"\s+(ext\.?|extern)$", re.IGNORECASE)


def person_name(raw: str) -> str:
    """A directory name as people say it: "Kralek, Karel (Contoso Services)"
    → "Karel Kralek", "GARCIA LOPEZ, JOSE MIGUEL EXT." → "Jose Miguel Garcia Lopez"."""
    name = re.sub(r"\s*\([^)]*\)\s*$", "", raw.strip())
    if name.count(",") == 1:
        last, first = (part.strip() for part in name.split(","))
        name = f"{_EXTERNAL.sub('', first)} {last}".strip()
    name = _EXTERNAL.sub("", name)
    if name.isupper():
        name = name.title()
    return name or raw.strip()


def looks_like_room(name: str) -> bool:
    """Exchange often lists rooms as people: "16 - Attakring | Conferenceroom"."""
    return bool(_ROOM.search(name))


def _tidy(a: Attendee) -> Attendee:
    """Calendars stored before names were cleaned up."""
    return Attendee(person_name(a.name), a.email, a.organizer, a.response, a.is_self,
                    a.is_room or looks_like_room(a.name))


def _overlap(event: Event, start: datetime, end: datetime) -> float:
    return max(0.0, (min(event.end, end) - max(event.start, start)).total_seconds())


def _fitting(events: list[Event], start: datetime, end: datetime) -> list[Event]:
    """Events overlapping the recording enough, best first: most overlap;
    among equals, one with people invited, then the closest start."""
    out = []
    for event in events:
        if event.all_day:
            continue
        overlap = _overlap(event, start, end)
        shorter = min((end - start).total_seconds(), (event.end - event.start).total_seconds())
        if overlap <= 0 or overlap < MIN_OVERLAP_SHARE * shorter:
            continue
        out.append(event)
    return sorted(out, key=lambda e: (_overlap(e, start, end), bool(e.attendees),
                                      -abs((e.start - start).total_seconds())), reverse=True)


def match(events: list[Event], start: datetime, end: datetime) -> Event | None:
    """The event the recording ``start``..``end`` overlaps most, if any."""
    found = _fitting(events, start, end)
    return found[0] if found else None


def _invites(event: Event) -> bool:
    """Someone besides the user is invited: a meeting, not a blocker."""
    return any(not a.is_self and not a.is_room for a in event.attendees)


@dataclass(frozen=True)
class Decision:
    """What the calendar says about a recording: an event and how it was
    linked, or a question (the events it might be), or neither."""
    event: Event | None = None
    link: Link | None = None
    question: list[Event] | None = None


def decide(events: list[Event], start: datetime, end: datetime, *, evidence: Evidence | None = None) -> Decision:
    """Which event the recording ``start``..``end`` was, how sure that is, and
    why. Events overlapping it about as much make a question, unless only one
    of them has people invited (the others are blockers). ``evidence``: what
    the user's corrections taught: an event series said no to often is not
    linked by time at all; one said no to once comes after any other, unsure."""
    found = _fitting(events, start, end)
    rejections = {id(e): evidence.doubted(e) if evidence is not None else 0 for e in found}
    if evidence is not None:
        found = [e for e in found if not evidence.never_by_time(e)]
        found.sort(key=lambda e: rejections[id(e)] > 0)  # stable: by overlap otherwise
    if not found:
        return Decision()
    best = found[0]
    close = [best] + [e for e in found[1:] if not rejections[id(e)]
                      and _overlap(e, start, end) >= AMBIGUOUS_SHARE * _overlap(best, start, end)]
    if len(close) > 1:
        invited = [e for e in close if _invites(e)]
        if len(invited) != 1:
            return Decision(question=sorted(close, key=lambda e: (e.start, e.title)))
        best = invited[0]
    rivals = [e for e in found if e is not best]
    if not rivals:
        confidence, reason = TIME_MATCH, "time match"
    elif any(_invites(e) for e in rivals) or not _invites(best):
        confidence, reason = TIME_MATCH_OVERLAPPED, f"time match, {len(found)} events overlapped"
    else:
        confidence = TIME_MATCH_NO_RIVAL
        others = "the others have" if len(rivals) > 1 else "the other has"
        reason = f"time match, {len(found)} events overlapped; {others} no invitees"
    if rejections[id(best)]:
        confidence *= REJECTED_ONCE
        n = rejections[id(best)]
        reason += "; you said a recording was not this event " + ("once" if n == 1 else f"{n} times")
    return Decision(best, Link("event", best.title, "calendar", round(confidence, 2), reason))


def event_key_at(events: list[Event], when: datetime) -> str | None:
    """The event on at ``when`` (as ``match`` picks it), by its key."""
    event = match(events, when, when + timedelta(seconds=1))
    if event is None:
        return None
    return event.key or f"{event.title}|{event.start.isoformat()}"


def candidates(event: Event, *, user_name: str) -> list[Attendee]:
    """Invitees who may have spoken on the other side: not the user, not a
    room, not someone who declined."""
    user = user_name.casefold()
    out, seen = [], set()
    for a in event.attendees:
        key = a.name.casefold()
        if (a.is_self or a.is_room or a.response == "declined" or key in seen
                or key == user or a.name.split()[0].casefold() == user):
            continue
        seen.add(key)
        out.append(a)
    return out


def resolve(invitee: str, known: list[str]) -> str | None:
    """The name already used for ``invitee`` ("Freddy" for "Freddy Schmidt"),
    or None. First names count only when unambiguous."""
    folded = invitee.casefold()
    for name in known:
        if name.casefold() == folded:
            return name
    first = invitee.split()[0].casefold() if invitee.split() else ""
    hits = [name for name in known if name.casefold() == first]
    return hits[0] if len(hits) == 1 else None


def invited_names(paths: RecordingPaths, known: list[str], *, user_name: str = "") -> list[str] | None:
    """The invitees of the recording's event, as ``known`` names where they
    resolve; None when the recording has no event."""
    event = load(paths)
    if event is None:
        return None
    return [resolve(a.name, known) or a.name for a in candidates(event, user_name=user_name)]


def _stored(paths: RecordingPaths) -> dict:
    try:
        d = json.loads(paths.calendar.read_text())
    except (OSError, ValueError):
        return {}
    return d if isinstance(d, dict) else {}


def load(paths: RecordingPaths) -> Event | None:
    try:
        return Event.from_dict(json.loads(paths.calendar.read_text()))
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None


def load_link(paths: RecordingPaths) -> Link | None:
    """How the stored event was linked; an unknown source for files stored
    before links had one. None without an event."""
    event = load(paths)
    return Link.from_dict("event", event.title, _stored(paths).get("link")) if event else None


def load_question(paths: RecordingPaths) -> list[Event] | None:
    """The events the recording might be, while the user has not said which."""
    question = _stored(paths).get("question")
    if not isinstance(question, list):
        return None
    try:
        return [Event.from_dict(d) for d in question]
    except (KeyError, TypeError, ValueError, AttributeError):
        return None


def save(paths: RecordingPaths, event: Event, link: Link | None = None) -> None:
    d = event.to_dict()
    if link is not None:
        d["link"] = link.stored()
    paths.calendar.write_text(json.dumps(d, indent=2, ensure_ascii=False))


def ask(paths: RecordingPaths, events: list[Event]) -> None:
    """Several events fit the recording: store them as a question, no event."""
    d = {"question": [e.to_dict() for e in sorted(events, key=lambda e: (e.start, e.title))]}
    if _stored(paths) != json.loads(json.dumps(d)):  # unchanged: the file (and its time) stays
        paths.calendar.write_text(json.dumps(d, indent=2, ensure_ascii=False))


def dismiss(paths: RecordingPaths) -> None:
    """The matched event is not this meeting (an ad-hoc call in its slot):
    forget it, and don't match one again."""
    paths.calendar.write_text(json.dumps({"none": True, "link": {"source": "you"}}))


def dismissed(paths: RecordingPaths) -> bool:
    return _stored(paths).get("none") is True


def assign(paths: RecordingPaths, event: Event, link: Link | None = None) -> None:
    """Store ``event`` as the recording's, with how it was linked, what
    was prepared for it, and whether its series shares one microphone."""
    save(paths, event, link)
    from . import prep, shared_mic

    prep.apply(paths, event)  # what was prepared for this event before it happened
    shared_mic.apply_series(paths, event)  # an All Hands remembered for its series (#56)


def attach(paths: RecordingPaths, provider: Provider, start: datetime, end: datetime, *,
           evidence: Evidence | None = None) -> Event | None:
    """Find and store the recording's event, or the question which one it
    was. A calendar decision already made stays: an event the user chose,
    "none of these", and any stored event (an event stored before events had
    an id only gets its id, when the calendar has the same occurrence; its
    invitees stay). Only a recording without a decision may get a question."""
    if dismissed(paths):
        return None
    events = provider(start - SEARCH_MARGIN, end + SEARCH_MARGIN)
    stored = load(paths)
    if stored is not None:
        if not stored.uid:
            same = [e for e in events if e.uid and e.title == stored.title and e.start == stored.start]
            if same:
                found = same[0]
                if stored.attendees and not found.attendees:
                    found = replace(found, attendees=stored.attendees)
                save(paths, found, load_link(paths))
                return found
        return stored
    decision = decide(events, start, end,
                      evidence=evidence if evidence is not None else Evidence(output_dir=paths.folder.parent))
    if decision.question:
        ask(paths, decision.question)
    elif decision.event is not None:
        assign(paths, decision.event, decision.link)
    return decision.event


def recording_span(paths: RecordingPaths) -> tuple[datetime, datetime]:
    """When the recording started and ended, from its meta.json."""
    meta = json.loads(paths.meta.read_text())
    start = datetime.fromisoformat(meta["start_time"])
    end = datetime.fromisoformat(meta["end_time"]) if meta.get("end_time") else (
        start + timedelta(seconds=float(meta["duration_seconds"])))
    return start, end


def attach_all(output_dir: Path, provider: Provider, since: datetime | None = None) -> int:
    """Look up the event of every finished recording (started after
    ``since``) that has none stored yet, e.g. those made before the calendar
    was connected, or one without an id. Returns how many found one."""
    found = 0
    if not output_dir.is_dir():
        return 0
    evidence = Evidence(output_dir=output_dir)
    for folder in sorted(output_dir.iterdir()):
        paths = RecordingPaths(folder)
        stored = load(paths)
        # Look again for events stored before they had an id (series, prep);
        # an open question too: the calendar may have changed since.
        if not is_recording_folder_name(folder.name) or (stored is not None and stored.uid) or dismissed(paths):
            continue
        try:
            start, end = recording_span(paths)
        except (OSError, ValueError, KeyError, TypeError):
            continue  # still recording, or not a recording
        if since is not None and start < since:
            continue
        if attach(paths, provider, start, end, evidence=evidence) is not None:
            found += 1
    return found
