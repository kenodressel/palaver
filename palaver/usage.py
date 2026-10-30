"""Local usage metrics (#59): which features testers use and which they
don't, recordings with their trigger and length, notes runs, errors.

One append-only JSON line per event in ``usage.jsonl``; it never leaves
the Mac except inside a problem report (report.py). ``record`` is the one
way in and never raises: counting must not break what is counted. Events
stay small and never hold transcript text.

Features are ``kind:id``: window actions (``action:meeting.trash``), views,
meeting tabs, ⌘K picks, settings changed, and CLI commands a person typed
(the app's own `live`, `process` … are runs, not features). The catalog of
every feature there is, for "never used", comes from the window's action
registry (posted by the page) plus the CLI's commands and the settings.
"""

from __future__ import annotations

import json
import os
import statistics
from datetime import datetime, timedelta
from pathlib import Path

SUPPORT = Path.home() / "Library" / "Application Support" / "palaver"
PATH = SUPPORT / "usage.jsonl"
CATALOG_PATH = SUPPORT / "usage-features.json"

MAX_TEXT = 200
FEATURE_KINDS = ("action", "view", "tab", "palette", "setting", "cli")
# What the page may post: its own feature kinds, and the errors it showed.
PAGE_KINDS = ("action", "view", "tab", "palette", "error")


def _small(value):
    if isinstance(value, str):
        return value[:MAX_TEXT]
    if isinstance(value, float):
        return round(value, 1)
    if isinstance(value, (list, tuple)):
        return [_small(v) for v in list(value)[:20]]
    return value


def record(kind: str, id: str | None = None, **fields) -> None:  # noqa: A002 (the event's id)
    """Append one event; never raises."""
    try:
        row = {"ts": datetime.now().astimezone().isoformat(timespec="seconds"), "kind": str(kind)}
        if id is not None:
            row["id"] = _small(str(id))
        row.update({k: _small(v) for k, v in fields.items()})
        line = json.dumps(row, ensure_ascii=False, default=str) + "\n"
        PATH.parent.mkdir(parents=True, exist_ok=True)
        # One write of a short line to a file opened for appending: processes don't interleave.
        fd = os.open(PATH, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
        try:
            os.write(fd, line.encode())
        finally:
            os.close(fd)
    except Exception:
        pass


def read(path: Path | None = None) -> list[dict]:
    """The events, skipping lines that are not one (cut short, edited)."""
    try:
        return read_lines(Path(path or PATH).read_text(errors="replace"))
    except OSError:
        return []


def read_lines(text: str) -> list[dict]:
    out = []
    for line in text.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict) and isinstance(row.get("kind"), str) and isinstance(row.get("ts"), str):
            out.append(row)
    return out


def feature(e: dict) -> str | None:
    """The feature an event is a use of, or None (a run, an error)."""
    if e.get("kind") not in FEATURE_KINDS or not e.get("id"):
        return None
    if e["kind"] == "cli" and e.get("by") != "user":
        return None
    return f"{e['kind']}:{e['id']}"


# --- settings changed ----------------------------------------------------------------

def setting_events(path: str, body: dict) -> list[dict]:
    """What a settings change of the window records: the keys, a switch's
    or a choice's value, never a key, endpoint or other free text."""
    if not isinstance(body, dict):
        return []
    if path.endswith("/key"):
        return [{"id": f"key.{body.get('provider')}", "removed": bool(body.get("remove"))}]
    if path == "/api/settings":
        from .settings import Settings
        from dataclasses import fields

        known = {f.name for f in fields(Settings)}
        return [{"id": k, "value": v} for k, v in body.items() if k in known and isinstance(v, bool)]
    out = []
    use = body.get("use")
    if isinstance(use, dict):
        out += [{"id": f"use.{k}", "value": str(v)[:80]} for k, v in use.items()]
    elif isinstance(use, str):
        out.append({"id": "use", "value": use[:80]})
    if "provider" in body:
        changed = sorted(k for k in body if k not in ("provider", "use"))
        out.append({"id": f"provider.{body['provider']}", "fields": changed})
    if "local_model" in body:
        out.append({"id": "local_model", "value": str(body["local_model"])[:120]})
    return out


# --- the catalog -----------------------------------------------------------------------

