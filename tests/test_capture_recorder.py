"""Unit tests for CaptureRecorder — no hardware required.

These tests exercise the PTS-alignment path by feeding synthetic
``_TimedChunk`` values directly into the writer thread, bypassing the
PyObjC / ScreenCaptureKit startup. The integration test in
``test_integration_capture.py`` covers the real SCStream wiring.
"""

from __future__ import annotations

import threading
import time
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from palaver.capture_recorder import (
    CaptureRecorder,
    _decode_pcm,
    _IncrementalTrackWriter,
    _TimedChunk,
)


def _sine(n: int, freq: float = 440.0, sr: int = 16_000, amp: float = 0.3) -> np.ndarray:
    t = np.arange(n) / sr
    return (amp * np.sin(2 * np.pi * freq * t)).astype(np.float32)


def _chunked(
    signal: np.ndarray, pts0: float, size: int, rate: int = 16_000
) -> list[_TimedChunk]:
    """Split ``signal`` into SCStream-sized chunks with contiguous PTS."""
    return [
        _TimedChunk(pts=pts0 + i / rate, samples=signal[i : i + size], rate=rate)
        for i in range(0, len(signal), size)
    ]


def _dominant_freq(x: np.ndarray, sr: int = 16_000) -> float:
    spectrum = np.abs(np.fft.rfft(x.astype(np.float64)))
    return float(np.fft.rfftfreq(len(x), 1 / sr)[np.argmax(spectrum)])


def _longest_zero_run(x: np.ndarray) -> int:
    best = run = 0
    for v in x:
        run = run + 1 if v == 0 else 0
        best = max(best, run)
    return best


# ---------------- PCM decoding ----------------


def test_decode_pcm_mono_float32():
    x = _sine(512)
    out = _decode_pcm(x.tobytes(), channels=1, bits=32, is_float=True, non_interleaved=False)
    np.testing.assert_array_equal(out, x)


def test_decode_pcm_interleaved_stereo_downmixes():
    left = np.full(100, 0.2, dtype=np.float32)
    right = np.full(100, 0.4, dtype=np.float32)
    interleaved = np.stack([left, right], axis=1).ravel()
    out = _decode_pcm(
        interleaved.tobytes(), channels=2, bits=32, is_float=True, non_interleaved=False
    )
    assert len(out) == 100
    np.testing.assert_allclose(out, 0.3, rtol=1e-6)


def test_decode_pcm_planar_stereo_downmixes():
    """Non-interleaved (planar) buffers are concatenated per channel —
    reshaping them as interleaved would scramble the timeline."""
    left = _sine(100, freq=440.0)
    right = _sine(100, freq=440.0)
    planar = np.concatenate([left, right])
    out = _decode_pcm(
        planar.tobytes(), channels=2, bits=32, is_float=True, non_interleaved=True
    )
    np.testing.assert_allclose(out, left, atol=1e-6)


def test_decode_pcm_int16():
    x = np.array([0, 16_384, -16_384, 32_767], dtype=np.int16)
    out = _decode_pcm(x.tobytes(), channels=1, bits=16, is_float=False, non_interleaved=False)
    np.testing.assert_allclose(out, [0.0, 0.5, -0.5, 32_767 / 32_768], rtol=1e-6)


def test_double_start_raises(tmp_path: Path):
    """A second start() without an intervening stop() should raise."""
    rec = CaptureRecorder(
        mic_raw_path=tmp_path / "m.wav", system_path=tmp_path / "s.wav"
    )
    # Fake an already-started state by setting _stream to a truthy value.
    rec._stream = object()
    with pytest.raises(RuntimeError, match="already started"):
        rec.start()


# ---------------- streaming writer tests ----------------


def _drive_writer_loop(rec: CaptureRecorder, mic: list, sys_: list) -> None:
    """Push pre-built chunks into the queues, run the writer loop, finalize.

    Bypasses SCStream entirely — drives just the writer thread. Mirrors what
    the real production path does once chunks reach the queues.
    """
    rec._mic_writer = _IncrementalTrackWriter(rec._mic_raw_path)
    rec._sys_writer = _IncrementalTrackWriter(rec._system_path)
    for c in mic:
        rec._mic_queue.put(c)
    for c in sys_:
        rec._sys_queue.put(c)

    thread = threading.Thread(target=rec._writer_loop, daemon=True)
    thread.start()
    # Give the writer time to drain the queues.
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        if rec._mic_queue.empty() and rec._sys_queue.empty():
            break
        time.sleep(0.02)
    rec._stop_flag.set()
    thread.join(timeout=2.0)
    rec._finalize_writers()


