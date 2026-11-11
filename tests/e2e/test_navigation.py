"""Getting back: a swipe, ⌘[ and ⌘] return to the page left, with its tab;
links to a project or a meeting and back again; a reload stays where it was."""

import pytest

from playwright.sync_api import expect  # noqa: E402

from .helpers import (  # noqa: E402
    RELOAD_WHEN_QUIET, cmd, goto, hash_of, heading, list_item, open_meeting, reload, show_tab, unfocus,
)
from .recordings import A, B, LIVE  # noqa: E402

pytestmark = pytest.mark.e2e


def _tab(page, name):
    return page.get_by_role("tab", name=name)


def test_back_and_forward_restore_the_meeting_and_its_tab(page, shared_server):
    open_meeting(page, shared_server, A, tab="Transcript")
    assert page.evaluate("window.palaver.command('back')") is False  # the first page: nothing to go back to
    list_item(page, B).click()
    expect(heading(page)).to_have_text("Design review")
    expect(_tab(page, "Summary")).to_have_attribute("aria-selected", "true")
    unfocus(page)
    cmd(page, "BracketLeft")
    expect(heading(page)).to_have_text("Team standup")
    expect(_tab(page, "Transcript")).to_have_attribute("aria-selected", "true")
    assert hash_of(page) == f"#/{A}"
    assert page.evaluate("window.palaver.command('back')") is False
    cmd(page, "BracketRight")
    expect(heading(page)).to_have_text("Design review")
    assert hash_of(page) == f"#/{B}"
    page.locator('.views [data-view="people"]').click()
    expect(heading(page)).to_have_text("People")
    page.go_back()  # a two-finger swipe: the web view's own Back
    expect(heading(page)).to_have_text("Design review")
    page.go_back()
    expect(_tab(page, "Transcript")).to_have_attribute("aria-selected", "true")
    expect(heading(page)).to_have_text("Team standup")


def test_back_in_the_browser_history_goes_to_the_page_left(page, shared_server):
    goto(page, shared_server, "#/glossary")
    page.locator("#settings-btn").click()
    expect(heading(page)).to_have_text("Settings")
    page.go_back()
    expect(heading(page)).to_have_text("Glossary")
    page.go_forward()
    expect(heading(page)).to_have_text("Settings")


def test_a_link_to_a_project_and_back(page, app_server):
    pid = next(p["id"] for p in app_server.api("/api/projects", {"name": "Pelican"})["projects"])
    app_server.api(f"/api/meetings/{A}/projects", {"project": pid})
    open_meeting(page, app_server, A, tab="Transcript")
    page.locator("#main .project-chip").get_by_role("button", name="Pelican", exact=True).click()
    expect(heading(page)).to_have_text("Projects")
    assert hash_of(page) == f"#/projects/{pid}"
    section = page.locator(f"#project-{pid}")
    expect(section).to_be_in_viewport()
    unfocus(page)
    cmd(page, "BracketLeft")
    expect(heading(page)).to_have_text("Team standup")
    expect(_tab(page, "Transcript")).to_have_attribute("aria-selected", "true")
    cmd(page, "BracketRight")
    expect(heading(page)).to_have_text("Projects")
    section.get_by_role("button", name="Team standup", exact=True).click()  # and from the project to its meeting
    expect(heading(page)).to_have_text("Team standup")
    assert hash_of(page) == f"#/{A}"


def test_a_meeting_link_on_the_people_page_and_back(page, shared_server):
    goto(page, shared_server, "#/people")
    eli = page.locator('#main .person[data-person="Eli"]')
    expect(eli.get_by_role("button", name="Design review", exact=True)).to_be_hidden()  # a person's meetings fold out
    eli.locator(".person-meta").click()
    eli.get_by_role("button", name="Design review", exact=True).click()
    expect(heading(page)).to_have_text("Design review")
    unfocus(page)
    cmd(page, "BracketLeft")
    expect(heading(page)).to_have_text("People")


def test_a_reload_stays_on_the_page_and_tab(page, shared_server):
    open_meeting(page, shared_server, A, tab="Transcript")
    list_item(page, B).click()
    expect(heading(page)).to_have_text("Design review")
    show_tab(page, "Transcript")
    reload(page)
    expect(heading(page)).to_have_text("Design review")
    expect(_tab(page, "Transcript")).to_have_attribute("aria-selected", "true")
    assert page.evaluate("window.palaver.command('back')")  # the history is still there (a swipe, ⌘[ or the menu)
    expect(heading(page)).to_have_text("Team standup")


def test_the_tests_reload_waits_for_an_open_request_and_cuts_none_off(page, shared_server):
    """helpers.reload: a request still open when the page reloads is a page error in WebKit (the guard fails the
    test), and the page polls every 3 s. The reload waits for it; the page reported nothing (the guard)."""
    goto(page, shared_server)
    held, let_go = [], []

    def ping(route):  # a ping stays open until let go
        if let_go:
            route.fulfill(json={"ok": True})
        else:
            held.append(route)

    page.route("**/api/ping", ping)
    page.evaluate("window.__mark = 1; fetch('/api/ping'); 0")  # not awaited
    page.wait_for_function("window.__requests > 0")
    with page.expect_navigation():
        page.evaluate(RELOAD_WHEN_QUIET)
        page.wait_for_timeout(400)
        assert page.evaluate("window.__mark") == 1  # not reloaded while the ping is open
        let_go.append(True)
        for route in held:
            route.fulfill(json={"ok": True})
    assert page.evaluate("window.__mark") is None  # a new page
    expect(page.locator("#main > *").first).to_be_visible()


def test_cmd_bracket_in_a_text_field_is_the_fields(page, shared_server):
    open_meeting(page, shared_server, A)
    list_item(page, B).click()
    expect(heading(page)).to_have_text("Design review")
    page.locator("#search").click()
    cmd(page, "BracketLeft")
    page.wait_for_timeout(300)
    expect(heading(page)).to_have_text("Design review")


def test_the_meetings_tab_goes_back_to_the_meeting_open_last(page, shared_server):
    open_meeting(page, shared_server, B)
    page.locator('.views [data-view="glossary"]').click()
    expect(heading(page)).to_have_text("Glossary")
    page.locator('.views [data-view="meetings"]').click()
    expect(heading(page)).to_have_text("Design review")
    assert hash_of(page) == f"#/{B}"


def test_the_meetings_tab_opens_the_newest_meeting_first(page, shared_server):
    goto(page, shared_server)  # Today (tests/e2e/test_today.py)
    page.locator('.views [data-view="meetings"]').click()
    expect(list_item(page, LIVE)).to_have_attribute("aria-current", "true")
    assert hash_of(page) == f"#/{LIVE}"
    assert page.evaluate("window.palaver.command('back')")
    expect(heading(page)).to_have_text("Today")
    assert page.evaluate("window.palaver.command('back')") is False
