"""Domain data models for the transcription pipeline."""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any


# Below this a word is "unsure": on recorded meetings such words differed
# from the final transcript 50–100 % of the time (above 0.95: 3–12 %).
UNSURE_CONFIDENCE = 0.85


@dataclass(frozen=True)
class Word:
    """A single word with sub-second timing."""

    text: str
    start: float
    end: float
    # How sure the transcriber was (0–1, its least sure piece); None: unknown.
    confidence: float | None = None

    def to_dict(self) -> dict[str, Any]:
        d = asdict(self)
        if self.confidence is None:
            del d["confidence"]
        return d

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "Word":
        confidence = d.get("confidence")
        return cls(text=d["text"], start=float(d["start"]), end=float(d["end"]),
                   confidence=None if confidence is None else float(confidence))


@dataclass
class Segment:
    """A Whisper segment (~30s chunk) with optional word-level timings."""

    start: float
    end: float
    text: str
    speaker: str | None = None
    words: list[Word] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "start": self.start,
            "end": self.end,
            "text": self.text,
            "speaker": self.speaker,
            "words": [w.to_dict() for w in self.words],
        }

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "Segment":
        return cls(
            start=float(d["start"]),
            end=float(d["end"]),
            text=d["text"],
            speaker=d.get("speaker"),
            words=[Word.from_dict(w) for w in d.get("words", [])],
        )


@dataclass(frozen=True)
class SpeakerTurn:
    """A contiguous interval during which one speaker was active."""

    speaker: str
    start: float
    end: float

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "SpeakerTurn":
        return cls(
            speaker=d["speaker"],
            start=float(d["start"]),
            end=float(d["end"]),
        )


@dataclass(frozen=True)
class Utterance:
    """Final merged output: who said what, when."""

    speaker: str
    start: float
    end: float
    text: str
    # Original diarization label when ``speaker`` was renamed (speakers.json),
    # so later renames can still map from it.
    label: str | None = None
    # What the transcriber heard, when the user rewrote ``text`` by hand.
    heard: str | None = None
    # Words in ``text`` the transcriber was unsure of (UNSURE_CONFIDENCE).
    unsure: tuple[str, ...] = ()
    # Where the glossary respelled ``text`` for showing it: (start, end, the
    # variant heard). Worked out by ``readable``, never stored.
    glossed: tuple[tuple[int, int, str], ...] = ()

    def to_dict(self) -> dict[str, Any]:
        d = asdict(self)
        del d["glossed"]
        for key in ("label", "heard"):
            if d[key] is None:
                del d[key]
        if self.unsure:
            d["unsure"] = list(self.unsure)
        else:
            del d["unsure"]
        return d

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "Utterance":
        return cls(
            speaker=d["speaker"],
            start=float(d["start"]),
            end=float(d["end"]),
            text=d["text"],
            label=d.get("label"),
            heard=d.get("heard"),
            unsure=tuple(d.get("unsure", ())),
        )
