"""The realtime stream of a recording in progress (#42).

`palaver stream <folder>` runs next to the recorder and the `live` worker.
Every step it feeds what the recorder wrote since the last step to one
`Engine` per track: the system track and the raw mic, without echo
cancellation. Settled words join into sentences. A mic sentence that is the
other side heard through the speakers is dropped by its words, once the
system track has heard the same moment. System sentences that end in "?"
make the question list. It writes only `stream.json`; nothing else reads it
but the Meetings window and the bench.
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import numpy as np

from .cleanup import echoes_remote
from . import live
from .live import SAMPLE_RATE, GrowingTrack, _write_atomic
from .models import Segment, Word
from .paths import RecordingPaths
from .session_log import event
from .stream_engine import MAX_AGE, WINDOW_SECONDS, Engine

STEP_SECONDS = 1.0  # how often the stream reads the tracks
SENTENCE_GAP = 1.0  # a pause this long ends a sentence
MAX_SENTENCE = 15.0  # a sentence never runs longer
ECHO_WAIT_SECONDS = 2.0  # a mic sentence waits at most this long for the system track
ECHO_LOOKAHEAD = 0.5  # ... to have been fed this far past the sentence's end
SPEAKING_DBFS = -45.0  # louder than this over the last SPEAKING_SECONDS is speech
SPEAKING_SECONDS = 0.5
MIN_FEED_SECONDS = 0.5  # the engine gets slices at least this long (R5)
STREAM_MEMORY_LIMIT = 4 * 1024**3  # MLX bytes (active + cache) above which the stream ends
MEMORY_CHECK_STEPS = 10  # ... checked every this many steps

_SENTENCE_END = (".", "?", "!")


@dataclass
class _Sentence:
    segment: Segment
    settled_at: float  # clock time its last word settled
    closed_at: float = 0.0  # clock time it closed
    published_at: float = 0.0  # clock time it joined its track's list (a mic one after the echo wait)

    def to_dict(self, *, words: bool = True) -> dict:
        d = {**self.segment.to_dict(), "settled_at": self.settled_at, "published_at": self.published_at}
        if not words:
            del d["words"]
        return d


class _Track:
    """One track's audio and text so far."""

    def __init__(self, track: GrowingTrack, engine: Engine, now: float):
        self.track = track
        self.engine = engine
        self.grew_at = now  # clock time the track last grew
        # A stream that starts late (the app or the stream restarted mid-call)
        # begins one window before the end instead of reading the backlog (R7).
        # Samples and seconds stay counted from the track's start.
        start = max(0, track.available() - int(WINDOW_SECONDS * SAMPLE_RATE))
        if start:
            engine.start_at(start / SAMPLE_RATE)
        self.read = start  # samples read from the track
        self.fed = start  # samples given to the engine
        self.unfed = np.zeros(0, dtype=np.int16)
        self.words: list[Word] = []  # the open sentence
        self.words_at = 0.0  # clock time its last word settled
        self.draft: list[Word] = []
        self.sentences: list[_Sentence] = []

    def pull(self) -> bool:
        """Read what the recorder wrote since the last call."""
        available = self.track.available()
        if available <= self.read:
            return False
        audio = self.track.read(self.read, available)
        self.read = available
        self.unfed = np.concatenate([self.unfed, audio])
        return True

    def feed(self, *, minimum: int) -> tuple[list[Word], list[Word]] | None:
        if len(self.unfed) == 0 or len(self.unfed) < minimum:
            return None
        audio, self.unfed = self.unfed, np.zeros(0, dtype=np.int16)
        self.fed += len(audio)
        return self.engine.add(audio.astype(np.float32) / 32768.0)

    def loud(self, end: int) -> bool:
        """Whether the SPEAKING_SECONDS before sample ``end`` hold speech.
        What the track has not written up to ``end`` counts as silence."""
        start = max(0, end - int(SPEAKING_SECONDS * SAMPLE_RATE))
        if end <= start:
            return False
        audio = self.track.read(start, end).astype(np.float64) / 32768.0
        return bool(10 * np.log10(float(np.mean(audio**2)) + 1e-20) > SPEAKING_DBFS)


