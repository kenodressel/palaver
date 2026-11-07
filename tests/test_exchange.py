"""Export and import of a meeting as one .zip (#58), with synthetic meetings only."""

import hashlib
import json
import shutil
import stat
import subprocess
import zipfile
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from palaver import exchange, inference, notes, projects, undo
from palaver.models import Utterance
from palaver.paths import RecordingPaths
from palaver.voices import VoiceBank

SR = 16_000
ID = "2026-10-29T10-00-00"
START = "2026-10-29T10:00:00+01:00"
EVENT = {
    "title": "Budget review", "start": "2026-10-29T10:00:00+01:00", "end": "2026-10-29T10:30:00+01:00",
    "uid": "ABC-123", "series": True, "location": "Teams",
    "attendees": [{"name": "Anna Berg", "email": "anna@example.com", "organizer": True, "response": "accepted",
                   "is_self": True},
                  {"name": "Tom Lang", "email": "tom@example.com", "response": "accepted"},
                  {"name": "Timo", "email": "timo@example.com", "response": "accepted"}],
    "link": {"source": "calendar", "confidence": 0.9, "reason": "time match"},
}


def _vector(seed: int) -> list[float]:
    return list(np.random.default_rng(seed).normal(size=64))


def make_meeting(root: Path, name: str = ID, *, start: str = START, event: dict | None = EVENT,
                 user: str = "Anna Berg") -> RecordingPaths:
    """Anna's recording: Tom named by hand, Carla recognized by voice,
    SPEAKER_02 merged into Tom, SPEAKER_03 removed as noise."""
    paths = RecordingPaths(root / name)
    paths.folder.mkdir(parents=True)
    t = np.arange(SR * 60)
    sf.write(str(paths.system_wav), (3000 * np.sin(t / 7)).astype(np.int16), SR, subtype="PCM_16")
    sf.write(str(paths.mic_wav), (2000 * np.sin(t / 3)).astype(np.int16), SR, subtype="PCM_16")
    paths.meta.write_text(json.dumps({"start_time": start, "duration_seconds": 60}))
    paths.language.write_text("de")
    paths.system_turns.write_text(json.dumps([
        {"speaker": "SPEAKER_00", "start": 2.0, "end": 20.0},
        {"speaker": "SPEAKER_01", "start": 21.0, "end": 40.0},
        {"speaker": "SPEAKER_02", "start": 41.0, "end": 44.0},
        {"speaker": "SPEAKER_03", "start": 45.0, "end": 45.5},
    ]))
    utterances = [
        Utterance(user, 0.0, 2.0, "Hallo zusammen."),
        Utterance("Tom", 2.0, 20.0, "Das Budget steht.", label="SPEAKER_00"),
        Utterance("Carla", 21.0, 40.0, "Wir brauchen mehr Zeit.", label="SPEAKER_01"),
        Utterance("SPEAKER_02", 41.0, 44.0, "Genau."),
        Utterance("SPEAKER_03", 45.0, 45.5, "Hm."),
        Utterance(user, 50.0, 55.0, "Dann machen wir das so."),
    ]
    paths.transcript_json.write_text(json.dumps([u.to_dict() for u in utterances]))
    paths.speakers.write_text(json.dumps({"SPEAKER_00": "Tom"}))
    paths.speakers_auto.write_text(json.dumps({"SPEAKER_01": {"name": "Carla", "similarity": 0.9}}))
    paths.speakers_merged.write_text(json.dumps({"SPEAKER_02": "SPEAKER_00"}))
    paths.speakers_ignored.write_text(json.dumps(["SPEAKER_03"]))
    paths.speaker_embeddings.write_text(json.dumps({"SPEAKER_00": _vector(0), "SPEAKER_01": _vector(1),
                                                    "SPEAKER_02": _vector(2), "SPEAKER_03": _vector(3)}))
    if event:
        paths.calendar.write_text(json.dumps(event))
    notes.save(paths, {
        "title": "Budget review", "summary": "SPEAKER_00 presented the budget.",
        "sections": [{"heading": "Budget", "points": [{"text": "It is fixed", "details": []},
                                                      {"text": "From my own notes", "details": [], "mine": True}]}],
        "next_steps": [{"owner": "Tom", "task": "Send the numbers"},
                       {"owner": "Anna Berg", "task": "My private reminder", "mine": True}],
        "decisions": ["Budget approved", "A decision from my notes"], "decisions_mine": [1],
        "speaker_names": [], "transcript_hash": notes.transcript_hash(utterances), "my_notes_hash": "abc",
    })
    # What never leaves: my notes (#44), review, the search index, coach data.
    paths.my_notes.write_text(json.dumps({"paragraphs": [{"text": "SECRET private note", "at": 3}]}))
    paths.review.write_text(json.dumps({"reviewed": "2026-10-29T11:00:00+01:00"}))
    (paths.folder / "search-index.npz").write_bytes(b"index")
    (paths.folder / "coach.json").write_text(json.dumps({"talk": "SECRET coach"}))
    return paths


def export(paths, dest: Path, **kw) -> Path:
    return exchange.export_meeting(paths, dest, user_name="Anna Berg", **kw)


def names_in(file: Path) -> set[str]:
    with zipfile.ZipFile(file) as zf:
        return set(zf.namelist())


def doc(file: Path, name: str):
    with zipfile.ZipFile(file) as zf:
        return json.loads(zf.read(name))


@pytest.fixture
def exported(tmp_path) -> Path:
    paths = make_meeting(tmp_path / "anna")
    return export(paths, tmp_path / "out" / "budget.zip")


# --- export ---------------------------------------------------------------------------


