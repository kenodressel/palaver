"""WebRTC AudioProcessing wrapper.

Loads the vendored libraven_aec.dylib (built from
`Laxcorp-Research/project-raven`'s webrtc-aec module) and exposes a single
Python function `aec_process(mic_raw_path, system_path, out_path)` that:

1. Reads mic_raw.wav and system.wav (both 16 kHz mono PCM_16).
2. Feeds 10 ms frames (160 Int16 samples) through the WebRTC APM --
   system -> process_render (far-end reference), mic -> process_capture
   (near-end, AEC applied, written to a fresh output buffer).
3. Writes the AEC-processed mic frames to out_path as 16 kHz mono PCM_16.

The C API (from `_vendored/webrtc_aec/include/aec_api.h`) is:

    RavenAecProcessor* raven_aec_create(int sample_rate);
    void               raven_aec_destroy(RavenAecProcessor*);
    int                raven_aec_process_render(RavenAecProcessor*,
                                                const int16_t* samples, int n);
    int                raven_aec_process_capture(RavenAecProcessor*,
                                                 const int16_t* in,
                                                 int16_t* out, int n);
    void               raven_aec_set_stream_delay(RavenAecProcessor*,
                                                  int delay_ms);
    void               raven_aec_get_stats(RavenAecProcessor*, RavenAecStats*);
    void               raven_aec_reset(RavenAecProcessor*);

process_capture takes SEPARATE input/output buffers -- we allocate one output
frame buffer and reuse it. After create we call set_stream_delay(0): the two
WAVs are already PTS-aligned and fed frame-by-frame, so there is no buffering
delay between render and capture — AEC3's own delay estimator finds the
remaining acoustic path (~28 ms on MacBook speakers).

The mic reaches the APM ``MIC_LEAD_MS`` late (see there), so the last
10-20 ms of the overlap come out zeroed; out length == min(mic, system)
length.
"""
from __future__ import annotations

import ctypes
from pathlib import Path

import numpy as np
import soundfile as sf

_DYLIB_PATH = Path(__file__).parent / "_vendored" / "webrtc_aec" / "libraven_aec.dylib"

SAMPLE_RATE = 16_000
FRAME_MS = 10
FRAME_SAMPLES = SAMPLE_RATE * FRAME_MS // 1000  # 160

# Render→capture buffering delay hint. Zero because capture_recorder writes
# both tracks on a shared PTS timeline. Measured on real speaker bleed
# (2026-10-20, MacBook speakers at 50 % volume): 0 ms → 39.6 dB echo
# reduction, 28 ms → 34.6 dB, 60 ms → -0.3 dB, 180 ms → -10.8 dB (the old
# value, calibrated on a mic track that was written at the wrong rate).
STREAM_DELAY_MS = 0

# The canceller sees the mic this much late. Its filter covers echo heard
# ~0-45 ms after the reference, and nothing heard before it. The tracks'
# offset jumps by up to ~20 ms when the recorder re-anchors the system track,
# and in the 2026-10-27 call it left the echo 2-5 ms after its reference for
# minutes: AEC removed 1-18 dB there instead of ~40 (#25). Seeing the mic
# 10 ms late cancelled it (median over the call 23 → 42 dB, echo words on
# the mic 340 → 4); 20 ms lost the 30-40 ms echo of other stretches.
MIC_LEAD_MS = 10
_LEAD_SAMPLES = SAMPLE_RATE * MIC_LEAD_MS // 1000

_lib: ctypes.CDLL | None = None


def _load_lib() -> ctypes.CDLL:
    global _lib
    if _lib is not None:
        return _lib
    if not _DYLIB_PATH.exists():
        raise RuntimeError(
            f"AEC library not found at {_DYLIB_PATH}. "
            f"Build it with `make aec` in the repository (needs cmake and the "
            f"Xcode Command Line Tools)."
        )
    lib = ctypes.CDLL(str(_DYLIB_PATH))

    # RavenAecProcessor* raven_aec_create(int sample_rate);
    lib.raven_aec_create.argtypes = [ctypes.c_int]
    lib.raven_aec_create.restype = ctypes.c_void_p

    # void raven_aec_destroy(RavenAecProcessor*);
    lib.raven_aec_destroy.argtypes = [ctypes.c_void_p]
    lib.raven_aec_destroy.restype = None

    # int raven_aec_process_render(RavenAecProcessor*, const int16_t*, int);
    lib.raven_aec_process_render.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_int16),
        ctypes.c_int,
    ]
    lib.raven_aec_process_render.restype = ctypes.c_int

    # int raven_aec_process_capture(RavenAecProcessor*, const int16_t* in,
    #                               int16_t* out, int n);
    lib.raven_aec_process_capture.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_int16),
        ctypes.POINTER(ctypes.c_int16),
        ctypes.c_int,
    ]
    lib.raven_aec_process_capture.restype = ctypes.c_int

    # void raven_aec_set_stream_delay(RavenAecProcessor*, int);
    lib.raven_aec_set_stream_delay.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.raven_aec_set_stream_delay.restype = None

    # void raven_aec_reset(RavenAecProcessor*);
    lib.raven_aec_reset.argtypes = [ctypes.c_void_p]
    lib.raven_aec_reset.restype = None

    _lib = lib
    return lib


