"""Split a recording that ran into the next meeting, and join two that
belong together (issue #40).

Back-to-back calls run into each other: the recording of one meeting goes
on into the next. ``split`` cuts a recording at a moment; the part after
becomes a recording of its own. ``join`` puts two recordings together —
the part that belongs to the next meeting, or a meeting split by a dropped
call. They undo each other.

Both work on the files a processed recording has: the three audio tracks,
segments, speaker turns, the transcript, and per-label names, merges and
voices. Notes become stale (they no longer match the transcript); the
calendar event, names given by hand and projects stay with the recording
that keeps the meeting's identity. A recording joined into another is
moved to ``.trash`` in the recordings folder, never deleted.
"""

from __future__ import annotations

import json
import math
import os
import re
import shutil
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

import numpy as np
import soundfile as sf

from . import my_notes, shared_mic
from .paths import RecordingPaths, is_recording_folder_name, new_recording_folder

SAMPLE_RATE = 16_000
# A recording this soon after another one ended is "the next" one.
NEXT_WITHIN = timedelta(minutes=30)
# A voice in the joined part this alike to one in the kept part is the same person.
SAME_VOICE = 0.75
TRASH = ".trash"
_DATA = ("mic_segments", "system_segments", "system_turns", "transcript_json")
_LABEL = re.compile(r"SPEAKER_(\d+)$")
# Silence before the first word or after the last worth offering to remove
# (a call joined early, a recording left running), and what is kept of it.
SILENCE_TRIM = 120.0
SILENCE_PAD = 2.0


def _read(path: Path, default: Any = None) -> Any:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def _write(path: Path, data: Any) -> None:
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False))


def _tracks(paths: RecordingPaths) -> tuple[Path, Path, Path]:
    return paths.mic_raw_wav, paths.mic_wav, paths.system_wav


def span(paths: RecordingPaths) -> tuple[datetime, float]:
    """When the recording started, and how long it is (seconds)."""
    meta = _read(paths.meta, {})
    return datetime.fromisoformat(meta["start_time"]), float(meta["duration_seconds"])


def _slice(items: list[dict], lo: float, hi: float, shift: float) -> list[dict]:
    """Segments, turns or utterances starting in [lo, hi), moved by ``shift``."""
    out = []
    for d in items:
        if not lo <= d["start"] < hi:
            continue
        e = {**d, "start": round(d["start"] + shift, 3), "end": round(min(d["end"], hi) + shift, 3)}
        if d.get("words"):
            e["words"] = [{**w, "start": round(w["start"] + shift, 3), "end": round(min(w["end"], hi) + shift, 3)}
                          for w in d["words"] if w["start"] < hi]
        out.append(e)
    return out


def _moved_gaps(gaps: list[dict], lo: float, hi: float, shift: float) -> list[dict]:
    """The part of each gap (a stretch nothing was recorded) in [lo, hi),
    moved by ``shift``."""
    out = []
    for g in gaps:
        start, end = max(g["start"], lo), min(g["end"], hi)
        if start < end:
            out.append({**g, "start": round(start + shift, 3), "end": round(end + shift, 3)})
    return out


def _with_gaps(meta: dict, gaps: list[dict], problems: list[dict] | None = None) -> dict:
    """``meta`` with these ``gaps`` and ``audio_problems`` (issue #50; both
    spans in seconds from the start), each left out when there is none."""
    meta = {k: v for k, v in meta.items() if k not in ("gaps", "audio_problems")}
    if gaps:
        meta["gaps"] = sorted(gaps, key=lambda g: g["start"])
    if problems:
        meta["audio_problems"] = sorted(problems, key=lambda p: p["start"])
    return meta


def _problem_spans(meta: dict, at_stop: float) -> list[dict]:
    """A recording's audio problems as spans; one still open when it was
    written lasted to its end."""
    return [{**p, "end": at_stop if p.get("end") is None else p["end"]} for p in meta.get("audio_problems") or []]


def _moved_problems(problems: list[dict], lo: float, hi: float, shift: float) -> list[dict]:
    """``_moved_gaps`` for audio problems, keeping a zero-length one (a
    moment) when it falls in [lo, hi)."""
    moments = [p for p in problems if p["start"] == p["end"] and lo <= p["start"] < hi]
    return _moved_gaps([p for p in problems if p["start"] != p["end"]], lo, hi, shift) + [
        {**p, "start": round(p["start"] + shift, 3), "end": round(p["end"] + shift, 3)} for p in moments]


