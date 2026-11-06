"""Voice bank and automatic speaker recognition (issue #13).

Voice embeddings are biometric data. They live only on this machine, in
``~/.config/palaver/voices/`` (one JSON file per person), are
added only when you name a speaker in ``rename``, and are removed with
``palaver voices forget <name>``.

Recognition compares each diarized speaker's voice embedding (256 floats from the engine) with every
stored sample (cosine similarity, best sample per person). Thresholds are
conservative because a wrong name is worse than an unnamed speaker. Across
eleven real meetings (2026-10), different speakers in one meeting scored
0.17 typically and up to 0.76 (the top ones likely one person split in two);
the same person in two meetings scored 0.80-0.96.
"""

from __future__ import annotations

import json
import re
from datetime import datetime
from pathlib import Path

import numpy as np

from ._xdg import xdg_config_home

MATCH_THRESHOLD = 0.75
MATCH_MARGIN = 0.1
# Below MATCH_THRESHOLD but this close: offered as a suggestion, not applied.
SUGGEST_THRESHOLD = 0.65
# A voice the user said is not someone counts against that person for voices
# at least this alike (and more alike than the person's own samples): the
# same person in two meetings scores 0.80-0.96, different people up to 0.76.
REJECT_SIMILAR = 0.75
# Embeddings of speakers with less talk time than this are too noisy to
# enrol or to recognize.
MIN_TALK_SECONDS = 10.0
MAX_SAMPLES_PER_PERSON = 20


def _slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "speaker"


def _unit(vector) -> np.ndarray:
    v = np.asarray(vector, dtype=float)
    norm = np.linalg.norm(v)
    return v / norm if norm else v


class VoiceBank:
    def __init__(self, directory: Path | None = None):
        self._dir = directory or xdg_config_home() / "palaver" / "voices"

    def _people(self) -> dict[str, tuple[Path, dict]]:
        people = {}
        if self._dir.is_dir():
            for f in sorted(self._dir.glob("*.json")):
                data = json.loads(f.read_text())
                people[data["name"]] = (f, data)
        return people

    def _find(self, name: str) -> tuple[Path, dict] | None:
        for person, entry in self._people().items():
            if person.casefold() == name.casefold():
                return entry
        return None

    def names(self) -> dict[str, int]:
        """Enrolled people and their number of voice samples."""
        return {name: len(data["samples"]) for name, (_, data) in self._people().items()}

    def add(self, name: str, embedding: list[float], *, source: str) -> bool:
        """Store a voice sample; ``source`` (recording:label) dedupes repeats."""
        found = self._find(name)
        if found is None:
            path, data = self._dir / f"{_slug(name)}.json", {"name": name, "samples": []}
            while path.exists():
                path = path.with_name(path.stem + "-1.json")
        else:
            path, data = found
        if any(s["source"] == source for s in data["samples"]):
            return False
        data["samples"].append({
            "embedding": [float(x) for x in embedding],
            "source": source,
            "added": datetime.now().astimezone().isoformat(timespec="seconds"),
        })
        data["samples"] = data["samples"][-MAX_SAMPLES_PER_PERSON:]
        self._dir.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, ensure_ascii=False))
        return True

    def owner(self, source: str) -> str | None:
        """Whose sample came from ``source`` (recording:label)."""
        for name, (_, data) in self._people().items():
            if any(s["source"] == source for s in data["samples"]):
                return name
        return None

    def remove_source(self, source: str) -> bool:
        """Take back a sample, e.g. when a speaker was named wrongly. A person
        left without samples is removed."""
        removed = False
        for _name, (path, data) in self._people().items():
            kept = [s for s in data["samples"] if s["source"] != source]
            if len(kept) == len(data["samples"]):
                continue
            removed = True
            if kept:
                path.write_text(json.dumps({**data, "samples": kept}, ensure_ascii=False))
            else:
                path.unlink()
        return removed

    def size(self) -> int | None:
        """How many numbers a stored voice has (the voice model's); None when empty."""
        for _name, (_path, data) in self._people().items():
            for sample in data["samples"]:
                return len(sample["embedding"])
        return None

    def remove_meeting(self, meeting_id: str) -> int:
        """Take back every sample learned from one meeting (an import undone)."""
        removed = 0
        for _name, (path, data) in self._people().items():
            kept = [s for s in data["samples"] if not str(s["source"]).startswith(f"{meeting_id}:")]
            if len(kept) == len(data["samples"]):
                continue
            removed += len(data["samples"]) - len(kept)
            if kept:
                path.write_text(json.dumps({**data, "samples": kept}, ensure_ascii=False))
            else:
                path.unlink()
        return removed

    def forget(self, name: str) -> bool:
        found = self._find(name)
        if found is None:
            return False
        found[0].unlink()
        return True

    def rename(self, old: str, new: str) -> bool:
        """Give ``old``'s samples to ``new``; merges when ``new`` exists."""
        found = self._find(old)
        if found is None:
            return False
        path, data = found
        target = self._find(new)
        if target is not None and target[0] == path:  # only the spelling changes
            path.write_text(json.dumps({**data, "name": new}, ensure_ascii=False))
            return True
        for sample in data["samples"]:
            self.add(new, sample["embedding"], source=sample["source"])
        path.unlink()
        return True

    def scores(self, embedding: list[float]) -> list[tuple[float, str]]:
        """(similarity, name) per person, best first."""
        query = _unit(embedding)
        return sorted(
            (
                (max(float(_unit(s["embedding"]) @ query) for s in data["samples"]), name)
                for name, (_, data) in self._people().items()
                if data["samples"]
            ),
            reverse=True,
        )

    def match(self, embedding: list[float]) -> tuple[str, float] | None:
        """Best-matching person, if clearly above threshold and runner-up."""
        scores = self.scores(embedding)
        if not scores or scores[0][0] < MATCH_THRESHOLD:
            return None
        if len(scores) > 1 and scores[0][0] - scores[1][0] < MATCH_MARGIN:
            return None
        return scores[0][1], scores[0][0]


