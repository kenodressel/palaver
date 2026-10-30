"""The voice-activity tier of the live pipeline (#42): who talks now, from
levels alone, with and without headphones. Synthetic tracks only: speech is
noise shaped like syllables; with speakers, the system track reaches the mic
as a delayed, quieter copy (the echo). Nothing is played or recorded."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from palaver.capture_recorder import _IncrementalTrackWriter
from palaver.paths import RecordingPaths
from palaver.voice_activity import VoiceActivity, VoiceMonitor, talk_text

SR = 16_000
RNG = np.random.default_rng(7)


def _speech(seconds: float, dbfs: float = -24.0) -> np.ndarray:
    """Noise with a 4 Hz syllable rhythm and a 0.3 s pause every 2.5 s
    (between phrases), at ``dbfs`` while it sounds."""
    n = int(seconds * SR)
    t = np.arange(n) / SR
    envelope = (0.55 + 0.45 * np.sin(2 * np.pi * 4 * t)) * ((t % 2.8) < 2.5)
    x = RNG.standard_normal(n) * envelope
    sounding = envelope > 0
    if sounding.any():
        x *= 10 ** (dbfs / 20) * 32768 / np.sqrt(np.mean(x[sounding] ** 2))
    return x


def _quiet(seconds: float) -> np.ndarray:
    return np.zeros(int(seconds * SR))


def _room(n: int, dbfs: float = -62.0) -> np.ndarray:
    """A quiet room's noise on the mic."""
    return RNG.standard_normal(n) * 10 ** (dbfs / 20) * 32768


def _tracks(me: list[np.ndarray], others: list[np.ndarray], *, echo_db: float | None,
            delay: float = 0.08) -> tuple[np.ndarray, np.ndarray]:
    """(mic, system) as int16. ``echo_db``: how loud the others come back on
    the mic, relative to the system track (None: headphones, no echo)."""
    system = np.concatenate(others)
    mine = np.concatenate(me)
    n = max(len(system), len(mine))
    system = np.pad(system, (0, n - len(system)))
    mic = np.pad(mine, (0, n - len(mine))) + _room(n)
    if echo_db is not None:
        shift = int(delay * SR)
        echo = np.concatenate([np.zeros(shift), system[: n - shift]]) * 10 ** (echo_db / 20)
        mic = mic + echo
    clip = lambda x: np.clip(np.round(x), -32768, 32767).astype(np.int16)  # noqa: E731
    return clip(mic), clip(system)


def _feed(va: VoiceActivity, mic: np.ndarray, system: np.ndarray, chunk: float = 0.25) -> None:
    step = int(chunk * SR)
    for i in range(0, len(mic), step):
        va.add(mic[i:i + step], system[i:i + step])


# --- who talks -------------------------------------------------------------------------


@pytest.mark.parametrize("echo_db", [None, -20.0, -10.0, -3.0])
def test_the_others_echo_on_the_mic_is_not_me(echo_db):
    """Speakers: the others come back on the mic, as loud as the system track
    at worst. That is never the user talking."""
    mic, system = _tracks([_quiet(90)], [_speech(30), _quiet(2), _speech(58)], echo_db=echo_db)
    va = VoiceActivity()
    _feed(va, mic, system)
    s = va.snapshot()
    assert s["me"] < 1.0
    assert s["others"] > 80
    assert s["share"] == 0.0


@pytest.mark.parametrize("echo_db", [None, -12.0])
def test_turns_give_the_talk_share(echo_db):
    me = [_speech(30), _quiet(20), _speech(10), _quiet(40)]
    others = [_quiet(30), _speech(20), _quiet(10), _speech(40)]
    mic, system = _tracks(me, others, echo_db=echo_db)
    va = VoiceActivity()
    _feed(va, mic, system)
    s = va.snapshot()
    assert s["me"] == pytest.approx(40, abs=2)
    assert s["others"] == pytest.approx(60, abs=2)
    assert s["share"] == pytest.approx(0.4, abs=0.03)


def test_who_speaks_now():
    va = VoiceActivity()
    mic, system = _tracks([_quiet(5)], [_speech(5)], echo_db=-12.0)
    _feed(va, mic, system)
    assert va.snapshot()["speaking"] == "others"
    mic, system = _tracks([_speech(3)], [_quiet(3)], echo_db=-12.0)
    _feed(va, mic, system)
    assert va.snapshot()["speaking"] == "me"
    mic, system = _tracks([_quiet(2)], [_quiet(2)], echo_db=-12.0)
    _feed(va, mic, system)
    assert va.snapshot()["speaking"] is None


