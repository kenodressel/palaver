"""The setup assistant (#55) in the window: the first start opens it; three
steps (you and your calendar, the recommended package, the test), Customize,
Skip, Back, re-open from Settings. The Mac is a fake (tests/fake_probe.py): no real checks, no
downloads, no microphone, no sound."""

from __future__ import annotations

import json
import re
import threading
from datetime import datetime, timedelta

import pytest
from playwright.sync_api import expect

from palaver import onboarding as ob, settings
from palaver.calendar_events import Attendee, Event
from palaver.webapp import api
from palaver.webapp.server import App, make_server
from tests.fake_probe import FakeProbe

from .conftest import Served, FakeNotes
from .helpers import expect_toast, goto, hash_of, heading, toast


def _calendar(start, end):
    at = datetime.now().astimezone() - timedelta(days=1)
    me = Attendee("Timo Strauss", "timo@kloud.io", is_self=True)
    return [Event("Contoso Northwind Weekly", at, at + timedelta(hours=1),
                  (me, Attendee("Stefan Dornbusch", "stefan@contoso.at")))]


@pytest.fixture
def fresh(tmp_path):
    """The app on its first start: no recordings yet, never set up."""
    root = tmp_path / "Recordings"
    root.mkdir()
    probe = FakeProbe()
    served = Served("", root, FakeNotes(), probe=probe)
    app = App(root, "User", calendar=_calendar, probe=probe, recording=served.recording)
    srv = make_server(app, port=0)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    served.url = f"http://127.0.0.1:{srv.server_address[1]}/"
    served.server = srv
    yield served
    served.close()


@pytest.fixture
def no_mcp_install(monkeypatch):
    added = []
    monkeypatch.setattr(api, "install_mcp", lambda target="code", cli_options=(): added.append(target) or api.mcp_status())
    return added


def primary(page):
    return page.locator("#main .setup-actions .btn.primary")


def step_title(page, title):
    expect(heading(page)).to_have_text(title)


def rec(page, rid):
    return page.locator(f'#main .setup-rec[data-rec="{rid}"]')


def pack(page, rid):
    return page.locator(f'#main .setup-pack-item[data-rec="{rid}"]')


def customize_all(page):
    page.locator("#main .setup-customize-all").click()


