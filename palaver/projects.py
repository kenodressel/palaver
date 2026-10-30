"""Projects: meetings grouped by customer, initiative or topic (issue #29).

A project has a name and a description, and many meetings; a meeting is
usually in one project but may be in several (a 1:1 that touches four
topics). Both are kept in one file next to the voice bank.

Meetings get their projects three ways, each recorded with who decided:

- by the user ("you"): added in the window; final.
- by rules ("auto"): the meeting resembles meetings already in a project —
  the same people, title words, or customer (the invitees' email domain).
- by the language model ("model"): it reads the meetings that rules could
  not place and proposes projects for them, new ones with a description.

Removing a meeting from a project remembers that: neither rules nor the
model put it back. Merging two projects moves every meeting to one of them.
"""

from __future__ import annotations

import json
import math
import re
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Collection

from . import calendar_events, notes, titles
from ._xdg import xdg_config_home
from .paths import RecordingPaths, is_recording_folder_name
from .speakers import names_in_effect

# Similarity to a project's closest meeting needed to put a meeting in it
# without asking, and to suggest it.
ASSIGN_SCORE = 0.6
SUGGEST_SCORE = 0.35
WEIGHTS = {"people": 0.6, "title": 0.6, "customer": 0.35}
# Who decided an assignment, strongest first: a stronger one is never
# replaced by a weaker one.
STRENGTH = {"you": 3, "model": 2, "auto": 1}

_STOP_WORDS = set("""
a an and at for from in of on or the to with x re fw aw wg
bei das der die ein eine für im in mit und von zu zum zur
""".split())


def _default_path() -> Path:
    return xdg_config_home() / "palaver" / "projects.json"