def _read(path: Path) -> np.ndarray:
    data, sr = sf.read(str(path), dtype="int16")
    assert sr == 16_000
    return data


def test_streaming_writer_produces_aligned_wavs(tmp_path: Path):
    """End-to-end: push chunks into queues, run writer, confirm both files
    are aligned and the same length, sample data preserved."""
    mic_path = tmp_path / "mic_raw.wav"
    sys_path = tmp_path / "system.wav"
    rec = CaptureRecorder(mic_raw_path=mic_path, system_path=sys_path)

    mic_chunks = _chunked(_sine(32_000, freq=440.0), 100.0, 320)
    sys_chunks = _chunked(_sine(32_000, freq=880.0), 100.0, 320)

    _drive_writer_loop(rec, mic_chunks, sys_chunks)

    m, s = _read(mic_path), _read(sys_path)
    assert len(m) == len(s) == 32_000
    assert _longest_zero_run(m) < 5


def test_streaming_writer_resamples_48k_mic_to_16k(tmp_path: Path):
    """SCStream ignores the configured 16 kHz for the microphone and delivers
    the device's native rate (48 kHz on a MacBook). The writer must resample
    rather than write 48 kHz samples into a 16 kHz file."""
    mic_path = tmp_path / "mic_raw.wav"
    sys_path = tmp_path / "system.wav"
    rec = CaptureRecorder(mic_raw_path=mic_path, system_path=sys_path)

    mic_chunks = _chunked(_sine(96_000, freq=440.0, sr=48_000), 100.0, 512, rate=48_000)
    sys_chunks = _chunked(_sine(32_000, freq=880.0), 100.0, 320)

    _drive_writer_loop(rec, mic_chunks, sys_chunks)

    m = _read(mic_path)
    assert abs(len(m) - 32_000) <= 2, f"mic len={len(m)}"
    assert abs(_dominant_freq(m) - 440.0) < 2.0
    assert _longest_zero_run(m[100:-100]) < 5


def test_streaming_writer_follows_rate_change_mid_track(tmp_path: Path):
    """Switching input device mid-meeting (e.g. AirPods connect) changes the
    mic's native rate. The timeline must stay continuous across the switch."""
    mic_path = tmp_path / "mic_raw.wav"
    sys_path = tmp_path / "system.wav"
    rec = CaptureRecorder(mic_raw_path=mic_path, system_path=sys_path)

    first = _chunked(_sine(48_000, freq=440.0, sr=48_000), 100.0, 512, rate=48_000)
    second = _chunked(_sine(24_000, freq=440.0, sr=24_000), 101.0, 240, rate=24_000)
    sys_chunks = _chunked(_sine(32_000, freq=880.0), 100.0, 320)

    _drive_writer_loop(rec, first + second, sys_chunks)

    m = _read(mic_path)
    assert abs(len(m) - 32_000) <= 4, f"mic len={len(m)}"
    assert abs(_dominant_freq(m[:16_000]) - 440.0) < 2.0
    assert abs(_dominant_freq(m[16_000:]) - 440.0) < 2.0
    assert _longest_zero_run(m[100:-100]) < 5


def test_streaming_writer_absorbs_pts_jitter(tmp_path: Path):
    """A sub-millisecond PTS jitter must not drop or zero-pad whole chunks."""
    mic_path = tmp_path / "mic_raw.wav"
    sys_path = tmp_path / "system.wav"
    rec = CaptureRecorder(mic_raw_path=mic_path, system_path=sys_path)

    rng = np.random.default_rng(0)
    mic_chunks = _chunked(_sine(32_000), 100.0, 320)
    for c in mic_chunks[1:]:
        c.pts += float(rng.choice([-1.4, -0.6, 0.6, 1.4])) / 16_000
    sys_chunks = _chunked(_sine(32_000, freq=880.0), 100.0, 320)

    _drive_writer_loop(rec, mic_chunks, sys_chunks)

    m = _read(mic_path)
    assert len(m) == 32_000
    assert _longest_zero_run(m) < 5


def test_streaming_writer_pads_real_gap(tmp_path: Path):
    """A genuine delivery gap (here 500 ms) is preserved as silence so later
    audio stays at its true wall-clock position."""
    mic_path = tmp_path / "mic_raw.wav"
    sys_path = tmp_path / "system.wav"
    rec = CaptureRecorder(mic_raw_path=mic_path, system_path=sys_path)

    mic_chunks = _chunked(_sine(16_000), 100.0, 320) + _chunked(_sine(16_000), 101.5, 320)
    sys_chunks = _chunked(_sine(40_000, freq=880.0), 100.0, 320)

    _drive_writer_loop(rec, mic_chunks, sys_chunks)

    m = _read(mic_path)
    assert len(m) == 40_000
    assert int(np.abs(m[16_000:24_000]).max()) == 0
    assert int(np.abs(m[24_000:24_160]).mean()) > 1000