def test_talking_over_the_others_counts_with_headphones():
    """Double talk: without echo the mic is the user's alone."""
    me = [_quiet(10), _speech(10)]
    others = [_speech(12), _quiet(8)]
    mic, system = _tracks(me, others, echo_db=None)
    va = VoiceActivity()
    _feed(va, mic, system)
    s = va.snapshot()
    assert s["interruptions"] == {"by_me": 1, "of_me": 0}
    assert s["me"] == pytest.approx(10, abs=1)


def test_talking_over_the_others_counts_with_speakers_when_clearly_louder_than_the_echo():
    me = [_quiet(20), _speech(10, dbfs=-20)]
    others = [_speech(22), _quiet(8)]
    mic, system = _tracks(me, others, echo_db=-24.0)
    va = VoiceActivity()
    _feed(va, mic, system)
    assert va.snapshot()["interruptions"]["by_me"] == 1


def test_being_interrupted():
    """With speakers, once the echo's level is learned (the others talked
    first), the user's voice over theirs still counts."""
    me = [_quiet(10.5), _speech(10), _quiet(5)]
    others = [_speech(10), _quiet(8), _speech(7.5)]
    mic, system = _tracks(me, others, echo_db=-15.0)
    va = VoiceActivity()
    _feed(va, mic, system)
    assert va.snapshot()["interruptions"] == {"by_me": 0, "of_me": 1}


def test_a_short_overlap_is_no_interruption():
    me = [_speech(10), _quiet(10)]
    others = [_quiet(9.8), _speech(10)]  # starts as I stop
    mic, system = _tracks(me, others, echo_db=None)
    va = VoiceActivity()
    _feed(va, mic, system)
    assert va.snapshot()["interruptions"] == {"by_me": 0, "of_me": 0}


def test_a_bluetooth_delay_still_reads_as_echo():
    mic, system = _tracks([_quiet(40)], [_speech(40)], echo_db=-8.0, delay=0.3)
    va = VoiceActivity()
    _feed(va, mic, system)
    assert va.snapshot()["me"] < 1.0


def test_a_noisy_mic_is_not_speech():
    """A fan or a loud room: the floor follows it."""
    n = 60 * SR
    mic = np.clip(RNG.standard_normal(n) * 10 ** (-40 / 20) * 32768, -32768, 32767).astype(np.int16)
    va = VoiceActivity()
    _feed(va, mic, np.zeros(n, np.int16))
    assert va.snapshot()["me"] < 3.0


# --- monologues, the window -------------------------------------------------------------


def test_the_current_monologue_runs_across_pauses():
    parts = []
    for _ in range(12):
        parts += [_speech(9), _quiet(1.5)]  # breathing pauses
    mic, system = _tracks(parts, [_quiet(len(np.concatenate(parts)) / SR)], echo_db=-12.0)
    va = VoiceActivity()
    _feed(va, mic, system)
    s = va.snapshot()
    assert s["monologue"] == pytest.approx(124.5, abs=3)
    assert s["longest"] >= s["monologue"]


def test_someone_else_talking_ends_the_monologue_but_a_backchannel_does_not():
    me = [_speech(60), _quiet(0.8), _speech(30), _quiet(5), _speech(20)]
    others = [_quiet(60), _speech(0.6), _quiet(30.2), _speech(4), _quiet(21)]
    mic, system = _tracks(me, others, echo_db=-12.0)
    va = VoiceActivity()
    _feed(va, mic, system)
    s = va.snapshot()
    assert s["longest"] == pytest.approx(90.8, abs=2)
    assert s["monologue"] == pytest.approx(20, abs=2)


def test_the_monologue_ends_after_a_long_pause():
    mic, system = _tracks([_speech(30), _quiet(10)], [_quiet(40)], echo_db=None)
    va = VoiceActivity()
    _feed(va, mic, system)
    assert va.snapshot()["monologue"] == 0


def test_talk_share_is_over_the_last_ten_minutes():
    me = [_speech(300), _quiet(600)]
    others = [_quiet(300), _speech(600)]
    mic, system = _tracks(me, others, echo_db=-12.0)
    va = VoiceActivity()
    _feed(va, mic, system, chunk=1.0)
    s = va.snapshot()
    assert s["window"] == pytest.approx(600, abs=1)
    assert s["me"] == pytest.approx(0, abs=1)
    assert s["share"] == pytest.approx(0, abs=0.01)


def test_no_share_before_anyone_said_much():
    mic, system = _tracks([_speech(5)], [_quiet(5)], echo_db=None)
    va = VoiceActivity()
    _feed(va, mic, system)
    assert va.snapshot()["share"] is None


# --- wait time after my question --------------------------------------------------------


