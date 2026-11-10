"""The parity corpus: the folders every parity scenario starts from (fictional people only).

A side is a directory with:

- ``Recordings/``: the four meetings of the e2e suite (A, B, C and LIVE, without a live
  pid) and D, E, E2, F, G and G2 below;
- ``config/``: its ``XDG_CONFIG_HOME``. The stores are in ``config/palaver/``, with
  ``config.toml`` (``[user] name = "Timo"``, ``[recording] output_dir``, the calendar off);
- ``home/``: its ``PALAVER_HOME`` (and ``HOME`` for Python), with ``home/Downloads/``;
- ``events.json``: the fake calendar both sides read (``Event.to_dict()`` each).

``build(side, now=...)`` is deterministic for a given ``now`` (numpy seed 3, Europe/Berlin).
"""

from __future__ import annotations

import json
import os
import time
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np
import soundfile as sf

from palaver import calendar_events, continuation, exchange, shared_mic
from palaver.attribution import Link
from palaver.calendar_events import Attendee, Event
from palaver.models import Segment, Utterance, Word
from palaver.paths import RecordingPaths
from tests.e2e.recordings import A, B, C, LIVE, ME, SR, USER, Line, _at, _tones, build_recordings, make_meeting

__all__ = ["A", "B", "C", "LIVE", "D", "E", "E2", "F", "G", "G2", "build", "base", "write_config"]

D = "2026-10-28T14-00-00"   # Northwind rollout sync: three system speakers, one sounds like Timo Strauß
E = "2026-10-22T15-00-00"   # Northwind weekly, first of the series: several people at the microphone
E2 = "2026-10-29T15-00-00"  # Northwind weekly, the next one (after the switch to winter time): unmarked
F = "2026-10-30T10-00-00"   # Contoso kickoff, imported from Valerie with two name hints
G = "2026-10-30T16-00-00"   # a recording cut by a restart ...
G2 = "2026-10-30T16-00-30"  # ... and the part that continues it

SEED = 3
DIM = 256  # the engine's voice embeddings
PROJECT = "4e6f7274"  # "Northwind rollout"
CONTOSO_TERM = "c0a7050f"
NORTHWIND_TERM = "4e0d7a1d"
SERIES = "northwind-weekly"

SELF = Attendee("Timo", "timo@kloud.example", organizer=True, response="accepted", is_self=True)
VALERIE = Attendee("Valerie", "valerie@northwind.example", response="accepted")
ROOM = Attendee("Raum 3.12", None, response="accepted", is_room=True)


def _berlin() -> None:
    """Meeting ids are local times: the corpus is Europe/Berlin's, wherever it is built."""
    if os.environ.get("TZ") != "Europe/Berlin":
        os.environ["TZ"] = "Europe/Berlin"
        time.tzset()


def _dump(path: Path, data, *, indent: int | None = 2, ensure_ascii: bool = False, newline: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=indent, ensure_ascii=ensure_ascii) + ("\n" if newline else ""))


def write_config(side: Path) -> None:
    """``config.toml`` naming this side's Recordings (it differs per side: the diff reads the
    side's own path as ``<side>``). The calendar is off: the Swift server would ask EventKit
    (this Mac's real calendar) where Python's server in the harness has none. So are the notes:
    the Swift server would start the language model's helpers (`palaver notes`, `projects`,
    `next-question`), which Python's server in the harness does not have."""
    stores = side / "config" / "palaver"
    stores.mkdir(parents=True, exist_ok=True)
    (stores / "config.toml").write_text(
        f'[user]\nname = "{USER}"\n\n[recording]\noutput_dir = {json.dumps(str(side / "Recordings"))}\n'
        '\n[calendar]\nenabled = false\n\n[notes]\nenabled = false\n')


def base(side: Path) -> None:
    """A side without meetings or stores: the folders, config.toml and an empty calendar."""
    (side / "Recordings").mkdir(parents=True, exist_ok=True)
    (side / "home" / "Downloads").mkdir(parents=True, exist_ok=True)
    write_config(side)
    if not (side / "events.json").exists():
        _dump(side / "events.json", [])


