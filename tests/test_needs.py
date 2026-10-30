"""What waits on the user ("Needs you", phase 2 of the UI spec): one list of
open items per meeting, for Today, the meeting's strip, the list's dot and
the counter in the top bar."""

import json
import threading
import time
from datetime import datetime, timedelta
from pathlib import Path

import pytest

from palaver import attribution
from palaver import calendar_events as cal
from palaver import projects as P
from palaver.paths import RecordingPaths
from palaver.webapp import api

from .test_webapp import MEETING, _meeting, _req, server  # noqa: F401 (a fixture)

OLDER = "2026-10-26T09-00-00"


@pytest.fixture(autouse=True)
def _no_lookups_from_other_tests():
    """The background cut lookups are the module's: each test starts without any."""
    api.wait_for_cut_lookups(5)
    api._CUT_CACHE.clear()
    api._CUT_PENDING.clear()
    yield
    api.wait_for_cut_lookups(5)


def _kinds(found, mid=MEETING):
    return [i["kind"] for m in found["meetings"] if m["id"] == mid for i in m["items"]]


def _items(found, mid=MEETING):
    return next(m["items"] for m in found["meetings"] if m["id"] == mid)


def test_an_unreviewed_meeting_lists_what_is_open_in_the_order_of_the_page(tmp_path: Path):
    paths = _meeting(tmp_path)
    paths.speakers_auto.write_text(json.dumps({"SPEAKER_01": {"name": "Rico", "similarity": 0.7}}))
    store = P.ProjectStore()
    pid = store.create("Foundry")
    store.assign(MEETING, pid, by="auto", why="title", confidence=0.7)
    store.save()
    found = api.needs(tmp_path, user_name="Timo")
    # SPEAKER_00 talks 11 s and has no name; SPEAKER_01 is a guess by voice; the project is a proposal.
    assert _kinds(found) == ["unnamed", "speaker", "project", "review"]
    unnamed, speaker, project, review = _items(found)
    assert unnamed["label"] == "SPEAKER_00" and unnamed["display"] == "Speaker 1"
    assert unnamed["talk_seconds"] == 11.0
    assert unnamed["clip"] == {"start": 1.0, "end": 9.0}
    assert unnamed["guesses"] == ["Rico"]  # "Hi Rico" — and SPEAKER_00 answers
    assert (speaker["label"], speaker["name"]) == ("SPEAKER_01", "Rico")
    assert speaker["why"] == "voice 70% alike"
    assert (project["project"], project["name"]) == (pid, "Foundry")
    assert review == {"kind": "review", "id": "review"}
    assert [i["id"] for i in (unnamed, speaker, project)] == ["unnamed|SPEAKER_00", "speaker|SPEAKER_01|Rico",
                                                              f"project|{pid}"]
    m = found["meetings"][0]
    assert (m["id"], m["title"], m["start"]) == (MEETING, "Hiring debrief", "2026-10-27T16:03:07+01:00")
    assert found["count"] == 1  # meetings waiting


def test_a_reviewed_meeting_needs_nothing_it_had_and_the_newest_comes_first(tmp_path: Path):
    _meeting(tmp_path, OLDER)
    _meeting(tmp_path)
    assert [m["id"] for m in api.needs(tmp_path, user_name="Timo")["meetings"]] == [MEETING, OLDER]
    api.mark_reviewed(tmp_path, MEETING)
    found = api.needs(tmp_path, user_name="Timo")
    assert [m["id"] for m in found["meetings"]] == [OLDER]
    assert found["count"] == 1


def test_a_reviewed_meeting_shows_what_appeared_after_its_review(tmp_path: Path):
    paths = _meeting(tmp_path)  # Speaker 1 has no name
    api.mark_reviewed(tmp_path, MEETING)
    assert json.loads(paths.review.read_text())["seen"] == ["unnamed|SPEAKER_00"]  # left as it was: answered
    assert api.needs(tmp_path, user_name="Timo") == {"count": 0, "meetings": []}

    store = P.ProjectStore()  # a project proposed after the review, and a name guessed
    pid = store.create("Foundry")
    store.assign(MEETING, pid, by="auto", why="title", confidence=0.7)
    store.save()
    paths.speakers_auto.write_text(json.dumps({"SPEAKER_01": {"name": "Rico", "similarity": 0.7}}))
    found = api.needs(tmp_path, user_name="Timo")
    assert _kinds(found) == ["speaker", "project"]  # no review item: it is reviewed
    assert found["count"] == 1

    api.mark_reviewed(tmp_path, MEETING, done=False)  # not reviewed: everything again
    assert _kinds(api.needs(tmp_path, user_name="Timo")) == ["unnamed", "speaker", "project", "review"]


