"""Tests for matching recordings to calendar events (issue #27)."""

import json
from datetime import datetime, timedelta
from pathlib import Path

from palaver import calendar_events as cal
from palaver.paths import RecordingPaths

T0 = datetime.fromisoformat("2026-10-27T15:00:00+01:00")


def _event(title, start_min, end_min, *names, **kw):
    attendees = tuple(cal.Attendee(n, f"{n.split()[0].lower()}@x.com") for n in names)
    return cal.Event(title, T0 + timedelta(minutes=start_min), T0 + timedelta(minutes=end_min),
                     attendees, **kw)


def test_the_event_overlapping_the_recording_most_wins():
    events = [
        _event("Standup", -30, 0, "Anna"),
        _event("Receipt case study", 0, 60, "Anna", "Bob"),
        _event("Focus time", 30, 120),  # no attendees, overlaps less
        _event("Holiday", -600, 1000, all_day=True),
    ]
    rec_start, rec_end = T0 + timedelta(minutes=1), T0 + timedelta(minutes=59)
    assert cal.match(events, rec_start, rec_end).title == "Receipt case study"


def test_no_event_when_the_overlap_is_marginal():
    events = [_event("Before", -60, 2, "Anna")]
    assert cal.match(events, T0, T0 + timedelta(minutes=30)) is None


def test_a_call_that_runs_long_still_matches():
    events = [_event("Sync", 0, 30, "Anna")]
    assert cal.match(events, T0 + timedelta(minutes=2), T0 + timedelta(minutes=55)).title == "Sync"


def test_candidates_leave_out_the_user_rooms_and_declines():
    event = cal.Event("Sync", T0, T0 + timedelta(minutes=30), (
        cal.Attendee("Timo Strauss", "timo@x.com", is_self=True),
        cal.Attendee("Anna Huber", "anna@x.com", organizer=True),
        cal.Attendee("Bob Weiss", "bob@x.com", response="declined"),
        cal.Attendee("Room Wien 3", "room@x.com", is_room=True),
        cal.Attendee("Carl Berg", "carl@x.com", response="tentative"),
    ))
    assert [a.name for a in cal.candidates(event, user_name="Timo")] == ["Anna Huber", "Carl Berg"]


def test_invitees_resolve_to_names_already_in_use():
    known = ["Freddy", "Anna Huber", "Martin", "Martina Klein"]
    assert cal.resolve("Anna Huber", known) == "Anna Huber"
    assert cal.resolve("anna huber", known) == "Anna Huber"
    assert cal.resolve("Freddy Schmidt", known) == "Freddy"  # first name, unambiguous
    assert cal.resolve("Martin Wolf", known) == "Martin"
    assert cal.resolve("Zoe Ray", known) is None


def test_attach_stores_the_matched_event(tmp_path: Path):
    paths = RecordingPaths(tmp_path)
    seen = []

    def provider(start, end):
        seen.append((start, end))
        return [_event("Receipt case study", 0, 60, "Anna Huber")]

    event = cal.attach(paths, provider, T0, T0 + timedelta(minutes=58))
    assert event.title == "Receipt case study"
    assert seen[0][0] < T0 and seen[0][1] > T0 + timedelta(minutes=58)  # searched around it
    loaded = cal.load(paths)
    assert loaded == event and loaded.attendees[0].email == "anna@x.com"


def test_attach_without_a_match_leaves_nothing(tmp_path: Path):
    paths = RecordingPaths(tmp_path)
    assert cal.attach(paths, lambda s, e: [], T0, T0 + timedelta(minutes=30)) is None
    assert cal.load(paths) is None


class _URL:
    def __init__(self, s):
        self.s = s

    def absoluteString(self):
        return self.s


class _Participant:
    def __init__(self, name, email, status=0, kind=1, me=False):
        self._n, self._e, self._s, self._k, self._me = name, email, status, kind, me

    def name(self): return self._n
    def URL(self): return _URL(f"mailto:{self._e}") if self._e else None
    def participantStatus(self): return self._s
    def participantType(self): return self._k
    def isCurrentUser(self): return self._me


