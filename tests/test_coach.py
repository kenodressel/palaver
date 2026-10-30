"""Tests for the speaker coach (#41)."""

import json
from pathlib import Path

from palaver import coach
from palaver.paths import RecordingPaths
from palaver.webapp import api


def _meeting(root: Path, name: str, lines: list[tuple[str, float, float, str]]) -> RecordingPaths:
    paths = RecordingPaths(root / name)
    paths.folder.mkdir(parents=True)
    paths.meta.write_text(json.dumps({"start_time": "2026-10-27T10:00:00+01:00", "duration_seconds": 900}))
    paths.transcript_json.write_text(json.dumps([
        {"speaker": who, "start": s, "end": e, "text": t, **({"label": who} if who.startswith("SPEAKER") else {})}
        for who, s, e, t in lines]))
    paths.system_turns.write_text("[]")
    return paths


LINES = [
    ("Timo", 0, 100, "Also ich habe das halt irgendwie quasi so gedacht, halt ganz anders und irgendwie besser."),
    ("Timo", 101, 200, "Und dann halt nochmal, weil das halt wichtig ist und ich das so sehe, ähm, genau."),
    ("SPEAKER_00", 205, 230, "Okay, verstehe ich, und was machen wir mit dem Budget, das ist ja noch offen?"),
    ("Timo", 228, 240, "Das Budget klären wir morgen mit dem Team, ganz sicher."),  # cuts in at 228
    ("SPEAKER_00", 240.5, 241, "Ja."),
    ("Timo", 245, 250, "Wie siehst du das?"),
    ("SPEAKER_00", 254, 280, "Ich finde das gut, wir sollten aber die Kosten im Blick behalten."),
]


def test_numbers_of_one_meeting(tmp_path):
    p = _meeting(tmp_path, "2026-10-27T10-00-00", LINES)
    r = coach.analyze(p, user_name="Timo", invited=["Anna Huber", "Ben Weiss"], names={"SPEAKER_00": "Anna Huber"})
    assert r["talk"]["people"] == 2 and r["talk"]["fair"] == 0.5
    assert r["talk"]["share"] == round(216 / (216 + 51.5), 3)  # 100 + 99 + 12 + 5 s of mine
    assert r["monologues"] == [{"start": 0, "seconds": 200}]  # one stretch: 0-200 s, a 1 s gap
    assert {f["word"]: f["count"] for f in r["fillers"]["top"]}["halt"] == 4
    assert r["fillers"]["hesitations"] == 1
    assert r["questions"]["count"] == 1 and r["questions"]["open"] == 1 and r["questions"]["wait"] == 4.0
    assert r["questions"]["kept_talking"] == 0
    assert r["interruptions"]["by_me"] == 1 and r["interruptions"]["by_me_at"][0] == {"start": 228, "who": "Anna Huber"}
    assert r["quiet_invitees"] == [{"name": "Ben Weiss", "seconds": 0}]
    assert r["language"] == "de"


def test_a_room_of_several_people_leaves_out_talk_share_monologues_and_quiet_invitees(tmp_path):
    from palaver import shared_mic

    p = _meeting(tmp_path, "2026-10-27T10-00-00", LINES)
    p.system_turns.write_text(json.dumps([{"speaker": "SPEAKER_00", "start": 205, "end": 280}]))
    shared_mic.set_lane(p, "SPEAKER_00", True, "Lab")
    r = coach.analyze(p, user_name="Timo", invited=["Anna Huber", "Ben Weiss"])
    assert r["talk"]["share"] is None and r["talk"]["fair"] is None and r["talk"]["shared"]
    assert r["monologues"] == [] and r["quiet_invitees"] == []
    assert r["questions"]["count"] == 1 and r["fillers"]["hesitations"] == 1  # my own track stays
    said = coach.highlights(r, {"share_1on1": 0.5, "share_group": 0.4, "wpm": 150, "fillers_per_minute": {"de": 1.0},
                                "meetings": 5, "questions_per_hour": 20})
    assert not any(s.startswith(("You talked", "Longest stretch", "Barely heard")) for s in said)


