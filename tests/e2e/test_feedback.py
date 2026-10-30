"""The toast and ⌘Z: Undo in the toast, the toast waits while the pointer is
on it, one toast at a time, ⌘Z in a text field, ⌘Z several times in order."""

import pytest

from playwright.sync_api import expect  # noqa: E402

from .helpers import cmd, expect_toast, open_meeting, toast, undo_in_toast, unfocus  # noqa: E402
from .recordings import A  # noqa: E402

pytestmark = pytest.mark.e2e


def _add_project(page, name: str):
    field = page.get_by_label("Add to a project, or name a new one")
    field.fill(name)
    field.press("Enter")
    expect_toast(page, f"Added to {name}")


def _chips(page):
    return page.locator("#main .project-chip > button.link")


def test_the_toasts_undo_reverts_and_leaves_nothing_for_cmd_z(page, app_server):
    open_meeting(page, app_server, A)
    _add_project(page, "Pelican")
    undo_in_toast(page)
    expect(_chips(page)).to_have_count(0)
    unfocus(page)
    cmd(page, "z")
    expect(toast(page).locator(".toast-text")).to_have_text("Nothing to undo")


def test_the_toast_waits_while_the_pointer_is_on_it(page, app_server):
    page.clock.install()
    open_meeting(page, app_server, A)
    _add_project(page, "Pelican")
    t = toast(page)
    t.hover()
    expect(t).to_have_class("toast paused")
    page.clock.run_for(20_000)  # far longer than the toast's 8 s
    expect(t).to_be_visible()
    page.mouse.move(5, 5)
    expect(t).not_to_have_class("toast paused")
    page.clock.run_for(9_000)
    expect(toast(page)).to_have_count(0)


def test_a_toast_goes_after_eight_seconds(page, app_server):
    page.clock.install()
    open_meeting(page, app_server, A)
    _add_project(page, "Pelican")
    page.mouse.move(5, 5)
    page.clock.run_for(5_000)
    expect(toast(page)).to_be_visible()
    page.clock.run_for(4_000)
    expect(toast(page)).to_have_count(0)


def test_only_one_toast_at_a_time(page, app_server):
    open_meeting(page, app_server, A)
    _add_project(page, "Alpha")
    _add_project(page, "Beta")
    expect(page.locator("#toasts .toast")).to_have_count(1)
    unfocus(page)
    cmd(page, "z")  # the first change is still undoable after its toast went
    cmd(page, "z")
    expect(_chips(page)).to_have_count(0)


def test_cmd_z_in_a_text_field_edits_the_text_not_the_app(page, app_server):
    open_meeting(page, app_server, A)
    _add_project(page, "Pelican")
    search = page.locator("#search")
    search.click()
    search.press_sequentially("abc")
    cmd(page, "z")
    expect(search).not_to_have_value("abc")  # the typing was undone: the key reached the field
    page.wait_for_timeout(300)
    expect(_chips(page)).to_have_text(["Pelican"])  # the change stays
    expect(toast(page).locator(".toast-text")).to_have_text("Added to Pelican")


def test_cmd_z_undoes_the_last_three_changes_in_order(page, app_server):
    open_meeting(page, app_server, A)
    for name in ("Alpha", "Beta", "Gamma"):
        _add_project(page, name)
    expect(_chips(page)).to_have_text(["Alpha", "Beta", "Gamma"])
    unfocus(page)
    for left in (["Alpha", "Beta"], ["Alpha"], []):
        cmd(page, "z")
        expect(_chips(page)).to_have_text(left)
    cmd(page, "z")
    expect(toast(page).locator(".toast-text")).to_have_text("Nothing to undo")
    assert app_server.api("/api/projects")["projects"] == []


def test_an_undo_the_server_refuses_says_so(page, app_server):
    page.guard.allow(r"status of 409")
    open_meeting(page, app_server, A)
    _add_project(page, "Pelican")
    pid = app_server.api("/api/projects")["projects"][0]["id"]
    app_server.api(f"/api/projects/{pid}", {"name": "Pelikan"})  # changed since, elsewhere
    toast(page).get_by_role("button", name="Undo").click()
    expect(toast(page).locator(".toast-text")).to_have_text("Can't undo this any more")
    unfocus(page)
    cmd(page, "z")
    expect(toast(page).locator(".toast-text")).to_have_text("Nothing to undo")  # it is gone from ⌘Z too
