"""Tests for Markdown rendering."""

from datetime import datetime

import pytest

from palaver.models import Utterance
from palaver.render import format_duration, render_markdown


def test_renders_header_with_metadata():
    utt = [Utterance("Timo", 0.0, 2.0, "hallo")]
    md = render_markdown(
        utterances=utt,
        session_start=datetime(2026, 4, 17, 14, 30),
        duration_seconds=120,
    )
    assert "2026-04-17 14:30" in md
    assert "2 min" in md
    assert "1 speaker" in md


def test_renders_plural_speakers():
    utt = [
        Utterance("Timo", 0.0, 1.0, "hi"),
        Utterance("SPEAKER_00", 1.0, 2.0, "hello"),
        Utterance("SPEAKER_01", 2.0, 3.0, "hey"),
    ]
    md = render_markdown(
        utterances=utt,
        session_start=datetime(2026, 4, 17, 14, 30),
        duration_seconds=60,
    )
    assert "3 speakers" in md


def test_renders_utterances_sorted_by_start():
    utt = [
        Utterance("Timo", 90.0, 95.0, "dritte zeile"),
        Utterance("SPEAKER_00", 30.0, 40.0, "zweite zeile"),
        Utterance("Timo", 0.0, 10.0, "erste zeile"),
    ]
    md = render_markdown(
        utterances=utt,
        session_start=datetime(2026, 4, 17, 14, 30),
        duration_seconds=100,
    )
    # Render sorts by start; caller can hand us unsorted input.
    assert md.index("erste zeile") < md.index("zweite zeile") < md.index("dritte zeile")
    assert "**Timo**" in md
    assert "**SPEAKER_00**" in md


def test_timestamp_format_relative():
    utt = [Utterance("Timo", 125.0, 130.0, "hallo")]
    md = render_markdown(
        utterances=utt,
        session_start=datetime(2026, 4, 17, 14, 30, 0),
        duration_seconds=200,
    )
    # Expect wall-clock format "14:32:05" (session start + 125s)
    assert "[14:32:05]" in md


def test_renders_empty_utterance_list():
    md = render_markdown(
        utterances=[],
        session_start=datetime(2026, 4, 17, 14, 30),
        duration_seconds=60,
    )
    # Header still renders; body is empty but doesn't crash.
    assert "2026-04-17 14:30" in md
    assert "0 speakers" in md
    assert md.endswith("\n")


@pytest.mark.parametrize(
    "seconds,expected",
    [
        (0, "0 min"),
        (59, "0 min"),       # rounds down to 0 min
        (60, "1 min"),
        (119, "1 min"),      # 1:59 → 1 min
        (3599, "59 min"),    # just under an hour
        (3600, "1h 0min"),
        (3660, "1h 1min"),
        (7260, "2h 1min"),
    ],
)
def test_format_duration(seconds, expected):
    assert format_duration(seconds) == expected


def test_build_meeting_title_is_shared_by_markdown_header():
    from datetime import datetime

    from palaver.models import Utterance
    from palaver.render import build_meeting_title, render_markdown

    start = datetime(2026, 10, 20, 14, 35)
    assert build_meeting_title(start, 1446.7, 4) == "2026-10-20 14:35 — Meeting (24 min, 4 speakers)"
    assert build_meeting_title(start, 3900, 1) == "2026-10-20 14:35 — Meeting (1h 5min, 1 speaker)"
    md = render_markdown([Utterance("Timo", 0.0, 1.0, "Hi")], start, 60.0)
    assert md.splitlines()[0] == "# " + build_meeting_title(start, 60.0, 1)


def test_markdown_is_clean_verbatim():
    utt = [
        Utterance("Anna", 0.0, 2.0, "Um, so we, uh, need a plan."),
        Utterance("Timo", 2.0, 2.5, "Mm-hmm."),
    ]
    md = render_markdown(utterances=utt, session_start=datetime(2026, 4, 17, 14, 30), duration_seconds=60)
    assert "So we need a plan." in md
    assert "Mm-hmm" not in md and "1 speaker" in md


def test_a_pause_in_the_recording_shows_where_it_was():
    utt = [Utterance("Timo", 400.0, 410.0, "vor dem neustart"), Utterance("Anna", 430.0, 440.0, "danach")]
    start = datetime.fromisoformat("2026-10-29T12:06:10+01:00")
    md = render_markdown(utt, start, 600, gaps=[{"start": 415.0, "end": 424.0, "why": "restart"}])
    before, after = md.index("vor dem neustart"), md.index("danach")
    pause = md.index("*Recording paused 12:13:05–12:13:14 (Palaver restarted)*")
    assert before < pause < after
