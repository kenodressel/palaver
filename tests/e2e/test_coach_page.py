"""The coach's statistics page, "How you talk" (#43): stat tiles, charts over time, highlights and topics."""

import json
import re
from datetime import datetime, timedelta
from pathlib import Path

import pytest

from playwright.sync_api import Locator, Page, expect  # noqa: E402

from .helpers import goto, heading  # noqa: E402
from .recordings import ME, Line, make_meeting  # noqa: E402

pytestmark = pytest.mark.e2e


def pace_card(page: Page) -> Locator:
    """The card of the pace chart (not the one of filler words a minute)."""
    return page.locator("#main .stat-card").filter(has=page.locator("h3", has_text=re.compile(r"^Words a minute$")))

WORDS = ("wir schauen uns das Budget für den Pelican Umbau an und planen dann die nächsten Schritte mit dem Team "
         "weil das wichtig ist und alle mitkommen sollen").split()

# The meetings of the charts: (days before the newest, title, the others in it, seconds I talk, words I say).
COACH_MEETINGS = [
    (40, "Pelican kickoff", ["Anna", "Bob", "Carla", "Dana"], 420, 980),
    (37, "Budget 1:1", ["Dana"], 300, 640),
    (33, "Design sync", ["Dana", "Eli"], 240, 560),
    (30, "Pelican weekly", ["Anna", "Bob", "Carla"], 200, 430),
    (26, "Budget 1:1", ["Dana"], 360, 820),
    (23, "Pelican weekly", ["Anna", "Bob", "Carla"], 180, 410),
    (16, "Pelican weekly", ["Anna", "Bob", "Carla"], 260, 600),
    (12, "Design sync", ["Dana", "Eli"], 200, 470),
    (9, "Budget 1:1", ["Dana"], 280, 600),
    (2, "Pelican weekly", ["Anna", "Bob", "Carla", "Eli"], 150, 330),
]


def _said(n: int, *, filler: str = "halt") -> str:
    """`n` words of a German update, a filler word every 20."""
    out = [filler if i % 20 == 19 else WORDS[i % len(WORDS)] for i in range(n)]
    return " ".join(out) + "."


def add_coach_meetings(root: Path, newest: datetime) -> list[str]:
    """COACH_MEETINGS in `root`, the last one at `newest`; their ids, oldest first."""
    ids = []
    for days, title, others, mine, words in COACH_MEETINGS:
        start = (newest - timedelta(days=days)).replace(hour=14, minute=0, second=0, microsecond=0)
        lines = [Line(ME, 0.0, float(mine), _said(words))]
        at = float(mine)
        for i, _ in enumerate(others):
            lines.append(Line(f"SPEAKER_{i:02d}", at + 1, at + 61, "Das Budget für Pelican sieht gut aus, wir machen weiter."))
            at += 62
        lines.append(Line(ME, at + 1, at + 6, "Was braucht ihr noch von mir?"))
        mid = start.strftime("%Y-%m-%dT%H-%M-%S")
        paths = make_meeting(root / mid, start=start.astimezone(), lines=lines, duration=10.0, title=title,
                             names={f"SPEAKER_{i:02d}": n for i, n in enumerate(others)})
        # The audio is a stand-in of 10 s; the meeting is as long as what was said.
        paths.meta.write_text(json.dumps({"start_time": start.astimezone().isoformat(), "duration_seconds": at + 60}))
        ids.append(mid)
    return ids


@pytest.fixture
def coach_server(app_server):
    ids = add_coach_meetings(app_server.root, datetime.now() - timedelta(days=1))
    app_server.api("/api/glossary/accept", {"term": "Pelican", "variants": []})
    pid = next(p["id"] for p in app_server.api("/api/projects", {"name": "Harbor"})["projects"])
    for mid in ids[:3]:
        app_server.api(f"/api/meetings/{mid}/projects", {"project": pid})
    weekly = [mid for mid, m in zip(ids, COACH_MEETINGS) if m[1] == "Pelican weekly"]
    sid = app_server.api(f"/api/meetings/{weekly[0]}/series", {"name": "Pelican weekly"})["series"]["id"]
    for mid in weekly[1:]:
        app_server.api(f"/api/meetings/{mid}/series", {"series": sid})
    return app_server


def test_the_coach_page_shows_tiles_and_charts(page, coach_server):
    goto(page, coach_server, "#/coach")
    expect(heading(page)).to_have_text("How you talk")
    tiles = page.locator("#main .stat-tile")
    expect(tiles).to_have_count(6)
    expect(tiles.first.locator(".stat-value")).to_have_text("13")  # the suite's three and these ten
    expect(page.locator("#main .stat-tile", has_text="Week streak").locator(".stat-value")).not_to_have_text("0")
    # Talk share by size: 1:1s, 3 and 5 or more people (the suite's own meetings add 2 and 3 people).
    sizes = page.locator("#main .size-meters li .size-name")
    expect(sizes).to_have_text(["1:1s", "3 people", "4 people", "5 or more"])
    # Five charts over time, each with a dot per meeting where the measure is known.
    charts = page.locator("#main .time-chart svg")
    expect(charts).to_have_count(5)
    expect(pace_card(page).locator(".chart-dot")).to_have_count(10)
    expect(pace_card(page).locator(".chart-ref-label")).to_contain_text("your usual")
    # Records and topics: the series and the project, the glossary term, by month.
    records = page.locator("#main .stat-card", has_text="Records")
    expect(records).to_contain_text("Fastest pace")
    expect(records).to_contain_text("Longest monologue")
    topics = page.locator("#main .heat-grid", has_text="Meetings per project or series")
    expect(topics.locator("th[scope=row]")).to_have_text(["Pelican weekly", "Harbor"])
    terms = page.locator("#main .heat-grid", has_text="Glossary terms said")
    expect(terms.locator("th[scope=row]")).to_have_text(["Pelican"])
    expect(page.locator("#main .people-bars li").first).to_contain_text("Dana")
    # The per-meeting table stays below the charts.
    expect(page.locator("#main .coach-overview > .coach-table tbody tr")).to_have_count(13)


def test_a_coach_chart_shows_a_meeting_on_hover_and_opens_it(page, coach_server):
    goto(page, coach_server, "#/coach")
    chart = pace_card(page).locator("svg")
    expect(chart).to_be_visible()
    chart.scroll_into_view_if_needed()
    box = chart.locator(".chart-dot").last.bounding_box()  # the newest
    page.mouse.move(box["x"] + box["width"] / 2, box["y"] + box["height"] / 2)
    tip = pace_card(page).locator(".chart-tip")
    expect(tip).to_be_visible()
    expect(tip).to_contain_text("words a minute")
    expect(tip).to_contain_text("Pelican weekly")
    page.mouse.click(box["x"] + box["width"] / 2, box["y"] + box["height"] / 2)
    expect(heading(page)).to_have_text("Pelican weekly")
    expect(page.get_by_role("tab", name="Coach")).to_have_attribute("aria-selected", "true")


def test_a_coach_chart_goes_through_the_meetings_by_keyboard(page, coach_server):
    goto(page, coach_server, "#/coach")
    chart = pace_card(page).locator("svg")
    chart.focus()
    page.keyboard.press("ArrowLeft")  # the newest first
    tip = pace_card(page).locator(".chart-tip")
    expect(tip).to_contain_text("Pelican weekly")
    page.keyboard.press("ArrowLeft")
    expect(tip).to_contain_text("Budget 1:1")
    page.keyboard.press("Enter")
    expect(heading(page)).to_have_text("Budget 1:1")
