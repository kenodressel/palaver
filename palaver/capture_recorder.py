"""Recorder that captures the microphone and system audio to two WAVs.

- Microphone: ``SCStreamOutputTypeMicrophone`` on an ``SCStream`` — the raw
  microphone input (verified RAW on macOS 26, see
  ``docs/superpowers/specs/2026-04-23-scstream-mic-verdict.md``). Written to
  ``mic_raw_path``.
- System audio: a Core Audio Process Tap (``_audio/process_tap.py``) on
  everything except this process. Unlike SCStream's audio output it is not
  starved by other recorders (Notion Meeting Recorder, Teams cloud
  recording). If the tap cannot start, the same SCStream also captures
  ``SCStreamOutputTypeAudio`` as a fallback. Written to ``system_path``.

All sources timestamp on the CoreAudio host-time clock, so PTS values are
directly comparable.

SCStream honours the configured 16 kHz mono format for system audio but
**ignores it for the microphone**, which arrives at the input device's native
rate (48 kHz for the MacBook mic, other rates for headsets — and the rate can
change mid-recording when the input device switches). Every buffer's format
is therefore read from its ``AudioStreamBasicDescription`` and each track is
streamed through its own resampler to 16 kHz before it reaches disk.

The mic and system output types do not start delivering at the same wall-clock
instant. To produce time-aligned WAVs, buffers are **indexed by PTS** relative
to a common ``start_pts`` — the *earlier* track's first PTS, so no captured
audio is ever discarded; the later track is zero-padded at the front. Each
file is finalized to its own length.

Within a track, chunks are written contiguously; PTS only overrides that when
it disagrees by more than ``PTS_TOLERANCE_FRAMES`` (a real delivery gap is
zero-padded, a real overlap is trimmed). Sub-millisecond PTS jitter is
absorbed instead of dropping or padding whole chunks.

Nothing a device says is trusted blindly (issue #50): an ``AudioHealth``
monitor watches the re-anchors, each track's length against the clock, a
microphone that sends only silence and what the capture sources report, and
keeps the incidents in ``problems`` for the status and meta.json.
"""

from __future__ import annotations

import json
import logging
import math
import os
import queue
import struct
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import numpy as np
import soxr

from . import lifecycle
from .audio_health import AudioHealth

# Hoisted to module level to avoid a pyobjc lazy-symbol-loading race when the
# first call comes from SCStream's mic receive queue (different dispatch queue
# than the system-audio one). In-function imports caused a hard crash on first
# mic buffer: KeyError: 'CMBlockBufferCopyDataBytes' propagated as NSException.
from CoreMedia import (  # noqa: E402
    CMAudioFormatDescriptionGetStreamBasicDescription,
    CMBlockBufferCopyDataBytes,
    CMBlockBufferGetDataLength,
    CMSampleBufferGetDataBuffer,
    CMSampleBufferGetFormatDescription,
    CMSampleBufferGetPresentationTimeStamp,
    CMTimeGetSeconds,
)

LOGGER = logging.getLogger(__name__)

SAMPLE_RATE = 16_000

# Contiguous-write tolerance: PTS disagreements up to 20 ms are treated as
# jitter. Larger ones are real gaps (zero-padded) or overlaps (trimmed).
PTS_TOLERANCE_FRAMES = SAMPLE_RATE // 50

# How long one track may deliver alone before start_pts is fixed without the
# other. Bounds the in-memory Phase A buffer when a track never shows up.
PHASE_A_MAX_SECONDS = 2.0

# Mic stall watchdog (#18): SCStream can stop delivering without an error.
MIC_STALL_SECONDS = 30.0
MIC_STALL_REMINDER_SECONDS = 60.0
# The tap delivers silence too while nothing plays (every recording's two
# tracks ended within 0.1 s of each other), so one that delivers nothing
# lost its device: a Slack call on AirPods got 6 min of mic and 0 s of the
# others, and nothing said so.
SYSTEM_STALL_SECONDS = 30.0

# How often the writer thread asks the health monitor (issue #50), and how
# often a failure of the monitor is logged (at debug: it must never cost audio).
HEALTH_CHECK_SECONDS = 0.25
HEALTH_FAILURE_LOG_SECONDS = 60.0
# After this many failures the monitor is off for the recording, which
# session.log says once.
HEALTH_FAILURES_OFF = 3

# SCStream.startCapture occasionally fails transiently ("Stream failed to
# start microphone", -3820) and succeeds seconds later.
SCSTREAM_START_ATTEMPTS = 3
SCSTREAM_RETRY_SECONDS = 2.0

_LPCM_FORMAT_ID = 0x6C70636D  # 'lpcm'
_FLAG_IS_FLOAT = 0x1
_FLAG_IS_NON_INTERLEAVED = 0x20


def _decode_pcm(
    buf: bytes, *, channels: int, bits: int, is_float: bool, non_interleaved: bool
) -> np.ndarray:
    """Decode linear PCM bytes into float32 mono, averaging channels.

    Non-interleaved buffers hold one contiguous block per channel, so they
    are split by channel rather than reshaped as interleaved frames.
    """
    if is_float:
        dtype = np.float32 if bits == 32 else np.float64
        arr = np.frombuffer(buf, dtype=dtype).astype(np.float32)
    else:
        dtype = {16: np.int16, 32: np.int32}[bits]
        arr = np.frombuffer(buf, dtype=dtype).astype(np.float32) / float(
            np.iinfo(dtype).max + 1
        )
    if channels > 1:
        frames = arr.size // channels
        arr = arr[: frames * channels]
        if non_interleaved:
            arr = arr.reshape(channels, frames).mean(axis=0)
        else:
            arr = arr.reshape(frames, channels).mean(axis=1)
    return arr.astype(np.float32, copy=False)