# --- voices ------------------------------------------------------------------------------


def _unit(v: np.ndarray) -> np.ndarray:
    return v / np.linalg.norm(v)


def _floats(v: np.ndarray) -> list[float]:
    """As the engine hands them over: float32 values, written as Python floats."""
    return [float(x) for x in v.astype(np.float32)]


def _voices(rng: np.random.Generator) -> dict[str, np.ndarray]:
    timo = _unit(rng.standard_normal(DIM))
    timo_again = _unit(timo + 0.6 * _unit(rng.standard_normal(DIM)))
    valerie = _unit(rng.standard_normal(DIM))
    other = rng.standard_normal(DIM)
    other = _unit(other - other.dot(timo) * timo)  # orthogonal to Timo Strauß's first sample
    return {
        "timo": timo, "timo_again": timo_again, "valerie": valerie,
        "d0": 0.8 * timo + 0.6 * other,  # cosine 0.8 to that sample
        "d1": _unit(rng.standard_normal(DIM)),
        "d2": _unit(rng.standard_normal(DIM)),
    }


def _bank(stores: Path, v: dict[str, np.ndarray]) -> None:
    """The voice bank as VoiceBank.add writes it: one file per person, no indent."""
    def sample(vec: np.ndarray, source: str, added: str) -> dict:
        return {"embedding": _floats(vec), "source": source, "added": added}

    _dump(stores / "voices" / "timo-strau.json", {"name": "Timo Strauß", "samples": [
        sample(v["timo"], "2026-10-13T10-00-00:SPEAKER_01", "2026-10-13T11:02:41+02:00"),
        sample(v["timo_again"], "2026-10-20T10-00-00:SPEAKER_00", "2026-10-20T10:58:03+02:00"),
    ]}, indent=None)
    _dump(stores / "voices" / "valerie.json", {"name": "Valerie", "samples": [
        sample(v["valerie"], "2026-10-20T10-00-00:SPEAKER_01", "2026-10-20T10:58:09+02:00"),
    ]}, indent=None)


# --- meetings ----------------------------------------------------------------------------


def _segments(lines: list[Line], *, unsure: float = 0.5) -> list[dict]:
    """Transcriber segments with words: sure ones at 0.97, the line's unsure ones at ``unsure``."""
    out = []
    for line in lines:
        words = line.text.split()
        step = (line.end - line.start) / len(words)
        out.append(Segment(line.start, line.end, line.text, None, [
            Word(w, round(line.start + i * step, 2), round(line.start + (i + 1) * step, 2),
                 unsure if w.strip(".,!?") in line.unsure else 0.97)
            for i, w in enumerate(words)
        ]).to_dict())
    return out


def _calendar(paths: RecordingPaths, event: Event) -> None:
    calendar_events.save(paths, event, Link("event", event.title, "calendar", 0.9, "time match"))


def _meeting_d(root: Path, v: dict[str, np.ndarray]) -> Event:
    start = _at(D)
    lines = [
        Line(ME, 0.0, 4.0, "Hallo zusammen, kurzer Stand zum Northwind Rollout."),
        Line("SPEAKER_00", 4.0, 14.0, "Die Migration bei KLOUD läuft, Wasti hat die Zugänge.", unsure=("KLOUD",)),
        Line("SPEAKER_01", 14.0, 24.0, "Bei Kontoso fehlt noch die Freigabe für den Rollout."),
        Line("SPEAKER_02", 24.0, 34.0, "Schöne Grüße aus Köln 🎉, die Größe passt für Übermorgen."),
        Line(ME, 34.0, 39.0, "Danke, dann machen wir Nordwind nächste Woche fertig."),
    ]
    paths = make_meeting(
        root / D, start=start, duration=40.0, title="Northwind rollout sync", lines=lines,
        summary="KLOUD migrates; the approval at Contoso is still missing.",
        decisions=["Finish the rollout next week"],
        next_steps=[{"owner": "SPEAKER_01", "task": "Get the approval from Contoso"}],
    )
    paths.mic_segments.write_text(json.dumps(_segments([line for line in lines if line.who == ME]), indent=2))
    paths.system_segments.write_text(json.dumps(_segments([line for line in lines if line.who != ME]), indent=2))
    paths.speaker_embeddings.write_text(json.dumps(
        {"SPEAKER_00": _floats(v["d0"]), "SPEAKER_01": _floats(v["d1"]), "SPEAKER_02": _floats(v["d2"])}))
    paths.language.write_text("de")
    event = Event("Northwind rollout sync", start, start + timedelta(minutes=30),
                  (SELF, VALERIE, Attendee("Anna", "anna@northwind.example"), ROOM),
                  source="Calendar", uid="northwind-rollout-sync", location="Microsoft Teams Meeting")
    _calendar(paths, event)
    return event