def test_which_event_an_unsure_one_and_none_at_all(tmp_path: Path):
    paths = _meeting(tmp_path)
    start = datetime.fromisoformat("2026-10-27T16:03:07+01:00")
    planned = cal.Event("Northwind", start, start + timedelta(minutes=60), (cal.Attendee("Anna", "anna@x.com"),),
                        uid="north")
    adhoc = cal.Event("Ad hoc", start, start + timedelta(minutes=10), (cal.Attendee("Bob", "bob@x.com"),), uid="adhoc")
    calendar = lambda s, e: []  # noqa: E731 (connected, nothing that runs into another meeting)

    # No event, no question: which was it? Only asked with a calendar to pick from.
    assert "no_event" not in _kinds(api.needs(tmp_path, user_name="Timo"))
    assert _kinds(api.needs(tmp_path, user_name="Timo", calendar=calendar))[0] == "no_event"

    cal.ask(paths, [planned, adhoc])
    item = _items(api.needs(tmp_path, user_name="Timo", calendar=calendar))[0]
    assert item["kind"] == "which_event" and item["reason"] == "2 events overlapped the recording"
    assert [c["title"] for c in item["choices"]] == ["Ad hoc", "Northwind"]

    cal.save(paths, planned, attribution.Link("event", "Northwind", "calendar", 0.6, "time match"))
    item = _items(api.needs(tmp_path, user_name="Timo", calendar=calendar))[0]
    assert (item["kind"], item["title"], item["why"]) == ("event", "Northwind", "time match")

    cal.dismiss(paths)  # "an ad-hoc call": not asked again
    assert _kinds(api.needs(tmp_path, user_name="Timo", calendar=calendar)) == ["unnamed", "review"]


def test_a_suggested_cut_is_open_until_dismissed(tmp_path: Path, monkeypatch):
    _meeting(tmp_path)
    cut = {"at": 13.0, "event": "Weekly", "event_start": "2026-10-27T16:03:20+01:00", "why": "new voices"}
    monkeypatch.setattr(api.cutting, "suggest_cut", lambda paths, events: None if paths.cut_dismissed.exists() else cut)
    calendar = lambda s, e: []  # noqa: E731
    api.needs(tmp_path, user_name="Timo", calendar=calendar)
    api.wait_for_cut_lookups(5)
    items = _items(api.needs(tmp_path, user_name="Timo", calendar=calendar))
    assert items[1] == {"kind": "cut", "id": "cut", **cut}
    api.dismiss_cut(tmp_path, MEETING)
    api.needs(tmp_path, user_name="Timo", calendar=calendar)
    api.wait_for_cut_lookups(5)
    assert "cut" not in _kinds(api.needs(tmp_path, user_name="Timo", calendar=calendar))


def test_the_cut_is_looked_up_in_the_background_and_again_later(tmp_path: Path, monkeypatch):
    _meeting(tmp_path)
    cut = {"at": 13.0, "event": "Weekly", "event_start": "2026-10-27T16:03:20+01:00", "why": "new voices"}
    gate, calls = threading.Event(), []

    def slow(paths, events):
        calls.append(paths.folder.name)
        gate.wait(5)
        return cut

    monkeypatch.setattr(api.cutting, "suggest_cut", slow)
    calendar = lambda s, e: []  # noqa: E731
    began = time.monotonic()
    assert "cut" not in _kinds(api.needs(tmp_path, user_name="Timo", calendar=calendar))  # never waits for it
    assert time.monotonic() - began < 1
    gate.set()
    api.wait_for_cut_lookups(5)
    assert "cut" in _kinds(api.needs(tmp_path, user_name="Timo", calendar=calendar))
    assert len(calls) == 1  # kept
    now = time.time()
    monkeypatch.setattr(api, "_clock", lambda: now + api.CUT_FRESH_SECONDS)  # ten minutes on: looked up again
    assert "cut" in _kinds(api.needs(tmp_path, user_name="Timo", calendar=calendar))  # the last answer meanwhile
    api.wait_for_cut_lookups(5)
    assert len(calls) == 2


