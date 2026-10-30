"""Integration test: real SCStream, one stream, two tracks, 2-second record.

Requires Screen Recording + Microphone permissions. First run may trigger
a permission dialog — Allow both.
"""

from __future__ import annotations

import os
import time
from pathlib import Path

import pytest
import soundfile as sf

from palaver.capture_recorder import CaptureRecorder


@pytest.mark.integration
@pytest.mark.skipif(os.environ.get("CI") == "true", reason="no mic in CI")
def test_captures_both_tracks(tmp_path: Path):
    mic = tmp_path / "mic_raw.wav"
    sys_ = tmp_path / "system.wav"
    rec = CaptureRecorder(mic_raw_path=mic, system_path=sys_)
    rec.start()
    time.sleep(3.0)
    rec.stop()

    # System audio should come from the Process Tap; "scstream" means the tap
    # failed to start (missing System Audio Recording permission?).
    assert rec.system_source == "process-tap"

    assert mic.exists() and sys_.exists()
    for p in (mic, sys_):
        _, sr = sf.read(p, dtype="int16")
        assert sr == 16_000, f"{p.name} sr={sr}"

    # The mic delivers continuously. The tap only delivers while something is
    # playing, so system.wav may be empty in a quiet room — but never longer
    # than the mic track, since both share sample 0.
    m_data, _ = sf.read(mic, dtype="int16")
    s_data, _ = sf.read(sys_, dtype="int16")
    assert len(m_data) > 2 * 16_000, f"mic too short: {len(m_data)}"
    assert len(s_data) <= len(m_data) + 1_600
