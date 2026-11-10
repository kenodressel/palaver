"""Attribution: why Palaver linked two things, and how sure it is (issue #48).

Palaver links a recording to a calendar event, a meeting to projects, a
voice to a person, a person to an organization. Each link is a ``Link``:
what it links, who decided (the ``source``), how sure that was
(``confidence``, 0..1, None when unknown) and a short ``reason`` the window
shows where the link is shown: "Event: Northwind (time match, 2 events
overlapped)". Links stored before this existed have no source: they read
as "unknown", and are not shown as unsure for that alone.

Corrections stick and teach:

- a link the user set or rejected (source "you") is never replaced by
  automation (calendar_events.attach, projects.ProjectStore.assign,
  the voice bank and inference never override a name given by hand);
- a rejection is negative evidence: "this voice is not Tom" (speakers.py,
  voices.recognize), "recordings are not this event" (``Evidence``);
- rejected again and again, it becomes a rule: an event series the user
  said no to at least ``RULE_AFTER`` times, and more often than they kept
  it (a recording still linked to it counts as kept), is no longer linked
  by time at all, until the user forgets the rule.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from ._xdg import xdg_config_home
from .store_lock import locked
from .paths import is_recording_folder_name

# Below this a link gets the "unsure" look (a dotted chip) and is asked about.
UNSURE_BELOW = 0.75
# Rejections of one event series that make a rule (when they also outnumber
# the recordings linked to it): recordings are no longer linked to it by time.
RULE_AFTER = 2

# What a source is called where no reason was kept.
SOURCE_TEXT = {
    "you": "you",
    "calendar": "time match",
    "voice": "voice",
    "inferred": "inferred",
    "rules": "rules",
    "model": "the model",
    "email": "email address",
    "unknown": "",
}
_KIND_TEXT = {"event": "Event", "project": "Project", "speaker": "Speaker", "org": "Organization"}
# projects.py says "auto" for its rules.
_PROJECT_SOURCES = {"you": "you", "auto": "rules", "model": "model"}


@dataclass(frozen=True)
class Link:
    kind: str                 # "event" | "project" | "speaker" | "org"
    target: str               # what it links to, as shown: "Northwind", "Tom", "Contoso"
    source: str = "unknown"   # see SOURCE_TEXT
    confidence: float | None = None
    reason: str = ""

    @property
    def by_you(self) -> bool:
        """Set (or confirmed) by the user: final, automation leaves it alone."""
        return self.source == "you"

    @property
    def unsure(self) -> bool:
        if self.by_you:
            return False
        if self.kind == "project":
            return True  # rules and the model only propose projects (#29); the user decides
        return self.confidence is not None and self.confidence < UNSURE_BELOW

    @property
    def why(self) -> str:
        return self.reason or SOURCE_TEXT.get(self.source, "")

    @property
    def label(self) -> str:
        """"Event: Northwind (time match, 2 events overlapped)"."""
        head = f"{_KIND_TEXT.get(self.kind, self.kind.title())}: {self.target}"
        return f"{head} ({self.why})" if self.why else head

    def stored(self) -> dict[str, Any]:
        """What a store keeps (the target is the thing itself, stored beside it)."""
        out: dict[str, Any] = {"source": self.source}
        if self.confidence is not None:
            out["confidence"] = self.confidence
        if self.reason:
            out["reason"] = self.reason
        return out

    def to_dict(self) -> dict[str, Any]:
        """For the window: everything, with how to show it."""
        return {"kind": self.kind, "target": self.target, "source": self.source, "confidence": self.confidence,
                "reason": self.reason, "unsure": self.unsure, "label": self.label}

    @classmethod
    def from_dict(cls, kind: str, target: str, d: dict | None) -> "Link":
        """As stored; missing fields (older files) mean an unknown source."""
        d = d if isinstance(d, dict) else {}
        confidence = d.get("confidence")
        return cls(kind, target, str(d.get("source") or "unknown"),
                   float(confidence) if isinstance(confidence, (int, float)) and not isinstance(confidence, bool)
                   else None,
                   str(d.get("reason") or ""))

    @classmethod
    def from_project(cls, name: str, how: dict) -> "Link":
        """A project assignment as projects.py stores it: {"by", "why", "confidence"?}."""
        return cls.from_dict("project", name, {"source": _PROJECT_SOURCES.get(how.get("by"), "unknown"),
                                               "confidence": how.get("confidence"), "reason": how.get("why")})


# --- negative evidence across meetings ----------------------------------------------


def _default_path() -> Path:
    return xdg_config_home() / "palaver" / "attributions.json"


class Evidence:
    """What the user's corrections taught, beyond one meeting: which event
    series recordings were said not to be (and which they were chosen for).
    One small JSON file next to the projects. ``output_dir``: the recordings,
    whose stored events count as kept (accepted) links."""

    def __init__(self, path: Path | None = None, *, output_dir: Path | None = None):
        self.path = path or _default_path()
        self.output_dir = output_dir
        self._linked: dict[str, set[str]] | None = None
        try:
            self._data = json.loads(self.path.read_text())
        except (OSError, ValueError):
            self._data = {}
        if not isinstance(self._data, dict):
            self._data = {}
        self._data.setdefault("events", {})

    def save(self) -> None:
        with locked(self.path):
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".json.tmp")
            tmp.write_text(json.dumps(self._data, indent=2, ensure_ascii=False))
            tmp.replace(self.path)

    @staticmethod
    def _series(event) -> str:
        return event.series_id or event.title

    def _entry(self, event) -> dict[str, Any]:
        entry = self._data["events"].setdefault(self._series(event), {})
        entry.setdefault("rejected", [])
        entry.setdefault("chosen", [])
        entry["title"] = event.title
        return entry

    def reject_event(self, event, meeting: str) -> None:
        """The user said recording ``meeting`` is not ``event``."""
        entry = self._entry(event)
        if meeting in entry["chosen"]:
            entry["chosen"].remove(meeting)
        if meeting not in entry["rejected"]:
            entry["rejected"].append(meeting)

    def confirm_event(self, event, meeting: str) -> None:
        """The user chose ``event`` for recording ``meeting``."""
        entry = self._entry(event)
        if meeting in entry["rejected"]:
            entry["rejected"].remove(meeting)
        if meeting not in entry["chosen"]:
            entry["chosen"].append(meeting)

    def forget_rule(self, series: str) -> None:
        """Link this series by time again: its rejections are forgotten."""
        entry = self._data["events"].get(series)
        if entry is not None:
            entry["rejected"] = []

    def _linked_meetings(self) -> dict[str, set[str]]:
        """series → recordings whose stored event is of it (read once)."""
        if self._linked is None:
            self._linked = {}
            if self.output_dir is not None and self.output_dir.is_dir():
                for folder in self.output_dir.iterdir():
                    if not is_recording_folder_name(folder.name):
                        continue
                    try:
                        d = json.loads((folder / "calendar.json").read_text())
                        series = str(d.get("uid") or "").split("/RID=")[0] or d["title"]
                    except (OSError, ValueError, KeyError, TypeError, AttributeError):
                        continue
                    self._linked.setdefault(series, set()).add(folder.name)
        return self._linked

    def _counts(self, series: str) -> tuple[int, int]:
        """(rejections, acceptances) of one series: recordings said not to be
        it; recordings chosen for it, or linked to it and kept."""
        entry = self._data["events"].get(series, {})
        rejected = set(entry.get("rejected", []))
        accepted = (set(entry.get("chosen", [])) | self._linked_meetings().get(series, set())) - rejected
        return len(rejected), len(accepted)

    def event_rejections(self, event) -> int:
        return self._counts(self._series(event))[0]

    def acceptances(self, event) -> int:
        return self._counts(self._series(event))[1]

    def doubted(self, event) -> int:
        """How often the user said no to this series, when that is more often
        than they kept it; else 0 (a weekly meeting kept every week is not in
        doubt because an ad-hoc call took its slot twice)."""
        rejected, accepted = self._counts(self._series(event))
        return rejected if rejected > accepted else 0

    def _is_rule(self, series: str) -> bool:
        rejected, accepted = self._counts(series)
        return rejected >= RULE_AFTER and rejected > accepted

    def never_by_time(self, event) -> bool:
        """A rule: the user said no to this series often, and more often than not."""
        return self._is_rule(self._series(event))

    def rule(self, event) -> dict[str, Any] | None:
        """The rule about this event's series, for the event picker."""
        series = self._series(event)
        return next((r for r in self.rules() if r["series"] == series), None)

    def rules(self) -> list[dict[str, Any]]:
        """The rules corrections made, for the window to show."""
        out = []
        for series, e in sorted(self._data["events"].items()):
            if self._is_rule(series):
                rejected, accepted = self._counts(series)
                title = e.get("title", series)
                out.append({"kind": "event", "series": series, "title": title, "rejected": rejected,
                            "accepted": accepted, "rule": f"Not linked by time any more: {title} — rejected {rejected}×"})
        return out


