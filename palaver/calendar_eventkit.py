"""Events from the macOS calendar (EventKit): every account added to the
Calendar app, e.g. Microsoft Exchange. Read-only, on this Mac.

Access needs the user's consent once (``request_access``, from the menu bar
app, whose Info.plist carries the reason shown in the dialog). Processing
runs as the app's helper process and inherits that consent.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Callable

from .calendar_events import Attendee, Event, looks_like_room, person_name

_STATUS_FULL_ACCESS = 3  # EKAuthorizationStatusFullAccess (= Authorized before macOS 14)
_RESPONSE = {2: "accepted", 3: "declined", 4: "tentative"}  # EKParticipantStatus
_ROOM_TYPES = {2, 3}  # EKParticipantTypeRoom, EKParticipantTypeResource


def has_access() -> bool:
    import EventKit

    return EventKit.EKEventStore.authorizationStatusForEntityType_(EventKit.EKEntityTypeEvent) == _STATUS_FULL_ACCESS


def request_access(done: Callable[[bool], None]) -> None:
    """Ask once for read access; ``done(granted)`` is called on another thread."""
    import EventKit

    store = EventKit.EKEventStore.alloc().init()
    if hasattr(store, "requestFullAccessToEventsWithCompletion_"):
        store.requestFullAccessToEventsWithCompletion_(lambda granted, _error: done(bool(granted)))
    else:  # macOS 13
        store.requestAccessToEntityType_completion_(
            EventKit.EKEntityTypeEvent, lambda granted, _error: done(bool(granted)))


def _datetime(nsdate) -> datetime:
    return datetime.fromtimestamp(nsdate.timeIntervalSince1970(), tz=timezone.utc).astimezone()


def _email(participant) -> str | None:
    url = participant.URL()
    text = str(url.absoluteString()) if url is not None else ""
    return text[len("mailto:"):].lower() if text.lower().startswith("mailto:") else None


def to_attendee(participant, organizer_email: str | None = None) -> Attendee:
    email = _email(participant)
    raw = str(participant.name() or email or "Unknown")
    return Attendee(
        name=person_name(raw),
        email=email,
        organizer=email is not None and email == organizer_email,
        response=_RESPONSE.get(int(participant.participantStatus()), "unknown"),
        is_self=bool(participant.isCurrentUser()),
        is_room=int(participant.participantType()) in _ROOM_TYPES or looks_like_room(raw),
    )


def to_event(ek) -> Event:
    organizer = ek.organizer()
    organizer_email = _email(organizer) if organizer is not None else None
    attendees = [to_attendee(p, organizer_email) for p in (ek.attendees() or [])]
    if organizer is not None and organizer_email not in {a.email for a in attendees}:
        attendees.insert(0, to_attendee(organizer, organizer_email))
    return Event(
        title=str(ek.title() or ""),
        start=_datetime(ek.startDate()),
        end=_datetime(ek.endDate()),
        attendees=tuple(attendees),
        all_day=bool(ek.isAllDay()),
        source="macos-calendar",
        uid=_uid(ek),
        series=bool(getattr(ek, "hasRecurrenceRules", lambda: False)()),
        location=str(getattr(ek, "location", lambda: "")() or ""),
    )


def _uid(ek) -> str:
    """The id Exchange gives the event (the same on this Mac and elsewhere,
    and on every occurrence of a series); else this calendar's own."""
    for name in ("calendarItemExternalIdentifier", "eventIdentifier"):
        value = getattr(ek, name, None)
        if callable(value) and value():
            return str(value())
    return ""


def events_between(start: datetime, end: datetime) -> list[Event]:
    import EventKit
    from Foundation import NSDate

    store = EventKit.EKEventStore.alloc().init()
    predicate = store.predicateForEventsWithStartDate_endDate_calendars_(
        NSDate.dateWithTimeIntervalSince1970_(start.timestamp()),
        NSDate.dateWithTimeIntervalSince1970_(end.timestamp()),
        None,
    )
    return [to_event(ek) for ek in store.eventsMatchingPredicate_(predicate) or []]
