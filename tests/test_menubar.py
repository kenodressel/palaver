"""Tests for the menu bar app's pure helpers (issue #14)."""

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from palaver import settings
from palaver.menubar import (
    auto_record_states,
    with_record_switches,
    AUTO_RECORD,
    START_TITLE,
    STOP_TITLE,
    click_action,
    event_action,
    manual_action,
    menu_layout,
    menu_title,
    show_menu_once,
    status_line,
)

NOW = datetime(2026, 10, 20, 15, 0, tzinfo=timezone.utc)


def _status(**kw):
    base = {"state": "idle", "auto": True, "manual": False, "since": NOW.isoformat(),
            "folder": None, "queued": [], "transcribing": False}
    base.update(kw)
    return base


def test_menu_title_per_state():
    assert menu_title(_status()) == ""  # the icon alone
    assert menu_title(_status(state="recording")) == "🔴"
    assert menu_title(_status(transcribing=True)) == "⏳"
    assert menu_title(_status(state="paused")) == "⏸"
    assert menu_title(_status(state="recording", transcribing=True)) == "🔴"  # recording wins
    assert menu_title(_status(), error=True) == "⚠️"


def test_the_start_stop_item_does_what_it_said():
    assert manual_action(START_TITLE, recording=False) == "start"
    assert manual_action(STOP_TITLE, recording=True) == "stop"
    # The call ended (or one began) while the menu was open: nothing happens.
    assert manual_action(STOP_TITLE, recording=False) is None
    assert manual_action(START_TITLE, recording=True) is None


def test_status_line():
    since = (NOW - timedelta(minutes=12)).isoformat()
    assert status_line(_status(), NOW) == "Waiting for a Teams call or Slack huddle"
    assert status_line(_status(state="paused"), NOW) == "Not recording calls automatically"
    line = status_line(_status(state="recording", since=since, folder="/r/2026-10-20T14-48-00"), NOW)
    assert line.startswith("Recording for 12 min")
    # Why it records, when the daemon says (issue #47).
    why = "Recording · Teams call since 14:48 · mic AirPods (24 kHz)"
    assert status_line(_status(state="recording", since=since, why_text=why), NOW) == why
    assert status_line(_status(transcribing=True, queued=["a"]), NOW) == "Transcribing (1 more queued)"


def test_the_menu_starts_and_stops_and_leaves_settings_to_the_window():
    layout = menu_layout()
    assert layout == [
        START_TITLE,
        "Keep recording",
        None,
        "Open Meetings",
        "Settings…",
        "Report a Problem…",
        None,
        "Check for Updates…",  # with the version; "Update available (…)" when there is one (#60)
        "Quit",
    ]
    for gone in ("Open latest transcript in Notion", "Open latest recording folder", "Open log",
                 "Record Teams calls and Slack huddles automatically", "Record Teams calls automatically",
                 "Record Slack huddles automatically", "Connect Calendar…"):
        assert gone not in layout
    assert [key for key, _ in AUTO_RECORD] == ["record_teams", "record_slack"]  # the Settings page's switches


def test_the_record_switches_are_the_settings_pages():
    defaults = settings.Settings(record_slack=False)  # config.toml said no Slack
    assert auto_record_states(defaults) == {"record_teams": True, "record_slack": False}
    settings.update({"record_teams": False})  # switched in the window's Settings: the status says it
    assert auto_record_states(defaults) == {"record_teams": False, "record_slack": False}


def _log(tmp_path: Path, events: list[dict]) -> Path:
    path = tmp_path / "session.log"
    path.write_text("".join(json.dumps(e) + "\n" for e in events))
    return path


