"""The live coach's nudges (#41): at most one every 3 minutes, each kind
can be switched off, thresholds from the user's own baseline."""

from __future__ import annotations

import pytest

from palaver.live_coach import (NUDGE_EVERY, Nudges, pace_and_fillers, quiet_invitees, share_threshold,
                                speech_kind)

ALL = {"talk_share": True, "monologue": True, "quiet_invitee": True, "pace": True, "fillers": True}


def _talk(until=900.0, share=0.5, window=600.0, me=200.0, monologue=0.0, **kw):
    return {"until": until, "share": share, "window": window, "me": me, "others": 200.0,
            "monologue": monologue, "speaking": None, **kw}


class _Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now


def test_talk_share_nudge():
    clock = _Clock()
    n = Nudges(clock=clock)
    assert n.update(_talk(share=0.55)) is None
    nudge = n.update(_talk(share=0.72))
    assert nudge["kind"] == "talk_share"
    assert nudge["text"] == "You've talked 72 % of the last 10 min"


def test_no_talk_share_nudge_in_the_first_minutes():
    n = Nudges(clock=_Clock())
    assert n.update(_talk(until=200, window=200, share=0.9, me=150)) is None


def test_monologue_nudge():
    n = Nudges(clock=_Clock())
    assert n.update(_talk(monologue=170)) is None
    assert n.update(_talk(monologue=245))["text"] == "4-min monologue"


def test_a_shared_microphone_leaves_out_talk_share_monologue_and_quiet_invitees():
    n = Nudges(clock=_Clock(), shared=True)
    assert n.update(_talk(share=0.9, monologue=400), quiet=["Valerie Vogel"], enabled=ALL) is None


def test_a_series_remembered_as_one_microphone_says_so_in_the_context():
    from datetime import datetime

    from palaver import shared_mic
    from palaver.calendar_events import Attendee, Event
    from palaver.live_coach import meeting_context

    at = datetime.fromisoformat("2026-10-30T10:00:00+01:00")
    event = Event("All Hands", at, at, attendees=(Attendee("Valerie Vogel", response="accepted"),),
                  uid="s1", series=True)
    assert "shared" not in meeting_context(event, user_name="Timo", baseline=None)
    shared_mic.remember(event, True)
    assert meeting_context(event, user_name="Timo", baseline=None)["shared"] is True


def test_one_nudge_every_three_minutes():
    clock = _Clock()
    n = Nudges(clock=clock)
    assert n.update(_talk(share=0.8))["kind"] == "talk_share"
    clock.now = 60
    assert n.update(_talk(share=0.8, monologue=200))["kind"] == "talk_share"  # still the one shown
    clock.now = NUDGE_EVERY + 1
    assert n.update(_talk(share=0.8, monologue=200))["kind"] == "monologue"


def test_a_nudge_is_shown_for_two_minutes_then_gone():
    clock = _Clock()
    n = Nudges(clock=clock)
    n.update(_talk(monologue=200))
    clock.now = 119
    assert n.update(_talk())["kind"] == "monologue"
    clock.now = 121
    assert n.update(_talk()) is None


def test_the_same_nudge_waits_until_it_stopped_being_true():
    clock = _Clock()
    n = Nudges(clock=clock)
    assert n.update(_talk(monologue=200))
    clock.now = 400
    assert n.update(_talk(monologue=500)) is None  # the same monologue
    clock.now = 410
    n.update(_talk(monologue=0))
    clock.now = 800
    assert n.update(_talk(monologue=190))["kind"] == "monologue"  # a new one


def test_kinds_switched_off():
    n = Nudges(clock=_Clock())
    off = {**ALL, "monologue": False, "talk_share": False}
    assert n.update(_talk(monologue=300, share=0.9), enabled=off) is None


def test_the_threshold_follows_the_baseline():
    assert share_threshold(None, None) == 0.7
    assert share_threshold({"share_1on1": 0.55, "share_group": 0.25}, "1:1") == pytest.approx(0.75)
    assert share_threshold({"share_1on1": 0.55, "share_group": 0.25}, "group") == pytest.approx(0.6)
    assert share_threshold({"share_1on1": 0.8, "share_group": None}, "1:1") == 0.85
    n = Nudges(clock=_Clock(), baseline={"share_1on1": 0.55, "share_group": 0.25}, kind="group")
    assert n.update(_talk(share=0.62))["text"] == "You've talked 62 % of the last 10 min"