def save_catalog(catalog: dict) -> None:
    """The window's features (its action registry, views, tabs), as the page posts them."""
    clean = {k: sorted({str(i)[:80] for i in v if isinstance(i, str)})[:500]
             for k, v in (catalog or {}).items() if k in FEATURE_KINDS and isinstance(v, list)}
    try:
        CATALOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        tmp = CATALOG_PATH.with_name(CATALOG_PATH.name + f".{os.getpid()}.tmp")
        tmp.write_text(json.dumps(clean, indent=1))
        tmp.replace(CATALOG_PATH)
    except OSError:
        pass


def catalog() -> dict[str, list[str]]:
    """Every feature there is: the window's (from its last start), the CLI's commands, the settings."""
    from dataclasses import fields

    from .settings import Settings

    try:
        saved = json.loads(CATALOG_PATH.read_text())
    except (OSError, ValueError):
        saved = {}
    out = {k: list(v) for k, v in saved.items() if k in FEATURE_KINDS and isinstance(v, list)} \
        if isinstance(saved, dict) else {}
    try:
        from .cli import command_names

        out["cli"] = command_names()
    except Exception:
        pass
    out["setting"] = sorted({*out.get("setting", []), *(f.name for f in fields(Settings))})
    for kind, ids in MENUBAR_FEATURES.items():
        out[kind] = sorted({*out.get(kind, []), *ids})
    return out


# What the menu bar icon's menu counts itself (menubar.py).
MENUBAR_FEATURES = {"action": ["menubar.reportProblem"]}


# --- the summary -------------------------------------------------------------------------

def _when(e: dict) -> datetime | None:
    try:
        ts = datetime.fromisoformat(e["ts"])
    except (KeyError, TypeError, ValueError):
        return None
    return ts if ts.tzinfo else ts.astimezone()


def _median(values: list[float]) -> float | None:
    return round(float(statistics.median(values)), 1) if values else None


def _counts(values: list[str]) -> dict[str, int]:
    out: dict[str, int] = {}
    for v in values:
        out[v] = out.get(v, 0) + 1
    return dict(sorted(out.items(), key=lambda kv: (-kv[1], kv[0])))


def summary(events: list[dict], catalog: dict, now: datetime | None = None) -> dict:
    """Counts per feature over 7 and 30 days and in all, the features never
    used (and not in 30 days), recordings, notes and process runs, errors."""
    now = now or datetime.now().astimezone()
    windows = {"7d": now - timedelta(days=7), "30d": now - timedelta(days=30)}
    dated = [(e, _when(e)) for e in events]
    features: dict[str, dict[str, int]] = {}
    for e, when in dated:
        name = feature(e)
        if name is None:
            continue
        c = features.setdefault(name, {"7d": 0, "30d": 0, "all": 0})
        c["all"] += 1
        for key, since in windows.items():
            if when is not None and when >= since:
                c[key] += 1
    known = {f"{kind}:{i}" for kind, ids in (catalog or {}).items() for i in ids}
    recent = [e for e, when in dated if when is not None and when >= windows["30d"]]

    def runs(kind: str) -> list[dict]:
        return [e for e in recent if e["kind"] == kind]

    stops = runs("recording_stop")
    notes = runs("notes")
    process = runs("process")
    errors = runs("error")
    times = [w for _, w in dated if w is not None]
    return {
        "generated": now.isoformat(timespec="seconds"),
        "events": len(events),
        "since": min(times).isoformat(timespec="seconds") if times else None,
        "features": dict(sorted(features.items())),
        "never_used": sorted(known - set(features)),
        "unused_30d": sorted(known - {f for f, c in features.items() if c["30d"]}),
        "recordings": {"30d": {
            "count": len(stops),
            "minutes": round(sum(float(e.get("seconds") or 0) for e in stops) / 60, 1),
            "by_trigger": _counts([str(e.get("trigger") or "unknown") for e in stops]),
        }},
        "notes": {"30d": {
            "runs": len(notes),
            "ok": sum(bool(e.get("ok")) for e in notes),
            "failed": sum(not e.get("ok") for e in notes),
            "median_seconds": _median([float(e["seconds"]) for e in notes if isinstance(e.get("seconds"), (int, float))]),
            "by_model": _counts([f"{e.get('engine') or '?'} {e.get('model') or '?'}" for e in notes]),
        }},
        "process": {"30d": {
            "runs": len(process),
            "ok": sum(bool(e.get("ok")) for e in process),
            "failed": sum(not e.get("ok") for e in process),
            "median_seconds": _median([float(e["seconds"]) for e in process if isinstance(e.get("seconds"), (int, float))]),
        }},
        "errors": {"30d": len(errors), "last": [{"ts": e["ts"], "text": e.get("text")} for e in errors[-20:]]},
    }