def _labels(paths: RecordingPaths) -> set[str]:
    return {t["speaker"] for t in _read(paths.system_turns, [])} | set(_read(paths.speaker_embeddings, {}))


def _keep_labels(paths: RecordingPaths, files: dict[str, Any], *, head: bool = True) -> None:
    """Per-label files of the original, for the labels this part has."""
    labels = {t["speaker"] for t in _read(paths.system_turns, [])}
    _write(paths.speaker_embeddings, {k: v for k, v in files["speaker_embeddings"].items() if k in labels})
    for name in ("speakers", "speakers_auto"):
        kept = {k: v for k, v in files[name].items() if k in labels}
        if kept:
            _write(getattr(paths, name), kept)
        else:
            getattr(paths, name).unlink(missing_ok=True)
    merges = {k: v for k, v in files["speakers_merged"].items() if k in labels and v in labels}
    if merges:
        _write(paths.speakers_merged, merges)
    else:
        paths.speakers_merged.unlink(missing_ok=True)
    ignored = sorted(set(files["speakers_ignored"]) & labels)
    if ignored:
        _write(paths.speakers_ignored, ignored)
    else:
        paths.speakers_ignored.unlink(missing_ok=True)
    unknown = sorted(set(files["speakers_unknown"]) & labels)
    if unknown:
        _write(paths.speakers_unknown, unknown)
    else:
        paths.speakers_unknown.unlink(missing_ok=True)
    rejected = {k: v for k, v in files["speakers_rejected"].items() if k in labels}
    if rejected:
        _write(paths.speakers_rejected, rejected)
    else:
        paths.speakers_rejected.unlink(missing_ok=True)
    paths.speakers_shared.unlink(missing_ok=True)
    shared_mic.save(paths, shared_mic.split_part(files["speakers_shared"], labels, head=head))


def _per_label_files(paths: RecordingPaths) -> dict[str, Any]:
    return {
        "speaker_embeddings": _read(paths.speaker_embeddings, {}),
        "speakers": _read(paths.speakers, {}),
        "speakers_auto": _read(paths.speakers_auto, {}),
        "speakers_merged": _read(paths.speakers_merged, {}),
        "speakers_ignored": _read(paths.speakers_ignored, []),
        "speakers_unknown": _read(paths.speakers_unknown, []),
        "speakers_rejected": _read(paths.speakers_rejected, {}),
        "speakers_shared": shared_mic.load(paths),
    }


def split(paths: RecordingPaths, at: float) -> RecordingPaths:
    """Cut the recording ``at`` seconds; returns the new recording of what
    came after. What came before stays where it is."""
    start, duration = span(paths)
    if not 1.0 <= at <= duration - 1.0:
        raise ValueError(f"cut between 0:01 and {int(duration // 60)}:{int(duration % 60) - 1:02d}")
    tail = RecordingPaths(new_recording_folder(paths.folder.parent, start + timedelta(seconds=at)))
    for src, dst in zip(_tracks(paths), _tracks(tail)):
        if src.exists():
            audio, rate = sf.read(str(src), dtype="int16")
            cut = int(round(at * rate))
            sf.write(str(dst), audio[cut:], rate, subtype="PCM_16")
            sf.write(str(src), audio[:cut], rate, subtype="PCM_16")
    for name in _DATA:
        items = _read(getattr(paths, name))
        if items is not None:
            _write(getattr(tail, name), _slice(items, at, math.inf, -at))
            _write(getattr(paths, name), _slice(items, 0.0, at, 0.0))
    files = _per_label_files(paths)
    for part in (paths, tail):
        _keep_labels(part, files, head=part is paths)
    meta = _read(paths.meta, {})
    gaps = meta.pop("gaps", [])
    problems = _problem_spans(meta, duration)
    cut_time = (start + timedelta(seconds=at)).isoformat()
    _write(tail.meta, _with_gaps({**meta, "start_time": cut_time, "duration_seconds": round(duration - at, 3),
                                  "trigger": "split"}, _moved_gaps(gaps, at, math.inf, -at),
                                 _moved_problems(problems, at, math.inf, -at)))
    head = {k: v for k, v in meta.items() if k != "stop_reason"}  # it did not stop: it goes on in the tail
    _write(paths.meta, _with_gaps({**head, "end_time": cut_time, "duration_seconds": round(at, 3)},
                                  _moved_gaps(gaps, 0.0, at, 0.0), _moved_problems(problems, 0.0, at, 0.0)))
    my_notes.split(paths.folder, tail.folder, at=at)  # what the user wrote after the cut goes along
    # A meeting kept on this Mac: both parts are; who transcribed it (#54): both parts.
    for carried in ("language", "local_only", "transcription"):
        if getattr(paths, carried).exists():
            shutil.copy2(getattr(paths, carried), getattr(tail, carried))
    for stale in (paths.review, paths.speakers_inferred):
        stale.unlink(missing_ok=True)
    return tail


