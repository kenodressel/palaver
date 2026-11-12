"""The meeting header after the cleanup of 2026-10-30: one person, one look
(tokens in the header, names in their colour in the text), the projects
beside the people, and what the recording itself says folded away in
"About this recording"."""

from __future__ import annotations

import json
from datetime import timedelta

from playwright.sync_api import expect

from .helpers import about, about_line, goto, lane, open_meeting
from .recordings import A, LIVE, _at
from .stores import add_project


def _invite(served, *people: tuple[str, str], title: str = "Team standup") -> None:
    """A's event with these invitees (name, email); the user is invited from their own organization."""
    start = _at(A)
    attendees = [{"name": "Timo", "email": "timo@contoso.com", "is_self": True, "organizer": True}]
    attendees += [{"name": n, "email": e} for n, e in people]
    (served.root / A / "calendar.json").write_text(json.dumps({
        "title": title, "start": start.isoformat(), "end": (start + timedelta(minutes=15)).isoformat(),
        "attendees": attendees, "uid": "standup-uid"}))


def _started_by_teams(served) -> None:
    meta_path = served.root / A / "meta.json"
    meta = json.loads(meta_path.read_text())
    start = _at(A)
    meta.update(trigger="teams", stop_reason="call_ended", end_time=(start + timedelta(minutes=1)).isoformat())
    meta_path.write_text(json.dumps(meta))


def _color(locator) -> str:
    return locator.evaluate("el => el.style.getPropertyValue('--c')")


def test_the_header_lists_the_invitees_as_people_who_spoke_first_in_their_lane_colour(page, app_server):
    _invite(app_server, ("Jonas Weber", "jonas@contoso.com"), ("Anna", "anna@contoso.com"),
            ("Mara Fischer", "mara@fabrikam.com"), ("Carla Rossi", "carla@contoso.com"))
    open_meeting(page, app_server, A)
    people = page.locator("#main .head .invitees .person-token")
    expect(people).to_have_text(["Anna", "Carla Rossi", "Jonas Weber", "Mara Fischer"])
    # Who spoke has the colour of their lane (Carla by her first name); who did not, a grey outline.
    expect(people.nth(0)).not_to_have_class("person-token silent")
    assert _color(people.nth(0)) == _color(lane(page, "SPEAKER_00"))
    assert _color(people.nth(1)) == _color(lane(page, "SPEAKER_02"))
    expect(people.nth(2)).to_have_class("person-token silent")
    # The user's own organization goes without saying; another is in the tooltip only.
    expect(page.locator("#main .head")).not_to_contain_text("Contoso", ignore_case=True)
    expect(people.nth(3)).to_have_attribute("title", "Mara Fischer · Fabrikam · invited, no named voice")
    expect(people.nth(2)).to_have_attribute("title", "Jonas Weber · invited, no named voice")


def test_a_person_has_one_colour_in_the_lanes_the_list_and_the_text(page, app_server):
    open_meeting(page, app_server, A)
    anna = _color(lane(page, "SPEAKER_00"))
    assert anna.startswith("var(--v")
    # The summary names her in her colour, as running text: no chip.
    mark = page.locator("#main .notes .summary .name-mark")
    expect(mark).to_have_text(["Anna"])
    assert _color(mark) == anna
    # The next step's owner is a person token.
    owner = page.locator("#main .notes .todo .owner .person-token")
    expect(owner).to_have_text(["Carla"])
    assert _color(owner) == _color(lane(page, "SPEAKER_02"))
    # The meeting list shows her the same way.
    listed = page.locator(f'#list .item[data-id="{A}"] .item-people .person-token', has_text="Anna")
    assert _color(listed) == anna
    # In the transcript, her name is marked where it is said, beside the glossary's and unsure marks.
    page.get_by_role("tab", name="Transcript").click()
    said = page.locator('#main .turn[data-start="15"] .said')
    expect(said.locator(".name-mark")).to_have_text(["Anna"])
    expect(page.locator('#main .turn[data-start="4"] .said .unsure')).to_have_text("Atterkring")


