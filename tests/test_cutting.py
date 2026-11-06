"""Tests for splitting and joining recordings (#40)."""

import json
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np
import soundfile as sf

from palaver import cutting
from palaver.paths import RecordingPaths
from palaver.webapp import api

SR = 16_000
T0 = datetime.fromisoformat("2026-10-21T15:34:00+02:00")
ANNA, BEN = [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]


def _recording(root: Path, start: datetime, seconds: int, speakers: list[tuple[str, float, float, list[float]]],
               *, user_line: tuple[float, str] | None = None) -> RecordingPaths:
    """``speakers``: (label, start, end, voice) — one turn and one line each."""
    paths = RecordingPaths(root / start.strftime("%Y-%m-%dT%H-%M-%S"))
    paths.folder.mkdir(parents=True)
    tone = (np.arange(seconds * SR) % 100).astype(np.int16)  # sample i of the recording = i % 100
    for track in (paths.mic_raw_wav, paths.mic_wav, paths.system_wav):
        sf.write(str(track), tone, SR, subtype="PCM_16")
    paths.meta.write_text(json.dumps({"start_time": start.isoformat(), "duration_seconds": seconds,
                                      "end_time": (start + timedelta(seconds=seconds)).isoformat()}))
    turns = [{"speaker": label, "start": s, "end": e} for label, s, e, _ in speakers]
    segments = [{"start": s, "end": e, "text": f"I am {label}.", "speaker": None,
                 "words": [{"text": "I", "start": s, "end": s + 0.5}]} for label, s, e, _ in speakers]
    lines = [{"speaker": label, "start": s, "end": e, "text": f"I am {label}."} for label, s, e, _ in speakers]
    if user_line:
        lines.append({"speaker": "Timo", "start": user_line[0], "end": user_line[0] + 2, "text": user_line[1]})
    paths.system_turns.write_text(json.dumps(turns))
    paths.system_segments.write_text(json.dumps(segments))
    paths.mic_segments.write_text("[]")
    paths.transcript_json.write_text(json.dumps(sorted(lines, key=lambda d: d["start"])))
    paths.speaker_embeddings.write_text(json.dumps({label: v for label, _, _, v in speakers}))
    return paths


def test_split_cuts_audio_data_and_names_at_the_moment(tmp_path):
    a = _recording(tmp_path, T0, 60, [("SPEAKER_00", 1, 30, ANNA), ("SPEAKER_01", 41, 59, BEN)])
    a.speakers.write_text(json.dumps({"SPEAKER_00": "Anna", "SPEAKER_01": "Ben"}))
    tail = cutting.split(a, 40)

    assert tail.folder.name == "2026-10-21T15-34-40"
    assert sf.info(str(a.system_wav)).duration == 40 and sf.info(str(tail.system_wav)).duration == 20
    first = sf.read(str(tail.mic_wav), dtype="int16")[0][:3]
    assert list(first) == [(40 * SR + i) % 100 for i in range(3)]  # continues where the cut was
    assert [t["speaker"] for t in json.loads(a.system_turns.read_text())] == ["SPEAKER_00"]
    assert json.loads(tail.system_turns.read_text()) == [{"speaker": "SPEAKER_01", "start": 1.0, "end": 19.0}]
    assert json.loads(tail.system_segments.read_text())[0]["words"][0]["start"] == 1.0
    assert set(json.loads(a.speaker_embeddings.read_text())) == {"SPEAKER_00"}
    assert json.loads(tail.speakers.read_text()) == {"SPEAKER_01": "Ben"}
    assert json.loads(a.meta.read_text())["duration_seconds"] == 40
    assert json.loads(tail.meta.read_text())["start_time"] == (T0 + timedelta(seconds=40)).isoformat()