class ProjectStore:
    """Projects and which meetings are in them, in one JSON file."""

    def __init__(self, path: Path | None = None):
        self.path = path or _default_path()
        self.reload()

    def reload(self) -> None:
        """Read the file again: someone else may have changed it (the window
        while the model was thinking)."""
        try:
            self._data = json.loads(self.path.read_text())
        except (OSError, ValueError):
            self._data = {}
        self._data.setdefault("projects", {})
        self._data.setdefault("meetings", {})

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(self._data, indent=2, ensure_ascii=False))
        tmp.replace(self.path)

    # --- projects

    def projects(self) -> dict[str, dict[str, Any]]:
        """id → {"name", "description", "description_by": "you" | "model" | None}."""
        return self._data["projects"]

    def find(self, name: str) -> str | None:
        for pid, p in self.projects().items():
            if p["name"].casefold() == name.strip().casefold():
                return pid
        return None

    def create(self, name: str, description: str = "", *, by: str = "you") -> str:
        name = name.strip()
        if not name:
            raise ValueError("a project needs a name")
        existing = self.find(name)
        if existing:
            return existing
        pid = uuid.uuid4().hex[:8]
        # An empty description is the model's to write.
        self.projects()[pid] = {"name": name, "description": description.strip(),
                                "description_by": by if description.strip() else None}
        return pid

    def update(self, pid: str, *, name: str | None = None, description: str | None = None,
               by: str = "you") -> None:
        project = self._project(pid)
        if name is not None:
            name = name.strip()
            if not name:
                raise ValueError("a project needs a name")
            other = self.find(name)
            if other and other != pid:
                raise ValueError(f"there is already a project called {name}")
            project["name"] = name
        if description is not None:
            project["description"] = description.strip()
            project["description_by"] = by

    def delete(self, pid: str) -> None:
        self._project(pid)
        del self.projects()[pid]
        for entry in self._data["meetings"].values():
            entry.get("assigned", {}).pop(pid, None)
            if pid in entry.get("rejected", []):
                entry["rejected"].remove(pid)

    def merge(self, pid: str, into: str) -> None:
        """``pid`` and ``into`` are the same project: keep ``into``."""
        if pid == into:
            raise ValueError("a project cannot be merged into itself")
        self._project(pid)
        target = self._project(into)
        source = self.projects()[pid]
        if not target["description"] and source["description"]:
            target["description"], target["description_by"] = source["description"], source["description_by"]
        for meeting, entry in self._data["meetings"].items():
            moved = entry.get("assigned", {}).pop(pid, None)
            if moved and into not in entry.get("rejected", []):
                current = entry["assigned"].get(into)
                if current is None or STRENGTH[moved["by"]] > STRENGTH[current["by"]]:
                    entry["assigned"][into] = moved
            if pid in entry.get("rejected", []):
                entry["rejected"].remove(pid)
        del self.projects()[pid]

    def _project(self, pid: str) -> dict[str, Any]:
        try:
            return self.projects()[pid]
        except KeyError:
            raise LookupError(pid) from None

    # --- meetings

    def _entry(self, meeting: str) -> dict[str, Any]:
        entry = self._data["meetings"].setdefault(meeting, {})
        entry.setdefault("assigned", {})
        entry.setdefault("rejected", [])
        return entry

    def of_meeting(self, meeting: str) -> dict[str, dict[str, str]]:
        """project id → {"by", "why"} for ``meeting``."""
        return dict(self._data["meetings"].get(meeting, {}).get("assigned", {}))

    def rejected(self, meeting: str) -> list[str]:
        return list(self._data["meetings"].get(meeting, {}).get("rejected", []))

    def meetings_of(self, pid: str) -> dict[str, dict[str, str]]:
        """meeting id → {"by", "why"} for project ``pid``."""
        return {m: e["assigned"][pid] for m, e in self._data["meetings"].items() if pid in e.get("assigned", {})}

    def assign(self, meeting: str, pid: str, *, by: str = "you", why: str = "",
               confidence: float | None = None) -> bool:
        """Put ``meeting`` in project ``pid``. Rules and the model never
        override the user: not an assignment, not a removal. ``confidence``:
        how sure the rules were (their score), kept with the reason (#48)."""
        self._project(pid)
        entry = self._entry(meeting)
        if by != "you" and pid in entry["rejected"]:
            return False
        current = entry["assigned"].get(pid)
        if current is not None and STRENGTH[current["by"]] >= STRENGTH[by]:
            return False
        if by == "you" and pid in entry["rejected"]:
            entry["rejected"].remove(pid)
        entry["assigned"][pid] = {"by": by, "why": why, **({} if confidence is None else {"confidence": confidence})}
        return True

    def forget_meeting(self, meeting: str) -> None:
        """A recording that is gone (joined into another)."""
        self._data["meetings"].pop(meeting, None)

    def unassign(self, meeting: str, pid: str) -> None:
        """Take ``meeting`` out of ``pid`` for good."""
        entry = self._entry(meeting)
        entry["assigned"].pop(pid, None)
        if pid not in entry["rejected"]:
            entry["rejected"].append(pid)


# --- what a meeting is about ----------------------------------------------


@dataclass(frozen=True)
class Facts:
    meeting: str
    title: str
    start: str
    people: frozenset[str]  # casefolded names: who spoke and who was invited
    orgs: frozenset[str]    # customers: invitees' email domains other than the user's
    words: frozenset[str]   # title words
    summary: str
    series: str = ""        # the calendar event's series id: the same on every occurrence


def _org(email: str | None) -> str | None:
    """contoso.com, contoso.es → contoso."""
    if not email or "@" not in email:
        return None
    parts = email.rsplit("@", 1)[1].lower().split(".")
    return parts[-2] if len(parts) >= 2 else None


def _words(title: str, user_name: str = "") -> frozenset[str]:
    from .settings import me

    skip = _STOP_WORDS | {w for name in me(user_name) for w in name.split()}
    return frozenset(w for w in re.findall(r"[^\W\d_]{3,}", title.casefold()) if w not in skip)


