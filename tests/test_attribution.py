"""Tests for attribution: why Palaver linked two things, how sure it is, and
what the user's corrections teach it (issue #48)."""

import json
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np
import pytest

from palaver import attribution as attr
from palaver import calendar_events as cal
from palaver import organizations as O
from palaver import projects as P
from palaver import speakers
from palaver.paths import RecordingPaths
from palaver.voices import VoiceBank, recognize
from palaver.webapp import api

from .test_webapp import MEETING, _meeting, _req, server  # noqa: F401 (a fixture)

T0 = datetime.fromisoformat("2026-10-27T15:00:00+01:00")


def _event(title, start_min, end_min, *names, uid="", series=False):
    attendees = tuple(cal.Attendee(n, f"{n.split()[0].lower()}@x.com") for n in names)
    return cal.Event(title, T0 + timedelta(minutes=start_min), T0 + timedelta(minutes=end_min), attendees,
                     uid=uid or title.lower().replace(" ", "-"), series=series)


# --- the record ---------------------------------------------------------------------


def test_a_link_without_fields_is_of_unknown_source_and_not_unsure():
    link = attr.Link.from_dict("event", "Team standup", None)
    assert (link.source, link.confidence, link.reason) == ("unknown", None, "")
    assert not link.unsure and not link.by_you
    assert link.to_dict()["label"] == "Event: Team standup"


def test_low_confidence_is_unsure_unless_the_user_set_it():
    sure = attr.Link("event", "Northwind", "calendar", 0.9, "time match")
    unsure = attr.Link("event", "Northwind", "calendar", 0.6, "time match, 2 events overlapped")
    yours = attr.Link("event", "Northwind", "you", None, "")
    assert not sure.unsure and unsure.unsure and not yours.unsure
    assert unsure.to_dict() == {"kind": "event", "target": "Northwind", "source": "calendar", "confidence": 0.6,
                                "reason": "time match, 2 events overlapped", "unsure": True,
                                "label": "Event: Northwind (time match, 2 events overlapped)"}
    assert yours.to_dict()["label"] == "Event: Northwind (you)"


def test_a_project_is_unsure_until_the_user_confirms_it():
    # Rules and the model only propose projects (#29): sure or not, the user decides.
    assert attr.Link("project", "Foundry", "rules", 0.95, "series").unsure
    assert attr.Link.from_project("Foundry", {"by": "model", "why": "suggested by the model"}).unsure
    link = attr.Link.from_project("Foundry", {"by": "auto", "why": "people like “Sync”", "confidence": 0.72})
    assert (link.source, link.confidence, link.reason) == ("rules", 0.72, "people like “Sync”")
    assert not attr.Link.from_project("Foundry", {"by": "you", "why": ""}).unsure


# --- meeting ↔ calendar event -------------------------------------------------------


def test_one_event_in_the_slot_is_a_sure_time_match():
    d = cal.decide([_event("Receipt case study", 0, 60, "Anna")], T0, T0 + timedelta(minutes=58))
    assert d.event.title == "Receipt case study" and d.question is None
    assert (d.link.source, d.link.confidence, d.link.reason) == ("calendar", 0.9, "time match")
    assert not d.link.unsure


def test_a_clear_winner_among_overlapping_events_is_unsure_and_says_so():
    events = [_event("Northwind", 0, 60, "Anna"), _event("Standup", 45, 75, "Bob")]
    d = cal.decide(events, T0, T0 + timedelta(minutes=60))
    assert d.event.title == "Northwind"
    assert d.link.reason == "time match, 2 events overlapped" and d.link.unsure
    assert d.link.to_dict()["label"] == "Event: Northwind (time match, 2 events overlapped)"


def test_two_events_at_the_same_time_are_a_question_not_a_guess():
    events = [_event("Northwind", 0, 60, "Anna"), _event("Contoso sync", 0, 60, "Bob", "Carl")]
    d = cal.decide(events, T0, T0 + timedelta(minutes=55))
    assert d.event is None and d.link is None
    assert [e.title for e in d.question] == ["Contoso sync", "Northwind"]


def test_a_blocker_without_invitees_does_not_make_it_a_question():
    events = [_event("Focus time", -60, 120), _event("Northwind", 0, 60, "Anna")]
    d = cal.decide(events, T0, T0 + timedelta(minutes=55))
    assert d.event.title == "Northwind"
    assert d.link.reason == "time match, 2 events overlapped; the other has no invitees" and not d.link.unsure


