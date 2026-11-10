"""Parity operations, the Python side: each runs in-process on one side of a parity run, with the
side's ``XDG_CONFIG_HOME``, ``HOME`` and ``PALAVER_HOME`` set and the module constants that hold
paths under the home (Application Support, Logs, …) moved into the side's ``home/``.

An op is ``(side: Side, args: dict) -> JSON value``. Its Swift twin, of the same name, is in
``native/Sources/palaver-parity/Ops.swift`` (and ``Ops+<Area>.swift``); later tasks add a section
here and an entry in ``TABLE`` for each area.
"""

from __future__ import annotations

import contextlib
import importlib
import json
import os
import pwd
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterator

# Modules whose constants are paths under the home: imported before a side is set up, so they
# are moved too.
_HOME_MODULES = ("palaver.app_bundle", "palaver.appctl", "palaver.cli", "palaver.daemon", "palaver.mcp_access",
                 "palaver.onboarding", "palaver.report", "palaver.runlog", "palaver.usage")
# What of the home a constant may point into (the checkout may live under the home too).
_UNDER_HOME = frozenset({"Library", "Applications", "Desktop", "Downloads", ".claude.json", ".config", ".cache",
                         ".local"})
_REAL_HOME = Path(pwd.getpwuid(os.getuid()).pw_dir)
_UNSET = ("HF_HOME", "HF_HUB_CACHE")


@dataclass(frozen=True)
class Side:
    root: Path
    recordings: Path   # config.toml's output_dir
    stores: Path       # config/palaver: the config dir
    home: Path         # PALAVER_HOME
    user_name: str
    events: list[dict]  # events.json, the fake calendar


def environment(root: Path) -> dict[str, str]:
    """The variables both sides run with (HF_HOME and HF_HUB_CACHE are unset besides)."""
    home = str(root / "home")
    return {"XDG_CONFIG_HOME": str(root / "config"), "HOME": home, "PALAVER_HOME": home, "TZ": "Europe/Berlin"}


_NOT_A_SIDE = "the parity ops run only on a parity side"


def unsafe_environment(env: dict[str, str], real_home: Path | None = None) -> str | None:
    """Why a side with this environment must not run (the twin of palaver-parity's SideGuard): the ops read and
    write the stores of ``XDG_CONFIG_HOME`` and the home of ``PALAVER_HOME``, so both must be set and neither may
    be the user's real home or its .config. None: safe."""
    real_home = real_home or _REAL_HOME
    real = {real_home.resolve(), (real_home / ".config").resolve()}
    for key in ("XDG_CONFIG_HOME", "PALAVER_HOME"):
        value = env.get(key)
        if not value:
            return f"{key} is not set: {_NOT_A_SIDE}"
        if Path(value).expanduser().resolve() in real:
            return f"{key} is the real home or ~/.config: {_NOT_A_SIDE}"
    return None


def inside(path: Path, root: Path) -> bool:
    """Whether ``path`` is ``root`` or inside it: the existing ancestors of its real path compared with ``root``
    by device and inode (case and firmlink spellings can't slip by). False when ``root`` does not exist."""
    try:
        st = os.stat(os.path.realpath(root))
    except OSError:
        return False
    want = (st.st_dev, st.st_ino)
    real = Path(os.path.realpath(path))
    for p in (real, *real.parents):
        try:
            st = os.stat(p)
        except OSError:
            continue
        if (st.st_dev, st.st_ino) == want:
            return True
    return False


def unsafe_side(root: Path, real_home: Path | None = None) -> str | None:
    """Why ``root`` is no parity side (before anything of it is read): its environment (see
    ``unsafe_environment``), a missing config/palaver/config.toml, or a side that holds the real home."""
    real_home = real_home or _REAL_HOME
    why = unsafe_environment(environment(root), real_home)
    if why:
        return why
    if not (root / "config" / "palaver" / "config.toml").is_file():
        return f"the side has no config/palaver/config.toml: {_NOT_A_SIDE}"
    if inside(real_home, root):
        return f"the side holds the real home: {_NOT_A_SIDE}"
    return None


def _moved(value: Any, homes: set[Path], to: Path) -> Any:
    """``value`` moved from one of ``homes`` to ``to``; None when it is no such path."""
    if isinstance(value, Path):
        for home in homes:
            try:
                rel = value.relative_to(home)
            except ValueError:
                continue
            if rel.parts and rel.parts[0] in _UNDER_HOME:
                return to / rel
        return None
    if isinstance(value, tuple) and value and all(isinstance(v, Path) for v in value):
        moved = tuple(_moved(v, homes, to) or v for v in value)
        return moved if moved != value else None
    return None


def _constants(homes: set[Path], to: Path) -> list[tuple[Any, str, Any]]:
    """Move the palaver modules' home paths; returns (module, name, old value) of each."""
    changed = []
    for name, module in list(sys.modules.items()):
        if module is None or not (name == "palaver" or name.startswith("palaver.")):
            continue
        for attr, value in list(vars(module).items()):
            moved = _moved(value, homes, to)
            if moved is not None:
                changed.append((module, attr, value))
                setattr(module, attr, moved)
    return changed


def _side_mcp_paths(home: Path) -> list[tuple[Any, str, Any]]:
    """mcp_access's files as the app has them in ``home`` (the root conftest moves them to a temporary folder of each
    test, which neither side's server would read), and Claude Desktop where palaver-server looks for it: the Mac's own
    /Applications (only whether it is there is read). Returns (module, name, old value) of each."""
    from palaver import mcp_access

    support = home / "Library" / "Application Support"
    paths = {"LOG_PATH": support / "palaver" / "mcp-access.jsonl", "PROCESS_DIR": support / "palaver" / "mcp",
             "CLAUDE_CONFIG": home / ".claude.json", "DESKTOP_CONFIG": support / "Claude" / "claude_desktop_config.json",
             "DESKTOP_APP": Path("/Applications/Claude.app")}
    changed = [(mcp_access, name, getattr(mcp_access, name)) for name in paths]
    for name, value in paths.items():
        setattr(mcp_access, name, value)
    return changed


@contextlib.contextmanager
def patched(root: Path) -> Iterator[None]:
    """Python as it runs on side ``root``: the environment and the home's constants."""
    for name in _HOME_MODULES:
        importlib.import_module(name)
    home = root / "home"
    env = environment(root)
    saved_env = {k: os.environ.get(k) for k in (*env, *_UNSET)}
    changed = _constants({_REAL_HOME, Path.home()}, home)
    changed += _side_mcp_paths(home)
    os.environ.update(env)
    for k in _UNSET:
        os.environ.pop(k, None)
    time.tzset()
    try:
        yield
    finally:
        for module, attr, value in reversed(changed):
            setattr(module, attr, value)
        _constants({home}, _REAL_HOME)  # modules first imported during the op took the side's home
        for k, v in saved_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        time.tzset()


def side(root: Path) -> Side:
    """The side at ``root``, read as the app reads it (call inside ``patched(root)``)."""
    from palaver.config import load_config

    stores = root / "config" / "palaver"
    cfg = load_config(stores / "config.toml", secrets=False)
    try:
        events = json.loads((root / "events.json").read_text())
    except (OSError, ValueError):
        events = []
    return Side(root, cfg.output_dir, stores, root / "home", cfg.user_name, events)


def args_for(op: str, args: dict) -> dict:
    """The args both sides get: the scenario's over the op's defaults."""
    return {**DEFAULT_ARGS.get(op, {}), **args}


class BadArgs(Exception):
    """The scenario gave an op args it can't use: the harness's fault, never a domain answer."""


def error_kind(exc: BaseException) -> str:
    """What the window's server makes of the exception (webapp/server.py): refused (400 with
    its message), not_found (404), gone (404 "can't undo this any more"), changed (409),
    bad_request (400), other (500); bad_args for the harness's own."""
    from palaver import my_notes, undo
    from palaver.webapp import api

    for kind, classes in (("bad_args", BadArgs), ("gone", undo.Gone), ("changed", (undo.Changed, my_notes.Conflict)),
                          ("not_found", api.NotFound), ("refused", api.Refused),
                          ("bad_request", (KeyError, ValueError))):
        if isinstance(exc, classes):
            return kind
    return "other"


def run(op: str, root: Path, args: dict) -> Any:
    """``op`` on side ``root``, as a JSON value; ``{"error": message, "kind": kind}`` when it
    fails (diff.py compares those)."""
    why = unsafe_side(root)
    if why:
        return {"error": why, "kind": "bad_args"}
    fn = TABLE.get(op)
    if fn is None:
        return {"error": f"unknown op {op}", "kind": "unknown_op"}
    with patched(root):
        here = side(root)
        if not inside(here.recordings, root):
            return {"error": f"config.toml's output_dir is outside the side: {_NOT_A_SIDE}", "kind": "bad_args"}
        try:
            result = fn(here, args)
        except Exception as exc:  # noqa: BLE001 - an op's failure is its answer
            return {"error": str(exc), "kind": error_kind(exc)}
    return json.loads(json.dumps(result))


# --- json (Task 4) ------------------------------------------------------------------------


def _format(indent: int | None = None, ensure_ascii: bool = True, newline: bool = False) -> dict:
    return {"indent": indent, "ensure_ascii": ensure_ascii, "newline": newline}


# How the Python app writes each JSON file (its main writer's json.dumps), by file name; a name
# ending in "/" is every file of such a folder. Anything else: json.dumps' defaults.
JSON_FORMATS: dict[str, dict] = {
    # A meeting's folder.
    "audio_deleted.json": _format(2),
    "audio_problems.json": _format(2),
    "calendar.json": _format(2, False),
    "cloud-pending.json": _format(2),
    "cut_dismissed.json": _format(),
    "imported.json": _format(2, False),
    "imported_voices.json": _format(),
    "live.json": _format(),
    "local_only.json": _format(),
    "meta.json": _format(2),
    "mic_segments.json": _format(2),
    "my-notes.json": _format(1, False),
    "notes.json": _format(2, False),
    "notion.json": _format(2),
    "parts.json": _format(2),
    "review.json": _format(),
    "search-index.json": _format(None, False),
    "speaker_embeddings.json": _format(),
    "speakers.json": _format(2, False),
    "speakers_auto.json": _format(2, False),
    "speakers_ignored.json": _format(),
    "speakers_inferred.json": _format(2, False),
    "speakers_lines.json": _format(2, False),
    "speakers_live.json": _format(None, False),
    "speakers_merged.json": _format(2, False),
    "speakers_rejected.json": _format(2, False),
    "speakers_shared.json": _format(2, False),
    "speakers_unknown.json": _format(),
    "stream.json": _format(),
    "system_segments.json": _format(2),
    "system_turns.json": _format(2),
    "title.json": _format(None, False),
    "transcript.json": _format(2),
    "transcription.json": _format(2, False),
    # The stores.
    "attributions.json": _format(2, False),
    "coach-baseline.json": _format(2),
    "glossary.json": _format(2, False),
    "organizations.json": _format(2, False),
    "prepared.json": _format(2, False),
    "projects.json": _format(2, False),
    "settings.json": _format(2, True, True),
    "shared-series.json": _format(2, False),
    "voices/": _format(None, False),
    # The parity side's calendar.
    "events.json": _format(2, False),
}


