"""Tests for the AVCaptureSession microphone source (no hardware)."""

import time

import pytest

from palaver._audio.av_mic import AVMicCapture, AVMicError


class _FakeSession:
    def __init__(self, uid, on_buffer):
        self.uid, self.on_buffer = uid, on_buffer
        self.running = False

    def start(self):
        self.running = True

    def stop(self):
        self.running = False


class _FakeBackend:
    def __init__(self, uid="BuiltInMicrophoneDevice", fail=False):
        self.uid = uid
        self.fail = fail
        self.sessions: list[_FakeSession] = []

    def default_input_uid(self):
        return self.uid

    def open_session(self, uid, on_buffer):
        if self.fail:
            raise AVMicError("microphone access denied")
        self.sessions.append(_FakeSession(uid, on_buffer))
        return self.sessions[-1]


def _wait_for(predicate, timeout=2.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.005)
    return False


def test_start_opens_session_on_default_input_and_forwards_chunks():
    chunks = []
    backend = _FakeBackend()
    mic = AVMicCapture(lambda *c: chunks.append(c), backend=backend, route_poll_interval=None)
    mic.start()

    session = backend.sessions[0]
    assert session.uid == "BuiltInMicrophoneDevice" and session.running
    session.on_buffer(12.5, [0.1, 0.2], 48_000.0)
    assert chunks == [(12.5, [0.1, 0.2], 48_000.0)]

    mic.stop()
    assert not session.running


def test_start_failure_raises():
    mic = AVMicCapture(lambda *c: None, backend=_FakeBackend(fail=True), route_poll_interval=None)
    with pytest.raises(AVMicError, match="denied"):
        mic.start()


def test_follows_default_input_change():
    """AirPods connect mid-meeting: record from them instead of going quiet."""
    backend = _FakeBackend()
    mic = AVMicCapture(lambda *c: None, backend=backend, route_poll_interval=0.01)
    mic.start()
    backend.uid = "AirPods-UID"

    assert _wait_for(lambda: len(backend.sessions) == 2)
    old, new = backend.sessions
    assert not old.running and new.running and new.uid == "AirPods-UID"
    mic.stop()
    assert not new.running


def test_rebuild_failure_keeps_retrying():
    backend = _FakeBackend()
    mic = AVMicCapture(lambda *c: None, backend=backend, route_poll_interval=0.01)
    mic.start()
    backend.fail = True
    backend.uid = "AirPods-UID"
    time.sleep(0.05)
    backend.fail = False
    assert _wait_for(lambda: len(backend.sessions) == 2 and backend.sessions[1].running)
    mic.stop()


def test_sink_class_is_defined_once_per_process():
    from palaver._audio.av_mic import _sink_class

    assert _sink_class() is _sink_class()


class _NamedBackend(_FakeBackend):
    NAMES = {"BuiltInMicrophoneDevice": "MacBook Pro Microphone", "AirPods-UID": "AirPods"}

    def device_name(self, uid):
        return self.NAMES[uid]


def test_names_the_microphone_it_records_from():
    """The menu says which mic records (issue #47), also after a switch."""
    backend = _NamedBackend()
    mic = AVMicCapture(lambda *c: None, backend=backend, route_poll_interval=0.01)
    mic.start()
    assert mic.device_name == "MacBook Pro Microphone"
    backend.uid = "AirPods-UID"
    assert _wait_for(lambda: mic.device_name == "AirPods")
    mic.stop()
    assert AVMicCapture(lambda *c: None, backend=_FakeBackend(), route_poll_interval=None).device_name is None