def test_processing_progress_from_session_log(tmp_path: Path):
    from palaver.menubar import processing_progress

    assert processing_progress(tmp_path / "missing.log") == (0, 7, "Starting")
    log = _log(tmp_path, [
        {"event": "record_stop"},
        {"event": "process_start"},
        {"event": "aec_start"}, {"event": "aec_done"},
        {"event": "transcribe_start", "track": "system"}, {"event": "transcribe_done", "track": "system"},
        {"event": "transcribe_start", "track": "mic"},
    ])
    assert processing_progress(log) == (3, 7, "Transcribing your microphone")
    log = _log(tmp_path, [{"event": "process_start"}, {"event": "diarize_start"}])
    assert processing_progress(log) == (4, 7, "Identifying speakers")
    log = _log(tmp_path, [{"event": "process_done", "rc": 0}, {"event": "notion_upload_start"}])
    assert processing_progress(log) == (7, 7, "Uploading to Notion")


def test_title_shows_elapsed_time_and_progress():
    since = (NOW - timedelta(minutes=12, seconds=34)).isoformat()
    assert menu_title(_status(state="recording", since=since), now=NOW) == "🔴 12:34"
    long = (NOW - timedelta(hours=1, minutes=2, seconds=3)).isoformat()
    assert menu_title(_status(state="recording", since=long), now=NOW) == "🔴 1:02:03"
    assert menu_title(_status(transcribing=True), progress=(3, 7, "x"), now=NOW) == "⏳ 3/7"


def test_recording_lines():
    from palaver.menubar import recording_lines

    since = (NOW - timedelta(minutes=5)).isoformat()
    lines = recording_lines(
        _status(state="recording", since=since, folder="/r/2026-10-20T14-55-00",
                system_source="process-tap", teams_active=True),
        [("mic", -24.0, 0.0), ("system", None, 12.0)],
        NOW,
    )
    # The status item above says why it records; the clock is in the menu bar.
    assert lines[0].startswith("Mic") and "-24 dB" in lines[0]
    assert lines[1].startswith("System") and "silent 12 s" in lines[1]
    assert lines[2] == "System audio via Process Tap · Call active"
    with_rate = recording_lines(
        _status(state="recording", since=since, system_source="process-tap", teams_active=True,
                why={"system": {"rate": 48000.0, "source": "process-tap"}}), [], NOW)
    assert with_rate[-1] == "System audio via Process Tap (48 kHz) · Call active"


def test_status_line_with_progress():
    line = status_line(_status(transcribing=True, queued=["a"]), NOW, (3, 7, "Transcribing your microphone"))
    assert line == "Transcribing your microphone (3/7, 1 more queued)"


def test_permissions_to_request_on_first_launch(tmp_path: Path):
    """Microphone and system-audio capture only — no Screen Recording."""
    from palaver.menubar import permissions_to_request

    marker = tmp_path / "asked"
    assert permissions_to_request(mic_status=0, marker=marker) == ["microphone", "system-audio"]
    assert permissions_to_request(mic_status=3, marker=marker) == ["system-audio"]
    marker.write_text("1")
    assert permissions_to_request(mic_status=3, marker=marker) == []
    # Denied mic is not re-requested (macOS would not show the prompt again).
    assert permissions_to_request(mic_status=2, marker=marker) == []


def test_recording_lines_warn_about_missing_track():
    from palaver.menubar import recording_lines

    since = (NOW - timedelta(minutes=1)).isoformat()
    lines = recording_lines(
        _status(state="recording", since=since, folder="/r/x", system_source="process-tap",
                mic_source="avcapture", teams_active=True, missing=["system audio"]),
        [("mic", -24.0, 0.0), ("system", None, 60.0)], NOW,
    )
    assert any(line.startswith("⚠ Not recording: system audio") for line in lines)


def test_title_flags_missing_track():
    since = (NOW - timedelta(minutes=2)).isoformat()
    assert menu_title(_status(state="recording", since=since, missing=["microphone"]), now=NOW) == "🔴⚠ 2:00"


def test_click_action_left_opens_right_and_ctrl_show_menu():
    from AppKit import NSEventModifierFlagControl, NSEventTypeLeftMouseUp, NSEventTypeRightMouseUp

    assert click_action(NSEventTypeLeftMouseUp, 0) == "open"
    assert click_action(NSEventTypeRightMouseUp, 0) == "menu"
    assert click_action(NSEventTypeLeftMouseUp, NSEventModifierFlagControl) == "menu"


