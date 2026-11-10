"""Which organization people belong to: "Timo Strauß (KLOUD)",
"Stefan D (Extern)".

The calendar knows everyone's email address; the domain says the
organization (contoso.es, contoso.com and contoso.de are all Contoso).
Private addresses (gmail, gmx, …) count as "Extern". Organizations get a
name derived from the domain, which the user can change, and a person can
be given an organization by hand — someone never invited by email, or
someone the domain gets wrong. Stored in ``organizations.json`` next to
the voice bank.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from ._xdg import xdg_config_home
from .store_lock import locked
from .attribution import Link

EXTERN = "Extern"
# Mail providers anyone can use: their domain says nothing about an organization.
PERSONAL_DOMAINS = {
    "gmail.com", "googlemail.com", "gmx.at", "gmx.de", "gmx.net", "web.de", "outlook.com", "hotmail.com",
    "live.com", "icloud.com", "me.com", "yahoo.com", "yahoo.de", "proton.me", "protonmail.com", "aon.at",
    "chello.at", "a1.net", "t-online.de",
}


def _path() -> Path:
    return xdg_config_home() / "palaver" / "organizations.json"


def org_key(email: str | None) -> str | None:
    """contoso.es → "contoso"; a private address → "extern"."""
    if not email or "@" not in email:
        return None
    domain = email.rsplit("@", 1)[1].lower()
    if domain in PERSONAL_DOMAINS:
        return "extern"
    labels = domain.split(".")
    return labels[-2] if len(labels) >= 2 else None


def default_name(key: str) -> str:
    """"kloud" → KLOUD (short ones look like acronyms), "contoso" → Contoso."""
    if key == "extern":
        return EXTERN
    return key.upper() if len(key) <= 5 else key.title()


class Organizations:
    def __init__(self, path: Path | None = None):
        self.path = path or _path()
        try:
            self._data = json.loads(self.path.read_text())
        except (OSError, ValueError):
            self._data = {}
        self._data.setdefault("names", {})
        self._data.setdefault("people", {})

    def save(self) -> None:
        with locked(self.path):
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".json.tmp")
            tmp.write_text(json.dumps(self._data, indent=2, ensure_ascii=False))
            tmp.replace(self.path)

    def name(self, key: str) -> str:
        return self._data["names"].get(key) or default_name(key)

    def rename(self, key: str, name: str) -> None:
        name = name.strip()
        if name and name != default_name(key):
            self._data["names"][key] = name
        else:
            self._data["names"].pop(key, None)

    def person(self, person: str) -> str | None:
        """The organization given to ``person`` by hand."""
        return self._data["people"].get(person.strip().casefold())

    def set_person(self, person: str, org: str | None) -> None:
        if org and org.strip():
            self._data["people"][person.strip().casefold()] = org.strip()
        else:
            self._data["people"].pop(person.strip().casefold(), None)


def people_index(output_dir: Path) -> dict[str, dict[str, Any]]:
    """Everyone the calendars invited: casefolded name → {"name", "email"
    (the latest), "emails" (each with how often it was invited), "self"}."""
    from . import calendar_events
    from .paths import RecordingPaths, is_recording_folder_name

    out: dict[str, dict[str, Any]] = {}
    if output_dir.is_dir():
        for folder in sorted(output_dir.iterdir()):
            if not is_recording_folder_name(folder.name):
                continue
            event = calendar_events.load(RecordingPaths(folder))
            for a in event.attendees if event else ():
                if not a.is_room and a.email:
                    entry = out.setdefault(a.name.casefold(), {"emails": {}, "self": False})
                    entry.update(name=a.name, email=a.email, self=entry["self"] or a.is_self)
                    entry["emails"][a.email] = entry["emails"].get(a.email, 0) + 1
    return out


def _entry(person: str, index: dict[str, dict[str, Any]]) -> dict[str, Any] | None:
    """``person`` in the index: by full name, or by first name when that is unambiguous."""
    key = person.strip().casefold()
    if key in index:
        return index[key]
    if " " in key or not key:
        return None
    hits = [e for k, e in index.items() if k.split()[0] == key]
    return hits[0] if len(hits) == 1 else None


def _own_key(index: dict[str, dict[str, Any]]) -> str | None:
    mine = next((e for e in index.values() if e["self"]), None)
    return org_key(mine["email"]) if mine else None


def _key_of(entry: dict[str, Any], own: str | None) -> str | None:
    """The organization an invitee's emails say. A colleague placed at a
    client is often invited with the client's address: any address in the
    user's own organization makes them one. Otherwise the organization
    they were invited with most often."""
    counts: dict[str, int] = {}
    for email, n in entry.get("emails", {entry["email"]: 1}).items():
        if key := org_key(email):
            counts[key] = counts.get(key, 0) + n
    if own and own != "extern" and own in counts:
        return own
    latest = org_key(entry["email"])
    return max(counts, key=lambda k: (counts[k], k == latest), default=None)


def org_of(person: str, index: dict[str, dict[str, Any]], orgs: Organizations) -> str | None:
    """The organization of ``person``: given by hand, else from their emails."""
    given = orgs.person(person)
    if given:
        return given
    entry = _entry(person, index)
    key = _key_of(entry, _own_key(index)) if entry else None
    return orgs.name(key) if key else None


def org_link(person: str, index: dict[str, dict[str, Any]], orgs: Organizations) -> Link | None:
    """``person``'s organization and why: given by hand, or the email
    addresses they were invited with (unsure when those say two
    organizations, or when only a first name matched)."""
    given = orgs.person(person)
    if given:
        return Link("org", given, "you")
    entry = _entry(person, index)
    own = _own_key(index)
    key = _key_of(entry, own) if entry else None
    if not key:
        return None
    keys = {k for email in entry.get("emails", {entry["email"]: 1}) if (k := org_key(email))}
    if len(keys) > 1 and key == own and own != "extern":
        confidence, reason = 0.9, "has an address of your organization"  # a colleague at a client: settled
    elif len(keys) > 1:
        confidence, reason = 0.6, f"invited with addresses of {len(keys)} organizations"
    else:
        confidence, reason = 0.9, f"invited as {entry['email']}"
    if person.strip().casefold() not in index:
        confidence, reason = min(confidence, 0.6), f"{reason}; matched by first name"
    return Link("org", orgs.name(key), "email", confidence, reason)


def own_org(index: dict[str, dict[str, Any]], orgs: Organizations, user_name: str) -> str | None:
    """The user's organization: given by hand, else from their own address."""
    given = orgs.person(user_name)
    if given:
        return given
    key = _own_key(index)
    return orgs.name(key) if key else None


def summary(index: dict[str, dict[str, Any]], orgs: Organizations) -> list[dict[str, Any]]:
    """Organizations with how many invitees each, most first, for editing."""
    counts: dict[str, int] = {}
    own = _own_key(index)
    for e in index.values():
        key = _key_of(e, own)
        if key:
            counts[key] = counts.get(key, 0) + 1
    return [{"key": k, "name": orgs.name(k), "default": default_name(k), "people": n}
            for k, n in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))]
