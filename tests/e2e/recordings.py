"""Synthetic recordings for the end-to-end tests: quiet tones in place of
voices, a transcript, speaker turns and notes. Never the user's meetings.

``build_recordings(root)`` makes the four meetings every E2E test starts
from (see ``A``, ``B``, ``C``, ``LIVE``).
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np
import soundfile as sf

from palaver import notes as notes_mod
from palaver.models import Utterance
from palaver.paths import RecordingPaths

SR = 16_000
USER = "Timo"
ME = "me"  # a line the user said (the mic track)

# The four meetings, oldest first. B and C are back to back (join, split onto the next).
A = "2026-10-27T09-00-00"     # Team standup: Anna named, Speaker 2 unnamed, Speaker 3 inferred "Carla"
B = "2026-10-27T10-00-00"     # Design review
C = "2026-10-27T10-00-45"     # Design review, part two (starts 5 s after B ends)
LIVE = "2026-10-27T11-00-00"  # being recorded: live.json and a growing .part file

TITLES = {A: "Team standup", B: "Design review", C: "Design review, part two"}


@dataclass(frozen=True)
class Line:
    who: str  # ME, or a diarization label such as "SPEAKER_00"
    start: float
    end: float
    text: str
    unsure: tuple[str, ...] = ()


def _tones(seconds: float, spans: list[tuple[float, float]], hz: float) -> np.ndarray:
    """A quiet tone wherever someone speaks, silence elsewhere."""
    n = int(round(seconds * SR))
    out = np.zeros(n, dtype=np.int16)
    for a, b in spans:
        i, j = int(a * SR), min(n, int(b * SR))
        t = np.arange(j - i) / SR
        out[i:j] = (300 * np.sin(2 * np.pi * hz * t)).astype(np.int16)
    return out


def make_meeting(folder: Path, *, start: datetime, lines: list[Line], duration: float,
                 names: dict[str, str] | None = None, title: str | None = None, notes: bool = True,
                 summary: str = "", decisions: list[str] = (), next_steps: list[dict] = (),
                 guesses: list[dict] = (), inferred: dict[str, dict] | None = None,
                 event: dict | None = None) -> RecordingPaths:
    """A finished, transcribed recording in ``folder``. ``names``: labels
    named by hand; ``guesses``: names the notes found ({label, name,
    evidence}); ``inferred``: label → {name, rule, why, confidence};
    ``event``: the calendar event stored with it."""
    paths = RecordingPaths(folder)
    folder.mkdir(parents=True)
    sf.write(str(paths.system_wav), _tones(duration, [(l.start, l.end) for l in lines if l.who != ME], 220),
             SR, subtype="PCM_16")
    sf.write(str(paths.mic_wav), _tones(duration, [(l.start, l.end) for l in lines if l.who == ME], 330),
             SR, subtype="PCM_16")
    paths.meta.write_text(json.dumps({"start_time": start.isoformat(), "duration_seconds": duration}))
    paths.system_turns.write_text(json.dumps(
        [{"speaker": l.who, "start": l.start, "end": l.end} for l in lines if l.who != ME]))
    utterances = [Utterance(USER if l.who == ME else l.who, l.start, l.end, l.text, unsure=l.unsure) for l in lines]
    paths.transcript_json.write_text(json.dumps([u.to_dict() for u in utterances]))
    if names:
        paths.speakers.write_text(json.dumps(names))
    if inferred:
        paths.speakers_inferred.write_text(json.dumps(inferred))
    if event:
        paths.calendar.write_text(json.dumps(event))
    if notes:
        notes_mod.save(paths, {
            "title": title or "Meeting",
            "summary": summary or f"What was said in {title or 'the meeting'}.",
            "sections": [{"heading": "Updates", "points": [{"text": "Everyone gave an update", "details": []}]}],
            "next_steps": list(next_steps),
            "decisions": list(decisions),
            "speaker_names": list(guesses),
            "transcript_hash": notes_mod.transcript_hash(utterances),
        })
    return paths


def live_part(folder: Path) -> Path:
    """The recording's system track while it is being written (SwiftServed keeps it written to)."""
    return Path(str(RecordingPaths(folder).system_wav) + ".part")


