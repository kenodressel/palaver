"""Meeting prep (#31): a meeting before it happens, from the calendar.

Upcoming events are listed with suggestions for their project (the same
rules as for recordings, from title, invitees and customer domain; a
recurring event goes where its earlier occurrences went) and context: the
last meeting with the same people or in the same series, with its summary
and open next steps. A project chosen ahead of time is kept here and given
to the recording once it is matched to the event (``apply``).
"""

from __future__ import annotations

import json
import re
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

from . import calendar_events, glossary, notes, projects
from ._xdg import xdg_config_home
from .paths import RecordingPaths

AHEAD = timedelta(hours=36)
CONTEXT_MEETINGS = 2


def _path() -> Path:
    return xdg_config_home() / "palaver" / "prepared.json"


def _load() -> dict[str, dict[str, Any]]:
    try:
        return json.loads(_path().read_text())
    except (OSError, ValueError):
        return {}


def _save(data: dict[str, dict[str, Any]]) -> None:
    path = _path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    tmp.replace(path)


def upcoming(provider: calendar_events.Provider, now: datetime) -> list[calendar_events.Event]:
    """Meetings still to come (or running) in the next day and a half: events
    with someone else invited."""
    return sorted(
        (e for e in provider(now, now + AHEAD)
         if not e.all_day and e.end > now and e.start < now + AHEAD and e.key
         and any(not a.is_self and not a.is_room for a in e.attendees)),  # a meeting, not a reminder
        key=lambda e: e.start,
    )


def chosen(event: calendar_events.Event) -> list[str]:
    """Project ids chosen for ``event`` ahead of time."""
    return list(_load().get(event.key, {}).get("projects", []))


def choose(event: calendar_events.Event, project: str, *, remove: bool = False) -> None:
    data = _load()
    entry = data.setdefault(event.key, {"title": event.title, "start": event.start.isoformat(), "projects": []})
    if remove:
        entry["projects"] = [p for p in entry["projects"] if p != project]
    elif project not in entry["projects"]:
        entry["projects"].append(project)
    if not entry["projects"]:
        del data[event.key]
    _save(data)


def apply(paths: RecordingPaths, event: calendar_events.Event) -> list[str]:
    """Give a recording what was prepared for its event beforehand: the
    projects chosen, and the user's own notes (#44)."""
    from . import my_notes

    if event.key:
        my_notes.adopt(my_notes.prep_folder(event.key), paths.folder)
    data = _load()
    entry = data.pop(event.key, None) if event.key else None
    if not entry:
        return []
    store = projects.ProjectStore()
    added = [pid for pid in entry["projects"]
             if pid in store.projects() and store.assign(paths.folder.name, pid, why="chosen before the meeting")]
    store.save()
    _save(data)
    return added


def suggestions(event: calendar_events.Event, output_dir: Path, *, user_name: str,
                store: projects.ProjectStore | None = None,
                every: dict[str, projects.Facts] | None = None) -> list[dict[str, Any]]:
    store = store or projects.ProjectStore()
    every = every if every is not None else projects.all_facts(output_dir, user_name=user_name)
    facts = projects.event_facts(event, user_name=user_name)
    taken = set(chosen(event))
    return [
        {"id": pid, "name": store.projects()[pid]["name"], "score": round(score, 2), "why": why}
        for pid, score, why in projects.scores(facts, store, every, projects.Similarity({**every, facts.meeting: facts}))
        if pid not in taken and score >= projects.SUGGEST_SCORE
    ][:3]


def context(event: calendar_events.Event, output_dir: Path, *, user_name: str,
            every: dict[str, projects.Facts] | None = None) -> list[dict[str, Any]]:
    """The last meetings that lead up to this one: earlier occurrences of the
    series first, then those that shared the most invitees."""
    every = every if every is not None else projects.all_facts(output_dir, user_name=user_name)
    facts = projects.event_facts(event, user_name=user_name)
    ranked = []
    for mid, f in every.items():
        if f.start and f.start >= event.start.isoformat():
            continue
        shared = len(facts.people & f.people)
        same_series = bool(facts.series) and facts.series == f.series
        if same_series or shared:
            ranked.append(((same_series, shared, f.start), mid))
    out = []
    for _, mid in sorted(ranked, reverse=True)[:CONTEXT_MEETINGS]:
        paths = RecordingPaths(output_dir / mid)
        n = glossary.current().apply_to(notes.with_names(notes.load(paths) or {}, _display_names(paths)))
        out.append({
            "id": mid, "title": every[mid].title, "start": every[mid].start,
            "why": "same series" if facts.series and facts.series == every[mid].series else "same people",
            "summary": n.get("summary"), "next_steps": n.get("next_steps", []),
        })
    return out


def _display_names(paths: RecordingPaths) -> dict[str, str]:
    """SPEAKER_xx → the name in effect, a room (#56), or "Speaker N"."""
    from .shared_mic import display
    from .speakers import names_in_effect

    names = {**names_in_effect(paths), **display(paths)}
    labels = set(re.findall(r"SPEAKER_\d+", json.dumps(notes.load(paths) or {})))
    return {label: names.get(label) or f"Speaker {int(label.rsplit('_', 1)[1]) + 1}" for label in labels | set(names)}


def find(provider: calendar_events.Provider, key: str, now: datetime) -> calendar_events.Event | None:
    """An upcoming event by its key."""
    return next((e for e in upcoming(provider, now) if e.key == key), None)