def test_quiet_invitee_nudge():
    n = Nudges(clock=_Clock())
    assert n.update(_talk(), quiet=["Valerie Vogel"])["text"] == "Valerie Vogel hasn't said anything yet"
    n = Nudges(clock=_Clock())
    assert n.update(_talk(), quiet=["Valerie", "Jasper"])["text"] == "Valerie and Jasper haven't said anything yet"


# --- pace and fillers, from the stream's text --------------------------------------------


def _mine(text, n, *, seconds=10.0, start=600.0):
    return [{"start": start + i * seconds, "end": start + (i + 1) * seconds - 0.5, "text": text} for i in range(n)]


def test_pace_and_fillers_over_the_last_minutes():
    words = "wir haben das halt quasi so gemacht und das ist eigentlich gut gelaufen " * 2  # 26 words
    stats = pace_and_fillers(_mine(words, 12), until=720.0)
    assert stats["seconds"] == pytest.approx(114, abs=1)
    assert stats["wpm"] == pytest.approx(26 * 12 / 114 * 60, abs=2)
    assert stats["fillers_per_minute"] == pytest.approx(6 * 12 / 114 * 60, abs=0.5)
    assert stats["top"] == "halt"
    assert stats["language"] == "de"


def test_too_little_speech_for_pace():
    assert pace_and_fillers(_mine("hello there", 3), until=630.0) is None


def test_pace_nudge_only_clearly_above_the_baseline():
    base = {"meetings": 6, "wpm": 140.0, "fillers_per_minute": {"de": 1.5, "en": None}}
    n = Nudges(clock=_Clock(), baseline=base)
    assert n.update(_talk(), speech={"wpm": 160, "fillers_per_minute": 1.6, "top": "halt", "language": "de",
                                      "seconds": 120}) is None
    nudge = n.update(_talk(), speech={"wpm": 190, "fillers_per_minute": 1.6, "top": "halt", "language": "de",
                                       "seconds": 120})
    assert nudge["text"] == "You're speaking fast: 190 words a minute (usual 140)"


def test_filler_nudge_against_the_baseline_in_the_same_language():
    base = {"meetings": 6, "wpm": 140.0, "fillers_per_minute": {"de": 1.5, "en": None}}
    n = Nudges(clock=_Clock(), baseline=base)
    assert n.update(_talk(), speech={"wpm": 140, "fillers_per_minute": 4.0, "top": "halt", "language": "en",
                                      "seconds": 120}) is None  # no English baseline
    nudge = n.update(_talk(), speech={"wpm": 140, "fillers_per_minute": 4.0, "top": "halt", "language": "de",
                                       "seconds": 120})
    assert nudge["text"] == "More filler words than usual: 4.0 a minute (usual 1.5), mostly “halt”"


def test_no_pace_or_filler_nudge_without_a_baseline():
    n = Nudges(clock=_Clock(), baseline={"meetings": 1, "wpm": 100.0, "fillers_per_minute": {"de": 0.5}})
    assert n.update(_talk(), speech={"wpm": 200, "fillers_per_minute": 6.0, "top": "halt", "language": "de",
                                      "seconds": 120}) is None


# --- who hasn't spoken ---------------------------------------------------------------------


def test_an_invitee_not_among_the_named_voices_is_quiet():
    talk = {"SPEAKER_00": 300.0, "SPEAKER_01": 120.0, "SPEAKER_02": 4.0}
    names = {"SPEAKER_00": "Jasper Costa", "SPEAKER_01": "Anna Berg"}
    assert quiet_invitees(["Valerie Vogel", "Jasper Costa"], talk, names, elapsed=700) == ["Valerie Vogel"]


def test_unsure_when_a_voice_has_no_name():
    talk = {"SPEAKER_00": 300.0, "SPEAKER_01": 120.0}
    names = {"SPEAKER_00": "Jasper Costa"}
    assert quiet_invitees(["Valerie Vogel"], talk, names, elapsed=700) == []


