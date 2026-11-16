"""Follow-ups after a call (#18): Draft Recap Email hands a draft (.eml) to the mail app, the next steps go to Todoist
or a Notion to-do database on a button press (the user's own first, each once), and Settings → Follow-ups keeps the
token in the Keychain and checks the services. Todoist and Notion are a stub on 127.0.0.1; nothing is sent anywhere
else, and nothing opens on the Mac."""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from playwright.sync_api import expect  # noqa: E402

from .conftest import _serve  # noqa: E402
from .helpers import expect_toast, goto, open_meeting, reload  # noqa: E402
from .recordings import A, USER  # noqa: E402
from .stores import RecordingPaths, attendee, load_notes, read_settings, save_notes  # noqa: E402

pytestmark = pytest.mark.e2e

TOKEN = "e2eTodoistToken0123456789abcdef01234567"
DB = "0123abcd-0123-4567-89ab-0123456789ab"


class StubServices:
    """Todoist's API v1 (/api/v1) and Notion's (/v1) as far as the follow-ups use them; keeps what it got."""

    def __init__(self):
        self.got: list[tuple[str, str, dict | None, str | None]] = []  # (method, path, body, Authorization)
        self._next = 0
        stub = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _answer(self, method: str):
                length = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(length)) if length else None
                stub.got.append((method, self.path, body, self.headers.get("Authorization")))
                status, out = stub.answer(method, self.path)
                data = json.dumps(out).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                self._answer("GET")

            def do_POST(self):
                self._answer("POST")

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self._server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self._server.server_address[1]}"

    def answer(self, method: str, path: str):
        if (method, path) == ("POST", "/api/v1/tasks"):  # v1 answers the task without a url
            self._next += 1
            return 200, {"id": f"6X7rM8997g3RQm{self._next:02d}", "content": "…", "project_id": "6Jf8VQXxpwv56VQ8"}
        if (method, path) == ("GET", "/api/v1/projects?limit=200"):  # paged: results and next_cursor
            return 200, {"results": [{"id": "6Jf8VQXxpwv56VQ8", "name": "Inbox", "inbox_project": True}],
                         "next_cursor": "eyJwYWdlIjoyfQ.aGFzaA"}
        if (method, path) == ("GET", "/api/v1/projects?limit=200&cursor=eyJwYWdlIjoyfQ.aGFzaA"):
            return 200, {"results": [{"id": "6Jf8VQXxpwv56VQ7", "name": "Contoso", "inbox_project": False}], "next_cursor": None}
        if (method, path) == ("GET", f"/v1/databases/{DB}"):
            return 200, {"object": "database", "title": [{"plain_text": "Tasks"}],
                         "properties": {"Name": {"type": "title"}, "Due": {"type": "date"}, "Done": {"type": "checkbox"}}}
        return 404, {"message": "not here"}

    def tasks(self) -> list[dict]:
        return [body for method, path, body, _ in self.got if (method, path) == ("POST", "/api/v1/tasks")]

    def close(self):
        self._server.shutdown()
        self._server.server_close()


@pytest.fixture
def services(tmp_path):
    """The window's server with the stub as Todoist and Notion, and meeting A with an invitee and a step of the user's."""
    stub = StubServices()
    srv, served = _serve(tmp_path / "Recordings", env={"PALAVER_TEST_TODOIST_URL": f"{stub.url}/api/v1",
                                                        "PALAVER_TEST_NOTION_API": f"{stub.url}/v1"})
    paths = RecordingPaths(served.root / A)
    notes = load_notes(paths)
    notes["next_steps"] = [{"owner": USER, "task": "Send the deploy notes by Friday"}] + notes["next_steps"]
    save_notes(paths, notes)
    event = json.loads(paths.calendar.read_text())
    event["attendees"] = [attendee(USER, "timo@contoso.example", is_self=True), attendee("Anna", "anna@contoso.example"),
                          attendee("Carla", "carla@northwind.example")]
    paths.calendar.write_text(json.dumps(event))
    yield served, stub
    served.close()
    stub.close()


def _keychain(served) -> dict:
    return served.keychain