def facts(paths: RecordingPaths, *, user_name: str) -> Facts:
    event = calendar_events.load(paths)
    meeting_notes = notes.load(paths) or {}
    people = {name.casefold() for name in names_in_effect(paths).values()}
    orgs: set[str] = set()
    own = {_org(a.email) for a in event.attendees if a.is_self} if event else set()
    if event:
        for a in calendar_events.candidates(event, user_name=user_name):
            people.add(a.name.casefold())
            org = _org(a.email)
            if org and org not in own:
                orgs.add(org)
    from .settings import me

    people -= me(user_name)  # an earlier name of the user too (#55)
    title = titles.resolve(paths, event=event, meeting_notes=meeting_notes)[0] or ""
    meta = _read_json(paths.meta)
    return Facts(paths.folder.name, title, meta.get("start_time", ""), frozenset(people), frozenset(orgs),
                 _words(title, user_name), meeting_notes.get("summary", ""),
                 event.series_id if event else "")


def event_facts(event: calendar_events.Event, *, user_name: str) -> Facts:
    """Facts of a meeting that has not happened yet: its calendar event."""
    people, orgs = set(), set()
    own = {_org(a.email) for a in event.attendees if a.is_self}
    for a in calendar_events.candidates(event, user_name=user_name):
        people.add(a.name.casefold())
        org = _org(a.email)
        if org and org not in own:
            orgs.add(org)
    return Facts(event.key or event.title, event.title, event.start.isoformat(), frozenset(people), frozenset(orgs),
                 _words(event.title, user_name), "", event.series_id)


def _read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def all_facts(output_dir: Path, *, user_name: str) -> dict[str, Facts]:
    """Facts of every processed meeting."""
    out = {}
    if output_dir.is_dir():
        for folder in sorted(output_dir.iterdir()):
            paths = RecordingPaths(folder)
            if is_recording_folder_name(folder.name) and paths.transcript_json.exists():
                out[folder.name] = facts(paths, user_name=user_name)
    return out


# --- rules ------------------------------------------------------------------


class Similarity:
    """How alike two meetings are. Rare things count more: sharing a
    customer's people says more than sharing a colleague who is in
    every meeting."""

    def __init__(self, all_facts: dict[str, Facts]):
        n = max(len(all_facts), 1)
        self._idf: dict[str, float] = {}
        for kind in ("people", "orgs", "words"):
            counts: dict[str, int] = {}
            for f in all_facts.values():
                for x in getattr(f, kind):
                    counts[x] = counts.get(x, 0) + 1
            for x, c in counts.items():
                self._idf[f"{kind}:{x}"] = math.log(1 + n / c)

    def _overlap(self, kind: str, a: frozenset[str], b: frozenset[str]) -> float:
        if not a or not b:
            return 0.0
        def weight(xs: frozenset[str]) -> float:
            return sum(self._idf.get(f"{kind}:{x}", 1.0) for x in xs)

        return 2 * weight(a & b) / (weight(a) + weight(b))  # Dice: "Sync" is not "Foundry Sync"

    def __call__(self, a: Facts, b: Facts) -> tuple[float, str]:
        """Score in 0..1 and the strongest reason. One signal in full is
        enough to assign (the same recurring title, the same people);
        together they add up. The same calendar series is the same project."""
        if a.series and a.series == b.series:
            return 1.0, "series"
        parts = {
            "people": WEIGHTS["people"] * self._overlap("people", a.people, b.people),
            "title": WEIGHTS["title"] * self._overlap("words", a.words, b.words),
            "customer": WEIGHTS["customer"] * self._overlap("orgs", a.orgs, b.orgs),
        }
        return 1 - math.prod(1 - p for p in parts.values()), max(parts, key=parts.get)


def scores(meeting: Facts, store: ProjectStore, all_facts: dict[str, Facts],
           similarity: Similarity) -> list[tuple[str, float, str]]:
    """(project id, score, why) for every project, best first. A project is
    represented by its meetings that the user or the model put there."""
    out = []
    for pid in store.projects():
        best, why = 0.0, ""
        for other, how in store.meetings_of(pid).items():
            if other == meeting.meeting or how["by"] == "auto" or other not in all_facts:
                continue
            score, reason = similarity(meeting, all_facts[other])
            if score > best:
                best, why = score, f"{reason} like “{all_facts[other].title}”"
        if best > 0:
            out.append((pid, best, why))
    return sorted(out, key=lambda x: -x[1])


