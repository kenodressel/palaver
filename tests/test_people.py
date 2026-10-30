"""Tests for people across meetings (issue #22)."""

import json
from pathlib import Path

import numpy as np

from palaver import people
from palaver.paths import RecordingPaths
from palaver.voices import VoiceBank


def _unit(*v):
    a = np.array(v, dtype=float)
    return list(a / np.linalg.norm(a))


ANNA = _unit(1, 0, 0, 0)
BEN = _unit(0, 1, 0, 0)
CARL = _unit(0, 0, 1, 0)


def _meeting(root: Path, name: str, speakers: dict[str, tuple[list[float], float]]) -> RecordingPaths:
    """A processed recording; ``speakers`` maps label → (voice, seconds of talk)."""
    paths = RecordingPaths(root / name)
    paths.folder.mkdir(parents=True)
    paths.meta.write_text(json.dumps({"start_time": "2026-10-27T10:00:00+01:00", "duration_seconds": 600}))
    turns, transcript, t = [], [{"speaker": "Timo", "start": 0.0, "end": 1.0, "text": "Hi."}], 1.0
    for label, (_, talk) in speakers.items():
        turns.append({"speaker": label, "start": t, "end": t + talk})
        transcript.append({"speaker": label, "start": t, "end": t + talk, "text": f"I am {label}."})
        t += talk
    paths.system_turns.write_text(json.dumps(turns))
    paths.transcript_json.write_text(json.dumps(transcript))
    paths.speaker_embeddings.write_text(json.dumps({label: v for label, (v, _) in speakers.items()}))
    return paths


def _names_in(paths: RecordingPaths) -> dict[str, str]:
    return {u.get("label") or u["speaker"]: u["speaker"] for u in json.loads(paths.transcript_json.read_text())}


def test_naming_a_voice_recognizes_it_in_other_meetings(tmp_path: Path):
    m1 = _meeting(tmp_path, "2026-10-20T10-00-00", {"SPEAKER_00": (ANNA, 60), "SPEAKER_01": (BEN, 60)})
    m2 = _meeting(tmp_path, "2026-10-27T10-00-00", {"SPEAKER_00": (BEN, 30), "SPEAKER_01": (_unit(1, 0.05, 0, 0), 40)})

    people.name_voices(tmp_path, [("2026-10-20T10-00-00", "SPEAKER_00")], "Anna")

    assert _names_in(m1)["SPEAKER_00"] == "Anna"
    assert _names_in(m2)["SPEAKER_01"] == "Anna"  # same voice, other meeting
    assert json.loads(m2.speakers_auto.read_text())["SPEAKER_01"]["name"] == "Anna"
    assert _names_in(m2)["SPEAKER_00"] == "SPEAKER_00"  # Ben is still unknown


def test_recurring_unknown_voices_are_grouped_across_meetings(tmp_path: Path):
    _meeting(tmp_path, "2026-10-20T10-00-00", {"SPEAKER_00": (ANNA, 60), "SPEAKER_01": (BEN, 60)})
    _meeting(tmp_path, "2026-10-27T10-00-00", {"SPEAKER_00": (_unit(0.05, 1, 0, 0), 30), "SPEAKER_01": (CARL, 40)})

    unknown = people.directory(tmp_path)["unknown"]

    assert len(unknown) == 1  # Ben twice; Anna and Carl are in one meeting only
    assert sorted((v["meeting"], v["label"]) for v in unknown[0]["voices"]) == [
        ("2026-10-20T10-00-00", "SPEAKER_01"), ("2026-10-27T10-00-00", "SPEAKER_00")]

    people.name_voices(tmp_path, [(v["meeting"], v["label"]) for v in unknown[0]["voices"]], "Ben")
    d = people.directory(tmp_path)
    assert d["unknown"] == []
    [ben] = d["people"]
    assert ben["name"] == "Ben" and len(ben["meetings"]) == 2 and ben["talk_seconds"] == 90


def test_directory_lists_named_people_with_their_meetings(tmp_path: Path):
    m1 = _meeting(tmp_path, "2026-10-20T10-00-00", {"SPEAKER_00": (ANNA, 60), "SPEAKER_01": (BEN, 5)})
    m1.speakers.write_text(json.dumps({"SPEAKER_00": "Anna", "SPEAKER_01": "Ben"}))
    d = people.directory(tmp_path)
    by_name = {p["name"]: p for p in d["people"]}
    assert set(by_name) == {"Anna", "Ben"}  # Ben too, though too short to learn his voice
    assert by_name["Anna"]["meetings"][0] == {"id": "2026-10-20T10-00-00", "label": "SPEAKER_00",
                                             "talk_seconds": 60.0, "named_by": "you"}


