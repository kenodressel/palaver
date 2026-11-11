"""Every page of the Meetings window loads, the search finds, a setting stays."""

import json
import re

import pytest

from playwright.sync_api import expect  # noqa: E402

from .helpers import audio, goto, heading, list_ids, list_item, open_meeting, reload  # noqa: E402
from .recordings import A, B, C, LIVE  # noqa: E402
from .stores import GEMMA, NOTIFICATIONS_SETTINGS_URL, QWEN, write_update_status  # noqa: E402

pytestmark = pytest.mark.e2e


@pytest.mark.parametrize("where, title", [
    ("#/today", "Today"),
    (f"#/{A}", "Team standup"),
    (f"#/{LIVE}", re.compile("Meeting at")),
    ("#/people", "People"),
    ("#/projects", "Projects"),
    ("#/glossary", "Glossary"),
    ("#/settings", "Settings"),
    ("#/coach", "How you talk"),
])
def test_every_page_loads_without_errors(page, shared_server, where, title):
    goto(page, shared_server, where)
    expect(heading(page)).to_have_text(title)


def test_the_review_loads(page, shared_server):
    goto(page, shared_server)
    expect(page.locator('.views [data-view="today"] .nav-count')).to_have_text("3")
    page.get_by_role("button", name="Review all in order").click()
    expect(page.locator("#main .review-bar")).to_contain_text("Review · 1 of 3")
    expect(page.locator("#main .review h1")).to_have_text("Design review, part two")
    page.get_by_role("button", name="Skip").click()
    expect(page.locator("#main .review-bar")).to_contain_text("Review · 2 of 3")


def test_the_top_bar_goes_to_every_page(page, shared_server):
    goto(page, shared_server)
    expect(heading(page)).to_have_text("Today")  # the start page
    for view, title in [("people", "People"), ("projects", "Projects"), ("glossary", "Glossary"), ("today", "Today")]:
        page.locator(f'.views [data-view="{view}"]').click()
        expect(heading(page)).to_have_text(title)
        expect(page.locator(f'.views [data-view="{view}"]')).to_have_attribute("aria-current", "page")
        expect(page.locator("body")).to_have_attribute("data-page", view)
    page.locator("#settings-btn").click()
    expect(heading(page)).to_have_text("Settings")
    page.locator('.views [data-view="meetings"]').click()
    expect(heading(page)).to_have_text(re.compile("Meeting at"))


def test_the_coach_tab_of_a_meeting(page, shared_server):
    open_meeting(page, shared_server, A, tab="Coach")
    expect(page.locator("#main .coach-card").first).to_be_visible()
    page.get_by_role("button", name="All meetings →").click()
    expect(heading(page)).to_have_text("How you talk")
    page.locator("#main .coach-table tbody tr", has_text="Design review").first.click()
    expect(page.get_by_role("tab", name="Coach")).to_have_attribute("aria-selected", "true")


@pytest.mark.usefixtures("audio_decoding")
def test_search_finds_a_word_in_a_transcript(page, shared_server):
    goto(page, shared_server, f"#/{B}")
    page.locator("#search").fill("pelican")
    result = list_item(page, A)
    expect(result.locator("mark")).to_have_text("pelican")
    expect(page.locator("#list .item")).to_have_count(1)
    result.click()
    expect(heading(page)).to_have_text("Team standup")
    expect(page.get_by_role("tab", name="Transcript")).to_have_attribute("aria-selected", "true")
    expect(page.locator("#clock")).to_have_text("0:15")  # at the line found
    assert audio(page)["time"] == pytest.approx(15, abs=0.5)
    page.locator("#search").fill("nothing like this")
    expect(page.locator("#list")).to_contain_text("Nothing found for “nothing like this”.")
    page.locator("#search").fill("")
    expect(page.locator("#list .item[data-id]")).to_have_count(4)


def test_the_filter_shows_one_persons_meetings(page, shared_server):
    goto(page, shared_server, f"#/{A}")
    page.locator("#filter").select_option(label="Dana (2)")
    expect(page.locator("#list .item[data-id]")).to_have_count(2)
    assert list_ids(page) == [C, B]
    page.locator("#filter").select_option(label="All meetings")
    expect(page.locator("#list .item[data-id]")).to_have_count(4)


def test_a_settings_switch_persists_after_reload(page, app_server):
    goto(page, app_server, "#/settings/recording")
    switch = page.get_by_role("switch", name="Realtime transcription")
    expect(switch).to_be_checked()  # on by default
    page.locator("label.switch-row", has_text="Realtime transcription").click()
    expect(switch).not_to_be_checked()
    expect(switch).to_be_focused()  # the page was rebuilt; the keyboard stays on the switch
    reload(page)
    expect(heading(page)).to_have_text("Settings")
    expect(page.get_by_role("switch", name="Realtime transcription")).not_to_be_checked()
    assert app_server.api("/api/settings")["realtime"] is False