def _weekly(start: datetime) -> Event:
    return Event("Northwind weekly", start, start + timedelta(minutes=30),
                 (SELF, VALERIE, Attendee("Carla", "carla@northwind.example", response="tentative"), ROOM),
                 source="Calendar", uid=SERIES, series=True, location="Raum 3.12")


def _meeting_e(root: Path) -> Event:
    paths = make_meeting(
        root / E, start=_at(E), duration=30.0, title="Northwind weekly",
        lines=[
            Line(ME, 0.0, 6.0, "Willkommen zum Northwind Weekly, Vasti sitzt heute mit im Raum."),
            Line("SPEAKER_00", 6.0, 18.0, "Hallo aus Wien, wir hören euch gut."),
            Line(ME, 18.0, 28.0, "Wir sind zu dritt hier am Tisch."),
        ],
        summary="The weekly, from Raum 3.12.",
    )
    event = _weekly(_at(E))
    _calendar(paths, event)
    shared_mic.set_lane(paths, shared_mic.MIC, True, "Raum 3.12")  # several people at the microphone
    return event


def _meeting_e2(root: Path) -> Event:
    make_meeting(
        root / E2, start=_at(E2), duration=30.0, title="Northwind weekly",
        lines=[
            Line(ME, 0.0, 5.0, "Zweite Runde, heute sind alle remote."),
            Line("SPEAKER_00", 5.0, 17.0, "Die Zahlen für November kommen bis Freitag."),
            Line("SPEAKER_01", 17.0, 28.0, "Von unserer Seite passt das."),
        ],
        summary="The November numbers come on Friday.",
    )
    return _weekly(_at(E2))  # in events.json only: E2 has no calendar.json yet


def _meeting_f(root: Path) -> None:
    """Imported as exchange._write_meeting leaves it: one mixed track, labels, the record and its hints."""
    start = _at(F)
    paths = RecordingPaths(root / F)
    paths.folder.mkdir(parents=True)
    lines = [Line("SPEAKER_00", 0.0, 12.0, "Willkommen zum Contoso Kickoff, schön dass Timo dabei ist."),
             Line("SPEAKER_01", 12.0, 28.0, "Danke Valerie, ich stelle kurz den Plan vor.")]
    sf.write(str(paths.system_wav), _tones(30.0, [(line.start, line.end) for line in lines], 220), SR, subtype="PCM_16")
    paths.meta.write_text(json.dumps({"start_time": start.isoformat(), "duration_seconds": 30.0}, indent=2))
    paths.language.write_text("de")
    paths.system_turns.write_text(json.dumps(
        [{"speaker": line.who, "start": line.start, "end": line.end} for line in lines]))
    paths.transcript_json.write_text(json.dumps(
        [Utterance(line.who, line.start, line.end, line.text).to_dict() for line in lines], indent=2))
    paths.imported.write_text(json.dumps({
        "from": "Valerie", "format": exchange.FORMAT, "palaver_version": "0.5.0",
        "exported_at": "2026-10-30T10:41:12+01:00", "imported_at": "2026-10-30T10:52:40+01:00",
        "file": "Contoso kickoff.palaver", "projects": [],
        "names": {"SPEAKER_00": {"name": "Valerie", "how": "exporter"},
                  "SPEAKER_01": {"name": "Timo Strauß", "how": "hand"}},
        "voices_pending": [], "beside": None, "title": "Contoso kickoff",
    }, indent=2, ensure_ascii=False))
    paths.speakers_inferred.write_text(json.dumps(exchange.hints(paths), indent=2, ensure_ascii=False))


