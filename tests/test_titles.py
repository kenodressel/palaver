"""Tests for a meeting's title: the user's own, the event's, the notes'."""

import json
from datetime import datetime, timedelta
from pathlib import Path

import pytest

from palaver import calendar_events, glossary, notes, titles
from palaver.paths import RecordingPaths

START = datetime.fromisoformat("2026-10-27T12:04:00+01:00")


def _folder(tmp_path: Path, *, event: str | None = None, notes_title: str | None = None) -> RecordingPaths:
    paths = RecordingPaths(tmp_path / "2026-10-27T12-04-00")
    paths.folder.mkdir()
    if event is not None:
        calendar_events.save(paths, calendar_events.Event(event, START, START + timedelta(minutes=30)))
    if notes_title is not None:
        notes.save(paths, {"title": notes_title, "summary": "", "sections": [], "next_steps": [], "decisions": []})
    return paths


def test_the_users_title_wins_over_the_event_and_the_notes(tmp_path):
    paths = _folder(tmp_path, event="Weekly sync", notes_title="Budget talk")
    titles.save(paths, "Budget with Anna")
    assert titles.resolve(paths) == ("Budget with Anna", "you")


def test_the_event_comes_before_the_notes(tmp_path):
    assert titles.resolve(_folder(tmp_path, event="Weekly sync", notes_title="Budget talk")) == ("Weekly sync", "calendar")


def test_the_notes_title_is_spelled_as_the_glossary_says(tmp_path):
    g = glossary.Glossary()
    g.add("Atterkring", variants=["Atterkrink"])
    g.save()
    assert titles.resolve(_folder(tmp_path, notes_title="Atterkrink rollout")) == ("Atterkring rollout", "notes")


def test_without_any_title_there_is_none(tmp_path):
    assert titles.resolve(_folder(tmp_path)) == (None, None)


def test_saving_an_empty_title_gives_it_back_to_the_event(tmp_path):
    paths = _folder(tmp_path, event="Weekly sync")
    titles.save(paths, "Mine")
    titles.save(paths, "")
    assert not paths.title.exists()
    assert titles.resolve(paths) == ("Weekly sync", "calendar")


def test_what_is_known_already_is_not_read_again(tmp_path):
    paths = _folder(tmp_path, event="Weekly sync", notes_title="Budget talk")
    assert titles.resolve(paths, event=None, meeting_notes=None) == (None, None)
    assert titles.resolve(paths, event=None) == ("Budget talk", "notes")


def test_a_broken_title_file_is_no_title(tmp_path):
    paths = _folder(tmp_path, event="Weekly sync")
    paths.title.write_text("{not json")
    assert titles.load(paths) is None
    paths.title.write_text(json.dumps({"title": 42}))
    assert titles.resolve(paths) == ("Weekly sync", "calendar")


def test_a_title_is_cleaned_and_capped():
    assert titles.clean("  Budget\n with  Anna \t") == "Budget with Anna"
    assert titles.clean("x" * 250) == "x" * titles.MAX_LENGTH
    assert titles.clean("   ") == ""
    with pytest.raises(ValueError):
        titles.clean(None)
    with pytest.raises(ValueError):
        titles.clean(["Budget"])


def test_the_fallback_says_when_the_meeting_started():
    start = START.astimezone()  # shown on this Mac's clock
    assert titles.fallback(START.isoformat()) == f"Meeting at {start:%H:%M}"
    assert titles.fallback(None) == "Meeting"
