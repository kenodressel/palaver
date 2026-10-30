"""Speakers that can't be separated (#56): the marks, the series memory and
the signals that suggest a mark."""

import json
import os
from datetime import datetime, timedelta
from pathlib import Path

from palaver import shared_mic
from palaver.calendar_events import Attendee, Event
from palaver.paths import RecordingPaths

START = datetime.fromisoformat("2026-10-27T16:00:00+01:00")


def _paths(tmp_path: Path, name: str = "2026-10-27T16-03-07") -> RecordingPaths:
    paths = RecordingPaths(tmp_path / name)
    paths.folder.mkdir(parents=True)
    paths.system_turns.write_text(json.dumps([
        {"speaker": "SPEAKER_00", "start": 0.0, "end": 30.0},
        {"speaker": "SPEAKER_01", "start": 31.0, "end": 60.0},
        {"speaker": "SPEAKER_02", "start": 61.0, "end": 62.0},
    ]))
    return paths


def _event(title: str = "Weekly", *, invited: int = 2, room: bool = False, location: str = "",
           uid: str = "abc", series: bool = False) -> Event:
    people = tuple(Attendee(f"Person {i}") for i in range(invited))
    rooms = (Attendee("Raum 3.12", is_room=True),) if room else ()
    return Event(title, START, START + timedelta(hours=1), people + rooms + (Attendee("Timo", is_self=True),),
                 uid=uid, series=series, location=location)


def test_a_meeting_without_a_mark_shows_every_voice_as_itself(tmp_path: Path):
    paths = _paths(tmp_path)
    assert shared_mic.display(paths) == {}
    assert not shared_mic.meeting_marked(paths)
    assert not paths.speakers_shared.exists()


def test_a_lane_marked_as_a_room_shows_as_the_room(tmp_path: Path):
    paths = _paths(tmp_path)
    shared_mic.set_lane(paths, "SPEAKER_01", True, "Raum 3.12")
    shared_mic.set_lane(paths, "SPEAKER_02", True)
    assert shared_mic.display(paths) == {"SPEAKER_01": "Room (Raum 3.12)", "SPEAKER_02": "Room"}
    assert shared_mic.room_names(paths) == {"SPEAKER_01": "Raum 3.12", "SPEAKER_02": ""}

    shared_mic.set_lane(paths, "SPEAKER_01", False)
    shared_mic.set_lane(paths, "SPEAKER_02", False)
    assert shared_mic.display(paths) == {} and not shared_mic.marked(paths)
    shared_mic.set_lane(paths, "SPEAKER_01", True)  # marked again: the room's name comes back
    assert shared_mic.display(paths) == {"SPEAKER_01": "Room (Raum 3.12)"}
    shared_mic.set_lane(paths, "SPEAKER_02", True, " " + "x" * 100)
    assert shared_mic.room_names(paths)["SPEAKER_02"] == "x" * shared_mic.NAME_LENGTH


def test_a_whole_meeting_mark_makes_every_remote_voice_several_people(tmp_path: Path):
    paths = _paths(tmp_path)
    shared_mic.set_meeting(paths, True)
    assert shared_mic.display(paths) == {label: "Several people" for label in ("SPEAKER_00", "SPEAKER_01", "SPEAKER_02")}
    shared_mic.set_meeting(paths, False)
    assert shared_mic.display(paths) == {}


def test_a_voice_merged_into_a_room_is_the_room_too(tmp_path: Path):
    paths = _paths(tmp_path)
    paths.speakers_merged.write_text(json.dumps({"SPEAKER_02": "SPEAKER_01"}))
    shared_mic.set_lane(paths, "SPEAKER_01", True, "Lab")
    assert shared_mic.display(paths) == {"SPEAKER_01": "Room (Lab)", "SPEAKER_02": "Room (Lab)"}


def test_a_remembered_series_marks_its_next_meetings(tmp_path: Path):
    event = _event("All Hands", uid="series-1/RID=2026-10-27", series=True)
    assert shared_mic.can_remember(event)
    assert not shared_mic.remembered(event)
    shared_mic.remember(event, True)
    assert shared_mic.remembered(_event("All Hands", uid="series-1/RID=2026-11-24", series=True))

    later = _paths(tmp_path, "2026-11-24T16-00-00")
    assert shared_mic.apply_series(later, event)
    assert shared_mic.meeting_marked(later)

    shared_mic.remember(event, False)
    assert not shared_mic.remembered(event)