def test_an_export_has_the_fixed_layout_and_a_manifest_with_checksums(exported):
    assert names_in(exported) == {"manifest.json", "meeting/meta.json", "meeting/calendar.json",
                                  "meeting/transcript.json", "meeting/turns.json", "meeting/speakers.json",
                                  "meeting/notes.json"}
    manifest = doc(exported, "manifest.json")
    assert manifest["format"] == 1 and manifest["exported_by"] == "Anna Berg"
    assert manifest["palaver_version"] and manifest["exported_at"]
    with zipfile.ZipFile(exported) as zf:
        for name, entry in manifest["files"].items():
            data = zf.read(name)
            assert entry == {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
    meta = doc(exported, "meeting/meta.json")
    assert meta["start"] == START and meta["duration"] == 60 and meta["title"] == "Budget review"
    assert meta["language"] == "de"


def test_the_exporters_microphone_becomes_a_lane_named_after_them(exported):
    speakers = {s["label"]: s for s in doc(exported, "meeting/speakers.json")}
    assert speakers == {
        "SPEAKER_00": {"label": "SPEAKER_00", "name": "Tom", "how": "hand"},
        "SPEAKER_01": {"label": "SPEAKER_01", "name": "Carla", "how": "voice"},
        "SPEAKER_04": {"label": "SPEAKER_04", "name": "Anna Berg", "how": "exporter"},
    }
    transcript = doc(exported, "meeting/transcript.json")
    assert [(t["label"], t["speaker"]) for t in transcript] == [
        ("SPEAKER_04", "Anna Berg"), ("SPEAKER_00", "Tom"), ("SPEAKER_01", "Carla"), ("SPEAKER_00", "Tom"),
        ("SPEAKER_04", "Anna Berg")]
    turns = doc(exported, "meeting/turns.json")
    assert {t["speaker"] for t in turns} == {"SPEAKER_00", "SPEAKER_01", "SPEAKER_04"}  # merged folded, noise gone
    assert {"speaker": "SPEAKER_04", "start": 50.0, "end": 55.0} in turns


def test_lines_said_to_be_someone_elses_travel_with_their_speaker(tmp_path):
    """#12: a line given to a speaker, to a person without a voice of their
    own, or to the exporter goes out as theirs."""
    paths = make_meeting(tmp_path)
    paths.speakers_lines.write_text(json.dumps([
        {"start": 0.0, "end": 2.0, "from": None, "label": "SPEAKER_00"},
        {"start": 21.0, "end": 40.0, "from": "SPEAKER_01", "name": "Timo Strauß"},
        {"start": 41.0, "end": 44.0, "from": "SPEAKER_02", "me": True, "name": "Anna Berg"},
    ]))
    exported = export(paths, tmp_path / "out.zip")
    transcript = doc(exported, "meeting/transcript.json")
    assert [(t["start"], t["label"], t["speaker"]) for t in transcript] == [
        (0.0, "SPEAKER_00", "Tom"), (2.0, "SPEAKER_00", "Tom"), (21.0, "SPEAKER_05", "Timo Strauß"),
        (41.0, "SPEAKER_04", "Anna Berg"), (50.0, "SPEAKER_04", "Anna Berg")]
    speakers = {s["label"]: s for s in doc(exported, "meeting/speakers.json")}
    assert speakers["SPEAKER_05"] == {"label": "SPEAKER_05", "name": "Timo Strauß", "how": "hand"}
    turns = doc(exported, "meeting/turns.json")
    assert {"speaker": "SPEAKER_05", "start": 21.0, "end": 40.0} in turns
    assert {"speaker": "SPEAKER_04", "start": 41.0, "end": 44.0} in turns
    assert "speakers_lines" not in " ".join(names_in(exported))  # applied, not sent along


def test_own_notes_coach_review_and_indexes_never_leave(exported):
    with zipfile.ZipFile(exported) as zf:
        everything = b"".join(zf.read(n) for n in zf.namelist())
    assert b"SECRET" not in everything and b"reviewed" not in everything
    shared = doc(exported, "meeting/notes.json")
    assert shared["decisions"] == ["Budget approved"]
    assert [s["task"] for s in shared["next_steps"]] == ["Send the numbers"]
    assert [p["text"] for p in shared["sections"][0]["points"]] == ["It is fixed"]
    assert "my_notes_hash" not in shared and "transcript_hash" not in shared and "decisions_mine" not in shared


def test_the_meeting_says_when_its_notes_were_written_with_my_notes_in_view(tmp_path):
    from palaver.webapp import api

    paths = make_meeting(tmp_path / "anna")  # its notes carry a my_notes_hash
    assert api.get_meeting(tmp_path / "anna", ID, user_name="Anna Berg")["notes_from_my_notes"] is True
    meeting_notes = notes.load(paths)
    meeting_notes.pop("my_notes_hash")
    notes.save(paths, meeting_notes)
    assert api.get_meeting(tmp_path / "anna", ID, user_name="Anna Berg")["notes_from_my_notes"] is False


def test_where_the_meeting_was_held_stays_home(exported):
    assert "location" not in doc(exported, "meeting/calendar.json")


def test_notes_can_be_left_out(tmp_path):
    out = export(make_meeting(tmp_path / "anna"), tmp_path / "x.zip", notes=False)
    assert "meeting/notes.json" not in names_in(out)


def test_voices_go_in_only_when_asked_and_only_of_people_named_by_hand_or_voice(tmp_path):
    paths = make_meeting(tmp_path / "anna")
    paths.speakers_inferred.write_text(json.dumps({"SPEAKER_01": {"name": "X", "rule": "calendar", "why": "",
                                                                  "confidence": 0.9}}))
    out = export(paths, tmp_path / "x.zip", voices=True)
    assert {n for n in names_in(out) if n.startswith("voices/")} == {"voices/SPEAKER_00.json", "voices/SPEAKER_01.json"}
    assert doc(out, "voices/SPEAKER_00.json") == {"label": "SPEAKER_00", "name": "Tom", "embedding": _vector(0)}


def test_audio_goes_in_only_when_asked_compressed(tmp_path):
    paths = make_meeting(tmp_path / "anna")
    assert not any(n.startswith("audio/") for n in names_in(export(paths, tmp_path / "a.zip")))
    out = export(paths, tmp_path / "b.zip", audio=True)
    assert {n for n in names_in(out) if n.startswith("audio/")} == {"audio/system.opus", "audio/mic.opus"}
    assert out.stat().st_size < paths.system_wav.stat().st_size


def test_a_meeting_kept_on_this_mac_asks_before_it_exports(tmp_path):
    paths = make_meeting(tmp_path / "anna")
    paths.local_only.write_text("{}")
    with pytest.raises(exchange.KeptOnThisMac):
        export(paths, tmp_path / "x.zip")
    assert not (tmp_path / "x.zip").exists()
    assert export(paths, tmp_path / "x.zip", confirm_local=True).exists()


def test_keep_on_this_mac_travels_with_the_file_and_can_be_lifted_here(tmp_path):
    from palaver.webapp import api

    paths = make_meeting(tmp_path / "anna")
    paths.local_only.write_text("{}")
    out = export(paths, tmp_path / "x.zip", confirm_local=True)
    assert doc(out, "meeting/meta.json")["kept_on_this_mac"] is True
    mine = tmp_path / "timo"
    import_into(mine, out)
    assert api.get_meeting(mine, ID, user_name="Timo")["local_only"] is True
    api.set_local_only(mine, ID, False)
    assert api.get_meeting(mine, ID, user_name="Timo")["local_only"] is False


def test_a_meeting_not_kept_on_this_mac_comes_in_as_any_other(tmp_path, exported):
    assert doc(exported, "meeting/meta.json")["kept_on_this_mac"] is False
    import_into(tmp_path / "timo", exported)
    assert not RecordingPaths(tmp_path / "timo" / ID).local_only.exists()


def test_a_meeting_still_being_processed_is_not_exported(tmp_path):
    paths = make_meeting(tmp_path / "anna")
    paths.transcript_json.unlink()
    with pytest.raises(exchange.NotReady):
        export(paths, tmp_path / "x.zip")


def test_the_file_name_is_date_and_title(tmp_path):
    paths = make_meeting(tmp_path / "anna")
    (paths.folder / "title.json").write_text(json.dumps({"title": "Q3: budget / plan?"}))
    assert exchange.file_name(paths) == "2026-10-29 Q3 budget plan.zip"


# --- import -----------------------------------------------------------------------------


def import_into(root: Path, file: Path, **kw) -> exchange.Imported:
    return exchange.import_package(root, file, user_name="Timo", **kw)


def test_an_import_is_a_meeting_with_the_names_as_hints_named_by_the_exporter(tmp_path, exported):
    from palaver.webapp import api

    mine = tmp_path / "timo"
    result = import_into(mine, exported)
    assert result.id == ID and result.sender == "Anna Berg" and result.matched is None
    m = api.get_meeting(mine, ID, user_name="Timo")
    assert m["status"] == "ready" and m["title"] == "Budget review"
    lanes = {s["label"]: s for s in m["speakers"] if not s["is_user"]}
    assert lanes["SPEAKER_00"]["name"] == "Tom" and lanes["SPEAKER_00"]["named_by"] == "inferred"
    assert lanes["SPEAKER_00"]["inferred"]["rule"] == "imported"
    assert lanes["SPEAKER_00"]["inferred"]["by"] == "Anna Berg"
    assert lanes["SPEAKER_00"]["inferred"]["why"] == "Named by Anna Berg in their recording."
    assert lanes["SPEAKER_04"]["name"] == "Anna Berg"
    assert not any(s["is_user"] for s in m["speakers"])  # Timo said nothing here: no lane of his
    assert [t["speaker"] for t in m["transcript"]][:2] == ["Anna Berg", "Tom"]
    assert m["notes"]["summary"] == "Tom presented the budget." and not m["notes_stale"]
    assert m["imported"]["from"] == "Anna Berg"
    assert m["calendar"]["title"] == "Budget review"
    assert m["calendar"]["link"]["source"] == "imported"
    assert not RecordingPaths(mine / ID).speakers.read_text().strip("{} \n")  # nothing named by the user
    assert not (mine / ".importing").exists()
    [entry] = api.list_meetings(mine)
    assert entry["imported"] == {"from": "Anna Berg"}


def test_the_importer_invited_is_themselves_in_the_event(tmp_path, exported):
    from palaver import calendar_events

    import_into(tmp_path / "timo", exported)
    event = calendar_events.load(RecordingPaths(tmp_path / "timo" / ID))
    assert [a.name for a in event.attendees if a.is_self] == ["Timo"]


def test_inference_keeps_the_hints_of_an_import(tmp_path):
    out = export(make_meeting(tmp_path / "anna"), tmp_path / "x.zip", voices=True)
    import_into(tmp_path / "timo", out)
    inference.refresh(tmp_path / "timo", user_name="Timo", bank=VoiceBank(tmp_path / "bank"))
    assert inference.load(RecordingPaths(tmp_path / "timo" / ID))["SPEAKER_00"]["rule"] == "imported"


def imported_with_voices(root: Path, *, invited: list[str], talk: dict[str, float], hint: dict[str, str]) -> RecordingPaths:
    """An imported meeting whose voices were said yes to, but whose names
    are still the sender's hints."""
    paths = RecordingPaths(root / ID)
    paths.folder.mkdir(parents=True)
    paths.meta.write_text(json.dumps({"start_time": START, "duration_seconds": 600}))
    turns, at = [], 0.0
    for label, seconds in talk.items():
        turns.append({"speaker": label, "start": at, "end": at + seconds})
        at += seconds
    paths.system_turns.write_text(json.dumps(turns))
    paths.transcript_json.write_text(json.dumps([{"speaker": t["speaker"], "start": t["start"], "end": t["end"],
                                                  "text": "Hallo."} for t in turns]))
    paths.speaker_embeddings.write_text(json.dumps({label: _vector(i) for i, label in enumerate(talk)}))
    paths.calendar.write_text(json.dumps({**EVENT, "attendees": [{"name": n, "email": f"{n[0]}@x"} for n in invited]
                                          + [{"name": "Timo", "is_self": True}]}))
    paths.imported.write_text(json.dumps({"from": "Anna", "names": {k: {"name": v, "how": "hand"} for k, v in hint.items()}}))
    return paths


def test_a_hinted_name_counts_as_known_for_the_rules(tmp_path):
    paths = imported_with_voices(tmp_path, invited=["Tom Lang", "Carla Diaz"], talk={"SPEAKER_00": 60, "SPEAKER_01": 60},
                                 hint={"SPEAKER_00": "Tom Lang"})
    inference.refresh(tmp_path, user_name="Timo", bank=VoiceBank(tmp_path / "bank"))
    found = inference.load(paths)
    assert found["SPEAKER_00"]["rule"] == "imported"
    assert (found["SPEAKER_01"]["name"], found["SPEAKER_01"]["rule"]) == ("Carla Diaz", "elimination")


def test_no_rule_gives_a_hinted_name_to_a_second_lane(tmp_path):
    paths = imported_with_voices(tmp_path, invited=["Tom Lang"], talk={"SPEAKER_00": 15, "SPEAKER_01": 100},
                                 hint={"SPEAKER_00": "Tom Lang"})
    inference.refresh(tmp_path, user_name="Timo", bank=VoiceBank(tmp_path / "bank"))
    assert set(inference.load(paths)) == {"SPEAKER_00"}


def test_the_exporters_own_title_comes_along_but_is_not_the_users(tmp_path):
    from palaver import titles
    from palaver.webapp import api

    paths = make_meeting(tmp_path / "anna")
    (paths.folder / "title.json").write_text(json.dumps({"title": "Budget with Tom"}))
    mine = tmp_path / "timo"
    import_into(mine, export(paths, tmp_path / "x.zip"))
    here = RecordingPaths(mine / ID)
    assert titles.resolve(here) == ("Budget with Tom", "imported")  # over the event's, under the user's
    assert titles.load(here) is None
    assert api.get_meeting(mine, ID, user_name="Timo")["imported"]["title"] == "Budget with Tom"
    titles.save(here, "My budget")
    assert titles.resolve(here) == ("My budget", "you")
    titles.save(here, "")
    assert titles.resolve(here) == ("Budget with Tom", "imported")


def test_audio_comes_in_as_one_track_the_window_plays(tmp_path):
    out = export(make_meeting(tmp_path / "anna"), tmp_path / "x.zip", audio=True)
    import_into(tmp_path / "timo", out)
    paths = RecordingPaths(tmp_path / "timo" / ID)
    info = sf.info(str(paths.system_wav))
    assert info.samplerate == SR and abs(info.frames / SR - 60) < 0.5
    assert not paths.mic_wav.exists()


def test_tracks_of_different_rates_become_one_system_track(tmp_path):
    paths = make_meeting(tmp_path / "anna")
    t = np.arange(48_000 * 60) / 48_000
    sf.write(str(paths.mic_wav), (0.3 * np.sin(2 * np.pi * 440 * t)).astype(np.float32), 48_000, subtype="PCM_16")
    import_into(tmp_path / "timo", export(paths, tmp_path / "x.zip", audio=True))
    here = RecordingPaths(tmp_path / "timo" / ID)
    audio, rate = sf.read(str(here.system_wav))
    assert rate == SR and abs(len(audio) / SR - 60) < 0.5 and not here.mic_wav.exists()
    spectrum = np.abs(np.fft.rfft(audio[: SR * 4]))
    assert spectrum[440 * 4] > 10 * np.median(spectrum)  # the sender's microphone is in it


def test_a_microphone_alone_becomes_the_system_track(tmp_path):
    paths = make_meeting(tmp_path / "anna")
    paths.system_wav.unlink()
    import_into(tmp_path / "timo", export(paths, tmp_path / "x.zip", audio=True))
    here = RecordingPaths(tmp_path / "timo" / ID)
    assert here.system_wav.exists() and not here.mic_wav.exists()


def test_audio_is_not_decoded_onto_a_nearly_full_disk(tmp_path, monkeypatch):
    out = export(make_meeting(tmp_path / "anna"), tmp_path / "x.zip", audio=True)
    monkeypatch.setattr(exchange, "_free_bytes", lambda path: exchange.MIN_FREE_BYTES + 1000)
    rejected(tmp_path, out, "Not enough free disk space")


def test_voices_go_into_the_voice_bank_only_after_a_yes(tmp_path):
    out = export(make_meeting(tmp_path / "anna"), tmp_path / "x.zip", voices=True)
    result = import_into(tmp_path / "timo", out)
    assert result.voices == [{"label": "SPEAKER_00", "name": "Tom"}, {"label": "SPEAKER_01", "name": "Carla"}]
    bank = VoiceBank()
    assert bank.names() == {}
    paths = RecordingPaths(tmp_path / "timo" / ID)
    assert sorted(exchange.decide_voices(paths, True, user_name="Timo")) == ["Carla", "Tom"]
    assert set(bank.names()) == {"Tom", "Carla"}
    assert exchange.load_record(paths)["voices_pending"] == []
    assert set(json.loads(paths.speaker_embeddings.read_text())) == {"SPEAKER_00", "SPEAKER_01"}
    assert not paths.imported_voices.exists()


def test_pending_voices_are_kept_apart_where_nothing_reads_them(tmp_path):
    """Recognition, inference, suggestions and the voice bank read
    speaker_embeddings.json; voices not yet said yes to are not in it."""
    out = export(make_meeting(tmp_path / "anna"), tmp_path / "x.zip", voices=True)
    import_into(tmp_path / "timo", out)
    paths = RecordingPaths(tmp_path / "timo" / ID)
    assert not paths.speaker_embeddings.exists()
    assert set(json.loads(paths.imported_voices.read_text())) == {"SPEAKER_00", "SPEAKER_01"}


def test_yes_to_a_hint_teaches_no_voice_while_the_voices_wait(tmp_path):
    from palaver.webapp import api

    out = export(make_meeting(tmp_path / "anna"), tmp_path / "x.zip", voices=True)
    mine = tmp_path / "timo"
    import_into(mine, out)
    api.name_speaker(mine, ID, "SPEAKER_00", "Tom")  # "Yes, Tom" on the hint
    assert exchange.load_record(RecordingPaths(mine / ID))["voices_pending"]
    assert "Tom" not in VoiceBank().names()


def test_yes_to_the_voices_skips_a_name_the_user_rejected(tmp_path):
    from palaver.speakers import load_speaker_names
    from palaver.webapp import api

    out = export(make_meeting(tmp_path / "anna"), tmp_path / "x.zip", voices=True)
    mine = tmp_path / "timo"
    import_into(mine, out)
    api.name_speaker(mine, ID, "SPEAKER_01", "")  # "No, not Carla"
    paths = RecordingPaths(mine / ID)
    assert exchange.decide_voices(paths, True, user_name="Timo") == ["Tom"]
    assert load_speaker_names(paths).get("SPEAKER_01") is None
    assert "Carla" not in VoiceBank().names()
    assert set(json.loads(paths.speaker_embeddings.read_text())) == {"SPEAKER_00"}


def test_voices_said_no_to_are_deleted_from_the_meeting(tmp_path):
    out = export(make_meeting(tmp_path / "anna"), tmp_path / "x.zip", voices=True)
    import_into(tmp_path / "timo", out)
    paths = RecordingPaths(tmp_path / "timo" / ID)
    assert exchange.decide_voices(paths, False) == []
    assert not paths.imported_voices.exists() and not paths.speaker_embeddings.exists()
    assert VoiceBank().names() == {}


def test_undoing_an_import_forgets_the_voices_it_taught(tmp_path):
    from palaver.webapp import api

    out = export(make_meeting(tmp_path / "anna"), tmp_path / "x.zip", voices=True)
    mine = tmp_path / "timo"
    answer = api.import_meeting(mine, out, user_name="Timo")
    bank = VoiceBank()
    bank.add("Tom", _vector(0), source=f"{ID}:SPEAKER_00")  # learned from it meanwhile
    bank.add("Zoe", _vector(9), source="2026-10-01T10-00-00:SPEAKER_00")
    api.undo_change(mine, answer["undo"], user_name="Timo")
    assert bank.names() == {"Zoe": 1}


def test_the_same_calendar_occurrence_here_is_a_collision(tmp_path, exported):
    mine = tmp_path / "timo"
    make_meeting(mine, "2026-10-29T10-01-12", start="2026-10-29T10:01:12+01:00",
                 event={**EVENT, "attendees": []}, user="Timo")
    with pytest.raises(exchange.Collision) as err:
        import_into(mine, exported)
    assert err.value.match == exchange.Match("2026-10-29T10-01-12", "event", True)
    assert err.value.sender == "Anna Berg"
    assert sorted(p.name for p in mine.iterdir()) == ["2026-10-29T10-01-12"]  # nothing written


def test_another_occurrence_of_the_series_is_no_match(tmp_path, exported):
    mine = tmp_path / "timo"
    make_meeting(mine, "2026-10-22T10-00-00", start="2026-10-22T10:00:00+02:00",
                 event={**EVENT, "start": "2026-10-22T10:00:00+02:00", "end": "2026-10-22T10:30:00+02:00",
                        "attendees": []}, user="Timo")
    assert import_into(mine, exported).matched is None


def test_more_than_half_overlap_and_a_shared_attendee_is_a_collision(tmp_path, exported):
    mine = tmp_path / "timo"
    other = {**EVENT, "uid": "OTHER", "title": "Budget (my calendar)",
             "attendees": [{"name": "Tom Lang", "email": "TOM@example.com"}]}
    make_meeting(mine, "2026-10-29T10-00-20", start="2026-10-29T10:00:20+01:00", event=other, user="Timo")
    with pytest.raises(exchange.Collision) as err:
        import_into(mine, exported)
    assert err.value.match.how == "overlap"


def test_overlap_without_shared_attendees_is_no_match(tmp_path, exported):
    mine = tmp_path / "timo"
    make_meeting(mine, "2026-10-29T10-00-20", start="2026-10-29T10:00:20+01:00",
                 event={**EVENT, "uid": "OTHER", "attendees": [{"name": "Zoe", "email": "zoe@example.com"}]})
    assert import_into(mine, exported).matched is None


def test_import_as_a_separate_meeting_goes_beside_mine_with_the_same_event(tmp_path, exported):
    from palaver import calendar_events

    mine = tmp_path / "timo"
    my_event = {**EVENT, "title": "Budget review (mine)", "attendees": []}
    make_meeting(mine, ID, event=my_event, user="Timo")
    result = import_into(mine, exported, separate=True)
    assert result.id == f"{ID}-2" and result.matched.id == ID
    assert calendar_events.load(RecordingPaths(mine / result.id)).title == "Budget review (mine)"
    assert exchange.load_record(RecordingPaths(mine / result.id))["beside"] == {"meeting": ID, "how": "event"}


def test_an_earlier_import_of_it_is_a_collision_that_is_not_mine(tmp_path, exported):
    mine = tmp_path / "timo"
    import_into(mine, exported)
    with pytest.raises(exchange.Collision) as err:
        import_into(mine, exported)
    assert err.value.match == exchange.Match(ID, "event", False)


def test_a_calendar_here_links_its_own_copy_of_the_event(tmp_path, exported):
    from palaver import calendar_events

    here = calendar_events.Event.from_dict({**EVENT, "title": "Budget review (Timo's calendar)"})
    import_into(tmp_path / "timo", exported, calendar=lambda start, end: [here])
    assert calendar_events.load(RecordingPaths(tmp_path / "timo" / ID)).title == "Budget review (Timo's calendar)"


def test_the_exporters_project_is_a_hint_kept_with_the_import(tmp_path):
    out = exchange.export_meeting(make_meeting(tmp_path / "anna"), tmp_path / "x.zip", user_name="Anna Berg",
                                  projects=["Northwind"])
    import_into(tmp_path / "timo", out)
    assert exchange.load_record(RecordingPaths(tmp_path / "timo" / ID))["projects"] == ["Northwind"]
    assert projects.ProjectStore().of_meeting(ID) == {}  # sorted here, not taken over


# --- the file is untrusted ------------------------------------------------------------------


def repack(src: Path, dst: Path, *, change: dict | None = None, manifest: dict | None = None, fix: bool = True,
           extra: list[tuple[zipfile.ZipInfo | str, bytes]] = ()) -> Path:
    """``src`` with entries changed (bytes, or None: left out), checksums
    made to fit (``fix``), the manifest changed, and raw extra entries."""
    with zipfile.ZipFile(src) as zf:
        files = {n: zf.read(n) for n in zf.namelist() if n != "manifest.json"}
        man = json.loads(zf.read("manifest.json"))
    for name, data in (change or {}).items():
        if data is None:
            files.pop(name, None)
            man["files"].pop(name, None)
        else:
            files[name] = data
    if fix:
        man["files"] = {n: {"sha256": hashlib.sha256(d).hexdigest(), "bytes": len(d)} for n, d in files.items()}
    man.update(manifest or {})
    with zipfile.ZipFile(dst, "w") as zf:
        zf.writestr("manifest.json", json.dumps(man))
        for n, d in files.items():
            zf.writestr(n, d)
        for info, d in extra:
            zf.writestr(info, d)
    return dst


def rejected(tmp_path: Path, file: Path, match: str) -> None:
    root = tmp_path / "target"
    root.mkdir(exist_ok=True)
    with pytest.raises(exchange.Rejected, match=match):
        import_into(root, file)
    assert list(root.iterdir()) == []  # nothing written, no staging left


def test_not_a_zip_is_rejected(tmp_path):
    bad = tmp_path / "x.zip"
    bad.write_text("hello")
    rejected(tmp_path, bad, "not a zip")


def test_an_unknown_format_version_is_rejected_with_a_clear_message(tmp_path, exported):
    rejected(tmp_path, repack(exported, tmp_path / "x.zip", manifest={"format": 2}),
             "format 2; this Palaver reads format 1. Update Palaver")


def test_a_file_not_matching_its_checksum_is_rejected(tmp_path, exported):
    transcript = json.dumps([{"start": 0, "end": 1, "text": "forged", "label": "SPEAKER_00"}]).encode()
    rejected(tmp_path, repack(exported, tmp_path / "x.zip", change={"meeting/transcript.json": transcript},
                              fix=False), "does not match its checksum")


def test_a_path_out_of_the_folder_is_rejected(tmp_path, exported):
    rejected(tmp_path, repack(exported, tmp_path / "x.zip", extra=[("../../evil.json", b"{}")]), "unsafe path")
    rejected(tmp_path, repack(exported, tmp_path / "y.zip", extra=[("/etc/evil.json", b"{}")]), "unsafe path")


def test_a_link_is_rejected(tmp_path, exported):
    info = zipfile.ZipInfo("voices/SPEAKER_00.json")
    info.external_attr = (stat.S_IFLNK | 0o777) << 16
    rejected(tmp_path, repack(exported, tmp_path / "x.zip", extra=[(info, b"/etc/passwd")]), "link")


def test_a_file_not_part_of_the_format_is_rejected(tmp_path, exported):
    rejected(tmp_path, repack(exported, tmp_path / "x.zip", extra=[("meeting/run.sh", b"rm -rf ~")]),
             "not part of an exported meeting")


def in_folder(src: Path, dst: Path, folder: str, *, extra: list[tuple[str, bytes]] = ()) -> Path:
    """``src`` the way Finder compresses its unpacked folder again: every
    entry under ``folder/``, the folders listed, AppleDouble files in
    ``__MACOSX/``, a ``.DS_Store``."""
    with zipfile.ZipFile(src) as zf:
        files = {n: zf.read(n) for n in zf.namelist()}
    with zipfile.ZipFile(dst, "w") as zf:
        for d in ("", "meeting/", "voices/", "audio/"):
            if d == "" or any(n.startswith(d) for n in files):
                zf.writestr(f"{folder}/{d}", b"")
        for n, d in files.items():
            zf.writestr(f"{folder}/{n}", d)
            zf.writestr(f"__MACOSX/{folder}/{'/'.join(n.split('/')[:-1] + ['._' + n.split('/')[-1]])}", b"\0\5\26\7")
        zf.writestr(f"{folder}/.DS_Store", b"\0\0\0\1Bud1")
        for n, d in extra:
            zf.writestr(n, d)
    return dst


def test_a_zip_unpacked_and_compressed_again_in_finder_imports(tmp_path):
    out = export(make_meeting(tmp_path / "anna"), tmp_path / "x.zip", audio=True, voices=True)
    again = in_folder(out, tmp_path / "again.zip", "2026-10-29 Q3 budget plan")
    result = import_into(tmp_path / "timo", again)
    assert result.id == ID and result.sender == "Anna Berg"
    assert RecordingPaths(tmp_path / "timo" / ID).system_wav.exists()  # the audio, read under the folder


@pytest.mark.skipif(shutil.which("ditto") is None, reason="macOS only: Finder's Compress is ditto")
def test_a_folder_compressed_by_finder_imports(tmp_path):
    out = export(make_meeting(tmp_path / "anna"), tmp_path / "x.zip", audio=True)
    unpacked = tmp_path / "unpacked" / "2026-10-29 Q3 budget plan"
    subprocess.run(["ditto", "-x", "-k", str(out), str(unpacked)], check=True)
    (unpacked / ".DS_Store").write_bytes(b"\0\0\0\1Bud1")
    subprocess.run(["xattr", "-w", "com.apple.metadata:kMDItemWhereFroms", "x", str(unpacked / "manifest.json")],
                   check=True)  # an attribute becomes a ._ file in __MACOSX/
    again = tmp_path / "again.zip"
    subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(unpacked), str(again)], check=True)
    assert any(n.startswith("__MACOSX/") for n in names_in(again))
    assert import_into(tmp_path / "timo", again).id == ID