def test_attach_stores_the_link_and_old_files_have_an_unknown_source(tmp_path: Path):
    paths = RecordingPaths(tmp_path)
    cal.attach(paths, lambda s, e: [_event("Receipt case study", 0, 60, "Anna")], T0, T0 + timedelta(minutes=58))
    assert cal.load_link(paths).reason == "time match"
    assert cal.load(paths).title == "Receipt case study"

    cal.save(paths, _event("Old", 0, 60))  # stored before links had a source
    stored = json.loads(paths.calendar.read_text())
    stored.pop("link", None)
    paths.calendar.write_text(json.dumps(stored))
    link = cal.load_link(paths)
    assert (link.target, link.source) == ("Old", "unknown")


def test_attach_asks_when_events_overlap_and_the_answer_sticks(tmp_path: Path):
    paths = RecordingPaths(tmp_path)
    both = lambda s, e: [_event("Northwind", 0, 60, "Anna"), _event("Contoso sync", 0, 60, "Bob")]
    assert cal.attach(paths, both, T0, T0 + timedelta(minutes=55)) is None
    assert cal.load(paths) is None and cal.load_link(paths) is None  # no title, no invitees from a guess
    assert [e.title for e in cal.load_question(paths)] == ["Contoso sync", "Northwind"]

    cal.assign(paths, cal.load_question(paths)[1], attr.Link("event", "Northwind", "you", None, "you chose it"))
    assert cal.load_question(paths) is None
    # Processing again never overrides what the user chose.
    other = lambda s, e: [_event("Contoso sync", 0, 60, "Bob")]
    assert cal.attach(paths, other, T0, T0 + timedelta(minutes=55)).title == "Northwind"
    assert cal.load_link(paths).by_you


def test_none_of_these_sticks(tmp_path: Path):
    paths = RecordingPaths(tmp_path)
    cal.dismiss(paths)
    assert cal.dismissed(paths)
    assert cal.attach(paths, lambda s, e: [_event("Northwind", 0, 60, "Anna")], T0, T0 + timedelta(minutes=55)) is None
    paths.calendar.write_text(json.dumps({"none": True}))  # as stored before links had a source
    assert cal.dismissed(paths)


def test_an_event_rejected_once_is_unsure_and_twice_never_matched_by_time(tmp_path: Path):
    evidence = attr.Evidence(tmp_path / "attributions.json")
    focus = _event("Focus time", 0, 60, "Anna", uid="focus/RID=1", series=True)
    evidence.reject_event(focus, "m1")
    d = cal.decide([focus], T0, T0 + timedelta(minutes=55), evidence=evidence)
    assert d.event == focus and d.link.unsure
    assert d.link.reason == "time match; you said a recording was not this event once"

    evidence.reject_event(focus, "m2")
    evidence.save()
    evidence = attr.Evidence(tmp_path / "attributions.json")
    assert cal.decide([focus], T0, T0 + timedelta(minutes=55), evidence=evidence).event is None
    assert evidence.rules() == [{"kind": "event", "series": "focus", "title": "Focus time", "rejected": 2,
                                 "accepted": 0, "rule": "Not linked by time any more: Focus time — rejected 2×"}]
    # With another candidate, the rejected one is no rival.
    sync = _event("Sync", 0, 60, "Bob")
    assert cal.decide([focus, sync], T0, T0 + timedelta(minutes=55), evidence=evidence).event == sync

    evidence.confirm_event(focus, "m3")  # chosen by hand once: still said no more often
    assert evidence.never_by_time(focus)
    evidence.confirm_event(focus, "m4")  # as often kept as rejected: no rule, and no doubt either
    d = cal.decide([focus], T0, T0 + timedelta(minutes=55), evidence=evidence)
    assert d.event == focus and d.link.reason == "time match"
    assert evidence.rules() == []


def _with_events(tmp_path: Path):
    paths = _meeting(tmp_path)
    start = datetime.fromisoformat(json.loads(paths.meta.read_text())["start_time"])
    planned = cal.Event("Northwind", start, start + timedelta(minutes=60), (cal.Attendee("Anna", "anna@x.com"),),
                        uid="north", series=True)
    adhoc = cal.Event("Ad hoc", start, start + timedelta(minutes=10), (cal.Attendee("Bob", "bob@x.com"),), uid="adhoc")
    return paths, planned, adhoc, (lambda s, e: [planned, adhoc])