def test_unsure_early_or_with_little_call_audio():
    talk = {"SPEAKER_00": 300.0}
    names = {"SPEAKER_00": "Jasper Costa"}
    assert quiet_invitees(["Valerie Vogel"], talk, names, elapsed=300) == []
    assert quiet_invitees(["Valerie Vogel"], {"SPEAKER_00": 30.0}, names, elapsed=900) == []


def test_invitees_matched_by_first_name():
    talk = {"SPEAKER_00": 300.0}
    assert quiet_invitees(["Jasper Costa"], talk, {"SPEAKER_00": "Jasper"}, elapsed=900) == []


def test_speech_kind():
    assert speech_kind(1) == "1:1"
    assert speech_kind(4) == "group"
    assert speech_kind(0) is None


def test_the_meeting_context_from_the_calendar():
    from datetime import datetime

    from palaver.calendar_events import Attendee, Event
    from palaver.live_coach import meeting_context

    at = datetime.fromisoformat("2026-10-30T10:00:00+01:00")
    event = Event("Weekly", at, at, attendees=(
        Attendee("Timo Strauss", is_self=True), Attendee("Valerie Vogel"), Attendee("Room 4", is_room=True),
        Attendee("Jasper Costa", response="declined")))
    # The calendar gives responses (Jasper declined): only who accepted is watched.
    ctx = meeting_context(event, user_name="Timo", baseline={"meetings": 4})
    assert ctx == {"invitees": [], "kind": "1:1", "baseline": {"meetings": 4}}
    accepted = Event("Weekly", at, at, attendees=(
        Attendee("Valerie Vogel", response="accepted"), Attendee("Anna Berg", response="tentative"),
        Attendee("Jasper Costa", response="declined")))
    assert meeting_context(accepted, user_name="Timo", baseline=None)["invitees"] == ["Valerie Vogel"]
    # No responses: only invitees whose voice is known.
    unknown = Event("Weekly", at, at, attendees=(Attendee("Valerie Vogel"), Attendee("Anna Berg")))
    ctx = meeting_context(unknown, user_name="Timo", baseline=None, voices=["Valerie"])
    assert ctx["invitees"] == ["Valerie Vogel"] and ctx["kind"] == "group"
    assert meeting_context(unknown, user_name="Timo", baseline=None)["invitees"] == []
    assert meeting_context(None, user_name="Timo", baseline=None) == {"invitees": [], "kind": None, "baseline": None}


def test_the_kinds_switched_on_in_settings():
    from palaver import settings
    from palaver.live_coach import enabled_kinds

    # Pace and fillers are off until they are calibrated against replays (bench-live).
    assert enabled_kinds(settings.Settings()) == {**ALL, "pace": False, "fillers": False}
    off = settings.Settings(nudge_pace=True, nudge_quiet_invitee=False)
    assert enabled_kinds(off) == {**ALL, "fillers": False, "quiet_invitee": False}


def test_unsure_when_two_voices_have_the_same_name():
    talk = {"SPEAKER_00": 300.0, "SPEAKER_01": 120.0}
    names = {"SPEAKER_00": "Jasper Costa", "SPEAKER_01": "Jasper Costa"}
    assert quiet_invitees(["Valerie Vogel"], talk, names, elapsed=700) == []


def test_pace_and_filler_nudges_come_back_only_well_below_the_threshold():
    base = {"meetings": 6, "wpm": 140.0, "fillers_per_minute": {"de": 1.5, "en": None}}
    clock = _Clock()
    n = Nudges(clock=clock, baseline=base)
    fast = {"wpm": 190, "fillers_per_minute": 1.0, "top": "halt", "language": "de", "seconds": 120}
    assert n.update(_talk(), speech=fast)["kind"] == "pace"
    clock.now = 400
    n.update(_talk(), speech={**fast, "wpm": 165})  # just under the threshold (168): not re-armed
    clock.now = 800
    assert n.update(_talk(), speech=fast) is None
    n.update(_talk(), speech={**fast, "wpm": 150})  # well under it
    clock.now = 1200
    assert n.update(_talk(), speech=fast)["kind"] == "pace"