# What a recording consists of — as opposed to what makes it a meeting
# (calendar event, the user's title, notes, review, Notion page, project
# assignments by folder name), which stays in its folder.
_CONTENT = ("mic_raw_wav", "mic_wav", "system_wav", "meta", "language", "transcript_md", "speaker_embeddings",
            "speakers", "speakers_auto", "speakers_merged", "speakers_ignored", "speakers_inferred",
            "speakers_rejected", "speakers_unknown", "transcription", *_DATA)


def trash(paths: RecordingPaths) -> Path:
    """Move a recording to ``.trash`` in the recordings folder (``-2``, ``-3``, …
    if the name is taken); returns where it went."""
    bin_ = paths.folder.parent / TRASH
    bin_.mkdir(exist_ok=True)
    target = bin_ / paths.folder.name
    n = 2
    while target.exists():  # an earlier one with this name is still in there
        target = bin_ / f"{paths.folder.name}-{n}"
        n += 1
    shutil.move(str(paths.folder), str(target))
    return target


def discard(paths: RecordingPaths, at: float, side: str) -> Path:
    """Throw away what came ``"after"`` or ``"before"`` the moment ``at``;
    the meeting keeps the rest. Returns where the discarded part went."""
    if side not in ("after", "before"):
        raise ValueError(f"discard 'after' or 'before', not {side!r}")
    tail = split(paths, at)
    if side == "before":
        # The meeting is what came after: its files go to the meeting's folder,
        # the rooms among its voices too; the meeting's own marks stay.
        shared_mic.save(paths, {**shared_mic.load(paths), "lanes": shared_mic.load(tail)["lanes"]})
        for name in _CONTENT:
            mine, theirs = getattr(paths, name), getattr(tail, name)
            swap = theirs.with_name(theirs.name + ".swap")
            if mine.exists():
                mine.rename(swap)
            if theirs.exists():
                theirs.rename(mine)
            if swap.exists():
                swap.rename(theirs)
    return trash(tail)


def _relabel(other: set[str], kept: set[str]) -> dict[str, str]:
    """New labels for ``other``'s speakers, after the kept recording's."""
    numbers = [int(m.group(1)) for label in kept if (m := _LABEL.match(label))]
    first = max(numbers, default=-1) + 1
    return {label: f"SPEAKER_{first + i:02d}" for i, label in enumerate(sorted(other))}


def _renamed(d: dict, relabel: dict[str, str]) -> dict:
    out = dict(d)
    for key in ("speaker", "label"):
        if out.get(key) in relabel:
            out[key] = relabel[out[key]]
    return out


def _unit(v) -> np.ndarray:
    a = np.asarray(v, dtype=float)
    n = np.linalg.norm(a)
    return a / n if n else a


def keeper(first: RecordingPaths, second: RecordingPaths) -> RecordingPaths:
    """The one of two recordings that ``join`` keeps: the longer one (the
    earlier one if they are as long)."""
    (a_start, a_len), (b_start, b_len) = span(first), span(second)
    if b_start < a_start:
        first, second, a_len, b_len = second, first, b_len, a_len
    return first if a_len >= b_len else second


# While a join rewrites the kept recording, what it was is kept here; a
# join that dies half-way is undone (or, past "done", finished) the next time.
_BACKUP = ".join-backup"
_DONE = "done"