def test_the_meeting_shows_the_event_link_and_the_question(tmp_path: Path):
    paths, planned, adhoc, calendar = _with_events(tmp_path)
    cal.ask(paths, [planned, adhoc])
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo", calendar=calendar)
    assert m["calendar"] is None
    q = m["event_question"]
    assert q["reason"] == "2 events overlapped the recording"
    assert [(c["title"], c["invited"]) for c in q["choices"]] == [("Ad hoc", 1), ("Northwind", 1)]

    # Answered without a calendar at hand: the stored candidates are the choices.
    token = api.set_meeting_event(tmp_path, MEETING, None, key=q["choices"][1]["key"])
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert m["event_question"] is None
    assert m["calendar"]["link"]["label"] == "Event: Northwind (you)" and not m["calendar"]["link"]["unsure"]
    api.undo_change(tmp_path, token, user_name="Timo")
    assert api.get_meeting(tmp_path, MEETING, user_name="Timo")["event_question"] is not None


def test_confirming_an_unsure_event_makes_it_the_users(tmp_path: Path):
    paths, planned, adhoc, calendar = _with_events(tmp_path)
    cal.assign(paths, planned, attr.Link("event", "Northwind", "calendar", 0.6, "time match, 2 events overlapped"))
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert m["calendar"]["link"]["unsure"]
    api.set_meeting_event(tmp_path, MEETING, None, key="current")
    assert cal.load_link(paths).by_you and cal.load(paths) == planned


def test_changing_the_event_is_negative_evidence_for_the_one_rejected(tmp_path: Path):
    paths, planned, adhoc, calendar = _with_events(tmp_path)
    cal.assign(paths, planned, attr.Link("event", "Northwind", "calendar", 0.9, "time match"))
    token = api.set_meeting_event(tmp_path, MEETING, calendar, key=adhoc.key)
    assert attr.Evidence().event_rejections(planned) == 1
    api.undo_change(tmp_path, token, user_name="Timo")  # the evidence goes with the change
    assert attr.Evidence().event_rejections(planned) == 0
    api.set_meeting_event(tmp_path, MEETING, calendar, key=None)  # none of these
    assert attr.Evidence().event_rejections(planned) == 1


# --- voice ↔ person ------------------------------------------------------------------


def _unit(*v):
    a = np.array(v, dtype=float)
    return a / np.linalg.norm(a)


def test_recognition_skips_a_name_the_user_rejected_for_a_voice_like_this():
    bank = VoiceBank()
    bank.add("Tom", list(_unit(1, 0, 0)), source="m0:SPEAKER_00")
    voice = list(_unit(1, 0.3, 0))  # 0.96 alike Tom
    assert recognize({"S": voice}, {"S": 60}, bank) == {"S": ("Tom", pytest.approx(0.958, abs=1e-3))}
    rejected = [("Tom", _unit(1, 0.32, 0))]  # "this voice is not Tom", in another meeting
    assert recognize({"S": voice}, {"S": 60}, bank, rejected=rejected) == {}
    far = [("Tom", _unit(0, 1, 0))]  # a different voice rejected as Tom says nothing about this one
    assert "S" in recognize({"S": voice}, {"S": 60}, bank, rejected=far)


def _voice_meeting(root: Path, name: str, voices: dict) -> RecordingPaths:
    paths = RecordingPaths(root / name)
    paths.folder.mkdir(parents=True)
    paths.meta.write_text(json.dumps({"start_time": "2026-10-27T10:00:00+01:00", "duration_seconds": 600}))
    turns, transcript, t = [], [], 0.0
    for label, (_, talk) in voices.items():
        turns.append({"speaker": label, "start": t, "end": t + talk})
        transcript.append({"speaker": label, "start": t, "end": t + talk, "text": f"I am {label}."})
        t += talk
    paths.system_turns.write_text(json.dumps(turns))
    paths.transcript_json.write_text(json.dumps(transcript))
    paths.speaker_embeddings.write_text(json.dumps({label: list(v) for label, (v, _) in voices.items()}))
    return paths


def test_not_tom_sticks_in_this_meeting_and_teaches_the_others(tmp_path: Path):
    from palaver import people

    named = _voice_meeting(tmp_path, "2026-10-20T10-00-00", {"SPEAKER_00": (_unit(1, 0, 0), 60)})
    a = _voice_meeting(tmp_path, "2026-10-21T10-00-00", {"SPEAKER_00": (_unit(1, 0.3, 0), 60)})
    b = _voice_meeting(tmp_path, "2026-10-22T10-00-00", {"SPEAKER_00": (_unit(1, 0.32, 0), 60)})
    people.name_voices(tmp_path, [(named.folder.name, "SPEAKER_00")], "Tom")
    assert speakers.names_in_effect(a) == {"SPEAKER_00": "Tom"} == speakers.names_in_effect(b)

    token = api.name_speaker(tmp_path, a.folder.name, "SPEAKER_00", "")  # Not Tom
    assert speakers.load_rejected_names(a) == {"SPEAKER_00": ["Tom"]}
    assert speakers.names_in_effect(a) == {}
    assert speakers.names_in_effect(b) == {}  # the same voice elsewhere is not Tom either
    assert speakers.load_speaker_names(a) == {}  # rejected one name, not every name
    lane = api.get_meeting(tmp_path, a.folder.name, user_name="Timo")["speakers"][1]
    assert lane["rejected"] == ["Tom"] and lane["name"] is None

    api.undo_change(tmp_path, token, user_name="Timo")
    assert speakers.names_in_effect(a) == {"SPEAKER_00": "Tom"} == speakers.names_in_effect(b)

    api.name_speaker(tmp_path, a.folder.name, "SPEAKER_00", "")
    api.name_speaker(tmp_path, a.folder.name, "SPEAKER_00", "Tom")  # it was Tom after all
    assert speakers.load_rejected_names(a) == {}
    assert speakers.names_in_effect(a) == {"SPEAKER_00": "Tom"}


