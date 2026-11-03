"""Today, the start page (UI spec, phase 2): the call being recorded, the
next meeting with its prep, what needs the user (answered in place, or all
in order in the review), the latest meetings; the strip and dot of a meeting
that needs something; the ⌘K palette, by keyboard."""

import json
from datetime import datetime, timedelta

import re

import pytest

from playwright.sync_api import expect  # noqa: E402

from .helpers import cmd, expect_toast, goto, hash_of, heading, list_item, open_meeting, undo_in_toast  # noqa: E402
from .recordings import A, B, C, LIVE  # noqa: E402

pytestmark = pytest.mark.e2e


def _today(page):
    return page.locator("#main .today")


def _card(page, text):
    return page.locator("#main .need-card", has_text=text)


def _count(page):
    return page.locator('.views [data-view="today"] .nav-count')


def _upcoming(page, minutes=25):
    """The calendar's next meeting (the E2E server has no calendar)."""
    start = datetime.now().astimezone() + timedelta(minutes=minutes, seconds=20)
    event = {"key": "next-1", "title": "1:1 with Lea", "start": start.isoformat(),
             "end": (start + timedelta(minutes=30)).isoformat(), "series": False, "projects": []}
    prep = {**event, "attendees": [{"name": "Lea", "organizer": True, "response": "accepted"}],
            "suggestions": [], "context": [], "all_projects": []}
    page.route("**/api/upcoming", lambda route: route.fulfill(json=[event]))
    page.route("**/api/upcoming/next-1", lambda route: route.fulfill(json=prep))
    page.route("**/api/upcoming/next-1/my-notes", lambda route: route.fulfill(
        json={"paragraphs": [], "images": {}, "revision": ""}))


def test_the_window_opens_on_today(page, shared_server):
    _upcoming(page)
    goto(page, shared_server)
    expect(heading(page)).to_have_text("Today")
    assert hash_of(page) == "#/today"
    today = page.locator('.views [data-view="today"]')
    expect(today).to_have_attribute("aria-current", "page")
    assert page.locator(".views [data-view]").first.get_attribute("data-view") == "today"
    assert page.evaluate("window.palaver.command('back')") is False
    assert page.evaluate("window.palaver.command('trash')") is False  # no meeting here

    live = page.locator("#main .live-now")  # the call being recorded, large
    expect(live).to_contain_text("Hi Timo, wir starten mit dem Budget.")
    expect(live.locator(".live-speakers .person-token")).to_have_text(["Timo", "Speaker 1", "Speaker 2"])

    nxt = page.locator("#main .next-meeting")
    expect(nxt).to_contain_text("1:1 with Lea")
    expect(nxt).to_contain_text("In 25 min")

    expect(_count(page)).to_have_text("3")  # three meetings wait
    expect(page.locator("#main .needs h2")).to_contain_text("Needs you · 3")
    expect(_card(page, "Is Speaker 3 Carla?")).to_be_visible()
    expect(_card(page, "Who is Speaker 2?")).to_be_visible()

    recent = page.locator("#main .recent .item[data-id]")
    expect(recent.first).to_have_attribute("data-id", LIVE)  # the same items as the list
    expect(page.locator("#review-entry")).to_have_count(0)  # "Review all in order" took its place

    nxt.get_by_role("button", name="Prepare").click()
    expect(heading(page)).to_have_text("1:1 with Lea")
    assert hash_of(page) == "#/upcoming/next-1"


def test_a_meeting_opens_from_today_under_meetings(page, shared_server):
    goto(page, shared_server)
    page.locator(f'#main .recent .item[data-id="{B}"]').click()
    expect(heading(page)).to_have_text("Design review")
    expect(page.locator('.views [data-view="meetings"]')).to_have_attribute("aria-current", "page")
    expect(list_item(page, B)).to_have_attribute("aria-current", "true")
    page.locator('.views [data-view="today"]').click()
    expect(heading(page)).to_have_text("Today")
    page.locator("#main .live-now").get_by_role("button", name="Open").click()
    expect(heading(page)).to_contain_text("Meeting at")
    assert hash_of(page) == f"#/{LIVE}"