class _Date:
    def __init__(self, dt):
        self.dt = dt

    def timeIntervalSince1970(self):
        return self.dt.timestamp()


class _EKEvent:
    def __init__(self, title, attendees, organizer):
        self._t, self._a, self._o = title, attendees, organizer

    def title(self): return self._t
    def startDate(self): return _Date(T0)
    def endDate(self): return _Date(T0 + timedelta(minutes=30))
    def isAllDay(self): return False
    def attendees(self): return self._a
    def organizer(self): return self._o


def test_eventkit_events_become_events():
    from palaver.calendar_eventkit import to_event

    org = _Participant("Anna Huber", "Anna@x.com", status=2)
    ek = _EKEvent("Receipt case study", [
        _Participant("Timo Strauss", "timo@x.com", status=2, me=True),
        _Participant("Bob Weiss", "bob@x.com", status=3),
        _Participant("Wien 3", "room@x.com", kind=2),
    ], org)
    event = to_event(ek)
    assert event.title == "Receipt case study" and event.start == T0
    names = [(a.name, a.organizer, a.response, a.is_self, a.is_room) for a in event.attendees]
    assert names == [
        ("Anna Huber", True, "accepted", False, False),  # organizer, not in the attendee list
        ("Timo Strauss", False, "accepted", True, False),
        ("Bob Weiss", False, "declined", False, False),
        ("Wien 3", False, "unknown", False, True),
    ]
    assert [a.name for a in cal.candidates(event, user_name="Timo")] == ["Anna Huber"]


def test_notes_prompt_names_the_event_and_invitees():
    from palaver import notes
    from palaver.models import Utterance

    seen = {}

    def run(prompt, schema):
        seen["p"] = prompt
        return {"title": "t", "summary": "s"}

    event = _event("Receipt case study", 0, 60, "Anna Huber", "Bob Weiss")
    notes.generate([Utterance("Timo", 0, 1, "Hi.")], user_name="Timo", meeting_start=T0, run=run, event=event)
    assert 'In the calendar it is "Receipt case study"; invited: Anna Huber, Bob Weiss.' in seen["p"]


def _recording(root: Path, name: str, start: datetime | None, minutes: float = 30) -> RecordingPaths:
    paths = RecordingPaths(root / name)
    paths.folder.mkdir()
    if start is not None:
        paths.meta.write_text(json.dumps({"start_time": start.isoformat(), "duration_seconds": minutes * 60}))
    return paths


def test_attach_all_fills_in_earlier_recordings(tmp_path: Path):
    done = _recording(tmp_path, "2026-10-27T14-00-00", T0 - timedelta(hours=1))
    cal.save(done, _event("Stored", -60, -30, uid="u1"))
    old = _recording(tmp_path, "2026-10-27T15-05-00", T0 + timedelta(minutes=5), minutes=20)
    cal.save(old, _event("Stored before events had ids", -30, 0))
    hit = _recording(tmp_path, "2026-10-27T15-00-00", T0)
    _recording(tmp_path, "2026-10-27T18-00-00", T0 + timedelta(hours=3))  # no event then
    _recording(tmp_path, "2026-10-27T19-00-00", None)  # still recording: no meta yet
    (tmp_path / "notes").mkdir()
    asked = []

    def provider(start, end):
        asked.append(start)
        return [_event("Receipt case study", 0, 30, "Anna Huber")]

    assert cal.attach_all(tmp_path, provider) == 2
    assert cal.load(hit).title == "Receipt case study"
    assert cal.load(done).title == "Stored"  # not looked up again
    # Looked up again (it had no id), but a stored event is never replaced by another (#48).
    assert cal.load(old).title == "Stored before events had ids"
    assert len(asked) == 3