def test_a_rejected_inferred_name_is_left_out_even_without_voices(tmp_path: Path):
    paths = _meeting(tmp_path)
    paths.speakers_inferred.write_text(json.dumps({"SPEAKER_00": {
        "name": "Carla", "rule": "elimination", "why": "the one invitee left", "confidence": 0.8}}))
    lane = api.get_meeting(tmp_path, MEETING, user_name="Timo")["speakers"][1]
    assert lane["link"] == {"kind": "speaker", "target": "Carla", "source": "inferred", "confidence": 0.8,
                            "reason": "the one invitee left", "unsure": False,
                            "label": "Speaker: Carla (the one invitee left)"}
    api.name_speaker(tmp_path, MEETING, "SPEAKER_00", "")
    lane = api.get_meeting(tmp_path, MEETING, user_name="Timo")["speakers"][1]
    assert lane["name"] is None and lane["named_by"] is None and lane["inferred"] is None


def test_a_name_recognized_by_voice_carries_how_alike(tmp_path: Path):
    paths = _meeting(tmp_path)
    paths.speakers_auto.write_text(json.dumps({"SPEAKER_00": {"name": "Rico", "similarity": 0.7}}))
    link = api.get_meeting(tmp_path, MEETING, user_name="Timo")["speakers"][1]["link"]
    assert (link["source"], link["confidence"], link["reason"], link["unsure"]) == ("voice", 0.7, "voice 70% alike", True)
    api.name_speaker(tmp_path, MEETING, "SPEAKER_00", "")  # not Rico: nor is the notes' guess offered again
    lane = api.get_meeting(tmp_path, MEETING, user_name="Timo")["speakers"][1]
    assert lane["name"] is None and lane["guesses"] == [] and lane["rejected"] == ["Rico"]


# --- person ↔ organization -------------------------------------------------------


def test_the_organization_says_where_it_came_from():
    index = {"anna huber": {"name": "Anna Huber", "email": "anna@contoso.de", "emails": {"anna@contoso.de": 3},
                            "self": False},
             "bob weiss": {"name": "Bob Weiss", "email": "bob@rtv.at",
                           "emails": {"bob@rtv.at": 2, "bob@contoso.de": 2}, "self": False}}
    orgs = O.Organizations()
    anna = O.org_link("Anna Huber", index, orgs)
    assert (anna.target, anna.source, anna.reason, anna.unsure) == ("Contoso", "email", "invited as anna@contoso.de", False)
    bob = O.org_link("Bob Weiss", index, orgs)
    assert bob.unsure and bob.reason == "invited with addresses of 2 organizations"
    assert O.org_link("Anna", index, orgs).reason == "invited as anna@contoso.de; matched by first name"
    orgs.set_person("Bob Weiss", "RTV")
    assert O.org_link("Bob Weiss", index, orgs).by_you
    assert O.org_link("Zoe", index, orgs) is None


# --- meeting ↔ project ----------------------------------------------------------------


def test_rules_keep_how_sure_they_were(tmp_path: Path):
    store = P.ProjectStore()
    pid = store.create("Foundry")
    assert store.assign("m1", pid, by="auto", why="title", confidence=0.72)
    assert store.of_meeting("m1") == {pid: {"by": "auto", "why": "title", "confidence": 0.72}}


# --- what needs the user --------------------------------------------------------------


def test_open_questions_list_overlapping_events_and_unsure_links(tmp_path: Path):
    paths, planned, adhoc, calendar = _with_events(tmp_path)
    cal.ask(paths, [planned, adhoc])
    paths.speakers_auto.write_text(json.dumps({"SPEAKER_00": {"name": "Rico", "similarity": 0.7}}))
    found = api.open_questions(tmp_path, user_name="Timo")
    assert [(q["meeting"], q["kind"]) for q in found] == [(MEETING, "event"), (MEETING, "speaker")]
    event_q, speaker_q = found
    assert event_q["question"] == "Which calendar event was this recording?"
    assert [c["title"] for c in event_q["choices"]] == ["Ad hoc", "Northwind"]
    assert speaker_q["link"]["label"] == "Speaker: Rico (voice 70% alike)"
    assert speaker_q["label"] == "SPEAKER_00"