def test_join_puts_the_tail_in_front_of_the_next_meeting_and_merges_the_same_voice(tmp_path):
    a = _recording(tmp_path, T0, 60, [("SPEAKER_00", 1, 30, ANNA), ("SPEAKER_01", 41, 59, BEN)])
    b = _recording(tmp_path, T0 + timedelta(seconds=62), 30, [("SPEAKER_00", 2, 28, [0.05, 1.0, 0.0])],
                   user_line=(1.0, "Hi Ben."))
    b.speakers.write_text(json.dumps({"SPEAKER_00": "Ben"}))
    tail = cutting.split(a, 40)
    kept = cutting.join(tail, b)

    assert kept.folder == b.folder  # the longer recording keeps the meeting
    assert not tail.folder.exists() and (tmp_path / ".trash" / tail.folder.name).exists()
    assert sf.info(str(kept.system_wav)).duration == 52  # 20 s tail, 2 s gap, 30 s
    meta = json.loads(kept.meta.read_text())
    assert meta["start_time"] == (T0 + timedelta(seconds=40)).isoformat() and meta["duration_seconds"] == 52
    turns = json.loads(kept.system_turns.read_text())
    assert turns == [{"speaker": "SPEAKER_01", "start": 1.0, "end": 19.0},
                     {"speaker": "SPEAKER_00", "start": 24.0, "end": 50.0}]
    assert json.loads(kept.speakers_merged.read_text()) == {"SPEAKER_01": "SPEAKER_00"}  # Ben both times
    lines = json.loads(kept.transcript_json.read_text())
    assert [(round(x["start"]), x["speaker"]) for x in lines] == [(1, "SPEAKER_01"), (23, "Timo"), (24, "SPEAKER_00")]


def test_cut_and_add_to_the_next_meeting_from_the_window(tmp_path):
    a = _recording(tmp_path, T0, 60, [("SPEAKER_00", 1, 30, ANNA), ("SPEAKER_01", 41, 59, BEN)])
    b = _recording(tmp_path, T0 + timedelta(seconds=62), 30, [("SPEAKER_00", 2, 28, [0.05, 1.0, 0.0])])
    b.speakers.write_text(json.dumps({"SPEAKER_00": "Ben"}))
    assert api.get_meeting(tmp_path, a.folder.name, user_name="Timo")["neighbours"]["next"]["id"] == b.folder.name

    result = api.split_meeting(tmp_path, a.folder.name, 40, join_next=True, user_name="Timo")
    assert result == {"id": a.folder.name, "rest": b.folder.name, "joined": True, "undo": result["undo"]}
    m = api.get_meeting(tmp_path, b.folder.name, user_name="Timo")
    assert [t["speaker"] for t in m["transcript"]] == ["Ben", "Ben"]
    assert [s["name"] for s in m["speakers"][1:]] == ["Ben"]  # one lane: the merged voice
    first = api.get_meeting(tmp_path, a.folder.name, user_name="Timo")
    assert [t["speaker"] for t in first["transcript"]] == ["Speaker 1"]
    assert first["duration"] == 40


def test_discard_what_came_after_keeps_the_meeting(tmp_path):
    a = _recording(tmp_path, T0, 60, [("SPEAKER_00", 1, 30, ANNA), ("SPEAKER_01", 41, 59, BEN)])
    a.notes.write_text(json.dumps({"title": "Sync", "summary": "x"}))
    gone = cutting.discard(a, 40, "after")

    assert gone == tmp_path / ".trash" / "2026-10-21T15-34-40"
    assert sf.info(str(a.system_wav)).duration == 40 and a.notes.exists()
    assert [t["speaker"] for t in json.loads(a.system_turns.read_text())] == ["SPEAKER_00"]
    assert [p.name for p in tmp_path.iterdir() if p.name != ".trash"] == [a.folder.name]


