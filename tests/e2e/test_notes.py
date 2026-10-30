"""Writing notes: the time it takes so far, Cancel, the usual time once known."""

import re

import pytest

from playwright.sync_api import expect  # noqa: E402

from .helpers import cmd, expect_toast, list_item, open_meeting, unfocus  # noqa: E402
from .recordings import A, B  # noqa: E402

pytestmark = pytest.mark.e2e


def _write_button(page):
    return page.locator("#main .toolbar .tbtn.primary")


def test_writing_shows_the_time_so_far(page, app_server):
    app_server.notes.hold()
    open_meeting(page, app_server, A)
    _write_button(page).click()
    bar = page.locator("#main .notes .writing")
    expect(bar).to_contain_text("Writing notes · 0:0")
    expect(_write_button(page)).to_be_disabled()
    expect(_write_button(page)).to_contain_text("Writing notes · 0:0")
    expect(list_item(page, A).locator(".item-state")).to_have_text("Writing notes…")
    expect(bar).to_contain_text(re.compile(r"Writing notes · 0:0[1-9]"))  # it counts
    app_server.notes.release()
    expect(bar).to_have_count(0)
    expect(_write_button(page)).to_be_enabled()
    expect(_write_button(page)).to_have_text(re.compile("Rewrite notes"))
    assert app_server.notes.calls == [A]


def test_write_notes_with_its_key(page, app_server):
    open_meeting(page, app_server, A)
    unfocus(page)
    cmd(page, "Shift+N")
    expect(_write_button(page)).to_be_enabled()
    assert app_server.notes.calls == [A]


def test_cancel_restores_the_button(page, app_server):
    app_server.notes.hold()
    open_meeting(page, app_server, A)
    _write_button(page).click()
    bar = page.locator("#main .notes .writing")
    expect(bar).to_be_visible()
    bar.get_by_role("button", name="Cancel").click()
    expect(bar).to_have_count(0)
    expect(_write_button(page)).to_be_enabled()
    expect(_write_button(page)).to_have_text(re.compile("Rewrite notes"))
    expect(list_item(page, A).locator(".item-state")).to_have_count(0)


def test_failed_notes_say_so_and_try_again(page, app_server):
    page.guard.allow(r"status of 502")
    app_server.notes.ok = False
    open_meeting(page, app_server, A)
    _write_button(page).click()
    toast = expect_toast(page, "Notes were not written: The language model could not write the notes; see the log")
    app_server.notes.ok = True
    toast.get_by_role("button", name="Try again").click()
    expect(page.locator("#main .notes .writing")).to_have_count(0)
    assert app_server.notes.calls == [A, A]


def test_an_estimate_shows_once_two_runs_are_known(page, app_server):
    """The usual time is the median of the runs before: none for the first two
    runs, shown from the third on (logic.notesEstimate needs two)."""
    open_meeting(page, app_server, A)
    bar = page.locator("#main .notes .writing")
    for run in range(3):
        app_server.notes.hold()
        _write_button(page).click()
        expect(bar).to_be_visible()
        if run < 2:
            expect(bar).not_to_contain_text("~")
        else:
            expect(bar).to_contain_text(re.compile(r"Writing notes · 0:\d\d · ~\d+ s"))
            expect(_write_button(page)).to_contain_text("· ~")
        app_server.notes.release()
        expect(bar).to_have_count(0)
    assert len(page.evaluate("JSON.parse(localStorage.getItem('palaver.notesDurations'))")) == 3


def test_notes_written_while_another_meeting_is_open(page, app_server):
    app_server.notes.hold()
    open_meeting(page, app_server, A)
    _write_button(page).click()
    expect(page.locator("#main .notes .writing")).to_be_visible()
    list_item(page, B).click()
    expect(page.locator("#main h1")).to_have_text("Design review")
    expect(list_item(page, A).locator(".item-state")).to_have_text("Writing notes…")
    app_server.notes.release()
    expect(list_item(page, A).locator(".item-state")).to_have_count(0)
    expect(page.locator("#main h1")).to_have_text("Design review")  # it stays on the meeting open
    list_item(page, A).click()
    expect(_write_button(page)).to_be_enabled()


def test_notes_a_restarted_server_finds_running_show_until_they_are_done(page, app_server):
    """The window's server was restarted while the app wrote notes (#57):
    the reloaded page shows the run, offers no second one, and shows the
    notes once it is done."""
    import sys

    from palaver import model_jobs

    root = model_jobs.jobs_root(app_server.root)
    model_jobs.launch(root, "notes", A, [sys.executable, "-c", "import time; time.sleep(4)"])
    open_meeting(page, app_server, A)
    bar = page.locator("#main .notes .writing")
    expect(bar).to_contain_text("Writing notes", timeout=10_000)
    expect(bar.get_by_role("button", name="Cancel")).to_have_count(0)  # not this page's run
    expect(_write_button(page)).to_be_disabled()
    expect(list_item(page, A).locator(".item-state")).to_have_text("Writing notes…")
    expect(bar).to_have_count(0, timeout=15_000)
    expect(_write_button(page)).to_be_enabled()
    assert app_server.notes.calls == []  # no second run
