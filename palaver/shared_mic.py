"""Speakers that can't be separated (#56): an All Hands on one room
microphone, a meeting room joined to the call through one device, an
in-person meeting recorded with the laptop's microphone.

Diarization still splits such a track into clusters, but the clusters mix
people, so any name given to one is a confident guess. The user says so,
and Palaver stops guessing there:

- for the whole meeting, every voice on the system track is "Several
  people"; without speech on the system track (in person) the microphone
  is a room too;
- for one lane, it is a room: "Room", or "Room (Raum 3.12)";
- for the microphone, several people sit at it with the user: its lines
  are "Room (with you)", not the user's.

Such a lane gets no name suggested, recognized or inferred, teaches the
voice bank nothing, and the coach leaves out what it can no longer tell.
Marks live in ``speakers_shared.json``; the whole-meeting mark can be
remembered for a recurring event, so its next meetings start out marked.

Detection only ever suggests the mark (``suggestion``): calendar titles
and rooms, and many invitees with few voices, are hints, never proof.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from .paths import RecordingPaths

ROOM = "Room"
SEVERAL = "Several people"
WITH_YOU = "with you"
MIC = "mic"  # the label of the microphone's lane in the marks and the API
LINE = "Several people shared one microphone here, so lines aren't assigned to people."
NAME_LENGTH = 80  # a room's name, at most

# Events where one microphone is usually shared by many.
GATHERING = re.compile(r"\b(all[\s-]?hands|town[\s-]?halls?|all[\s-]?staff|company[\s-]meeting|"
                       r"betriebsversammlung|(?:mitarbeiter|belegschafts|voll)versammlung)\b", re.IGNORECASE)
# A location that is a meeting room ("Raum 3.12", "Besprechungsraum", "Conference Room").
ROOM_LOCATION = re.compile(r"(room|raum)\b|\bmeeting ?room|\bkonferenz", re.IGNORECASE)
# Many invitees but few voices: at least this many invited ...
MANY_INVITEES = 8
# ... and at most this share of them heard as voices of their own.
FEW_VOICES_SHARE = 0.25


def room_text(name: str = "") -> str:
    return f"{ROOM} ({name})" if name.strip() else ROOM


def _names(value: Any) -> dict[str, str]:
    return {str(k): str(v or "") for k, v in value.items()} if isinstance(value, dict) else {}


def load(paths: RecordingPaths) -> dict[str, Any]:
    """The marks: ``meeting``, ``lanes`` (label → room name), ``mic`` (the
    room's name, present while marked), ``names`` (the names of rooms marked
    before, for when they are marked again) and the suggestion ``dismissed``."""
    try:
        data = json.loads(paths.speakers_shared.read_text())
    except (OSError, ValueError):
        data = {}
    if not isinstance(data, dict):
        data = {}
    data["lanes"] = _names(data.get("lanes"))
    data["names"] = _names(data.get("names"))
    if "mic" in data:
        data["mic"] = str(data["mic"] or "")
    return data


def save(paths: RecordingPaths, data: dict[str, Any]) -> None:
    data = {k: v for k, v in data.items() if v not in ({}, None) and not (k == "dismissed" and v is False)}
    if not data:
        paths.speakers_shared.unlink(missing_ok=True)
        return
    tmp = paths.speakers_shared.with_name(paths.speakers_shared.name + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    tmp.replace(paths.speakers_shared)


def meeting_marked(paths: RecordingPaths) -> bool:
    return load(paths).get("meeting") is True


def from_series(paths: RecordingPaths) -> bool:
    """Marked because the event's series is remembered, not by hand here."""
    data = load(paths)
    return data.get("meeting") is True and data.get("from_series") is True


def set_meeting(paths: RecordingPaths, on: bool) -> None:
    """The whole meeting's voices can't be told apart, or (``on=False``) they
    can after all; that stays so, also for a series that is remembered."""
    data = load(paths)
    data["meeting"] = bool(on)
    data.pop("from_series", None)
    save(paths, data)


def set_lane(paths: RecordingPaths, label: str, on: bool, name: str | None = None) -> None:
    """``label`` (or MIC, the microphone) is a room of several people, or
    one voice after all. Without a ``name`` a room marked again gets the
    name it had."""
    data = load(paths)
    if label == MIC:
        current = data.pop("mic", None)
    else:
        current = data["lanes"].pop(label, None)
    if on:
        name = (data["names"].pop(label, "") if name is None else name).strip()[:NAME_LENGTH]
        data["names"].pop(label, None)
        if label == MIC:
            data["mic"] = name
        else:
            data["lanes"][label] = name
    elif current:
        data["names"][label] = current
    save(paths, data)


def forget_lanes(paths: RecordingPaths) -> None:
    """The lanes' labels mean other voices now (diarized again); the
    microphone is still the microphone."""
    data = load(paths)
    data["lanes"], data["names"] = {}, {k: v for k, v in data["names"].items() if k == MIC}
    save(paths, data)