def test_streaming_writer_keeps_mic_before_late_system(tmp_path: Path):
    """Mic audio captured before system audio starts must be kept. Both files
    share sample 0 = the earlier track's first PTS; the late track is
    zero-padded at the front."""
    mic_path = tmp_path / "mic_raw.wav"
    sys_path = tmp_path / "system.wav"
    rec = CaptureRecorder(mic_raw_path=mic_path, system_path=sys_path)

    mic_chunks = _chunked(_sine(80_000), 100.0, 320)
    sys_chunks = _chunked(_sine(32_000, freq=880.0), 103.0, 320)

    _drive_writer_loop(rec, mic_chunks, sys_chunks)

    m, s = _read(mic_path), _read(sys_path)
    assert len(m) == 80_000
    assert len(s) == 80_000
    assert int(np.abs(m[:160]).mean()) > 1000
    assert int(np.abs(s[:48_000]).max()) == 0
    assert int(np.abs(s[48_000:48_160]).mean()) > 1000


def test_streaming_writer_late_starting_mic_is_padded(tmp_path: Path):
    """Mic arriving 1s after system: its signal lands at sample 16 000."""
    mic_path = tmp_path / "mic_raw.wav"
    sys_path = tmp_path / "system.wav"
    rec = CaptureRecorder(mic_raw_path=mic_path, system_path=sys_path)

    sys_chunks = _chunked(_sine(48_000), 100.0, 320)
    mic_chunks = _chunked(_sine(32_000, freq=880.0, amp=0.5), 101.0, 512)

    _drive_writer_loop(rec, mic_chunks, sys_chunks)

    m, s = _read(mic_path), _read(sys_path)
    assert len(m) == len(s) == 48_000
    assert int(np.abs(m[:16_000]).max()) == 0
    assert int(np.abs(m[16_000:16_160]).mean()) > 1000


def test_streaming_writer_writes_mic_when_system_never_arrives(tmp_path: Path):
    """If SCStream never delivers system audio (another recorder holds it),
    the mic must still be written in full."""
    mic_path = tmp_path / "mic_raw.wav"
    sys_path = tmp_path / "system.wav"
    rec = CaptureRecorder(mic_raw_path=mic_path, system_path=sys_path)

    _drive_writer_loop(rec, _chunked(_sine(80_000), 100.0, 320), [])

    assert len(_read(mic_path)) == 80_000
    assert len(_read(sys_path)) == 0


def test_streaming_writer_flushes_long_single_track_phase_a(tmp_path: Path):
    """While only one track is delivering, its audio must reach disk after a
    bounded wait instead of accumulating in memory until stop()."""
    mic_path = tmp_path / "mic_raw.wav"
    sys_path = tmp_path / "system.wav"
    rec = CaptureRecorder(mic_raw_path=mic_path, system_path=sys_path)
    rec._mic_writer = _IncrementalTrackWriter(mic_path)
    rec._sys_writer = _IncrementalTrackWriter(sys_path)

    for c in _chunked(_sine(80_000), 100.0, 320):
        rec._handle_chunk(c, is_mic=True)

    assert rec._mic_writer.frames_written > 0
    rec._finalize_writers()


def test_streaming_writer_preserves_mic_when_system_stops_early(tmp_path: Path):
    """If system audio stops mid-recording (e.g. another app stole SCStream's
    output, issue #18), mic must keep its full length."""
    mic_path = tmp_path / "mic_raw.wav"
    sys_path = tmp_path / "system.wav"
    rec = CaptureRecorder(mic_raw_path=mic_path, system_path=sys_path)

    sys_chunks = _chunked(_sine(16_000), 100.0, 320)
    mic_chunks = _chunked(_sine(80_000, freq=880.0), 100.0, 320)

    _drive_writer_loop(rec, mic_chunks, sys_chunks)

    m, s = _read(mic_path), _read(sys_path)
    assert len(m) == 80_000, f"mic was truncated: len={len(m)}"
    assert len(s) == 16_000, f"system unexpectedly long: len={len(s)}"


