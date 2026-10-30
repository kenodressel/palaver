"""What the meetings app shows, as plain data: the HTTP layer (server.py)
only turns these into JSON and audio responses."""

from __future__ import annotations

import difflib
import json
import logging
import os
import re
import threading
import time
from contextlib import contextmanager
from dataclasses import asdict, fields
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Callable, NamedTuple

import numpy as np
import soundfile as sf

from .. import (attribution, calendar_events, coach, cutting, exchange, glossary, inference, lifecycle, mcp_access,
                my_notes, notes, organizations, people, prep, projects, settings, shared_mic, titles)
from .. import search as search_query
from ..render import render_markdown
from .. import install_layout, model_jobs, undo
from .._xdg import xdg_config_home
from ..models import Segment, SpeakerTurn, Utterance
from ..paths import RecordingPaths, is_recording_folder_name, recording_folder_timestamp
from ..readable import readable
from ..speakers import (
    apply_speaker_names,
    load_inferred_names,
    load_merges,
    load_recognized_names,
    load_rejected_names,
    load_speaker_names,
    load_unknown,
    merge_speakers,
    load_ignored,
    merged_turns,
    name_live_speaker,
    names_in_effect,
    save_speaker_names,
    set_ignored,
    set_rejected_name,
    set_unknown as mark_unknown,
    talk_seconds,
    without_ignored,
)
from ..voices import MIN_TALK_SECONDS, VoiceBank

LOGGER = logging.getLogger(__name__)

CLIPS_PER_SPEAKER = 3
CLIP_SECONDS = 8.0
SEARCH_HITS_PER_MEETING = 5
SEARCH_MAX_MEETINGS = 50
SEARCH_NOTES_HITS = 3
STREAM_STALE_SECONDS = 10.0  # a stream.json not rewritten for this long is a stream gone


class NotFound(LookupError):
    pass


class Refused(ValueError):
    """A change the meeting can't have now; the message says why, for the page as it is."""


def recording_question(recording) -> dict:
    """The open question about the running recording, e.g. whether to stop
    a manual one after its call ended (issue #52); None outside the menu bar
    app or when nothing is asked. ``recording``: why the running recording
    records (issue #47), ``{"meeting", "text"}``, or None."""
    if recording is None:
        return {"question": None, "recording": None}
    why = getattr(recording, "recording", None)
    return {"question": recording.question(), "recording": why() if why else None}


def memory_status(recording) -> dict:
    """What Palaver costs in memory now and each worker's state (#49), from
    the menu bar app's daemon; None outside it."""
    memory = getattr(recording, "memory", None)
    return {"memory": memory() if memory else None}


def live_coach(recording) -> dict:
    """Who talks now in the running recording and the coach's nudge (#41,
    #42), from the menu bar app's daemon; None outside it."""
    coach = getattr(recording, "coach", None)
    return {"coach": coach() if coach else None}


def search_status(recording) -> dict:
    """Whether the menu bar app builds the search index now, and whether it
    first downloads its model (#46); both False without the menu bar app."""
    indexing = getattr(recording, "indexing", None)
    status = indexing() if indexing else {}
    return {"indexing": bool(status.get("indexing")), "downloading": bool(status.get("downloading"))}


_ANSWERED = {"stop": "stopped", "keep": "kept"}


def answer_recording_question(recording, choice: str, meeting_id: str) -> dict:
    """"stop" or "keep" the manual recording ``meeting_id``."""
    if recording is None:
        raise Refused("Recordings are started and stopped by the Palaver menu bar app.")
    if not recording.answer(choice, meeting_id):
        raise Refused("This recording is no longer running." if choice == "stop"
                      else "This recording is no longer running, or nothing is asked about it any more.")
    return {_ANSWERED[choice]: meeting_id}


_STILL_PROCESSING = "This meeting is still being transcribed. It can {} once that is done."


def _read_json(path: Path, default: Any = None) -> Any:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def meeting_paths(output_dir: Path, meeting_id: str) -> RecordingPaths:
    """The folder of ``meeting_id``; only names of recording folders, so a
    request can never reach outside the recordings directory."""
    if not is_recording_folder_name(meeting_id) or not (output_dir / meeting_id).is_dir():
        raise NotFound(meeting_id)
    return RecordingPaths(output_dir / meeting_id)


def _start(paths: RecordingPaths) -> str | None:
    meta = _read_json(paths.meta, {})
    if meta.get("start_time"):
        return meta["start_time"]
    stamp = recording_folder_timestamp(paths.folder.name)
    if stamp is None:
        return None
    return datetime.strptime(stamp, "%Y-%m-%dT%H-%M-%S").astimezone().isoformat()


def _status(paths: RecordingPaths) -> str:
    from ..cli import _status as folder_status
    from ..live import worker_running

    status = folder_status(paths)
    if status == "recording" or worker_running(paths.folder):
        return "recording"
    if status in ("processed", "synced"):
        return "ready"
    if status == "recorded":
        return "processing"
    return "incomplete"


_names = names_in_effect


def _label_display(label: str) -> str:
    """"Speaker 2" for SPEAKER_01."""
    number = label.rsplit("_", 1)[-1]
    return f"Speaker {int(number) + 1}" if number.isdigit() else label


def _display_names(paths: RecordingPaths) -> dict[str, str]:
    """Every label → what to show: its name, or "Speaker 2" for SPEAKER_01;
    a merged label shows as the label it was merged into."""
    names = _names(paths)
    merges = load_merges(paths)
    labels = {d["speaker"] for d in _read_json(paths.system_turns, [])} | set(names)
    shared = shared_mic.display(paths, labels)  # "Room (Raum 3.12)", "Several people" (#56)
    return {label: shared.get(label) or names.get(label) or _label_display(merges.get(label, label))
            for label in labels}


def _turns(paths: RecordingPaths) -> list[SpeakerTurn]:
    """Speaker turns, merged labels under the label they were merged into."""
    turns = [SpeakerTurn.from_dict(d) for d in _read_json(paths.system_turns, [])]
    return merged_turns(turns, load_merges(paths))


def _utterances(paths: RecordingPaths) -> list[Utterance]:
    return [Utterance.from_dict(d) for d in _read_json(paths.transcript_json, [])]


def _list_entry(paths: RecordingPaths) -> dict[str, Any]:
    """A meeting as the list shows it: what it was, who was in it, and what
    is still to do (speakers without a name, notes missing or out of date)."""
    meeting_notes = notes.load(paths)
    meta = _read_json(paths.meta, {})
    event = calendar_events.load(paths)
    raw = without_ignored(paths, _utterances(paths))
    talk = talk_seconds(_turns(paths))
    names = _names(paths)
    # Speakers worth a name: a few words from someone are no to-do, nor
    # is a room of several people (#56).
    ignored = load_ignored(paths) | shared_mic.shared_labels(paths)
    lanes = sorted((label for label in talk if talk[label] >= MIN_TALK_SECONDS and label not in ignored),
                   key=lambda label: -talk[label])
    people_named = list(dict.fromkeys(names[label] for label in lanes if label in names))
    nameless = [label for label in lanes if label not in names]
    # No to-do: a voice the user can't name, nor one left unnamed in the review (as in Needs you).
    unknown, seen = load_unknown(paths), _seen(paths) or set()
    title, title_from = titles.resolve(paths, event=event, meeting_notes=meeting_notes)
    return {
        "id": paths.folder.name,
        "start": _start(paths),
        "duration": meta.get("duration_seconds"),
        "status": _status(paths),
        "title": title,
        "title_from": title_from,
        "summary": glossary.current().apply_to((meeting_notes or {}).get("summary")),
        "people": people_named,
        "unnamed": sum(1 for label in nameless
                       if label not in unknown and _need_id({"kind": "unnamed", "label": label}) not in seen),
        "nameless": len(nameless),
        "invited": [a.name for a in calendar_events.candidates(event, user_name="")] if event else [],
        "has_notes": meeting_notes is not None,
        "imported": _imported_brief(paths),
        "notes_stale": bool(raw) and meeting_notes is not None and notes.is_stale(paths, raw),
    }


# id → (file times, entry): the window polls the list every few seconds.
_LIST_CACHE: dict[str, tuple[tuple, dict[str, Any]]] = {}


def _signature(paths: RecordingPaths) -> tuple:
    files = (paths.meta, paths.transcript_json, paths.calendar, paths.title, paths.speakers, paths.speakers_auto,
             paths.speakers_merged, paths.speakers_ignored, paths.speakers_inferred, paths.speakers_rejected,
             paths.speakers_shared, paths.speakers_unknown, paths.system_turns, paths.imported, paths.review,
             paths.notes, paths.my_notes, paths.my_notes_images, glossary._default_path())
    return tuple(f.stat().st_mtime_ns if f.exists() else 0 for f in files)


def list_meetings(output_dir: Path) -> list[dict[str, Any]]:
    """Newest first."""
    out = []
    if not output_dir.is_dir():
        return out
    store = projects.ProjectStore()
    for folder in sorted(output_dir.iterdir(), reverse=True):
        if not folder.is_dir() or not is_recording_folder_name(folder.name):
            continue
        paths = RecordingPaths(folder)
        signature = _signature(paths)
        cached = _LIST_CACHE.get(str(folder))
        if cached is None or cached[0] != signature:
            cached = (signature, _list_entry(paths))
            _LIST_CACHE[str(folder)] = cached
        # The status changes without a file changing (a live worker).
        out.append({**cached[1], "status": _status(paths), "projects": _projects_of(store, folder.name)})
    return out


def _projects_of(store: projects.ProjectStore, meeting_id: str) -> list[dict[str, Any]]:
    named = store.projects()
    return sorted(({"id": pid, "name": named[pid]["name"], **how,
                    "link": attribution.Link.from_project(named[pid]["name"], how).to_dict()}
                   for pid, how in store.of_meeting(meeting_id).items() if pid in named),
                  key=lambda p: p["name"].casefold())


def _speakers(paths: RecordingPaths, user_name: str, names: dict[str, str], display: dict[str, str],
              utterances: list[Utterance], meeting_notes: dict | None) -> list[dict[str, Any]]:
    turns = _turns(paths)
    talk = talk_seconds(turns)
    merges = load_merges(paths)
    recognized = load_recognized_names(paths)
    inferred = inference.load(paths)
    manual = load_speaker_names(paths)
    rejected = load_rejected_names(paths)
    guesses: dict[str, list[dict]] = {}
    for g in notes.backed_name_guesses((meeting_notes or {}).get("speaker_names", []), utterances):
        guesses.setdefault(g["label"], []).append({"name": g["name"], "evidence": g["evidence"]})
    spoken = {merges.get(u.label or u.speaker, u.label or u.speaker) for u in utterances}
    maybe = people.suggestions(paths)
    shared = shared_mic.display(paths)
    rooms = shared_mic.room_names(paths)

    mic = shared_mic.mic_room(paths)  # several people at the user's microphone (#56)
    mine = [u for u in utterances if u.speaker == user_name and not u.label]
    # An imported meeting the user said nothing in has no lane of theirs (#58).
    you = not paths.imported.exists() or bool(mine)
    has_audio = paths.system_wav.exists()
    speakers = [] if not you else [{
        "label": None,
        "name": user_name,
        "display": user_name if mic is None else shared_mic.mic_display(paths),
        "is_user": True,
        "shared": None if mic is None else "mic" if "mic" in shared_mic.load(paths) else "meeting",
        "room": mic or "",
        "talk_seconds": round(sum(u.end - u.start for u in mine), 1),
        "clips": [],
    }]
    ignored, unknown = load_ignored(paths), load_unknown(paths)
    for label in sorted(talk, key=lambda l: -talk[l]):
        if label not in spoken or label in ignored:
            continue
        own = sorted((t for t in turns if t.speaker == label), key=lambda t: t.start - t.end)
        clips = [{"start": t.start, "end": min(t.end, t.start + CLIP_SECONDS)}
                 for t in sorted(own[:CLIPS_PER_SPEAKER], key=lambda t: t.start)] if has_audio else []
        if label in shared:  # several people: no name, no guess (#56)
            speakers.append({
                "label": label, "name": None, "display": display[label], "is_user": False,
                "shared": "meeting" if shared_mic.meeting_marked(paths) else "room", "room": rooms.get(label, ""),
                "named_by": None, "link": None, "rejected": [], "recognized": None, "inferred": None,
                "guesses": [], "maybe": [], "talk_seconds": round(talk[label], 1),
                "merged": [{"label": m, "display": _label_display(m)} for m, into in sorted(merges.items())
                           if into == label],
                "clips": clips,
            })
            continue
        auto = recognized.get(label)
        guess = inferred.get(label) if label not in manual and not auto else None
        if guess and guess.get("name", "").casefold() in {n.casefold() for n in rejected.get(label, [])}:
            guess = None  # "Not Carla"
        named_by = "you" if manual.get(label, label) != label else (
            "voice" if auto and label not in manual else ("inferred" if guess else None))
        speakers.append({
            "label": label,
            "name": names.get(label),
            "display": display[label],
            "is_user": False,
            "named_by": named_by,
            "link": _speaker_link(names.get(label), named_by, auto, guess),
            "rejected": rejected.get(label, []),
            "recognized": {"name": auto[0], "similarity": round(auto[1], 2)} if auto else None,
            "inferred": {**{k: guess[k] for k in ("rule", "why", "confidence")}, "by": guess.get("by"),
                         "how": guess.get("how")}
            if guess else None,
            "guesses": [g for g in guesses.get(label, [])
                        if g["name"].casefold() not in {n.casefold() for n in rejected.get(label, [])}],
            "maybe": [{"name": n, "similarity": s} for n, s in maybe.get(label, [])],
            "talk_seconds": round(talk[label], 1),
            "merged": [{"label": m, "display": _label_display(m)} for m, into in sorted(merges.items())
                       if into == label],
            "shared": None,
            "unknown": label in unknown,  # "Don't Know Who This Is": no to-do while it has no name
            "clips": clips,
        })
    return speakers


def _speaker_link(name: str | None, named_by: str | None, auto, guess) -> dict[str, Any] | None:
    """How a lane got its name, for the window: by you, by voice, inferred."""
    if not name or named_by is None:
        return None
    if named_by == "voice":
        return attribution.Link("speaker", name, "voice", round(auto[1], 2), f"voice {round(auto[1] * 100)}% alike").to_dict()
    if named_by == "inferred":
        return attribution.Link.from_dict("speaker", name, {"source": "inferred", "confidence": guess.get("confidence"),
                                                            "reason": guess.get("why")}).to_dict()
    return attribution.Link("speaker", name, "you").to_dict()


def _calendar(event, user_name: str, used: set[str], link: attribution.Link | None = None) -> dict[str, Any] | None:
    """The event's title and people; ``invited``: invitees (as names already
    in use where they resolve) not yet given to a speaker of this meeting."""
    if event is None:
        return None
    attendees, seen = [], set()
    for a in event.attendees:
        if not a.is_room and not a.is_self and a.name.casefold() not in seen:
            seen.add(a.name.casefold())
            attendees.append({"name": a.name, "organizer": a.organizer, "response": a.response})
    known = _bank_names()
    invited = []
    for a in calendar_events.candidates(event, user_name=user_name):
        name = calendar_events.resolve(a.name, known) or a.name
        if name not in used and name not in invited:
            invited.append(name)
    return {
        "title": event.title,
        "attendees": attendees,
        "invited": invited,
        "link": (link or attribution.Link("event", event.title)).to_dict(),
    }


def _event_choice(e: calendar_events.Event, key: str, current: calendar_events.Event | None = None) -> dict[str, Any]:
    return {"key": key, "title": e.title, "start": e.start.isoformat(), "end": e.end.isoformat(),
            "invited": len(e.attendees), "current": current is not None and e == current}


def _event_question(paths: RecordingPaths) -> dict[str, Any] | None:
    """Which event, when several overlapped the recording: asked, not guessed."""
    question = calendar_events.load_question(paths)
    if not question:
        return None
    return {"reason": f"{len(question)} events overlapped the recording",
            "choices": [_event_choice(e, e.key or f"question|{i}") for i, e in enumerate(question)]}


def _bank_names() -> list[str]:
    """Names the voice bank knows; invitees resolve to these ("Freddy")."""
    return list(VoiceBank().names())


def _glossed(u: Utterance) -> list[list]:
    """Where the glossary respelled a line: [start, end, the variant heard]."""
    return [[a, b, heard] for a, b, heard in u.glossed]


def _live_meeting(output_dir: Path, paths: RecordingPaths, *, user_name: str) -> dict[str, Any]:
    """A meeting being recorded, from what the live worker has so far
    (live.json): text, provisional speakers, names by voice (the voice bank,
    or given while recording)."""
    from ..merger import merge
    from ..speakers import load_live_names, match_live_names
    from ..voices import recognize

    live = _read_json(paths.live, {})
    turns = [SpeakerTurn.from_dict(d) for d in live.get("turns", [])]
    raw = merge([Segment.from_dict(d) for d in live.get("mic", [])],
                [Segment.from_dict(d) for d in live.get("system", [])], turns)
    embeddings = live.get("embeddings", {})
    talk = talk_seconds(turns)
    bank = VoiceBank()
    invited = calendar_events.invited_names(paths, list(bank.names()), user_name=user_name)
    recognized = recognize(embeddings, talk, bank, invited=invited) if embeddings else {}
    named = match_live_names(embeddings, load_live_names(paths))
    names = {**{label: name for label, (name, _) in recognized.items()}, **named}
    labels = sorted(set(talk) | {u.speaker for u in raw if u.speaker != user_name}, key=lambda label: (-talk.get(label, 0), label))
    display = {label: names.get(label) or _label_display(label) for label in labels}
    utterances = readable(apply_speaker_names(raw, display))
    speakers = [{"label": None, "name": user_name, "display": user_name, "is_user": True, "clips": [],
                 "talk_seconds": round(sum(u.end - u.start for u in utterances if u.speaker == user_name and not u.label), 1)}]
    for label in labels:
        auto = recognized.get(label)
        speakers.append({
            "label": label, "name": names.get(label), "display": display[label], "is_user": False,
            "named_by": "you" if label in named else ("voice" if auto else None),
            "recognized": {"name": auto[0], "similarity": round(auto[1], 2)} if auto else None,
            "guesses": [], "maybe": [], "merged": [], "clips": [],
            "talk_seconds": round(talk.get(label, 0.0), 1),
        })
    event = calendar_events.load(paths)
    title, title_from = titles.resolve(paths, event=event, meeting_notes=None)
    return {
        "id": paths.folder.name,
        "title": title,
        "title_from": title_from,
        "calendar": _calendar(event, user_name, set(names.values())),
        "start": _start(paths),
        "duration": None,
        "status": "recording",
        "live": {"until": live.get("until", 0)},
        "notes": None,
        "notes_stale": False,
        "notes_stale_reason": None,
        "my_notes_revision": my_notes.revision(paths.folder),
        "speakers": speakers,
        "transcript": [
            {"speaker": u.speaker, "label": u.label or (None if u.speaker == user_name else u.speaker),
             "start": round(u.start, 2), "end": round(u.end, 2), "text": u.text, "glossed": _glossed(u)}
            for u in utterances
        ],
        "has_audio": False,
        **_meeting_projects(output_dir, paths.folder.name, user_name),
    }


