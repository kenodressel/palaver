from __future__ import annotations

import numpy as np
import pytest

from palaver._audio.process_tap import (
    ProcessTap,
    ProcessTapError,
    _TapFormat,
)


class _FakeUUID:
    def UUIDString(self):
        return "tap-uid"


class _FakeDescription:
    def UUID(self):
        return _FakeUUID()


class _FakeTimestamp:
    def __init__(self, host_time: int):
        self.mHostTime = host_time


class _FakeBuffer:
    def __init__(self, samples: np.ndarray, channels: int):
        self._payload = np.asarray(samples, dtype=np.float32).tobytes()
        self.mData = self._payload
        self.mDataByteSize = len(self._payload)
        self.mNumberChannels = channels


_OUTPUT_TIME = object()


class _FakeBackend:
    def __init__(self, *, deliver: bool = True, fail_start: bool = False):
        self.deliver = deliver
        self.fail_start = fail_start
        self.callback_results: list[object] = []
        self.output_uid = "BuiltInSpeakerDevice"
        self.device_rate = 48_000.0
        self.next_aggregate_id = 20
        self.calls: list[tuple] = []
        self.excluded: list[int] | None = None
        self.tap_uid: str | None = None

    def translate_pid(self, pid: int) -> int | None:
        self.calls.append(("translate", pid))
        return {1234: 99, 4321: None}.get(pid, 1000 + pid)

    def create_tap_description(self, excluded_processes: list[int]):
        self.calls.append(("description", tuple(excluded_processes)))
        self.excluded = list(excluded_processes)
        return _FakeDescription()

    def create_process_tap(self, description) -> int:
        self.calls.append(("create_tap",))
        return 10

    def read_tap_format(self, tap_id: int) -> _TapFormat:
        self.calls.append(("format", tap_id))
        return _TapFormat(sample_rate=48_000.0, channels=2)

    def device_sample_rate(self, device_id: int) -> float | None:
        return self.device_rate

    def create_aggregate_device(self, tap_uid: str) -> int:
        self.calls.append(("create_aggregate", tap_uid, self.output_uid))
        self.tap_uid = tap_uid
        return self.next_aggregate_id

    def create_io_proc_id(self, device_id: int, callback):
        self.calls.append(("create_io", device_id))
        self.callback = callback
        return "io-proc"

    def start_device(self, device_id: int, io_proc_id: object) -> None:
        self.calls.append(("start", device_id, io_proc_id))
        if self.fail_start:
            raise ProcessTapError("AudioDeviceStart failed", os_status=-1)
        if self.deliver:
            # 480 frames at 48 kHz stereo -> 480 mono frames at native rate.
            frame = np.column_stack(
                [
                    np.ones(480, dtype=np.float32),
                    np.zeros(480, dtype=np.float32),
                ]
            ).reshape(-1)
            # Block-style callback signature: 5 args (in_now, in_input_data,
            # in_input_time, out_output_data, in_output_time). pyobjc handles
            # the block-context pointer internally. See _handle_io.
            self.callback_results.append(
                self.callback(
                    _FakeTimestamp(123_000_000),
                    [_FakeBuffer(frame, channels=2)],
                    _FakeTimestamp(123_000_000),
                    None,
                    _OUTPUT_TIME,
                )
            )

    def stop_device(self, device_id: int, io_proc_id: object) -> None:
        self.calls.append(("stop", device_id, io_proc_id))

    def destroy_io_proc_id(self, device_id: int, io_proc_id: object) -> None:
        self.calls.append(("destroy_io", device_id, io_proc_id))

    def destroy_aggregate_device(self, device_id: int) -> None:
        self.calls.append(("destroy_aggregate", device_id))

    def destroy_process_tap(self, tap_id: int) -> None:
        self.calls.append(("destroy_tap", tap_id))

    def default_output_uid(self) -> str:
        return self.output_uid

    def host_time_to_seconds(self, host_time: int) -> float:
        return host_time * 1e-9

    def tap_uid_for_description(self, description) -> str:
        return description.UUID().UUIDString()


def test_start_translates_pids_and_wires_aggregate_uid():
    chunks: list[tuple[float, np.ndarray, float]] = []
    backend = _FakeBackend()
    tap = ProcessTap(
        lambda pts, samples, rate: chunks.append((pts, samples, rate)),
        excluded_pids=[1234, 4321],
        backend=backend,
    )

    tap.start()

    assert backend.excluded == [99]
    assert backend.tap_uid == "tap-uid"
    assert ("create_aggregate", "tap-uid", "BuiltInSpeakerDevice") in backend.calls
    assert len(chunks) == 1
    pts, samples, rate = chunks[0]
    assert pts == pytest.approx(0.123)
    assert samples.dtype == np.float32
    assert rate == 48_000.0
    assert len(samples) == 480
    np.testing.assert_allclose(samples, 0.5)

    tap.stop()
    assert backend.calls[-4:] == [
        ("stop", 20, "io-proc"),
        ("destroy_io", 20, "io-proc"),
        ("destroy_aggregate", 20),
        ("destroy_tap", 10),
    ]