# --- what needs the user ----------------------------------------------------------


def questions(meeting: dict[str, Any]) -> list[dict[str, Any]]:
    """What to ask the user about one meeting (the meeting as the window gets
    it): which event, when events overlapped, and every unsure link. For the
    "Needs you" page; one item per question, in the order of the page."""
    base = {"meeting": meeting["id"], "title": meeting.get("title"), "start": meeting.get("start")}
    out = []
    question = meeting.get("event_question")
    if question:
        out.append({**base, "kind": "event", "question": "Which calendar event was this recording?",
                    "reason": question.get("reason", ""), "choices": question.get("choices", [])})
    link = (meeting.get("calendar") or {}).get("link")
    if link and link.get("unsure"):
        out.append({**base, "kind": "event", "question": f"Was this recording “{link['target']}”?", "link": link})
    for s in meeting.get("speakers", []):
        link = s.get("link")
        if link and link.get("unsure"):
            out.append({**base, "kind": "speaker", "label": s["label"],
                        "question": f"Is this {link['target']}?", "link": link})
    for p in meeting.get("projects", []):
        link = p.get("link")
        if link and link.get("unsure"):
            out.append({**base, "kind": "project", "project": p.get("id"),
                        "question": f"Is this meeting part of {link['target']}?", "link": link})
    return out
