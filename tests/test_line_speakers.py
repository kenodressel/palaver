"""The speaker of single transcript lines (#12): a line diarization gave
to the wrong voice ("Speaker 2" holds two people) said to be someone
else's, in speakers_lines.json, applied wherever the meeting is shown,
searched, summarized or exported, and kept when it is processed again."""

import json
import threading
import urllib.request
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from palaver import notes, semantic, undo
from palaver.models import Utterance
from palaver.paths import RecordingPaths
from palaver.speakers import corrected_lines, load_line_speakers, save_speaker_names, without_ignored
from palaver.webapp import api
from palaver.webapp.server import App, make_server

SR = 16_000
M = "2026-10-29T14-00-00"
USER = "Kim"


def _lines() -> list[Utterance]:
    return [
        Utterance(USER, 0.0, 1.0, "Hi everyone."),
        Utterance("Valerie", 1.0, 12.0, "Welcome to the Contoso review.", label="SPEAKER_00"),
        Utterance("SPEAKER_01", 13.0, 15.0, "The Northwind numbers are in."),
        Utterance("SPEAKER_01", 16.0, 18.0, "I disagree with those numbers."),  # Timo Strauß, really
        Utterance(USER, 16.5, 17.5, "Really?"),  # at the same time, on the microphone
        Utterance("SPEAKER_01", 19.0, 21.0, "Let us check them again."),
    ]


def _meeting(root: Path) -> RecordingPaths:
    """Valerie named, Speaker 2 unnamed and two people in truth."""
    paths = RecordingPaths(root / M)
    paths.folder.mkdir(parents=True)
    t = np.arange(SR * 25)
    sf.write(str(paths.system_wav), (3000 * np.sin(t / 7)).astype(np.int16), SR, subtype="PCM_16")
    sf.write(str(paths.mic_wav), (2000 * np.sin(t / 3)).astype(np.int16), SR, subtype="PCM_16")
    paths.meta.write_text(json.dumps({"start_time": "2026-10-29T14:00:00+01:00", "duration_seconds": 25}))
    paths.system_turns.write_text(json.dumps([
        {"speaker": "SPEAKER_00", "start": 1.0, "end": 12.0},
        {"speaker": "SPEAKER_01", "start": 13.0, "end": 21.0},
        {"speaker": "SPEAKER_02", "start": 22.0, "end": 22.5},
    ]))
    paths.speakers.write_text(json.dumps({"SPEAKER_00": "Valerie"}))
    utterances = _lines()
    paths.transcript_json.write_text(json.dumps([u.to_dict() for u in utterances]))
    notes.save(paths, {"title": "Contoso review", "summary": "SPEAKER_01 has the numbers.", "sections": [],
                       "next_steps": [], "decisions": [], "speaker_names": [],
                       "transcript_hash": notes.transcript_hash(utterances)})
    save_speaker_names(paths, {"SPEAKER_00": "Valerie"}, learn=False)
    return paths


def _line(m: dict, start: float) -> dict:
    return next(t for t in m["transcript"] if t["start"] == start and t["text"] != "Really?")


def _get(root: Path) -> dict:
    return api.get_meeting(root, M, user_name=USER)


def _set(root: Path, start: float, to) -> str:
    return api.set_line_speaker(root, M, start=start, to=to, user_name=USER)


# --- moving a line ----------------------------------------------------------------


def test_a_line_moves_to_another_speaker(tmp_path: Path):
    paths = _meeting(tmp_path)
    token = _set(tmp_path, 16.0, {"label": "SPEAKER_00"})
    assert token

    m = _get(tmp_path)
    moved = _line(m, 16.0)
    assert (moved["speaker"], moved["label"]) == ("Valerie", "SPEAKER_00")
    assert moved["fixed"] == {"was": "Speaker 2", "from": "SPEAKER_01"}
    assert (_line(m, 13.0)["speaker"], _line(m, 13.0)["fixed"]) == ("Speaker 2", None)
    assert next(t for t in m["transcript"] if t["text"] == "Really?")["speaker"] == USER  # the mic is not moved
    assert load_line_speakers(paths) == [{"start": 16.0, "end": 18.0, "from": "SPEAKER_01", "label": "SPEAKER_00"}]
    assert "**Valerie** [14:00:16]  I disagree with those numbers." in paths.transcript_md.read_text()