def json_roundtrip(side: Side, args: dict) -> dict:
    """Every ``*.json`` under the side read and written again in its file's format."""
    formats = args.get("formats")
    if not isinstance(formats, dict):
        raise BadArgs("json-roundtrip needs formats")
    rewritten = 0
    for f in sorted(side.root.rglob("*.json")):
        if not f.is_file():
            continue
        try:
            value = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        fmt = formats.get(f.name) or formats.get(f.parent.name + "/") or {}
        text = json.dumps(value, indent=fmt.get("indent"), ensure_ascii=fmt.get("ensure_ascii", True))
        f.write_text(text + ("\n" if fmt.get("newline") else ""))
        rewritten += 1
    return {"rewritten": rewritten}


# --- meetings (Task 5) ---------------------------------------------------------------------


def _meeting_folders(side: Side) -> list[Path]:
    """The recording folders of the side's output dir, by name."""
    from palaver.paths import is_recording_folder_name

    if not side.recordings.is_dir():
        return []
    return sorted(f for f in side.recordings.iterdir() if f.is_dir() and is_recording_folder_name(f.name))


def models_roundtrip(side: Side, args: dict) -> dict:
    """Every meeting's segments, turns and utterances read into the models and written again
    (``json.dumps(..., indent=2)``); a file the models can't read is left as it is."""
    from palaver.models import Segment, SpeakerTurn, Utterance
    from palaver.paths import RecordingPaths

    rewritten = skipped = 0
    for folder in _meeting_folders(side):
        paths = RecordingPaths(folder)
        for file, model in ((paths.mic_segments, Segment), (paths.system_segments, Segment),
                            (paths.system_turns, SpeakerTurn), (paths.transcript_json, Utterance)):
            if not file.is_file():
                continue
            try:
                items = [model.from_dict(d).to_dict() for d in json.loads(file.read_text())]
            except (OSError, ValueError, KeyError, TypeError, AttributeError):
                skipped += 1
                continue
            file.write_text(json.dumps(items, indent=2))
            rewritten += 1
    return {"rewritten": rewritten, "skipped": skipped}


def meeting_status(side: Side, args: dict) -> dict:
    """Each meeting's status (``later`` seconds from now), whether it stays on this Mac, why it has no
    transcript, whether its system track still wants the cloud."""
    from palaver import llm, process_state, transcription
    from palaver.cli import _status
    from palaver.paths import RecordingPaths

    now = time.time() + float(args.get("later", 0))
    out = {}
    for folder in _meeting_folders(side):
        paths = RecordingPaths(folder)
        failed = process_state.read(paths)
        out[folder.name] = {"status": _status(paths, now=now), "local_only": llm.is_local_only(folder),
                            "failed": failed and failed["reason"], "wants_cloud": transcription.wants_cloud(paths)}
    return out


def meeting_markers(side: Side, args: dict) -> dict:
    """The small marker files: local_only.json, failed.json, transcription.json of one meeting."""
    from palaver import llm, process_state, transcription
    from palaver.paths import RecordingPaths
    from palaver.webapp.api import NotFound

    folder = side.recordings / str(args.get("folder", ""))
    if not args.get("folder") or not folder.is_dir():
        raise NotFound(f"no meeting {args.get('folder')}")
    paths = RecordingPaths(folder)
    if "local_only" in args:
        llm.set_local_only(folder, bool(args["local_only"]))
    if "failed" in args:
        failed = args["failed"]
        if failed is None:
            process_state.clear(paths)
        else:
            process_state.mark(paths, failed["reason"], missing=failed.get("missing", []), error=failed.get("error"))
    if "transcription" in args:
        marker = args["transcription"]
        transcription.write_marker(paths, marker["track"], **marker.get("info", {}))
    return {"wants_cloud": transcription.wants_cloud(paths)}


# --- stores (Task 6, 7) --------------------------------------------------------------------


def hold_lock(side: Side, args: dict) -> dict:
    """Take the lock of ``args["target"]`` (a store path, relative to the side's root unless absolute;
    ``"meeting": true`` means a recording folder), hold it for 0.5 s: a writer started meanwhile must wait."""
    from palaver.store_lock import locked, meeting_lock

    if not isinstance(args.get("target"), str):
        raise BadArgs("hold-lock needs target")
    target = side.root / args["target"]  # absolute stays absolute
    with (meeting_lock(target) if args.get("meeting") is True else locked(target)):
        time.sleep(0.5)
    return {"held": True}


# --- my_notes (Task 8) ----------------------------------------------------------------------


def _notes_folder(side: Side, args: dict, *, key: str = "folder", prep: str = "in_prep") -> Path:
    """The notes folder an op names: a recording of the side (``folder``) or the folder prepared for a
    calendar event (``in_prep``: its key)."""
    from palaver import my_notes

    if isinstance(args.get(prep), str):
        return my_notes.prep_folder(args[prep])
    if isinstance(args.get(key), str) and args[key]:
        return side.recordings / args[key]
    raise BadArgs(f"my-notes needs {key} or {prep}")


def my_notes_op(side: Side, args: dict) -> dict:
    """One action on the user's own notes (my_notes.py): ``action`` is plant (a fixed stand-in image with its
    text), add-image (answers the kind of file stored, then removes it: names are random), save, put-back,
    remove-image, clear, adopt (``from_prep``: the key to adopt from), join (``other``, ``keep``: "first" or
    "second", ``offset``), split (``tail``, ``at``), document or prompt. Answers the folder's paragraphs
    and files besides what the action answers."""
    from palaver import my_notes

    action = args.get("action")
    folder = _notes_folder(side, args)
    answer: dict[str, Any] = {}
    if action == "plant":
        (folder / "my-notes").mkdir(parents=True, exist_ok=True)
        (folder / "my-notes" / args["name"]).write_bytes(b"\x89PNG\r\n\x1a\n")
        if args.get("text") is not None:
            (folder / "my-notes" / f"{args['name']}.txt").write_text(args["text"])
    elif action == "add-image":
        data = bytes.fromhex(args["hex"])
        name = my_notes.add_image(folder, data)
        answer["ext"] = name.rsplit(".", 1)[1]
        (folder / "my-notes" / name).unlink()
    elif action == "save":
        answer["saved"] = my_notes.save(folder, args["paragraphs"], base=args.get("base"))
    elif action == "put-back":
        my_notes.put_back(folder, args["paragraphs"], after=args.get("after"))
    elif action == "remove-image":
        removed, before = my_notes.remove_image(folder, args["name"])
        answer.update(removed=removed, before=before)
    elif action == "clear":
        my_notes.clear(folder)
    elif action == "adopt":
        answer["adopted"] = my_notes.adopt(my_notes.prep_folder(args["from_prep"]), folder)
    elif action == "join":
        other = _notes_folder(side, args, key="other", prep="other_in_prep")
        keep = folder if args.get("keep", "first") == "first" else other
        my_notes.join(folder, other, keep=keep, offset=float(args["offset"]))
    elif action == "split":
        my_notes.split(folder, _notes_folder(side, args, key="tail", prep="tail_in_prep"), at=float(args["at"]))
    elif action == "document":
        answer["document"] = my_notes.document(folder)
    elif action == "prompt":
        text = my_notes.prompt_text(folder)
        answer.update(text=text, hash=my_notes.prompt_hash(text))
    else:
        raise BadArgs(f"my-notes: unknown action {action!r}")
    answer["paragraphs"] = my_notes.load(folder)
    answer["files"] = sorted(str(f.relative_to(folder)) for f in folder.rglob("*") if f.is_file()) if folder.is_dir() else []
    return answer


# --- text (Task 9) ---------------------------------------------------------------------------


def glossary_op(side: Side, args: dict) -> dict:
    """One action on the user's glossary (glossary.py): ``action`` is add (``term``, ``variants``, ``note``;
    ``new_id``, required, is the id a new term gets), update (``of`` a term's name or ``id``; ``term``,
    ``note``), remove-variant (``of``/``id``, ``variant``), delete (``of``/``id``), reject (``key``), apply
    (``text``) or show. Saves after every change. Answers the terms, the rejected keys, and for apply the
    respelled text with its marks."""
    import uuid

    from palaver import glossary

    action = args.get("action")
    g = glossary.Glossary()
    tid = args.get("id")
    if tid is None and "of" in args:
        tid = g.find(args["of"])
        if tid is None:
            raise LookupError(args["of"])
    answer: dict = {}
    if action == "add":
        if not args.get("new_id"):
            raise BadArgs("glossary add needs new_id (random ids would differ)")

        class _Id:
            hex = str(args["new_id"]) + "0" * 24

        real = uuid.uuid4
        uuid.uuid4 = lambda: _Id()
        try:
            answer["id"] = g.add(args["term"], args.get("variants", ()), args.get("note", ""))
        finally:
            uuid.uuid4 = real
    elif action == "update":
        g.update(tid, term=args.get("term"), note=args.get("note"))
    elif action == "remove-variant":
        g.remove_variant(tid, args["variant"])
    elif action == "delete":
        g.delete(tid)
    elif action == "reject":
        g.reject(args["key"])
    elif action == "apply":
        text, marks = g.apply_marked(args["text"])
        answer.update(text=text, marks=[list(m) for m in marks])
    elif action != "show":
        raise BadArgs(f"glossary: unknown action {action!r}")
    if action not in ("apply", "show"):
        g.save()
    answer["terms"] = g.terms()
    answer["rejected"] = sorted(g.rejected())
    return answer


def _known_order(name: str) -> tuple[bool, str]:
    """GlossarySuggest.knownOrder: a name not all in capitals first ("Karel" before "KAREL"), then by code points.
    Python's known_spellings is a set, whose order changes from run to run; both sides sort it so."""
    return (name.isupper(), name)