def test_wait_time_after_my_question():
    me = [_speech(8), _quiet(12)]
    others = [_quiet(11), _speech(9)]
    mic, system = _tracks(me, others, echo_db=-12.0)
    va = VoiceActivity()
    _feed(va, mic, system)
    va.questions([7.9])
    q = va.snapshot()["question"]
    assert q["at"] == 7.9
    assert q["wait"] == pytest.approx(3.1, abs=0.3)
    assert q["answered"] and not q["kept_talking"]


def test_still_waiting_for_an_answer():
    mic, system = _tracks([_speech(8), _quiet(5)], [_quiet(13)], echo_db=-12.0)
    va = VoiceActivity()
    _feed(va, mic, system)
    va.questions([8.0])
    q = va.snapshot()["question"]
    assert not q["answered"]
    assert q["wait"] == pytest.approx(5, abs=0.3)


def test_answering_my_own_question():
    me = [_speech(8), _quiet(1), _speech(5), _quiet(3)]
    others = [_quiet(15), _speech(2)]
    mic, system = _tracks(me, others, echo_db=-12.0)
    va = VoiceActivity()
    _feed(va, mic, system)
    va.questions([8.0])
    q = va.snapshot()["question"]
    assert q["kept_talking"]
    assert q["wait"] == pytest.approx(1.0, abs=0.3)


# --- what the status says -------------------------------------------------------------------


def test_talk_text():
    assert talk_text({"speaking": "me", "share": 0.62, "window": 600, "monologue": 130, "me": 300,
                      "others": 180, "interruptions": {"by_me": 0, "of_me": 0}, "question": None}) \
        == "You 62 % of the last 10 min · talking for 2:10"
    assert talk_text({"speaking": "others", "share": 0.3, "window": 240, "monologue": 0, "me": 60,
                      "others": 140, "interruptions": {"by_me": 2, "of_me": 0},
                      "question": {"at": 200, "wait": 2.5, "answered": True, "kept_talking": False}}) \
        == "You 30 % of the last 4 min · 2 interruptions by you · answered 3 s after your question"
    assert talk_text({"speaking": None, "share": None, "window": 20, "monologue": 0, "me": 3,
                      "others": 0, "interruptions": {"by_me": 0, "of_me": 0},
                      "question": {"at": 15, "wait": 4.2, "answered": False, "kept_talking": False}}) \
        == "Quiet for 4 s since your question"
    assert talk_text(None) is None


# --- replaying a recording as it is written ------------------------------------------------


class _Recording:
    def __init__(self, folder: Path):
        self.paths = RecordingPaths(folder)
        self.mic = _IncrementalTrackWriter(self.paths.mic_raw_wav)
        self.system = _IncrementalTrackWriter(self.paths.system_wav)

    def write(self, mic: np.ndarray, system: np.ndarray, *, system_silent: bool = False) -> None:
        """The next chunk of both tracks. The Process Tap writes nothing while
        nothing plays; the gap is filled with zeros when it plays again."""
        at = self.mic.frames_written
        self.mic.write_chunk_at_offset(at, mic)
        self.mic.flush()
        if not system_silent:
            self.system.write_chunk_at_offset(at, system)
            self.system.flush()

    def close(self):
        self.mic.abort()
        self.system.abort()


def test_replay_at_simulated_speed(tmp_path):
    """Chunk by chunk as the recorder writes them: the monitor reads only
    what is new and keeps up within a second."""
    rec = _Recording(tmp_path)
    me = [_speech(20), _quiet(25)]
    others = [_quiet(25), _speech(20)]
    mic, system = _tracks(me, others, echo_db=-10.0)
    clock = [0.0]
    monitor = VoiceMonitor(tmp_path, clock=lambda: clock[0])
    step = int(0.1 * SR)
    lags = []
    try:
        for i in range(0, len(mic), step):
            silent = not system[i:i + step].any()
            rec.write(mic[i:i + step], system[i:i + step], system_silent=silent)
            clock[0] += 0.1
            if i % (step * 5) == 0:  # polled every half second
                monitor.poll()
                lags.append(len(mic[:i + step]) / SR - monitor.snapshot()["until"])
        monitor.poll()
        s = monitor.snapshot()
    finally:
        rec.close()
    assert max(lags) < 1.0
    assert s["me"] == pytest.approx(20, abs=1.5)
    assert s["others"] == pytest.approx(20, abs=1.5)
    assert s["speaking"] == "others"


