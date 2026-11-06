"""Tests for the realtime processor (scripted engines, no model)."""

import json
from pathlib import Path

import numpy as np
import pytest

from palaver.capture_recorder import _IncrementalTrackWriter
from palaver.models import Word
from palaver.paths import RecordingPaths
from palaver.stream import ECHO_WAIT_SECONDS, MAX_SENTENCE, RealtimeProcessor
from palaver.stream_engine import MAX_AGE

SR = 16_000
LOUD = 3000  # about -21 dBFS
SCHEMA = {"until", "system", "mic", "draft", "questions", "speaking", "updated_at"}


class _ScriptedEngine:
    """``add`` returns the next preset (settled, draft); ``flush`` the preset
    rest. Remembers how many samples each ``add`` got."""

    def __init__(self, *calls, flush=()):
        self._calls = list(calls)
        self._flush = list(flush)
        self.fed: list[int] = []

    def add(self, audio):
        assert audio.dtype == np.float32
        self.fed.append(len(audio))
        if not self._calls:
            return [], []
        return self._calls.pop(0)

    def flush(self):
        rest, self._flush = self._flush, []
        return rest


class _Recording:
    """The recorder's .part files in a recording folder."""

    def __init__(self, folder: Path):
        self.paths = RecordingPaths(folder)
        self.system = _IncrementalTrackWriter(self.paths.system_wav)
        self.mic = _IncrementalTrackWriter(self.paths.mic_raw_wav)

    def add(self, seconds: float, *, system: int = 0, mic: int = 0, only: str | None = None) -> None:
        for name, writer, level in (("system", self.system, system), ("mic", self.mic, mic)):
            if only in (None, name):
                writer.write_chunk_at_offset(writer.frames_written, np.full(int(seconds * SR), level, np.int16))
                writer.flush()

    def close(self) -> None:
        self.system.abort()
        self.mic.abort()


@pytest.fixture
def rec(tmp_path: Path):
    recording = _Recording(tmp_path)
    yield recording
    recording.close()


class _Clock:
    def __init__(self, now: float = 1000.0):
        self.now = now

    def __call__(self) -> float:
        return self.now


def _w(text: str, start: float, end: float) -> Word:
    return Word(text, start, end)


def _texts(segments) -> list[str]:
    return [s["text"] for s in segments]


def _state(processor: RealtimeProcessor, paths: RecordingPaths) -> dict:
    processor.write()
    return json.loads(paths.stream.read_text())


def test_sentences_close_at_gaps_and_punctuation(rec):
    clock = _Clock(100.0)
    system = _ScriptedEngine(
        ([_w("Hallo", 0.1, 0.4), _w("zusammen.", 0.5, 0.9)], []),
        ([], []),
        ([_w("Wie", 2.4, 2.6), _w("geht's", 2.7, 2.9)], []),
    )
    processor = RealtimeProcessor(rec.paths, system_engine=system, mic_engine=_ScriptedEngine(), clock=clock)
    rec.add(1.0)
    processor.step()
    state = _state(processor, rec.paths)
    assert _texts(state["system"]) == ["Hallo zusammen."]  # the full stop closes it
    assert state["system"][0]["settled_at"] == 100.0
    for _ in range(2):
        clock.now += 1
        rec.add(1.0)
        processor.step()
    assert _texts(_state(processor, rec.paths)["system"]) == ["Hallo zusammen."]  # still open
    for _ in range(2):
        clock.now += 1
        rec.add(1.0)
        processor.step()
    state = _state(processor, rec.paths)
    assert _texts(state["system"]) == ["Hallo zusammen.", "Wie geht's"]  # a second of quiet
    assert state["system"][1]["settled_at"] == 102.0  # when "geht's" settled
    assert (state["system"][1]["start"], state["system"][1]["end"]) == (2.4, 2.9)


def test_settled_words_split_at_a_gap_and_at_max_sentence(rec):
    words = [_w("ja", 0.1, 0.3), _w("genau", 1.5, 1.8)]  # 1.2 s apart
    words += [_w(f"w{i}", 2.0 + i * 0.5, 2.3 + i * 0.5) for i in range(40)]  # 20 s, no pause
    system = _ScriptedEngine((words, []))
    processor = RealtimeProcessor(rec.paths, system_engine=system, mic_engine=_ScriptedEngine())
    rec.add(25.0)
    processor.step()
    sentences = _state(processor, rec.paths)["system"]
    assert _texts(sentences)[0] == "ja"
    assert sentences[1]["text"].startswith("genau w0")
    assert all(s["end"] - s["start"] <= MAX_SENTENCE for s in sentences)
    assert sum(len(s["text"].split()) for s in sentences) == 42  # the rest closed after 3 s of quiet


