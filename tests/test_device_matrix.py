"""The device matrix (issue #50): every audio setup Palaver meets, replayed
offline through the real capture path.

Fakes sit only at the operating-system boundary: a fake CoreAudio (the
Process Tap's backend: devices, aggregate, IO callbacks with host-time
stamps) and a fake AVFoundation (the microphone's backend: default input,
capture sessions). Everything above — ``ProcessTap``, ``AVMicCapture``,
``CaptureRecorder`` with its resamplers, writers and health monitor — is the
production code. Nothing plays sound or opens a microphone.

The microphone's buffers are fake CMSampleBuffers (format description,
bytes, stamp) decoded by the production decoder, so a rate change reaches the
recorder the way AVFoundation reports it. CoreMedia's accessors are the
faked boundary there.

Each row replays a known signal (a tone per track and clicks at known
times) and asserts what reaches disk: the file's rate, the content's speed
(the tone's pitch), the track's length against wall-clock time, and how far
each click landed from its true time. A healthy row raises no warning.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import numpy as np
import pytest
import soundfile as sf

from palaver import capture_recorder
from palaver._audio import av_mic
from palaver._audio.av_mic import AVMicCapture, AVMicError
from palaver._audio.process_tap import ProcessTap, ProcessTapError, _TapFormat
from palaver.capture_recorder import PTS_TOLERANCE_FRAMES, SAMPLE_RATE, CaptureRecorder

T0 = 1000.0  # host time at the start, seconds
STEP = 0.01  # one IO cycle
LATENCY = 0.004  # from a buffer's host time to its arrival in the recorder
MIC_TONE, SYSTEM_TONE = 300.0, 500.0
MARKS = [2.5, 7.5, 12.5, 17.5, 22.5, 27.5, 32.5, 37.5]  # clicks, seconds from the start
DRIFT_LIMIT = PTS_TOLERANCE_FRAMES / SAMPLE_RATE  # 20 ms


class Rough:
    """A Bluetooth-like link: stamps jitter by ±5 ms, 0.5 % of IO cycles
    are lost, and now and then nothing arrives for 30-80 ms (the audio of
    the stall is lost). Healthy, if not pretty."""

    STALLS = [(4.1, 0.03), (9.3, 0.08), (15.7, 0.05), (24.2, 0.06), (30.8, 0.04), (35.4, 0.07)]  # clear of MARKS

    def __init__(self, seed: int):
        self.rng = np.random.default_rng(seed)

    def deliver(self, t: float) -> float | None:
        """The stamp of the cycle at ``t``, or None when it is lost."""
        rel = t - T0
        if any(at <= rel < at + length for at, length in self.STALLS) or self.rng.random() < 0.005:
            return None
        return t + self.rng.uniform(-0.005, 0.005)


@pytest.fixture(autouse=True)
def fake_coremedia(monkeypatch):
    """CoreMedia's accessors, for the fake sample buffers below."""
    for name, fn in {
        "CMSampleBufferGetFormatDescription": lambda sb: sb,
        "CMAudioFormatDescriptionGetStreamBasicDescription": lambda desc: desc.asbd,
        "CMSampleBufferGetDataBuffer": lambda sb: sb,
        "CMBlockBufferGetDataLength": lambda block: len(block.data),
        "CMBlockBufferCopyDataBytes": lambda block, offset, length, dest: (0, block.data[offset:offset + length]),
        "CMSampleBufferGetPresentationTimeStamp": lambda sb: sb.pts,
        "CMTimeGetSeconds": lambda pts: pts,
    }.items():
        monkeypatch.setattr(capture_recorder, name, fn)


def _signal(tone: float, times: np.ndarray) -> np.ndarray:
    """What is said (mic) or played (system) at host ``times``."""
    rel = times - T0
    x = 0.2 * np.sin(2 * np.pi * tone * rel)
    for m in MARKS:
        x[(rel >= m) & (rel < m + 0.005)] = 0.9
    return x.astype(np.float32)


# ---------------- fake CoreAudio: the Process Tap's backend ----------------


@dataclass
class Output:
    """An output device, the clock of the tap's aggregate device."""

    uid: str
    name: str
    rate: float  # what the hardware runs at now
    channels: int = 2
    claims: float | None = None  # kAudioTapPropertyFormat's rate; None: the same as ``rate``
    alive: bool = True  # False: no IO cycles (a Bluetooth profile switch)
    frames: int | None = None  # frames per IO cycle; None: 10 ms worth
    ppm: float = 0.0  # the device's clock against host time (+: fast)