def glossary_suggest_op(side: Side, args: dict) -> Any:
    """The glossary's suggestions (glossary.py:283-517, Task 18): ``action`` is corpus (every processed meeting's
    readable lines), unsure (the recordings' unsure words, by word: Python's order is the folders' listing order),
    known (the known spellings in ``_known_order``: Python's is a set), occurrences or suggest. Those two take ``transcripts``
    (meeting → [[start, text]]; the corpus when left out) and ``unsure`` (word → how often, or a list: every
    time; the recordings' when left out); suggest also ``known`` (the known spellings in ``_known_order`` when left out:
    the order decides ties, and a set's changes from run to run) and the user's glossary."""
    from palaver import glossary as G

    action = args.get("action")
    if action == "corpus":
        return G.corpus(side.recordings)
    if action == "unsure":
        return dict(sorted(G.unsure_words(side.recordings).items()))
    if action == "known":
        return sorted(G.known_spellings(side.recordings, user_name=side.user_name), key=_known_order)
    if action not in ("occurrences", "suggest"):
        raise BadArgs(f"glossary-suggest: unknown action {action!r}")
    if "transcripts" in args:
        transcripts = {m: [(float(start), text) for start, text in lines] for m, lines in args["transcripts"].items()}
    else:
        transcripts = G.corpus(side.recordings)
    unsure = args["unsure"] if "unsure" in args else G.unsure_words(side.recordings)
    if action == "occurrences":
        return {w: {"count": o.count, "meetings": sorted(o.meetings), "examples": o.examples, "rare": o.rare}
                for w, o in G.occurrences(transcripts, unsure).items()}
    known = args["known"] if "known" in args else sorted(G.known_spellings(side.recordings, user_name=side.user_name), key=_known_order)
    return G.suggest(transcripts, known, G.Glossary(), unsure=unsure)


def render_op(side: Side, args: dict) -> dict:
    """transcript.md of every meeting with a transcript and a meta (written into the folder, as the process
    step does) and what the glossary respelled in each line. ``gaps`` replaces meta.json's; ``texts`` (utterance
    dicts) are rendered too, as a meeting that started 2026-10-28T09:00:00+01:00."""
    from datetime import datetime

    from palaver.models import Utterance
    from palaver.paths import RecordingPaths
    from palaver.readable import readable
    from palaver.render import render_markdown

    def shown(utterances: list, start: datetime, duration: float, gaps) -> dict:
        return {"markdown": render_markdown(utterances, start, duration, gaps),
                "glossed": [[u.start, u.text, [list(m) for m in u.glossed]] for u in readable(utterances)]}

    out: dict = {}
    for folder in _meeting_folders(side):
        paths = RecordingPaths(folder)
        try:
            utterances = [Utterance.from_dict(d) for d in json.loads(paths.transcript_json.read_text())]
            meta = json.loads(paths.meta.read_text())
            start = datetime.fromisoformat(meta["start_time"])
            duration = float(meta["duration_seconds"])
        except (OSError, ValueError, KeyError):
            continue
        out[folder.name] = shown(utterances, start, duration, args.get("gaps", meta.get("gaps")))
        paths.transcript_md.write_text(out[folder.name]["markdown"])
    if "texts" in args:
        out["texts"] = shown([Utterance.from_dict(d) for d in args["texts"]],
                             datetime.fromisoformat("2026-10-28T09:00:00+01:00"), float(args.get("duration", 600)),
                             args.get("gaps"))
    return out


# --- calendar (Task 10) -----------------------------------------------------------------------


def _calendar_events(side: Side, args: dict) -> list:
    """The fake calendar (events.json), or ``events`` (event dicts) when the step brings its own."""
    from palaver.calendar_events import Event

    return [Event.from_dict(d) for d in args.get("events", side.events)]


def _calendar_event(side: Side, ref: dict):
    """The first event of events.json with this ``title`` (and a ``start`` beginning with the given text)."""
    from palaver.calendar_events import Event

    for d in side.events:
        if d["title"] == ref["title"] and d["start"].startswith(ref.get("start", "")):
            return Event.from_dict(d)
    raise BadArgs(f"calendar: no event {ref!r}")


def _calendar_folder(side: Side, args: dict):
    from palaver.paths import RecordingPaths
    from palaver.webapp.api import NotFound

    folder = side.recordings / str(args.get("folder", ""))
    if not args.get("folder") or not folder.is_dir():
        raise NotFound(f"no meeting {args.get('folder')}")
    return RecordingPaths(folder)


def attribution_op(side: Side, args: dict) -> dict:
    """The calendar and attribution rules (attribution.py, calendar_events.py without assign/attach): ``action`` is
    ``decide`` (``folder``'s recording span against the events, or ``start``/``end``; ``store`` writes the decision as
    calendar.json: the event with its link, or the question; ``evidence: false`` ignores what corrections taught),
    ``state`` (what calendar.json says of ``folder``), ``dismiss`` (``folder``), ``evidence`` (``steps`` of
    {do: reject|confirm, event: {title, start?}, meeting} or {do: forget, series}; ``save``; ``check`` events to
    count), ``questions`` (of the ``meeting`` dict), ``key-at`` (``when``), ``invited`` (``folder``, ``known``)."""
    from datetime import datetime

    from palaver import attribution as attr
    from palaver import calendar_events as cal

    action = args.get("action")
    if action == "questions":
        return {"questions": attr.questions(args["meeting"])}
    if action == "key-at":
        return {"key": cal.event_key_at(_calendar_events(side, args), datetime.fromisoformat(args["when"]))}
    if action == "evidence":
        ev = attr.Evidence(output_dir=side.recordings)
        for step in args.get("steps", []):
            if step["do"] == "forget":
                ev.forget_rule(step["series"])
            elif step["do"] in ("reject", "confirm"):
                (ev.reject_event if step["do"] == "reject" else ev.confirm_event)(
                    _calendar_event(side, step["event"]), step["meeting"])
            else:
                raise BadArgs(f"attribution evidence: unknown step {step['do']!r}")
        if args.get("save", True):
            ev.save()
        checked = []
        for ref in args.get("check", []):
            e = _calendar_event(side, ref)
            checked.append({"rejections": ev.event_rejections(e), "acceptances": ev.acceptances(e),
                            "doubted": ev.doubted(e), "never_by_time": ev.never_by_time(e), "rule": ev.rule(e)})
        return {"rules": ev.rules(), "checked": checked}
    paths = _calendar_folder(side, args)
    if action == "decide":
        if "folder" in args and "start" not in args:
            start, end = cal.recording_span(paths)
        else:
            start, end = datetime.fromisoformat(args["start"]), datetime.fromisoformat(args["end"])
        evidence = attr.Evidence(output_dir=side.recordings) if args.get("evidence", True) else None
        d = cal.decide(_calendar_events(side, args), start, end, evidence=evidence)
        if args.get("store"):
            if d.question:
                cal.ask(paths, d.question)
            elif d.event is not None:
                cal.save(paths, d.event, d.link)
        return {"event": d.event and d.event.to_dict(), "link": d.link and d.link.to_dict(),
                "question": d.question and [e.to_dict() for e in d.question]}
    if action == "state":
        event, question = cal.load(paths), cal.load_question(paths)
        link = cal.load_link(paths)
        return {"event": event and event.to_dict(), "link": link and link.to_dict(),
                "question": question and [e.to_dict() for e in question], "dismissed": cal.dismissed(paths)}
    if action == "dismiss":
        cal.dismiss(paths)
        return {"dismissed": cal.dismissed(paths)}
    if action == "invited":
        return {"names": cal.invited_names(paths, args.get("known", []), user_name=side.user_name)}
    raise BadArgs(f"attribution: unknown action {action!r}")


def organizations_op(side: Side, args: dict) -> dict:
    """People's organizations (organizations.py): ``action`` is ``keys`` (``emails`` → org_key and default_name),
    ``index`` (people_index of the recordings folder), ``state`` (for ``people``: the organization and its link, with the
    ``own`` organization of ``user`` (default: the user's name), the summary and the index) or ``edit`` (``steps`` of
    {do: rename, key, name} or {do: person, person, org}; ``save``: write organizations.json)."""
    from palaver import organizations as O

    action = args.get("action")
    if action == "keys":
        return {"keys": [{"email": e, "key": O.org_key(e), "name": O.default_name(O.org_key(e)) if O.org_key(e) else None}
                         for e in args.get("emails", [])]}
    index = O.people_index(side.recordings)
    if action == "index":
        return {"index": index}
    orgs = O.Organizations()
    if action == "edit":
        for step in args.get("steps", []):
            if step["do"] == "rename":
                orgs.rename(step["key"], step["name"])
            elif step["do"] == "person":
                orgs.set_person(step["person"], step.get("org"))
            else:
                raise BadArgs(f"organizations edit: unknown step {step['do']!r}")
        if args.get("save", True):
            orgs.save()
        return {"saved": bool(args.get("save", True))}
    if action == "state":
        who = []
        for person in args.get("people", []):
            link = O.org_link(person, index, orgs)
            who.append({"person": person, "org": O.org_of(person, index, orgs), "link": link and link.to_dict()})
        return {"people": who, "own": O.own_org(index, orgs, args.get("user", side.user_name)),
                "summary": O.summary(index, orgs), "index": index}
    raise BadArgs(f"organizations: unknown action {action!r}")


def title_op(side: Side, args: dict) -> dict:
    """A meeting's title (titles.py): ``action`` is ``clean`` (``text``: any JSON value), ``fallback`` (``start``),
    ``resolve`` (``folder``; ``no_event``/``no_notes`` hand resolve a known "none"; ``load``/``imported`` add the single
    sources), ``save`` (``folder``, ``title`` as typed: cleaned first, as the window does; "" removes it)."""
    from palaver import titles

    action = args.get("action")
    if action == "clean":
        return {"title": titles.clean(args.get("text"))}
    if action == "fallback":
        return {"title": titles.fallback(args.get("start"))}
    paths = _calendar_folder(side, args)
    if action == "save":
        titles.save(paths, titles.clean(args.get("title")))
        return {"own": titles.load(paths)}
    if action == "resolve":
        kw = {}
        if args.get("no_event"):
            kw["event"] = None
        if args.get("no_notes"):
            kw["meeting_notes"] = None
        title, source = titles.resolve(paths, **kw)
        return {"title": title, "source": source, "own": titles.load(paths), "imported": titles.imported(paths)}
    raise BadArgs(f"title: unknown action {action!r}")


# --- speakers (Task 12) --------------------------------------------------------------------------


def _voice(side: Side, ref) -> list:
    """A voice a step names: a list of numbers, or ``{"folder", "label"}``: that speaker's in speaker_embeddings.json."""
    if isinstance(ref, list):
        return ref
    if not isinstance(ref, dict) or "label" not in ref:
        raise BadArgs(f"speakers: no voice {ref!r}")
    return json.loads(_calendar_folder(side, ref).speaker_embeddings.read_text())[ref["label"]]