def test_question_from_the_other_side_is_listed(rec):
    system = _ScriptedEngine(([_w("Was", 0.1, 0.3), _w("kostet", 0.4, 0.6), _w("das?", 0.7, 0.9)], []))
    mic = _ScriptedEngine(([_w("Kommt", 3.1, 3.3), _w("er?", 3.4, 3.6)], []))
    processor = RealtimeProcessor(rec.paths, system_engine=system, mic_engine=mic)
    rec.add(5.0)
    processor.step()
    state = _state(processor, rec.paths)
    assert state["questions"] == [{"start": 0.1, "end": 0.9, "text": "Was kostet das?"}]
    assert _texts(state["mic"]) == ["Kommt er?"]


@pytest.mark.parametrize("mine, kept", [(["Das", "ist", "ein", "Test."], []),
                                        (["Ich", "sehe", "das", "anders."], ["Ich sehe das anders."])])
def test_mic_sentence_that_echoes_remote_is_dropped(rec, mine, kept):
    times = [(0.1, 0.25), (0.3, 0.4), (0.45, 0.55), (0.6, 0.75)]
    remote = [_w(t, s, e) for t, (s, e) in zip(["Das", "ist", "ein", "Test."], times)]
    heard = [_w(t, s + 0.2, e + 0.2) for t, (s, e) in zip(mine, times)]
    clock = _Clock()
    processor = RealtimeProcessor(
        rec.paths, system_engine=_ScriptedEngine((remote, [])), mic_engine=_ScriptedEngine((heard, [])), clock=clock
    )
    rec.add(1.0)
    processor.step()
    assert _state(processor, rec.paths)["mic"] == []  # waits for the system track past 1.45 s
    rec.add(1.0)
    processor.step()  # same clock: decided because the system track is fed to 2.0 s
    state = _state(processor, rec.paths)
    assert _texts(state["system"]) == ["Das ist ein Test."]
    assert _texts(state["mic"]) == kept


def test_mic_sentence_waits_for_system_then_times_out(rec):
    clock = _Clock()
    mic = _ScriptedEngine(([_w("Ich", 0.1, 0.3), _w("bin", 0.4, 0.6), _w("hier.", 0.7, 0.9)], []))
    processor = RealtimeProcessor(rec.paths, system_engine=_ScriptedEngine(), mic_engine=mic, clock=clock)
    rec.add(1.0, only="mic")
    processor.step()
    clock.now += ECHO_WAIT_SECONDS - 0.5
    rec.add(1.0, only="mic")
    processor.step()
    assert _state(processor, rec.paths)["mic"] == []
    clock.now += 0.5
    processor.step()
    state = _state(processor, rec.paths)
    assert _texts(state["mic"]) == ["Ich bin hier."]
    assert state["mic"][0]["settled_at"] == 1000.0
    assert state["mic"][0]["published_at"] == 1000.0 + ECHO_WAIT_SECONDS  # the echo wait counts


def test_open_settled_words_show_in_the_draft(rec):
    """Settled words of a sentence that has neither ended nor paused are in
    no closed sentence: they show with the draft."""
    system = _ScriptedEngine(([_w("wir", 0.1, 0.3), _w("nehmen", 0.4, 0.7)], [_w("das", 0.8, 0.95)]))
    mic = _ScriptedEngine(([_w("also", 0.2, 0.5), _w("gut", 0.6, 0.8)], []))
    processor = RealtimeProcessor(rec.paths, system_engine=system, mic_engine=mic, clock=_Clock())
    rec.add(1.0)
    processor.step()
    state = _state(processor, rec.paths)
    assert state["system"] == [] and state["mic"] == []
    assert state["draft"] == {"system": "wir nehmen das", "mic": "also gut"}


def test_a_stalled_track_settles_its_draft_after_max_age(rec):
    """The tap writes nothing in a silence: the last sentence before a pause
    settles by the clock, without waiting for audio to resume."""
    clock = _Clock()
    question = [_w("Was", 0.1, 0.3), _w("kostet", 0.4, 0.6)], [_w("das?", 0.7, 0.9)]
    system = _ScriptedEngine(question, flush=[_w("das?", 0.7, 0.9)])
    processor = RealtimeProcessor(rec.paths, system_engine=system, mic_engine=_ScriptedEngine(), clock=clock)
    rec.add(1.0)
    processor.step()
    assert _state(processor, rec.paths)["questions"] == []
    for _ in range(2):  # the system track stalls; the mic goes on
        clock.now += MAX_AGE / 2 - 0.1
        rec.add(1.0, only="mic")
        processor.step()
    assert _state(processor, rec.paths)["questions"] == []
    clock.now += 0.2
    processor.step()
    state = _state(processor, rec.paths)
    assert state["questions"] == [{"start": 0.1, "end": 0.9, "text": "Was kostet das?"}]
    assert _texts(state["system"]) == ["Was kostet das?"] and state["draft"]["system"] == ""


