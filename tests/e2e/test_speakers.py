"""The speaker lanes: merge, Not a Speaker, rename, a guess confirmed, a
failed naming, and the lane menu by keyboard."""

import re

import pytest

from playwright.sync_api import expect  # noqa: E402

from .helpers import (  # noqa: E402
    cmd, expect_toast, lane, line, menu_item, more, open_meeting, run_from_menu, speakers_in_transcript,
    toast, undo_in_toast, unfocus,
)
from .recordings import A  # noqa: E402

pytestmark = pytest.mark.e2e


def test_the_lane_menu_in_order(page, shared_server):
    open_meeting(page, shared_server, A)
    more(page, "Actions for Speaker 2").click()
    labels = page.locator(".menu .menu-label").all_text_contents()
    assert labels == ["Rename", "Play Voice", "Merge Into…", "Don't Know Who This Is", "A Room, Several People",
                      "Not a Speaker"]
    page.keyboard.press("Escape")
    more(page, "Actions for Carla").click()  # an inferred name can be taken back
    labels = page.locator(".menu .menu-label").all_text_contents()
    assert labels == ["Rename", "Play Voice", "Merge Into…", "Not Carla", "A Room, Several People", "Not a Speaker"]
    expect(menu_item(page, "Not a Speaker")).to_have_class("danger")


def test_merge_and_undo(page, app_server):
    open_meeting(page, app_server, A, tab="Transcript")
    run_from_menu(page, "Actions for Speaker 2", "Merge Into…")
    submenu = page.locator(".menu")
    expect(submenu.locator(".menu-label")).to_have_text(["Anna", "Carla"])
    menu_item(page, "Anna").click()
    expect(lane(page, "SPEAKER_01")).to_have_count(0)
    expect_toast(page, "Speaker 2 → Anna · 1 line")
    assert speakers_in_transcript(page) == ["Timo", "Anna", "Anna", "Carla", "Timo"]
    expect(lane(page, "SPEAKER_00").locator(".merged-row")).to_contain_text("Speaker 2 ×")
    undo_in_toast(page)
    expect(lane(page, "SPEAKER_01")).to_have_count(1)
    assert speakers_in_transcript(page) == ["Timo", "Anna", "Speaker 2", "Carla", "Timo"]
    expect(lane(page, "SPEAKER_00").locator(".merged-row")).to_have_count(0)


def test_a_merged_speaker_splits_off_again(page, app_server):
    app_server.api(f"/api/meetings/{A}/merge", {"label": "SPEAKER_01", "into": "SPEAKER_00"})
    open_meeting(page, app_server, A)
    lane(page, "SPEAKER_00").get_by_role("button", name="Speaker 2 ×").click()
    expect(lane(page, "SPEAKER_01")).to_have_count(1)
    expect_toast(page, "Speaker 2 split off from Anna")
    undo_in_toast(page)
    expect(lane(page, "SPEAKER_01")).to_have_count(0)


def test_not_a_speaker_and_undo(page, app_server):
    open_meeting(page, app_server, A, tab="Transcript")
    run_from_menu(page, "Actions for Speaker 2", "Not a Speaker")
    expect(lane(page, "SPEAKER_01")).to_have_count(0)
    expect(line(page, 15)).to_have_count(0)  # its lines go with it
    expect_toast(page, "Speaker 2 removed · 1 line")
    expect(page.locator("#main .ribbon-foot")).to_contain_text("Speaker 2 removed")
    undo_in_toast(page)
    expect(lane(page, "SPEAKER_01")).to_have_count(1)
    expect(line(page, 15)).to_have_count(1)
    expect(page.locator("#main .ribbon-foot")).to_have_count(0)


def test_dont_know_who_this_is_and_ask_me_again(page, app_server):
    open_meeting(page, app_server, A)
    run_from_menu(page, "Actions for Speaker 2", "Don't Know Who This Is")
    expect_toast(page, "Speaker 2 stays without a name · not asked again")
    expect(lane(page, "SPEAKER_01").locator(".name-input")).to_have_value("")  # a lane to name any time
    expect(page.locator(f'#list .item[data-id="{A}"]')).not_to_contain_text("to name")
    run_from_menu(page, "Actions for Speaker 2", "Ask Me Again")
    expect_toast(page, "Speaker 2 is asked about again")
    expect(page.locator(f'#list .item[data-id="{A}"]')).to_contain_text("1 to name")


def test_a_removed_speaker_is_restored_from_under_the_lanes(page, app_server):
    app_server.api(f"/api/meetings/{A}/remove", {"label": "SPEAKER_01", "removed": True})
    open_meeting(page, app_server, A)
    page.locator("#main .ribbon-foot").get_by_role("button", name="Restore").click()
    expect(lane(page, "SPEAKER_01")).to_have_count(1)
    expect_toast(page, "Speaker 2 restored")