def test_a_zip_that_is_not_an_exported_meeting_says_so(tmp_path):
    other = tmp_path / "photos.zip"
    with zipfile.ZipFile(other, "w") as zf:
        zf.writestr("photos/beach.jpg", b"\xff\xd8")
    rejected(tmp_path, other, "not a meeting exported from Palaver")


def test_only_one_folder_around_the_meeting_is_taken(tmp_path, exported):
    two = in_folder(exported, tmp_path / "two.zip", "a", extra=[("b/manifest.json", b"{}")])
    rejected(tmp_path, two, "not a meeting exported from Palaver")
    deeper = in_folder(in_folder(exported, tmp_path / "in.zip", "inner"), tmp_path / "deeper.zip", "outer")
    rejected(tmp_path, deeper, "not a meeting exported from Palaver")


def test_under_the_folder_the_same_rules_hold(tmp_path, exported):
    rejected(tmp_path, in_folder(exported, tmp_path / "a.zip", "m", extra=[("m/meeting/run.sh", b"rm -rf ~")]),
             "not part of an exported meeting")
    rejected(tmp_path, in_folder(exported, tmp_path / "b.zip", "m", extra=[("m/scripts/", b"")]),
             "folder 'm/scripts/'")
    rejected(tmp_path, in_folder(exported, tmp_path / "c.zip", "m", extra=[("__MACOSX/../evil", b"")]),
             "unsafe path")
    rejected(tmp_path, in_folder(exported, tmp_path / "d.zip", "m", extra=[("m/.DS_Store/x.json", b"{}")]),
             "not part of an exported meeting")