def test_discard_what_came_before_keeps_the_meeting_where_it_is(tmp_path):
    a = _recording(tmp_path, T0, 60, [("SPEAKER_00", 1, 30, ANNA), ("SPEAKER_01", 41, 59, BEN)])
    cal_file = a.calendar
    cal_file.write_text('{"title": "Sync"}')
    cutting.discard(a, 40, "before")

    assert a.folder.name == "2026-10-21T15-34-00" and cal_file.read_text() == '{"title": "Sync"}'
    assert sf.info(str(a.system_wav)).duration == 20
    assert json.loads(a.system_turns.read_text()) == [{"speaker": "SPEAKER_01", "start": 1.0, "end": 19.0}]
    assert json.loads(a.meta.read_text())["start_time"] == (T0 + timedelta(seconds=40)).isoformat()
    trashed = RecordingPaths(tmp_path / ".trash" / "2026-10-21T15-34-40")
    assert sf.info(str(trashed.system_wav)).duration == 40  # what came before, kept in the trash


def test_discard_from_the_window(tmp_path):
    a = _recording(tmp_path, T0, 60, [("SPEAKER_00", 1, 30, ANNA), ("SPEAKER_01", 41, 59, BEN)])
    result = api.split_meeting(tmp_path, a.folder.name, 40, discard="after", user_name="Timo")
    assert result["discarded"] == "after"
    assert api.get_meeting(tmp_path, a.folder.name, user_name="Timo")["duration"] == 40


def test_long_silence_before_the_first_word_and_after_the_last_is_offered_for_removal(tmp_path):
    # A one-on-one recorded seven minutes early, and left running five minutes after.
    a = _recording(tmp_path, T0, 1800, [("SPEAKER_00", 420, 900, ANNA), ("SPEAKER_01", 900, 1500, BEN)])
    assert cutting.suggest_trim(a) == [{"edge": "start", "at": 418.0, "seconds": 418.0},
                                       {"edge": "end", "at": 1502.0, "seconds": 298.0}]


def test_a_short_quiet_start_or_end_is_left_alone(tmp_path):
    a = _recording(tmp_path, T0, 600, [("SPEAKER_00", 60, 300, ANNA), ("SPEAKER_01", 300, 540, BEN)])
    assert cutting.suggest_trim(a) == []


def test_silence_said_no_to_is_not_offered_again_and_the_undo_offers_it_again(tmp_path):
    a = _recording(tmp_path, T0, 1800, [("SPEAKER_00", 420, 1790, ANNA)])
    api.dismiss_cut(tmp_path, a.folder.name, what="silence")
    assert cutting.suggest_trim(a) == []
    assert cutting.suggest_cut(a, []) is None  # the other suggestion is untouched by it
    assert not a.cut_dismissed.exists()
    api.dismiss_cut(tmp_path, a.folder.name, False, what="silence")
    assert cutting.suggest_trim(a)[0]["edge"] == "start"


def test_the_window_offers_the_silence_and_removing_it_keeps_the_meeting(tmp_path):
    a = _recording(tmp_path, T0, 1800, [("SPEAKER_00", 420, 1790, ANNA)])
    [s] = api.get_meeting(tmp_path, a.folder.name, user_name="Timo")["silence"]
    api.split_meeting(tmp_path, a.folder.name, s["at"], discard="before", user_name="Timo")
    m = api.get_meeting(tmp_path, a.folder.name, user_name="Timo")
    assert m["duration"] == 1800 - 418 and m["silence"] == []


def _events(*specs):
    from palaver import calendar_events as cal

    me = cal.Attendee("Timo Strauss", "timo@x.com", is_self=True)
    return [cal.Event(title, T0 + timedelta(seconds=s), T0 + timedelta(seconds=e),
                      (me, *[cal.Attendee(p, f"{p.lower()}@x.com") for p in people]), uid=title)
            for title, s, e, people in specs]


