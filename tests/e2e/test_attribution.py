"""Links Palaver made, shown with their reason, dotted when unsure, and
corrected in place (issue #48): the event chip, the question when events
overlapped, an unsure voice name; each change undone."""

from __future__ import annotations

import json
from datetime import timedelta

from playwright.sync_api import expect

from .helpers import about_line, expect_toast, heading, lane, list_item, open_meeting, run_from_menu, undo_in_toast
from .recordings import A, B, C, _at


def _event(title: str, start, minutes: int, uid: str, *people: str) -> dict:
    return {"title": title, "start": start.isoformat(), "end": (start + timedelta(minutes=minutes)).isoformat(),
            "attendees": [{"name": p, "email": f"{p.lower()}@x.com"} for p in people], "uid": uid}


def test_a_sure_event_the_title_names_is_no_chip_about_says_how_it_was_linked(page, shared_server):
    open_meeting(page, shared_server, A)  # "Team standup", the event's title
    expect(page.locator("#main .event-link")).to_have_count(0)
    expect(page.locator("#main .title-hint")).to_have_count(0)
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
    expect(page.locator("#main .event-link")).to_have_count(0)  # answered: the title names it
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
    expect(page.locator("#main .event-link")).to_have_count(0)  # sure now: nothing left to ask
    expect(about_line(page, "event")).to_have_text("Event: Design review, part two (you)")

    undo_in_toast(page)
    expect(page.locator("#main .event-link .link-chip")).to_have_class("link-chip unsure")


def test_an_unsure_event_can_be_changed_from_its_chip(page, app_server):
    event = _event("Design review, part two", _at(C), 30, "part-two", "Dana")
    event["link"] = {"source": "calendar", "confidence": 0.6, "reason": "time match, 2 events overlapped"}
    (app_server.root / C / "calendar.json").write_text(json.dumps(event))
    open_meeting(page, app_server, C)
    page.locator("#main .event-link").get_by_role("button", name="Change the event").click()
    expect(page.locator("#main .event-picker")).to_be_visible()


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
    from palaver import projects

    store = projects.ProjectStore()  # the server's store: the same temporary config
    pid = store.create("Foundry")
    store.assign(A, pid, by="auto", why="people like “Sync”", confidence=0.72)
    store.save()
    open_meeting(page, app_server, A)
    chip = page.locator("#main .project-chip", has_text="Foundry")
    expect(chip).to_have_class("project-chip unsure")
    expect(chip).to_have_attribute("title", "Project: Foundry (people like “Sync”) · 72% sure. Not sure: confirm or change it.")


def test_a_rule_from_rejections_shows_in_the_picker_and_can_be_forgotten(page, app_server):
    from palaver import attribution
    from palaver import calendar_events as cal

    standup = cal.load(cal.RecordingPaths(app_server.root / A))
    evidence = attribution.Evidence()  # the server's store: the same temporary config
    for meeting in ("adhoc-1", "adhoc-2"):
        evidence.reject_event(standup, meeting)
    evidence.save()

    open_meeting(page, app_server, A)
    run_from_menu(page, "More actions", "Change Event…")
    rule = page.locator("#main .event-picker .event-rule")
    expect(rule).to_contain_text("Not linked by time any more: Team standup — rejected 2×")
    rule.get_by_role("button", name="Forget this rule").click()
    expect_toast(page, "“Team standup” is linked by time again")
    expect(page.locator("#main .event-picker .event-rule")).to_have_count(0)
    assert attribution.Evidence().rules() == []
    undo_in_toast(page)
    assert [r["title"] for r in attribution.Evidence().rules()] == ["Team standup"]
