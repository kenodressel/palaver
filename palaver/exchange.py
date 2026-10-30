"""Send a meeting to a colleague and take one in (issue #58): one
``.palaver`` file, a zip with a fixed layout, no cloud and no account.

::

    manifest.json            format, Palaver version, exported at, by whom, every file's sha256
    meeting/meta.json        start, end, duration, title, language, the exporter's projects (a hint)
    meeting/calendar.json    the event: iCal UID, occurrence start, title, attendees (optional)
    meeting/transcript.json  lines with their speaker label and the name shown
    meeting/turns.json       when each label talked (the lanes)
    meeting/speakers.json    label → name, and how it was named (by hand, by voice, inferred, the exporter)
    meeting/notes.json       summary, sections, next steps, decisions (optional)
    voices/<label>.json      the voice of a named person (optional, opt-in: biometric)
    audio/system.opus, audio/mic.opus   (optional, opt-in; FLAC where Opus can't take the rate)

The export is written from the exporter's side but not in it: their
microphone becomes a lane like any other, named after them. Only what is
listed above goes in; never their own notes (#44), the coach, the review,
search indexes or undo data. Items of the notes taken from their own notes
("mine") stay home too.

The file is untrusted input. ``read_package`` takes nothing but the names
above, no links, nothing larger than its cap, no format it does not know,
and checks every JSON against its schema and every file against the
manifest's sha256, all before anything is written. ``import_package``
builds the meeting in a folder of its own beside the recordings and moves
it into place in one rename. Nothing in the file is ever run.

What comes in is the colleague's word, not the user's: names given there
are hints ("named by Anna", stored like inferred names, which the user
confirms or rejects), voices go into the voice bank only when the user says
so, projects and search are worked out here again.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import re
import shutil
import stat
import tempfile
import uuid
import zipfile
import zlib
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Callable, Iterable

import numpy as np
import soundfile as sf

from . import __version__, calendar_events, notes as notes_mod, shared_mic, titles
from .attribution import Link
from .models import SpeakerTurn, Utterance
from .paths import RecordingPaths, is_recording_folder_name
from .speakers import (load_ignored, load_inferred_names, load_merges, load_recognized_names, load_rejected_names,
                       load_speaker_names, names_in_effect, save_speaker_names)

FORMAT = 1
SUFFIX = ".palaver"

# Caps: a four-hour meeting fits with room to spare, a zip bomb does not.
MAX_ENTRIES = 64
MAX_JSON_BYTES = 16 * 1024 * 1024
MAX_AUDIO_BYTES = 600 * 1024 * 1024
MAX_TOTAL_BYTES = 1300 * 1024 * 1024
MAX_FILE_BYTES = 1400 * 1024 * 1024  # the file itself: what it unpacks to, and its zip headers
MAX_DIRECTORY_BYTES = 64 * 1024  # the zip's table of contents: 64 entries need a few KB
_END_OF_DIRECTORY = b"PK\x05\x06"
MAX_SECONDS = 12 * 3600
MIN_FREE_BYTES = 2 * 1024 ** 3  # what decoding an import's audio leaves free at least
_CHUNK = 1 << 20

# How sure a name from the export is, by how it was named there.
HINT_CONFIDENCE = {"exporter": 1.0, "hand": 0.9, "voice": 0.8, "inferred": 0.6}
HOWS = tuple(HINT_CONFIDENCE)
IMPORTED = "imported"  # the rule of an inferred name that came with an import

_OPUS_RATES = (8000, 12000, 16000, 24000, 48000)
STAGING = ".importing"  # beside the recordings: where an import is built before it moves in
_LABEL = r"SPEAKER_\d{1,3}"
_JSON_FILES = {"meeting/meta.json", "meeting/calendar.json", "meeting/transcript.json", "meeting/turns.json",
               "meeting/speakers.json", "meeting/notes.json"}
_NAME = re.compile(rf"manifest\.json|meeting/(meta|calendar|transcript|turns|speakers|notes)\.json"
                   rf"|voices/{_LABEL}\.json|audio/(system|mic)\.(opus|flac)")
_REQUIRED = {"meeting/meta.json", "meeting/transcript.json", "meeting/turns.json", "meeting/speakers.json"}
# Notes keys that travel; anything else (hashes of the exporter's files) stays home.
_NOTES_KEYS = ("title", "summary", "sections", "next_steps", "decisions", "speaker_names")


class Rejected(ValueError):
    """The file can't be imported; the message says why, in words for the user."""


class KeptOnThisMac(Exception):
    """The meeting is marked "Keep on this Mac": the user is asked before it leaves."""


class NotReady(ValueError):
    """Only a finished, transcribed meeting can be exported."""


@dataclass(frozen=True)
class Match:
    """A meeting here the import is the same meeting as."""
    id: str
    how: str  # "event" (same calendar occurrence) | "overlap" (same time, same people)
    own: bool  # the user's own recording, not an earlier import


class Collision(Exception):
    """The same meeting is here already; the user decides (phase 1: keep
    theirs, or import as a separate meeting)."""

    def __init__(self, match: Match, sender: str):
        super().__init__(f"{match.id} is the same meeting")
        self.match = match
        self.sender = sender


# --- schemas ------------------------------------------------------------------------