def test_speaking_flags_from_levels(rec):
    processor = RealtimeProcessor(rec.paths, system_engine=_ScriptedEngine(), mic_engine=_ScriptedEngine())
    rec.add(1.0, system=LOUD, mic=LOUD)
    processor.step()
    assert _state(processor, rec.paths)["speaking"] == {"others": True, "me": False}  # doubletalk
    rec.add(1.0, system=0, mic=LOUD)
    processor.step()
    assert _state(processor, rec.paths)["speaking"] == {"others": False, "me": True}
    rec.add(1.0, system=0, mic=10)  # about -70 dBFS: room noise
    processor.step()
    assert _state(processor, rec.paths)["speaking"] == {"others": False, "me": False}


def test_speaking_is_judged_at_the_same_moment_when_a_track_stalls(rec):
    processor = RealtimeProcessor(rec.paths, system_engine=_ScriptedEngine(), mic_engine=_ScriptedEngine())
    rec.add(1.0, system=LOUD, mic=0)
    processor.step()
    assert _state(processor, rec.paths)["speaking"] == {"others": True, "me": False}
    rec.add(1.0, mic=LOUD, only="mic")  # the system track stops growing: the others went quiet
    processor.step()
    assert _state(processor, rec.paths)["speaking"] == {"others": False, "me": True}


def test_engines_get_half_a_second_at_least(rec):
    system, mic = _ScriptedEngine(), _ScriptedEngine()
    processor = RealtimeProcessor(rec.paths, system_engine=system, mic_engine=mic)
    rec.add(0.3)
    assert processor.step() is True  # new samples, but too few to feed
    assert system.fed == [] and mic.fed == []
    assert processor.step() is False
    rec.add(0.3)
    processor.step()
    assert system.fed == [int(0.6 * SR)] and mic.fed == [int(0.6 * SR)]
    rec.add(0.2)
    processor.step()
    processor.finish()
    assert system.fed == [int(0.6 * SR), int(0.2 * SR)]  # finish feeds the rest
    assert json.loads(rec.paths.stream.read_text())["until"] == 0.8


def test_finish_settles_the_draft(rec):
    draft = [_w("und", 0.2, 0.4), _w("dann", 0.5, 0.8)]
    mic = _ScriptedEngine(([], draft), flush=draft)
    processor = RealtimeProcessor(rec.paths, system_engine=_ScriptedEngine(), mic_engine=mic)
    rec.add(1.0)
    processor.step()
    assert _state(processor, rec.paths)["draft"] == {"system": "", "mic": "und dann"}
    processor.finish()
    state = json.loads(rec.paths.stream.read_text())
    assert "und dann" in state["mic"][-1]["text"]
    assert state["draft"] == {"system": "", "mic": ""}


def test_stream_json_is_written_atomically(rec):
    clock = _Clock(500.0)
    system = _ScriptedEngine(([_w("Gut.", 0.1, 0.3)], []))
    mic = _ScriptedEngine(([_w("Ja.", 0.1, 0.3)], []))
    processor = RealtimeProcessor(rec.paths, system_engine=system, mic_engine=mic, clock=clock)
    rec.add(1.0)
    processor.step()
    processor.write()
    state = json.loads(rec.paths.stream.read_text())
    assert set(state) == SCHEMA
    # System sentences leave their words out (R6); the mic keeps them for the bench.
    assert state["system"] == [{"start": 0.1, "end": 0.3, "text": "Gut.", "speaker": None, "settled_at": 500.0,
                               "published_at": 500.0}]
    assert state["mic"] == [{"start": 0.1, "end": 0.3, "text": "Ja.", "speaker": None, "settled_at": 500.0,
                             "published_at": 500.0,
                             "words": [{"text": "Ja.", "start": 0.1, "end": 0.3}]}]
    assert state["until"] == 1.0 and state["updated_at"] == 500.0
    assert not list(rec.paths.folder.glob("*.tmp"))
    assert rec.paths.stream == rec.paths.folder / "stream.json"
    assert rec.paths.stream_pid == rec.paths.folder / "stream.pid"


class _FakeProcessor:
    """step() grows nothing unless told; counts calls."""

    def __init__(self, on_step=None):
        self.steps = 0
        self.finished = 0
        self.writes = 0
        self._on_step = on_step

    def step(self):
        self.steps += 1
        return self._on_step(self.steps) if self._on_step else False

    def write(self):
        self.writes += 1

    def finish(self):
        self.finished += 1