def live_stream(output_dir: Path, meeting_id: str, *, user_name: str, since: float,
                now: float | None = None) -> dict[str, Any]:
    """The realtime stream's newest lines (stream.json, #42): settled
    sentences starting at ``since`` or later, both tracks by time, read the
    way the transcript is (fillers out, glossary applied), plus the drafts.
    Without a stream: ``{"stream": False}``, with ``"starting": True``
    while a stream runs but has not written yet (its model loads), or
    ``"stale": True`` once stream.json has not been rewritten for
    STREAM_STALE_SECONDS (the stream died). The window shows only the
    system draft; the mic draft is the raw mic, which without headphones
    holds the other side's words."""
    from ..stream import worker_running as stream_running

    paths = meeting_paths(output_dir, meeting_id)
    stream = _read_json(paths.stream, None)
    if not isinstance(stream, dict):
        if not paths.stream.exists() and stream_running(paths.folder):
            return {"stream": False, "starting": True}
        return {"stream": False}
    updated = stream.get("updated_at")
    if _is_number(updated) and (time.time() if now is None else now) - updated > STREAM_STALE_SECONDS:
        return {"stream": False, "stale": True}
    def entries(track: str) -> list[dict]:
        found = stream.get(track)
        return [d for d in found if _sane_segment(d)] if isinstance(found, list) else []

    raw = [Utterance(user_name if track == "mic" else "Others", d["start"], d["end"], d["text"],
                     None if track == "mic" else "stream")
           for track in ("mic", "system") for d in entries(track) if d["start"] >= since]
    lines = [{"speaker": u.speaker, "label": u.label, "start": round(u.start, 2), "end": round(u.end, 2),
              "text": u.text, "glossed": _glossed(u)}
             for u in readable(sorted(raw, key=lambda u: (u.start, u.end)))]
    draft = stream.get("draft")
    draft = draft if isinstance(draft, dict) else {}
    until, speaking, questions = stream.get("until"), stream.get("speaking"), stream.get("questions")
    return {
        "stream": True,
        "until": until if _is_number(until) else 0,
        "lines": lines,
        "draft": {track: _clean_draft(draft.get(track)) for track in ("system", "mic")},
        "speaking": speaking if isinstance(speaking, dict) else {},
        "questions": questions if isinstance(questions, list) else [],
    }


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _sane_segment(d: Any) -> bool:
    return (isinstance(d, dict) and _is_number(d.get("start")) and _is_number(d.get("end"))
            and isinstance(d.get("text"), str))


def _clean_draft(text: Any) -> str:
    if not isinstance(text, str):
        return ""
    [u, *_] = readable([Utterance("", 0.0, 0.0, text)]) or [None]
    return u.text if u else ""


def _events_during(output_dir: Path, paths: RecordingPaths, calendar) -> list:
    """Calendar events while the recording ran: from the calendar, or else
    the events stored with the recordings around it."""
    start, duration = cutting.span(paths)
    if calendar is not None:
        try:
            return calendar(start, start + timedelta(seconds=duration))
        except Exception:
            pass
    found = [calendar_events.load(RecordingPaths(output_dir / mid)) for mid in cutting.neighbours(paths).values() if mid]
    return [e for e in found if e is not None]


def _cut_suggestion(output_dir: Path, paths: RecordingPaths, calendar) -> dict[str, Any] | None:
    if _status(paths) != "ready":
        return None
    try:
        return cutting.suggest_cut(paths, _events_during(output_dir, paths, calendar))
    except (KeyError, TypeError, ValueError, OSError):
        return None


def dismiss_cut(output_dir: Path, meeting_id: str, dismiss: bool = True) -> None:
    """No, the suggested cut is wrong; don't suggest it again. ``dismiss``
    False: its undo, suggested again."""
    paths = meeting_paths(output_dir, meeting_id)
    if not dismiss:
        paths.cut_dismissed.unlink(missing_ok=True)
        return
    paths.cut_dismissed.write_text(json.dumps({"dismissed": datetime.now().astimezone().isoformat(timespec="seconds")}))


def _candidate_events(paths: RecordingPaths, calendar) -> list[calendar_events.Event]:
    """Calendar events around the recording, to say which one it was:
    several when meetings overlapped, the stored one even without a calendar."""
    start, duration = cutting.span(paths)
    end = start + timedelta(seconds=duration)
    events = []
    if calendar is not None:
        try:
            events = calendar(start - calendar_events.SEARCH_MARGIN, end + calendar_events.SEARCH_MARGIN)
        except Exception:
            LOGGER.exception("calendar lookup failed")
    events = [e for e in events if not e.all_day and e.end > start and e.start < end]
    # The stored event, and the ones asked about, even without a calendar at hand.
    for stored in [calendar_events.load(paths), *(calendar_events.load_question(paths) or [])]:
        if stored is not None and all(e.key != stored.key or not stored.key for e in events) and stored not in events:
            events.append(stored)
    return sorted(events, key=lambda e: (e.start, e.title))


def meeting_events(output_dir: Path, meeting_id: str, calendar) -> list[dict[str, Any]]:
    paths = meeting_paths(output_dir, meeting_id)
    current = calendar_events.load(paths)
    evidence = attribution.Evidence(output_dir=output_dir)

    def rule(e: calendar_events.Event) -> dict[str, str] | None:
        r = evidence.rule(e)
        return {"series": r["series"], "text": r["rule"]} if r else None

    return [{**_event_choice(e, e.key or f"stored|{i}", current), "rejected": evidence.event_rejections(e),
             "rule": rule(e)}
            for i, e in enumerate(_candidate_events(paths, calendar))]


def forget_rule(output_dir: Path, series: str) -> str:
    """Link recordings to this event series by time again; returns the undo token."""
    with _undoable(output_dir, "forget rule", stores=_store_paths("attributions")) as token:
        evidence = attribution.Evidence()
        evidence.forget_rule(series)
        evidence.save()
    return token


def _chosen_event(output_dir: Path, paths: RecordingPaths, calendar, key: str) -> calendar_events.Event:
    """The event ``key`` names: "current" (the stored one, confirmed), one of
    the question's, or one of the calendar's around the recording."""
    if key == "current":
        current = calendar_events.load(paths)
        if current is None:
            raise NotFound(key)
        return current
    for i, e in enumerate(calendar_events.load_question(paths) or []):
        if key == (e.key or f"question|{i}"):
            return e
    found = [e for entry, e in zip(meeting_events(output_dir, paths.folder.name, calendar),
                                   _candidate_events(paths, calendar)) if entry["key"] == key]
    if not found:
        raise NotFound(key)
    return found[0]


def set_meeting_event(output_dir: Path, meeting_id: str, calendar, *, key: str | None, user_name: str = "") -> str:
    """Which calendar event this recording was ("current": yes, the one it
    has); None: none of them. The user's choice is final, and the event it
    replaces is negative evidence (attribution.Evidence). Then what
    processing did with the event, or would have: recognition among its
    invitees, inference, projects by rules (prep comes with the event).
    Returns the undo token: the meeting's files (no audio), the projects,
    what was prepared for the event and that evidence come back as they
    were; the names elsewhere follow from those again (undo_change)."""
    paths = meeting_paths(output_dir, meeting_id)
    event = None if key is None else _chosen_event(output_dir, paths, calendar, key)
    previous = calendar_events.load(paths)
    # What was prepared for the event (its waiting notes, #44) comes back on undo too.
    prepared = [my_notes.prep_folder(event.key)] if event is not None and event.key else []
    with _PROJECTS_LOCK, _undoable(output_dir, "event", meetings=[meeting_id],
                                   stores=[*_store_paths("projects", "prepared", "attributions"), *prepared]) as token:
        evidence = attribution.Evidence()
        if previous is not None and previous != event:
            evidence.reject_event(previous, meeting_id)
        if event is None:
            calendar_events.dismiss(paths)
        else:
            calendar_events.assign(paths, event, attribution.Link("event", event.title, "you"))
            evidence.confirm_event(event, meeting_id)
        evidence.save()
        if paths.system_turns.exists() and paths.transcript_json.exists() and paths.meta.exists():
            _after_cut(output_dir, [paths], [], user_name=user_name)
    return token


def get_meeting(output_dir: Path, meeting_id: str, *, user_name: str, calendar=None) -> dict[str, Any]:
    paths = meeting_paths(output_dir, meeting_id)
    if paths.live.exists() and _status(paths) == "recording":
        meeting = _live_meeting(output_dir, paths, user_name=user_name)
    else:
        meeting = _meeting(output_dir, paths, meeting_id, user_name=user_name, calendar=calendar)
    return _with_orgs(meeting, output_dir, user_name)


def _with_orgs(meeting: dict[str, Any], output_dir: Path, user_name: str) -> dict[str, Any]:
    """Each speaker's and invitee's organization: "Stefan D (Extern)"."""
    index, orgs = organizations.people_index(output_dir), organizations.Organizations()
    for s in meeting["speakers"]:
        s["org"] = (organizations.own_org(index, orgs, user_name) if s["is_user"]
                    else organizations.org_of(s["name"], index, orgs) if s["name"] else None)
        link = organizations.org_link(s["name"], index, orgs) if s["name"] and not s["is_user"] else None
        s["org_link"] = link.to_dict() if link and link.target == s["org"] else None
    for a in (meeting.get("calendar") or {}).get("attendees", []):
        a["org"] = organizations.org_of(a["name"], index, orgs)
        link = organizations.org_link(a["name"], index, orgs)
        a["org_link"] = link.to_dict() if link and link.target == a["org"] else None
    return meeting


def _recorded(paths: RecordingPaths, meta: dict) -> dict[str, Any]:
    """How the recording started and stopped, where it paused (#47), and
    when its audio went wrong (#50)."""
    try:
        start = datetime.fromisoformat(meta["start_time"])
        recorded = lifecycle.recorded_text(meta, continued=paths.parts.exists())
    except (KeyError, TypeError, ValueError):
        return {"recorded": None, "gaps": [], "audio_problems": []}
    return {"recorded": recorded,
            "gaps": [{"start": g["start"], "end": g["end"], "text": lifecycle.gap_text(g, start)}
                     for g in meta.get("gaps") or []],
            "audio_problems": [{"start": p["start"], "end": p.get("end"), "text": lifecycle.problem_text(p, start)}
                               for p in meta.get("audio_problems") or []]}


def _meeting(output_dir: Path, paths: RecordingPaths, meeting_id: str, *, user_name: str,
             calendar=None) -> dict[str, Any]:
    meta = _read_json(paths.meta, {})
    names = _names(paths)
    display = _display_names(paths)
    raw = without_ignored(paths, _utterances(paths))
    utterances = readable(apply_speaker_names(raw, display))
    merges = load_merges(paths)

    def lane(u: Utterance) -> str | None:
        """The speaker lane an utterance belongs to; None for the user."""
        label = u.label or (None if u.speaker == user_name else u.speaker)
        return merges.get(label, label) if label else None

    meeting_notes = notes.load(paths)
    event = calendar_events.load(paths)
    stale = notes.stale_reason(paths, raw) if raw and meeting_notes is not None else None
    mic = shared_mic.mic_display(paths)  # the room's, while several people sat at the microphone (#56)
    title, title_from = titles.resolve(paths, event=event, meeting_notes=meeting_notes)
    return {
        "id": meeting_id,
        "title": title,
        "title_from": title_from,
        "calendar": _calendar(event, user_name, set(names.values()), calendar_events.load_link(paths)),
        "event_question": _event_question(paths),
        "start": _start(paths),
        "duration": meta.get("duration_seconds"),
        "status": _status(paths),
        # The notes model wrote from the transcript as heard: spell names right.
        "notes": glossary.current().apply_to(notes.with_names(meeting_notes, display)) if meeting_notes else None,
        "notes_stale": stale is not None,
        "notes_stale_reason": stale,
        # Written with the user's own notes in the prompt (#44): an export asks before they go (#58).
        "notes_from_my_notes": bool((meeting_notes or {}).get("my_notes_hash")),
        "my_notes_revision": my_notes.revision(paths.folder),
        "speakers": _speakers(paths, user_name, names, display, raw, meeting_notes),
        "transcript": [
            {"speaker": mic if mic and lane(u) is None else u.speaker, "label": lane(u),
             "start": round(u.start, 2), "end": round(u.end, 2), "text": u.text, "glossed": _glossed(u),
             "edited": u.heard is not None, "heard": u.heard,
             "unsure": [] if u.heard is not None else list(u.unsure)}
            for u in utterances
        ],
        "has_audio": paths.system_wav.exists(),
        "reviewed": _read_json(paths.review, {}).get("reviewed"),
        "local_only": paths.local_only.exists(),
        "imported": _imported(paths),
        "transcribed_by": _transcribed_by(paths),
        "failure": last_failure(paths),  # a failed run, offered for a report (#59)
        "neighbours": _neighbours(output_dir, paths),
        "cut_suggestion": _cut_suggestion(output_dir, paths, calendar),
        "shared": _shared(paths, event),
        "shared_suggestion": shared_mic.suggestion(paths, event, user_name=user_name),
        "removed": [{"label": label, "display": _label_display(label)} for label in sorted(load_ignored(paths))],
        **_recorded(paths, meta),
        **_meeting_projects(output_dir, meeting_id, user_name),
    }


def _shared(paths: RecordingPaths, event) -> dict[str, Any]:
    """Whether voices here can't be told apart (#56): the whole meeting,
    lanes that are rooms, the user's microphone; ``line`` is the quiet
    sentence the page shows while a voice of the meeting is marked."""
    rooms = shared_mic.room_names(paths)
    meeting = shared_mic.meeting_marked(paths)
    return {"meeting": meeting, "rooms": rooms, "mic": shared_mic.mic_room(paths),
            "from_series": shared_mic.from_series(paths),
            "line": shared_mic.LINE if shared_mic.marked(paths) else None,
            "series": {"can": shared_mic.can_remember(event), "remembered": shared_mic.remembered(event)}}


def last_failure(paths: RecordingPaths) -> dict[str, Any] | None:
    """The meeting's last run that failed and was not done right since, from
    its session.log (#59): transcribing ({"step": "process"}) or writing the
    notes ({"step": "notes"}), with what it said; None when all went well."""
    failed: dict[str, dict] = {}
    running = None  # the run the lines belong to: process or notes (others, e.g. live, are not shown)
    try:
        lines = paths.session_log.read_text(errors="replace").splitlines()
    except OSError:
        return None
    for line in lines:
        if '"event"' not in line and '"ERROR"' not in line:
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if not isinstance(row, dict):
            continue
        name = row.get("event")
        if name in ("process_start", "notes_start"):
            running = name[:-6]
            failed.pop(running, None)
        elif name in ("live_start", "stream_start", "record_start", "notion_upload_start"):
            running = None
        elif name == "notes_failed":
            failed["notes"] = {"step": "notes", "error": str(row.get("error") or "")[:300], "at": row.get("ts")}
        elif name == "process_done" and row.get("rc") not in (0, None):
            failed["process"] = {"step": "process", "error": f"exit code {row.get('rc')}", "at": row.get("ts")}
        elif row.get("level") == "ERROR" and row.get("message") == "command failed" and running:
            tb = [t for t in str(row.get("traceback") or "").splitlines() if t.strip()]
            failed[running] = {"step": running, "error": (tb[-1].strip() if tb else "it stopped")[:300],
                               "at": row.get("ts")}
    return failed.get("process") or failed.get("notes")


def _transcribed_by(paths: RecordingPaths) -> dict[str, Any] | None:
    """Who transcribed the system track (#54), with the services' names; None: not said."""
    from .. import providers

    system = _read_json(paths.transcription, {}).get("system")
    if not isinstance(system, dict):
        return None
    out = dict(system)
    for key, label in (("engine", "label"), ("fallback_from", "fallback_label")):
        if out.get(key) in providers.PROVIDERS:
            out[label] = providers.PROVIDERS[out[key]].label
    return out


def _meeting_projects(output_dir: Path, meeting_id: str, user_name: str) -> dict[str, Any]:
    store = projects.ProjectStore()
    every = projects.all_facts(output_dir, user_name=user_name)
    return {
        "projects": _projects_of(store, meeting_id),
        "project_suggestions": projects.suggestions(meeting_id, store, every),
        "all_projects": sorted(({"id": pid, "name": p["name"]} for pid, p in store.projects().items()),
                               key=lambda p: p["name"].casefold()),
    }


def _automatic_name(paths: RecordingPaths, label: str) -> str | None:
    """The name recognition or inference gives ``label`` now, if any."""
    recognized = load_recognized_names(paths)
    if label in recognized:
        return recognized[label][0]
    return load_inferred_names(paths).get(label)


def name_speaker(output_dir: Path, meeting_id: str, label: str, name: str) -> str | None:
    """Give ``label`` a name; an empty name leaves it unnamed. Emptying a
    name recognized by voice or inferred says "this voice is not Tom": the
    name is rejected for this voice (and voices like it elsewhere), others
    may still fit; returns the undo token of that change."""
    paths = meeting_paths(output_dir, meeting_id)
    if paths.live.exists() and _status(paths) == "recording":
        try:
            name_live_speaker(paths, label, name)  # follows the voice; labels change while recording
        except LookupError:
            raise NotFound(label) from None
        return
    turns = {d["speaker"] for d in _read_json(paths.system_turns, [])}
    if label not in turns:
        raise NotFound(label)
    label = load_merges(paths).get(label, label)  # naming a merged label names the person
    names = load_speaker_names(paths)
    name = name.strip()
    automatic = _automatic_name(paths, label) if label not in names else None

    def known() -> None:  # a name for a voice nobody knew: if it loses the name, it is asked about again
        mark_unknown(paths, label, False)

    if not name and automatic:
        def reject() -> None:
            set_rejected_name(paths, label, automatic)
            save_speaker_names(paths, names)
            people.refresh_recognition(output_dir)

        return _undoable_names(output_dir, "not", reject)
    if name and any(n.casefold() == name.casefold() for n in load_rejected_names(paths).get(label, [])):
        def after_all() -> None:  # it was them after all; its undo brings the rejection back
            set_rejected_name(paths, label, name, rejected=False)
            known()
            save_speaker_names(paths, {**names, label: name})
            people.refresh_recognition(output_dir)

        return _undoable_names(output_dir, "after all", after_all)
    if name and automatic and name.casefold() == automatic.casefold():
        def confirm() -> None:  # the guess was right; its undo makes it a guess again
            known()
            save_speaker_names(paths, {**names, label: name})
            people.refresh_recognition(output_dir)

        return _undoable_names(output_dir, "confirm", confirm)
    if name:
        names[label] = name
        known()
    elif label in load_recognized_names(paths) or label in inference.load(paths):
        names[label] = label  # not who the voice or the calendar suggested
    else:
        names.pop(label, None)
    save_speaker_names(paths, names)
    people.refresh_recognition(output_dir)  # the voice may be in other meetings too
    return None


