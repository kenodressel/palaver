"""Core Audio Process Tap wrapper for system-audio capture.

The public contract is intentionally tiny: ``ProcessTap`` starts CoreAudio,
downmixes callback buffers to mono float32 at the tap's native rate, and
reports chunks on the CoreAudio host-time clock. Resampling is left to the
consumer, which can keep filter state across chunks (a per-chunk resampler
clicks at every ~10 ms boundary) and keeps the realtime callback short.

The IO proc runs on the clock device's cycle, silence included: every
recording's system and mic tracks ended within 0.1 s of each other. A tap
that delivers nothing has lost its device and is rebuilt.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import logging
import os
import threading
import time
import uuid
import warnings
from dataclasses import dataclass
from typing import Callable, Protocol

import numpy as np


LOGGER = logging.getLogger(__name__)

# An aggregate that delivered nothing this long is rebuilt, then after twice
# as long each time it stays quiet, up to the maximum.
QUIET_REBUILD_SECONDS = 5.0
QUIET_REBUILD_MAX_SECONDS = 60.0


class ProcessTapError(RuntimeError):
    def __init__(self, message: str, os_status: int | None = None):
        super().__init__(message)
        self.os_status = os_status


@dataclass(frozen=True)
class _TapFormat:
    sample_rate: float
    channels: int


class _Backend(Protocol):
    def translate_pid(self, pid: int) -> int | None: ...
    def create_tap_description(self, excluded_processes: list[int]): ...
    def create_process_tap(self, description) -> int: ...
    def read_tap_format(self, tap_id: int) -> _TapFormat: ...
    def device_sample_rate(self, device_id: int) -> float | None: ...
    def create_aggregate_device(self, tap_uid: str) -> int: ...
    def create_io_proc_id(self, device_id: int, callback) -> object: ...
    def start_device(self, device_id: int, io_proc_id: object) -> None: ...
    def stop_device(self, device_id: int, io_proc_id: object) -> None: ...
    def destroy_io_proc_id(self, device_id: int, io_proc_id: object) -> None: ...
    def destroy_aggregate_device(self, device_id: int) -> None: ...
    def destroy_process_tap(self, tap_id: int) -> None: ...
    def default_output_uid(self) -> str: ...
    def default_output_name(self) -> str | None: ...
    def host_time_to_seconds(self, host_time: int) -> float: ...


class _AudioObjectPropertyAddress(ctypes.Structure):
    _fields_ = [
        ("mSelector", ctypes.c_uint32),
        ("mScope", ctypes.c_uint32),
        ("mElement", ctypes.c_uint32),
    ]


class _AudioStreamBasicDescription(ctypes.Structure):
    _fields_ = [
        ("mSampleRate", ctypes.c_double),
        ("mFormatID", ctypes.c_uint32),
        ("mFormatFlags", ctypes.c_uint32),
        ("mBytesPerPacket", ctypes.c_uint32),
        ("mFramesPerPacket", ctypes.c_uint32),
        ("mBytesPerFrame", ctypes.c_uint32),
        ("mChannelsPerFrame", ctypes.c_uint32),
        ("mBitsPerChannel", ctypes.c_uint32),
        ("mReserved", ctypes.c_uint32),
    ]


def _format_osstatus(status: int) -> str:
    try:
        raw = int(status).to_bytes(4, "big", signed=False)
        if all(32 <= b < 127 for b in raw):
            return f"{status} ('{raw.decode('ascii')}')"
    except Exception:
        pass
    return str(status)


class _CoreAudioBackend:
    def __init__(self):
        import CoreAudio

        self.ca = CoreAudio
        lib_path = ctypes.util.find_library("CoreAudio")
        if not lib_path:
            raise ProcessTapError("CoreAudio framework not found")
        self._lib = ctypes.CDLL(lib_path)
        self._lib.AudioObjectGetPropertyData.argtypes = [
            ctypes.c_uint32,
            ctypes.POINTER(_AudioObjectPropertyAddress),
            ctypes.c_uint32,
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_uint32),
            ctypes.c_void_p,
        ]
        self._lib.AudioObjectGetPropertyData.restype = ctypes.c_int32
        # AudioDeviceStart/Stop/DestroyIOProcID take an AudioDeviceIOProcID
        # which is an opaque pointer-typed handle. pyobjc declares the param
        # type as `^?` (function pointer) and refuses to round-trip a value
        # it returned from AudioDeviceCreateIOProcIDWithBlock, raising
        # `ValueError: calling method/function with 'undefined' argument`.
        # Call these via ctypes with a plain void* instead — we extract the
        # raw address from the pyobjc-returned object's pointerAsInteger.
        self._lib.AudioDeviceStart.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
        self._lib.AudioDeviceStart.restype = ctypes.c_int32
        self._lib.AudioDeviceStop.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
        self._lib.AudioDeviceStop.restype = ctypes.c_int32
        self._lib.AudioDeviceDestroyIOProcID.argtypes = [
            ctypes.c_uint32,
            ctypes.c_void_p,
        ]
        self._lib.AudioDeviceDestroyIOProcID.restype = ctypes.c_int32

    @staticmethod
    def _io_proc_address(io_proc_id) -> int:
        # The PyObjCPointer wrapper exposes the underlying handle as an int.
        return int(getattr(io_proc_id, "pointerAsInteger", 0) or int(io_proc_id))

    def translate_pid(self, pid: int) -> int | None:
        addr = self._property_address(
            self.ca.kAudioHardwarePropertyTranslatePIDToProcessObject
        )
        pid_value = ctypes.c_int32(int(pid))
        out = ctypes.c_uint32(0)
        size = ctypes.c_uint32(ctypes.sizeof(out))
        status = self._lib.AudioObjectGetPropertyData(
            self.ca.kAudioObjectSystemObject,
            ctypes.byref(addr),
            ctypes.sizeof(pid_value),
            ctypes.byref(pid_value),
            ctypes.byref(size),
            ctypes.byref(out),
        )
        if status != self.ca.kAudioHardwareNoError:
            raise self._error_for_status("process-object translation failed", status)
        return int(out.value) or None

    def create_tap_description(self, excluded_processes: list[int]):
        desc = (
            self.ca.CATapDescription.alloc()
            .initMonoGlobalTapButExcludeProcesses_(excluded_processes)
        )
        desc.setName_("Palaver System Audio Tap")
        desc.setPrivate_(True)
        desc.setMuteBehavior_(self.ca.CATapUnmuted)
        if hasattr(desc, "setMixdown_"):
            desc.setMixdown_(True)
        if hasattr(desc, "setMono_"):
            desc.setMono_(True)
        return desc

    def create_process_tap(self, description) -> int:
        status, tap_id = self.ca.AudioHardwareCreateProcessTap(description, None)
        if status != self.ca.kAudioHardwareNoError:
            raise self._error_for_status("process tap creation failed", status)
        if not tap_id:
            raise ProcessTapError("process tap creation returned no tap id")
        return int(tap_id)

    def read_tap_format(self, tap_id: int) -> _TapFormat:
        addr = self._property_address(self.ca.kAudioTapPropertyFormat)
        asbd = _AudioStreamBasicDescription()
        size = ctypes.c_uint32(ctypes.sizeof(asbd))
        status = self._lib.AudioObjectGetPropertyData(
            int(tap_id),
            ctypes.byref(addr),
            0,
            None,
            ctypes.byref(size),
            ctypes.byref(asbd),
        )
        if status != self.ca.kAudioHardwareNoError:
            raise self._error_for_status("tap format lookup failed", status)
        channels = int(asbd.mChannelsPerFrame) or 1
        sample_rate = float(asbd.mSampleRate) or 48_000.0
        return _TapFormat(sample_rate=sample_rate, channels=channels)

    def device_sample_rate(self, device_id: int) -> float | None:
        addr = self._property_address(self.ca.kAudioDevicePropertyNominalSampleRate)
        rate = ctypes.c_double(0.0)
        size = ctypes.c_uint32(ctypes.sizeof(rate))
        status = self._lib.AudioObjectGetPropertyData(
            int(device_id),
            ctypes.byref(addr),
            0,
            None,
            ctypes.byref(size),
            ctypes.byref(rate),
        )
        if status != self.ca.kAudioHardwareNoError:
            raise self._error_for_status("sample rate lookup failed", status)
        return float(rate.value) or None

    def create_aggregate_device(self, tap_uid: str) -> int:
        # CoreAudio's aggregate-device key constants come from pyobjc as bytes
        # (e.g. b'name', b'taps'). CFDictionary expects CFString keys; passing
        # bytes results in a malformed dict that segfaults inside
        # AudioHardwareCreateAggregateDevice. Decode to str.
        def _k(key) -> str:
            if isinstance(key, bytes):
                return key.decode("ascii")
            return key

        # Aggregate needs a master/main subdevice for its clock. Without one,
        # CoreAudio invokes the IO proc once and stalls. Using the system's
        # default output device is the conventional pattern (e.g. AudioCap).
        # The output device is declared as a sub-device so it can serve as
        # the master; it contributes only a clock, not any audio input.
        master_uid = self.default_output_uid()
        master_key = getattr(
            self.ca,
            "kAudioAggregateDeviceMainSubDeviceKey",
            self.ca.kAudioAggregateDeviceMasterSubDeviceKey,
        )

        props = {
            _k(self.ca.kAudioAggregateDeviceNameKey): "Palaver System Audio",
            _k(self.ca.kAudioAggregateDeviceUIDKey): (
                f"palaver.system-tap.{uuid.uuid4()}"
            ),
            _k(master_key): master_uid,
            _k(self.ca.kAudioAggregateDeviceIsPrivateKey): True,
            _k(self.ca.kAudioAggregateDeviceIsStackedKey): False,
            _k(self.ca.kAudioAggregateDeviceTapAutoStartKey): True,
            _k(self.ca.kAudioAggregateDeviceSubDeviceListKey): [
                {_k(self.ca.kAudioSubDeviceUIDKey): master_uid},
            ],
            _k(self.ca.kAudioAggregateDeviceTapListKey): [
                {
                    _k(self.ca.kAudioSubTapDriftCompensationKey): True,
                    _k(self.ca.kAudioSubTapUIDKey): tap_uid,
                }
            ],
        }
        status, device_id = self.ca.AudioHardwareCreateAggregateDevice(props, None)
        if status != self.ca.kAudioHardwareNoError:
            raise self._error_for_status("aggregate device creation failed", status)
        if not device_id:
            raise ProcessTapError("aggregate device creation returned no device id")
        return int(device_id)

    def create_io_proc_id(self, device_id: int, callback) -> object:
        # Use the block-based variant. The C-function-pointer variant
        # (AudioDeviceCreateIOProcID) bridges Python callables in a way that
        # segfaults when CoreAudio's realtime audio thread invokes them on
        # macOS 26 / pyobjc's current CoreAudio bindings. The block variant
        # uses pyobjc's well-tested ObjC-block bridging instead.
        #
        # pyobjc's metadata types the block's inOutputTime as in/out (``N^``
        # instead of the header's const pointer), so the Python callable must
        # return it — see ProcessTap._handle_io. Returning None made the IO
        # proc die silently after its first buffer (issue #19).
        import objc

        with warnings.catch_warnings():
            # The IOProcID is an opaque handle; pyobjc warns that it wraps
            # it as a raw pointer.
            warnings.simplefilter("ignore", objc.ObjCPointerWarning)
            status, io_proc_id = self.ca.AudioDeviceCreateIOProcIDWithBlock(
                None, int(device_id), None, callback
            )
        if status != self.ca.kAudioHardwareNoError:
            raise self._error_for_status("IO proc registration failed", status)
        if io_proc_id is None:
            raise ProcessTapError("IO proc registration returned no IO proc id")
        return io_proc_id

    def start_device(self, device_id: int, io_proc_id: object) -> None:
        addr = self._io_proc_address(io_proc_id)
        status = self._lib.AudioDeviceStart(int(device_id), addr)
        if status != self.ca.kAudioHardwareNoError:
            raise self._error_for_status("audio device start failed", status)

    def stop_device(self, device_id: int, io_proc_id: object) -> None:
        addr = self._io_proc_address(io_proc_id)
        self._log_stop_status(
            "AudioDeviceStop", self._lib.AudioDeviceStop(int(device_id), addr)
        )

    def destroy_io_proc_id(self, device_id: int, io_proc_id: object) -> None:
        addr = self._io_proc_address(io_proc_id)
        self._log_stop_status(
            "AudioDeviceDestroyIOProcID",
            self._lib.AudioDeviceDestroyIOProcID(int(device_id), addr),
        )

    def destroy_aggregate_device(self, device_id: int) -> None:
        self._log_stop_status(
            "AudioHardwareDestroyAggregateDevice",
            self.ca.AudioHardwareDestroyAggregateDevice(int(device_id)),
        )

    def destroy_process_tap(self, tap_id: int) -> None:
        self._log_stop_status(
            "AudioHardwareDestroyProcessTap",
            self.ca.AudioHardwareDestroyProcessTap(int(tap_id)),
        )

    def host_time_to_seconds(self, host_time: int) -> float:
        return float(self.ca.AudioConvertHostTimeToNanos(int(host_time))) * 1e-9

    def default_output_uid(self) -> str:
        """Return the UID string of the system's default output device.

        Used as the master subdevice when assembling our aggregate so the
        aggregate has a running clock and CoreAudio actually pumps audio
        into the tap continuously (without a master, the IO proc fires
        once and stalls).
        """
        device_id = self._default_device_id(self.ca.kAudioHardwarePropertyDefaultOutputDevice)
        return self._string_property(
            device_id, self.ca.kAudioDevicePropertyDeviceUID, "default output device UID lookup failed"
        )

    def default_output_name(self) -> str | None:
        """The default output's name, e.g. "AirPods Pro" (for the status)."""
        device_id = self._default_device_id(self.ca.kAudioHardwarePropertyDefaultOutputDevice)
        return self._string_property(device_id, self.ca.kAudioObjectPropertyName, "device name lookup failed")

    def default_device(self, scope: str) -> tuple[str | None, float | None]:
        """(name, nominal rate) of the default "input" or "output" device —
        read-only properties: nothing is opened or played."""
        selector = (
            self.ca.kAudioHardwarePropertyDefaultInputDevice if scope == "input"
            else self.ca.kAudioHardwarePropertyDefaultOutputDevice
        )
        try:
            device_id = self._default_device_id(selector)
        except ProcessTapError:
            return None, None
        name = self._string_property(device_id, self.ca.kAudioObjectPropertyName, "device name lookup failed")
        return name, self.device_sample_rate(device_id)

    def _default_device_id(self, selector: int) -> int:
        # The device ID via ctypes (uint32 out-param).
        addr = self._property_address(selector)
        device_id = ctypes.c_uint32(0)
        size = ctypes.c_uint32(ctypes.sizeof(device_id))
        status = self._lib.AudioObjectGetPropertyData(
            self.ca.kAudioObjectSystemObject,
            ctypes.byref(addr),
            0,
            None,
            ctypes.byref(size),
            ctypes.byref(device_id),
        )
        if status != self.ca.kAudioHardwareNoError or device_id.value == 0:
            raise self._error_for_status("default device lookup failed", status)
        return int(device_id.value)

    def _string_property(self, object_id: int, selector: int, message: str) -> str:
        # A CFStringRef: read the pointer via ctypes, convert to a Python
        # str via CoreFoundation. CFString returned from
        # AudioObjectGetPropertyData has +1 retain count (the caller owns it
        # and must CFRelease).
        addr = self._property_address(selector)
        cfstring_ref = ctypes.c_void_p(0)
        size = ctypes.c_uint32(ctypes.sizeof(cfstring_ref))
        status = self._lib.AudioObjectGetPropertyData(
            int(object_id),
            ctypes.byref(addr),
            0,
            None,
            ctypes.byref(size),
            ctypes.byref(cfstring_ref),
        )
        if status != self.ca.kAudioHardwareNoError or not cfstring_ref.value:
            raise self._error_for_status(message, status)
        try:
            return _cfstring_to_python(cfstring_ref.value)
        finally:
            _cf_release(cfstring_ref.value)

    def tap_uid_for_description(self, description) -> str:
        value = description.UUID()
        if hasattr(value, "UUIDString"):
            value = value.UUIDString()
        return str(value)

    def _property_address(self, selector: int) -> _AudioObjectPropertyAddress:
        return _AudioObjectPropertyAddress(
            int(selector),
            int(self.ca.kAudioObjectPropertyScopeGlobal),
            int(self.ca.kAudioObjectPropertyElementMain),
        )

    def _error_for_status(self, message: str, status: int) -> ProcessTapError:
        if status == self.ca.kAudioHardwareIllegalOperationError:
            return ProcessTapError(
                "permission denied - System Settings -> Privacy -> "
                "System Audio Recording",
                os_status=int(status),
            )
        if status == self.ca.kAudioHardwareUnsupportedOperationError:
            return ProcessTapError(
                "requires macOS 14.4+ and an audio output device",
                os_status=int(status),
            )
        return ProcessTapError(
            f"{message}: OSStatus {_format_osstatus(int(status))}",
            os_status=int(status),
        )

    def _log_stop_status(self, action: str, status: int) -> None:
        if status != self.ca.kAudioHardwareNoError:
            LOGGER.warning("%s returned OSStatus %s", action, _format_osstatus(status))