def test_a_line_goes_to_a_person_who_has_no_voice_of_their_own(tmp_path: Path):
    paths = _meeting(tmp_path)
    _set(tmp_path, 16.0, {"name": "  Timo Strauß "})
    moved = _line(_get(tmp_path), 16.0)
    assert moved["speaker"] == "Timo Strauß" and moved["fixed"] == {"was": "Speaker 2", "from": "SPEAKER_01"}
    assert load_line_speakers(paths) == [{"start": 16.0, "end": 18.0, "from": "SPEAKER_01", "name": "Timo Strauß"}]
    assert "**Timo Strauß** [14:00:16]" in paths.transcript_md.read_text()


def test_a_line_is_mine(tmp_path: Path):
    paths = _meeting(tmp_path)
    _set(tmp_path, 19.0, {"me": True})
    m = _get(tmp_path)
    mine = _line(m, 19.0)
    assert (mine["speaker"], mine["label"]) == (USER, None)
    assert load_line_speakers(paths) == [{"start": 19.0, "end": 21.0, "from": "SPEAKER_01", "me": True, "name": USER}]
    you = next(s for s in m["speakers"] if s["is_user"])
    assert you["talk_seconds"] == 4.0  # 0–1, 16.5–17.5 and now 19–21


def test_a_line_of_mine_goes_to_someone_else(tmp_path: Path):
    _meeting(tmp_path)
    _set(tmp_path, 0.0, {"label": "SPEAKER_01"})
    first = _get(tmp_path)["transcript"][0]
    assert (first["speaker"], first["label"], first["fixed"]) == ("Speaker 2", "SPEAKER_01", {"was": USER, "from": None})


def test_the_name_of_a_speaker_moves_the_line_to_that_speaker(tmp_path: Path):
    paths = _meeting(tmp_path)
    _set(tmp_path, 16.0, {"name": "valerie"})
    assert load_line_speakers(paths)[0]["label"] == "SPEAKER_00"
    _set(tmp_path, 13.0, {"name": "kim"})  # the user's own name: mine
    assert load_line_speakers(paths)[0].get("me") is True


def test_back_to_the_speaker_it_was(tmp_path: Path):
    paths = _meeting(tmp_path)
    _set(tmp_path, 16.0, {"name": "Timo Strauß"})
    _set(tmp_path, 16.0, {"label": "SPEAKER_00"})  # changed again: one correction per line
    assert len(load_line_speakers(paths)) == 1
    _set(tmp_path, 16.0, None)
    assert not paths.speakers_lines.exists()
    assert _line(_get(tmp_path), 16.0)["speaker"] == "Speaker 2"
    _set(tmp_path, 16.0, {"label": "SPEAKER_01"})  # its own speaker: nothing to correct
    assert not paths.speakers_lines.exists()


def test_what_cannot_be_chosen(tmp_path: Path):
    _meeting(tmp_path)
    with pytest.raises(api.NotFound):
        _set(tmp_path, 16.0, {"label": "SPEAKER_09"})
    with pytest.raises(api.NotFound):
        _set(tmp_path, 3.0, {"me": True})  # no line starts there
    with pytest.raises(ValueError):
        _set(tmp_path, 16.0, {"name": "  "})
    with pytest.raises(ValueError):
        _set(tmp_path, 16.0, {"who": "Valerie"})


# --- wherever the meeting is used ---------------------------------------------------


def test_notes_search_and_the_list_use_the_corrected_speaker(tmp_path: Path):
    _meeting(tmp_path)
    assert not _get(tmp_path)["notes_stale"] and not api.list_meetings(tmp_path)[0]["notes_stale"]
    _set(tmp_path, 16.0, {"name": "Timo Strauß"})
    assert _get(tmp_path)["notes_stale"]  # the notes said who said what: written again
    assert api.list_meetings(tmp_path)[0]["notes_stale"]
    [hit] = api.search(tmp_path, "disagree", user_name=USER)
    assert hit["hits"][0]["speaker"] == "Timo Strauß"