def _stream_description(sample_buffer) -> tuple | None:
    """(sample_rate, format_id, flags, channels, bits) of a CMSampleBuffer."""
    try:
        asbd = CMAudioFormatDescriptionGetStreamBasicDescription(
            CMSampleBufferGetFormatDescription(sample_buffer)
        )
    except Exception:
        return None
    if asbd is None:
        return None
    if isinstance(asbd, tuple):
        # pyobjc hands the struct back as a plain field tuple.
        rate, fmt, flags, _bpp, _fpp, _bpf, channels, bits = asbd[:8]
    else:
        rate, fmt, flags = asbd.mSampleRate, asbd.mFormatID, asbd.mFormatFlags
        channels, bits = asbd.mChannelsPerFrame, asbd.mBitsPerChannel
    return float(rate), int(fmt), int(flags), int(channels), int(bits)


def _cmsample_to_mono(sample_buffer) -> tuple[np.ndarray, float] | None:
    """Extract float32 mono samples and their native sample rate."""
    desc = _stream_description(sample_buffer)
    if desc is None:
        return None
    rate, fmt, flags, channels, bits = desc
    if fmt != _LPCM_FORMAT_ID or rate <= 0 or channels < 1:
        return None

    block = CMSampleBufferGetDataBuffer(sample_buffer)
    if block is None:
        return None
    length = CMBlockBufferGetDataLength(block)
    if length == 0:
        return None

    try:
        result = CMBlockBufferCopyDataBytes(block, 0, length, None)
    except Exception:
        return None
    if isinstance(result, tuple):
        status, buf = result
        if status != 0 or buf is None:
            return None
    else:
        buf = result
        if buf is None:
            return None

    try:
        arr = _decode_pcm(
            buf,
            channels=channels,
            bits=bits,
            is_float=bool(flags & _FLAG_IS_FLOAT),
            non_interleaved=bool(flags & _FLAG_IS_NON_INTERLEAVED),
        )
    except (KeyError, ValueError):
        return None
    if arr.size == 0:
        return None
    return arr, rate


def _cmsample_pts_seconds(sample_buffer) -> float | None:
    """Presentation timestamp of the first sample in ``sample_buffer``, in seconds.

    Uses ``CMSampleBufferGetPresentationTimeStamp`` which returns a ``CMTime``
    on the CoreMedia host-time clock. Both the mic and system output types on
    a single SCStream share this clock, so PTS values are directly comparable.
    """
    try:
        pts = CMSampleBufferGetPresentationTimeStamp(sample_buffer)
        secs = CMTimeGetSeconds(pts)
    except Exception:
        return None
    if secs is None:
        return None
    if not math.isfinite(secs):
        return None
    return float(secs)


@dataclass
class _TimedChunk:
    """A chunk of audio samples tagged with the PTS of its first sample."""

    pts: float  # seconds, on CoreMedia host-time clock
    samples: np.ndarray  # float32 mono
    rate: float = SAMPLE_RATE  # native sample rate of ``samples``


class _TrackResampler:
    """Streams one track's native-rate chunks to 16 kHz, keeping PTS exact.

    soxr's stream resampler is latency-compensated but emits output in
    bursts, so output PTS is tracked from the stream's own sample count
    rather than taken from whichever input chunk triggered the burst. The
    stream is flushed and restarted whenever the input rate changes or the
    input PTS departs from the stream's *accumulated* sample count by more
    than the tolerance — comparing only chunk-to-chunk would let lost IO
    cycles and clock drift add up unchecked.
    """

    def __init__(self, label: str, on_reanchor: Callable[[float], bool] | None = None):
        self._label = label
        # Told of each re-anchor for drift (issue #50); returns True to
        # keep it out of the log (a known incident would flood it).
        self._on_reanchor = on_reanchor
        self._stream: soxr.ResampleStream | None = None
        self._in_rate: float | None = None
        self._anchor_pts = 0.0  # input PTS where the current stream started
        self._in_samples = 0  # input samples fed since the anchor
        self._out_pts = 0.0

    def push(self, chunk: _TimedChunk) -> list[_TimedChunk]:
        out: list[_TimedChunk] = []
        if self._in_rate is not None and chunk.rate != self._in_rate:
            LOGGER.info(
                "%s: input rate changed %g Hz → %g Hz",
                self._label, self._in_rate, chunk.rate,
            )
        if self._stream is not None:
            expected_pts = self._anchor_pts + self._in_samples / self._in_rate
            drift = chunk.pts - expected_pts
            if (
                chunk.rate != self._in_rate
                or abs(drift) * SAMPLE_RATE > PTS_TOLERANCE_FRAMES
            ):
                if chunk.rate == self._in_rate:
                    quiet = self._on_reanchor(drift) if self._on_reanchor else False
                    if not quiet:
                        LOGGER.info(
                            "%s: re-anchored resampler after %+.1f ms PTS drift",
                            self._label, drift * 1000,
                        )
                out.extend(self.flush())
        self._in_rate = chunk.rate

        if chunk.rate == SAMPLE_RATE:
            out.append(chunk)
            return out
        if self._stream is None:
            self._stream = soxr.ResampleStream(
                chunk.rate, SAMPLE_RATE, 1, dtype="float32"
            )
            self._out_pts = chunk.pts
            self._anchor_pts = chunk.pts
            self._in_samples = 0
        self._in_samples += len(chunk.samples)
        out.extend(self._emit(self._stream.resample_chunk(chunk.samples)))
        return out

    def flush(self) -> list[_TimedChunk]:
        if self._stream is None:
            return []
        tail = self._stream.resample_chunk(np.zeros(0, dtype=np.float32), last=True)
        self._stream = None
        return self._emit(tail)

    def _emit(self, samples: np.ndarray) -> list[_TimedChunk]:
        if samples.size == 0:
            return []
        chunk = _TimedChunk(pts=self._out_pts, samples=samples)
        self._out_pts += len(samples) / SAMPLE_RATE
        return [chunk]