def test_about_this_recording_holds_what_the_recording_says(page, app_server):
    _started_by_teams(app_server)
    reads = {"reads": [{"time": "2026-10-27T12:00:00+01:00", "client": {"name": "claude-code"}, "tool": "get_meeting",
                        "meetings": [A], "args": {"id": A, "part": "notes"}}]}
    page.route("**/api/mcp?meeting=*", lambda r: r.fulfill(json=reads))
    open_meeting(page, app_server, A)
    head = page.locator("#main .head")
    expect(head).not_to_contain_text("Teams call detected")
    expect(head.locator(".mcp-read")).to_have_count(0)

    section = about(page)
    expect(section).not_to_have_attribute("open", "")  # folded away
    expect(about_line(page, "recorded")).to_be_hidden()
    section.locator("summary").click()
    expect(about_line(page, "recorded")).to_contain_text("Teams call detected 09:00")
    expect(about_line(page, "event")).to_have_text("Event: Team standup · linked before Palaver kept reasons")
    read = section.locator(".mcp-read")
    expect(read).to_contain_text("Read by Claude Code")
    expect(read.get_by_role("button", name="Access log")).to_be_visible()
    # It stays open while the page is built again (a tab switch).
    page.get_by_role("tab", name="Transcript").click()
    expect(about_line(page, "recorded")).to_be_visible()


def test_a_meeting_with_nothing_to_tell_has_no_about(page, app_server):
    page.route("**/api/mcp?meeting=*", lambda r: r.fulfill(json={"reads": []}))
    (app_server.root / A / "calendar.json").unlink()
    open_meeting_titled(page, app_server, "Daily standup")  # no event (the notes' title), no trigger stored, nothing read
    expect(about(page)).to_be_hidden()


def test_while_it_records_the_recording_line_stays_in_the_header(page, app_server):
    app_server.recording.recording = lambda: {"meeting": LIVE, "text": "Recording · Teams call since 11:00",
                                              "warnings": [], "hints": []}
    goto(page, app_server, f"#/{LIVE}")
    expect(page.locator("#main .head .recorded")).to_have_text("Recording · Teams call since 11:00")


def test_a_title_other_than_the_event_shows_the_event_quietly(page, app_server):
    _invite(app_server, title="Foundry Pitch")
    (app_server.root / A / "title.json").write_text(json.dumps({"title": "Factory pitch with Anna"}))
    open_meeting_titled(page, app_server, "Factory pitch with Anna")
    expect(page.locator("#main .event-link .link-title")).to_have_text("Foundry Pitch")


def open_meeting_titled(page, served, title: str) -> None:
    goto(page, served, f"#/{A}")
    expect(page.locator("#main h1")).to_have_text(title)


def test_with_a_confirmed_project_the_suggestions_go_into_the_picker(page, app_server):
    add_project("Foundry", {A: {}})
    others = {name: add_project(name) for name in ("Internal", "Northwind Terminal")}
    suggestions = [{"id": others["Internal"], "name": "Internal", "score": 0.5, "why": "same people"},
                   {"id": others["Northwind Terminal"], "name": "Northwind Terminal", "score": 0.4, "why": "title"}]

    def with_suggestions(route):
        answer = route.fetch()
        m = answer.json()
        m["project_suggestions"] = suggestions
        route.fulfill(response=answer, json=m)

    page.route(f"**/api/meetings/{A}", with_suggestions)
    open_meeting(page, app_server, A)
    row = page.locator("#main .project-row")
    expect(row.locator(".project-chip")).to_have_count(1)
    expect(row.locator(".chip")).to_have_count(0)  # no dashed suggestions beside a confirmed project
    options = row.locator("datalist option")
    assert options.evaluate_all("os => os.map((o) => [o.value, o.hasAttribute('label')])")[:2] == [["Internal", True],
                                                                                   ["Northwind Terminal", True]]