def test_a_meeting_the_user_unmarked_stays_unmarked_for_its_series(tmp_path: Path):
    event = _event("All Hands", series=True)
    shared_mic.remember(event, True)
    paths = _paths(tmp_path)
    shared_mic.set_meeting(paths, False)
    assert not shared_mic.apply_series(paths, event)
    assert not shared_mic.meeting_marked(paths)


def test_a_single_event_cannot_be_remembered(tmp_path: Path):
    assert not shared_mic.can_remember(_event("All Hands", series=False))
    assert not shared_mic.can_remember(None)


def test_an_all_hands_in_the_calendar_suggests_the_mark(tmp_path: Path):
    paths = _paths(tmp_path)
    found = shared_mic.signals(paths, _event("Company All-Hands October"))
    assert found["gathering"] and not found["room"]
    suggestion = shared_mic.suggestion(paths, _event("Company All-Hands October"))
    assert suggestion is not None and "All-Hands" in suggestion["why"]


def test_a_room_with_many_invitees_but_few_voices_suggests_the_mark(tmp_path: Path):
    paths = _paths(tmp_path)
    event = _event("Sprint review", invited=12, room=True)
    found = shared_mic.signals(paths, event)
    assert found == {"gathering": False, "room": True, "invitees": 12, "voices": 2, "few_voices": True}
    assert shared_mic.suggestion(paths, event) is not None


def test_a_meeting_room_alone_is_no_reason_to_suggest(tmp_path: Path):
    paths = _paths(tmp_path)
    assert shared_mic.suggestion(paths, _event("Sprint review", invited=3, room=True)) is None
    assert shared_mic.suggestion(paths, _event("Sprint review", invited=3, location="Raum 3.12")) is None


def test_many_quiet_invitees_alone_are_no_reason_to_suggest(tmp_path: Path):
    paths = _paths(tmp_path)  # a webinar: many invited, one or two speak
    assert shared_mic.suggestion(paths, _event("Webinar", invited=30)) is None


def test_a_room_in_the_location_counts_as_a_room(tmp_path: Path):
    paths = _paths(tmp_path)
    assert shared_mic.signals(paths, _event("Review", invited=12, location="Besprechungsraum Attakring"))["room"]


def test_a_dismissed_or_marked_meeting_is_not_suggested_again(tmp_path: Path):
    paths = _paths(tmp_path)
    event = _event("All Hands")
    shared_mic.dismiss_suggestion(paths, True)
    assert shared_mic.suggestion(paths, event) is None
    shared_mic.dismiss_suggestion(paths, False)
    assert shared_mic.suggestion(paths, event) is not None
    shared_mic.set_lane(paths, "SPEAKER_00", True)
    assert shared_mic.suggestion(paths, event) is None


def test_a_meeting_without_an_event_has_no_suggestion(tmp_path: Path):
    paths = _paths(tmp_path)
    assert shared_mic.suggestion(paths, None) is None
    assert shared_mic.signals(paths, None)["invitees"] == 0


# --- names, voices and people ---------------------------------------------------------

from palaver import people  # noqa: E402
from palaver.speakers import names_in_effect, save_speaker_names  # noqa: E402
from palaver.voices import VoiceBank  # noqa: E402

from .test_people import ANNA, BEN, _meeting, _names_in  # noqa: E402


def _bank_meeting(tmp_path: Path, name: str = "2026-10-20T10-00-00") -> RecordingPaths:
    return _meeting(tmp_path, name, {"SPEAKER_00": (ANNA, 60), "SPEAKER_01": (BEN, 60)})


def test_a_room_keeps_no_name_and_its_lines_show_the_room(tmp_path: Path):
    paths = _bank_meeting(tmp_path)
    paths.speakers_auto.write_text(json.dumps({"SPEAKER_01": {"name": "Ben", "similarity": 0.9}}))
    paths.speakers_inferred.write_text(json.dumps(
        {"SPEAKER_00": {"name": "Anna", "rule": "only", "why": "", "confidence": 0.8}}))
    shared_mic.set_lane(paths, "SPEAKER_01", True, "Lab")
    save_speaker_names(paths, {})
    assert names_in_effect(paths) == {"SPEAKER_00": "Anna"}  # the auto name on the room no longer counts
    assert _names_in(paths) == {"Timo": "Timo", "SPEAKER_00": "Anna", "SPEAKER_01": "Room (Lab)"}


