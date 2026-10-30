"""Tests for meeting prep: projects and context before a meeting (#31)."""

import json
from datetime import datetime, timedelta
from pathlib import Path

from palaver import calendar_events as cal
from palaver import prep
from palaver import projects as P
from palaver.paths import RecordingPaths

NOW = datetime.fromisoformat("2026-10-28T09:00:00+01:00")


def _event(title, hours, *people, uid="", series=False, start=None):
    start = start or NOW + timedelta(hours=hours)
    attendees = (cal.Attendee("Timo Strauss", "timo@kloud.io", is_self=True),) + tuple(
        cal.Attendee(p, f"{p.split()[0].lower()}@contoso.com") for p in people)
    return cal.Event(title, start, start + timedelta(minutes=30), attendees, uid=uid or title, series=series)


def _recorded(root: Path, name: str, event: cal.Event, summary: str = "", steps=()) -> RecordingPaths:
    paths = RecordingPaths(root / name)
    paths.folder.mkdir(parents=True)
    paths.meta.write_text(json.dumps({"start_time": event.start.isoformat(), "duration_seconds": 1800}))
    paths.transcript_json.write_text("[]")
    cal.save(paths, event)
    if summary:
        notes = {"title": event.title, "summary": summary,
                 "next_steps": [{"owner": "SPEAKER_01", "task": t} for t in steps]}
        paths.notes.write_text(json.dumps(notes))
    return paths


def test_upcoming_lists_what_is_still_to_come():
    events = [_event("Done", -2, "Anna"), _event("Running", -0.2, "Anna"), _event("Later", 3, "Anna"),
              _event("Day after", 60, "Anna"), _event("Kita reminder", 1),  # nobody invited: not a meeting
              cal.Event("Holiday", NOW, NOW + timedelta(days=1), all_day=True, uid="h")]
    assert [e.title for e in prep.upcoming(lambda s, e: events, NOW)] == ["Running", "Later"]


def test_a_project_chosen_before_goes_to_the_recording(tmp_path):
    store = P.ProjectStore()
    pid = store.create("Migration Foundry")
    store.save()
    event = _event("Foundry Sync", 2, "Jannik Kessler", uid="abc", series=True)
    prep.choose(event, pid)
    assert prep.chosen(event) == [pid]

    paths = _recorded(tmp_path, "2026-10-28T11-00-00", event)
    assert prep.apply(paths, event) == [pid]
    assert P.ProjectStore().of_meeting("2026-10-28T11-00-00") == {pid: {"by": "you", "why": "chosen before the meeting"}}
    assert prep.chosen(event) == []  # used up


def test_a_recurring_event_goes_where_its_series_went_and_brings_context(tmp_path):
    past = _event("Foundry Sync", -24 * 7, "Jannik Kessler", uid="series-1", series=True)
    _recorded(tmp_path, "2026-10-21T11-00-00", past, summary="Pilot in Australia.", steps=["Book the engineer"])
    _recorded(tmp_path, "2026-10-14T11-00-00", _event("Lunch", -24 * 14, "Jannik Kessler", uid="x"))
    store = P.ProjectStore()
    pid = store.create("Migration Foundry")
    store.assign("2026-10-21T11-00-00", pid)
    store.save()

    # A changed occurrence: its id is the series' plus when it was.
    upcoming = _event("Foundry Sync (moved)", 2, "Jasper Moreira", uid="series-1/RID=814282200", series=True)
    [s] = prep.suggestions(upcoming, tmp_path, user_name="Timo")
    assert s["id"] == pid and s["why"].startswith("series")
    [c] = prep.context(upcoming, tmp_path, user_name="Timo")
    assert c["id"] == "2026-10-21T11-00-00" and c["why"] == "same series"
    assert c["summary"] == "Pilot in Australia." and c["next_steps"][0]["task"] == "Book the engineer"
    assert c["next_steps"][0]["owner"] == "Speaker 2"  # no label shows

    other = _event("Contoso chat", 3, "Jannik Kessler", uid="new")
    assert [c["why"] for c in prep.context(other, tmp_path, user_name="Timo")] == ["same people", "same people"]


def test_the_meetings_before_are_called_what_the_user_renamed_them_to(tmp_path):
    from palaver import titles

    past = _event("Foundry Sync", -24 * 7, "Jannik Kessler", uid="series-1", series=True)
    paths = _recorded(tmp_path, "2026-10-21T11-00-00", past, summary="Pilot in Australia.")
    titles.save(paths, "Pilot go/no-go")
    upcoming = _event("Foundry Sync", 2, "Jannik Kessler", uid="series-1/RID=814282200", series=True)
    [c] = prep.context(upcoming, tmp_path, user_name="Timo")
    assert c["title"] == "Pilot go/no-go"