def test_needs_you_is_answered_in_place_with_undo(page, app_server):
    goto(page, app_server)
    card = _card(page, "Is Speaker 3 Carla?")
    expect(card).to_contain_text("Team standup")
    card.get_by_role("button", name="Yes").click()
    expect(card).to_have_count(0)  # it leaves
    expect_toast(page, "Speaker 3 is Carla")
    who = {s["label"]: s for s in app_server.api(f"/api/meetings/{A}")["speakers"]}
    assert who["SPEAKER_02"]["named_by"] == "you"

    name = _card(page, "Who is Speaker 2?")
    name.get_by_role("button", name="Bob").click()  # the name the notes found
    expect(name).to_have_count(0)
    expect_toast(page, "Speaker 2 is now Bob")
    undo_in_toast(page)
    expect(_card(page, "Who is Speaker 2?")).to_be_visible()  # back in its place
    assert {s["label"]: s["name"] for s in app_server.api(f"/api/meetings/{A}")["speakers"]}["SPEAKER_01"] is None

    typed = _card(page, "Who is Speaker 2?")
    field = typed.get_by_role("combobox", name="Name for Speaker 2")
    field.fill("Bert")
    field.press("Enter")
    expect(typed).to_have_count(0)
    expect_toast(page, "Speaker 2 is now Bert")

    expect(_count(page)).to_have_text("3")
    reviewed = page.locator(f'#main .need-card[data-meeting="{C}"]')
    reviewed.get_by_role("button", name="Mark reviewed").click()
    expect(reviewed).to_have_count(0)
    expect_toast(page, "“Design review, part two” is marked reviewed.")
    expect(_count(page)).to_have_text("2")
    assert app_server.api(f"/api/meetings/{C}")["reviewed"]
    undo_in_toast(page)
    expect(_count(page)).to_have_text("3")
    expect(page.locator(f'#main .need-card[data-meeting="{C}"]')).to_be_visible()


def test_review_all_in_order(page, shared_server):
    goto(page, shared_server)
    page.locator("#main .needs").get_by_role("button", name="Review all in order").click()
    expect(page.locator("#main .review-bar")).to_contain_text("Review · 1 of 3")
    expect(page.locator("#main .review h1")).to_have_text("Design review, part two")
    page.get_by_role("button", name="Skip").click()
    expect(page.locator("#main .review-bar")).to_contain_text("Review · 2 of 3")


def test_a_meeting_that_needs_something_has_a_strip_and_a_dot(page, shared_server):
    open_meeting(page, shared_server, A)
    strip = page.locator("#main .needs-strip")
    expect(strip).to_contain_text("2 things to check")
    expect(strip).to_contain_text("1 voice without a name")
    expect(strip).to_contain_text("a name to confirm")
    expect(list_item(page, A).locator(".needs-dot")).to_have_count(1)
    expect(list_item(page, B).locator(".needs-dot")).to_have_count(0)  # only its review is open
    strip.get_by_role("button", name="Review").click()
    expect(page.locator("#main .review-bar")).to_contain_text("Review · 3 of 3")
    expect(page.locator("#main .review h1")).to_have_text("Team standup")


def test_a_part_of_the_strip_goes_to_what_answers_it(page, shared_server):
    open_meeting(page, shared_server, A)
    items = next(m for m in shared_server.api("/api/needs")["meetings"] if m["id"] == A)["items"]
    unnamed = next(i for i in items if i["kind"] == "unnamed")["label"]
    speaker = next(i for i in items if i["kind"] == "speaker")["label"]
    strip = page.locator("#main .needs-strip")
    strip.get_by_role("button", name="1 voice without a name").click()
    expect(page.locator(f'#main .lane-group[data-label="{unnamed}"] .name-input')).to_be_focused()
    strip.get_by_role("button", name="a name to confirm").click()
    expect(page.locator(f'#main .lane-group[data-label="{speaker}"] :focus')).to_have_count(1)


def _palette(page):
    return page.locator(".palette")


def _options(page):
    return _palette(page).get_by_role("option")


