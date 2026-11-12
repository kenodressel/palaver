"""Links Palaver made, shown with their reason, dotted when unsure, and
corrected in place (issue #48): the event chip, the question when events
overlapped, an unsure voice name; each change undone."""

from __future__ import annotations

import json
import re
from datetime import timedelta

import pytest
from playwright.sync_api import expect

from .conftest import _serve
from .helpers import (about_line, expect_toast, hash_of, heading, lane, list_item, open_meeting, run_from_menu,
                      undo_in_toast)
from .recordings import A, B, C, _at
from .stores import add_project, reject_event, rejected_events


def _event(title: str, start, minutes: int, uid: str, *people: str) -> dict:
    return {"title": title, "start": start.isoformat(), "end": (start + timedelta(minutes=minutes)).isoformat(),
            "attendees": [{"name": p, "email": f"{p.lower()}@x.com"} for p in people], "uid": uid}


def test_a_sure_event_shows_quietly_with_change_about_says_how_it_was_linked(page, shared_server):
    open_meeting(page, shared_server, A)  # "Team standup", the event's title
    chip = page.locator("#main .event-link .link-chip")
    expect(chip).to_have_class("link-chip quiet")  # sure: no dots, no ✓
    expect(chip.locator(".link-kind")).to_have_text("Event")
    expect(chip.locator(".link-title")).to_have_text("Team standup")
    expect(chip.get_by_role("button")).to_have_text(["Change…"])
    # Stored before links kept a reason: said so, folded away at the bottom.
    expect(about_line(page, "event")).to_have_text("Event: Team standup · linked before Palaver kept reasons")


def test_overlapping_events_are_asked_not_guessed(page, app_server):
    start = _at(B)
    question = [_event("Design review", start, 45, "design", "Dana", "Eli"),
                _event("Northwind", start, 45, "north", "Lena")]
    (app_server.root / B / "calendar.json").write_text(json.dumps({"question": question}))
    assert [q["kind"] for q in app_server.api("/api/questions") if q["meeting"] == B] == ["event"]

    open_meeting(page, app_server, B)  # no event yet: the notes' title
    asking = page.locator("#main .event-link.asking")
    expect(asking.locator(".link-chip.unsure")).to_contain_text("Which one?")
    expect(asking.locator(".event-choice")).to_have_text(["Design review", "Northwind"])
    expect(asking.locator(".link-why")).to_have_text("2 events overlapped the recording")

    asking.get_by_role("button", name="Northwind").click()
    expect_toast(page, "Event changed to “Northwind”")
    expect(heading(page)).to_have_text("Northwind")
    expect(page.locator("#main .event-link .link-chip")).to_have_class("link-chip quiet")  # answered: sure now
    expect(about_line(page, "event")).to_have_text("Event: Northwind (you)")
    expect(list_item(page, B).locator(".item-title")).to_have_text("Northwind")
    assert [q for q in app_server.api("/api/questions") if q["meeting"] == B] == []

    undo_in_toast(page)
    expect(page.locator("#main .event-link.asking")).to_be_visible()
    expect(heading(page)).to_have_text("Design review")


def test_none_of_the_overlapping_events(page, app_server):
    start = _at(B)
    question = [_event("Design review", start, 45, "design", "Dana"), _event("Northwind", start, 45, "north", "Lena")]
    (app_server.root / B / "calendar.json").write_text(json.dumps({"question": question}))
    open_meeting(page, app_server, B)
    page.locator("#main .event-link.asking").get_by_role("button", name="None of these").click()
    expect_toast(page, "Event changed to “none”")
    expect(page.locator("#main .event-link")).to_have_count(0)


def test_an_unsure_event_is_confirmed_in_place(page, app_server):
    event = _event("Design review, part two", _at(C), 30, "part-two", "Dana")
    event["link"] = {"source": "calendar", "confidence": 0.6, "reason": "time match, 2 events overlapped"}
    (app_server.root / C / "calendar.json").write_text(json.dumps(event))

    open_meeting(page, app_server, C)
    chip = page.locator("#main .event-link .link-chip")
    expect(chip).to_have_class("link-chip unsure")
    expect(chip.locator(".link-why")).to_have_text("time match, 2 events overlapped")
    expect(chip).to_have_attribute("title", "Event: Design review, part two (time match, 2 events overlapped)"
                                            " · 60% sure. Not sure: confirm or change it.")
    chip.get_by_role("button", name="Confirm the event Design review, part two").click()
    expect_toast(page, "Event confirmed: “Design review, part two”")
    expect(chip).to_have_class("link-chip quiet")  # sure now: nothing left to ask
    expect(chip.locator(".link-why")).to_have_count(0)
    expect(about_line(page, "event")).to_have_text("Event: Design review, part two (you)")

    undo_in_toast(page)
    expect(page.locator("#main .event-link .link-chip")).to_have_class("link-chip unsure")


