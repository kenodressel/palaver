"""Tests for the meetings app: API data and the HTTP server."""

import json
import os
import time
import urllib.error
import urllib.request
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from palaver import glossary, notes, projects
from palaver.models import Utterance
from palaver.paths import RecordingPaths
from palaver.webapp import api
from palaver.webapp.server import App, make_server

SR = 16_000
MEETING = "2026-10-27T16-03-07"


def _meeting(root: Path, name: str = MEETING) -> RecordingPaths:
    paths = RecordingPaths(root / name)
    paths.folder.mkdir(parents=True)
    t = np.arange(SR * 20)
    sf.write(str(paths.system_wav), (3000 * np.sin(t / 7)).astype(np.int16), SR, subtype="PCM_16")
    sf.write(str(paths.mic_wav), (2000 * np.sin(t / 3)).astype(np.int16), SR, subtype="PCM_16")
    paths.meta.write_text(json.dumps({"start_time": "2026-10-27T16:03:07+01:00", "duration_seconds": 20}))
    paths.system_turns.write_text(json.dumps([
        {"speaker": "SPEAKER_00", "start": 1.0, "end": 12.0},
        {"speaker": "SPEAKER_01", "start": 13.0, "end": 15.0},
        {"speaker": "SPEAKER_02", "start": 16.0, "end": 16.2},  # never in the transcript
    ]))
    utterances = [
        Utterance("Timo", 0.0, 1.0, "Hi Rico, äh, welcome."),
        Utterance("SPEAKER_00", 1.0, 12.0, "Welcome to the hiring debrief."),
        Utterance("SPEAKER_01", 13.0, 15.0, "Thanks Rico, the salary band is fine."),
    ]
    paths.transcript_json.write_text(json.dumps([u.to_dict() for u in utterances]))
    notes.save(paths, {
        "title": "Hiring debrief",
        "summary": "SPEAKER_00 ran the debrief.",
        "sections": [],
        "next_steps": [{"owner": "SPEAKER_01", "task": "Send the offer"}],
        "decisions": ["Make an offer"],
        "speaker_names": [{"label": "SPEAKER_00", "name": "Rico", "evidence": "Hi Rico"},
                          {"label": "SPEAKER_01", "name": "Rico", "evidence": "Thanks Rico"}],
        "transcript_hash": notes.transcript_hash(utterances),
    })
    return paths


def test_list_meetings_newest_first_with_titles(tmp_path: Path):
    _meeting(tmp_path, "2026-10-26T09-00-00")
    _meeting(tmp_path)
    (tmp_path / "not-a-recording").mkdir()
    meetings = api.list_meetings(tmp_path)
    assert [m["id"] for m in meetings] == [MEETING, "2026-10-26T09-00-00"]
    assert meetings[0]["title"] == "Hiring debrief" and meetings[0]["status"] == "ready"
    assert meetings[0]["start"] == "2026-10-27T16:03:07+01:00"


def test_meeting_has_clean_transcript_speakers_and_named_notes(tmp_path: Path):
    _meeting(tmp_path)
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")

    assert m["transcript"][0] == {"speaker": "Timo", "label": None, "start": 0.0, "end": 1.0, "text": "Hi Rico welcome.",
                                  "edited": False, "heard": None, "unsure": [], "glossed": []}
    assert [s["label"] for s in m["speakers"]] == [None, "SPEAKER_00", "SPEAKER_01"]
    rico = m["speakers"][1]
    assert rico["name"] is None and rico["display"] == "Speaker 1" and rico["guesses"] == [{"name": "Rico", "evidence": "Hi Rico"}]
    assert m["speakers"][2]["guesses"] == []  # said "Thanks Rico" itself: not a hint
    assert rico["clips"] == [{"start": 1.0, "end": 9.0}]  # capped at 8 s
    assert m["notes"]["summary"] == "Speaker 1 ran the debrief."
    assert [t["speaker"] for t in m["transcript"]] == ["Timo", "Speaker 1", "Speaker 2"]
    assert m["transcript"][1]["label"] == "SPEAKER_00"
    assert not m["notes_stale"]


def test_naming_a_speaker_updates_transcript_and_notes(tmp_path: Path):
    paths = _meeting(tmp_path)
    api.name_speaker(tmp_path, MEETING, "SPEAKER_00", "Rico")
    api.name_speaker(tmp_path, MEETING, "SPEAKER_01", "Anna")
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert [t["speaker"] for t in m["transcript"]] == ["Timo", "Rico", "Anna"]
    assert m["transcript"][1]["label"] == "SPEAKER_00"
    assert m["notes"]["summary"] == "Rico ran the debrief."
    assert m["notes"]["next_steps"][0]["owner"] == "Anna"
    assert m["speakers"][1]["named_by"] == "you"
    assert not m["notes_stale"]  # names don't make notes stale
    assert api.known_names(tmp_path, "Timo") == ["Anna", "Rico", "Timo"]

    api.name_speaker(tmp_path, MEETING, "SPEAKER_01", "")
    assert json.loads(paths.speakers.read_text()) == {"SPEAKER_00": "Rico"}
    with pytest.raises(api.NotFound):
        api.name_speaker(tmp_path, MEETING, "SPEAKER_09", "Bob")


def test_search_finds_transcript_lines_and_notes(tmp_path: Path):
    _meeting(tmp_path)
    [hit] = api.search(tmp_path, "SALARY", user_name="Timo")
    assert hit["id"] == MEETING and hit["hits"][0]["start"] == 13.0
    [hit] = api.search(tmp_path, "make an offer", user_name="Timo")
    assert hit["in_notes"] and hit["hits"] == []
    assert api.search(tmp_path, "nothing like this", user_name="Timo") == []


def test_search_matches_words_from_their_start(tmp_path: Path):
    paths = _meeting(tmp_path)
    transcript = json.loads(paths.transcript_json.read_text())
    transcript[1]["text"] = "Lass uns den Wortvorrat prüfen."
    transcript[2]["text"] = "Das RTV-Projekt läuft gut."
    paths.transcript_json.write_text(json.dumps(transcript))
    [hit] = api.search(tmp_path, "rtv", user_name="Timo")
    assert [h["text"] for h in hit["hits"]] == ["Das RTV-Projekt läuft gut."]  # not "Wortvorrat"
    assert api.search(tmp_path, "rojekt", user_name="Timo") == []
    [hit] = api.search(tmp_path, "projekt rtv", user_name="Timo")  # every word, any order
    assert hit["hit_count"] == 1
    assert api.search(tmp_path, "rtv rico", user_name="Timo")  # the words may be in different lines


def test_search_ranks_title_and_notes_before_the_transcript(tmp_path: Path):
    first = _meeting(tmp_path)
    second = tmp_path / "2026-10-20T09-00-00"
    import shutil
    shutil.copytree(first.folder, second)
    meta = json.loads((second / "meta.json").read_text())
    (second / "meta.json").write_text(json.dumps({**meta, "start_time": "2026-10-20T09:00:00+02:00"}))
    notes_doc = json.loads((second / "notes.json").read_text())
    (second / "notes.json").write_text(json.dumps({**notes_doc, "title": "Salary review"}))
    assert [r["id"] for r in api.search(tmp_path, "salary", user_name="Timo")] == [second.name, MEETING]


def test_meeting_ids_cannot_leave_the_recordings_folder(tmp_path: Path):
    _meeting(tmp_path)
    for bad in ("..", "../etc", "2026-10-27T16-03-07/../..", "x"):
        with pytest.raises(api.NotFound):
            api.meeting_paths(tmp_path, bad)


def test_audio_mix_is_the_sum_and_any_range_matches(tmp_path: Path):
    paths = _meeting(tmp_path)
    src = api.AudioSource(paths, "mix")
    whole = src.read(0, src.size - 1)
    assert len(whole) == src.size
    mic, _ = sf.read(str(paths.mic_wav), dtype="int16")
    sysa, _ = sf.read(str(paths.system_wav), dtype="int16")
    expected = np.clip(mic.astype(np.int32) + sysa, -32768, 32767).astype("<i2")
    assert np.array_equal(np.frombuffer(whole[44:], dtype="<i2"), expected)
    # Odd, unaligned slices stitch back together.
    cuts = [0, 7, 44, 45, 1001, 50_000, src.size]
    assert b"".join(src.read(a, b - 1) for a, b in zip(cuts, cuts[1:])) == whole
    info = sf.info(str(paths.mic_wav))
    tmp = tmp_path / "out.wav"
    tmp.write_bytes(whole)
    assert sf.info(str(tmp)).frames == info.frames


# --- HTTP ---------------------------------------------------------------

@pytest.fixture
def server(tmp_path: Path):
    _meeting(tmp_path)
    written, model_runs = [], []
    app = App(tmp_path, "Timo", write_notes=lambda mid: written.append(mid) or True,
              run_projects=lambda args: model_runs.append(args) or True)
    srv = make_server(app, port=0)
    import threading

    threading.Thread(target=srv.serve_forever, daemon=True).start()
    srv.written = written
    srv.model_runs = model_runs
    yield srv
    srv.shutdown()
    srv.server_close()


def _req(srv, path, *, method="GET", body=None, headers=None):
    port = srv.server_address[1]
    data = json.dumps(body).encode() if body is not None else None
    h = {"Host": f"127.0.0.1:{port}", **({"Content-Type": "application/json"} if data else {}), **(headers or {})}
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as err:
        return err.code, dict(err.headers), err.read()


def test_http_api_and_page(server):
    status, _, body = _req(server, "/api/meetings")
    assert status == 200 and json.loads(body)[0]["id"] == MEETING
    status, headers, body = _req(server, "/")
    assert status == 200 and headers["Content-Type"].startswith("text/html") and b"<html" in body.lower()
    assert _req(server, "/api/meetings/..%2F..%2Fetc")[0] == 404
    assert _req(server, "/../server.py")[0] == 404  # exists, but outside static/


def test_index_has_settings_entry(server):
    status, _, body = _req(server, "/")
    assert status == 200 and b'aria-label="Settings"' in body


def test_http_rejects_other_hosts_and_non_json_posts(server):
    assert _req(server, "/api/meetings", headers={"Host": "evil.example:8765"})[0] == 403
    port = server.server_address[1]
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/api/meetings/{MEETING}/speakers", data=b"label=SPEAKER_00&name=X",
        method="POST", headers={"Content-Type": "application/x-www-form-urlencoded"})
    with pytest.raises(urllib.error.HTTPError) as err:
        urllib.request.urlopen(req)
    assert err.value.code == 415


def test_http_names_speakers_and_writes_notes(server):
    status, _, body = _req(server, f"/api/meetings/{MEETING}/speakers", method="POST",
                           body={"label": "SPEAKER_00", "name": "Rico"})
    assert status == 200 and json.loads(body)["transcript"][1]["speaker"] == "Rico"
    status, _, _ = _req(server, f"/api/meetings/{MEETING}/notes", method="POST", body={})
    assert status == 200 and server.written == [MEETING]


def test_http_audio_ranges(server):
    status, headers, body = _req(server, f"/api/meetings/{MEETING}/audio", headers={"Range": "bytes=0-99"})
    assert status == 206 and len(body) == 100 and body[:4] == b"RIFF"
    total = int(headers["Content-Range"].split("/")[1])
    assert total == 44 + 2 * SR * 20
    status, headers, body = _req(server, f"/api/meetings/{MEETING}/audio?track=system",
                                 headers={"Range": "bytes=100-"})
    assert status == 206 and headers["Content-Range"].startswith("bytes 100-")
    assert _req(server, f"/api/meetings/{MEETING}/audio", headers={"Range": f"bytes={total}-"})[0] == 416


def test_http_people_directory_rename_and_name_voices(server):
    _req(server, f"/api/meetings/{MEETING}/speakers", method="POST", body={"label": "SPEAKER_00", "name": "Rico"})
    status, _, body = _req(server, "/api/people")
    [rico] = json.loads(body)["people"]
    assert status == 200 and rico["name"] == "Rico"
    assert rico["meetings"][0]["title"] == "Hiring debrief" and rico["meetings"][0]["clip"] == {"start": 1.0, "end": 9.0}
    assert rico["meetings"][0]["projects"] == []  # shown next to the day, each a link to its filter

    status, _, body = _req(server, "/api/people/rename", method="POST", body={"old": "Rico", "new": "Rico Lanza"})
    assert status == 200 and json.loads(body)["people"][0]["name"] == "Rico Lanza"
    _, _, body = _req(server, f"/api/meetings/{MEETING}")
    assert json.loads(body)["transcript"][1]["speaker"] == "Rico Lanza"

    status, _, _ = _req(server, "/api/voices/name", method="POST",
                        body={"voices": [[MEETING, "SPEAKER_01"]], "name": "Anna"})
    assert status == 200
    assert _req(server, "/api/voices/name", method="POST", body={"voices": [[MEETING, "SPEAKER_09"]], "name": "X"})[0] == 404
    assert _req(server, "/api/people/rename", method="POST", body={"old": "Anna", "new": " "})[0] == 400
    _, _, body = _req(server, "/api/names")
    assert json.loads(body) == ["Anna", "Rico Lanza", "Timo"]


def test_meeting_shows_its_calendar_event_and_offers_invitees(tmp_path: Path):
    from datetime import datetime

    from palaver import calendar_events as cal

    paths = _meeting(tmp_path)
    t = datetime.fromisoformat("2026-10-27T16:00:00+01:00")
    cal.save(paths, cal.Event("Hiring debrief: Data Parks", t, t, (
        cal.Attendee("Timo Strauss", is_self=True),
        cal.Attendee("Rico Lanza", organizer=True),
        cal.Attendee("Anna Berg"),
        cal.Attendee("Bob Weiss", response="declined"),
        cal.Attendee("Wien 3", is_room=True),
    )))
    api.name_speaker(tmp_path, MEETING, "SPEAKER_00", "Rico Lanza")
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert m["calendar"]["title"] == "Hiring debrief: Data Parks"
    assert [a["name"] for a in m["calendar"]["attendees"]] == ["Rico Lanza", "Anna Berg", "Bob Weiss"]
    assert m["calendar"]["invited"] == ["Anna Berg"]  # Rico has a speaker already, Bob declined
    assert api.list_meetings(tmp_path)[0]["title"] == "Hiring debrief: Data Parks"


