"""A transcript line's toolbar and right-click menu: play from here, split
(its own meeting, onto the next, discard either side), edit, copy."""

import re

import pytest

from playwright.sync_api import expect  # noqa: E402

from .helpers import (  # noqa: E402
    audio, cmd, expect_toast, line, line_tool, menu_item, open_meeting,
    undo_in_toast, unfocus,
)
from .recordings import A, B, C, LIVE  # noqa: E402

pytestmark = pytest.mark.e2e

ALL = [LIVE, C, B, A]


@pytest.mark.usefixtures("audio_decoding")
def test_play_from_here(page, shared_server):
    open_meeting(page, shared_server, A, tab="Transcript")
    line_tool(page, 15, "play").click()
    expect(page.locator("#play")).to_have_attribute("aria-label", "Pause")
    expect(page.locator("#clock")).to_have_text(re.compile(r"0:1[5-9]"))
    expect(page.locator("#now-speaking")).to_have_text("Speaker 2")
    assert audio(page)["time"] >= 15
    page.locator("#play").click()


def test_the_line_menu(page, shared_server):
    open_meeting(page, shared_server, A, tab="Transcript")
    line(page, 15).click(button="right", position={"x": 4, "y": 4})  # beside the words: a right-click selects one
    labels = page.locator(".menu .menu-label").all_text_contents()
    assert labels == ["Play from here", "Edit", "Fix spelling", "Copy", "Split here"]
    expect(menu_item(page, "Fix spelling")).to_be_disabled()  # nothing marked or selected in this line
    page.keyboard.press("Escape")
    line(page, 4).click(button="right")
    expect(menu_item(page, "Fix spelling")).to_be_enabled()  # "Atterkring" is marked unsure


def test_no_split_here_on_the_first_line(page, shared_server):
    open_meeting(page, shared_server, A, tab="Transcript")
    line(page, 0).click(button="right")
    expect(page.locator(".menu")).to_be_visible()
    expect(menu_item(page, "Split here")).to_have_count(0)
    page.keyboard.press("Escape")
    line(page, 0).hover()
    expect(line(page, 0).locator(".line-tool")).to_have_count(4)
    expect(line_tool(page, 0, "split")).to_have_count(0)


def _split(page, start: float):
    line(page, start).click(button="right")
    menu_item(page, "Split here").click()
    bar = page.locator("#main .cut-bar")
    expect(bar).to_contain_text("and everything after it")
    return bar


def test_split_here_into_its_own_meeting_and_undo(page, app_server):
    open_meeting(page, app_server, A, tab="Transcript")
    _split(page, 27).get_by_role("button", name="becomes its own meeting").click()
    expect_toast(page, "The rest is now a meeting of its own.")
    expect(page.locator("#list .item[data-id]")).to_have_count(5)
    expect(line(page, 27)).to_have_count(0)
    expect(page.locator("#duration")).to_have_text("0:27")
    expect(page.locator("#main .inline-notice")).to_contain_text("The rest is now a meeting of its own.")
    assert len(app_server.meeting_ids()) == 5
    undo_in_toast(page)
    expect(page.locator("#list .item[data-id]")).to_have_count(4)
    expect(line(page, 27)).to_have_count(1)
    expect(page.locator("#duration")).to_have_text("0:40")
    assert app_server.meeting_ids() == ALL


def test_split_here_onto_the_next_meeting_and_undo(page, app_server):
    open_meeting(page, app_server, B, tab="Transcript")
    _split(page, 20).get_by_role("button", name="goes to the start of “Design review, part two”").click()
    expect_toast(page, "The rest is now the start of the next meeting.")
    expect(line(page, 20)).to_have_count(0)
    expect(page.locator("#duration")).to_have_text("0:20")
    assert app_server.api(f"/api/meetings/{C}")["transcript"][0]["text"].startswith("I like the flow")
    undo_in_toast(page)
    expect(line(page, 20)).to_have_count(1)
    assert app_server.meeting_ids() == ALL
    assert app_server.api(f"/api/meetings/{C}")["transcript"][0]["text"].startswith("Back from the break")


@pytest.mark.parametrize("side, row", [("after", 0), ("before", 1)])
def test_split_here_discarding_a_part_and_undo(page, app_server, side, row):
    open_meeting(page, app_server, A, tab="Transcript")
    bar = _split(page, 15)
    bar.locator(".cut-row").nth(row).get_by_role("button", name="goes to Trash").click()
    text = {"after": "Everything from there on is in Trash (Recordings/.trash).",
            "before": "Everything before that is in Trash (Recordings/.trash)."}[side]
    expect_toast(page, text)
    expect(page.locator("#main .turn")).to_have_count(2 if side == "after" else 3)
    expect(page.locator("#main .transcript")).not_to_contain_text(
        "over to you Bob" if side == "before" else "after lunch")
    assert app_server.meeting_ids() == ALL  # no meeting more or less
    undo_in_toast(page)
    expect(page.locator("#main .turn")).to_have_count(5)
    expect(page.locator("#duration")).to_have_text("0:40")