def test_a_provider_card_saves_its_key_with_one_save(page, app_server):
    """No separate "Save key": the card's Save stores a key typed into it, then the rest."""
    goto(page, app_server, "#/settings/language-model")
    card = page.locator(".settings-card", has=page.get_by_role("heading", name="Anthropic API"))
    expect(card.get_by_role("button", name="Save key")).to_have_count(0)
    card.get_by_role("textbox", name="Model for Anthropic API").fill("claude-test-model")
    card.get_by_role("textbox", name="API key for Anthropic API").fill("sk-test-123")
    card.get_by_role("button", name="Save", exact=True).click()
    card = page.locator(".settings-card", has=page.get_by_role("heading", name="Anthropic API"))
    expect(card).to_contain_text("Key set ✓")
    assert "sk-test-123" in app_server.keychain.values()
    anthropic = next(p for p in app_server.api("/api/language-model")["providers"] if p["label"] == "Anthropic API")
    assert anthropic["model"] == "claude-test-model" and anthropic["key_set"]

    # Enter in the key field is that Save too: a transcription service, in its own pane.
    page.locator(".settings-nav").get_by_role("link", name="Transcription").click()
    expect(page).to_have_url(re.compile("#/settings/transcription$"))
    card = page.locator(".settings-card", has=page.get_by_role("heading", name="Soniox"))
    field = card.get_by_role("textbox", name="API key for Soniox")
    field.fill("soniox-key")
    field.press("Enter")
    card = page.locator(".settings-card", has=page.get_by_role("heading", name="Soniox"))
    expect(card).to_contain_text("Key set ✓")
    assert "soniox-key" in app_server.keychain.values()


class _StubGateway:
    """An OpenAI-compatible endpoint on this Mac: answers every chat completion with a greeting and keeps the
    Authorization headers it got."""

    def __init__(self):
        import threading
        from http.server import BaseHTTPRequestHandler, HTTPServer

        got = self.authorizations = []
        self.paths = []
        paths = self.paths

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                self.rfile.read(int(self.headers.get("Content-Length") or 0))
                got.append(self.headers.get("Authorization"))
                paths.append(self.path)
                body = json.dumps({"choices": [{"message": {"role": "assistant",
                                                            "content": json.dumps({"reply": "Hello from the stub"})},
                                                "finish_reason": "stop"}]}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass

        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def test_a_cloud_model_is_set_up_chosen_and_tested(page, app_server):
    """The server keeps the key (never shown again), the provider is chosen for notes, and the Test button asks the
    endpoint: an OpenAI-compatible gateway stubbed on this Mac."""
    gateway = _StubGateway()
    key = "sk-e2e-gateway-0123456789"
    try:
        goto(page, app_server, "#/settings/language-model")
        card = page.locator(".settings-card", has=page.get_by_role("heading", name="OpenAI-compatible", exact=True))
        card.get_by_role("textbox", name="Endpoint for OpenAI-compatible").fill(f"http://127.0.0.1:{gateway.port}/v1")
        card.get_by_role("textbox", name="Model for OpenAI-compatible").fill("stub-model")
        card.get_by_role("textbox", name="API key for OpenAI-compatible").fill(key)
        card.get_by_role("button", name="Save", exact=True).click()
        card = page.locator(".settings-card", has=page.get_by_role("heading", name="OpenAI-compatible", exact=True))
        expect(card).to_contain_text("Key set ✓")
        expect(card).to_contain_text("Ready.")
        assert app_server.keychain.get("openai.api_key") == key
        assert key not in json.dumps(app_server.api("/api/language-model")) and key not in page.content()

        page.get_by_role("combobox", name="Model for Notes").select_option("openai")
        for _ in range(50):
            notes = next(f for f in app_server.api("/api/language-model")["features"] if f["id"] == "notes")
            if notes["choice"] == "openai":
                break
            page.wait_for_timeout(100)
        assert notes["choice"] == "openai"

        card.get_by_role("button", name="Test").click()
        expect(card.get_by_role("status")).to_contain_text("“Hello from the stub” in")
        assert gateway.paths == ["/v1/chat/completions"] and gateway.authorizations == [f"Bearer {key}"]
        expect(page.locator(".lm-log li")).to_have_count(1)  # the test call, in what was sent to the cloud
        assert key not in page.content()
    finally:
        gateway.close()


class _StubTranscriber:
    """An OpenAI-compatible transcription endpoint on this Mac: answers every upload with timed words and keeps what it
    got (path, content type, whether a FLAC file came, the Authorization header)."""

    def __init__(self):
        import threading
        from http.server import BaseHTTPRequestHandler, HTTPServer

        got = self.uploads = []

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
                got.append({"path": self.path, "type": self.headers.get("Content-Type", ""),
                            "flac": b'filename="audio.flac"' in body and b"fLaC" in body,
                            "authorization": self.headers.get("Authorization")})
                answer = json.dumps({"language": "english", "duration": 2.0, "text": "Beep.",
                                     "words": [{"word": "Beep", "start": 0.1, "end": 0.6}],
                                     "segments": [{"start": 0.0, "end": 1.0, "text": " Beep."}]}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(answer)))
                self.end_headers()
                self.wfile.write(answer)

            def log_message(self, *a):
                pass

        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def test_a_transcription_service_is_set_up_and_tested(page, app_server):
    """The transcription Test button sends two seconds of a tone (FLAC, no meeting) to the service and says how long it
    took: an OpenAI-compatible endpoint stubbed on this Mac (no key needed there)."""
    stub = _StubTranscriber()
    try:
        goto(page, app_server, "#/settings/transcription")
        name = "OpenAI-compatible transcription"
        card = page.locator(".settings-card", has=page.get_by_role("heading", name=name, exact=True))
        card.get_by_role("textbox", name=f"Endpoint for {name}").fill(f"http://127.0.0.1:{stub.port}/v1")
        card.get_by_role("textbox", name=f"Model for {name}").fill("whisper-1")
        card.get_by_role("button", name="Save", exact=True).click()
        card = page.locator(".settings-card", has=page.get_by_role("heading", name=name, exact=True))
        expect(card).to_contain_text("Ready.")
        card.get_by_role("button", name="Test").click()
        expect(card.get_by_role("status")).to_contain_text(re.compile(r"Answered in [0-9.]+ s"))
        assert [u["path"] for u in stub.uploads] == ["/v1/audio/transcriptions"]
        assert stub.uploads[0]["type"].startswith("multipart/form-data") and stub.uploads[0]["flac"]
        assert stub.uploads[0]["authorization"] is None  # no key was set, none is sent
        log = app_server.api("/api/language-model")["log"]  # what was sent to the cloud
        assert [(e["feature"], e["audio_seconds"], e["ok"]) for e in log] == [("test", 2.0, True)]
    finally:
        stub.close()