def test_highlights_compare_with_what_is_usual(tmp_path):
    p = _meeting(tmp_path, "2026-10-27T10-00-00", LINES)
    r = coach.analyze(p, user_name="Timo")
    usual = {"share_1on1": 0.5, "share_group": 0.4, "wpm": 150, "fillers_per_minute": {"de": 1.0}, "meetings": 5,
             "questions_per_hour": 20}
    said = coach.highlights(r, usual)
    assert said[0].startswith("You talked 81 % of the time; in 1:1s you usually talk 50 %")
    assert any(s.startswith("Longest stretch without anyone else: 3:20") for s in said)
    assert any("“halt”" in s for s in said)


def test_the_window_gets_numbers_and_an_overview(tmp_path):
    _meeting(tmp_path, "2026-10-27T10-00-00", LINES)
    r = api.coach_meeting(tmp_path, "2026-10-27T10-00-00", user_name="Timo")
    assert r["baseline"]["meetings"] == 1 and r["highlights"]
    o = api.coach_overview(tmp_path, user_name="Timo")
    assert o["meetings"][0]["longest"] == 200 and o["meetings"][0]["questions"] == 1
    assert o["trends"]["weeks"] == [{"week": "2026-10-26", "meetings": 1, "share": 0.807, "wpm": o["meetings"][0]["wpm"],
                                     "fillers": o["meetings"][0]["fillers"]}]
    assert [k["kind"] for k in o["trends"]["kinds"]] == ["1:1"]


def test_results_are_kept_until_the_meeting_changes(tmp_path, monkeypatch):
    p = _meeting(tmp_path, "2026-10-27T10-00-00", LINES)
    calls = []
    real = coach.analyze
    monkeypatch.setattr(coach, "analyze", lambda *a, **kw: calls.append(1) or real(*a, **kw))
    first = coach.result(p, user_name="Timo")
    assert coach.result(p, user_name="Timo") is first and len(calls) == 1
    import os
    st = p.transcript_json.stat()
    os.utime(p.transcript_json, ns=(st.st_atime_ns, st.st_mtime_ns + 10**9))
    coach.result(p, user_name="Timo")
    assert len(calls) == 2


def test_history_has_every_meeting_with_its_day_and_kind(tmp_path):
    _meeting(tmp_path, "2026-10-27T10-00-00", LINES)
    group = LINES + [("SPEAKER_01", 300, 340, "Und ich sehe das auch so, das passt für uns gut.")]
    _meeting(tmp_path, "2026-10-20T10-00-00", group)
    h = coach.history(tmp_path, user_name="Timo")
    assert [(m["id"], m["kind"]) for m in h] == [("2026-10-20T10-00-00", "group"), ("2026-10-27T10-00-00", "1:1")]
    assert h[0]["start"].startswith("2026-10-27")  # meta.json's start_time


def _row(mid, kind, share, wpm, fillers, lang="de", minutes=10.0):
    return {"id": mid, "start": mid[:10] + "T10:00:00+01:00", "kind": kind, "language": lang,
            "minutes_talked": minutes, "talk": {"share": share, "people": 2 if kind == "1:1" else 4},
            "pace": {"wpm": wpm}, "fillers": {"per_minute": fillers}}


def test_trends_per_week_and_per_kind():
    rows = [_row("2026-10-12T10-00-00", "1:1", 0.6, 150, 2.0),
            _row("2026-10-14T10-00-00", "group", 0.2, 130, 1.0),
            _row("2026-10-20T10-00-00", "group", 0.3, 140, 1.5),
            _row("2026-10-21T10-00-00", "group", 0.5, None, None, minutes=1.0)]
    t = coach.trends(rows)
    assert [(w["week"], w["meetings"]) for w in t["weeks"]] == [("2026-10-12", 2), ("2026-10-19", 2)]
    assert t["weeks"][0]["share"] == 0.4 and t["weeks"][0]["wpm"] == 140 and t["weeks"][0]["fillers"] == 1.5
    assert t["weeks"][1]["share"] == 0.4 and t["weeks"][1]["wpm"] == 140  # a meeting without pace leaves it out
    assert t["kinds"] == [
        {"kind": "1:1", "meetings": 1, "share": 0.6, "wpm": 150, "fillers": 2.0},
        {"kind": "group", "meetings": 3, "share": 0.333, "wpm": 135, "fillers": 1.25}]


