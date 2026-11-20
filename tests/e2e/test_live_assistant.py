"""The live assistant on a meeting being recorded (#15): Catch me up, Next steps so far and a question about what
was said, each on a click only, with palaver-lm's test model in place of the notes' model."""

import pytest

from playwright.sync_api import expect  # noqa: E402

from .helpers import goto, open_meeting  # noqa: E402
from .recordings import A, LIVE  # noqa: E402
from .stores import PENDING, update_settings  # noqa: E402

pytestmark = pytest.mark.e2e

WARNING = "Runs Gemma on this Mac during the call (about 10 GB, may slow the call)"


def _panel(page):
    """The live assistant; in the test's window (1280 px) it is in the meeting's Ask tab."""
    page.get_by_role("tab", name="Ask").click()
    return page.get_by_role("region", name="Live assistant")


def test_a_narrow_window_has_one_coach_line_and_the_assistant_in_the_ask_tab(page, app_server):
    app_server.recording.live_coach = {"meeting": LIVE, "talk": {"speaking": "me", "share": 0.72},
                                       "text": "You 72 % of the last 10 min", "nudge": None, "quiet": []}
    goto(page, app_server, f"#/{LIVE}")
    live = page.get_by_role("complementary", name="Live")
    expect(live.get_by_role("button", name="Best answer", exact=True)).to_be_visible()
    expect(live.get_by_role("button", name="Best next question", exact=True)).to_be_visible()
    line = live.locator(".coach-line").bounding_box()
    assert line["height"] < 60, line  # one row
    expect(live.locator(".coach-meter")).to_have_attribute("title", "You 72 % of the last 10 min")
    expect(page.get_by_role("region", name="Live assistant")).to_have_count(0)
    page.get_by_role("tab", name="Ask").click()
    assistant = page.get_by_role("region", name="Live assistant")
    expect(assistant.get_by_role("button", name="Catch me up", exact=True)).to_be_visible()
    expect(assistant.get_by_label("Ask about what was said")).to_be_visible()


def test_the_coach_tab_while_it_records_is_the_coach_page_from_what_is_transcribed(page, app_server):
    goto(page, app_server, f"#/{LIVE}")
    page.get_by_role("tab", name="Coach").click()
    coach = page.locator("#main section.coach")
    expect(coach.locator(".coach-live-note")).to_contain_text("Live: from what is transcribed so far")
    expect(coach.locator(".coach-card", has_text="You talked").locator(".big-number")).to_have_text("33 %")
    expect(coach.locator("button.moment")).to_have_count(0)  # no audio to play yet
    expect(page.get_by_role("complementary", name="Live")).to_be_visible()  # the line stays up


def test_a_wide_window_shows_the_assistant_beside_the_meeting(page, app_server):
    page.set_viewport_size({"width": 1600, "height": 900})
    goto(page, app_server, f"#/{LIVE}")
    live = page.get_by_role("complementary", name="Live")
    expect(live.get_by_role("heading", name="Live")).to_be_visible()
    assistant = live.get_by_role("region", name="Live assistant")
    expect(assistant.get_by_role("button", name="Catch me up", exact=True)).to_be_visible()
    expect(page.get_by_role("tab", name="Ask")).to_have_count(0)  # the assistant is in the panel
    expect(page.get_by_role("tab", name="Coach")).to_be_visible()  # the coach is a tab in either window
    tabs = page.locator("#main .tabs").bounding_box()
    box = live.bounding_box()
    assert box["x"] >= tabs["x"] + tabs["width"], (box, tabs)  # its own column, right of the transcript
    assert box["width"] < 400
    # Narrower: the line and the Ask tab, without a reload.
    page.set_viewport_size({"width": 1280, "height": 900})
    expect(page.get_by_role("tab", name="Ask")).to_be_visible()
    expect(live.get_by_role("heading", name="Live")).to_have_count(0)