def _speaker_state(paths) -> dict:
    """What the speaker files and the marks say of one meeting, as the readers of speakers.py and shared_mic.py read it."""
    from palaver import shared_mic
    from palaver import speakers as S
    from palaver.models import SpeakerTurn, Utterance

    turns = ([SpeakerTurn.from_dict(d) for d in json.loads(paths.system_turns.read_text())]
             if paths.system_turns.exists() else [])
    shown = corrected = None
    if paths.transcript_json.exists():
        utterances = [Utterance.from_dict(d) for d in json.loads(paths.transcript_json.read_text())]
        shown = [u.speaker for u in shared_mic.shown(paths, S.without_ignored(paths, utterances))]
        corrected = [[u.speaker, u.label, u.said_by, list(u.heard_as) if u.heard_as else None]
                     for u in S.with_line_speakers(paths, utterances)]
    return {
        "names": S.load_speaker_names(paths),
        "merges": S.load_merges(paths),
        "ignored": sorted(S.load_ignored(paths)),
        "unknown": sorted(S.load_unknown(paths)),
        "rejected": S.load_rejected_names(paths),
        "inferred": S.load_inferred_names(paths),
        "recognized": {label: list(hit) for label, hit in S.load_recognized_names(paths).items()},
        "in_effect": S.names_in_effect(paths),
        "live": S.load_live_names(paths),
        "talk": S.talk_seconds(S.merged_turns(turns, S.load_merges(paths))),
        "longest": {label: t.to_dict() for label, t in S.longest_turns(turns).items()},
        "shared": {
            "display": dict(sorted(shared_mic.display(paths).items())),
            "rooms": shared_mic.room_names(paths),
            "meeting": shared_mic.meeting_marked(paths),
            "from_series": shared_mic.from_series(paths),
            "mic_room": shared_mic.mic_room(paths),
            "mic_display": shared_mic.mic_display(paths),
            "marked": shared_mic.marked(paths),
            "system_speech": shared_mic.system_speech(paths),
        },
        "shown": shown,
        "lines": S.load_line_speakers(paths),
        "corrected": corrected,
    }


def speakers_op(side: Side, args: dict) -> dict:
    """One meeting's speakers (speakers.py, the marks' readers of shared_mic.py): ``action`` is ``state``, ``save-names``
    (``names``, ``learn``), ``merge`` (``label``, ``into``: null splits it off), ``ignore``/``unknown`` (``label``, ``on``),
    ``reject`` (``label``, ``name``, ``on``), ``save-shared`` (``marks``: shared_mic.save, until Task 14 sets them), ``plant-live`` (``voices``: live label → a label of speaker_embeddings.json, that of ``from`` (a meeting) when
    given, written into live.json's ``embeddings`` as the live worker would), ``name-live`` (``label``, ``name``), ``adopt-live``,
    ``plant-lines`` (``text`` written as speakers_lines.json) or ``set-line`` (``line``: an index into transcript.json; ``to``).
    Answers what changed and the meeting's ``state`` after it."""
    from palaver import speakers as S

    action = args.get("action")
    paths = _calendar_folder(side, args)
    answer: dict = {}
    if action == "save-names":
        answer["enrolled"] = S.save_speaker_names(paths, args.get("names", {}), learn=args.get("learn", True))
    elif action == "merge":
        S.merge_speakers(paths, args["label"], args.get("into"))
    elif action == "ignore":
        S.set_ignored(paths, args["label"], args.get("on", True))
    elif action == "unknown":
        S.set_unknown(paths, args["label"], args.get("on", True))
    elif action == "reject":
        S.set_rejected_name(paths, args["label"], args["name"], args.get("on", True))
    elif action == "save-shared":
        from palaver import shared_mic

        shared_mic.save(paths, args.get("marks", {}))
    elif action == "plant-live":
        live = json.loads(paths.live.read_text()) if paths.live.exists() else {}
        source = _calendar_folder(side, {"folder": args["from"]}) if args.get("from") else paths
        embeddings = json.loads(source.speaker_embeddings.read_text())
        live["embeddings"] = {label: embeddings[final] for label, final in args.get("voices", {}).items()}
        paths.live.write_text(json.dumps(live))
    elif action == "name-live":
        S.name_live_speaker(paths, args["label"], args["name"])
    elif action == "adopt-live":
        answer["adopted"] = S.adopt_live_names(paths)
    elif action == "plant-lines":
        paths.speakers_lines.write_text(args["text"])
    elif action == "set-line":
        from palaver.models import Utterance

        lines = [Utterance.from_dict(d) for d in json.loads(paths.transcript_json.read_text())]
        S.set_line_speaker(paths, lines[args["line"]], args.get("to"))
    elif action != "state":
        raise BadArgs(f"speakers: unknown action {action!r}")
    answer["state"] = _speaker_state(paths)
    return answer


def _shared_state(paths, event=None) -> dict:
    from palaver import shared_mic

    return {
        "display": dict(sorted(shared_mic.display(paths).items())),
        "rooms": shared_mic.room_names(paths),
        "marks": shared_mic.load(paths),
        "meeting": shared_mic.meeting_marked(paths),
        "from_series": shared_mic.from_series(paths),
        "mic_room": shared_mic.mic_room(paths),
        "marked": shared_mic.marked(paths),
        "series": {"can": shared_mic.can_remember(event), "remembered": shared_mic.remembered(event)},
    }


def shared_mic_op(side: Side, args: dict) -> dict:
    """The shared microphone's setters, series memory and suggestion (shared_mic.py): ``action`` is ``state``, ``set-meeting``
    (``on``), ``set-lane`` (``label``, ``on``, ``name``), ``forget-lanes``, ``remember`` (``event``: {title, start} of
    events.json; ``on``), ``apply-series`` (``event``, null for none), ``signals``/``suggestion`` (``event``, ``user``),
    ``dismiss`` (``on``), ``split`` (``labels``, ``head``: the part of the folder's marks; ``write`` saves it into the folder) or
    ``join`` (``from``: another folder whose marks join into ``folder``'s; ``relabel``). Answers ``result`` and the marks' ``shared`` state."""
    from palaver import shared_mic

    def event():
        return _calendar_event(side, args["event"]) if args.get("event") else None

    def raw(paths) -> dict:
        return json.loads(paths.speakers_shared.read_text()) if paths.speakers_shared.exists() else {}

    action = args.get("action")
    paths = _calendar_folder(side, args)
    result: Any = None
    if action == "set-meeting":
        shared_mic.set_meeting(paths, args.get("on", True))
    elif action == "set-lane":
        shared_mic.set_lane(paths, args["label"], args.get("on", True), args.get("name"))
    elif action == "forget-lanes":
        shared_mic.forget_lanes(paths)
    elif action == "remember":
        shared_mic.remember(event(), args.get("on", True))
    elif action == "apply-series":
        result = shared_mic.apply_series(paths, event())
    elif action == "signals":
        result = shared_mic.signals(paths, event(), user_name=args.get("user", ""))
    elif action == "suggestion":
        result = shared_mic.suggestion(paths, event(), user_name=args.get("user", ""))
    elif action == "dismiss":
        shared_mic.dismiss_suggestion(paths, args.get("on", True))
    elif action == "split":
        result = shared_mic.split_part(raw(paths), set(args.get("labels", [])), head=args.get("head", True))
        if args.get("write"):
            shared_mic.save(paths, result)
    elif action == "join":
        shared_mic.join_from(paths, raw(_calendar_folder(side, {"folder": args.get("from")})), args.get("relabel", {}))
    elif action != "state":
        raise BadArgs(f"shared-mic: unknown action {action!r}")
    return {"result": result, "shared": _shared_state(paths, event())}


def voices_op(side: Side, args: dict) -> dict:
    """The voice bank (voices.py): ``action`` is ``names``, ``add`` (``name``, ``voice``, ``source``), ``owner``/``remove-source``
    (``source``), ``remove-meeting`` (``meeting``), ``forget`` (``name``), ``rename`` (``old``, ``new``), ``size``, ``slug``
    (``names``), ``scores``/``match`` (``voice``) or ``recognize`` (``folder``'s voices and talk; ``invited``; ``rejected``:
    [name, voice] pairs). A ``voice`` is a list of numbers or {folder, label}. Answers ``result`` and the bank's names."""
    from palaver import voices as V
    from palaver.models import SpeakerTurn
    from palaver.speakers import talk_seconds

    action = args.get("action")
    bank = V.VoiceBank()
    if action == "names":
        result = bank.names()
    elif action == "add":
        result = bank.add(args["name"], _voice(side, args["voice"]), source=args["source"])
    elif action == "owner":
        result = bank.owner(args["source"])
    elif action == "remove-source":
        result = bank.remove_source(args["source"])
    elif action == "remove-meeting":
        result = bank.remove_meeting(args["meeting"])
    elif action == "forget":
        result = bank.forget(args["name"])
    elif action == "rename":
        result = bank.rename(args["old"], args["new"])
    elif action == "size":
        result = bank.size()
    elif action == "slug":
        result = [V._slug(n) for n in args.get("names", [])]
    elif action == "scores":
        result = [[sim, name] for sim, name in bank.scores(_voice(side, args["voice"]))]
    elif action == "match":
        found = bank.match(_voice(side, args["voice"]))
        result = list(found) if found else None
    elif action == "recognize":
        paths = _calendar_folder(side, args)
        turns = [SpeakerTurn.from_dict(d) for d in json.loads(paths.system_turns.read_text())]
        found = V.recognize(json.loads(paths.speaker_embeddings.read_text()), talk_seconds(turns), bank,
                            args.get("invited"), [(n, _voice(side, v)) for n, v in args.get("rejected", [])])
        result = {label: list(hit) for label, hit in found.items()}
    else:
        raise BadArgs(f"voices: unknown action {action!r}")
    return {"result": result, "names": bank.names()}


def people_op(side: Side, args: dict) -> dict:
    """People across meetings (people.py, Task 13): ``action`` is ``directory`` (``me``: casefolded names), ``voices``,
    ``rejected-voices``, ``refresh`` (refresh_recognition; ``user_name``, else the side's), ``name-voices`` (``members``:
    [meeting, label] pairs, ``name``), ``rename-person`` (``old``, ``new``), ``suggestions`` (``folder``) or ``plant``
    (``folder``'s speaker_embeddings.json from ``voices``: label → a voice, and its system_turns.json from ``turns``:
    [label, start, end] lists, written as the diarizer writes them). Answers ``result``."""
    from palaver import people

    action = args.get("action")
    if action == "directory":
        result = people.directory(side.recordings, me=set(args.get("me", [])))
    elif action == "voices":
        result = [{"meeting": v.meeting, "label": v.label, "talk_seconds": v.talk_seconds, "name": v.name,
                   "named_by": v.named_by} for v in people.voices(side.recordings)]
    elif action == "rejected-voices":
        result = [[name, [float(x) for x in vector]] for name, vector in people.rejected_voices(side.recordings)]
    elif action == "refresh":
        result = people.refresh_recognition(side.recordings, user_name=args.get("user_name", side.user_name))
    elif action == "name-voices":
        result = people.name_voices(side.recordings, [tuple(m) for m in args["members"]], args["name"])
    elif action == "rename-person":
        result = people.rename_person(side.recordings, args["old"], args["new"])
    elif action == "suggestions":
        result = people.suggestions(_calendar_folder(side, args))
    elif action == "plant":
        paths = _calendar_folder(side, args)
        voices = {label: _voice(side, ref) for label, ref in args.get("voices", {}).items()}
        if "turns" in args:
            paths.system_turns.write_text(json.dumps([{"speaker": t[0], "start": t[1], "end": t[2]} for t in args["turns"]]))
        paths.speaker_embeddings.write_text(json.dumps(voices))
        result = None
    else:
        raise BadArgs(f"people: unknown action {action!r}")
    return {"result": result}