def test_merged_speakers_share_one_lane(tmp_path: Path):
    paths = _meeting(tmp_path)
    api.merge_speaker(tmp_path, MEETING, "SPEAKER_01", "SPEAKER_00")
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert [s["label"] for s in m["speakers"]] == [None, "SPEAKER_00"]
    lane = m["speakers"][1]
    assert lane["talk_seconds"] == 13.0 and lane["merged"] == [{"label": "SPEAKER_01", "display": "Speaker 2"}]
    assert [(t["speaker"], t["label"]) for t in m["transcript"][1:]] == [
        ("Speaker 1", "SPEAKER_00"), ("Speaker 1", "SPEAKER_00")]
    assert m["notes"]["next_steps"][0]["owner"] == "Speaker 1"

    api.name_speaker(tmp_path, MEETING, "SPEAKER_01", "Konrad")  # names the person it joined
    assert json.loads(paths.speakers.read_text()) == {"SPEAKER_00": "Konrad"}
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert [t["speaker"] for t in m["transcript"]] == ["Timo", "Konrad", "Konrad"]

    api.merge_speaker(tmp_path, MEETING, "SPEAKER_01", None)
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert [t["speaker"] for t in m["transcript"]] == ["Timo", "Konrad", "Speaker 2"]
    with pytest.raises(api.NotFound):
        api.merge_speaker(tmp_path, MEETING, "SPEAKER_01", "SPEAKER_09")


def test_http_merges_speakers(server):
    status, _, body = _req(server, f"/api/meetings/{MEETING}/merge", method="POST",
                           body={"label": "SPEAKER_01", "into": "SPEAKER_00"})
    assert status == 200 and len(json.loads(body)["speakers"]) == 2
    status, _, body = _req(server, f"/api/meetings/{MEETING}/merge", method="POST",
                           body={"label": "SPEAKER_01", "into": None})
    assert status == 200 and len(json.loads(body)["speakers"]) == 3


def test_list_shows_who_was_there_and_what_is_left_to_do(tmp_path: Path):
    paths = _meeting(tmp_path)
    [m] = api.list_meetings(tmp_path)
    # SPEAKER_00 talked 11 s, SPEAKER_01 only 2 s: too little to ask for a name
    assert m["people"] == [] and m["unnamed"] == 1
    assert m["has_notes"] and not m["notes_stale"] and m["title_from"] == "notes"

    api.name_speaker(tmp_path, MEETING, "SPEAKER_00", "Rico")
    [m] = api.list_meetings(tmp_path)  # file times changed: not the cached entry
    assert m["people"] == ["Rico"] and m["unnamed"] == 0

    transcript = json.loads(paths.transcript_json.read_text())
    transcript[1]["text"] = "Welcome to the new hiring debrief."
    paths.transcript_json.write_text(json.dumps(transcript))
    [m] = api.list_meetings(tmp_path)
    assert m["notes_stale"]


def test_projects_page_and_meeting_projects(tmp_path: Path):
    _meeting(tmp_path)
    _meeting(tmp_path, "2026-10-26T09-00-00")
    d = api.list_projects(tmp_path, user_name="Timo")
    assert d["projects"] == [] and {m["id"] for m in d["unsorted"]} == {MEETING, "2026-10-26T09-00-00"}

    api.set_meeting_project(tmp_path, MEETING, name="Hiring")  # a new name makes a project
    [hiring] = api.list_projects(tmp_path, user_name="Timo")["projects"]
    pid = hiring["id"]
    # the faces beside the meeting in the project: its named people, as in the meeting list
    assert hiring["meetings"][0]["people"] == next(m["people"] for m in api.list_meetings(tmp_path) if m["id"] == MEETING)
    api.update_project(tmp_path, pid, description="Lead engineer hiring.")
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert [(p["name"], p["by"]) for p in m["projects"]] == [("Hiring", "you")]
    assert m["all_projects"] == [{"id": pid, "name": "Hiring"}]
    # the other meeting has the same title and people: suggested
    assert [s["name"] for s in api.get_meeting(tmp_path, "2026-10-26T09-00-00", user_name="Timo")[
        "project_suggestions"]] == ["Hiring"]
    assert api.list_meetings(tmp_path)[0]["projects"][0]["name"] == "Hiring"

    other = api.create_project("Recruiting")
    api.set_meeting_project(tmp_path, "2026-10-26T09-00-00", project=other)
    api.merge_projects(tmp_path, other, pid)
    [p] = api.list_projects(tmp_path, user_name="Timo")["projects"]
    assert p["description"] == "Lead engineer hiring." and len(p["meetings"]) == 2

    api.set_meeting_project(tmp_path, MEETING, project=pid, remove=True)
    assert api.get_meeting(tmp_path, MEETING, user_name="Timo")["project_suggestions"] == []  # stays out
    api.delete_project(tmp_path, pid)
    with pytest.raises(api.NotFound):
        api.update_project(tmp_path, pid, name="X")
    with pytest.raises(api.NotFound):
        api.set_meeting_project(tmp_path, "2026-01-01T00-00-00", name="X")


def test_http_projects(server):
    status, _, body = _req(server, "/api/projects", method="POST", body={"name": "Hiring"})
    pid = json.loads(body)["projects"][0]["id"]
    status, _, body = _req(server, f"/api/meetings/{MEETING}/projects", method="POST", body={"project": pid})
    assert status == 200 and json.loads(body)["projects"][0]["name"] == "Hiring"
    status, _, body = _req(server, f"/api/projects/{pid}", method="POST", body={"name": "Recruiting"})
    assert status == 200 and json.loads(body)["projects"][0]["name"] == "Recruiting"
    status, _, body = _req(server, "/api/projects/suggest", method="POST", body={})
    assert status == 200 and server.model_runs == [["suggest"]]
    assert _req(server, "/api/projects/zz/delete", method="POST", body={})[0] == 404
    status, _, body = _req(server, f"/api/projects/{pid}/delete", method="POST", body={})
    assert status == 200 and json.loads(body)["projects"] == []


def test_glossary_suggestions_accept_and_what_changed(tmp_path: Path):
    paths = _meeting(tmp_path)
    transcript = json.loads(paths.transcript_json.read_text())
    transcript[1]["text"] = "Welcome, we run it on Databricks in Atterkring."
    transcript[2]["text"] = "Databricks is fine, Atterkring too."
    paths.transcript_json.write_text(json.dumps(transcript))
    paths.transcript_md.write_text("old")
    paths.calendar.write_text(json.dumps({"title": "Debrief", "start": "2026-10-27T16:03:07+01:00",
                                          "end": "2026-10-27T16:30:00+01:00",
                                          "attendees": [{"name": "16 - Attakring | Conferenceroom"}]}))

    page = api.glossary_page(tmp_path, user_name="Timo")
    variant = next(s for s in page["suggestions"] if s["kind"] == "variant")
    assert variant["term"] == "Attakring" and variant["variants"] == ["Atterkring"]
    assert variant["examples"][0]["title"] == "Debrief"

    notes_now = json.loads(paths.notes.read_text())
    paths.notes.write_text(json.dumps({**notes_now, "summary": "Debrief held in Atterkring."}))
    changed = api.accept_suggestion(tmp_path, term="Attakring", variants=["Atterkring"])
    assert changed == {"meetings": [MEETING], "replacements": 2, "in_notes": 1}
    assert api.get_meeting(tmp_path, MEETING, user_name="Timo")["notes"]["summary"] == "Debrief held in Attakring."
    assert api.list_meetings(tmp_path)[0]["summary"] == "Debrief held in Attakring."
    assert "Attakring" in paths.transcript_md.read_text()  # rendered again
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert m["transcript"][1]["text"] == "Welcome, we run it on Databricks in Attakring."
    assert json.loads(paths.transcript_json.read_text())[1]["text"].endswith("Atterkring.")  # kept as heard

    [term] = api.glossary_page(tmp_path, user_name="Timo")["terms"]
    assert api.update_term(tmp_path, term["id"], delete=True)["replacements"] == 2
    assert api.get_meeting(tmp_path, MEETING, user_name="Timo")["transcript"][1]["text"].endswith("Atterkring.")


def test_respelling_words_as_a_meeting_shows_them(tmp_path: Path):
    paths = _meeting(tmp_path)
    transcript = json.loads(paths.transcript_json.read_text())
    transcript[1]["text"] = "Es geht darum, Tini abzulösen, den Genie-Teil im SDK."
    paths.transcript_json.write_text(json.dumps(transcript))
    said = lambda: api.get_meeting(tmp_path, MEETING, user_name="Timo")["transcript"][1]["text"]

    d = api.respell(tmp_path, heard="Tini", term="Genie")
    assert d["changed"]["replacements"] == 1 and d["term"]["variants"] == ["Tini"]
    assert said() == "Es geht darum, Genie abzulösen, den Genie-Teil im SDK."

    # The meeting shows the term now: respelling it renames the term.
    d = api.respell(tmp_path, heard="Genie", term="Zini")
    assert d["changed"]["replacements"] == 2  # every word shown differently, not just the new variant
    assert d["term"]["term"] == "Zini" and d["term"]["variants"] == ["Tini", "Genie"]
    assert said() == "Es geht darum, Zini abzulösen, den Zini-Teil im SDK."

    # Another term by that spelling takes this one in.
    gid = d["term"]["id"]
    api.accept_suggestion(tmp_path, term="Zini GmbH", variants=[])
    d = api.respell(tmp_path, heard="Zini", term="zini gmbh")
    assert d["term"]["term"] == "Zini GmbH" and d["term"]["variants"] == ["Zini", "Tini", "Genie"]
    assert gid not in glossary.Glossary().terms()
    assert said() == "Es geht darum, Zini GmbH abzulösen, den Zini GmbH-Teil im SDK."

    with pytest.raises(ValueError):
        api.respell(tmp_path, heard="Zini", term=" ")


def test_review_queue_lists_what_is_open_until_done(tmp_path: Path):
    _meeting(tmp_path)
    [item] = api.review_queue(tmp_path, user_name="Timo")
    assert item["open"]["unnamed"] == 1 and item["open"]["projects"] == "none" and item["open"]["notes"] == "ok"
    api.mark_reviewed(tmp_path, MEETING)
    assert api.review_queue(tmp_path, user_name="Timo") == []
    api.mark_reviewed(tmp_path, MEETING, done=False)
    assert len(api.review_queue(tmp_path, user_name="Timo")) == 1


def test_http_glossary_and_review(server):
    status, _, body = _req(server, "/api/glossary/accept", method="POST",
                           body={"term": "Rico", "variants": ["Riko"]})
    d = json.loads(body)
    assert status == 200 and d["terms"][0]["term"] == "Rico" and d["changed"]["replacements"] == 0
    status, _, body = _req(server, "/api/glossary/respell", method="POST", body={"heard": "Rico", "term": "Riko"})
    assert status == 200 and json.loads(body)["term"] == {"id": d["terms"][0]["id"], "term": "Riko",
                                                          "variants": ["Rico"], "note": ""}
    status, _, body = _req(server, "/api/glossary/reject", method="POST", body={"key": "term:x"})
    assert status == 200
    status, _, body = _req(server, f"/api/meetings/{MEETING}/reviewed", method="POST", body={"done": True})
    assert status == 200 and json.loads(body) == []
    assert _req(server, "/api/glossary/ffff", method="POST", body={"term": "X"})[0] == 404


def _recording(root: Path) -> RecordingPaths:
    """A meeting being recorded, as far as the live worker got."""
    paths = RecordingPaths(root / MEETING)
    paths.folder.mkdir(parents=True)
    Path(str(paths.system_wav) + ".part").write_bytes(b"\0" * 100)  # still growing
    seg = lambda t, text, who=None: {"start": t, "end": t + 2, "text": text, "speaker": who, "words": []}
    paths.live.write_text(json.dumps({
        "until": 60.0,
        "mic": [seg(0.0, "Hallo zusammen.", "Timo")],
        "system": [seg(3.0, "Hi Timo."), seg(20.0, "Ja, passt.")],
        "turns": [{"speaker": "SPEAKER_00", "start": 3.0, "end": 15.0},
                  {"speaker": "SPEAKER_01", "start": 18.0, "end": 30.0}],
        "embeddings": {"SPEAKER_00": [1.0, 0.0], "SPEAKER_01": [0.0, 1.0]},
    }))
    return paths


def test_a_meeting_just_started_opens_before_its_first_live_block(tmp_path: Path):
    """The first minute of a call: audio growing, no live.json and no speaker turns yet."""
    paths = RecordingPaths(tmp_path / MEETING)
    paths.folder.mkdir(parents=True)
    for track in (paths.system_wav, paths.mic_raw_wav):
        Path(str(track) + ".part").write_bytes(b"\0" * 100)
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert m["status"] == "recording"


