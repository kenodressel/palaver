"""My own notes on a meeting (#44): typing (saved as I go, there after a
reload), the time chip, pasted and dropped images with the text read from
them, delete and clear with undo, and what the notes took from them."""

import base64
import io
import json
import re
from datetime import timedelta

import pytest

from playwright.sync_api import expect  # noqa: E402

from .helpers import expect_toast, goto, line, menu_item, open_meeting, reload, show_tab, undo_in_toast  # noqa: E402
from .recordings import A, B, C, LIVE, _at  # noqa: E402
from .stores import prepared_notes_folder, save_my_notes  # noqa: E402

pytestmark = pytest.mark.e2e


def _pad(page):
    return page.locator("#main .my-notes")


def _saved(page):
    expect(_pad(page).locator(".mn-status")).to_have_text("Saved")


def _doc(served, mid=A) -> dict:
    return served.api(f"/api/meetings/{mid}/my-notes")


def _seed(served, mid, paragraphs) -> dict:
    """The notes written elsewhere (another window, before the test), on the revision there."""
    return served.api(f"/api/meetings/{mid}/my-notes", {"paragraphs": paragraphs, "revision": _doc(served, mid)["revision"]})


def _png(text: str) -> str:
    from PIL import Image, ImageDraw, ImageFont

    img = Image.new("RGB", (700, 160), "white")
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 48)
    ImageDraw.Draw(img).text((24, 50), text, fill="black", font=font)
    out = io.BytesIO()
    img.save(out, format="PNG")
    return base64.b64encode(out.getvalue()).decode()


# A paste or drop with an image file in it, as the page gets it from the system.
_GIVE_IMAGE = """([selector, kind, b64]) => {
  const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  const file = new File([bytes], "Screenshot.png", { type: "image/png" });
  const data = { files: [file], types: ["Files"] };
  const e = new Event(kind, { bubbles: true, cancelable: true });
  Object.defineProperty(e, kind === "paste" ? "clipboardData" : "dataTransfer", { value: data });
  document.querySelector(selector).dispatchEvent(e);
}"""


def _start_typing(page):
    _pad(page).locator(".mn-placeholder").click()
    expect(_pad(page).locator(".mn-input")).to_be_focused()


def test_typing_is_saved_and_there_after_a_reload(page, app_server):
    open_meeting(page, app_server, A, tab="Notes")
    expect(_pad(page).get_by_role("heading", name="My notes")).to_be_visible()
    _start_typing(page)
    page.keyboard.type("Ask about the **budget**")
    page.keyboard.press("Enter")
    page.keyboard.type("- go-live in March")
    page.keyboard.press("Enter")
    page.keyboard.type("two testers")  # the list goes on
    _saved(page)
    assert _doc(app_server)["paragraphs"] == [
        {"text": "Ask about the **budget**", "at": None},
        {"text": "- go-live in March", "at": None},
        {"text": "- two testers", "at": None},
    ]
    assert json.loads((app_server.root / A / "my-notes.json").read_text())[0]["text"] == "Ask about the **budget**"

    reload(page)
    expect(_pad(page).locator(".mn-text strong")).to_have_text("budget")  # light markdown, as text
    assert "null" not in _pad(page).inner_text()
    expect(_pad(page).locator(".mn-text li")).to_have_text(["go-live in March", "two testers"])
    expect(_pad(page).locator(".mn-text").first).to_have_text("Ask about the budget")
    _pad(page).locator(".mn-text").first.click()
    expect(_pad(page).locator(".mn-input")).to_have_value("Ask about the **budget**")


def test_markup_typed_is_shown_as_text(page, app_server):
    _seed(app_server, A, [{"text": "<img src=x onerror=alert(1)> **<b>hi</b>**", "at": None}])
    open_meeting(page, app_server, A, tab="Notes")
    text = _pad(page).locator(".mn-text")
    expect(text).to_have_text("<img src=x onerror=alert(1)> <b>hi</b>")
    expect(text.locator("img, b")).to_have_count(0)
    expect(text.locator("strong")).to_have_text("<b>hi</b>")


