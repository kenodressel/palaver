"""Ask your meetings (#42): one question across all meetings on the Ask page, answered by palaver-lm's test model in
place of the notes' model from the passages found for it, with sources that open their meeting at the moment. A
meeting is being recorded in these tests, so the local model asks first."""

import json

import pytest

from playwright.sync_api import expect  # noqa: E402

from .helpers import goto, heading  # noqa: E402
from .recordings import B, C  # noqa: E402
from .stores import update_settings  # noqa: E402

pytestmark = pytest.mark.e2e

WARNING = "Runs Gemma on this Mac during the call (about 10 GB, may slow the call)"
ANSWER = {"answer": "Eli wanted other colours [3]; in the second part the darker palette was chosen [4].",
          "sources": [3, 4]}


def _ask(page, question: str):
    field = page.get_by_label("Ask your meetings")
    field.fill(question)
    field.press("Enter")


def test_a_question_is_answered_from_the_passages_with_sources_that_open_the_moment(page, app_server):
    app_server.ask_meetings.answer(ANSWER)
    goto(page, app_server)
    page.locator('.views [data-view="ask"]').click()
    expect(heading(page)).to_have_text("Ask your meetings")
    expect(page).to_have_url(f"{app_server.url}#/ask")
    expect(page.locator(".ask-model")).to_have_text("Gemma, on this Mac · runs only when you ask · nothing leaves this Mac")
    _ask(page, "What did we say about the colours?")
    # The local model during the call: said first, run only on a second click.
    expect(page.locator(".ask-status")).to_contain_text(WARNING)
    assert app_server.ask_meetings.asked == []
    app_server.ask_meetings.gate.clear()
    page.get_by_role("button", name="Run anyway").click()
    expect(page.get_by_role("button", name="Thinking…")).to_be_disabled()
    app_server.ask_meetings.gate.set()
    card = page.get_by_role("region", name="What did we say about the colours?")
    expect(card.locator(".ask-a")).to_have_text(
        "Eli wanted other colours 3; in the second part the darker palette was chosen 4.")
    expect(card.locator(".ask-source-quote")).to_have_text(["Eli: “I like the flow, but the colours need work.”",
                                                            "Dana: “Back from the break, about those colours.”"])
    expect(card.locator(".assistant-note")).to_have_text("From 4 passages in 2 meetings · Gemma 4 12B on this Mac")
    expect(page.get_by_label("Ask your meetings")).to_have_value("")
    (asked,) = app_server.ask_meetings.asked
    assert asked["meetings"] == [B, C]
    prompt = asked["prompt"]
    assert "## Question\nWhat did we say about the colours?" in prompt
    assert "[1] 2026-10-27 · Design review · notes, decision: Rework the colours" in prompt
    assert "Eli: I like the flow, but the colours need work." in prompt
    assert "pelican" not in prompt and "Good morning" not in prompt  # passages, not whole transcripts
    # A citation opens its meeting at the moment.
    card.get_by_role("button", name="Source 4: Design review, part two", exact=False).click()
    expect(heading(page)).to_have_text("Design review, part two")
    expect(page).to_have_url(f"{app_server.url}#/{C}")
    # The answers stay for the session.
    page.locator('.views [data-view="ask"]').click()
    expect(page.locator(".ask-card")).to_have_count(1)
    assert len(app_server.ask_meetings.asked) == 1


def test_nothing_found_runs_no_model(page, app_server):
    goto(page, app_server, "#/ask")
    _ask(page, "When did we talk about the Excel export?")
    expect(page.locator(".ask-card .ask-a")).to_have_text(
        "Nothing in your meetings matches this question. Try other words, or fewer filters.")
    expect(page.locator(".ask-status")).to_be_empty()  # no second click asked: no model would run
    assert app_server.ask_meetings.asked == []


def test_the_palette_asks_the_meetings(page, app_server):
    goto(page, app_server, "#/today")
    page.locator("#palette-btn").click()
    page.keyboard.type("colours")
    page.get_by_text("Ask your meetings “colours”").click()
    expect(heading(page)).to_have_text("Ask your meetings")
    expect(page.locator(".ask-status")).to_contain_text(WARNING)
    expect(page.get_by_label("Ask your meetings")).to_have_value("colours")


def test_a_meeting_kept_on_this_mac_stays_out_of_a_cloud_model(page, app_server):
    (app_server._fake.folder / "keychain.json").write_text(json.dumps({"anthropic.api_key": "sk-ant-e2e-test-key"}))
    update_settings({"engines": {"notes": "anthropic"}})
    (app_server.root / B / "local_only.json").write_text('{"since": "2026-10-27T10:30:00+01:00"}')
    app_server.ask_meetings.answer({"answer": "The darker palette [1].", "sources": [1]})
    goto(page, app_server, "#/ask")
    expect(page.locator(".ask-model")).to_have_text(
        "Claude Opus 5.5, cloud · runs only when you ask · meetings kept on this Mac stay out")
    _ask(page, "What did we say about the colours?")
    card = page.locator(".ask-card")
    expect(card.locator(".ask-a")).to_have_text("The darker palette 1.")
    expect(card.locator(".ask-left-out")).to_contain_text(
        "1 meeting kept on this Mac matches too: it was left out, a cloud model never sees it.")
    (asked,) = app_server.ask_meetings.asked
    assert asked["meetings"] == [C] and "Rework the colours" not in asked["prompt"]
    # On this Mac: the local model, with it (asked first: a meeting is being recorded).
    card.get_by_role("button", name="Ask on this Mac").click()
    page.get_by_role("button", name="Run anyway").click()
    expect(page.locator(".ask-card")).to_have_count(1)  # the same question, answered again
    expect(page.locator(".ask-card .assistant-note")).to_contain_text("Gemma 4 12B on this Mac")
    assert app_server.ask_meetings.asked[-1]["meetings"] == [B, C]