def test_a_cut_is_suggested_where_the_next_meeting_starts_and_a_new_voice_comes_in(tmp_path):
    from palaver import calendar_events as cal

    a = _recording(tmp_path, T0, 600, [("SPEAKER_00", 10, 300, ANNA), ("SPEAKER_01", 420, 580, BEN)])
    cal.save(a, _events(("Sync", 0, 400, ["Anna"]))[0])
    events = _events(("Sync", 0, 400, ["Anna"]), ("Checkin", 400, 900, ["Ben"]), ("Reminder", 200, 260, []))

    s = cutting.suggest_cut(a, events)
    assert s["at"] == 420 and s["event"] == "Checkin"
    assert s["why"] == "new voice from then on: Speaker 2; Speaker 1 stopped talking"

    a.cut_dismissed.write_text("{}")
    assert cutting.suggest_cut(a, events) is None


def test_no_cut_is_suggested_when_the_voices_go_on(tmp_path):
    a = _recording(tmp_path, T0, 600, [("SPEAKER_00", 10, 590, ANNA)])
    assert cutting.suggest_cut(a, _events(("Checkin", 400, 900, ["Ben"]))) is None


def test_the_window_suggests_a_cut_from_the_next_recordings_event(tmp_path):
    from palaver import calendar_events as cal

    a = _recording(tmp_path, T0, 600, [("SPEAKER_00", 10, 300, ANNA), ("SPEAKER_01", 420, 580, BEN)])
    b = _recording(tmp_path, T0 + timedelta(seconds=610), 300, [("SPEAKER_00", 2, 280, [0.05, 1.0, 0.0])])
    cal.save(b, _events(("Checkin", 400, 900, ["Ben"]))[0])  # it started while the first one recorded
    s = api.get_meeting(tmp_path, a.folder.name, user_name="Timo")["cut_suggestion"]
    assert s["at"] == 420 and s["event"] == "Checkin"
    api.dismiss_cut(tmp_path, a.folder.name)
    assert api.get_meeting(tmp_path, a.folder.name, user_name="Timo")["cut_suggestion"] is None


def test_names_a_voice_is_not_go_with_the_voice_through_split_and_join(tmp_path):
    a = _recording(tmp_path, T0, 60, [("SPEAKER_00", 1, 30, ANNA), ("SPEAKER_01", 41, 59, BEN)])
    b = _recording(tmp_path, T0 + timedelta(seconds=62), 30, [("SPEAKER_00", 2, 28, [0.0, 0.0, 1.0])])
    a.speakers_rejected.write_text(json.dumps({"SPEAKER_00": ["Tom"], "SPEAKER_01": ["Uli"]}))
    tail = cutting.split(a, 40)
    assert json.loads(a.speakers_rejected.read_text()) == {"SPEAKER_00": ["Tom"]}
    assert json.loads(tail.speakers_rejected.read_text()) == {"SPEAKER_01": ["Uli"]}

    b.speakers_rejected.write_text(json.dumps({"SPEAKER_00": ["Vera"]}))
    kept = cutting.join(tail, b)  # b keeps its labels, the tail's are renumbered after them
    assert json.loads(kept.speakers_rejected.read_text()) == {"SPEAKER_00": ["Vera"], "SPEAKER_01": ["Uli"]}


def test_voices_nobody_knows_go_with_the_voice_through_split_and_join(tmp_path):
    a = _recording(tmp_path, T0, 60, [("SPEAKER_00", 1, 30, ANNA), ("SPEAKER_01", 41, 59, BEN)])
    b = _recording(tmp_path, T0 + timedelta(seconds=62), 30, [("SPEAKER_00", 2, 28, [0.0, 0.0, 1.0])])
    a.speakers_unknown.write_text(json.dumps(["SPEAKER_00", "SPEAKER_01"]))
    tail = cutting.split(a, 40)
    assert json.loads(a.speakers_unknown.read_text()) == ["SPEAKER_00"]
    assert json.loads(tail.speakers_unknown.read_text()) == ["SPEAKER_01"]

    b.speakers_unknown.write_text(json.dumps(["SPEAKER_00"]))
    kept = cutting.join(tail, b)  # b keeps its labels, the tail's are renumbered after them
    assert json.loads(kept.speakers_unknown.read_text()) == ["SPEAKER_00", "SPEAKER_01"]


