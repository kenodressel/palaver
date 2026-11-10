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
