"""While the window's server restarts (#57) the page says so, quietly:
"Reconnecting…" after 2 s without an answer, gone once it answers."""

import re

import pytest

from playwright.sync_api import expect  # noqa: E402

from .helpers import goto, heading  # noqa: E402
from .recordings import A  # noqa: E402

pytestmark = pytest.mark.e2e

PING = re.compile(r"/api/ping$")


def test_reconnecting_shows_while_the_server_does_not_answer(page, shared_server):
    goto(page, shared_server, f"#/{A}")
    expect(heading(page)).to_have_text("Team standup")
    line = page.locator("#reconnecting")
    expect(line).to_be_hidden()
    held = []
    page.route(PING, lambda route: held.append(route))
    expect(line).to_be_visible(timeout=10_000)
    expect(line).to_have_text("Reconnecting…")
    expect(line).to_have_attribute("role", "status")
    assert "error" not in (line.get_attribute("class") or "")
    page.unroute(PING)  # the server answers again: the next ping goes through
    for route in held:
        try:
            route.continue_()
        except Exception:  # unroute already let it through
            pass
    expect(line).to_be_hidden(timeout=10_000)