def test_the_first_start_takes_three_steps(page, fresh, no_mcp_install):
    page.goto(fresh.url)
    step_title(page, "You and your calendar")
    expect(page.locator(".setup-count")).to_have_text("Setup · step 1 of 3")
    expect(page.locator("#setup-name")).to_have_value("Timo Strauss")  # from the macOS account
    expect(page.locator("#setup-org")).to_have_value("KLOUD")  # from the calendar
    expect(page.locator(".setup-seed-term")).to_have_count(3)  # Stefan Dornbusch, Contoso, Northwind
    expect(page.locator(".setup-seed-term input:checked")).to_have_count(0)  # nothing ticked for the user
    add = page.get_by_role("button", name="Add 0 terms")
    expect(add).to_be_disabled()
    page.locator(".setup-seed-term", has_text="Stefan").locator("input").check()
    page.locator(".setup-seed-term", has_text="Northwind").locator("input").check()
    page.get_by_role("button", name="Add 2 terms").click()
    expect_toast(page, "2 terms added to the glossary")
    expect(page.locator(".setup-seed-term")).to_have_count(1)  # Contoso is left
    expect(page.locator(".setup-renamed")).to_be_hidden()
    page.locator("#setup-name").fill("Timo Strauß")
    expect(page.locator(".setup-renamed")).to_have_text(
        "Earlier meetings show your old name in their transcripts. Palaver still knows it is you.")
    page.locator("#setup-name").fill("Timo Strauss")
    primary(page).click()

    step_title(page, "Recommended for this Mac")
    expect(page.locator("#main .lede")).to_contain_text("M4 Pro with 48 GB")
    expect(pack(page, "language_model")).to_contain_text("Gemma 4 12B on this Mac")
    expect(pack(page, "record_teams")).to_be_visible()
    expect(pack(page, "claude_code")).to_be_visible()
    expect(page.locator("#main")).to_contain_text("nothing leaves it")
    expect(page.locator(".setup-downloads")).to_contain_text("Speech models (500 MB)")
    customize_all(page)  # every choice with its reason
    lm = rec(page, "language_model")
    expect(lm.locator(".setup-why")).to_contain_text("48 GB")
    expect(rec(page, "realtime").locator(".setup-why")).to_contain_text("M4 Pro")
    expect(rec(page, "record_slack").locator(".setup-why")).to_contain_text("not installed")
    assert fresh.probe.fetched == []  # nothing downloads until the user agrees
    expect(primary(page)).to_have_text("Use recommended")
    primary(page).click()

    step_title(page, "Test recording")
    expect(page.locator("#setup-downloads")).to_contain_text("downloaded")  # the click started them
    assert sorted(fresh.probe.fetched) == ["e5", "gemma", "speech"]
    assert fresh.probe.autostart_on and no_mcp_install == ["code"]
    expect(page.locator("#main")).not_to_contain_text("headphone")
    assert fresh.probe.recorder.started == []  # never by itself
    primary(page).click()  # Start test recording
    expect(primary(page)).to_have_text("Stop")
    primary(page).click()
    expect(page.locator("#main .setup-checks").first).to_contain_text("This is my test sentence")
    expect(page.locator("#main .setup-checks").first).to_contain_text("quiet, as nothing played")
    expect(primary(page)).to_have_text("Done")
    primary(page).click()
    expect_toast(page, re.compile(r"^Setup done\."))
    assert hash_of(page) == "#/today"  # the start page
    expect(heading(page)).to_have_text("Today")

    saved = settings.read_raw()
    assert saved["setup"]["done"] and saved["setup"]["hardware"] == "Apple M4 Pro, 48 GB"
    assert saved["user_name"] == "Timo Strauss"
    assert sorted(t["term"] for t in json.loads((settings.path().parent / "glossary.json").read_text())["terms"].values()) \
        == ["Northwind", "Stefan Dornbusch"]


def test_skip_a_step_changes_nothing_and_skip_setup_is_remembered(page, fresh):
    page.goto(fresh.url)
    step_title(page, "You and your calendar")
    page.locator("#main .setup-actions").get_by_role("button", name="Skip this step").click()
    step_title(page, "Recommended for this Mac")
    page.locator("#main .setup-actions").get_by_role("button", name="Skip this step").click()
    step_title(page, "Test recording")
    assert "local_model" not in settings.read_raw() and "engines" not in settings.read_raw()
    assert fresh.probe.fetched == [] and not fresh.probe.autostart_on
    page.locator("#main .setup-actions").get_by_role("button", name="Back").click()
    step_title(page, "Recommended for this Mac")
    page.get_by_role("button", name="Skip setup").click()
    expect_toast(page, "Setup skipped. It is in Settings when you want it.")
    assert settings.read_raw()["setup"]["skipped"]
    page.reload()
    page.wait_for_load_state("networkidle")
    expect(page.locator("#main .setup")).to_have_count(0)  # not offered again


def test_the_test_can_be_skipped(page, fresh):
    page.goto(fresh.url + "#/setup/test")
    page.locator("#main .setup-actions").get_by_role("button", name="Skip the test").click()
    expect_toast(page, re.compile(r"^Setup done\."))
    assert fresh.probe.recorder.started == []


