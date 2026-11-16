"""Meetings from calendars that aren't connected (#24): the call window's title and people for a meeting
without an event, and a series Palaver remembered, shown on the event line and stopped from the ⋯ menu.
Series of Palaver's own (#39): a meeting put into one from its ⋯ menu, moved or taken out, and the series page
(name, project, its meetings, delete)."""

import json

import pytest

from playwright.sync_api import expect  # noqa: E402

from .helpers import (  # noqa: E402
    expect_toast, goto, hash_of, heading, list_item, menu_item, open_meeting, run_from_menu, show_tab, undo_in_toast,
)
from .recordings import A, B, C  # noqa: E402
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


def _series_file() -> dict:
    return json.loads((config_dir() / "series.json").read_text())["series"]


def test_a_meeting_goes_into_a_series_from_its_menu_and_the_series_page_edits_it(page, app_server):
    # #39: ⋯ → Add to Series… with a new name makes a series of the user's.
    open_meeting(page, app_server, B)
    run_from_menu(page, "More actions", "Add to Series…")
    field = page.get_by_role("dialog").get_by_role("combobox", name="Series")
    field.fill("Contoso weekly")
    field.press("Enter")
    expect_toast(page, "Added to “Contoso weekly”")
    chip = page.locator("#main .event-link .series-chip")
    expect(chip).to_contain_text("Contoso weekly")
    (sid, made), = _series_file().items()
    assert made["learned"] == "you" and made["meetings"] == [B]
    # The other meeting into the same series, by picking its name; the list filters by it.
    open_meeting(page, app_server, C)
    run_from_menu(page, "More actions", "Add to Series…")
    page.get_by_role("dialog").get_by_role("combobox", name="Series").fill("contoso weekly")
    page.get_by_role("dialog").get_by_role("button", name="Add").click()
    expect_toast(page, "Added to “Contoso weekly”")
    page.locator("#filter").select_option(f"s:{sid}")
    expect(page.locator("#list .item[data-id]")).to_have_count(2)
    page.locator("#filter").select_option("")

    # The chip opens the series: its meetings newest first, called by the series without an event of their own.
    page.locator("#main .event-link .series-chip").click()
    expect(heading(page)).to_have_text("Contoso weekly")
    assert hash_of(page) == f"#/series/{sid}"
    rows = page.locator("#main .series li[data-meeting]")
    expect(rows).to_have_count(2)
    assert rows.evaluate_all("els => els.map((e) => e.dataset.meeting)") == [C, B]
    expect(rows.locator(".appearance-title")).to_have_text(["Contoso weekly", "Contoso weekly"])

    # Its project, its name; undo takes a change back.
    project = page.get_by_role("combobox", name="Project of Contoso weekly")
    project.fill("Contoso")
    project.press("Enter")
    expect_toast(page, "“Contoso weekly” is in project Contoso")
    assert _series_file()[sid]["project"] == "Contoso"
    name = page.get_by_role("textbox", name="Rename Contoso weekly")
    name.fill("Contoso jour fixe")
    name.press("Enter")
    expect_toast(page, "“Contoso weekly” is now “Contoso jour fixe”")
    undo_in_toast(page)
    expect(page.get_by_role("textbox", name="Rename Contoso weekly")).to_have_value("Contoso weekly")

    # × takes a meeting out (it has its notes' title again); it stays out of the series.
    page.locator(f'#main .series li[data-meeting="{C}"] .row-tool').click()
    expect_toast(page, "“Contoso weekly” removed from “Contoso weekly”")
    expect(rows).to_have_count(1)
    assert _series_file()[sid]["removed"] == [C]
    expect(list_item(page, C).locator(".item-title")).to_have_text("Design review, part two")

    # Deleted from its ⋯: the meetings stay, in no series; the page goes to all series.
    run_from_menu(page, "Actions for Contoso weekly", "Delete Series")
    expect_toast(page, "Series “Contoso weekly” deleted; its meetings stay")
    expect(heading(page)).to_have_text("Series")
    assert _series_file() == {}
    undo_in_toast(page)
    expect(page.locator("#main .series li[data-meeting]")).to_have_count(1)


def test_a_meeting_moves_to_another_series_and_leaves_it_from_its_menu(page, app_server):
    config_dir().mkdir(parents=True, exist_ok=True)
    (config_dir() / "series.json").write_text(json.dumps({"series": {
        "s1": {"name": "Northwind sync", "project": "Northwind", "calendar_series": "", "call_title": "northwind sync",
               "weekday": 2, "minutes": 540, "learned": "call-window", "meetings": [B]},
        "s2": {"name": "Valerie 1:1", "project": None, "calendar_series": "", "call_title": "", "weekday": None,
               "minutes": None, "learned": "you", "meetings": []}}}))
    goto(page, app_server, f"#/{B}")
    expect(heading(page)).to_have_text("Northwind sync")  # no event: the series' name
    expect(page.locator("#main .event-link .series-chip")).to_contain_text("Northwind")
    run_from_menu(page, "More actions", "Move to Series…")
    page.get_by_role("dialog").get_by_role("combobox", name="Series").fill("Valerie 1:1")
    page.get_by_role("dialog").get_by_role("button", name="Move").click()
    expect_toast(page, "Moved to “Valerie 1:1”")
    expect(page.locator("#main .event-link .series-chip")).to_contain_text("Valerie 1:1")
    run_from_menu(page, "More actions", "Remove from Series")
    expect_toast(page, "Removed from “Valerie 1:1”")
    expect(page.locator("#main .event-link .series-chip")).to_have_count(0)
    assert _series_file()["s2"]["meetings"] == [] and _series_file()["s1"]["meetings"] == []
    undo_in_toast(page)
    expect(page.locator("#main .event-link .series-chip")).to_contain_text("Valerie 1:1")


def test_a_series_of_the_users_remembers_the_note_template_chosen_for_it(page, app_server):
    config_dir().mkdir(parents=True, exist_ok=True)
    (config_dir() / "series.json").write_text(json.dumps({"series": {
        "s2": {"name": "Valerie 1:1", "project": None, "calendar_series": "", "call_title": "", "weekday": None,
               "minutes": None, "learned": "you", "meetings": [B]}}}))
    goto(page, app_server, f"#/{B}")
    expect(heading(page)).to_have_text("Valerie 1:1")
    page.locator("#main .notes .template-picker").click()
    menu_item(page, "Interview").click()
    ask = page.locator("#main .template-ask")
    expect(ask).to_contain_text("Use Interview for every meeting of “Valerie 1:1”?")
    ask.get_by_role("button", name="Use for this series").click()
    expect_toast(page, "The next meetings of “Valerie 1:1” use Interview")
    stored = json.loads((config_dir() / "templates.json").read_text())
    assert stored["series"] == {"palaver:s2": {"template": "interview", "title": "Valerie 1:1"}}
