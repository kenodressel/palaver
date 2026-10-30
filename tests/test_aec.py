"""Unit tests for aec.py using synthetic WAVs."""
from __future__ import annotations

import math
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from palaver.aec import aec_process


def _write_wav(path: Path, samples: np.ndarray, rate: int = 16_000) -> None:
    sf.write(str(path), samples.astype(np.int16), rate, subtype="PCM_16")


def _sine(freq: float, duration: float, amp: int = 8000, rate: int = 16_000) -> np.ndarray:
    n = int(duration * rate)
    t = np.arange(n) / rate
    return (amp * np.sin(2 * math.pi * freq * t)).astype(np.int16)


def _silence(duration: float, rate: int = 16_000) -> np.ndarray:
    return np.zeros(int(duration * rate), dtype=np.int16)


def _rms(samples: np.ndarray) -> float:
    if len(samples) == 0:
        return 0.0
    return float(np.sqrt(np.mean(samples.astype(np.float64) ** 2)))


def test_silent_mic_with_audible_system_yields_silent_output(tmp_path: Path):
    # Mic captures ONLY the speaker bleed (same signal as system, slightly attenuated)
    system = _sine(440.0, 3.0)
    mic_raw = (system * 0.5).astype(np.int16)  # attenuated bleed, no near-end speech

    mic_path = tmp_path / "mic_raw.wav"
    sys_path = tmp_path / "system.wav"
    out_path = tmp_path / "mic.wav"
    _write_wav(mic_path, mic_raw)
    _write_wav(sys_path, system)

    aec_process(mic_raw_path=mic_path, system_path=sys_path, out_path=out_path)

    out, sr = sf.read(str(out_path), dtype="int16")
    assert sr == 16_000
    # AEC should suppress the bleed significantly; tolerate residual tail in the first
    # few hundred ms while the filter converges, then require <20% of input energy.
    converged = out[8000:]  # skip first 500 ms
    mic_rms = _rms(mic_raw[8000:])
    out_rms = _rms(converged)
    assert out_rms < 0.2 * mic_rms, f"AEC did not suppress bleed: mic_rms={mic_rms} out_rms={out_rms}"


def test_silent_system_preserves_near_end_speech(tmp_path: Path):
    # User talks, nothing playing through system; mic.wav should be ~identical to mic_raw
    mic_raw = _sine(220.0, 3.0)  # stand-in for speech
    system = _silence(3.0)

    mic_path = tmp_path / "mic_raw.wav"
    sys_path = tmp_path / "system.wav"
    out_path = tmp_path / "mic.wav"
    _write_wav(mic_path, mic_raw)
    _write_wav(sys_path, system)

    aec_process(mic_raw_path=mic_path, system_path=sys_path, out_path=out_path)

    out, _ = sf.read(str(out_path), dtype="int16")
    mic_rms = _rms(mic_raw[8000:])
    out_rms = _rms(out[8000:])
    # Near-end should be preserved at a similar level. WebRTC's APM runs
    # noise-suppression and AGC over the capture stream; a pure 220 Hz sine
    # looks like stationary noise to the NS, so some attenuation is expected
    # (empirically ~0.45-0.55 on pure sines). The key assertion is that
    # absent a far-end reference the APM doesn't gate the signal to near-zero
    # -- real speech with a wider spectrum retains more energy than this.
    assert out_rms > 0.3 * mic_rms, f"near-end too aggressively suppressed: mic_rms={mic_rms} out_rms={out_rms}"


def test_output_length_matches_input(tmp_path: Path):
    mic_raw = _silence(2.5)
    system = _silence(2.5)
    mic_path = tmp_path / "mic_raw.wav"
    sys_path = tmp_path / "system.wav"
    out_path = tmp_path / "mic.wav"
    _write_wav(mic_path, mic_raw)
    _write_wav(sys_path, system)

    aec_process(mic_raw_path=mic_path, system_path=sys_path, out_path=out_path)

    out, sr = sf.read(str(out_path), dtype="int16")
    assert sr == 16_000
    # Accept +/- 10 ms slack for AEC's internal buffering.
    assert abs(len(out) - len(mic_raw)) < 160, f"out={len(out)} vs in={len(mic_raw)}"


def test_mic_longer_than_system_preserves_post_overlap_tail(tmp_path: Path):
    """If system stops mid-recording (issue #18), the post-overlap mic tail
    is appended verbatim — we never silently drop mic content because the
    far-end reference disappeared."""
    # Mic: 5s of distinct content. System: only 2s of content.
    # Expected: mic.wav is 5s long. First 2s are AEC-processed, last 3s are
    # mic_raw verbatim.
    mic_raw = np.concatenate(
        [
            _sine(440.0, 2.0, amp=4000),  # overlap region
            _sine(880.0, 3.0, amp=8000),  # tail (only in mic_raw)
        ]
    )
    system = _sine(220.0, 2.0, amp=8000)

    mic_path = tmp_path / "mic_raw.wav"
    sys_path = tmp_path / "system.wav"
    out_path = tmp_path / "mic.wav"
    _write_wav(mic_path, mic_raw)
    _write_wav(sys_path, system)

    aec_process(mic_raw_path=mic_path, system_path=sys_path, out_path=out_path)

    out, sr = sf.read(str(out_path), dtype="int16")
    assert sr == 16_000
    # Output is full mic length, not min(mic, sys).
    assert abs(len(out) - len(mic_raw)) < 160
    # The post-overlap tail (samples 32000..) must match mic_raw[32000:]
    # because we appended verbatim. Compare element-wise.
    overlap_samples = 32_000
    np.testing.assert_array_equal(out[overlap_samples:], mic_raw[overlap_samples:])
    # The overlap region is non-empty (AEC ran on it; not asserting exact
    # values since AEC mangles the signal, but RMS must be > 0).
    overlap_rms = _rms(out[:overlap_samples])
    assert overlap_rms > 100


