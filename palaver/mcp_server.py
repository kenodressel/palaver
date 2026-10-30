"""The meetings for Claude and other MCP clients (issue #35).

`palaver mcp` serves, over stdio, what the Meetings window shows:
meetings with their notes and transcripts, projects, people and open next
steps. Read-only. The tools call the same functions as the window
(webapp/api.py), so names, merges and the glossary apply here too.

Transcripts are long, so tools answer with summaries and excerpts first;
the full transcript (or a time range of it) comes only when asked for.
"""

from __future__ import annotations

import functools
import inspect
import json
import os
import signal
import time
from pathlib import Path
from typing import Any, Callable

from . import glossary, mcp_access, my_notes, search, titles
from . import notes as notes_module
from .paths import RecordingPaths
from .webapp import api

INSTRUCTIONS = """\
The user's recorded meetings (mostly Microsoft Teams calls, in German and \
English): notes (summary, sections, next steps, decisions), transcripts with \
speaker names, projects (customers, initiatives, topics) and people. \
Start with search_meetings or list_meetings; read a meeting with get_meeting \
(notes first; ask for the transcript only when the notes are not enough, \
preferably a time range). get_project and open_next_steps gather across \
meetings. Meeting ids look like 2026-10-21T16-29-29 (the start, local time). \
Meetings the user keeps on this Mac are not shared here."""

KEPT_ON_THIS_MAC = "This meeting is kept on this Mac; it is not shared with Claude."

TRANSCRIPT_LINES = 400


def _clock(seconds: float) -> str:
    s = int(seconds)
    return f"{s // 3600}:{s // 60 % 60:02d}:{s % 60:02d}" if s >= 3600 else f"{s // 60}:{s % 60:02d}"


def _quotable(value: str) -> str:
    """A parameter as one quoted filter value: the search has no escape for a
    quote, so quotes go (a name never has one)."""
    return " ".join(value.replace('"', " ").split())


_NOTE_KINDS = {"decision": "Decision", "step": "Next step", "point": "Point", "summary": "Summary"}


def _note(n: dict[str, Any]) -> str:
    """"Decision: …", "Next step (Anna): …" """
    owner = f" ({n['owner']})" if n.get("owner") else ""
    return f"{_NOTE_KINDS.get(n['kind'], n['kind'].title())}{owner}: {n['text']}"


