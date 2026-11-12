"""The meeting's ⋯ menu, the list's right-click menu and their keys: trash,
join, change the event, review again; each undone."""

import re

import pytest

from playwright.sync_api import expect  # noqa: E402

from .helpers import (  # noqa: E402
    cmd, expect_toast, goto, hash_of, heading, list_ids, list_item, menu_item, more, open_meeting,
    run_from_menu, toast, undo_in_toast, unfocus,
)
from .recordings import A, B, C, LIVE  # noqa: E402
from .stores import ERROR, MODELS, RecordingPaths, mark_failed  # noqa: E402

pytestmark = pytest.mark.e2e

ALL = [LIVE, C, B, A]


def test_the_menu_has_the_meetings_actions_in_order(page, shared_server):
    open_meeting(page, shared_server, A)
    more(page).click()
    menu = page.locator(".menu")
    expect(menu.get_by_role("menuitem")).to_have_count(12)
    labels = menu.locator(".menu-label").all_text_contents()
    assert labels == ["Rename…", "Change Event…", "Join with Previous", "Join with Next", "Split At…", "Review Again",
                      "Export…", "Keep on This Mac", "Speakers Can't Be Separated",
                      "Report a Problem with This Meeting…", "Delete Audio…", "Move to Trash"]
    expect(menu_item(page, "Join with Previous")).to_be_disabled()  # no recording right before it
    expect(menu_item(page, "Review Again")).to_be_disabled()  # not reviewed yet
    expect(menu_item(page, "Move to Trash")).to_have_class("danger")
    expect(menu_item(page, "Move to Trash").locator("kbd")).to_have_text("⌘⌫")
    page.keyboard.press("Escape")
    expect(menu).to_have_count(0)
    expect(more(page)).to_be_focused()


def test_trash_from_the_menu_and_undo(page, app_server):
    open_meeting(page, app_server, A)
    run_from_menu(page, "More actions", "Move to Trash")
    expect(list_item(page, A)).to_have_count(0)
    expect_toast(page, "“Team standup” moved to Trash")
    expect(heading(page)).to_have_text("Design review")  # the one above it opens: A was the last
    assert hash_of(page) == f"#/{B}"
    assert A not in app_server.meeting_ids()
    undo_in_toast(page)
    expect(heading(page)).to_have_text("Team standup")
    assert list_ids(page) == ALL
    assert hash_of(page) == f"#/{A}"
    assert app_server.meeting_ids() == ALL


def test_delete_audio_asks_and_keeps_the_transcript(page, app_server):
    """#9: the audio goes after a yes; the meeting, its transcript and notes stay."""
    open_meeting(page, app_server, A)
    run_from_menu(page, "More actions", "Delete Audio…")
    dialog = page.get_by_role("dialog", name="Delete this meeting's audio?")
    dialog.get_by_role("button", name="Cancel").click()
    assert (app_server.root / A / "system.wav").exists()
    run_from_menu(page, "More actions", "Delete Audio…")
    page.get_by_role("dialog").get_by_role("button", name="Delete Audio").click()
    expect_toast(page, re.compile(r"^Audio deleted: .+ free again\.$"))
    assert not (app_server.root / A / "system.wav").exists()
    assert (app_server.root / A / "transcript.json").exists()
    expect(page.locator("#player")).to_be_hidden()
    expect(page.locator("#main .about-deleted")).to_have_text(re.compile(r"^Audio deleted on "))
    more(page).click()
    expect(menu_item(page, "Delete Audio…")).to_have_count(0)


def test_trash_with_cmd_backspace_and_undo_with_cmd_z(page, app_server):
    open_meeting(page, app_server, B)
    unfocus(page)
    cmd(page, "Backspace")
    expect(list_item(page, B)).to_have_count(0)
    expect(heading(page)).to_have_text("Team standup")  # the one below it
    assert B not in app_server.meeting_ids()
    unfocus(page)
    cmd(page, "z")
    expect(toast(page).locator(".toast-text")).to_have_text("Undone")
    expect(heading(page)).to_have_text("Design review")
    assert list_ids(page) == ALL


def test_trash_from_the_lists_right_click_and_undo(page, app_server):
    open_meeting(page, app_server, C)
    list_item(page, A).click(button="right")
    menu_item(page, "Move to Trash").click()
    expect(list_item(page, A)).to_have_count(0)
    expect_toast(page, "“Team standup” moved to Trash")
    expect(heading(page)).to_have_text("Design review, part two")  # the meeting open stays open
    undo_in_toast(page)
    assert list_ids(page) == ALL
    expect(heading(page)).to_have_text("Team standup")  # the meeting back opens