def test_a_whole_meeting_mark_names_nobody_on_the_system_track(tmp_path: Path):
    paths = _bank_meeting(tmp_path)
    shared_mic.set_meeting(paths, True)
    save_speaker_names(paths, {"SPEAKER_00": "Anna"})
    assert names_in_effect(paths) == {}
    assert _names_in(paths) == {"Timo": "Timo", "SPEAKER_00": "Several people", "SPEAKER_01": "Several people"}
    shared_mic.set_meeting(paths, False)  # the name given by hand comes back
    save_speaker_names(paths, {"SPEAKER_00": "Anna"})
    assert names_in_effect(paths) == {"SPEAKER_00": "Anna"}


def test_a_room_never_teaches_the_voice_bank(tmp_path: Path):
    paths = _bank_meeting(tmp_path)
    save_speaker_names(paths, {"SPEAKER_01": "Ben"})
    assert "Ben" in VoiceBank().names()
    shared_mic.set_lane(paths, "SPEAKER_01", True)
    save_speaker_names(paths, {"SPEAKER_01": "Ben"})
    assert "Ben" not in VoiceBank().names()  # what it taught before is taken back


def test_a_room_is_not_recognized_suggested_or_an_unknown_recurring_voice(tmp_path: Path):
    first = _bank_meeting(tmp_path, "2026-10-20T10-00-00")
    second = _bank_meeting(tmp_path, "2026-10-27T10-00-00")
    assert len(people.directory(tmp_path)["unknown"]) == 2  # Anna and Ben recur
    shared_mic.set_lane(first, "SPEAKER_01", True)
    shared_mic.set_lane(second, "SPEAKER_01", True)
    assert len(people.directory(tmp_path)["unknown"]) == 1

    VoiceBank().add("Ben", BEN, source="elsewhere:SPEAKER_05")
    people.name_voices(tmp_path, [("2026-10-20T10-00-00", "SPEAKER_00")], "Anna")
    assert _names_in(second)["SPEAKER_00"] == "Anna"
    assert _names_in(second)["SPEAKER_01"] == "Room"
    assert "SPEAKER_01" not in json.loads(second.speakers_auto.read_text())
    VoiceBank().add("Bert", [0.7, 0.71, 0, 0], source="elsewhere:SPEAKER_06")
    assert people.suggestions(second) == {}


# --- processing -------------------------------------------------------------------------


def test_an_event_of_a_remembered_series_marks_the_meeting_it_is_linked_to(tmp_path: Path):
    from palaver import calendar_events

    shared_mic.remember(_event("All Hands", series=True), True)
    paths = _paths(tmp_path)
    calendar_events.assign(paths, _event("All Hands", series=True))
    assert shared_mic.meeting_marked(paths)
    other = _paths(tmp_path, "2026-10-28T10-00-00")
    calendar_events.assign(other, _event("Weekly", uid="other", series=True))
    assert not shared_mic.meeting_marked(other)


def test_processing_a_marked_meeting_recognizes_nobody_and_logs_the_signals(tmp_path: Path, monkeypatch):
    import numpy as np

    from palaver import cli
    from palaver.models import Segment, SpeakerTurn

    from .test_cli import _events, _fake_models, _ns, _recording_folder

    folder = tmp_path / "2026-10-20T14-35-17"
    paths = _recording_folder(folder, seconds=40.0)
    VoiceBank().add("Tom", [1.0, 0.0, 0.0], source="m0:SPEAKER_00")
    shared_mic.set_meeting(paths, True)
    voice = np.array([1.0, 0.05, 0.0])
    _fake_models(monkeypatch, turns=[SpeakerTurn("SPEAKER_00", 0.0, 30.0)],
                 embeddings={"SPEAKER_00": list(voice / np.linalg.norm(voice))},
                 segments_for=lambda wav: [] if wav == "mic.wav"
                 else [Segment(start=1.0, end=29.0, text="hallo zusammen", speaker=None, words=[])])
    monkeypatch.setattr("palaver.cleanup.drop_silent_segments", lambda segs, wav, db: segs)  # quiet test audio
    args = _ns(folder)
    args.no_notes = True
    assert cli._cmd_process(args) == 0
    assert [u["speaker"] for u in json.loads(paths.transcript_json.read_text())] == ["Several people"]
    assert "Tom" not in paths.speakers_auto.read_text()
    [logged] = [e for e in _events(paths) if e.get("event") == "shared_mic_signals"]
    assert logged["marked"] is True and logged["voices"] == 1 and logged["gathering"] is False