def test_a_lookup_that_takes_too_long_counts_as_failed_and_is_tried_later(tmp_path: Path, monkeypatch):
    _meeting(tmp_path)
    gate, calls = threading.Event(), []
    monkeypatch.setattr(api.cutting, "suggest_cut", lambda paths, events: calls.append(1) or gate.wait(5) and None)
    calendar = lambda s, e: []  # noqa: E731
    now = [(time.time() // api.CUT_FRESH_SECONDS) * api.CUT_FRESH_SECONDS + 1]  # early in a ten minutes' span
    monkeypatch.setattr(api, "_clock", lambda: now[0])
    api.needs(tmp_path, user_name="Timo", calendar=calendar)
    now[0] += api.CUT_LOOKUP_SECONDS + 1
    api.needs(tmp_path, user_name="Timo", calendar=calendar)  # timed out: not asked again at once
    assert len(calls) == 1
    gate.set()
    api.wait_for_cut_lookups(5)
    now[0] += api.CUT_FRESH_SECONDS
    api.needs(tmp_path, user_name="Timo", calendar=calendar)
    api.wait_for_cut_lookups(5)
    assert len(calls) == 2


def test_needs_are_cached_per_meeting_by_its_files(tmp_path: Path, monkeypatch):
    paths = _meeting(tmp_path)
    first = api.needs(tmp_path, user_name="Timo")
    monkeypatch.setattr(api, "_lane_links", lambda *a, **kw: pytest.fail("not cached"))
    monkeypatch.setattr(api, "_unnamed_lanes", lambda *a, **kw: pytest.fail("not cached"))
    assert api.needs(tmp_path, user_name="Timo") == first
    monkeypatch.undo()
    paths.speakers.write_text(json.dumps({"SPEAKER_00": "Rico"}))  # named: built again
    assert _kinds(api.needs(tmp_path, user_name="Timo")) == ["review"]


def test_live_and_unfinished_meetings_need_nothing_yet(tmp_path: Path):
    paths = _meeting(tmp_path)
    paths.transcript_json.unlink()  # still being processed
    assert api.needs(tmp_path, user_name="Timo") == {"count": 0, "meetings": []}


def test_http_needs_and_undoing_a_dismissed_cut(server, tmp_path: Path):
    status, _, body = _req(server, "/api/needs")
    assert status == 200 and [m["id"] for m in json.loads(body)["meetings"]] == [MEETING]
    paths = RecordingPaths(tmp_path / MEETING)
    _req(server, f"/api/meetings/{MEETING}/cut-suggestion", method="POST", body={"dismiss": True})
    assert paths.cut_dismissed.exists()
    status, _, _ = _req(server, f"/api/meetings/{MEETING}/cut-suggestion", method="POST", body={"dismiss": False})
    assert status == 200 and not paths.cut_dismissed.exists()


def test_confirming_a_guessed_name_can_be_undone(tmp_path: Path):
    paths = _meeting(tmp_path)
    paths.speakers_inferred.write_text(json.dumps({"SPEAKER_00": {"name": "Carla", "rule": "elimination",
                                                                  "why": "the one invitee left", "confidence": 0.8}}))
    assert "speaker" in _kinds(api.needs(tmp_path, user_name="Timo"))
    token = api.name_speaker(tmp_path, MEETING, "SPEAKER_00", "Carla")
    assert token  # a confirmation is a change like any other: Today's card comes back with its undo
    assert _kinds(api.needs(tmp_path, user_name="Timo")) == ["review"]
    api.undo_change(tmp_path, token, user_name="Timo")
    lane = api.get_meeting(tmp_path, MEETING, user_name="Timo")["speakers"][1]
    assert (lane["name"], lane["named_by"]) == ("Carla", "inferred")


# --- "Don't Know": a voice the user can't name ------------------------------------------


def _unnamed(tmp_path: Path) -> int:
    return api.list_meetings(tmp_path)[0]["unnamed"]


def test_a_voice_nobody_knows_is_no_to_do_but_stays_an_unnamed_lane(tmp_path: Path):
    paths = _meeting(tmp_path)
    assert _unnamed(tmp_path) == 1 and "unnamed" in _kinds(api.needs(tmp_path, user_name="Timo"))
    token = api.set_unknown(tmp_path, MEETING, "SPEAKER_00", True)
    assert token and json.loads(paths.speakers_unknown.read_text()) == ["SPEAKER_00"]
    assert _kinds(api.needs(tmp_path, user_name="Timo")) == ["review"]
    entry = api.list_meetings(tmp_path)[0]
    assert (entry["unnamed"], entry["nameless"]) == (0, 1)  # no to-do, still a voice in the meeting
    lane = api.get_meeting(tmp_path, MEETING, user_name="Timo")["speakers"][1]
    assert (lane["label"], lane["name"], lane["unknown"]) == ("SPEAKER_00", None, True)
    assert lane["guesses"]  # a normal unnamed lane: its suggestions stay

    api.set_unknown(tmp_path, MEETING, "SPEAKER_00", False)  # Ask Me Again
    assert not paths.speakers_unknown.exists()
    assert _unnamed(tmp_path) == 1 and "unnamed" in _kinds(api.needs(tmp_path, user_name="Timo"))
    assert api.get_meeting(tmp_path, MEETING, user_name="Timo")["speakers"][1]["unknown"] is False


def test_dont_know_is_undone_with_its_token(tmp_path: Path):
    paths = _meeting(tmp_path)
    token = api.set_unknown(tmp_path, MEETING, "SPEAKER_00", True)
    assert api.undo_change(tmp_path, token, user_name="Timo") == [MEETING]
    assert not paths.speakers_unknown.exists() and _unnamed(tmp_path) == 1


def test_dont_know_is_said_of_a_voice_of_the_meeting(tmp_path: Path):
    paths = _meeting(tmp_path)
    with pytest.raises(api.NotFound):
        api.set_unknown(tmp_path, MEETING, "SPEAKER_09", True)
    paths.speakers_merged.write_text(json.dumps({"SPEAKER_01": "SPEAKER_00"}))
    api.set_unknown(tmp_path, MEETING, "SPEAKER_01", True)  # a merged voice is the lane it joined
    assert json.loads(paths.speakers_unknown.read_text()) == ["SPEAKER_00"]


def test_naming_a_voice_nobody_knew_takes_it_out_of_dont_know(tmp_path: Path):
    paths = _meeting(tmp_path)
    api.set_unknown(tmp_path, MEETING, "SPEAKER_00", True)
    api.name_speaker(tmp_path, MEETING, "SPEAKER_00", "Rico")
    assert not paths.speakers_unknown.exists()
    api.name_speaker(tmp_path, MEETING, "SPEAKER_00", "")  # unnamed again: asked again
    assert _unnamed(tmp_path) == 1


def test_the_undo_of_a_naming_brings_dont_know_back(tmp_path: Path):
    paths = _meeting(tmp_path)
    api.set_unknown(tmp_path, MEETING, "SPEAKER_00", True)
    # Inferred later, then confirmed: the speaker-file snapshot of that confirmation holds speakers_unknown.json too.
    paths.speakers_inferred.write_text(json.dumps({"SPEAKER_00": {"name": "Carla", "rule": "elimination",
                                                                  "why": "the one invitee left", "confidence": 0.8}}))
    token = api.name_speaker(tmp_path, MEETING, "SPEAKER_00", "Carla")
    assert token and not paths.speakers_unknown.exists()
    api.undo_change(tmp_path, token, user_name="Timo")
    assert json.loads(paths.speakers_unknown.read_text()) == ["SPEAKER_00"]


def test_a_reviewed_meeting_has_no_voices_to_name_left_in_the_list(tmp_path: Path):
    _meeting(tmp_path)
    api.mark_reviewed(tmp_path, MEETING)  # Speaker 1 was open then: the user saw it and left it
    entry = api.list_meetings(tmp_path)[0]
    assert (entry["unnamed"], entry["nameless"]) == (0, 1)
    api.mark_reviewed(tmp_path, MEETING, done=False)
    assert _unnamed(tmp_path) == 1


def test_a_voice_unnamed_after_the_review_is_to_name_again(tmp_path: Path):
    paths = _meeting(tmp_path)
    paths.speakers.write_text(json.dumps({"SPEAKER_00": "Rico"}))
    api.mark_reviewed(tmp_path, MEETING)
    assert _unnamed(tmp_path) == 0
    api.name_speaker(tmp_path, MEETING, "SPEAKER_00", "")  # not seen at the review: a to-do, as in Needs you
    assert _unnamed(tmp_path) == 1 and _kinds(api.needs(tmp_path, user_name="Timo")) == ["unnamed"]


def test_http_dont_know(server, tmp_path: Path):
    path = f"/api/meetings/{MEETING}/unknown"
    status, _, body = _req(server, path, method="POST", body={"label": "SPEAKER_00", "on": True})
    answer = json.loads(body)
    assert status == 200 and answer["undo"] and answer["speakers"][1]["unknown"] is True
    assert _req(server, path, method="POST", body={"label": "SPEAKER_00", "on": "yes"})[0] == 400
    assert _req(server, path, method="POST", body={"label": "SPEAKER_09", "on": True})[0] == 404
    status, _, _ = _req(server, "/api/undo", method="POST", body={"token": answer["undo"]})
    assert status == 200 and not RecordingPaths(tmp_path / MEETING).speakers_unknown.exists()