def test_an_unsure_event_can_be_changed_from_its_chip(page, app_server):
    event = _event("Design review, part two", _at(C), 30, "part-two", "Dana")
    event["link"] = {"source": "calendar", "confidence": 0.6, "reason": "time match, 2 events overlapped"}
    (app_server.root / C / "calendar.json").write_text(json.dumps(event))
    open_meeting(page, app_server, C)
    page.locator("#main .event-link").get_by_role("button", name="Change the event").click()
    expect(page.locator(".event-picker")).to_be_visible()


def test_a_voice_name_palaver_is_unsure_of_is_dotted_and_not_bob_sticks(page, app_server):
    (app_server.root / A / "speakers_auto.json").write_text(json.dumps({"SPEAKER_01": {"name": "Bob", "similarity": 0.7}}))
    open_meeting(page, app_server, A)
    bob = lane(page, "SPEAKER_01")
    expect(bob.locator(".name-input")).to_have_value("Bob")
    expect(bob.locator(".name-input")).to_have_class("name-input unsure-link")
    expect(bob.locator(".named-by")).to_have_text("by voice · 70%")

    run_from_menu(page, "Actions for Bob", "Not Bob")
    expect_toast(page, "Speaker 2 is not Bob")
    expect(page.get_by_label("Name for Speaker 2")).to_have_value("")
    # The notes heard "over to you Bob": no longer offered for this voice.
    expect(bob.locator(".hints .chip", has_text="Bob")).to_have_count(0)
    rejected = app_server.api(f"/api/meetings/{A}")["speakers"]
    assert [s["rejected"] for s in rejected if s["label"] == "SPEAKER_01"] == [["Bob"]]

    undo_in_toast(page)
    expect(page.get_by_label("Name for Bob")).to_have_value("Bob")
    expect(lane(page, "SPEAKER_01").locator(".name-input")).to_have_class("name-input unsure-link")


def test_unsure_project_chips_say_why(page, app_server):
    # The server's store: the same temporary config.
    add_project("Foundry", {A: {"by": "auto", "why": "people like “Sync”", "confidence": 0.72}})
    open_meeting(page, app_server, A)
    chip = page.locator("#main .project-chip", has_text="Foundry")
    expect(chip).to_have_class("project-chip unsure")
    expect(chip).to_have_attribute("title", "Project: Foundry (people like “Sync”) · 72% sure. Not sure: confirm or change it.")


def test_a_rule_from_rejections_shows_in_the_picker_and_can_be_forgotten(page, app_server):
    # The standup's event (calendar.json, by its uid) was said not to be two recordings: a rule. The server's store.
    reject_event("standup-uid", "Team standup", ["adhoc-1", "adhoc-2"])

    open_meeting(page, app_server, A)
    run_from_menu(page, "More actions", "Change Event…")
    rule = page.locator(".event-picker .event-rule")
    expect(rule).to_contain_text("Not linked by time any more: Team standup — rejected 2×")
    rule.get_by_role("button", name="Forget this rule").click()
    expect_toast(page, "“Team standup” is linked by time again")
    expect(page.locator(".event-picker .event-rule")).to_have_count(0)
    assert rejected_events() == {"standup-uid": []}
    undo_in_toast(page)
    assert rejected_events() == {"standup-uid": ["adhoc-1", "adhoc-2"]}


@pytest.fixture
def calendar_server(tmp_path):
    """The app with a calendar (the server's fake one): Design review's day and the days around it. The 1:1 with
    Lena Vogt was planned for 15:00; it was held at 10:00, as Design review's recording (#28)."""
    day = _at(B).replace(hour=0, minute=0, second=0)

    def at(days: int, hour: int, minute: int = 0):
        return day + timedelta(days=days, hours=hour, minutes=minute)

    events = [
        _event("Contoso check-in", at(0, 9, 45), 45, "check-in", "Jana Berger"),  # overlaps the recording
        _event("Contoso standup", at(0, 9), 15, "standup", "Jana Berger"),
        _event("Lunch with Jana", at(0, 12), 60, "lunch", "Jana Berger"),
        _event("1:1 Lena Vogt", at(0, 15), 30, "one-on-one", "Lena Vogt"),
        _event("Northwind review", at(0, 17), 60, "northwind", "Ole Hansen"),
        _event("Retro", at(-1, 16), 60, "retro", "Jana Berger"),
        _event("Planning", at(1, 9), 60, "planning", "Jana Berger"),
        _event("Kickoff", at(-1, 9), 60, "kickoff", "Ole Hansen"),
        _event("Demo", at(1, 14), 60, "demo", "Ole Hansen"),
        _event("Late call", at(1, 20), 30, "late", "Ole Hansen"),
        _event("Too far", at(2, 10), 60, "too-far", "Ole Hansen"),  # two days later: not offered
    ]
    file = tmp_path / "events.json"
    file.write_text(json.dumps(events))
    srv, served = _serve(tmp_path / "Recordings", env={"PALAVER_TEST_CALENDAR": str(file)})
    yield served
    served.close()


