"""Meetings from calendars that aren't connected (#24): the call window's title and people for a meeting
without an event, and a series Palaver remembered, shown on the event line and stopped from the ⋯ menu."""

import json

import pytest

from playwright.sync_api import expect  # noqa: E402

from .helpers import (  # noqa: E402
    expect_toast, goto, heading, list_item, open_meeting, run_from_menu, show_tab, undo_in_toast,
)
from .recordings import A, B  # noqa: E402
from .stores import config_dir  # noqa: E402

pytestmark = pytest.mark.e2e


def test_the_call_windows_title_and_people_name_a_meeting_without_an_event(page, app_server):
    (app_server.root / B / "call-window.json").write_text(json.dumps(
        {"app": "teams", "title": "Northwind sync", "participants": ["Valerie", "Kim"],
         "read_at": "2026-10-27T10:05:00+01:00"}))
    goto(page, app_server, f"#/{B}")
    expect(heading(page)).to_have_text("Northwind sync")
    show_tab(page, "Transcript")
    expect(list_item(page, B)).to_have_attribute("title", "No calendar event; title from the call window")
    names = page.locator("#meeting-names option")
    expect(names.and_(page.locator("[value='Valerie']"))).to_have_count(1)
    expect(names.and_(page.locator("[value='Kim']"))).to_have_count(1)


def test_a_remembered_series_shows_on_the_event_line_and_can_be_stopped(page, app_server):
    config_dir().mkdir(parents=True, exist_ok=True)
    (config_dir() / "series.json").write_text(json.dumps({"series": {"s1": {
        "name": "Team standup", "project": None, "calendar_series": "standup-uid", "call_title": "",
        "weekday": 2, "minutes": 540, "learned": "event", "meetings": [A]}}}))
    open_meeting(page, app_server, A)
    chip = page.locator("#main .event-link .series-chip")
    expect(chip).to_contain_text("Team standup")
    expect(chip).to_contain_text("linked by hand, Tuesdays around 09:00")
    run_from_menu(page, "More actions", "Stop Linking This Series")
    expect_toast(page, "Recordings no longer join “Team standup” by themselves")
    expect(chip).to_have_count(0)
    assert json.loads((config_dir() / "series.json").read_text())["series"] == {}
    undo_in_toast(page)
    expect(page.locator("#main .event-link .series-chip")).to_contain_text("Team standup")
