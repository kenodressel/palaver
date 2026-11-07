"""The speaker of single lines (#12): click a line's speaker, say who it
really is, and go on through that speaker's next lines."""

import json

import pytest

from playwright.sync_api import expect  # noqa: E402

from .helpers import expect_toast, line, line_tool, menu_item, open_meeting, speakers_in_transcript, undo_in_toast  # noqa: E402
from .recordings import A  # noqa: E402

pytestmark = pytest.mark.e2e


def _speaker_2_says_three_lines(served) -> None:
    """Speaker 2 of the standup, in three lines: two people in truth."""
    path = served.root / A / "transcript.json"
    lines = [d for d in json.loads(path.read_text()) if d["start"] != 15.0]
    lines += [{"speaker": "SPEAKER_01", "start": 15.0, "end": 19.0, "text": "Thanks Anna."},
              {"speaker": "SPEAKER_01", "start": 19.0, "end": 23.0, "text": "The pelican deploy is still blocked."},
              {"speaker": "SPEAKER_01", "start": 23.0, "end": 27.0, "text": "I can unblock it today."}]
    path.write_text(json.dumps(sorted(lines, key=lambda d: d["start"])))


def _menu_title(page):
    return page.locator(".menu .menu-title")


def test_this_line_is_and_on_to_the_next_line_of_that_speaker(page, app_server):
    _speaker_2_says_three_lines(app_server)
    open_meeting(page, app_server, A, tab="Transcript")
    line(page, 15).locator(".speaker").click()
    expect(_menu_title(page)).to_have_text("This line is…")
    assert page.locator(".menu .menu-label").all_text_contents() == ["Me", "Anna", "Carla"]
    menu_item(page, "Carla").click()

    expect_toast(page, "Line at 0:15 → Carla")
    expect(line(page, 15).locator(".speaker")).to_have_text("Carla")
    expect(line(page, 15).locator(".speaker-fixed")).to_have_attribute("title", "Was Speaker 2")
    # On to Speaker 2's next line, asked the same at once.
    expect(_menu_title(page)).to_have_text("This line is…")
    expect(page.locator("#main .turn.line-asking")).to_have_attribute("data-start", "19")
    expect(menu_item(page, "Me")).to_be_focused()
    page.keyboard.press("ArrowDown")  # Anna
    page.keyboard.press("Enter")
    expect_toast(page, "Line at 0:19 → Anna")
    expect(page.locator("#main .turn.line-asking")).to_have_attribute("data-start", "23")
    page.keyboard.press("Escape")  # this one is Speaker 2's
    expect(page.locator(".menu")).to_have_count(0)
    expect(page.locator("#main .turn.line-asking")).to_have_count(0)
    assert speakers_in_transcript(page) == ["Timo", "Anna", "Carla", "Anna", "Speaker 2", "Carla", "Timo"]

    undo_in_toast(page)
    expect(line(page, 19).locator(".speaker")).to_have_text("Speaker 2")
    assert speakers_in_transcript(page) == ["Timo", "Anna", "Carla", "Speaker 2", "Speaker 2", "Carla", "Timo"]
    saved = app_server.api(f"/api/meetings/{A}")
    assert [t["speaker"] for t in saved["transcript"]][2:5] == ["Carla", "Speaker 2", "Speaker 2"]


def test_a_line_without_its_name_shown_and_back_again(page, app_server):
    _speaker_2_says_three_lines(app_server)
    open_meeting(page, app_server, A, tab="Transcript")
    line_tool(page, 19, "speaker").click()  # the second of Speaker 2's lines shows no name: from its toolbar
    menu_item(page, "Me").click()
    expect_toast(page, "Line at 0:19 → Me")
    page.keyboard.press("Escape")  # not on to the next one
    expect(line(page, 19).locator(".speaker")).to_have_text("Timo")
    line(page, 19).locator(".speaker").click()
    assert page.locator(".menu .menu-label").all_text_contents() == ["Anna", "Carla", "Back to Speaker 2"]
    menu_item(page, "Back to Speaker 2").click()
    expect_toast(page, "Line at 0:19 → Speaker 2 again")
    expect(page.locator(".menu")).to_have_count(0)  # going back is no run through the lines
    assert speakers_in_transcript(page)[2:5] == ["Speaker 2", "Speaker 2", "Speaker 2"]