def _neighbours(output_dir: Path, paths: RecordingPaths) -> dict[str, Any]:
    """The recordings right before and after, to join with."""
    try:
        found = cutting.neighbours(paths)
    except (KeyError, TypeError, ValueError):
        return {"previous": None, "next": None}
    titles = {m["id"]: m for m in list_meetings(output_dir)} if any(found.values()) else {}
    return {side: {"id": mid, "title": titles.get(mid, {}).get("title"), "start": titles.get(mid, {}).get("start")}
            if mid else None for side, mid in found.items()}


@contextmanager
def _undoable(output_dir: Path, label: str, **what):
    """A snapshot for the change in the ``with`` body: sealed when it is
    done; when it fails, rolled back from the snapshot."""
    token = undo.take(output_dir, label, **what)
    try:
        yield token
    except BaseException:
        try:  # half-changed: the snapshot is the way back (a restore removes it)
            undo.restore(output_dir, token, check=False)
        except Exception:
            LOGGER.exception("rolling back %s failed; the snapshot %s is kept", label, token)
        raise
    undo.sealed(output_dir, token)
    undo.prune(output_dir)


def _store_paths(*names: str) -> list[Path]:
    """Where the stores an undo may need to put back live: "projects",
    "glossary", "organizations", "prepared", "attributions", "voices",
    "shared_series"."""
    where = {"projects": projects._default_path, "glossary": glossary._default_path,
             "organizations": organizations._path, "prepared": prep._path,
             "attributions": attribution._default_path,
             "voices": lambda: xdg_config_home() / "palaver" / "voices",
             "shared_series": shared_mic._series_path}
    return [where[n]() for n in names]


def undo_change(output_dir: Path, token: str, *, user_name: str) -> list[str]:
    """Roll back the change the token stands for; returns the meetings it
    touched. Raises ``undo.Gone`` / ``undo.Changed``."""
    if undo.label(output_dir, token).startswith("my-notes"):  # the user's own notes: nothing depends on them
        _undo_my_notes(output_dir, token)
        return []
    if undo.label(output_dir, token) == "shared":
        with _PROJECTS_LOCK:
            return _undo_shared(output_dir, token, user_name=user_name)
    if undo.label(output_dir, token) in ("title", "unknown"):  # nothing depends on them but what reads them
        return _undo_own_file(output_dir, token)
    imported = undo.created_ids(output_dir, token) if undo.label(output_dir, token) == "import" else []
    with _PROJECTS_LOCK, _GLOSSARY_LOCK:
        glossary_back = glossary._default_path() in undo.stores(output_dir, token)
        ids = undo.restore(output_dir, token)
        for meeting_id in imported:  # what the bank learned from it goes with it (#58)
            VoiceBank().remove_meeting(meeting_id)
        there = [i for i in ids if (output_dir / i).is_dir()]
        ready = [i for i in there if (output_dir / i / "system_turns.json").exists()
                 and (output_dir / i / "transcript.json").exists()]  # a recording still being processed has no names to redo
        _after_cut(output_dir, [RecordingPaths(output_dir / i) for i in ready],
                   [i for i in ids if i not in there], user_name=user_name)
        if glossary_back:
            _rerender(output_dir, [m["id"] for m in list_meetings(output_dir)])
        undo.prune(output_dir)
    return ids


def _after_cut(output_dir: Path, changed: list[RecordingPaths], gone: list[str], *, user_name: str,
               calendar=None) -> None:
    """Bring everything that depends on the transcripts up to date."""
    store = projects.ProjectStore()
    for mid in gone:
        store.forget_meeting(mid)
    store.save()
    for paths in changed:
        if calendar is not None and not paths.calendar.exists():
            start, duration = cutting.span(paths)
            try:
                calendar_events.attach(paths, calendar, start, start + timedelta(seconds=duration))
            except Exception:  # no calendar is no reason to fail the cut
                pass
        save_speaker_names(paths, load_speaker_names(paths))
    people.refresh_recognition(output_dir, user_name=user_name)
    projects.assign_by_rules(output_dir, store, user_name=user_name,
                             meetings=[p.folder.name for p in changed if not store.of_meeting(p.folder.name)])
    store.save()


def set_title(output_dir: Path, meeting_id: str, title: Any) -> str:
    """The user's own title for the meeting, over its event's and its
    notes'; "" gives the title back to them. Also while the meeting is
    recorded: the title is a file nothing else writes. Returns the undo
    token."""
    paths = meeting_paths(output_dir, meeting_id)
    title = titles.clean(title)
    with _undoable(output_dir, "title", stores=[paths.title]) as token:
        titles.save(paths, title)
        undo.note(output_dir, token, {"meeting": meeting_id})
    return token


def _undo_own_file(output_dir: Path, token: str) -> list[str]:
    """The title (or the voices nobody knows) as it was, unless the meeting
    is gone (to the trash, into another): then there is no folder to put it
    back in."""
    meeting_id = str(undo.extra(output_dir, token).get("meeting") or "")
    if not meeting_id or not (output_dir / meeting_id).is_dir():
        raise undo.Changed(meeting_id)
    undo.restore(output_dir, token)
    undo.prune(output_dir)
    return [meeting_id]


def edit_line(output_dir: Path, meeting_id: str, *, start: float, text: str | None) -> None:
    """The user's wording of one transcript line, found by when it starts.
    What the transcriber heard is kept; ``text=None`` puts it back."""
    paths = meeting_paths(output_dir, meeting_id)
    if _status(paths) != "ready":
        raise ValueError("only a finished transcript can be edited")
    if text is not None and not text.strip():
        raise ValueError("a line needs words")
    lines = _read_json(paths.transcript_json, [])
    line = next((d for d in lines if abs(float(d["start"]) - start) < 0.01), None)
    if line is None:
        raise NotFound(f"{meeting_id} at {start}")
    heard = line.get("heard", line["text"])
    if text is None or text.strip() == heard:
        line["text"] = heard
        line.pop("heard", None)
    else:
        line["heard"], line["text"] = heard, text.strip()
    tmp = paths.transcript_json.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(lines, indent=2, ensure_ascii=False))
    tmp.replace(paths.transcript_json)
    _rerender(output_dir, [meeting_id])


def trash_meeting(output_dir: Path, meeting_id: str, *, user_name: str) -> str:
    """Move a whole recording to ``.trash`` in the recordings folder; it
    can be moved back from there. Returns the undo token."""
    paths = meeting_paths(output_dir, meeting_id)
    status = _status(paths)
    if status == "recording":
        raise Refused("This meeting is being recorded. It can go to the trash once the recording has stopped.")
    if status == "processing":  # the pipeline still writes into its folder
        raise Refused(_STILL_PROCESSING.format("go to the trash"))
    with _PROJECTS_LOCK, _undoable(output_dir, "trash", stores=_store_paths("projects")) as token:
        undo.moved(output_dir, token, paths.folder, cutting.trash(paths))
        _after_cut(output_dir, [], [meeting_id], user_name=user_name)
    return token


# --- export and import (#58) ------------------------------------------------------------------


def _imported_brief(paths: RecordingPaths) -> dict[str, Any] | None:
    """For the list and MCP: who a meeting was imported from."""
    record = exchange.load_record(paths)
    return {"from": str(record.get("from") or "")} if record else None


def _imported(paths: RecordingPaths) -> dict[str, Any] | None:
    """What the meeting page says about an import: from whom, when, the
    exporter's projects (a hint) and the voices waiting for a yes."""
    record = exchange.load_record(paths)
    if not record:
        return None
    hinted = {label: h["name"] for label, h in exchange.hints(paths).items()}
    return {"from": str(record.get("from") or ""), "at": record.get("imported_at"), "title": titles.imported(paths),
            "projects": [str(p) for p in record.get("projects") or []],
            "beside": (record.get("beside") or {}).get("meeting"),
            "voices": [{"label": label, "name": hinted.get(label, label)} for label in record.get("voices_pending") or []]}


def export_meeting(output_dir: Path, meeting_id: str, downloads: Path, *, user_name: str, notes: bool = True,
                   voices: bool = False, audio: bool = False, confirm_local: bool = False) -> dict[str, Any]:
    """Save the meeting as a ``.palaver`` file in ``downloads``: the window
    can't download in its web view, the server is on this Mac anyway. A
    meeting kept on this Mac answers with a question first."""
    paths = meeting_paths(output_dir, meeting_id)
    try:  # what an export cut short left there; not at a start (server.sweep_leftovers)
        exchange.sweep(output_dir, downloads)
    except OSError:
        LOGGER.warning("could not sweep export leftovers", exc_info=True)
    dest = exchange.free_name(downloads, exchange.file_name(paths))
    try:
        exchange.export_meeting(paths, dest, user_name=user_name, notes=notes, voices=voices, audio=audio,
                                confirm_local=confirm_local, projects=exchange.confirmed_projects(meeting_id))
    except exchange.KeptOnThisMac:
        return {"question": "local_only"}
    except exchange.NotReady as exc:
        raise Refused(str(exc)) from None
    return {"saved": str(dest), "name": dest.name, "folder": dest.parent.name, "bytes": dest.stat().st_size}


def import_meeting(output_dir: Path, file: Path, *, user_name: str, separate: bool = False,
                   calendar=None) -> dict[str, Any]:
    """Import a ``.palaver`` file as a meeting; undone by trashing it again.
    The same meeting here already answers with a question (keep mine, or
    import as a separate meeting) and writes nothing."""
    try:
        package = exchange.read_package(file)
        match = exchange.find_match(output_dir, package)
    except exchange.Rejected as exc:
        raise Refused(f"Not imported: {exc}") from None
    if match is not None and not separate:
        there = meeting_paths(output_dir, match.id)
        return {"question": "collision", "from": package.sender, "how": match.how, "own": match.own,
                "meeting": {"id": match.id, "title": titles.resolve(there)[0] or titles.fallback(_start(there)),
                            "start": _start(there)}}
    output_dir.mkdir(parents=True, exist_ok=True)

    def after(meeting_id: str) -> None:
        undo.created(output_dir, token, [meeting_id])
        exchange.settle(output_dir, meeting_id, user_name=user_name)

    try:  # the slow part, before the projects are held
        staged = exchange.stage(output_dir, package, user_name=user_name, separate=separate, calendar=calendar)
    except exchange.Rejected as exc:
        raise Refused(f"Not imported: {exc}") from None
    try:
        with _PROJECTS_LOCK, _undoable(output_dir, "import", stores=_store_paths("projects")) as token:
            result = exchange.place(output_dir, staged, after=after)
    finally:
        staged.discard()
    return {"imported": result.id, "from": result.sender, "voices": result.voices, "warnings": result.warnings,
            "beside": result.matched.id if result.matched else None, "undo": token}


def decide_imported_voices(output_dir: Path, meeting_id: str, add: bool, *, user_name: str = "") -> str:
    """Yes or no to the voices that came with an import; undoable (a yes
    recognizes voices in every meeting again)."""
    paths = meeting_paths(output_dir, meeting_id)
    with _PROJECTS_LOCK, _undoable(output_dir, "voices", meetings=[meeting_id], speaker_files_of_all=True,
                                   stores=_store_paths("voices", "organizations")) as token:
        exchange.decide_voices(paths, add, user_name=user_name)
    return token


def split_meeting(output_dir: Path, meeting_id: str, at: float, *, join_next: bool = False,
                  discard: str | None = None, user_name: str, calendar=None) -> dict[str, Any]:
    """Cut a meeting ``at`` seconds; the rest becomes a meeting of its own,
    or (``join_next``) the start of the recording that follows. With
    ``discard`` ("after" / "before"), that part goes to the trash instead.
    The answer has an ``undo`` token."""
    paths = meeting_paths(output_dir, meeting_id)
    if _status(paths) != "ready":
        raise ValueError("only a finished, transcribed meeting can be cut")
    if discard:
        with _PROJECTS_LOCK, _undoable(output_dir, "cut", meetings=[meeting_id], audio=True,
                                       stores=_store_paths("projects")) as token:
            cutting.discard(paths, at, discard)
            _after_cut(output_dir, [paths], [], user_name=user_name)
        return {"id": meeting_id, "rest": None, "joined": False, "discarded": discard, "undo": token}
    following = cutting.neighbours(paths)["next"] if join_next else None
    if join_next and following is None:
        raise ValueError("no recording follows this one")
    with _PROJECTS_LOCK, _undoable(output_dir, "split", meetings=[meeting_id, *([following] if following else [])],
                                   audio=True, stores=_store_paths("projects")) as token:
        tail = cutting.split(paths, at)
        undo.created(output_dir, token, [tail.folder.name])  # when it is joined on, restore trashes what is left
        if following:
            joined = cutting.join(tail, RecordingPaths(output_dir / following))
            gone = [tail.folder.name] if joined.folder != tail.folder else [following]
            _after_cut(output_dir, [paths, joined], gone, user_name=user_name, calendar=calendar)
            rest, was_joined = joined.folder.name, True
        else:
            _after_cut(output_dir, [paths, tail], [], user_name=user_name, calendar=calendar)
            rest, was_joined = tail.folder.name, False
    return {"id": meeting_id, "rest": rest, "joined": was_joined, "undo": token}


def join_meetings(output_dir: Path, meeting_id: str, other_id: str, *, user_name: str) -> dict[str, str]:
    """Join two recordings of one meeting; returns the one that remains
    (``id``) and the ``undo`` token."""
    a, b = meeting_paths(output_dir, meeting_id), meeting_paths(output_dir, other_id)
    if _status(a) != "ready" or _status(b) != "ready":
        raise ValueError("only finished, transcribed meetings can be joined")
    keeper = cutting.keeper(a, b).folder.name
    other = other_id if keeper == meeting_id else meeting_id
    with _PROJECTS_LOCK, _undoable(output_dir, "join", meetings=[keeper], audio=True,
                                   stores=_store_paths("projects")) as token:
        bin_ = output_dir / cutting.TRASH
        before = set(bin_.iterdir()) if bin_.is_dir() else set()
        kept = cutting.join(a, b)
        for target in set(bin_.iterdir()) - before:  # where the other recording went
            undo.moved(output_dir, token, output_dir / other, target)
        _after_cut(output_dir, [kept], [other], user_name=user_name)
    return {"id": kept.folder.name, "undo": token}


def remove_speaker(output_dir: Path, meeting_id: str, label: str, removed: bool = True) -> None:
    """Remove a voice as noise — a few words, a fragment of someone — with
    its lines, or bring it back."""
    paths = meeting_paths(output_dir, meeting_id)
    if label not in {d["speaker"] for d in _read_json(paths.system_turns, [])}:
        raise NotFound(label)
    set_ignored(paths, load_merges(paths).get(label, label), removed)
    save_speaker_names(paths, load_speaker_names(paths))  # transcript.md, voice samples
    people.refresh_recognition(output_dir)


def set_unknown(output_dir: Path, meeting_id: str, label: str, on: bool) -> str:
    """"Don't Know Who This Is" (``on``) or "Ask Me Again" for one voice:
    it stays an unnamed lane, to be named any time, but is no to-do and no
    Needs-you item, so a voice the user can't name isn't asked about
    forever. The undo token keeps only this meeting's list: nothing else
    follows from it."""
    paths = meeting_paths(output_dir, meeting_id)
    if _status(paths) != "ready":
        raise Refused("Voices can be marked once the meeting is transcribed.")
    if label not in {d["speaker"] for d in _read_json(paths.system_turns, [])}:
        raise NotFound(label)
    label = load_merges(paths).get(label, label)  # a merged voice is the lane it joined
    with _undoable(output_dir, "unknown", stores=[paths.speakers_unknown]) as token:
        mark_unknown(paths, label, on)
        undo.note(output_dir, token, {"meeting": meeting_id})
    return token


def merge_speaker(output_dir: Path, meeting_id: str, label: str, into: str | None) -> str | None:
    """Fold speaker ``label`` into ``into`` — the diarizer split one person
    in two — or, with ``into=None``, split it off again. A merge returns the
    undo token: splitting off again would not give back the name the merge
    moved, nor the speakers merged into ``label`` before. The voices go in
    the snapshot too: the merge may teach the bank the target's voice."""
    paths = meeting_paths(output_dir, meeting_id)
    labels = {d["speaker"] for d in _read_json(paths.system_turns, [])}
    if label not in labels or (into is not None and into not in labels):
        raise NotFound(label if label not in labels else into)
    if into is None:
        merge_speakers(paths, label, None)
        people.refresh_recognition(output_dir)
        return None
    if load_merges(paths).get(into, into) == label:
        raise ValueError("a speaker cannot be merged into itself")
    with _undoable(output_dir, "merge speakers", meetings=[meeting_id], stores=_store_paths("voices")) as token:
        merge_speakers(paths, label, into)
        people.refresh_recognition(output_dir)
    return token