def test_a_correction_stays_when_the_meeting_is_processed_again(tmp_path: Path):
    paths = _meeting(tmp_path)
    _set(tmp_path, 16.0, {"name": "Timo Strauß"})
    _set(tmp_path, 19.0, {"label": "SPEAKER_00"})
    # Transcribed again: the times move a little, the words may differ.
    again = [Utterance(USER, 0.0, 1.1, "Hi everyone."),
             Utterance("SPEAKER_00", 1.0, 12.0, "Welcome to the Contoso review."),
             Utterance("SPEAKER_01", 13.1, 15.0, "The Northwind numbers are in."),
             Utterance("SPEAKER_01", 16.08, 18.2, "I disagree with these numbers."),
             Utterance(USER, 16.4, 17.6, "Really?"),
             Utterance("SPEAKER_01", 18.9, 20.7, "Let's check them again.")]
    paths.transcript_json.write_text(json.dumps([u.to_dict() for u in again]))
    save_speaker_names(paths, json.loads(paths.speakers.read_text()), learn=False)

    m = _get(tmp_path)
    assert [t["speaker"] for t in m["transcript"]] == [USER, "Valerie", "Speaker 2", "Timo Strauß", USER, "Valerie"]
    assert "**Timo Strauß** [14:00:16]  I disagree with these numbers." in paths.transcript_md.read_text()


def test_lines_of_a_removed_voice_and_no_lines_moved_to_one(tmp_path: Path):
    paths = _meeting(tmp_path)
    _set(tmp_path, 16.0, {"name": "Timo Strauß"})
    api.remove_speaker(tmp_path, M, "SPEAKER_01")
    texts = [t["text"] for t in _get(tmp_path)["transcript"]]
    assert "I disagree with those numbers." in texts  # someone else's line: it stays
    assert "Let us check them again." not in texts
    with pytest.raises(api.Refused, match="Speaker 2 was removed as not a speaker"):
        _set(tmp_path, 0.0, {"label": "SPEAKER_01"})  # no lines for a removed voice
    api.remove_speaker(tmp_path, M, "SPEAKER_00")
    with pytest.raises(api.Refused, match="removed as not a speaker"):
        _set(tmp_path, 0.0, {"name": "Valerie"})  # nor by its name
    assert "Hi everyone." in paths.transcript_md.read_text()


def test_a_line_given_to_a_person_keeps_their_name_where_the_microphone_is_a_room(tmp_path: Path):
    """#56: the microphone's lines show as "Room (with you)"; a line said to be
    a person's is no microphone line, though it has no label."""
    from datetime import datetime

    from palaver import shared_mic

    paths = _meeting(tmp_path)
    shared_mic.set_lane(paths, shared_mic.MIC, True)
    _set(tmp_path, 16.0, {"name": "Timo Strauß"})
    md = paths.transcript_md.read_text()
    assert "**Timo Strauß** [14:00:16]  I disagree with those numbers." in md
    assert "**Room (with you)** [14:00:16]  Really?" in md
    assert _line(_get(tmp_path), 16.0)["speaker"] == "Timo Strauß"
    [hit] = api.search(tmp_path, "disagree", user_name=USER)
    assert hit["hits"][0]["speaker"] == "Timo Strauß"

    seen = {}

    def run(prompt, schema):
        seen["prompt"] = prompt
        return {"title": "t", "summary": "s", "sections": [], "next_steps": [], "decisions": [], "speaker_names": []}

    raw = [Utterance.from_dict(d) for d in json.loads(paths.transcript_json.read_text())]
    notes.generate(without_ignored(paths, raw), user_name=USER, meeting_start=datetime(2026, 10, 29, 14), run=run,
                   mic=shared_mic.mic_display(paths))
    assert "[00:16] Timo Strauß: I disagree with those numbers." in seen["prompt"]
    assert "[00:16] Room (with you): Really?" in seen["prompt"]


def test_a_line_is_found_by_its_start_and_track(tmp_path: Path):
    paths = _meeting(tmp_path)
    lines = json.loads(paths.transcript_json.read_text())
    lines[4]["start"] = 16.005  # the microphone's "Really?" starts with the system line
    paths.transcript_json.write_text(json.dumps(lines))
    with pytest.raises(ValueError, match="track"):
        _set(tmp_path, 16.0, {"label": "SPEAKER_00"})
    api.set_line_speaker(tmp_path, M, start=16.0, track="mic", to={"label": "SPEAKER_00"}, user_name=USER)
    assert load_line_speakers(paths) == [{"start": 16.005, "end": 17.5, "from": None, "label": "SPEAKER_00"}]
    m = _get(tmp_path)
    really = next(t for t in m["transcript"] if t["text"] == "Really?")
    disagree = _line(m, 16.0)
    assert (really["speaker"], really["track"], really["fixed"]) == ("Valerie", "mic", {"was": USER, "from": None})
    assert (disagree["speaker"], disagree["track"], disagree["fixed"]) == ("Speaker 2", "others", None)
    with pytest.raises(ValueError):
        api.set_line_speaker(tmp_path, M, start=16.0, track="system", to=None, user_name=USER)