def test_a_meeting_being_recorded_shows_what_is_there_so_far(tmp_path: Path):
    paths = _recording(tmp_path)
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert m["status"] == "recording" and m["live"] == {"until": 60.0}
    assert [(t["speaker"], t["text"]) for t in m["transcript"]] == [
        ("Timo", "Hallo zusammen."), ("Speaker 1", "Hi Timo."), ("Speaker 2", "Ja, passt.")]
    assert [s["label"] for s in m["speakers"]] == [None, "SPEAKER_00", "SPEAKER_01"]

    api.name_speaker(tmp_path, MEETING, "SPEAKER_01", "Konrad")
    # The next snapshot clusters differently: Konrad's voice is now SPEAKER_00.
    live = json.loads(paths.live.read_text())
    live["embeddings"] = {"SPEAKER_00": [0.1, 1.0], "SPEAKER_01": [1.0, 0.1]}
    paths.live.write_text(json.dumps(live))
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert m["transcript"][1]["speaker"] == "Konrad" and m["speakers"][1]["named_by"] == "you"

    # Recording done and processed: the final label with Konrad's voice gets his name.
    from palaver.speakers import adopt_live_names

    paths.speaker_embeddings.write_text(json.dumps({"SPEAKER_00": [0.9, 0.2], "SPEAKER_01": [0.05, 1.0]}))
    assert adopt_live_names(paths) == {"SPEAKER_01": "Konrad"}
    assert json.loads(paths.speakers.read_text()) == {"SPEAKER_01": "Konrad"}
    assert not paths.speakers_live.exists()


def test_upcoming_meetings_can_be_prepared(tmp_path: Path):
    from datetime import datetime, timedelta

    from palaver import calendar_events as cal

    _meeting(tmp_path)
    now = datetime.fromisoformat("2026-10-28T09:00:00+01:00")
    event = cal.Event("Hiring debrief", now + timedelta(hours=2), now + timedelta(hours=3),
                      (cal.Attendee("Anna Huber", "anna@x.com"),), uid="ev/1+=", series=True)
    provider = lambda s, e: [event]  # noqa: E731
    [u] = api.upcoming(provider, now=now)
    assert u["key"] == "ev/1+=|2026-10-28" and u["projects"] == []

    api.set_upcoming_project(provider, u["key"], name="Hiring", now=now)
    m = api.upcoming_meeting(tmp_path, provider, u["key"], user_name="Timo", now=now)
    assert [p["name"] for p in m["projects"]] == ["Hiring"] and m["attendees"][0]["name"] == "Anna Huber"
    assert api.upcoming(None) == []
    with pytest.raises(api.NotFound):
        api.upcoming_meeting(tmp_path, provider, "nope|2026-10-28", user_name="Timo", now=now)


def test_http_upcoming_without_a_calendar(server):
    status, _, body = _req(server, "/api/upcoming")
    assert status == 200 and json.loads(body) == []
    assert _req(server, "/api/upcoming/x%7C2026-10-28")[0] == 404


def test_a_voice_removed_as_noise_disappears_with_its_lines_until_restored(tmp_path: Path):
    paths = _meeting(tmp_path)
    api.remove_speaker(tmp_path, MEETING, "SPEAKER_01")
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert [s["label"] for s in m["speakers"]] == [None, "SPEAKER_00"]
    assert [t["speaker"] for t in m["transcript"]] == ["Timo", "Speaker 1"]
    assert m["removed"] == [{"label": "SPEAKER_01", "display": "Speaker 2"}]
    assert "salary" not in paths.transcript_md.read_text()
    assert len(json.loads(paths.transcript_json.read_text())) == 3  # kept as heard
    assert api.search(tmp_path, "salary", user_name="Timo") == []

    api.remove_speaker(tmp_path, MEETING, "SPEAKER_01", removed=False)
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert len(m["speakers"]) == 3 and m["removed"] == []
    assert not paths.speakers_ignored.exists()


def test_http_removes_a_voice(server):
    status, _, body = _req(server, f"/api/meetings/{MEETING}/remove", method="POST", body={"label": "SPEAKER_01"})
    assert status == 200 and json.loads(body)["removed"][0]["label"] == "SPEAKER_01"
    assert _req(server, f"/api/meetings/{MEETING}/remove", method="POST", body={"label": "SPEAKER_09"})[0] == 404


def test_a_page_that_lets_go_mid_answer_is_no_error(tmp_path: Path, monkeypatch, caplog):
    import socket

    _meeting(tmp_path)
    srv = make_server(App(tmp_path, "Timo"), port=0)
    import threading

    threading.Thread(target=srv.serve_forever, daemon=True).start()

    def gone(*args, **kwargs):
        raise BrokenPipeError(32, "Broken pipe")

    monkeypatch.setattr(api, "list_meetings", gone)
    port = srv.server_address[1]
    with socket.create_connection(("127.0.0.1", port)) as s:
        s.sendall(f"GET /api/meetings HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n".encode())
        s.settimeout(2)
        assert s.recv(100) == b""  # closed without an answer
    srv.shutdown()
    srv.server_close()
    assert "failed" not in caplog.text


def test_choosing_the_calendar_event_of_a_meeting(tmp_path: Path):
    from datetime import datetime, timedelta

    from palaver import calendar_events as cal

    paths = _meeting(tmp_path)
    start = datetime.fromisoformat(json.loads(paths.meta.read_text())["start_time"])

    def event(title, minutes, uid):
        return cal.Event(title, start, start + timedelta(minutes=minutes), uid=uid)

    planned, adhoc = event("Northwind Zwischenstand", 60, "u1"), event("Ad hoc", 10, "u2")
    calendar = lambda s, e: [planned, adhoc]  # two at once
    cal.save(paths, planned)

    found = api.meeting_events(tmp_path, MEETING, calendar)
    assert [(e["title"], e["current"]) for e in found] == [("Ad hoc", False), ("Northwind Zwischenstand", True)]

    api.set_meeting_event(tmp_path, MEETING, calendar, key=adhoc.key)
    assert cal.load(paths).title == "Ad hoc"
    api.set_meeting_event(tmp_path, MEETING, calendar, key=None)  # none of them
    assert cal.load(paths) is None and cal.dismissed(paths)
    assert not any(e["current"] for e in api.meeting_events(tmp_path, MEETING, calendar))
    with pytest.raises(api.NotFound):
        api.set_meeting_event(tmp_path, MEETING, calendar, key="nope|2026-10-27")


def test_http_meeting_events(server):
    status, _, body = _req(server, f"/api/meetings/{MEETING}/events")
    assert status == 200 and json.loads(body) == []  # no calendar connected in tests
    status, _, body = _req(server, f"/api/meetings/{MEETING}/event", method="POST", body={"key": None})
    assert status == 200 and json.loads(body)["calendar"] is None


def test_a_meeting_goes_to_the_trash(tmp_path: Path):
    _meeting(tmp_path)
    api.trash_meeting(tmp_path, MEETING, user_name="Timo")
    assert not (tmp_path / MEETING).exists() and (tmp_path / ".trash" / MEETING / "meta.json").exists()
    assert [m["id"] for m in api.list_meetings(tmp_path)] == []
    with pytest.raises(api.NotFound):
        api.trash_meeting(tmp_path, MEETING, user_name="Timo")


def test_a_meeting_being_recorded_is_not_trashed(tmp_path: Path, monkeypatch):
    _meeting(tmp_path)
    monkeypatch.setattr(api, "_status", lambda paths: "recording")
    with pytest.raises(ValueError):
        api.trash_meeting(tmp_path, MEETING, user_name="Timo")
    assert (tmp_path / MEETING).exists()


def test_http_trash(server):
    status, _, body = _req(server, f"/api/meetings/{MEETING}/trash", method="POST", body={})
    assert status == 200 and json.loads(body) == {"trashed": MEETING, "undo": json.loads(body)["undo"]}

def test_http_settings(server):
    status, _, body = _req(server, "/api/settings")
    assert status == 200 and json.loads(body)["realtime"] is True
    status, _, body = _req(server, "/api/settings", method="POST", body={"realtime": False})
    assert status == 200 and json.loads(body)["realtime"] is False
    assert json.loads(_req(server, "/api/settings")[2])["realtime"] is False
    assert _req(server, "/api/settings", method="POST", body={"realtime": "yes"})[0] == 400


# --- the stream's tail (#42) ---------------------------------------------

def _stream_json(paths: RecordingPaths) -> None:
    seg = lambda t, text: {"start": t, "end": t + 2, "text": text, "speaker": None, "settled_at": t + 3}
    paths.stream.write_text(json.dumps({
        "until": 75.0,
        "system": [seg(50.0, "Alt, von vorher."), seg(70.0, "Ähm, wir nehmen Atterkring."), seg(74.0, "Ja.")],
        "mic": [{**seg(72.0, "Äh, passt gut."), "words": []}],
        "draft": {"system": "und dann", "mic": "roh vom Mikro"},
        "questions": [{"start": 70.0, "end": 72.0, "text": "Wie viel?"}],
        "speaking": {"others": True, "me": False},
        "updated_at": time.time(),
    }))


def test_stream_tail_without_stream_json(tmp_path: Path):
    _recording(tmp_path)
    assert api.live_stream(tmp_path, MEETING, user_name="Timo", since=0.0) == {"stream": False}


def test_stream_tail_after_block_text(tmp_path: Path):
    g = glossary.Glossary()
    g.add("Attakring", ["Atterkring"])
    g.save()
    _stream_json(_recording(tmp_path))  # live.json says until=60
    tail = api.live_stream(tmp_path, MEETING, user_name="Timo", since=60.0)
    assert tail["stream"] is True and tail["until"] == 75.0
    assert tail["lines"] == [
        {"speaker": "Others", "label": "stream", "start": 70.0, "end": 72.0, "text": "Wir nehmen Attakring.",
         "glossed": [[11, 20, "Atterkring"]]},  # shown as respelled by the glossary
        {"speaker": "Timo", "label": None, "start": 72.0, "end": 74.0, "text": "Passt gut.", "glossed": []},
        {"speaker": "Others", "label": "stream", "start": 74.0, "end": 76.0, "text": "Ja.", "glossed": []},
    ]
    assert tail["draft"] == {"system": "und dann", "mic": "roh vom Mikro"}
    assert tail["speaking"] == {"others": True, "me": False}
    assert tail["questions"] == [{"start": 70.0, "end": 72.0, "text": "Wie viel?"}]


def test_http_stream_endpoint(server, tmp_path: Path):
    assert json.loads(_req(server, f"/api/meetings/{MEETING}/stream?since=0")[2]) == {"stream": False}
    _stream_json(RecordingPaths(tmp_path / MEETING))
    status, _, body = _req(server, f"/api/meetings/{MEETING}/stream?since=71")
    assert status == 200
    assert json.loads(body) == api.live_stream(tmp_path, MEETING, user_name="Timo", since=71.0)
    assert [l["start"] for l in json.loads(body)["lines"]] == [72.0, 74.0]
    assert _req(server, "/api/meetings/nope/stream")[0] == 404


def test_stream_tail_survives_wrong_shapes(tmp_path: Path):
    paths = _recording(tmp_path)
    good = {"start": 70.0, "end": 72.0, "text": "Gut.", "speaker": None}
    paths.stream.write_text(json.dumps({
        "until": "soon",
        "system": [good, None, "x", {"end": 3, "text": "no start"}, {"start": "7", "end": 8, "text": "str start"},
                   {"start": 71.0, "end": 72.0}, {"start": 71.0, "end": 72.0, "text": 5}],
        "mic": None,
        "draft": "not a dict",
        "speaking": [1],
        "questions": None,
    }))
    tail = api.live_stream(tmp_path, MEETING, user_name="Timo", since=0.0)
    assert tail == {"stream": True, "until": 0, "draft": {"system": "", "mic": ""}, "speaking": {}, "questions": [],
                    "lines": [{"speaker": "Others", "label": "stream", "start": 70.0, "end": 72.0, "text": "Gut.",
                               "glossed": []}]}
    paths.stream.write_text(json.dumps({"system": {"a": 1}, "draft": None}))
    assert api.live_stream(tmp_path, MEETING, user_name="Timo", since=0.0)["lines"] == []
    paths.stream.write_text("[1, 2]")
    assert api.live_stream(tmp_path, MEETING, user_name="Timo", since=0.0) == {"stream": False}


def test_stream_tail_while_the_stream_starts(tmp_path: Path):
    """stream.json appears once the model has loaded; until then a running
    stream says it is starting, so the window keeps asking."""
    paths = _recording(tmp_path)
    paths.stream_pid.write_text(str(os.getpid()))
    assert api.live_stream(tmp_path, MEETING, user_name="Timo", since=0.0) == {"stream": False, "starting": True}
    paths.stream_pid.write_text("999999999")  # gone
    assert api.live_stream(tmp_path, MEETING, user_name="Timo", since=0.0) == {"stream": False}


def test_a_stale_stream_is_no_stream(tmp_path: Path):
    paths = _recording(tmp_path)
    _stream_json(paths)
    updated = json.loads(paths.stream.read_text())["updated_at"]
    tail = api.live_stream(tmp_path, MEETING, user_name="Timo", since=0.0, now=updated + 9.5)
    assert tail["stream"] is True and tail["draft"]["system"] == "und dann"
    paths.stream_pid.write_text(str(os.getpid()))  # even with its pid file left
    assert api.live_stream(tmp_path, MEETING, user_name="Timo", since=0.0, now=updated + 10.5) == {
        "stream": False, "stale": True}


def test_set_settings_writes_only_what_changed(tmp_path: Path):
    """A switch the user never touched follows config.toml: settings.json
    holds only the keys the user changed."""
    from palaver import settings

    no_slack = settings.Settings(record_slack=False)  # config.toml: [recording] slack = false
    assert api.set_settings({"realtime": False}, no_slack)["record_slack"] is False
    assert json.loads(settings.path().read_text()) == {"realtime": False}
    assert api.get_settings(settings.Settings())["record_slack"] is True  # config.toml changed
    settings.path().write_text('{"realtime": false, "future": 1}')
    assert api.set_settings({"record_teams": False}, no_slack) == {
        "realtime": False, "record_teams": False, "record_slack": False, "search_meaning": True,
        "live_processing": True, "nudge_talk_share": True, "nudge_monologue": True, "nudge_quiet_invitee": True,
        "nudge_pace": False, "nudge_fillers": False, "check_updates": True}
    assert json.loads(settings.path().read_text()) == {"realtime": False, "future": 1, "record_teams": False}
    settings.path().write_text("[broken")
    api.set_settings({"record_slack": True}, no_slack)
    assert json.loads(settings.path().read_text()) == {"record_slack": True}