def _backup(keep: RecordingPaths, other: RecordingPaths) -> Path:
    backup = keep.folder / _BACKUP
    shutil.rmtree(backup, ignore_errors=True)
    backup.mkdir()
    files = []
    tracks = {t.name for t in _tracks(keep)}
    for name in (*_CONTENT, "calendar", "title", "review", "my_notes", "speakers_shared"):
        f = getattr(keep, name)
        if not f.exists():
            continue
        if f.name in tracks:  # a track is replaced by a rename, never written into: a link keeps the old one
            try:
                os.link(f, backup / f.name)
            except OSError:
                shutil.copy2(f, backup / f.name)
        else:
            shutil.copy2(f, backup / f.name)
        files.append(f.name)
    # Written last: a backup without it is incomplete, and nothing was changed yet.
    _write_atomic(backup / "files.json", json.dumps({"files": files, "other": other.folder.name}))
    return backup


def _write_atomic(path: Path, text: str) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


def _restore(backup: Path, paths: RecordingPaths) -> None:
    kept = set(json.loads((backup / "files.json").read_text())["files"])
    for name in (*_CONTENT, "calendar", "title", "review", "my_notes", "speakers_shared"):
        f = getattr(paths, name)
        if f.name in kept:
            os.replace(backup / f.name, f)
        else:
            f.unlink(missing_ok=True)
        f.with_name(f.name + ".joining").unlink(missing_ok=True)
    shutil.rmtree(backup, ignore_errors=True)


def finish_unfinished_join(paths: RecordingPaths) -> None:
    """A join into ``paths`` that was killed: undo it, or — when all was
    written and only the other recording was not moved to the trash yet —
    finish it."""
    backup = paths.folder / _BACKUP
    if not backup.is_dir():
        return
    if not (backup / "files.json").exists():
        shutil.rmtree(backup, ignore_errors=True)  # killed while backing up: nothing changed
        return
    if (backup / _DONE).exists():
        other = paths.folder.parent / json.loads((backup / "files.json").read_text())["other"]
        if other.is_dir():
            trash(RecordingPaths(other))
        shutil.rmtree(backup, ignore_errors=True)
        return
    _restore(backup, paths)