class Meetings:
    """What the tools answer, as plain data."""

    def __init__(self, output_dir: Path, user_name: str):
        self.output_dir = output_dir
        self._user_name = user_name

    @property
    def user_name(self) -> str:
        """Read per call: a name changed in the app applies without a restart (#55)."""
        from .settings import current_user_name

        return current_user_name(self._user_name)

    # --- helpers

    def _private(self) -> set[str]:
        """Meetings kept on this Mac (#53): no tool shows them or what is in them."""
        from .llm import local_only_meetings

        return local_only_meetings(self.output_dir)

    def _hidden_projects(self, private: set[str]) -> set[str]:
        """Projects whose meetings are all kept on this Mac: their name and
        description came from those meetings."""
        from .projects import ProjectStore

        store = ProjectStore()
        return {pid for pid in store.projects()
                if store.meetings_of(pid) and all(m in private for m in store.meetings_of(pid))}

    def _meetings(self) -> list[dict[str, Any]]:
        private = self._private()
        return [m for m in api.list_meetings(self.output_dir) if m["id"] not in private]

    def _project_id(self, project: str | None) -> str | None:
        if not project:
            return None
        from .projects import ProjectStore

        store = ProjectStore()
        pid = project if project in store.projects() else store.find(project)
        # A hidden project answers like one that doesn't exist.
        if pid is None or pid in self._hidden_projects(self._private()):
            raise ValueError(f"no project {project!r}; list_projects shows them")
        return pid

    def _projects(self) -> list[dict[str, Any]]:
        """The window's projects without the meetings kept on this Mac: their
        people and dates left out too, and a project of only those left out whole."""
        private = self._private()
        hidden = self._hidden_projects(private)
        people = {m["id"]: m["people"] for m in api.list_meetings(self.output_dir)}
        out = []
        for p in api.list_projects(self.output_dir, user_name=self.user_name)["projects"]:
            if p["id"] in hidden:
                continue
            members = [x for x in p["meetings"] if x["id"] not in private]
            counts: dict[str, int] = {}
            for x in members:
                for name in people.get(x["id"], []):
                    counts[name] = counts.get(name, 0) + 1
            out.append({**p, "meetings": members,
                        "people": sorted(counts, key=lambda n: (-counts[n], n.casefold()))[:8],
                        "latest": members[0]["start"] if members else None})
        return out

    def _matches(self, m: dict[str, Any], project_id: str | None, person: str | None,
                 since: str | None, until: str | None) -> bool:
        if project_id and not any(p["id"] == project_id for p in m["projects"]):
            return False
        if person:
            wanted = person.casefold()
            if not any(wanted in n.casefold() for n in [*m["people"], *m["invited"]]):
                return False
        start = (m["start"] or "")[:10]
        return not ((since and start < since[:10]) or (until and start > until[:10]))

    @staticmethod
    def _brief(m: dict[str, Any]) -> dict[str, Any]:
        out = {
            "id": m["id"], "title": m["title"] or titles.fallback(m["start"]), "start": m["start"],
            "minutes": round((m["duration"] or 0) / 60), "status": m["status"],
            "projects": [p["name"] for p in m["projects"]], "people": m["people"], "summary": m["summary"],
        }
        if m.get("imported"):  # recorded by a colleague, not the user (#58)
            out["imported_from"] = m["imported"]["from"]
        return out

    # --- tools

    def list_meetings(self, project: str | None = None, person: str | None = None, since: str | None = None,
                      until: str | None = None, limit: int = 30) -> list[dict[str, Any]]:
        pid = self._project_id(project)
        meetings = [m for m in self._meetings() if self._matches(m, pid, person, since, until)]
        return [self._brief(m) for m in meetings[:limit]]

    def search_meetings(self, query: str, project: str | None = None, person: str | None = None,
                        organization: str | None = None, since: str | None = None, until: str | None = None,
                        limit: int = 10) -> dict[str, Any]:
        """The window's search: the query read the same way (people,
        projects, organizations, dates, decisions, who said it), the
        parameters as written-out filters, then meetings found by meaning."""
        text = query
        if project:
            from .projects import ProjectStore

            text += f' project:"{ProjectStore().projects()[self._project_id(project)]["name"]}"'
        for key, value in (("person", person), ("org", organization), ("since", since), ("until", until)):
            if value and _quotable(value):
                text += f' {key}:"{_quotable(value)}"'
        for key, value in (("since", since), ("until", until)):
            if value and not any(f.kind == key for f in search.parse(f'{key}:"{_quotable(value)}"', search.Vocabulary()).filters):
                raise ValueError(f"{key} must be a date like 2026-10-01 (or 2026-10, or a month name); got {value!r}")
        # "Keep on This Mac" (#53): never searched for MCP, by words or by meaning,
        # nor their people and projects read out of the query.
        private = frozenset(self._private())
        hidden = frozenset(self._hidden_projects(set(private)))
        q, results = api.run_search(self.output_dir, text, user_name=self.user_name, exclude=private,
                                    hide_projects=hidden)
        results = [r for r in results if r["id"] not in private]
        out = [{**self._brief(r), "matched_by": "words", "found_in_notes": r["in_notes"],
                "notes": [_note(n) for n in r["notes_hits"]], "matches_in_transcript": r["hit_count"],
                "lines": [f"[{_clock(x['start'])}] {x['speaker']}: {x['text']}" for x in r["hits"]]}
               for r in results[:limit]]
        if len(out) < limit and q.words:
            seen = {r["id"] for r in out}
            for r in api.search_meaning(self.output_dir, text, user_name=self.user_name, exclude=private,
                                        hide_projects=hidden):
                if r["id"] in seen or r["id"] in private or len(out) >= limit:
                    continue
                pieces = r["meaning"]
                out.append({**self._brief(r), "matched_by": "meaning",
                            "notes": [_note(p) for p in pieces if p["kind"] != "line"],
                            "lines": [f"[{_clock(p['start'])}] {p['speaker']}: {p['text']}"
                                      for p in pieces if p["kind"] == "line"]})
        return {"understood": [c["label"] for c in q.chips()], "meetings": out}

    def get_meeting(self, meeting_id: str, include_transcript: bool = False, from_minute: float | None = None,
                    to_minute: float | None = None) -> dict[str, Any]:
        if meeting_id in self._private():
            return {"id": meeting_id, "kept_on_this_mac": True, "message": KEPT_ON_THIS_MAC}
        m = api.get_meeting(self.output_dir, meeting_id, user_name=self.user_name)
        notes = m["notes"] or {}
        out: dict[str, Any] = {
            "id": m["id"],
            "title": m["title"] or titles.fallback(m["start"]),
            "start": m["start"], "minutes": round((m["duration"] or 0) / 60), "status": m["status"],
            "invited": [a["name"] for a in (m["calendar"] or {}).get("attendees", [])],
            "speakers": [f"{s['name'] or s['display']} ({s['org']})" if s.get("org") else s["name"] or s["display"]
                         for s in m["speakers"]],
            "projects": [p["name"] for p in m["projects"]],
            **({"imported_from": m["imported"]["from"],
                "note": f"Imported from {m['imported']['from']}: recorded by them, not by the user."}
               if m.get("imported") else {}),
            "notes": {k: notes.get(k) for k in ("summary", "sections", "next_steps", "decisions", "decisions_mine")
                      if notes.get(k)},
        }
        mine = my_notes.prompt_text(self.output_dir / meeting_id)  # the user's own notes (#44), as text
        if mine:
            out["my_notes"] = mine
        if include_transcript or from_minute is not None or to_minute is not None:
            lo = (from_minute or 0) * 60
            hi = to_minute * 60 if to_minute is not None else float("inf")
            lines = [f"[{_clock(t['start'])}] {t['speaker']}: {t['text']}"
                     for t in m["transcript"] if lo <= t["start"] < hi]
            out["transcript"] = lines[:TRANSCRIPT_LINES]
            if len(lines) > TRANSCRIPT_LINES:
                out["transcript_truncated"] = (f"{len(lines) - TRANSCRIPT_LINES} more lines; "
                                               "ask again with from_minute/to_minute")
        return out

    def list_projects(self) -> list[dict[str, Any]]:
        return [{"id": p["id"], "name": p["name"], "description": p["description"],
                 "meetings": len(p["meetings"]), "people": p["people"], "latest": p["latest"]}
                for p in self._projects()]

    def get_project(self, project: str) -> dict[str, Any]:
        pid = self._project_id(project)
        p = next(p for p in self._projects() if p["id"] == pid)
        return {
            "id": p["id"], "name": p["name"], "description": p["description"], "people": p["people"],
            "meetings": [{"id": x["id"], "title": x["title"], "start": x["start"], "summary": x["summary"]}
                         for x in p["meetings"]],
            "next_steps": self.open_next_steps(project=pid),
        }

    def list_people(self) -> list[dict[str, Any]]:
        """People from the meetings that are shared: someone met only in
        meetings kept on this Mac is not listed."""
        private = self._private()
        out = []
        for p in api.directory(self.output_dir)["people"]:
            seen = [x for x in p["meetings"] if x["id"] not in private]
            if p["meetings"] and not seen:
                continue
            out.append({"name": p["name"], "organization": p.get("org"), "meetings": len(seen),
                        "minutes_talked": round(sum(x.get("talk_seconds") or 0 for x in seen) / 60),
                        "last_meeting": seen[0]["start"] if seen else None})
        return out

    def open_next_steps(self, project: str | None = None, person: str | None = None, owner: str | None = None,
                        since: str | None = None) -> list[dict[str, Any]]:
        """Next steps from the notes, newest meeting first. Notes have no
        done/undone state yet: these are all that were agreed."""
        pid = self._project_id(project)
        out = []
        for m in self._meetings():
            if not m["has_notes"] or not self._matches(m, pid, person, since, None):
                continue
            paths = RecordingPaths(self.output_dir / m["id"])
            steps = glossary.current().apply_to(notes_module.with_names(
                (notes_module.load(paths) or {}).get("next_steps", []), api._display_names(paths)))
            for s in steps:
                if owner and owner.casefold() not in (s.get("owner") or "").casefold():
                    continue
                out.append({"meeting": m["id"], "title": m["title"], "start": m["start"],
                            "owner": s.get("owner") or None, "task": s.get("task")})
        return out