def split_part(data: dict[str, Any], labels: set[str], *, head: bool) -> dict[str, Any]:
    """The marks of one part of a split recording (``data``: the whole's):
    each part keeps the rooms among its own voices. The rest is the
    meeting's: the head keeps it; the tail starts without (its own event
    decides a series mark)."""
    lanes = {k: v for k, v in data.get("lanes", {}).items() if k in labels}
    names = {k: v for k, v in data.get("names", {}).items() if k in labels or (head and k == MIC)}
    if not head:
        return {"lanes": lanes, "names": names}
    return {**data, "lanes": lanes, "names": names}


def join_from(paths: RecordingPaths, data: dict[str, Any], relabel: dict[str, str]) -> None:
    """Another recording's marks (``data``) joined into this one, its labels
    ``relabel``-ed. A room in either part stays a room."""
    own = load(paths)
    own["lanes"].update({relabel.get(k, k): v for k, v in data.get("lanes", {}).items()})
    for k, v in data.get("names", {}).items():
        own["names"].setdefault(relabel.get(k, k), v)
    if "mic" in data and "mic" not in own:
        own["mic"] = data["mic"]
    for key in ("meeting", "from_series", "dismissed"):
        if key not in own and key in data:
            own[key] = data[key]
    save(paths, own)


def follow_merges(paths: RecordingPaths) -> None:
    """A room merged into a voice makes that voice the room: degrading
    honestly beats a wrong name. The room's name goes along when the
    voice's room has none."""
    from .speakers import load_merges

    data = load(paths)
    changed = False
    for label, into in load_merges(paths).items():
        if label in data["lanes"] and (into not in data["lanes"] or not data["lanes"][into] and data["lanes"][label]):
            data["lanes"][into] = data["lanes"][label]
            changed = True
    if changed:
        save(paths, data)


def room_names(paths: RecordingPaths) -> dict[str, str]:
    """label → the room's name ("" when it has none), for lanes marked by hand."""
    return load(paths)["lanes"]


def _turns(paths: RecordingPaths) -> list[dict]:
    try:
        turns = json.loads(paths.system_turns.read_text())
    except (OSError, ValueError):
        return []
    return turns if isinstance(turns, list) else []


def _labels(paths: RecordingPaths) -> set[str]:
    out = {str(d["speaker"]) for d in _turns(paths) if isinstance(d, dict) and "speaker" in d}
    try:
        out |= {str(k) for k in json.loads(paths.speaker_embeddings.read_text())}
    except (OSError, ValueError, TypeError):
        pass
    return out


def display(paths: RecordingPaths, labels: set[str] | None = None) -> dict[str, str]:
    """label → what to show instead of a person, for every voice of the
    system track that can't be told apart. A label merged into a room is
    that room, and a room merged into a voice keeps it a room."""
    if not paths.speakers_shared.exists():
        return {}
    from .speakers import load_merges

    data = load(paths)
    merges = load_merges(paths)
    lanes = data["lanes"]
    out = {}
    for label in labels if labels is not None else _labels(paths):
        into = merges.get(label, label)
        sources = [k for k, v in merges.items() if v == into and k in lanes]
        if data.get("meeting") is True:
            out[label] = SEVERAL
        elif into in lanes or label in lanes or sources:
            names = [lanes.get(into, ""), lanes.get(label, ""), *(lanes[k] for k in sources)]
            out[label] = room_text(next((n for n in names if n), ""))
    return out


def shared_labels(paths: RecordingPaths) -> set[str]:
    return set(display(paths))


def system_speech(paths: RecordingPaths) -> bool:
    """Whether anyone spoke on the system track: a call. Without it the
    recording is of the room around the Mac (in person)."""
    from .speakers import load_ignored
    from .voices import MIN_TALK_SECONDS

    ignored = load_ignored(paths)
    talk = sum(float(d["end"]) - float(d["start"]) for d in _turns(paths)
               if isinstance(d, dict) and d.get("speaker") not in ignored)
    return talk >= MIN_TALK_SECONDS


def mic_room(paths: RecordingPaths) -> str | None:
    """The room's name when several people sat at the microphone ("" when
    it has none): marked so, or the whole meeting marked in person. None:
    the microphone is the user's."""
    if not paths.speakers_shared.exists():
        return None
    data = load(paths)
    if "mic" in data:
        return data["mic"]
    if data.get("meeting") is True and not system_speech(paths):
        return ""
    return None


def mic_display(paths: RecordingPaths) -> str | None:
    """What the microphone's lines show instead of the user's name: "Room
    (with you)", or the room's name; None while they are the user's."""
    room = mic_room(paths)
    return None if room is None else room_text(room or WITH_YOU)