def test_the_monitor_takes_my_questions_from_the_stream(tmp_path):
    rec = _Recording(tmp_path)
    mic, system = _tracks([_speech(8), _quiet(12)], [_quiet(11), _speech(9)], echo_db=-12.0)
    rec.write(mic, system)
    rec.paths.stream.write_text(json.dumps({"mic": [
        {"start": 0.2, "end": 3.0, "text": "So that's the plan."},
        {"start": 4.0, "end": 7.9, "text": "When can you send the numbers?"}]}))
    try:
        monitor = VoiceMonitor(tmp_path)
        monitor.poll()
        q = monitor.snapshot()["question"]
    finally:
        rec.close()
    assert q["at"] == 7.9 and q["answered"]
    assert q["wait"] == pytest.approx(3.1, abs=0.3)


def test_a_monitor_started_late_reads_only_the_last_ten_minutes(tmp_path):
    rec = _Recording(tmp_path)
    n = 15 * 60 * SR
    try:
        rec.write(np.zeros(n, np.int16), np.zeros(n, np.int16))
        monitor = VoiceMonitor(tmp_path)
        monitor.poll()
        assert monitor.snapshot()["until"] == pytest.approx(15 * 60, abs=1)
        assert monitor.read_samples <= 10 * 60 * SR + SR
    finally:
        rec.close()


def test_a_room_echo_with_reverb_is_not_me():
    """Speakers in a room: the echo is smeared by a 300 ms reverb tail,
    not a clean copy."""
    system = np.concatenate([_speech(40), _quiet(1)])
    ir = RNG.standard_normal(int(0.3 * SR)) * np.exp(-np.arange(int(0.3 * SR)) / (0.06 * SR))
    ir *= 10 ** (-6 / 20) / np.sqrt(np.sum(ir**2))
    echo = np.convolve(system, ir)[: len(system)]
    shift = int(0.04 * SR)
    mic = np.concatenate([np.zeros(shift), echo[:-shift]]) + _room(len(system))
    va = VoiceActivity()
    _feed(va, np.clip(mic, -32768, 32767).astype(np.int16), system.astype(np.int16))
    assert va.snapshot()["me"] < 1.0


def test_with_speakers_my_turns_between_theirs_still_count():
    """The usual call without headphones: turns, each side's voice on the mic."""
    me, others = [], []
    for _ in range(6):
        me += [_speech(8), _quiet(6)]
        others += [_quiet(8.3), _speech(5.4), _quiet(0.3)]
    mic, system = _tracks(me, others, echo_db=-6.0)
    va = VoiceActivity()
    _feed(va, mic, system)
    s = va.snapshot()
    assert s["me"] == pytest.approx(48, abs=4)
    assert s["others"] == pytest.approx(32.4, abs=3)
    assert s["interruptions"] == {"by_me": 0, "of_me": 0}


# --- review fixes -------------------------------------------------------------------------------


def test_a_track_flushed_late_is_not_read_as_silence(tmp_path):
    """The monitor reads only up to what the older track has written (less a
    margin), unless that track has written nothing for over a second."""
    from palaver.voice_activity import STALE_SECONDS

    rec = _Recording(tmp_path)
    mic, system = _tracks([_quiet(10)], [_speech(10)], echo_db=None)
    try:
        rec.mic.write_chunk_at_offset(0, mic[: 5 * SR])
        rec.mic.flush()
        rec.system.write_chunk_at_offset(0, system[: int(4.5 * SR)])  # flushed half a second behind
        rec.system.flush()
        monitor = VoiceMonitor(tmp_path)
        monitor.poll()
        assert monitor.snapshot()["until"] <= 4.5
        rec.system.write_chunk_at_offset(int(4.5 * SR), system[int(4.5 * SR): 5 * SR])
        rec.system.flush()
        monitor.poll()
        assert monitor.snapshot()["others"] == pytest.approx(5, abs=0.5)
        rec.mic.write_chunk_at_offset(5 * SR, mic[5 * SR:])  # the call went quiet: the tap writes nothing
        rec.mic.flush()
        monitor.poll()
        assert monitor.snapshot()["until"] == pytest.approx(10 - STALE_SECONDS, abs=0.2)
    finally:
        rec.close()


def test_answered_questions_keep_their_wait_as_the_minutes_go_by():
    va = VoiceActivity()
    mic, system = _tracks([_speech(8), _quiet(12)], [_quiet(11), _speech(9)], echo_db=None)
    _feed(va, mic, system)
    va.questions([7.9])
    first = va.snapshot()
    assert first["median_wait"] == pytest.approx(3.1, abs=0.3)
    mic, system = _tracks([_speech(600), _quiet(600)], [_quiet(600), _speech(600)], echo_db=None)
    _feed(va, mic, system, chunk=1.0)  # 20 minutes later: the old turns are pruned
    va.questions([7.9])  # the stream lists it again
    later = va.snapshot()
    assert later["median_wait"] == first["median_wait"] and later["questions"] == 1
    assert va._waiting == []