class _TS:
    def __init__(self, host: int):
        self.mHostTime = host


class _Buffer:
    def __init__(self, samples: np.ndarray, channels: int):
        self.mData = samples.astype(np.float32).tobytes()
        self.mDataByteSize = len(self.mData)
        self.mNumberChannels = channels


class _Desc:
    def UUID(self):
        return self

    def UUIDString(self):
        return "tap-uid"


class FakeCoreAudio:
    """CoreAudio as the Process Tap sees it. ``reports_rate=False`` is the
    tap before a857e49: it never asked the device its rate and trusted the
    tap's format."""

    def __init__(self, output: Output, *, reports_rate: bool = True, rough: Rough | None = None,
                 tick_hz: float = 1e9):
        self.output = output  # the default output device
        self.reports_rate = reports_rate
        self.rough = rough
        self.tick_hz = tick_hz  # host-time ticks a second: 24 MHz on Apple silicon
        self.aggregates: dict[int, dict] = {}
        self.fail_aggregate: ProcessTapError | None = None
        self._next = 40

    def translate_pid(self, pid):
        return 1

    def create_tap_description(self, excluded):
        return _Desc()

    def create_process_tap(self, description):
        return 7

    def tap_uid_for_description(self, description):
        return "tap-uid"

    def read_tap_format(self, tap_id):
        return _TapFormat(sample_rate=self.output.claims or self.output.rate, channels=self.output.channels)

    def device_sample_rate(self, device_id):
        if not self.reports_rate:
            return None
        return self.aggregates[device_id]["output"].rate

    def create_aggregate_device(self, tap_uid):
        if self.fail_aggregate is not None:
            raise self.fail_aggregate
        self._next += 1
        self.aggregates[self._next] = {"output": self.output, "callback": None, "running": False}
        return self._next

    def create_io_proc_id(self, device_id, callback):
        self.aggregates[device_id]["callback"] = callback
        return f"io-{device_id}"

    def start_device(self, device_id, io_proc_id):
        self.aggregates[device_id]["running"] = True

    def stop_device(self, device_id, io_proc_id):
        self.aggregates[device_id]["running"] = False

    def destroy_io_proc_id(self, device_id, io_proc_id):
        pass

    def destroy_aggregate_device(self, device_id):
        self.aggregates.pop(device_id, None)

    def destroy_process_tap(self, tap_id):
        pass

    def default_output_uid(self):
        return self.output.uid

    def default_output_name(self):
        return self.output.name

    def host_time_to_seconds(self, host_time):
        return host_time / self.tick_hz

    def _cycle(self, agg: dict, at: float, n: int, rate: float) -> None:
        out = agg["output"]
        mono = _signal(SYSTEM_TONE, at + np.arange(n) / rate)
        frames = np.repeat(mono, out.channels)  # interleaved
        host = _TS(int(round(at * self.tick_hz)))
        agg["callback"](host, [_Buffer(frames, out.channels)], host, None, object())

    def render(self, t: float, dt: float) -> None:
        """One IO cycle of every running aggregate whose clock device is
        still the default output (the old one goes quiet on a switch)."""
        for agg in list(self.aggregates.values()):
            out = agg["output"]
            if not (agg["running"] and out is self.output and out.alive):
                agg.pop("next", None)
                continue
            if out.frames:  # whole cycles of the device's own clock
                rate = out.rate * (1 + out.ppm * 1e-6)
                agg.setdefault("next", t)
                while agg["next"] < t + dt - 1e-12:
                    self._cycle(agg, agg["next"], out.frames, rate)
                    agg["next"] += out.frames / rate
                continue
            stamp = self.rough.deliver(t) if self.rough else t
            if stamp is None:
                continue
            n = int(round(out.rate * dt))
            mono = _signal(SYSTEM_TONE, t + np.arange(n) / out.rate)
            frames = np.repeat(mono, out.channels)  # interleaved
            host = _TS(int(round(stamp * 1e9)))
            agg["callback"](host, [_Buffer(frames, out.channels)], host, None, object())


# ---------------- fake AVFoundation: the microphone's backend ----------------