def _during_the_live_call(page):
    """The page's clock a few minutes into the call being recorded: its date
    is fixed, and notes over 7 days into a meeting are refused (MAX_AT)."""
    page.clock.install(time=_at(LIVE) + timedelta(minutes=5))


def _live_paragraph_gets_its_time(page, app_server):
    expect(page.locator("#main .live-badge, #main .pill.state").first).to_be_visible()
    show_tab(page, "Notes")
    _start_typing(page)
    page.keyboard.type("They agreed on the budget")
    _saved(page)
    [p] = _doc(app_server, LIVE)["paragraphs"]
    assert p["text"] == "They agreed on the budget" and p["at"] > 60
    chip = _pad(page).locator(".mn-time").first
    expect(chip).to_have_text(re.compile(r"^\d+:\d\d(:\d\d)?$"))
    expect(chip).to_have_attribute("title", re.compile("into the meeting"))  # nothing to play while it records
    assert "none" not in chip.get_attribute("class")
    page.keyboard.press("Escape")
    expect(_pad(page).locator(".mn-input")).to_have_count(0)
    expect(_pad(page).locator(".mn-text")).to_have_text("They agreed on the budget")
    expect(_pad(page).locator(".mn-block .mn-time")).to_have_text(re.compile(r"^\d+:\d\d"))  # the chip stays


def test_notes_written_live_get_the_meeting_time(page, app_server):
    _during_the_live_call(page)
    goto(page, app_server, f"#/{LIVE}")
    _live_paragraph_gets_its_time(page, app_server)


def test_notes_written_in_the_first_minute_get_the_meeting_time_too(page, app_server):
    _during_the_live_call(page)
    (app_server.root / LIVE / "live.json").unlink()  # the live worker has not written its first block yet
    goto(page, app_server, f"#/{LIVE}")
    _live_paragraph_gets_its_time(page, app_server)


@pytest.mark.usefixtures("audio_decoding")
def test_the_time_chip_plays_from_there(page, app_server):
    _seed(app_server, A, [{"text": "Deploy still blocked", "at": 15}])
    open_meeting(page, app_server, A, tab="Notes")
    chip = _pad(page).get_by_role("button", name="Play from 0:15")
    expect(chip).to_have_text("0:15")
    chip.click()
    expect(page.locator("#clock")).to_have_text(re.compile(r"0:1[5-9]"))
    page.locator("#play").click()


def test_a_pasted_image_is_kept_and_its_text_read(page, app_server):
    open_meeting(page, app_server, A, tab="Notes")
    _start_typing(page)
    page.keyboard.type("The slide:")
    page.evaluate(_GIVE_IMAGE, ["#main .my-notes .mn-input", "paste", _png("Budget Q3 frozen")])
    image = _pad(page).locator(".mn-image img")
    expect(image).to_be_visible()
    expect(_pad(page).locator(".mn-image summary")).to_have_text("Text in the image", timeout=20_000)
    _pad(page).locator(".mn-image summary").click()
    expect(_pad(page).locator(".mn-read")).to_contain_text("Budget Q3")
    _saved(page)
    doc = _doc(app_server)
    [first, second] = doc["paragraphs"]
    assert first["text"] == "The slide:" and second["image"].endswith(".png")
    assert "Budget Q3" in doc["images"][second["image"]]["text"]
    assert (app_server.root / A / "my-notes" / second["image"]).exists()
    assert image.evaluate("img => img.naturalWidth") == 700  # served back from this Mac

    reload(page)
    expect(_pad(page).locator(".mn-image img")).to_be_visible()


