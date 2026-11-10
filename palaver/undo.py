"""Undo for the Meetings window: a snapshot taken before a change, and
the way back.

``take`` copies what the change is about to touch (a meeting without its
audio, or only its per-speaker files, or a store file like the project
list) into ``.trash/.undo/<token>/``. The change tells ``moved`` and
``created`` what it moved or made, and ``sealed`` once it is done.
``restore`` puts everything back; what it replaces goes to ``.trash``,
nothing is deleted (only the audio of what an audio snapshot replaces: that
is the undone change's own audio, made again by doing the change again). A
restore is refused if a meeting, a store or a folder the change made changed
again after the change (its files differ from what ``sealed`` saw; the same
content written again, as a later change's undo does, is no change), or if
a meeting the change left in place has gone to the trash since.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import time
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from typing import Iterable

from . import cutting
from .paths import RecordingPaths, is_recording_folder_name

_SPEAKER_FILES = "speakers*.json"
# Caches made from a meeting's files in the background (the search index,
# #46), the locks my notes (#44) and the speaker files are written under, and the
# temporary files of a write in progress (my notes save while you type): not part of what a
# change touched, never snapshot or compared; a restored meeting gets them
# made again.
_DERIVED = ("search-index.*", ".my-notes.lock", ".speakers.lock", "*.tmp")


def _derived(path: Path) -> bool:
    return any(path.match(p) for p in _DERIVED)
# A snapshot without a manifest this young is still being taken.
_UNFINISHED = 3600


class Gone(Exception):
    """No such snapshot (never taken, pruned, or already used)."""


class Changed(Exception):
    """A meeting or store changed after the change; restoring would lose that."""


def _root(output_dir: Path) -> Path:
    return output_dir / cutting.TRASH / ".undo"


def _dir(output_dir: Path, token: str) -> Path:
    if len(token) != 32 or any(c not in "0123456789abcdef" for c in token):
        raise Gone(token)
    return _root(output_dir) / token


def _load(output_dir: Path, token: str) -> tuple[Path, dict]:
    snap = _dir(output_dir, token)
    try:
        return snap, json.loads((snap / "manifest.json").read_text())
    except (OSError, ValueError):
        raise Gone(token) from None


def _save(snap: Path, manifest: dict) -> None:
    tmp = snap / "manifest.json.tmp"
    tmp.write_text(json.dumps(manifest, indent=2))
    os.replace(tmp, snap / "manifest.json")  # a reader never sees half of it


def _newest(folder: Path, partial: bool) -> float:
    """Latest change in a meeting folder (or just its per-speaker files):
    the check of snapshots taken before fingerprints were recorded."""
    if not folder.is_dir():
        return 0.0
    items = folder.glob(_SPEAKER_FILES) if partial else [folder, *(p for p in folder.rglob("*") if not _derived(p))]
    return max((p.stat().st_mtime for p in items), default=0.0)


def _fingerprint(folder: Path, partial: bool) -> str:
    """What a meeting folder (or just its per-speaker files) holds: every
    file's name and size, and the content of all but the audio. A file
    rewritten with the same content (a later change undone) keeps it, so
    an older undo still works then; any real edit changes it."""
    if not folder.is_dir():
        return ""
    files = folder.glob(_SPEAKER_FILES) if partial else (p for p in folder.rglob("*") if p.is_file() and not _derived(p))
    digest = hashlib.sha256()
    for f in sorted(files, key=lambda p: p.relative_to(folder).as_posix()):
        name = f.relative_to(folder).as_posix()
        digest.update(f"{name}\0{f.stat().st_size}\0".encode())
        if f.suffix.lower() != ".wav":
            digest.update(hashlib.sha256(f.read_bytes()).digest())
    return digest.hexdigest()


def _store_fingerprint(path: Path) -> str:
    """What a store holds: a file's content, or a folder's (as for a
    meeting). Missing is the empty string."""
    if path.is_dir():
        return "dir:" + _fingerprint(path, False)
    if path.is_file():
        return "file:" + hashlib.sha256(path.read_bytes()).hexdigest()
    return ""


def _fingerprints(output_dir: Path, meetings: dict) -> None:
    for id_, entry in meetings.items():
        entry.pop("mtime", None)
        entry["fingerprint"] = _fingerprint(output_dir / id_, entry["partial"])


def _changed(folder: Path, entry: dict) -> bool:
    if not folder.is_dir():
        # A whole meeting that was there when the change was done and is gone
        # now went to the trash since: copying it back would make a second,
        # audio-less meeting. A partial one (speaker files) is skipped.
        return not entry["partial"] and bool(entry.get("fingerprint"))
    if "fingerprint" not in entry:  # a snapshot from before fingerprints
        return _newest(folder, entry["partial"]) > entry["mtime"]
    return _fingerprint(folder, entry["partial"]) != entry["fingerprint"]


def _what_changed(output_dir: Path, manifest: dict) -> str | None:
    """The first meeting, store or made folder that differs from what
    ``sealed`` saw, or None."""
    moved_back = {Path(src) for src, dst in manifest["moves"] if Path(dst).exists() and not Path(src).exists()}
    for id_, entry in manifest["meetings"].items():
        if output_dir / id_ in moved_back:  # the change moved it away; restore moves it back first
            continue
        if _changed(output_dir / id_, entry):
            return id_
    for store in manifest["stores"]:
        if "fingerprint" in store and _store_fingerprint(Path(store["path"])) != store["fingerprint"]:
            return store["path"]
    for id_, print_ in manifest.get("created_fingerprints", {}).items():
        folder = output_dir / id_
        if folder.is_dir() and _fingerprint(folder, False) != print_:  # gone (trashed) is no loss
            return id_
    return None


def take(output_dir: Path, label: str, *, meetings: Iterable[str] = (), audio: bool = False,
         speaker_files_of_all: bool = False, stores: Iterable[Path] = ()) -> str:
    """Snapshot what a change is about to touch; returns the token."""
    token = uuid.uuid4().hex
    snap = _dir(output_dir, token)
    entries: dict[str, dict] = {}
    skip_audio = shutil.ignore_patterns(*_DERIVED) if audio else shutil.ignore_patterns("*.wav", *_DERIVED)
    for id_ in meetings:
        if (output_dir / id_).is_dir():
            shutil.copytree(output_dir / id_, snap / "meetings" / id_, ignore=skip_audio)
            entries[id_] = {"partial": False, "audio": audio}
    if speaker_files_of_all:
        for folder in sorted(output_dir.iterdir()):
            if folder.name in entries or not folder.is_dir() or not is_recording_folder_name(folder.name):
                continue
            (snap / "meetings" / folder.name).mkdir(parents=True)
            for f in folder.glob(_SPEAKER_FILES):
                shutil.copy2(f, snap / "meetings" / folder.name / f.name)
            entries[folder.name] = {"partial": True, "audio": False}
    saved = []
    for i, store in enumerate(stores):
        store = Path(store)
        entry = {"path": str(store), "index": i, "existed": store.exists(), "dir": store.is_dir()}
        if store.is_dir():
            shutil.copytree(store, snap / "stores" / str(i) / store.name)
        elif store.exists():
            (snap / "stores" / str(i)).mkdir(parents=True)
            shutil.copy2(store, snap / "stores" / str(i) / store.name)
        saved.append(entry)
    _fingerprints(output_dir, entries)
    snap.mkdir(parents=True, exist_ok=True)
    _save(snap, {"label": label, "time": datetime.now().astimezone().isoformat(), "meetings": entries,
                 "stores": saved, "moves": [], "created": []})
    return token


def note(output_dir: Path, token: str, extra: dict) -> None:
    """What the change knows about itself and its undo needs besides the
    files (e.g. the paragraphs a notes change took out)."""
    snap, manifest = _load(output_dir, token)
    manifest["extra"] = extra
    _save(snap, manifest)


def extra(output_dir: Path, token: str) -> dict:
    return dict(_load(output_dir, token)[1].get("extra") or {})


def label(output_dir: Path, token: str) -> str:
    """What the change was ("trash", "my-notes clear", …)."""
    return str(_load(output_dir, token)[1].get("label", ""))


def stores(output_dir: Path, token: str) -> list[Path]:
    """The store files and folders the snapshot would put back."""
    return [Path(s["path"]) for s in _load(output_dir, token)[1]["stores"]]


def sealed(output_dir: Path, token: str) -> None:
    """The change is done: what the meetings, the stores and the folders
    it made look like now is what ``restore`` expects to find."""
    snap, manifest = _load(output_dir, token)
    _fingerprints(output_dir, manifest["meetings"])
    for store in manifest["stores"]:
        store["fingerprint"] = _store_fingerprint(Path(store["path"]))
    manifest["created_fingerprints"] = {id_: _fingerprint(output_dir / id_, False) for id_ in manifest["created"]}
    _save(snap, manifest)


def moved(output_dir: Path, token: str, src: Path, dst: Path) -> None:
    """The change moved ``src`` to ``dst``; restore moves it back."""
    snap, manifest = _load(output_dir, token)
    manifest["moves"].append([str(src), str(dst)])
    _save(snap, manifest)


def created(output_dir: Path, token: str, meeting_ids: Iterable[str]) -> None:
    """The change made these meeting folders; restore trashes them."""
    snap, manifest = _load(output_dir, token)
    manifest["created"] += list(meeting_ids)
    _save(snap, manifest)


def created_ids(output_dir: Path, token: str) -> list[str]:
    """The meeting folders the change made."""
    return list(_load(output_dir, token)[1]["created"])


def restore(output_dir: Path, token: str, *, check: bool = True) -> list[str]:
    """Put back what ``take`` copied; returns the meeting ids touched.
    ``check=False`` skips the refusal when something changed since (for
    rolling back a change that failed half-way)."""
    snap, manifest = _load(output_dir, token)
    entries = manifest["meetings"]
    if check and (what := _what_changed(output_dir, manifest)) is not None:
        raise Changed(what)
    bin_ = output_dir / cutting.TRASH
    bin_.mkdir(exist_ok=True)
    suffix = f".undone-{token[:8]}"
    aside = bin_ / f"undone-{token[:8]}"  # what a restore replaces, for files that are not meeting folders
    ids = []
    for src, dst in reversed(manifest["moves"]):
        src, dst = Path(src), Path(dst)
        if dst.exists() and not src.exists():
            shutil.move(str(dst), str(src))
            if src.parent == output_dir and src.name not in ids:
                ids.append(src.name)
    for id_ in manifest["created"]:
        if (output_dir / id_).is_dir():
            cutting.trash(RecordingPaths(output_dir / id_))
    for id_, entry in entries.items():
        folder, saved = output_dir / id_, snap / "meetings" / id_
        if entry["partial"]:
            if not folder.is_dir():  # trashed since: nothing to put back there
                continue
            for f in folder.glob(_SPEAKER_FILES):
                (aside / id_).mkdir(parents=True, exist_ok=True)
                shutil.move(str(f), str(aside / id_ / f.name))
            for f in saved.glob(_SPEAKER_FILES):
                shutil.copy2(f, folder / f.name)
        else:
            old = None
            if folder.exists():
                old = bin_ / (id_ + suffix)
                shutil.move(str(folder), str(old))
            shutil.copytree(saved, folder)
            if old and not entry["audio"]:  # the snapshot has no audio: keep the current (moved, not a second copy)
                for wav in old.glob("*.wav"):
                    if not (folder / wav.name).exists():
                        shutil.move(str(wav), str(folder / wav.name))
            elif old:  # the audio of the undone change (a cut): doing the change again makes it again
                for wav in old.rglob("*.wav"):
                    wav.unlink()
        if id_ not in ids:
            ids.append(id_)
    for store in manifest["stores"]:
        path, saved = Path(store["path"]), snap / "stores" / str(store["index"]) / Path(store["path"]).name
        if path.exists():
            (aside / "stores" / str(store["index"])).mkdir(parents=True, exist_ok=True)
            shutil.move(str(path), str(aside / "stores" / str(store["index"]) / path.name))
        if store["dir"]:
            shutil.copytree(saved, path)
        elif store["existed"]:
            path.parent.mkdir(parents=True, exist_ok=True)  # e.g. an image of notes cleared since
            shutil.copy2(saved, path)
    shutil.rmtree(snap)
    return ids


def prune(output_dir: Path, *, keep: int = 20, max_age: timedelta = timedelta(hours=24)) -> None:
    """Drop snapshots older than ``max_age``, and all but the newest ``keep``."""
    root = _root(output_dir)
    if not root.is_dir():
        return
    now = datetime.now().astimezone()
    live = []
    for snap in root.iterdir():
        try:
            when = datetime.fromisoformat(json.loads((snap / "manifest.json").read_text())["time"])
        except (OSError, ValueError, KeyError):
            when = None
        if when is None and time.time() - snap.stat().st_mtime < _UNFINISHED:
            continue  # a take still copying
        if when is None or now - when > max_age:
            shutil.rmtree(snap, ignore_errors=True)
        else:
            live.append((when, snap))
    for _, snap in sorted(live, key=lambda x: x[0], reverse=True)[keep:]:
        shutil.rmtree(snap, ignore_errors=True)