def test_questions_is_a_pure_function_of_the_meeting():
    m = {"id": "m1", "title": "Sync", "start": "2026-10-27T10:00:00+01:00",
         "event_question": None,
         "calendar": {"link": attr.Link("event", "Sync", "calendar", 0.6, "time match, 2 events overlapped").to_dict()},
         "speakers": [{"label": None, "is_user": True},
                      {"label": "SPEAKER_00", "link": attr.Link("speaker", "Tom", "you", None, "").to_dict()}],
         "projects": [{"id": "p1", "name": "Foundry", "link": attr.Link("project", "Foundry", "rules", 0.7, "title").to_dict()}]}
    assert [(q["kind"], q["link"]["target"]) for q in attr.questions(m)] == [("event", "Sync"), ("project", "Foundry")]


def test_http_questions_and_an_undoable_not_name(server, tmp_path: Path):
    status, _, body = _req(server, "/api/questions")
    assert status == 200 and json.loads(body) == []
    paths = RecordingPaths(tmp_path / MEETING)
    paths.speakers_auto.write_text(json.dumps({"SPEAKER_00": {"name": "Rico", "similarity": 0.7}}))
    status, _, body = _req(server, "/api/questions")
    assert [q["kind"] for q in json.loads(body)] == ["speaker"]

    status, _, body = _req(server, f"/api/meetings/{MEETING}/speakers", method="POST",
                           body={"label": "SPEAKER_00", "name": ""})
    m = json.loads(body)
    assert status == 200 and m["undo"] and m["speakers"][1]["name"] is None
    status, _, body = _req(server, "/api/undo", method="POST", body={"token": m["undo"]})
    assert status == 200
    assert api.get_meeting(tmp_path, MEETING, user_name="Timo")["speakers"][1]["name"] == "Rico"
    status, _, body = _req(server, f"/api/meetings/{MEETING}/speakers", method="POST",
                           body={"label": "SPEAKER_01", "name": "Anna"})
    assert "undo" not in json.loads(body)  # a name typed is set back by the page, as before


def test_an_event_with_only_the_user_on_it_is_a_blocker():
    me = cal.Attendee("Timo", "timo@kloud.io", is_self=True)
    blocker = cal.Event("Focus", T0, T0 + timedelta(minutes=60), (me,), uid="focus")
    call = _event("Northwind", 0, 60, "Anna")
    d = cal.decide([blocker, call], T0, T0 + timedelta(minutes=55))
    assert d.event == call and not d.link.unsure


# --- review fixes ---------------------------------------------------------------------


def _bank_tom_ben():
    """A voice 0.86 alike Tom and 0.76 alike Ben (the reviewer's numbers)."""
    bank = VoiceBank()
    bank.add("Tom", [0.86, float(np.sqrt(1 - 0.86 ** 2)), 0.0], source="m0:SPEAKER_00")
    bank.add("Ben", [0.76, 0.0, float(np.sqrt(1 - 0.76 ** 2))], source="m0:SPEAKER_01")
    return bank, [1.0, 0.0, 0.0]


def test_not_tom_does_not_hand_the_voice_to_the_runner_up():
    bank, voice = _bank_tom_ben()
    assert recognize({"S": voice}, {"S": 60}, bank, invited=["Tom"]) == {"S": ("Tom", pytest.approx(0.86))}
    not_tom = [("Tom", _unit(*voice))]
    assert recognize({"S": voice}, {"S": 60}, bank, rejected=not_tom) == {}  # Ben is a guess by elimination
    # Nor among the invitees, where one left would need no margin.
    assert recognize({"S": voice}, {"S": 60}, bank, invited=["Ben"], rejected=not_tom) == {}
    assert recognize({"S": voice}, {"S": 60}, bank, invited=["Tom", "Ben"], rejected=not_tom) == {}