def assign_by_rules(output_dir: Path, store: ProjectStore, *, user_name: str,
                    meetings: list[str] | None = None) -> list[tuple[str, str]]:
    """Put meetings that are in no project yet into the project they
    clearly resemble. Returns the (meeting, project id) pairs added."""
    every = all_facts(output_dir, user_name=user_name)
    similarity = Similarity(every)
    added = []
    for mid in meetings if meetings is not None else list(every):
        if mid not in every or store.of_meeting(mid):
            continue
        for pid, score, why in scores(every[mid], store, every, similarity):
            if score >= ASSIGN_SCORE and store.assign(mid, pid, by="auto", why=why, confidence=round(score, 2)):
                added.append((mid, pid))
                break  # a second project is the user's or the model's call
    return added


def suggestions(meeting: str, store: ProjectStore, every: dict[str, Facts],
                similarity: Similarity | None = None) -> list[dict[str, Any]]:
    """Projects a meeting might belong to, for the user to confirm."""
    if meeting not in every:
        return []
    similarity = similarity or Similarity(every)
    taken = set(store.of_meeting(meeting)) | set(store.rejected(meeting))
    return [
        {"id": pid, "name": store.projects()[pid]["name"], "score": round(score, 2), "why": why}
        for pid, score, why in scores(every[meeting], store, every, similarity)
        if pid not in taken and score >= SUGGEST_SCORE
    ][:3]


# --- the model ----------------------------------------------------------------

DESCRIPTION_RULES = (
    "At most two short sentences: what the project is about and who is involved (at most three names). "
    "Only what the meetings show — no guessing; when they say little, say little. "
    "Never mention the person whose meetings these are."
)

SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "new_projects": {
            "type": "array",
            "description": "Projects to create: only when no existing project fits.",
            "items": {
                "type": "object",
                "properties": {
                    "key": {"type": "string", "description": "A placeholder id like new1, used in assignments."},
                    "name": {"type": "string", "description": "Short: the customer, initiative or topic, 1-4 words."},
                    "description": {"type": "string", "description": DESCRIPTION_RULES},
                },
                "required": ["key", "name", "description"],
            },
        },
        "assignments": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "meeting": {"type": "string", "description": "The meeting id, exactly as given."},
                    "projects": {"type": "array", "items": {"type": "string"},
                                 "description": "Ids of existing projects or keys of new ones. Usually one; "
                                                "several only when the meeting really covered several."},
                },
                "required": ["meeting", "projects"],
            },
        },
        "descriptions": {
            "type": "array",
            "description": "New descriptions for existing projects marked (description can be rewritten).",
            "items": {
                "type": "object",
                "properties": {"project": {"type": "string"}, "description": {"type": "string"}},
                "required": ["project", "description"],
            },
        },
    },
    "required": ["new_projects", "assignments"],
}

PROMPT = """\
You sort the meetings {user} recorded into projects: a customer, an \
initiative, or a recurring topic such as hiring. Prefer the existing \
projects; create a new project only for meetings none of them fits, and \
group meetings that belong together into the same new project. Write names \
and descriptions in the language most of the project's meetings use. \
Descriptions: {rules}

Existing projects:
{projects}

Meetings to sort:
{meetings}
"""


def _describe(f: Facts) -> str:
    people = ", ".join(sorted(f.people)[:8]) or "unknown"
    lines = [f"- id {f.meeting}: “{f.title or 'untitled'}” on {f.start[:10]}; people: {people}"]
    if f.orgs:
        lines.append(f"  customers (email domains): {', '.join(sorted(f.orgs))}")
    if f.summary:
        lines.append(f"  summary: {f.summary}")
    return "\n".join(lines)


def parse_answer(text: str) -> dict[str, Any]:
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end < start:
        raise ValueError("no JSON object in the answer")
    out = json.loads(text[start : end + 1])
    if not isinstance(out, dict) or not isinstance(out.get("assignments"), list):
        raise ValueError("no assignments")
    out.setdefault("new_projects", [])
    out.setdefault("descriptions", [])
    return out