def test_rename_from_the_lane_menu(page, app_server):
    open_meeting(page, app_server, A, tab="Transcript")
    run_from_menu(page, "Actions for Speaker 2", "Rename")
    field = page.get_by_label("Name for Speaker 2")
    expect(field).to_be_focused()
    field.press_sequentially("Bob")
    field.press("Enter")
    expect_toast(page, "Speaker 2 is now Bob")
    expect(line(page, 15).locator(".speaker")).to_have_text("Bob")
    unfocus(page)
    cmd(page, "z")
    expect(line(page, 15).locator(".speaker")).to_have_text("Speaker 2")
    expect(page.get_by_label("Name for Speaker 2")).to_have_value("")


def test_an_inferred_name_is_confirmed_or_taken_back(page, app_server):
    open_meeting(page, app_server, A)
    carla = lane(page, "SPEAKER_02")
    expect(carla.locator(".inferred-row")).to_contain_text("by elimination")
    carla.get_by_role("button", name="Yes, Carla").click()
    expect_toast(page, "Speaker 3 is Carla")
    expect(carla.locator(".inferred-row")).to_have_count(0)
    expect(carla.locator(".voice-play")).to_have_count(0)  # sure now
    undo_in_toast(page)  # a guess again
    expect(carla.locator(".inferred-row")).to_contain_text("by elimination")


def test_not_the_inferred_name(page, app_server):
    open_meeting(page, app_server, A)
    run_from_menu(page, "Actions for Carla", "Not Carla")
    expect_toast(page, "Speaker 3 is not Carla")
    expect(page.get_by_label("Name for Speaker 3")).to_have_value("")
    undo_in_toast(page)
    expect(page.get_by_label("Name for Carla")).to_have_value("Carla")


def test_a_naming_failure_rolls_back(page, app_server):
    page.guard.allow(r"status of 500")
    failing = [True]

    def speakers(route):
        if failing[0]:
            route.fulfill(status=500, content_type="application/json", body='{"error": "disk full"}')
        else:
            route.continue_()

    page.route(re.compile(r"/api/meetings/[^/]+/speakers$"), speakers)
    open_meeting(page, app_server, A, tab="Transcript")
    field = page.get_by_label("Name for Speaker 2")
    field.fill("Bob")
    field.press("Enter")
    expect_toast(page, "The name was not saved: disk full")
    expect(page.get_by_label("Name for Speaker 2")).to_have_value("")  # the name shown at once is taken back
    expect(line(page, 15).locator(".speaker")).to_have_text("Speaker 2")
    assert app_server.api(f"/api/meetings/{A}")["speakers"][1]["name"] is None
    failing[0] = False
    toast(page).get_by_role("button", name="Try again").click()
    expect_toast(page, "Speaker 2 is now Bob")
    expect(line(page, 15).locator(".speaker")).to_have_text("Bob")


def test_the_lane_menu_works_by_keyboard(page, app_server):
    open_meeting(page, app_server, A)
    button = more(page, "Actions for Speaker 2")
    button.focus()
    page.keyboard.press("Enter")
    expect(button).to_have_attribute("aria-expanded", "true")
    expect(menu_item(page, "Rename")).to_be_focused()
    page.keyboard.press("ArrowDown")
    expect(menu_item(page, "Play Voice")).to_be_focused()
    page.keyboard.press("End")
    expect(menu_item(page, "Not a Speaker")).to_be_focused()
    page.keyboard.press("ArrowDown")  # around to the top
    expect(menu_item(page, "Rename")).to_be_focused()
    page.keyboard.press("Escape")
    expect(page.locator(".menu")).to_have_count(0)
    expect(button).to_be_focused()
    expect(button).to_have_attribute("aria-expanded", "false")
    page.keyboard.press("Enter")
    page.keyboard.press("Home")
    page.keyboard.press("Enter")  # Rename
    expect(page.get_by_label("Name for Speaker 2")).to_be_focused()


def test_merge_by_keyboard(page, app_server):
    open_meeting(page, app_server, A)
    button = more(page, "Actions for Speaker 2")
    button.focus()
    page.keyboard.press("Enter")
    page.keyboard.press("ArrowDown")
    page.keyboard.press("ArrowDown")
    expect(menu_item(page, "Merge Into…")).to_be_focused()
    page.keyboard.press("Enter")
    expect(menu_item(page, "Anna")).to_be_focused()  # the second menu, of the other speakers
    page.keyboard.press("ArrowDown")
    page.keyboard.press("Enter")  # Carla
    expect_toast(page, "Speaker 2 → Carla · 1 line")
    expect(lane(page, "SPEAKER_01")).to_have_count(0)
    unfocus(page)
    cmd(page, "z")
    expect(lane(page, "SPEAKER_01")).to_have_count(1)