def test_a_system_track_that_got_nothing_passes_the_mic_through(tmp_path: Path):
    """The tap can deliver nothing for a whole call, leaving system.wav a
    bare header: with no reference there is nothing to cancel."""
    from palaver.capture_recorder import _wav_header

    mic_raw = _sine(440.0, 2.0, amp=4000)
    _write_wav(tmp_path / "mic_raw.wav", mic_raw)
    (tmp_path / "system.wav").write_bytes(_wav_header(0))

    aec_process(mic_raw_path=tmp_path / "mic_raw.wav", system_path=tmp_path / "system.wav",
                out_path=tmp_path / "mic.wav")

    out, _ = sf.read(str(tmp_path / "mic.wav"), dtype="int16")
    np.testing.assert_array_equal(out, mic_raw)


def test_stream_in_blocks_matches_one_pass():
    """Live processing feeds the AEC as the recording grows; the result must
    not depend on block boundaries (partial 10 ms frames are carried over)."""
    from palaver.aec import AecStream

    rng = np.random.default_rng(0)
    system = (rng.standard_normal(16_000 * 3) * 3000).astype(np.int16)
    mic = (np.roll(system, 400) // 4 + rng.standard_normal(len(system)) * 500).astype(np.int16)

    one = AecStream()
    whole = one.process(mic, system)
    one.close()

    blocks = AecStream()
    cuts = [0, 1234, 5000, 5001, 31_337, len(mic)]
    parts = [blocks.process(mic[a:b], system[a:b]) for a, b in zip(cuts, cuts[1:])]
    blocks.close()
    assert np.array_equal(np.concatenate(parts), whole)


def test_a_kill_while_writing_leaves_no_mic_wav_a_retry_would_trust(tmp_path: Path, monkeypatch):
    """`process` skips the echo cancellation when mic.wav exists: it is only
    there once complete (written aside, then renamed; #49)."""
    import palaver.aec as aec

    mic_path, sys_path, out_path = tmp_path / "mic_raw.wav", tmp_path / "system.wav", tmp_path / "mic.wav"
    _write_wav(mic_path, _sine(440.0, 1.0))
    _write_wav(sys_path, _sine(440.0, 1.0))
    real_write = sf.write

    def killed_halfway(file, data, *args, **kwargs):
        real_write(file, data[: len(data) // 2], *args, **kwargs)  # half on disk, then the kill
        raise KeyboardInterrupt

    monkeypatch.setattr(aec.sf, "write", killed_halfway)
    with pytest.raises(KeyboardInterrupt):
        aec_process(mic_raw_path=mic_path, system_path=sys_path, out_path=out_path)
    assert not out_path.exists()
    monkeypatch.setattr(aec.sf, "write", real_write)
    aec_process(mic_raw_path=mic_path, system_path=sys_path, out_path=out_path)
    assert sf.info(str(out_path)).frames == 16_000
    assert [p.name for p in tmp_path.iterdir() if p.name.startswith("mic.wav")] == ["mic.wav"]


def _speechlike(seconds: float, seed: int = 0) -> np.ndarray:
    """Broadband bursts with pauses: what the far end sends, roughly."""
    rng = np.random.default_rng(seed)
    n = int(seconds * 16_000)
    talking = np.repeat(rng.random(n // 1600 + 1) > 0.3, 1600)[:n]
    return (np.convolve(rng.standard_normal(n), np.hanning(8), "same") * talking * 4000).astype(np.int16)


def _echo(far: np.ndarray, delay_ms: float) -> np.ndarray:
    """The far end through a room (direct path and two reflections), heard
    ``delay_ms`` later; a negative delay is heard before its reference."""
    room = np.zeros(400)
    room[[0, 40, 120]] = [0.5, -0.2, 0.1]
    echo = np.convolve(far.astype(np.float64), room)[: len(far)]
    d = int(delay_ms * 16)
    echo = np.concatenate([np.zeros(d), echo])[: len(far)] if d >= 0 else np.concatenate([echo[-d:], np.zeros(-d)])
    return echo.astype(np.int16)


def _reduction_db(mic: np.ndarray, out: np.ndarray, skip: int = 6 * 16_000) -> float:
    return 20 * math.log10(_rms(mic[skip:]) / max(_rms(out[skip:]), 1e-3))


@pytest.mark.parametrize("delay_ms", [-5, 0, 3, 30])
def test_echo_is_cancelled_even_when_it_reaches_the_mic_with_its_reference(delay_ms):
    """The tracks' offset jumps by up to ~20 ms mid-call when the recorder
    re-anchors the system track (#25); an echo that lands at or before its
    reference must still be cancelled."""
    from palaver.aec import AecStream

    far = _speechlike(12)
    mic = _echo(far, delay_ms)
    stream = AecStream()
    out = stream.process(mic, far)
    stream.close()
    assert _reduction_db(mic[: len(out)], out) > 35


def test_looking_at_the_mic_late_does_not_delay_what_comes_out():
    """The APM itself returns the mic 13 ms late (208 samples, its noise
    suppressor's look-ahead); feeding it the mic late must not add to that."""
    from palaver.aec import AecStream

    near = _speechlike(4, seed=1)
    stream = AecStream()
    out = stream.process(near, np.zeros_like(near))
    stream.close()
    a, b = near[: len(out)].astype(np.float64), out.astype(np.float64)
    lags = range(-400, 401)
    best = max(lags, key=lambda k: float(np.dot(a[400:-400], np.roll(b, -k)[400:-400])))
    assert best == 208