def test_a_changed_file_under_the_folder_fails_its_checksum(tmp_path, exported):
    forged = repack(exported, tmp_path / "f.zip", fix=False,
                    change={"meeting/transcript.json": b'[{"start": 0, "end": 1, "text": "x", "label": "SPEAKER_00"}]'})
    rejected(tmp_path, in_folder(forged, tmp_path / "g.zip", "m"), "does not match its checksum")


def test_finder_entries_do_not_count_as_files_but_are_capped(tmp_path, exported):
    junk = [(f"__MACOSX/m/._{i}", b"") for i in range(exchange.MAX_RAW_ENTRIES)]
    rejected(tmp_path, in_folder(exported, tmp_path / "j.zip", "m", extra=junk), "an exported meeting has at most 64")


def test_a_zip_listing_too_many_entries_is_rejected_before_it_is_opened(tmp_path, monkeypatch):
    many = tmp_path / "many.zip"
    with zipfile.ZipFile(many, "w") as zf:
        for i in range(300):
            zf.writestr(f"x{i}", b"")
    monkeypatch.setattr(zipfile, "ZipFile", lambda *a, **k: pytest.fail("opened"))
    rejected(tmp_path, many, "300 entries; an exported meeting has at most 64")


def test_a_zip_with_a_huge_table_of_contents_is_rejected(tmp_path):
    big = tmp_path / "big.zip"
    with zipfile.ZipFile(big, "w") as zf:
        for i in range(3):
            zf.writestr(f"{i}" + "a" * 30_000, b"")
    rejected(tmp_path, big, "table of contents is too large")