# --- the access log (#45) ---------------------------------------------------------

ARG_CHARS = 120
LOGGED_MEETINGS = 100  # meeting ids per log line, at most

# What one item of a tool's list answer is.
_ITEMS = {"list_meetings": "meetings", "search_meetings": "meetings", "list_projects": "projects",
          "list_people": "people", "open_next_steps": "next_steps"}
# The tools whose list items carry a meeting id ("id", or "meeting" for next steps).
_MEETING_LISTS = {"list_meetings", "search_meetings", "open_next_steps"}


def _short_args(fn: Callable, args: tuple, kwargs: dict) -> dict[str, Any]:
    """The arguments given, without the defaults; long text cut short."""
    sig = inspect.signature(fn)
    bound = sig.bind_partial(*args, **kwargs)
    out: dict[str, Any] = {}
    for name, value in bound.arguments.items():
        if value is None or value == sig.parameters[name].default:
            continue
        if isinstance(value, str) and len(value) > ARG_CHARS:
            value = value[:ARG_CHARS - 1] + "…"
        out[name] = value
    return out


def _measure(tool: str, result: Any) -> tuple[dict[str, int], list[str]]:
    """How much went out (meetings, lines, characters), and which meetings."""
    whole = result
    out: dict[str, int] = {}
    ids: list[str] = []
    if tool == "search_meetings" and isinstance(result, dict):  # {understood, meetings} (#46)
        result = result.get("meetings") or []
    if tool in _ITEMS and isinstance(result, list):
        out[_ITEMS[tool]] = len(result)
        if tool in _MEETING_LISTS:
            ids = [r.get("meeting") or r.get("id") for r in result]
        if tool == "search_meetings":
            out["lines"] = sum(len(r.get("lines") or []) for r in result)
        if tool == "open_next_steps":
            out["meetings"] = len(set(ids))
    elif tool == "get_meeting":
        out["meetings"] = 1
        ids = [result["id"]]
        if "transcript" in result:
            out["lines"] = len(result["transcript"])
    elif tool == "get_project":
        out["projects"] = 1
        out["meetings"] = len(result["meetings"])
        out["next_steps"] = len(result["next_steps"])
        ids = [m["id"] for m in result["meetings"]]
    out["chars"] = len(json.dumps(whole, ensure_ascii=False, default=str))
    return out, list(dict.fromkeys(i for i in ids if i))[:LOGGED_MEETINGS]