def test_rooms_and_a_whole_meeting_mark_go_with_split_and_join(tmp_path):
    from palaver import shared_mic

    a = _recording(tmp_path, T0, 60, [("SPEAKER_00", 1, 30, ANNA), ("SPEAKER_01", 41, 59, BEN)])
    b = _recording(tmp_path, T0 + timedelta(seconds=62), 30, [("SPEAKER_00", 2, 28, [0.0, 0.0, 1.0])])
    shared_mic.set_lane(a, "SPEAKER_01", True, "Lab")
    tail = cutting.split(a, 40)
    assert shared_mic.room_names(a) == {} and shared_mic.room_names(tail) == {"SPEAKER_01": "Lab"}

    shared_mic.set_meeting(b, True)
    kept = cutting.join(tail, b)  # b keeps its labels, the tail's are renumbered after them
    assert shared_mic.room_names(kept) == {"SPEAKER_01": "Lab"} and shared_mic.meeting_marked(kept)


def test_a_split_leaves_the_whole_meeting_mark_with_the_head(tmp_path):
    from palaver import shared_mic

    a = _recording(tmp_path, T0, 60, [("SPEAKER_00", 1, 30, ANNA), ("SPEAKER_01", 41, 59, BEN)])
    shared_mic.set_meeting(a, True)
    shared_mic.set_lane(a, shared_mic.MIC, True, "Lab")
    shared_mic.dismiss_suggestion(a)
    tail = cutting.split(a, 40)
    assert shared_mic.meeting_marked(a) and shared_mic.mic_room(a) == "Lab" and shared_mic.load(a).get("dismissed")
    assert not shared_mic.meeting_marked(tail) and shared_mic.mic_room(tail) is None
    assert not shared_mic.load(tail).get("dismissed")


def test_discarding_the_start_keeps_the_meetings_marks_and_the_rooms_after(tmp_path):
    from palaver import shared_mic

    a = _recording(tmp_path, T0, 60, [("SPEAKER_00", 1, 30, ANNA), ("SPEAKER_01", 41, 59, BEN)])
    shared_mic.set_meeting(a, True)
    shared_mic.set_lane(a, "SPEAKER_01", True, "Lab")
    cutting.discard(a, 40, "before")
    assert shared_mic.meeting_marked(a) and shared_mic.room_names(a) == {"SPEAKER_01": "Lab"}


def test_a_room_merged_into_a_voice_by_hand_makes_it_the_room(tmp_path):
    from palaver import shared_mic
    from palaver.speakers import merge_speakers

    a = _recording(tmp_path, T0, 60, [("SPEAKER_00", 1, 30, ANNA), ("SPEAKER_01", 41, 59, BEN)])
    a.meta.write_text(json.dumps({**json.loads(a.meta.read_text())}))
    shared_mic.set_lane(a, "SPEAKER_01", True, "Lab")
    merge_speakers(a, "SPEAKER_01", "SPEAKER_00")
    assert shared_mic.room_names(a)["SPEAKER_00"] == "Lab"
    assert shared_mic.display(a) == {"SPEAKER_00": "Room (Lab)", "SPEAKER_01": "Room (Lab)"}


def test_a_marked_voice_merged_away_still_marks_its_target_as_a_safety_net(tmp_path):
    from palaver import shared_mic

    a = _recording(tmp_path, T0, 60, [("SPEAKER_00", 1, 30, ANNA), ("SPEAKER_01", 41, 59, BEN)])
    shared_mic.set_lane(a, "SPEAKER_01", True, "Lab")
    a.speakers_merged.write_text(json.dumps({"SPEAKER_01": "SPEAKER_00"}))  # merged without follow_merges
    assert shared_mic.display(a) == {"SPEAKER_00": "Room (Lab)", "SPEAKER_01": "Room (Lab)"}


