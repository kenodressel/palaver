"""Render a transcript to Markdown."""

from __future__ import annotations

from datetime import datetime, timedelta

from .models import Utterance
from .readable import readable


def render_markdown(
    utterances: list[Utterance],
    session_start: datetime,
    duration_seconds: float,
    gaps: list[dict] | None = None,
) -> str:
    """``gaps``: stretches nothing was recorded (meta.json, see lifecycle);
    each shows as a line where it was."""
    from .lifecycle import gap_text

    utterances = readable(utterances)
    n_speakers = len({u.speaker for u in utterances})
    lines = [f"# {build_meeting_title(session_start, duration_seconds, n_speakers)}", ""]
    pending = sorted(gaps or [], key=lambda g: g["start"])

    for u in sorted(utterances, key=lambda x: x.start):
        while pending and pending[0]["start"] <= u.start:
            lines += [f"*{gap_text(pending.pop(0), session_start)}*", ""]
        when = session_start + timedelta(seconds=u.start)
        wall = when.strftime("%H:%M:%S")
        lines.append(f"**{u.speaker}** [{wall}]  {u.text}")
        lines.append("")
    for gap in pending:
        lines += [f"*{gap_text(gap, session_start)}*", ""]

    return "\n".join(lines).rstrip() + "\n"


def build_meeting_title(
    session_start: datetime, duration_seconds: float, n_speakers: int
) -> str:
    """Title shared by the Markdown header and the Notion page."""
    speaker_word = "speaker" if n_speakers == 1 else "speakers"
    return (
        f"{session_start.strftime('%Y-%m-%d %H:%M')} — Meeting "
        f"({format_duration(duration_seconds)}, {n_speakers} {speaker_word})"
    )


def format_duration(seconds: float) -> str:
    total = int(round(seconds))
    hours, rem = divmod(total, 3600)
    minutes, _ = divmod(rem, 60)
    if hours:
        return f"{hours}h {minutes}min"
    return f"{minutes} min"
