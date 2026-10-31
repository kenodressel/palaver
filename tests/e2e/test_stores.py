"""The stores across meetings: projects (a meeting's chips, the Projects
page), the glossary and people; each change undone, and a failed one tried again."""

import re

import pytest

from playwright.sync_api import expect  # noqa: E402

from .helpers import (  # noqa: E402
    expect_toast, goto, heading, list_item, menu_item, more, open_meeting, run_from_menu, toast, undo_in_toast,
)
from .recordings import A, B  # noqa: E402

pytestmark = pytest.mark.e2e


def _project(served, name: str, *meetings: str) -> str:
    answer = served.api("/api/projects", {"name": name})
    pid = next(p["id"] for p in answer["projects"] if p["name"] == name)
    for mid in meetings:
        served.api(f"/api/meetings/{mid}/projects", {"project": pid})
    return pid


def _chips(page) -> list[str]:
    return page.locator("#main .project-chip > button.link").all_text_contents()


# --- a meeting's projects --------------------------------------------------------

def test_project_chip_add_remove_and_undo(page, app_server):
    open_meeting(page, app_server, A)
    field = page.get_by_label("Add to a project, or name a new one")
    field.fill("Pelican")
    field.press("Enter")
    expect(page.locator("#main .project-chip")).to_have_text(["Pelican×"])
    expect_toast(page, "Added to Pelican")
    expect(list_item(page, A).locator(".item-projects")).to_have_text("Pelican")
    undo_in_toast(page)
    expect(page.locator("#main .project-chip")).to_have_count(0)
    assert app_server.api("/api/projects")["projects"] == []  # the project made by name goes too

    pid = _project(app_server, "Pelican", A)
    page.reload()
    expect(page.locator("#main .project-chip")).to_have_count(1)
    page.get_by_role("button", name="Remove from Pelican").click()
    expect(page.locator("#main .project-chip")).to_have_count(0)
    expect_toast(page, "Removed from Pelican")
    undo_in_toast(page)
    expect(page.locator(f'#main .project-chip[data-project="{pid}"]')).to_be_visible()


def test_a_project_chip_opens_the_project(page, app_server):
    pid = _project(app_server, "Pelican", A)
    open_meeting(page, app_server, A)
    page.locator("#main .project-chip").get_by_role("button", name="Pelican", exact=True).click()
    expect(heading(page)).to_have_text("Projects")
    expect(page.locator(f"#project-{pid}")).to_be_in_viewport()


# --- the Projects page -----------------------------------------------------------

def test_create_a_project(page, app_server):
    goto(page, app_server, "#/projects")
    expect(page.locator("#main")).to_contain_text("No projects yet.")
    page.get_by_label("New project name").fill("Onboarding")
    page.get_by_role("button", name="Add", exact=True).click()
    expect(page.get_by_label("Rename Onboarding")).to_have_value("Onboarding")
    page.get_by_label("Project for Design review", exact=True).select_option(label="Onboarding")
    expect_toast(page, "“Design review” added to Onboarding")
    expect(page.locator("#main section.project li[data-meeting]")).to_have_count(1)


def test_project_delete_and_undo(page, app_server):
    pid = _project(app_server, "Alpha", A)
    _project(app_server, "Beta")
    goto(page, app_server, "#/projects")
    run_from_menu(page, "Actions for Alpha", "Delete")
    expect(page.locator(f"#project-{pid}")).to_have_count(0)
    expect_toast(page, "“Alpha” deleted")
    expect(more(page, "Actions for Beta")).to_be_focused()  # the next project's ⋯, never <body>
    undo_in_toast(page)
    section = page.locator(f"#project-{pid}")
    expect(section).to_be_visible()
    expect(section.locator(f'li[data-meeting="{A}"]')).to_have_count(1)  # with its meetings