def test_a_file_larger_than_any_meeting_is_rejected_before_it_is_read(tmp_path, exported, monkeypatch):
    monkeypatch.setattr(exchange, "MAX_FILE_BYTES", 1000)
    rejected(tmp_path, exported, "The file is too large")


def test_the_web_route_takes_files_as_large_as_the_core_does():
    from palaver.webapp import server

    assert server.MAX_IMPORT_BODY == exchange.MAX_FILE_BYTES


def test_too_many_entries_are_rejected(tmp_path, exported, monkeypatch):
    monkeypatch.setattr(exchange, "MAX_ENTRIES", 5)
    rejected(tmp_path, exported, "at most 5")


def test_a_file_too_large_is_rejected(tmp_path, exported, monkeypatch):
    monkeypatch.setattr(exchange, "MAX_JSON_BYTES", 100)
    rejected(tmp_path, exported, "too large")


def test_too_much_in_total_is_rejected(tmp_path, exported, monkeypatch):
    monkeypatch.setattr(exchange, "MAX_TOTAL_BYTES", 500)
    rejected(tmp_path, exported, "too large")


def test_an_entry_larger_than_its_header_says_is_rejected(tmp_path, exported, monkeypatch):
    real = exchange._cap
    monkeypatch.setattr(exchange, "_entries", lambda zf: ("", {i.filename: i for i in zf.infolist()}))
    monkeypatch.setattr(exchange, "_cap", lambda name: 10 if name == "meeting/transcript.json" else real(name))
    rejected(tmp_path, exported, "larger than it says")


