"""Microphone capture via AVCaptureSession.

Raw device input (no voice processing), delivered as CMSampleBuffers whose
presentation timestamps are on the host clock — the same clock as the
system-audio Process Tap, so the two tracks align by PTS. Needs only the
Microphone permission (ScreenCaptureKit's microphone output also needs Screen
Recording, which macOS revokes from time to time).

The session is bound to one device; a watcher rebuilds it on the new default
input when that changes (AirPods connect, headphones unplugged). The rebuild
leaves a short PTS gap, which the writer zero-pads.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import logging
import threading
from typing import Callable, Protocol

LOGGER = logging.getLogger(__name__)


class AVMicError(RuntimeError):
    pass


class AVMicPermissionError(AVMicError):
    """The authorization status says no: a real permission problem."""


# AVAuthorizationStatus
_RESTRICTED, _DENIED = 1, 2


def check_authorization(status: int) -> None:
    """Raise AVMicPermissionError for a microphone authorization status
    that forbids recording."""
    if status in (_RESTRICTED, _DENIED):
        raise AVMicPermissionError("microphone access denied")


def deliver_sample_buffer(sample_buffer, callback) -> None:
    """Decode a CMSampleBuffer from the capture output and hand
    ``(pts, mono samples, native rate)`` to ``callback``. The rate is read
    from the buffer's own format, so a device that changes rate is followed."""
    from ..capture_recorder import _cmsample_pts_seconds, _cmsample_to_mono

    decoded = _cmsample_to_mono(sample_buffer)
    pts = _cmsample_pts_seconds(sample_buffer)
    if decoded is not None and pts is not None:
        callback(pts, decoded[0], decoded[1])


class _Session(Protocol):
    def start(self) -> None: ...
    def stop(self) -> None: ...


OnBuffer = Callable[[float, object, float], None]


_SINK = None


def _sink_class():
    """The AVCaptureAudioDataOutput delegate, defined once per process
    (Objective-C classes are process-global)."""
    global _SINK
    if _SINK is not None:
        return _SINK
    import objc
    from Foundation import NSObject

    # The protocol exists in the runtime only once AVFoundation is loaded (on
    # macOS 15 nothing else loads it first). Declaring it is a courtesy: the
    # capture output calls the delegate by its selector either way.
    import AVFoundation  # noqa: F401

    try:
        protocols = [objc.protocolNamed("AVCaptureAudioDataOutputSampleBufferDelegate")]
    except objc.ProtocolError:
        protocols = []

    class _MicSink(NSObject, protocols=protocols):
        def initWithCallback_(self, callback):
            self = objc.super(_MicSink, self).init()
            if self is None:
                return None
            self._callback = callback
            return self

        def captureOutput_didOutputSampleBuffer_fromConnection_(self, output, sample_buffer, connection):
            deliver_sample_buffer(sample_buffer, self._callback)

    _SINK = _MicSink
    return _SINK


class _AVFoundationSession:
    def __init__(self, uid: str, on_buffer: OnBuffer):
        import AVFoundation as AVF
        import objc

        device = AVF.AVCaptureDevice.deviceWithUniqueID_(uid)
        if device is None:
            raise AVMicError(f"input device {uid} not found")
        device_input, error = AVF.AVCaptureDeviceInput.deviceInputWithDevice_error_(device, None)
        if device_input is None:
            raise AVMicError(f"microphone unavailable: {error}")
        self._session = AVF.AVCaptureSession.alloc().init()
        if not self._session.canAddInput_(device_input):
            raise AVMicError("cannot add the microphone to a capture session")
        self._session.addInput_(device_input)
        self._output = AVF.AVCaptureAudioDataOutput.alloc().init()
        self._sink = _sink_class().alloc().initWithCallback_(on_buffer)
        self._queue = objc.objc_object(c_void_p=_dispatch_queue_create(b"palaver.mic", None))
        self._output.setSampleBufferDelegate_queue_(self._sink, self._queue)
        self._session.addOutput_(self._output)

    def start(self) -> None:
        self._session.startRunning()
        if not self._session.isRunning():
            raise AVMicError("microphone capture did not start (permission denied?)")

    def stop(self) -> None:
        self._session.stopRunning()