@dataclass
class Input:
    uid: str
    name: str
    rate: float
    layout: str = "float32"  # "float32" mono, "int16x2" interleaved, "float32x2planar"
    muted: bool = False  # delivers digital silence
    level: float = 1.0  # a quiet speaker: the signal scaled down


class _SampleBuffer:
    """A CMSampleBuffer as the fake CoreMedia accessors read it: the
    AudioStreamBasicDescription as pyobjc hands it back, the bytes, the stamp."""

    LPCM = 0x6C70636D

    def __init__(self, mono: np.ndarray, rate: float, layout: str, pts: float):
        if layout == "int16x2":
            pcm = np.repeat(np.clip(mono * 32_767, -32_768, 32_767).astype(np.int16), 2)
            flags, channels, bits = 0x4 | 0x8, 2, 16  # signed integer, packed
        elif layout == "float32x2planar":
            pcm = np.concatenate([mono, mono]).astype(np.float32)
            flags, channels, bits = 0x1 | 0x8 | 0x20, 2, 32  # float, packed, non-interleaved
        else:
            pcm = mono.astype(np.float32)
            flags, channels, bits = 0x1 | 0x8, 1, 32
        self.data = pcm.tobytes()
        self.asbd = (float(rate), self.LPCM, flags, 0, 1, 0, channels, bits)
        self.pts = pts


class _MicSession:
    def __init__(self, device: Input, on_buffer):
        self.device, self.on_buffer, self.running = device, on_buffer, False

    def start(self):
        self.running = True

    def stop(self):
        self.running = False


class FakeAVFoundation:
    AUTHORIZED, DENIED = 3, 2  # AVAuthorizationStatus

    def __init__(self, *devices: Input, rough: Rough | None = None):
        self.devices = {d.uid: d for d in devices}
        self.default: str | None = devices[0].uid
        self.status = self.AUTHORIZED
        self.delivering = True
        self.rough = rough
        self.sessions: list[_MicSession] = []

    def default_input_uid(self):
        av_mic.check_authorization(self.status)  # the real status → error mapping
        if self.default is None:
            raise AVMicError("no microphone available")
        return self.default

    def open_session(self, uid, on_buffer):
        session = _MicSession(self.devices[uid], on_buffer)
        self.sessions.append(session)
        return session

    def device_name(self, uid):
        return self.devices[uid].name

    def render(self, t: float, dt: float) -> None:
        if not self.delivering:
            return
        for s in self.sessions:
            if not s.running:
                continue
            stamp = self.rough.deliver(t) if self.rough else t
            if stamp is None:
                continue
            d = s.device
            n = int(round(d.rate * dt))
            x = _signal(MIC_TONE, t + np.arange(n) / d.rate) * d.level
            if d.muted or self.status != self.AUTHORIZED:
                x = np.zeros(n, dtype=np.float32)
            # Decoded by the production path, as the capture delegate does.
            av_mic.deliver_sample_buffer(_SampleBuffer(x, d.rate, d.layout, stamp), s.on_buffer)


# ---------------- the recorder, stepped by the test ----------------


class _SteppedRecorder(CaptureRecorder):
    """The production recorder, pumped by the test instead of its writer
    thread, so time is the simulation's."""

    def _start_writer(self) -> None:
        pass


@dataclass
class Run:
    rec: CaptureRecorder
    mic: np.ndarray
    system: np.ndarray
    mic_rate: int
    system_rate: int
    problems: list[dict]
    devices: tuple[str | None, str | None]  # (mic, output) as the status showed them before the stop
    hints: list[list[dict]]  # the soft hints, as the status showed them each second


Event = Callable[[FakeCoreAudio, FakeAVFoundation], None]