def _logged(fn: Callable, session: mcp_access.Session) -> Callable:
    """``fn`` as a tool that leaves one line in the access log per call.
    The log never changes what the tool answers or raises."""

    @functools.wraps(fn)
    def tool(*args, **kwargs):
        t0 = time.monotonic()
        result, error = None, None
        try:
            result = fn(*args, **kwargs)
            return result
        except Exception as exc:
            error = str(exc) or type(exc).__name__
            raise
        finally:
            try:
                out, ids = _measure(fn.__name__, result) if error is None else ({}, [])
                session.record(fn.__name__, args=_short_args(fn, args, kwargs), out=out, meetings=ids,
                               ms=round((time.monotonic() - t0) * 1000), error=error and error[:300])
            except Exception:
                mcp_access.LOGGER.debug("could not log an MCP call", exc_info=True)

    return tool


def _client_watch(session: mcp_access.Session):
    """Server middleware: the client's name and version, from the
    initialize handshake (or, without one, from the connection)."""

    async def watch(ctx, call_next):
        if ctx.method == "initialize":
            session.set_client((ctx.params or {}).get("clientInfo"))
        result = await call_next(ctx)
        if session.client is None:
            try:
                session.set_client(ctx.session.client_params.client_info)
            except Exception:
                pass
        return result

    return watch


