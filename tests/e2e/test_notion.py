"""#34: where Notion uploads go, and each uploaded meeting's Notion page. palaver-server against a stub Notion API
(stub_notion.py) with its token and a parent page in config.toml: Settings → Notion names the workspace and the page,
the ⋯ menu uploads a meeting (and again) and opens its page, and a meeting uploaded before the target changed says it
is in the earlier one. Links open through the server ($PALAVER_TEST_OPENED): nothing opens on this Mac."""

from __future__ import annotations

import json
import time

import pytest

from playwright.sync_api import expect  # noqa: E402

from .conftest import _serve  # noqa: E402
from .helpers import expect_toast, goto, more, open_meeting  # noqa: E402
from .recordings import A  # noqa: E402
from .stub_notion import OTHER, PARENT, PARENT_URL, TOKEN, WORKSPACE, StubNotion  # noqa: E402

pytestmark = pytest.mark.e2e


@pytest.fixture
def notion(tmp_path):
    """The window's server with Notion set up: the stub's token, its parent page, no automatic upload."""
    stub = StubNotion()
    srv, served = _serve(tmp_path / "Recordings", env={"PALAVER_TEST_NOTION_API": stub.url, "NOTION_TOKEN": TOKEN},
                         config_extra=f'\n[notion]\nparent_page_id = "{PARENT}"\nauto_sync = false\n')
    yield served, stub
    served.close()
    stub.close()


def item(page, name: str):
    return page.locator(".menu").get_by_role("menuitem", name=name, exact=True)


def test_settings_name_the_workspace_and_page_uploads_go_to(page, notion):
    served, stub = notion
    goto(page, served, "#/settings/notion")
    section = page.locator("#notion-section")
    expect(section.locator(".notion-target")).to_have_text(
        f"Uploads go to {WORKSPACE} → Meetings (a page under this page)")
    expect(section).to_contain_text("only when you choose Upload to Notion")
    section.get_by_role("button", name="Open in Notion").click()
    assert _eventually(lambda: served.opened == [PARENT_URL])
    assert all(method == "GET" for method, _, _ in stub.requests)  # looking never uploads


def test_settings_say_when_notion_is_not_set_up(page, shared_server):
    goto(page, shared_server, "#/settings/notion")
    expect(page.locator("#notion-section")).to_contain_text("Notion isn't set up: meetings stay on this Mac.")


def test_a_meeting_uploaded_from_its_menu_links_its_page(page, notion):
    served, stub = notion
    open_meeting(page, served, A)
    expect(page.locator("#main .notion-link")).to_have_count(0)
    more(page).click()
    expect(item(page, "Open in Notion")).to_have_count(0)
    item(page, "Upload to Notion").click()
    expect_toast(page, "Uploaded to Notion.")
    assert stub.created[0]["parent"] == {"page_id": PARENT}
    info = json.loads((served.root / A / "notion.json").read_text())
    assert info["page_url"] == stub.page_url(1) and info["target_id"] == PARENT and info["mode"] == "page"
    link = page.locator("#main .notion-link")
    expect(link).to_have_text("In Notion")
    link.click()
    assert _eventually(lambda: served.opened == [stub.page_url(1)])
    more(page).click()
    item(page, "Open in Notion").click()
    assert _eventually(lambda: served.opened == [stub.page_url(1)] * 2)
    more(page).click()
    item(page, "Upload to Notion Again").click()
    expect_toast(page, "Uploaded to Notion again. The earlier page stays in Notion until you remove it there.")
    assert len(stub.created) == 2
    assert json.loads((served.root / A / "notion.json").read_text())["page_url"] == stub.page_url(2)


def test_a_changed_target_leaves_the_meeting_where_it_went(page, notion):
    """Uploaded to another page before the target changed: it says so, and stays there until uploaded again. A meeting
    kept on this Mac is not offered for upload."""
    served, stub = notion
    (served.root / A / "notion.json").write_text(json.dumps({
        "page_url": "https://www.notion.so/Northwind-Team-standup-0123", "uploaded_at": "2026-10-27T10:00:00.000000",
        "target_id": OTHER, "mode": "page", "workspace": "Northwind"}))
    open_meeting(page, served, A)
    link = page.locator("#main .notion-link")
    expect(link).to_have_text("In Notion (earlier target)")
    expect(link).to_have_attribute("title", "Uploaded in Northwind to where uploads went before; it stays there. "
                                   "Settings → Notion shows where they go now.")
    more(page).click()
    item(page, "Keep on This Mac").click()
    expect(page.locator("#main .pill.local-only")).to_be_visible()
    more(page).click()
    expect(item(page, "Open in Notion")).to_be_visible()  # the page uploaded before is still there
    expect(item(page, "Upload to Notion Again")).to_have_count(0)
    assert not stub.created


def _eventually(check, timeout: float = 5.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return True
        time.sleep(0.05)
    return check()