def set_shared(output_dir: Path, meeting_id: str, *, on: bool, label: str | None = None, name: str | None = None,
               series: bool | None = None) -> str:
    """Say voices can't be told apart (#56): the whole meeting's
    (``label=None``), or one lane's, a room of several people (``name``: the
    room's, if known); ``on=False`` takes it back. ``series``: remember the
    whole-meeting mark for the event's series, or forget it.

    The undo token keeps only what the user said: this meeting's marks (and
    the remembered series). Everything else follows from them (the
    transcript, the voice bank, names recognized and inferred in other
    meetings) and is derived again on undo, so a call processed meanwhile is
    no reason to refuse it. Naming a room or remembering a series changes
    no voice: nothing is recognized again for those."""
    if series is not None and (label is not None or not on):
        raise ValueError("a series is remembered with the whole meeting marked")
    paths = meeting_paths(output_dir, meeting_id)
    if _status(paths) != "ready":
        raise Refused("Voices can be marked once the meeting is transcribed.")
    if label is not None and label != shared_mic.MIC:  # MIC: the user's microphone
        if label not in {d["speaker"] for d in _read_json(paths.system_turns, [])}:
            raise NotFound(label)
        label = load_merges(paths).get(label, label)  # a merged voice is the lane it joined
    event = calendar_events.load(paths)
    if series is not None and not shared_mic.can_remember(event):
        raise Refused("Only a meeting of a recurring calendar event can be remembered for its series.")

    def voices() -> tuple:
        return shared_mic.shared_labels(paths), shared_mic.mic_room(paths) is None

    stores = [paths.speakers_shared, *(_store_paths("shared_series") if series is not None else [])]
    with _PROJECTS_LOCK, _undoable(output_dir, "shared", stores=stores) as token:
        before = voices()
        if label is None:
            shared_mic.set_meeting(paths, on)
        else:
            shared_mic.set_lane(paths, label, on, name)
        if series is not None:
            shared_mic.remember(event, series)
        derive = voices() != before
        undo.note(output_dir, token, {"meeting": meeting_id, "derive": derive})
        _derive_shared(output_dir, paths, derive)
    return token


def _derive_shared(output_dir: Path, paths: RecordingPaths, derive: bool, user_name: str = "") -> None:
    """What follows from a meeting's marks: its transcript; when which
    voices are several people changed, the voice bank (a room's voice leaves
    it) and the names recognized and inferred in every meeting."""
    if paths.transcript_json.exists() and paths.system_turns.exists() and paths.meta.exists():
        save_speaker_names(paths, load_speaker_names(paths), learn=derive)
    if derive:
        people.refresh_recognition(output_dir, user_name=user_name)


def _undo_shared(output_dir: Path, token: str, *, user_name: str) -> list[str]:
    """Undo of a mark: the meeting's marks as they were, and what follows
    from them derived again."""
    extra = undo.extra(output_dir, token)
    meeting_id = str(extra.get("meeting") or "")
    if not meeting_id or not (output_dir / meeting_id).is_dir():  # gone to the trash, or cut away since
        raise undo.Changed(meeting_id)
    undo.restore(output_dir, token)
    _derive_shared(output_dir, RecordingPaths(output_dir / meeting_id), bool(extra.get("derive", True)), user_name)
    undo.prune(output_dir)
    return [meeting_id]


def remember_series(output_dir: Path, meeting_id: str, remember: bool) -> str:
    """Whether the next meetings of this meeting's event series start out
    marked; this meeting's own mark stays as it is. Returns the undo token."""
    paths = meeting_paths(output_dir, meeting_id)
    event = calendar_events.load(paths)
    if not shared_mic.can_remember(event):
        raise Refused("Only a meeting of a recurring calendar event can be remembered for its series.")
    with _undoable(output_dir, "shared", stores=_store_paths("shared_series")) as token:
        shared_mic.remember(event, remember)
        undo.note(output_dir, token, {"meeting": meeting_id, "derive": False})
    return token


def dismiss_shared_suggestion(output_dir: Path, meeting_id: str, dismiss: bool = True) -> None:
    """"No, each voice is one person": the mark is not suggested again;
    False: its undo, suggested again."""
    shared_mic.dismiss_suggestion(meeting_paths(output_dir, meeting_id), dismiss)


def _clip(paths: RecordingPaths, label: str) -> dict[str, float] | None:
    turns = [t for t in _turns(paths) if t.speaker == label]
    if not turns:
        return None
    t = max(turns, key=lambda t: t.end - t.start)
    return {"start": t.start, "end": min(t.end, t.start + CLIP_SECONDS)}


def directory(output_dir: Path, user_name: str = "") -> dict[str, Any]:
    """People across meetings, and recurring voices without a name, with each
    meeting's title and a clip of the voice there. The user, by any of
    their names, is marked "you"."""
    meetings = {m["id"]: m for m in list_meetings(output_dir)}

    def where(meeting_id: str, label: str) -> dict[str, Any]:
        m = meetings.get(meeting_id, {})
        return {"id": meeting_id, "title": m.get("title"), "start": m.get("start"),
                "projects": [{"id": p["id"], "name": p["name"]} for p in m.get("projects", [])],
                "clip": _clip(RecordingPaths(output_dir / meeting_id), label)}

    d = people.directory(output_dir, me=settings.me(user_name))
    index, orgs = organizations.people_index(output_dir), organizations.Organizations()
    for person in d["people"]:
        person["meetings"] = sorted(({**where(x["id"], x["label"]), **x} for x in person["meetings"]),
                                    key=lambda x: x["id"], reverse=True)
        person["org"] = organizations.org_of(person["name"], index, orgs)
        person["org_given"] = orgs.person(person["name"]) is not None
    d["organizations"] = organizations.summary(index, orgs)
    for group in d["unknown"]:
        group["voices"] = sorted(({**where(v["meeting"], v["label"]), **v} for v in group["voices"]),
                                 key=lambda x: x["id"], reverse=True)
    return d


def rename_organization(key: str, name: str) -> None:
    orgs = organizations.Organizations()
    orgs.rename(key, name)
    orgs.save()


def set_person_org(person: str, org: str | None) -> None:
    """Give ``person`` an organization by hand; empty takes it back to the email's."""
    if not person.strip():
        raise ValueError("a person is needed")
    orgs = organizations.Organizations()
    orgs.set_person(person, org)
    orgs.save()


def rename_person(output_dir: Path, old: str, new: str) -> str:
    """Returns the undo token."""
    new = new.strip()
    if not new:
        raise ValueError("a name is needed")
    return _undoable_names(output_dir, "rename", lambda: people.rename_person(output_dir, old, new))


def _undoable_names(output_dir: Path, label: str, change) -> str:
    """Run ``change`` (it touches the speaker files of every meeting, the
    voices and the organizations) so that it can be undone."""
    with _PROJECTS_LOCK, _undoable(output_dir, label, speaker_files_of_all=True,
                                   stores=_store_paths("voices", "organizations")) as token:
        change()
    return token


def name_voices(output_dir: Path, members: list[tuple[str, str]], name: str) -> str:
    name = name.strip()
    if not name or not members:
        raise ValueError("a name and at least one voice are needed")
    for meeting_id, label in members:
        paths = meeting_paths(output_dir, meeting_id)
        if label not in {d["speaker"] for d in _read_json(paths.system_turns, [])}:
            raise NotFound(f"{meeting_id} {label}")
    return _undoable_names(output_dir, "name", lambda: people.name_voices(output_dir, members, name))


# --- projects -------------------------------------------------------------------

# One change at a time: the server answers requests on several threads.
_PROJECTS_LOCK = threading.Lock()


def list_projects(output_dir: Path, *, user_name: str) -> dict[str, Any]:
    """Every project with its meetings and people, most recent first, and
    the meetings in no project yet, with suggestions."""
    store = projects.ProjectStore()
    meetings = {m["id"]: m for m in list_meetings(output_dir)}
    every = projects.all_facts(output_dir, user_name=user_name)
    similarity = projects.Similarity(every)
    out = []
    for pid, p in store.projects().items():
        members = []
        for mid, how in store.meetings_of(pid).items():
            m = meetings.get(mid)
            if m is not None:
                members.append({"id": mid, "title": m["title"], "start": m["start"], "duration": m["duration"],
                                "summary": m["summary"], **how})
        members.sort(key=lambda m: m["id"], reverse=True)
        counts: dict[str, int] = {}
        for m in members:
            for name in meetings[m["id"]]["people"]:
                counts[name] = counts.get(name, 0) + 1
        out.append({
            "id": pid, **p, "meetings": members,
            "people": sorted(counts, key=lambda n: (-counts[n], n.casefold()))[:8],
            "latest": members[0]["start"] if members else None,
        })
    out.sort(key=lambda p: p["latest"] or "", reverse=True)
    unsorted = [
        {"id": m["id"], "title": m["title"], "start": m["start"], "duration": m["duration"],
         "suggestions": projects.suggestions(m["id"], store, every, similarity)}
        for m in meetings.values() if m["id"] in every and not m["projects"]
    ]
    return {"projects": out, "unsorted": unsorted}


def create_project(name: str, description: str = "") -> str:
    with _PROJECTS_LOCK:
        store = projects.ProjectStore()
        pid = store.create(name, description)
        store.save()
        return pid


def update_project(output_dir: Path, pid: str, *, name: str | None = None,
                   description: str | None = None) -> str:
    """A project's name or description; returns the undo token."""
    with _PROJECTS_LOCK:
        store = projects.ProjectStore()
        if pid not in store.projects():
            raise NotFound(pid)
        with _undoable(output_dir, "project", stores=_store_paths("projects")) as token:
            store.update(pid, name=name, description=description)
            store.save()
    return token


class _ModelFailed(Exception):
    pass


def model_change(output_dir: Path, label: str, run: Callable[[], bool], *, jobs: Path | None = None,
                 page_label: str | None = None) -> str | None:
    """The local model changes the projects (sorts meetings, describes a
    project): ``run()`` says whether it worked. Returns the undo token, or
    None when it failed (what it changed by then is rolled back). ``jobs``:
    the snapshot is noted there while the run goes on, so a server started
    after this one finishes it (``model_jobs``, #57)."""
    taken = []
    try:
        with _undoable(output_dir, label, stores=_store_paths("projects")) as token:
            taken.append(token)
            if jobs is not None:
                model_jobs.pending_undo(jobs, token, page_label or label)
            if not run():
                raise _ModelFailed
    except _ModelFailed:
        if jobs is not None:
            model_jobs.finish_undo(jobs, taken[0], ok=False, told=True)
        return None
    except BaseException:
        if jobs is not None and taken:
            model_jobs.finish_undo(jobs, taken[0], ok=False, told=True)
        raise
    if jobs is not None:
        model_jobs.finish_undo(jobs, token, ok=True, told=True)
    return token


def model_jobs_view(output_dir: Path, jobs: Path) -> dict[str, Any]:
    """The language model's jobs (#57): those running (the page shows them,
    also after the server was restarted) and the model changes finished
    after the server that started them was gone, with their undo."""
    _finish_orphaned(output_dir, jobs)
    return {"running": [{"kind": j["kind"], "key": j["key"], "started": j.get("started")}
                        for j in model_jobs.running(jobs)],
            "finished": model_jobs.finished_undos(jobs)}


def _finish_orphaned(output_dir: Path, jobs: Path) -> None:
    """A sort whose server is gone: sealed once its run ended well (or it is
    not known how it ended), rolled back when it failed."""
    for pending in model_jobs.pending_undos(jobs):
        owner = pending.get("owner")
        if owner == os.getpid() or _pid_alive(owner):
            continue  # its server waits for it
        run = model_jobs.read(jobs, "projects", "projects")
        if run and run.get("state") == "running" and not run.get("stale"):
            continue
        ok = run is None or run.get("stale") or run.get("returncode") == 0
        token = pending["token"]
        with _PROJECTS_LOCK:
            try:
                if ok:
                    undo.sealed(output_dir, token)
                else:
                    undo.restore(output_dir, token, check=False)
            except Exception:
                LOGGER.exception("finishing the model's change %s failed", token)
                ok = False
        model_jobs.finish_undo(jobs, token, ok=bool(ok))
        model_jobs.clear(jobs, "projects", "projects")


def _pid_alive(pid) -> bool:
    try:
        os.kill(int(pid), 0)
    except (TypeError, ValueError, ProcessLookupError):
        return False
    except PermissionError:
        return True
    return True


def merge_projects(output_dir: Path, pid: str, into: str) -> str:
    """Returns the undo token."""
    with _PROJECTS_LOCK:
        store = projects.ProjectStore()
        if pid not in store.projects() or into not in store.projects():
            raise NotFound(pid if pid not in store.projects() else into)
        with _undoable(output_dir, "merge projects", stores=_store_paths("projects")) as token:
            store.merge(pid, into)
            store.save()
    return token


def delete_project(output_dir: Path, pid: str) -> str:
    """Returns the undo token."""
    with _PROJECTS_LOCK:
        store = projects.ProjectStore()
        if pid not in store.projects():
            raise NotFound(pid)
        with _undoable(output_dir, "delete project", stores=_store_paths("projects")) as token:
            store.delete(pid)
            store.save()
    return token


def set_meeting_project(output_dir: Path, meeting_id: str, *, project: str | None = None,
                        name: str | None = None, remove: bool = False) -> str:
    """Put a meeting in a project (by id, or by name — a new name makes a new
    project), confirm a suggested one, or take it out. Returns the undo
    token: the projects store as it was (an inverse call would leave the
    project rejected, confirmed, or made)."""
    meeting_paths(output_dir, meeting_id)
    with _PROJECTS_LOCK:
        store = projects.ProjectStore()
        if project is None:
            if not (name or "").strip():
                raise ValueError("a project or a name is needed")
        elif project not in store.projects():
            raise NotFound(project)
        with _undoable(output_dir, "project", stores=_store_paths("projects")) as token:
            if project is None:
                project = store.find(name) or store.create(name)
            if remove:
                store.unassign(meeting_id, project)
            else:
                store.assign(meeting_id, project, why="")
            store.save()
    return token


def known_names(output_dir: Path, user_name: str) -> list[str]:
    """Names to suggest: the voice bank and every name given in a meeting."""
    found = {user_name, *VoiceBank().names()}
    if output_dir.is_dir():
        for folder in output_dir.iterdir():
            if folder.is_dir() and is_recording_folder_name(folder.name):
                found.update(_names(RecordingPaths(folder)).values())
    return sorted(found, key=str.casefold)


def _search_words(query: str | list[str]) -> list[re.Pattern]:
    """Each word of ``query``, matched where a word starts: "rtv" finds
    "RTV" and "RTV-Projekt", not "Wortvorrat". A quoted phrase is one word."""
    words = query.split() if isinstance(query, str) else query
    return [re.compile(r"(?<!\w)" + re.escape(w), re.IGNORECASE) for w in words]


def _has_all(words: list[re.Pattern], text: str) -> bool:
    return all(w.search(text) for w in words)


# --- search (#46) ----------------------------------------------------------------

# id → (file times, who took part): named speakers and invitees.
_PARTICIPANTS_CACHE: dict[str, tuple[tuple, dict[str, list[str]]]] = {}
_ORG_INDEX: dict[str, Any] = {"key": None}


def _participants(paths: RecordingPaths, user_name: str) -> dict[str, list[str]]:
    """Who spoke (named speakers, and the user when they said something) and
    who was invited."""
    signature = (_signature(paths), user_name)
    cached = _PARTICIPANTS_CACHE.get(str(paths.folder))
    if cached is None or cached[0] != signature:
        ignored = load_ignored(paths)
        spoke = [name for label, name in _names(paths).items() if label not in ignored]
        if user_name and any(u.speaker == user_name for u in _utterances(paths)):
            spoke.append(user_name)
        event = calendar_events.load(paths)
        invited = [a.name for a in calendar_events.candidates(event, user_name="")] if event else []
        cached = (signature, {"spoke": list(dict.fromkeys(spoke)), "invited": invited})
        _PARTICIPANTS_CACHE[str(paths.folder)] = cached
    return cached[1]


def _org_index(output_dir: Path) -> dict[str, dict[str, Any]]:
    """Everyone the calendars invited (organizations.people_index), read again
    only when a calendar file changed."""
    key = tuple((f.name, f.stat().st_mtime_ns) for f in sorted(output_dir.glob("*/calendar.json")))
    if _ORG_INDEX["key"] != key:
        _ORG_INDEX.update(key=key, index=organizations.people_index(output_dir))
    return _ORG_INDEX["index"]


def _name_words(name: str) -> list[str]:
    return re.findall(r"\w+", name.casefold())


def is_person(wanted: str, name: str) -> bool:
    """Whether ``name`` (a speaker or invitee) is ``wanted``: every word of
    it ("Anna" is Anna Berger), or the same first name when ``name`` is only a
    first name (a speaker called "Anna" is Anna Berger)."""
    want, have = _name_words(wanted), _name_words(name)
    if not want or not have:
        return False
    return all(w in have for w in want) or (len(have) == 1 and have[0] == want[0])


def _took_part(person: str, who: dict[str, list[str]]) -> int:
    """2: spoke, 1: was invited, 0: neither."""
    if any(is_person(person, n) for n in who["spoke"]):
        return 2
    return 1 if any(is_person(person, n) for n in who["invited"]) else 0


def search_vocabulary(output_dir: Path, meetings: list[dict[str, Any]], user_name: str,
                      hide_projects: frozenset[str] = frozenset()) -> search_query.Vocabulary:
    """The names a search knows: people who spoke or were invited, the voice
    bank, projects and organizations."""
    found: dict[str, str] = {}
    for name in [user_name, *VoiceBank().names()]:
        found.setdefault(name.casefold(), name)
    for m in meetings:
        who = _participants(RecordingPaths(output_dir / m["id"]), user_name)
        for name in [*who["spoke"], *who["invited"]]:
            found.setdefault(name.casefold(), name)
    store = projects.ProjectStore()
    orgs = organizations.Organizations()
    index = _org_index(output_dir)
    org_names = [o["name"] for o in organizations.summary(index, orgs)] if index else []
    return search_query.Vocabulary(
        people=sorted(n for n in found.values() if n),
        projects={pid: p["name"] for pid, p in store.projects().items() if pid not in hide_projects},
        orgs=org_names)


def _start_day(m: dict[str, Any]):
    try:
        return datetime.fromisoformat(m["start"]).date() if m.get("start") else None
    except ValueError:
        return None


class _Line(NamedTuple):
    start: float
    speaker: str
    text: str


# id → (file times, {names, notes, lines}): a search reads each meeting's
# notes and makes its transcript readable once per change, not per query.
# Lines are kept as plain tuples (~100 bytes a line).
_SEARCH_CACHE: dict[str, tuple[tuple, dict[str, Any]]] = {}