def join(first: RecordingPaths, second: RecordingPaths, *, keep: RecordingPaths | None = None,
         gap_why: str | None = None) -> RecordingPaths:
    """Put two recordings together, in the order they were recorded. The
    longer one keeps the meeting (its folder, calendar event, notes,
    names), or ``keep``; the other is moved to the trash. With ``gap_why``
    the stretch between them is marked in meta.json as a gap nothing was
    recorded in (e.g. "restart"). Returns the joined recording."""
    for paths in (first, second):
        finish_unfinished_join(paths)
    (a_start, a_len), (b_start, b_len) = span(first), span(second)
    if b_start < a_start:
        first, second = second, first
        (a_start, a_len), (b_start, b_len) = (b_start, b_len), (a_start, a_len)
    offset = (b_start - a_start).total_seconds()
    a_keep = min(a_len, offset)  # an overlap: the second recording has that part
    gap = offset - a_keep
    keeps_first = keeper(first, second) is first if keep is None else keep.folder == first.folder
    keep, other = (first, second) if keeps_first else (second, first)
    backup = _backup(keep, other)
    try:
        relabel = _relabel(_labels(other), _labels(keep))

        for a_track, b_track, k_track in zip(_tracks(first), _tracks(second), _tracks(keep)):
            if not (a_track.exists() or b_track.exists()):
                continue
            a_audio = sf.read(str(a_track), dtype="int16")[0] if a_track.exists() else np.zeros(0, np.int16)
            b_audio = sf.read(str(b_track), dtype="int16")[0] if b_track.exists() else np.zeros(0, np.int16)
            n = int(round(a_keep * SAMPLE_RATE))
            a_audio = a_audio[:n]
            if len(a_audio) < n:  # a track that ended early
                a_audio = np.pad(a_audio, (0, n - len(a_audio)))
            joined = np.concatenate([a_audio, np.zeros(int(round(gap * SAMPLE_RATE)), np.int16), b_audio])
            tmp = k_track.with_name(k_track.name + ".joining")
            sf.write(str(tmp), joined, SAMPLE_RATE, subtype="PCM_16", format="WAV")
            tmp.replace(k_track)  # a track is the old one or the joined one, never half of it

        for name in _DATA:
            a_items, b_items = _read(getattr(first, name), []), _read(getattr(second, name), [])
            a_items = _slice(a_items, 0.0, a_keep, 0.0)
            b_items = _slice(b_items, 0.0, math.inf, offset)
            if other is first:
                a_items = [_renamed(d, relabel) for d in a_items]
            else:
                b_items = [_renamed(d, relabel) for d in b_items]
            _write(getattr(keep, name), sorted(a_items + b_items, key=lambda d: d["start"]))

        kept, theirs = _per_label_files(keep), _per_label_files(other)
        embeddings = {**kept["speaker_embeddings"],
                      **{relabel[k]: v for k, v in theirs["speaker_embeddings"].items() if k in relabel}}
        _write(keep.speaker_embeddings, embeddings)
        for name in ("speakers", "speakers_auto"):
            # label → name; a label mapped to itself is a rejected name and moves along.
            moved = {relabel.get(k, k): (relabel.get(k, k) if v == k else v) for k, v in theirs[name].items()}
            if kept[name] or moved:
                _write(getattr(keep, name), {**kept[name], **moved})
        merges = {**kept["speakers_merged"], **{relabel.get(k, k): relabel.get(v, v)
                                                 for k, v in theirs["speakers_merged"].items()}}
        # The same person in both parts is one speaker: merge by voice.
        kept_voices = {k: _unit(v) for k, v in kept["speaker_embeddings"].items() if k not in kept["speakers_merged"]}
        for label in relabel.values():
            if label in merges or label not in embeddings or not kept_voices:
                continue
            sim, best = max((float(_unit(embeddings[label]) @ v), k) for k, v in kept_voices.items())
            if sim >= SAME_VOICE:
                merges[label] = best
        if merges:
            _write(keep.speakers_merged, merges)
        ignored = sorted(set(kept["speakers_ignored"]) | {relabel.get(k, k) for k in theirs["speakers_ignored"]})
        if ignored:
            _write(keep.speakers_ignored, ignored)
        unknown = sorted(set(kept["speakers_unknown"]) | {relabel.get(k, k) for k in theirs["speakers_unknown"]})
        if unknown:
            _write(keep.speakers_unknown, unknown)
        rejected = {**kept["speakers_rejected"],
                    **{relabel.get(k, k): v for k, v in theirs["speakers_rejected"].items()}}
        if rejected:
            _write(keep.speakers_rejected, rejected)
        shared_mic.join_from(keep, theirs["speakers_shared"], relabel)
        shared_mic.follow_merges(keep)  # a room merged into a voice by its voice makes that voice the room

        meta, a_meta, b_meta = _read(keep.meta, {}), _read(first.meta, {}), _read(second.meta, {})
        gaps = _moved_gaps(a_meta.get("gaps", []), 0.0, a_keep, 0.0) + _moved_gaps(b_meta.get("gaps", []), 0.0, math.inf, offset)
        if gap_why and gap > 0:
            gaps.append({"start": round(a_keep, 3), "end": round(offset, 3), "why": gap_why})
        problems = (_moved_problems(_problem_spans(a_meta, a_keep), 0.0, a_keep, 0.0)
                    + _moved_problems(_problem_spans(b_meta, b_len), 0.0, math.inf, offset))
        # How the meeting ended is how its later part ended.
        ending = {k: b_meta[k] for k in ("end_time", "stop_reason") if b_meta.get(k)}
        meta = {k: v for k, v in meta.items() if k != "stop_reason"}
        _write(keep.meta, _with_gaps({**meta, "start_time": a_start.isoformat(),
                                      "duration_seconds": round(offset + b_len, 3), **ending}, gaps, problems))
        if other.calendar.exists() and _their_event_wins(keep, other):
            shutil.copy2(other.calendar, keep.calendar)
        if not keep.local_only.exists() and other.local_only.exists():  # kept on this Mac if either part was
            shutil.copy2(other.local_only, keep.local_only)
        if not keep.title.exists() and other.title.exists():  # the user's title, whichever part had it
            shutil.copy2(other.title, keep.title)
        # The user's own notes of both parts (#44), on the joined clock.
        my_notes.join(first.folder, second.folder, keep=keep.folder, offset=offset)
        joined = _joined_transcription(first, second)
        if joined:
            _write(keep.transcription, joined)
        for stale in (keep.review, keep.speakers_inferred):
            stale.unlink(missing_ok=True)
        (backup / _DONE).write_text("")
    except BaseException:
        if not (backup / _DONE).exists():
            _restore(backup, keep)  # the kept recording as it was; the other one untouched
        raise
    trash(other)
    shutil.rmtree(backup, ignore_errors=True)
    return keep