class AecStream:
    """WebRTC AEC over two growing, PTS-aligned tracks. ``process`` takes
    equally long int16 blocks (any length; partial 10 ms frames are carried
    over) and returns the echo-cancelled mic for every whole frame so far.
    Feeding a recording in blocks gives the same output as in one go.

    The mic goes in ``MIC_LEAD_MS`` behind the system track (it starts with
    that much silence), and the output drops it again, so it lines up with
    the raw mic."""

    def __init__(self):
        self._lib = _load_lib()
        self._handle = self._lib.raven_aec_create(SAMPLE_RATE)
        if not self._handle:
            raise RuntimeError("raven_aec_create returned NULL")
        self._lib.raven_aec_set_stream_delay(self._handle, STREAM_DELAY_MS)
        self._out_frame = np.empty(FRAME_SAMPLES, dtype=np.int16)
        self._mic_rest = np.zeros(_LEAD_SAMPLES, dtype=np.int16)
        self._sys_rest = np.zeros(0, dtype=np.int16)
        self._skip = _LEAD_SAMPLES  # output of the lead's silence

    def process(self, mic: np.ndarray, sysaudio: np.ndarray) -> np.ndarray:
        if len(mic) != len(sysaudio):
            raise ValueError("mic and system blocks must have the same length")
        lib, handle = self._lib, self._handle
        mic = np.concatenate([self._mic_rest, mic.astype(np.int16, copy=False)])
        sysaudio = np.concatenate([self._sys_rest, sysaudio.astype(np.int16, copy=False)])
        whole = len(sysaudio) // FRAME_SAMPLES * FRAME_SAMPLES
        self._mic_rest, self._sys_rest = mic[whole:], sysaudio[whole:]
        out = np.empty(whole, dtype=np.int16)
        out_ptr = self._out_frame.ctypes.data_as(ctypes.POINTER(ctypes.c_int16))
        for off in range(0, whole, FRAME_SAMPLES):
            # Contiguous slices so ctypes gets a plain buffer.
            far = np.ascontiguousarray(sysaudio[off : off + FRAME_SAMPLES])
            near = np.ascontiguousarray(mic[off : off + FRAME_SAMPLES])
            ret = lib.raven_aec_process_render(
                handle, far.ctypes.data_as(ctypes.POINTER(ctypes.c_int16)), FRAME_SAMPLES
            )
            if ret != 0:
                raise RuntimeError(f"raven_aec_process_render failed: {ret}")
            ret = lib.raven_aec_process_capture(
                handle, near.ctypes.data_as(ctypes.POINTER(ctypes.c_int16)), out_ptr, FRAME_SAMPLES
            )
            if ret != 0:
                raise RuntimeError(f"raven_aec_process_capture failed: {ret}")
            out[off : off + FRAME_SAMPLES] = self._out_frame
        skip, self._skip = min(self._skip, whole), self._skip - min(self._skip, whole)
        return out[skip:]

    @property
    def pending(self) -> int:
        """Mic samples fed but not returned yet: the lead and a partial frame."""
        return len(self._mic_rest)

    def close(self) -> None:
        if self._handle:
            self._lib.raven_aec_destroy(self._handle)
            self._handle = None


def aec_process(mic_raw_path: Path, system_path: Path, out_path: Path) -> None:
    """Run WebRTC AEC over (mic_raw, system) -> out.

    All three files are 16 kHz mono PCM_16. Streams 10 ms frames through the
    APM: the system frame is the far-end reference, the mic frame is
    echo-cancelled against it.

    Length-mismatch handling: if mic_raw is longer than system (which
    happens when ScreenCaptureKit's system-audio output pauses mid-recording
    — see issue #18), AEC runs over the overlap and the post-overlap mic
    tail is appended verbatim. The output is always the full mic length —
    we never silently drop mic content because the reference signal stopped.
    """
    mic_full = _read_mono_int16(mic_raw_path)
    sysaudio = _read_mono_int16(system_path)
    overlap = min(len(mic_full), len(sysaudio))

    stream = AecStream()
    try:
        out = stream.process(mic_full[:overlap], sysaudio[:overlap])
    finally:
        stream.close()
    # A partial tail frame within the overlap stays zeroed.
    out = np.concatenate([out, np.zeros(overlap - len(out), dtype=np.int16)])

    if len(mic_full) > overlap:
        # Append the post-overlap mic verbatim. No system reference exists
        # for this region, so AEC could not run — speaker bleed (if any) is
        # preserved as-is. Better than silently dropping minutes of mic.
        out = np.concatenate([out, mic_full[overlap:]])

    # Written aside and renamed: `process` trusts a mic.wav that exists, so
    # a kill while writing must not leave a short one (#49).
    tmp = out_path.with_name(out_path.name + ".tmp")
    try:
        sf.write(str(tmp), out, SAMPLE_RATE, subtype="PCM_16", format="WAV")
        tmp.replace(out_path)
    finally:
        tmp.unlink(missing_ok=True)


def _read_mono_int16(path: Path) -> np.ndarray:
    data, sr = sf.read(str(path), dtype="int16")
    if sr != SAMPLE_RATE:
        raise ValueError(f"{path.name} has sample rate {sr}, expected {SAMPLE_RATE}")
    if data.ndim > 1:
        data = data[:, 0]
    return np.ascontiguousarray(data, dtype=np.int16)