def test_draft_recap_email_hands_a_draft_to_the_mail_app(page, services):
    served, _ = services
    open_meeting(page, served, A)
    button = page.locator("#follow-ups").get_by_role("button", name="Draft Recap Email")
    expect(button).to_have_attribute("title", "A draft to Anna, Carla, written from the notes, in your mail app. Palaver sends nothing.")
    button.click()
    expect_toast(page, "The recap is open as a draft in your mail app.")
    assert len(served.opened) == 1 and served.opened[0].endswith(".eml")
    eml = open(served.opened[0], encoding="utf-8", newline="").read()  # CRLF as written
    assert eml.startswith("X-Unsent: 1\r\nTo: Anna <anna@contoso.example>,\r\n Carla <carla@northwind.example>\r\n")
    assert "Subject: Recap: Team standup\r\n" in eml and "timo@contoso.example" not in eml


def test_my_next_steps_go_to_todoist_once_then_the_others_on_request(page, services):
    served, stub = services
    (served._fake.folder / "keychain.json").write_text(json.dumps({"TODOIST_TOKEN": TOKEN}))
    open_meeting(page, served, A)
    row = page.locator("#follow-ups")
    row.get_by_role("button", name="Add my next steps to Todoist").click()
    expect_toast(page, "1 next step added to Todoist")
    expect(row.get_by_role("button", name="Added to Todoist ✓")).to_be_disabled()
    assert stub.tasks() == [{"content": "Send the deploy notes by Friday", "due_date": "2026-10-30",
                             "description": "From the meeting “Team standup, 2026-10-27” (Palaver)"}]
    assert all(auth == f"Bearer {TOKEN}" for *_, auth in stub.got)
    row.get_by_role("checkbox", name="Include others' next steps").check()
    row.get_by_role("button", name="Add 1 new next step to Todoist").click()
    expect(row.get_by_role("button", name="Added to Todoist ✓")).to_be_disabled()
    assert stub.tasks()[1]["content"] == "Carla: Review the pelican deploy"
    record = json.loads((RecordingPaths(served.root / A).folder / "follow-ups.json").read_text())
    assert len(record["todoist"]) == 2 and TOKEN not in json.dumps(record)


def test_a_meeting_kept_on_this_mac_sends_no_tasks(page, services):
    served, stub = services
    (served._fake.folder / "keychain.json").write_text(json.dumps({"TODOIST_TOKEN": TOKEN}))
    (served.root / A / "local_only.json").write_text('{"since": "2026-10-27T09:30:00+01:00"}')
    open_meeting(page, served, A)
    row = page.locator("#follow-ups")
    expect(row.get_by_role("button", name="Add my next steps to Todoist")).to_be_disabled()
    expect(row).to_contain_text("Kept on this Mac: next steps don't go to Todoist or Notion.")
    expect(row.get_by_role("button", name="Draft Recap Email")).to_be_enabled()  # nothing leaves until it is sent
    assert stub.got == []


def test_settings_keep_the_token_in_the_keychain_and_check_the_services(page, services):
    served, stub = services
    goto(page, served, "#/settings/follow-ups")
    page.get_by_role("textbox", name="Todoist API token").fill(TOKEN)
    page.locator("#todoist-card").get_by_role("button", name="Save").click()
    expect_toast(page, "Token saved in the Keychain.")
    assert _keychain(served) == {"TODOIST_TOKEN": TOKEN}
    expect(page.locator("#todoist-card")).to_contain_text("Token set ✓")
    assert TOKEN not in page.content()
    page.locator("#todoist-card").get_by_role("button", name="Check").click()
    expect(page.locator("#todoist-card [role=status]")).to_have_text("Connected to Todoist: 2 projects.")
    page.get_by_role("combobox", name="Todoist project").select_option(label="Contoso")
    expect_toast(page, "Tasks go to Contoso.")
    expect(page.get_by_role("combobox", name="Todoist project")).to_have_value("6Jf8VQXxpwv56VQ7")
    assert read_settings()["todoist_project"] == {"id": "6Jf8VQXxpwv56VQ7", "name": "Contoso"}

    (served._fake.folder / "keychain.json").write_text(json.dumps({"TODOIST_TOKEN": TOKEN, "NOTION_TOKEN": "secret_e2e_notion"}))
    reload(page)
    page.get_by_role("textbox", name="Notion to-do database").fill(f"https://www.notion.so/contoso/Tasks-{DB.replace('-', '')}?v=1")
    page.locator("#notion-tasks-card").get_by_role("button", name="Save").click()
    expect_toast(page, "Notion to-do database saved.")
    assert read_settings()["notion_tasks_database"] == DB
    page.locator("#notion-tasks-card").get_by_role("button", name="Check").click()
    expect(page.locator("#notion-tasks-card [role=status]")).to_have_text(
        "“Tasks” is ready: a step goes into Name and its due date into Due.")