def test_a_maybe_suggestion_goes_with_not_tom(tmp_path: Path):
    from palaver import people

    named = _voice_meeting(tmp_path, "2026-10-20T10-00-00", {"SPEAKER_00": (_unit(1, 0, 0), 60)})
    a = _voice_meeting(tmp_path, "2026-10-21T10-00-00", {"SPEAKER_00": (_unit(1, 1, 0), 60)})  # 0.71 alike
    people.name_voices(tmp_path, [(named.folder.name, "SPEAKER_00")], "Tom")
    lane = api.get_meeting(tmp_path, a.folder.name, user_name="Timo")["speakers"][1]
    assert [g["name"] for g in lane["maybe"]] == ["Tom"]
    speakers.set_rejected_name(a, "SPEAKER_00", "Tom")
    lane = api.get_meeting(tmp_path, a.folder.name, user_name="Timo")["speakers"][1]
    assert lane["maybe"] == []


def test_processing_again_never_writes_a_rejected_name_back(tmp_path: Path, monkeypatch):
    from palaver import cli

    from .test_cli import _fake_models, _ns, _recording_folder

    folder = tmp_path / "2026-10-20T14-35-17"
    paths = _recording_folder(folder, seconds=40.0)
    VoiceBank().add("Tom", list(_unit(1, 0, 0)), source="m0:SPEAKER_00")
    from palaver.models import Segment, SpeakerTurn

    _fake_models(monkeypatch, turns=[SpeakerTurn("SPEAKER_00", 0.0, 30.0)],
                 embeddings={"SPEAKER_00": list(_unit(1, 0.1, 0))},
                 segments_for=lambda wav: [] if wav == "mic.wav"
                 else [Segment(start=1.0, end=29.0, text="hallo zusammen", speaker=None, words=[])])
    monkeypatch.setattr("palaver.cleanup.drop_silent_segments", lambda segs, wav, db: segs)  # quiet test audio
    args = _ns(folder)
    args.no_notes = True
    assert cli._cmd_process(args) == 0
    assert "Tom" in paths.transcript_md.read_text()

    paths.speakers_rejected.write_text(json.dumps({"SPEAKER_00": ["Tom"]}))  # Not Tom
    for f in (paths.transcript_json, paths.transcript_md):
        f.unlink()
    assert cli._cmd_process(args) == 0
    assert "Tom" not in paths.transcript_md.read_text()
    assert all(u["speaker"] != "Tom" for u in json.loads(paths.transcript_json.read_text()))
    assert "Tom" not in paths.speakers_auto.read_text()


def test_inference_blocks_a_voice_like_a_rejected_one_only_when_more_alike_than_the_person(tmp_path: Path):
    from palaver import inference

    from .test_inference import _meeting as inf_meeting

    # Anna's 1:1 names her voice. In a third meeting a voice 0.95 alike hers is 0.80 alike a
    # voice rejected as Anna: more like Anna than like the rejected one, so still Anna
    # (alike = max(0.75, sim), as recognition decides).
    anna, rejected, third_voice = _unit(1, 0, 0), _unit(0.572, 0.820, 0), _unit(0.95, 0.312, 0)
    assert float(rejected @ third_voice) == pytest.approx(0.80, abs=0.01) and float(rejected @ anna) < 0.75
    one = inf_meeting(tmp_path, "2026-10-20T10-00-00", {"SPEAKER_00": (list(anna), 600)}, ["Anna Huber"])
    other = inf_meeting(tmp_path, "2026-10-21T10-00-00", {"SPEAKER_00": (list(rejected), 600)}, ["Bob Weiss"])
    other.speakers_rejected.write_text(json.dumps({"SPEAKER_00": ["Anna Huber"]}))
    third = inf_meeting(tmp_path, "2026-10-22T10-00-00",
                        {"SPEAKER_00": (list(third_voice), 600), "SPEAKER_01": (list(_unit(0, 0, 1)), 600)},
                        ["Anna Huber", "Carl Berg"])
    inference.refresh(tmp_path)
    assert inference.load(one)["SPEAKER_00"]["name"] == "Anna Huber"
    assert inference.load(third)["SPEAKER_00"]["name"] == "Anna Huber"


# --- events: acceptances, rules, re-attach, catching up --------------------------------


def _jour_fixe(week: int):
    start = T0 + timedelta(days=7 * week)
    return cal.Event("Jour fixe", start, start + timedelta(minutes=60), (cal.Attendee("Anna", "anna@x.com"),),
                     uid=f"jf/RID={week}", series=True)


def _recording_at(root: Path, start: datetime, minutes: int = 55) -> RecordingPaths:
    paths = RecordingPaths(root / start.strftime("%Y-%m-%dT%H-%M-%S"))
    paths.folder.mkdir(parents=True)
    paths.meta.write_text(json.dumps({"start_time": start.isoformat(), "duration_seconds": minutes * 60}))
    return paths