_TIME = {"type": "string", "maxLength": 40,
         "pattern": r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?([+-]\d{2}:\d{2}|Z)"}
_SECONDS = {"type": "number", "minimum": 0, "maximum": MAX_SECONDS}
_TEXT = {"type": "string", "maxLength": 20000}
_NAME_TEXT = {"type": "string", "maxLength": 200}
_LABEL_TEXT = {"type": "string", "pattern": _LABEL}


def _obj(props: dict, required: Iterable[str] = ()) -> dict:
    return {"type": "object", "properties": props, "required": list(required), "additionalProperties": False}


def _list(items: dict, max_items: int) -> dict:
    return {"type": "array", "items": items, "maxItems": max_items}


MANIFEST = _obj({
    "format": {"type": "integer"},
    "palaver_version": {"type": "string", "maxLength": 40},
    "exported_at": _TIME,
    "exported_by": {"type": "string", "maxLength": 200, "minLength": 1},
    "files": {"type": "object", "maxProperties": MAX_ENTRIES, "propertyNames": {"type": "string", "maxLength": 100},
              "additionalProperties": _obj({"sha256": {"type": "string", "pattern": "[0-9a-f]{64}"},
                                            "bytes": {"type": "integer", "minimum": 0}}, ["sha256", "bytes"])},
}, ["format", "palaver_version", "exported_at", "exported_by", "files"])

SCHEMAS: dict[str, dict] = {
    "meeting/meta.json": _obj({
        "start": _TIME, "end": _TIME, "duration": _SECONDS,
        "title": {"type": ["string", "null"], "maxLength": 500},
        "language": {"type": ["string", "null"], "maxLength": 16},
        "projects": _list({"type": "string", "maxLength": 200}, 50),
        "kept_on_this_mac": {"type": "boolean"},
    }, ["start", "end", "duration"]),
    "meeting/calendar.json": _obj({
        "uid": {"type": "string", "maxLength": 1000}, "start": _TIME, "end": _TIME,
        "title": {"type": "string", "maxLength": 500}, "series": {"type": "boolean"},
        "attendees": _list(_obj({
            "name": _NAME_TEXT, "email": {"type": ["string", "null"], "maxLength": 320},
            "organizer": {"type": "boolean"},
            "response": {"type": "string", "enum": ["accepted", "tentative", "declined", "unknown"]},
            "room": {"type": "boolean"},
        }, ["name"]), 1000),
    }, ["uid", "start", "end", "title", "attendees"]),
    "meeting/transcript.json": _list(_obj({
        "start": _SECONDS, "end": _SECONDS, "text": _TEXT, "label": _LABEL_TEXT, "speaker": _NAME_TEXT,
    }, ["start", "end", "text", "label"]), 200_000),
    "meeting/turns.json": _list(_obj({"speaker": _LABEL_TEXT, "start": _SECONDS, "end": _SECONDS},
                                     ["speaker", "start", "end"]), 400_000),
    "meeting/speakers.json": _list(_obj({
        "label": _LABEL_TEXT, "name": {"type": ["string", "null"], "maxLength": 200},
        "how": {"type": ["string", "null"], "enum": [*HOWS, None]},
    }, ["label", "name", "how"]), 1000),
    "meeting/notes.json": _obj({
        "title": {"type": "string", "maxLength": 500},
        "summary": _TEXT,
        "sections": _list(_obj({
            "heading": {"type": "string", "maxLength": 1000},
            "points": _list(_obj({"text": _TEXT, "details": _list(_TEXT, 200)}, ["text"]), 500),
        }, ["heading", "points"]), 200),
        "next_steps": _list(_obj({"owner": {"type": "string", "maxLength": 500}, "task": _TEXT}, ["task"]), 500),
        "decisions": _list(_TEXT, 500),
        "speaker_names": _list(_obj({"label": {"type": "string", "maxLength": 50}, "name": _NAME_TEXT,
                                     "evidence": _TEXT}, ["label", "name"]), 500),
    }, ["summary"]),
}
VOICE = _obj({"label": _LABEL_TEXT, "name": _NAME_TEXT,
              "embedding": {"type": "array", "items": {"type": "number"}, "minItems": 16, "maxItems": 4096}},
             ["label", "name", "embedding"])

_TYPES: dict[str, Callable[[Any], bool]] = {
    "object": lambda v: isinstance(v, dict),
    "array": lambda v: isinstance(v, list),
    "string": lambda v: isinstance(v, str),
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "boolean": lambda v: isinstance(v, bool),
    "null": lambda v: v is None,
}


def check(value: Any, schema: dict, where: str) -> None:
    """``value`` against a JSON Schema (the subset the schemas above use);
    raises ``Rejected`` naming the first place that does not fit."""
    types = schema.get("type")
    types = [types] if isinstance(types, str) else types
    if types and not any(_TYPES[t](value) for t in types):
        raise Rejected(f"{where} is not {' or '.join(types)}")
    if "enum" in schema and value not in schema["enum"]:
        raise Rejected(f"{where} has a value it can't have")
    if isinstance(value, str):
        if len(value) > schema.get("maxLength", len(value)) or len(value) < schema.get("minLength", 0):
            raise Rejected(f"{where} is too long or too short")
        if "pattern" in schema and not re.fullmatch(schema["pattern"], value):
            raise Rejected(f"{where} is not in the expected form")
    elif isinstance(value, (int, float)) and not isinstance(value, bool):
        if isinstance(value, float) and not math.isfinite(value):  # 1e999 reads as infinity
            raise Rejected(f"{where} is not a finite number")
        if value < schema.get("minimum", value) or value > schema.get("maximum", value):
            raise Rejected(f"{where} is out of range")
    elif isinstance(value, list):
        if len(value) > schema.get("maxItems", len(value)) or len(value) < schema.get("minItems", 0):
            raise Rejected(f"{where} has too many or too few items")
        for i, item in enumerate(value):
            check(item, schema.get("items", {}), f"{where}[{i}]")
    elif isinstance(value, dict):
        if len(value) > schema.get("maxProperties", len(value)):
            raise Rejected(f"{where} has too many entries")
        for key in schema.get("required", []):
            if key not in value:
                raise Rejected(f"{where} lacks {key!r}")
        props, extra = schema.get("properties", {}), schema.get("additionalProperties", True)
        for key, item in value.items():
            if "propertyNames" in schema:
                check(key, schema["propertyNames"], f"{where} key")
            if key in props:
                check(item, props[key], f"{where}.{key}")
            elif extra is False:
                raise Rejected(f"{where} has {key[:40]!r}, which it can't have")
            elif isinstance(extra, dict):
                check(item, extra, f"{where}.{key[:40]}")


def _json(data: bytes, where: str) -> Any:
    """Strict JSON: UTF-8, no NaN or Infinity, no nesting deep enough to hurt."""
    def no_constant(name):
        raise Rejected(f"{where} has {name}, which JSON can't have")
    try:
        return json.loads(data.decode("utf-8"), parse_constant=no_constant)
    except Rejected:
        raise
    except (UnicodeDecodeError, ValueError, RecursionError):
        raise Rejected(f"{where} is not valid JSON") from None


def _time(text: str, where: str) -> datetime:
    try:
        t = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        raise Rejected(f"{where} is not a time") from None
    if t.tzinfo is None:
        raise Rejected(f"{where} has no time zone")
    if not 2000 <= t.year <= 2100:  # 9999 or year 1 overflow once moved to this Mac's time zone
        raise Rejected(f"{where} is out of range")
    return t


# --- export -------------------------------------------------------------------------


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(_CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, indent=1).encode()


def file_name(paths: RecordingPaths) -> str:
    """``<date> <title>.palaver``, safe as a file name anywhere it is sent."""
    meta = _read(paths.meta, {})
    try:
        start = datetime.fromisoformat(meta["start_time"]).astimezone()
    except (KeyError, TypeError, ValueError):
        start = None
    title, _ = titles.resolve(paths)
    title = re.sub(r"[\x00-\x1f/\\:*?\"<>|]+", " ", title or "Meeting")
    title = " ".join(title.split())[:80].strip(" .") or "Meeting"
    return f"{start:%Y-%m-%d} {title}{SUFFIX}" if start else f"{title}{SUFFIX}"


def _read(path: Path, default: Any = None) -> Any:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def _status_ready(paths: RecordingPaths) -> bool:
    from .cli import _status
    from .live import worker_running

    return _status(paths) in ("processed", "synced") and not worker_running(paths.folder)


def _lanes(paths: RecordingPaths, user_name: str) -> tuple[list[dict], list[dict], list[dict], str]:
    """The transcript, turns and speakers as the export has them, the
    exporter's microphone a lane of its own; and that lane's label."""
    merges = load_merges(paths)
    ignored = load_ignored(paths)
    utterances = [Utterance.from_dict(d) for d in _read(paths.transcript_json, [])]
    turns = [SpeakerTurn.from_dict(d) for d in _read(paths.system_turns, [])]
    labels = {t.speaker for t in turns} | {u.label or u.speaker for u in utterances if not notes_mod._is_mic(u)}
    numbers = [int(x.rsplit("_", 1)[1]) for x in labels if re.fullmatch(_LABEL, x)]
    mic = f"SPEAKER_{max(numbers, default=-1) + 1:02d}"
    lane = lambda label: merges.get(label, label)  # noqa: E731

    names = names_in_effect(paths)
    manual = {k: v for k, v in load_speaker_names(paths).items() if v != k}
    recognized = load_recognized_names(paths)
    inferred = load_inferred_names(paths)
    shown = lambda label: names.get(label) or label  # noqa: E731
    exporter = None if shared_mic.mic_room(paths) is not None else user_name

    transcript, mic_turns = [], []
    for u in utterances:
        if notes_mod._is_mic(u):
            transcript.append({"start": round(u.start, 3), "end": round(u.end, 3), "text": u.text, "label": mic,
                               "speaker": exporter or "Several people"})
            mic_turns.append({"speaker": mic, "start": round(u.start, 3), "end": round(u.end, 3)})
            continue
        label = lane(u.label or u.speaker)
        if label in ignored or not re.fullmatch(_LABEL, label):
            continue
        transcript.append({"start": round(u.start, 3), "end": round(u.end, 3), "text": u.text, "label": label,
                           "speaker": shown(label)})
    out_turns = [{"speaker": lane(t.speaker), "start": round(t.start, 3), "end": round(t.end, 3)}
                 for t in turns if lane(t.speaker) not in ignored and re.fullmatch(_LABEL, lane(t.speaker))]
    out_turns = sorted(out_turns + mic_turns, key=lambda t: (t["start"], t["speaker"]))

    speakers = []
    for label in sorted({t["speaker"] for t in out_turns} | {t["label"] for t in transcript}):
        if label == mic:
            speakers.append({"label": mic, "name": exporter, "how": "exporter" if exporter else None})
            continue
        name = names.get(label)
        how = None
        if name:
            how = ("hand" if label in manual else "voice" if label in recognized
                   else "inferred" if label in inferred else "hand")  # a merged label: named as its person
        speakers.append({"label": label, "name": name, "how": how})
    return transcript, out_turns, speakers, mic


def _notes(paths: RecordingPaths) -> dict | None:
    """The notes as they travel: without what came from the exporter's own
    notes (#44), and without the hashes of their files."""
    current = notes_mod.load(paths)
    if not current:
        return None
    mine = set(current.get("decisions_mine") or [])
    out = {k: current[k] for k in _NOTES_KEYS if k in current}
    out["sections"] = [{"heading": s.get("heading", ""),
                        "points": [{"text": p.get("text", ""), "details": list(p.get("details") or [])}
                                   for p in s.get("points", []) if not p.get("mine")]}
                       for s in current.get("sections", [])]
    out["next_steps"] = [{"owner": s.get("owner", ""), "task": s.get("task", "")}
                         for s in current.get("next_steps", []) if not s.get("mine")]
    out["decisions"] = [d for i, d in enumerate(current.get("decisions", [])) if i not in mine]
    out["speaker_names"] = [{"label": g.get("label", ""), "name": g.get("name", ""), "evidence": g.get("evidence", "")}
                            for g in current.get("speaker_names", [])]
    out.setdefault("summary", "")
    return out


def _calendar(paths: RecordingPaths) -> dict | None:
    event = calendar_events.load(paths)
    if event is None:
        return None
    return {"uid": event.uid, "start": event.start.isoformat(), "end": event.end.isoformat(), "title": event.title,
            "series": event.series,
            "attendees": [{"name": a.name, "email": a.email, "organizer": a.organizer, "response": a.response,
                           "room": a.is_room} for a in event.attendees]}


def _encode_audio(wav: Path, dest_dir: Path, track: str) -> Path:
    """``wav`` compressed: Opus at the rates it takes, else FLAC. Block by
    block, so an hour of audio is never in memory at once."""
    info = sf.info(str(wav))
    if info.samplerate in _OPUS_RATES:
        out, kwargs = dest_dir / f"{track}.opus", {"format": "OGG", "subtype": "OPUS"}
    else:
        out, kwargs = dest_dir / f"{track}.flac", {"format": "FLAC", "subtype": "PCM_16"}
    with sf.SoundFile(str(out), "w", samplerate=info.samplerate, channels=info.channels, **kwargs) as dst:
        for block in sf.blocks(str(wav), blocksize=info.samplerate * 10, dtype="float32", always_2d=True):
            dst.write(block)
    return out


def export_meeting(paths: RecordingPaths, dest: Path, *, user_name: str, notes: bool = True, voices: bool = False,
                   audio: bool = False, confirm_local: bool = False, projects: Iterable[str] = ()) -> Path:
    """Write the meeting to ``dest`` (a ``.palaver`` file; written beside
    it first, then renamed, so a half-written file is never seen). A
    meeting kept on this Mac raises ``KeptOnThisMac`` unless the user said
    yes (``confirm_local``). ``projects``: the exporter's project names, a
    hint for the importer."""
    if not _status_ready(paths):
        raise NotReady("Only a finished, transcribed meeting can be exported.")
    if paths.local_only.exists() and not confirm_local:
        raise KeptOnThisMac(paths.folder.name)
    meta = _read(paths.meta, {})
    start = datetime.fromisoformat(meta["start_time"])
    duration = float(meta.get("duration_seconds") or 0.0)
    transcript, turns, speakers, _ = _lanes(paths, user_name)
    title, _ = titles.resolve(paths)
    language = paths.language.read_text().strip()[:16] if paths.language.exists() else None
    files: dict[str, bytes | Path] = {
        "meeting/meta.json": _bytes({"start": start.isoformat(), "end": (start + timedelta(seconds=duration)).isoformat(),
                                     "duration": duration, "title": title, "language": language or None,
                                     "projects": sorted(set(projects)),
                                     "kept_on_this_mac": paths.local_only.exists()}),
        "meeting/transcript.json": _bytes(transcript),
        "meeting/turns.json": _bytes(turns),
        "meeting/speakers.json": _bytes(speakers),
    }
    if (event := _calendar(paths)) is not None:
        files["meeting/calendar.json"] = _bytes(event)
    if notes and (meeting_notes := _notes(paths)) is not None:
        files["meeting/notes.json"] = _bytes(meeting_notes)
    if voices:
        embeddings = _read(paths.speaker_embeddings, {}) or {}
        merges = load_merges(paths)
        for s in speakers:
            if s["how"] not in ("hand", "voice"):
                continue  # a guess teaches no voice; the exporter's own microphone has none
            vector = embeddings.get(s["label"]) or next(
                (embeddings[k] for k, into in merges.items() if into == s["label"] and k in embeddings), None)
            if vector:
                files[f"voices/{s['label']}.json"] = _bytes({"label": s["label"], "name": s["name"],
                                                             "embedding": [float(x) for x in vector]})
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=dest.parent, prefix=".palaver-export-") as tmp:
        tmp = Path(tmp)
        if audio:
            for track, wav in (("system", paths.system_wav), ("mic", paths.mic_wav if paths.mic_wav.exists()
                                                             else paths.mic_raw_wav)):
                if wav.exists():
                    out = _encode_audio(wav, tmp, track)
                    files[f"audio/{out.name}"] = out
        listed = {}
        for name, content in files.items():
            if isinstance(content, Path):
                listed[name] = {"sha256": _sha256(content), "bytes": content.stat().st_size}
            else:
                listed[name] = {"sha256": hashlib.sha256(content).hexdigest(), "bytes": len(content)}
        manifest = {"format": FORMAT, "palaver_version": __version__,
                    "exported_at": datetime.now().astimezone().isoformat(timespec="seconds"),
                    "exported_by": user_name, "files": listed}
        part = tmp / "out.palaver"
        with zipfile.ZipFile(part, "w") as zf:
            zf.writestr("manifest.json", _bytes(manifest), compress_type=zipfile.ZIP_DEFLATED)
            for name, content in files.items():
                if isinstance(content, Path):  # compressed audio: deflating it again gains nothing
                    zf.write(content, name, compress_type=zipfile.ZIP_STORED)
                else:
                    zf.writestr(name, content, compress_type=zipfile.ZIP_DEFLATED)
        os.replace(part, dest)
    return dest