def test_cmd_backspace_in_a_name_field_does_not_trash(page, app_server):
    open_meeting(page, app_server, A)
    field = page.get_by_label("Name for Speaker 2")
    field.fill("Bo")
    cmd(page, "Backspace")
    expect(field).to_have_value("")  # the key emptied the field...
    page.wait_for_timeout(500)
    assert A in app_server.meeting_ids()  # ...and trashed nothing
    expect(list_item(page, A)).to_have_count(1)
    expect(toast(page)).to_have_count(0)


def test_a_held_cmd_backspace_trashes_one_meeting(page, app_server):
    open_meeting(page, app_server, C)
    unfocus(page)
    page.keyboard.down("Meta")
    page.keyboard.down("Backspace")
    page.keyboard.down("Backspace")  # a repeat
    page.keyboard.up("Backspace")
    page.keyboard.up("Meta")
    expect(list_item(page, C)).to_have_count(0)
    page.wait_for_timeout(600)
    assert app_server.meeting_ids() == [LIVE, B, A]


def test_join_with_previous_and_undo(page, app_server):
    open_meeting(page, app_server, C)
    run_from_menu(page, "More actions", "Join with Previous")
    expect_toast(page, "Joined with “Design review”")
    expect(list_item(page, C)).to_have_count(0)  # the longer one keeps the meeting
    expect(heading(page)).to_have_text("Design review")
    assert app_server.meeting_ids() == [LIVE, B, A]
    page.get_by_role("tab", name="Transcript").click()
    expect(page.locator("#main .transcript")).to_contain_text("we use the darker palette")
    expect(page.locator("#duration")).to_have_text("1:15")
    undo_in_toast(page)
    expect(list_item(page, C)).to_have_count(1)
    assert app_server.meeting_ids() == ALL
    expect(page.locator("#duration")).to_have_text("0:30")  # back on the meeting it was
    expect(heading(page)).to_have_text("Design review, part two")


def test_join_with_cmd_j(page, app_server):
    open_meeting(page, app_server, C)
    unfocus(page)
    cmd(page, "j")
    expect_toast(page, "Joined with “Design review”")
    assert app_server.meeting_ids() == [LIVE, B, A]


def test_change_event_and_undo(page, app_server):
    open_meeting(page, app_server, A)
    run_from_menu(page, "More actions", "Change Event…")
    picker = page.locator(".event-picker")
    expect(picker.locator(".event-option")).to_have_count(1)
    expect(picker.locator(".event-option.current")).to_contain_text("Team standup")
    picker.get_by_role("button", name="None of these (an ad-hoc call)").click()
    expect(picker).to_have_count(0)
    expect(heading(page)).to_have_text("Daily standup")  # the notes' title now
    expect_toast(page, "Event changed to “none”")
    expect(list_item(page, A).locator(".item-title")).to_have_text("Daily standup")
    undo_in_toast(page)
    expect(heading(page)).to_have_text("Team standup")
    expect(list_item(page, A).locator(".item-title")).to_have_text("Team standup")


def test_cancel_the_event_picker(page, shared_server):
    open_meeting(page, shared_server, A)
    run_from_menu(page, "More actions", "Change Event…")
    box = page.get_by_role("dialog", name="Which calendar event was this recording?")
    expect(box.locator(".event-picker")).to_be_visible()  # a pop-up: on the page it went unnoticed
    expect(box).not_to_contain_text("null")
    box.get_by_role("button", name="Cancel").click()
    expect(box).to_have_count(0)
    expect(heading(page)).to_have_text("Team standup")


def test_a_live_meeting_has_move_to_trash_disabled(page, app_server):
    goto(page, app_server, f"#/{LIVE}")
    expect(page.locator("#main .live-badge")).to_be_visible()
    more(page).click()
    expect(menu_item(page, "Move to Trash")).to_be_disabled()
    for name in ["Change Event…", "Join with Previous", "Join with Next", "Split At…"]:
        expect(menu_item(page, name)).to_be_disabled()
    expect(menu_item(page, "Rename…")).to_be_enabled()  # a title is harmless while it records
    page.keyboard.press("Escape")
    list_item(page, LIVE).click(button="right")
    expect(menu_item(page, "Move to Trash")).to_be_disabled()
    page.keyboard.press("Escape")
    unfocus(page)
    cmd(page, "Backspace")
    page.wait_for_timeout(300)
    assert LIVE in app_server.meeting_ids()
    assert page.evaluate("window.palaver.command('trash')") is False  # the native menu's way in