def _wav_header(data_bytes: int, sample_rate: int = 16_000) -> bytes:
    """Build a 44-byte PCM_16 mono WAV header for the given data length."""
    channels = 1
    bits = 16
    byte_rate = sample_rate * channels * bits // 8
    block_align = channels * bits // 8
    return struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF", 36 + data_bytes, b"WAVE", b"fmt ",
        16, 1, channels, sample_rate, byte_rate, block_align, bits,
        b"data", data_bytes,
    )


class _IncrementalTrackWriter:
    """Streams 16kHz mono PCM_16 samples to ``<path>.part``.

    Writes a placeholder 44-byte WAV header at open time so the file is at
    least structurally a WAV from the first byte. ``write_chunk_at_offset``
    appends samples (with zero-padding for any gap to the previous chunk),
    advancing a frame counter. ``finalize_to`` truncates the data section to
    a target length and patches the header sizes, then atomically renames
    ``.part`` → final path.

    On crash (process killed, no chance to finalize), the ``.part`` file is
    left on disk with a stale header (the placeholder zeros) but the data
    body is intact. ``abort`` patches the header in-place to whatever was
    written so the partial WAV is at least playable for forensics.

    Out-of-order writes (offset earlier than ``frames_written``) are dropped
    with a no-op — within one SCStream output type, chunks arrive in PTS
    order, so this branch should never fire in practice. Treat it as
    defensive.
    """

    SAMPLE_RATE = 16_000
    HEADER_SIZE = 44

    def __init__(self, final_path: Path):
        self._final_path = Path(final_path)
        self._part_path = Path(str(final_path) + ".part")
        self._fh = open(self._part_path, "wb")
        self._fh.write(_wav_header(0, self.SAMPLE_RATE))
        self._fh.flush()
        self._frames_written = 0
        self._closed = False
        self._lock = threading.Lock()

    @property
    def frames_written(self) -> int:
        return self._frames_written

    def write_chunk_at_offset(
        self, offset_frames: int, samples_int16: np.ndarray
    ) -> None:
        if self._closed:
            return
        if samples_int16.size == 0:
            return
        with self._lock:
            if offset_frames < 0:
                # Pre-roll relative to start_pts; drop.
                return
            if offset_frames < self._frames_written:
                # Out-of-order within a single track. Defensive no-op.
                return
            if offset_frames > self._frames_written:
                gap = offset_frames - self._frames_written
                self._fh.write(b"\x00\x00" * gap)
                self._frames_written += gap
            self._fh.write(samples_int16.tobytes())
            self._frames_written += int(len(samples_int16))

    def flush(self) -> None:
        """Make everything written so far visible to readers of ``.part``."""
        with self._lock:
            if not self._closed:
                self._fh.flush()

    def finalize_to(self, total_frames: int) -> None:
        """Truncate to ``total_frames``, patch header, rename to final path."""
        with self._lock:
            if self._closed:
                return
            target_bytes = self.HEADER_SIZE + total_frames * 2
            self._fh.flush()
            self._fh.truncate(target_bytes)
            self._fh.seek(0)
            self._fh.write(_wav_header(total_frames * 2, self.SAMPLE_RATE))
            self._fh.close()
            self._closed = True
            if self._final_path.exists():
                self._final_path.unlink()
            self._part_path.rename(self._final_path)

    def abort(self) -> None:
        """Close without renaming. Leaves ``.part`` with a header reflecting
        whatever was actually written, for crash-forensics."""
        with self._lock:
            if self._closed:
                return
            self._fh.flush()
            self._fh.seek(0)
            self._fh.write(_wav_header(self._frames_written * 2, self.SAMPLE_RATE))
            self._fh.close()
            self._closed = True


_SCSTREAM_SINK = None


