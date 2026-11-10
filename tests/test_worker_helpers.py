"""palaver-worker's helpers (palaver-lm's notes; Python's cloud-transcribe and sync) belong to the worker's process
group: the daemon stops a worker with killpg, and a helper must stop with it (a notes run keeps gigabytes of model). A
SIGTERM sent to the worker alone reaches its helper too, and the worker ends once the helper did.

Runs the debug build (``make parity-helper``); skipped without it.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import time
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

ROOT = Path(__file__).resolve().parents[1]
WORKER = ROOT / "native" / ".build" / "debug" / "palaver-worker"

PYTHON = """#!/bin/sh
case " $* " in
  *" notes "*) echo $$ > "$NOTES_PID"; exec /bin/sleep 60 ;;
esac
exit 0
"""


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def _gone_within(pid: int, seconds: float) -> bool:
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if not _alive(pid):
            return True
        time.sleep(0.05)
    return not _alive(pid)


@pytest.fixture
def worker_in_notes(tmp_path: Path):
    """palaver-worker processing a 1 s meeting, started in a session of its own as the daemon starts it, stopped in
    its notes helper; yields (worker, the helper's pid)."""
    if not WORKER.exists():
        pytest.skip("palaver-worker is not built (make parity-helper)")
    recs = tmp_path / "Recordings"
    folder = recs / "2026-10-20T14-35-17"
    folder.mkdir(parents=True)
    tone = (0.3 * np.sin(2 * np.pi * 220 * np.arange(16_000) / 16_000)).astype(np.float32)
    sf.write(str(folder / "mic.wav"), tone, 16_000, subtype="PCM_16")
    sf.write(str(folder / "system.wav"), tone, 16_000, subtype="PCM_16")
    (folder / "meta.json").write_text(json.dumps({"start_time": "2026-10-20T14:35:17+02:00", "duration_seconds": 1.0}))
    engine = tmp_path / "engine.json"
    engine.write_text(json.dumps({"transcribe": {"mic.wav": [
        {"start": 0.0, "end": 1.0, "text": "Hallo.", "speaker": None, "words": []}]}}))
    config = tmp_path / "config.toml"
    config.write_text(f'[user]\nname = "Timo"\n[recording]\noutput_dir = "{recs}"\n[calendar]\nenabled = false\n')
    python = tmp_path / "python"
    python.write_text(PYTHON)
    python.chmod(0o755)
    pid_file = tmp_path / "notes.pid"
    home = tmp_path / "home"
    env = {"PATH": "/usr/bin:/bin", "XDG_CONFIG_HOME": str(tmp_path / "config"), "PALAVER_HOME": str(home),
           "HOME": str(home), "PALAVER_TEST_ENGINE": str(engine), "NOTES_PID": str(pid_file), "TZ": "Europe/Berlin",
           "PALAVER_LM_BIN": str(python)}  # palaver-lm, which writes the notes: the same script
    worker = subprocess.Popen([str(WORKER), "--config", str(config), "--no-notify", "process", str(folder)], env=env, start_new_session=True,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        end = time.monotonic() + 60
        while not (pid_file.exists() and pid_file.read_text().strip()):
            assert worker.poll() is None, f"the worker ended (exit {worker.returncode}) before its notes helper ran"
            assert time.monotonic() < end, "the notes helper never started"
            time.sleep(0.05)
        yield worker, int(pid_file.read_text())
    finally:
        for pid in (worker.pid,):
            try:
                os.killpg(pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        worker.wait(10)


def test_killing_the_workers_group_stops_its_helper(worker_in_notes):
    worker, helper = worker_in_notes
    assert os.getpgid(helper) == worker.pid  # the worker's group, not one of its own
    os.killpg(worker.pid, signal.SIGTERM)  # how the daemon stops a worker
    worker.wait(10)
    assert _gone_within(helper, 5)


def test_a_sigterm_to_the_worker_alone_reaches_the_helper_and_ends_the_worker(worker_in_notes):
    worker, helper = worker_in_notes
    os.kill(worker.pid, signal.SIGTERM)
    assert worker.wait(10) == -signal.SIGTERM  # it waited for its helper, then stopped as told
    assert _gone_within(helper, 5)