def test_event_action_without_an_event_opens_the_window():
    from AppKit import NSEventModifierFlagControl, NSEventTypeLeftMouseUp, NSEventTypeRightMouseUp

    class Event:
        def __init__(self, kind, flags=0):
            self.kind, self.flags = kind, flags

        def type(self):
            return self.kind

        def modifierFlags(self):
            return self.flags

    assert event_action(None) == "open"
    assert event_action(Event(NSEventTypeLeftMouseUp)) == "open"
    assert event_action(Event(NSEventTypeRightMouseUp)) == "menu"
    assert event_action(Event(NSEventTypeLeftMouseUp, NSEventModifierFlagControl)) == "menu"


def test_the_menu_is_taken_off_again_even_when_showing_it_fails():
    import pytest

    class Item:
        def __init__(self):
            self.menus = []

        def setMenu_(self, menu):
            self.menus.append(menu)

    class Button:
        def __init__(self, fail):
            self.fail = fail

        def performClick_(self, _):
            if self.fail:
                raise RuntimeError("no window server")

    item = Item()
    show_menu_once(item, Button(fail=False), "menu")
    assert item.menus == ["menu", None]
    item = Item()
    with pytest.raises(RuntimeError):
        show_menu_once(item, Button(fail=True), "menu")
    assert item.menus == ["menu", None]


def test_the_start_stop_item_asks_when_a_manual_recording_outlived_its_call():
    from palaver.menubar import manual_title

    assert manual_title(_status()) == START_TITLE
    assert manual_title(_status(state="recording")) == STOP_TITLE
    asked = {"meeting": "m", "reason": "teams", "minutes": 10, "message": "…"}
    assert manual_title(_status(state="recording", stop_question=asked)) == "Call ended — Stop recording"
    silent = {**asked, "reason": "silence", "minutes": 30}
    assert manual_title(_status(state="recording", stop_question=silent)) == "Silent for 30 min — Stop recording"
    # Whatever it says, a click on it while recording stops.
    assert manual_action("Call ended — Stop recording", recording=True) == "stop"
    assert manual_action("Silent for 30 min — Stop recording", recording=False) is None


# --- audio problems (issue #50) -------------------------------------------------

WARNING = "System audio is playing at the wrong speed; Palaver is correcting it"
HINT = "Your mic sends nothing — muted?"


def test_recording_lines_show_audio_warnings_and_hints():
    from palaver.menubar import recording_lines

    since = (NOW - timedelta(minutes=1)).isoformat()
    lines = recording_lines(
        _status(state="recording", since=since, folder="/r/x", system_source="process-tap",
                teams_active=True, warnings=[WARNING], hints=[HINT]),
        [("mic", -24.0, 0.0), ("system", -30.0, 0.0)], NOW,
    )
    assert f"⚠ {WARNING}" in lines and HINT in lines and f"⚠ {HINT}" not in lines
    assert lines.index(f"⚠ {WARNING}") < next(i for i, x in enumerate(lines) if x.startswith("System audio via")) \
        < lines.index(HINT)


def test_recording_lines_show_two_warnings_at_most_and_never_drop_the_source_line():
    from palaver.menubar import recording_lines

    since = (NOW - timedelta(minutes=1)).isoformat()
    lines = recording_lines(
        _status(state="recording", since=since, folder="/r/x", system_source="process-tap", teams_active=True,
                missing=["microphone"], warnings=["a", "b", "c", "d"], hints=[HINT]),
        [("mic", -24.0, 0.0), ("system", -30.0, 0.0)], NOW,
    )
    assert [line for line in lines if line.startswith("⚠ ") and "Not recording" not in line] == ["⚠ a", "⚠ b"]
    assert "+2 more — open Palaver for all" in lines
    assert any(line.startswith("System audio via") for line in lines) and lines[-1] == HINT  # hints after it (#41)
    assert len(lines) <= 8  # the menu's live lines