class _Found:
    """A meeting that passed the filters, with what the words may be found in."""

    def __init__(self, output_dir: Path, m: dict[str, Any], score: int):
        self.m = m
        self.score = score  # how the people took part: speakers before invitees
        self.paths = RecordingPaths(output_dir / m["id"])
        signature = _signature(self.paths)
        cached = _SEARCH_CACHE.get(str(self.paths.folder))
        if cached is None or cached[0] != signature:
            names = _display_names(self.paths)
            raw = notes.load(self.paths)
            cached = (signature, {"names": names, "lines": None, "notes": (
                glossary.current().apply_to(notes.with_names(raw, names)) if raw is not None else None)})
            _SEARCH_CACHE[str(self.paths.folder)] = cached
        self._data = cached[1]
        self.names, self.notes = self._data["names"], self._data["notes"]

    @property
    def lines(self) -> list[_Line]:
        if self._data["lines"] is None:
            self._data["lines"] = [_Line(u.start, u.speaker, u.text) for u in readable(shared_mic.shown(
                self.paths, apply_speaker_names(without_ignored(self.paths, _utterances(self.paths)), self.names)))]
        return self._data["lines"]

    def items(self) -> list[dict[str, Any]]:
        """The notes, piece by piece: decisions, next steps, points, summary."""
        n = self.notes or {}
        out = [{"kind": "decision", "text": d} for d in n.get("decisions") or [] if isinstance(d, str)]
        out += [{"kind": "step", "text": s.get("task") or "", "owner": s.get("owner") or ""}
                for s in n.get("next_steps") or [] if isinstance(s, dict)]
        for section in n.get("sections") or []:
            for point in section.get("points") or []:
                text = " ".join([point.get("text") or "", *(point.get("details") or [])]).strip()
                out.append({"kind": "point", "text": text, "heading": section.get("heading") or ""})
        if n.get("summary"):
            out.append({"kind": "summary", "text": n["summary"]})
        return out


def _filtered(output_dir: Path, q: search_query.Query, user_name: str,
              exclude: frozenset[str] = frozenset()) -> list[_Found]:
    """The meetings that pass the query's filters, newest first."""
    meetings = [m for m in list_meetings(output_dir) if m["id"] not in exclude]
    want_orgs = {o.casefold() for o in q.orgs}
    index = _org_index(output_dir) if want_orgs else {}
    org_names = organizations.Organizations() if want_orgs else None
    out = []
    for m in meetings:
        day = _start_day(m)
        if (q.since and (day is None or day < q.since)) or (q.until and (day is None or day > q.until)):
            continue
        if q.projects and not all(any(p["id"] == pid for p in m["projects"]) for pid in q.projects):
            continue
        if q.reviewed is not None and (output_dir / m["id"] / "review.json").exists() != q.reviewed:
            continue
        who = _participants(RecordingPaths(output_dir / m["id"]), user_name)
        took = [_took_part(p, who) for p in q.people]
        if took and not (any(took) if q.any_person else all(took)):
            continue
        if want_orgs:
            theirs = {(organizations.org_of(n, index, org_names) or "").casefold() for n in who["spoke"] + who["invited"]}
            if not want_orgs <= theirs - {""}:
                continue
        found = _Found(output_dir, m, sum(took))
        if q.has_steps and not (found.notes or {}).get("next_steps"):
            continue
        out.append(found)
    return out


_SCOPE_KINDS = {"decisions": {"decision"}, "steps": {"step"}, "notes": {"decision", "step", "point", "summary"},
                "title": set(), "transcript": set(), None: {"decision", "step", "point", "summary"}}


def _line(u: Utterance) -> dict[str, Any]:
    return {"start": round(u.start, 2), "speaker": u.speaker, "text": u.text}


def _matched(f: _Found, q: search_query.Query) -> dict[str, Any] | None:
    """The meeting as a result: the notes pieces and transcript lines the
    words are in; None when they are not all in the part searched."""
    words = _search_words(q.words)
    scope = q.scope if not q.said_by else "transcript"
    title = f.m["title"] or ""
    kinds = _SCOPE_KINDS[scope]
    items = [i for i in f.items() if i["kind"] in kinds]
    lines = []
    if scope in (None, "transcript"):
        lines = [u for u in f.lines if not q.said_by or is_person(q.said_by, u.speaker)]
    texts = ([title] if scope in (None, "title") else []) + [_item_text(i) for i in items]
    texts += [f"{u.speaker} {u.text}" for u in lines] if not q.said_by else [u.text for u in lines]
    if not words:
        if scope in ("decisions", "steps") and not items:
            return None
        if q.said_by and not lines:
            return None
        note_hits = items if scope in ("decisions", "steps") else []
        line_hits = lines if q.said_by else []
        in_title = in_notes = False
    else:
        if not _has_all(words, " ".join(texts)):
            return None
        note_hits = [i for i in items if _has_all(words, _item_text(i))]
        line_hits = [u for u in lines if _has_all(words, u.text if q.said_by else f"{u.speaker} {u.text}")]
        in_title = scope in (None, "title") and _has_all(words, title)
        in_notes = _has_all(words, " ".join([title, *(_item_text(i) for i in items)]))
    order = {"decision": 0, "step": 1, "point": 2, "summary": 3}
    note_hits = sorted(note_hits, key=lambda i: order[i["kind"]])
    return {**f.m, "in_title": in_title, "in_notes": in_notes,
            "notes_hits": note_hits[:SEARCH_NOTES_HITS], "hits": [_line(u) for u in line_hits[:SEARCH_HITS_PER_MEETING]],
            "hit_count": len(line_hits),
            "_rank": (in_title, any(i["kind"] in ("decision", "step") for i in note_hits), in_notes, len(line_hits),
                      f.score)}


WARM_DELAY_SECONDS = 20.0   # after the window's server starts: the app launches first
WARM_RETRY_SECONDS = 30.0   # while a recording or processing runs
WARM_PAUSE_SECONDS = 0.05   # between meetings: others go first


def busy_recording(recording) -> bool:
    """Whether the menu bar app records or processes a recording now
    (never without the menu bar app)."""
    busy = getattr(recording, "busy", None)
    try:
        if busy:
            return bool(busy())
        from .. import daemon  # `palaver app`: a `palaver daemon` may record beside it

        state = json.loads(daemon.STATE_PATH.read_text())
        return state.get("state") == "recording" or bool(state.get("transcribing"))
    except FileNotFoundError:
        return False
    except Exception:
        return True  # not known: as if busy


def warm_search_cache(output_dir: Path, *, user_name: str, busy: Callable[[], bool],
                      sleep: Callable[[float], None] = time.sleep, delay: float = WARM_DELAY_SECONDS) -> None:
    """Make every finished meeting ready for the search (names, notes,
    readable lines), so the first search after a start is as quick as the
    rest. Waits ``delay`` first; never while a recording or processing runs
    (``busy``), stops when one starts and goes on after it."""
    sleep(delay)
    while True:
        if busy():
            sleep(WARM_RETRY_SECONDS)
            continue
        stopped = False
        for m in list_meetings(output_dir):
            if m["status"] != "ready":
                continue
            if busy():
                stopped = True
                break
            try:
                _Found(output_dir, m, 0).lines
            except Exception:
                LOGGER.debug("warming the search of %s failed", m["id"], exc_info=True)
            sleep(WARM_PAUSE_SECONDS)
        if not stopped:
            return


def _background_qos() -> None:
    """This thread on the efficiency cores, behind everything else (macOS)."""
    try:
        import ctypes

        ctypes.CDLL(None).pthread_set_qos_class_self_np(0x09, 0)  # QOS_CLASS_BACKGROUND
    except Exception:
        pass


def start_warming(output_dir: Path, *, user_name: str, recording) -> threading.Thread:
    def run():
        _background_qos()
        try:
            warm_search_cache(output_dir, user_name=user_name, busy=lambda: busy_recording(recording))
        except Exception:
            LOGGER.debug("warming the search failed", exc_info=True)

    t = threading.Thread(target=run, name="search-warm", daemon=True)
    t.start()
    return t


def _item_text(item: dict[str, Any]) -> str:
    return " ".join(x for x in (item.get("owner"), item.get("heading"), item["text"]) if x)


def run_search(output_dir: Path, text: str, *, user_name: str, exclude: frozenset[str] = frozenset(),
               hide_projects: frozenset[str] = frozenset(),
               today=None) -> tuple[search_query.Query, list[dict[str, Any]]]:
    meetings = [m for m in list_meetings(output_dir) if m["id"] not in exclude]
    q = search_query.parse(text, search_vocabulary(output_dir, meetings, user_name, hide_projects), today=today)
    if q.empty:
        return q, []
    results = [r for f in _filtered(output_dir, q, user_name, exclude) if (r := _matched(f, q)) is not None]
    results.sort(key=lambda r: r.pop("_rank"), reverse=True)  # stable: newest first among equals
    return q, results[:SEARCH_MAX_MEETINGS]


def search(output_dir: Path, query: str, *, user_name: str, today=None) -> list[dict[str, Any]]:
    """Meetings for a search: its filters (people who took part, an
    organization, projects, dates, reviewed, next steps) and every word of
    it in the part searched (title, notes, transcript; decisions only, next
    steps only, or one person's lines). A match in the title ranks first,
    then a decision or next step, then the notes, then the most transcript
    lines, then how the people took part, then the newest."""
    return run_search(output_dir, query, user_name=user_name, today=today)[1]


def search_page(output_dir: Path, query: str, *, user_name: str, today=None) -> dict[str, Any]:
    """The search as the window shows it: the results, the filters it
    understood (as chips), the words, and whether search by meaning can add
    to them ("ready") or not ("off")."""
    from .. import semantic

    q, results = run_search(output_dir, query, user_name=user_name, today=today)
    return {"query": query, "understood": q.chips(), "words": q.words, "results": results,
            "meaning": "ready" if q.words and semantic.ready(output_dir) else "off"}


SEARCH_MEANING_MEETINGS = 6
_MEANING_KINDS = {None: None, "decisions": {"decision"}, "steps": {"step"},
                  "notes": {"summary", "decision", "step", "point"}, "transcript": {"line"}}
_SEARCHER = None


def searcher():
    """The window's searcher by meaning: one per process, its model loaded on demand."""
    global _SEARCHER
    if _SEARCHER is None:
        from .. import semantic

        _SEARCHER = semantic.Searcher()
    return _SEARCHER


def search_meaning(output_dir: Path, query: str, *, user_name: str, searcher=None,
                   exclude: frozenset[str] = frozenset(), hide_projects: frozenset[str] = frozenset(),
                   today=None) -> list[dict[str, Any]]:
    """Meetings about the words of ``query`` by meaning, within its filters,
    best first, each with its best pieces (``meaning``): notes pieces, or
    lines with who said them and when. Empty when it is switched off, or
    nothing is indexed."""
    from .. import semantic

    if not semantic.enabled():
        return []
    meetings = [m for m in list_meetings(output_dir) if m["id"] not in exclude]
    q = search_query.parse(query, search_vocabulary(output_dir, meetings, user_name, hide_projects), today=today)
    if not q.words or q.scope == "title":
        return []
    found = {f.paths.folder.name: f for f in _filtered(output_dir, q, user_name, exclude)}
    if not found:
        return []
    kinds = {"line"} if q.said_by else _MEANING_KINDS[q.scope]
    names = {mid: f.names for mid, f in found.items()}
    who = None
    if q.said_by:
        def who(paths: RecordingPaths, label: str) -> bool:
            return is_person(q.said_by, names[paths.folder.name].get(label, label))
    hits = (searcher or globals()["searcher"]()).search([f.paths for f in found.values()], " ".join(q.words),
                                                         kinds=kinds, speaker=who)
    out = []
    for mid, pieces in hits.items():
        f = found[mid]
        shown = []
        for piece in pieces:
            piece = glossary.current().apply_to(notes.with_names(piece, f.names))
            if piece["kind"] == "line":
                piece["speaker"] = f.names.get(piece["speaker"], piece["speaker"])
            shown.append(piece)
        out.append({**f.m, "meaning": shown, "_score": pieces[0]["score"]})
    out.sort(key=lambda r: r.pop("_score"), reverse=True)
    return out[:SEARCH_MEANING_MEETINGS]


# --- audio -------------------------------------------------------------

def _tracks(paths: RecordingPaths, track: str) -> list[Path]:
    if track == "system":
        files = [paths.system_wav]
    elif track == "mix":
        files = [paths.mic_wav if paths.mic_wav.exists() else paths.mic_raw_wav, paths.system_wav]
    else:
        raise NotFound(track)
    files = [f for f in files if f.exists()]
    if not files:
        raise NotFound(track)
    return files


class AudioSource:
    """A recording's audio as one 16-bit mono WAV, mixed on the fly so any
    byte range can be served without writing a mixed copy to disk."""

    HEADER = 44

    def __init__(self, paths: RecordingPaths, track: str):
        self._files = _tracks(paths, track)
        infos = [sf.info(str(f)) for f in self._files]
        self.sample_rate = infos[0].samplerate
        self.frames = max(i.frames for i in infos)
        self.size = self.HEADER + 2 * self.frames

    def _header(self) -> bytes:
        import struct

        data = 2 * self.frames
        return (
            b"RIFF" + struct.pack("<I", 36 + data) + b"WAVEfmt "
            + struct.pack("<IHHIIHH", 16, 1, 1, self.sample_rate, 2 * self.sample_rate, 2, 16)
            + b"data" + struct.pack("<I", data)
        )

    def read(self, start: int, end: int) -> bytes:
        """Bytes ``start`` .. ``end`` inclusive."""
        out = b""
        if start < self.HEADER:
            out = self._header()[start : min(end + 1, self.HEADER)]
            start = self.HEADER
        if end < start:
            return out
        first, last = (start - self.HEADER) // 2, (end - self.HEADER) // 2 + 1
        mix = np.zeros(last - first, dtype=np.int32)
        for f in self._files:
            chunk, _ = sf.read(str(f), start=first, stop=last, dtype="int16", always_2d=True)
            mix[: len(chunk)] += chunk[:, 0]
        pcm = np.clip(mix, -32768, 32767).astype("<i2").tobytes()
        offset = (start - self.HEADER) % 2
        return out + pcm[offset : offset + end - start + 1]


# --- glossary ---------------------------------------------------------------------

GLOSSARY_SUGGESTIONS = 20
REVIEW_SUGGESTIONS = 3
_GLOSSARY_LOCK = threading.Lock()
_SUGGESTIONS: dict[str, tuple[tuple, list[dict[str, Any]]]] = {}


def _suggestions(output_dir: Path, user_name: str) -> list[dict[str, Any]]:
    """All glossary suggestions; computed again when a transcript, the
    calendar, the projects or the glossary change."""
    files = [glossary._default_path(), projects._default_path()]
    if output_dir.is_dir():
        for folder in output_dir.iterdir():
            if is_recording_folder_name(folder.name):
                files += [folder / "transcript.json", folder / "calendar.json", folder / "speakers.json"]
    signature = tuple(f.stat().st_mtime_ns if f.exists() else 0 for f in files)
    cached = _SUGGESTIONS.get(str(output_dir))
    if cached is None or cached[0] != signature:
        found = glossary.suggest(glossary.corpus(output_dir),
                                 glossary.known_spellings(output_dir, user_name=user_name), glossary.Glossary(),
                                 unsure=glossary.unsure_words(output_dir))
        cached = (signature, found)
        _SUGGESTIONS[str(output_dir)] = cached
    return cached[1]


def _with_titles(suggestions: list[dict[str, Any]], titles: dict[str, str | None]) -> list[dict[str, Any]]:
    return [{**s, "examples": [{**e, "title": titles.get(e["meeting"])} for e in s["examples"]]} for s in suggestions]


def glossary_page(output_dir: Path, *, user_name: str) -> dict[str, Any]:
    g = glossary.Glossary()
    titles = {m["id"]: m["title"] for m in list_meetings(output_dir)}
    return {
        "terms": sorted(({"id": tid, **t} for tid, t in g.terms().items()), key=lambda t: t["term"].casefold()),
        "suggestions": _with_titles(_suggestions(output_dir, user_name)[:GLOSSARY_SUGGESTIONS], titles),
    }


def _raw_texts(output_dir: Path) -> dict[str, list[str]]:
    from ..readable import clean_text

    out = {}
    if output_dir.is_dir():
        for folder in output_dir.iterdir():
            if is_recording_folder_name(folder.name):
                out[folder.name] = [clean_text(u.text) for u in _utterances(RecordingPaths(folder))]
    return out


def _rerender(output_dir: Path, meetings: list[str]) -> None:
    """transcript.md with the glossary as it is now."""
    for meeting_id in meetings:
        paths = RecordingPaths(output_dir / meeting_id)
        meta = _read_json(paths.meta, {})
        if meta.get("start_time") and meta.get("duration_seconds") is not None and paths.transcript_md.exists():
            paths.transcript_md.write_text(render_markdown(
                _utterances(paths), datetime.fromisoformat(meta["start_time"]), float(meta["duration_seconds"]),
                meta.get("gaps")))


def _respelled(before: glossary.Glossary, after: glossary.Glossary, text: str) -> int:
    """How many words of ``text`` are shown differently after a glossary change."""
    a, b = before.apply(text).split(), after.apply(text).split()
    if a == b:
        return 0
    ops = difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes()
    return sum(max(i2 - i1, j2 - j1) for op, i1, i2, j1, j2 in ops if op != "equal")


def change_glossary(output_dir: Path, change) -> dict[str, Any]:
    """Apply ``change(glossary)`` and say what it did to the meetings: how
    many words are shown differently, in which meetings."""
    with _GLOSSARY_LOCK:
        g = glossary.Glossary()
        before = glossary.Glossary(g.path)
        change(g)
        g.save()
    texts = _raw_texts(output_dir)
    notes_texts = {m: json.dumps(n, ensure_ascii=False) for m in texts
                   if (n := notes.load(RecordingPaths(output_dir / m)))}
    words = {m: sum(_respelled(before, g, t) for t in lines) for m, lines in texts.items()}
    in_notes = {m: _respelled(before, g, t) for m, t in notes_texts.items()}
    changed = sorted(m for m in texts if words[m] or in_notes.get(m))
    _rerender(output_dir, changed)
    return {"meetings": changed,
            "replacements": sum(words[m] for m in changed),
            "in_notes": sum(in_notes.get(m, 0) for m in changed)}


def accept_suggestion(output_dir: Path, *, term: str, variants: list[str], note: str = "") -> dict[str, Any]:
    """Accept a suggestion as given or corrected: ``term`` is the right
    spelling, ``variants`` the ones to respell."""
    if not term.strip():
        raise ValueError("a term is needed")
    return change_glossary(output_dir, lambda g: g.add(term, variants, note))


def respell(output_dir: Path, *, heard: str, term: str) -> dict[str, Any]:
    """Words as a meeting shows them, and how they are really spelled.
    ``heard`` becomes a variant of ``term``; when it is a term already (a
    meeting shows terms, not their variants), that term is respelled, or
    joins ``term`` with all its variants."""
    heard, term = heard.strip(), term.strip()
    if not heard or not term:
        raise ValueError("the words and their spelling are needed")

    def change(g: glossary.Glossary) -> None:
        tid, other = g.find(heard), g.find(term)
        if tid is None:
            g.add(term, [heard])
            return
        variants = g.terms()[tid]["variants"]
        if other not in (None, tid):
            g.delete(tid)
        else:
            g.update(tid, term=term)
        g.add(term, [heard, *variants])

    with _undoable(output_dir, "respell", stores=_store_paths("glossary")) as token:
        changed = change_glossary(output_dir, change)
    g = glossary.Glossary()
    tid = g.find(term)
    return {"changed": changed, "term": {"id": tid, **g.terms()[tid]}, "undo": token}