def test_a_line_speaker_changes_under_the_lock_names_change_under(tmp_path: Path, monkeypatch):
    _meeting(tmp_path)
    held = []
    real = api.save_line_speaker
    monkeypatch.setattr(api, "save_line_speaker", lambda *a: held.append(api._PROJECTS_LOCK.locked()) or real(*a))
    _set(tmp_path, 16.0, {"me": True})
    assert held == [True]


def test_the_overlay_matches_lines_by_time_and_track():
    fixes = [{"start": 16.0, "end": 18.0, "from": "SPEAKER_01", "name": "Timo Strauß"},
             {"start": 0.0, "end": 1.0, "from": None, "label": "SPEAKER_01"}]
    lines = [Utterance(USER, 0.05, 0.9, "Hi."),
             Utterance("SPEAKER_01", 13.0, 15.9, "Before."),
             Utterance("SPEAKER_03", 16.2, 18.0, "Relabelled by a new diarization."),
             Utterance(USER, 16.5, 17.5, "Really?"),
             Utterance("SPEAKER_01", 17.9, 21.0, "Mostly after.")]
    out = corrected_lines(lines, fixes, names={"SPEAKER_01": "Bea"})
    assert [(u.speaker, u.label) for u in out] == [("Bea", "SPEAKER_01"), ("SPEAKER_01", None),
                                                   ("Timo Strauß", None), (USER, None), ("SPEAKER_01", None)]
    assert [u.text for u in out] == [u.text for u in lines]


def test_without_ignored_applies_the_corrections(tmp_path: Path):
    paths = _meeting(tmp_path)
    _set(tmp_path, 16.0, {"me": True})
    raw = [Utterance.from_dict(d) for d in json.loads(paths.transcript_json.read_text())]
    assert [u.speaker for u in without_ignored(paths, raw)][3] == USER


# --- undo, and where the file goes ---------------------------------------------------


def test_undo_puts_the_line_back(tmp_path: Path):
    paths = _meeting(tmp_path)
    first = _set(tmp_path, 16.0, {"name": "Timo Strauß"})
    second = _set(tmp_path, 19.0, {"me": True})
    assert api.undo_change(tmp_path, second, user_name=USER) == [M]
    assert load_line_speakers(paths) == [{"start": 16.0, "end": 18.0, "from": "SPEAKER_01", "name": "Timo Strauß"}]
    assert api.undo_change(tmp_path, first, user_name=USER) == [M]
    assert not paths.speakers_lines.exists()
    assert "**SPEAKER_01** [14:00:16]" in paths.transcript_md.read_text()  # transcript.md follows
    with pytest.raises(undo.Gone):
        api.undo_change(tmp_path, first, user_name=USER)


def test_speakers_lines_is_one_of_the_speaker_files(tmp_path: Path):
    paths = _meeting(tmp_path)
    _set(tmp_path, 16.0, {"me": True})
    assert paths.speakers_lines.name == "speakers_lines.json"
    assert paths.speakers_lines in paths.folder.glob(undo._SPEAKER_FILES)  # snapshots of speaker files take it
    assert paths.speakers_lines in semantic._sources(paths)  # the search index is made again


# --- the window's server ----------------------------------------------------------


@pytest.fixture
def server(tmp_path: Path):
    _meeting(tmp_path)
    srv = make_server(App(tmp_path, USER), port=0)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield srv
    srv.shutdown()
    srv.server_close()


def _post(server, path: str, body: dict) -> tuple[int, dict]:
    host, port = server.server_address[:2]
    req = urllib.request.Request(f"http://{host}:{port}{path}", data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read())


def test_http_line_speaker_and_undo(server):
    status, m = _post(server, f"/api/meetings/{M}/line-speaker", {"start": 16.0, "to": {"name": "Timo Strauß"}})
    assert status == 200 and m["undo"]
    assert _line(m, 16.0)["speaker"] == "Timo Strauß"
    status, _ = _post(server, "/api/undo", {"token": m["undo"]})
    assert status == 200
    status, m = _post(server, f"/api/meetings/{M}/line-speaker", {"start": 16.0, "to": {"label": "SPEAKER_07"}})
    assert status == 404
    status, m = _post(server, f"/api/meetings/{M}/line-speaker", {"start": 16.0, "to": "Valerie"})
    assert status == 400
