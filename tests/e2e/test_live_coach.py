"""The live coach on a meeting being recorded (#41, #42): who talks, the
talk share and the nudge as a quiet line, and "Best next question" with a
fake language model."""

import re

import pytest

from playwright.sync_api import expect  # noqa: E402

from palaver.notes import NotesError  # noqa: E402

from .helpers import goto, open_meeting  # noqa: E402
from .recordings import A, LIVE  # noqa: E402

pytestmark = pytest.mark.e2e

COACH = {"meeting": LIVE, "talk": {"speaking": "me", "share": 0.72},
         "text": "You 72 % of the last 10 min · talking for 4:05",
         "nudge": {"kind": "monologue", "text": "4-min monologue", "at": 245.0}, "quiet": []}


def test_the_coach_line_follows_the_daemon(page, app_server):
    app_server.recording.live_coach = COACH
    goto(page, app_server, f"#/{LIVE}")
    line = page.locator("#main .coach-line")
    expect(line.locator(".coach-now")).to_have_text("You're talking")
    expect(line.locator(".coach-talk")).to_have_text("You 72 % of the last 10 min · talking for 4:05")
    expect(line.locator(".coach-nudge")).to_have_text("4-min monologue")
    app_server.recording.live_coach = {**COACH, "talk": {"speaking": "others"}, "text": "You 70 % of the last 10 min",
                                       "nudge": None}
    expect(line.locator(".coach-now")).to_have_text("Others are talking")  # within a second, no reload
    expect(line.locator(".coach-nudge")).to_have_count(0)


def test_no_coach_line_on_a_finished_meeting(page, app_server):
    app_server.recording.live_coach = COACH
    open_meeting(page, app_server, A)
    expect(page.locator("#main .coach-live")).to_have_count(0)


def test_best_next_question(page, app_server):
    app_server.model.answer = {"engine": "Fake model", "questions": [
        {"question": "Who sends the numbers tomorrow?", "why": "“Die Zahlen kommen morgen” came without a name."},
        {"question": "What is the budget for Q1?", "why": "The budget came up at the start and was dropped."}]}
    app_server.model.gate.clear()
    goto(page, app_server, f"#/{LIVE}")
    button = page.get_by_role("button", name="Best next question (Gemma, on this Mac)")
    button.click()
    answer = page.locator("#main .coach-answer")
    # The local model during the call: said first, run only on a second click.
    expect(answer.locator(".coach-warning")).to_contain_text(
        "Runs Gemma on this Mac during the call (about 10 GB, may slow the call)")
    assert app_server.model.asked == []
    answer.get_by_role("button", name="Run anyway").click()
    expect(page.get_by_role("button", name="Thinking…")).to_be_disabled()
    app_server.model.gate.set()
    expect(answer.locator(".next-questions .q")).to_have_text(
        ["Who sends the numbers tomorrow?", "What is the budget for Q1?"])
    expect(answer.locator(".why").first).to_contain_text("came without a name")
    # palaver-lm names the engine the user chose (the test's model answers in its place).
    expect(answer.locator(".next-questions-note")).to_contain_text(
        "Gemma 4 12B on this Mac · from what was said and your prep only")
    meeting, prompt = app_server.model.asked[0]
    assert meeting == LIVE
    assert "Ja, das passt für uns." in prompt and "## Transcript (the last minutes)" in prompt
    answer.get_by_role("button", name="Hide").click()
    expect(answer.locator(".next-questions")).to_have_count(0)
    expect(page.get_by_role("button", name="Best next question (Gemma, on this Mac)")).to_be_enabled()


def test_not_enough_memory_for_the_local_model_is_said_plainly(page, app_server):
    page.guard.allow(r"status of 400")
    app_server.free_gb = 4.0
    goto(page, app_server, f"#/{LIVE}")
    page.get_by_role("button", name="Best next question (Gemma, on this Mac)").click()
    page.get_by_role("button", name="Run anyway").click()
    expect(page.locator("#main .coach-error")).to_have_text(
        "Not enough free memory for the local model during the call; choose a cloud model in "
        "Settings → Language model, or ask after the call")
    assert app_server.model.asked == []


def test_a_failing_model_says_why(page, app_server):
    page.guard.allow(r"status of 502")
    app_server.model.answer = NotesError("Anthropic API: the key was refused")
    goto(page, app_server, f"#/{LIVE}")
    page.get_by_role("button", name="Best next question (Gemma, on this Mac)").click()
    page.get_by_role("button", name="Run anyway").click()
    expect(page.locator("#main .coach-error")).to_have_text("Anthropic API: the key was refused")


def test_without_a_model_the_button_is_off_and_says_why(page, app_server):
    from palaver import providers, settings

    settings.update({"engines": {"coach": providers.PENDING}})
    goto(page, app_server, f"#/{LIVE}")
    expect(page.get_by_role("button", name="Best next question")).to_be_disabled()
    expect(page.locator("#main .coach-reason")).to_have_text(
        "No model yet: choose one for Best next question in Settings → Language model.")
    assert app_server.model.asked == []


def test_how_you_talk_over_time(page, shared_server):
    goto(page, shared_server, "#/coach")
    trends = page.get_by_role("region", name="Over time")
    expect(trends.locator(".trend-table").first.locator("th")).to_have_text(
        ["Week of", "Meetings", "You talked", "Words/min", "Fillers/min"])
    expect(trends.locator(".trend-table").first.locator("tbody tr").first).to_be_visible()
    expect(trends.locator(".trend-share").first).to_have_attribute("title", re.compile(r"You talked \d+ % in the week of"))