def inference_op(side: Side, args: dict) -> dict:
    """Names by inference (inference.py, Task 13): ``action`` is ``refresh`` (``user_name``, else the side's) or ``load``
    (``folder``). Answers ``result``."""
    from palaver import inference

    action = args.get("action")
    if action == "refresh":
        result = inference.refresh(side.recordings, user_name=args.get("user_name", side.user_name))
    elif action == "load":
        result = inference.load(_calendar_folder(side, args))
    else:
        raise BadArgs(f"inference: unknown action {action!r}")
    return {"result": result}


def hints_op(side: Side, args: dict) -> dict:
    """The names an import came with (exchange.py ``load_record``, ``hints``) of ``folder``."""
    from palaver import exchange

    paths = _calendar_folder(side, args)
    return {"record": exchange.load_record(paths), "hints": exchange.hints(paths)}


# --- projects (Task 15) ---------------------------------------------------------------------------


def _project(store, ref) -> str:
    """A project a step names: its id, else its name (ids made during a scenario differ between the sides)."""
    ref = str(ref)
    return ref if ref in store.projects() else (store.find(ref) or ref)


def _facts_dict(f) -> dict:
    return {"meeting": f.meeting, "title": f.title, "start": f.start, "people": sorted(f.people), "orgs": sorted(f.orgs),
            "words": sorted(f.words), "summary": f.summary, "series": f.series}


def _provider(side: Side):
    """The fake calendar (events.json) as EventKit answers it: the events overlapping the window asked for."""
    from palaver.calendar_events import Event

    events = [Event.from_dict(d) for d in side.events]
    return lambda start, end: [e for e in events if e.start < end and e.end > start]


def _now(side: Side, args: dict):
    """``now``: an ISO time, or ``{"before": {title, start?}, "hours": h}``: ``h`` hours (default 2) before that event of
    events.json (the corpus' upcoming events are built around the run's now)."""
    from datetime import datetime, timedelta

    now = args.get("now")
    if isinstance(now, str):
        return datetime.fromisoformat(now)
    if isinstance(now, dict) and isinstance(now.get("before"), dict):
        return _calendar_event(side, now["before"]).start - timedelta(hours=float(now.get("hours", 2)))
    raise BadArgs("prep needs now")


def projects_op(side: Side, args: dict) -> dict:
    """Projects and the rules (projects.py up to the model): ``action`` is ``edit`` (``steps`` of {do: create (``name``,
    ``description``, ``by``) | update (``project``, ``name``, ``description``, ``by``) | delete | merge (``project``,
    ``into``) | assign (``meeting``, ``project``, ``by``, ``why``, ``confidence``) | unassign | forget (``meeting``)};
    reloaded, changed and saved under the lock unless ``save`` is false; answers each step's result), ``state``
    (the projects, and ``meetings``' assignments and rejections), ``facts`` (all_facts), ``rules`` (assign_by_rules
    of ``meetings`` or all, under the lock as the CLI runs it), ``scores`` and ``suggestions`` (``meeting``). A
    ``project`` is an id or a name."""
    from palaver import projects as P

    action = args.get("action")
    store = P.ProjectStore()
    user = args.get("user", side.user_name)
    if action == "edit":
        def run_steps() -> list:
            results = []
            for step in args.get("steps", []):
                do = step.get("do")
                if do == "create":
                    results.append(store.create(step["name"], step.get("description", ""), by=step.get("by", "you")))
                elif do == "update":
                    store.update(_project(store, step["project"]), name=step.get("name"), description=step.get("description"),
                                 by=step.get("by", "you"))
                    results.append(None)
                elif do == "delete":
                    store.delete(_project(store, step["project"]))
                    results.append(None)
                elif do == "merge":
                    store.merge(_project(store, step["project"]), into=_project(store, step["into"]))
                    results.append(None)
                elif do == "assign":
                    results.append(store.assign(step["meeting"], _project(store, step["project"]), by=step.get("by", "you"),
                                                why=step.get("why", ""), confidence=step.get("confidence")))
                elif do == "unassign":
                    store.unassign(step["meeting"], _project(store, step["project"]))
                    results.append(None)
                elif do == "forget":
                    store.forget_meeting(step["meeting"])
                    results.append(None)
                else:
                    raise BadArgs(f"projects edit: unknown step {do!r}")
            return results

        if not args.get("save", True):
            return {"results": run_steps()}
        with store.locked():
            store.reload()
            results = run_steps()
            store.save()
        return {"results": results}
    if action == "state":
        return {"projects": store.projects(),
                "meetings": {m: {"assigned": store.of_meeting(m), "rejected": store.rejected(m)} for m in args.get("meetings", [])},
                "of": {pid: store.meetings_of(pid) for pid in store.projects()}}
    if action == "facts":
        return {"facts": {m: _facts_dict(f) for m, f in P.all_facts(side.recordings, user_name=user).items()}}
    if action == "rules":
        with store.locked():
            store.reload()
            added = P.assign_by_rules(side.recordings, store, user_name=user, meetings=args.get("meetings"))
            store.save()
        return {"added": added}
    every = P.all_facts(side.recordings, user_name=user)
    if action == "scores":
        meeting = every[args["meeting"]]
        return {"scores": [[pid, round(score, 12), why] for pid, score, why in P.scores(meeting, store, every, P.Similarity(every))]}
    if action == "suggestions":
        return {"suggestions": P.suggestions(args["meeting"], store, every)}
    raise BadArgs(f"projects: unknown action {action!r}")


def prep_op(side: Side, args: dict) -> dict:
    """Meeting prep (prep.py): ``action`` is ``upcoming`` (``now``: see ``_now``; the events' keys), ``find`` (``key``,
    ``now``), ``chosen``/``suggestions``/``context`` (``event``: {title, start?} of events.json; ``user``), ``choose``
    (``event``, ``project``: an id or a name, ``remove``) or ``apply`` (``folder``, ``event``)."""
    from palaver import prep
    from palaver import projects as P

    action = args.get("action")
    if action == "upcoming":
        return {"upcoming": [e.to_dict() for e in prep.upcoming(_provider(side), _now(side, args))]}
    if action == "find":
        found = prep.find(_provider(side), args["key"], _now(side, args))
        return {"event": found and found.to_dict()}
    event = _calendar_event(side, args["event"])
    user = args.get("user", side.user_name)
    if action == "chosen":
        return {"chosen": prep.chosen(event)}
    if action == "choose":
        prep.choose(event, _project(P.ProjectStore(), args["project"]), remove=bool(args.get("remove", False)))
        return {"chosen": prep.chosen(event)}
    if action == "apply":
        return {"added": prep.apply(_calendar_folder(side, args), event)}
    if action == "suggestions":
        return {"suggestions": prep.suggestions(event, side.recordings, user_name=user)}
    if action == "context":
        return {"context": prep.context(event, side.recordings, user_name=user)}
    raise BadArgs(f"prep: unknown action {action!r}")


def calendar_attach_op(side: Side, args: dict) -> dict:
    """Attaching events to recordings (calendar_events.py ``assign``, ``attach``, ``attach_all``) with the fake calendar:
    ``action`` is ``attach-all`` (``since``: an ISO time), ``attach`` (``folder``: its recording span) or ``assign``
    (``folder``, ``event``: {title, start?}, ``link``: {kind, target, source, confidence, reason})."""
    from datetime import datetime

    from palaver import attribution as attr
    from palaver import calendar_events as cal

    action = args.get("action")
    if action == "attach-all":
        since = datetime.fromisoformat(args["since"]) if args.get("since") else None
        return {"found": cal.attach_all(side.recordings, _provider(side), since)}
    paths = _calendar_folder(side, args)
    if action == "attach":
        start, end = cal.recording_span(paths)
        event = cal.attach(paths, _provider(side), start, end)
        return {"event": event and event.to_dict()}
    if action == "assign":
        link = args.get("link")
        cal.assign(paths, _calendar_event(side, args["event"]),
                   attr.Link(link["kind"], link["target"], link.get("source", "unknown"), link.get("confidence"),
                             link.get("reason", "")) if link else None)
        return {"event": cal.load(paths).to_dict()}
    raise BadArgs(f"calendar-attach: unknown action {action!r}")


# --- search (Tasks 19, 34, 35) ----------------------------------------------------------------------


def search_query_json(q) -> dict:
    """A parsed search as the goldens (tools/parity/goldens.py ``search_parse``) and the
    ``search-parse`` op answer it: the fields, every property and the chips."""
    return {
        "text": q.text,
        "words": q.words,
        "filters": [{"kind": f.kind, "value": f.value, "label": f.label, "span": list(f.span), "written": f.written}
                    for f in q.filters],
        "any_person": q.any_person,
        "people": q.people,
        "orgs": q.orgs,
        "projects": q.projects,
        "since": q.since and q.since.isoformat(),
        "until": q.until and q.until.isoformat(),
        "scope": q.scope,
        "said_by": q.said_by,
        "reviewed": q.reviewed,
        "has_steps": q.has_steps,
        "empty": q.empty,
        "chips": q.chips(),
    }


def search_parse_op(side: Side, args: dict) -> dict:
    """search.parse (search.py) of each of ``texts`` with ``vocab`` ({people, projects: {id: name}, orgs}; empty when
    left out) on ``today`` (an ISO date, required: the run must not depend on the day it runs)."""
    from datetime import date

    from palaver import search

    if not isinstance(args.get("today"), str) or not isinstance(args.get("texts"), list):
        raise BadArgs("search-parse needs today and texts")
    v = args.get("vocab") or {}
    vocab = search.Vocabulary(people=list(v.get("people", [])), projects=dict(v.get("projects", {})),
                              orgs=list(v.get("orgs", [])))
    today = date.fromisoformat(args["today"])
    return {"queries": [search_query_json(search.parse(text, vocab, today=today)) for text in args["texts"]]}


_CHECKOUT = Path(__file__).resolve().parents[2]


