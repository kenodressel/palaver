"""A meeting exported to a .palaver file and imported again (#58): from ⋯,
⌘K, the sidebar and a file dropped on the window; the same meeting here
asks first; the voices wait for a yes; Undo takes the import back."""

import base64
import json
import re
import zipfile

import numpy as np
import pytest

from playwright.sync_api import expect  # noqa: E402

from .helpers import cmd, expect_toast, heading, list_ids, list_item, menu_item, more, open_meeting, toast, unfocus  # noqa: E402
from .recordings import A, B  # noqa: E402

pytestmark = pytest.mark.e2e


def dialog(page):
    return page.get_by_role("dialog")


def export_from_menu(page, served, mid: str, *, voices: bool = False) -> str:
    """Export… from ⋯; returns the file's path."""
    open_meeting(page, served, mid)
    more(page).click()
    menu_item(page, "Export…").click()
    if voices:
        dialog(page).get_by_role("checkbox", name="Voices of the named people").check()
    dialog(page).get_by_role("button", name="Export").click()
    expect(dialog(page)).to_have_count(0)
    text = expect_toast(page, re.compile(r"^Saved to Downloads: “.+\.palaver”$")).locator(".toast-text").inner_text()
    name = text.split("“", 1)[1].rstrip("”")
    return str(served.root.parent / "Downloads" / name)


def test_export_offers_what_goes_in_and_saves_the_file_to_downloads(page, app_server):
    open_meeting(page, app_server, A)
    more(page).click()
    menu_item(page, "Export…").click()
    d = dialog(page)
    expect(d.get_by_role("heading")).to_have_text("Export “Team standup”")
    expect(d.get_by_role("checkbox", name="Transcript and names")).to_be_checked()
    expect(d.get_by_role("checkbox", name="Transcript and names")).to_be_disabled()
    expect(d.get_by_role("checkbox", name="Notes")).to_be_checked()
    expect(d.get_by_role("checkbox", name="Voices of the named people")).not_to_be_checked()
    expect(d.get_by_role("checkbox", name="Audio")).not_to_be_checked()
    expect(d).to_contain_text("Biometric data")
    d.get_by_role("checkbox", name="Notes").uncheck()
    d.get_by_role("button", name="Export").click()
    expect_toast(page, "Saved to Downloads: “2026-10-27 Team standup.palaver”")
    with zipfile.ZipFile(app_server.root.parent / "Downloads" / "2026-10-27 Team standup.palaver") as zf:
        names = set(zf.namelist())
    assert "meeting/transcript.json" in names and "meeting/notes.json" not in names
    assert not any(n.startswith(("audio/", "voices/")) for n in names)


def test_escape_cancels_the_export(page, app_server):
    open_meeting(page, app_server, A)
    unfocus(page)
    cmd(page, "k")
    page.get_by_role("combobox", name="Search or run a command").fill("export")
    page.keyboard.press("Enter")
    expect(dialog(page)).to_be_visible()
    page.keyboard.press("Escape")
    expect(dialog(page)).to_have_count(0)
    assert not (app_server.root.parent / "Downloads").exists()


def test_escape_and_a_click_beside_do_not_close_the_dialog_while_it_works(page, app_server):
    held = []
    page.route("**/api/meetings/*/export", lambda route: held.append(route))
    open_meeting(page, app_server, A)
    more(page).click()
    menu_item(page, "Export…").click()
    dialog(page).get_by_role("button", name="Export").click()
    page.wait_for_function("() => document.querySelector('.dialog .btn.primary')?.disabled")
    while not held:
        page.wait_for_timeout(50)
    page.keyboard.press("Escape")
    page.mouse.click(5, 800)  # on the dimmed window beside it
    expect(dialog(page)).to_be_visible()
    held[0].continue_()
    expect(dialog(page)).to_have_count(0)
    expect_toast(page, re.compile(r"^Saved to Downloads"))


def test_a_meeting_kept_on_this_mac_asks_before_it_is_exported(page, app_server):
    (app_server.root / A / "local_only.json").write_text("{}")
    open_meeting(page, app_server, A)
    more(page).click()
    menu_item(page, "Export…").click()
    dialog(page).get_by_role("button", name="Export").click()
    expect(dialog(page).get_by_role("heading")).to_have_text("This meeting is kept on this Mac")
    dialog(page).get_by_role("button", name="Cancel").click()
    expect(dialog(page)).to_have_count(0)
    assert not (app_server.root.parent / "Downloads").exists()