def test_finalize_without_samples_writes_empty_wavs(tmp_path: Path):
    """If the stream never delivered audio on either track, both WAV files
    still exist (so path-existence checks downstream don't crash)."""
    mic_path = tmp_path / "mic_raw.wav"
    sys_path = tmp_path / "system.wav"
    rec = CaptureRecorder(mic_raw_path=mic_path, system_path=sys_path)

    _drive_writer_loop(rec, [], [])

    assert len(_read(mic_path)) == 0 and len(_read(sys_path)) == 0


# ---------------- _IncrementalTrackWriter ----------------


def test_incremental_writer_part_file_grows_during_writes(tmp_path: Path):
    """Confirm the .part file actually grows on disk as chunks are written —
    the whole point of the streaming path."""
    out = tmp_path / "track.wav"
    w = _IncrementalTrackWriter(out)
    part = Path(str(out) + ".part")
    assert part.exists()
    initial = part.stat().st_size
    assert initial == 44  # placeholder header only

    samples = (np.ones(16_000, dtype=np.float32) * 0.1 * 32767).astype(np.int16)
    w.write_chunk_at_offset(0, samples)
    after_first = part.stat().st_size
    assert after_first == 44 + 16_000 * 2  # 1 second of int16 mono

    w.write_chunk_at_offset(16_000, samples)
    after_second = part.stat().st_size
    assert after_second == 44 + 32_000 * 2  # 2 seconds total

    w.finalize_to(32_000)
    assert out.exists()
    assert not part.exists()  # renamed
    final, sr = sf.read(str(out), dtype="int16")
    assert sr == 16_000
    assert len(final) == 32_000


def test_incremental_writer_pads_gap_with_zeros(tmp_path: Path):
    """Writing a chunk past the current end should zero-pad the gap."""
    out = tmp_path / "track.wav"
    w = _IncrementalTrackWriter(out)
    samples = (np.ones(1_600, dtype=np.float32) * 0.5 * 32767).astype(np.int16)
    w.write_chunk_at_offset(0, samples)
    # Gap of 8000 frames (0.5s of silence)
    w.write_chunk_at_offset(9_600, samples)
    w.finalize_to(11_200)

    data, _ = sf.read(str(out), dtype="int16")
    assert len(data) == 11_200
    # First 1600 frames non-silent
    assert int(np.abs(data[:1_600]).mean()) > 1000
    # Gap (1600..9600) should be silent
    assert int(np.abs(data[1_600:9_600]).mean()) == 0
    # Last 1600 frames non-silent
    assert int(np.abs(data[9_600:11_200]).mean()) > 1000


def test_incremental_writer_abort_leaves_valid_part_file(tmp_path: Path):
    """Simulate a crash: write some data, abort instead of finalize, confirm
    the .part file is at least a structurally valid WAV with the data we
    actually wrote."""
    out = tmp_path / "track.wav"
    w = _IncrementalTrackWriter(out)
    samples = (np.ones(8_000, dtype=np.float32) * 0.3 * 32767).astype(np.int16)
    w.write_chunk_at_offset(0, samples)
    w.abort()

    part = Path(str(out) + ".part")
    assert part.exists()
    assert not out.exists()
    data, sr = sf.read(str(part), dtype="int16")
    assert sr == 16_000
    assert len(data) == 8_000
    assert int(np.abs(data).mean()) > 1000


def test_incremental_writer_drops_negative_offset(tmp_path: Path):
    """Pre-roll (offset < 0) is silently dropped, not crashed."""
    out = tmp_path / "track.wav"
    w = _IncrementalTrackWriter(out)
    samples = (np.ones(1_000, dtype=np.float32) * 0.2 * 32767).astype(np.int16)
    w.write_chunk_at_offset(-100, samples)
    assert w.frames_written == 0
    w.write_chunk_at_offset(0, samples)
    assert w.frames_written == 1_000
    w.finalize_to(1_000)
    data, _ = sf.read(str(out), dtype="int16")
    assert len(data) == 1_000


# ---------------- capture sources ----------------


class _FakeSource:
    def __init__(self, on_chunk, error=None):
        self.on_chunk = on_chunk
        self.error = error
        self.started = False
        self.stopped = False

    def start(self):
        if self.error is not None:
            raise self.error
        self.started = True

    def stop(self):
        self.stopped = True