def test_stream_tail_filler_only_draft_is_empty(tmp_path: Path):
    paths = _recording(tmp_path)
    paths.stream.write_text(json.dumps({"draft": {"system": "Mm-hmm.", "mic": "äh"}}))
    assert api.live_stream(tmp_path, MEETING, user_name="Timo", since=0.0)["draft"] == {"system": "", "mic": ""}


def test_a_transcript_line_can_be_edited_and_reverted(tmp_path: Path):
    paths = _meeting(tmp_path)
    paths.transcript_md.write_text("old")
    line = api.get_meeting(tmp_path, MEETING, user_name="Timo")["transcript"][-1]
    assert line["text"] == "Thanks Rico, the salary band is fine." and not line["edited"]

    api.edit_line(tmp_path, MEETING, start=line["start"], text="Thanks, Rico. The salary band is fine, äh, really.")
    edited = api.get_meeting(tmp_path, MEETING, user_name="Timo")["transcript"][-1]
    assert edited["edited"] and edited["text"] == "Thanks, Rico. The salary band is fine, äh, really."  # as typed
    assert edited["heard"] == "Thanks Rico, the salary band is fine."
    raw = json.loads(paths.transcript_json.read_text())[-1]
    assert raw["heard"] == "Thanks Rico, the salary band is fine."  # what was heard is kept
    assert "really" in paths.transcript_md.read_text()  # rendered again
    assert api.search(tmp_path, "really", user_name="Timo")

    api.edit_line(tmp_path, MEETING, start=line["start"], text=None)  # back to what was heard
    back = api.get_meeting(tmp_path, MEETING, user_name="Timo")["transcript"][-1]
    assert back["text"] == "Thanks Rico, the salary band is fine." and not back["edited"]
    assert "heard" not in json.loads(paths.transcript_json.read_text())[-1]

    with pytest.raises(api.NotFound):
        api.edit_line(tmp_path, MEETING, start=999.0, text="x")
    with pytest.raises(ValueError):
        api.edit_line(tmp_path, MEETING, start=line["start"], text="   ")


def test_http_edit_line(server):
    line = json.loads(_req(server, f"/api/meetings/{MEETING}")[2])["transcript"][0]
    status, _, body = _req(server, f"/api/meetings/{MEETING}/line", method="POST",
                           body={"start": line["start"], "text": "Hi Rico, welcome."})
    assert status == 200 and json.loads(body)["transcript"][0]["text"] == "Hi Rico, welcome."


def test_unsure_words_reach_the_window_until_the_line_is_edited(tmp_path: Path):
    paths = _meeting(tmp_path)
    transcript = json.loads(paths.transcript_json.read_text())
    transcript[2]["unsure"] = ["salary"]
    paths.transcript_json.write_text(json.dumps(transcript))
    line = api.get_meeting(tmp_path, MEETING, user_name="Timo")["transcript"][-1]
    assert line["unsure"] == ["salary"]
    api.edit_line(tmp_path, MEETING, start=line["start"], text="Thanks Rico, the salary band is fine!")
    assert api.get_meeting(tmp_path, MEETING, user_name="Timo")["transcript"][-1]["unsure"] == []


# --- undo ---------------------------------------------------------------

def _post(server, path, body=None):
    status, _, data = _req(server, path, method="POST", body={} if body is None else body)
    return status, json.loads(data)


def _next_meeting(root: Path, name: str = "2026-10-27T16-03-30") -> RecordingPaths:
    paths = _meeting(root, name)
    meta = json.loads(paths.meta.read_text())
    paths.meta.write_text(json.dumps({**meta, "start_time": "2026-10-27T16:03:30+01:00"}))
    return paths


def test_http_trash_can_be_undone(server):
    status, answer = _post(server, f"/api/meetings/{MEETING}/trash")
    assert status == 200 and answer["undo"]
    assert _req(server, f"/api/meetings/{MEETING}")[0] == 404
    assert _post(server, "/api/undo", {"token": answer["undo"]}) == (200, {"restored": [MEETING]})
    assert _req(server, f"/api/meetings/{MEETING}")[0] == 200


def test_http_join_can_be_undone(server, tmp_path: Path):
    other = _next_meeting(tmp_path)
    before = len(json.loads((tmp_path / MEETING / "transcript.json").read_text()))
    status, answer = _post(server, f"/api/meetings/{MEETING}/join", {"with": other.folder.name})
    assert status == 200 and answer["undo"]
    assert not other.folder.exists() or answer["id"] == other.folder.name
    joined = len(json.loads((tmp_path / answer["id"] / "transcript.json").read_text()))
    assert joined > before
    status, restored = _post(server, "/api/undo", {"token": answer["undo"]})
    assert status == 200 and sorted(restored["restored"]) == sorted([MEETING, other.folder.name])
    for name in (MEETING, other.folder.name):
        assert _req(server, f"/api/meetings/{name}")[0] == 200
        assert len(json.loads((tmp_path / name / "transcript.json").read_text())) == before
        assert sf.info(str(tmp_path / name / "system.wav")).frames == SR * 20


def test_http_split_can_be_undone(server, tmp_path: Path):
    status, answer = _post(server, f"/api/meetings/{MEETING}/split", {"at": 10})
    assert status == 200 and answer["undo"] and answer["rest"]
    assert answer["rest"] in [m["id"] for m in json.loads(_req(server, "/api/meetings")[2])]
    assert sf.info(str(tmp_path / MEETING / "system.wav")).frames == SR * 10
    assert _post(server, "/api/undo", {"token": answer["undo"]})[0] == 200
    assert [m["id"] for m in json.loads(_req(server, "/api/meetings")[2])] == [MEETING]
    assert sf.info(str(tmp_path / MEETING / "system.wav")).frames == SR * 20
    assert json.loads((tmp_path / MEETING / "meta.json").read_text())["duration_seconds"] == 20


def test_http_project_delete_can_be_undone(server):
    _, answer = _post(server, "/api/projects", {"name": "Hiring"})
    pid = answer["projects"][0]["id"]
    _post(server, f"/api/meetings/{MEETING}/projects", {"project": pid})
    status, answer = _post(server, f"/api/projects/{pid}/delete")
    assert status == 200 and answer["projects"] == [] and answer["undo"]
    assert _post(server, "/api/undo", {"token": answer["undo"]})[0] == 200
    projects = json.loads(_req(server, "/api/projects")[2])["projects"]
    assert [p["name"] for p in projects] == ["Hiring"]
    assert [m["id"] for m in projects[0]["meetings"]] == [MEETING]


def test_http_person_rename_can_be_undone(server):
    _post(server, f"/api/meetings/{MEETING}/speakers", {"label": "SPEAKER_00", "name": "Ana"})
    status, answer = _post(server, "/api/people/rename", {"old": "Ana", "new": "Anna"})
    assert status == 200 and answer["undo"]
    assert json.loads(_req(server, f"/api/meetings/{MEETING}")[2])["transcript"][1]["speaker"] == "Anna"
    assert _post(server, "/api/undo", {"token": answer["undo"]})[0] == 200
    assert json.loads(_req(server, f"/api/meetings/{MEETING}")[2])["transcript"][1]["speaker"] == "Ana"


def test_http_glossary_delete_can_be_undone(server):
    _, answer = _post(server, "/api/glossary/accept", {"term": "Genie", "variants": ["Tini"]})
    tid = next(iter(glossary.Glossary().terms()))
    status, answer = _post(server, f"/api/glossary/{tid}", {"delete": True})
    assert status == 200 and answer["undo"] and glossary.Glossary().terms() == {}
    assert _post(server, "/api/undo", {"token": answer["undo"]})[0] == 200
    assert list(glossary.Glossary().terms()) == [tid]


def test_http_undo_refused_after_the_meeting_changed(server):
    _, answer = _post(server, f"/api/meetings/{MEETING}/split", {"at": 10})
    _post(server, f"/api/meetings/{MEETING}/speakers", {"label": "SPEAKER_00", "name": "Ana"})
    status, error = _post(server, "/api/undo", {"token": answer["undo"]})
    assert status == 409 and "changed" in error["error"]


def test_http_older_split_undo_works_after_a_later_split_was_undone(server, tmp_path: Path):
    _, first = _post(server, f"/api/meetings/{MEETING}/split", {"at": 10})
    status, second = _post(server, f"/api/meetings/{MEETING}/split", {"at": 5, "join_next": True})
    assert status == 200 and second["joined"]
    assert _post(server, "/api/undo", {"token": second["undo"]})[0] == 200
    assert _post(server, "/api/undo", {"token": first["undo"]})[0] == 200
    assert [m["id"] for m in json.loads(_req(server, "/api/meetings")[2])] == [MEETING]
    assert sf.info(str(tmp_path / MEETING / "system.wav")).frames == SR * 20


def test_http_undo_unknown_token_is_404(server):
    status, error = _post(server, "/api/undo", {"token": "0" * 32})
    assert status == 404 and "can't undo" in error["error"]


def test_http_undo_with_a_meeting_still_being_processed(server, tmp_path: Path):
    waiting = tmp_path / "2026-10-27T17-00-00"
    waiting.mkdir()
    (waiting / "mic_raw.wav").write_bytes(b"")  # no transcript yet
    _post(server, f"/api/meetings/{MEETING}/speakers", {"label": "SPEAKER_00", "name": "Ana"})
    _, answer = _post(server, "/api/people/rename", {"old": "Ana", "new": "Anna"})
    assert _post(server, "/api/undo", {"token": answer["undo"]})[0] == 200
    assert json.loads(_req(server, f"/api/meetings/{MEETING}")[2])["transcript"][1]["speaker"] == "Ana"
    # trash it and undo
    status, answer = _post(server, "/api/meetings/2026-10-27T17-00-00/trash")
    assert status == 200
    assert _post(server, "/api/undo", {"token": answer["undo"]}) == (200, {"restored": ["2026-10-27T17-00-00"]})
    assert waiting.is_dir()


def test_http_undo_rename_after_one_meeting_was_trashed(server, tmp_path: Path):
    other = _next_meeting(tmp_path)
    for name in (MEETING, other.folder.name):
        _post(server, f"/api/meetings/{name}/speakers", {"label": "SPEAKER_00", "name": "Ana"})
    _, answer = _post(server, "/api/people/rename", {"old": "Ana", "new": "Anna"})
    _post(server, f"/api/meetings/{other.folder.name}/trash")
    status, restored = _post(server, "/api/undo", {"token": answer["undo"]})
    assert status == 200 and restored["restored"] == [MEETING]
    assert json.loads(_req(server, f"/api/meetings/{MEETING}")[2])["transcript"][1]["speaker"] == "Ana"
    assert "Ana" in json.loads(_req(server, "/api/names")[2])
    assert _post(server, "/api/undo", {"token": answer["undo"]})[0] == 404  # used up


def test_http_failed_change_leaves_no_snapshot(server, tmp_path: Path):
    status, _ = _post(server, f"/api/meetings/{MEETING}/split", {"at": 500})
    assert status >= 400
    assert not (tmp_path / ".trash" / ".undo").exists() or not list((tmp_path / ".trash" / ".undo").iterdir())


def test_http_glossary_undo_renders_the_markdown_again(server, tmp_path: Path):
    md = tmp_path / MEETING / "transcript.md"
    md.write_text("rendered")  # the glossary only re-renders a Markdown that exists
    _post(server, "/api/glossary/accept", {"term": "Rico Lanza", "variants": ["Rico"]})
    tid = next(iter(glossary.Glossary().terms()))
    _, answer = _post(server, f"/api/glossary/{tid}", {"delete": True})
    assert "Rico Lanza" not in md.read_text()
    _post(server, "/api/undo", {"token": answer["undo"]})
    assert "Rico Lanza" in md.read_text()


def _snapshots(root: Path) -> list[Path]:
    bin_ = root / ".trash" / ".undo"
    return list(bin_.iterdir()) if bin_.exists() else []


def test_http_change_failing_half_way_is_rolled_back(server, tmp_path: Path, monkeypatch):
    from palaver import cutting

    def half(paths, at):
        paths.system_turns.write_text("[]")
        (paths.folder / "system.wav").write_bytes(b"")
        raise RuntimeError("disk full")

    monkeypatch.setattr(cutting, "split", half)
    before = (tmp_path / MEETING / "system_turns.json").read_text()
    status, _ = _post(server, f"/api/meetings/{MEETING}/split", {"at": 10})
    assert status == 500
    assert (tmp_path / MEETING / "system_turns.json").read_text() == before
    assert sf.info(str(tmp_path / MEETING / "system.wav")).frames == SR * 20
    assert _snapshots(tmp_path) == []


def test_http_failed_rollback_keeps_the_snapshot(server, tmp_path: Path, monkeypatch):
    from palaver import cutting, undo

    def fail(*a, **k):
        raise RuntimeError("nope")

    monkeypatch.setattr(cutting, "split", fail)
    monkeypatch.setattr(undo, "restore", fail)
    assert _post(server, f"/api/meetings/{MEETING}/split", {"at": 10})[0] == 500
    assert len(_snapshots(tmp_path)) == 1