def test_the_palette_by_keyboard(page, shared_server):
    open_meeting(page, shared_server, A)
    list_item(page, B).click()
    expect(heading(page)).to_have_text("Design review")
    cmd(page, "k")
    box = page.get_by_role("combobox", name="Search or run a command")
    expect(box).to_be_focused()
    # Before typing: the places opened lately, then what can be done with this meeting.
    expect(_palette(page).locator(".palette-group").first).to_have_text("Recent")
    expect(_options(page).first).to_contain_text("Design review")
    expect(_options(page).nth(1)).to_contain_text("Team standup")
    trash = _options(page).filter(has_text="Move to Trash")
    expect(trash.locator("kbd")).to_have_text("⌘⌫")
    cmd(page, "k")  # ⌘K again closes it
    expect(_palette(page)).to_have_count(0)

    cmd(page, "k")
    page.keyboard.type("standup")
    expect(_options(page).first).to_contain_text("Team standup")
    expect(_options(page).first).to_have_attribute("aria-selected", "true")
    page.keyboard.press("Enter")
    expect(_palette(page)).to_have_count(0)
    expect(heading(page)).to_have_text("Team standup")

    cmd(page, "k")
    page.keyboard.type("split")
    expect(_options(page).first).to_contain_text("Split At…")
    page.keyboard.press("Enter")
    expect(page.locator("#main .cut-bar")).to_be_visible()  # the command ran on the open meeting

    cmd(page, "k")
    page.keyboard.type("dana")
    expect(_options(page).first).to_contain_text("Dana")
    page.keyboard.press("ArrowDown")
    page.keyboard.press("ArrowUp")
    expect(_options(page).first).to_have_attribute("aria-selected", "true")
    page.keyboard.press("Enter")
    expect(heading(page)).to_have_text("People")
    assert hash_of(page).startswith("#/people/Dana")

    cmd(page, "k")
    page.keyboard.type("design")
    page.keyboard.press("Escape")
    expect(_palette(page)).to_have_count(0)
    expect(heading(page)).to_have_text("People")


def test_the_palette_opens_a_settings_pane(page, shared_server):
    goto(page, shared_server, "#/today")
    cmd(page, "k")
    page.keyboard.type("disk")
    expect(_options(page).first).to_contain_text("Storage")
    page.keyboard.press("Enter")
    expect(page).to_have_url(re.compile("#/settings/storage$"))
    expect(page.locator("#storage-section")).to_be_visible()


def test_the_palette_opens_while_typing_in_a_field(page, shared_server):
    goto(page, shared_server, f"#/{B}")
    page.locator("#search").click()
    cmd(page, "k")
    expect(page.get_by_role("combobox", name="Search or run a command")).to_be_focused()
    page.keyboard.press("Escape")
    expect(page.locator("#search")).to_be_focused()  # focus goes back where it was


def test_the_ribbon_splits_where_pointed(page, shared_server):
    open_meeting(page, shared_server, B)
    expect(page.locator("#main .ribbon")).to_be_visible()
    # No "Continued from" / "Continues in" tabs on its edge (the user found them not worth the room).
    expect(page.locator("#main .ribbon .continues")).to_have_count(0)
    expect(page.locator("#main .ribbon")).not_to_contain_text("Continues in")

    track = page.locator("#main .ribbon .track").first
    box = track.bounding_box()
    page.mouse.move(box["x"] + box["width"] * 0.49, box["y"] + box["height"] / 2)
    cut = page.locator("#main .ribbon .ribbon-cut")
    expect(cut).to_be_visible()
    expect(cut.get_by_role("button")).to_have_text("Split at 0:20")  # the line starting nearest the pointer
    page.mouse.move(box["x"] + box["width"] * 0.9, box["y"] + box["height"] / 2)
    expect(cut.get_by_role("button")).to_have_text("Split at 0:38")  # it follows
    page.mouse.move(box["x"] + box["width"] * 0.49, box["y"] + box["height"] / 2)
    cut.get_by_role("button").click()
    expect(page.locator("#main .cut-bar")).to_contain_text("This line (0:20) and everything after it")
    page.locator("#main .cut-bar").get_by_role("button", name="Cancel").click()


