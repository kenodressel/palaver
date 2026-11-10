"""Settings → Claude access: adding Palaver's MCP server to Claude Code and Claude Desktop.

The window's server adds it itself (phase 4: no Python helper): Claude Code through the
`claude` command (fake_claude.py, first on the server's PATH), Claude Desktop through its
config file in the test's own home. Both start the Swift `palaver mcp` with the app's
options (`--config`).
"""

import json

import pytest

from playwright.sync_api import expect  # noqa: E402

from .helpers import goto, toast  # noqa: E402

pytestmark = pytest.mark.e2e


def test_the_claude_access_pane_adds_palaver_to_claude_code_and_desktop(page, app_server):
    app_server.claude_desktop_app.mkdir(parents=True)  # Claude Desktop is installed: its row shows
    goto(page, app_server, "#/settings/mcp")
    section = page.locator("#mcp-section")
    expect(section).to_contain_text("Claude Code does not know Palaver's MCP server yet.")

    section.get_by_role("button", name="Add to Claude Code").click()
    expect(toast(page)).to_contain_text("Added to Claude Code")
    expect(section).to_contain_text("Claude Code starts Palaver's MCP server (“meetings”, all projects).")
    [args] = app_server.claude_calls
    assert args[:6] == ["mcp", "add", "--scope", "user", "meetings", "--"]
    assert args[6].endswith("/palaver-cli") and args[7] == "--config" and args[-1] == "mcp"

    section.get_by_role("button", name="Add to Claude Desktop").click()
    expect(toast(page)).to_contain_text("Added to Claude Desktop")
    expect(section).to_contain_text("Claude Desktop starts Palaver's MCP server (“meetings”).")
    entry = json.loads(app_server.claude_desktop_config.read_text())["mcpServers"]["meetings"]
    assert entry == {"command": args[6], "args": args[7:]}
    assert app_server.mcp_installs == ["code", "desktop"]


def test_a_broken_claude_desktop_config_is_left_alone_and_said(page, app_server):
    app_server.claude_desktop_app.mkdir(parents=True)
    config = app_server.claude_desktop_config
    config.parent.mkdir(parents=True)
    config.write_text("{not json")
    goto(page, app_server, "#/settings/mcp")
    page.guard.allow(r"status of 500")  # the server's refusal, said in the toast
    page.locator("#mcp-section").get_by_role("button", name="Add to Claude Desktop").click()
    expect(toast(page)).to_contain_text("Not added to Claude Desktop")
    expect(toast(page)).to_contain_text("is not valid JSON; not changed")
    assert config.read_text() == "{not json"