def _recorder_with_fake_sources(
    tmp_path: Path, monkeypatch, *, tap_fails=False, mic_fails=False,
    scstream_fails=False, scstream_failures=None,
):
    import palaver.capture_recorder as capture_recorder
    from palaver._audio.av_mic import AVMicError
    from palaver._audio.process_tap import ProcessTapError

    monkeypatch.setattr(capture_recorder, "SCSTREAM_RETRY_SECONDS", 0.0)
    taps: list[_FakeSource] = []
    mics: list[_FakeSource] = []
    scstream_calls: list[tuple[bool, bool]] = []
    failures_left = [scstream_failures or 0]

    def _tap(on_chunk):
        taps.append(_FakeSource(on_chunk, ProcessTapError("tap denied", os_status=-1) if tap_fails else None))
        return taps[-1]

    def _mic(on_chunk):
        mics.append(_FakeSource(on_chunk, AVMicError("microphone access denied") if mic_fails else None))
        return mics[-1]

    rec = CaptureRecorder(
        mic_raw_path=tmp_path / "mic_raw.wav",
        system_path=tmp_path / "system.wav",
        system_tap_factory=_tap,
        mic_capture_factory=_mic,
    )

    def _fake_scstream(capture_mic: bool, capture_system: bool):
        scstream_calls.append((capture_mic, capture_system))
        if scstream_fails or failures_left[0] > 0:
            failures_left[0] -= 1
            raise RuntimeError("SCStream startCapture failed")

    monkeypatch.setattr(rec, "_start_scstream", _fake_scstream)
    return rec, taps, mics, scstream_calls


def test_default_sources_need_no_screen_capture(tmp_path: Path, monkeypatch):
    """Mic via AVCaptureSession + system audio via the Process Tap: no
    ScreenCaptureKit, so no Screen Recording permission (which macOS revokes
    from time to time — every auto-recording failed on 2026-10-23)."""
    rec, taps, mics, scstream_calls = _recorder_with_fake_sources(tmp_path, monkeypatch)

    rec.start()
    assert (rec.mic_source, rec.system_source) == ("avcapture", "process-tap")
    assert scstream_calls == [] and rec.missing == []
    signal = _sine(96_000, sr=48_000)
    for i in range(0, len(signal), 480):
        taps[0].on_chunk(100.0 + i / 48_000, signal[i : i + 480], 48_000.0)
        mics[0].on_chunk(100.0 + i / 48_000, signal[i : i + 480], 48_000.0)
    time.sleep(0.2)
    rec.stop()

    assert taps[0].stopped and mics[0].stopped
    for name in ("mic_raw.wav", "system.wav"):
        x = _read(tmp_path / name)
        assert abs(len(x) - 32_000) <= 2 and abs(_dominant_freq(x) - 440.0) < 2.0


def test_mic_falls_back_to_scstream(tmp_path: Path, monkeypatch, caplog):
    rec, _, _, scstream_calls = _recorder_with_fake_sources(tmp_path, monkeypatch, mic_fails=True)
    rec.start()
    rec.stop()
    assert scstream_calls == [(True, False)]
    assert rec.mic_source == "scstream" and rec.missing == []
    assert "microphone access denied" in caplog.text


def test_system_audio_falls_back_to_scstream(tmp_path: Path, monkeypatch, caplog):
    rec, _, _, scstream_calls = _recorder_with_fake_sources(tmp_path, monkeypatch, tap_fails=True)
    rec.start()
    rec.stop()
    assert scstream_calls == [(False, True)]
    assert rec.system_source == "scstream" and rec.missing == []
    assert "tap denied" in caplog.text


def test_records_system_audio_alone_when_no_mic_source_works(tmp_path: Path, monkeypatch, caplog):
    """Losing one track must not throw away the other."""
    rec, taps, _, _ = _recorder_with_fake_sources(
        tmp_path, monkeypatch, mic_fails=True, scstream_fails=True
    )
    rec.start()
    assert rec.missing == ["microphone"] and rec.system_source == "process-tap"
    assert taps[0].started
    assert "recording without the microphone" in caplog.text
    rec.stop()
    assert (tmp_path / "system.wav").exists()


def test_records_mic_alone_when_no_system_source_works(tmp_path: Path, monkeypatch):
    rec, _, mics, _ = _recorder_with_fake_sources(
        tmp_path, monkeypatch, tap_fails=True, scstream_fails=True
    )
    rec.start()
    assert rec.missing == ["system audio"] and rec.mic_source == "avcapture"
    rec.stop()
    assert mics[0].stopped


def test_start_fails_only_when_nothing_works(tmp_path: Path, monkeypatch):
    rec, taps, mics, _ = _recorder_with_fake_sources(
        tmp_path, monkeypatch, tap_fails=True, mic_fails=True, scstream_fails=True
    )
    with pytest.raises(RuntimeError, match="neither the microphone nor system audio"):
        rec.start()
    assert not (tmp_path / "mic_raw.wav").exists()  # aborted, left as .part