def test_io_callback_returns_output_time(caplog):
    """pyobjc's CoreAudio metadata marks the IO block's inOutputTime as an
    in/out argument, so the Python block must hand it back. Returning None
    kills the IO proc silently after the first buffer (issue #19)."""
    backend = _FakeBackend()
    tap = ProcessTap(lambda *_: None, excluded_pids=[1234], backend=backend)
    tap.start()
    assert backend.callback_results == [_OUTPUT_TIME]

    def _boom(*_):
        raise RuntimeError("consumer failed")

    tap._on_chunk = _boom
    assert backend.callback(None, None, None, None, _OUTPUT_TIME) is _OUTPUT_TIME
    assert backend.callback(
        _FakeTimestamp(1), [_FakeBuffer(np.ones(4), channels=1)], None, None, _OUTPUT_TIME
    ) is _OUTPUT_TIME
    tap.stop()


def test_start_succeeds_while_nothing_is_playing():
    """Starting does not wait for a first buffer: a tap that is quiet at
    first must not cost the recording (a quiet one is rebuilt later)."""
    backend = _FakeBackend(deliver=False)
    tap = ProcessTap(lambda *_: None, excluded_pids=[1234], backend=backend)

    tap.start()
    tap.stop()

    assert backend.calls[-4:] == [
        ("stop", 20, "io-proc"),
        ("destroy_io", 20, "io-proc"),
        ("destroy_aggregate", 20),
        ("destroy_tap", 10),
    ]


def test_start_failure_cleans_up():
    backend = _FakeBackend(fail_start=True)
    tap = ProcessTap(lambda *_: None, excluded_pids=[1234], backend=backend)

    with pytest.raises(ProcessTapError, match="AudioDeviceStart failed"):
        tap.start()

    assert backend.calls[-4:] == [
        ("stop", 20, "io-proc"),
        ("destroy_io", 20, "io-proc"),
        ("destroy_aggregate", 20),
        ("destroy_tap", 10),
    ]


def test_stop_is_idempotent():
    backend = _FakeBackend()
    tap = ProcessTap(lambda *_: None, excluded_pids=[1234], backend=backend)
    tap.start()
    tap.stop()
    calls_after_first_stop = list(backend.calls)

    tap.stop()

    assert backend.calls == calls_after_first_stop



def _wait_for(predicate, timeout: float = 2.0) -> bool:
    import time

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.005)
    return False


def test_rebuilds_tap_when_default_output_changes():
    """The aggregate's clock comes from the default output device at creation
    time. When the user switches output (AirPods connect, headphones
    unplugged), the tap must be rebuilt on the new device or it goes quiet."""
    backend = _FakeBackend(deliver=False)
    tap = ProcessTap(
        lambda *_: None, excluded_pids=[1234], backend=backend, route_poll_interval=0.01
    )
    tap.start()

    backend.next_aggregate_id = 21
    backend.output_uid = "AirPods-UID"
    assert _wait_for(
        lambda: ("create_aggregate", "tap-uid", "AirPods-UID") in backend.calls
    )
    assert _wait_for(lambda: ("start", 21, "io-proc") in backend.calls)
    # Old aggregate was torn down before the new one was created.
    first_teardown = backend.calls.index(("destroy_aggregate", 20))
    rebuild = backend.calls.index(("create_aggregate", "tap-uid", "AirPods-UID"))
    assert first_teardown < rebuild

    tap.stop()
    assert backend.calls[-4:] == [
        ("stop", 21, "io-proc"),
        ("destroy_io", 21, "io-proc"),
        ("destroy_aggregate", 21),
        ("destroy_tap", 10),
    ]


def test_chunks_carry_the_devices_rate_not_the_taps():
    """AirPods in a call run at 24 kHz while the tap still says 48 kHz; read
    at 48 kHz the system track came out at double speed with gaps."""
    chunks = []
    backend = _FakeBackend()
    backend.device_rate = 24_000.0
    tap = ProcessTap(lambda pts, samples, rate: chunks.append(rate), excluded_pids=[1234], backend=backend)
    tap.start()
    assert chunks == [24_000.0]
    tap.stop()


def test_follows_a_rate_change_on_the_same_output(caplog):
    """A call opening the AirPods' mic drops them to 24 kHz; the default
    output stays the same device, so nothing is rebuilt."""
    backend = _FakeBackend(deliver=False)
    tap = ProcessTap(
        lambda *_: None, excluded_pids=[1234], backend=backend, route_poll_interval=0.01
    )
    tap.start()
    backend.device_rate = 24_000.0
    assert _wait_for(lambda: tap._source_rate == 24_000.0)
    assert [c for c in backend.calls if c[0] == "create_aggregate"] == [
        ("create_aggregate", "tap-uid", "BuiltInSpeakerDevice")]
    tap.stop()