def build_server(output_dir: Path, user_name: str, session: mcp_access.Session | None = None):
    from mcp.server.mcpserver import MCPServer

    meetings = Meetings(output_dir, user_name)
    session = session or mcp_access.Session()
    server = MCPServer("meetings", instructions=INSTRUCTIONS, middleware=[_client_watch(session)])

    def tool():
        return lambda fn: server.tool()(_logged(fn, session))

    @tool()
    def list_meetings(project: str | None = None, person: str | None = None, since: str | None = None,
                      until: str | None = None, limit: int = 30) -> list[dict[str, Any]]:
        """Meetings, newest first, with title, people, projects and summary.
        Filter by project (name or id), person (spoke or was invited; part of
        a name is enough), and dates (YYYY-MM-DD)."""
        return meetings.list_meetings(project, person, since, until, limit)

    @tool()
    def search_meetings(query: str, project: str | None = None, person: str | None = None,
                        organization: str | None = None, since: str | None = None, until: str | None = None,
                        limit: int = 10) -> dict[str, Any]:
        """Search the meetings as the Meetings window does. The query may name
        people ("Anna and Tom": both took part, as named speakers or invitees;
        "Anna or Tom"), projects, organizations ("ACB people"), dates ("last
        month", "since 2026-10-01", "oktober"), decisions or next steps ("what
        did we decide about X"), or one person's lines ("where did Mara talk
        about pricing"); quoted words stay words. Filters can be written out:
        person: project: org: since: until: in:decisions|steps|notes|transcript
        by:<name> is:reviewed has:steps. The other parameters add filters.
        Returns what was understood, and meetings found by words (title,
        notes, transcript lines), then ones found by meaning (similar
        wording, other language) when the index has them."""
        return meetings.search_meetings(query, project, person, organization, since, until, limit)

    @tool()
    def get_meeting(meeting_id: str, include_transcript: bool = False, from_minute: float | None = None,
                    to_minute: float | None = None) -> dict[str, Any]:
        """One meeting: who was invited and spoke, projects, its notes and the user's own notes.
        The transcript only with include_transcript, or from_minute/to_minute
        for a part of it (minutes from the start)."""
        return meetings.get_meeting(meeting_id, include_transcript, from_minute, to_minute)

    @tool()
    def list_projects() -> list[dict[str, Any]]:
        """Projects (customers, initiatives, topics) with their description,
        how many meetings, the people involved and the latest meeting."""
        return meetings.list_projects()

    @tool()
    def get_project(project: str) -> dict[str, Any]:
        """A project (name or id): description, its meetings with summaries,
        people, and the next steps agreed in its meetings."""
        return meetings.get_project(project)

    @tool()
    def list_people() -> list[dict[str, Any]]:
        """People named in the meetings, with how many meetings and when the
        last one was."""
        return meetings.list_people()

    @tool()
    def open_next_steps(project: str | None = None, person: str | None = None, owner: str | None = None,
                        since: str | None = None) -> list[dict[str, Any]]:
        """Next steps agreed in meetings, newest first: filter by project,
        person in the meeting, owner of the step, and since (YYYY-MM-DD)."""
        return meetings.open_next_steps(project, person, owner, since)

    return server


def serve(output_dir: Path, user_name: str, *, orphan_check: float = 5.0) -> None:
    """`palaver mcp`: serve one client over stdio, with a heartbeat file
    while it runs. Ends when the client closes stdin, when the client
    process is gone (see mcp_access.watch_parent), or on SIGTERM/SIGHUP."""
    session = mcp_access.Session()
    session.start()

    def stop(signum, frame):
        session.stop()  # takes no lock: the main thread may hold the session's
        os._exit(128 + signum)

    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, stop)
    mcp_access.watch_parent(session, interval=orphan_check)
    try:
        build_server(output_dir, user_name, session).run("stdio")
    finally:
        session.stop()


def server_args(config: str | None = None, options: list[str] = ()) -> list[str]:
    """The arguments to the Python that runs this server: ``options`` are
    global CLI options (the app's, e.g. --config), ``config`` one more."""
    return ["-m", "palaver", *options, *(["--config", config] if config else []), "mcp"]


def install_command(argv0: str, config: str | None = None, options: list[str] = ()) -> list[str]:
    """`claude mcp add` for Claude Code, user-wide."""
    return ["claude", "mcp", "add", "--scope", "user", "meetings", "--", argv0, *server_args(config, options)]

