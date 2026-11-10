"""A meeting: its notes and transcript, playing it, naming a speaker,
editing a line, and a meeting still being recorded."""

import re

import pytest

from playwright.sync_api import expect  # noqa: E402

from palaver.paths import RecordingPaths  # noqa: E402

from .helpers import (  # noqa: E402
    audio, expect_toast, goto, heading, lane, line, line_tool, list_item, open_meeting, reload, show_tab,
    speakers_in_transcript,
)
from .recordings import A, B, LIVE, write_stream  # noqa: E402

pytestmark = pytest.mark.e2e


def test_open_shows_notes_and_transcript(page, shared_server):
    goto(page, shared_server, f"#/{B}")
    list_item(page, A).click()
    expect(heading(page)).to_have_text("Team standup")
    expect(page.get_by_role("tab", name="Summary")).to_have_attribute("aria-selected", "true")
    notes = page.locator("#main .notes")
    expect(notes.locator(".summary")).to_have_text("Anna finished the migration; the pelican deploy is blocked.")
    expect(notes.locator(".decision")).to_have_text(["Carla reviews the deploy after lunch"])
    expect(notes.locator(".todo li")).to_have_text(["Carla: Review the pelican deploy"])
    show_tab(page, "Transcript")
    expect(page.locator("#main .transcript .turn")).to_have_count(5)
    assert speakers_in_transcript(page) == ["Timo", "Anna", "Speaker 2", "Carla", "Timo"]
    expect(line(page, 15).locator(".said")).to_contain_text("The pelican deploy is still blocked.")
    expect(page.locator("#player")).to_be_visible()
    expect(page.locator("#duration")).to_have_text("0:40")


@pytest.mark.usefixtures("audio_decoding")
def test_play_moves_the_clock(page, shared_server):
    open_meeting(page, shared_server, A)
    play = page.locator("#main .tbtn-play")
    expect(play).to_have_text("Play")
    play.click()
    expect(play).to_have_text("Pause")
    expect(page.locator("#clock")).not_to_have_text("0:00", timeout=6_000)
    assert audio(page)["muted"]  # never heard
    play.click()
    expect(play).to_have_text("Play")
    assert audio(page)["paused"]


@pytest.mark.usefixtures("audio_decoding")
def test_space_plays_and_pauses(page, shared_server):
    open_meeting(page, shared_server, A)
    page.locator("#main .when").click()  # on the page, not in a field (the title is one once clicked)
    page.keyboard.press(" ")
    expect(page.locator("#play")).to_have_attribute("aria-label", "Pause")
    expect(page.locator("#clock")).not_to_have_text("0:00", timeout=6_000)
    page.keyboard.press(" ")
    expect(page.locator("#play")).to_have_attribute("aria-label", "Play")


def test_pausing_before_the_audio_loaded_is_no_error(page, shared_server):
    """play() is rejected with an AbortError when pause() comes first: the page
    takes that as no error (it was an unhandled rejection)."""
    held = []
    page.route(re.compile(r"/audio\?track=mix"), lambda route: held.append(route))
    open_meeting(page, shared_server, A)
    page.locator("#main .when").click()  # on the page, not in a field (the title is one once clicked)
    page.keyboard.press(" ")
    expect(page.locator("#play")).to_have_attribute("aria-label", "Pause")
    page.keyboard.press(" ")  # the audio is still loading
    expect(page.locator("#play")).to_have_attribute("aria-label", "Play")
    page.wait_for_timeout(300)
    for route in held:
        route.continue_()
    page.wait_for_timeout(300)


@pytest.mark.usefixtures("audio_decoding")
def test_click_a_line_to_seek(page, shared_server):
    open_meeting(page, shared_server, A, tab="Transcript")
    line(page, 27).locator(".said").click()
    expect(page.locator("#clock")).to_have_text(re.compile(r"0:2[78]"))
    expect(line(page, 27)).to_have_class(re.compile(r"\bplaying\b"))
    assert audio(page)["time"] >= 27
    page.locator("#play").click()  # pause
    expect(page.locator("#play")).to_have_attribute("aria-label", "Play")


