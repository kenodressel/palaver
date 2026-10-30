"""Voices several people share (#56): a lane marked as a room and named,
the whole meeting from its menu, and the way back."""

import pytest

from playwright.sync_api import expect  # noqa: E402

from .helpers import (  # noqa: E402
    cmd, expect_toast, lane, line, open_meeting, run_from_menu, speakers_in_transcript, undo_in_toast, unfocus,
)
from .recordings import A  # noqa: E402

pytestmark = pytest.mark.e2e

LINE = "Several people shared one microphone here, so lines aren't assigned to people."


def test_a_lane_marked_as_a_room_is_named_and_undone(page, app_server):
    open_meeting(page, app_server, A, tab="Transcript")
    expect(lane(page, "SPEAKER_01").locator(".hints")).to_contain_text("Bob")  # a name guessed from the words
    run_from_menu(page, "Actions for Speaker 2", "A Room, Several People")
    expect_toast(page, "Speaker 2 is a room, several people · 1 line")
    expect(line(page, 15).locator(".speaker")).to_have_text("Room")
    expect(page.locator("#main .shared-line")).to_have_text(LINE)
    expect(lane(page, "SPEAKER_01").locator(".hints")).to_have_count(0)  # no names offered for a room

    field = page.get_by_label("Room name for Speaker 2")
    field.fill("Raum 3.12")
    field.press("Enter")
    expect_toast(page, "The room is now “Raum 3.12”")
    expect(line(page, 15).locator(".speaker")).to_have_text("Room (Raum 3.12)")
    undo_in_toast(page)
    expect(line(page, 15).locator(".speaker")).to_have_text("Room")

    unfocus(page)
    cmd(page, "z")  # the mark itself
    expect(line(page, 15).locator(".speaker")).to_have_text("Speaker 2")
    expect(page.locator("#main .shared-line")).to_have_count(0)
    expect(page.get_by_label("Name for Speaker 2")).to_have_value("")


def test_several_people_at_my_mic_and_undo(page, app_server):
    open_meeting(page, app_server, A, tab="Transcript")
    expect(line(page, 0).locator(".speaker")).to_have_text("Timo")
    run_from_menu(page, "Actions for Timo", "Several People at My Mic")
    expect_toast(page, "Several people at your microphone · 2 lines")
    expect(line(page, 0).locator(".speaker")).to_have_text("Room (with you)")
    expect(page.locator("#main .shared-line")).to_have_text(LINE)
    undo_in_toast(page)
    expect(line(page, 0).locator(".speaker")).to_have_text("Timo")
    expect(page.locator("#main .shared-line")).to_have_count(0)


def _series(app_server) -> None:
    import json

    calendar = app_server.root / A / "calendar.json"
    calendar.write_text(json.dumps({**json.loads(calendar.read_text()), "uid": "standup-series", "series": True}))


def test_unmarking_a_meeting_of_a_remembered_series_asks_to_forget_the_series(page, app_server):
    _series(app_server)
    app_server.api(f"/api/meetings/{A}/shared", {"on": True, "series": True})
    open_meeting(page, app_server, A)
    run_from_menu(page, "More actions", "Speakers Can Be Separated")
    ask = page.locator("#main .shared-ask")
    expect(ask).to_contain_text("still start out with speakers that can't be separated")
    ask.get_by_role("button", name="Forget for this series").click()
    expect_toast(page, "The next meetings of “Team standup” start out unmarked")
    expect(ask).to_have_count(0)
    undo_in_toast(page)
    run_from_menu(page, "More actions", "Forget for This Series")  # also in the menu while remembered
    expect_toast(page, "The next meetings of “Team standup” start out unmarked")


def test_the_coach_says_on_each_card_what_it_leaves_out(page, app_server):
    app_server.api(f"/api/meetings/{A}/shared", {"label": "SPEAKER_01", "on": True})
    open_meeting(page, app_server, A, tab="Coach")
    left_out = page.locator("#main .coach-card", has_text="Left out: several people shared one microphone here.")
    expect(left_out.locator("h3")).to_have_text(["You talked", "Monologues"])


def test_the_whole_meeting_from_its_menu_and_undo(page, app_server):
    open_meeting(page, app_server, A, tab="Transcript")
    run_from_menu(page, "More actions", "Speakers Can't Be Separated")
    expect_toast(page, "Speakers can't be separated in this meeting")
    expect(page.locator("#main .shared-line")).to_have_text(LINE)
    assert speakers_in_transcript(page) == ["Timo", "Several people", "Several people", "Several people", "Timo"]
    expect(page.get_by_label("Name for Anna")).to_have_count(0)  # no lane keeps a person's name
    undo_in_toast(page)
    expect(line(page, 15).locator(".speaker")).to_have_text("Speaker 2")
    expect(page.get_by_label("Name for Anna")).to_have_value("Anna")
    expect(page.locator("#main .shared-line")).to_have_count(0)