class ProcessTap:
    """Global "everything but us" system-audio tap.

    The private aggregate device that carries the tap takes its clock from
    the default output device at creation time. When the default output
    changes (AirPods connect, headphones unplugged), a watcher thread
    rebuilds the aggregate on the new device; otherwise the tap goes quiet.
    It also rebuilds an aggregate that delivers nothing on the same device:
    built at 48 kHz on AirPods that a call took to 24 kHz a second later,
    one delivered nothing for a whole call. The rebuild leaves a short PTS
    gap, which the consumer zero-pads.
    """

    def __init__(
        self,
        on_chunk: Callable[[float, np.ndarray, float], None],
        *,
        excluded_pids: list[int] | None = None,
        backend: _Backend | None = None,
        route_poll_interval: float | None = 1.0,
        clock: Callable[[], float] = time.monotonic,
    ):
        self._on_chunk = on_chunk
        self._excluded_pids = excluded_pids
        self._backend = backend or _CoreAudioBackend()
        self._route_poll_interval = route_poll_interval
        self._tap_description = None
        self._tap_id: int | None = None
        self._aggregate_id: int | None = None
        self._io_proc_id: object | None = None
        self._io_proc = self._handle_io
        self._source_rate = 48_000.0
        self._source_channels = 1
        self._started = False
        self._clock = clock
        # When the aggregate last delivered (or was built), whether it has,
        # and how often it was rebuilt for delivering nothing since one did.
        self._last_audio = clock()
        self._delivered = False
        self._quiet_rebuilds = 0
        self._output_uid: str | None = None
        # For the status (issue #50): the device the tap is clocked by, and
        # "device" while the tap can't be rebuilt on a new output.
        self.output_name: str | None = None
        self.problem: str | None = None
        self._lock = threading.Lock()
        self._watch_stop = threading.Event()
        self._watcher: threading.Thread | None = None

    def start(self) -> None:
        if self._started or self._tap_id is not None or self._aggregate_id is not None:
            raise ProcessTapError("ProcessTap already started")
        try:
            excluded_objects = self._resolve_excluded_processes()
            self._tap_description = self._backend.create_tap_description(
                excluded_objects
            )
            self._tap_id = self._backend.create_process_tap(self._tap_description)
            with self._lock:
                self._open_aggregate()
            self._started = True
        except BaseException:
            self.stop()
            raise
        if self._route_poll_interval:
            self._watch_stop.clear()
            self._watcher = threading.Thread(
                target=self._watch_default_output, daemon=True
            )
            self._watcher.start()

    def stop(self) -> None:
        self._watch_stop.set()
        watcher = self._watcher
        if watcher is not None and watcher is not threading.current_thread():
            watcher.join(timeout=5.0)
        self._watcher = None
        with self._lock:
            self._close_aggregate()
        tap_id = self._tap_id
        if tap_id is not None:
            self._backend.destroy_process_tap(tap_id)
        self._tap_id = None
        self._tap_description = None
        self._started = False

    def _open_aggregate(self) -> None:
        """Create the aggregate on the current default output and start IO."""
        self._output_uid = self._backend.default_output_uid()
        self.output_name = self._output_name()
        # The tap's mixdown format follows the output device; re-read it so
        # chunks after a rebuild carry the right rate.
        fmt = self._backend.read_tap_format(self._tap_id)
        self._source_rate = fmt.sample_rate
        self._source_channels = max(1, int(fmt.channels))
        tap_uid = self._tap_uid(self._tap_description)
        self._aggregate_id = self._backend.create_aggregate_device(tap_uid)
        # Buffers arrive at the aggregate's rate, which is its clock
        # device's: 24 kHz for AirPods in a call, whatever the tap says.
        self._follow_device_rate()
        self._last_audio, self._delivered = self._clock(), False
        self._io_proc_id = self._backend.create_io_proc_id(
            self._aggregate_id, self._io_proc
        )
        # No first-buffer gate: a quiet start is not a failure; the route
        # watcher rebuilds an aggregate that stays quiet.
        self._backend.start_device(self._aggregate_id, self._io_proc_id)

    def _close_aggregate(self) -> None:
        aggregate_id = self._aggregate_id
        io_proc_id = self._io_proc_id
        if aggregate_id is not None and io_proc_id is not None:
            self._backend.stop_device(aggregate_id, io_proc_id)
            self._backend.destroy_io_proc_id(aggregate_id, io_proc_id)
        if aggregate_id is not None:
            self._backend.destroy_aggregate_device(aggregate_id)
        self._io_proc_id = None
        self._aggregate_id = None

    def _watch_default_output(self) -> None:
        assert self._route_poll_interval
        while not self._watch_stop.wait(self._route_poll_interval):
            self._check_route()

    def _check_route(self) -> None:
        """One look at the default output: follow its rate, or rebuild the
        aggregate on a new one, or on the same one when it delivers nothing."""
        try:
            uid = self._backend.default_output_uid()
        except ProcessTapError:
            return  # transient while devices are switching
        if uid != self._output_uid:
            LOGGER.warning(
                "default output changed (%s → %s); rebuilding system audio tap",
                self._output_uid,
                uid,
            )
            self._rebuild()
            return
        with self._lock:
            self._follow_device_rate()
        quiet = self._clock() - self._last_audio
        wait = min(QUIET_REBUILD_SECONDS * 2 ** self._quiet_rebuilds, QUIET_REBUILD_MAX_SECONDS)
        if quiet >= wait:
            LOGGER.warning("system audio tap delivered nothing for %.0f s; rebuilding it", quiet)
            self._quiet_rebuilds += 1
            self._rebuild()
        elif self._quiet_rebuilds and self._delivered:
            LOGGER.info("system audio tap delivers again")
            self._quiet_rebuilds = 0

    def _rebuild(self) -> None:
        """A new aggregate on the current default output."""
        with self._lock:
            if self._watch_stop.is_set():
                return
            self._close_aggregate()
            try:
                self._open_aggregate()
            except Exception:
                # The old aggregate is gone; keep retrying every tick
                # rather than letting the watcher thread die. Not a
                # permission problem as far as anyone can tell
                # (kAudioHardwareIllegalOperationError proves nothing):
                # "device", for the status (issue #50).
                if self.problem is None:
                    LOGGER.exception("rebuilding system audio tap failed; retrying")
                self.problem = "device"
                try:
                    self._close_aggregate()
                except Exception:
                    LOGGER.debug("cleanup after failed rebuild failed", exc_info=True)
                    self._io_proc_id = self._aggregate_id = None
                self._output_uid = None  # forces another attempt next tick
            else:
                if self.problem is not None:
                    LOGGER.info("system audio tap rebuilt; recording again")
                self.problem = None

    def _output_name(self) -> str | None:
        name = getattr(self._backend, "default_output_name", None)
        try:
            return name() if name else None
        except Exception:  # the name is for the status; recording goes on without it
            return None

    def _follow_device_rate(self) -> None:
        """Take the aggregate's current rate. It changes without a new
        default output: AirPods drop from 48 to 24 kHz once a call opens
        their mic; read at the old rate, the system track came out at double
        speed with gaps."""
        if self._aggregate_id is None:
            return
        try:
            rate = self._backend.device_sample_rate(self._aggregate_id)
        except ProcessTapError:
            return
        if rate and rate != self._source_rate:
            LOGGER.warning("system audio rate %g Hz → %g Hz", self._source_rate, rate)
            self._source_rate = rate

    def _resolve_excluded_processes(self) -> list[int]:
        pids = (
            list(self._excluded_pids)
            if self._excluded_pids is not None
            else [os.getpid(), os.getppid()]
        )
        process_objects: list[int] = []
        for index, pid in enumerate(dict.fromkeys(p for p in pids if p and p > 0)):
            try:
                process_id = self._backend.translate_pid(pid)
            except ProcessTapError:
                if index == 0:
                    raise
                LOGGER.info("parent PID %s is not a CoreAudio process", pid)
                continue
            if process_id is not None:
                process_objects.append(process_id)
            elif index == 0:
                LOGGER.info("current PID %s has no CoreAudio process object", pid)
        return process_objects

    def _tap_uid(self, description) -> str:
        if hasattr(self._backend, "tap_uid_for_description"):
            return self._backend.tap_uid_for_description(description)  # type: ignore[attr-defined]
        value = description.UUID()
        if hasattr(value, "UUIDString"):
            value = value.UUIDString()
        return str(value)

    def _handle_io(
        self,
        in_now,
        in_input_data,
        in_input_time,
        _out_output_data,
        in_output_time,
    ):
        # Block-style callback: no device id, no clientData. pyobjc handles
        # the block-context pointer internally — Python sees only the 5 audio
        # args. Every path must return ``in_output_time`` (see
        # _CoreAudioBackend.create_io_proc_id).
        try:
            self._deliver(in_now, in_input_data, in_input_time)
        except Exception:
            LOGGER.exception("ProcessTap IO callback failed")
        return in_output_time

    def _deliver(self, in_now, in_input_data, in_input_time) -> None:
        samples = self._samples_from_buffer_list(in_input_data)
        if samples is None or samples.size == 0:
            return
        timestamp = in_input_time if in_input_time is not None else in_now
        host_time = int(getattr(timestamp, "mHostTime", 0) or 0)
        if host_time == 0:
            return
        pts = self._backend.host_time_to_seconds(host_time)
        self._last_audio, self._delivered = self._clock(), True
        self._on_chunk(pts, samples, float(self._source_rate))

    def _samples_from_buffer_list(self, buffer_list) -> np.ndarray | None:
        if buffer_list is None:
            return None
        try:
            if len(buffer_list) == 0:
                return None
            buffer = buffer_list[0]
        except Exception:
            return None

        byte_size = int(getattr(buffer, "mDataByteSize", 0) or 0)
        if byte_size <= 0:
            return None
        data = getattr(buffer, "mData", None)
        if data is None:
            return None

        samples = _float32_array_from_buffer(data, byte_size)
        if samples.size == 0:
            return None

        channels = int(getattr(buffer, "mNumberChannels", 0) or self._source_channels)
        channels = max(channels, 1)
        if channels > 1 and samples.size >= channels:
            frames = samples.size // channels
            samples = samples[: frames * channels]
            samples = samples.reshape(frames, channels).mean(axis=1)
        return np.asarray(samples, dtype=np.float32)