def test_a_json_not_fitting_its_schema_is_rejected_before_anything_is_written(tmp_path, exported):
    transcript = json.dumps([{"start": 0, "end": 1, "text": 42, "label": "SPEAKER_00"}]).encode()
    rejected(tmp_path, repack(exported, tmp_path / "x.zip", change={"meeting/transcript.json": transcript}),
             r"transcript.json\[0\].text is not string")


def test_unknown_keys_are_rejected(tmp_path, exported):
    meta = json.loads(json.dumps(doc(exported, "meeting/meta.json")))
    meta["run"] = "something"
    rejected(tmp_path, repack(exported, tmp_path / "x.zip", change={"meeting/meta.json": json.dumps(meta).encode()}),
             "which it can't have")


def test_nan_is_rejected(tmp_path, exported):
    rejected(tmp_path, repack(exported, tmp_path / "x.zip",
                              change={"meeting/turns.json": b'[{"speaker": "SPEAKER_00", "start": NaN, "end": 1}]'}),
             "NaN")


def test_a_label_that_is_not_a_speaker_label_is_rejected(tmp_path, exported):
    speakers = json.dumps([{"label": "../../x", "name": "Tom", "how": "hand"}]).encode()
    rejected(tmp_path, repack(exported, tmp_path / "x.zip", change={"meeting/speakers.json": speakers}),
             "not in the expected form")


def test_times_outside_the_meeting_are_rejected(tmp_path, exported):
    turns = json.dumps([{"speaker": "SPEAKER_00", "start": 1, "end": 5000}]).encode()
    rejected(tmp_path, repack(exported, tmp_path / "x.zip", change={"meeting/turns.json": turns}),
             "not within the meeting")


def test_a_missing_required_file_is_rejected(tmp_path, exported):
    rejected(tmp_path, repack(exported, tmp_path / "x.zip", change={"meeting/turns.json": None}), "lacks")


def test_a_file_the_manifest_does_not_list_is_rejected(tmp_path, exported):
    out = repack(exported, tmp_path / "x.zip", fix=False, extra=[("meeting/notes.json", b"{}")],
                 change={"meeting/notes.json": None})
    rejected(tmp_path, out, "not listed")