def test_a_poll_keeps_today_as_it_is_and_the_focus_where_it_was(page, shared_server):
    goto(page, shared_server)
    expect(page.locator("#main .live-now")).to_contain_text("Hi Timo")  # Today has all it shows
    page.wait_for_load_state("networkidle")
    button = page.locator(f'#main .need-card[data-meeting="{C}"]').get_by_role("button", name="Mark reviewed")
    button.focus()
    page.evaluate("""document.activeElement.__mark = 1;
      for (const el of document.querySelectorAll('#main .live-now, #main .need-card, #main .recent .item')) el.__mark = 1""")
    page.evaluate("window.palaver.poll()")
    page.wait_for_timeout(500)
    assert page.evaluate("document.activeElement.__mark === 1")  # the same button, still focused
    # Nothing changed: nothing rebuilt, so no card fades in again.
    assert page.evaluate("""[...document.querySelectorAll('#main .live-now, #main .need-card, #main .recent .item')]
      .every((el) => el.__mark === 1)""")


def test_an_answer_leaves_a_name_typed_in_another_card(page, app_server):
    goto(page, app_server)
    field = _card(page, "Who is Speaker 2?").get_by_role("combobox", name="Name for Speaker 2")
    field.fill("Ber")
    _card(page, "Is Speaker 3 Carla?").get_by_role("button", name="Yes").click()
    expect_toast(page, "Speaker 3 is Carla")
    expect(_card(page, "Is Speaker 3 Carla?")).to_have_count(0)
    expect(field).to_have_value("Ber")


def test_an_undo_refreshes_the_meeting_it_touched(page, app_server):
    goto(page, app_server)
    _card(page, "Is Speaker 3 Carla?").get_by_role("button", name="Yes").click()
    expect_toast(page, "Speaker 3 is Carla")
    open_meeting(page, app_server, A)
    carla = page.locator('#main .lane-group[data-label="SPEAKER_02"]')
    expect(carla.locator(".inferred-row")).to_have_count(0)  # confirmed
    page.evaluate("document.activeElement?.blur()")
    cmd(page, "z")
    expect(carla.locator(".inferred-row")).to_contain_text("by elimination")  # a guess again, without a reload


def test_meetings_without_a_meeting_open(page, shared_server):
    goto(page, shared_server, "#/meetings")
    expect(page.locator("#list .item[data-id]")).to_have_count(4)
    expect(page.locator("#list .item[aria-current=true]")).to_have_count(0)  # nothing opened by itself
    expect(page.locator("#main .empty")).to_have_text("Pick a meeting on the left.")
    assert hash_of(page) == "#/meetings"


def test_the_needs_dot_is_said_too(page, shared_server):
    goto(page, shared_server, f"#/{B}")
    expect(list_item(page, A).locator(".needs-dot")).to_have_count(1)
    expect(list_item(page, A)).to_contain_text("Needs you: 1 voice without a name, a name to confirm")


def test_a_reviewed_meeting_shows_what_is_new_since(page, app_server):
    app_server.api(f"/api/meetings/{A}/reviewed", {"done": True})  # left: Speaker 2, Carla
    goto(page, app_server)
    expect(_count(page)).to_have_text("2")  # B and C
    expect(page.locator(f'#main .need-card[data-meeting="{A}"]')).to_have_count(0)
    expect(list_item(page, A)).not_to_contain_text("to name")  # Speaker 2 was seen and left at the review


def test_dont_know_takes_a_voice_off_the_to_dos_until_undone(page, app_server):
    goto(page, app_server)
    expect(list_item(page, A)).to_contain_text("1 to name")
    card = _card(page, "Who is Speaker 2?")
    card.get_by_role("button", name="Don't Know").click()
    expect(card).to_have_count(0)  # it leaves
    expect_toast(page, "Speaker 2 stays without a name · not asked again")
    expect(list_item(page, A)).not_to_contain_text("to name")
    who = {s["label"]: s for s in app_server.api(f"/api/meetings/{A}")["speakers"]}
    assert (who["SPEAKER_01"]["name"], who["SPEAKER_01"]["unknown"]) == (None, True)  # still a lane without a name
    undo_in_toast(page)
    expect(_card(page, "Who is Speaker 2?")).to_be_visible()  # back in its place
    expect(list_item(page, A)).to_contain_text("1 to name")