def run(tmp_path: Path, output: Output, *mics: Input, seconds: float = 40.0,
        events: dict[float, Event] | None = None, reports_rate: bool = True,
        setup: Callable[[FakeCoreAudio, FakeAVFoundation], None] | None = None, rough: bool = False,
        tweak: Callable[[CaptureRecorder], None] | None = None, tick_hz: float = 1e9) -> Run:
    ca = FakeCoreAudio(output, reports_rate=reports_rate, rough=Rough(1) if rough else None, tick_hz=tick_hz)
    av = FakeAVFoundation(*mics, rough=Rough(2) if rough else None)
    if setup:
        setup(ca, av)
    rec = _SteppedRecorder(
        tmp_path / "mic_raw.wav", tmp_path / "system.wav",
        system_tap_factory=lambda cb: ProcessTap(cb, excluded_pids=[1], backend=ca, route_poll_interval=None),
        mic_capture_factory=lambda cb: AVMicCapture(cb, backend=av, route_poll_interval=None),
    )
    now = [T0]
    rec._clock = lambda: now[0] + LATENCY
    rec.start()
    if tweak:
        tweak(rec)
    hints = []
    pending = sorted((events or {}).items())
    steps = int(round(seconds / STEP))
    for k in range(steps):
        t = T0 + k * STEP
        now[0] = t
        while pending and k * STEP >= pending[0][0] - 1e-9:
            pending.pop(0)[1](ca, av)
        if k and k % 100 == 0:  # the route watchers poll once a second
            rec._system_tap._check_route()
            rec._mic_capture._check_route()
            hints.append(rec.hints)
        ca.render(t, STEP)
        av.render(t, STEP)
        while rec._drain_once():
            pass
        rec._check_health()
    now[0] = T0 + seconds
    devices = (rec.mic_device, rec.system_device)
    rec.stop()
    mic, mic_rate = sf.read(str(tmp_path / "mic_raw.wav"), dtype="float32")
    system, system_rate = sf.read(str(tmp_path / "system.wav"), dtype="float32")
    return Run(rec, mic, system, mic_rate, system_rate, rec.problems, devices, hints)


def _pitch(x: np.ndarray) -> float:
    spectrum = np.abs(np.fft.rfft(x.astype(np.float64) * np.hanning(len(x))))
    return float(np.fft.rfftfreq(len(x), 1 / SAMPLE_RATE)[np.argmax(spectrum)])