def test_a_room_merged_into_a_voice_by_a_join_makes_it_the_room(tmp_path):
    from palaver import shared_mic

    a = _recording(tmp_path, T0, 30, [("SPEAKER_00", 1, 28, ANNA)])
    b = _recording(tmp_path, T0 + timedelta(seconds=32), 60, [("SPEAKER_00", 2, 58, ANNA)])  # the same voice, longer
    shared_mic.set_lane(a, "SPEAKER_00", True, "Lab")
    kept = cutting.join(a, b)
    assert kept.folder == b.folder
    assert set(shared_mic.display(kept).values()) == {"Room (Lab)"}  # b's own voice too: the room wins


def test_a_meeting_kept_on_this_mac_stays_so_when_split_or_joined(tmp_path):
    from palaver import llm

    a = _recording(tmp_path, T0, 60, [("SPEAKER_00", 1, 30, ANNA), ("SPEAKER_01", 41, 59, BEN)])
    llm.set_local_only(a.folder, True)
    tail = cutting.split(a, 40)
    assert llm.is_local_only(a.folder) and llm.is_local_only(tail.folder)  # both parts

    b = _recording(tmp_path, T0 + timedelta(seconds=62), 30, [("SPEAKER_00", 2, 28, BEN)])
    kept = cutting.join(tail, b)  # b keeps the meeting; tail was local only
    assert kept.folder == b.folder and llm.is_local_only(kept.folder)


def test_discarding_the_start_keeps_the_mark(tmp_path):
    from palaver import llm

    a = _recording(tmp_path, T0, 60, [("SPEAKER_00", 1, 30, ANNA), ("SPEAKER_01", 41, 59, BEN)])
    llm.set_local_only(a.folder, True)
    cutting.discard(a, 20, "before")
    assert llm.is_local_only(a.folder)


# --- a recording continued after a restart (#47) ------------------------------


def _meta(paths: RecordingPaths) -> dict:
    return json.loads(paths.meta.read_text())


def test_join_can_keep_the_first_part_and_marks_the_gap(tmp_path):
    a = _recording(tmp_path, T0, 30, [("SPEAKER_00", 1, 20, ANNA)])
    b = _recording(tmp_path, T0 + timedelta(seconds=39), 60, [("SPEAKER_00", 2, 50, ANNA)])
    b.meta.write_text(json.dumps({**_meta(b), "stop_reason": "call_ended"}))
    kept = cutting.join(a, b, keep=a, gap_why="restart")

    assert kept.folder == a.folder and not b.folder.exists()  # the first part keeps the meeting, though shorter
    meta = _meta(a)
    assert meta["duration_seconds"] == 99 and meta["start_time"] == T0.isoformat()
    assert meta["gaps"] == [{"start": 30.0, "end": 39.0, "why": "restart"}]
    assert meta["stop_reason"] == "call_ended"  # how the meeting ended: its last part
    audio = sf.read(str(a.system_wav), dtype="int16")[0]
    assert len(audio) == 99 * SR and not audio[30 * SR:39 * SR].any()  # silence where nothing was recorded


def test_gaps_move_with_later_joins_and_splits(tmp_path):
    a = _recording(tmp_path, T0, 30, [("SPEAKER_00", 1, 20, ANNA)])
    b = _recording(tmp_path, T0 + timedelta(seconds=39), 30, [("SPEAKER_00", 2, 20, ANNA)])
    c = _recording(tmp_path, T0 + timedelta(seconds=80), 20, [("SPEAKER_00", 2, 10, ANNA)])
    cutting.join(a, b, keep=a, gap_why="restart")
    cutting.join(a, c, keep=a, gap_why="restart")
    assert [(g["start"], g["end"]) for g in _meta(a)["gaps"]] == [(30.0, 39.0), (69.0, 80.0)]

    tail = cutting.split(a, 50)
    assert [(g["start"], g["end"]) for g in _meta(a)["gaps"]] == [(30.0, 39.0)]
    assert [(g["start"], g["end"]) for g in _meta(tail)["gaps"]] == [(19.0, 30.0)]