def e5_encode_op(side: Side, args: dict) -> dict:
    """embeddings.Encoder on ``folder`` (absolute, or relative to the checkout: the tiny fixtures; only read):
    the ``ids`` of each of ``texts`` with the passage prefix in front (``"kind": "query"``: the query prefix), and
    their ``vectors`` (``passages(texts)``, or ``query`` of each), every number rounded to ``round`` places when
    given. ``prefix_query`` and ``prefix_passage`` replace the Encoder's defaults."""
    from palaver import embeddings

    folder, texts, kind = args.get("folder"), args.get("texts"), args.get("kind", "passages")
    if not isinstance(folder, str) or not isinstance(texts, list) or kind not in ("passages", "query"):
        raise BadArgs("e5-encode needs folder, texts and kind passages or query")
    prefixes = {k: args[k] for k in ("prefix_query", "prefix_passage") if k in args}
    encoder = embeddings.Encoder(_CHECKOUT / folder, **prefixes)
    prefix = encoder.prefix_query if kind == "query" else encoder.prefix_passage
    vectors = [encoder.query(t) for t in texts] if kind == "query" else list(encoder.passages(texts))
    digits = args.get("round")

    def number(v) -> float:
        return float(v) if digits is None else round(float(v), digits)

    return {"ids": [encoder._ids(prefix + t) for t in texts], "vectors": [[number(v) for v in row] for row in vectors]}


_TINY_BERT = "tests/fixtures/tiny_embedder/bert"
_INDEX_SOURCES = ("transcript.json", "notes.json", "speakers_ignored.json", "speakers_lines.json")


def index_op(side: Side, args: dict) -> dict:
    """The search-by-meaning index (semantic.py, Task 35) under the model string ``model`` ("tiny-bert-fixture" by
    default) with the tiny embedder in ``folder`` (checkout-relative, the ``bert`` fixture by default), so the run
    does not depend on the real model. ``action``: ``run`` (index_stale, or ``only`` these folders: the number
    indexed and the folders stale after), ``stale`` (the stale folders' names), ``chunks`` (``folder``'s pieces),
    ``plant`` (``text``, when given, written as ``folder``'s ``file``, one of the index's sources, then its times set
    to ``ns``: the .sig holds the sources' times, so both sides must have the same) or ``floor`` (of ``scores`` as
    float32)."""
    import numpy as np

    from palaver import embeddings, semantic
    from palaver.paths import RecordingPaths

    action = args.get("action", "run")
    saved = embeddings.MODEL
    embeddings.MODEL = args.get("model", "tiny-bert-fixture")
    try:
        if action == "run":
            only = args.get("only")
            folder = _CHECKOUT / args.get("folder", _TINY_BERT)
            done = semantic.index_stale(side.recordings, lambda: embeddings.Encoder(folder),
                                        only=None if only is None else [RecordingPaths(side.recordings / f) for f in only])
            return {"done": done, "stale": [p.folder.name for p in semantic.stale(side.recordings)]}
        if action == "stale":
            return {"stale": [p.folder.name for p in semantic.stale(side.recordings)]}
        if action == "chunks":
            return {"chunks": semantic.chunks(_calendar_folder(side, args))}
        if action == "plant":
            paths = _calendar_folder(side, args)
            if args.get("file") not in _INDEX_SOURCES or not isinstance(args.get("ns"), int):
                raise BadArgs(f"index plant needs ns and a file of {_INDEX_SOURCES}")
            f = paths.folder / args["file"]
            if args.get("text") is not None:
                f.write_text(args["text"])
            os.utime(f, ns=(args["ns"], args["ns"]))
            return {}
        if action == "floor":
            return {"floor": semantic.floor(np.array(args["scores"], np.float32))}
    finally:
        embeddings.MODEL = saved
    raise BadArgs(f"index: unknown action {action!r}")


def notes_stale_op(side: Side, args: dict) -> dict:
    """The notes' read side (notes.py) on ``folder``'s transcript.json: ``write`` (an object) is stored as notes.json first
    (``stamp``: with the transcript, my-notes and lanes hashes of now put in; ``raw``: instead, this text as the file),
    ``guesses`` are filtered by backed_name_guesses and ``names`` ({value, names}) put through with_names. Answers the
    hashes, the lanes, the language, the reason and ``is_stale``."""
    from palaver import my_notes, notes, shared_mic
    from palaver.models import Utterance

    paths = _calendar_folder(side, args)
    utterances = [Utterance.from_dict(d) for d in json.loads(paths.transcript_json.read_text())]
    lanes = notes.shared_lanes(utterances, shared_mic.display(paths), shared_mic.mic_display(paths))
    mine = notes.my_notes_hash(my_notes.prompt_text(paths.folder))
    if args.get("raw") is not None:
        paths.notes.write_text(args["raw"])
    elif args.get("write") is not None:
        data = dict(args["write"])
        if args.get("stamp"):
            data.update(transcript_hash=notes.transcript_hash(utterances), my_notes_hash=mine, shared_lanes=lanes)
        notes.save(paths, data)
    out = {"transcript_hash": notes.transcript_hash(utterances), "my_notes_hash": mine, "shared_lanes": lanes,
           "language": notes.meeting_language(utterances), "reason": notes.stale_reason(paths, utterances),
           "is_stale": notes.is_stale(paths, utterances)}
    if args.get("guesses") is not None:
        out["backed"] = notes.backed_name_guesses(args["guesses"], utterances)
    if args.get("names") is not None:
        out["named"] = notes.with_names(args["names"]["value"], args["names"]["names"])
    return out


# --- files (Task 21, 22) ---------------------------------------------------------------------------


def _recording(side: Side, args: dict, key: str):
    """The recording ``args[key]`` names (a folder of the side's output dir)."""
    return _calendar_folder(side, {"folder": args.get(key)})


def cutting_op(side: Side, args: dict) -> dict:
    """Cutting recordings (cutting.py): ``action`` is ``span``, ``neighbours``, ``keeper`` (``first``, ``second``),
    ``split`` (``at``: an int stays one), ``discard`` (``at``, ``side``), ``join`` (``first``, ``second``, ``keep``,
    ``gap_why``), ``trash``, ``finish-join``, ``suggest-trim``, ``suggest-cut`` (``events``: event dicts, else
    events.json) on ``folder``; or ``plant``: ``files`` ({name: JSON value}) written into ``folder`` (made) as
    ``json.dumps`` writes them. Folders are answered by name, moved ones relative to the output dir; ``at`` again under
    another key (diff.py compares an "at" only for presence)."""
    from palaver import cutting

    action = args.get("action")
    if action == "plant":
        folder = side.recordings / args["folder"]
        folder.mkdir(parents=True, exist_ok=True)
        for name, value in args["files"].items():
            (folder / name).write_text(json.dumps(value))
        return {"planted": sorted(args["files"])}
    if action in ("keeper", "join"):
        first, second = _recording(side, args, "first"), _recording(side, args, "second")
        if action == "keeper":
            return {"keeper": cutting.keeper(first, second).folder.name}
        keep = _recording(side, args, "keep") if args.get("keep") else None
        return {"kept": cutting.join(first, second, keep=keep, gap_why=args.get("gap_why")).folder.name}
    paths = _recording(side, args, "folder")
    if action == "span":
        start, duration = cutting.span(paths)
        return {"start": start.isoformat(), "duration": duration}
    if action == "neighbours":
        return cutting.neighbours(paths)
    if action == "split":
        return {"tail": cutting.split(paths, args["at"]).folder.name}
    if action == "discard":
        return {"gone": str(cutting.discard(paths, args["at"], args["side"]).relative_to(side.recordings))}
    if action == "trash":
        return {"to": str(cutting.trash(paths).relative_to(side.recordings))}
    if action == "finish-join":
        cutting.finish_unfinished_join(paths)
        return {}
    if action == "suggest-trim":
        trim = cutting.suggest_trim(paths)
        return {"trim": trim, "trim_at": [s["at"] for s in trim]}
    if action == "suggest-cut":
        cut = cutting.suggest_cut(paths, _calendar_events(side, args))
        return {"cut": cut, "cut_at": cut and cut["at"]}
    raise BadArgs(f"cutting: unknown action {action!r}")


def growing_track_op(side: Side, args: dict) -> dict:
    """A track of ``folder`` read as the live worker reads it while it is recorded (live.py ``GrowingTrack``):
    ``track`` (system, mic_raw or mic), samples ``start`` to ``end``."""
    from palaver.live import GrowingTrack

    paths = _recording(side, args, "folder")
    final = {"system": paths.system_wav, "mic_raw": paths.mic_raw_wav, "mic": paths.mic_wav}[args["track"]]
    track = GrowingTrack(final)
    return {"available": track.available(), "samples": track.read(args["start"], args["end"]).tolist()}


def wav_op(side: Side, args: dict) -> dict:
    """``sf.info`` of a track of ``folder``: frames, rate, channels; and ``sf.read`` of ``start`` (``frames`` of them)."""
    import soundfile as sf

    paths = _recording(side, args, "folder")
    wav = {"system": paths.system_wav, "mic_raw": paths.mic_raw_wav, "mic": paths.mic_wav}[args["track"]]
    info = sf.info(str(wav))
    start = args.get("start", 0)
    samples = sf.read(str(wav), start=start, stop=start + args.get("frames", 0), dtype="int16", always_2d=True)[0]
    return {"frames": info.frames, "rate": info.samplerate, "channels": info.channels,
            "samples": samples.reshape(-1).tolist()}


def _side_path(side: Side, rel: str) -> Path:
    """``rel`` (a path relative to the side, no ``..``) under the side's root."""
    if not isinstance(rel, str) or not rel or rel.startswith("/") or ".." in rel.split("/"):
        raise BadArgs(f"not a path in the side: {rel!r}")
    return side.root / rel


def _undo_token(side: Side, args: dict) -> str:
    """The snapshot a step means: ``token`` as given; ``of``: the one with that label; ``broken``: the one whose manifest
    is no JSON (the tokens differ between the sides, so a scenario names a snapshot by its label)."""
    if "token" in args:
        return args["token"]
    root = side.recordings / ".trash" / ".undo"
    for snap in sorted(root.iterdir()) if root.is_dir() else []:
        try:
            label = json.loads((snap / "manifest.json").read_text()).get("label")
        except (OSError, ValueError):
            if args.get("broken"):
                return snap.name
            continue
        if "of" in args and label == args["of"]:
            return snap.name
    raise BadArgs(f"undo: no snapshot {args.get('of')!r}")