def test_processing_goes_on_when_the_signals_cannot_be_read(tmp_path: Path, monkeypatch):
    from palaver import cli

    from .test_cli import _events, _fake_models, _ns, _recording_folder

    folder = tmp_path / "2026-10-20T14-35-17"
    paths = _recording_folder(folder)
    _fake_models(monkeypatch)

    def broken(*args, **kwargs):
        raise ValueError("a calendar.json from the future")

    monkeypatch.setattr(shared_mic, "signals", broken)
    args = _ns(folder)
    args.no_notes = True
    assert cli._cmd_process(args) == 0
    assert paths.transcript_json.exists()
    assert any(e.get("event") == "shared_mic_signals_failed" for e in _events(paths))


# --- the meetings window -----------------------------------------------------------------

from palaver import calendar_events  # noqa: E402
from palaver.webapp import api  # noqa: E402

from .test_webapp import MEETING, _meeting as _window_meeting, _req, server  # noqa: E402,F401


def _lanes(m: dict) -> dict:
    return {s["label"]: s for s in m["speakers"] if not s["is_user"]}


def test_a_room_lane_shows_the_room_and_offers_no_names(tmp_path: Path):
    paths = _window_meeting(tmp_path)
    calendar_events.save(paths, _event("Hiring debrief", invited=3))
    token = api.set_shared(tmp_path, MEETING, label="SPEAKER_00", on=True, name="Raum 3.12")
    assert token
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    room = _lanes(m)["SPEAKER_00"]
    assert (room["display"], room["name"], room["shared"], room["room"]) == ("Room (Raum 3.12)", None, "room", "Raum 3.12")
    assert room["guesses"] == [] and room["maybe"] == [] and room["link"] is None  # not "Rico" from the notes
    assert [t["speaker"] for t in m["transcript"]][:2] == ["Timo", "Room (Raum 3.12)"]
    assert m["notes"]["summary"] == "Room (Raum 3.12) ran the debrief."
    assert m["shared"]["line"] == shared_mic.LINE and m["shared"]["rooms"] == {"SPEAKER_00": "Raum 3.12"}
    assert "Room (Raum 3.12)" in paths.transcript_md.read_text()

    api.undo_change(tmp_path, token, user_name="Timo")
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert _lanes(m)["SPEAKER_00"]["shared"] is None and m["shared"]["line"] is None
    assert [t["speaker"] for t in m["transcript"]][:2] == ["Timo", "Speaker 1"]


def test_mcp_and_search_show_the_room_not_a_guessed_person(tmp_path: Path):
    from palaver import mcp_server

    _window_meeting(tmp_path)
    api.name_speaker(tmp_path, MEETING, "SPEAKER_01", "Rico")
    api.set_meeting_project(tmp_path, MEETING, name="Hiring")
    api.set_shared(tmp_path, MEETING, label="SPEAKER_01", on=True, name="Lab")
    m = mcp_server.Meetings(tmp_path, "Timo")
    [hit] = m.search_meetings("salary")["meetings"]
    assert hit["lines"] == ["[0:13] Room (Lab): Thanks Rico, the salary band is fine."]
    assert "Room (Lab)" in m.get_meeting(MEETING)["speakers"] and "Rico" not in m.get_meeting(MEETING)["speakers"]
    assert m.get_project("Hiring")["next_steps"][0]["owner"] == "Room (Lab)"
    assert [p["name"] for p in m.list_people()] == []
    assert [line["speaker"] for line in api.search(tmp_path, "salary", user_name="Timo")[0]["hits"]] == ["Room (Lab)"]