def make_live(folder: Path, *, start: datetime, pid: int | None) -> RecordingPaths:
    """A meeting being recorded: what the live worker has so far (live.json),
    a .part file, and a live worker that is "running" (``pid``; None: no
    live.pid, as in the parity corpus)."""
    paths = RecordingPaths(folder)
    folder.mkdir(parents=True)
    live_part(folder).write_bytes(b"\0" * 100)
    paths.meta.write_text(json.dumps({"start_time": start.isoformat()}))
    if pid is not None:
        (folder / "live.pid").write_text(str(pid))
    seg = lambda t, text, who=None: {"start": t, "end": t + 2, "text": text, "speaker": who, "words": []}
    paths.live.write_text(json.dumps({
        "until": 60.0,
        "mic": [seg(0.0, "Hallo zusammen, schön dass ihr da seid.", USER)],
        "system": [seg(3.0, "Hi Timo, wir starten mit dem Budget."), seg(20.0, "Ja, das passt für uns.")],
        "turns": [{"speaker": "SPEAKER_00", "start": 3.0, "end": 15.0},
                  {"speaker": "SPEAKER_01", "start": 18.0, "end": 30.0}],
    }))
    return paths


def write_stream(paths: RecordingPaths) -> None:
    """The realtime stream's newest lines, beyond what live.json has (fresh: it goes stale in 10 s)."""
    import time

    seg = lambda t, text: {"start": t, "end": t + 2, "text": text, "speaker": None, "settled_at": t + 3}
    paths.stream.write_text(json.dumps({
        "until": 75.0,
        "system": [seg(70.0, "Die Zahlen kommen morgen.")],
        "mic": [],
        "draft": {"system": "und dann noch", "mic": ""},
        "speaking": {"others": True, "me": False},
        "updated_at": time.time(),
    }))


def _at(stamp: str) -> datetime:
    return datetime.strptime(stamp, "%Y-%m-%dT%H-%M-%S").astimezone()


def build_recordings(root: Path, live_pid: int | None) -> dict[str, RecordingPaths]:
    """The four meetings of the E2E suite, in ``root``. ``live_pid`` is the live
    worker of the meeting being recorded: a process that is running; None
    writes no live.pid (the parity corpus, tools/parity/corpus.py)."""
    root.mkdir(parents=True, exist_ok=True)
    a_start = _at(A)
    out = {
        A: make_meeting(
            root / A, start=a_start, duration=40.0, title="Daily standup",
            lines=[
                Line(ME, 0.0, 4.0, "Good morning, let us start the standup."),
                Line("SPEAKER_00", 4.0, 15.0, "Morning. I finished the Atterkring migration, over to you Bob.",
                     unsure=("Atterkring",)),
                Line("SPEAKER_01", 15.0, 27.0, "Thanks Anna. The pelican deploy is still blocked."),
                Line("SPEAKER_02", 27.0, 38.0, "I can take that review after lunch."),
                Line(ME, 38.0, 39.5, "Great, thanks everyone."),
            ],
            names={"SPEAKER_00": "Anna"},
            summary="SPEAKER_00 finished the migration; the pelican deploy is blocked.",
            decisions=["Carla reviews the deploy after lunch"],
            next_steps=[{"owner": "SPEAKER_02", "task": "Review the pelican deploy"}],
            guesses=[{"label": "SPEAKER_01", "name": "Bob", "evidence": "over to you Bob"}],
            inferred={"SPEAKER_02": {"name": "Carla", "rule": "elimination", "why": "the one invitee left",
                                     "confidence": 0.8}},
            event={"title": "Team standup", "start": a_start.isoformat(),
                   "end": (a_start + timedelta(minutes=15)).isoformat(), "attendees": [], "uid": "standup-uid"},
        ),
        B: make_meeting(
            root / B, start=_at(B), duration=40.0, title="Design review",
            lines=[
                Line(ME, 0.0, 5.0, "Welcome to the design review."),
                Line("SPEAKER_00", 5.0, 20.0, "The new onboarding flow is ready for feedback."),
                Line("SPEAKER_01", 20.0, 38.0, "I like the flow, but the colours need work."),
                Line(ME, 38.0, 39.5, "Let us continue after the break."),
            ],
            names={"SPEAKER_00": "Dana", "SPEAKER_01": "Eli"},
            summary="Dana showed the onboarding flow; Eli wants other colours.",
            decisions=["Rework the colours"],
        ),
        C: make_meeting(
            root / C, start=_at(C), duration=30.0, title="Design review, part two",
            lines=[
                Line("SPEAKER_00", 0.5, 14.0, "Back from the break, about those colours."),
                Line(ME, 14.0, 28.0, "Agreed, we use the darker palette."),
            ],
            names={"SPEAKER_00": "Dana"},
            summary="The darker palette it is.",
        ),
        LIVE: make_live(root / LIVE, start=_at(LIVE), pid=live_pid),
    }
    return out