def undo_op(side: Side, args: dict) -> dict:
    """Undo snapshots (undo.py) of the side's recordings: ``action`` is ``take`` (``label``, ``meetings``, ``audio``,
    ``speaker_files_of_all``, ``stores``), ``note`` (``extra``), ``extra``, ``label``, ``stores``, ``sealed``, ``moved``
    (``src``, ``dst``), ``created`` (``ids``), ``created-ids``, ``restore`` (``check``), ``prune`` (``keep``,
    ``max_age_hours``), ``fingerprint`` (``path``, ``partial``, ``store``); ``edit`` writes ``text`` to ``path`` (none:
    removes it) and ``break`` makes a snapshot's manifest no JSON. Paths are relative to the side; a snapshot is named by
    ``of`` (its label), ``broken`` or ``token`` (see ``_undo_token``)."""
    from datetime import timedelta

    from palaver import undo

    action, out = args.get("action"), side.recordings
    if action == "take":
        token = undo.take(out, args["label"], meetings=args.get("meetings", []), audio=args.get("audio", False),
                          speaker_files_of_all=args.get("speaker_files_of_all", False),
                          stores=[_side_path(side, s) for s in args.get("stores", [])])
        return {"token": token}
    if action == "edit":
        path = _side_path(side, args["path"])
        if args.get("text") is None:
            path.unlink()
        else:
            path.write_text(args["text"])
        return {}
    if action == "prune":
        undo.prune(out, keep=args.get("keep", 20), max_age=timedelta(hours=args.get("max_age_hours", 24)))
        root = out / ".trash" / ".undo"
        return {"left": len(list(root.iterdir())) if root.is_dir() else 0}
    if action == "fingerprint":
        path = _side_path(side, args["path"])
        if args.get("store"):
            return {"fingerprint": undo._store_fingerprint(path)}
        return {"fingerprint": undo._fingerprint(path, bool(args.get("partial")))}
    token = _undo_token(side, args)
    if action == "break":
        (out / ".trash" / ".undo" / token / "manifest.json").write_text("{not json")
        return {}
    if action == "note":
        undo.note(out, token, args["extra"])
        return {}
    if action == "extra":
        return {"extra": undo.extra(out, token)}
    if action == "label":
        return {"label": undo.label(out, token)}
    if action == "stores":
        return {"stores": [str(p) for p in undo.stores(out, token)]}
    if action == "sealed":
        undo.sealed(out, token)
        return {}
    if action == "moved":
        undo.moved(out, token, _side_path(side, args["src"]), _side_path(side, args["dst"]))
        return {}
    if action == "created":
        undo.created(out, token, args["ids"])
        return {}
    if action == "created-ids":
        return {"created": undo.created_ids(out, token)}
    if action == "restore":
        return {"ids": undo.restore(out, token, check=args.get("check", True))}
    raise BadArgs(f"undo: unknown action {action!r}")


def exchange_op(side: Side, args: dict) -> dict:
    """Exporting a meeting (exchange.py, Task 24): ``action`` is ``export`` (``folder`` to ``dest``, a path relative to
    the side; ``notes``, ``voices``, ``confirm_local``, ``projects``, ``user_name`` (else the side's)), answered as the
    zip's entries ([name, compress_type, file_size]) and each JSON in it, the manifest's ``exported_at`` only as
    present; ``file-name`` (``folder``); ``free-name`` (``name`` in ``in``, a path relative to the side); ``sweep``
    (``downloads``: home/Downloads too; ``older_than``); ``leftover``: a folder ``path`` (relative to the side) with a
    file in it, last changed ``hours_ago``. With ``audio`` (Task 27) the tracks go in too; the sides' encoders differ
    (libopus 1.4 in soundfile, 1.5.2 in Swift), so an audio entry is answered as [name, compress_type, "<audio>"], its
    content as what soundfile reads of it ({rate, channels, frames}), and its manifest entry's sha256 and bytes only as
    present.

    Importing one (Task 25): ``import`` (``file``, a path relative to the side; ``separate``; ``calendar``: the fake
    calendar is this Mac's; ``settle``: settled once placed; ``user_name``), answered as ``Imported``; ``match``
    (``file``): the meeting here it is; ``settle`` (``folder``); ``decide-voices`` (``folder``, ``add``): the names
    learned. ``plant-golden`` (Task 27): the golden ``name`` (native/Tests/PalaverDomainTests/Goldens) copied to
    ``dest`` (relative to the side), so both sides import the same audio."""
    import os
    import time
    import zipfile

    from palaver import exchange

    action = args.get("action")
    if action == "leftover":
        path = _side_path(side, args["path"])
        path.mkdir(parents=True, exist_ok=True)
        (path / "part").write_text("x")
        when = time.time() - args.get("hours_ago", 0) * 3600
        os.utime(path, (when, when))
        return {}
    if action == "sweep":
        downloads = side.home / "Downloads" if args.get("downloads") else None
        exchange.sweep(side.recordings, downloads, older_than=args.get("older_than", 3600))
        return {}
    if action == "free-name":
        return {"name": exchange.free_name(_side_path(side, args["in"]), args["name"]).name}
    if action == "plant-golden":
        from tools.parity.goldens import GOLDENS

        name = args.get("name")
        if not isinstance(name, str) or "/" in name or not (GOLDENS / name).is_file():
            raise BadArgs(f"exchange plant-golden: no golden {name!r}")
        dest = _side_path(side, args["dest"])
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes((GOLDENS / name).read_bytes())
        return {}
    user = args.get("user_name", side.user_name)

    def match_json(m):
        return None if m is None else {"id": m.id, "how": m.how, "own": m.own}

    if action == "match":
        return {"match": match_json(exchange.find_match(side.recordings, exchange.read_package(_side_path(side, args["file"]))))}
    if action == "import":
        def after(meeting_id: str) -> None:
            exchange.settle(side.recordings, meeting_id, user_name=user)

        done = exchange.import_package(side.recordings, _side_path(side, args["file"]), user_name=user,
                                       separate=args.get("separate", False),
                                       calendar=_provider(side) if args.get("calendar") else None,
                                       after=after if args.get("settle") else None)
        return {"id": done.id, "from": done.sender, "matched": match_json(done.matched), "voices": done.voices,
                "names": done.names, "warnings": done.warnings}
    paths = _recording(side, args, "folder")
    if action == "settle":
        exchange.settle(side.recordings, paths.folder.name, user_name=user)
        return {}
    if action == "decide-voices":
        return {"learned": exchange.decide_voices(paths, args["add"], user_name=user)}
    if action == "file-name":
        return {"name": exchange.file_name(paths)}
    if action == "export":
        import io

        import soundfile as sf

        out = exchange.export_meeting(paths, _side_path(side, args["dest"]), user_name=args.get("user_name", side.user_name),
                                      notes=args.get("notes", True), voices=args.get("voices", False),
                                      audio=args.get("audio", False), confirm_local=args.get("confirm_local", False),
                                      projects=args.get("projects", []))
        entries, contents = [], {}
        with zipfile.ZipFile(out) as zf:
            for i in zf.infolist():
                if i.filename.startswith("audio/"):
                    info = sf.info(io.BytesIO(zf.read(i.filename)))
                    entries.append([i.filename, i.compress_type, "<audio>"])
                    contents[i.filename] = {"rate": info.samplerate, "channels": info.channels, "frames": info.frames}
                else:
                    entries.append([i.filename, i.compress_type, i.file_size])
                    contents[i.filename] = json.loads(zf.read(i.filename))
        manifest = contents["manifest.json"]
        manifest["exported_at"] = bool(manifest.get("exported_at"))
        for name, listed in manifest["files"].items():
            if name.startswith("audio/"):
                listed["sha256"], listed["bytes"] = bool(listed["sha256"]), bool(listed["bytes"])
        return {"name": out.name, "entries": entries, "contents": contents}
    raise BadArgs(f"exchange: unknown action {action!r}")


# --- storage (Task 28) ------------------------------------------------------------------------------


def _config(side: Side):
    from palaver.config import load_config

    return load_config(side.stores / "config.toml", secrets=False)


def _naive_now(args: dict):
    """``now``: a naive local ISO time (storage.py compares naive local times), else the clock's."""
    from datetime import datetime

    return datetime.fromisoformat(args["now"]) if "now" in args else None


def _plant_root(side: Side, where: Any) -> Path:
    """Where ``plant`` writes: ``cache:<repo>`` (the repo's Hugging Face cache folder), ``models`` (Application
    Support/palaver/models) or ``support`` (Application Support/palaver)."""
    from palaver import install_layout, onboarding

    if isinstance(where, str) and where.startswith("cache:"):
        return onboarding._cache_dir(where[len("cache:"):])
    if where == "models":
        return install_layout.models_dir()
    if where == "support":
        return install_layout.support_dir()
    raise BadArgs(f"storage plant: where is cache:<repo>, models or support, not {where!r}")


@contextlib.contextmanager
def _side_engine_marker() -> Iterator[None]:
    """install_layout.engine_proven_marker as the app has it (in the side's Application Support): the root conftest
    moves it to a temporary file of each test, which the side's ``plant`` can't reach."""
    from palaver import install_layout

    saved = install_layout.engine_proven_marker
    install_layout.engine_proven_marker = lambda home=None: install_layout.support_dir(home) / "engine-transcribed"
    try:
        yield
    finally:
        install_layout.engine_proven_marker = saved


def storage_op(side: Side, args: dict) -> Any:
    """What the meetings and models take (storage.py): ``action`` is ``plant`` (``where``: see ``_plant_root``;
    ``files``: {relative path: size}, zero bytes each), ``summary`` (``now``), ``models``, ``delete-model`` (``id``),
    ``drop-retired``, ``audio-days``, ``set-audio-days`` (``days``: any JSON value), ``meeting`` (``folder``: its audio
    files, bytes, whether it can go and the bytes deleted so far), ``drop-audio`` (``folder``), ``older-than``
    (``days``, ``now``) or ``drop-old-audio`` (``days``, ``now``)."""
    with _side_engine_marker():
        return _storage(side, args)


def _storage(side: Side, args: dict) -> Any:
    from palaver import storage

    action = args.get("action")
    if action == "plant":
        root = _plant_root(side, args.get("where"))
        for rel, size in args["files"].items():
            if not isinstance(rel, str) or not rel or rel.startswith("/") or ".." in rel.split("/"):
                raise BadArgs(f"storage plant: not a relative path: {rel!r}")
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
            (root / rel).write_bytes(b"\0" * size)
        return {"planted": sorted(args["files"])}
    if action == "summary":
        return storage.summary(side.recordings, _config(side), _naive_now(args))
    if action == "models":
        return storage.models(_config(side))
    if action == "delete-model":
        return {"freed": storage.delete_model(_config(side), args["id"])}
    if action == "drop-retired":
        return {"freed": storage.drop_retired(_config(side))}
    if action == "audio-days":
        return {"days": storage.audio_days()}
    if action == "set-audio-days":
        storage.set_audio_days(args["days"])
        return {"days": storage.audio_days()}
    if action == "older-than":
        return [p.folder.name for p in storage.older_than(side.recordings, args["days"], _naive_now(args))]
    if action == "drop-old-audio":
        count, freed = storage.drop_old_audio(side.recordings, args["days"], _naive_now(args))
        return {"meetings": count, "bytes": freed}
    paths = _recording(side, args, "folder")
    if action == "meeting":
        return {"audio": [f.name for f in storage.audio_files(paths)], "audio_bytes": storage.audio_bytes(paths),
                "can_drop": storage.can_drop(paths), "deleted": (storage.deleted(paths) or {}).get("bytes")}
    if action == "drop-audio":
        return {"freed": storage.drop_audio(paths)}
    raise BadArgs(f"storage: unknown action {action!r}")