# ---------------- mic stall watchdog (#18) ----------------


def test_warns_when_mic_stops_delivering_and_when_it_resumes(tmp_path: Path, caplog):
    rec = CaptureRecorder(mic_raw_path=tmp_path / "m.wav", system_path=tmp_path / "s.wav")
    rec._mic_writer = _IncrementalTrackWriter(rec._mic_raw_path)
    rec._sys_writer = _IncrementalTrackWriter(rec._system_path)
    now = [1000.0]
    rec._clock = lambda: now[0]

    rec._handle_chunk(_TimedChunk(pts=100.0, samples=_sine(320)), is_mic=True)
    now[0] += 29.0
    rec._check_mic_stall()
    assert caplog.text == ""

    now[0] += 2.0
    rec._check_mic_stall()
    rec._check_mic_stall()  # no repeat within the reminder interval
    assert caplog.text.count("no microphone audio for 31 s") == 1
    caplog.clear()

    now[0] += 60.0
    rec._check_mic_stall()
    assert "no microphone audio for 91 s" in caplog.text
    caplog.clear()

    rec._handle_chunk(_TimedChunk(pts=191.0, samples=_sine(320)), is_mic=True)
    assert "microphone audio resumed after 91 s" in caplog.text
    rec._finalize_writers()


def test_no_stall_warning_before_mic_ever_delivered(tmp_path: Path, caplog):
    rec = CaptureRecorder(mic_raw_path=tmp_path / "m.wav", system_path=tmp_path / "s.wav")
    rec._clock = lambda: 10_000.0
    rec._check_mic_stall()
    assert caplog.text == ""


def test_resampled_track_does_not_accumulate_small_pts_jumps(tmp_path: Path):
    """A source that loses single IO cycles (each ~10 ms, below the jitter
    tolerance) must not drift: losses add up, so placement has to follow the
    accumulated PTS, not just chunk-to-chunk continuity. A real 25-min
    meeting drifted the system track by >100 ms this way."""
    mic_path = tmp_path / "mic_raw.wav"
    rec = CaptureRecorder(mic_raw_path=mic_path, system_path=tmp_path / "system.wav")

    signal = _sine(480_000, sr=48_000)  # 10 s at 48 kHz
    chunks = _chunked(signal, 100.0, 480, rate=48_000)
    kept = [c for i, c in enumerate(chunks) if i % 10 != 9]  # lose every 10th cycle
    marker_pts = 109.0
    for c in kept:
        if abs(c.pts - marker_pts) < 1e-9:
            c.samples = np.full(480, 0.9, dtype=np.float32)

    _drive_writer_loop(rec, kept, [])

    m = _read(mic_path)
    expected = int((marker_pts - 100.0) * 16_000)
    found = int(np.argmax(m > 0.8 * 32_767))
    assert abs(found - expected) <= 320 + 16, f"marker at {found}, expected {expected}"


def test_retries_transient_scstream_start_failure(tmp_path: Path, monkeypatch, caplog):
    """SCStream sometimes fails with "Stream failed to start microphone"
    (-3820) and succeeds seconds later."""
    rec, _, _, scstream_calls = _recorder_with_fake_sources(
        tmp_path, monkeypatch, mic_fails=True, scstream_failures=2
    )
    rec.start()
    rec.stop()
    assert scstream_calls == [(True, False)] * 3
    assert rec.mic_source == "scstream"
    assert caplog.text.count("retrying") == 2


def test_gives_up_on_scstream_after_repeated_failures(tmp_path: Path, monkeypatch):
    import palaver.capture_recorder as capture_recorder

    rec, _, _, scstream_calls = _recorder_with_fake_sources(
        tmp_path, monkeypatch, mic_fails=True, scstream_fails=True
    )
    rec.start()
    assert len(scstream_calls) == capture_recorder.SCSTREAM_START_ATTEMPTS
    assert rec.missing == ["microphone"]
    rec.stop()