def _server_with(tmp_path: Path, calendar):
    import threading

    srv = make_server(App(tmp_path, "Timo", calendar=calendar), port=0)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def test_http_event_change_to_none_can_be_undone_exactly(tmp_path: Path):
    from datetime import datetime, timedelta

    from palaver import calendar_events as cal
    from palaver import projects

    paths = _meeting(tmp_path)
    start = datetime.fromisoformat(json.loads(paths.meta.read_text())["start_time"])
    cal.save(paths, cal.Event("Stored only", start, start + timedelta(minutes=30)))  # in no calendar any more
    stored = paths.calendar.read_text()
    store = projects.ProjectStore()
    pid = store.create("Hiring")
    store.assign(MEETING, pid, why="test")
    store.save()
    srv = _server_with(tmp_path, calendar=None)
    try:
        before = json.loads(_req(srv, f"/api/meetings/{MEETING}")[2])["projects"]
        status, answer = _post(srv, f"/api/meetings/{MEETING}/event", {"key": None})
        assert status == 200 and answer["calendar"] is None and answer["undo"]
        assert cal.dismissed(paths)
        assert _post(srv, "/api/undo", {"token": answer["undo"]}) == (200, {"restored": [MEETING]})
        assert paths.calendar.read_text() == stored
        assert json.loads(_req(srv, f"/api/meetings/{MEETING}")[2])["projects"] == before
    finally:
        srv.shutdown()
        srv.server_close()


def test_http_choosing_an_event_can_be_undone_to_nothing_stored(tmp_path: Path):
    from datetime import datetime, timedelta

    from palaver import calendar_events as cal
    from palaver import prep, projects

    paths = _meeting(tmp_path)
    start = datetime.fromisoformat(json.loads(paths.meta.read_text())["start_time"])
    planned = cal.Event("Planned", start, start + timedelta(minutes=30), uid="u1")
    store = projects.ProjectStore()
    pid = store.create("Hiring")
    store.save()
    prep.choose(planned, pid)  # chosen before the meeting: choosing the event gives the meeting this project
    srv = _server_with(tmp_path, calendar=lambda s, e: [planned])
    try:
        assert not paths.calendar.exists()
        key = json.loads(_req(srv, f"/api/meetings/{MEETING}/events")[2])[0]["key"]
        status, answer = _post(srv, f"/api/meetings/{MEETING}/event", {"key": key})
        assert status == 200 and answer["calendar"]["title"] == "Planned" and answer["undo"]
        assert [p["id"] for p in answer["projects"]] == [pid] and prep.chosen(planned) == []
        assert _post(srv, "/api/undo", {"token": answer["undo"]})[0] == 200
        assert not paths.calendar.exists() and not cal.dismissed(paths)  # matching by time stays possible
        assert json.loads(_req(srv, f"/api/meetings/{MEETING}")[2])["projects"] == []
        assert prep.chosen(planned) == [pid]
    finally:
        srv.shutdown()
        srv.server_close()


def test_http_merge_undo_puts_names_and_earlier_merges_back(server, tmp_path: Path):
    # A (SPEAKER_00) is "Henrik" and has C (SPEAKER_02) merged in; then A goes into the unnamed B (SPEAKER_01).
    _post(server, f"/api/meetings/{MEETING}/speakers", {"label": "SPEAKER_00", "name": "Henrik"})
    _post(server, f"/api/meetings/{MEETING}/merge", {"label": "SPEAKER_02", "into": "SPEAKER_00"})
    status, answer = _post(server, f"/api/meetings/{MEETING}/merge", {"label": "SPEAKER_00", "into": "SPEAKER_01"})
    assert status == 200 and answer["undo"]
    assert [s["label"] for s in answer["speakers"]] == [None, "SPEAKER_01"]
    assert answer["speakers"][1]["name"] == "Henrik"  # the merge moved the name

    assert _post(server, "/api/undo", {"token": answer["undo"]}) == (200, {"restored": [MEETING]})
    m = json.loads(_req(server, f"/api/meetings/{MEETING}")[2])
    a, b = m["speakers"][1], m["speakers"][2]
    assert (a["label"], a["name"]) == ("SPEAKER_00", "Henrik")
    assert (b["label"], b["name"]) == ("SPEAKER_01", None)
    assert a["merged"] == [{"label": "SPEAKER_02", "display": "Speaker 3"}]
    assert [(t["speaker"], t["label"]) for t in m["transcript"][1:]] == [
        ("Henrik", "SPEAKER_00"), ("Speaker 2", "SPEAKER_01")]


def test_http_splitting_off_a_merged_speaker_has_no_undo_token(server):
    _post(server, f"/api/meetings/{MEETING}/merge", {"label": "SPEAKER_01", "into": "SPEAKER_00"})
    status, answer = _post(server, f"/api/meetings/{MEETING}/merge", {"label": "SPEAKER_01", "into": None})
    assert status == 200 and "undo" not in answer


# --- a meeting's projects: undone from a snapshot, not by the inverse call ----------

OTHER = "2026-10-26T09-00-00"  # the same title and people as MEETING: its project is suggested


def _project_of(server, meeting: str) -> dict:
    m = json.loads(_req(server, f"/api/meetings/{meeting}")[2])
    return {"in": [(p["name"], p["by"]) for p in m["projects"]],
            "suggested": [s["name"] for s in m["project_suggestions"]],
            "all": [p["name"] for p in m["all_projects"]]}


def _undo(server, answer: dict):
    assert answer["undo"]
    assert _post(server, "/api/undo", {"token": answer["undo"]})[0] == 200


def _unsure(pid: str, meeting: str = MEETING):
    store = projects.ProjectStore()
    store.assign(meeting, pid, by="model", why="the same people")
    store.save()


def test_http_adding_a_suggested_project_undone_leaves_it_suggested(server, tmp_path: Path):
    _meeting(tmp_path, OTHER)
    _, answer = _post(server, "/api/projects", {"name": "Hiring"})
    pid = answer["projects"][0]["id"]
    _post(server, f"/api/meetings/{OTHER}/projects", {"project": pid})
    assert _project_of(server, MEETING)["suggested"] == ["Hiring"]
    status, answer = _post(server, f"/api/meetings/{MEETING}/projects", {"project": pid})
    assert status == 200 and answer["projects"][0]["name"] == "Hiring"
    _undo(server, answer)
    assert _project_of(server, MEETING) == {"in": [], "suggested": ["Hiring"], "all": ["Hiring"]}  # not rejected


def test_http_removing_an_unsure_project_undone_brings_it_back_unsure(server):
    _, answer = _post(server, "/api/projects", {"name": "Hiring"})
    pid = answer["projects"][0]["id"]
    _unsure(pid)
    _, answer = _post(server, f"/api/meetings/{MEETING}/projects", {"project": pid, "remove": True})
    assert answer["projects"] == []
    _undo(server, answer)
    assert _project_of(server, MEETING)["in"] == [("Hiring", "model")]


def test_http_adding_a_new_project_by_name_undone_removes_the_project(server):
    _, answer = _post(server, f"/api/meetings/{MEETING}/projects", {"name": "Hiring"})
    assert [p["name"] for p in answer["projects"]] == ["Hiring"]
    _undo(server, answer)
    assert _project_of(server, MEETING) == {"in": [], "suggested": [], "all": []}
    assert json.loads(_req(server, "/api/projects")[2])["projects"] == []


def test_http_confirming_a_project_undone_leaves_it_unsure(server):
    _, answer = _post(server, "/api/projects", {"name": "Hiring"})
    pid = answer["projects"][0]["id"]
    _unsure(pid)
    _, answer = _post(server, f"/api/meetings/{MEETING}/projects", {"project": pid})
    assert [(p["name"], p["by"]) for p in answer["projects"]] == [("Hiring", "you")]
    _undo(server, answer)
    assert _project_of(server, MEETING)["in"] == [("Hiring", "model")]


def _concurrent_notes(tmp_path, ids):
    import threading
    import time

    release, calls, state = threading.Event(), [], {"now": 0, "max": 0}
    lock = threading.Lock()

    def fake(mid):
        with lock:
            calls.append(mid)
            state["now"] += 1
            state["max"] = max(state["max"], state["now"])
        release.wait(5)
        with lock:
            state["now"] -= 1
        return True

    app = App(tmp_path, "Timo", write_notes=fake, run_projects=lambda a: True)
    srv = make_server(app, port=0)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    results = []
    threads = [threading.Thread(target=lambda m=m: results.append(
        _req(srv, f"/api/meetings/{m}/notes", method="POST", body={})[0])) for m in ids]
    for t in threads:
        t.start()
        time.sleep(0.2)
    release.set()
    for t in threads:
        t.join(10)
    srv.shutdown()
    srv.server_close()
    return calls, state["max"], results


def test_two_notes_requests_for_one_meeting_run_the_model_once(tmp_path):
    _meeting(tmp_path)
    calls, peak, results = _concurrent_notes(tmp_path, [MEETING, MEETING])
    assert calls == [MEETING] and results == [200, 200]


def test_notes_for_different_meetings_never_overlap(tmp_path):
    _meeting(tmp_path)
    other = "2026-10-22T10-00-00"
    _meeting(tmp_path, other)
    calls, peak, results = _concurrent_notes(tmp_path, [MEETING, other])
    assert sorted(calls) == sorted([MEETING, other]) and peak == 1 and results == [200, 200]


# --- final review: stores checked on undo; cuts that join on or discard -----------

def test_http_chip_undo_refused_after_a_project_rename(server):
    _, answer = _post(server, "/api/projects", {"name": "Hiring"})
    pid = answer["projects"][0]["id"]
    _, chip = _post(server, f"/api/meetings/{MEETING}/projects", {"project": pid})
    _post(server, f"/api/projects/{pid}", {"name": "Recruiting"})  # an unrelated later edit of the store
    status, error = _post(server, "/api/undo", {"token": chip["undo"]})
    assert status == 409 and "changed" in error["error"]
    assert [p["name"] for p in json.loads(_req(server, "/api/projects")[2])["projects"]] == ["Recruiting"]


def test_http_two_chip_changes_undone_in_order(server):
    _, answer = _post(server, "/api/projects", {"name": "Hiring"})
    pid = answer["projects"][0]["id"]
    _, first = _post(server, f"/api/meetings/{MEETING}/projects", {"project": pid})
    _, second = _post(server, f"/api/meetings/{MEETING}/projects", {"project": pid, "remove": True})
    _undo(server, second)
    assert _project_of(server, MEETING)["in"] == [("Hiring", "you")]
    _undo(server, first)
    assert _project_of(server, MEETING)["in"] == []


def _short_meeting(root: Path, name: str, start: str, seconds: int) -> RecordingPaths:
    paths = _meeting(root, name)
    t = np.arange(SR * seconds)
    sf.write(str(paths.system_wav), (3000 * np.sin(t / 5)).astype(np.int16), SR, subtype="PCM_16")
    sf.write(str(paths.mic_wav), (2000 * np.sin(t / 2)).astype(np.int16), SR, subtype="PCM_16")
    paths.meta.write_text(json.dumps({"start_time": start, "duration_seconds": seconds}))
    turns = [{"speaker": "SPEAKER_00", "start": 0.5, "end": seconds - 0.5}]
    paths.system_turns.write_text(json.dumps(turns))
    paths.transcript_json.write_text(json.dumps([Utterance("SPEAKER_00", 0.5, seconds - 0.5, "Later.").to_dict()]))
    return paths


def _state(root: Path, ids: list[str]) -> dict:
    return {i: (sf.info(str(root / i / "system.wav")).frames, json.loads((root / i / "transcript.json").read_text()),
                json.loads((root / i / "meta.json").read_text())) for i in ids}


def _ids(server) -> list[str]:
    return sorted(m["id"] for m in json.loads(_req(server, "/api/meetings")[2]))


@pytest.mark.parametrize("following_seconds, kept", [(20, "following"), (3, "tail")])
def test_http_split_joining_on_can_be_undone(server, tmp_path: Path, following_seconds, kept):
    after = "2026-10-27T16-03-30"
    _short_meeting(tmp_path, after, "2026-10-27T16:03:30+01:00", following_seconds)
    before = _state(tmp_path, [MEETING, after])
    status, answer = _post(server, f"/api/meetings/{MEETING}/split", {"at": 12, "join_next": True})
    assert status == 200 and answer["joined"] and answer["undo"]
    assert (answer["rest"] == after) == (kept == "following")  # the longer one keeps the meeting
    assert sf.info(str(tmp_path / MEETING / "system.wav")).frames == SR * 12
    status, restored = _post(server, "/api/undo", {"token": answer["undo"]})
    assert status == 200 and set(restored["restored"]) >= {MEETING, after}
    assert _ids(server) == sorted([MEETING, after])
    assert _state(tmp_path, [MEETING, after]) == before
    assert not list((tmp_path / ".trash").glob("*.undone-*/*.wav"))  # the undone audio is not kept twice


@pytest.mark.parametrize("side", ["before", "after"])
def test_http_discarding_part_of_a_meeting_can_be_undone(server, tmp_path: Path, side):
    before = _state(tmp_path, [MEETING])
    status, answer = _post(server, f"/api/meetings/{MEETING}/split", {"at": 12, "discard": side})
    assert status == 200 and answer["discarded"] == side and answer["undo"]
    assert sf.info(str(tmp_path / MEETING / "system.wav")).frames == SR * (12 if side == "after" else 8)
    assert _post(server, "/api/undo", {"token": answer["undo"]}) == (200, {"restored": [MEETING]})
    assert _ids(server) == [MEETING]
    assert _state(tmp_path, [MEETING]) == before


# --- a meeting still being transcribed is not trashed or put back in the review ------