def test_a_dropped_image_goes_in_too(page, app_server):
    _seed(app_server, A, [{"text": "Whiteboard", "at": None}])
    open_meeting(page, app_server, A, tab="Notes")
    expect(_pad(page).locator(".mn-text")).to_have_text("Whiteboard")
    page.evaluate(_GIVE_IMAGE, ["#main .my-notes .mn-block", "drop", _png("Q4")])
    expect(_pad(page).locator(".mn-image img")).to_be_visible()
    _saved(page)
    assert [bool(p.get("image")) for p in _doc(app_server)["paragraphs"]] == [False, True]


def test_deleting_an_image_can_be_undone(page, app_server):
    open_meeting(page, app_server, A, tab="Notes")
    _start_typing(page)
    page.keyboard.type("Slide")
    page.evaluate(_GIVE_IMAGE, ["#main .my-notes .mn-input", "paste", _png("Agenda")])
    expect(_pad(page).locator(".mn-image img")).to_be_visible()
    _saved(page)
    name = _doc(app_server)["paragraphs"][1]["image"]
    _pad(page).locator(".mn-image").hover()
    _pad(page).get_by_role("button", name="Delete image").click()
    expect_toast(page, "Image deleted from your notes")
    expect(_pad(page).locator(".mn-image")).to_have_count(0)
    assert not (app_server.root / A / "my-notes" / name).exists()
    undo_in_toast(page)
    expect(_pad(page).locator(".mn-image img")).to_be_visible()
    assert [p.get("image") for p in _doc(app_server)["paragraphs"]] == [None, name]


def test_clearing_my_notes_can_be_undone(page, app_server):
    _seed(app_server, A, [{"text": "Mine", "at": None}])
    open_meeting(page, app_server, A, tab="Notes")
    expect(_pad(page).locator(".mn-text")).to_have_text("Mine")
    expect(_pad(page).get_by_role("button", name="Clear", exact=True)).to_be_visible()
    _pad(page).get_by_role("button", name="Clear", exact=True).click()
    expect_toast(page, "Your notes cleared")
    expect(_pad(page).locator(".mn-text")).to_have_count(0)
    expect(_pad(page).get_by_role("button", name="Clear", exact=True)).to_have_count(0)  # nothing left to clear
    assert _doc(app_server)["paragraphs"] == []
    undo_in_toast(page)
    expect(_pad(page).locator(".mn-text")).to_have_text("Mine")
    assert _doc(app_server)["paragraphs"] == [{"text": "Mine", "at": None}]


def test_what_the_notes_took_from_mine_is_marked(page, app_server):
    path = app_server.root / A / "notes.json"
    n = json.loads(path.read_text())
    n["decisions_mine"] = [0]
    n["sections"][0]["points"][0]["mine"] = True
    path.write_text(json.dumps(n))
    open_meeting(page, app_server, A)
    expect(page.locator("#main .notes .you-mark")).to_have_count(2)
    expect(page.locator("#main .note-card .decision .you-mark")).to_have_attribute("title", "From your notes")

    _seed(app_server, A, [{"text": "Changed my mind", "at": None}])
    reload(page)
    expect(page.locator("#main .stale")).to_contain_text("Your notes changed after these notes were written.")


# --- never lost (review of #44) --------------------------------------------------------------------------


def test_notes_written_in_another_window_meanwhile_are_merged_not_overwritten(page, app_server):
    page.guard.allow(r"status of 409")  # the save refused, then merged and saved again
    open_meeting(page, app_server, A, tab="Notes")
    _start_typing(page)
    page.keyboard.type("Mine")
    _saved(page)
    _seed(app_server, A, [{"text": "Mine", "at": None}, {"text": "From the other window", "at": None}])
    page.keyboard.type(", more")  # on the notes as this window read them
    expect(_pad(page).locator(".mn-status")).to_have_text("Saved")
    page.wait_for_function(f"""async () => (await (await fetch('/api/meetings/{A}/my-notes')).json())
      .paragraphs.map((p) => p.text).join('|') === 'Mine, more|From the other window'""")
    expect(_pad(page).locator(".mn-text")).to_have_text(["From the other window"])  # shown here too
    expect(_pad(page).locator(".mn-input")).to_have_value("Mine, more")
    expect(_pad(page).locator(".mn-input")).to_be_focused()