def test_long_recording_with_tap_drift_losses_and_silence_stays_aligned(tmp_path: Path):
    """20 min through the real writer: tap clock 130 ppm fast (measured on
    hardware), 0.2 % lost IO cycles, a minute of tap silence every 5 min.
    Clicks played at the same wall-clock time must land within the 20 ms
    PTS tolerance of each other. (A 2 h run of the same scenario stayed
    within ±11 ms at a constant ~53 MB.)"""
    rec = CaptureRecorder(mic_raw_path=tmp_path / "mic_raw.wav", system_path=tmp_path / "system.wav")
    rec._mic_writer = _IncrementalTrackWriter(rec._mic_raw_path)
    rec._sys_writer = _IncrementalTrackWriter(rec._system_path)
    rng = np.random.default_rng(0)
    noise = rng.normal(0, 0.01, 512).astype(np.float32)
    marks = [100.0, 610.0, 1130.0]  # outside the simulated silent minutes
    total, drift = 1200.0, 130e-6
    mic_step, sys_step = 1 / 48_000, (1 + drift) / 48_000

    def samples(k0, n, step):
        x = noise[:n].copy()
        t = (k0 + np.arange(n)) * step
        for m in marks:
            x[(t >= m) & (t < m + 0.01)] = 0.9
        return x

    mic_k = sys_k = 0
    while mic_k * mic_step < total:
        rec._handle_chunk(_TimedChunk(100.0 + mic_k * mic_step, samples(mic_k, 512, mic_step), 48_000), True)
        mic_k += 512
        while sys_k * sys_step < mic_k * mic_step:
            host = sys_k * sys_step
            if int(host) % 300 < 240 and rng.random() > 0.002:
                rec._handle_chunk(_TimedChunk(100.0 + host, samples(sys_k, 480, sys_step), 48_000), False)
            sys_k += 480
    rec._finalize_writers()

    def clicks(path):
        x = _read(path)
        idx = np.flatnonzero(x > 0.8 * 32_767)
        return [g[0] / 16_000 for g in np.split(idx, np.flatnonzero(np.diff(idx) > 1_000) + 1) if len(g)]

    mic, sys_ = clicks(tmp_path / "mic_raw.wav"), clicks(tmp_path / "system.wav")
    assert len(mic) == len(sys_) == 3
    for m, s in zip(mic, sys_):
        assert abs(s - m) <= 0.020, f"system click at {s:.4f}s vs mic {m:.4f}s"


def test_warns_when_mic_never_delivers(tmp_path: Path, caplog):
    """SCStream can start without its mic output ever delivering."""
    rec = CaptureRecorder(mic_raw_path=tmp_path / "m.wav", system_path=tmp_path / "s.wav")
    now = [0.0]
    rec._clock = lambda: now[0]
    rec._arm_mic_watchdog()
    now[0] = 31.0
    rec._check_mic_stall()
    assert "no microphone audio for 31 s" in caplog.text


def test_scstream_sink_class_is_defined_once_per_process():
    """A long-running app records many meetings in one process; defining the
    Objective-C sink class per start made every recording after the first
    fail with 'overriding existing Objective-C class'."""
    from palaver.capture_recorder import _scstream_sink_class

    assert _scstream_sink_class() is _scstream_sink_class()


def test_knows_the_native_rate_and_the_mic_each_track_records_from(tmp_path: Path):
    """For the menu's "mic AirPods (24 kHz)" (issue #47)."""
    rec = CaptureRecorder(mic_raw_path=tmp_path / "m.wav", system_path=tmp_path / "s.wav")
    rec._mic_writer = _IncrementalTrackWriter(rec._mic_raw_path)
    rec._sys_writer = _IncrementalTrackWriter(rec._system_path)
    assert rec.mic_rate is None and rec.system_rate is None and rec.mic_device is None
    rec._handle_chunk(_TimedChunk(pts=100.0, samples=_sine(480, sr=24_000), rate=24_000), is_mic=True)
    rec._handle_chunk(_TimedChunk(pts=100.0, samples=_sine(960, sr=48_000), rate=48_000), is_mic=False)
    assert rec.mic_rate == 24_000 and rec.system_rate == 48_000
    rec._mic_capture = type("Mic", (), {"device_name": "AirPods"})()
    assert rec.mic_device == "AirPods"


def test_audio_problems_are_kept_beside_the_audio_as_they_open_and_end(tmp_path: Path):
    """Issue #50: written as they happen (atomically), for a crash to keep."""
    import json

    sidecar = tmp_path / "audio_problems.json"
    rec = CaptureRecorder(mic_raw_path=tmp_path / "m.wav", system_path=tmp_path / "s.wav", problems_path=sidecar)
    now = [0.0]
    rec._clock = lambda: now[0]
    rec._health = type(rec._health)(started=0.0)
    rec._arm_mic_watchdog()
    now[0] = 31.0
    rec._check_health()
    kept = json.loads(sidecar.read_text())
    assert [(p["kind"], p["track"], p["start"], p["end"]) for p in kept] == [("stalled", "mic", 31.0, None)]
    assert "id" not in kept[0] and kept[0]["at"]
    rec._mic_writer = _IncrementalTrackWriter(rec._mic_raw_path)
    rec._sys_writer = _IncrementalTrackWriter(rec._system_path)
    rec._handle_chunk(_TimedChunk(pts=100.0, samples=_sine(320)), is_mic=True)  # the mic is back
    now[0] = 32.0
    rec._check_health()
    assert [p["end"] for p in json.loads(sidecar.read_text())] == [32.0]
    assert not list(tmp_path.glob("*.tmp"))
    rec._finalize_writers()