def _scstream_sink_class():
    """The SCStreamOutput delegate class, defined once per process.

    Objective-C classes are process-global: defining it inside each start
    made the second recording of a long-running app fail with "_CaptureSink
    is overriding existing Objective-C class".
    """
    global _SCSTREAM_SINK
    if _SCSTREAM_SINK is not None:
        return _SCSTREAM_SINK
    import objc
    from Foundation import NSObject
    from ScreenCaptureKit import SCStreamOutputTypeAudio, SCStreamOutputTypeMicrophone

    audio_type = int(SCStreamOutputTypeAudio)
    mic_type = int(SCStreamOutputTypeMicrophone)

    class _CaptureSink(NSObject, protocols=[objc.protocolNamed("SCStreamOutput")]):
        def initWithOwner_(self, owner):
            self = objc.super(_CaptureSink, self).init()
            if self is None:
                return None
            self._owner = owner
            return self

        # Selector: stream:didOutputSampleBuffer:ofType:
        def stream_didOutputSampleBuffer_ofType_(self, stream, sample_buffer, output_type):
            if self._generation != self._owner._stream_generation:
                return  # a timed-out earlier start attempt came alive late
            decoded = _cmsample_to_mono(sample_buffer)
            if decoded is None:
                return
            pts = _cmsample_pts_seconds(sample_buffer)
            if pts is None:
                return
            chunk = _TimedChunk(pts=pts, samples=decoded[0], rate=decoded[1])
            tcode = int(output_type)
            if tcode == audio_type:
                self._owner._sys_queue.put(chunk)
            elif tcode == mic_type:
                self._owner._mic_queue.put(chunk)

    _SCSTREAM_SINK = _CaptureSink
    return _SCSTREAM_SINK


def _default_mic_capture(on_chunk):
    from ._audio.av_mic import AVMicCapture

    return AVMicCapture(on_chunk)


def _default_system_tap(on_chunk):
    from ._audio.process_tap import ProcessTap

    return ProcessTap(on_chunk)


