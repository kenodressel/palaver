"""Every page of the Meetings window loads, the search finds, a setting stays."""

import re

import pytest

from playwright.sync_api import expect  # noqa: E402

from .helpers import audio, goto, heading, list_ids, list_item, open_meeting  # noqa: E402
from .recordings import A, B, C, LIVE  # noqa: E402

pytestmark = pytest.mark.e2e


@pytest.mark.parametrize("where, title", [
    ("#/today", "Today"),
    (f"#/{A}", "Team standup"),
    (f"#/{LIVE}", re.compile("Meeting at")),
    ("#/people", "People"),
    ("#/projects", "Projects"),
    ("#/glossary", "Glossary"),
    ("#/settings", "Settings"),
    ("#/coach", "How you talk"),
])
def test_every_page_loads_without_errors(page, shared_server, where, title):
    goto(page, shared_server, where)
    expect(heading(page)).to_have_text(title)


def test_the_review_loads(page, shared_server):
    goto(page, shared_server)
    expect(page.locator('.views [data-view="today"] .nav-count')).to_have_text("3")
    page.get_by_role("button", name="Review all in order").click()
    expect(page.locator("#main .review-bar")).to_contain_text("Review · 1 of 3")
    expect(page.locator("#main .review h1")).to_have_text("Design review, part two")
    page.get_by_role("button", name="Skip").click()
    expect(page.locator("#main .review-bar")).to_contain_text("Review · 2 of 3")


def test_the_top_bar_goes_to_every_page(page, shared_server):
    goto(page, shared_server)
    expect(heading(page)).to_have_text("Today")  # the start page
    for view, title in [("people", "People"), ("projects", "Projects"), ("glossary", "Glossary"), ("today", "Today")]:
        page.locator(f'.views [data-view="{view}"]').click()
        expect(heading(page)).to_have_text(title)
        expect(page.locator(f'.views [data-view="{view}"]')).to_have_attribute("aria-current", "page")
        expect(page.locator("body")).to_have_attribute("data-page", view)
    page.locator("#settings-btn").click()
    expect(heading(page)).to_have_text("Settings")
    page.locator('.views [data-view="meetings"]').click()
    expect(heading(page)).to_have_text(re.compile("Meeting at"))


def test_the_coach_tab_of_a_meeting(page, shared_server):
    open_meeting(page, shared_server, A, tab="Coach")
    expect(page.locator("#main .coach-card").first).to_be_visible()
    page.get_by_role("button", name="All meetings →").click()
    expect(heading(page)).to_have_text("How you talk")
    page.locator("#main .coach-table tbody tr", has_text="Design review").first.click()
    expect(page.get_by_role("tab", name="Coach")).to_have_attribute("aria-selected", "true")


@pytest.mark.usefixtures("audio_decoding")
def test_search_finds_a_word_in_a_transcript(page, shared_server):
    goto(page, shared_server, f"#/{B}")
    page.locator("#search").fill("pelican")
    result = list_item(page, A)
    expect(result.locator("mark")).to_have_text("pelican")
    expect(page.locator("#list .item")).to_have_count(1)
    result.click()
    expect(heading(page)).to_have_text("Team standup")
    expect(page.get_by_role("tab", name="Transcript")).to_have_attribute("aria-selected", "true")
    expect(page.locator("#clock")).to_have_text("0:15")  # at the line found
    assert audio(page)["time"] == pytest.approx(15, abs=0.5)
    page.locator("#search").fill("nothing like this")
    expect(page.locator("#list")).to_contain_text("Nothing found for “nothing like this”.")
    page.locator("#search").fill("")
    expect(page.locator("#list .item[data-id]")).to_have_count(4)


def test_the_filter_shows_one_persons_meetings(page, shared_server):
    goto(page, shared_server, f"#/{A}")
    page.locator("#filter").select_option(label="Dana (2)")
    expect(page.locator("#list .item[data-id]")).to_have_count(2)
    assert list_ids(page) == [C, B]
    page.locator("#filter").select_option(label="All meetings")
    expect(page.locator("#list .item[data-id]")).to_have_count(4)


def test_a_settings_switch_persists_after_reload(page, app_server):
    goto(page, app_server, "#/settings")
    switch = page.get_by_role("switch", name="Realtime transcription")
    expect(switch).to_be_checked()  # on by default
    page.locator("label.switch-row", has_text="Realtime transcription").click()
    expect(switch).not_to_be_checked()
    expect(switch).to_be_focused()  # the page was rebuilt; the keyboard stays on the switch
    page.reload()
    expect(heading(page)).to_have_text("Settings")
    expect(page.get_by_role("switch", name="Realtime transcription")).not_to_be_checked()
    assert app_server.api("/api/settings")["realtime"] is False


def test_a_provider_card_saves_its_key_with_one_save(page, app_server, fake_keychain):
    """No separate "Save key": the card's Save stores a key typed into it, then the rest."""
    goto(page, app_server, "#/settings")
    card = page.locator(".settings-card", has=page.get_by_role("heading", name="Anthropic API"))
    expect(card.get_by_role("button", name="Save key")).to_have_count(0)
    card.get_by_role("textbox", name="Model for Anthropic API").fill("claude-test-model")
    card.get_by_role("textbox", name="API key for Anthropic API").fill("sk-test-123")
    card.get_by_role("button", name="Save", exact=True).click()
    card = page.locator(".settings-card", has=page.get_by_role("heading", name="Anthropic API"))
    expect(card).to_contain_text("Key set ✓")
    assert "sk-test-123" in fake_keychain.values()
    anthropic = next(p for p in app_server.api("/api/language-model")["providers"] if p["label"] == "Anthropic API")
    assert anthropic["model"] == "claude-test-model" and anthropic["key_set"]

    # Enter in the key field is that Save too: a transcription service.
    card = page.locator(".settings-card", has=page.get_by_role("heading", name="Soniox"))
    field = card.get_by_role("textbox", name="API key for Soniox")
    field.fill("soniox-key")
    field.press("Enter")
    card = page.locator(".settings-card", has=page.get_by_role("heading", name="Soniox"))
    expect(card).to_contain_text("Key set ✓")
    assert "soniox-key" in fake_keychain.values()


def test_settings_say_how_palaver_updates_and_uninstalling_asks_first(page, app_server):
    """#60: a checkout has no updates; "Uninstall Palaver…" asks, and Cancel
    changes nothing."""
    goto(page, app_server, "#/settings")
    section = page.locator("#update-section")
    expect(section.get_by_role("heading", name="Updates")).to_be_visible()
    expect(section.get_by_role("status")).to_contain_text("runs from a checkout")
    section.get_by_role("button", name="Uninstall Palaver…").click()
    box = page.get_by_role("dialog", name="Uninstall Palaver?")
    expect(box.get_by_role("checkbox", name=re.compile("Also delete my recordings"))).not_to_be_checked()
    expect(box.get_by_role("button", name="Uninstall")).to_be_focused()
    box.get_by_role("button", name="Cancel").click()
    expect(box).to_have_count(0)
