"""Recording by hand from the window (#11): Start Recording on Today, atop
the meetings list and in the palette; the running recording with its Stop."""

import shutil

import pytest

from playwright.sync_api import expect  # noqa: E402

from .helpers import cmd, expect_toast, goto, list_item  # noqa: E402
from .recordings import A, LIVE  # noqa: E402

pytestmark = pytest.mark.e2e


def _no_recording(page, served):
    """The call being recorded in the fixtures has ended (and is gone)."""
    # The page asks for the live meeting as it loads: its folder goes only once that answer is in (else a 404).
    page.wait_for_load_state("networkidle")
    served.live_worker.kill()
    served.live_worker.wait()
    shutil.rmtree(served.root / LIVE)
    served.recording.records_into = A  # here: a meeting there is, to open
    page.evaluate("window.palaver.poll()")


def test_today_starts_a_recording(page, app_server):
    goto(page, app_server, "#/today")
    _no_recording(page, app_server)
    card = page.locator("#main .today .record-card")
    expect(card).to_contain_text("New recording")
    expect(card).to_contain_text("Your microphone and this Mac's sound")
    card.get_by_role("button", name="Start Recording").click()
    expect_toast(page, "Recording. Stop it here, or from the menu bar icon.")
    assert app_server.recording.recorded == [("start", None)]


def test_the_meetings_list_starts_one_too(page, app_server):
    goto(page, app_server, f"#/{A}")
    _no_recording(page, app_server)
    card = page.locator("#list .record-card")
    expect(card).to_contain_text("New recording")
    expect(list_item(page, A)).to_be_visible()  # below it, the meetings as before
    card.get_by_role("button", name="Start Recording").click()
    expect_toast(page, "Recording. Stop it here, or from the menu bar icon.")
    assert app_server.recording.recorded == [("start", None)]


def test_the_running_recording_shows_with_its_stop(page, app_server):
    goto(page, app_server, f"#/{A}")
    card = page.locator("#list .record-card")
    expect(card).to_contain_text("Recording")
    expect(card.get_by_role("button", name="Start Recording")).to_have_count(0)
    card.get_by_role("button", name="Stop").click()
    expect_toast(page, "Recording stopped. It is transcribed now.")
    assert app_server.recording.recorded == [("stop", LIVE)]


@pytest.mark.parametrize("width", [320, 260, 220])
def test_the_running_recordings_time_never_runs_under_its_stop(page, app_server, width):
    # Fonts and the list's width vary by Mac: the card is made narrow on purpose.
    goto(page, app_server, f"#/{A}")
    card = page.locator("#list .record-card")
    expect(card).to_contain_text("since")
    page.add_style_tag(content=f"#list .record-card {{ width: {width}px; box-sizing: border-box; }}")
    since = card.locator(".record-text .meta").bounding_box()
    actions = card.locator(".record-actions").bounding_box()
    assert since["x"] + since["width"] <= actions["x"]  # the time ends before the Stop button starts


def test_the_palette_starts_and_stops(page, app_server):
    goto(page, app_server, f"#/{A}")
    cmd(page, "k")
    page.keyboard.type("record")
    options = page.locator(".palette").get_by_role("option")
    expect(options.filter(has_text="Stop Recording")).to_have_count(1)  # one runs
    expect(options.filter(has_text="Start Recording")).to_have_count(0)
    page.keyboard.press("Escape")
    _no_recording(page, app_server)
    expect(page.locator("#list .record-card")).to_contain_text("New recording")
    cmd(page, "k")
    page.keyboard.type("on site")
    expect(options.first).to_contain_text("Start Recording")
    page.keyboard.press("Enter")
    expect_toast(page, "Recording. Stop it here, or from the menu bar icon.")
    assert app_server.recording.recorded == [("start", None)]


# Muted in the recorded call: the mic is not kept, and the window says so plainly.
def _recording_view(served, **extra) -> dict:
    view = {"meeting": LIVE, "text": "Recording · Teams call since 11:00", "warnings": [], "hints": [], **extra}
    served.recording.recording = lambda: view
    return view


def test_while_muted_in_teams_the_recording_says_its_mic_is_not_recorded(page, app_server):
    _recording_view(app_server, muted="teams")
    goto(page, app_server, f"#/{LIVE}")
    pill = page.locator("#main .head .muted-pill")
    expect(pill).to_have_text("Your mic is muted in Teams: not recorded")
    expect(pill).to_have_attribute("role", "status")
    _recording_view(app_server, muted=None)  # unmuted: in daemon.json at once
    page.evaluate("window.palaver.poll()")
    expect(pill).to_have_count(0)
    _recording_view(app_server, muted="teams")
    page.evaluate("window.palaver.poll()")
    expect(pill).to_be_visible()


def test_todays_live_card_says_so_too(page, app_server):
    _recording_view(app_server, muted="teams")
    goto(page, app_server, "#/today")
    pill = page.locator("#main .today .live-now .muted-pill")
    expect(pill).to_have_text("Your mic is muted in Teams: not recorded")
    _recording_view(app_server, muted=None)
    page.evaluate("window.palaver.poll()")
    expect(pill).to_have_count(0)
    expect(page.locator("#main .today .live-now")).to_be_visible()


def test_unmuted_there_is_no_pill(page, app_server):
    _recording_view(app_server, muted=None)
    goto(page, app_server, f"#/{LIVE}")
    expect(page.locator("#main .head .recorded")).to_have_text("Recording · Teams call since 11:00")
    expect(page.locator("#main .muted-pill")).to_have_count(0)
    expect(page.locator("#main .unfollowed-hint")).to_have_count(0)


def test_a_teams_mute_that_cant_be_seen_points_to_accessibility(page, app_server):
    _recording_view(app_server, muted=None, mute_unfollowed="teams")
    goto(page, app_server, f"#/{LIVE}")
    hint = page.locator("#main .head .unfollowed-hint")
    expect(hint).to_contain_text("Palaver can't see whether you're muted in Teams, so your mic is recorded")
    expect(hint.get_by_role("button", name="Open System Settings")).to_be_visible()