def test_a_join_by_hand_marks_no_gap(tmp_path):
    a = _recording(tmp_path, T0, 30, [("SPEAKER_00", 1, 20, ANNA)])
    b = _recording(tmp_path, T0 + timedelta(seconds=39), 60, [("SPEAKER_00", 2, 50, ANNA)])
    kept = cutting.join(a, b)
    assert kept.folder == b.folder and "gaps" not in _meta(kept)


def test_audio_problems_move_with_joins_and_splits(tmp_path):
    """Issue #50: "Audio problem at 12:14" stays at 12:14 when parts are joined or cut."""
    a = _recording(tmp_path, T0, 30, [("SPEAKER_00", 1, 20, ANNA)])
    b = _recording(tmp_path, T0 + timedelta(seconds=39), 30, [("SPEAKER_00", 2, 20, ANNA)])
    problem = {"kind": "speed", "track": "system"}
    a.meta.write_text(json.dumps({**_meta(a), "audio_problems": [{**problem, "start": 5.0, "end": 8.0}]}))
    b.meta.write_text(json.dumps({**_meta(b), "audio_problems": [{**problem, "start": 10.0, "end": 25.0}]}))
    cutting.join(a, b, keep=a, gap_why="restart")
    assert [(p["start"], p["end"]) for p in _meta(a)["audio_problems"]] == [(5.0, 8.0), (49.0, 64.0)]

    tail = cutting.split(a, 50)
    assert [(p["start"], p["end"]) for p in _meta(a)["audio_problems"]] == [(5.0, 8.0), (49.0, 50.0)]
    assert [(p["start"], p["end"], p["kind"]) for p in _meta(tail)["audio_problems"]] == [(0.0, 14.0, "speed")]


def test_a_zero_length_audio_problem_moves_like_any_other(tmp_path):
    a = _recording(tmp_path, T0, 30, [("SPEAKER_00", 1, 20, ANNA)])
    a.meta.write_text(json.dumps({**_meta(a), "audio_problems": [
        {"kind": "stalled", "track": "mic", "start": 10.0, "end": 10.0},
        {"kind": "stalled", "track": "mic", "start": 22.0, "end": 22.0}]}))
    tail = cutting.split(a, 20)
    assert [(p["start"], p["end"]) for p in _meta(a)["audio_problems"]] == [(10.0, 10.0)]
    assert [(p["start"], p["end"]) for p in _meta(tail)["audio_problems"]] == [(2.0, 2.0)]


# --- who transcribed it (#54) ------------------------------------------------------------


def _marked(paths: RecordingPaths, **system) -> None:
    paths.transcription.write_text(json.dumps({"system": system}))


def _system_marker(paths: RecordingPaths) -> dict:
    return json.loads(paths.transcription.read_text())["system"]


def test_a_split_carries_who_transcribed_it_to_both_halves(tmp_path):
    a = _recording(tmp_path, T0, 60, [("SPEAKER_00", 1, 30, ANNA), ("SPEAKER_01", 41, 59, BEN)])
    _marked(a, engine="assemblyai", model="universal-3-5-pro", sent_seconds=50.0)
    tail = cutting.split(a, 40)
    assert _system_marker(a)["engine"] == _system_marker(tail)["engine"] == "assemblyai"