def test_recording_span_uses_the_end_time_when_known(tmp_path: Path):
    paths = _recording(tmp_path, "2026-10-27T15-00-00", T0)
    assert cal.recording_span(paths) == (T0, T0 + timedelta(minutes=30))
    paths.meta.write_text(json.dumps({"start_time": T0.isoformat(),
                                      "end_time": (T0 + timedelta(minutes=5)).isoformat()}))
    assert cal.recording_span(paths)[1] == T0 + timedelta(minutes=5)


def test_directory_names_become_names_people_say():
    assert cal.person_name("Kralek, Karel (Contoso Services)") == "Karel Kralek"
    assert cal.person_name("Ortega, Luis Alberto (Contoso Technology, externer Mitarbeiter)") == "Luis Alberto Ortega"
    assert cal.person_name("GARCIA LOPEZ, JOSE MIGUEL EXT. (Contoso Technology Iberia External)") == "Jose Miguel Garcia Lopez"
    assert cal.person_name("Katharina Lichtenegg") == "Katharina Lichtenegg"
    assert cal.looks_like_room("03 - Seestraße | Meetingroom | KLOUD Vienna")
    assert cal.looks_like_room("16 - Attakring | Conferenceroom | KLOUD Vienna")
    assert not cal.looks_like_room("Andres Moreno Vidal")


def test_stored_events_are_tidied_and_invitees_listed_once():
    event = cal.Event.from_dict({
        "title": "Migration", "start": T0.isoformat(), "end": (T0 + timedelta(minutes=30)).isoformat(),
        "attendees": [{"name": "Brunner, Felix (Contoso Technology)", "email": "d@x.com"},
                      {"name": "Felix Brunner", "email": "felix@y.com"},
                      {"name": "03 - Seestraße | Meetingroom | KLOUD Vienna", "email": "room@x.com"}],
    })
    assert [a.name for a in cal.candidates(event, user_name="Timo")] == ["Felix Brunner"]


def test_attach_all_can_look_only_at_recent_recordings(tmp_path: Path):
    old = _recording(tmp_path, "2026-10-26T15-00-00", T0 - timedelta(days=1))
    new = _recording(tmp_path, "2026-10-27T15-00-00", T0)

    def provider(start, end):
        return [_event("Yesterday", -1440, -1410, "Anna"), _event("Today", 0, 30, "Anna")]

    assert cal.attach_all(tmp_path, provider, since=T0 - timedelta(hours=1)) == 1
    assert cal.load(new) is not None and cal.load(old) is None


def test_a_dismissed_event_is_not_attached_again(tmp_path: Path):
    paths = _recording(tmp_path, "2026-10-27T15-00-00", T0)
    provider = lambda s, e: [_event("Receipt case study", 0, 30, "Anna Huber")]
    cal.attach(paths, provider, T0, T0 + timedelta(minutes=30))
    cal.dismiss(paths)
    assert cal.load(paths) is None and cal.dismissed(paths)
    assert cal.attach(paths, provider, T0, T0 + timedelta(minutes=30)) is None
    assert cal.attach_all(tmp_path, provider) == 0
    assert cal.load(paths) is None


def test_the_event_at_a_moment_tells_back_to_back_meetings_apart():
    """For a call continued after a restart: still the same event? (#47)"""
    events = [_event("Standup", -30, 0, "Anna", uid="s"), _event("1:1", 0, 30, "Bob", uid="o"),
              _event("Holiday", -600, 1000, all_day=True)]
    assert cal.event_key_at(events, T0 - timedelta(minutes=2)) == events[0].key
    assert cal.event_key_at(events, T0 + timedelta(minutes=1)) == events[1].key
    assert cal.event_key_at(events, T0 + timedelta(hours=2)) is None
    no_uid = [_event("Sync", 0, 30, "Anna")]
    assert cal.event_key_at(no_uid, T0 + timedelta(minutes=5)) == f"Sync|{no_uid[0].start.isoformat()}"
