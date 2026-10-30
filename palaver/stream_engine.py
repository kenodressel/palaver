"""The live stream's speech engine: a sliding window with local agreement.

Every step the last `WINDOW_SECONDS` of a track are transcribed in full, so
the model always sees context on both sides of a word. A word settles once
two passes in a row agree on it, or once it is older than `MAX_AGE` seconds
(so a word that never agrees cannot leave the window unsaid). The words that
have not settled yet are the draft: they change from pass to pass.
"""

from __future__ import annotations

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


def window_transcriber(model) -> Callable[[np.ndarray], list[Word]]:
    """Turn a loaded parakeet-mlx model into a `transcribe` for WindowEngine."""
    import mlx.core as mx
    from parakeet_mlx.audio import get_logmel

    from .transcriber import _words_from_tokens

    def transcribe(audio: np.ndarray) -> list[Word]:
        mel = get_logmel(mx.array(audio), model.preprocessor_config)
        result = model.generate(mel)[0]
        return [w for sentence in result.sentences for w in _words_from_tokens(sentence.tokens)]

    return transcribe


CACHE_LIMIT = 512 * 1024**2  # MLX keeps at most this much freed memory for reuse


def load_engines(repo: str, dictionary: Dictionary) -> tuple[WindowEngine, WindowEngine]:
    """The system and the mic engine, sharing one loaded model."""
    import mlx.core as mx
    from parakeet_mlx import from_pretrained

    mx.set_cache_limit(CACHE_LIMIT)
    transcribe = window_transcriber(from_pretrained(repo))
    return (
        WindowEngine(transcribe, dictionary=dictionary),
        WindowEngine(transcribe, dictionary=dictionary),
    )


def mlx_memory() -> int:
    """The bytes MLX holds now: in use and cached."""
    import mlx.core as mx

    return mx.get_active_memory() + mx.get_cache_memory()


def mlx_peak_mb() -> int:
    """The most MLX has held at once, in MB."""
    import mlx.core as mx

    return round(mx.get_peak_memory() / 1024**2)