def sweep(output_dir: Path, downloads: Path | None = None, *, older_than: float = 3600) -> None:
    """What imports and exports left behind when the server stopped half-way
    through one: staging folders, and temporary folders beside exports."""
    import time

    old = time.time() - older_than
    leftovers = [*Path(output_dir, STAGING).glob("*")]
    if downloads is not None:
        leftovers += Path(downloads).glob(".palaver-export-*")
    for path in leftovers:
        try:
            if path.is_dir() and not path.is_symlink() and path.stat().st_mtime < old:
                shutil.rmtree(path, ignore_errors=True)
        except OSError:
            pass


def free_name(folder: Path, name: str) -> Path:
    """``folder/name``, or ``name 2``, ``name 3`` … when that is taken."""
    target = folder / name
    stem, suffix = name[: -len(SUFFIX)] if name.endswith(SUFFIX) else name, SUFFIX if name.endswith(SUFFIX) else ""
    n = 2
    while target.exists():
        target = folder / f"{stem} {n}{suffix}"
        n += 1
    return target


# --- reading a file -----------------------------------------------------------------


@dataclass
class Package:
    """A ``.palaver`` file, checked: everything but the audio read and
    validated; the audio checked when it is copied out."""
    path: Path
    manifest: dict
    meta: dict
    transcript: list[dict]
    turns: list[dict]
    speakers: list[dict]
    calendar: dict | None = None
    notes: dict | None = None
    voices: dict[str, dict] = field(default_factory=dict)  # label → {label, name, embedding}
    audio: list[str] = field(default_factory=list)  # entry names under audio/

    @property
    def sender(self) -> str:
        return self.manifest["exported_by"]

    @property
    def start(self) -> datetime:
        return _time(self.meta["start"], "meta.json start")

    @property
    def end(self) -> datetime:
        return _time(self.meta["end"], "meta.json end")

    def event(self, user_name: str = "") -> calendar_events.Event | None:
        """The exporter's event, seen from here: the user, if invited, is "self"."""
        c = self.calendar
        if c is None:
            return None
        me = calendar_events.person_name(user_name).casefold() if user_name.strip() else ""
        return calendar_events.Event(
            title=c["title"], start=_time(c["start"], "calendar.json start"), end=_time(c["end"], "calendar.json end"),
            attendees=tuple(calendar_events.Attendee(
                calendar_events.person_name(a["name"]), a.get("email"), bool(a.get("organizer")),
                a.get("response", "unknown"), bool(me) and calendar_events.person_name(a["name"]).casefold() == me,
                bool(a.get("room")) or calendar_events.looks_like_room(a["name"]))
                for a in c["attendees"]),
            source=IMPORTED, uid=c["uid"], series=bool(c.get("series")))