def test_review_again_and_undo(page, app_server):
    app_server.api(f"/api/meetings/{B}/reviewed", {"done": True})
    open_meeting(page, app_server, B)
    expect(page.locator("#main .pill.reviewed")).to_have_text("✓ Reviewed")
    run_from_menu(page, "More actions", "Review Again")
    expect(page.locator("#main .review-bar")).to_be_visible()
    expect(page.locator("#main .review h1")).to_have_text("Design review")
    expect_toast(page, "“Design review” is back in the review")
    count = page.locator('.views [data-view="today"] .nav-count')  # the meetings that need you
    expect(count).to_have_text("3")
    undo_in_toast(page)
    expect(heading(page)).to_have_text("Design review")
    expect(page.locator("#main .pill.reviewed")).to_have_text("✓ Reviewed")
    expect(count).to_have_text("2")


def test_split_at_opens_the_cut_bar(page, shared_server):
    open_meeting(page, shared_server, B)
    run_from_menu(page, "More actions", "Split At…")
    bar = page.locator("#main .cut-bar")
    expect(bar).to_contain_text("This line (0:05) and everything after it")  # the second line
    expect(page.get_by_role("tab", name="Transcript")).to_have_attribute("aria-selected", "true")
    expect(bar.get_by_role("button", name="becomes its own meeting")).to_be_focused()
    bar.get_by_role("button", name="Cancel").focus()
    page.keyboard.press("Enter")  # by keyboard: the focus goes back to the line
    expect(bar).to_have_count(0)
    expect(page.locator('#main .turn[data-start="5"]')).to_be_focused()
    assert re.fullmatch(r"#/\S+", hash_of(page))


def test_trash_from_search_results_and_undo(page, app_server):
    goto(page, app_server, f"#/{A}")
    page.locator("#search").fill("colours")
    expect(page.locator("#list .item[data-id]")).to_have_count(2)
    shown = list_ids(page)
    list_item(page, shown[0]).click()
    expect(heading(page)).to_have_text(re.compile("Design review"))
    unfocus(page)
    cmd(page, "Backspace")
    expect(page.locator("#list .item[data-id]")).to_have_count(1)  # the results, less the one trashed
    expect(heading(page)).to_have_text(re.compile("Design review"))  # the other result opens
    assert list_ids(page) == [shown[1]]
    undo_in_toast(page)
    expect(page.locator("#list .item[data-id]")).to_have_count(2)
    assert sorted(list_ids(page)) == sorted(shown)
    expect(page.locator("#search")).to_have_value("colours")


def test_back_after_a_trash_and_its_undo(page, app_server):
    open_meeting(page, app_server, A)
    list_item(page, B).click()
    expect(heading(page)).to_have_text("Design review")
    unfocus(page)
    cmd(page, "Backspace")
    expect(heading(page)).to_have_text("Team standup")  # in the trashed meeting's place
    cmd(page, "z")
    expect(heading(page)).to_have_text("Design review")
    cmd(page, "BracketLeft")
    expect(heading(page)).to_have_text("Team standup")
    cmd(page, "BracketRight")
    expect(heading(page)).to_have_text("Design review")


def _not_transcribed(served, mid, reason, **kw):
    paths = RecordingPaths(served.root / mid)
    paths.transcript_json.unlink()
    paths.notes.unlink(missing_ok=True)
    mark_failed(paths, reason, **kw)
    return paths


def test_a_meeting_whose_transcription_failed_can_be_transcribed_again(page, app_server):
    paths = _not_transcribed(app_server, A, ERROR, error="Unable to reach MTLCompilerService")
    goto(page, app_server, f"#/{A}")
    notice = page.locator("#main .notes-empty")
    expect(notice).to_contain_text("This meeting was not transcribed (Unable to reach MTLCompilerService)")
    expect(list_item(page, A)).to_contain_text("Not transcribed")
    more(page).click()
    expect(page.locator(".menu .menu-label").first).to_have_text("Transcribe Again")
    page.keyboard.press("Escape")
    notice.get_by_role("button", name="Transcribe Again").click()
    expect_toast(page, "Transcribing “Team standup”. Notes follow once it is done.")
    expect(page.locator("#main .notes-empty")).to_contain_text("The recording is being transcribed")
    expect(list_item(page, A)).to_contain_text("Transcribing")
    assert app_server.recording.transcribing == [paths.folder]