def test_name_a_speaker(page, app_server):
    open_meeting(page, app_server, A, tab="Transcript")
    field = page.get_by_label("Name for Speaker 2")
    field.fill("Bob")
    field.press("Enter")
    expect_toast(page, "Speaker 2 is now Bob")
    expect(line(page, 15).locator(".speaker")).to_have_text("Bob")
    expect(lane(page, "SPEAKER_01").locator(".voice-play")).to_have_count(0)  # a sure name: no play button
    reload(page)
    expect(page.get_by_label("Name for Bob")).to_have_value("Bob")
    assert app_server.api(f"/api/meetings/{A}")["transcript"][2]["speaker"] == "Bob"


def test_a_name_suggestion_names_with_one_click(page, app_server):
    open_meeting(page, app_server, A)
    chip = lane(page, "SPEAKER_01").locator(".hints .chip", has_text="Bob")
    expect(chip).to_have_attribute("title", "Name Speaker 2 Bob")
    expect(chip).to_contain_text("“over to you Bob”")  # what the notes found
    chip.click()
    expect_toast(page, "Speaker 2 is now Bob")
    expect(page.get_by_label("Name for Bob")).to_have_value("Bob")


def test_a_voice_without_a_sure_name_can_be_played_in_place(page, shared_server):
    open_meeting(page, shared_server, A)
    expect(lane(page, "SPEAKER_01").locator(".voice-play")).to_be_visible()  # no name yet
    expect(lane(page, "SPEAKER_02").locator(".voice-play")).to_be_visible()  # an inferred name
    expect(lane(page, "SPEAKER_00").locator(".voice-play")).to_have_count(0)  # named by hand
    with page.expect_request(re.compile(r"/audio\?track=system")):
        lane(page, "SPEAKER_01").get_by_role("button", name="Play voice of Speaker 2").click()


@pytest.mark.usefixtures("audio_decoding")
def test_a_voice_sample_can_be_stopped(page, shared_server):
    """#22: while a sample plays its ▶ is a stop button; a click, Escape or another sample stops it."""
    open_meeting(page, shared_server, A)
    two = lane(page, "SPEAKER_01")
    three = lane(page, "SPEAKER_02")
    two.get_by_role("button", name="Play voice of Speaker 2").click()
    stop = two.get_by_role("button", name="Stop voice of Speaker 2")
    expect(stop).to_have_class(re.compile(r"\bplaying\b"))
    stop.click()
    expect(two.get_by_role("button", name="Play voice of Speaker 2")).not_to_have_class(re.compile(r"\bplaying\b"))

    two.get_by_role("button", name="Play voice of Speaker 2").click()
    expect(two.get_by_role("button", name="Stop voice of Speaker 2")).to_be_visible()
    page.keyboard.press("Escape")
    expect(two.get_by_role("button", name="Play voice of Speaker 2")).to_be_visible()

    two.get_by_role("button", name="Play voice of Speaker 2").click()
    expect(two.get_by_role("button", name="Stop voice of Speaker 2")).to_be_visible()
    play_three = three.locator(".voice-play")
    play_three.click()  # another sample: the first one stops
    expect(two.get_by_role("button", name="Play voice of Speaker 2")).to_be_visible()
    expect(three.locator(".voice-play.playing")).to_have_count(1)
    expect(three.locator(".voice-play")).to_have_attribute("aria-label", re.compile(r"^Stop voice of "))


def test_edit_a_line_then_back_to_what_was_heard(page, app_server):
    open_meeting(page, app_server, A, tab="Transcript")
    line_tool(page, 4, "edit").click()
    box = page.get_by_role("textbox", name="The line at 0:04")
    expect(box).to_be_focused()
    box.fill("Morning. I finished the Attakring migration on Monday.")
    box.press("Enter")
    said = line(page, 4).locator(".said")
    expect(said).to_contain_text("I finished the Attakring migration on Monday.")
    expect(said.locator(".edited")).to_have_text("edited")
    expect_toast(page, "Line at 0:04 edited")
    expect(line(page, 4)).to_be_focused()  # back on the line once the editor closed

    line_tool(page, 4, "edit").click()
    page.get_by_role("button", name="Back to what was heard").click()
    expect(said).to_contain_text("I finished the Atterkring migration, over to you Bob.")
    expect(said.locator(".edited")).to_have_count(0)
    expect_toast(page, "Line at 0:04 edited")