def reject_suggestion(output_dir: Path, keys: str | list[str]) -> str:
    """"Not this": the suggestion (or one spelling of it: each spelling of a
    known name has its own key) is not made again. Returns the undo token."""
    with _undoable(output_dir, "not this", stores=_store_paths("glossary")) as token, _GLOSSARY_LOCK:
        g = glossary.Glossary()
        for key in [keys] if isinstance(keys, str) else keys:
            g.reject(key)
        g.save()
    return token


def update_term(output_dir: Path, tid: str, *, term: str | None = None, note: str | None = None,
                remove_variant: str | None = None, add_variants: list[str] | None = None,
                delete: bool = False) -> dict[str, Any]:
    g = glossary.Glossary()
    if tid not in g.terms():
        raise NotFound(tid)

    def change(g: glossary.Glossary) -> None:
        if delete:
            g.delete(tid)
            return
        g.update(tid, term=term, note=note)
        if remove_variant:
            g.remove_variant(tid, remove_variant)
        if add_variants:
            g.add(g.terms()[tid]["term"], add_variants)

    with _undoable(output_dir, "delete term" if delete else "term", stores=_store_paths("glossary")) as token:
        changed = change_glossary(output_dir, change)
    return {**changed, "undo": token}


# --- review -------------------------------------------------------------------------


def _open_items(output_dir: Path, m: dict[str, Any], suggestions: list[dict[str, Any]]) -> dict[str, Any]:
    unsure = [p for p in m["projects"] if p["by"] != "you"]
    return {
        "unnamed": m["unnamed"],
        "projects": "none" if not m["projects"] else ("unsure" if unsure else "ok"),
        "glossary": [s for s in suggestions if m["id"] in s["meetings"]][:REVIEW_SUGGESTIONS],
        "notes": "missing" if not m["has_notes"] else ("stale" if m["notes_stale"] else "ok"),
    }


def review_queue(output_dir: Path, *, user_name: str) -> list[dict[str, Any]]:
    """Finished meetings not reviewed yet, newest first, with what is open."""
    meetings = [m for m in list_meetings(output_dir) if m["status"] == "ready"
                and not (output_dir / m["id"] / "review.json").exists()]
    suggestions = _suggestions(output_dir, user_name) if meetings else []
    titles = {m["id"]: m["title"] for m in meetings}
    return [{**m, "open": {**(o := _open_items(output_dir, m, suggestions)),
                           "glossary": _with_titles(o["glossary"], titles)}} for m in meetings]


def _lane_links(paths: RecordingPaths) -> list[dict[str, Any]]:
    """How each speaker got its name, from the stored files alone (no
    transcript): what open_questions needs of the lanes."""
    manual, recognized = load_speaker_names(paths), load_recognized_names(paths)
    rejected = load_rejected_names(paths)
    inferred = {label: i for label, i in inference.load(paths).items()
                if isinstance(i, dict) and i.get("name", "").casefold()
                not in {n.casefold() for n in rejected.get(label, [])}}
    skip = set(load_merges(paths)) | load_ignored(paths) | shared_mic.shared_labels(paths)
    out = []
    for label in sorted(set(manual) | set(recognized) | set(inferred)):
        if label in skip:
            continue
        auto = recognized.get(label)
        guess = inferred.get(label) if label not in manual and not auto else None
        named_by = "you" if manual.get(label, label) != label else (
            "voice" if auto and label not in manual else ("inferred" if guess else None))
        name = manual.get(label) if named_by == "you" else auto[0] if named_by == "voice" else (
            guess["name"] if guess else None)
        link = _speaker_link(name, named_by, auto, guess)
        if link:
            out.append({"label": label, "link": link})
    return out


# id → (file times, what the questions are made of): the stored files only.
_QUESTIONS_CACHE: dict[str, tuple[tuple, dict[str, Any]]] = {}


def open_questions(output_dir: Path, *, user_name: str) -> list[dict[str, Any]]:
    """What Palaver is unsure of and asks the user (issue #48), newest
    meeting first: which event, when several overlapped a recording, and
    every unsure link (event, speaker, project). For the "Needs you" page of
    the UI spec; each item says what to ask and the link it is about. Made
    from the stored files, cached per meeting by their times."""
    out = []
    for m in list_meetings(output_dir):
        if m["status"] != "ready":
            continue
        paths = RecordingPaths(output_dir / m["id"])
        signature = _signature(paths)
        cached = _QUESTIONS_CACHE.get(str(paths.folder))
        if cached is None or cached[0] != signature:
            link = calendar_events.load_link(paths)
            cached = (signature, {"event_question": _event_question(paths),
                                  "calendar": {"link": link.to_dict()} if link else None,
                                  "speakers": _lane_links(paths)})
            _QUESTIONS_CACHE[str(paths.folder)] = cached
        out += attribution.questions({**m, **cached[1]})
    return out


def _unnamed_lanes(paths: RecordingPaths) -> list[dict[str, Any]]:
    """The voices worth a name that have none, most talk first: their label,
    a clip to hear, and the names the notes found for them (backed by the
    transcript). From the stored files, without building the meeting."""
    talk = talk_seconds(_turns(paths))
    names = _names(paths)
    skip = load_ignored(paths) | shared_mic.shared_labels(paths) | load_unknown(paths)  # "Don't Know": not asked
    lanes = sorted((label for label in talk if talk[label] >= MIN_TALK_SECONDS and label not in skip
                    and label not in names), key=lambda label: -talk[label])
    if not lanes:
        return []
    turns = _turns(paths)
    meeting_notes = notes.load(paths) or {}
    guesses = notes.backed_name_guesses(meeting_notes.get("speaker_names", []),
                                        without_ignored(paths, _utterances(paths)))
    out = []
    for label in lanes:
        longest = max((t for t in turns if t.speaker == label), key=lambda t: t.end - t.start, default=None)
        out.append({"label": label, "display": _label_display(label), "talk_seconds": round(talk[label], 1),
                    "clip": {"start": longest.start, "end": min(longest.end, longest.start + CLIP_SECONDS)}
                    if longest else None,
                    "guesses": list(dict.fromkeys(g["name"] for g in guesses if g["label"] == label))})
    return out


# id → (file times, what the needs are made of): the stored files only.
_NEEDS_CACHE: dict[str, tuple[tuple, dict[str, Any]]] = {}

# The order of a meeting's items, as its page shows them; "review" last.
_NEED_ORDER = ("which_event", "event", "no_event", "cut", "unnamed", "speaker", "project", "review")


def _need_id(item: dict[str, Any]) -> str:
    """What an item is about, the same while it stays open: what a review
    remembers as seen ("speaker|SPEAKER_02|Carla": a new guess is another item)."""
    kind = item["kind"]
    if kind == "unnamed":
        return f"unnamed|{item['label']}"
    if kind == "speaker":
        return f"speaker|{item['label']}|{item['name']}"
    if kind == "project":
        return f"project|{item['project']}"
    if kind == "event":
        return f"event|{item['title']}"
    return kind


def _need_items(m: dict[str, Any], made: dict[str, Any], cut: dict[str, Any] | None, *,
                calendar_on: bool) -> list[dict[str, Any]]:
    items = []
    for q in attribution.questions({**m, **made}):
        link = q.get("link") or {}
        if q["kind"] == "event" and q.get("choices"):
            items.append({"kind": "which_event", "reason": q["reason"], "choices": q["choices"]})
        elif q["kind"] == "event":
            items.append({"kind": "event", "title": link["target"], "why": link.get("reason") or ""})
        elif q["kind"] == "project":
            items.append({"kind": "project", "project": q["project"], "name": link["target"],
                          "why": link.get("reason") or ""})
    # A name Palaver guessed: inferred ones always (the page asks Yes or No), by voice when unsure (#48).
    for lane in made["speakers"]:
        link = lane["link"]
        if link["source"] == "inferred" or link["unsure"]:
            items.append({"kind": "speaker", "label": lane["label"], "display": _label_display(lane["label"]),
                          "name": link["target"], "why": link.get("reason") or "", "confidence": link.get("confidence")})
    if calendar_on and not made["has_event"] and not made["event_question"] and not made["dismissed"]:
        items.append({"kind": "no_event"})
    if cut:
        items.append({"kind": "cut", **cut})
    items += [{"kind": "unnamed", **lane} for lane in made["unnamed"]]
    items.append({"kind": "review"})
    return [{**i, "id": _need_id(i)} for i in sorted(items, key=lambda i: _NEED_ORDER.index(i["kind"]))]


# The cut suggestion asks the calendar, which may be slow or hang: it is
# looked up in the background, never while the window waits, and again
# after CUT_FRESH_SECONDS (a failed or stale answer is retried then). A
# lookup slower than CUT_LOOKUP_SECONDS counts as failed.
CUT_LOOKUP_SECONDS = 10.0
CUT_FRESH_SECONDS = 600.0
CUT_LOOKUPS_AT_ONCE = 4
_clock = time.time
_CUT_LOCK = threading.Lock()
_CUT_CACHE: dict[str, tuple[tuple, dict[str, Any] | None]] = {}  # folder → (key, the suggestion)
_CUT_PENDING: dict[str, tuple[tuple, float, threading.Thread]] = {}  # folder → (key, started, the lookup)