def test_project_merge_and_undo(page, app_server):
    alpha = _project(app_server, "Alpha", A)
    beta = _project(app_server, "Beta", B)
    goto(page, app_server, "#/projects")
    run_from_menu(page, "Actions for Alpha", "Merge Into…")
    expect(page.locator(".menu .menu-label")).to_have_text(["Beta"])
    menu_item(page, "Beta").click()
    expect(page.locator(f"#project-{alpha}")).to_have_count(0)
    expect_toast(page, "Merged into Beta")
    expect(page.locator(f"#project-{beta} li[data-meeting]")).to_have_count(2)
    undo_in_toast(page)
    expect(page.locator(f"#project-{alpha} li[data-meeting]")).to_have_count(1)
    expect(page.locator(f"#project-{beta} li[data-meeting]")).to_have_count(1)


def test_project_rename_and_undo(page, app_server):
    _project(app_server, "Alpha", A)
    goto(page, app_server, "#/projects")
    run_from_menu(page, "Actions for Alpha", "Rename")
    field = page.get_by_label("Rename Alpha")
    expect(field).to_be_focused()
    field.fill("Apollo")
    field.press("Enter")
    expect_toast(page, "“Alpha” is now “Apollo”")
    expect(page.get_by_label("Rename Apollo")).to_have_value("Apollo")
    undo_in_toast(page)
    expect(page.get_by_label("Rename Alpha")).to_have_value("Alpha")


def test_sort_with_the_model_and_undo(page, app_server):
    def sorted_by_model(args):  # what the model's run changes: Team standup goes in a new project
        pid = app_server.api("/api/projects", {"name": "Pelicans"})["projects"][-1]["id"]
        app_server.api(f"/api/meetings/{A}/projects", {"project": pid})

    app_server.on_model_run = sorted_by_model
    goto(page, app_server, "#/projects")
    expect(page.locator("#main input[aria-label^='Rename ']")).to_have_count(0)
    page.get_by_role("button", name="Sort meetings into projects").click()
    expect_toast(page, "Meetings sorted into projects")
    assert app_server.model_runs == [["suggest"]]
    expect(page.get_by_label("Rename Pelicans")).to_have_value("Pelicans")
    undo_in_toast(page)
    expect(page.locator("#main input[aria-label^='Rename ']")).to_have_count(0)  # the sorting undone: no project again
    assert app_server.api("/api/projects")["projects"] == []


def test_a_server_error_shows_try_again_and_retrying_works(page, app_server):
    page.guard.allow(r"status of 500")
    pid = _project(app_server, "Alpha", A)
    failing = [True]

    def delete(route):
        if failing[0]:
            route.fulfill(status=500, content_type="application/json", body='{"error": "disk full"}')
        else:
            route.continue_()

    page.route(re.compile(r"/api/projects/[0-9a-f]+/delete$"), delete)
    goto(page, app_server, "#/projects")
    run_from_menu(page, "Actions for Alpha", "Delete")
    expect_toast(page, "“Alpha” was not deleted: disk full")
    expect(page.locator(f"#project-{pid}")).to_be_visible()
    failing[0] = False
    toast(page).get_by_role("button", name="Try again").click()
    expect_toast(page, "“Alpha” deleted")
    expect(page.locator(f"#project-{pid}")).to_have_count(0)
    assert app_server.api("/api/projects")["projects"] == []


# --- the glossary ----------------------------------------------------------------

def _add_term(page, term: str, heard: str):
    page.get_by_label("New term").fill(term)
    page.get_by_label("Misheard spellings").fill(heard)
    page.locator("#main form.new-project").get_by_role("button", name="Add").click()


def test_glossary_add_delete_and_undo(page, app_server):
    goto(page, app_server, "#/glossary")
    _add_term(page, "Attakring", "Atterkring")
    expect(page.get_by_label("Rename Attakring")).to_have_value("Attakring")
    expect(page.locator("#main .inline-notice")).to_have_text("Respelled 1 word in 1 meeting.")
    run_from_menu(page, "Actions for Attakring", "Delete")
    expect(page.locator("#main .term-row")).to_have_count(0)
    expect_toast(page, "“Attakring” deleted from the glossary")
    undo_in_toast(page)
    expect(page.get_by_label("Rename Attakring")).to_have_value("Attakring")
    assert [t["term"] for t in app_server.api("/api/glossary")["terms"]] == ["Attakring"]


