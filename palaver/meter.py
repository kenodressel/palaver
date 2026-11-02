"""Live per-track level meter for `record` (issue #17).

Reads the still-growing ``.part`` WAVs directly — never via ``wave.open()``,
whose header ``nframes`` stays 0 until the file is finalized. Only bytes
appended since the previous tick are measured: the Process Tap writes
nothing while no audio plays, so the file tail would show stale audio.
"""

from __future__ import annotations

import math
import sys
import threading
import time
from pathlib import Path
from typing import Callable, TextIO

import numpy as np

_HEADER_SIZE = 44
_BAR_WIDTH = 8
_BAR_FLOOR_DB = -60.0
_BLOCKS = " ▁▂▃▄▅▆▇█"
# Measure at most the last 0.5 s of new audio per tick.
_MAX_TICK_BYTES = 16_000
# Louder than this is sound (speech, the call); a quiet room's noise on the
# mic stays below it.
SOUND_DBFS = -45.0


def level_dbfs(pcm16: bytes) -> float | None:
    """RMS level of int16 PCM in dBFS; None for empty or digital silence."""
    samples = np.frombuffer(pcm16[: len(pcm16) // 2 * 2], dtype=np.int16)
    if samples.size == 0:
        return None
    rms = math.sqrt(float(np.mean(samples.astype(np.float64) ** 2)))
    if rms == 0:
        return None
    return 20 * math.log10(rms / 32_768)


def _bar(db: float | None) -> str:
    if db is None:
        return " " * _BAR_WIDTH
    fill = min(max((db - _BAR_FLOOR_DB) / -_BAR_FLOOR_DB, 0.0), 1.0) * _BAR_WIDTH
    full = int(fill)
    partial = _BLOCKS[int((fill - full) * (len(_BLOCKS) - 1))] if full < _BAR_WIDTH else ""
    return ("█" * full + partial).ljust(_BAR_WIDTH)


def format_line(
    elapsed: float, tracks: list[tuple[str, float | None, float]]
) -> str:
    """``tracks`` holds (label, level dBFS or None, seconds without audio)."""
    minutes, seconds = divmod(int(elapsed), 60)
    parts = [f"rec {minutes:02d}:{seconds:02d}"]
    for label, db, silent_for in tracks:
        level = f"{db:4.0f} dB" if db is not None else "  -- dB"
        part = f"{label} {_bar(db)} {level}"
        if silent_for >= 5:
            part += f" (silent {silent_for:.0f}s)"
        parts.append(part)
    return " | ".join(parts)


def level_bar(db: float | None) -> str:
    """8-character block bar for a dBFS level (empty below -60 dB)."""
    return _bar(db)


class LevelTracker:
    """Per-track level of the audio appended since the previous ``read()``,
    plus how long each track has had no audio, and how long all of them
    have had nothing louder than ``sound_dbfs`` (``quiet_for``)."""

    def __init__(
        self,
        tracks: list[tuple[str, Path]],
        *,
        clock: Callable[[], float] = time.monotonic,
        sound_dbfs: float = SOUND_DBFS,
    ):
        self._tracks = [(label, Path(path)) for label, path in tracks]
        self._clock = clock
        self._sound_dbfs = sound_dbfs
        start = clock()
        self._offsets = {label: _HEADER_SIZE for label, _ in self._tracks}
        self._last_audio = {label: start for label, _ in self._tracks}
        self._last_sound = start
        self._last_sound_of = {label: start for label, _ in self._tracks}
        self._last_read = start

    def read(self) -> list[tuple[str, float | None, float]]:
        now = self._clock()
        self._last_read = now
        readings = []
        for label, path in self._tracks:
            db = self._read_new(label, path)
            if db is not None:
                self._last_audio[label] = now
                if db >= self._sound_dbfs:
                    self._last_sound = self._last_sound_of[label] = now
            readings.append((label, db, now - self._last_audio[label]))
        return readings

    def quiet_for(self, label: str | None = None) -> float:
        """Seconds, up to the last ``read()``, that no track had sound (or
        the track ``label``: "system", the others in a call)."""
        return self._last_read - (self._last_sound if label is None else self._last_sound_of[label])

    def _read_new(self, label: str, path: Path) -> float | None:
        try:
            size = path.stat().st_size
        except OSError:
            return None
        start = max(self._offsets[label], size - _MAX_TICK_BYTES)
        start += (start - _HEADER_SIZE) % 2  # stay sample-aligned
        if size <= start:
            return None
        with open(path, "rb") as f:
            f.seek(start)
            data = f.read(size - start)
        self._offsets[label] = size
        return level_dbfs(data)


class LevelMeter:
    """Prints a carriage-return-updated level line once per ``interval``."""

    def __init__(
        self,
        tracks: list[tuple[str, Path]],
        *,
        interval: float = 1.0,
        out: TextIO | None = None,
        clock: Callable[[], float] = time.monotonic,
    ):
        self._tracker = LevelTracker(tracks, clock=clock)
        self._interval = interval
        self._out = out or sys.stdout
        self._clock = clock
        self._start = clock()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None
        self._out.write("\n")
        self._out.flush()

    def _run(self) -> None:
        while not self._stop.wait(self._interval):
            self.tick()

    def tick(self) -> None:
        readings = self._tracker.read()
        line = format_line(self._clock() - self._start, readings)
        self._out.write("\r" + line + "\x1b[K")
        self._out.flush()