def test_a_meeting_waiting_for_its_models_says_so_and_links_to_settings(page, app_server):
    _not_transcribed(app_server, A, MODELS, missing=["Speech models"])
    goto(page, app_server, f"#/{A}")
    notice = page.locator("#main .notes-empty")
    expect(notice).to_contain_text("waiting for Speech models")
    expect(list_item(page, A)).to_contain_text("Waiting for models")
    notice.get_by_role("link", name="Open Settings").click()
    expect(page).to_have_url(re.compile(r"#/settings$"))


def test_silence_before_the_first_word_is_offered_for_removal_and_removed(page, app_server):
    # A one-on-one joined three minutes early: nobody speaks until 3:20.
    from datetime import datetime

    from .recordings import ME, Line, make_meeting

    mid = "2026-10-26T14-00-00"
    make_meeting(app_server.root / mid, start=datetime.fromisoformat("2026-10-26T14:00:00+01:00"), duration=260.0,
                 title="One-on-one", lines=[Line("SPEAKER_00", 200.0, 230.0, "Sorry, I'm late."),
                                            Line(ME, 230.0, 255.0, "No problem.")])
    goto(page, app_server, f"#/{mid}")
    expect(page.locator("#main h1")).to_have_text("One-on-one")
    offer = page.locator("#main .silence-suggest")
    expect(offer).to_contain_text("3 min of silence before anyone speaks.")
    offer.get_by_role("button", name="Remove it").click()
    expect(offer).to_have_count(0)
    assert app_server.api(f"/api/meetings/{mid}")["duration"] == 62.0  # from 3:18, two seconds before the first word


# --- the ⋯ menu in Review (#30) --------------------------------------------------------------

def _in_review(page, at: str, title: str) -> None:
    expect(page.locator("#main .review-bar .meta")).to_have_text(at)
    expect(page.locator("#main .review h1")).to_have_text(title)


def test_review_has_the_meetings_menu_beside_skip(page, shared_server):
    goto(page, shared_server, "#/review")
    _in_review(page, "Review · 1 of 3", "Design review, part two")
    bar = page.locator("#main .review-bar")
    expect(bar.locator("button")).to_have_text(["", "Skip", "Done, next →"])  # ⋯ first, then Skip
    more(page).click()
    labels = page.locator(".menu .menu-label").all_text_contents()
    assert labels[:5] == ["Rename…", "Change Event…", "Join with Previous", "Join with Next", "Split At…"]
    assert labels[-1] == "Move to Trash"
    page.keyboard.press("Escape")


def test_rename_in_review_stays_on_the_meeting(page, app_server):
    goto(page, app_server, "#/review")
    _in_review(page, "Review · 1 of 3", "Design review, part two")
    run_from_menu(page, "More actions", "Rename…")
    field = page.locator("#main h1").get_by_role("textbox", name="Meeting title")
    field.fill("Design follow-up")
    field.press("Enter")
    expect_toast(page, "Renamed to “Design follow-up”")
    _in_review(page, "Review · 1 of 3", "Design follow-up")
    assert hash_of(page) == "#/review"
    assert app_server.api(f"/api/meetings/{C}")["title"] == "Design follow-up"


def test_join_in_review_goes_on_with_the_joined_meeting_and_undo_comes_back(page, app_server):
    goto(page, app_server, "#/review")
    _in_review(page, "Review · 1 of 3", "Design review, part two")
    run_from_menu(page, "More actions", "Join with Previous")
    expect_toast(page, "Joined with “Design review”")
    _in_review(page, "Review · 1 of 2", "Design review")  # the joined meeting, still in Review
    assert app_server.meeting_ids() == [LIVE, B, A]
    undo_in_toast(page)
    _in_review(page, "Review · 1 of 3", "Design review, part two")


def test_trash_in_review_moves_on_and_undo_comes_back(page, app_server):
    goto(page, app_server, "#/review")
    _in_review(page, "Review · 1 of 3", "Design review, part two")
    run_from_menu(page, "More actions", "Move to Trash")
    expect_toast(page, "“Design review, part two” moved to Trash")
    _in_review(page, "Review · 1 of 2", "Design review")
    assert C not in app_server.meeting_ids()
    undo_in_toast(page)
    _in_review(page, "Review · 1 of 3", "Design review, part two")


def test_split_in_review_opens_the_cut_bar_there(page, app_server):
    goto(page, app_server, "#/review")
    _in_review(page, "Review · 1 of 3", "Design review, part two")
    run_from_menu(page, "More actions", "Split At…")
    expect(page.locator("#main .review .cut-bar")).to_be_visible()
    assert hash_of(page) == "#/review"