def _unsafe(name: str) -> bool:
    return (name.startswith(("/", "\\")) or "\\" in name or ":" in name
            or any(part in ("", ".", "..") for part in name.split("/")))


def _cap(name: str) -> int:
    return MAX_AUDIO_BYTES if name.startswith("audio/") else MAX_JSON_BYTES


def _entries(zf: zipfile.ZipFile) -> dict[str, zipfile.ZipInfo]:
    """The zip's entries, refused unless every one is a file we know, of a
    size we take, stored plainly or deflated, not encrypted, not a link."""
    infos = zf.infolist()
    if len(infos) > MAX_ENTRIES:
        raise Rejected(f"The file has {len(infos)} entries; a Palaver file has at most {MAX_ENTRIES}.")
    out: dict[str, zipfile.ZipInfo] = {}
    total = 0
    for info in infos:
        name = info.filename
        if _unsafe(name):
            raise Rejected(f"The file has an unsafe path: {name[:80]!r}.")
        if stat.S_ISLNK(info.external_attr >> 16):
            raise Rejected(f"The file has a link, which Palaver never follows: {name[:80]!r}.")
        if not _NAME.fullmatch(name):
            raise Rejected(f"The file has {name[:80]!r}, which is not part of a Palaver file.")
        if name in out:
            raise Rejected(f"The file has {name!r} twice.")
        if info.flag_bits & 0x1:
            raise Rejected("The file is encrypted.")
        if info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
            raise Rejected(f"{name!r} is compressed in a way Palaver does not read.")
        if info.file_size > _cap(name):
            raise Rejected(f"{name!r} is too large ({info.file_size // (1024 * 1024)} MB).")
        total += info.file_size
        out[name] = info
    if total > MAX_TOTAL_BYTES:
        raise Rejected(f"The file is too large ({total // (1024 * 1024)} MB unpacked).")
    return out