def said_not(name: str, embedding, rejected, alike: float = 0.0) -> bool:
    """The user said a voice like ``embedding`` is not ``name``: one of the
    ``rejected`` voices (name, embedding) given that name is at least
    REJECT_SIMILAR alike, and more alike than ``alike`` (how close the voice
    is to the person's own samples)."""
    query = _unit(embedding)
    return any(n.casefold() == name.casefold() and float(_unit(v) @ query) >= max(REJECT_SIMILAR, alike)
               for n, v in rejected)


def recognize(
    embeddings: dict[str, list[float]],
    talk_seconds: dict[str, float],
    bank: VoiceBank,
    invited: list[str] | None = None,
    rejected=(),
) -> dict[str, tuple[str, float]]:
    """label → (name, similarity) for speakers the bank recognizes.

    ``invited`` (names as the bank knows them) are the people the calendar
    says were in the meeting: among them SUGGEST_THRESHOLD is enough, since
    the voice only has to be told apart from a few. Otherwise, or when none
    of them matches, the usual MATCH_THRESHOLD against everyone applies.
    ``rejected``: voices the user said are not someone, (name, embedding):
    a voice like one of them is not that person (``said_not``). That leaves
    no guess by elimination: the next best must clear MATCH_THRESHOLD and
    beat everyone, the rejected name included, by MATCH_MARGIN; the
    invitees' easier threshold no longer applies to this voice."""
    allowed = {n.casefold() for n in invited or []}
    found = {}
    for label, embedding in sorted(embeddings.items()):
        if talk_seconds.get(label, 0.0) < MIN_TALK_SECONDS:
            continue
        everyone = bank.scores(embedding)
        scores = [(sim, name) for sim, name in everyone
                  if not (rejected and said_not(name, embedding, rejected, sim))]
        said_no = len(scores) < len(everyone)
        hit = None
        if allowed and not said_no:
            among = [(sim, name) for sim, name in scores if name.casefold() in allowed]
            if among and among[0][0] >= SUGGEST_THRESHOLD and (
                len(among) == 1 or among[0][0] - among[1][0] >= MATCH_MARGIN
            ):
                hit = (among[0][1], among[0][0])
        if hit is None and scores and scores[0][0] >= MATCH_THRESHOLD:
            best_sim, best = scores[0]
            rivals = [sim for sim, name in everyone if name != best]
            if not rivals or best_sim - max(rivals) >= MATCH_MARGIN:
                hit = (best, best_sim)
        if hit is not None:
            found[label] = hit
    return found