def test_the_live_coach_settings_say_where_nudges_show(page, app_server):
    """#19: nudges come as notifications (a switch, on by default), not next to the clock."""
    goto(page, app_server, "#/settings/recording")
    card = page.locator(".settings-card", has=page.get_by_role("switch", name="Long monologues (3 minutes and more)"))
    expect(card).to_contain_text("as a notification")
    expect(card).not_to_contain_text("next to the clock")
    switch = page.get_by_role("switch", name="Show nudges as notifications")
    expect(switch).to_be_checked()
    page.locator("label.switch-row", has_text="Show nudges as notifications").click()
    expect(switch).not_to_be_checked()  # at once; the save follows
    for _ in range(50):
        if app_server.api("/api/settings")["nudge_notify"] is False:
            break
        page.wait_for_timeout(100)
    assert app_server.api("/api/settings")["nudge_notify"] is False


def test_settings_say_how_palaver_updates_and_uninstalling_asks_first(page, app_server):
    """#60: a checkout has no updates; "Uninstall Palaver…" asks, and Cancel
    changes nothing."""
    goto(page, app_server, "#/settings/update")
    section = page.locator("#update-section")
    expect(section.get_by_role("heading", name="Updates")).to_be_visible()
    expect(section.get_by_role("status")).to_contain_text("runs from a checkout")
    section.get_by_role("button", name="Uninstall Palaver…").click()
    box = page.get_by_role("dialog", name="Uninstall Palaver?")
    expect(box.get_by_role("checkbox", name=re.compile("Also delete my recordings"))).not_to_be_checked()
    expect(box.get_by_role("button", name="Uninstall")).to_be_focused()
    box.get_by_role("button", name="Cancel").click()
    expect(box).to_have_count(0)


def _cached(served, repo: str, size: int) -> None:
    """A model in the server's Hugging Face cache: one blob of ``size`` bytes (sparse)."""
    blobs = served.home / ".cache" / "huggingface" / "hub" / ("models--" + repo.replace("/", "--")) / "blobs"
    blobs.mkdir(parents=True)
    with open(blobs / "weights", "wb") as f:
        f.truncate(size)