def _read_entry(zf: zipfile.ZipFile, info: zipfile.ZipInfo, expected: dict, sink=None) -> bytes:
    """The entry's bytes (or, with ``sink``, written there), never more than
    its cap whatever its header says, and checked against the manifest."""
    cap, size, digest, chunks = _cap(info.filename), 0, hashlib.sha256(), []
    try:
        with zf.open(info) as f:
            for chunk in iter(lambda: f.read(_CHUNK), b""):
                size += len(chunk)
                if size > cap:
                    raise Rejected(f"{info.filename!r} is larger than it says.")
                digest.update(chunk)
                if sink is None:
                    chunks.append(chunk)
                else:
                    sink.write(chunk)
    except (zipfile.BadZipFile, zlib.error, EOFError) as exc:
        raise Rejected(f"{info.filename!r} is damaged ({exc}).") from None
    if digest.hexdigest() != expected["sha256"] or size != expected["bytes"]:
        raise Rejected(f"{info.filename!r} does not match its checksum: the file was changed or damaged.")
    return b"".join(chunks)


def _precheck(path: Path) -> None:
    """The file's size and its zip's table of contents, read from its end
    record before zipfile reads (and keeps in memory) the table itself."""
    try:
        size = path.stat().st_size
        if size > MAX_FILE_BYTES:
            raise Rejected(f"The file is too large ({size // (1024 * 1024)} MB).")
        with path.open("rb") as f:
            f.seek(max(0, size - 22 - 0xFFFF))  # the end record, behind at most a 64 KB comment
            tail = f.read()
    except OSError:
        raise Rejected("This is not a Palaver file (it can't be read).") from None
    at = tail.rfind(_END_OF_DIRECTORY)
    if at < 0 or len(tail) - at < 22:
        raise Rejected("This is not a Palaver file (it is not a zip).")
    entries = int.from_bytes(tail[at + 10:at + 12], "little")
    directory = int.from_bytes(tail[at + 12:at + 16], "little")
    if entries > MAX_ENTRIES:
        raise Rejected(f"The file has {entries} entries; a Palaver file has at most {MAX_ENTRIES}.")
    if directory > MAX_DIRECTORY_BYTES:
        raise Rejected("The file's table of contents is too large for a Palaver file.")


def read_package(path: Path) -> Package:
    """Open and check a ``.palaver`` file (all but the audio's content,
    which ``import_package`` checks as it copies it). Raises ``Rejected``."""
    path = Path(path)
    _precheck(path)
    try:
        zf = zipfile.ZipFile(path)
    except (zipfile.BadZipFile, OSError, ValueError):
        raise Rejected("This is not a Palaver file (it is not a zip).") from None
    with zf:
        entries = _entries(zf)
        if "manifest.json" not in entries:
            raise Rejected("This is not a Palaver file: it has no manifest.")
        manifest_info = entries.pop("manifest.json")
        if manifest_info.file_size > MAX_JSON_BYTES:
            raise Rejected("The manifest is too large.")
        try:
            with zf.open(manifest_info) as f:
                raw = f.read(MAX_JSON_BYTES + 1)
        except (zipfile.BadZipFile, zlib.error, EOFError, OSError) as exc:
            raise Rejected(f"The manifest is damaged ({exc}).") from None
        if len(raw) > MAX_JSON_BYTES:
            raise Rejected("The manifest is too large.")
        manifest = _json(raw, "manifest.json")
        if isinstance(manifest, dict) and manifest.get("format") != FORMAT and isinstance(manifest.get("format"), int):
            newer = manifest["format"] > FORMAT
            raise Rejected(f"This file has format {manifest['format']}; this Palaver reads format {FORMAT}."
                           + (" Update Palaver to import it." if newer else ""))
        check(manifest, MANIFEST, "manifest.json")
        _time(manifest["exported_at"], "manifest.json exported_at")
        listed = manifest["files"]
        if set(listed) != set(entries):
            missing, extra = sorted(set(listed) - set(entries)), sorted(set(entries) - set(listed))
            raise Rejected("The file does not match its manifest: "
                           + (f"{missing[0]!r} is missing" if missing else f"{extra[0]!r} is not listed") + ".")
        if not _REQUIRED <= set(entries):
            raise Rejected(f"The file lacks {sorted(_REQUIRED - set(entries))[0]!r}.")
        docs: dict[str, Any] = {}
        voices: dict[str, dict] = {}
        for name, info in entries.items():
            if name.startswith("audio/"):
                continue
            doc = _json(_read_entry(zf, info, listed[name]), name)
            if name.startswith("voices/"):
                check(doc, VOICE, name)
                if f"voices/{doc['label']}.json" != name:
                    raise Rejected(f"{name!r} is the voice of {doc['label']}.")
                voices[doc["label"]] = doc
            else:
                check(doc, SCHEMAS[name], name)
                docs[name] = doc
    package = Package(path=path, manifest=manifest, meta=docs["meeting/meta.json"],
                      transcript=docs["meeting/transcript.json"], turns=docs["meeting/turns.json"],
                      speakers=docs["meeting/speakers.json"], calendar=docs.get("meeting/calendar.json"),
                      notes=docs.get("meeting/notes.json"), voices=voices,
                      audio=sorted(n for n in entries if n.startswith("audio/")))
    _consistent(package)
    return package