def _joined_transcription(first: RecordingPaths, second: RecordingPaths) -> dict | None:
    """Who transcribed the joined meeting, track by track (#54): who did
    both parts, or "mixed" — never sent to a service again."""
    a, b = _read(first.transcription, {}) or {}, _read(second.transcription, {}) or {}
    out = {}
    for track in sorted(set(a) | set(b)):
        x, y = a.get(track) or {}, b.get(track) or {}
        if x.get("engine") and x.get("engine") == y.get("engine") and x.get("engine") != "mixed":
            joined = {"engine": x["engine"]}
            if x.get("model") == y.get("model") and x.get("model"):
                joined["model"] = x["model"]
            for n in ("sent_seconds", "usd"):
                if isinstance(x.get(n), (int, float)) and isinstance(y.get(n), (int, float)):
                    joined[n] = round(x[n] + y[n], 4)
            if x.get("fallback_from") and x.get("fallback_from") == y.get("fallback_from"):
                joined["fallback_from"] = x["fallback_from"]
        else:
            joined = {"engine": "mixed", "parts": [x.get("engine"), y.get("engine")]}
        out[track] = {**joined, "at": datetime.now().astimezone().isoformat(timespec="seconds")}
    return out or None


def _by_you(paths: RecordingPaths) -> bool:
    """The recording's calendar decision is the user's: an event chosen, or none."""
    from . import calendar_events

    link = calendar_events.load_link(paths)
    return calendar_events.dismissed(paths) or (link is not None and link.by_you)


def _their_event_wins(keep: RecordingPaths, other: RecordingPaths) -> bool:
    """The other recording's calendar decision goes to the joined one: when
    the kept one has none, or the other's is the user's and the kept one's is
    not (an open question, a time match)."""
    return not keep.calendar.exists() or (_by_you(other) and not _by_you(keep))


def neighbours(paths: RecordingPaths) -> dict[str, str | None]:
    """The recordings just before and just after this one (ended or
    started within NEXT_WITHIN), by folder name."""
    start, duration = span(paths)
    end = start + timedelta(seconds=duration)
    before = after = None
    for folder in sorted(paths.folder.parent.iterdir()):
        if folder == paths.folder or not is_recording_folder_name(folder.name):
            continue
        other = RecordingPaths(folder)
        try:
            o_start, o_len = span(other)
        except (KeyError, TypeError, ValueError):
            continue
        if not other.transcript_json.exists():
            continue
        if -timedelta(minutes=1) <= o_start - end <= NEXT_WITHIN and after is None:
            after = folder.name
        o_end = o_start + timedelta(seconds=o_len)
        if -timedelta(minutes=1) <= start - o_end <= NEXT_WITHIN:
            before = folder.name
    return {"previous": before, "next": after}


# --- a cut where the recording ran into the next meeting --------------------

# Around the next event's start: where to look for voices that come or go,
# and for a pause to cut at.
BOUNDARY_WINDOW = 300.0
NEW_VOICE_TALK = 20.0  # seconds after the boundary: a voice of the next meeting
OLD_VOICE_TALK = 5.0   # ... with less than this before it


def _talk(turns: list[dict], lo: float, hi: float) -> dict[str, float]:
    out: dict[str, float] = {}
    for t in turns:
        overlap = min(t["end"], hi) - max(t["start"], lo)
        if overlap > 0:
            out[t["speaker"]] = out.get(t["speaker"], 0.0) + overlap
    return out