def test_a_marks_undo_keeps_only_this_meetings_marks_and_ignores_other_meetings(tmp_path: Path):
    from palaver import undo

    from .e2e.recordings import A, B, build_recordings

    build_recordings(tmp_path, os.getpid())
    token = api.set_shared(tmp_path, A, label="SPEAKER_01", on=True)
    manifest = undo._load(tmp_path, token)[1]
    assert manifest["meetings"] == {}  # no meeting's speaker files, no voice bank
    assert [Path(s["path"]).name for s in manifest["stores"]] == ["speakers_shared.json"]
    (tmp_path / B / "speakers_auto.json").write_text("{}")  # a call got processed meanwhile
    api.undo_change(tmp_path, token, user_name="Timo")
    assert _lanes(api.get_meeting(tmp_path, A, user_name="Timo"))["SPEAKER_01"]["shared"] is None
    assert "Room" not in (tmp_path / A / "transcript.md").read_text()


def test_naming_a_room_or_remembering_a_series_recognizes_nothing_again(tmp_path: Path, monkeypatch):
    paths = _window_meeting(tmp_path)
    calendar_events.save(paths, _event("All Hands", series=True))
    api.set_shared(tmp_path, MEETING, label="SPEAKER_00", on=True)
    api.set_shared(tmp_path, MEETING, on=True)
    calls = []
    monkeypatch.setattr(people, "refresh_recognition", lambda *a, **kw: calls.append("refresh"))
    monkeypatch.setattr("palaver.speakers._remember_voices", lambda *a, **kw: calls.append("voices") or 0)
    named = api.set_shared(tmp_path, MEETING, label="SPEAKER_00", on=True, name="Lab")
    remembered = api.set_shared(tmp_path, MEETING, on=True, series=True)
    api.undo_change(tmp_path, remembered, user_name="Timo")
    api.undo_change(tmp_path, named, user_name="Timo")
    assert calls == []


def test_a_room_named_and_both_changes_undone_in_turn(tmp_path: Path):
    from .e2e.recordings import A, build_recordings

    build_recordings(tmp_path, os.getpid())
    marked = api.set_shared(tmp_path, A, label="SPEAKER_01", on=True)
    named = api.set_shared(tmp_path, A, label="SPEAKER_01", on=True, name="Raum 3.12")
    api.undo_change(tmp_path, named, user_name="Timo")
    api.undo_change(tmp_path, marked, user_name="Timo")
    assert _lanes(api.get_meeting(tmp_path, A, user_name="Timo"))["SPEAKER_01"]["shared"] is None


def test_a_room_is_no_open_question_and_no_unnamed_voice(tmp_path: Path):
    _window_meeting(tmp_path)
    unnamed = lambda: [i["label"] for m in api.needs(tmp_path, user_name="Timo")["meetings"]  # noqa: E731
                       for i in m["items"] if i["kind"] == "unnamed"]
    assert unnamed() == ["SPEAKER_00"] and api.list_meetings(tmp_path)[0]["unnamed"] == 1
    api.set_shared(tmp_path, MEETING, label="SPEAKER_00", on=True)
    assert unnamed() == [] and api.list_meetings(tmp_path)[0]["unnamed"] == 0
    assert api.list_meetings(tmp_path)[0]["people"] == []


def test_a_whole_meeting_mark_can_be_remembered_for_its_series(tmp_path: Path):
    paths = _window_meeting(tmp_path)
    calendar_events.save(paths, _event("All Hands", series=True))
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert m["shared_suggestion"] == {"why": "The calendar calls it “All Hands”."}
    assert m["shared"]["series"] == {"can": True, "remembered": False}

    token = api.set_shared(tmp_path, MEETING, on=True, series=True)
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert {s["display"] for s in _lanes(m).values()} == {"Several people"}
    assert m["shared"]["series"]["remembered"] and m["shared_suggestion"] is None
    api.undo_change(tmp_path, token, user_name="Timo")
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert not m["shared"]["meeting"] and not m["shared"]["series"]["remembered"]


def test_a_meeting_marked_from_its_series_can_forget_the_series_after_it_was_unmarked(tmp_path: Path):
    paths = _window_meeting(tmp_path)
    event = _event("All Hands", series=True)
    shared_mic.remember(event, True)
    calendar_events.assign(paths, event)
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert m["shared"]["meeting"] and m["shared"]["from_series"] and m["shared"]["series"]["remembered"]

    api.set_shared(tmp_path, MEETING, on=False)
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert not m["shared"]["meeting"] and not m["shared"]["from_series"] and m["shared"]["series"]["remembered"]
    token = api.remember_series(tmp_path, MEETING, False)
    assert not shared_mic.remembered(event) and not shared_mic.meeting_marked(paths)
    api.undo_change(tmp_path, token, user_name="Timo")
    assert shared_mic.remembered(event)


