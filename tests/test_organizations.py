"""Tests for people's organizations: "Timo Strauß (KLOUD)", "Stefan D (Extern)"."""

import json
from pathlib import Path

from palaver import calendar_events as cal
from palaver import organizations as O
from palaver.webapp import api

from .test_webapp import MEETING, _meeting


def test_the_email_domain_says_the_organization():
    assert O.org_key("karel@contoso.es") == O.org_key("jan@contoso.com") == "contoso"
    assert O.org_key("ana@externos.contoso.es") == "contoso"
    assert O.org_key("stefan@gmail.com") == "extern"
    assert O.org_key(None) is None
    assert O.default_name("kloud") == "KLOUD" and O.default_name("contoso") == "Contoso"
    assert O.default_name("extern") == "Extern"


def _with_invitees(tmp_path: Path):
    paths = _meeting(tmp_path)
    start = cal.datetime.fromisoformat("2026-10-27T16:03:07+01:00")
    cal.save(paths, cal.Event("Debrief", start, start + cal.timedelta(minutes=30), (
        cal.Attendee("Timo Strauß", "timo@kloud.io", is_self=True),
        cal.Attendee("Rico Lanza", "rico@muellerbau.at"),
        cal.Attendee("Anna Huber", "anna@gmail.com"),
        cal.Attendee("Room 3", "room@kloud.io", is_room=True),
    )))
    return paths


def test_speakers_and_invitees_show_their_organization(tmp_path):
    _with_invitees(tmp_path)
    api.name_speaker(tmp_path, MEETING, "SPEAKER_00", "Rico")  # first name: resolves to Rico Lanza
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert [(s["name"], s["org"]) for s in m["speakers"]] == [("Timo", "KLOUD"), ("Rico", "Muellerbau"),
                                                             (None, None)]
    assert {a["name"]: a["org"] for a in m["calendar"]["attendees"]} == {"Rico Lanza": "Muellerbau",
                                                                        "Anna Huber": "Extern"}


def test_organizations_can_be_renamed_and_people_given_one(tmp_path):
    _with_invitees(tmp_path)
    api.name_speaker(tmp_path, MEETING, "SPEAKER_00", "Rico")
    api.name_speaker(tmp_path, MEETING, "SPEAKER_01", "Stefan D")
    api.rename_organization("muellerbau", "Müllerbau")
    api.set_person_org("Stefan D", "Extern")
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert [s["org"] for s in m["speakers"]] == ["KLOUD", "Müllerbau", "Extern"]

    d = api.directory(tmp_path)
    assert {o["key"]: o["name"] for o in d["organizations"]} == {"kloud": "KLOUD", "muellerbau": "Müllerbau",
                                                                 "extern": "Extern"}
    stefan = next(p for p in d["people"] if p["name"] == "Stefan D")
    assert stefan["org"] == "Extern" and stefan["org_given"]
    api.set_person_org("Stefan D", "")
    assert api.get_meeting(tmp_path, MEETING, user_name="Timo")["speakers"][2]["org"] is None
    assert json.loads(O._path().read_text())["names"] == {"muellerbau": "Müllerbau"}


def test_a_colleague_at_a_client_stays_a_colleague():
    """Felix is KLOUD but was invited with his Contoso address lately; Anna
    has two client addresses, more often the Contoso one."""
    def entry(name, emails, me=False):
        return {"name": name, "email": emails[-1], "emails": {e: emails.count(e) for e in emails}, "self": me}

    index = {
        "timo": entry("Timo", ["timo@kloud.io"], me=True),
        "felix brunner": entry("Felix Brunner", ["felix@kloud.io", "felix.brunner@contoso.es"]),
        "anna huber": entry("Anna Huber", ["anna@contoso.de", "anna@contoso.de", "anna@muellerbau.at"]),
    }
    orgs = O.Organizations(Path("/nonexistent/organizations.json"))
    assert O.org_of("Felix Brunner", index, orgs) == "KLOUD"
    assert O.org_of("Anna Huber", index, orgs) == "Contoso"


def test_the_index_keeps_every_address_of_a_person(tmp_path):
    from datetime import datetime, timedelta

    from palaver.paths import RecordingPaths

    start = datetime.fromisoformat("2026-10-27T16:03:07+01:00")
    for i, email in enumerate(["felix@kloud.io", "felix.brunner@contoso.es"]):
        paths = _meeting(tmp_path / str(i))
        folder = tmp_path / f"2026-10-2{7 + i}T16-03-07"
        paths.folder.rename(folder)
        cal.save(RecordingPaths(folder), cal.Event("Sync", start, start + timedelta(minutes=30), (cal.Attendee("Felix Brunner", email),)))
    entry = O.people_index(tmp_path)["felix brunner"]
    assert entry["emails"] == {"felix@kloud.io": 1, "felix.brunner@contoso.es": 1}