def test_the_weekly_jour_fixe_kept_by_the_user_is_no_rule(tmp_path: Path):
    evidence_path = tmp_path / "attributions.json"
    # Four weeks the Jour fixe was linked by time and kept.
    for week in range(4):
        rec = _recording_at(tmp_path, _jour_fixe(week).start)
        cal.attach(rec, lambda s, e, w=week: [_jour_fixe(w)], *cal.recording_span(rec))
    # Twice an ad-hoc call took its slot: "not the Jour fixe".
    ev = attr.Evidence(evidence_path, output_dir=tmp_path)
    ev.reject_event(_jour_fixe(4), "adhoc-1")
    ev.reject_event(_jour_fixe(5), "adhoc-2")
    ev.save()
    ev = attr.Evidence(evidence_path, output_dir=tmp_path)
    assert ev.acceptances(_jour_fixe(6)) == 4
    assert not ev.never_by_time(_jour_fixe(6)) and ev.rules() == []
    d = cal.decide([_jour_fixe(6)], _jour_fixe(6).start, _jour_fixe(6).end, evidence=ev)
    assert d.event is not None and d.link.reason == "time match" and not d.link.unsure

    # Rejected more often than kept: then it is a rule.
    for n in range(3):
        ev.reject_event(_jour_fixe(7 + n), f"adhoc-{3 + n}")
    assert ev.never_by_time(_jour_fixe(10))
    [rule] = ev.rules()
    assert rule["rule"] == "Not linked by time any more: Jour fixe — rejected 5×"
    ev.forget_rule(rule["series"])
    assert not ev.never_by_time(_jour_fixe(10)) and ev.rules() == []


def test_a_rule_shows_in_the_picker_and_can_be_forgotten_with_undo(tmp_path: Path):
    paths, planned, adhoc, calendar = _with_events(tmp_path)
    ev = attr.Evidence()
    ev.reject_event(planned, "x1")
    ev.reject_event(planned, "x2")
    ev.save()
    found = {e["title"]: e for e in api.meeting_events(tmp_path, MEETING, calendar)}
    assert found["Northwind"]["rule"] == {"series": "north", "text": "Not linked by time any more: Northwind — rejected 2×"}
    assert found["Ad hoc"]["rule"] is None
    token = api.forget_rule(tmp_path, "north")
    assert attr.Evidence().rules() == []
    api.undo_change(tmp_path, token, user_name="Timo")
    assert [r["series"] for r in attr.Evidence().rules()] == ["north"]


def test_re_attaching_never_turns_a_stored_event_into_a_question(tmp_path: Path):
    old = _recording_at(tmp_path, T0)
    legacy = _event("Sync", 0, 60, "Anna", "Bob", uid="x")
    d = legacy.to_dict()
    d["uid"] = ""  # stored before events had an id
    old.calendar.write_text(json.dumps(d))
    both = lambda s, e: [_event("Sync", 0, 60, uid="sync-uid"), _event("Contoso", 0, 60, "Carl")]
    cal.attach_all(tmp_path, both)
    assert cal.load_question(old) is None
    kept = cal.load(old)
    assert kept.title == "Sync" and [a.name for a in kept.attendees] == ["Anna", "Bob"]  # invitees kept

    # The same occurrence found again with its id: it gets the id, keeps its invitees.
    cal.attach_all(tmp_path, lambda s, e: [_event("Sync", 0, 60, uid="sync-uid")])
    kept = cal.load(old)
    assert kept.uid == "sync-uid" and [a.name for a in kept.attendees] == ["Anna", "Bob"]

    fresh = _recording_at(tmp_path, T0 + timedelta(days=1))  # no calendar decision yet: may be asked
    day = lambda s, e: [_event("A", 24 * 60, 24 * 60 + 60, "Anna"), _event("B", 24 * 60, 24 * 60 + 60, "Bob")]
    cal.attach_all(tmp_path, day)
    assert [e.title for e in cal.load_question(fresh)] == ["A", "B"]


def test_answering_the_question_catches_up_on_what_processing_skipped(tmp_path: Path, monkeypatch):
    paths, planned, adhoc, calendar = _with_events(tmp_path)
    cal.ask(paths, [planned, adhoc])
    ran = []
    from palaver import people

    real = people.refresh_recognition
    monkeypatch.setattr(people, "refresh_recognition",
                        lambda *a, **kw: ran.append("recognition") or real(*a, **kw))
    monkeypatch.setattr(P, "assign_by_rules", lambda *a, **kw: ran.append("projects") or [])
    token = api.set_meeting_event(tmp_path, MEETING, None, key=planned.key, user_name="Timo")
    assert ran == ["recognition", "projects"]
    m = api.get_meeting(tmp_path, MEETING, user_name="Timo")
    assert m["calendar"]["invited"] == ["Anna"]  # its invitees are offered for the speakers now
    api.undo_change(tmp_path, token, user_name="Timo")
    assert cal.load_question(paths) is not None and cal.load(paths) is None
    ran.clear()
    api.set_meeting_event(tmp_path, MEETING, None, key=None, user_name="Timo")  # none of these: the same
    assert ran == ["recognition", "projects"]