def test_a_voice_of_someone_not_named_is_rejected(tmp_path, exported):
    voice = json.dumps({"label": "SPEAKER_00", "name": "Mallory", "embedding": _vector(5)}).encode()
    rejected(tmp_path, repack(exported, tmp_path / "x.zip", change={"voices/SPEAKER_00.json": voice}),
             "not the voice of a person named")


def test_an_unusual_compression_is_rejected(tmp_path, exported):
    info = zipfile.ZipInfo("meeting/calendar.json")
    info.compress_type = zipfile.ZIP_BZIP2
    out = repack(exported, tmp_path / "x.zip", change={"meeting/calendar.json": None},
                 manifest={}, extra=[(info, b"{}")])
    rejected(tmp_path, out, "compressed in a way")


def test_a_number_json_can_only_write_as_infinity_is_rejected(tmp_path, exported):
    voice = b'{"label": "SPEAKER_00", "name": "Tom", "embedding": [1e999' + b", 0.5" * 20 + b"]}"
    rejected(tmp_path, repack(exported, tmp_path / "x.zip", change={"voices/SPEAKER_00.json": voice}),
             "not a finite number")


def test_voices_of_another_size_than_here_are_left_out_and_said_so(tmp_path):
    from palaver import people

    anna = make_meeting(tmp_path / "anna")
    emb = json.loads(anna.speaker_embeddings.read_text())
    anna.speaker_embeddings.write_text(json.dumps({k: v + v for k, v in emb.items()}))  # 128, here 64
    out = export(anna, tmp_path / "x.zip", voices=True)
    mine = tmp_path / "timo"
    make_meeting(mine, "2026-10-01T10-00-00", start="2026-10-01T10:00:00+01:00", event=None, user="Timo")
    VoiceBank().add("Zoe", [1.0] * 64, source="x:1")
    result = import_into(mine, out)
    assert result.voices == []
    assert result.warnings == ["2 voices were left out: they were made by another voice model than this Mac's."]
    assert not RecordingPaths(mine / ID).imported_voices.exists()
    people.refresh_recognition(mine, user_name="Timo")  # nothing here it can't compare


def test_an_import_whose_follow_up_fails_is_taken_out_again(tmp_path, exported):
    def broken(meeting_id):
        raise RuntimeError("recognition failed")

    mine = tmp_path / "timo"
    with pytest.raises(RuntimeError):
        import_into(mine, exported, after=broken)
    assert not (mine / ID).exists() and not (mine / ".importing").exists()


def test_a_damaged_manifest_is_rejected(tmp_path, exported):
    damaged = tmp_path / "x.zip"
    data = bytearray(exported.read_bytes())
    with zipfile.ZipFile(exported) as zf:
        info = zf.getinfo("manifest.json")
    start = info.header_offset + 30 + len(info.filename.encode()) + len(info.extra)
    data[start + 5:start + 25] = b"\xff" * 20
    damaged.write_bytes(bytes(data))
    rejected(tmp_path, damaged, "damaged")


@pytest.mark.parametrize("when", ["9999-12-31T23:59:59+14:00", "0001-01-01T00:00:00-12:00", "1970-01-01T00:00:00+00:00"])
def test_a_date_out_of_range_is_rejected(tmp_path, exported, when):
    meta = {**doc(exported, "meeting/meta.json"), "start": when, "end": when}
    rejected(tmp_path, repack(exported, tmp_path / "x.zip", change={"meeting/meta.json": json.dumps(meta).encode()}),
             "out of range")


def test_audio_broken_after_its_header_is_rejected(tmp_path):
    out = export(make_meeting(tmp_path / "anna"), tmp_path / "x.zip", audio=True)
    with zipfile.ZipFile(out) as zf:
        opus = bytearray(zf.read("audio/system.opus"))
    opus[300:] = bytes((i * 37) % 256 for i in range(len(opus) - 300))
    rejected(tmp_path, repack(out, tmp_path / "y.zip", change={"audio/system.opus": bytes(opus)}), "audio")


def test_leftovers_of_imports_are_swept_at_start_and_of_exports_on_the_next_export(tmp_path):
    import os
    import time

    from palaver.webapp import api
    from palaver.webapp.server import App, sweep_leftovers

    rec, downloads = tmp_path / "rec", tmp_path / "Downloads"
    old, fresh = rec / ".importing" / "a", rec / ".importing" / "b"
    old_export, other = downloads / ".palaver-export-x1", downloads / "keep.zip"
    for d in (old, fresh, old_export):
        d.mkdir(parents=True)
    other.write_text("mine")
    hours_ago = time.time() - 2 * 3600
    for path in (old, old_export, other):
        os.utime(path, (hours_ago, hours_ago))
    sweep_leftovers(App(rec, "Timo", downloads=downloads))
    # Downloads is not looked at on a start: macOS may ask the user first,
    # and the window's server would wait on that answer, not serving (#58).
    assert not old.exists() and fresh.exists() and old_export.exists() and other.exists()
    # It is swept when the user exports, which writes there anyway.
    meeting = make_meeting(rec)
    api.export_meeting(rec, meeting.folder.name, downloads, user_name="Timo")
    assert not old_export.exists() and other.exists()


def test_audio_that_is_not_audio_is_rejected(tmp_path):
    out = export(make_meeting(tmp_path / "anna"), tmp_path / "x.zip", audio=True)
    rejected(tmp_path, repack(out, tmp_path / "y.zip", change={"audio/system.opus": b"not audio at all"}),
             "can't be read")


# --- undo -----------------------------------------------------------------------------


def test_an_import_can_be_undone_through_the_trash(tmp_path, exported):
    from palaver.webapp import api

    mine = tmp_path / "timo"
    mine.mkdir()
    answer = api.import_meeting(mine, exported, user_name="Timo")
    assert answer["imported"] == ID and (mine / ID).is_dir()
    api.undo_change(mine, answer["undo"], user_name="Timo")
    assert not (mine / ID).exists()
    assert (mine / ".trash" / ID / "transcript.json").exists()
    with pytest.raises(undo.Gone):
        undo.restore(mine, answer["undo"])


# --- MCP ---------------------------------------------------------------------------------


def test_mcp_says_a_meeting_was_imported_and_from_whom(tmp_path, exported):
    from palaver import mcp_server

    import_into(tmp_path / "timo", exported)
    make_meeting(tmp_path / "timo", "2026-10-20T09-00-00", start="2026-10-20T09:00:00+02:00", event=None, user="Timo")
    meetings = mcp_server.Meetings(tmp_path / "timo", "Timo")
    listed = {m["id"]: m for m in meetings.list_meetings()}
    assert listed[ID]["imported_from"] == "Anna Berg" and "imported_from" not in listed["2026-10-20T09-00-00"]
    got = meetings.get_meeting(ID)
    assert got["imported_from"] == "Anna Berg" and got["note"].startswith("Imported from Anna Berg")


# --- CLI ---------------------------------------------------------------------------------