def _consistent(p: Package) -> None:
    """What a schema can't say: times that fit the meeting, one entry per
    label, voices only of named people, one audio file per track."""
    start, end = p.start, p.end
    if end < start or (end - start).total_seconds() > MAX_SECONDS:
        raise Rejected("meta.json: the meeting ends before it starts, or lasts too long.")
    limit = float(p.meta["duration"]) + 60
    for what, items in (("transcript.json", p.transcript), ("turns.json", p.turns)):
        for i, x in enumerate(items):
            if not x["start"] <= x["end"] <= limit:
                raise Rejected(f"{what}[{i}] is not within the meeting.")
    if p.calendar is not None:
        _time(p.calendar["start"], "calendar.json start")
        _time(p.calendar["end"], "calendar.json end")
    labels = [s["label"] for s in p.speakers]
    if len(labels) != len(set(labels)):
        raise Rejected("speakers.json names a label twice.")
    named = {s["label"]: s["name"] for s in p.speakers if s["name"]}
    for label, voice in p.voices.items():
        if named.get(label) != voice["name"]:
            raise Rejected(f"voices/{label}.json is not the voice of a person named in speakers.json.")
    tracks = [n.split("/")[1].split(".")[0] for n in p.audio]
    if len(tracks) != len(set(tracks)):
        raise Rejected("The file has a track twice.")


# --- matching -------------------------------------------------------------------------


def _span(paths: RecordingPaths) -> tuple[datetime, datetime] | None:
    meta = _read(paths.meta, {}) or {}
    try:
        start = datetime.fromisoformat(meta["start_time"])
    except (KeyError, TypeError, ValueError):
        return None
    return start, start + timedelta(seconds=float(meta.get("duration_seconds") or 0.0))


def _people(event: calendar_events.Event | None) -> set[str]:
    """Who was invited, by email where there is one, else by name."""
    if event is None:
        return set()
    return {(a.email or a.name).casefold().strip() for a in event.attendees if not a.is_room}


def find_match(output_dir: Path, package: Package) -> Match | None:
    """The meeting here that is the one in the file: the same calendar
    occurrence (iCal UID and start); else one that overlaps it by more
    than half, with someone invited to both. None: a meeting of its own."""
    theirs = package.event()
    span = (package.start, package.end)
    by_overlap: list[tuple[float, str]] = []
    if not output_dir.is_dir():
        return None
    folders = [f for f in sorted(output_dir.iterdir()) if f.is_dir() and is_recording_folder_name(f.name)]
    for folder in folders:
        paths = RecordingPaths(folder)
        mine = calendar_events.load(paths)
        own = not paths.imported.exists()
        if theirs is not None and mine is not None and theirs.uid and mine.uid \
                and mine.series_id == theirs.series_id and abs((mine.start - theirs.start).total_seconds()) < 60:
            return Match(folder.name, "event", own)
        here = _span(paths)
        if here is None or not (_people(theirs) & _people(mine)):
            continue
        overlap = (min(here[1], span[1]) - max(here[0], span[0])).total_seconds()
        shorter = min((here[1] - here[0]).total_seconds(), (span[1] - span[0]).total_seconds())
        if shorter > 0 and overlap > 0.5 * shorter:
            by_overlap.append((overlap, folder.name))
    if not by_overlap:
        return None
    best = max(by_overlap)[1]
    return Match(best, "overlap", not RecordingPaths(output_dir / best).imported.exists())


# --- import ---------------------------------------------------------------------------


@dataclass
class Imported:
    id: str
    sender: str
    matched: Match | None  # the meeting it was imported beside, as a separate meeting
    voices: list[dict]  # [{label, name}] waiting for the user's yes
    names: dict[str, str]  # label → name hinted
    warnings: list[str] = field(default_factory=list)  # what was left out, in words for the user


def load_record(paths: RecordingPaths) -> dict | None:
    """What came with an imported meeting (imported.json), or None."""
    record = _read(paths.imported)
    return record if isinstance(record, dict) else None


def hints(paths: RecordingPaths) -> dict[str, dict]:
    """label → the inferred-name entry (as inference.py stores them) of a
    name that came with the import."""
    record = load_record(paths)
    if not record:
        return {}
    sender = str(record.get("from") or "the sender")
    out = {}
    for label, hint in (record.get("names") or {}).items():
        if not isinstance(hint, dict) or not hint.get("name"):
            continue
        how = hint.get("how") if hint.get("how") in HOWS else "inferred"
        out[label] = {"name": hint["name"], "rule": IMPORTED, "why": _why(how, sender),
                      "confidence": HINT_CONFIDENCE[how], "depends": [], "by": sender, "how": how}
    return out


def _why(how: str, sender: str) -> str:
    return {"exporter": f"{sender}'s own microphone in their recording.",
            "hand": f"Named by {sender} in their recording.",
            "voice": f"{sender}'s Palaver recognized the voice.",
            "inferred": f"{sender}'s Palaver inferred the name."}[how]


def _new_folder(output_dir: Path, start: datetime) -> str:
    base = start.astimezone().strftime("%Y-%m-%dT%H-%M-%S")
    name, n = base, 2
    while (output_dir / name).exists():
        name, n = f"{base}-{n}", n + 1
    return name


def _free_bytes(path: Path) -> int:
    return shutil.disk_usage(path).free


def _write_audio(zf: zipfile.ZipFile, package: Package, staging: Path, folder: Path) -> None:
    """The tracks out of the file (checked against the manifest as they are
    copied), decoded and mixed into the one system track the window plays:
    the sender's microphone is a remote voice here, its lane's clips are
    cut from there, and the user has no microphone in a meeting they were
    not in. One rate, the system track's (the microphone's is resampled)."""
    tracks: dict[str, Path] = {}
    for name in package.audio:
        raw = staging / name.replace("/", "-")
        with raw.open("wb") as sink:
            _read_entry(zf, zf.getinfo(name), package.manifest["files"][name], sink)
        tracks[name.split("/")[1].split(".")[0]] = raw
    if not tracks:
        return
    infos = {}
    for track, raw in tracks.items():
        try:
            info = sf.info(str(raw))
        except (RuntimeError, sf.LibsndfileError):
            raise Rejected(f"The {track} audio can't be read.") from None
        if not (8000 <= info.samplerate <= 48000) or info.channels not in (1, 2) \
                or info.frames / info.samplerate > float(package.meta["duration"]) + 60:
            raise Rejected(f"The {track} audio does not fit the meeting.")
        infos[track] = info
    rate = infos["system"].samplerate if "system" in infos else infos["mic"].samplerate
    frames = max(int(i.frames * rate / i.samplerate) + 1 for i in infos.values())
    if _free_bytes(staging) - (44 + 2 * frames) < MIN_FREE_BYTES:
        raise Rejected("Not enough free disk space for its audio: import it without, or make room first.")
    _decode_mixed([tracks[t] for t in ("system", "mic") if t in tracks], rate, RecordingPaths(folder).system_wav)


