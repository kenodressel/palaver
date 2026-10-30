"""Tests for speakers named by inference (#38)."""

import json
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np

from palaver import calendar_events as cal
from palaver import inference
from palaver.paths import RecordingPaths
from palaver.webapp import api

T0 = datetime.fromisoformat("2026-10-20T10:00:00+02:00")


def _unit(*v):
    a = np.array(v, dtype=float)
    return list(a / np.linalg.norm(a))


ANNA, BEN, CARL, DORA = _unit(1, 0, 0, 0), _unit(0, 1, 0, 0), _unit(0, 0, 1, 0), _unit(0, 0, 0, 1)


def _meeting(root: Path, name: str, speakers: dict, invited: list[str], *, room: bool = False) -> RecordingPaths:
    """``speakers``: label → (voice, seconds of talk)."""
    paths = RecordingPaths(root / name)
    paths.folder.mkdir(parents=True)
    paths.meta.write_text(json.dumps({"start_time": T0.isoformat(), "duration_seconds": 3600}))
    turns, transcript, t = [], [], 0.0
    for label, (_, talk) in speakers.items():
        turns.append({"speaker": label, "start": t, "end": t + talk})
        transcript.append({"speaker": label, "start": t, "end": t + talk, "text": f"I am {label}."})
        t += talk
    paths.system_turns.write_text(json.dumps(turns))
    paths.transcript_json.write_text(json.dumps(transcript))
    paths.speaker_embeddings.write_text(json.dumps({label: v for label, (v, _) in speakers.items()}))
    attendees = [cal.Attendee("Timo Strauss", "timo@kloud.io", is_self=True)] + [
        cal.Attendee(n, f"{n.split()[0].lower()}@x.com") for n in invited]
    if room:
        attendees.append(cal.Attendee("Room 3", "room@x.com", is_room=True))
    cal.save(paths, cal.Event(name, T0, T0 + timedelta(hours=1), tuple(attendees)))
    return paths


def _names(paths: RecordingPaths) -> dict[str, str]:
    return {u.get("label") or u["speaker"]: u["speaker"] for u in json.loads(paths.transcript_json.read_text())}


def test_a_one_on_one_names_the_other_voice(tmp_path):
    m = _meeting(tmp_path, "2026-10-20T10-00-00", {"SPEAKER_00": (ANNA, 600), "SPEAKER_01": (BEN, 12)}, ["Anna Huber"])
    assert inference.refresh(tmp_path) == 1
    i = inference.load(m)["SPEAKER_00"]
    assert (i["name"], i["rule"], i["confidence"]) == ("Anna Huber", "calendar", 0.9)
    assert "Only Anna Huber was invited" in i["why"]
    assert _names(m)["SPEAKER_00"] == "Anna Huber"
    assert inference.refresh(tmp_path) == 0  # nothing new


def test_a_room_of_several_people_is_never_inferred_to_be_someone(tmp_path):
    from palaver import shared_mic

    m = _meeting(tmp_path, "2026-10-20T10-00-00", {"SPEAKER_00": (ANNA, 600), "SPEAKER_01": (BEN, 12)}, ["Anna Huber"])
    shared_mic.set_lane(m, "SPEAKER_00", True, "Lab")
    inference.refresh(tmp_path)
    assert inference.load(m) == {}
    assert _names(m)["SPEAKER_00"] == "SPEAKER_00"  # rewritten only when an inference changes


def test_a_room_in_the_meeting_leaves_nobody_to_eliminate(tmp_path):
    from palaver import shared_mic

    # Anna may be in the room: the other voice is not her by elimination.
    m = _meeting(tmp_path, "2026-10-20T10-00-00", {"SPEAKER_00": (ANNA, 600), "SPEAKER_01": (BEN, 600)},
                 ["Anna Huber"])
    shared_mic.set_lane(m, "SPEAKER_00", True)
    inference.refresh(tmp_path)
    assert inference.load(m) == {}
    shared_mic.set_lane(m, "SPEAKER_00", False)
    shared_mic.set_lane(m, shared_mic.MIC, True)  # several people at the user's microphone
    inference.refresh(tmp_path)
    assert inference.load(m) == {}


def test_no_guess_when_the_calendar_does_not_say_enough(tmp_path):
    two_voices = _meeting(tmp_path, "2026-10-20T10-00-00",
                          {"SPEAKER_00": (ANNA, 600), "SPEAKER_01": (BEN, 300)}, ["Anna Huber"])
    a_room = _meeting(tmp_path, "2026-10-21T10-00-00", {"SPEAKER_00": (CARL, 600)}, ["Carl Berg"], room=True)
    split = _meeting(tmp_path, "2026-10-22T10-00-00",  # 25 s of another voice: maybe Dora split in two
                     {"SPEAKER_00": (DORA, 100), "SPEAKER_01": (_unit(0.1, 0.2, 0.3, 1), 25)}, ["Dora Klein"])
    inference.refresh(tmp_path)
    assert not any(inference.load(p) for p in (two_voices, a_room, split))