_libsystem = ctypes.CDLL(ctypes.util.find_library("System"))
_libsystem.dispatch_queue_create.restype = ctypes.c_void_p
_libsystem.dispatch_queue_create.argtypes = [ctypes.c_char_p, ctypes.c_void_p]


def _dispatch_queue_create(label: bytes, attr):
    # pyobjc-framework-libdispatch is not a dependency; a serial queue is all
    # setSampleBufferDelegate:queue: needs.
    return _libsystem.dispatch_queue_create(label, attr)


class _AVFoundationBackend:
    def default_input_uid(self) -> str:
        import AVFoundation as AVF

        check_authorization(AVF.AVCaptureDevice.authorizationStatusForMediaType_(AVF.AVMediaTypeAudio))
        device = AVF.AVCaptureDevice.defaultDeviceWithMediaType_(AVF.AVMediaTypeAudio)
        if device is None:
            raise AVMicError("no microphone available")
        return str(device.uniqueID())

    def open_session(self, uid: str, on_buffer: OnBuffer) -> _Session:
        return _AVFoundationSession(uid, on_buffer)

    def device_name(self, uid: str) -> str | None:
        import AVFoundation as AVF

        device = AVF.AVCaptureDevice.deviceWithUniqueID_(uid)
        return str(device.localizedName()) if device is not None else None


class AVMicCapture:
    def __init__(
        self,
        on_chunk: Callable[[float, object, float], None],
        *,
        backend=None,
        route_poll_interval: float | None = 1.0,
    ):
        self._on_chunk = on_chunk
        self._backend = backend or _AVFoundationBackend()
        self._poll = route_poll_interval
        self._session: _Session | None = None
        self._uid: str | None = None
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._watcher: threading.Thread | None = None
        self.device_name: str | None = None  # of the input recorded from, e.g. "AirPods"
        # What keeps the microphone from being followed, for the status
        # (issue #50): "access" (the authorization status says no) or
        # "device" (no microphone, or it won't open); None once it works.
        self.problem: str | None = None

    def start(self) -> None:
        with self._lock:
            self._open()
        if self._poll:
            self._stop.clear()
            self._watcher = threading.Thread(target=self._watch, daemon=True)
            self._watcher.start()

    def stop(self) -> None:
        self._stop.set()
        if self._watcher is not None and self._watcher is not threading.current_thread():
            self._watcher.join(timeout=5.0)
        self._watcher = None
        with self._lock:
            self._close()

    def _open(self) -> None:
        uid = self._backend.default_input_uid()
        session = self._backend.open_session(uid, self._on_chunk)
        session.start()
        self._session, self._uid = session, uid
        try:
            self.device_name = getattr(self._backend, "device_name", lambda _uid: None)(uid)
        except Exception:  # the name is for the menu; recording goes on without it
            self.device_name = None

    def _close(self) -> None:
        session, self._session = self._session, None
        if session is not None:
            session.stop()

    def _watch(self) -> None:
        while not self._stop.wait(self._poll):
            self._check_route()

    def _check_route(self) -> None:
        """One look at the default input: follow it when it changed."""
        try:
            uid = self._backend.default_input_uid()
        except AVMicError as exc:
            self._report("access" if isinstance(exc, AVMicPermissionError) else "device", exc)
            return
        except Exception:
            return  # transient while devices switch
        if uid == self._uid:
            self.problem = None
            return
        LOGGER.warning("microphone changed (%s → %s); following it", self._uid, uid)
        with self._lock:
            if self._stop.is_set():
                return
            self._close()
            try:
                self._open()
            except Exception as exc:
                LOGGER.exception("switching microphone failed; retrying")
                self._report("access" if isinstance(exc, AVMicPermissionError) else "device", exc)
                self._uid = None  # forces another attempt next tick
            else:
                self.problem = None

    def _report(self, kind: str, exc: Exception) -> None:
        if self.problem != kind:
            LOGGER.warning("microphone: %s", exc)
        self.problem = kind
