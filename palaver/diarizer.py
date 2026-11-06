"""Speaker diarization through palaver-engine (FluidAudio, CoreML)."""

from __future__ import annotations

from pathlib import Path
from typing import Callable

import numpy as np

from .models import SpeakerTurn
from .transcriber import MIN_AUDIO_SECONDS

# The live worker diarizes the whole recording so far at most this often
# (seconds of new audio): the engine has no incremental mode.
LIVE_DIARIZE_EVERY = 120.0


def _turns_from_reply(reply: dict) -> tuple[list[SpeakerTurn], dict[str, list[float]]]:
    turns = [
        SpeakerTurn(speaker=str(t["speaker"]), start=float(t["start"]), end=float(t["end"]))
        for t in reply.get("turns", [])
    ]
    turns.sort(key=lambda t: t.start)
    embeddings = {str(k): [float(v) for v in row] for k, row in reply.get("embeddings", {}).items()}
    return turns, embeddings


class EngineDiarizer:
    """Speaker diarization through palaver-engine (FluidAudio, CoreML)."""

    def __init__(self, engine=None):
        self._engine = engine
        # Voice embedding (256 floats) per speaker label from the last diarize() call.
        self.last_embeddings: dict[str, list[float]] = {}

    def _call(self, wav: Path) -> dict:
        if self._engine is None:
            from .engine import Engine

            self._engine = Engine()
        return self._engine.call("diarize", wav=str(wav))

    def diarize(self, wav: Path) -> list[SpeakerTurn]:
        import soundfile as sf

        info = sf.info(str(wav))
        if info.frames < MIN_AUDIO_SECONDS * info.samplerate:
            self.last_embeddings = {}  # a track that got nothing
            return []
        turns, self.last_embeddings = _turns_from_reply(self._call(wav))
        return turns


class LiveEngineDiarizer:
    """Provisional diarization while the recording grows, through the engine.
    The engine diarizes whole files, so every ``LIVE_DIARIZE_EVERY`` seconds of
    new audio the system track so far is written to a scratch file and
    diarized again."""

    SAMPLE_RATE = 16_000

    def __init__(self, folder: Path, engine=None):
        self._scratch = Path(folder) / ".live-diarize.wav"
        self._scratch.unlink(missing_ok=True)  # a killed worker's
        self._diarizer = EngineDiarizer(engine)
        self._turns: list[SpeakerTurn] = []
        self._last_at = 0
        self.chunks_done = 0

    @property
    def last_embeddings(self) -> dict[str, list[float]]:
        return self._diarizer.last_embeddings

    def _run(self, samples: np.ndarray) -> list[SpeakerTurn]:
        import soundfile as sf

        try:
            sf.write(str(self._scratch), samples, self.SAMPLE_RATE, subtype="PCM_16")
            return self._diarizer.diarize(self._scratch)
        finally:
            self._scratch.unlink(missing_ok=True)

    def advance(self, read: Callable[[int, int], np.ndarray], available: int, max_chunks: int = 120) -> int:
        if available < self._last_at + LIVE_DIARIZE_EVERY * self.SAMPLE_RATE:
            return 0
        self._turns = self._run(read(0, available))
        self._last_at = available
        self.chunks_done += 1
        return 1

    def provisional(self) -> list[SpeakerTurn]:
        return list(self._turns)

    def finish(self, samples: np.ndarray) -> list[SpeakerTurn]:
        self._turns = self._run(samples)
        self.chunks_done += 1
        return list(self._turns)