def test_http_a_meeting_being_processed_is_not_trashed_or_reviewed_again(server, tmp_path: Path, monkeypatch):
    api.mark_reviewed(tmp_path, MEETING)
    monkeypatch.setattr(api, "_status", lambda paths: "processing")
    status, error = _post(server, f"/api/meetings/{MEETING}/trash")
    assert status == 400 and error["error"] == (
        "This meeting is still being transcribed. It can go to the trash once that is done.")
    assert (tmp_path / MEETING).is_dir()
    status, error = _post(server, f"/api/meetings/{MEETING}/reviewed", {"done": False})
    assert status == 400 and error["error"] == (
        "This meeting is still being transcribed. It can be reviewed again once that is done.")
    assert (tmp_path / MEETING / "review.json").exists()
    assert _post(server, f"/api/meetings/{MEETING}/reviewed", {"done": True})[0] == 200  # marking it done is fine


# --- every change on the Projects and Glossary pages can be undone -----------------

def _project(server) -> dict:
    [p] = json.loads(_req(server, "/api/projects")[2])["projects"]
    return p


def test_http_project_rename_can_be_undone(server):
    _post(server, "/api/projects", {"name": "Hiring"})
    pid = _project(server)["id"]
    status, answer = _post(server, f"/api/projects/{pid}", {"name": "Recruiting"})
    assert status == 200 and answer["projects"][0]["name"] == "Recruiting"
    _undo(server, answer)
    assert _project(server)["name"] == "Hiring"


def test_http_project_description_can_be_undone(server):
    _post(server, "/api/projects", {"name": "Hiring", "description": "Old words."})
    pid = _project(server)["id"]
    status, answer = _post(server, f"/api/projects/{pid}", {"description": "New words."})
    assert status == 200 and answer["projects"][0]["description"] == "New words."
    _undo(server, answer)
    assert _project(server)["description"] == "Old words."


def _model_server(tmp_path: Path, run):
    import threading

    _meeting(tmp_path)
    srv = make_server(App(tmp_path, "Timo", run_projects=run), port=0)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def _sort(args):
    store = projects.ProjectStore()
    store.assign(MEETING, store.create("Hiring"), by="model", why="the title")
    store.save()
    return True


def test_http_sorting_with_the_model_can_be_undone(tmp_path: Path):
    srv = _model_server(tmp_path, _sort)
    try:
        status, answer = _post(srv, "/api/projects/suggest")
        assert status == 200 and [p["name"] for p in answer["projects"]] == ["Hiring"]
        _undo(srv, answer)
        assert json.loads(_req(srv, "/api/projects")[2])["projects"] == []
    finally:
        srv.shutdown()
        srv.server_close()


def test_http_describing_with_the_model_can_be_undone(tmp_path: Path):
    def describe(args):
        store = projects.ProjectStore()
        store.update(args[1], description="Written by the model.")
        store.save()
        return True

    srv = _model_server(tmp_path, describe)
    try:
        pid = _post(srv, "/api/projects", {"name": "Hiring"})[1]["projects"][0]["id"]
        status, answer = _post(srv, f"/api/projects/{pid}/describe")
        assert status == 200 and answer["projects"][0]["description"] == "Written by the model."
        _undo(srv, answer)
        assert json.loads(_req(srv, "/api/projects")[2])["projects"][0]["description"] == ""
    finally:
        srv.shutdown()
        srv.server_close()


def test_http_a_failed_model_run_is_rolled_back(tmp_path: Path):
    srv = _model_server(tmp_path, lambda args: _sort(args) and False)  # changed some, then failed
    try:
        status, _ = _post(srv, "/api/projects/suggest")
        assert status == 502
        assert json.loads(_req(srv, "/api/projects")[2])["projects"] == []
        assert _snapshots(tmp_path) == []
    finally:
        srv.shutdown()
        srv.server_close()


def _term(server) -> dict:
    [t] = json.loads(_req(server, "/api/glossary")[2])["terms"]
    return t


def test_http_term_rename_can_be_undone(server):
    _post(server, "/api/glossary/accept", {"term": "Genie", "variants": ["Tini"]})
    tid = _term(server)["id"]
    status, answer = _post(server, f"/api/glossary/{tid}", {"term": "Jeanie"})
    assert status == 200 and answer["terms"][0]["term"] == "Jeanie"
    _undo(server, answer)
    assert _term(server)["term"] == "Genie"


def test_http_term_note_can_be_undone(server):
    _post(server, "/api/glossary/accept", {"term": "Genie", "variants": ["Tini"], "note": "the bot"})
    tid = _term(server)["id"]
    status, answer = _post(server, f"/api/glossary/{tid}", {"note": "the lamp"})
    assert status == 200 and answer["terms"][0]["note"] == "the lamp"
    _undo(server, answer)
    assert _term(server)["note"] == "the bot"


def test_http_not_this_can_be_undone(server):
    status, answer = _post(server, "/api/glossary/reject", {"key": "term:rico"})
    assert status == 200 and "term:rico" in glossary.Glossary().rejected()
    _undo(server, answer)
    assert "term:rico" not in glossary.Glossary().rejected()


def test_http_not_this_takes_several_spellings_at_once(server):
    # A card's "Not this" goes for each of its spellings, or the rest come back.
    keys = ["variant:kein:timo", "variant:kino:timo"]
    status, answer = _post(server, "/api/glossary/reject", {"keys": keys})
    assert status == 200 and set(keys) <= glossary.Glossary().rejected()
    _undo(server, answer)
    assert not set(keys) & glossary.Glossary().rejected()


def _hold_model(path: Path):
    """Another process using the language model: its flock on the lock file."""
    import fcntl

    f = open(path, "a")
    fcntl.flock(f, fcntl.LOCK_EX)
    return f


def test_http_sorting_while_the_model_is_busy_answers_409_before_any_snapshot(tmp_path: Path, notes_lock_in_tmp):
    runs = []
    srv = _model_server(tmp_path, lambda args: runs.append(args) or True)
    holder = _hold_model(notes_lock_in_tmp)
    try:
        before = (projects._default_path().read_bytes() if projects._default_path().exists() else None)
        status, body = _post(srv, "/api/projects/suggest")
        assert status == 409 and "the language model is busy; try again in a minute" in json.dumps(body)
        assert runs == [] and _snapshots(tmp_path) == []
        assert (projects._default_path().read_bytes() if projects._default_path().exists() else None) == before
    finally:
        holder.close()
        srv.shutdown()
        srv.server_close()


def test_http_the_model_taken_after_the_check_answers_409_and_rolls_back(tmp_path: Path):
    from palaver.cli import ModelBusy

    def busy(args):
        raise ModelBusy

    srv = _model_server(tmp_path, busy)
    try:
        status, body = _post(srv, "/api/projects/suggest")
        assert status == 409 and "the language model is busy" in json.dumps(body)
        assert _snapshots(tmp_path) == []
    finally:
        srv.shutdown()
        srv.server_close()


def test_http_sorting_with_a_free_model_still_remembers_an_undo(tmp_path: Path):
    srv = _model_server(tmp_path, _sort)
    try:
        status, answer = _post(srv, "/api/projects/suggest")
        assert status == 200 and answer.get("undo")
    finally:
        srv.shutdown()
        srv.server_close()


# --- the running recording's question (issue #52) ---------------------------

class _Recording:
    def __init__(self, question=None, why=None):
        self.asked, self.answers, self.why = question, [], why

    def question(self):
        return self.asked

    def recording(self):
        return self.why

    def answer(self, choice, meeting):
        self.answers.append((choice, meeting))
        return meeting == MEETING


def _recording_server(tmp_path: Path, recording):
    import threading

    _meeting(tmp_path)
    srv = make_server(App(tmp_path, "Timo", recording=recording), port=0)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def test_http_the_recording_question_and_its_answers(tmp_path: Path):
    asked = {"meeting": MEETING, "reason": "teams", "minutes": 10, "message": "Stop recording?"}
    rec = _Recording(asked)
    srv = _recording_server(tmp_path, rec)
    try:
        status, _, body = _req(srv, "/api/recording/question")
        assert status == 200 and json.loads(body) == {"question": asked, "recording": None}
        assert _post(srv, "/api/recording/keep", {"meeting": MEETING}) == (200, {"kept": MEETING})
        assert _post(srv, "/api/recording/stop", {"meeting": MEETING}) == (200, {"stopped": MEETING})
        assert rec.answers == [("keep", MEETING), ("stop", MEETING)]
        status, answer = _post(srv, "/api/recording/stop", {"meeting": "2026-10-27T09-00-00"})
        assert status == 400 and "no longer" in answer["error"]
        assert _post(srv, "/api/recording/stop", {})[0] == 400
    finally:
        srv.shutdown()
        srv.server_close()


def test_http_no_recording_question_outside_the_menu_bar_app(tmp_path: Path):
    srv = _recording_server(tmp_path, None)
    try:
        assert json.loads(_req(srv, "/api/recording/question")[2]) == {"question": None, "recording": None}
        assert _post(srv, "/api/recording/stop", {"meeting": MEETING})[0] == 400
    finally:
        srv.shutdown()
        srv.server_close()


# --- the language model (#53) ---------------------------------------------------------

KEY = "sk-ant-api03-SECRET-abcdefghijklmnop"


def _cloud_answers(monkeypatch, reply=None, status=200):
    """Requests to cloud providers go to a fake; returns what was sent."""
    from palaver import cloud_llm

    sent = []

    def transport(request):
        sent.append(request)
        body = {"content": [{"type": "text", "text": json.dumps({"reply": reply or "Hello there"})}],
                "stop_reason": "end_turn"} if status == 200 else {"error": {"message": f"invalid x-api-key {KEY}"}}
        return cloud_llm.Response(status, {}, json.dumps(body).encode())

    monkeypatch.setattr(cloud_llm, "default_transport", transport)
    return sent


def test_language_model_page_starts_local_and_says_what_goes_where():
    lm = api.language_model(None)
    assert [f["id"] for f in lm["features"]] == ["notes", "projects", "coach"]
    assert all(f["choice"] == "local" and f["sends"] for f in lm["features"])
    assert [p["id"] for p in lm["providers"]] == ["anthropic", "openai", "claude-cli"]
    assert lm["local"]["model"] == notes.DEFAULT_LOCAL_MODEL
    assert {m["repo"] for m in lm["local"]["models"]} >= {notes.DEFAULT_LOCAL_MODEL}
    assert lm["log"] == []


def test_config_toml_choices_show_as_the_default():
    cfg = type("Cfg", (), {"notes_engine": "claude", "notes_model": "opus", "notes_local_model": "someone/else",
                           "claude_path": None})()
    lm = api.language_model(cfg)
    assert [f["choice"] for f in lm["features"]] == ["claude-cli", "claude-cli", "local"]  # the coach: its own
    assert next(p for p in lm["providers"] if p["id"] == "claude-cli")["model"] == "opus"
    assert lm["local"]["model"] == "someone/else"
    assert "someone/else" in [m["repo"] for m in lm["local"]["models"]]  # shown though not in the list


def test_set_key_never_comes_back_to_the_page(fake_keychain):
    lm = api.set_provider_key(None, {"provider": "anthropic", "key": KEY})
    assert fake_keychain == {"anthropic.api_key": KEY}
    anthropic = next(p for p in lm["providers"] if p["id"] == "anthropic")
    assert anthropic["key_set"] is True and anthropic["ready"] is True
    assert KEY not in json.dumps(lm)
    lm = api.set_provider_key(None, {"provider": "anthropic", "remove": True})
    assert fake_keychain == {} and not next(p for p in lm["providers"] if p["id"] == "anthropic")["key_set"]


def test_choosing_a_provider_needs_it_set_up():
    with pytest.raises(api.Refused, match="API key"):
        api.set_language_model(None, {"use": {"notes": "anthropic"}})
    api.set_provider_key(None, {"provider": "anthropic", "key": KEY})
    lm = api.set_language_model(None, {"use": {"notes": "anthropic"}})
    assert [f["choice"] for f in lm["features"]] == ["anthropic", "local", "local"]


def test_provider_settings_and_the_local_model():
    lm = api.set_language_model(None, {"provider": "openai", "endpoint": "https://acme.openai.azure.com/openai/v1",
                                       "model": "gpt-x", "context_tokens": 200000})
    openai = next(p for p in lm["providers"] if p["id"] == "openai")
    assert openai["endpoint"] == "https://acme.openai.azure.com/openai/v1" and openai["model"] == "gpt-x"
    assert openai["ready"] is False and openai["problem"] == "Add the API key"  # a remote endpoint needs one
    lm = api.set_language_model(None, {"provider": "openai", "auth": "api-key"})
    assert next(p for p in lm["providers"] if p["id"] == "openai")["auth"] == "api-key"
    with pytest.raises(api.Refused):
        api.set_language_model(None, {"provider": "openai", "endpoint": "http://evil.example.com"})
    lm = api.set_language_model(None, {"local_model": "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"})
    assert lm["local"]["model"] == "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"


def test_test_button(monkeypatch):
    sent = _cloud_answers(monkeypatch)
    api.set_provider_key(None, {"provider": "anthropic", "key": KEY})
    result = api.test_provider(None, {"provider": "anthropic"})
    assert result["answer"] == "Hello there" and result["seconds"] >= 0 and len(sent) == 1
    assert api.language_model(None)["log"][0]["feature"] == "test"


def test_meeting_can_be_kept_on_this_mac(tmp_path: Path):
    _meeting(tmp_path)
    assert api.get_meeting(tmp_path, MEETING, user_name="Timo")["local_only"] is False
    api.set_local_only(tmp_path, MEETING, True)
    assert api.get_meeting(tmp_path, MEETING, user_name="Timo")["local_only"] is True
    assert (tmp_path / MEETING / "local_only.json").exists()
    api.set_local_only(tmp_path, MEETING, False)
    assert api.get_meeting(tmp_path, MEETING, user_name="Timo")["local_only"] is False