def test_catch_me_up_runs_only_on_a_click(page, app_server):
    app_server.assistant.answer({"bullets": ["Timo opened, the budget comes first.", "The others agreed."]})
    goto(page, app_server, f"#/{LIVE}")
    panel = _panel(page)
    expect(panel.locator(".assistant-model")).to_have_text(
        "Gemma, on this Mac · runs only when you ask · not part of the notes")
    panel.get_by_label("Catch me up on the last").select_option("10")
    panel.get_by_role("button", name="Catch me up").click()
    # The local model during the call: said first, run only on a second click.
    expect(panel.locator(".assistant-warning")).to_contain_text(WARNING)
    assert app_server.assistant.asked == []
    app_server.assistant.gate.clear()
    panel.get_by_role("button", name="Run anyway").click()
    expect(panel.get_by_role("button", name="Thinking…")).to_be_disabled()
    expect(panel.get_by_role("button", name="Next steps so far")).to_be_disabled()  # one ask at a time
    app_server.assistant.gate.set()
    card = panel.locator(".assistant-catchup")
    expect(card.locator("h3")).to_have_text("Last 10 minutes · up to 00:22")
    expect(card.locator("li")).to_have_text(["Timo opened, the budget comes first.", "The others agreed."])
    expect(card.locator(".assistant-note")).to_have_text("Gemma 4 12B on this Mac")
    (asked,) = app_server.assistant.asked
    assert asked["meeting"] == LIVE and asked["ask"] == "catchup"
    assert "## Transcript (the last 10 minutes)" in asked["prompt"] and "Ja, das passt für uns." in asked["prompt"]
    # Kept for the call: a reload shows it again, without asking the model.
    page.reload()
    expect(_panel(page).locator(".assistant-catchup li")).to_have_count(2)
    assert len(app_server.assistant.asked) == 1


def test_next_steps_and_a_question(page, app_server):
    goto(page, app_server, f"#/{LIVE}")
    panel = _panel(page)
    app_server.assistant.answer({"next_steps": [{"owner": "Valerie", "task": "Send the numbers tomorrow"}],
                                 "decisions": ["The budget comes first"]})
    panel.get_by_role("button", name="Next steps so far").click()
    panel.get_by_role("button", name="Run anyway").click()
    steps = panel.locator(".assistant-steps")
    expect(steps.locator(".assistant-next-steps li")).to_have_text(["Valerie: Send the numbers tomorrow"])
    expect(steps.locator(".assistant-decisions li")).to_have_text(["The budget comes first"])

    app_server.assistant.answer({"answer": "Das Budget.", "quotes": [
        {"time": "00:03", "speaker": "Others", "text": "wir starten mit dem Budget"}]})
    field = panel.get_by_label("Ask about what was said")
    field.fill("Womit starten wir?")
    field.press("Enter")
    panel.get_by_role("button", name="Run anyway").click()
    qa = panel.locator(".assistant-qa")
    expect(qa.locator(".q")).to_have_text("Womit starten wir?")
    expect(qa.locator(".a")).to_have_text("Das Budget.")
    expect(qa.locator(".assistant-quotes li")).to_have_text("00:03 · Others: “wir starten mit dem Budget”")
    expect(field).to_have_value("")
    asks = app_server.assistant.asked
    assert [a["ask"] for a in asks] == ["next_steps", "ask"]
    assert "## Question\nWomit starten wir?" in asks[1]["prompt"] and "## Transcript (so far)" in asks[1]["prompt"]
    # The next steps are still shown beside the answer.
    expect(steps.locator(".assistant-next-steps li")).to_have_count(1)


def test_a_failing_model_says_why(page, app_server):
    page.guard.allow(r"status of 502")
    app_server.assistant.answer(RuntimeError("Anthropic API: the key was refused"))
    goto(page, app_server, f"#/{LIVE}")
    panel = _panel(page)
    panel.get_by_role("button", name="Catch me up").click()
    panel.get_by_role("button", name="Run anyway").click()
    expect(panel.locator(".assistant-error")).to_have_text("Anthropic API: the key was refused")
    expect(panel.get_by_role("button", name="Catch me up")).to_be_enabled()


def test_without_a_model_the_asks_are_off_and_say_why(page, app_server):
    update_settings({"engines": {"notes": PENDING}})
    goto(page, app_server, f"#/{LIVE}")
    panel = _panel(page)
    expect(panel.locator(".assistant-model")).to_have_text(
        "No model yet: choose one for Notes in Settings → Language model.")
    expect(panel.get_by_role("button", name="Catch me up")).to_be_disabled()
    expect(panel.get_by_label("Ask about what was said")).to_be_disabled()
    assert app_server.assistant.asked == []


def test_no_assistant_on_a_finished_meeting(page, app_server):
    open_meeting(page, app_server, A)
    expect(page.locator("#main .assistant")).to_have_count(0)