def test_the_same_meeting_imported_asks_and_goes_beside_mine_then_undo_takes_it_back(page, app_server):
    file = export_from_menu(page, app_server, A)
    before = list_ids(page)
    with page.expect_file_chooser() as chooser:
        page.get_by_role("button", name="Import…").click()
    chooser.value.set_files(file)
    d = dialog(page)
    expect(d.get_by_role("heading")).to_have_text("This meeting is here already")
    expect(d).to_contain_text("You recorded this meeting yourself: “Team standup”")
    d.get_by_role("button", name="Import as a Separate Meeting").click()
    imported = f"{A}-2"
    expect(list_item(page, imported)).to_be_visible()
    expect(heading(page)).to_have_text("Team standup")
    expect(page.locator("#main .when .from")).to_have_text("from Timo")  # the rest in About this recording
    expect(page.locator("#main .about .imported-line")).to_contain_text("Imported from Timo")
    expect_toast(page, "“Team standup” imported from Timo")
    # Names come as hints, named by the sender: Anna was named by hand there.
    expect(page.locator('#main .lane-group[data-label="SPEAKER_00"] .inferred')).to_have_text("named by Timo")

    toast(page).get_by_role("button", name="Undo").click()
    expect(list_item(page, imported)).to_have_count(0)
    assert sorted(list_ids(page)) == sorted(before)
    assert (app_server.root / ".trash" / imported).is_dir()


def test_keep_mine_imports_nothing(page, app_server):
    file = export_from_menu(page, app_server, A)
    before = app_server.meeting_ids()
    unfocus(page)
    cmd(page, "k")
    page.get_by_role("combobox", name="Search or run a command").fill("import meeting")
    with page.expect_file_chooser() as chooser:
        page.keyboard.press("Enter")
    chooser.value.set_files(file)
    dialog(page).get_by_role("button", name="Keep Mine").click()
    expect(dialog(page)).to_have_count(0)
    assert app_server.meeting_ids() == before


def drop(page, file: str, target: str = "#main") -> None:
    """A file dropped on the window, as WebKit hands it to the page."""
    data = base64.b64encode(open(file, "rb").read()).decode()
    name = file.rsplit("/", 1)[1]
    transfer = page.evaluate_handle("""([data, name]) => {
        const bytes = Uint8Array.from(atob(data), (c) => c.charCodeAt(0));
        const t = new DataTransfer();
        t.items.add(new File([bytes], name, { type: "application/octet-stream" }));
        return t;
    }""", [data, name])
    page.dispatch_event(target, "dragover", {"dataTransfer": transfer})
    page.dispatch_event(target, "drop", {"dataTransfer": transfer})


def test_a_dropped_file_with_voices_imports_and_asks_about_the_voices(page, app_server):
    # Dana's and Eli's voices, as the diarizer left them.
    rng = np.random.default_rng(0)
    (app_server.root / B / "speaker_embeddings.json").write_text(json.dumps(
        {"SPEAKER_00": list(rng.normal(size=64)), "SPEAKER_01": list(rng.normal(size=64))}))
    file = export_from_menu(page, app_server, B, voices=True)
    drop(page, file)
    d = dialog(page)
    expect(d.get_by_role("heading")).to_have_text("Add their voices?")
    expect(d).to_contain_text("Timo sent the voices of Dana and Eli.")
    d.get_by_role("button", name="Add to Voice Bank").click()
    expect(dialog(page)).to_have_count(0)
    imported = f"{B}-2"  # B has no event, and no one invited: no match, a meeting of its own
    expect(list_item(page, imported)).to_be_visible()
    expect_toast(page, "Their voices are in your voice bank")
    meeting = app_server.api(f"/api/meetings/{imported}")
    assert meeting["imported"]["voices"] == []
    # Their voices' names now count as the user's; the sender's own lane is still a hint.
    assert {s["name"]: s["named_by"] for s in meeting["speakers"]} == {"Dana": "you", "Eli": "you", "Timo": "inferred"}


def test_return_on_the_voices_question_keeps_them_out(page, app_server):
    rng = np.random.default_rng(1)
    (app_server.root / B / "speaker_embeddings.json").write_text(json.dumps(
        {"SPEAKER_00": list(rng.normal(size=64)), "SPEAKER_01": list(rng.normal(size=64))}))
    file = export_from_menu(page, app_server, B, voices=True)
    drop(page, file)
    d = dialog(page)
    expect(d.get_by_role("heading")).to_have_text("Add their voices?")
    expect(d.get_by_role("button", name="Don’t Add")).to_be_focused()
    page.keyboard.press("Enter")
    expect(dialog(page)).to_have_count(0)
    expect_toast(page, "Their voices were not kept")
    assert not (app_server.root / f"{B}-2" / "imported_voices.json").exists()
    assert not (app_server.root / f"{B}-2" / "speaker_embeddings.json").exists()


def test_a_file_that_is_not_a_palaver_file_says_so(page, app_server, tmp_path):
    page.guard.allow(r"status of 400")  # the server's refusal, said in the toast
    open_meeting(page, app_server, A)
    bad = tmp_path / "notes.palaver"
    bad.write_bytes(b"not a zip")
    drop(page, str(bad))
    expect_toast(page, "Not imported: This is not a Palaver file (it is not a zip).")
    other = tmp_path / "photo.png"
    other.write_bytes(b"\x89PNG")
    drop(page, str(other))
    expect_toast(page, "Only a .palaver file can be dropped here: a meeting a colleague exported")