def test_only_the_last_weeks():
    rows = [_row(f"2026-{m:02d}-01T10-00-00", "group", 0.3, 140, 1.0) for m in range(1, 11)]
    assert len(coach.trends(rows, weeks=4)["weeks"]) == 4
    assert coach.trends(rows, weeks=4)["weeks"][-1]["week"] == "2026-09-28"


def test_the_baseline_follows_the_recent_meetings():
    old = [{**_row(f"2026-0{m}-01T10-00-00", "1:1", 0.8, 180, 3.0), "questions": {"per_hour": 5}}
           for m in range(1, 10)]
    new = [{**_row(f"2026-10-{d:02d}T10-00-00", "1:1", 0.4, 130, 1.0), "questions": {"per_hour": 5}}
           for d in range(1, 31)]
    base = coach.baseline(old + new)
    assert base["meetings"] == coach.BASELINE_MEETINGS and base["share_1on1"] == 0.4 and base["wpm"] == 130


def test_an_earlier_name_of_mine_is_still_my_lane(tmp_path):
    """#55: after a name change in the setup assistant, meetings recorded
    under the old name still count as mine."""
    from palaver import settings

    p = _meeting(tmp_path, "2026-10-27T10-00-00", LINES)  # recorded as "Timo"
    settings.update({"user_name": "Timo Strauß", "user_aliases": ["Timo"]})
    r = coach.analyze(p, user_name="Timo Strauß", invited=[], names={"SPEAKER_00": "Anna Huber"})
    assert r["talk"]["share"] == round(216 / (216 + 51.5), 3)


def test_history_analyses_at_most_the_last_meetings(tmp_path, monkeypatch):
    for day in range(1, 36):
        _meeting(tmp_path, f"2026-09-{day % 30 + 1:02d}T{day // 30 + 10:02d}-00-00", LINES)
    calls = []
    real = coach.analyze
    monkeypatch.setattr(coach, "analyze", lambda paths, **kw: calls.append(paths.folder.name) or real(paths, **kw))
    h = coach.history(tmp_path, user_name="Timo", limit=coach.BASELINE_MEETINGS)
    assert len(h) == 30 and len(calls) == 30
    assert calls == sorted(calls) and calls[-1] == sorted(p.name for p in tmp_path.iterdir())[-1]


def test_the_baseline_is_kept_on_disk(tmp_path, monkeypatch):
    _meeting(tmp_path, "2026-10-27T10-00-00", LINES)
    assert coach.load_baseline() is None
    saved = coach.refresh_baseline(tmp_path, user_name="Timo")
    assert saved["meetings"] == 1
    monkeypatch.setattr(coach, "history", lambda *a, **kw: (_ for _ in ()).throw(AssertionError("read meetings")))
    assert coach.load_baseline() == saved


def test_process_refreshes_the_baseline(tmp_path, monkeypatch):
    from palaver import cli

    done = []
    monkeypatch.setattr(cli, "_process", lambda *a, **kw: 0)
    monkeypatch.setattr(coach, "refresh_baseline", lambda output_dir, *, user_name: done.append((output_dir, user_name)))
    folder = tmp_path / "2026-10-27T10-00-00"
    folder.mkdir()
    cfg = type("Cfg", (), {"output_dir": tmp_path, "user_name": "Timo"})()
    monkeypatch.setattr(cli, "_load_cfg", lambda args: cfg)
    assert cli.main(["--no-notify", "process", str(folder)]) == 0
    assert done == [(tmp_path, "Timo")]