def _recorded(folder: Path, start: datetime, duration: float) -> RecordingPaths:
    """A recording that was never processed: the two tracks as the recorder wrote them."""
    paths = RecordingPaths(folder)
    folder.mkdir(parents=True)
    sf.write(str(paths.system_wav), _tones(duration, [(1.0, duration - 1.0)], 220), SR, subtype="PCM_16")
    sf.write(str(paths.mic_raw_wav), _tones(duration, [(0.0, 1.0)], 330), SR, subtype="PCM_16")
    paths.meta.write_text(json.dumps({"start_time": start.isoformat(), "duration_seconds": duration}, indent=2))
    return paths


def _meeting_g(root: Path) -> None:
    _recorded(root / G, _at(G), 20.0)
    _recorded(root / G2, _at(G2), 15.0)
    continuation.add_part(root / G, root / G2)


# --- stores and the calendar -------------------------------------------------------------


def _upcoming(now: datetime) -> list[Event]:
    soon, tomorrow = now + timedelta(hours=2), now + timedelta(hours=20)
    return [
        Event("Northwind rollout check-in", soon, soon + timedelta(minutes=30), (SELF, VALERIE),
              source="Calendar", uid="northwind-checkin", location="Microsoft Teams Meeting"),
        Event("Contoso planning", tomorrow, tomorrow + timedelta(hours=1),
              (SELF, Attendee("Anna", "anna@contoso.example", organizer=True, response="accepted"),
               Attendee("Carla", "carla@contoso.example")),
              source="Calendar", uid="contoso-planning"),
    ]


def _stores(stores: Path, upcoming: list[Event]) -> None:
    _dump(stores / "projects.json", {
        "projects": {PROJECT: {"name": "Northwind rollout", "description": "Rolling out the platform at Northwind.",
                               "description_by": "you"}},
        "meetings": {
            D: {"assigned": {PROJECT: {"by": "you", "why": ""}}, "rejected": []},
            E: {"assigned": {PROJECT: {"by": "auto", "why": "same people as Northwind rollout sync",
                                       "confidence": 0.72}}, "rejected": []},
        },
    })
    _dump(stores / "glossary.json", {
        "terms": {CONTOSO_TERM: {"term": "Contoso", "variants": [], "note": ""},
                  NORTHWIND_TERM: {"term": "Northwind", "variants": ["Nordwind"], "note": "the customer"}},
        "rejected": [],
    })
    _dump(stores / "organizations.json", {"names": {"northwind": "Northwind Traders"},
                                          "people": {"timo strauss": "KLOUD"}})
    _dump(stores / "attributions.json", {"events": {
        "standup-uid": {"rejected": [B], "chosen": [], "title": "Team standup"},
        SERIES: {"rejected": [], "chosen": [E], "title": "Northwind weekly"},
    }})
    _dump(stores / "settings.json", {"realtime": True, "live_processing": True, "check_updates": False},
          ensure_ascii=True, newline=True)
    soon = upcoming[0]
    _dump(stores / "prepared.json", {soon.key: {"title": soon.title, "start": soon.start.isoformat(),
                                                "projects": [PROJECT]}})


def build(side: Path, *, now: datetime) -> None:
    """The whole corpus in ``side`` (a new folder)."""
    _berlin()
    base(side)
    root, stores = side / "Recordings", side / "config" / "palaver"
    rng = np.random.default_rng(SEED)
    voices = _voices(rng)
    build_recordings(root, live_pid=None)
    events = [_meeting_e(root), _meeting_d(root, voices), _meeting_e2(root)]
    _meeting_f(root)
    _meeting_g(root)
    _bank(stores, voices)
    upcoming = _upcoming(now)
    _stores(stores, upcoming)
    _dump(side / "events.json", [e.to_dict() for e in sorted(events + upcoming, key=lambda e: e.start)])