def test_an_event_hours_away_can_be_picked_and_found_by_its_title(page, calendar_server):
    open_meeting(page, calendar_server, B)
    run_from_menu(page, "More actions", "Change Event…")
    picker = page.locator(".event-picker")
    options = picker.locator(".event-option .event-title")
    # The one overlapping the recording first, then the others nearest first; not the one two days later.
    expect(options).to_have_text(["Contoso check-in", "Contoso standup", "Lunch with Jana", "1:1 Lena Vogt",
                                  "Northwind review", "Retro", "Planning", "Kickoff", "Demo", "Late call"])
    expect(picker.locator(".event-group")).to_have_text("Other events that day and the days around it, nearest first:")
    expect(picker.locator(".event-option").nth(3).locator(".event-time")).to_contain_text("15:00–15:30")

    picker.get_by_role("searchbox", name="Filter events by title").fill("lena")
    expect(options).to_have_text(["1:1 Lena Vogt"])
    picker.locator(".event-option", has_text="1:1 Lena Vogt").click()
    expect_toast(page, "Event changed to “1:1 Lena Vogt”")
    expect(heading(page)).to_have_text("1:1 Lena Vogt")
    expect(about_line(page, "event")).to_have_text("Event: 1:1 Lena Vogt (you)")
    meeting = calendar_server.api(f"/api/meetings/{B}")
    assert meeting["calendar"]["invited"] == ["Lena Vogt"]
    # Chosen by hand, nothing said no to: no rule about linking by time.
    assert rejected_events() == {"one-on-one": []}


def _review(page, served, mid: str, title: str) -> None:
    """Review, at meeting ``mid``: from its page's strip."""
    open_meeting(page, served, mid)
    page.locator("#main .needs-strip").get_by_role("button", name="Review").click()
    expect(page.locator("#main .review-bar")).to_be_visible()
    expect(page.locator("#main .review h1")).to_have_text(title)


def test_review_changes_a_sure_event_from_its_line_and_from_the_menu(page, calendar_server):
    # #30: a 1:1 held in another meeting's slot was linked to it with confidence; Review shows the event and changes it.
    _review(page, calendar_server, A, "Team standup")
    at = page.locator("#main .review-bar .meta").inner_text()
    line = page.locator("#main .review .event-link")
    expect(line.locator(".link-chip")).to_have_class("link-chip quiet")
    expect(line.locator(".link-title")).to_have_text("Team standup")
    expect(line.get_by_role("button", name="Confirm the event Team standup")).to_have_count(0)  # sure: no ✓

    line.get_by_role("button", name="Change the event").click()
    picker = page.locator(".event-picker")
    picker.get_by_role("searchbox", name="Filter events by title").fill("lena")
    picker.locator(".event-option", has_text="1:1 Lena Vogt").click()
    expect_toast(page, "Event changed to “1:1 Lena Vogt”")
    expect(page.locator("#main .review h1")).to_have_text("1:1 Lena Vogt")  # still in Review, on the same meeting
    expect(line.locator(".link-title")).to_have_text("1:1 Lena Vogt")
    expect(page.locator("#main .review-bar .meta")).to_have_text(at)
    assert hash_of(page) == "#/review"

    run_from_menu(page, "More actions", "Change Event…")
    picker.get_by_role("searchbox", name="Filter events by title").fill("lunch")
    picker.locator(".event-option", has_text="Lunch with Jana").click()
    expect_toast(page, "Event changed to “Lunch with Jana”")
    expect(page.locator("#main .review h1")).to_have_text("Lunch with Jana")
    expect(line.locator(".link-title")).to_have_text("Lunch with Jana")
    assert calendar_server.api(f"/api/meetings/{A}")["calendar"]["title"] == "Lunch with Jana"

    undo_in_toast(page)
    expect(page.locator("#main .review h1")).to_have_text("1:1 Lena Vogt")
    expect(page.locator("#main .review-bar")).to_be_visible()


def test_a_meeting_without_an_event_offers_to_pick_one_while_the_calendar_is_on(page, calendar_server):
    open_meeting(page, calendar_server, B)  # no event: the notes' title
    chip = page.locator("#main .event-link .link-chip")
    expect(chip.locator(".link-kind")).to_have_text("No event")
    chip.get_by_role("button", name="Pick the event").click()
    expect(page.locator(".event-picker .event-option").first).to_be_visible()


def test_picking_an_event_shows_at_once_until_the_change_lands(page, calendar_server):
    # #31: the click spins its button and the picker waits, before the server answers.
    open_meeting(page, calendar_server, B)
    run_from_menu(page, "More actions", "Change Event…")
    picker = page.locator(".event-picker")
    held = []
    page.route(f"**/api/meetings/{B}/event", lambda route: held.append(route))
    option = picker.locator(".event-option", has_text="Contoso check-in")
    option.click()
    expect(option).to_have_class(re.compile(r"\bspinning\b"))
    expect(picker).to_have_attribute("aria-busy", "true")
    expect(picker.get_by_role("button", name="None of these (an ad-hoc call)")).to_be_disabled()
    for _ in range(100):
        if held:
            break
        page.wait_for_timeout(20)
    assert len(held) == 1
    held[0].continue_()
    expect_toast(page, "Event changed to “Contoso check-in”")
    expect(picker).to_have_count(0)
