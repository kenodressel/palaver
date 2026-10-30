"""Tests for the live level meter shown during `record`."""

import io
from pathlib import Path

import numpy as np

from palaver.meter import LevelMeter, format_line, level_dbfs

HEADER = b"\x00" * 44


def _append(path: Path, samples: np.ndarray) -> None:
    with open(path, "ab") as f:
        f.write(samples.astype(np.int16).tobytes())


def _tone(seconds: float, amp: float) -> np.ndarray:
    t = np.arange(int(seconds * 16_000))
    return amp * 32_767 * np.sin(2 * np.pi * 220 * t / 16_000)


def test_level_dbfs_of_full_scale_sine_is_about_minus_3():
    assert abs(level_dbfs(_tone(0.5, 1.0).astype(np.int16).tobytes()) + 3.0) < 0.2


def test_level_dbfs_of_digital_silence_is_none():
    assert level_dbfs(np.zeros(800, dtype=np.int16).tobytes()) is None
    assert level_dbfs(b"") is None


def test_format_line_shows_levels_and_silence_counters():
    line = format_line(42.0, [("mic", -18.0, 0.0), ("system", None, 12.0)])
    assert line.startswith("rec 00:42 | mic ")
    assert "-18 dB" in line
    assert "system" in line and "silent 12s" in line


def test_meter_only_measures_newly_written_audio(tmp_path: Path):
    """The Process Tap stops writing during silence; re-reading the file tail
    would keep showing the last (stale) audio."""
    mic, system = tmp_path / "mic.part", tmp_path / "system.part"
    for p in (mic, system):
        p.write_bytes(HEADER)
    out = io.StringIO()
    now = [0.0]
    meter = LevelMeter([("mic", mic), ("system", system)], out=out, clock=lambda: now[0])

    _append(mic, _tone(1.0, 0.1))
    _append(system, _tone(1.0, 0.5))
    now[0] = 1.0
    meter.tick()
    first = out.getvalue().split("\r")[-1]
    assert "-23 dB" in first and "-9 dB" in first

    _append(mic, _tone(1.0, 0.1))  # system stops growing
    now[0] = 6.0
    meter.tick()
    second = out.getvalue().split("\r")[-1]
    assert "-23 dB" in second
    assert "silent 5s" in second


def test_meter_tolerates_missing_files(tmp_path: Path):
    out = io.StringIO()
    meter = LevelMeter([("mic", tmp_path / "nope.part")], out=out, clock=lambda: 3.0)
    meter.tick()
    assert "mic" in out.getvalue()


def test_level_tracker_reports_levels_without_printing(tmp_path: Path):
    from palaver.meter import LevelTracker

    mic = tmp_path / "mic.part"
    mic.write_bytes(HEADER)
    now = [0.0]
    tracker = LevelTracker([("mic", mic)], clock=lambda: now[0])
    _append(mic, _tone(1.0, 0.1))
    now[0] = 1.0
    [(label, db, silent)] = tracker.read()
    assert label == "mic" and round(db) == -23 and silent == 0.0
    now[0] = 4.0
    [(_, db, silent)] = tracker.read()
    assert db is None and silent == 3.0


def test_level_tracker_says_how_long_every_track_was_quiet(tmp_path: Path):
    """Room noise on the mic is not sound; speech on either track is."""
    from palaver.meter import LevelTracker

    mic, system = tmp_path / "mic.part", tmp_path / "system.part"
    mic.write_bytes(HEADER)
    system.write_bytes(HEADER)
    now = [0.0]
    tracker = LevelTracker([("mic", mic), ("system", system)], clock=lambda: now[0])
    assert tracker.quiet_for() == 0.0
    for t in range(1, 6):
        _append(mic, _tone(0.5, 0.001))  # about -63 dB: a quiet room
        now[0] = float(t)
        tracker.read()
    assert tracker.quiet_for() == 5.0
    _append(system, _tone(0.5, 0.1))  # someone speaks
    now[0] = 6.0
    tracker.read()
    assert tracker.quiet_for() == 0.0
    now[0] = 9.0
    tracker.read()
    assert tracker.quiet_for() == 3.0