def test_title_flags_an_audio_problem_but_not_a_hint():
    since = (NOW - timedelta(minutes=2)).isoformat()
    assert menu_title(_status(state="recording", since=since, warnings=[WARNING]), now=NOW) == "🔴⚠ 2:00"
    assert menu_title(_status(state="recording", since=since, warnings=[], hints=[HINT]), now=NOW) == "🔴 2:00"


def test_status_line_while_the_search_index_is_built():
    """#46: the first run downloads the search model; say so while it does."""
    assert status_line(_status(indexing=True, index_downloading=True), NOW) == \
        "Downloading the search model (470 MB)"
    assert status_line(_status(indexing=True), NOW) == "Indexing meetings for search"
    assert status_line(_status(indexing=True, transcribing=True), NOW).startswith("Transcribing")


def test_the_coach_in_the_menu_bar():
    """The coach is one line at the end of the menu, never in the title (#41):
    the title keeps the clock and 🔴."""
    from palaver.menubar import MENU_LINES, recording_lines

    since = (NOW - timedelta(minutes=12)).isoformat()
    status = _status(state="recording", since=since, folder="/r/x", system_source="process-tap", teams_active=False,
                     warnings=[WARNING], hints=[HINT], talk_text="You 62 % of the last 10 min",
                     nudge={"kind": "monologue", "text": "4-min monologue"})
    assert menu_title(status, now=NOW) == "🔴⚠ 12:00"
    lines = recording_lines(status, [("mic", -24.0, 0.0), ("system", -30.0, 0.0)], NOW)
    order = [lines.index(f"⚠ {WARNING}"), next(i for i, x in enumerate(lines) if "Call ended" in x),
             lines.index(HINT), lines.index("Coach: 4-min monologue")]
    assert order == sorted(order) and lines[-1] == "Coach: 4-min monologue"
    assert "You 62 % of the last 10 min" not in lines  # one coach line: the nudge wins
    no_nudge = recording_lines({**status, "nudge": None}, [("mic", -24.0, 0.0)], NOW)
    assert no_nudge[-1] == "You 62 % of the last 10 min"
    full = recording_lines({**status, "warnings": [WARNING] * 5, "hints": [HINT] * 3, "missing": ["microphone"]},
                           [("mic", -24.0, 0.0), ("system", -30.0, 0.0)], NOW)
    assert len(full) <= MENU_LINES and not any(x.startswith("Coach") for x in full)  # no room: the coach waits


def test_both_record_switches_off_is_paused():
    off = {"record_teams": False, "record_slack": False}
    assert with_record_switches(_status(), off)["state"] == "paused"
    assert menu_title(with_record_switches(_status(), off)) == "⏸"
    assert with_record_switches(_status(), {"record_teams": True, "record_slack": False})["state"] == "idle"
    recording = _status(state="recording")
    assert with_record_switches(recording, off)["state"] == "recording"  # a manual one keeps running


def test_quitting_never_holds_the_main_thread_for_the_window_server():
    """before_quit (#57): the recording is finished first, then the window's
    server stops in the background; the main thread is free within 3 s."""
    import threading
    import time

    from palaver.menubar import finalize

    order = []

    class Timer:
        def stop(self):
            order.append("timer")

    class Daemon:
        def shutdown(self, reason):
            order.append(("daemon", reason))

    class Web:
        def __init__(self):
            self.stopped = threading.Event()

        def stop(self):
            order.append("web")
            time.sleep(5)  # a server draining its last change
            self.stopped.set()

    class Control:
        def close(self):
            order.append("control")

    class App:
        timer, daemon, web, control = Timer(), Daemon(), Web(), Control()
        quit_reason = "by_you"

    started = time.monotonic()
    t = finalize(App())
    assert time.monotonic() - started < 3
    assert order[:2] == ["timer", ("daemon", "by_you")]
    assert _wait(lambda: "web" in order)
    assert not App.web.stopped.is_set() and t.daemon


def _wait(condition, timeout=2.0):
    import time

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline and not condition():
        time.sleep(0.01)
    return condition()