def test_customize_picks_an_alternative(page, fresh, no_mcp_install):
    page.goto(fresh.url + "#/setup/recommended")
    customize_all(page)
    lm = rec(page, "language_model")
    lm.get_by_role("button", name="Customize").click()
    expect(lm.get_by_role("radio", name="Qwen3 30B A3B on this Mac")).to_have_count(0)  # no longer offered
    lm.get_by_role("radio", name="None yet: set up a cloud model").check()
    expect(lm.get_by_role("radio", name="Anthropic API")).to_be_disabled()  # no key yet
    expect(primary(page)).to_have_text("Use these")
    page.locator("#main .setup-customize-all").click()  # back to the summary: it shows the pick
    expect(pack(page, "language_model")).to_contain_text("None yet: set up a cloud model")
    expect(pack(page, "language_model")).to_contain_text("recommended: Gemma 4 12B on this Mac")
    primary(page).click()
    step_title(page, "Test recording")
    assert settings.read_raw()["engines"] == {"notes": "pending", "projects": "pending"}


def test_reopen_from_settings_with_the_recommendations(page, app_server):
    goto(page, app_server, "#/settings/recording")  # meetings exist: the first start opened nothing
    step = page.locator("#main .switch-row", has_text="Realtime transcription")
    expect(step).to_be_visible()
    # A switch set as recommended needs no word; one set otherwise says what is recommended.
    expect(page.locator("#main .setup-hint")).to_have_count(0)
    step.get_by_role("switch").click(force=True)  # the drawn track lies over the checkbox
    expect(page.locator("#main .setup-hint").first).to_contain_text("Recommended for this Mac: On")
    step.get_by_role("switch").click(force=True)  # the drawn track lies over the checkbox
    expect(page.locator("#main .setup-hint")).to_have_count(0)
    page.locator(".settings-nav").get_by_role("link", name="General").click()
    page.get_by_role("button", name="Open setup assistant").click()
    step_title(page, "You and your calendar")
    page.locator("#main .setup-actions").get_by_role("button", name="Skip this step").click()
    step_title(page, "Recommended for this Mac")
    page.locator("#main .setup-actions").get_by_role("button", name="Back").click()
    step_title(page, "You and your calendar")
    assert page.evaluate("window.palaver.command('back')")  # Back (a swipe, ⌘[) leaves the assistant
    expect(heading(page)).to_have_text("Settings")


def test_an_existing_user_is_not_shown_the_assistant(page, app_server):
    goto(page, app_server)
    expect(heading(page)).not_to_have_text("You and your calendar")
    expect(page.locator(".setup")).to_have_count(0)


def test_a_new_mac_offers_a_review(page, app_server):
    settings.update({"setup": {"done": "2026-10-01T09:00:00+02:00", "hardware": "Apple M1, 16 GB"}})
    goto(page, app_server)
    t = expect_toast(page, "This is another Mac (Apple M4 Pro, 48 GB). Review the recommended settings?")
    t.get_by_role("button", name="Review").click()
    step_title(page, "Recommended for this Mac")


def test_reopening_keeps_a_deliberate_choice(page, fresh, no_mcp_install):
    settings.update({"realtime": False, "setup": {"done": "2026-10-01T09:00:00+02:00",
                                                  "hardware": "Apple M4 Pro, 48 GB"}})
    page.goto(fresh.url + "#/setup/recommended")
    expect(pack(page, "realtime")).to_contain_text("Off")
    expect(pack(page, "realtime")).to_contain_text("recommended: On")
    expect(primary(page)).to_have_text("Keep current")
    expect(page.locator("#main .setup-actions .setup-secondary")).to_have_text("Use recommended")
    primary(page).click()
    step_title(page, "Test recording")
    assert settings.read_raw()["realtime"] is False  # kept


def test_a_failed_download_can_be_tried_again(page, fresh, no_mcp_install):
    fresh.probe.fail_once = {"speech"}
    page.goto(fresh.url + "#/setup/recommended")
    primary(page).click()
    step_title(page, "Test recording")
    retry = page.locator('#setup-downloads .setup-retry[data-model="speech"]')
    expect(retry).to_have_text("Try again")
    expect(page.locator("#setup-downloads")).to_contain_text("failed: connection reset")
    retry.click()
    expect(page.locator("#setup-downloads .setup-retry")).to_have_count(0)
    assert fresh.probe.fetched.count("speech") == 2


