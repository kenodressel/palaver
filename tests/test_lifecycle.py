"""Why Palaver records, why it stopped, where it paused (issue #47)."""

from datetime import datetime

from palaver.lifecycle import gap_text, recorded_text, recording_text, stopped_text

START = "2026-10-29T12:06:10+01:00"


def test_recording_text_says_why_and_with_which_mic():
    why = {"trigger": "teams", "since": START, "mic": {"device": "AirPods", "rate": 24000}}
    assert recording_text(why) == "Recording · Teams call since 12:06 · mic AirPods (24 kHz)"
    assert recording_text({"trigger": "slack", "since": START}) == "Recording · Slack huddle since 12:06"
    assert recording_text({"trigger": "manual", "since": START, "mic": {"rate": 44100}}) == (
        "Recording · started by you at 12:06 · mic 44.1 kHz")
    assert recording_text({"trigger": "teams", "since": START, "restarts": 1, "mic": {"device": "MacBook Pro Mic"}}) == (
        "Recording · Teams call since 12:06, continued after a Palaver restart · mic MacBook Pro Mic")


def test_stopped_text_names_the_reason():
    assert stopped_text("teams", "call_ended") == "Teams call ended"
    assert stopped_text("slack", "call_ended") == "Slack huddle ended"
    assert stopped_text("manual", "by_you") == "Stopped by you"
    assert stopped_text("teams", "restart") == "Palaver restarted"
    assert stopped_text("teams", "auto_off") == "Automatic recording turned off"
    assert stopped_text("teams", "max_length") == "Reached the maximum length"
    assert stopped_text("teams", None) is None


def test_gap_text_gives_the_wall_clock():
    start = datetime.fromisoformat(START)
    assert gap_text({"start": 415.0, "end": 424.4, "why": "restart"}, start) == (
        "Recording paused 12:13:05–12:13:14 (Palaver restarted)")
    assert gap_text({"start": 415.0, "end": 424.0}, start) == "Recording paused 12:13:05–12:13:14"


def test_recorded_text_tells_how_a_recording_started_and_stopped():
    meta = {"start_time": START, "end_time": "2026-10-29T13:02:00+01:00", "trigger": "teams",
            "stop_reason": "call_ended", "gaps": [{"start": 415.0, "end": 424.0, "why": "restart"}]}
    assert recorded_text(meta) == "Teams call detected 12:06 · Teams call ended 13:02 · Palaver restarted — continued"
    two = {**meta, "gaps": meta["gaps"] * 2}
    assert recorded_text(two).endswith("Palaver restarted twice — continued")
    manual = {"start_time": START, "end_time": "2026-10-29T12:40:00+01:00", "trigger": "manual", "stop_reason": "by_you"}
    assert recorded_text(manual) == "Started by you 12:06 · Stopped by you 12:40"
    cut = {"start_time": START, "end_time": "2026-10-29T12:13:05+01:00", "trigger": "teams", "stop_reason": "restart"}
    assert recorded_text(cut) == "Teams call detected 12:06 · Palaver restarted 12:13"
    assert recorded_text(cut, continued=True) == "Teams call detected 12:06 · Palaver restarted 12:13 — continued"
    assert recorded_text({"start_time": START, "duration_seconds": 60}) is None  # recorded before #47


# --- audio problems (issue #50) -------------------------------------------------

from palaver.lifecycle import problem_text, problem_warning, recording_hints, recording_warnings  # noqa: E402


def test_recording_text_names_the_output_device_when_known():
    why = {"trigger": "teams", "since": START, "mic": {"device": "AirPods Pro", "rate": 24000},
           "system": {"device": "AirPods Pro", "rate": 24000, "source": "process-tap"}}
    assert recording_text(why) == (
        "Recording · Teams call since 12:06 · mic AirPods Pro (24 kHz) · output AirPods Pro (24 kHz)")


def test_problem_warning_says_what_is_wrong_in_plain_words():
    assert problem_warning({"kind": "speed", "track": "system"}) == (
        "System audio is playing at the wrong speed; Palaver is correcting it")
    assert problem_warning({"kind": "speed", "track": "mic"}) == (
        "Microphone is recording at the wrong speed; Palaver is correcting it")
    assert problem_warning({"kind": "length", "track": "mic"}) == "Microphone is out of step with the clock"
    assert problem_warning({"kind": "stalled", "track": "mic"}) == "No microphone audio is arriving"
    assert problem_warning({"kind": "stalled", "track": "system"}) == "No system audio is arriving"
    assert problem_warning({"kind": "access", "track": "mic"}) == (
        "Microphone access was turned off — allow it in System Settings → Privacy & Security")
    assert problem_warning({"kind": "device", "track": "system"}) == (
        "System audio couldn't be rebuilt; Palaver keeps trying")
    assert problem_warning({"kind": "device", "track": "mic"}) == "Microphone is unavailable; Palaver keeps trying"


def test_recording_warnings_are_the_open_problems_and_hints_are_apart():
    why = {"trigger": "teams", "since": START,
           "problems": [{"kind": "speed", "track": "system", "start": 480.0}],
           "hints": [{"kind": "silent", "track": "mic"}]}
    assert recording_warnings(why) == ["System audio is playing at the wrong speed; Palaver is correcting it"]
    assert recording_hints(why) == ["Your mic sends nothing — muted?"]
    assert recording_warnings({"trigger": "teams", "since": START}) == []
    assert recording_warnings(None) == [] and recording_hints(None) == []


def test_problem_text_gives_the_wall_clock_and_what_went_wrong():
    start = datetime.fromisoformat(START)
    assert problem_text({"kind": "speed", "track": "system", "start": 480.0, "end": 600.0}, start) == (
        "Audio problem at 12:14 (system audio played at the wrong speed)")
    assert problem_text({"kind": "length", "track": "mic", "start": 0, "end": None}, start) == (
        "Audio problem at 12:06 (microphone drifted from the clock)")
    assert problem_text({"kind": "silent", "track": "mic", "start": 60}, start) == (
        "Audio problem at 12:07 (microphone sent nothing — muted?)")
    assert problem_text({"kind": "unknown-kind", "track": "mic", "start": 60}, start) == "Audio problem at 12:07"
    # The wall clock taken when it happened wins: a sleep shifts the offset, not this.
    late = {"kind": "device", "track": "system", "start": 60, "at": "2026-10-29T12:31:40+01:00"}
    assert problem_text(late, start) == "Audio problem at 12:31 (system audio couldn't be rebuilt)"
