"""Search in the window and MCP (#46): filters for people, organizations,
projects and dates next to the words, results grouped per meeting."""

import json
import shutil
from datetime import date, datetime
from pathlib import Path

from palaver import calendar_events as cal
from palaver import notes
from palaver.paths import RecordingPaths
from palaver.webapp import api

from .test_webapp import MEETING, _meeting

TODAY = date(2026, 10, 29)
OTHER = "2026-09-15T10-00-00"


def _copy(root: Path, name: str, start: str) -> RecordingPaths:
    shutil.copytree(root / MEETING, root / name)
    paths = RecordingPaths(root / name)
    meta = json.loads(paths.meta.read_text())
    paths.meta.write_text(json.dumps({**meta, "start_time": start}))
    return paths


def _invite(paths: RecordingPaths, *people: tuple[str, str]):
    t = datetime.fromisoformat("2026-10-27T16:00:00+01:00")
    cal.save(paths, cal.Event("Weekly", t, t, (
        cal.Attendee("Timo Strauss", "timo@kloud.io", is_self=True),
        *(cal.Attendee(name, email) for name, email in people))))


def _two(tmp_path: Path) -> tuple[RecordingPaths, RecordingPaths]:
    """MEETING: Rico and Anna spoke; OTHER (September): Rico spoke, Thomas invited from ACB."""
    first = _meeting(tmp_path)
    second = _copy(tmp_path, OTHER, "2026-09-15T10:00:00+02:00")
    api.name_speaker(tmp_path, MEETING, "SPEAKER_00", "Rico")
    api.name_speaker(tmp_path, MEETING, "SPEAKER_01", "Anna")
    api.name_speaker(tmp_path, OTHER, "SPEAKER_00", "Rico")
    _invite(second, ("Thomas Kraus", "thomas@acb.de"))
    return first, second


def ids(results):
    return [r["id"] for r in results]


def search(tmp_path, text):
    return api.search(tmp_path, text, user_name="Timo", today=TODAY)


def test_people_who_all_took_part(tmp_path: Path):
    _two(tmp_path)
    assert ids(search(tmp_path, "Rico")) == [MEETING, OTHER]
    assert ids(search(tmp_path, "Rico and Anna")) == [MEETING]
    assert ids(search(tmp_path, "Anna and Thomas")) == []
    assert ids(search(tmp_path, "Anna or Thomas")) == [MEETING, OTHER]


def test_an_invitee_took_part_but_a_speaker_ranks_first(tmp_path: Path):
    _two(tmp_path)
    assert ids(search(tmp_path, "Thomas")) == [OTHER]  # invited only
    api.name_speaker(tmp_path, MEETING, "SPEAKER_00", "")  # Rico no longer speaks in MEETING …
    _invite(RecordingPaths(tmp_path / MEETING), ("Rico Lanza", "rico@kloud.io"))  # … he is invited
    # MEETING is newer, but in OTHER Rico spoke ("Rico" there is "Rico Lanza" here).
    assert ids(search(tmp_path, "rico lanza")) == [OTHER, MEETING]


def test_an_organization_took_part(tmp_path: Path):
    _two(tmp_path)
    page = api.search_page(tmp_path, "meetings with ACB people", user_name="Timo", today=TODAY)
    assert ids(page["results"]) == [OTHER]
    assert [c["kind"] for c in page["understood"]] == ["org"]


def test_a_project_and_a_time_range(tmp_path: Path):
    _two(tmp_path)
    api.set_meeting_project(tmp_path, MEETING, name="ÖNW")
    api.set_meeting_project(tmp_path, OTHER, project=api.projects.ProjectStore().find("ÖNW"))
    assert ids(search(tmp_path, "ÖNW")) == [MEETING, OTHER]
    assert ids(search(tmp_path, "ÖNW last month")) == [OTHER]
    assert ids(search(tmp_path, "önw since 2026-10-01")) == [MEETING]


def test_people_and_words_together(tmp_path: Path):
    _two(tmp_path)
    second = RecordingPaths(tmp_path / OTHER)
    lines = json.loads(second.transcript_json.read_text())
    lines[1]["text"] = "Welcome to the pricing talk."
    second.transcript_json.write_text(json.dumps(lines))
    [hit] = search(tmp_path, "with Rico about pricing")
    assert hit["id"] == OTHER and hit["hits"] == [{"start": 1.0, "speaker": "Rico", "text": "Welcome to the pricing talk."}]