def test_the_assistant_asks_for_no_hugging_face_token(page, fresh, no_mcp_install):
    page.goto(fresh.url + "#/setup/recommended")
    expect(page.locator("#main")).to_contain_text("Speech models")
    expect(page.locator(".setup-token")).to_have_count(0)
    expect(page.locator("#main")).not_to_contain_text("Hugging Face token")
    primary(page).click()
    step_title(page, "Test recording")  # the download starts with no token
    assert fresh.probe.fetched.count("speech") == 1


def test_a_cloud_model_that_is_not_set_up_leaves_notes_off(page, fresh, no_mcp_install):
    fresh.probe._hardware = ob.Hardware("Apple M2 Pro", 16, 200)
    page.goto(fresh.url + "#/setup/recommended")
    expect(pack(page, "language_model")).to_contain_text("None yet: set up a cloud model")
    expect(pack(page, "language_model")).to_contain_text("needs setting up in Settings")
    customize_all(page)
    lm = rec(page, "language_model")
    expect(lm.locator(".setup-why")).to_contain_text("16 GB")
    expect(lm.locator(".setup-why")).to_contain_text("Small local models wrote clearly worse notes in our tests")
    expect(lm.get_by_role("button", name="Set up a cloud model in Settings")).to_be_visible()
    expect(primary(page)).to_have_text("Use recommended")
    primary(page).click()
    step_title(page, "Test recording")
    # Notes wait for a cloud model: never left on Gemma, and Gemma is not downloaded.
    assert settings.read_raw()["engines"] == {"notes": "pending", "projects": "pending"}
    assert "gemma" not in fresh.probe.fetched


def test_connect_calendar_in_the_assistant(page, fresh):
    page.goto(fresh.url + "#/setup/you")
    step_title(page, "You and your calendar")
    row = page.locator("#main .setup-check", has_text="Calendar")
    row.get_by_role("button", name="Connect Calendar").click()
    expect(row).to_have_class(re.compile(r"\bok\b"))  # macOS's dialog answered: the page follows by itself
    expect(row).to_contain_text("connected (read only)")
    expect(row.get_by_role("button")).to_have_count(0)
    assert fresh.probe.calendar.asked == 1


def test_a_calendar_connected_from_the_menu_shows_and_keeps_what_was_typed(page, fresh):
    page.goto(fresh.url + "#/setup/you")
    step_title(page, "You and your calendar")
    row = page.locator("#main .setup-check", has_text="Calendar")
    expect(row.get_by_role("button", name="Connect Calendar")).to_be_visible()
    page.locator("#setup-name").fill("Timo S.")
    fresh.probe.calendar.grant()  # Connect Calendar… in the menu bar
    expect(row).to_have_class(re.compile(r"\bok\b"), timeout=5000)
    expect(page.locator("#setup-name")).to_have_value("Timo S.")
    assert fresh.probe.calendar.asked == 0


def test_a_refused_calendar_opens_system_settings(page, fresh):
    fresh.probe._permissions["calendar"] = {"state": "denied", "detail": "not allowed"}
    page.goto(fresh.url + "#/setup/you")
    row = page.locator("#main .setup-check", has_text="Calendar")
    row.get_by_role("button", name="Open System Settings").click()
    expect_toast(page, re.compile("System Settings is open at Calendars"))
    assert fresh.probe.calendar.opened_settings == 1 and fresh.probe.calendar.asked == 0


def test_an_existing_user_without_the_speech_models_is_told_their_meetings_wait(page, app_server):
    app_server.probe._downloaded.discard("speech")
    goto(page, app_server)
    expect_toast(page, "Speech models are not downloaded yet.")