def marked(paths: RecordingPaths) -> bool:
    """Whether any voice of the meeting is marked as several people now."""
    return bool(display(paths)) or mic_room(paths) is not None


def shown(paths: RecordingPaths, utterances: list) -> list:
    """``utterances`` as they are shown and summarized: the microphone's lines
    as the room, while several people sat at it (transcript.json keeps the
    user's name on them, so they stay the microphone's lines)."""
    return mic_lines(utterances, mic_display(paths), _labels(paths))


def mic_lines(utterances: list, display_name: str | None, labels: set[str]) -> list:
    """``utterances`` with the microphone's lines (no diarization label)
    shown as ``display_name``: lines kept, speaker replaced."""
    if display_name is None:
        return utterances
    from .models import Utterance

    return [Utterance(display_name, u.start, u.end, u.text, label=None, heard=u.heard, unsure=u.unsure)
            if u.label is None and u.speaker not in labels else u for u in utterances]


# --- a recurring event remembered -------------------------------------------------


def _series_path() -> Path:
    from ._xdg import xdg_config_home

    return xdg_config_home() / "palaver" / "shared-series.json"


def _series() -> dict[str, Any]:
    try:
        data = json.loads(_series_path().read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def can_remember(event) -> bool:
    """Only a recurring event with an id has next meetings to mark."""
    return event is not None and bool(event.series) and bool(event.series_id)


def remembered(event) -> bool:
    return can_remember(event) and event.series_id in _series()


def remember(event, on: bool) -> None:
    """Every next meeting of ``event``'s series starts out marked (or no
    longer does)."""
    if not can_remember(event):
        raise ValueError("only a recurring calendar event can be remembered")
    data = _series()
    if on:
        data[event.series_id] = {"title": event.title}
    else:
        data.pop(event.series_id, None)
    path = _series_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    tmp.replace(path)


def apply_series(paths: RecordingPaths, event) -> bool:
    """Mark a meeting whose event is of a remembered series, unless the user
    already said for this meeting; a mark that came from a series goes when
    the meeting's event is no longer of a remembered one. Returns whether
    the meeting is marked from its series now."""
    data = load(paths)
    if data.get("from_series") and not remembered(event):
        data.pop("meeting", None)
        data.pop("from_series", None)
        save(paths, data)
        return False
    if "meeting" in data or not remembered(event):
        return bool(data.get("from_series"))
    data["meeting"] = True
    data["from_series"] = True
    save(paths, data)
    return True


# --- suggesting the mark ------------------------------------------------------------


def signals(paths: RecordingPaths, event, *, user_name: str = "") -> dict[str, Any]:
    """The cheap hints that one microphone was shared: logged for every
    meeting, to calibrate the thresholds on real recordings later."""
    from .calendar_events import candidates
    from .speakers import load_ignored, load_merges, merged_turns, talk_seconds
    from .models import SpeakerTurn
    from .voices import MIN_TALK_SECONDS

    try:
        turns = [SpeakerTurn.from_dict(d) for d in json.loads(paths.system_turns.read_text())]
    except (OSError, ValueError):
        turns = []
    ignored = load_ignored(paths)
    talk = talk_seconds(merged_turns(turns, load_merges(paths)))
    voices = sum(1 for label, t in talk.items() if t >= MIN_TALK_SECONDS and label not in ignored)
    invitees = len(candidates(event, user_name=user_name)) if event is not None else 0
    room = event is not None and (any(a.is_room for a in event.attendees)
                                  or bool(ROOM_LOCATION.search(event.location or "")))
    return {
        "gathering": event is not None and bool(GATHERING.search(event.title or "")),
        "room": room,
        "invitees": invitees,
        "voices": voices,
        "few_voices": invitees >= MANY_INVITEES and voices <= invitees * FEW_VOICES_SHARE,
    }


def dismiss_suggestion(paths: RecordingPaths, dismissed: bool = True) -> None:
    data = load(paths)
    data["dismissed"] = bool(dismissed)
    save(paths, data)


def suggestion(paths: RecordingPaths, event, *, user_name: str = "") -> dict[str, str] | None:
    """Why the meeting may be one where voices can't be told apart, when the
    hints are strong: an All Hands or Town Hall, or a meeting room with many
    invitees but few voices. A meeting room alone is not (rooms are booked
    for calls everyone joins on their own), nor are many quiet invitees (a
    webinar). None once the user marked anything or said no."""
    data = load(paths)
    if data.get("dismissed") or "meeting" in data or data.get("lanes"):
        return None
    found = signals(paths, event, user_name=user_name)
    if found["gathering"]:
        return {"why": f"The calendar calls it “{event.title}”."}
    if found["room"] and found["few_voices"]:
        return {"why": f"A meeting room was booked, and {found['invitees']} people were invited "
                       f"but only {found['voices']} voices were heard."}
    return None