def test_glossary_term_menu_and_its_fields(page, app_server):
    goto(page, app_server, "#/glossary")
    _add_term(page, "Attakring", "Atterkring")
    run_from_menu(page, "Actions for Attakring", "Edit Note")
    note = page.get_by_label("Note on Attakring")
    expect(note).to_be_focused()
    note.fill("A district of Vienna")
    note.press("Enter")
    expect_toast(page, "Note on “Attakring” saved")
    page.get_by_role("button", name="Remove Atterkring").click()
    expect_toast(page, "“Atterkring” is no longer respelled as “Attakring”")
    undo_in_toast(page)
    expect(page.get_by_role("button", name="Remove Atterkring")).to_be_visible()


# --- people ----------------------------------------------------------------------

def test_person_rename_and_undo(page, app_server):
    goto(page, app_server, "#/people")
    run_from_menu(page, "Actions for Anna", "Rename")
    field = page.get_by_label("Rename Anna")
    expect(field).to_be_focused()
    field.fill("Anna Berg")
    field.press("Enter")
    expect_toast(page, "Anna is now Anna Berg")
    expect(page.locator('#main .person[data-person="Anna Berg"]')).to_be_visible()
    assert app_server.api(f"/api/meetings/{A}")["transcript"][1]["speaker"] == "Anna Berg"
    undo_in_toast(page)
    expect(page.locator('#main .person[data-person="Anna"]')).to_be_visible()
    assert app_server.api(f"/api/meetings/{A}")["transcript"][1]["speaker"] == "Anna"


def test_renaming_to_someone_known_merges_the_two(page, app_server):
    goto(page, app_server, "#/people")
    field = page.get_by_label("Rename Eli")
    field.fill("Dana")
    field.press("Enter")
    expect_toast(page, "Eli merged into Dana")
    expect(page.locator('#main .person[data-person="Eli"]')).to_have_count(0)
    undo_in_toast(page)
    expect(page.locator('#main .person[data-person="Eli"]')).to_be_visible()


def test_a_persons_menu(page, shared_server):
    goto(page, shared_server, "#/people")
    more(page, "Actions for Dana").click()
    expect(page.locator(".menu .menu-label")).to_have_text(["Rename", "Change Organization", "Play Voice"])
    menu_item(page, "Change Organization").click()
    expect(page.get_by_label("Organization of Dana")).to_be_focused()


def test_a_suggested_spelling_can_be_taken_out_with_a_click(page, app_server):
    """"Team" is no spelling of Timo: a click on it says so for that
    spelling alone; "Not this" then goes for every spelling left."""
    import json

    card = {"kind": "variant", "key": "variant:team:timo", "term": "Timo", "variants": ["Team", "Tmo"],
            "count": 3, "meetings": [A], "examples": [], "unsure": True}
    page.route("**/api/glossary", lambda route: route.fulfill(
        json={"terms": [], "suggestions": [card]}) if route.request.method == "GET" else route.continue_())
    sent = []
    page.route("**/api/glossary/reject", lambda route: (sent.append(json.loads(route.request.post_data)),
                                                        route.continue_()))
    goto(page, app_server, "#/glossary")
    page.get_by_role("button", name="“Team” is not “Timo”").click()
    expect_toast(page, "“Team” is no longer suggested for “Timo”")
    assert sent == [{"keys": ["variant:team:timo"]}]
    page.reload()  # the card again, as stubbed
    page.get_by_role("button", name="Not this").click()
    expect_toast(page, "“Timo” is no longer suggested")
    assert sent[-1] == {"keys": ["variant:team:timo", "variant:tmo:timo"]}