def _decode_mixed(sources: list[Path], rate: int, dest: Path) -> None:
    """``sources`` mixed into one 16-bit mono WAV at ``rate``, block by block."""
    import soxr

    files = []
    try:
        files += [sf.SoundFile(str(s)) for s in sources]
        streams = [None if f.samplerate == rate else soxr.ResampleStream(f.samplerate, rate, 1, dtype="float32")
                   for f in files]
        with sf.SoundFile(str(dest), "w", samplerate=rate, channels=1, subtype="PCM_16", format="WAV") as out:
            done = [False] * len(files)
            while not all(done):
                parts = []
                for i, (f, stream) in enumerate(zip(files, streams)):
                    if done[i]:
                        continue
                    block = f.read(f.samplerate * 10, dtype="float32", always_2d=True).mean(axis=1)
                    done[i] = len(block) == 0
                    if stream is not None:
                        block = stream.resample_chunk(np.ascontiguousarray(block, dtype=np.float32), last=done[i])
                    parts.append(block)
                n = max((len(p) for p in parts), default=0)
                if n == 0:
                    continue
                mix = np.zeros(n, dtype=np.float32)
                for part in parts:
                    mix[: len(part)] += part
                out.write(np.clip(mix, -1.0, 1.0))
    except (RuntimeError, sf.LibsndfileError, ValueError) as exc:
        raise Rejected(f"The audio can't be decoded ({exc}).") from None
    finally:
        for f in files:
            f.close()


def _event_here(package: Package, user_name: str, calendar) -> tuple[calendar_events.Event, Link] | None:
    """The event to link: the same occurrence in this Mac's calendar, when
    it can be asked; else the exporter's, seen from here."""
    theirs = package.event(user_name)
    if theirs is None:
        return None
    sender = package.sender
    if calendar is not None and theirs.uid:
        try:
            found = calendar(theirs.start - timedelta(minutes=5), theirs.end + timedelta(minutes=5))
        except Exception:  # no calendar is no reason to fail the import
            found = []
        for event in found:
            if event.uid and event.series_id == theirs.series_id and abs((event.start - theirs.start).total_seconds()) < 60:
                return event, Link("event", event.title, IMPORTED, None, f"the event of {sender}'s recording")
    return theirs, Link("event", theirs.title, IMPORTED, None, f"the event of {sender}'s recording")


def _title_of_their_own(package: Package) -> str | None:
    """The exporter's title, when it is neither the event's nor the notes':
    one they gave it."""
    title = (package.meta.get("title") or "").strip()
    known = {(package.calendar or {}).get("title"), (package.notes or {}).get("title")}
    return title if title and title not in known else None


@dataclass
class Staged:
    """A meeting built from a file, beside the recordings, not yet among them."""
    package: Package
    match: Match | None
    staging: Path
    names: dict[str, str]
    warnings: list[str] = field(default_factory=list)

    @property
    def folder(self) -> Path:
        return self.staging / "meeting"

    def discard(self) -> None:
        shutil.rmtree(self.staging, ignore_errors=True)
        try:
            self.staging.parent.rmdir()
        except OSError:
            pass


def stage(output_dir: Path, package: Package, *, user_name: str, separate: bool = False, calendar=None) -> Staged:
    """Build the meeting of ``package`` in ``<output>/.importing``: the
    slow part (copying, checking, decoding), done before anything else is
    held. The same meeting here already raises ``Collision`` unless
    ``separate`` (then it goes beside it, linked to the same event).
    ``calendar``: this Mac's calendar, ``(start, end) -> events``."""
    output_dir = Path(output_dir)
    match = find_match(output_dir, package)
    if match is not None and not separate:
        raise Collision(match, package.sender)
    staging_root = output_dir / STAGING
    staging_root.mkdir(parents=True, exist_ok=True)
    staged = Staged(package, match, staging_root / uuid.uuid4().hex, {})
    package.voices, left_out = fitting_voices(output_dir, package.voices)
    if left_out:
        staged.warnings.append(f"{left_out} voice{'s were' if left_out > 1 else ' was'} left out: they were made "
                               "by another voice model than this Mac's.")
    staged.staging.mkdir()
    try:
        staged.folder.mkdir()
        with zipfile.ZipFile(package.path) as zf:
            _write_audio(zf, package, staged.staging, staged.folder)
        staged.names = _write_meeting(RecordingPaths(staged.folder), package, user_name=user_name,
                                      calendar=calendar, beside=match, output_dir=output_dir)
    except BaseException:
        staged.discard()
        raise
    return staged


def place(output_dir: Path, staged: Staged, *, after: Callable[[str], None] | None = None) -> Imported:
    """Move a staged meeting among the recordings, in one rename (the list
    sees all of it or nothing); ``after(id)`` then works out what follows
    here (projects, names)."""
    output_dir = Path(output_dir)
    package = staged.package
    meeting_id = _new_folder(output_dir, package.start)
    while True:
        try:
            os.rename(staged.folder, output_dir / meeting_id)
            break
        except OSError:
            if not (output_dir / meeting_id).exists():
                raise
            meeting_id = _new_folder(output_dir, package.start)
    if after is not None:
        try:
            after(meeting_id)
        except BaseException:  # never a meeting among the recordings that what follows chokes on
            from . import cutting

            cutting.trash(RecordingPaths(output_dir / meeting_id))
            raise
    pending = load_record(RecordingPaths(output_dir / meeting_id)).get("voices_pending", [])
    return Imported(meeting_id, package.sender, staged.match,
                    [{"label": label, "name": package.voices[label]["name"]} for label in pending], staged.names,
                    staged.warnings)


def import_package(output_dir: Path, file: Path, *, user_name: str, separate: bool = False, calendar=None,
                   package: Package | None = None, after: Callable[[str], None] | None = None) -> Imported:
    """``stage`` and ``place`` in one: the meeting in ``file`` as a meeting of its own."""
    staged = stage(output_dir, package or read_package(file), user_name=user_name, separate=separate,
                   calendar=calendar)
    try:
        return place(output_dir, staged, after=after)
    finally:
        staged.discard()