def test_escape_cancels_an_edit(page, shared_server):
    open_meeting(page, shared_server, A, tab="Transcript")
    line_tool(page, 15, "edit").click()
    box = page.get_by_role("textbox", name="The line at 0:15")
    box.fill("Something else entirely.")
    box.press("Escape")
    expect(box).to_have_count(0)
    expect(line(page, 15).locator(".said")).to_contain_text("The pelican deploy is still blocked.")


def test_a_live_meeting_shows_live_text(page, app_server):
    write_stream(RecordingPaths(app_server.root / LIVE))
    goto(page, app_server, f"#/{LIVE}")
    expect(page.locator("#main .live-badge")).to_have_text("Live · transcribed up to 1:00")
    expect(page.get_by_role("tab", name="Transcript")).to_have_attribute("aria-selected", "true")
    expect(page.locator("#main .transcript > .turn")).to_have_count(3)
    assert speakers_in_transcript(page)[:3] == ["Timo", "Speaker 1", "Speaker 2"]
    expect(page.locator("#main .transcript")).to_contain_text("Ja, das passt für uns.")
    tail = page.locator("#main .stream-tail")
    expect(tail).to_contain_text("Die Zahlen kommen morgen.")  # the stream, once a second
    expect(tail.locator(".draft")).to_contain_text("und dann noch")
    expect(page.locator("#player")).to_be_hidden()  # nothing to play while recording
    page.get_by_role("tab", name="Summary").click()
    expect(page.locator("#main .notes")).to_contain_text("This meeting is still being recorded.")


def _ask(served, meeting=LIVE):
    served.recording.asked = {"meeting": meeting, "reason": "teams", "minutes": 10,
                              "message": "The Teams call has ended. Stop recording?"}


@pytest.mark.parametrize("choice, said", [
    ("Stop recording", "Recording stopped. It is transcribed in the background."),
    ("Keep recording", "Still recording. Palaver asks again when the next call ends or after 30 silent minutes."),
])
def test_a_live_meeting_asks_whether_to_stop(page, app_server, choice, said):
    _ask(app_server)
    goto(page, app_server, f"#/{LIVE}")
    banner = page.locator("#main .stop-question")
    expect(banner).to_contain_text("The Teams call has ended. Stop recording?")
    banner.get_by_role("button", name=choice).click()
    expect_toast(page, said)
    expect(banner).to_have_count(0)
    assert app_server.recording.answers == [("stop" if choice.startswith("Stop") else "keep", LIVE)]


def test_the_stop_question_only_on_its_meeting(page, app_server):
    _ask(app_server)
    open_meeting(page, app_server, A)
    expect(page.locator("#main .live-badge, #main .stop-question")).to_have_count(0)
    list_item(page, LIVE).click()
    expect(page.locator("#main .stop-question")).to_be_visible()


def test_a_stop_that_fails_says_so_and_tries_again(page, app_server):
    page.guard.allow(r"status of 400")
    _ask(app_server)
    app_server.recording.running = False
    goto(page, app_server, f"#/{LIVE}")
    page.locator("#main .stop-question").get_by_role("button", name="Stop recording").click()
    toast = expect_toast(page, "Not stopped: This recording is no longer running.")
    expect(page.locator("#main .stop-question")).to_be_visible()  # still asked
    app_server.recording.running = True
    toast.get_by_role("button", name="Try again").click()
    expect_toast(page, "Recording stopped. It is transcribed in the background.")
    expect(page.locator("#main .stop-question")).to_have_count(0)