def test_a_mark_from_a_series_goes_when_the_meeting_gets_another_event(tmp_path: Path):
    paths = _window_meeting(tmp_path)
    shared_mic.remember(_event("All Hands", series=True), True)
    calendar_events.assign(paths, _event("All Hands", series=True))
    assert shared_mic.meeting_marked(paths)
    calendar_events.assign(paths, _event("Weekly", uid="weekly", series=True))
    assert not shared_mic.meeting_marked(paths)
    shared_mic.set_meeting(paths, True)  # marked by hand: stays with any event
    calendar_events.assign(paths, _event("Retro", uid="retro"))
    assert shared_mic.meeting_marked(paths)


def test_several_people_at_my_mic_show_as_the_room_not_as_me(tmp_path: Path):
    paths = _window_meeting(tmp_path)
    token = api.set_shared(tmp_path, MEETING, label=shared_mic.MIC, on=True)
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    me = m["speakers"][0]
    assert (me["is_user"], me["display"], me["shared"], me["room"]) == (True, "Room (with you)", "mic", "")
    assert m["transcript"][0]["speaker"] == "Room (with you)" and m["transcript"][0]["label"] is None
    assert m["shared"]["line"] == shared_mic.LINE and m["shared"]["mic"] == ""
    assert "Room (with you)" in paths.transcript_md.read_text() and "**Timo**" not in paths.transcript_md.read_text()
    assert json.loads(paths.transcript_json.read_text())[0]["speaker"] == "Timo"  # still the microphone's line
    [hit] = api.search(tmp_path, "welcome", user_name="Timo")
    assert hit["hits"][0]["speaker"] == "Room (with you)"

    api.set_shared(tmp_path, MEETING, label=shared_mic.MIC, on=True, name="Raum 3.12")
    assert api.get_meeting(tmp_path, MEETING, user_name="Timo")["transcript"][0]["speaker"] == "Room (Raum 3.12)"
    api.set_shared(tmp_path, MEETING, label=shared_mic.MIC, on=False)
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert m["transcript"][0]["speaker"] == "Timo" and m["shared"]["line"] is None
    assert "**Timo**" in paths.transcript_md.read_text()
    del token


def test_a_whole_meeting_mark_covers_my_mic_only_in_person(tmp_path: Path):
    paths = _window_meeting(tmp_path)
    api.set_shared(tmp_path, MEETING, on=True)
    assert api.get_meeting(tmp_path, MEETING, user_name="Timo")["transcript"][0]["speaker"] == "Timo"  # a call
    paths.system_turns.write_text("[]")  # nobody on the system track: in person
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert m["transcript"][0]["speaker"] == "Room (with you)" and m["speakers"][0]["shared"] == "meeting"


def test_one_person_after_all_keeps_the_rooms_name_for_when_it_is_marked_again(tmp_path: Path):
    _window_meeting(tmp_path)
    api.set_shared(tmp_path, MEETING, label="SPEAKER_00", on=True, name="Lab")
    api.set_shared(tmp_path, MEETING, label="SPEAKER_00", on=False)
    assert _lanes(api.get_meeting(tmp_path, MEETING, user_name="Timo"))["SPEAKER_00"]["shared"] is None
    api.set_shared(tmp_path, MEETING, label="SPEAKER_00", on=True)
    assert _lanes(api.get_meeting(tmp_path, MEETING, user_name="Timo"))["SPEAKER_00"]["display"] == "Room (Lab)"


def test_the_quiet_line_shows_only_while_a_marked_voice_is_in_the_meeting(tmp_path: Path):
    paths = _window_meeting(tmp_path)
    paths.speakers_shared.write_text(json.dumps({"lanes": {"SPEAKER_09": "Lab"}}))  # a voice cut away since
    assert api.get_meeting(tmp_path, MEETING, user_name="Timo")["shared"]["line"] is None


