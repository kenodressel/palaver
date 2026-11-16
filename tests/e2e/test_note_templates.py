"""Note templates (#13): the picker above a meeting's notes (picked by the calendar title, chosen for the meeting and
its series, the notes written again with it), and Settings → Note Templates (the built-in ones, the user's own)."""

import json
import re

import pytest

from playwright.sync_api import expect  # noqa: E402

from .helpers import expect_toast, goto, menu_item, open_meeting, undo_in_toast  # noqa: E402
from .recordings import A  # noqa: E402
from .stores import RecordingPaths, config_dir, load_notes  # noqa: E402

pytestmark = pytest.mark.e2e


def _picker(page):
    return page.locator("#main .notes .template-picker")


def test_the_titles_template_shows_and_another_one_rewrites_the_notes(page, app_server):
    open_meeting(page, app_server, A)
    expect(_picker(page)).to_have_text("Template: Stand-up ▾")  # "Team standup" in the calendar
    expect(_picker(page)).to_have_attribute("title", "Picked by the calendar title")
    _picker(page).click()
    expect(menu_item(page, "Stand-up")).to_contain_text("✓")
    menu_item(page, "Interview").click()
    expect(_picker(page)).to_have_text("Template: Interview ▾")
    expect(page.locator("#main .notes .writing")).to_have_count(0)
    assert app_server.notes.calls == [A]
    assert 'The meeting\'s note template is "Interview".' in app_server.notes.prompts[-1]
    paths = RecordingPaths(app_server.root / A)
    assert load_notes(paths)["template"] == "interview"
    assert json.loads((paths.folder / "template.json").read_text()) == {"template": "interview"}
    expect(page.locator("#main .template-ask")).to_have_count(0)  # no calendar series to remember it for


def test_a_meeting_of_a_series_offers_its_template_for_the_series(page, app_server):
    calendar = app_server.root / A / "calendar.json"
    calendar.write_text(json.dumps({**json.loads(calendar.read_text()), "uid": "standup-series", "series": True}))
    open_meeting(page, app_server, A)
    _picker(page).click()
    menu_item(page, "1:1").click()
    ask = page.locator("#main .template-ask")
    expect(ask).to_contain_text("Use 1:1 for every meeting of “Team standup”?")
    ask.get_by_role("button", name="Use for this series").click()
    expect_toast(page, "The next meetings of “Team standup” use 1:1")
    expect(ask).to_have_count(0)
    stored = json.loads((config_dir() / "templates.json").read_text())
    assert stored["series"] == {"standup-series": {"template": "one-on-one", "title": "Team standup"}}
    # Listed in Settings, where it can be forgotten.
    goto(page, app_server, "#/settings/templates")
    row = page.locator(".template-series")
    expect(row).to_have_text(re.compile("“Team standup”: 1:1"))
    row.get_by_role("button", name="Forget").click()
    expect(row).to_have_count(0)
    assert json.loads((config_dir() / "templates.json").read_text())["series"] == {}


def test_settings_shows_the_built_in_templates_and_keeps_the_users_own(page, app_server):
    goto(page, app_server, "#/settings/templates")
    interview = page.locator(".template-card[data-template='interview']")
    expect(interview).to_contain_text("candidate")
    expect(interview.locator("input, textarea")).to_have_count(0)  # read-only
    new = page.locator(".template-card[data-template='new']")
    new.get_by_label("Name of the new template").fill("Board meeting")
    new.get_by_label("Instructions of the new template").fill("Sections: one per agenda item.")
    new.get_by_role("button", name="Add Template").click()
    expect_toast(page, "Board meeting added")
    mine = page.locator(".template-card", has=page.get_by_label("Name of Board meeting"))
    expect(mine.get_by_label("Instructions of Board meeting")).to_have_value("Sections: one per agenda item.")
    mine.get_by_label("Name of Board meeting").fill("Board")
    mine.get_by_role("button", name="Save").click()
    expect_toast(page, "Saved")
    mine = page.locator(".template-card", has=page.get_by_label("Name of Board"))
    expect(mine).to_have_count(1)
    # It is offered on a meeting's picker.
    open_meeting(page, app_server, A)
    _picker(page).click()
    expect(menu_item(page, "Board")).to_be_visible()
    page.keyboard.press("Escape")
    # Deleted, and back with Undo.
    goto(page, app_server, "#/settings/templates")
    page.locator(".template-card", has=page.get_by_label("Name of Board")).get_by_role("button", name="Delete").click()
    expect_toast(page, "Board deleted")
    expect(page.get_by_label("Name of Board")).to_have_count(0)
    undo_in_toast(page)
    expect(page.get_by_label("Name of Board")).to_have_count(1)
    assert [t["name"] for t in json.loads((config_dir() / "templates.json").read_text())["templates"]] == ["Board"]


def test_a_template_without_a_name_is_refused_with_why(page, app_server):
    page.guard.allow(r"status of 400")
    goto(page, app_server, "#/settings/templates")
    new = page.locator(".template-card[data-template='new']")
    new.get_by_label("Instructions of the new template").fill("Sections: anything.")
    new.get_by_role("button", name="Add Template").click()
    expect(page.locator("#main .settings-pane .error")).to_have_text("Not added: a template needs a name")