def test_a_user_chosen_event_wins_over_a_question_when_joining(tmp_path: Path):
    from palaver import cutting

    from .test_cutting import ANNA, BEN, T0 as C0, _recording

    first = _recording(tmp_path, C0, 60, [("SPEAKER_00", 1, 50, ANNA)])
    second = _recording(tmp_path, C0 + timedelta(seconds=62), 30, [("SPEAKER_00", 2, 28, BEN)])
    sync = cal.Event("Sync", C0, C0 + timedelta(minutes=30), uid="sync")
    cal.ask(first, [sync, cal.Event("Other", C0, C0 + timedelta(minutes=30), uid="other")])
    cal.assign(second, sync, attr.Link("event", "Sync", "you"))
    kept = cutting.join(first, second)
    assert kept.folder == first.folder
    assert cal.load(kept) == sync and cal.load_link(kept).by_you and cal.load_question(kept) is None


# --- rejections stay attached ----------------------------------------------------------


def test_renaming_a_person_moves_their_rejections(tmp_path: Path):
    from palaver import people

    a = _voice_meeting(tmp_path, "2026-10-21T10-00-00", {"SPEAKER_00": (_unit(1, 0, 0), 60)})
    speakers.set_rejected_name(a, "SPEAKER_00", "Tom")
    people.rename_person(tmp_path, "Tom", "Thomas Berg")
    assert speakers.load_rejected_names(a) == {"SPEAKER_00": ["Thomas Berg"]}


def test_merging_labels_carries_their_rejections(tmp_path: Path):
    a = _voice_meeting(tmp_path, "2026-10-21T10-00-00",
                       {"SPEAKER_00": (_unit(1, 0, 0), 60), "SPEAKER_01": (_unit(0, 1, 0), 60)})
    speakers.set_rejected_name(a, "SPEAKER_01", "Tom")
    speakers.set_rejected_name(a, "SPEAKER_00", "Uli")
    api.merge_speaker(tmp_path, a.folder.name, "SPEAKER_01", "SPEAKER_00")
    assert speakers.load_rejected_names(a)["SPEAKER_00"] == ["Uli", "Tom"]


def test_undoing_a_typed_name_brings_the_rejection_back(tmp_path: Path):
    paths = _meeting(tmp_path)
    paths.speakers_auto.write_text(json.dumps({"SPEAKER_00": {"name": "Rico", "similarity": 0.8}}))
    api.name_speaker(tmp_path, MEETING, "SPEAKER_00", "")  # not Rico
    token = api.name_speaker(tmp_path, MEETING, "SPEAKER_00", "Rico")  # it was Rico after all
    assert token and speakers.load_rejected_names(paths) == {}
    api.undo_change(tmp_path, token, user_name="Timo")
    assert speakers.load_rejected_names(paths) == {"SPEAKER_00": ["Rico"]}
    assert api.get_meeting(tmp_path, MEETING, user_name="Timo")["speakers"][1]["name"] is None


def test_a_colleague_at_a_client_is_not_unsure():
    index = {"timo": {"name": "Timo", "email": "timo@kloud.io", "emails": {"timo@kloud.io": 5}, "self": True},
             "mia lang": {"name": "Mia Lang", "email": "mia@contoso.de",
                          "emails": {"mia@contoso.de": 4, "mia@kloud.io": 1}, "self": False}}
    link = O.org_link("Mia Lang", index, O.Organizations())
    assert (link.target, link.unsure, link.reason) == ("KLOUD", False, "has an address of your organization")


def test_open_questions_do_not_build_every_meeting(tmp_path: Path, monkeypatch):
    paths, planned, adhoc, calendar = _with_events(tmp_path)
    paths.speakers_auto.write_text(json.dumps({"SPEAKER_00": {"name": "Rico", "similarity": 0.7}}))
    monkeypatch.setattr(api, "_speakers", lambda *a, **kw: pytest.fail("built the speakers"))
    first = api.open_questions(tmp_path, user_name="Timo")
    assert [q["kind"] for q in first] == ["speaker"]
    assert first[0]["link"]["label"] == "Speaker: Rico (voice 70% alike)"
    monkeypatch.setattr(api, "_lane_links", lambda *a, **kw: pytest.fail("not cached"))
    assert api.open_questions(tmp_path, user_name="Timo") == first