def test_a_join_keeps_the_service_only_when_both_parts_had_it(tmp_path):
    a = _recording(tmp_path / "same", T0, 60, [("SPEAKER_00", 1, 30, ANNA)])
    b = _recording(tmp_path / "same", T0 + timedelta(seconds=60), 60, [("SPEAKER_00", 1, 30, BEN)])
    _marked(a, engine="assemblyai", model="universal-3-5-pro", sent_seconds=40.0, usd=0.003)
    _marked(b, engine="assemblyai", model="universal-3-5-pro", sent_seconds=20.0, usd=0.0015)
    kept = cutting.join(a, b)
    marker = _system_marker(kept)
    assert marker["engine"] == "assemblyai" and marker["sent_seconds"] == 60.0

    c = _recording(tmp_path / "mixed", T0, 60, [("SPEAKER_00", 1, 30, ANNA)])
    d = _recording(tmp_path / "mixed", T0 + timedelta(seconds=60), 60, [("SPEAKER_00", 1, 30, BEN)])
    _marked(c, engine="assemblyai", model="universal-3-5-pro", sent_seconds=40.0)
    _marked(d, engine="local")
    kept = cutting.join(c, d)
    assert _system_marker(kept)["engine"] == "mixed"

    e = _recording(tmp_path / "unknown", T0, 60, [("SPEAKER_00", 1, 30, ANNA)])
    f = _recording(tmp_path / "unknown", T0 + timedelta(seconds=60), 60, [("SPEAKER_00", 1, 30, BEN)])
    _marked(e, engine="live")  # the other part has no marker: transcribed before any of this
    assert _system_marker(cutting.join(e, f))["engine"] == "mixed"


def test_a_failed_join_puts_the_marker_back(tmp_path, monkeypatch):
    import pytest

    a = _recording(tmp_path, T0, 60, [("SPEAKER_00", 1, 30, ANNA)])
    b = _recording(tmp_path, T0 + timedelta(seconds=60), 60, [("SPEAKER_00", 1, 30, BEN)])
    _marked(a, engine="assemblyai", sent_seconds=40.0)
    _marked(b, engine="local")
    def killed(*args):
        raise RuntimeError("killed")

    monkeypatch.setattr(cutting, "_with_gaps", killed)
    with pytest.raises(RuntimeError):
        cutting.join(a, b, keep=a)
    assert _system_marker(a)["engine"] == "assemblyai"


def test_my_notes_follow_a_join_and_a_split(tmp_path):
    """A restart mid-call (#47) joins two parts: what the user wrote in either is kept, on one clock."""
    from palaver import my_notes

    a = _recording(tmp_path, T0, 30, [("SPEAKER_00", 1, 20, ANNA)])
    b = _recording(tmp_path, T0 + timedelta(seconds=39), 60, [("SPEAKER_00", 2, 50, ANNA)])
    my_notes.save(a.folder, [{"text": "prep", "at": None}, {"text": "in part one", "at": 10}])
    my_notes.save(b.folder, [{"text": "in part two", "at": 5}])
    kept = cutting.join(a, b, keep=a, gap_why="restart")
    assert my_notes.load(kept.folder) == [{"text": "prep", "at": None}, {"text": "in part one", "at": 10},
                                          {"text": "in part two", "at": 44}]

    tail = cutting.split(kept, 40)
    assert my_notes.load(kept.folder) == [{"text": "prep", "at": None}, {"text": "in part one", "at": 10}]
    assert my_notes.load(tail.folder) == [{"text": "in part two", "at": 4}]


def test_the_users_title_stays_with_the_meeting_through_split_and_join(tmp_path):
    from palaver import titles

    a = _recording(tmp_path, T0, 60, [("SPEAKER_00", 1, 30, ANNA), ("SPEAKER_01", 41, 59, BEN)])
    titles.save(a, "Budget with Anna")
    tail = cutting.split(a, 40)
    assert titles.load(a) == "Budget with Anna" and titles.load(tail) is None  # the rest is another meeting

    titles.save(tail, "Budget, part two")
    b = _recording(tmp_path, T0 + timedelta(seconds=62), 30, [("SPEAKER_00", 2, 28, BEN)])
    kept = cutting.join(tail, b)  # b keeps the meeting, and had no title of its own
    assert kept.folder == b.folder and titles.load(kept) == "Budget, part two"