def _clicks(x: np.ndarray) -> list[float]:
    idx = np.flatnonzero(x > 0.6)
    if not len(idx):
        return []
    groups = np.split(idx, np.flatnonzero(np.diff(idx) > SAMPLE_RATE // 10) + 1)
    return [g[0] / SAMPLE_RATE for g in groups]


# ---------------- the matrix ----------------

SPEAKERS = Output("BuiltInSpeakerDevice", "MacBook Pro Speakers", 48_000)
HEADPHONES = Output("BuiltInHeadphoneOutputDevice", "External Headphones", 44_100)
BUILTIN_MIC = Input("BuiltInMicrophoneDevice", "MacBook Pro Microphone", 48_000)


def _airpods_join_call(ca: FakeCoreAudio, av: FakeAVFoundation) -> None:
    """The call opens the AirPods' mic: A2DP → HFP. The output drops to
    24 kHz (the tap's format still says 48 kHz) after a short silence, and
    the AirPods become the default input."""
    ca.output.rate, ca.output.alive = 24_000, False
    av.default = "AirPodsMic"


def _airpods_audio_back(ca: FakeCoreAudio, av: FakeAVFoundation) -> None:
    ca.output.alive = True


def _switch_to_headphones(ca: FakeCoreAudio, av: FakeAVFoundation) -> None:
    ca.output = Output("BuiltInHeadphoneOutputDevice", "External Headphones", 44_100)


def _rate_change(ca: FakeCoreAudio, av: FakeAVFoundation) -> None:
    """Audio MIDI Setup: the same devices switch from 48 to 44.1 kHz."""
    ca.output.rate = 44_100
    for d in av.devices.values():
        d.rate = 44_100


@dataclass
class Row:
    output: Output
    mics: tuple[Input, ...]
    rates: tuple[float, float]  # (mic, system) at the end, before resampling
    names: tuple[str, str]  # (mic, output) at the end
    events: dict[float, Event] = field(default_factory=dict)
    unsettled: tuple[tuple[float, float], ...] = ()  # (from, to): following a change; not checked for pitch
    rough: bool = False
    tick_hz: float = 1e9


def _airpods() -> Output:
    return Output("AirPods-Out", "AirPods Pro", 48_000, claims=48_000)


MATRIX = {
    "built-in speakers": lambda: Row(
        SPEAKERS, (BUILTIN_MIC,), (48_000, 48_000), ("MacBook Pro Microphone", "MacBook Pro Speakers")),
    "wired headphones": lambda: Row(
        HEADPHONES, (BUILTIN_MIC,), (48_000, 44_100), ("MacBook Pro Microphone", "External Headphones")),
    "AirPods, A2DP to HFP mid-call": lambda: Row(
        _airpods(),
        (Input(BUILTIN_MIC.uid, BUILTIN_MIC.name, 48_000), Input("AirPodsMic", "AirPods Pro", 24_000)),
        (24_000, 24_000), ("AirPods Pro", "AirPods Pro"),
        events={20.0: _airpods_join_call, 20.3: _airpods_audio_back},
        unsettled=((20.0, 21.0),)),
    "external interface at 44.1 kHz": lambda: Row(
        Output("Scarlett", "Scarlett 2i2", 44_100, claims=48_000),
        (Input("ScarlettIn", "Scarlett 2i2", 44_100, layout="int16x2"),),
        (44_100, 44_100), ("Scarlett 2i2", "Scarlett 2i2")),
    "external interface at 96 kHz": lambda: Row(
        Output("UltraLite", "UltraLite-mk5", 96_000, channels=4, claims=48_000),
        (Input("UltraLiteIn", "UltraLite-mk5", 96_000, layout="float32x2planar"),),
        (96_000, 96_000), ("UltraLite-mk5", "UltraLite-mk5")),
    "output switched mid-call": lambda: Row(
        Output(SPEAKERS.uid, SPEAKERS.name, 48_000), (BUILTIN_MIC,), (48_000, 44_100),
        ("MacBook Pro Microphone", "External Headphones"),
        events={20.0: _switch_to_headphones}, unsettled=((20.0, 21.0),)),
    "sample rate changed mid-call": lambda: Row(
        Output(SPEAKERS.uid, SPEAKERS.name, 48_000),
        (Input(BUILTIN_MIC.uid, BUILTIN_MIC.name, 48_000),), (44_100, 44_100),
        ("MacBook Pro Microphone", "MacBook Pro Speakers"),
        events={20.0: _rate_change}, unsettled=((20.0, 21.0),)),
    "1024-frame cycles, 24 MHz host ticks, device clock 20 ppm slow": lambda: Row(
        Output(SPEAKERS.uid, SPEAKERS.name, 48_000, frames=1024, ppm=-20), (BUILTIN_MIC,), (48_000, 48_000),
        ("MacBook Pro Microphone", "MacBook Pro Speakers"), tick_hz=24e6),
    "2048-frame cycles, 24 MHz host ticks, device clock 20 ppm fast": lambda: Row(
        Output(SPEAKERS.uid, SPEAKERS.name, 48_000, frames=2048, ppm=20), (BUILTIN_MIC,), (48_000, 48_000),
        ("MacBook Pro Microphone", "MacBook Pro Speakers"), tick_hz=24e6),
    "Bluetooth-like link: jitter, lost cycles, short stalls": lambda: Row(
        Output("Headset", "Jabra Evolve2", 48_000), (Input("HeadsetMic", "Jabra Evolve2", 16_000),),
        (16_000, 48_000), ("Jabra Evolve2", "Jabra Evolve2"), rough=True),
}


@pytest.mark.parametrize("name", list(MATRIX))
def test_device_matrix(tmp_path: Path, name: str):
    row = MATRIX[name]()
    r = run(tmp_path, row.output, *row.mics, events=row.events, rough=row.rough, tick_hz=row.tick_hz)
    seconds = 40.0

    # Rate: both files are 16 kHz mono, whatever the devices ran at.
    assert (r.mic_rate, r.system_rate) == (SAMPLE_RATE, SAMPLE_RATE)
    assert r.mic.ndim == r.system.ndim == 1

    # Duration against wall-clock time.
    for track in (r.mic, r.system):
        assert abs(len(track) / SAMPLE_RATE - seconds) <= 0.05, f"{len(track) / SAMPLE_RATE:.3f} s"

    # Speed: the tone keeps its pitch everywhere but right after a change
    # (the route watcher polls once a second) or a stall.
    stalls = tuple((at, at + length) for at, length in Rough.STALLS) if row.rough else ()
    for track, tone in ((r.mic, MIC_TONE), (r.system, SYSTEM_TONE)):
        for second in range(1, int(seconds) - 1):
            if any(lo - 1 <= second < hi + 1 for lo, hi in row.unsettled + stalls):
                continue
            window = track[second * SAMPLE_RATE:(second + 1) * SAMPLE_RATE]
            assert abs(_pitch(window) - tone) <= tone * 0.01, f"{tone} Hz track at {second} s: {_pitch(window)} Hz"

    # Drift: each click lands within 20 ms of when it happened, on both tracks.
    for track in (r.mic, r.system):
        found = _clicks(track)
        assert len(found) == len(MARKS), found
        for got, want in zip(found, MARKS):
            assert abs(got - want) <= DRIFT_LIMIT, f"click at {got:.4f} s, played at {want} s"

    # Health: no warning on a healthy setup, and the status knows the devices.
    assert r.problems == []
    assert not any(r.hints)
    assert (r.rec.mic_rate, r.rec.system_rate) == row.rates
    assert r.devices == row.names


# ---------------- detect, don't trust: the same rows going wrong ----------------


def test_airpods_with_a_tap_that_trusts_its_format_warn_of_the_wrong_speed(tmp_path: Path):
    """The 2026-10-29 bug: the tap's format said 48 kHz while AirPods ran at
    24 kHz, so the system track came out at double speed with gaps. Should
    a device ever lie again, the recording says so within seconds."""
    r = run(tmp_path, _airpods(), BUILTIN_MIC, Input("AirPodsMic", "AirPods Pro", 24_000),
            events={20.0: _airpods_join_call, 20.3: _airpods_audio_back}, reports_rate=False)
    speed = [p for p in r.problems if p["kind"] == "speed"]
    assert [p["track"] for p in speed] == ["system"]
    assert 20.0 <= speed[0]["start"] <= 28.0
    assert speed[0]["end"] == pytest.approx(40.0, abs=0.5)  # still wrong when it stopped
    assert not [p for p in r.problems if p["track"] == "mic"]


@pytest.mark.parametrize("frames,ppm", [(1024, -20), (1024, 20), (2048, 0), (2048, -20), (2048, 20)])
def test_the_airpods_misread_warns_with_long_io_cycles_and_host_ticks(tmp_path: Path, frames: int, ppm: float):
    """A 2x misread with 20-ms-plus cycles sat on the old continuity bound:
    it never warned."""
    airpods = Output("AirPods-Out", "AirPods Pro", 48_000, claims=48_000, frames=frames, ppm=ppm)
    r = run(tmp_path, airpods, BUILTIN_MIC, Input("AirPodsMic", "AirPods Pro", 24_000),
            events={20.0: _airpods_join_call, 20.3: _airpods_audio_back}, reports_rate=False, tick_hz=24e6)
    assert [(p["kind"], p["track"]) for p in r.problems] == [("speed", "system")]
    assert 20.0 <= r.problems[0]["start"] <= 28.0


def test_lost_io_cycles_are_gaps_not_a_wrong_speed(tmp_path: Path):
    """5 % of IO cycles lost, with exact stamps: each loss is a jump of
    exactly one cycle, like a 2x misread for that one pair."""
    rng = np.random.default_rng(5)

    def lossy(ca, av):
        cycle = ca._cycle

        def maybe(agg, at, n, rate):
            if rng.random() >= 0.05:
                cycle(agg, at, n, rate)

        ca._cycle = maybe

    r = run(tmp_path, Output(SPEAKERS.uid, SPEAKERS.name, 48_000, frames=512), BUILTIN_MIC,
            seconds=40.0, setup=lossy, tick_hz=24e6)
    assert r.problems == []


def test_lost_microphone_permission_is_a_warning(tmp_path: Path):
    """The authorization status turns to denied (System Settings): the
    real status-to-error mapping makes it an "access" problem."""
    def revoke(ca, av):
        av.status = FakeAVFoundation.DENIED

    r = run(tmp_path, SPEAKERS, BUILTIN_MIC, seconds=30.0, events={15.0: revoke})
    assert [(p["kind"], p["track"]) for p in r.problems] == [("access", "mic")]
    assert r.problems[0]["start"] == pytest.approx(15.0, abs=0.3)  # when it was seen, though opened 4 s later


def test_a_tap_that_cannot_be_rebuilt_is_a_warning(tmp_path: Path):
    """kAudioHardwareIllegalOperationError on the rebuild: not proof of a
    lost permission, so said plainly."""
    def switch_refused(ca, av):
        _switch_to_headphones(ca, av)
        ca.fail_aggregate = ProcessTapError("aggregate device creation failed", os_status=1852797029)  # 'nope'

    r = run(tmp_path, Output(SPEAKERS.uid, SPEAKERS.name, 48_000), BUILTIN_MIC, seconds=30.0,
            events={15.0: switch_refused})
    assert [(p["kind"], p["track"]) for p in r.problems] == [("device", "system")]
    assert r.problems[0]["start"] == pytest.approx(15.0, abs=0.3)


def test_no_microphone_for_a_second_while_airpods_switch_is_no_warning(tmp_path: Path):
    def gone(ca, av):
        _airpods_join_call(ca, av)
        av.default = None  # between the two microphones

    def back(ca, av):
        av.default = "AirPodsMic"

    r = run(tmp_path, _airpods(), BUILTIN_MIC, Input("AirPodsMic", "AirPods Pro", 24_000),
            events={20.0: gone, 20.3: _airpods_audio_back, 21.5: back})
    assert r.problems == []


def test_a_muted_microphone_while_the_others_talk_is_only_a_hint(tmp_path: Path):
    """A soft line in the status, no warning, no notification; kept on the
    meeting page only because it stayed muted to the end."""
    muted = Input(BUILTIN_MIC.uid, BUILTIN_MIC.name, 48_000, muted=True)
    r = run(tmp_path, SPEAKERS, muted, seconds=75.0)
    shown = [i for i, h in enumerate(r.hints, start=1) if h]
    assert shown and 60 <= shown[0] <= 62 and r.hints[-1] == [{"kind": "silent", "track": "mic"}]
    assert [(p["kind"], p["track"], p["end"]) for p in r.problems] == [("silent", "mic", 75.0)]


def test_a_quiet_participant_is_not_a_warning(tmp_path: Path):
    """Someone who only listens still has a noise floor: not silence."""
    quiet = Input(BUILTIN_MIC.uid, BUILTIN_MIC.name, 48_000, level=0.001)  # about -70 dBFS
    r = run(tmp_path, SPEAKERS, quiet, seconds=75.0)
    assert r.problems == [] and not any(r.hints)


def test_a_microphone_that_stops_delivering_is_a_warning(tmp_path: Path):
    def stall(ca, av):
        av.delivering = False

    r = run(tmp_path, SPEAKERS, BUILTIN_MIC, seconds=50.0, events={10.0: stall})
    stalled = [p for p in r.problems if p["kind"] == "stalled"]
    assert [p["track"] for p in stalled] == ["mic"]
    assert 39.0 <= stalled[0]["start"] <= 41.0


def test_a_track_out_of_step_with_the_clock_is_a_length_warning_not_a_speed_one(tmp_path: Path):
    """Stamps that keep pace with the samples but not with the clock: the
    source delivers 54 s of audio a minute. Its speed is right; its length
    is not."""
    def slow_clock(ca, av):
        render = av.render

        def lagging(t, dt):
            render(T0 + (t - T0) * 0.9, dt * 0.9)

        av.render = lagging

    r = run(tmp_path, SPEAKERS, BUILTIN_MIC, seconds=60.0, setup=slow_clock)
    assert [(p["kind"], p["track"]) for p in r.problems] == [("length", "mic")]


def test_a_failing_health_monitor_never_stops_the_recording(tmp_path: Path, caplog):
    """The monitor runs on the writer thread: whatever it raises, the audio
    still reaches disk, and the failure is logged at debug, not per buffer."""
    import logging

    def boom(*_args, **_kwargs):
        raise RuntimeError("health monitor bug")

    def break_health(rec):
        for name in ("chunk", "check", "reanchor", "close_all", "problems", "hints", "is_open", "open_problems"):
            setattr(rec._health, name, boom)

    caplog.set_level(logging.DEBUG, logger="palaver.capture_recorder")
    r = run(tmp_path, SPEAKERS, BUILTIN_MIC, seconds=20.0, tweak=break_health)
    for track in (r.mic, r.system):
        assert abs(len(track) / SAMPLE_RATE - 20.0) <= 0.05
        assert len(_clicks(track)) == 4
    assert r.problems == []
    failures = [rec for rec in caplog.records if "health monitor failed" in rec.getMessage()]
    assert failures and all(rec.levelno == logging.DEBUG for rec in failures)
    assert len(failures) <= 3
    # Made visible once: session.log says the warnings are off.
    off = [rec for rec in caplog.records if rec.levelno == logging.WARNING
           and rec.getMessage() == "Audio health checks failed; warnings are off for this recording"]
    assert len(off) == 1