def cli_config(tmp_path: Path, name: str, user: str) -> Path:
    cfg = tmp_path / f"{name}.toml"
    cfg.write_text(f'[user]\nname = "{user}"\n[notion]\ntoken = "ntn_test"\nparent_page_id = "p"\n'
                   f'[recording]\noutput_dir = "{tmp_path / name}"\n[calendar]\nenabled = false\n')
    return cfg


def test_cli_export_and_import_round_trip(tmp_path, capsys, monkeypatch):
    from palaver.cli import main

    monkeypatch.setattr("palaver.settings.user_name", lambda: None)
    make_meeting(tmp_path / "anna")
    out = tmp_path / "budget.zip"
    assert main(["--config", str(cli_config(tmp_path, "anna", "Anna Berg")), "export", ID, "--no-notes", "--voices",
                 "-o", str(out)]) == 0
    assert "Exported transcript and names, voices to" in capsys.readouterr().out
    assert "meeting/notes.json" not in names_in(out) and "voices/SPEAKER_00.json" in names_in(out)
    timo = cli_config(tmp_path, "timo", "Timo")
    assert main(["--config", str(timo), "import", str(out)]) == 0
    printed = capsys.readouterr().out
    assert f"Imported {ID} from Anna Berg." in printed and "SPEAKER_00: Tom (named by Anna Berg" in printed
    assert "Voices not added" in printed and VoiceBank().names() == {}  # no terminal to say yes on
    assert main(["--config", str(timo), "import", str(out)]) == 1  # the same meeting again: kept
    assert "here already" in capsys.readouterr().out
    assert main(["--config", str(timo), "import", str(out), "--separate"]) == 0
    assert (tmp_path / "timo" / f"{ID}-2").is_dir()


def test_cli_export_of_a_meeting_kept_on_this_mac_needs_yes(tmp_path, capsys, monkeypatch):
    from palaver.cli import main

    monkeypatch.setattr("palaver.settings.user_name", lambda: None)
    paths = make_meeting(tmp_path / "anna")
    paths.local_only.write_text("{}")
    cfg = str(cli_config(tmp_path, "anna", "Anna Berg"))
    assert main(["--config", cfg, "export", ID, "-o", str(tmp_path / "x.zip")]) == 1
    assert not (tmp_path / "x.zip").exists()
    assert main(["--config", cfg, "export", ID, "-o", str(tmp_path / "x.zip"), "--yes"]) == 0


def test_cli_import_says_why_a_file_is_rejected(tmp_path, capsys):
    from palaver.cli import main

    bad = tmp_path / "x.zip"
    bad.write_text("nope")
    assert main(["--config", str(cli_config(tmp_path, "timo", "Timo")), "import", str(bad)]) == 1
    assert "Not imported: This is not a zip" in capsys.readouterr().out


def test_an_import_is_built_before_the_projects_are_held(tmp_path, monkeypatch):
    from palaver.webapp import api

    out = export(make_meeting(tmp_path / "anna"), tmp_path / "x.zip", audio=True)
    held = []
    real = exchange._write_audio
    monkeypatch.setattr(exchange, "_write_audio",
                        lambda *a: held.append(api._PROJECTS_LOCK.locked()) or real(*a))
    api.import_meeting(tmp_path / "timo", out, user_name="Timo")
    assert held == [False]


# --- HTTP --------------------------------------------------------------------------------


@pytest.fixture
def server(tmp_path):
    import threading

    from palaver.webapp.server import App, make_server

    make_meeting(tmp_path / "rec", user="Timo")
    app = App(tmp_path / "rec", "Timo", downloads=tmp_path / "Downloads")
    srv = make_server(app, port=0)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield srv
    srv.shutdown()


def call(srv, path, body=None, *, raw: bytes | None = None, content_type="application/json"):
    import urllib.error
    import urllib.request

    port = srv.server_address[1]
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, method="POST",
                                 headers={"Host": f"127.0.0.1:{port}", "Content-Type": content_type})
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as err:
        return err.code, json.loads(err.read())


def test_http_export_saves_to_downloads(server, tmp_path):
    status, answer = call(server, f"/api/meetings/{ID}/export", {"notes": False, "voices": True})
    assert status == 200 and answer["name"] == "2026-10-29 Budget review.zip" and answer["folder"] == "Downloads"
    saved = tmp_path / "Downloads" / answer["name"]
    assert "meeting/notes.json" not in names_in(saved) and "voices/SPEAKER_00.json" in names_in(saved)
    _, again = call(server, f"/api/meetings/{ID}/export", {})
    assert again["name"] == "2026-10-29 Budget review 2.zip"  # never over an earlier one


def test_http_export_of_a_meeting_kept_on_this_mac_asks_first(server, tmp_path):
    (tmp_path / "rec" / ID / "local_only.json").write_text("{}")
    assert call(server, f"/api/meetings/{ID}/export", {}) == (200, {"question": "local_only"})
    assert not (tmp_path / "Downloads").exists()
    status, answer = call(server, f"/api/meetings/{ID}/export", {"confirm_local": True})
    assert status == 200 and answer["name"].endswith(".zip")


def test_http_import_asks_before_going_beside_my_own_recording(server, tmp_path, exported):
    raw = exported.read_bytes()
    status, answer = call(server, "/api/import", raw=raw, content_type="application/octet-stream")
    assert status == 200 and answer["question"] == "collision" and answer["own"] is True
    assert answer["meeting"]["id"] == ID and answer["from"] == "Anna Berg"
    status, answer = call(server, "/api/import?separate=1", raw=raw, content_type="application/octet-stream")
    assert status == 200 and answer["imported"] == f"{ID}-2" and answer["beside"] == ID and answer["undo"]
    status, restored = call(server, "/api/undo", {"token": answer["undo"]})
    assert status == 200 and not (tmp_path / "rec" / f"{ID}-2").exists()


def test_http_import_refuses_json_and_says_why_a_file_is_rejected(server, tmp_path, exported):
    assert call(server, "/api/import", {"file": "x"})[0] == 415
    status, answer = call(server, "/api/import", raw=b"not a zip", content_type="application/octet-stream")
    assert status == 400 and answer["error"].startswith("Not imported: This is not a zip")


def test_http_voices_of_an_import_are_added_on_a_yes(tmp_path, server):
    out = export(make_meeting(tmp_path / "anna", "2026-10-28T09-00-00", start="2026-10-28T09:00:00+01:00", event=None),
                 tmp_path / "x.zip", voices=True)
    _, answer = call(server, "/api/import", raw=out.read_bytes(), content_type="application/octet-stream")
    assert answer["voices"] == [{"label": "SPEAKER_00", "name": "Tom"}, {"label": "SPEAKER_01", "name": "Carla"}]
    before = VoiceBank().names()  # Tom, from the user's own meeting (named by hand there)
    assert "Carla" not in before
    status, meeting = call(server, f"/api/meetings/{answer['imported']}/imported-voices", {"add": True})
    assert status == 200 and meeting["imported"]["voices"] == [] and VoiceBank().names()["Carla"] == 1
    call(server, "/api/undo", {"token": meeting["undo"]})
    assert VoiceBank().names() == before