def test_settings_show_what_meetings_and_models_take(page, app_server):
    """#9: the meetings' size, how long audio stays (kept by default), the
    models; only a notes model not in use offers Delete, and asks first."""
    _cached(app_server, GEMMA, 9 * 1024 ** 3)  # the notes model in use
    _cached(app_server, QWEN, 17 * 1024 ** 3)  # no longer offered
    goto(page, app_server, "#/settings/storage")
    section = page.locator("#storage-section")
    expect(section.get_by_role("heading", name="Storage")).to_be_visible()
    expect(section).to_contain_text(re.compile(r"\d+ meetings take .+ of it audio\."))
    expect(section.get_by_role("combobox", name="Delete the audio of transcribed meetings")).to_have_value("0")
    expect(section.locator('[data-model="gemma"] button')).to_have_count(0)
    section.locator('[data-model="qwen"]').get_by_role("button", name="Delete").click()
    box = page.get_by_role("dialog", name="Delete Qwen3 30B A3B?")
    box.get_by_role("button", name="Cancel").click()
    expect(box).to_have_count(0)


def test_settings_say_when_notifications_are_off(page, app_server):
    """macOS refused them: said, with the way to System Settings; on, a quiet line."""
    state = app_server.notify_state  # the app's launcher writes it
    state.write_text("denied")
    goto(page, app_server, "#/settings/notifications")
    section = page.locator("#notifications-section")
    expect(section).to_contain_text("Off")
    expect(page.locator('.settings-nav [data-pane="notifications"] .settings-flag')).to_have_count(1)  # said in the list
    section.get_by_role("button", name="Open System Settings").click()
    expect(page.locator("#toasts")).to_contain_text("Allow notifications for Palaver there")
    assert app_server.opened == [NOTIFICATIONS_SETTINGS_URL]
    state.write_text("allowed")  # allowed in System Settings: the page follows
    expect(section.get_by_role("button", name="Open System Settings")).to_have_count(0, timeout=10_000)
    expect(page.locator("#notifications-section")).to_contain_text("On")


def _update_json(served, status: dict) -> None:
    """update.json as the menu bar app's updater writes it."""
    write_update_status(status, served.home)


def test_a_new_release_shows_in_the_top_bar_and_opens_settings(page, app_server):
    """The top bar's "Update to 0.9.0" on every page while there is one; a click
    shows it in Settings. Up to date, the top bar says nothing."""
    _update_json(app_server, {"state": "available", "current": "0.3.6", "announced": "0.9.0",
                              "available": {"version": "0.9.0", "notes": "Faster notes.", "download_bytes": 3 << 20,
                                            "runtime": False, "models": []}})
    goto(page, app_server, "#/people")
    pill = page.locator("#update-status")
    expect(pill).to_have_text("Update to 0.9.0")
    pill.click()
    expect(page).to_have_url(re.compile("#/settings/update$"))
    section = page.locator("#update-section")
    expect(section.get_by_role("status")).to_contain_text("Palaver 0.9.0 is available (3 MB). You have 0.3.6.")
    expect(section.get_by_role("button", name="Download and install")).to_be_visible()

    _update_json(app_server, {"state": "up_to_date", "current": "0.9.0", "available": None})
    goto(page, app_server, "#/settings/update")  # the notification's click
    expect(page.locator("#update-section")).to_be_in_viewport()
    expect(pill).to_be_hidden()


def test_today_leads_with_a_new_release_until_it_is_installed(page, app_server):
    _update_json(app_server, {"state": "available", "current": "0.3.6",
                              "available": {"version": "0.9.0", "download_bytes": 3 << 20}})
    goto(page, app_server, "#/today")
    card = page.locator(".today .update-card")
    expect(card).to_contain_text("Palaver 0.9.0 is available")
    card.get_by_role("button", name="Update Now").click()
    page.wait_for_timeout(300)
    assert app_server.update_actions == ["install"]  # asked of the menu bar app
    card.get_by_role("button", name="What's new").click()
    expect(page).to_have_url(re.compile("#/settings/update$"))


def test_settings_connect_the_calendar_and_follow_a_yes_given_elsewhere(page, app_server):
    """The calendar moved from the menu bar's menu to Settings."""
    goto(page, app_server, "#/settings/calendar")
    card = page.locator("#calendar-card")
    expect(card).to_contain_text("not connected")
    card.get_by_role("button", name="Connect Calendar").click()
    expect(card).to_contain_text("connected (read only)")  # macOS's dialog answered: the page follows
    expect(card.get_by_role("button")).to_have_count(0)
    assert app_server.probe.calendar.asked == 1