def test_elimination_rests_on_names_and_falls_with_them(tmp_path):
    m = _meeting(tmp_path, "2026-10-20T10-00-00",
                 {"SPEAKER_00": (ANNA, 300), "SPEAKER_01": (BEN, 300)}, ["Anna Huber", "Ben Weiss"])
    api.name_speaker(tmp_path, m.folder.name, "SPEAKER_00", "Anna Huber")
    i = inference.load(m)["SPEAKER_01"]
    assert (i["name"], i["rule"], i["depends"]) == ("Ben Weiss", "elimination", ["2026-10-20T10-00-00:SPEAKER_00"])
    assert i["confidence"] == 0.85

    api.name_speaker(tmp_path, m.folder.name, "SPEAKER_00", "")  # Anna unnamed again
    assert inference.load(m) == {}
    assert _names(m)["SPEAKER_01"] == "SPEAKER_01"


def test_an_inferred_voice_names_itself_elsewhere_and_a_rejection_takes_it_all_back(tmp_path):
    one_on_one = _meeting(tmp_path, "2026-10-20T10-00-00", {"SPEAKER_00": (ANNA, 600)}, ["Anna Huber"])
    group = _meeting(tmp_path, "2026-10-21T10-00-00",
                     {"SPEAKER_00": (BEN, 300), "SPEAKER_01": (_unit(1, 0.1, 0, 0), 300)}, ["Anna Huber", "Ben Weiss"])
    inference.refresh(tmp_path)
    voice = inference.load(group)["SPEAKER_01"]
    assert (voice["name"], voice["rule"]) == ("Anna Huber", "voice")
    assert voice["depends"] == ["2026-10-20T10-00-00:SPEAKER_00"]
    ben = inference.load(group)["SPEAKER_00"]
    assert (ben["name"], ben["rule"], ben["depends"]) == ("Ben Weiss", "elimination", ["2026-10-21T10-00-00:SPEAKER_01"])
    assert ben["confidence"] == round(0.85 * 0.9 * 0.9, 3)

    # "That is not Anna": the 1:1 guess goes, and with it all that followed.
    api.name_speaker(tmp_path, one_on_one.folder.name, "SPEAKER_00", "")
    assert inference.load(one_on_one) == {} and inference.load(group) == {}
    # Not Anna, rather than nobody: another name may still fit this voice (#48).
    assert json.loads(one_on_one.speakers_rejected.read_text()) == {"SPEAKER_00": ["Anna Huber"]}
    assert json.loads(one_on_one.speakers.read_text()) == {}


def test_a_recurring_voice_is_the_invitee_its_meetings_share(tmp_path):
    a = _meeting(tmp_path, "2026-10-20T10-00-00", {"SPEAKER_00": (CARL, 300), "SPEAKER_01": (BEN, 300)},
                 ["Carl Berg", "Ben Weiss"])
    b = _meeting(tmp_path, "2026-10-21T10-00-00", {"SPEAKER_00": (_unit(0.05, 0, 1, 0), 300), "SPEAKER_01": (DORA, 300)},
                 ["Carl Berg", "Dora Klein"])
    inference.refresh(tmp_path)
    assert inference.load(a)["SPEAKER_00"]["rule"] == "intersection"
    assert inference.load(a)["SPEAKER_00"]["name"] == inference.load(b)["SPEAKER_00"]["name"] == "Carl Berg"
    # ... and then the rest by elimination
    assert inference.load(a)["SPEAKER_01"]["name"] == "Ben Weiss"
    assert inference.load(b)["SPEAKER_01"]["name"] == "Dora Klein"


def test_the_window_shows_inferred_names_and_confirming_makes_them_facts(tmp_path):
    m = _meeting(tmp_path, "2026-10-20T10-00-00", {"SPEAKER_00": (ANNA, 600)}, ["Anna Huber"])
    inference.refresh(tmp_path)
    lane = api.get_meeting(tmp_path, m.folder.name, user_name="Timo")["speakers"][1]
    assert lane["name"] == "Anna Huber" and lane["named_by"] == "inferred"
    assert lane["inferred"]["rule"] == "calendar"

    api.name_speaker(tmp_path, m.folder.name, "SPEAKER_00", "Anna Huber")  # ✓
    lane = api.get_meeting(tmp_path, m.folder.name, user_name="Timo")["speakers"][1]
    assert lane["named_by"] == "you" and lane["inferred"] is None
    from palaver.voices import VoiceBank

    assert VoiceBank().names() == {"Anna Huber": 1}  # now in the voice bank