def test_http_language_model(server, monkeypatch, fake_keychain):
    status, _, body = _req(server, "/api/language-model")
    assert status == 200 and json.loads(body)["features"][0]["choice"] == "local"
    status, _, body = _req(server, "/api/language-model", method="POST", body={"use": {"notes": "anthropic"}})
    assert status == 400 and "API key" in json.loads(body)["error"]
    status, _, body = _req(server, "/api/language-model/key", method="POST", body={"provider": "anthropic", "key": KEY})
    assert status == 200 and KEY.encode() not in body and fake_keychain["anthropic.api_key"] == KEY
    status, _, body = _req(server, "/api/language-model", method="POST", body={"use": {"notes": "anthropic"}})
    assert status == 200 and json.loads(body)["features"][0]["choice"] == "anthropic"

    sent = _cloud_answers(monkeypatch)
    status, _, body = _req(server, "/api/language-model/test", method="POST", body={"provider": "anthropic"})
    assert status == 200 and json.loads(body)["answer"] == "Hello there" and len(sent) == 1

    _cloud_answers(monkeypatch, status=401)
    status, _, body = _req(server, "/api/language-model/test", method="POST", body={"provider": "anthropic"})
    assert status == 502 and "401" in json.loads(body)["error"] and KEY.encode() not in body
    status, _, body = _req(server, "/api/language-model")
    assert KEY.encode() not in body  # nor in the access log shown

    status, _, body = _req(server, f"/api/meetings/{MEETING}/local-only", method="POST", body={"on": True})
    assert status == 200 and json.loads(body)["local_only"] is True


def test_http_a_bad_key_request_does_not_echo_it(server, fake_keychain):
    status, _, body = _req(server, "/api/language-model/key", method="POST",
                           body={"provider": "claude-cli", "key": KEY})
    assert status == 400 and KEY.encode() not in body and fake_keychain == {}
    status, _, body = _req(server, "/api/language-model/key", method="POST",
                           body={"provider": "anthropic", "key": "two\nlines " + KEY})
    assert status == 400 and KEY.encode() not in body and fake_keychain == {}


# --- why it records, why it stopped, where it paused (issue #47) ---------------


def test_http_says_why_the_running_recording_records(tmp_path: Path):
    why = {"meeting": MEETING, "text": "Recording · Teams call since 16:03 · mic AirPods (24 kHz)"}
    srv = _recording_server(tmp_path, _Recording(why=why))
    try:
        assert json.loads(_req(srv, "/api/recording/question")[2]) == {"question": None, "recording": why}
    finally:
        srv.shutdown()
        srv.server_close()


def test_a_meeting_says_how_it_was_recorded_and_where_it_paused(tmp_path: Path):
    paths = _meeting(tmp_path)
    meta = json.loads(paths.meta.read_text())
    paths.meta.write_text(json.dumps({**meta, "end_time": "2026-10-27T16:03:27+01:00", "trigger": "teams",
                                      "stop_reason": "call_ended",
                                      "gaps": [{"start": 12.0, "end": 12.5, "why": "restart"}]}))
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert m["recorded"] == "Teams call detected 16:03 · Teams call ended 16:03 · Palaver restarted — continued"
    assert m["gaps"] == [{"start": 12.0, "end": 12.5,
                          "text": "Recording paused 16:03:19–16:03:19 (Palaver restarted)"}]


def test_a_part_cut_by_a_restart_says_it_is_continued(tmp_path: Path):
    paths = _meeting(tmp_path)
    meta = json.loads(paths.meta.read_text())
    paths.meta.write_text(json.dumps({**meta, "end_time": "2026-10-27T16:03:27+01:00", "trigger": "teams",
                                      "stop_reason": "restart"}))
    assert api.get_meeting(tmp_path, MEETING, user_name="Timo")["recorded"] == (
        "Teams call detected 16:03 · Palaver restarted 16:03")
    paths.parts.write_text(json.dumps({"parts": ["2026-10-27T16-03-40"]}))
    assert api.get_meeting(tmp_path, MEETING, user_name="Timo")["recorded"].endswith("Palaver restarted 16:03 — continued")
    assert api.get_meeting(tmp_path, MEETING, user_name="Timo")["gaps"] == []


def test_a_meeting_says_when_its_audio_went_wrong(tmp_path: Path):
    """Issue #50: "Audio problem at 16:04 (system audio played at the wrong speed)"."""
    paths = _meeting(tmp_path)
    meta = json.loads(paths.meta.read_text())
    paths.meta.write_text(json.dumps({**meta, "audio_problems": [
        {"kind": "speed", "track": "system", "start": 60.0, "end": 75.0}]}))
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert m["audio_problems"] == [{"start": 60.0, "end": 75.0,
                                    "text": "Audio problem at 16:04 (system audio played at the wrong speed)"}]
    paths.meta.write_text(json.dumps(meta))
    assert api.get_meeting(tmp_path, MEETING, user_name="Timo")["audio_problems"] == []


# --- transcription (#54) -----------------------------------------------------------------

ASR_KEY = "aai-SECRET-abcdefghijklmnopqrstuvwxyz0123"


def _assemblyai_answers(monkeypatch, *, refuse=False):
    """AssemblyAI's API as a fake transport; returns the requests sent."""
    from palaver import cloud_llm

    sent = []

    def transport(request):
        sent.append(request)
        if refuse:
            return cloud_llm.Response(401, {}, json.dumps({"error": f"Invalid API key {ASR_KEY}"}).encode())
        if request.url.endswith("/v2/upload"):
            body = {"upload_url": "https://cdn.assemblyai.test/u/1"}
        elif request.method == "POST":
            body = {"id": "t1", "status": "queued"}
        else:
            body = {"id": "t1", "status": "completed", "words": [], "audio_duration": 2}
        return cloud_llm.Response(200, {}, json.dumps(body).encode())

    monkeypatch.setattr(cloud_llm, "default_transport", transport)
    return sent


def test_transcription_page_starts_local_and_says_what_goes_where():
    tr = api.transcription(None)
    assert tr["feature"]["choice"] == "local" and "system track" in tr["feature"]["sends"]
    assert [p["id"] for p in tr["providers"]] == ["assemblyai", "soniox", "mistral", "openai-transcribe"]
    assert all(p["privacy"] for p in tr["providers"])
    assert next(p for p in tr["providers"] if p["id"] == "assemblyai")["region"] == "eu"
    assert tr["month"]["seconds"] == 0
    # The language model page keeps to language models.
    lm = api.language_model(None)
    assert "transcription" not in [f["id"] for f in lm["features"]]
    assert "assemblyai" not in [p["id"] for p in lm["providers"]]
    assert lm["labels"]["assemblyai"] == "AssemblyAI"  # for the shared access log


def test_transcription_choice_key_region_and_test(monkeypatch, fake_keychain):
    with pytest.raises(api.Refused, match="API key"):
        api.set_transcription(None, {"use": "assemblyai"})
    tr = api.set_transcription_key(None, {"provider": "assemblyai", "key": ASR_KEY})
    assert fake_keychain == {"assemblyai.api_key": ASR_KEY} and ASR_KEY not in json.dumps(tr)
    tr = api.set_transcription(None, {"use": "assemblyai"})
    assert tr["feature"]["choice"] == "assemblyai"
    tr = api.set_transcription(None, {"provider": "assemblyai", "region": "us", "model": "universal-2"})
    a = next(p for p in tr["providers"] if p["id"] == "assemblyai")
    assert a["region"] == "us" and a["model"] == "universal-2"
    with pytest.raises(api.Refused):
        api.set_transcription(None, {"provider": "assemblyai", "region": "moon"})
    with pytest.raises(api.Refused):
        api.set_transcription(None, {"use": "anthropic"})
    sent = _assemblyai_answers(monkeypatch)
    result = api.test_transcription(None, {"provider": "assemblyai"})
    assert result["model"] == "universal-2" and result["usd_per_hour"] > 0
    assert sent[0].url == "https://api.assemblyai.com/v2/upload"
    assert api.transcription(None)["log"][0]["feature"] == "test"


def test_http_transcription(server, monkeypatch, fake_keychain):
    status, _, body = _req(server, "/api/transcription")
    assert status == 200 and json.loads(body)["feature"]["choice"] == "local"
    status, _, body = _req(server, "/api/transcription", method="POST", body={"use": "soniox"})
    assert status == 400 and "API key" in json.loads(body)["error"]
    status, _, body = _req(server, "/api/transcription/key", method="POST",
                           body={"provider": "assemblyai", "key": ASR_KEY})
    assert status == 200 and ASR_KEY.encode() not in body
    status, _, body = _req(server, "/api/transcription", method="POST", body={"use": "assemblyai"})
    assert status == 200 and json.loads(body)["feature"]["choice"] == "assemblyai"
    _assemblyai_answers(monkeypatch, refuse=True)
    status, _, body = _req(server, "/api/transcription/test", method="POST", body={"provider": "assemblyai"})
    assert status == 502 and "refused the API key" in json.loads(body)["error"] and ASR_KEY.encode() not in body
    status, _, body = _req(server, "/api/transcription")
    assert ASR_KEY.encode() not in body


def test_meeting_says_which_service_transcribed_it(tmp_path: Path):
    from palaver import transcription

    _meeting(tmp_path)
    paths = RecordingPaths(tmp_path / MEETING)
    assert api.get_meeting(tmp_path, MEETING, user_name="Timo")["transcribed_by"] is None
    transcription.write_marker(paths, "system", engine="local", fallback_from="soniox", error="HTTP 503")
    t = api.get_meeting(tmp_path, MEETING, user_name="Timo")["transcribed_by"]
    assert t["engine"] == "local" and t["fallback_label"] == "Soniox" and t["error"] == "HTTP 503"
    transcription.write_marker(paths, "system", engine="assemblyai", sent_seconds=60.0, usd=0.0047)
    t = api.get_meeting(tmp_path, MEETING, user_name="Timo")["transcribed_by"]
    assert t["label"] == "AssemblyAI" and t["sent_seconds"] == 60.0


# --- the user's own notes (#44) -------------------------------------------------------------

def _png() -> bytes:
    import io

    from PIL import Image

    out = io.BytesIO()
    Image.new("RGB", (40, 20), "white").save(out, format="PNG")
    return out.getvalue()


def _upload(server, base: str, data: bytes) -> tuple[int, dict]:
    import base64

    return _post(server, f"{base}/my-notes/images", {"data": base64.b64encode(data).decode()})


@pytest.fixture
def no_vision(monkeypatch):
    """The server reads pasted images in the background: here with a fake."""
    from palaver import my_notes

    read = []
    monkeypatch.setattr(my_notes, "recognize_text", lambda path: read.append(path.name) or "Slide: Budget Q3")
    return read


def _wait_for(check, seconds=5.0):
    deadline = time.monotonic() + seconds
    while not check():
        assert time.monotonic() < deadline, "timed out"
        time.sleep(0.02)


def _save_notes(server, base: str, paragraphs: list) -> tuple[int, dict]:
    """A save from an editor that has just read the notes."""
    revision = json.loads(_req(server, f"{base}/my-notes")[2])["revision"]
    return _post(server, f"{base}/my-notes", {"paragraphs": paragraphs, "revision": revision})


def test_http_my_notes_are_saved_and_read_back(server, tmp_path: Path):
    base = f"/api/meetings/{MEETING}"
    assert json.loads(_req(server, f"{base}/my-notes")[2]) == {"paragraphs": [], "images": {}, "revision": ""}
    doc = [{"text": "Ask about the **budget**", "at": None}, {"text": "- yes", "at": 4.5}]
    status, answer = _save_notes(server, base, doc)
    assert status == 200 and answer["saved"] == 2 and answer["revision"]
    assert api.get_meeting(tmp_path, MEETING, user_name="Timo")["my_notes_revision"] == answer["revision"]
    assert json.loads(_req(server, f"{base}/my-notes")[2])["paragraphs"] == doc
    assert json.loads((tmp_path / MEETING / "my-notes.json").read_text()) == doc


def test_http_my_notes_refuse_garbage(server, tmp_path: Path):
    base = f"/api/meetings/{MEETING}"
    _save_notes(server, base, [{"text": "kept", "at": None}])
    revision = json.loads(_req(server, f"{base}/my-notes")[2])["revision"]
    assert _post(server, f"{base}/my-notes", {"paragraphs": []})[0] == 400  # a save says what it was based on
    for body in ({"revision": revision}, {"paragraphs": "x", "revision": revision},
                 {"paragraphs": [{"text": 1, "at": None}], "revision": revision},
                 {"paragraphs": [{"text": "", "at": None, "image": "../meta.json"}], "revision": revision}):
        assert _post(server, f"{base}/my-notes", body)[0] == 400
    assert _post(server, "/api/meetings/2026-01-01T00-00-00/my-notes", {"paragraphs": [], "revision": ""})[0] == 404
    assert json.loads((tmp_path / MEETING / "my-notes.json").read_text()) == [{"text": "kept", "at": None}]


def test_http_a_pasted_image_is_stored_served_and_read(server, tmp_path: Path, no_vision):
    base = f"/api/meetings/{MEETING}"
    status, answer = _upload(server, base, _png())
    assert status == 200
    name = answer["name"]
    assert (tmp_path / MEETING / "my-notes" / name).read_bytes() == _png()
    status, headers, body = _req(server, f"{base}/my-notes/images/{name}")
    assert status == 200 and headers["Content-Type"] == "image/png" and body == _png()
    _wait_for(lambda: (tmp_path / MEETING / "my-notes" / f"{name}.txt").exists())
    _save_notes(server, base, [{"text": "", "at": 3, "image": name}])
    assert json.loads(_req(server, f"{base}/my-notes")[2])["images"] == {name: {"text": "Slide: Budget Q3"}}
    assert no_vision == [name]