def test_what_was_decided_shows_the_decision_first(tmp_path: Path):
    _two(tmp_path)
    [hit, _] = search(tmp_path, "what did we decide about the offer")
    assert hit["notes_hits"] == [{"kind": "decision", "text": "Make an offer"}]
    assert hit["hits"] == []  # the transcript is not where decisions are
    [hit, _] = search(tmp_path, "offer")
    assert [h["kind"] for h in hit["notes_hits"]] == ["decision", "step"]  # decisions, then next steps
    assert hit["notes_hits"][1] == {"kind": "step", "text": "Send the offer", "owner": "Anna"}


def test_decisions_alone_list_the_meetings_decisions(tmp_path: Path):
    first, _ = _two(tmp_path)
    doc = json.loads(first.notes.read_text())
    first.notes.write_text(json.dumps({**doc, "decisions": []}))
    [hit] = search(tmp_path, "in:decisions")
    assert hit["id"] == OTHER and hit["notes_hits"] == [{"kind": "decision", "text": "Make an offer"}]


def test_lines_a_person_said(tmp_path: Path):
    _two(tmp_path)
    [hit] = search(tmp_path, "where did Anna talk about salary")
    assert hit["id"] == MEETING
    assert [h["speaker"] for h in hit["hits"]] == ["Anna"]
    assert search(tmp_path, "where did Rico talk about salary") == []  # Anna said it, not Rico
    [hit] = search(tmp_path, "by:Anna")
    assert hit["hit_count"] == 1  # all she said


def test_reviewed_and_next_steps(tmp_path: Path):
    first, second = _two(tmp_path)
    api.mark_reviewed(tmp_path, OTHER)
    assert ids(search(tmp_path, "is:reviewed")) == [OTHER]
    assert ids(search(tmp_path, "is:unreviewed")) == [MEETING]
    doc = json.loads(first.notes.read_text())
    first.notes.write_text(json.dumps({**doc, "next_steps": []}))
    assert ids(search(tmp_path, "has:steps")) == [OTHER]


def test_a_quoted_name_is_a_word(tmp_path: Path):
    _two(tmp_path)
    assert ids(search(tmp_path, '"Rico" salary')) == [MEETING, OTHER]  # said in both
    assert search(tmp_path, '"Tom"') == []  # nobody says Tom


def test_the_page_gets_what_was_understood_and_whether_meaning_can_help(tmp_path: Path):
    _two(tmp_path)
    page = api.search_page(tmp_path, "Rico last month salary", user_name="Timo", today=TODAY)
    assert page["understood"] == [
        {"kind": "person", "label": "Rico", "title": "Took part: named speaker or invited", "span": [0, 4],
         "text": "Rico", "written": False},
        {"kind": "date", "label": "Last month", "title": "2026-09-01 to 2026-09-30", "span": [5, 15],
         "text": "last month", "written": False},
    ]
    assert page["words"] == ["salary"] and ids(page["results"]) == [OTHER]
    assert page["meaning"] == "off"  # no index yet in this folder
    assert api.search_page(tmp_path, "", user_name="Timo")["results"] == []


def test_the_window_asks_over_http(tmp_path: Path, monkeypatch):
    import threading
    from urllib.parse import quote

    from palaver.webapp.server import App, make_server

    from .test_webapp import _req

    _two(tmp_path)
    asked = []
    monkeypatch.setattr(api, "search_meaning",
                        lambda output_dir, q, *, user_name, **kw: asked.append(q) or [{"id": MEETING, "meaning": []}])
    srv = make_server(App(tmp_path, "Timo"), port=0)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        status, _, body = _req(srv, "/api/search?q=" + quote("Rico and Anna"))
        page = json.loads(body)
        assert status == 200 and ids(page["results"]) == [MEETING]
        assert [c["label"] for c in page["understood"]] == ["Rico", "Anna"]
        status, _, body = _req(srv, "/api/search/meaning?q=pricing")
        assert status == 200 and json.loads(body) == [{"id": MEETING, "meaning": []}] and asked == ["pricing"]
    finally:
        srv.shutdown()
        srv.server_close()