def _float32_array_from_buffer(data, byte_size: int) -> np.ndarray:
    item_count = byte_size // np.dtype(np.float32).itemsize
    if item_count <= 0:
        return np.empty(0, dtype=np.float32)
    if isinstance(data, (bytes, bytearray, memoryview)):
        return np.frombuffer(memoryview(data)[:byte_size], dtype=np.float32).copy()
    address = _pointer_value(data)
    if address is None:
        return np.empty(0, dtype=np.float32)
    array_type = ctypes.c_float * item_count
    return np.ctypeslib.as_array(array_type.from_address(address)).copy()


def _cfstring_to_python(cfstring_ptr: int) -> str:
    """Convert a CFStringRef pointer to a Python str via CoreFoundation."""
    cf = ctypes.CDLL(ctypes.util.find_library("CoreFoundation"))
    cf.CFStringGetLength.argtypes = [ctypes.c_void_p]
    cf.CFStringGetLength.restype = ctypes.c_long
    cf.CFStringGetMaximumSizeForEncoding.argtypes = [ctypes.c_long, ctypes.c_uint32]
    cf.CFStringGetMaximumSizeForEncoding.restype = ctypes.c_long
    cf.CFStringGetCString.argtypes = [
        ctypes.c_void_p,
        ctypes.c_char_p,
        ctypes.c_long,
        ctypes.c_uint32,
    ]
    cf.CFStringGetCString.restype = ctypes.c_bool
    utf8 = 0x08000100  # kCFStringEncodingUTF8
    length = cf.CFStringGetLength(cfstring_ptr)
    max_size = cf.CFStringGetMaximumSizeForEncoding(length, utf8) + 1
    buf = ctypes.create_string_buffer(max_size)
    if not cf.CFStringGetCString(cfstring_ptr, buf, max_size, utf8):
        raise ProcessTapError("CFString -> Python conversion failed")
    return buf.value.decode("utf-8")


def _cf_release(cf_ptr: int) -> None:
    if not cf_ptr:
        return
    cf = ctypes.CDLL(ctypes.util.find_library("CoreFoundation"))
    cf.CFRelease.argtypes = [ctypes.c_void_p]
    cf.CFRelease.restype = None
    cf.CFRelease(cf_ptr)


def _pointer_value(value) -> int | None:
    if isinstance(value, int):
        return value
    if isinstance(value, ctypes.c_void_p):
        return int(value.value) if value.value else None
    raw = getattr(value, "value", None)
    if isinstance(raw, int):
        return raw
    try:
        return int(value)
    except Exception:
        return None

