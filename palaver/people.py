"""People across meetings (issue #22).

Every diarized speaker has a voice embedding per meeting. Named speakers
teach the voice bank (voices.py); this module applies what the bank knows to
all meetings, not only the one being processed:

- ``refresh_recognition`` re-runs recognition in every meeting, so naming
  someone once names their voice in earlier meetings too (as "recognized by
  voice", which a name given by hand always overrides);
- ``directory`` lists the named people with their meetings, and voices that
  recur in several meetings without a name yet;
- ``name_voices`` and ``rename_person`` change names in all meetings at once.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from . import calendar_events, shared_mic
from .models import SpeakerTurn
from .paths import RecordingPaths, is_recording_folder_name
from .speakers import (
    load_ignored,
    load_inferred_names,
    load_merges,
    load_recognized_names,
    load_rejected_names,
    load_speaker_names,
    merged_turns,
    save_speaker_names,
    talk_seconds,
)
from .store_lock import meeting_lock
from .voices import MATCH_THRESHOLD, MIN_TALK_SECONDS, SUGGEST_THRESHOLD, VoiceBank, recognize, said_not

# Unnamed voices this similar (average over the group) count as one person.
GROUP_THRESHOLD = 0.75


@dataclass(frozen=True)
class Voice:
    meeting: str
    label: str
    talk_seconds: float
    embedding: np.ndarray  # unit length
    name: str | None
    named_by: str | None  # "you" | "voice" | None


def _meetings(output_dir: Path) -> list[RecordingPaths]:
    if not output_dir.is_dir():
        return []
    return [
        RecordingPaths(f) for f in sorted(output_dir.iterdir())
        if f.is_dir() and is_recording_folder_name(f.name) and (f / "system_turns.json").exists()
    ]


def _turns(paths: RecordingPaths) -> list[SpeakerTurn]:
    """The meeting's speaker turns, merged labels under the label they
    were merged into. None yet while a meeting has just started."""
    try:
        turns = [SpeakerTurn.from_dict(d) for d in json.loads(paths.system_turns.read_text())]
    except FileNotFoundError:
        return []
    return merged_turns(turns, load_merges(paths))


def _embeddings(paths: RecordingPaths) -> dict[str, list[float]]:
    """Voice per label; merged-away labels have none of their own, and
    voices removed as noise or several people's (#56) don't count."""
    try:
        embeddings = json.loads(paths.speaker_embeddings.read_text())
    except (OSError, ValueError):
        return {}
    skip = set(load_merges(paths)) | load_ignored(paths) | shared_mic.shared_labels(paths)
    return {label: v for label, v in embeddings.items() if label not in skip}


def _naming(paths: RecordingPaths) -> dict[str, tuple[str, str]]:
    """label → (name, "you" | "voice" | "inferred"); a name given by hand
    wins, then one recognized by voice. Merged-away labels are left out:
    they count as the label they joined."""
    out = {label: (name, "inferred") for label, name in load_inferred_names(paths).items()}
    out.update({label: (name, "voice") for label, (name, _) in load_recognized_names(paths).items()})
    for label, name in load_speaker_names(paths).items():
        if name == label:  # a recognized name rejected by hand
            out.pop(label, None)
        else:
            out[label] = (name, "you")
    skip = set(load_merges(paths)) | load_ignored(paths) | shared_mic.shared_labels(paths)
    return {label: named for label, named in out.items() if label not in skip}


def voices(output_dir: Path) -> list[Voice]:
    """Speakers with enough talk for their voice to be compared."""
    out = []
    for paths in _meetings(output_dir):
        talk = talk_seconds(_turns(paths))
        naming = _naming(paths)
        for label, vector in _embeddings(paths).items():
            v = np.asarray(vector, dtype=float)
            if talk.get(label, 0.0) < MIN_TALK_SECONDS or not np.isfinite(v).all() or not v.any():
                continue
            name, by = naming.get(label, (None, None))
            out.append(Voice(paths.folder.name, label, talk[label], v / np.linalg.norm(v), name, by))
    return out


def _groups(items: list[Voice], threshold: float) -> list[list[Voice]]:
    """Average-linkage clusters of voices at least ``threshold`` similar."""
    if len(items) < 2:
        return [items] if items else []
    from scipy.cluster.hierarchy import fcluster, linkage

    z = linkage(np.stack([v.embedding for v in items]), "average", metric="cosine")
    found: dict[int, list[Voice]] = {}
    for v, cluster in zip(items, fcluster(z, t=1 - threshold, criterion="distance")):
        found.setdefault(int(cluster), []).append(v)
    return list(found.values())


def directory(output_dir: Path, me: set[str] = frozenset()) -> dict[str, list[dict]]:
    """Named people with the meetings they spoke in, and unnamed voices that
    recur in more than one meeting, most talk first. ``me``: the user's
    names, casefolded (an earlier one too, #55): their entry says "you"."""
    people: dict[str, dict] = {}
    for paths in _meetings(output_dir):
        talk = talk_seconds(_turns(paths))
        for label, (name, by) in sorted(_naming(paths).items()):
            person = people.setdefault(name.casefold(), {"name": name, "meetings": [], "talk_seconds": 0.0})
            person["meetings"].append({"id": paths.folder.name, "label": label,
                                       "talk_seconds": round(talk.get(label, 0.0), 1), "named_by": by})
            person["talk_seconds"] = round(person["talk_seconds"] + talk.get(label, 0.0), 1)
    samples = {name.casefold(): n for name, n in VoiceBank().names().items()}
    for key, person in people.items():
        person["voice_samples"] = samples.get(key, 0)
        person["you"] = key in me

    unknown = []
    for group in _groups([v for v in voices(output_dir) if v.name is None], GROUP_THRESHOLD):
        if len({v.meeting for v in group}) < 2:
            continue
        unknown.append({
            "voices": [{"meeting": v.meeting, "label": v.label, "talk_seconds": round(v.talk_seconds, 1)}
                       for v in sorted(group, key=lambda v: v.meeting)],
            "talk_seconds": round(sum(v.talk_seconds for v in group), 1),
        })
    return {
        "people": sorted(people.values(), key=lambda p: -p["talk_seconds"]),
        "unknown": sorted(unknown, key=lambda g: -g["talk_seconds"]),
    }


def rejected_voices(output_dir: Path) -> list[tuple[str, np.ndarray]]:
    """Every voice the user said is not someone ("Not Tom"): (name, voice).
    Negative evidence for recognition and inference in all meetings."""
    out = []
    for paths in _meetings(output_dir):
        rejected = load_rejected_names(paths)
        if not rejected:
            continue
        embeddings = _embeddings(paths)
        for label, names in rejected.items():
            vector = np.asarray(embeddings.get(label, []), dtype=float)
            if vector.size and np.isfinite(vector).all() and vector.any():
                out += [(name, vector / np.linalg.norm(vector)) for name in names]
    return out


def refresh_recognition(output_dir: Path, bank: VoiceBank | None = None, *, user_name: str = "") -> int:
    """Recognize the bank's voices in every meeting, then infer the names
    that follow (inference.py); rewrite the transcripts whose names changed.
    Returns how many changed."""
    from . import inference

    bank = bank or VoiceBank()
    changed = 0
    rejected = rejected_voices(output_dir)
    for paths in _meetings(output_dir):
        embeddings = _embeddings(paths)
        if not embeddings or not paths.transcript_json.exists():
            continue
        invited = calendar_events.invited_names(paths, list(bank.names()))
        found = recognize(embeddings, talk_seconds(_turns(paths)), bank, invited=invited, rejected=rejected)
        auto = {label: {"name": name, "similarity": round(sim, 3)} for label, (name, sim) in found.items()}
        with meeting_lock(paths.folder):
            try:
                before = json.loads(paths.speakers_auto.read_text())
            except (OSError, ValueError):
                before = {}
            if {k: v["name"] for k, v in auto.items()} == {k: v["name"] for k, v in before.items()}:
                continue
            paths.speakers_auto.write_text(json.dumps(auto, indent=2, ensure_ascii=False))
        # Outside the meeting's lock: saving the names learns voices, which takes the bank's.
        save_speaker_names(paths, load_speaker_names(paths), bank)
        changed += 1
    return changed + inference.refresh(output_dir, user_name=user_name, bank=bank)


def name_voices(output_dir: Path, members: list[tuple[str, str]], name: str) -> None:
    """Name the speakers ``(meeting, label)`` — e.g. one recurring voice in
    several meetings — then recognize the voice everywhere else."""
    bank = VoiceBank()
    by_meeting: dict[str, list[str]] = {}
    for meeting, label in members:
        by_meeting.setdefault(meeting, []).append(label)
    for meeting, labels in by_meeting.items():
        paths = RecordingPaths(output_dir / meeting)
        names = load_speaker_names(paths)
        names.update({label: name for label in labels})
        save_speaker_names(paths, names, bank)
    refresh_recognition(output_dir, bank)


def rename_person(output_dir: Path, old: str, new: str) -> None:
    """``old`` is called ``new`` from now on, in every meeting and in the
    voice bank; renaming onto an existing name merges the two people."""
    bank = VoiceBank()
    bank.rename(old, new)
    for paths in _meetings(output_dir):
        with meeting_lock(paths.folder):
            rejected = load_rejected_names(paths)
            moved = {label: list(dict.fromkeys(new if n.casefold() == old.casefold() else n for n in ns))
                     for label, ns in rejected.items()}
            if moved != rejected:  # "not Tom" is "not Thomas Berg" now
                paths.speakers_rejected.write_text(json.dumps(moved, indent=2, ensure_ascii=False))
        names = load_speaker_names(paths)
        renamed = {label: (new if name.casefold() == old.casefold() else name) for label, name in names.items()}
        if renamed != names:
            save_speaker_names(paths, renamed, bank)
    refresh_recognition(output_dir, bank)


def suggestions(paths: RecordingPaths, bank: VoiceBank | None = None) -> dict[str, list[tuple[str, float]]]:
    """For speakers without a name: people whose voice is close, but not
    close enough to name them automatically."""
    bank = bank or VoiceBank()
    talk = talk_seconds(_turns(paths))
    naming = _naming(paths)
    not_them = load_rejected_names(paths)
    rejected = rejected_voices(paths.folder.parent)  # this voice, or one like it elsewhere
    out = {}
    for label, vector in _embeddings(paths).items():
        if label in naming or talk.get(label, 0.0) < MIN_TALK_SECONDS:
            continue
        no = {n.casefold() for n in not_them.get(label, [])}
        close = [(name, round(sim, 2)) for sim, name in bank.scores(vector)
                 if SUGGEST_THRESHOLD <= sim < MATCH_THRESHOLD and name.casefold() not in no
                 and not said_not(name, vector, rejected, sim)]
        if close:
            out[label] = close[:2]
    return out
