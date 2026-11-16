"""The opt-in usage numbers (#6) in the window: Settings → Updates shows the switch (off), the ping byte for byte with
this Mac's values, "New ID" and the public page; the setup assistant asks once and leaves it off. The window's server
never sends a ping (the menu bar app does): nothing goes over the network here."""

from __future__ import annotations

import platform
import re
from pathlib import Path

import pytest
from playwright.sync_api import expect

from .conftest import _serve
from .helpers import expect_toast, goto
from .stores import read_settings, support_dir, write_update_status

STATS = "https://palaver-stats.contoso.workers.dev/ping"
PAGE = "https://palaver-stats.contoso.workers.dev/"
VERSION = (Path(__file__).resolve().parents[2] / "VERSION").read_text().strip()


def _macos() -> str:
    major, minor = (platform.mac_ver()[0].split(".") + ["0"])[:2]
    return f"{major}.{minor}"


def _install_id(served) -> str:
    return (support_dir(served.home) / "install-id").read_text().strip()


def _body(install: str) -> str:
    return f'{{"install": "{install}", "version": "{VERSION}", "macos": "{_macos()}"}}'


@pytest.fixture
def served(tmp_path):
    srv, served = _serve(tmp_path / "Recordings", env={"PALAVER_STATS_URL": STATS})
    yield served
    served.close()


@pytest.fixture
def fresh(tmp_path):
    """The first start: never set up, nothing downloaded."""
    srv, served = _serve(tmp_path / "Recordings", recordings=False, user="User", env={"PALAVER_STATS_URL": STATS})
    served.probe.set(downloaded=[])
    yield served
    served.close()


def test_settings_show_exactly_what_is_sent_and_share_only_once_turned_on(page, served):
    write_update_status({"state": "up_to_date", "current": VERSION, "available": None}, served.home)
    goto(page, served, "#/settings/update")
    card = page.locator("#usage-stats")
    share = card.get_by_role("switch", name="Share anonymous usage numbers")
    expect(share).not_to_be_checked()  # off by default
    install = _install_id(served)
    assert re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", install)
    expect(card.locator(".usage-stats-body")).to_have_text(_body(install))
    expect(card).to_contain_text("Your name, your meetings, their audio and anything from them are never sent.")
    assert "share_usage" not in read_settings()

    share.click(force=True)  # the drawn track lies over the checkbox
    expect(page.locator("#usage-stats")).to_contain_text("Not sent yet.")  # saved: the page is drawn again
    expect(page.locator("#usage-stats").get_by_role("switch", name="Share anonymous usage numbers")).to_be_checked()
    assert read_settings()["share_usage"] is True

    # Without automatic update checks nothing is sent: said where the switch is.
    page.locator("#update-section").get_by_role("switch", name="Look for updates automatically").click(force=True)
    expect(page.locator("#usage-stats")).to_contain_text("Sent only while “Look for updates automatically” is on.")

    page.locator("#usage-stats").get_by_role("button", name="New ID").click()
    expect_toast(page, "New ID made.")
    renewed = _install_id(served)
    assert renewed != install
    expect(page.locator("#usage-stats .usage-stats-body")).to_have_text(_body(renewed))

    link = page.locator("#usage-stats .usage-stats-page")
    expect(link).to_have_text(PAGE)
    with page.expect_response(lambda r: r.url.endswith("/api/usage-stats/open-page")):
        link.click()
    expect(page.locator("#usage-stats")).to_be_visible()  # the window stays where it is
    assert served.opened == [PAGE]  # in the browser, by the server


def test_the_setup_assistant_asks_once_and_leaves_it_off(page, fresh):
    page.goto(fresh.url + "#/setup/recommended")
    card = page.locator("#main .setup-usage")
    share = card.get_by_role("switch", name="Share anonymous usage numbers")
    expect(share).not_to_be_checked(timeout=20_000)  # the first look at this Mac takes a few seconds
    expect(card.locator(".usage-stats-body")).to_have_text(_body(_install_id(fresh)))
    page.locator("#main .setup-actions .btn.primary").click()
    expect(page.locator("#main h1")).to_have_text("Test recording")
    assert "share_usage" not in read_settings()  # left as it was: off


def test_the_setup_assistant_turns_it_on_when_asked(page, fresh):
    page.goto(fresh.url + "#/setup/recommended")
    share = page.locator("#main .setup-usage").get_by_role("switch", name="Share anonymous usage numbers")
    expect(share).not_to_be_checked(timeout=20_000)
    share.click(force=True)
    page.locator("#main .setup-actions .btn.primary").click()
    expect(page.locator("#main h1")).to_have_text("Test recording")
    assert read_settings()["share_usage"] is True
