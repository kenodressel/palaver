"""What the E2E tests do on the page, by what the user sees."""

from __future__ import annotations

import re

from playwright.sync_api import Locator, Page, expect

from .recordings import TITLES

expect.set_options(timeout=8_000)


def goto(page: Page, served, where: str = "") -> None:
    """Load the window at ``where`` (a hash like "#/people") and wait until it shows something."""
    page.goto(served.url + where)
    expect(page.locator("#main > *").first).to_be_visible()
    page.locator("#list .item").first.wait_for(state="attached")  # the list is hidden beside People etc.


def open_meeting(page: Page, served, mid: str, tab: str | None = None) -> None:
    goto(page, served, f"#/{mid}")
    expect(page.locator("#main h1")).to_have_text(TITLES[mid])
    if tab:
        show_tab(page, tab)


def show_tab(page: Page, name: str) -> None:
    page.get_by_role("tab", name=name).click()
    expect(page.get_by_role("tab", name=name)).to_have_attribute("aria-selected", "true")


def heading(page: Page) -> Locator:
    return page.locator("#main h1")


def list_item(page: Page, mid: str) -> Locator:
    return page.locator(f'#list .item[data-id="{mid}"]')


def list_ids(page: Page) -> list[str]:
    return page.locator("#list .item[data-id]").evaluate_all("els => els.map((e) => e.dataset.id)")


def toast(page: Page) -> Locator:
    return page.locator("#toasts .toast:not(.gone)")


def expect_toast(page: Page, text: str | re.Pattern) -> Locator:
    t = toast(page)
    expect(t.locator(".toast-text")).to_have_text(text)
    return t


def undo_in_toast(page: Page) -> None:
    toast(page).get_by_role("button", name="Undo").click()
    expect(toast(page).locator(".toast-text")).to_have_text("Undone")


def menu_item(page: Page, name: str) -> Locator:
    return page.locator(".menu").get_by_role("menuitem", name=name)


def more(page: Page, label: str = "More actions") -> Locator:
    """A ⋯ button, by its label ("More actions", "Actions for Speaker 2", …)."""
    return page.locator("#main").get_by_role("button", name=label, exact=True)


def run_from_menu(page: Page, label: str, item: str) -> None:
    more(page, label).click()
    menu_item(page, item).click()


def lane(page: Page, label: str) -> Locator:
    return page.locator(f'#main .lane-group[data-label="{label}"]')


def line(page: Page, start: float) -> Locator:
    return page.locator(f'#main .turn[data-start="{start:g}"]')


def line_tool(page: Page, start: float, name: str) -> Locator:
    """A button in a transcript line's toolbar, shown when the pointer comes by."""
    row = line(page, start)
    row.hover()
    return row.locator(f'.line-tool[data-name="{name}"]')


def about(page: Page) -> Locator:
    """"About this recording", folded away at the bottom of the meeting."""
    return page.locator("#main details.about")


def about_line(page: Page, kind: str) -> Locator:
    """A line of About this recording: recorded, event, transcribed, audio, imported."""
    return about(page).locator(f".about-{kind}")


def speakers_in_transcript(page: Page) -> list[str]:
    """Who said each line, as the transcript shows it (the name is on a speaker's first line)."""
    return page.locator("#main .transcript .turn").evaluate_all("""rows => {
      let who = null;
      return rows.map((r) => (who = r.querySelector('.speaker')?.firstChild?.textContent ?? who));
    }""")


def unfocus(page: Page) -> None:
    """Focus off any field, so ⌘ keys go to the app."""
    page.evaluate("document.activeElement?.blur()")


def cmd(page: Page, key: str) -> None:
    page.keyboard.press(f"Meta+{key}")


def audio(page: Page) -> dict:
    return page.evaluate("(() => { const a = document.getElementById('audio');"
                         " return {time: a.currentTime, paused: a.paused, muted: a.muted}; })()")


def hash_of(page: Page) -> str:
    return page.evaluate("location.hash")