def test_route_watcher_stops_with_tap():
    backend = _FakeBackend(deliver=False)
    tap = ProcessTap(
        lambda *_: None, excluded_pids=[1234], backend=backend, route_poll_interval=0.01
    )
    tap.start()
    tap.stop()
    calls = list(backend.calls)

    backend.output_uid = "AirPods-UID"
    assert not _wait_for(lambda: backend.calls != calls, timeout=0.1)


def test_route_watcher_survives_unexpected_rebuild_errors(caplog):
    """A non-ProcessTapError during a rebuild must not kill the watcher —
    the old aggregate is already gone, so it has to keep retrying."""
    backend = _FakeBackend(deliver=False)
    tap = ProcessTap(
        lambda *_: None, excluded_pids=[1234], backend=backend, route_poll_interval=0.01
    )
    tap.start()
    original = backend.create_aggregate_device
    failures = [1]

    def flaky(tap_uid):
        if failures[0]:
            failures[0] -= 1
            raise RuntimeError("pyobjc hiccup")
        return original(tap_uid)

    backend.create_aggregate_device = flaky
    backend.next_aggregate_id = 21
    backend.output_uid = "AirPods-UID"
    assert _wait_for(lambda: ("start", 21, "io-proc") in backend.calls)
    tap.stop()


def _buffer(backend: _FakeBackend, n: int = 240) -> None:
    """One IO cycle of the current aggregate."""
    backend.callback(_FakeTimestamp(123_000_000), [_FakeBuffer(np.zeros(n), channels=1)],
                     _FakeTimestamp(123_000_000), None, _OUTPUT_TIME)


def _quiet_tap(backend: _FakeBackend, now: list[float], chunks: list | None = None) -> ProcessTap:
    tap = ProcessTap(lambda pts, samples, rate: chunks.append(rate) if chunks is not None else None,
                     excluded_pids=[1234], backend=backend, route_poll_interval=None, clock=lambda: now[0])
    tap.start()
    return tap


def _aggregates(backend: _FakeBackend) -> int:
    return sum(1 for c in backend.calls if c[0] == "create_aggregate")


def test_a_tap_that_delivers_nothing_after_the_airpods_switch_to_a_call_is_rebuilt(caplog):
    """A Slack call on AirPods: the aggregate was built at 48 kHz, the call
    took the AirPods to 24 kHz a second later, and the tap delivered nothing
    for the 6 minutes of the call. Built on a device already at 24 kHz, it
    records (as in every other call that day)."""
    backend = _FakeBackend(deliver=False)
    now, chunks = [0.0], []
    tap = _quiet_tap(backend, now, chunks)
    now[0] = 1.0
    backend.device_rate = 24_000.0
    tap._check_route()
    assert tap._source_rate == 24_000.0 and _aggregates(backend) == 1
    now[0] = 4.9
    tap._check_route()
    assert _aggregates(backend) == 1

    now[0], backend.deliver, backend.next_aggregate_id = 5.0, True, 21
    tap._check_route()
    assert _aggregates(backend) == 2 and ("destroy_aggregate", 20) in backend.calls
    assert chunks == [24_000.0]
    assert "system audio tap delivered nothing for 5 s; rebuilding it" in caplog.text
    caplog.set_level("INFO")
    for second in range(6, 30):
        now[0] = float(second)
        _buffer(backend)
        tap._check_route()
    assert _aggregates(backend) == 2
    assert "system audio tap delivers again" in caplog.text
    tap.stop()


def test_a_tap_that_keeps_delivering_nothing_is_rebuilt_less_and_less_often():
    """Should some output deliver nothing while nothing plays after all,
    the aggregate is not rebuilt every few seconds of a quiet meeting."""
    backend = _FakeBackend(deliver=False)
    now = [0.0]
    tap = _quiet_tap(backend, now)
    rebuilt = []
    for tick in range(1, 401):
        now[0] = tick / 2
        before = _aggregates(backend)
        tap._check_route()
        if _aggregates(backend) > before:
            rebuilt.append(now[0])
    assert rebuilt == [5.0, 15.0, 35.0, 75.0, 135.0, 195.0]
    tap.stop()


def test_a_tap_that_delivers_is_never_rebuilt():
    backend = _FakeBackend()
    now = [0.0]
    tap = _quiet_tap(backend, now)
    for tick in range(1, 200):
        now[0] = tick / 10
        _buffer(backend)
        tap._check_route()
    assert _aggregates(backend) == 1
    tap.stop()