def test_the_menu_bar_app_checks_for_updates_and_quits_for_the_swap_only_when_told(monkeypatch, tmp_path):
    """Updates (#60) as the menu bar app holds them: from a checkout there is
    nothing to update and nothing is fetched."""
    import os

    from palaver import menubar, updater
    from palaver import settings as settings_module

    monkeypatch.delenv("PALAVER_APP", raising=False)
    monkeypatch.setattr(updater, "write_status", lambda status, home=None: None)
    fetched = []
    monkeypatch.setattr("palaver.downloader.fetch_manifest", lambda *a, **k: fetched.append(1))

    class Daemon:
        def status(self):
            return {"state": "idle"}

    updates = menubar.Updates(Daemon())
    assert updates.updater.status()["state"] == "unsupported"
    assert updates.tick() is False and fetched == []
    assert updates.app_pids() == [os.getpid()]  # not the terminal it runs in
    assert settings_module.load().check_updates is True



@pytest.mark.parametrize("daemon_status, jobs, test, downloading, reason", [
    ({"state": "idle"}, [], "idle", False, None),
    ({"state": "recording"}, [], "idle", False, "recording"),
    ({"state": "idle"}, [{"kind": "notes", "key": "x"}], "idle", False, "writing notes"),
    ({"state": "idle"}, [], "recording", False, "a test recording"),
    ({"state": "idle"}, [], "checking", False, "a test recording"),
    ({"state": "idle"}, [], "done", False, None),
    ({"state": "idle"}, [], "idle", True, "downloading models"),
])
def test_an_update_waits_for_everything_palaver_does_not_only_recordings(daemon_status, jobs, test, downloading, reason):
    from palaver import menubar

    assert menubar.update_busy(daemon_status, jobs=jobs, test=test, downloading=downloading) == reason



def test_a_started_release_says_so_for_the_swap_and_carries_a_failed_swaps_error(monkeypatch, tmp_path):
    """The swap keeps the app before until the new one has started (#60);
    a swap that failed is said again after the reopen."""
    from palaver import install_layout, menubar, updater

    home = tmp_path / "home"
    monkeypatch.setenv("HOME", str(home))
    app = tmp_path / "Palaver.app"
    (app / "Contents" / "Resources").mkdir(parents=True)
    (app / "Contents" / "Resources" / "runtime.json").write_text(json.dumps({"version": "0.2.0", "runtime": "rt"}))
    monkeypatch.setenv("PALAVER_APP", str(app))
    monkeypatch.setattr(updater, "prune_runtimes", lambda current, home=None: [])
    updater.write_status({"state": "failed", "from_swap": True, "error": "Palaver 0.3.0 did not start; 0.2.0 is back.",
                          "available": {"version": "0.3.0"}})

    class Daemon:
        def status(self):
            return {"state": "idle"}

    updates = menubar.Updates(Daemon())
    assert updates.updater.status()["error"] == "Palaver 0.3.0 did not start; 0.2.0 is back."
    assert updater.read_status()["error"] == "Palaver 0.3.0 did not start; 0.2.0 is back."
    assert not install_layout.started_ok_path().exists()
    updates.started()
    assert install_layout.started_ok_path().read_text() == "0.2.0"


def test_the_launcher_is_waited_for_only_when_this_process_runs_under_it(monkeypatch, tmp_path):
    """An installed app's command started from a terminal has the shell as
    its parent: an update or uninstall must not wait for that (#60)."""
    import os

    from palaver import menubar, updater

    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("PALAVER_APP", str(tmp_path / "Palaver.app"))
    monkeypatch.setattr(updater, "prune_runtimes", lambda current, home=None: [])
    monkeypatch.setattr(menubar, "_move_mcp_entries", lambda: None)

    class Daemon:
        def status(self):
            return {"state": "idle"}

    monkeypatch.delenv("PALAVER_LAUNCHER_FD", raising=False)
    assert menubar.Updates(Daemon()).app_pids() == [os.getpid()]
    monkeypatch.setenv("PALAVER_LAUNCHER_FD", "3")
    assert menubar.Updates(Daemon()).app_pids() == [os.getpid(), os.getppid()]
