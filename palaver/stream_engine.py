"""The live stream's speech engine: a sliding window with local agreement.

Every step the last `WINDOW_SECONDS` of a track are transcribed in full, so
the model always sees context on both sides of a word. A word settles once
two passes in a row agree on it, or once it is older than `MAX_AGE` seconds
(so a word that never agrees cannot leave the window unsaid). The words that
have not settled yet are the draft: they change from pass to pass.
"""

from __future__ import annotations

import os
from typing import Callable, Protocol

import numpy as np

from .dictionary import Dictionary
from .models import UNSURE_CONFIDENCE, Word

SAMPLE_RATE = 16_000
WINDOW_SECONDS = 10.0  # how much audio each pass transcribes
REHEAR_SECONDS = 1.0  # a pass starts this far before the settled end
MAX_AGE = 3.0  # a word older than this settles without agreement
# How sure Parakeet was moves that age: on recorded meetings, words below
# 0.85 differed from the final transcript 50–100 % of the time and those of
# 0.95 and up 3–12 %. Unsure words wait for more context; sure ones settle
# sooner (1.3–1.8 points less disagreement at the same median latency).
SURE, UNSURE = 0.95, UNSURE_CONFIDENCE
SURE_AGE, UNSURE_AGE = 2.0, 6.0


class Engine(Protocol):
    def add(self, audio: np.ndarray) -> tuple[list[Word], list[Word]]:
        """Feed float32 16 kHz samples that continue the track. Returns the
        newly settled whole words and the current draft; times are seconds
        from the track's start."""
        ...

    def flush(self) -> list[Word]:
        """The draft as settled words, at the end."""
        ...

    def start_at(self, seconds: float) -> None:
        """The first sample fed is this far into the track (a late start)."""
        ...


def _key(word: Word) -> str:
    return word.text.strip(".,?!").casefold()


class WindowEngine(Engine):
    def __init__(
        self,
        transcribe: Callable[[np.ndarray], list[Word]],
        *,
        window: float = WINDOW_SECONDS,
        rehear: float = REHEAR_SECONDS,
        max_age: float = MAX_AGE,
        dictionary: Dictionary | None = None,
    ) -> None:
        self._transcribe = transcribe
        self._window = window
        self._rehear = rehear
        self._max_age = max_age
        self._dictionary = dictionary
        self._audio = np.zeros(0, dtype=np.float32)  # the last window + rehear seconds
        self._audio_start = 0  # sample index of self._audio[0] in the track
        self._settled_end = 0.0
        self._previous: list[Word] = []

    def add(self, audio: np.ndarray) -> tuple[list[Word], list[Word]]:
        self._audio = np.concatenate([self._audio, np.asarray(audio, dtype=np.float32)])
        fed_samples = self._audio_start + len(self._audio)
        fed = fed_samples / SAMPLE_RATE
        # Only the last window + rehear seconds stay in memory: a pass never
        # begins before fed - window.
        keep = int((self._window + self._rehear) * SAMPLE_RATE)
        if len(self._audio) > keep:
            self._audio_start += len(self._audio) - keep
            self._audio = self._audio[-keep:]
        begin = max(0.0, self._settled_end - self._rehear, fed - self._window)
        # A jump past the window (the recorder wrote nothing in a silence,
        # then the whole gap at once): the last draft's words this pass
        # can't hear again settle as they were.
        carried: list[Word] = []
        while self._previous and self._previous[0].start < begin:
            carried.append(self._previous.pop(0))
        if carried:
            self._settled_end = carried[-1].end
        offset = max(0, round(begin * SAMPLE_RATE) - self._audio_start)
        words = self._transcribe(self._audio[offset:])
        # The pass starts where the audio slice starts, not at `begin` exactly.
        shift = (self._audio_start + offset) / SAMPLE_RATE
        hyp = [
            Word(self._text(w.text), shift + w.start, shift + w.end, w.confidence)
            for w in words
            if shift + w.start >= self._settled_end - 0.05
        ]
        # Local agreement: the longest common prefix with the last pass settles.
        n = 0
        while n < min(len(hyp), len(self._previous)) and _key(hyp[n]) == _key(self._previous[n]):
            n += 1
        # A word that has been heard long enough settles regardless.
        while n < len(hyp) and hyp[n].end < fed - self._age_limit(hyp[n]):
            n += 1
        settled, self._previous = carried + hyp[:n], hyp[n:]
        if settled:
            self._settled_end = settled[-1].end
        return settled, list(self._previous)

    def _age_limit(self, word: Word) -> float:
        if word.confidence is None or SURE > word.confidence >= UNSURE:
            return self._max_age
        return SURE_AGE if word.confidence >= SURE else UNSURE_AGE

    def start_at(self, seconds: float) -> None:
        self._audio_start = round(seconds * SAMPLE_RATE)
        self._settled_end = seconds

    def flush(self) -> list[Word]:
        settled, self._previous = self._previous, []
        if settled:
            self._settled_end = settled[-1].end
        return settled

    def _text(self, text: str) -> str:
        return self._dictionary.apply(text) if self._dictionary else text


def window_transcriber(engine) -> Callable[[np.ndarray], list[Word]]:
    """A `transcribe` for WindowEngine that sends each window to palaver-engine
    as base64 float32 little-endian samples."""
    import base64

    def transcribe(audio: np.ndarray) -> list[Word]:
        pcm = base64.b64encode(np.asarray(audio, dtype="<f4").tobytes()).decode("ascii")
        reply = engine.call("transcribe_window", pcm=pcm)
        return [
            Word(w["text"], float(w["start"]), float(w["end"]), w.get("confidence"))
            for w in reply.get("words", [])
        ]

    return transcribe


def load_engines(dictionary: Dictionary, engine=None) -> tuple[WindowEngine, WindowEngine]:
    """The system and the mic engine, sharing one palaver-engine process."""
    if engine is None:
        from .engine import Engine

        engine = Engine()
    transcribe = window_transcriber(engine)
    return (
        WindowEngine(transcribe, dictionary=dictionary),
        WindowEngine(transcribe, dictionary=dictionary),
    )


class MemoryMeter:
    """The stream's memory: this process and the engine it started (the
    model lives in the engine, so only the whole tree says what the stream
    costs). Called, it returns the bytes now and remembers the most."""

    def __init__(self, pid: int | None = None):
        self._pid = os.getpid() if pid is None else pid
        self._peak = 0

    def __call__(self) -> int:
        from . import memory

        used = memory.tree_footprint(self._pid) or 0
        self._peak = max(self._peak, used)
        return used

    def peak_mb(self) -> int:
        """The most the tree held at once, in MB."""
        return round(self._peak / 1024**2)