def model_choice_op(side: Side, args: dict) -> Any:
    """Which language model runs a feature, the read side (llm.py, providers.py): ``action`` is ``save``
    (``settings``: merged into settings.json as settings.update does), ``keep-local`` (``folder``, ``on``),
    ``choice-for`` (``feature``, ``folders``), ``local-model``, ``memory-gb`` (``feature``, ``folder``),
    ``settings-of`` (``provider``, with llm.provider_defaults) or ``labels``. Never a key."""
    from palaver import llm, providers, settings

    action = args.get("action")
    cfg = _config(side)
    if action == "save":
        settings.update(args["settings"])
        return {}
    if action == "keep-local":
        llm.set_local_only(_recording(side, args, "folder").folder, bool(args.get("on")))
        return {}
    if action == "choice-for":
        folders = [_recording(side, {"folder": f}, "folder").folder for f in args.get("folders", [])]
        return {"choice": llm.choice_for(cfg, args["feature"], folders)}
    if action == "local-model":
        return {"model": llm.local_model(cfg)}
    if action == "memory-gb":
        folder = _recording(side, args, "folder").folder if args.get("folder") else None
        return {"gb": llm.memory_gb(cfg, args["feature"], folder)}
    if action == "settings-of":
        return providers.settings_of(args["provider"], llm.provider_defaults(cfg, args["provider"]))
    if action == "labels":
        return {pid: p.label for pid, p in providers.PROVIDERS.items()}
    raise BadArgs(f"model-choice: unknown action {action!r}")


# --- coach (Task 31) -----------------------------------------------------------------------


def coach_op(side: Side, args: dict) -> Any:
    """The coach's numbers (coach.py): ``action`` is ``plant`` (``folder``, ``lines``: [speaker, start, end, text],
    a SPEAKER_xx line labelled; ``start_time``: meta.json and transcript.json written as the app writes them),
    ``analyze`` (``folder``, ``user``, ``invited``, ``names``), ``result`` (``folder``), ``meetings``, ``history``
    (``limit``), ``baseline``/``trends`` (``rows``, else the history; ``weeks``), ``highlights`` (``folder``;
    ``base``, else the saved baseline), ``refresh`` or ``load``. The user is the side's unless ``user`` says."""
    from palaver import coach

    action = args.get("action")
    user = args.get("user", side.user_name)
    if action == "plant":
        folder = side.recordings / str(args["folder"])
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "meta.json").write_text(json.dumps({"start_time": args.get("start_time", "2026-10-27T10:00:00+01:00"),
                                                      "duration_seconds": 900}, indent=2))
        (folder / "transcript.json").write_text(json.dumps(
            [{"speaker": who, "start": s, "end": e, "text": t, **({"label": who} if who.startswith("SPEAKER") else {})}
             for who, s, e, t in args["lines"]], indent=2))
        return {}
    if action == "analyze":
        return coach.analyze(_recording(side, args, "folder"), user_name=user, invited=args.get("invited"),
                             names=args.get("names"))
    if action == "result":
        return coach.result(_recording(side, args, "folder"), user_name=user)
    if action == "meetings":
        return [p.folder.name for p in coach.meetings(side.recordings)]
    if action == "history":
        return coach.history(side.recordings, user_name=user, limit=args.get("limit"))
    if action == "baseline":
        rows = args["rows"] if "rows" in args else coach.history(side.recordings, user_name=user)
        return coach.baseline(rows)
    if action == "trends":
        rows = args["rows"] if "rows" in args else coach.history(side.recordings, user_name=user)
        return coach.trends(rows, weeks=args.get("weeks", coach.TREND_WEEKS))
    if action == "highlights":
        base = args["base"] if "base" in args else coach.load_baseline()
        return coach.highlights(coach.result(_recording(side, args, "folder"), user_name=user), base)
    if action == "refresh":
        return coach.refresh_baseline(side.recordings, user_name=user)
    if action == "load":
        return coach.load_baseline()
    raise BadArgs(f"coach: unknown action {action!r}")


# --- pipeline (Task 32) ----------------------------------------------------------------------


def pipeline_op(side: Side, args: dict) -> Any:
    """The merger and the cleanup filters (merger.py, cleanup.py): ``action`` is ``merge`` (``mic``, ``system``,
    ``turns`` as dicts, or ``folder``: its mic_segments.json, system_segments.json and system_turns.json, a missing one
    empty), ``assign`` (``segments``, ``turns``: [start, end, text, speaker] of each word), ``silent`` (``folder``,
    ``track``, ``segments``, ``min_peak_dbfs``), ``bleed`` (``mic``, ``system``; ``window``, ``min_words``,
    ``min_overlap``), ``echoes`` (``mic``: a segment, ``remote``: words), ``echo`` (``folder``, ``mic``, ``system``:
    on its mic.wav and mic_raw.wav), or ``plant-wav``: ``track`` of ``folder`` (made) written as PCM_16 at ``rate``,
    ``seconds`` long, silent but for ``regions`` [start, end, amplitude, period] of an integer sawtooth. Segments
    answer as dicts."""
    import numpy as np
    import soundfile as sf

    from palaver import cleanup, merger
    from palaver.models import Segment, SpeakerTurn, Word

    def segments(key: str) -> list[Segment]:
        return [Segment.from_dict(d) for d in args.get(key, [])]

    def track(paths) -> Path:
        return {"system": paths.system_wav, "mic_raw": paths.mic_raw_wav, "mic": paths.mic_wav}[args["track"]]

    action = args.get("action")
    if action == "plant-wav":
        from palaver.paths import RecordingPaths

        paths = RecordingPaths(side.recordings / str(args["folder"]))
        paths.folder.mkdir(parents=True, exist_ok=True)
        rate = args.get("rate", 16_000)
        x = np.zeros(int(args["seconds"] * rate), dtype=np.int16)
        for start, end, amp, period in args.get("regions", []):
            for i in range(int(start * rate), min(len(x), int(end * rate))):
                x[i] = (i % period) * 2 * amp // (period - 1) - amp
        sf.write(str(track(paths)), x, rate, subtype="PCM_16")
        return {"frames": len(x)}
    if action == "merge":
        if "folder" in args:
            paths = _recording(side, args, "folder")
            def read(file: Path, model):
                return [model.from_dict(d) for d in json.loads(file.read_text())] if file.is_file() else []
            mic, system = read(paths.mic_segments, Segment), read(paths.system_segments, Segment)
            turns = read(paths.system_turns, SpeakerTurn)
        else:
            mic, system = segments("mic"), segments("system")
            turns = [SpeakerTurn.from_dict(d) for d in args.get("turns", [])]
        return [u.to_dict() for u in merger.merge(mic, system, turns)]
    if action == "assign":
        turns = [SpeakerTurn.from_dict(d) for d in args.get("turns", [])]
        return [list(w) for w in merger.assign_speakers_to_words(segments("segments"), turns)]
    if action == "silent":
        wav = track(_recording(side, args, "folder"))
        kept = cleanup.drop_silent_segments(segments("segments"), wav, args.get("min_peak_dbfs", cleanup.MIC_MIN_PEAK_DBFS))
        return [s.to_dict() for s in kept]
    if action == "bleed":
        options = {k: args[k] for k in ("window", "min_words", "min_overlap") if k in args}
        return [s.to_dict() for s in cleanup.drop_bleed_duplicates(segments("mic"), segments("system"), **options)]
    if action == "echoes":
        return cleanup.echoes_remote(Segment.from_dict(args["mic"]), [Word.from_dict(d) for d in args["remote"]])
    if action == "echo":
        paths = _recording(side, args, "folder")
        return [s.to_dict() for s in cleanup.drop_echo(segments("mic"), segments("system"), paths.mic_wav, paths.mic_raw_wav)]
    raise BadArgs(f"pipeline: unknown action {action!r}")


# --- the menu bar app's files (Task 37) ---------------------------------------------------


_APP_FILES = ("daemon.json", "update.json")


def app_state_op(side: Side, args: dict) -> dict:
    """The menu bar app's files the window's server reads: ``files`` ({name: JSON value, or null to remove it}, names
    from ``_APP_FILES``) written into the side's Application Support/palaver with ``json.dumps``; the string ``"<now>"``
    anywhere in a value stands for the time now (``isoformat(timespec="seconds")``), so daemon.json is fresh."""
    from datetime import datetime

    from palaver import install_layout

    now = datetime.now().astimezone().isoformat(timespec="seconds")

    def fill(v: Any) -> Any:
        if v == "<now>":
            return now
        if isinstance(v, dict):
            return {k: fill(x) for k, x in v.items()}
        if isinstance(v, list):
            return [fill(x) for x in v]
        return v

    files = args.get("files")
    if not isinstance(files, dict) or any(name not in _APP_FILES for name in files):
        raise BadArgs(f"app-state: files is {{name: value}} with names from {_APP_FILES}")
    root = install_layout.support_dir()
    for name, value in files.items():
        path = root / name
        if value is None:
            path.unlink(missing_ok=True)
        else:
            root.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(fill(value)))
    return {"written": sorted(files)}


TABLE: dict[str, Callable[[Side, dict], Any]] = {
    "json-roundtrip": json_roundtrip,
    "models-roundtrip": models_roundtrip,
    "meeting-status": meeting_status,
    "meeting-markers": meeting_markers,
    "hold-lock": hold_lock,
    "my-notes": my_notes_op,
    "glossary": glossary_op,
    "glossary-suggest": glossary_suggest_op,
    "render": render_op,
    "attribution": attribution_op,
    "organizations": organizations_op,
    "title": title_op,
    "speakers": speakers_op,
    "shared-mic": shared_mic_op,
    "voices": voices_op,
    "people": people_op,
    "inference": inference_op,
    "hints": hints_op,
    "projects": projects_op,
    "prep": prep_op,
    "calendar-attach": calendar_attach_op,
    "search-parse": search_parse_op,
    "e5-encode": e5_encode_op,
    "index": index_op,
    "notes-stale": notes_stale_op,
    "cutting": cutting_op,
    "growing-track": growing_track_op,
    "wav": wav_op,
    "undo": undo_op,
    "exchange": exchange_op,
    "storage": storage_op,
    "model-choice": model_choice_op,
    "coach": coach_op,
    "pipeline": pipeline_op,
    "app-state": app_state_op,
}
DEFAULT_ARGS: dict[str, dict] = {
    "json-roundtrip": {"formats": JSON_FORMATS},
}