class _FakeTime:
    def __init__(self):
        self.now = 0.0

    def clock(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


def test_run_stream_finishes_when_recording_finishes(rec):
    from palaver.stream import run_stream

    rec.add(1.0)
    rec.system.finalize_to(SR)  # the recorder renamed its .part files
    rec.mic.finalize_to(SR)
    fake = _FakeTime()

    def on_step(n):
        if n == 3:
            rec.paths.meta.write_text("{}")
        return True

    processor = _FakeProcessor(on_step)
    assert run_stream(processor, rec.paths, clock=fake.clock, sleep=fake.sleep) is True
    assert processor.finished == 1
    assert processor.steps == 3


def test_run_stream_idles_through_silence(rec):
    from palaver.stream import run_stream

    fake = _FakeTime()
    processor = _FakeProcessor()

    def sleep(seconds):
        fake.sleep(seconds)
        if fake.now >= 60:
            raise KeyboardInterrupt  # stop the test's loop

    with pytest.raises(KeyboardInterrupt):
        run_stream(processor, rec.paths, stall=120, clock=fake.clock, sleep=sleep)
    assert processor.steps >= 59
    assert processor.finished == 0


def test_run_stream_gives_up_on_a_dead_recorder(rec):
    from palaver.stream import run_stream

    fake = _FakeTime()
    processor = _FakeProcessor()
    assert run_stream(processor, rec.paths, stall=30, clock=fake.clock, sleep=fake.sleep) is False
    assert processor.finished == 0
    writes = processor.writes
    assert fake.now > 30
    assert processor.writes == writes


def test_worker_running(tmp_path):
    import os

    from palaver.stream import worker_running

    paths = RecordingPaths(tmp_path)
    assert not worker_running(tmp_path)
    paths.stream_pid.write_text(str(os.getpid()))
    assert worker_running(tmp_path)
    paths.stream_pid.write_text("not a pid")
    assert not worker_running(tmp_path)


class _OffsetEngine:
    """Remembers where it was told it starts and what it was fed."""

    def __init__(self):
        self.start = None
        self.fed = 0

    def start_at(self, seconds):
        self.start = seconds

    def add(self, audio):
        self.fed += len(audio)
        end = (self.start or 0) + self.fed / SR
        return [_w("spät", end - 1.0, end - 0.5)], []

    def flush(self):
        return []


def test_a_late_stream_reads_only_the_last_window(rec):
    rec.add(60.0, system=LOUD, mic=LOUD)
    system, mic = _OffsetEngine(), _OffsetEngine()
    processor = RealtimeProcessor(rec.paths, system_engine=system, mic_engine=mic, clock=_Clock())
    processor.step()
    assert system.start == 50.0
    assert system.fed == 10 * SR  # not the 60 s backlog
    assert _state(processor, rec.paths)["until"] == 60.0
    rec.add(1.0, system=LOUD, mic=LOUD)
    processor.step()
    assert system.fed == 11 * SR
    processor.finish()
    state = json.loads(rec.paths.stream.read_text())
    assert state["system"][0]["start"] > 50  # track time, not window time


def test_run_stream_stops_above_the_memory_cap(rec):
    """Every MEMORY_CHECK_STEPS steps the stream reads its memory (this process and the engine); above
    the cap it logs and ends without finishing or touching the recording."""
    from palaver.session_log import session_log
    from palaver.stream import MEMORY_CHECK_STEPS, STREAM_MEMORY_LIMIT, run_stream

    fake = _FakeTime()
    processor = _FakeProcessor(lambda n: True)
    readings = [STREAM_MEMORY_LIMIT, STREAM_MEMORY_LIMIT + 1]  # at the cap is fine; above is not
    parts = {p.name: p.read_bytes() for p in rec.paths.folder.glob("*.part")}
    with session_log(rec.paths.session_log):
        assert run_stream(processor, rec.paths, clock=fake.clock, sleep=fake.sleep,
                          memory=lambda: readings.pop(0)) is False
    assert readings == []
    assert processor.steps == 2 * MEMORY_CHECK_STEPS and processor.finished == 0
    assert {p.name: p.read_bytes() for p in rec.paths.folder.glob("*.part")} == parts and parts
    events = [json.loads(line) for line in rec.paths.session_log.read_text().splitlines()]
    capped = [e for e in events if e.get("event") == "stream_memory_cap"]
    assert len(capped) == 1 and capped[0]["mb"] == round((STREAM_MEMORY_LIMIT + 1) / 1024**2)
    from palaver import memory

    # twice the stream's budget, measured as this process plus the engine
    assert STREAM_MEMORY_LIMIT == 2 * memory.DEFAULT_STREAM_GB * memory.GB == 3 * 1024**3


def test_the_stream_cap_follows_the_configured_budget():
    from types import SimpleNamespace

    from palaver import memory
    from palaver.stream import memory_limit_for

    assert memory_limit_for(SimpleNamespace(memory={"stream": 2.5})) == 5 * 1024**3
    assert memory_limit_for(SimpleNamespace()) == 2 * memory.DEFAULT_STREAM_GB * memory.GB