def _longest_pause(turns: list[dict], mine: list[dict], lo: float, hi: float) -> float | None:
    """The middle of the longest stretch in [lo, hi] when nobody spoke."""
    spans = sorted((max(d["start"], lo), min(d["end"], hi)) for d in turns + mine if d["end"] > lo and d["start"] < hi)
    best, at, cursor = 0.0, None, lo
    for s, e in spans:
        if s - cursor > best:
            best, at = s - cursor, (cursor + s) / 2
        cursor = max(cursor, e)
    if hi - cursor > best:
        at = (cursor + hi) / 2
    return at


def suggest_trim(paths: RecordingPaths) -> list[dict[str, Any]]:
    """Long silence before the first word or after the last: where to cut it
    off ("start": everything before ``at`` goes; "end": everything after).
    [] when there is none, or the user said no before."""
    lines = _read(paths.transcript_json, [])
    if paths.silence_dismissed.exists() or not lines:
        return []
    _, duration = span(paths)
    first, last = min(d["start"] for d in lines), max(d["end"] for d in lines)
    out = []
    if first - SILENCE_PAD >= SILENCE_TRIM:
        at = round(first - SILENCE_PAD, 2)
        out.append({"edge": "start", "at": at, "seconds": at})
    if duration - last - SILENCE_PAD >= SILENCE_TRIM:
        at = round(last + SILENCE_PAD, 2)
        out.append({"edge": "end", "at": at, "seconds": round(duration - at, 2)})
    return out


def suggest_cut(paths: RecordingPaths, events: list) -> dict[str, Any] | None:
    """Where the recording seems to run into another meeting: an event that
    starts while it records, around which voices come or go. None if
    nothing looks like it, or the user said no before."""
    from . import calendar_events
    from .speakers import load_ignored, load_merges, names_in_effect

    if paths.cut_dismissed.exists():
        return None
    start, duration = span(paths)
    own = calendar_events.load(paths)
    merges, ignored = load_merges(paths), load_ignored(paths)
    turns = [{**t, "speaker": merges.get(t["speaker"], t["speaker"])} for t in _read(paths.system_turns, [])]
    turns = [t for t in turns if t["speaker"] not in ignored]
    mine = _read(paths.mic_segments, [])
    lines = _read(paths.transcript_json, [])
    names = names_in_effect(paths)
    later = sorted((e for e in events if not e.all_day and (own is None or e.key != own.key or not e.key)
                    and (own is None or e.start > own.start)
                    and any(not a.is_self and not a.is_room for a in e.attendees)
                    and 60 < (e.start - start).total_seconds() < duration - 60), key=lambda e: e.start)
    for event in later:
        b = (event.start - start).total_seconds()
        before = _talk(turns, 0.0, b - BOUNDARY_WINDOW / 2)
        after = _talk(turns, b - BOUNDARY_WINDOW / 2, duration)
        new = [s for s, t in after.items() if t >= NEW_VOICE_TALK and before.get(s, 0.0) < OLD_VOICE_TALK]
        gone = [s for s, t in before.items() if t >= NEW_VOICE_TALK and _talk(turns, b + 60, duration).get(s, 0.0) < OLD_VOICE_TALK]
        if not new and not gone:
            continue
        firsts = [min(t["start"] for t in turns if t["speaker"] == s) for s in new]
        firsts = [f for f in firsts if b - BOUNDARY_WINDOW <= f <= b + 2 * BOUNDARY_WINDOW]
        at = min(firsts) if firsts else _longest_pause(turns, mine, b - BOUNDARY_WINDOW, b + BOUNDARY_WINDOW)
        if at is None:
            continue
        # At the start of a transcript line, where the window can cut.
        starts = sorted(d["start"] for d in lines if d["start"] >= at - 5)
        at = starts[0] if starts else at
        if at < 30 or duration - at < 30:
            continue
        def who(labels: list[str]) -> str:
            return ", ".join(names.get(s) or (f"Speaker {int(m.group(1)) + 1}" if (m := _LABEL.match(s)) else s)
                             for s in labels)

        why = []
        if new:
            why.append(f"new {'voice' if len(new) == 1 else 'voices'} from then on: {who(new)}")
        if gone:
            why.append(f"{who(gone)} stopped talking")
        return {"at": round(at, 2), "event": event.title, "event_start": event.start.isoformat(), "why": "; ".join(why)}
    return None