def test_picking_the_event_brings_its_prepared_notes_and_keeps_what_was_typed(page, app_server):
    start = _at(B)
    event = lambda title, uid: {"title": title, "start": start.isoformat(),  # noqa: E731
                                "end": (start + timedelta(minutes=45)).isoformat(), "attendees": [], "uid": uid}
    (app_server.root / B / "calendar.json").write_text(json.dumps({"question": [event("Design review", "design"),
                                                                              event("Northwind", "north")]}))
    save_my_notes(prepared_notes_folder(f"north|{start.date().isoformat()}"),
                  [{"text": "Ask about the lottery budget", "at": None}])
    open_meeting(page, app_server, B, tab="Notes")
    _start_typing(page)
    page.keyboard.type("Typed in the call")  # not saved yet when the event is picked
    page.locator("#main .event-link.asking").get_by_role("button", name="Northwind").click()
    expect_toast(page, "Event changed to “Northwind”")
    expect(_pad(page).locator(".mn-text, .mn-input")).to_have_count(2)
    page.wait_for_function(f"""async () => (await (await fetch('/api/meetings/{B}/my-notes')).json())
      .paragraphs.map((p) => p.text).sort().join('|') === 'Ask about the lottery budget|Typed in the call'""")


def test_a_cut_moves_the_later_notes_and_the_page_follows(page, app_server):
    _seed(app_server, A, [{"text": "Before the cut", "at": 5}, {"text": "After the cut", "at": 30}])
    open_meeting(page, app_server, A, tab="Notes")
    expect(_pad(page).locator(".mn-text")).to_have_count(2)
    show_tab(page, "Transcript")
    line(page, 27).click(button="right")
    menu_item(page, "Split here").click()
    page.locator("#main .cut-bar").get_by_role("button", name="becomes its own meeting").click()
    expect_toast(page, "The rest is now a meeting of its own.")
    show_tab(page, "Notes")
    expect(_pad(page).locator(".mn-text")).to_have_text(["Before the cut"])
    [tail] = [m for m in app_server.meeting_ids() if m not in (A, B, C, LIVE)]
    assert _doc(app_server, tail)["paragraphs"] == [{"text": "After the cut", "at": 3}]


def test_the_live_refresh_leaves_the_notes_tab_alone_while_i_type(page, app_server):
    _during_the_live_call(page)
    goto(page, app_server, f"#/{LIVE}")
    show_tab(page, "Notes")
    _start_typing(page)
    page.keyboard.type("Typing while they talk")
    page.evaluate("document.querySelector('#main article.meeting').__mark = 1")
    live = app_server.root / LIVE / "live.json"
    data = json.loads(live.read_text())
    data["system"].append({"start": 40.0, "end": 42.0, "text": "Eine neue Zeile vom Band.", "speaker": None, "words": []})
    live.write_text(json.dumps(data))
    page.evaluate("window.palaver.poll()")
    page.wait_for_timeout(500)
    assert page.evaluate("document.querySelector('#main article.meeting').__mark") == 1  # not built again under the caret
    ta = _pad(page).locator(".mn-input")
    expect(ta).to_be_focused()
    expect(ta).to_have_value("Typing while they talk")
    assert ta.evaluate("t => t.selectionStart") == len("Typing while they talk")
    show_tab(page, "Transcript")
    expect(page.locator("#main .transcript")).to_contain_text("Eine neue Zeile vom Band.", timeout=15_000)


# --- the tabs ------------------------------------------------------------------------------------