def test_the_lines_of_a_meeting_are_made_readable_once_per_change(tmp_path: Path, monkeypatch):
    import os

    first, _ = _two(tmp_path)
    calls = []
    real = api.readable
    monkeypatch.setattr(api, "readable", lambda us: calls.append(1) or real(us))
    search(tmp_path, "salary")
    search(tmp_path, "band")
    api.search_meaning(tmp_path, "salary", user_name="Timo")  # the meaning request uses them too
    assert len(calls) == 2  # one per meeting
    later = first.transcript_json.stat().st_mtime_ns + 10**9
    lines = json.loads(first.transcript_json.read_text())
    lines[2]["text"] = "Thanks Rico, the salary band is too low."
    first.transcript_json.write_text(json.dumps(lines))
    os.utime(first.transcript_json, ns=(later, later))
    [hit, _] = search(tmp_path, "salary")
    assert len(calls) == 3 and hit["hits"][0]["text"] == "Thanks Rico, the salary band is too low."


def test_the_window_learns_when_the_index_is_built():
    class Bridge:
        def question(self):
            return None

        def indexing(self):
            return {"indexing": True, "downloading": True}

    assert api.search_status(Bridge()) == {"indexing": True, "downloading": True}
    assert api.search_status(None) == {"indexing": False, "downloading": False}  # no menu bar app


def test_the_search_cache_is_warmed_in_the_background(tmp_path: Path, monkeypatch):
    """At start the window's server makes every meeting readable for the
    search, after a delay, and never while a recording or processing runs."""
    _two(tmp_path)
    api._SEARCH_CACHE.clear()
    calls, slept = [], []
    real = api.readable
    monkeypatch.setattr(api, "readable", lambda us: calls.append(1) or real(us))
    busy = iter([True, True, False, False, False, False])  # busy at first: it waits

    api.warm_search_cache(tmp_path, user_name="Timo", busy=lambda: next(busy), sleep=slept.append, delay=20.0)
    assert slept[:3] == [20.0, api.WARM_RETRY_SECONDS, api.WARM_RETRY_SECONDS]
    assert len(calls) == 2  # both meetings
    search(tmp_path, "salary")
    assert len(calls) == 2  # the search found them ready


def test_warming_stops_when_a_recording_starts_and_goes_on_after_it(tmp_path: Path, monkeypatch):
    _two(tmp_path)
    api._SEARCH_CACHE.clear()
    calls, slept = [], []
    real = api.readable
    monkeypatch.setattr(api, "readable", lambda us: calls.append(1) or real(us))
    states = iter([False, False, True, True, False, False, False, False])  # a call starts after the first

    api.warm_search_cache(tmp_path, user_name="Timo", busy=lambda: next(states), sleep=slept.append, delay=0.0)
    assert len(calls) == 2 and slept.count(api.WARM_RETRY_SECONDS) == 1


def test_the_menu_bar_says_when_it_is_busy(tmp_path: Path, monkeypatch):
    from palaver import daemon

    monkeypatch.setattr(daemon, "STATE_PATH", tmp_path / "daemon.json")
    assert api.busy_recording(None) is False  # no menu bar app, no daemon
    (tmp_path / "daemon.json").write_text(json.dumps({"state": "recording", "pid": 1}))
    assert api.busy_recording(None) is True  # `palaver app` beside `palaver daemon`: its state file says
    for status, busy in [({"state": "recording"}, True), ({"state": "idle", "transcribing": True}, True),
                         ({"state": "idle", "transcribing": False}, False)]:
        class Bridge:
            def busy(self, _s=status):
                return _s["state"] == "recording" or bool(_s.get("transcribing"))
        assert api.busy_recording(Bridge()) is busy


def test_the_server_warms_the_search_at_start(tmp_path: Path, monkeypatch):
    from palaver.webapp import server

    started = []
    monkeypatch.setattr(api, "start_warming", lambda output_dir, **kw: started.append((output_dir, kw)))
    srv = server.start_in_background(server.App(tmp_path, "Timo"), port=0)
    try:
        assert started == [(tmp_path, {"user_name": "Timo", "recording": None})]
    finally:
        srv.shutdown()
        srv.server_close()