def suggest_with_model(output_dir: Path, store: ProjectStore, run: Callable[[str, dict], dict], *,
                       user_name: str, meetings: list[str] | None = None,
                       private: Collection[str] = ()) -> list[tuple[str, str]]:
    """Ask the model to place the meetings that are in no project (or just
    ``meetings``); creates the new projects it proposes. Returns the
    (meeting, project id) pairs added. ``private``: meetings kept on this
    Mac, left out of the prompt entirely (a cloud model is asked)."""
    every = {m: f for m, f in all_facts(output_dir, user_name=user_name).items() if m not in private}
    todo = [every[m] for m in (meetings if meetings is not None else every)
            if m in every and not store.of_meeting(m)]
    if not todo:
        return []
    # A project whose meetings are all private is left out whole: its name
    # and description were drawn from them.
    hidden = {pid for pid in store.projects() if store.meetings_of(pid)
              and all(m in private for m in store.meetings_of(pid))}
    projects = []
    for pid, p in store.projects().items():
        if pid in hidden:
            continue
        sample = [every[m].title for m in store.meetings_of(pid) if m in every][:5]
        rewrite = " (description can be rewritten)" if p["description_by"] != "you" else ""
        projects.append(f"- id {pid}: {p['name']} — {p['description'] or 'no description yet'}{rewrite}"
                        + (f"\n  meetings: {'; '.join(sample)}" if sample else ""))
    store.save()  # the model takes a while; changes made meanwhile are read back
    answer = run(PROMPT.format(user=user_name, rules=DESCRIPTION_RULES, projects="\n".join(projects) or "(none yet)",
                               meetings="\n".join(_describe(f) for f in todo)), SCHEMA)
    store.reload()

    created: dict[str, str] = {}
    for p in answer.get("new_projects", []):
        if isinstance(p, dict) and str(p.get("name", "")).strip():
            created[str(p.get("key"))] = store.create(str(p["name"]), str(p.get("description", "")), by="model")
    for d in answer.get("descriptions", []):
        pid = str(d.get("project")) if isinstance(d, dict) else ""
        if pid in store.projects() and pid not in hidden and store.projects()[pid]["description_by"] != "you":
            store.update(pid, description=str(d.get("description", "")), by="model")
    asked = {f.meeting for f in todo}
    added = []
    for a in answer.get("assignments", []):
        mid = str(a.get("meeting")) if isinstance(a, dict) else ""
        if mid not in asked:
            continue
        for ref in a.get("projects", []):
            pid = created.get(str(ref), str(ref))
            if pid in store.projects() and pid not in hidden and store.assign(mid, pid, by="model",
                                                                               why="suggested by the model"):
                added.append((mid, pid))
    # Projects the model proposed but put nothing in are noise.
    for pid in created.values():
        if not store.meetings_of(pid):
            store.delete(pid)
    return added


def describe_with_model(output_dir: Path, store: ProjectStore, pid: str, run: Callable[[str, dict], dict], *,
                        user_name: str, private: Collection[str] = ()) -> str:
    """(Re)write a project's description from its meetings, except the
    ``private`` ones; with nothing else to go on, the model is not asked."""
    every = {m: f for m, f in all_facts(output_dir, user_name=user_name).items() if m not in private}
    project = store.projects()[pid]
    meetings = "\n".join(_describe(every[m]) for m in store.meetings_of(pid) if m in every)
    if not meetings:
        return project["description"]
    store.save()
    answer = run(
        f"Describe the project “{project['name']}” from the meetings {user_name} recorded in it. "
        f"{DESCRIPTION_RULES} Write in the language most of the meetings use. Its meetings:\n{meetings}",
        {"type": "object", "properties": {"description": {"type": "string"}}, "required": ["description"]},
    )
    store.reload()
    if pid not in store.projects():
        return ""  # deleted meanwhile
    store.update(pid, description=str(answer.get("description", "")), by="model")
    return store.projects()[pid]["description"]