def test_edit_and_undo(page, app_server):
    open_meeting(page, app_server, A, tab="Transcript")
    line(page, 27).click(button="right")
    menu_item(page, "Edit").click()
    box = page.get_by_label("The line at 0:27")
    box.fill("I can take that review before lunch.")
    page.get_by_role("button", name="Save").click()
    said = line(page, 27).locator(".said")
    expect(said).to_contain_text("I can take that review before lunch.")
    expect(said.locator(".edited")).to_have_attribute("title", "Heard: “I can take that review after lunch.”")
    undo_in_toast(page)
    expect(said).to_contain_text("I can take that review after lunch.")
    expect(said.locator(".edited")).to_have_count(0)
    assert app_server.api(f"/api/meetings/{A}")["transcript"][3]["edited"] is False


def test_an_edit_that_fails_keeps_what_was_typed(page, app_server):
    page.guard.allow(r"status of 500")
    page.route(re.compile(r"/api/meetings/[^/]+/line$"),
               lambda route: route.fulfill(status=500, content_type="application/json", body='{"error": "disk full"}'))
    open_meeting(page, app_server, A, tab="Transcript")
    line_tool(page, 27, "edit").click()
    box = page.get_by_label("The line at 0:27")
    box.fill("Typed by hand.")
    box.press("Enter")
    expect(page.locator("#main .line-error")).to_have_text("Not saved: disk full. What you typed is still here.")
    expect(box).to_have_value("Typed by hand.")


def test_copy(page, shared_server):
    open_meeting(page, shared_server, A, tab="Transcript")
    line(page, 15).click(button="right")
    menu_item(page, "Copy").click()
    expect_toast(page, "Copied")
    assert page.evaluate("window.__copied") == ["Thanks Anna. The pelican deploy is still blocked."]


def test_fix_spelling_everywhere_and_undo(page, app_server):
    open_meeting(page, app_server, A, tab="Transcript")
    line_tool(page, 4, "fixSpelling").click()
    form = page.get_by_role("dialog", name="Fix the spelling")
    field = form.get_by_label("How “Atterkring” is spelled")
    expect(field).to_be_focused()
    field.fill("Attakring")
    form.get_by_role("button", name="Fix everywhere").click()
    expect_toast(page, "“Atterkring” is now “Attakring” everywhere")
    said = line(page, 4).locator(".said")
    expect(said.locator(".glossed")).to_have_text("Attakring")
    expect(page.locator("#main .inline-notice")).to_contain_text("“Atterkring” is now “Attakring”.")
    assert [t["term"] for t in app_server.api("/api/glossary")["terms"]] == ["Attakring"]
    undo_in_toast(page)
    expect(said).to_contain_text("Atterkring")
    expect(said.locator(".glossed")).to_have_count(0)
    assert app_server.api("/api/glossary")["terms"] == []


def test_a_selection_offers_fix_spelling(page, app_server):
    open_meeting(page, app_server, A, tab="Transcript")
    box = line(page, 15).locator(".said").bounding_box()
    # "pelican" selected, as a double-click would.
    page.evaluate("""() => {
      const said = document.querySelector('#main .turn[data-start="15"] .said');
      const node = [...said.childNodes].find((n) => n.nodeType === Node.TEXT_NODE && n.textContent.includes('pelican'));
      const at = node.textContent.indexOf('pelican');
      const r = document.createRange();
      r.setStart(node, at);
      r.setEnd(node, at + 'pelican'.length);
      getSelection().removeAllRanges();
      getSelection().addRange(r);
    }""")
    page.mouse.move(box["x"] + 5, box["y"] + 5)
    page.mouse.up()  # the selection is final once the mouse is up
    offer = page.get_by_role("button", name="Fix spelling…")
    offer.click()
    field = page.get_by_label("How “pelican” is spelled")
    field.fill("Pelikan")
    field.press("Enter")
    expect_toast(page, "“pelican” is now “Pelikan” everywhere")
    expect(line(page, 15).locator(".glossed")).to_have_text("Pelikan")
    unfocus(page)
    cmd(page, "z")
    expect(line(page, 15).locator(".glossed")).to_have_count(0)
