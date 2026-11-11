"""Report a Problem (#59): the form from ⌘K, a meeting's ⋯ menu, Settings and
an error toast; it writes one zip to the Desktop of the server's (test) home and says where."""

import json
import re
import zipfile

import pytest

from playwright.sync_api import expect  # noqa: E402

from .helpers import cmd, expect_toast, goto, heading, open_meeting, run_from_menu, toast  # noqa: E402
from .recordings import A, B, TITLES  # noqa: E402
from .stores import read_usage, support_dir  # noqa: E402

pytestmark = pytest.mark.e2e


def _form(page):
    return page.locator("#main .report-form")


def test_the_form_from_cmd_k_writes_the_zip_to_the_desktop(page, app_server):
    open_meeting(page, app_server, B)
    cmd(page, "k")
    page.keyboard.type("report a problem")
    expect(page.locator(".palette").get_by_role("option").first).to_contain_text("Report a Problem")
    page.keyboard.press("Enter")
    expect(heading(page)).to_have_text("Report a Problem")
    form = _form(page)
    expect(form.get_by_label("A problem")).to_be_checked()
    meeting = form.get_by_label("The meeting it is about")
    expect(meeting.locator("option:checked")).to_contain_text(TITLES[B])  # the one that was open
    audio = form.get_by_label("Include this meeting's audio")
    expect(audio).not_to_be_checked()
    form.get_by_label("What happened?").fill("The second speaker got my name")
    form.get_by_role("button", name="Create Report").click()

    expect_toast(page, re.compile(r"^Report saved to .*Palaver report .*\.zip · \d"))
    expect(form.locator(".report-done")).to_contain_text("shown in Finder")
    [zip_path] = (app_server.home / "Desktop").glob("Palaver report *.zip")
    assert app_server.revealed == [zip_path]
    with zipfile.ZipFile(zip_path) as z:
        report = json.loads(z.read("report.json"))
        names = z.namelist()
    assert report["form"] == {"kind": "bug", "text": "The second speaker got my name", "meeting": B, "audio": False}
    assert f"meetings/{B}/transcript.json" in names and not [n for n in names if n.endswith(".wav")]


def test_a_wish_about_no_meeting(page, app_server):
    goto(page, app_server, "#/settings")
    page.locator("#main").get_by_role("button", name="Report a Problem…").click()
    expect(heading(page)).to_have_text("Report a Problem")
    form = _form(page)
    form.get_by_label("A wish").check()
    form.get_by_label("The meeting it is about").select_option("")
    expect(form.get_by_label("Include this meeting's audio")).to_be_disabled()
    form.get_by_label("What happened?").fill("A dark icon, please")
    form.get_by_role("button", name="Create Report").click()
    expect(toast(page)).to_contain_text("Report saved to")
    [zip_path] = (app_server.home / "Desktop").glob("*.zip")
    with zipfile.ZipFile(zip_path) as z:
        assert json.loads(z.read("report.json"))["form"] == {"kind": "wish", "text": "A dark icon, please",
                                                              "meeting": None, "audio": False}


def test_a_meetings_menu_reports_a_problem_with_it(page, app_server):
    open_meeting(page, app_server, A)
    run_from_menu(page, "More actions", "Report a Problem with This Meeting…")
    expect(heading(page)).to_have_text("Report a Problem")
    expect(_form(page).get_by_label("The meeting it is about").locator("option:checked")).to_contain_text(TITLES[A])
    assert page.evaluate("location.hash") == f"#/report/{A}"


def test_an_error_toast_offers_a_report_that_starts_with_its_words(page, app_server):
    page.guard.allow(r"status of 500")
    page.route(re.compile(r"/api/meetings/[^/]+/speakers$"),
               lambda route: route.fulfill(status=500, content_type="application/json", body='{"error": "disk full"}'))
    open_meeting(page, app_server, A, tab="Transcript")
    field = page.get_by_label("Name for Speaker 2")
    field.fill("Bob")
    field.press("Enter")
    expect_toast(page, "The name was not saved: disk full")
    toast(page).get_by_role("button", name="Report…").click()
    expect(heading(page)).to_have_text("Report a Problem")
    expect(_form(page).get_by_label("What happened?")).to_have_value(
        "Palaver said: “The name was not saved: disk full”\n\n")
    expect(_form(page).get_by_label("The meeting it is about").locator("option:checked")).to_contain_text(TITLES[A])


def test_what_the_window_does_is_counted(page, app_server):
    support = support_dir(app_server.home)  # the server's usage log and feature catalog

    open_meeting(page, app_server, A)
    run_from_menu(page, "More actions", "Report a Problem with This Meeting…")
    expect(heading(page)).to_have_text("Report a Problem")
    page.evaluate("window.dispatchEvent(new Event('pagehide'))")  # posts what was counted now, not in 5 s
    events = []
    for _ in range(50):
        events = read_usage(support / "usage.jsonl")
        seen = {(e.get("kind"), e.get("id")) for e in events}
        if ("action", "meeting.report") in seen and ("view", "report") in seen:  # they may come in two posts
            break
        page.wait_for_timeout(100)
    kinds = {(e["kind"], e.get("id")) for e in events}
    assert ("action", "meeting.report") in kinds and ("view", "report") in kinds
    catalog = json.loads((support / "usage-features.json").read_text())
    assert "meeting.report" in catalog["action"] and "lane.notSpeaker" in catalog["action"]
