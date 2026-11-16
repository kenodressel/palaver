"""A meeting from before Palaver (#4): a Notion AI meeting note, as `palaver import` or Claude's import_meeting
leaves it. The list marks it "Imported", the page links its Notion page and shows one lane of unknown speakers,
without a player."""

import hashlib
import json

import pytest

from playwright.sync_api import expect  # noqa: E402

from .helpers import goto, heading, list_item  # noqa: E402

pytestmark = pytest.mark.e2e

LEGACY = "2026-03-04T10-00-00"
URL = "https://www.notion.so/example-weekly-sync-0123456789abcdef"


def write_legacy(root) -> None:
    """The files LegacyImport writes for a note of two paragraphs (the transcript's hash as Notes.transcriptHash)."""
    folder = root / LEGACY
    folder.mkdir()
    lines = [{"speaker": "SPEAKER_00", "start": 0.0, "end": 600.0, "text": "Hallo zusammen, the Northwind pricing."},
             {"speaker": "SPEAKER_00", "start": 600.0, "end": 1800.0, "text": "Valerie sends the offer."}]
    digest = hashlib.sha256("".join(f"{u['speaker']}\t{u['start']:.2f}\t{u['text']}\n" for u in lines).encode()).hexdigest()
    files = {
        "meta.json": {"start_time": "2026-03-04T10:00:00+01:00", "end_time": "2026-03-04T10:30:00+01:00",
                      "duration_seconds": 1800.0, "trigger": "import"},
        "transcript.json": lines,
        "system_turns.json": [{"speaker": u["speaker"], "start": u["start"], "end": u["end"]} for u in lines],
        "speakers_unknown.json": ["SPEAKER_00"],
        "speakers.json": {},
        "notes.json": {"title": "Weekly sync", "summary": "Topics: Pricing.",
                       "sections": [{"heading": "Pricing", "points": [{"text": "Ten percent", "details": []}]}],
                       "next_steps": [{"owner": "Valerie", "task": "send the offer"}], "decisions": [],
                       "speaker_names": [], "source": "notion", "transcript_hash": digest[:16],
                       "generated_at": "2026-11-16T10:00:00+01:00"},
        "source.json": {"kind": "notion", "url": URL, "id": "0123456789abcdef", "title": "Weekly sync",
                        "content_hash": "0" * 16, "imported_at": "2026-11-16T10:00:00+01:00"},
    }
    for name, value in files.items():
        (folder / name).write_text(json.dumps(value))


def test_an_imported_notion_note_is_marked_and_links_its_page(page, app_server):
    write_legacy(app_server.root)
    goto(page, app_server, f"#/{LEGACY}")
    expect(heading(page)).to_have_text("Weekly sync")
    expect(list_item(page, LEGACY).locator(".imported-mark")).to_have_text("Imported")
    link = page.locator("#main .when a.imported-mark")
    expect(link).to_have_text("Imported from Notion")
    expect(link).to_have_attribute("href", URL)
    expect(link).to_have_attribute("target", "_blank")
    # One lane for everyone, nothing to play; the notes are Notion's, up to date.
    expect(page.locator("#main .lane-group")).to_have_count(1)
    expect(page.locator("#main .lane-group .name-input")).to_have_attribute("placeholder", "Unknown speakers")
    expect(page.locator("#main .voice-play")).to_have_count(0)
    expect(page.locator("#player")).to_be_hidden()
    meeting = app_server.api(f"/api/meetings/{LEGACY}")
    assert meeting["notes_stale"] is False and meeting["source"]["url"] == URL