def _write_meeting(paths: RecordingPaths, package: Package, *, user_name: str, calendar, beside: Match | None,
                   output_dir: Path) -> dict[str, str]:
    """The meeting's files in ``paths`` (the staging folder); returns the
    names hinted."""
    start = package.start
    duration = float(package.meta["duration"])
    paths.meta.write_text(json.dumps({"start_time": start.isoformat(), "duration_seconds": duration}, indent=2))
    if package.meta.get("language"):
        paths.language.write_text(package.meta["language"])
    paths.system_turns.write_text(json.dumps(package.turns))
    utterances = [Utterance(s["label"], s["start"], s["end"], s["text"]) for s in package.transcript]
    paths.transcript_json.write_text(json.dumps([u.to_dict() for u in utterances], indent=2))
    named = {s["label"]: {"name": s["name"], "how": s["how"] or "hand"} for s in package.speakers if s["name"]}
    if package.voices:  # apart, until the user says yes (decide_voices)
        paths.imported_voices.write_text(json.dumps({label: v["embedding"] for label, v in package.voices.items()}))
    record = {
        "from": package.sender, "format": package.manifest["format"],
        "palaver_version": package.manifest["palaver_version"], "exported_at": package.manifest["exported_at"],
        "imported_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "file": package.path.name[:200], "projects": list(package.meta.get("projects") or []),
        "names": named, "voices_pending": sorted(package.voices),
        "beside": None if beside is None else {"meeting": beside.id, "how": beside.how},
        "title": _title_of_their_own(package),  # theirs, not the user's: under a title the user gives it
    }
    paths.imported.write_text(json.dumps(record, indent=2, ensure_ascii=False))
    if package.meta.get("kept_on_this_mac"):  # the sender kept it on their Mac: so does this one, until lifted
        from .llm import set_local_only

        set_local_only(paths.folder, True)
    # The names are hints: stored as inferred names (inference.refresh keeps them), confirmed by the user.
    hinted = hints(paths)
    if hinted:
        paths.speakers_inferred.write_text(json.dumps(hinted, indent=2, ensure_ascii=False))
    linked = None
    if beside is not None:  # beside the user's own: the event as it is linked there
        there = RecordingPaths(output_dir / beside.id)
        event = calendar_events.load(there)
        if event is not None:
            linked = (event, Link("event", event.title, IMPORTED, None, "the event of your own recording"))
    linked = linked or _event_here(package, user_name, calendar)
    if linked is not None:
        calendar_events.save(paths, *linked)
    save_speaker_names(paths, {}, learn=False)
    if package.notes is not None:
        final = [Utterance.from_dict(d) for d in json.loads(paths.transcript_json.read_text())]
        notes_mod.save(paths, {**package.notes, "transcript_hash": notes_mod.transcript_hash(final)})
    return {label: h["name"] for label, h in named.items()}


def confirmed_projects(meeting_id: str) -> list[str]:
    """The projects the user put the meeting in (not the rules' or the
    model's proposals): the exporter's hint for the importer."""
    from . import projects

    store = projects.ProjectStore()
    named = store.projects()
    return sorted(named[pid]["name"] for pid, how in store.of_meeting(meeting_id).items()
                  if pid in named and how.get("by") == "you")


def settle(output_dir: Path, meeting_id: str, *, user_name: str) -> None:
    """What is worked out here for an imported meeting: its projects, by
    the rules, else the exporter's project of the same name here as a
    suggestion to confirm; voices the bank knows and the names that follow
    (search indexes it in the background, like any meeting)."""
    from . import people, projects

    store = projects.ProjectStore()
    if not projects.assign_by_rules(output_dir, store, user_name=user_name, meetings=[meeting_id]):
        record = load_record(RecordingPaths(output_dir / meeting_id)) or {}
        for name in record.get("projects") or []:
            pid = store.find(str(name))
            if pid and store.assign(meeting_id, pid, by="auto", why=f"{record.get('from')} filed it under {name}",
                                    confidence=0.6):
                break
    store.save()
    people.refresh_recognition(output_dir, user_name=user_name)


def _voice_size(output_dir: Path, bank=None) -> int | None:
    """How many numbers a voice has here: the voice bank's, else a meeting's."""
    from .voices import VoiceBank

    size = (bank or VoiceBank()).size()
    if size or not output_dir.is_dir():
        return size
    for folder in sorted(output_dir.iterdir()):
        if folder.is_dir() and is_recording_folder_name(folder.name):
            vectors = _read(RecordingPaths(folder).speaker_embeddings, {}) or {}
            for vector in vectors.values() if isinstance(vectors, dict) else ():
                if isinstance(vector, list) and vector:
                    return len(vector)
    return None


def fitting_voices(output_dir: Path, voices: dict[str, dict], bank=None) -> tuple[dict[str, dict], int]:
    """The voices comparable with the ones here (made by the same voice
    model: as many numbers), and how many were left out. With none here,
    those of the size most of them have."""
    size = _voice_size(Path(output_dir), bank)
    if size is None and voices:
        sizes = [len(v["embedding"]) for v in voices.values()]
        size = max(set(sizes), key=sizes.count)
    kept = {label: v for label, v in voices.items() if len(v["embedding"]) == size}
    return kept, len(voices) - len(kept)


def decide_voices(paths: RecordingPaths, add: bool, *, user_name: str = "", bank=None) -> list[str]:
    """The user's answer about the voices that came with an import. Yes:
    they join the meeting's own voices, and the names they came with count
    as given by the user here, which teaches the voice bank (as naming a
    speaker by hand does), then voices are recognized everywhere again; a
    name the user said a voice is not is skipped, voice and all. No: they
    are deleted. Returns the names whose voices were learned."""
    from . import people
    from .voices import VoiceBank

    record = load_record(paths)
    if not record or not record.get("voices_pending"):
        return []
    pending = {label: v for label, v in (_read(paths.imported_voices, {}) or {}).items()
               if label in record["voices_pending"]}
    learned: list[str] = []
    if add:
        bank = bank or VoiceBank()
        names = load_speaker_names(paths)
        hinted = {label: h["name"] for label, h in hints(paths).items()}
        rejected = load_rejected_names(paths)
        size = _voice_size(paths.folder.parent, bank)  # the bank may have changed since the import
        taken = {}
        for label, vector in sorted(pending.items()):
            if size is not None and len(vector) != size:
                continue
            name = names.get(label) if names.get(label, label) != label else hinted.get(label)
            if not name or name.casefold() in {n.casefold() for n in rejected.get(label, [])}:
                continue
            taken[label] = vector
            if names.get(label, label) == label:
                names[label] = name
            learned.append(name)
        if taken:
            own = _read(paths.speaker_embeddings, {}) or {}
            paths.speaker_embeddings.write_text(json.dumps({**own, **taken}))
        save_speaker_names(paths, names, bank)
    paths.imported_voices.unlink(missing_ok=True)
    record["voices_pending"] = []
    record["voices"] = "added" if add else "declined"
    tmp = paths.imported.with_name(paths.imported.name + ".tmp")
    tmp.write_text(json.dumps(record, indent=2, ensure_ascii=False))
    os.replace(tmp, paths.imported)
    if add:
        people.refresh_recognition(paths.folder.parent, bank, user_name=user_name)
    return learned