def test_http_only_images_and_only_image_names(server, no_vision):
    import base64

    base = f"/api/meetings/{MEETING}"
    assert _upload(server, base, b"<svg/>")[0] == 400
    assert _post(server, f"{base}/my-notes/images", {"data": "not base64 !!"})[0] == 400
    assert _post(server, f"{base}/my-notes/images", {"data": base64.b64encode(b"x").decode() * 0})[0] == 400
    assert _req(server, f"{base}/my-notes/images/meta.json")[0] == 404
    assert _req(server, f"{base}/my-notes/images/img-0123456789ab.png")[0] == 404
    assert _req(server, f"{base}/my-notes/images/..%2Fmeta.json")[0] == 404


def test_http_deleting_an_image_can_be_undone(server, tmp_path: Path, no_vision):
    base = f"/api/meetings/{MEETING}"
    name = _upload(server, base, _png())[1]["name"]
    _wait_for(lambda: (tmp_path / MEETING / "my-notes" / f"{name}.txt").exists())
    doc = [{"text": "before", "at": 1}, {"text": "", "at": 2, "image": name}, {"text": "after", "at": 3}]
    _save_notes(server, base, doc)
    status, answer = _post(server, f"{base}/my-notes/images/{name}/delete")
    assert status == 200 and answer["undo"]
    assert answer["paragraphs"] == [doc[0], doc[2]] and answer["images"] == {}
    assert not (tmp_path / MEETING / "my-notes" / name).exists()
    assert _post(server, "/api/undo", {"token": answer["undo"]})[0] == 200
    again = json.loads(_req(server, f"{base}/my-notes")[2])
    assert again["paragraphs"] == doc and again["images"] == {name: {"text": "Slide: Budget Q3"}}
    assert _post(server, f"{base}/my-notes/images/img-0123456789ab.png/delete")[0] == 404


def test_http_undoing_a_delete_keeps_what_was_typed_since(server, tmp_path: Path, no_vision):
    base = f"/api/meetings/{MEETING}"
    name = _upload(server, base, _png())[1]["name"]
    _wait_for(lambda: (tmp_path / MEETING / "my-notes" / f"{name}.txt").exists())
    _save_notes(server, base, [{"text": "before", "at": 1}, {"text": "", "at": 2, "image": name}])
    answer = _post(server, f"{base}/my-notes/images/{name}/delete")[1]
    _save_notes(server, base, [{"text": "before", "at": 1}, {"text": "typed since", "at": 9}])
    assert _post(server, "/api/undo", {"token": answer["undo"]})[0] == 200
    doc = json.loads(_req(server, f"{base}/my-notes")[2])
    assert doc["paragraphs"] == [{"text": "before", "at": 1}, {"text": "", "at": 2, "image": name},
                                 {"text": "typed since", "at": 9}]
    assert doc["images"] == {name: {"text": "Slide: Budget Q3"}}


def test_http_clearing_my_notes_can_be_undone_also_after_typing(server, tmp_path: Path, no_vision):
    base = f"/api/meetings/{MEETING}"
    name = _upload(server, base, _png())[1]["name"]
    _wait_for(lambda: (tmp_path / MEETING / "my-notes" / f"{name}.txt").exists())
    doc = [{"text": "mine", "at": None}, {"text": "", "at": 2, "image": name}]
    _save_notes(server, base, doc)
    status, answer = _post(server, f"{base}/my-notes/clear")
    assert status == 200 and answer["paragraphs"] == [] and not (tmp_path / MEETING / "my-notes.json").exists()
    _post(server, "/api/undo", {"token": answer["undo"]})
    assert json.loads(_req(server, f"{base}/my-notes")[2])["paragraphs"] == doc

    answer = _post(server, f"{base}/my-notes/clear")[1]
    _save_notes(server, base, [{"text": "new words", "at": 30}])
    assert _post(server, "/api/undo", {"token": answer["undo"]})[0] == 200  # put back beside the new words
    assert json.loads(_req(server, f"{base}/my-notes")[2])["paragraphs"] == [
        {"text": "mine", "at": None}, {"text": "", "at": 2, "image": name}, {"text": "new words", "at": 30}]


def test_http_a_save_on_an_old_revision_is_refused_with_the_notes_as_they_are(server):
    base = f"/api/meetings/{MEETING}"
    old = json.loads(_req(server, f"{base}/my-notes")[2])["revision"]
    _save_notes(server, base, [{"text": "from the other window", "at": None}])
    status, answer = _post(server, f"{base}/my-notes", {"paragraphs": [{"text": "mine", "at": None}], "revision": old})
    assert status == 409 and answer["document"]["paragraphs"] == [{"text": "from the other window", "at": None}]
    assert answer["document"]["revision"] and answer["error"]


def test_http_bodies_are_capped_before_they_are_read(server):
    import http.client

    port = server.server_address[1]
    for path, size in ((f"/api/meetings/{MEETING}/my-notes", 3 * 1024 * 1024),
                       (f"/api/meetings/{MEETING}/my-notes/images", 40 * 1024 * 1024)):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        conn.putrequest("POST", path)
        conn.putheader("Host", f"127.0.0.1:{port}")
        conn.putheader("Content-Type", "application/json")
        conn.putheader("Content-Length", str(size))
        conn.endheaders()
        conn.send(b"{}")
        assert conn.getresponse().status == 413
        conn.close()


def test_picking_the_event_brings_its_prepared_notes_and_undo_takes_them_back(tmp_path: Path):
    from datetime import datetime, timedelta

    from palaver import calendar_events as cal
    from palaver import my_notes

    paths = _meeting(tmp_path)
    start = datetime.fromisoformat("2026-10-27T16:03:07+01:00")
    event = cal.Event("Hiring debrief", start, start + timedelta(minutes=30), uid="hire-1")
    paths.calendar.write_text(json.dumps({"question": [event.to_dict(), cal.Event(
        "Other", start, start + timedelta(minutes=30), uid="other").to_dict()]}))
    prepared = my_notes.prep_folder(event.key)
    my_notes.save(prepared, [{"text": "Ask about the salary band", "at": None}])
    my_notes.save(paths.folder, [{"text": "typed in the call", "at": 5}])
    before = my_notes.document(paths.folder)["revision"]

    token = api.set_meeting_event(tmp_path, MEETING, None, key=event.key)
    assert [p["text"] for p in my_notes.load(paths.folder)] == ["Ask about the salary band", "typed in the call"]
    assert api.get_meeting(tmp_path, MEETING, user_name="Timo")["my_notes_revision"] != before
    api.undo_change(tmp_path, token, user_name="Timo")
    assert my_notes.load(paths.folder) == [{"text": "typed in the call", "at": 5}]
    assert my_notes.load(prepared) == [{"text": "Ask about the salary band", "at": None}]  # waiting again


def test_my_notes_changed_after_the_notes_were_written(tmp_path: Path):
    from palaver import my_notes

    _meeting(tmp_path)
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert not m["notes_stale"] and m["notes_stale_reason"] is None
    entry = api.list_meetings(tmp_path)[0]
    assert not entry["notes_stale"]
    my_notes.save(tmp_path / MEETING, [{"text": "They said yes", "at": 4}])
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert m["notes_stale"] and m["notes_stale_reason"] == "my_notes"
    assert api.list_meetings(tmp_path)[0]["notes_stale"]  # the list notices the change too


def _prep_server(tmp_path: Path, now):
    from datetime import timedelta

    from palaver import calendar_events as cal

    event = cal.Event("Budget call", now + timedelta(hours=1), now + timedelta(hours=2),
                      (cal.Attendee("Anna Huber", "anna@x.com"),), uid="ev/1+=")
    srv = _server_with(tmp_path, lambda s, e: [event] if s <= event.start < e or s < event.end <= e else [])
    return srv, event


def test_http_notes_written_before_the_meeting(tmp_path: Path, no_vision):
    from datetime import datetime
    from urllib.parse import quote

    from palaver import my_notes, prep

    now = datetime.now().astimezone()
    srv, event = _prep_server(tmp_path, now)
    try:
        base = f"/api/upcoming/{quote(event.key, safe='')}"
        doc = [{"text": "Ask about the budget", "at": None}]
        status, answer = _save_notes(srv, base, doc)
        assert status == 200 and answer["saved"] == 1
        name = _upload(srv, base, _png())[1]["name"]
        assert _req(srv, f"{base}/my-notes/images/{name}")[2] == _png()
        assert json.loads(_req(srv, f"{base}/my-notes")[2])["paragraphs"] == doc
        assert _post(srv, "/api/upcoming/nope%7C2026-10-28/my-notes", {"paragraphs": doc, "revision": ""})[0] == 404
        assert my_notes.load(my_notes.prep_folder(event.key)) == doc

        recording = _meeting(tmp_path)
        prep.apply(recording, event)  # the recording is matched to its event
        assert my_notes.load(recording.folder) == doc
        assert json.loads(_req(srv, f"{base}/my-notes")[2])["paragraphs"] == []
    finally:
        srv.shutdown()
        srv.server_close()


def test_http_prep_notes_show_in_the_meeting_while_it_is_recorded(tmp_path: Path):
    from datetime import datetime, timedelta

    from palaver import my_notes

    now = datetime.now().astimezone()
    srv, event = _prep_server(tmp_path, now - timedelta(hours=1, minutes=5))  # began 5 minutes ago
    try:
        my_notes.save(my_notes.prep_folder(event.key), [{"text": "Ask about the budget", "at": None}])
        paths = _recording(tmp_path)
        paths.meta.write_text(json.dumps({"start_time": (now - timedelta(minutes=4)).isoformat()}))
        (paths.folder / "live.pid").write_text(str(os.getpid()))
        doc = json.loads(_req(srv, f"/api/meetings/{MEETING}/my-notes")[2])
        assert doc["paragraphs"] == [{"text": "Ask about the budget", "at": None}]
        assert not my_notes.prep_folder(event.key).exists()
    finally:
        srv.shutdown()
        srv.server_close()


# --- a title of the user's own --------------------------------------------------------

def _with_event(paths: RecordingPaths, title: str) -> None:
    from datetime import datetime, timedelta

    from palaver import calendar_events as cal

    start = datetime.fromisoformat(json.loads(paths.meta.read_text())["start_time"])
    cal.save(paths, cal.Event(title, start, start + timedelta(minutes=30)))


def test_a_meeting_renamed_is_called_so_in_the_list_the_page_and_the_search(tmp_path: Path):
    _meeting(tmp_path)
    assert api.list_meetings(tmp_path)[0]["title"] == "Hiring debrief"  # cached now
    api.set_title(tmp_path, MEETING, "Offer for Rico")
    [entry] = api.list_meetings(tmp_path)
    assert (entry["title"], entry["title_from"]) == ("Offer for Rico", "you")
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert (m["title"], m["title_from"]) == ("Offer for Rico", "you")
    [hit] = api.search(tmp_path, "offer in:title", user_name="Timo")
    assert hit["id"] == MEETING and hit["in_title"]


def test_a_renamed_meeting_keeps_its_calendar_event_beside_the_title(tmp_path: Path):
    paths = _meeting(tmp_path)
    _with_event(paths, "Weekly sync")
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert (m["title"], m["title_from"]) == ("Weekly sync", "calendar")
    api.set_title(tmp_path, MEETING, "Hiring: Rico")
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert (m["title"], m["title_from"]) == ("Hiring: Rico", "you")
    assert m["calendar"]["title"] == "Weekly sync"  # the page's "Calendar: Weekly sync"


def test_an_empty_title_falls_back_to_the_next_one(tmp_path: Path):
    paths = _meeting(tmp_path)
    api.set_title(tmp_path, MEETING, "Mine")
    api.set_title(tmp_path, MEETING, "   ")
    assert not paths.title.exists()
    assert api.list_meetings(tmp_path)[0]["title_from"] == "notes"


def test_a_meeting_being_recorded_can_be_renamed(tmp_path: Path):
    paths = _recording(tmp_path)
    assert api.get_meeting(tmp_path, MEETING, user_name="Timo")["title"] is None
    api.set_title(tmp_path, MEETING, "Call with Konrad")
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert m["status"] == "recording" and (m["title"], m["title_from"]) == ("Call with Konrad", "you")
    assert paths.live.exists()


def test_http_rename_strips_caps_and_can_be_undone(server, tmp_path: Path):
    status, answer = _post(server, f"/api/meetings/{MEETING}/title", {"title": "  Offer for Rico  "})
    assert status == 200 and answer["title"] == "Offer for Rico" and answer["title_from"] == "you" and answer["undo"]
    status, second = _post(server, f"/api/meetings/{MEETING}/title", {"title": "y" * 300})
    assert status == 200 and second["title"] == "y" * 200
    assert _post(server, "/api/undo", {"token": second["undo"]}) == (200, {"restored": [MEETING]})
    assert json.loads(_req(server, "/api/meetings")[2])[0]["title"] == "Offer for Rico"
    assert _post(server, "/api/undo", {"token": answer["undo"]})[0] == 200
    m = json.loads(_req(server, f"/api/meetings/{MEETING}")[2])
    assert (m["title"], m["title_from"]) == ("Hiring debrief", "notes")
    assert not (tmp_path / MEETING / "title.json").exists()


def test_http_rename_takes_only_text(server):
    for bad in ({"title": None}, {"title": 7}, {"title": ["Rico"]}, {}):
        status, _ = _post(server, f"/api/meetings/{MEETING}/title", bad)
        assert status == 400, bad
    assert _post(server, "/api/meetings/2026-01-01T00-00-00/title", {"title": "x"})[0] == 404


def test_http_rename_undone_after_the_meeting_went_to_the_trash_brings_nothing_back(server, tmp_path: Path):
    _, answer = _post(server, f"/api/meetings/{MEETING}/title", {"title": "Offer for Rico"})
    _post(server, f"/api/meetings/{MEETING}/trash")
    assert _post(server, "/api/undo", {"token": answer["undo"]})[0] == 409
    assert not (tmp_path / MEETING).exists()  # no folder made for the title alone
