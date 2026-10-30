"""A recording cut by a Palaver restart, and the parts that continue it
(issue #47).

When Palaver quits while a call is recorded and the same call is still on
when it starts again, the new recording continues the cut one: its folder
is listed in the first part's ``parts.json``. Nothing is processed until
the call ends; then `process` joins the parts into the first one (gaps
marked, see cutting.join) and transcribes the whole meeting.

What a live worker derived (mic.wav, segments, turns, voices) is kept only
when it finished every part. A worker stopped with the app leaves its part
without them, and a meeting stitched from some parts' text would miss the
rest — so then everything is derived again from the joined audio.
"""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path

from . import cutting, shared_mic
from .paths import RecordingPaths

LOGGER = logging.getLogger(__name__)

# What a live worker writes when it finishes a part (live.LiveProcessor.finish).
_LIVE = ("mic_wav", "mic_segments", "system_segments", "system_turns", "speaker_embeddings")
# Derived from those, label by label: stale once they are derived again.
_BY_LABEL = ("speakers", "speakers_auto", "speakers_merged", "speakers_ignored", "speakers_inferred",
             "speakers_unknown")
# `process` writes these anew from the joined parts.
_MERGED = ("transcript_json", "transcript_md", "review")


def _file(head: Path) -> Path:
    return RecordingPaths(head).parts


def _read(head: Path) -> dict:
    try:
        data = json.loads(_file(head).read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def parts(head: Path) -> list[Path]:
    """The folders that continue the recording ``head``, in order."""
    return [head.parent / name for name in _read(head).get("parts", [])]


def _write(head: Path, data: dict) -> None:
    path = _file(head)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(data, indent=2))
    os.replace(tmp, path)


def add_part(head: Path, part: Path) -> None:
    names = [p.name for p in parts(head)]
    if part.name not in names:
        _write(head, {**_read(head), "parts": [*names, part.name]})


def being_recorded(folder: Path) -> bool:
    """Whether ``folder`` is still being recorded: a running Palaver records
    into it, or its audio still grows (the .part files)."""
    from .cli import _status
    from .daemon import recording_into

    return folder.is_dir() and (_status(RecordingPaths(folder)) == "recording" or recording_into(folder))


def still_recording(head: Path) -> list[Path]:
    """``head`` and those of its parts still being recorded."""
    return [f for f in (head, *parts(head)) if being_recorded(f)]


def recover_head(head: RecordingPaths) -> RecordingPaths:
    """The meeting's first part, made whole if the app died recording it.
    One with no audio at all hands the meeting to its first readable part
    (and is left as it is, to be seen and trashed)."""
    if not parts(head.folder) or _recover(head):
        return head
    listed = parts(head.folder)
    for i, folder in enumerate(listed):
        part = RecordingPaths(folder)
        if folder.is_dir() and _recover(part):
            rest = [f.name for f in listed[i + 1:]]
            if rest:
                _write(folder, {"parts": rest})
            head.parts.unlink(missing_ok=True)
            LOGGER.warning("%s has no audio; %s is the meeting now", head.folder.name, folder.name)
            return part
    return head


def _recover(part: RecordingPaths) -> bool:
    """A part the app died recording, made whole as `process` would: the
    .part files promoted, meta.json rebuilt from the audio. False when
    there is nothing to read."""
    from .cli import _fold_audio_problems, _promote_part_files, _synthesize_meta_from_audio

    _promote_part_files(part)
    if part.meta.exists():
        _fold_audio_problems(part)  # a crash after meta.json, before they were folded in
        return True
    return _synthesize_meta_from_audio(part.folder, part)


def _live_done(paths: RecordingPaths) -> bool:
    return all(getattr(paths, name).exists() for name in _LIVE)


def join_parts(head: RecordingPaths) -> int:
    """Join the parts listed in ``head`` into it; returns how many. A part
    that is gone is dropped; one that can't be read stays listed (and its
    folder stays), so a later `process` can join it once it is recovered."""
    cutting.finish_unfinished_join(head)
    data = _read(head.folder)
    if not data.get("parts"):
        return 0
    if not _recover(head):
        LOGGER.warning("%s has no audio to join the parts into", head.folder.name)
        return 0
    found, unreadable = [], []
    for folder in parts(head.folder):
        part = RecordingPaths(folder)
        if not folder.is_dir():
            LOGGER.warning("%s, a part of %s, is gone", folder.name, head.folder.name)
        elif _recover(part):
            found.append(part)
        else:
            LOGGER.warning("%s, a part of %s, has no audio to join; left for later", folder.name, head.folder.name)
            unreadable.append(folder.name)
    # Decided once, before anything is joined: a join killed half-way and run
    # again must not take what the first one wrote for a live worker's output.
    complete = data.get("complete")
    if complete is None:
        complete = all(_live_done(p) for p in [head, *found])
        _write(head.folder, {**data, "complete": complete})
    live_names, seen = [], set()
    for p in [head, *found]:  # the head may hold them all already: a join run again
        try:
            named = json.loads(p.speakers_live.read_text())
        except (OSError, ValueError):
            continue
        for n in named:
            key = json.dumps(n, sort_keys=True)
            if key not in seen:
                seen.add(key)
                live_names.append(n)
    if live_names:
        head.speakers_live.write_text(json.dumps(live_names, ensure_ascii=False))
    for part in found:
        cutting.join(head, part, keep=head, gap_why="restart")
    stale = _MERGED if complete else (*_MERGED, *_LIVE, *_BY_LABEL)
    for name in stale:
        getattr(head, name).unlink(missing_ok=True)
    if not complete:  # rooms were lanes of labels that are gone; a whole-meeting mark stays
        shared_mic.forget_lanes(head)
    if unreadable:
        _write(head.folder, {"parts": unreadable})
    else:
        head.parts.unlink(missing_ok=True)
    if found:
        LOGGER.info("joined %d part(s) into %s%s", len(found), head.folder.name,
                    "" if complete else "; transcribing it whole")
    return len(found)