class RealtimeProcessor:
    """Sentences, the echo filter, questions and who is speaking, from the
    two engines. ``step`` takes in what the recorder wrote; ``write`` writes
    ``stream.json``; ``finish`` settles everything once the recording stopped."""

    def __init__(self, paths: RecordingPaths, *, system_engine: Engine, mic_engine: Engine,
                 clock: Callable[[], float] = time.time):
        self._paths = paths
        self._clock = clock
        self._system = _Track(GrowingTrack(paths.system_wav), system_engine, clock())
        self._mic = _Track(GrowingTrack(paths.mic_raw_wav), mic_engine, clock())
        self._remote: list[Word] = []  # every settled system word, for the echo filter
        self._waiting: list[_Sentence] = []  # closed mic sentences the echo filter has not decided
        self._questions: list[dict] = []
        self._speaking = {"others": False, "me": False}

    def step(self) -> bool:
        """Read the tracks up to what is written and feed the engines. Returns
        whether new audio arrived."""
        arrived = False
        now = self._clock()
        for track in (self._system, self._mic):
            if track.pull():
                arrived = True
                track.grew_at = now
            self._advance(track, track.feed(minimum=int(MIN_FEED_SECONDS * SAMPLE_RATE)))
            # The recorder writes a track only when audio arrives: in a
            # silence nothing comes that would settle the last words. They
            # settle once the track has not grown for MAX_AGE.
            if now - track.grew_at >= MAX_AGE and (track.draft or len(track.unfed)):
                self._advance(track, track.feed(minimum=1))
                self._advance(track, (track.engine.flush(), []))
        self._decide_echo()
        self._judge_speaking()
        return arrived

    def finish(self) -> None:
        """Feed what is left, settle the drafts and decide every mic sentence."""
        for track in (self._system, self._mic):
            track.pull()
            self._advance(track, track.feed(minimum=1))
        for track in (self._system, self._mic):
            self._advance(track, (track.engine.flush(), []))
            self._close(track)
        self._decide_echo(final=True)
        self._speaking = {"others": False, "me": False}  # nobody speaks after the stop
        self.write()

    def write(self) -> None:
        system, mic = self._system, self._mic
        _write_atomic(self._paths.stream, json.dumps({
            "until": round(min(system.fed, mic.fed) / SAMPLE_RATE, 2),
            # System words stay out (R6): they are most of the bytes of a
            # file rewritten every second. The bench needs the mic's, for echo.
            "system": [s.to_dict(words=False) for s in system.sentences],
            "mic": [s.to_dict() for s in mic.sentences],
            # The open sentence's settled words are in no sentence yet: they
            # show with the draft.
            "draft": {"system": _text(system.words + system.draft), "mic": _text(mic.words + mic.draft)},
            "questions": self._questions,
            "speaking": self._speaking,
            "updated_at": self._clock(),
        }))

    def _judge_speaking(self) -> None:
        """Both tracks over the same last moment: the recorder writes a track
        only when audio arrives, so a stalled track's own end is stale."""
        end = max(self._system.fed, self._mic.fed)
        others = self._system.loud(end)
        # The raw mic hears the others too: while they speak it can't tell.
        self._speaking = {"others": others, "me": self._mic.loud(end) and not others}

    def _advance(self, track: _Track, result: tuple[list[Word], list[Word]] | None) -> None:
        if result is None:
            return
        settled, track.draft = result
        now = self._clock()
        for word in settled:
            if track.words and (
                word.start - track.words[-1].end >= SENTENCE_GAP
                or word.end - track.words[0].start > MAX_SENTENCE
            ):
                self._close(track)
            track.words.append(Word(word.text, round(word.start, 2), round(word.end, 2), word.confidence))
            track.words_at = now
            if track is self._system:
                self._remote.append(word)
            if word.text.endswith(_SENTENCE_END):
                self._close(track)
        # A pause after the last settled word, with nothing heard yet in it.
        if track.words:
            heard = track.draft[0].start if track.draft else track.fed / SAMPLE_RATE
            if heard - track.words[-1].end >= SENTENCE_GAP:
                self._close(track)

    def _close(self, track: _Track) -> None:
        if not track.words:
            return
        words, track.words = track.words, []
        text = _text(words)
        sentence = _Sentence(Segment(words[0].start, words[-1].end, text, words=words),
                             settled_at=track.words_at, closed_at=self._clock())
        if track is self._mic:
            self._waiting.append(sentence)
            return
        sentence.published_at = sentence.closed_at
        track.sentences.append(sentence)
        if text.endswith("?"):
            self._questions.append({"start": words[0].start, "end": words[-1].end, "text": text})

    def _decide_echo(self, *, final: bool = False) -> None:
        """Keep or drop the waiting mic sentences, oldest first, once the
        system track has heard their moment or they waited long enough."""
        heard = self._system.fed / SAMPLE_RATE
        now = self._clock()
        while self._waiting:
            sentence = self._waiting[0]
            if not (final or heard >= sentence.segment.end + ECHO_LOOKAHEAD
                    or now - sentence.closed_at >= ECHO_WAIT_SECONDS):
                break
            self._waiting.pop(0)
            if not echoes_remote(sentence.segment, self._remote + self._system.draft):
                sentence.published_at = now
                self._mic.sentences.append(sentence)


def running_pid(folder: Path) -> int | None:
    """The pid of the stream still running for ``folder``, if any."""
    try:
        pid = int(RecordingPaths(folder).stream_pid.read_text())
        os.kill(pid, 0)
    except (OSError, ValueError):
        return None
    return pid


def worker_running(folder: Path) -> bool:
    """Whether a stream is still running for ``folder``."""
    return running_pid(folder) is not None


def run_stream(processor: RealtimeProcessor, paths: RecordingPaths, *, step: float = STEP_SECONDS,
               stall: float = live.STALL_SECONDS, clock: Callable[[], float] = time.monotonic,
               sleep: Callable[[float], None] = time.sleep, memory: Callable[[], int] | None = None,
               memory_limit: int = STREAM_MEMORY_LIMIT) -> bool:
    """Step and write every ``step`` seconds until the recording stops, then
    finish. Returns False if the recorder stopped growing without finishing,
    or once ``memory()`` (bytes, read every MEMORY_CHECK_STEPS steps) passes
    ``memory_limit``: the stream gives up, the recording goes on."""
    last_growth = clock()
    steps = 0
    while not live.recording_finished(paths):
        if processor.step():
            last_growth = clock()
        elif clock() - last_growth > stall:
            return False
        processor.write()
        steps += 1
        if memory is not None and steps % MEMORY_CHECK_STEPS == 0:
            used = memory()
            if used > memory_limit:
                event("stream_memory_cap", mb=round(used / 1024**2), limit_mb=round(memory_limit / 1024**2))
                return False
        sleep(step)
    processor.finish()
    return True


def _text(words: list[Word]) -> str:
    return " ".join(w.text for w in words)