def test_the_coach_leaves_out_my_pace_and_fillers_when_several_people_sat_at_my_mic(tmp_path: Path):
    from palaver import coach

    paths = _window_meeting(tmp_path)
    shared_mic.set_lane(paths, shared_mic.MIC, True)
    r = coach.analyze(paths, user_name="Timo")
    assert r["talk"]["share"] is None and r["talk"]["at_mic"] and r["monologues"] == []
    assert r["pace"] == {"wpm": None, "fastest": None}
    assert r["fillers"] == {"per_minute": None, "top": [], "hesitations": None}


def test_the_coach_says_a_room_cut_in_not_a_label(tmp_path: Path):
    from palaver import coach

    paths = _window_meeting(tmp_path)
    paths.transcript_json.write_text(json.dumps([
        {"speaker": "SPEAKER_00", "start": 0.0, "end": 10.0, "text": "Das ist ein langer Satz über das Budget hier."},
        {"speaker": "Timo", "start": 8.0, "end": 14.0, "text": "Ja aber wir müssen auch die Kosten sehen jetzt."},
    ]))
    shared_mic.set_lane(paths, "SPEAKER_00", True, "Lab")
    r = coach.result(paths, user_name="Timo")
    assert r["interruptions"]["by_me_at"] == [{"start": 8.0, "who": "Room (Lab)"}]


def test_notes_from_my_mic_in_a_room_are_not_mine_by_default():
    from datetime import datetime

    from palaver import notes
    from palaver.models import Utterance

    seen = {}

    def run(prompt, schema):
        seen["prompt"] = prompt
        return {"title": "t", "summary": "s", "sections": [], "next_steps": [], "decisions": [], "speaker_names": []}

    lines = [Utterance("Timo", 0.0, 3.0, "Ich mach das bis Freitag."), Utterance("SPEAKER_00", 4.0, 6.0, "Gut.")]
    out = notes.generate(lines, user_name="Timo", meeting_start=datetime(2026, 10, 30, 10), run=run,
                         mic="Room (with you)")
    assert "[00:00] Room (with you): Ich mach das bis Freitag." in seen["prompt"]
    assert 'Timo sat at the microphone labelled "Room (with you)" with the others' in seen["prompt"]
    assert out["shared_lanes"] == ["mic"] and out["transcript_hash"] == notes.transcript_hash(lines)


def test_only_a_recurring_event_is_remembered(tmp_path: Path):
    import pytest

    paths = _window_meeting(tmp_path)
    calendar_events.save(paths, _event("All Hands", series=False))
    with pytest.raises(api.Refused):
        api.set_shared(tmp_path, MEETING, on=True, series=True)


def test_http_marks_a_room_and_dismisses_the_suggestion(server):  # noqa: F811
    status, _, body = _req(server, f"/api/meetings/{MEETING}/shared", method="POST",
                           body={"label": "SPEAKER_01", "on": True, "name": "Lab"})
    m = json.loads(body)
    assert status == 200 and m["undo"] and _lanes(m)["SPEAKER_01"]["display"] == "Room (Lab)"
    assert _req(server, f"/api/meetings/{MEETING}/shared", method="POST",
                body={"label": "SPEAKER_09", "on": True})[0] == 404
    status, _, body = _req(server, f"/api/meetings/{MEETING}/shared-suggestion", method="POST", body={"dismiss": True})
    assert status == 200 and json.loads(body)["shared_suggestion"] is None


def test_http_takes_marks_only_as_said_plainly(server):  # noqa: F811
    def post(body):
        return _req(server, f"/api/meetings/{MEETING}/shared", method="POST", body=body)

    assert post({"label": "SPEAKER_01", "on": "false"})[0] == 400  # not a JSON boolean
    assert post({"label": "SPEAKER_01"})[0] == 400
    assert post({"on": False, "series": True})[0] == 400  # a series only with the whole meeting marked
    assert post({"label": "SPEAKER_01", "on": True, "series": True})[0] == 400
    assert post({"label": "SPEAKER_01", "on": True, "name": ["Lab"]})[0] == 400
    status, _, body = post({"label": "SPEAKER_01", "on": True, "name": "  " + "R" * 120 + " "})
    assert status == 200 and _lanes(json.loads(body))["SPEAKER_01"]["room"] == "R" * 80
