"""A meeting renamed: in place on its title, from ⋯ and from ⌘K; undone."""

import pytest

from playwright.sync_api import expect  # noqa: E402

from .helpers import cmd, expect_toast, heading, list_item, menu_item, more, open_meeting, undo_in_toast, unfocus  # noqa: E402
from .recordings import A, B  # noqa: E402

pytestmark = pytest.mark.e2e


def title_field(page):
    return page.locator("#main h1").get_by_role("textbox", name="Meeting title")


def test_a_meeting_without_an_event_renamed_in_place_shows_so_in_the_list_and_is_undone(page, app_server):
    open_meeting(page, app_server, B)  # "Design review": no calendar event, titled by the notes
    heading(page).click()
    field = title_field(page)
    expect(field).to_be_focused()
    expect(field).to_have_value("Design review")
    field.fill("Onboarding colours")
    field.press("Enter")
    expect(heading(page)).to_have_text("Onboarding colours")
    expect(list_item(page, B).locator(".item-title")).to_have_text("Onboarding colours")
    expect_toast(page, "Renamed to “Onboarding colours”")
    assert app_server.api(f"/api/meetings/{B}")["title_from"] == "you"

    undo_in_toast(page)
    expect(heading(page)).to_have_text("Design review")
    expect(list_item(page, B).locator(".item-title")).to_have_text("Design review")
    assert app_server.api(f"/api/meetings/{B}")["title_from"] == "notes"


def test_escape_leaves_the_title_as_it_was(page, app_server):
    open_meeting(page, app_server, B)
    heading(page).click()
    title_field(page).fill("Something else")
    title_field(page).press("Escape")
    expect(heading(page)).to_have_text("Design review")
    expect(title_field(page)).to_have_count(0)
    assert app_server.api(f"/api/meetings/{B}")["title"] == "Design review"


def test_renamed_from_the_menu_the_title_wins_over_the_calendar_which_shows_below(page, app_server):
    open_meeting(page, app_server, A)  # "Team standup", from its calendar event
    more(page).click()
    menu_item(page, "Rename…").click()
    title_field(page).fill("Standup with Carla")
    page.locator("#main .when").click()  # away from the field: saved
    expect(heading(page)).to_have_text("Standup with Carla")
    expect(page.locator("#main .event-link .link-title")).to_have_text("Team standup")
    expect_toast(page, "Renamed to “Standup with Carla”")

    unfocus(page)
    cmd(page, "z")
    expect(heading(page)).to_have_text("Team standup")
    expect(page.locator("#main .event-link .link-title")).to_have_text("Team standup")


def test_rename_meeting_in_the_palette_opens_the_title_field(page, app_server):
    open_meeting(page, app_server, B)
    unfocus(page)
    cmd(page, "k")
    page.get_by_role("combobox", name="Search or run a command").fill("rename")
    page.keyboard.press("Enter")
    expect(title_field(page)).to_be_focused()
    title_field(page).fill("")
    title_field(page).press("Enter")  # empty: no title of its own to clear, nothing changes
    expect(heading(page)).to_have_text("Design review")