def test_a_system_tap_that_delivers_nothing_for_30_s_is_a_warning(tmp_path: Path, caplog):
    """A Slack call on AirPods recorded 6 minutes of mic and 0 s of system
    audio, and nothing said so: the tap's track was thought silent by design
    while nothing plays, but it delivers silence too (every recording's two
    tracks ended within 0.1 s of each other)."""
    rec = CaptureRecorder(mic_raw_path=tmp_path / "m.wav", system_path=tmp_path / "s.wav")
    now = [0.0]
    rec._clock = lambda: now[0]
    rec._health = type(rec._health)(started=0.0)
    rec.system_source = "process-tap"
    rec._arm_mic_watchdog()
    rec._mic_writer = _IncrementalTrackWriter(rec._mic_raw_path)
    rec._sys_writer = _IncrementalTrackWriter(rec._system_path)
    for k in range(29):
        now[0] = float(k + 1)
        rec._handle_chunk(_TimedChunk(pts=100.0 + k, samples=_sine(16_000)), is_mic=True)
        rec._check_health()
    assert rec.problems == []
    now[0] = 30.0
    rec._handle_chunk(_TimedChunk(pts=129.0, samples=_sine(16_000)), is_mic=True)
    rec._check_health()
    assert [(p["kind"], p["track"]) for p in rec.problems] == [("stalled", "system")]
    assert "No system audio is arriving" in caplog.text
    rec._finalize_writers()


def test_no_system_warning_while_the_tap_delivers_or_another_source_records_it(tmp_path: Path):
    rec = CaptureRecorder(mic_raw_path=tmp_path / "m.wav", system_path=tmp_path / "s.wav")
    now = [0.0]
    rec._clock = lambda: now[0]
    rec._health = type(rec._health)(started=0.0)
    rec.system_source = "process-tap"
    rec._arm_mic_watchdog()
    rec._mic_writer = _IncrementalTrackWriter(rec._mic_raw_path)
    rec._sys_writer = _IncrementalTrackWriter(rec._system_path)
    for k in range(40):
        now[0] = float(k + 1)
        rec._handle_chunk(_TimedChunk(pts=100.0 + k, samples=_sine(16_000)), is_mic=True)
        if k < 5 or k > 30:  # quiet for 26 s in between
            rec._handle_chunk(_TimedChunk(pts=100.0 + k, samples=_sine(16_000)), is_mic=False)
        rec._check_health()
    assert [p["track"] for p in rec.problems if p["kind"] == "stalled"] == []
    rec._finalize_writers()

    rec = CaptureRecorder(mic_raw_path=tmp_path / "m2.wav", system_path=tmp_path / "s2.wav")
    rec._clock = lambda: now[0]
    rec._health = type(rec._health)(started=0.0)
    now[0] = 0.0
    rec._arm_mic_watchdog()
    rec.system_source, rec.missing = None, ["system audio"]  # already said when it started
    now[0] = 60.0
    rec._check_health()
    assert [p["track"] for p in rec.problems] == ["mic"]


def test_the_audio_problems_file_is_synced_before_it_replaces_the_last(tmp_path: Path, monkeypatch):
    import os

    synced, replaced = [], []
    real_fsync, real_replace = os.fsync, os.replace
    monkeypatch.setattr(os, "fsync", lambda fd: synced.append(fd) or real_fsync(fd))
    monkeypatch.setattr(os, "replace", lambda a, b: replaced.append(len(synced)) or real_replace(a, b))
    rec = CaptureRecorder(mic_raw_path=tmp_path / "m.wav", system_path=tmp_path / "s.wav",
                          problems_path=tmp_path / "audio_problems.json")
    now = [0.0]
    rec._clock = lambda: now[0]
    rec._health = type(rec._health)(started=0.0)
    rec._arm_mic_watchdog()
    now[0] = 31.0
    rec._check_health()
    assert replaced == [1]  # one fsync, before the replace