def _tab_names(page):
    return page.locator("#main [role=tab]").evaluate_all("els => els.map((e) => e.querySelector('.tab-label').textContent)")


def test_the_tabs_are_summary_notes_transcript_coach(page, app_server):
    open_meeting(page, app_server, A)
    assert _tab_names(page) == ["Summary", "Notes", "Transcript", "Coach"]
    summary = page.get_by_role("tab", name="Summary")
    expect(summary).to_have_attribute("aria-selected", "true")  # the generated notes come first
    expect(summary).to_have_attribute("title", re.compile("AI generated"))
    expect(summary.locator(".tab-ai")).to_be_visible()
    expect(page.locator("#main .notes .summary")).to_be_visible()
    expect(_pad(page)).to_have_count(0)  # my notes are a tab of their own, not beside the others
    expect(page.locator("#main .meeting-cols")).to_have_count(0)
    show_tab(page, "Notes")
    expect(_pad(page)).to_be_visible()
    expect(page.locator("#main .notes")).to_have_count(0)
    goto(page, app_server, f"#/{LIVE}")
    expect(page.locator("#main .tabs [role=tab]")).to_have_count(3)  # no coach while it records
    assert _tab_names(page) == ["Summary", "Notes", "Transcript"]


@pytest.mark.parametrize("width", [1280, 900])
def test_my_notes_take_the_whole_tab(page, app_server, width):
    page.set_viewport_size({"width": width, "height": 800})
    open_meeting(page, app_server, A, tab="Notes")
    pad, tabs = _pad(page).bounding_box(), page.locator("#main .tabs").bounding_box()
    body = page.locator("#main .meeting").bounding_box()
    assert abs(pad["x"] - tabs["x"]) < 2 and pad["width"] > body["width"] - 2 * 40 - 4  # full width, under the tabs
    assert pad["y"] > tabs["y"]


def test_typing_in_my_notes_then_another_tab_and_back_keeps_it(page, app_server):
    open_meeting(page, app_server, A, tab="Notes")
    page.evaluate("""() => { window.__posts = 0; const f = window.fetch;
      window.fetch = (u, o) => { if (o?.method === "POST" && String(u).endsWith("/my-notes")) window.__posts++; return f(u, o); }; }""")
    _start_typing(page)
    page.keyboard.type("Ask about the budget")
    # Leaving the tab saves at once (not 500 ms later): the editor leaves the page with the click.
    sent = page.evaluate("""() => { [...document.querySelectorAll('#main [role=tab]')]
      .find((t) => t.textContent === 'Transcript').click(); return window.__posts; }""")
    assert sent == 1
    expect(page.get_by_role("tab", name="Transcript")).to_have_attribute("aria-selected", "true")
    expect(_pad(page)).to_have_count(0)
    page.wait_for_function(f"""async () => (await (await fetch('/api/meetings/{A}/my-notes')).json())
      .paragraphs.map((p) => p.text).join('|') === 'Ask about the budget'""")
    show_tab(page, "Notes")
    expect(_pad(page).locator(".mn-text")).to_have_text("Ask about the budget")
    expect(_pad(page).locator(".mn-status")).to_have_text("Saved")
    _pad(page).locator(".mn-text").click()
    page.keyboard.press("End")
    page.keyboard.type(" and the testers")
    show_tab(page, "Summary")
    show_tab(page, "Notes")
    expect(_pad(page).locator(".mn-text")).to_have_text("Ask about the budget and the testers")
    reload(page)
    expect(page.get_by_role("tab", name="Notes")).to_have_attribute("aria-selected", "true")  # the tab, kept
    expect(_pad(page).locator(".mn-text")).to_have_text("Ask about the budget and the testers")