def test_renaming_a_person_renames_them_everywhere(tmp_path: Path):
    m1 = _meeting(tmp_path, "2026-10-20T10-00-00", {"SPEAKER_00": (ANNA, 60)})
    m2 = _meeting(tmp_path, "2026-10-27T10-00-00", {"SPEAKER_03": (ANNA, 60)})
    people.name_voices(tmp_path, [("2026-10-20T10-00-00", "SPEAKER_00")], "Ana")
    assert _names_in(m2)["SPEAKER_03"] == "Ana"

    people.rename_person(tmp_path, "Ana", "Anna Müller")

    assert _names_in(m1)["SPEAKER_00"] == "Anna Müller"
    assert _names_in(m2)["SPEAKER_03"] == "Anna Müller"
    assert VoiceBank().names() == {"Anna Müller": 1}


def test_renaming_onto_an_existing_person_merges(tmp_path: Path):
    _meeting(tmp_path, "2026-10-20T10-00-00", {"SPEAKER_00": (ANNA, 60), "SPEAKER_01": (BEN, 60)})
    people.name_voices(tmp_path, [("2026-10-20T10-00-00", "SPEAKER_00")], "Anna")
    people.name_voices(tmp_path, [("2026-10-20T10-00-00", "SPEAKER_01")], "Anna M.")
    people.rename_person(tmp_path, "Anna M.", "Anna")
    assert VoiceBank().names() == {"Anna": 2}
    assert [p["name"] for p in people.directory(tmp_path)["people"]] == ["Anna"]


def test_close_but_uncertain_voices_are_only_suggested(tmp_path: Path):
    _meeting(tmp_path, "2026-10-20T10-00-00", {"SPEAKER_00": (ANNA, 60)})
    m2 = _meeting(tmp_path, "2026-10-27T10-00-00", {"SPEAKER_00": (_unit(1, 0.9, 0, 0), 60)})  # cos 0.74
    people.name_voices(tmp_path, [("2026-10-20T10-00-00", "SPEAKER_00")], "Anna")
    assert _names_in(m2)["SPEAKER_00"] == "SPEAKER_00"
    [(name, similarity)] = people.suggestions(m2)["SPEAKER_00"]
    assert name == "Anna" and 0.65 <= similarity < 0.75


def test_a_meeting_just_started_has_no_suggestions_yet(tmp_path: Path):
    """A live meeting before its first block: no speaker turns yet (the window opened it and failed)."""
    paths = RecordingPaths(tmp_path / "2026-10-30T08-02-13")
    paths.folder.mkdir()
    assert people.suggestions(paths) == {}


def test_a_merged_speaker_counts_as_the_one_it_joined(tmp_path: Path):
    from palaver.speakers import merge_speakers

    m = _meeting(tmp_path, "2026-10-21T16-29-29", {"SPEAKER_00": (ANNA, 60), "SPEAKER_01": (BEN, 20)})
    other = _meeting(tmp_path, "2026-10-27T10-00-00", {"SPEAKER_00": (BEN, 30)})
    merge_speakers(m, "SPEAKER_01", "SPEAKER_00")
    people.name_voices(tmp_path, [("2026-10-21T16-29-29", "SPEAKER_00")], "Konrad")

    [konrad] = people.directory(tmp_path)["people"]
    assert konrad["meetings"] == [{"id": "2026-10-21T16-29-29", "label": "SPEAKER_00",
                                   "talk_seconds": 80.0, "named_by": "you"}]
    assert _names_in(other)["SPEAKER_00"] == "SPEAKER_00"  # Ben's voice did not become Konrad's
    assert {v.label for v in people.voices(tmp_path) if v.meeting == m.folder.name} == {"SPEAKER_00"}


def test_the_people_list_marks_the_user_by_any_of_their_names(tmp_path: Path):
    """#55: an old name kept as an alias is still the user."""
    _meeting(tmp_path, "2026-10-20T10-00-00", {"SPEAKER_00": (ANNA, 60), "SPEAKER_01": (BEN, 60)})
    people.name_voices(tmp_path, [("2026-10-20T10-00-00", "SPEAKER_00")], "Anna")
    people.name_voices(tmp_path, [("2026-10-20T10-00-00", "SPEAKER_01")], "Timo")  # the user's echo, old name
    d = people.directory(tmp_path, me={"timo strauß", "timo"})
    assert {p["name"]: p["you"] for p in d["people"]} == {"Anna": False, "Timo": True}