def _cut_later(output_dir: Path, paths: RecordingPaths, calendar, files: tuple) -> dict[str, Any] | None:
    """The cut suggestion as last looked up for these files; when that is
    not fresh, a lookup starts in the background (the answer shows next time)."""
    now = _clock()
    key = (files, int(now // CUT_FRESH_SECONDS))
    folder = str(paths.folder)
    with _CUT_LOCK:
        cached = _CUT_CACHE.get(folder)
        if cached and cached[0] == key:
            return cached[1]
        last = cached[1] if cached and cached[0][0] == files else None  # stale, but about these files
        pending = _CUT_PENDING.get(folder)
        if pending and now - pending[1] < CUT_LOOKUP_SECONDS:
            return last
        if pending:  # too slow: failed; asked again once the key moves on
            del _CUT_PENDING[folder]
            _CUT_CACHE[folder] = (pending[0], last)
            if pending[0] == key:
                return last
        if len(_CUT_PENDING) >= CUT_LOOKUPS_AT_ONCE:
            return last

        def look() -> None:
            try:
                found = _cut_suggestion(output_dir, paths, calendar)
            except Exception:
                LOGGER.exception("looking up a cut for %s failed", folder)
                found = last
            with _CUT_LOCK:
                if _CUT_PENDING.get(folder, (None,))[0] == key:
                    del _CUT_PENDING[folder]
                    _CUT_CACHE[folder] = (key, found)

        thread = threading.Thread(target=look, name="cut-lookup", daemon=True)
        _CUT_PENDING[folder] = (key, now, thread)
        thread.start()
        return last


def wait_for_cut_lookups(timeout: float) -> None:
    """For tests: until the background lookups running now are done."""
    with _CUT_LOCK:
        threads = [t for _, _, t in _CUT_PENDING.values()]
    for t in threads:
        t.join(timeout)


def _meeting_needs(output_dir: Path, m: dict[str, Any], calendar) -> list[dict[str, Any]]:
    """Every item open in finished meeting ``m``, reviewed or not."""
    paths = RecordingPaths(output_dir / m["id"])
    signature = (_signature(paths), paths.cut_dismissed.exists())
    cached = _NEEDS_CACHE.get(str(paths.folder))
    if cached is None or cached[0] != signature:
        link = calendar_events.load_link(paths)
        cached = (signature, {
            "event_question": _event_question(paths),
            "calendar": {"link": link.to_dict()} if link else None,
            "has_event": link is not None,
            "dismissed": calendar_events.dismissed(paths),
            "speakers": _lane_links(paths),
            "unnamed": _unnamed_lanes(paths),
        })
        _NEEDS_CACHE[str(paths.folder)] = cached
    cut = _cut_later(output_dir, paths, calendar, signature) if calendar is not None else None
    return _need_items(m, cached[1], cut, calendar_on=calendar is not None)


def needs(output_dir: Path, *, user_name: str, calendar=None) -> dict[str, Any]:
    """What waits on the user ("Needs you", phase 2 of the UI spec), per
    meeting, newest first: which event (several overlapped, an unsure match,
    none at all while a calendar is connected), a cut where the recording
    seems to run into another meeting (looked up in the background), voices
    without a name, names and projects Palaver is unsure of (#48), and that
    it is not reviewed yet. Of a reviewed meeting only what appeared after
    its review: what was open then the user saw and left. ``count``: the
    meetings with anything open. Made from the stored files, cached per
    meeting by their times."""
    out = []
    for m in list_meetings(output_dir):
        if m["status"] != "ready":
            continue
        items = _meeting_needs(output_dir, m, calendar)
        seen = _seen(RecordingPaths(output_dir / m["id"]))
        if seen is not None:
            items = [i for i in items if i["kind"] != "review" and i["id"] not in seen]
        if items:
            out.append({"id": m["id"], "title": m["title"], "start": m["start"], "items": items})
    return {"count": len(out), "meetings": out}


def _seen(paths: RecordingPaths) -> set[str] | None:
    """The items open when the meeting was reviewed (``_need_id``); None
    while it is not reviewed."""
    review = _read_json(paths.review, None)
    return set(review.get("seen") or []) if isinstance(review, dict) else None


def mark_reviewed(output_dir: Path, meeting_id: str, done: bool = True, *, calendar=None) -> None:
    """Reviewed, with the items open now ("seen"): they stay answered;
    only what appears later needs the user again."""
    paths = meeting_paths(output_dir, meeting_id)
    if not done and _status(paths) == "processing":
        raise Refused(_STILL_PROCESSING.format("be reviewed again"))
    if done:
        entry = next((m for m in list_meetings(output_dir) if m["id"] == meeting_id and m["status"] == "ready"), None)
        seen = [i["id"] for i in _meeting_needs(output_dir, entry, calendar) if i["kind"] != "review"] if entry else []
        paths.review.write_text(json.dumps({"reviewed": datetime.now().astimezone().isoformat(timespec="seconds"),
                                            "seen": seen}))
    else:
        paths.review.unlink(missing_ok=True)


# --- prep ---------------------------------------------------------------------------


def _upcoming_entry(event: calendar_events.Event, store: projects.ProjectStore) -> dict[str, Any]:
    named = store.projects()
    return {
        "key": event.key, "title": event.title, "start": event.start.isoformat(), "end": event.end.isoformat(),
        "series": event.series,
        "projects": [{"id": pid, "name": named[pid]["name"]} for pid in prep.chosen(event) if pid in named],
    }


def upcoming(provider, *, now: datetime | None = None) -> list[dict[str, Any]]:
    """Meetings still to come, with the projects chosen for them."""
    if provider is None:
        return []
    store = projects.ProjectStore()
    return [_upcoming_entry(e, store) for e in prep.upcoming(provider, now or datetime.now().astimezone())]


def _event(provider, key: str, now: datetime | None) -> calendar_events.Event:
    event = prep.find(provider, key, now or datetime.now().astimezone()) if provider else None
    if event is None:
        raise NotFound(key)
    return event


def upcoming_meeting(output_dir: Path, provider, key: str, *, user_name: str,
                     now: datetime | None = None) -> dict[str, Any]:
    """One upcoming meeting: invitees, projects (chosen and suggested), and
    the meetings that lead up to it."""
    event = _event(provider, key, now)
    store = projects.ProjectStore()
    every = projects.all_facts(output_dir, user_name=user_name)
    return {
        **_upcoming_entry(event, store),
        "attendees": [{"name": a.name, "organizer": a.organizer, "response": a.response}
                      for a in event.attendees if not a.is_room and not a.is_self],
        "suggestions": prep.suggestions(event, output_dir, user_name=user_name, store=store, every=every),
        "context": prep.context(event, output_dir, user_name=user_name, every=every),
        "all_projects": sorted(({"id": pid, "name": p["name"]} for pid, p in store.projects().items()),
                               key=lambda p: p["name"].casefold()),
    }


def set_upcoming_project(provider, key: str, *, project: str | None = None, name: str | None = None,
                         remove: bool = False, now: datetime | None = None) -> None:
    event = _event(provider, key, now)
    with _PROJECTS_LOCK:
        store = projects.ProjectStore()
        if project is None:
            if not (name or "").strip():
                raise ValueError("a project or a name is needed")
            project = store.find(name) or store.create(name)
            store.save()
        if project not in store.projects():
            raise NotFound(project)
    prep.choose(event, project, remove=remove)


# --- coach ------------------------------------------------------------------------

def _coach_result(paths: RecordingPaths, user_name: str) -> dict[str, Any]:
    """The coach's numbers for one meeting, cached until its files change."""
    return coach.result(paths, user_name=user_name)


def _my_notes(paths: RecordingPaths, event: calendar_events.Event | None) -> list[str]:
    """The user's own notes (#44) as the notes model reads them, with the
    text read from images; and the notes written before the meeting for
    its event that were not adopted into the recording yet."""
    from .. import my_notes

    texts = [my_notes.prompt_text(paths.folder)]
    if event is not None and event.key:
        texts.append(my_notes.prompt_text(my_notes.prep_folder(event.key)))
    return [t for t in texts if t.strip()]


def _event_of(paths: RecordingPaths, calendar) -> calendar_events.Event | None:
    """The recording's calendar event: the one stored, else the one the
    calendar has on while it was recorded."""
    event = calendar_events.load(paths)
    if event is not None or calendar is None:
        return event
    try:
        start, duration = cutting.span(paths)
        end = max(start + timedelta(seconds=duration), datetime.now().astimezone())
        return calendar_events.match(calendar(start - calendar_events.SEARCH_MARGIN, end), start, end)
    except Exception:
        LOGGER.exception("calendar lookup failed")
        return None


def next_question_inputs(output_dir: Path, meeting_id: str, *, user_name: str, calendar=None,
                         coach: dict | None = None, cfg=None) -> dict[str, Any]:
    """What the best next question is asked from (next_question.build_prompt):
    the text so far with speaker names (the live text and the stream's newer
    lines while recording), the calendar event, the last meeting with the
    same people, who hasn't spoken (the live coach) and the user's notes.

    With a cloud model, no earlier meeting kept on this Mac is in it
    ("Keep on This Mac", #53). ``meetings``: every meeting whose content it
    holds, for the access log."""
    from .. import llm, next_question, providers

    paths = meeting_paths(output_dir, meeting_id)
    cloud = llm.choice_for(cfg, next_question.FEATURE, [paths.folder]) not in (providers.LOCAL, providers.PENDING)
    m = get_meeting(output_dir, meeting_id, user_name=user_name)
    lines = [{"speaker": t["speaker"], "start": t["start"], "end": t["end"], "text": t["text"]}
             for t in m.get("transcript") or []]
    if m.get("status") == "recording":
        until = (m.get("live") or {}).get("until", 0)
        stream = live_stream(output_dir, meeting_id, user_name=user_name, since=until)
        lines += [{"speaker": "Others" if line["label"] else line["speaker"], "start": line["start"],
                   "end": line["end"], "text": line["text"]} for line in stream.get("lines") or []]
    event = _event_of(paths, calendar)
    last_time = []
    if event is not None:
        try:
            last_time = prep.context(event, output_dir, user_name=user_name)
        except Exception:
            LOGGER.exception("could not find the meetings before this one")
    if cloud:
        last_time = [t for t in last_time if not llm.is_local_only(output_dir / t["id"])]
    return {
        "user": user_name,
        "now": max((line["end"] for line in lines), default=0.0),
        "lines": lines,
        "title": titles.resolve(paths, event=event)[0],
        "invitees": [a.name for a in calendar_events.candidates(event, user_name=user_name)] if event else [],
        "quiet": list((coach or {}).get("quiet") or []),
        "last_time": last_time,
        "my_notes": _my_notes(paths, event),
        "meetings": [meeting_id, *[t["id"] for t in last_time if t["id"] != meeting_id]],
    }


def next_question_info(cfg, output_dir: Path, meeting_id: str, *, enabled: bool) -> dict[str, Any]:
    """The button: which model answers and where ("Best next question (Gemma,
    on this Mac)"), whether it can (``reason`` when not), and the warning a
    local model during the call needs a second click for."""
    from .. import llm, next_question, providers

    paths = meeting_paths(output_dir, meeting_id)
    off = {"ready": False, "label": "Best next question", "local": False, "warning": None}
    if not enabled:
        return {**off, "reason": "Notes are turned off, and with them the language model."}
    choice = llm.choice_for(cfg, next_question.FEATURE, [paths.folder])
    if choice == providers.PENDING:
        return {**off, "reason": "No model yet: choose one for Best next question in Settings → Language model."}
    if choice == providers.LOCAL:
        repo = llm.local_model(cfg)
        info = llm.LOCAL_MODELS.get(repo, {})
        short = info.get("label", repo.rsplit("/", 1)[-1]).split()[0]
        warning = None
        if _status(paths) == "recording":
            warning = (f"Runs {short} on this Mac during the call (about {info.get('running_gb', 10)} GB, "
                       "may slow the call)")
        return {"ready": True, "reason": None, "label": f"Best next question ({short}, on this Mac)",
                "local": True, "warning": warning}
    model = providers.settings_of(choice, llm.provider_defaults(cfg, choice)).get("model") or \
        providers.PROVIDERS[choice].label
    return {"ready": True, "reason": None, "label": f"Best next question ({next_question.model_name(model)}, cloud)",
            "local": False, "warning": None}


def next_question_problem(cfg, output_dir: Path, meeting_id: str, *, free_gb: float) -> str | None:
    """Why the best next question can't be asked now (the local model
    without its memory), or None. ``llm.choice_for`` keeps a meeting marked
    "Keep on This Mac" local."""
    from .. import llm, next_question, providers

    paths = meeting_paths(output_dir, meeting_id)
    local = llm.choice_for(cfg, next_question.FEATURE, [paths.folder]) == providers.LOCAL
    return next_question.memory_problem(local=local, free_gb=free_gb,
                                        need_gb=llm.memory_gb(cfg, next_question.FEATURE, paths.folder),
                                        recording=_status(paths) == "recording")


def coach_meeting(output_dir: Path, meeting_id: str, *, user_name: str) -> dict[str, Any]:
    """How the user talked in one meeting, with what is usual for them and
    the few things worth saying."""
    paths = meeting_paths(output_dir, meeting_id)
    if not paths.transcript_json.exists():
        raise NotFound(meeting_id)
    base = coach.baseline(coach.history(output_dir, user_name=user_name, limit=coach.BASELINE_MEETINGS))
    r = _coach_result(paths, user_name)
    return {**r, "baseline": base, "highlights": coach.highlights(r, base)}


def coach_overview(output_dir: Path, *, user_name: str) -> dict[str, Any]:
    """Every meeting's key numbers, newest first, and the averages."""
    titles = {m["id"]: m for m in list_meetings(output_dir)}
    results = {p.folder.name: _coach_result(p, user_name) for p in coach.meetings(output_dir)}
    rows = []
    for mid in sorted(results, reverse=True):
        r, m = results[mid], titles.get(mid, {})
        rows.append({"id": mid, "title": m.get("title"), "start": m.get("start"), "people": r["talk"]["people"],
                     "share": r["talk"]["share"], "wpm": r["pace"]["wpm"], "fillers": r["fillers"]["per_minute"],
                     "language": r["language"], "longest": r["monologues"][0]["seconds"] if r["monologues"] else 0,
                     "questions": r["questions"]["count"], "interruptions": r["interruptions"]["by_me"]})
    return {"baseline": coach.baseline(list(results.values())), "meetings": rows,
            "trends": coach.trends(coach.history(output_dir, user_name=user_name))}


# --- settings ---------------------------------------------------------------------

def get_settings(defaults: settings.Settings = settings.Settings()) -> dict[str, Any]:
    return asdict(settings.load(defaults))


def switches_turned_off(recording, body: dict) -> list[str]:
    """A record switch turned off on the Settings page stops that app's
    automatic recording now, as the menu's switch does; the apps told."""
    from ..appctl import SWITCH_APP

    tell = getattr(recording, "switched_off", None)
    off = [app for key, app in SWITCH_APP.items() if body.get(key) is False]
    for app in off if tell else []:
        tell(app)
    return off


def set_settings(body: dict, defaults: settings.Settings = settings.Settings()) -> dict[str, Any]:
    """Save the known keys of ``body``; anything but a boolean is a ValueError.
    Only those keys are written: a switch never touched keeps following
    ``defaults`` (config.toml)."""
    known = {f.name for f in fields(settings.Settings)}
    changes = {k: v for k, v in body.items() if k in known}
    for key, value in changes.items():
        if not isinstance(value, bool):
            raise ValueError(f"{key} must be true or false")
    settings.update(changes)
    return get_settings(defaults)


# --- the language model (#53) ---------------------------------------------------------


def language_model(cfg) -> dict[str, Any]:
    """The Settings page's Language model section: which model each feature
    uses and what it sends, the providers (never a key, only whether one
    is set), the local models and the access log. ``cfg``: config.toml,
    for the choices made there; None reads as its defaults."""
    from .. import access_log, llm, providers

    local = llm.local_model(cfg)
    models = [{"repo": repo, **info} for repo, info in llm.LOCAL_MODELS.items()]
    if local not in llm.LOCAL_MODELS:  # a model set in config.toml
        models.append({"repo": local, "label": local, "memory_gb": notes.notes_memory_gb(local),
                       "context_tokens": llm.LOCAL_CONTEXT_TOKENS, "note": "Set in config.toml."})
    claude_path = getattr(cfg, "claude_path", None)
    return {
        "features": [{"id": fid, **info, "choice": providers.choice(fid, default=llm.default_choice(cfg, fid)),
                      "default": llm.default_choice(cfg, fid)}
                     for fid, info in providers.FEATURES.items() if info["uses"] == providers.LANGUAGE_MODEL],
        "providers": [providers.public(pid, claude_path=claude_path, defaults=llm.provider_defaults(cfg, pid))
                      for pid in providers.language_models()],
        "local": {"model": local, "models": models},
        "log": access_log.recent(20),  # transcription's uploads too: one log of what left the Mac
        "labels": {pid: p.label for pid, p in providers.PROVIDERS.items()},
    }


def set_language_model(cfg, body: dict) -> dict[str, Any]:
    """{"use": {feature: "local" | provider}}, {"provider": id, "endpoint",
    "model", "context_tokens"} or {"local_model": repo}."""
    from .. import llm, providers

    try:
        for feature, value in (body.get("use") or {}).items():
            providers.choose(str(feature), value, claude_path=getattr(cfg, "claude_path", None),
                             defaults=llm.provider_defaults(cfg, str(value)))
        if "provider" in body:
            changes = {k: body[k] for k in ("endpoint", "model", "context_tokens", "auth") if k in body}
            providers.configure(str(body["provider"]), **changes)
        if "local_model" in body:
            llm.choose_local_model(str(body["local_model"]))
    except ValueError as exc:
        raise Refused(str(exc)) from None
    return language_model(cfg)


def set_provider_key(cfg, body: dict) -> dict[str, Any]:
    """{"provider", "key"} stores the key in the Keychain; {"provider",
    "remove": true} removes it. The answer says only whether one is set."""
    from .. import keychain, providers

    pid = str(body.get("provider"))
    try:
        if body.get("remove"):
            providers.remove_key(pid)
        else:
            providers.set_key(pid, body.get("key"))
    except (ValueError, keychain.KeychainError) as exc:
        raise Refused(str(exc)) from None
    return language_model(cfg)


def test_provider(cfg, body: dict) -> dict[str, Any]:
    """A tiny prompt to the provider: its answer and the time it took. A
    failure raises notes.NotesError with a message safe to show."""
    from .. import llm

    try:
        return llm.test(str(body.get("provider")), cfg)
    except ValueError as exc:
        raise Refused(str(exc)) from None


# --- transcription (#54) ------------------------------------------------------------------


def transcription(cfg) -> dict[str, Any]:
    """The Settings page's Transcription section: local or which service,
    what it sends, the services (never a key), what was sent this month."""
    from .. import access_log, providers
    from .. import transcription as tr

    info = providers.FEATURES[tr.FEATURE]
    return {
        "feature": {"id": tr.FEATURE, **info, "choice": providers.choice(tr.FEATURE, default=providers.LOCAL)},
        "providers": [providers.public(pid) for pid in providers.transcribers()],
        "month": tr.month(),
        "log": access_log.recent(20),
        "labels": {pid: p.label for pid, p in providers.PROVIDERS.items()},
    }


def set_transcription(cfg, body: dict) -> dict[str, Any]:
    """{"use": "local" | provider} or {"provider": id, "model", "region", "endpoint", "auth"}."""
    from .. import providers

    try:
        if "use" in body:
            providers.choose("transcription", body["use"])
        if "provider" in body:
            pid = str(body["provider"])
            if pid not in providers.transcribers():
                raise ValueError(f"no transcription service {pid!r}")
            providers.configure(pid, **{k: body[k] for k in ("endpoint", "model", "region", "auth") if k in body})
    except ValueError as exc:
        raise Refused(str(exc)) from None
    return transcription(cfg)


def set_transcription_key(cfg, body: dict) -> dict[str, Any]:
    """{"provider", "key"} or {"provider", "remove": true}, for a transcription service."""
    from .. import keychain, providers

    pid = str(body.get("provider"))
    try:
        if pid not in providers.transcribers():
            raise ValueError(f"no transcription service {pid!r}")
        if body.get("remove"):
            providers.remove_key(pid)
        else:
            providers.set_key(pid, body.get("key"))
    except (ValueError, keychain.KeychainError) as exc:
        raise Refused(str(exc)) from None
    return transcription(cfg)


def test_transcription(cfg, body: dict) -> dict[str, Any]:
    """Two seconds of a tone to the service: how long it took, what an
    hour costs. A failure raises notes.NotesError, safe to show."""
    from .. import transcription as tr

    try:
        return tr.test(str(body.get("provider")), cfg)
    except ValueError as exc:
        raise Refused(str(exc)) from None


def set_local_only(output_dir: Path, meeting_id: str, on: bool) -> None:
    from .. import llm

    llm.set_local_only(meeting_paths(output_dir, meeting_id).folder, on)


# --- the user's own notes (#44) -------------------------------------------------------------
#
# Each set of notes lives in a folder: a meeting's recording folder, or, before
# the meeting, the waiting folder of its calendar event (my_notes.prep_folder).

_MY_NOTES_LOCK = threading.Lock()  # one change to a set of notes at a time
_KNOWN_EVENTS: set[str] = set()   # calendar keys already looked up: autosave needs no calendar call


def my_notes_folder(output_dir: Path, meeting_id: str) -> Path:
    return meeting_paths(output_dir, meeting_id).folder


def prep_notes_folder(provider, key: str, now: datetime | None = None) -> Path:
    """The waiting folder of an upcoming meeting's notes; only for events
    still to come in the calendar."""
    if key not in _KNOWN_EVENTS:
        _event(provider, key, now)
        _KNOWN_EVENTS.add(key)
    return my_notes.prep_folder(key)


def adopt_prepared_notes(output_dir: Path, meeting_id: str, provider, now: datetime | None = None) -> bool:
    """While a meeting is recorded, the notes written for its calendar event
    beforehand join it, so they are there to go through during the call.
    (Once it is processed, prep.apply does the same.)"""
    paths = meeting_paths(output_dir, meeting_id)
    if provider is None or not my_notes.has_prepared() or _status(paths) != "recording":
        return False
    start = _start(paths)
    if start is None:
        return False
    start_at, now = datetime.fromisoformat(start), now or datetime.now().astimezone()
    try:
        event = calendar_events.match(provider(start_at - calendar_events.SEARCH_MARGIN,
                                               now + calendar_events.SEARCH_MARGIN), start_at, max(now, start_at))
    except Exception:  # no calendar is no reason to fail the notes
        LOGGER.debug("looking up the calendar for prepared notes failed", exc_info=True)
        return False
    if event is None or not event.key:
        return False
    with _MY_NOTES_LOCK:
        return my_notes.adopt(my_notes.prep_folder(event.key), paths.folder)


def get_my_notes(folder: Path) -> dict[str, Any]:
    return my_notes.document(folder)


def save_my_notes(folder: Path, body: dict) -> dict[str, Any]:
    """Save on the revision the editor read; my_notes.Conflict when the
    notes changed since (the server answers 409 with them as they are)."""
    if "paragraphs" not in body:
        raise ValueError("no paragraphs")
    if not isinstance(body.get("revision"), str):
        raise ValueError("no revision: a save says which notes it was based on")
    saved = my_notes.save(folder, body["paragraphs"], base=body["revision"])
    return {"saved": len(saved["paragraphs"]), "revision": saved["revision"]}


def add_my_notes_image(folder: Path, body: dict) -> dict[str, Any]:
    """A pasted or dropped image (base64 in JSON: the server takes JSON
    only). Stored in the folder, never uploaded anywhere; its text is read
    on this Mac in the background."""
    import base64
    import binascii

    try:
        data = base64.b64decode(str(body["data"]), validate=True)
    except (binascii.Error, ValueError):
        raise ValueError("the image is not base64") from None
    with _MY_NOTES_LOCK:
        name = my_notes.add_image(folder, data)
    my_notes.read_in_background(folder, name)
    return {"name": name}


def my_notes_image(folder: Path, name: str) -> tuple[bytes, str]:
    try:
        path = my_notes.image_path(folder, name)
    except (ValueError, FileNotFoundError):
        raise NotFound(name) from None
    return path.read_bytes(), my_notes.content_type(name)


def delete_my_notes_image(output_dir: Path, folder: Path, name: str) -> dict[str, Any]:
    """Delete an image from the notes, undoably."""
    with _MY_NOTES_LOCK:
        try:
            files = my_notes.image_files(folder, name)
        except (ValueError, FileNotFoundError):
            raise NotFound(name) from None
        # The image's files come back as they were; its paragraph is put back into
        # the notes as they are then (put_back), so what was typed since stays.
        with _undoable(output_dir, "my-notes image", stores=files) as token:
            removed, before = my_notes.remove_image(folder, name)
            undo.note(output_dir, token, {"folder": str(folder), "paragraphs": [removed] if removed else [],
                                          "after": before})
    return {**my_notes.document(folder), "undo": token}


def clear_my_notes(output_dir: Path, folder: Path) -> dict[str, Any]:
    """No notes any more, undoably (unless written again since)."""
    with _MY_NOTES_LOCK:
        paragraphs = my_notes.load(folder)
        images = [f for f in my_notes.files(folder) if f.name != my_notes.FILE]
        with _undoable(output_dir, "my-notes clear", stores=images) as token:
            my_notes.clear(folder)
            undo.note(output_dir, token, {"folder": str(folder), "paragraphs": paragraphs})
    return {**my_notes.document(folder), "undo": token}


def _undo_my_notes(output_dir: Path, token: str) -> None:
    """Undo of an image deleted or the notes cleared: the files back, and
    the paragraphs merged into the notes as they are now."""
    extra = undo.extra(output_dir, token)
    folder = Path(extra.get("folder", ""))
    if not extra.get("folder") or not folder.is_dir():
        raise undo.Gone(token)  # the meeting went (to the trash, into another)
    with _MY_NOTES_LOCK:
        undo.restore(output_dir, token)
        my_notes.put_back(folder, extra.get("paragraphs") or [], after=extra.get("after"))
    undo.prune(output_dir)


# --- Claude access (MCP, #45) ------------------------------------------------------------

# --- updates and uninstalling (#60): the menu bar app does both ----------------------------------

APP_GONE = "Palaver's menu bar app does not answer; open Palaver and try again."


def update_status(read: Callable[[], dict | None] | None = None) -> dict[str, Any]:
    """What the menu bar app's updater knows (update.json), for Settings."""
    from .. import updater

    status = (read or updater.read_status)() or {"state": "unsupported"}
    return {**status, "check_updates": settings.load().check_updates}


def update_action(action: str, call: Callable | None = None) -> dict[str, Any]:
    """"check": look for a release now; "install": download it and install
    it at the next idle moment (the menu bar app decides when)."""
    from .. import appctl

    if action not in ("check", "install"):
        raise Refused(f"no update action {action!r}")
    try:
        return (call or appctl.call)(f"update_{action}", {})
    except appctl.CallRefused as exc:
        raise Refused(str(exc)) from None
    except appctl.CallFailed:
        raise Refused(APP_GONE) from None


def uninstall_palaver(body: dict, call: Callable | None = None) -> dict[str, Any]:
    """{"confirm": true, "models": bool, "recordings": bool}: Palaver quits
    and is removed; recordings only when ticked."""
    from .. import appctl

    if body.get("confirm") is not True:
        raise Refused("uninstalling needs the user's confirmation")
    args = {"models": body.get("models") is True, "recordings": body.get("recordings") is True}
    try:
        return (call or appctl.call)("uninstall", args, timeout=appctl.MAIN_THREAD_TIMEOUT + 2.0)
    except appctl.CallRefused as exc:
        raise Refused(str(exc)) from None
    except appctl.CallFailed:
        raise Refused(APP_GONE) from None


def mcp_status() -> dict[str, Any]:
    """The running `palaver mcp` clients, the newest access log entries
    (newest first) and whether Claude Code starts the server."""
    return {"clients": mcp_access.clients(), "log": mcp_access.read(), "registered": mcp_access.registered(),
            "desktop": mcp_access.desktop_registered()}


def mcp_reads(meeting_id: str) -> dict[str, Any]:
    """What MCP clients read of one meeting, newest first."""
    return {"reads": mcp_access.read(meeting=meeting_id)}


def clear_mcp_log() -> dict[str, Any]:
    """Empty the access log; ``cleared``: how many calls it held, ``undo``:
    the token for restore_mcp_log (None when it was empty)."""
    cleared = len(mcp_access.read(limit=1 << 30))
    token = mcp_access.clear()
    return {**mcp_status(), "cleared": cleared, "undo": token}


def restore_mcp_log(token: str) -> dict[str, Any]:
    if not mcp_access.restore(token):
        raise undo.Gone(token)
    return mcp_status()


def install_mcp(target: str = "code", cli_options: list[str] = ()) -> dict[str, Any]:
    """Add the server to Claude Code (``target`` "code") or Claude Desktop
    ("desktop"), started with this app's Python and CLI options (--config)."""
    import sys

    if target == "desktop":
        mcp_access.install_desktop(install_layout.stable_python(), list(cli_options))
    else:
        mcp_access.install(install_layout.stable_python(), list(cli_options))
    return mcp_status()


# --- the setup assistant (#55) ------------------------------------------------------------
# What the assistant shows comes from onboarding.py (pure, tested per Mac);
# here it meets the stores. Looking changes nothing: every change below is
# the user's click.

SEED_PAST_DAYS = 30
SEED_NEXT_DAYS = 14
_SWITCHES = ("realtime", "live_processing", "search_meaning", "record_teams", "record_slack")


def setup_registry(cfg):
    """providers.FEATURES x PROVIDERS as the recommendations read them: a
    feature's kind of provider (#54 adds "transcription"), each provider's
    readiness."""
    from .. import llm, onboarding, providers

    claude_path = getattr(cfg, "claude_path", None)
    # A feature chosen on its own (the coach) is not part of the assistant's bulk choice.
    features = {f: info.get("uses", providers.LANGUAGE_MODEL) for f, info in providers.FEATURES.items()
                if not info.get("own")}
    infos = {}
    for pid, p in providers.PROVIDERS.items():
        trouble = providers.problem(pid, claude_path=claude_path, defaults=llm.provider_defaults(cfg, pid))
        infos[pid] = onboarding.ProviderInfo(p.label, frozenset(p.uses), trouble is None, trouble)
    return onboarding.Registry(features, infos)


def _setup_current(app, downloaded=None):
    from .. import llm, onboarding, providers

    reg = setup_registry(app.cfg)
    code, desktop = mcp_access.registered(), mcp_access.desktop_registered()
    mcp = {"code": bool(code.get("registered")), "desktop": bool(desktop.get("registered"))}
    return onboarding.Current(
        settings=asdict(settings.load(app.settings)),
        choices={f: providers.choice(f, default=_feature_default(app.cfg, f, reg)) for f in reg.features},
        local_model=llm.local_model(app.cfg),
        downloaded=app.probe.downloaded() if downloaded is None else downloaded,
        registry=reg, mcp=mcp, chosen=_chosen(app.cfg, reg, mcp))


def _feature_default(cfg, feature: str, registry) -> str:
    """A feature's choice when never made in Settings: config.toml's
    [notes].engine for the language models, local for transcription."""
    from .. import llm, onboarding

    return llm.default_choice(cfg, feature) if registry.features.get(feature) == onboarding.LANGUAGE_MODEL \
        else "local"


def _chosen(cfg, registry, mcp: dict) -> frozenset[str]:
    """The recommendations whose current value the user set on purpose:
    in settings.json or config.toml, or Palaver added to Claude. Re-opening
    the assistant offers to keep those."""
    from .. import llm, onboarding

    raw = settings.read_raw()
    engines = raw.get("engines") if isinstance(raw.get("engines"), dict) else {}
    out = {k for k in _SWITCHES if k in raw}
    lm = registry.features_of(onboarding.LANGUAGE_MODEL)
    if "local_model" in raw or any(f in engines for f in lm) or llm.default_choice(cfg) != "local" \
            or getattr(cfg, "notes_local_model", onboarding.GEMMA) != onboarding.GEMMA:
        out.add("language_model")
    if any(f in engines for f in registry.features_of(onboarding.TRANSCRIPTION)):
        out.add("transcription")
    out |= {f"claude_{t}" for t, on in mcp.items() if on}
    return frozenset(out)


def _hardware_dict(hw) -> dict[str, Any]:
    return {"chip": hw.chip, "short": hw.short, "memory_gb": hw.memory_gb, "free_disk_gb": round(hw.free_disk_gb, 1),
            "apple_silicon": hw.apple_silicon, "fingerprint": hw.fingerprint}


def _setup_state() -> dict[str, Any] | None:
    state = settings.read_raw().get("setup")
    return state if isinstance(state, dict) else None


def _has_meetings(output_dir: Path) -> bool:
    return output_dir.is_dir() and any(is_recording_folder_name(p.name) for p in output_dir.iterdir())


def setup_offer(app) -> dict[str, Any] | None:
    """Whether the window opens the assistant now (onboarding.offer). An
    existing user who never ran it is not asked: nothing is looked at."""
    from .. import onboarding

    state = _setup_state()
    has_meetings = _has_meetings(app.output_dir)
    if not state and has_meetings:
        return None
    hw = app.probe.hardware()
    missing = onboarding.missing_models(_setup_current(app), hw) if state and state.get("done") else []
    offer = onboarding.offer(state, hw.fingerprint, has_meetings=has_meetings, missing=missing)
    if offer and offer.get("models"):
        offer["labels"] = {m: onboarding.MODELS[m].label for m in offer["models"]}
    return offer


def setup_recommendations(app) -> dict[str, Any]:
    """For the Settings page's "Recommended for this Mac"."""
    from .. import onboarding

    hw = app.probe.hardware()
    recs = onboarding.recommend(hw, app.probe.installed(), _setup_current(app))
    return {"hardware": _hardware_dict(hw), "recommendations": [r.to_dict() for r in recs]}


def _calendar_events(calendar) -> list:
    if calendar is None:
        return []
    now = datetime.now().astimezone()
    try:
        return list(calendar(now - timedelta(days=SEED_PAST_DAYS), now + timedelta(days=SEED_NEXT_DAYS)))
    except Exception:
        LOGGER.exception("reading the calendar for the setup assistant failed")
        return []


def _profile(app, events) -> dict[str, Any]:
    from .. import onboarding

    chosen = settings.user_name()
    if chosen:
        name, source = chosen, "app"
    elif app.user_name and app.user_name != "User":
        name, source = app.user_name, "config"
    else:
        name, source = app.probe.full_name() or "", "macOS"
    orgs = organizations.Organizations()
    org = (organizations.own_org(organizations.people_index(app.output_dir), orgs, name) if name else None) \
        or onboarding.own_organization(events)
    return {"name": name, "name_from": source, "organization": org}


def setup_page(app) -> dict[str, Any]:
    """Everything the assistant shows: the checks, the recommendations, the
    downloads, what to prefill, and the summary."""
    from .. import llm, onboarding, providers

    hw = app.probe.hardware()
    installed = app.probe.installed()
    permissions = app.probe.permissions(app.output_dir)
    current = _setup_current(app)
    recs = onboarding.recommend(hw, installed, current)
    # What the choices as they are now need: after the Models step, the ones chosen there.
    needed = onboarding.missing_models(current, hw)
    if current.settings.get("search_meaning", True) and "e5" not in current.downloaded:
        needed.append("e5")
    pyannote = onboarding.MODELS["pyannote"]
    events = _calendar_events(app.calendar)
    profile = _profile(app, events)
    known = [t["term"] for t in glossary.Glossary().terms().values()]
    state = _setup_state()
    missing = onboarding.missing_models(current, hw) if state and state.get("done") else []
    return {
        "offer": onboarding.offer(state, hw.fingerprint, has_meetings=_has_meetings(app.output_dir), missing=missing),
        "state": state,
        "hardware": _hardware_dict(hw),
        "installed": asdict(installed),
        "permissions": permissions,
        "recommendations": [r.to_dict() for r in recs],
        "downloads": {"needed": [{"id": m, "label": onboarding.MODELS[m].label,
                                  "purpose": onboarding.MODELS[m].purpose,
                                  "disk_gb": onboarding.MODELS[m].disk_gb,
                                  "note": onboarding.download_note(m, hw)} for m in needed],
                      "total_gb": round(onboarding.download_size(needed), 2),
                      "free_disk_gb": round(hw.free_disk_gb, 1),
                      # pyannote's model is gated: its download needs a token (never shown, only whether set)
                      "hf_token": {"set": app.probe.hf_token_set(), "needed": app.probe.hf_token_needed(),
                                   "where": "[hf].token in ~/.config/palaver/config.toml, or HF_TOKEN",
                                   "terms": f"https://huggingface.co/{app.probe.repo_of(pyannote)}"},
                      "status": app.probe.downloads.status()},
        "profile": profile,
        "glossary": onboarding.seed_terms(events, user_name=profile["name"] or app.user_name, known=known),
        "storage": {"recordings": str(app.output_dir),
                    "retention_days": getattr(app.cfg, "retention_days", 14),
                    # The coach's own choice too (#41): not the assistant's to set, but where its text goes.
                    "cloud": [{"feature": f, "label": info["label"],
                               "choice": current.choices[f] if f in current.choices
                               else providers.choice(f, default=llm.default_choice(app.cfg, f))}
                              for f, info in providers.FEATURES.items()],
                    "autostart": app.probe.autostart()},
        "mcp": mcp_status(),
        "summary": [asdict(c) for c in onboarding.summary(hw, permissions, installed, current)],
        "test": app.probe.test.status(),
    }


def _apply_one(app, rid: str, value: Any, registry) -> None:
    from .. import llm, onboarding, providers

    if rid in _SWITCHES:
        if not isinstance(value, bool):
            raise Refused(f"{rid} must be true or false")
        settings.update({rid: value})
        return
    if rid in ("claude_code", "claude_desktop"):
        if not isinstance(value, bool):
            raise Refused(f"{rid} must be true or false")
        if value:
            install_mcp("code" if rid == "claude_code" else "desktop", app.cli_options)
        return
    kind = {"language_model": onboarding.LANGUAGE_MODEL, "transcription": onboarding.TRANSCRIPTION}.get(rid)
    if kind is None:
        raise Refused(f"nothing to set for {rid!r}")
    if not isinstance(value, str):
        raise Refused(f"no choice {value!r}")
    features = registry.features_of(kind)
    context = {"claude_path": getattr(app.cfg, "claude_path", None)}
    try:
        if value == onboarding.PENDING and kind != onboarding.LANGUAGE_MODEL:
            raise ValueError("only notes can wait for a cloud model")
        if value.startswith(f"{onboarding.LOCAL}:") and kind == onboarding.LANGUAGE_MODEL:
            llm.choose_local_model(value.split(":", 1)[1])
            value = onboarding.LOCAL
        if not features:  # e.g. transcription before #54: on this Mac, nothing to choose
            if value != onboarding.LOCAL:
                raise ValueError(f"no {rid.replace('_', ' ')} service {value!r}")
            return
        for f in features:
            providers.choose(f, value, **context, defaults=llm.provider_defaults(app.cfg, value))
    except ValueError as exc:
        raise Refused(str(exc)) from None


def apply_setup(app, body: dict) -> dict[str, Any]:
    """{"changes": {recommendation id: value}}: what the user chose in a
    step. Answers with the recommendations as they are now."""
    changes = body.get("changes")
    if not isinstance(changes, dict) or not changes:
        raise Refused("nothing to change")
    registry = setup_registry(app.cfg)
    for rid, value in changes.items():
        _apply_one(app, str(rid), value, registry)
    return setup_recommendations(app)


def setup_profile(app, body: dict) -> dict[str, Any]:
    """{"name", "organization"}: the user's name (settings.json, which wins
    over config.toml) and their organization (organizations.json)."""
    name = body.get("name")
    if not isinstance(name, str) or not name.strip() or len(name) > 120 or any(c in name for c in "\r\n\0"):
        raise Refused("your name must be one line of text")
    name = name.strip()
    before = settings.user_name() or app.user_name
    aliases = [a for a in settings.user_aliases() if a.casefold() != name.casefold()]
    if before and before != "User" and before.casefold() != name.casefold() \
            and before.casefold() not in {a.casefold() for a in aliases}:
        aliases.append(before)  # earlier meetings show the old name: it stays "me"
    settings.update({"user_name": name, "user_aliases": aliases})
    app.user_name = name
    org = body.get("organization")
    if isinstance(org, str):
        orgs = organizations.Organizations()
        orgs.set_person(name, org.strip() or None)
        orgs.save()
    return {"name": name, "organization": organizations.Organizations().person(name)}


def seed_glossary(app, body: dict) -> dict[str, Any]:
    """{"terms": [...]}: add the calendar's names the user ticked to the
    glossary, undoable."""
    terms = [t.strip() for t in body.get("terms") or [] if isinstance(t, str) and t.strip()]
    if not terms:
        return {"added": 0, "undo": None}
    app.output_dir.mkdir(parents=True, exist_ok=True)
    before = set(glossary.Glossary().terms())

    def add(g: glossary.Glossary) -> None:
        for t in terms:
            g.add(t)

    with _undoable(app.output_dir, "glossary from the calendar", stores=_store_paths("glossary")) as token:
        change_glossary(app.output_dir, add)
    return {"added": len(set(glossary.Glossary().terms()) - before), "undo": token}


def setup_autostart(app, body: dict) -> dict[str, Any]:
    on = body.get("on")
    if not isinstance(on, bool):
        raise Refused("on must be true or false")
    app.probe.set_autostart(on)
    return {"autostart": app.probe.autostart()}


def finish_setup(app, body: dict) -> dict[str, Any]:
    """{"how": "done" | "skipped"}: remembered with this Mac, so a new Mac
    (or a missing model) offers the assistant again."""
    how = body.get("how")
    if how not in ("done", "skipped"):
        raise Refused('how must be "done" or "skipped"')
    state = {how: datetime.now().astimezone().isoformat(timespec="seconds"),
             "hardware": app.probe.hardware().fingerprint}
    settings.update({"setup": state})
    return {"state": state}


def setup_downloads(app) -> dict[str, Any]:
    return app.probe.downloads.status()


def start_downloads(app, body: dict) -> dict[str, Any]:
    """{"models": [...]}: the downloads the user agreed to, in the background."""
    ids = body.get("models")
    if not isinstance(ids, list) or not ids:
        raise Refused("no models to download")
    try:
        return app.probe.downloads.start([str(i) for i in ids])
    except ValueError as exc:
        raise Refused(str(exc)) from None


def _recording_now(recording) -> bool:
    now = getattr(recording, "recording", None)
    if callable(now):
        try:
            return now() is not None
        except Exception:
            return True
    return busy_recording(recording)


def _test_mode(app) -> dict[str, Any]:
    """How the test may transcribe the mic track: with Parakeet on this Mac
    when it is there (never downloaded for the test), or not at all when a
    cloud service transcribes the calls (the test sends nothing)."""
    from .. import onboarding, providers

    reg = setup_registry(app.cfg)
    tr = reg.features_of(onboarding.TRANSCRIPTION)
    chosen = providers.choice(tr[0], default="local") if tr else "local"
    if chosen != "local":
        return {"transcribe": "cloud", "service": providers.PROVIDERS[chosen].label}
    return {"transcribe": "local", "repo": app.probe.repo_of(onboarding.MODELS["parakeet"])}


def setup_test(app, body: dict) -> dict[str, Any]:
    """The test recording: {"action": "start"} or {"action": "stop"} (the
    user's click); without one, how it is going."""
    action = body.get("action")
    if action == "start":
        try:
            return app.probe.test.start(busy=lambda: _recording_now(app.recording), mode=_test_mode(app))
        except ValueError as exc:
            raise Refused(str(exc)) from None
    if action == "stop":
        return app.probe.test.stop()
    if action is not None:
        raise Refused('action must be "start" or "stop"')
    return app.probe.test.status()


# --- Report a Problem and usage (#59) -------------------------------------------------------

MAX_USAGE_EVENTS = 200
_USAGE_FIELDS = ("text", "from")


def create_report(app, body: dict) -> dict[str, Any]:
    """The report zip on the Desktop, shown in Finder (report.py); its path and size."""
    from .. import report

    form = report.Form.from_dict(body)
    LOGGER.info("writing a problem report (%s, meeting %s, audio %s)", form.kind, form.meeting, form.audio)
    result = report.create(form, output_dir=app.output_dir, config_path=report.config_path_from(app.cli_options),
                           via="window")
    report.reveal(Path(result["path"]))
    LOGGER.info("problem report written: %s (%s)", result["path"], report.size_text(result["size"]))
    home = str(Path.home())
    shown = "~" + result["path"][len(home):] if result["path"].startswith(home + "/") else result["path"]
    return {**result, "size_text": report.size_text(result["size"]), "shown": shown}


def record_usage(body: dict) -> dict[str, Any]:
    """What the page counted (actions, views, tabs, ⌘K, errors shown) and, at
    its start, its catalog of features. Anything else is left out."""
    from .. import usage

    events = body.get("events") or []
    if not isinstance(events, list):
        raise ValueError("events is a list")
    for e in events[:MAX_USAGE_EVENTS]:
        if not isinstance(e, dict) or e.get("kind") not in usage.PAGE_KINDS:
            continue
        extra = {k: e[k] for k in _USAGE_FIELDS if isinstance(e.get(k), str)}
        usage.record(e["kind"], str(e.get("id") or "")[:80] or None, **extra)
    if isinstance(body.get("catalog"), dict):
        usage.save_catalog(body["catalog"])
    return {"ok": True}


def count_setting(path: str, body: dict) -> None:
    """A setting changed in the window: which one, never a secret (usage.setting_events)."""
    from .. import usage

    for e in usage.setting_events(path, body):
        usage.record("setting", **e)