class CaptureRecorder:
    """Records microphone and system audio to two WAV files from one SCStream.

    The two tracks are aligned using CMSampleBuffer presentation timestamps
    so that sample 0 of ``mic_raw_path`` and sample 0 of ``system_path``
    correspond to the same wall-clock instant. Each file keeps its own
    length; neither track's audio is discarded to match the other.
    """

    SAMPLE_RATE = SAMPLE_RATE
    CHANNELS = 1

    def __init__(
        self,
        mic_raw_path: Path,
        system_path: Path,
        *,
        system_tap_factory: Callable[[Callable[[float, np.ndarray, float], None]], object]
        | None = None,
        mic_capture_factory: Callable[[Callable[[float, np.ndarray, float], None]], object]
        | None = None,
        problems_path: Path | None = None,
    ):
        self._mic_raw_path = Path(mic_raw_path)
        self._system_path = Path(system_path)
        self._stream = None
        self._output_handler = None
        self._system_tap_factory = system_tap_factory or _default_system_tap
        self._system_tap = None
        self._mic_capture_factory = mic_capture_factory or _default_mic_capture
        self._mic_capture = None
        # Bumped per SCStream start attempt; callbacks from older attempts
        # (a start that timed out but came alive later) are ignored.
        self._stream_generation = 0
        # Where each track comes from once started: "process-tap" /
        # "avcapture", or "scstream" as the fallback.
        self.system_source: str | None = None
        self.mic_source: str | None = None
        # Tracks no source could deliver ("microphone", "system audio"); the
        # recording continues with the other one.
        self.missing: list[str] = []
        # The rate each track arrives at before resampling (e.g. 24 kHz from
        # AirPods), once it has delivered.
        self.mic_rate: float | None = None
        self.system_rate: float | None = None
        self._clock: Callable[[], float] = time.monotonic
        self._last_mic_arrival: float | None = None
        self._last_system_arrival: float | None = None
        self._last_stall_warning: float | None = None
        self._health = AudioHealth(started=self._clock())
        self._last_health_check: float | None = None
        self._health_failed_at: float | None = None
        self._health_failures = 0
        self._health_off = False
        # Where incidents are kept as they open and end, for a crash to keep.
        self._problems_path = Path(problems_path) if problems_path else None
        # Incoming PTS-tagged chunks, one queue per track.
        self._mic_queue: queue.Queue[_TimedChunk] = queue.Queue()
        self._sys_queue: queue.Queue[_TimedChunk] = queue.Queue()
        self._mic_resampler, self._sys_resampler = self._resamplers()
        # Streaming writer state.
        self._writer_thread: threading.Thread | None = None
        self._stop_flag = threading.Event()
        self._mic_writer: _IncrementalTrackWriter | None = None
        self._sys_writer: _IncrementalTrackWriter | None = None
        self._start_pts: float | None = None
        self._mic_first_pts: float | None = None
        self._sys_first_pts: float | None = None
        # Phase A buffers: chunks that arrive before start_pts is fixed (both
        # tracks have delivered, or one has delivered alone for
        # PHASE_A_MAX_SECONDS). Then they are flushed to disk at PTS-derived
        # offsets and the writer switches to live mode.
        self._phase_a_mic: list[_TimedChunk] = []
        self._phase_a_sys: list[_TimedChunk] = []

    # ---------------- public API ----------------

    @property
    def mic_device(self) -> str | None:
        """The microphone's name (AVCaptureSession only), e.g. "AirPods"."""
        return getattr(self._mic_capture, "device_name", None)

    @property
    def system_device(self) -> str | None:
        """The output the system-audio tap is clocked by, e.g. "AirPods Pro"."""
        return getattr(self._system_tap, "output_name", None)

    @property
    def problems(self) -> list[dict]:
        """Audio incidents of this recording (issue #50): ``{"id", "kind",
        "track", "start", "end", "at"}``, seconds from the start; ``end`` is
        None while one lasts."""
        return self._guarded(self._health.problems, default=[])

    @property
    def hints(self) -> list[dict]:
        """Soft hints to show now, e.g. a mic that sends only silence."""
        return self._guarded(self._health.hints, default=[])

    def start(self) -> None:
        if self._stream is not None:
            raise RuntimeError("CaptureRecorder already started")
        self._stop_flag.clear()
        self._health = AudioHealth(started=self._clock())
        self._last_health_check = None
        self._health_failures, self._health_off = 0, False
        self._mic_resampler, self._sys_resampler = self._resamplers()
        self._start_pts = None
        self._mic_first_pts = None
        self._sys_first_pts = None
        self._phase_a_mic = []
        self._phase_a_sys = []
        self._arm_mic_watchdog()
        # Drain any stale chunks left in queues from a previous (failed) run.
        for q in (self._mic_queue, self._sys_queue):
            while True:
                try:
                    q.get_nowait()
                except queue.Empty:
                    break
        self._mic_writer = _IncrementalTrackWriter(self._mic_raw_path)
        self._sys_writer = _IncrementalTrackWriter(self._system_path)
        self._start_writer()
        self.system_source = self.mic_source = None
        self.missing = []
        try:
            self._start_capture()
        except BaseException:
            self._stop_mic_capture()
            self._stop_system_tap()
            self._stop_flag.set()
            if self._writer_thread is not None:
                self._writer_thread.join(timeout=2.0)
                self._writer_thread = None
            for w in (self._mic_writer, self._sys_writer):
                if w is not None:
                    w.abort()
            self._mic_writer = None
            self._sys_writer = None
            raise

    def stop(self) -> None:
        if self._stream is not None:
            done = threading.Event()

            def _cb(_err):
                done.set()

            try:
                self._stream.stopCaptureWithCompletionHandler_(_cb)
                done.wait(timeout=5.0)
            finally:
                self._stream = None
                self._output_handler = None
        self._stop_mic_capture()
        self._stop_system_tap()

        self._stop_flag.set()
        if self._writer_thread is not None:
            self._writer_thread.join(timeout=5.0)
            self._writer_thread = None

        self._finalize_writers()
        self._guarded(self._health.close_all, self._clock())
        self._keep_problems()

    def _start_writer(self) -> None:
        self._writer_thread = threading.Thread(target=self._writer_loop, daemon=True)
        self._writer_thread.start()

    def _resamplers(self) -> tuple[_TrackResampler, _TrackResampler]:
        return (_TrackResampler("mic", lambda drift: self._on_reanchor("mic", drift)),
                _TrackResampler("system", lambda drift: self._on_reanchor("system", drift)))

    def _on_reanchor(self, track: str, drift: float) -> bool:
        """Counted by the health monitor; True (not logged) while the
        track's wrong-speed incident is open."""
        def count() -> bool:
            self._health.reanchor(track, self._clock(), drift)
            return self._health.is_open("speed", track)

        return bool(self._guarded(count, default=False))

    def _guarded(self, fn, *args, default=None, **kwargs):
        """Run a health-monitor call; whatever it raises, the writer goes
        on (logged at debug, at most once a minute). A monitor that keeps
        failing is switched off for the recording, and session.log says so
        once."""
        if self._health_off:
            return default
        try:
            return fn(*args, **kwargs)
        except Exception:
            now = time.monotonic()
            if self._health_failed_at is None or now - self._health_failed_at >= HEALTH_FAILURE_LOG_SECONDS:
                self._health_failed_at = now
                LOGGER.debug("health monitor failed; recording goes on", exc_info=True)
            self._health_failures += 1
            if self._health_failures >= HEALTH_FAILURES_OFF:
                self._health_off = True
                LOGGER.warning("Audio health checks failed; warnings are off for this recording")
            return default

    def _keep_problems(self) -> None:
        """Write the incidents beside the audio (atomically), so a crash
        before stop() still has them (issue #50)."""
        if self._problems_path is None:
            return
        problems = [{k: v for k, v in p.items() if k != "id"} for p in self.problems]
        if not problems and not self._problems_path.exists():
            return
        try:
            tmp = self._problems_path.with_name(self._problems_path.name + ".tmp")
            with open(tmp, "w") as fh:
                fh.write(json.dumps(problems, indent=2))
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp, self._problems_path)
        except OSError:
            LOGGER.debug("could not keep the audio problems", exc_info=True)

    def _finalize_writers(self) -> None:
        """Drain, flush resamplers and Phase A, then finalize both files.

        Each track is finalized to its OWN length. Truncating both to
        min(mic, sys) silently discards mic data when system audio pauses
        mid-recording (issue #18); the AEC step downstream handles the length
        mismatch by AEC-processing the overlap and appending the mic tail.
        """
        # Final drain in case the writer thread missed anything between
        # stop_flag.set() and exiting.
        self._drain_queues_into_writers()

        if self._mic_writer is None or self._sys_writer is None:
            return

        for resampler, is_mic in (
            (self._mic_resampler, True),
            (self._sys_resampler, False),
        ):
            for out in resampler.flush():
                self._place(out, is_mic)
        if self._start_pts is None and (
            self._mic_first_pts is not None or self._sys_first_pts is not None
        ):
            self._enter_phase_b()

        self._mic_writer.finalize_to(self._mic_writer.frames_written)
        self._sys_writer.finalize_to(self._sys_writer.frames_written)
        self._mic_writer = None
        self._sys_writer = None

    # ---------------- capture sources ----------------

    def _start_capture(self) -> None:
        """Process Tap for system audio, AVCaptureSession for the mic — neither
        needs Screen Recording permission. ScreenCaptureKit only fills in for
        a source that failed; a track nothing can deliver is reported in
        ``missing`` and the recording continues with the other."""
        tap_ok = self._start_system_tap()
        mic_ok = self._start_mic_capture()
        self.system_source = "process-tap" if tap_ok else None
        self.mic_source = "avcapture" if mic_ok else None
        need_mic, need_system = not mic_ok, not tap_ok
        if not (need_mic or need_system):
            return
        try:
            self._start_scstream_with_retries(capture_mic=need_mic, capture_system=need_system)
        except RuntimeError as exc:
            if not (mic_ok or tap_ok):
                raise RuntimeError(
                    f"neither the microphone nor system audio can be recorded: {exc}"
                ) from exc
            if need_mic:
                self.missing.append("microphone")
                LOGGER.warning("⚠ recording without the microphone: %s", exc)
            if need_system:
                self.missing.append("system audio")
                LOGGER.warning(
                    "⚠ recording without system audio (the other participants): %s", exc
                )
            return
        if need_mic:
            self.mic_source = "scstream"
        if need_system:
            self.system_source = "scstream"

    def _start_scstream_with_retries(self, *, capture_mic: bool, capture_system: bool) -> None:
        for attempt in range(1, SCSTREAM_START_ATTEMPTS + 1):
            try:
                self._start_scstream(capture_mic=capture_mic, capture_system=capture_system)
                return
            except RuntimeError as exc:
                if attempt == SCSTREAM_START_ATTEMPTS:
                    raise
                LOGGER.warning(
                    "warning: %s; retrying in %g s (%d/%d)",
                    exc, SCSTREAM_RETRY_SECONDS, attempt, SCSTREAM_START_ATTEMPTS - 1,
                )
                time.sleep(SCSTREAM_RETRY_SECONDS)

    def _start_mic_capture(self) -> bool:
        mic = self._mic_capture_factory(self._on_mic_chunk)
        try:
            mic.start()
        except Exception as exc:
            LOGGER.warning(
                "warning: microphone via AVCaptureSession unavailable (%s); "
                "trying ScreenCaptureKit.",
                exc,
            )
            return False
        self._mic_capture = mic
        return True

    def _on_mic_chunk(self, pts: float, samples: np.ndarray, rate: float) -> None:
        self._mic_queue.put(_TimedChunk(pts=pts, samples=np.asarray(samples, dtype=np.float32), rate=rate))

    def _stop_mic_capture(self) -> None:
        mic, self._mic_capture = self._mic_capture, None
        if mic is not None:
            mic.stop()

    def _start_system_tap(self) -> bool:
        from ._audio.process_tap import ProcessTapError

        tap = self._system_tap_factory(self._on_system_tap_chunk)
        try:
            tap.start()
        except ProcessTapError as exc:
            LOGGER.warning(
                "warning: system audio tap unavailable (%s); falling back to "
                "ScreenCaptureKit system audio, which other recorders running "
                "in parallel can starve.",
                exc,
            )
            return False
        self._system_tap = tap
        return True

    def _on_system_tap_chunk(self, pts: float, samples: np.ndarray, rate: float) -> None:
        self._sys_queue.put(_TimedChunk(pts=pts, samples=samples, rate=rate))

    def _stop_system_tap(self) -> None:
        tap, self._system_tap = self._system_tap, None
        if tap is not None:
            tap.stop()

    def _start_scstream(self, *, capture_mic: bool, capture_system: bool) -> None:
        """PyObjC ScreenCaptureKit wiring — the fallback for the microphone
        and/or system audio. Needs Screen Recording permission."""
        from ScreenCaptureKit import (
            SCContentFilter,
            SCShareableContent,
            SCStream,
            SCStreamConfiguration,
            SCStreamOutputTypeAudio,
            SCStreamOutputTypeMicrophone,
        )

        # --- 1. Synchronously resolve shareable content ---------------------
        content_done = threading.Event()
        content_result: list = [None, None]

        def _content_cb(content, error):
            content_result[0] = content
            content_result[1] = error
            content_done.set()

        SCShareableContent.getShareableContentWithCompletionHandler_(_content_cb)
        if not content_done.wait(timeout=5.0):
            raise RuntimeError(
                "Timed out fetching SCShareableContent (Screen Recording permission?)"
            )
        content, error = content_result
        if error is not None or content is None:
            raise RuntimeError(f"SCShareableContent failed: {error}")

        displays = content.displays()
        if displays is None or len(displays) == 0:
            raise RuntimeError("No displays available for SCShareableContent")
        display = displays[0]

        # --- 2. Content filter: everything on the display -------------------
        content_filter = SCContentFilter.alloc().initWithDisplay_excludingWindows_(
            display, []
        )

        # --- 3. Stream configuration ----------------------------------------
        config = SCStreamConfiguration.alloc().init()
        config.setCapturesAudio_(capture_system)
        config.setSampleRate_(self.SAMPLE_RATE)
        config.setChannelCount_(self.CHANNELS)
        # Enable the mic output on the same stream (shared host-time clock).
        try:
            config.setCaptureMicrophone_(capture_mic)
        except Exception as exc:
            raise RuntimeError(
                "SCStreamConfiguration.setCaptureMicrophone_ unavailable — "
                "requires macOS 15+ (this runtime lacks the selector)."
            ) from exc
        # SCStream still requires *some* video config; ask for the minimum.
        config.setWidth_(2)
        config.setHeight_(2)
        config.setMinimumFrameInterval_(
            __import__("CoreMedia").CMTimeMake(1, 1)  # one frame/sec max
        )
        try:
            config.setExcludesCurrentProcessAudio_(True)
        except Exception:
            pass

        # --- 4. Output handler -----------------------------------------------
        self._stream_generation += 1
        handler = _scstream_sink_class().alloc().initWithOwner_(self)
        handler._generation = self._stream_generation
        self._output_handler = handler

        # --- 5. Build stream and attach both outputs ------------------------
        stream = SCStream.alloc().initWithFilter_configuration_delegate_(
            content_filter, config, None
        )

        if capture_system:
            try:
                ok_audio, err_audio = stream.addStreamOutput_type_sampleHandlerQueue_error_(
                    handler, SCStreamOutputTypeAudio, None, None
                )
            except Exception as e:
                raise RuntimeError(f"addStreamOutput(audio) failed: {e}") from e
            if not ok_audio:
                raise RuntimeError(
                    f"SCStream.addStreamOutput(audio) returned error: {err_audio}"
                )

        if capture_mic:
            try:
                ok_mic, err_mic = stream.addStreamOutput_type_sampleHandlerQueue_error_(
                    handler, SCStreamOutputTypeMicrophone, None, None
                )
            except Exception as e:
                raise RuntimeError(f"addStreamOutput(mic) failed: {e}") from e
            if not ok_mic:
                raise RuntimeError(
                    f"SCStream.addStreamOutput(mic) returned error: {err_mic}"
                )

        # --- 6. Start capture -----------------------------------------------
        start_done = threading.Event()
        err_holder: list = [None]

        def _start_cb(err):
            err_holder[0] = err
            start_done.set()

        stream.startCaptureWithCompletionHandler_(_start_cb)
        if not start_done.wait(timeout=10.0):
            # The stream may still finish starting after we retry; retire its
            # generation and ask it to stop so it can't feed (or hold) the mic.
            self._stream_generation += 1
            try:
                stream.stopCaptureWithCompletionHandler_(lambda _err: None)
            except Exception:
                pass
            raise RuntimeError("Timed out starting SCStream capture")
        if err_holder[0] is not None:
            raise RuntimeError(f"SCStream startCapture failed: {err_holder[0]}")

        self._stream = stream

    # ---------------- queue draining + streaming write ----------------

    def _writer_loop(self) -> None:
        """Single writer thread: pulls chunks from both queues and writes to disk.

        Every chunk first passes through its track's resampler (native rate →
        16 kHz). Then:

        Phase A — ``start_pts`` is not yet fixed. Resampled chunks are
        buffered in ``_phase_a_mic`` / ``_phase_a_sys``.

        Phase A → B transition — once both tracks have delivered, or one has
        delivered alone for ``PHASE_A_MAX_SECONDS``, ``start_pts`` is fixed
        to the earliest known first PTS and the Phase A buffers are flushed.

        Phase B — each chunk is written immediately at its PTS-derived frame
        offset within its track's file. Memory footprint stays bounded
        regardless of recording length, and a SIGKILL leaves usable .part
        files on disk.
        """
        while not self._stop_flag.is_set():
            if not self._drain_once():
                self._check_health()
                self._stop_flag.wait(timeout=0.02)

    def _arm_mic_watchdog(self) -> None:
        """Count from now, so a track that never delivers is caught too."""
        self._last_mic_arrival = self._last_system_arrival = self._clock()
        self._last_stall_warning = None

    def _check_health(self) -> None:
        """The mic watchdog, then every HEALTH_CHECK_SECONDS the health
        monitor: incidents opening and ending go to the log (session.log)
        and beside the audio. Never raises: it runs on the writer thread."""
        self._check_mic_stall()
        now = self._clock()
        if self._last_health_check is not None and now - self._last_health_check < HEALTH_CHECK_SECONDS:
            return
        self._last_health_check = now
        self._guarded(self._run_health_check, now)

    def _run_health_check(self, now: float) -> None:
        written = {
            track: writer.frames_written / self.SAMPLE_RATE
            for track, writer in (("mic", self._mic_writer), ("system", self._sys_writer))
            if writer is not None
        }
        stalled = (
            self._last_mic_arrival is not None and "microphone" not in self.missing
            and now - self._last_mic_arrival >= MIC_STALL_SECONDS
        )
        # Only the tap: whether ScreenCaptureKit's audio delivers silence is unknown.
        system_stalled = (
            self._last_system_arrival is not None and self.system_source == "process-tap"
            and now - self._last_system_arrival >= SYSTEM_STALL_SECONDS
        )
        access = {
            "mic": getattr(self._mic_capture, "problem", None),
            "system": getattr(self._system_tap, "problem", None),
        }
        opened, closed = self._health.check(
            now, written=written, start_pts=self._start_pts, access=access, stalled=stalled,
            system_stalled=system_stalled,
        )
        for p in opened:
            text = lifecycle.problem_warning(p)
            fields = {**{k: p[k] for k in ("kind", "track", "start", "at")}, "text": text,
                      "reanchors_per_minute": self._health.reanchors_per_minute(p["track"])}
            LOGGER.warning("⚠ %s", text, extra={"event": "audio_problem", "fields": fields})
        for p in closed:
            LOGGER.info("audio problem over: %s", lifecycle.problem_warning(p),
                        extra={"event": "audio_problem_over", "fields": {k: p[k] for k in ("kind", "track", "end")}})
        if opened or closed:
            self._keep_problems()

    def _check_mic_stall(self) -> None:
        if self._last_mic_arrival is None or "microphone" in self.missing:
            return
        now = self._clock()
        idle = now - self._last_mic_arrival
        if idle < MIC_STALL_SECONDS:
            return
        if (
            self._last_stall_warning is not None
            and now - self._last_stall_warning < MIC_STALL_REMINDER_SECONDS
        ):
            return
        self._last_stall_warning = now
        LOGGER.warning(
            "⚠ no microphone audio for %.0f s — ScreenCaptureKit may have "
            "stopped delivering (display sleep, device change?).",
            idle,
        )

    def _drain_once(self) -> bool:
        made_progress = False
        for q, is_mic in ((self._mic_queue, True), (self._sys_queue, False)):
            try:
                chunk = q.get_nowait()
            except queue.Empty:
                continue
            self._handle_chunk(chunk, is_mic)
            made_progress = True
        return made_progress

    def _drain_queues_into_writers(self) -> None:
        for q, is_mic in ((self._mic_queue, True), (self._sys_queue, False)):
            while True:
                try:
                    chunk = q.get_nowait()
                except queue.Empty:
                    break
                self._handle_chunk(chunk, is_mic)

    def _handle_chunk(self, chunk: _TimedChunk, is_mic: bool) -> None:
        if self._mic_writer is None or self._sys_writer is None:
            return  # already finalized
        now = self._clock()
        self._guarded(self._health.chunk, "mic" if is_mic else "system", now, chunk.pts, chunk.samples, chunk.rate)
        if is_mic:
            if self._last_stall_warning is not None and self._last_mic_arrival is not None:
                LOGGER.warning(
                    "microphone audio resumed after %.0f s.",
                    now - self._last_mic_arrival,
                )
                self._last_stall_warning = None
            self._last_mic_arrival = now
        if is_mic:
            self.mic_rate = chunk.rate
        else:
            self.system_rate = chunk.rate
            self._last_system_arrival = now
        if is_mic and self._mic_first_pts is None:
            self._mic_first_pts = chunk.pts
        elif (not is_mic) and self._sys_first_pts is None:
            self._sys_first_pts = chunk.pts
        resampler = self._mic_resampler if is_mic else self._sys_resampler
        for out in resampler.push(chunk):
            self._place(out, is_mic)
        if self._start_pts is None and self._phase_a_done(chunk.pts):
            self._enter_phase_b()

    def _phase_a_done(self, latest_pts: float) -> bool:
        firsts = [p for p in (self._mic_first_pts, self._sys_first_pts) if p is not None]
        if len(firsts) == 2:
            return True
        return bool(firsts) and latest_pts - firsts[0] >= PHASE_A_MAX_SECONDS

    def _place(self, chunk: _TimedChunk, is_mic: bool) -> None:
        if self._start_pts is None:
            (self._phase_a_mic if is_mic else self._phase_a_sys).append(chunk)
            return
        writer = self._mic_writer if is_mic else self._sys_writer
        self._write_chunk_to_writer(chunk, writer)

    def _enter_phase_b(self) -> None:
        """Fix start_pts to the earliest first PTS, flush Phase A in order."""
        self._start_pts = min(
            p for p in (self._mic_first_pts, self._sys_first_pts) if p is not None
        )
        for chunk in sorted(self._phase_a_mic, key=lambda c: c.pts):
            self._write_chunk_to_writer(chunk, self._mic_writer)
        for chunk in sorted(self._phase_a_sys, key=lambda c: c.pts):
            self._write_chunk_to_writer(chunk, self._sys_writer)
        self._phase_a_mic = []
        self._phase_a_sys = []

    def _write_chunk_to_writer(
        self, chunk: _TimedChunk, writer: _IncrementalTrackWriter | None
    ) -> None:
        if writer is None or self._start_pts is None:
            return
        offset_frames = int(round((chunk.pts - self._start_pts) * self.SAMPLE_RATE))
        samples = chunk.samples
        drift = offset_frames - writer.frames_written
        if abs(drift) <= PTS_TOLERANCE_FRAMES:
            # Jitter: continue contiguously.
            offset_frames = writer.frames_written
        elif drift < 0:
            # Real overlap (or pre-roll before start_pts): drop the part of
            # the chunk that is already on disk.
            if -drift >= len(samples):
                return
            samples = samples[-drift:]
            offset_frames = writer.frames_written
        # A positive drift beyond tolerance is a real gap; the writer
        # zero-pads up to offset_frames.
        scaled = np.clip(samples * 32_767.0, -32_768, 32_767).astype(np.int16)
        writer.write_chunk_at_offset(offset_frames, scaled)