def test_which_tab_a_meeting_opens_on(page, app_server):
    open_meeting(page, app_server, A)
    expect(page.get_by_role("tab", name="Summary")).to_have_attribute("aria-selected", "true")
    goto(page, app_server, f"#/{LIVE}")
    expect(page.get_by_role("tab", name="Transcript")).to_have_attribute("aria-selected", "true")
    # No summary written, but notes of mine: those.
    (app_server.root / C / "notes.json").unlink()
    _seed(app_server, C, [{"text": "My own take", "at": None}])
    goto(page, app_server, f"#/{C}")
    expect(page.get_by_role("tab", name="Notes")).to_have_attribute("aria-selected", "true")
    expect(_pad(page).locator(".mn-text")).to_have_text("My own take")
    # Neither: the summary tab, with its Write notes.
    (app_server.root / B / "notes.json").unlink()
    goto(page, app_server, f"#/{B}")
    expect(page.get_by_role("tab", name="Summary")).to_have_attribute("aria-selected", "true")
    expect(page.locator("#main .notes")).to_contain_text("No notes for this meeting yet.")


def test_a_paragraph_without_a_time_keeps_no_room_for_one(page, app_server):
    _seed(app_server, A, [{"text": "Warum sind wir hier? Test 12345", "at": None}, {"text": "Deploy blocked", "at": 15}])
    open_meeting(page, app_server, A, tab="Notes")
    expect(_pad(page).locator(".mn-block")).to_have_count(2)  # rendered before they are looked at
    untimed, timed = _pad(page).locator(".mn-block").all()
    expect(untimed.locator(".mn-time")).to_have_count(0)
    columns = lambda block: block.evaluate("b => getComputedStyle(b).gridTemplateColumns.split(' ').length")  # noqa: E731
    assert columns(untimed) == 1
    assert columns(timed) == 2
    block, text = untimed.bounding_box(), untimed.locator(".mn-text").bounding_box()
    assert text["x"] - block["x"] < 2  # no indent
    # A time sits at the right: the text still starts where an untimed paragraph's does.
    timed_text, chip = timed.locator(".mn-text").bounding_box(), timed.locator(".mn-time").bounding_box()
    assert timed_text["x"] - timed.bounding_box()["x"] < 2
    assert chip["x"] > timed_text["x"] + timed_text["width"]


def test_a_save_that_cannot_happen_says_so_and_offers_the_notes(page, app_server):
    import shutil

    open_meeting(page, app_server, A, tab="Notes")
    _start_typing(page)
    page.keyboard.type("Keep this")
    _saved(page)
    shutil.move(str(app_server.root / A), str(app_server.root.parent / "gone"))  # e.g. joined into another meanwhile
    page.guard.allow(r"404")
    page.keyboard.type(" safe")
    problem = _pad(page).locator(".mn-problem")
    expect(problem).to_contain_text("Couldn't save: this meeting is not here any more")
    expect(_pad(page).locator(".mn-input")).to_have_value("Keep this safe")
    problem.get_by_role("button", name="Copy my notes").click()
    expect_toast(page, "Your notes are copied")
    assert page.evaluate("window.__copied") == ["Keep this safe"]
    page.wait_for_timeout(1500)
    assert problem.is_visible()  # no retries: it stays said


def test_notes_not_saved_when_the_page_went_come_back(page, app_server):
    open_meeting(page, app_server, A, tab="Notes")
    page.route(f"**/api/meetings/{A}/my-notes", lambda route: route.abort() if route.request.method == "POST"
               else route.continue_())
    page.guard.allow(r"my-notes|Load failed|network")
    _start_typing(page)
    page.keyboard.type("Written while offline")
    expect(_pad(page).locator(".mn-status")).to_have_text("Not saved · trying again")
    page.unroute(f"**/api/meetings/{A}/my-notes")
    reload(page)
    expect(_pad(page).locator(".mn-text")).to_have_text("Written while offline")
    page.wait_for_function(f"""async () => (await (await fetch('/api/meetings/{A}/my-notes')).json())
      .paragraphs.map((p) => p.text).join('|') === 'Written while offline'""")
