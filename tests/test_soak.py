"""Soak test (issue #49): replay a recording through the live and the
realtime stream workers at real speed and hold them to a memory ceiling.

Excluded by default; run it before a release::

    pytest -m soak tests/test_soak.py -s                          # 60 minutes
    PALAVER_SOAK_MINUTES=3 pytest -m soak tests/test_soak.py -s   # a short calibration

It never opens the microphone or plays a sound: the audio comes from WAV
files, written into a temporary recording folder the way the recorder writes
them (``stream_bench.replay``), while `palaver live` and `palaver stream` run
on that folder as the daemon starts them. Memory is the phys_footprint of
each worker and its children (``memory.tree_footprint``), sampled every
SAMPLE_SECONDS. A worker above its ceiling stops the soak at once. When
Palaver starts recording meanwhile, the soak stops and is skipped.

Environment:

- PALAVER_SOAK_MINUTES: how much audio to replay (60).
- PALAVER_SOAK_SOURCE: a folder with mic_raw.wav and system.wav (16 kHz
  mono); default: a synthetic 30 s voice, looped, as the other
  side, and the same voices shifted and quieter as the microphone.
- PALAVER_SOAK_CONFIG: the config.toml the workers read (default
  ~/.config/palaver/config.toml; only read).
- PALAVER_SOAK_LIVE_GB, PALAVER_SOAK_STREAM_GB: the ceilings (default: the
  budgets, memory.DEFAULT_LIVE_GB and DEFAULT_STREAM_GB).
- PALAVER_SOAK_REPORT: a JSON file the numbers are written to.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from palaver import memory
from palaver.memory import GB
from palaver.paths import RecordingPaths

SAMPLE_RATE = 16_000
SAMPLE_SECONDS = 2.0
RECORDING_CHECK_SECONDS = 10.0
FINISH_TIMEOUT = 15 * 60.0  # the live worker finishes its last block after the stop
ROOT = Path(__file__).resolve().parents[1]


def _synthetic_voice(seconds: float) -> np.ndarray:
    """Harmonics of a low voice in ~0.25 s bursts with pauses: no speech, but
    audio of the same shape (use ``source`` for a real recording)."""
    t = np.arange(int(seconds * SAMPLE_RATE)) / SAMPLE_RATE
    pitch = 110 + 20 * np.sin(2 * np.pi * 0.3 * t)
    voice = sum(np.sin(2 * np.pi * k * np.cumsum(pitch) / SAMPLE_RATE) / k for k in range(1, 9))
    bursts = (np.sin(2 * np.pi * 2.0 * t) > -0.3) & (np.sin(2 * np.pi * 0.17 * t) > -0.5)
    return (0.3 * voice * bursts).astype(np.float32)


def soak_source(dest: Path, minutes: float, source: Path | None = None) -> RecordingPaths:
    """A recording folder with ``minutes`` of mic_raw.wav and system.wav:
    cut from ``source``, or made from a synthetic voice (harmonics in syllable bursts)."""
    dest.mkdir(parents=True, exist_ok=True)
    out = RecordingPaths(dest)
    n = int(minutes * 60 * SAMPLE_RATE)
    if source is not None:
        src = RecordingPaths(source)
        for path, target in ((src.mic_raw_wav, out.mic_raw_wav), (src.system_wav, out.system_wav)):
            audio, rate = sf.read(str(path), frames=n, dtype="int16")
            assert rate == SAMPLE_RATE and audio.ndim == 1, f"{path.name}: needs 16 kHz mono"
            sf.write(str(target), audio, SAMPLE_RATE, subtype="PCM_16")
        return out
    voices = _synthetic_voice(30.0)
    system = np.resize(voices, n)
    # The microphone: the same voices 15 s later (someone else talking) and
    # a little of the other side heard through the speakers.
    mic = 0.6 * np.roll(system, 15 * SAMPLE_RATE) + 0.05 * system
    for track, target in ((system, out.system_wav), (mic, out.mic_raw_wav)):
        sf.write(str(target), np.clip(track, -1, 1), SAMPLE_RATE, subtype="PCM_16")
    return out


def palaver_recording() -> bool:
    """Whether the running Palaver records (its daemon.json)."""
    from palaver.daemon import STATE_PATH, palaver_alive

    try:
        state = json.loads(STATE_PATH.read_text())
    except (OSError, ValueError):
        return False
    return state.get("state") == "recording" and palaver_alive(state.get("pid"))


def test_soak_source_is_16k_mono_of_the_asked_length(tmp_path):
    paths = soak_source(tmp_path / "src", 0.75)
    for path in (paths.mic_raw_wav, paths.system_wav):
        info = sf.info(str(path))
        assert (info.samplerate, info.channels, info.frames) == (SAMPLE_RATE, 1, 45 * SAMPLE_RATE)
    cut = soak_source(tmp_path / "cut", 0.25, source=tmp_path / "src")
    assert sf.info(str(cut.system_wav)).frames == 15 * SAMPLE_RATE


def _launch(cmd: str, folder: Path, config: Path, log: Path) -> subprocess.Popen:
    env = {**os.environ, "PYTHONPATH": str(ROOT)}
    with open(log, "a") as fh:
        return subprocess.Popen([sys.executable, "-m", "palaver", "--config", str(config), "--no-notify", cmd,
                                 str(folder)], cwd=ROOT, env=env, stdout=fh, stderr=subprocess.STDOUT,
                                stdin=subprocess.DEVNULL, start_new_session=True)


def _stop(workers: dict[str, subprocess.Popen]) -> None:
    for p in workers.values():
        if p.poll() is None:
            try:
                os.killpg(p.pid, signal.SIGTERM)
            except OSError:
                pass
    for p in workers.values():
        try:
            p.wait(10)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except OSError:
                pass
            p.wait()


@pytest.mark.soak
def test_live_and_stream_stay_under_their_ceilings_at_real_speed(tmp_path):
    from palaver.stream_bench import BenchAborted, replay

    minutes = float(os.environ.get("PALAVER_SOAK_MINUTES", 60))
    ceilings = {"live": float(os.environ.get("PALAVER_SOAK_LIVE_GB", memory.DEFAULT_LIVE_GB)),
                "stream": float(os.environ.get("PALAVER_SOAK_STREAM_GB", memory.DEFAULT_STREAM_GB))}
    config = Path(os.environ.get("PALAVER_SOAK_CONFIG", Path.home() / ".config" / "palaver" / "config.toml"))
    if not config.exists():
        pytest.skip(f"no config at {config}")
    if palaver_recording():
        pytest.skip("Palaver is recording; the soak waits for a quiet Mac")
    source = os.environ.get("PALAVER_SOAK_SOURCE")
    src = soak_source(tmp_path / "source", minutes, Path(source) if source else None)
    folder = tmp_path / "rec"
    stop = threading.Event()
    replayed: list = []

    def do_replay():
        try:
            replay(src, folder, speed=1.0, stop=stop)
            replayed.append("done")
        except BenchAborted:
            replayed.append("stopped")
        except Exception as exc:  # pragma: no cover - shown in the failure
            replayed.append(exc)

    replayer = threading.Thread(target=do_replay, daemon=True)
    replayer.start()
    while not (folder / "system.wav.part").exists() and replayer.is_alive():
        time.sleep(0.05)
    log = tmp_path / "workers.log"
    workers = {kind: _launch(kind, folder, config, log) for kind in ("live", "stream")}
    peaks = memory.PeakTracker()
    started = time.monotonic()
    stopped_at = None
    over = interrupted = None
    last_check = started
    try:
        while any(p.poll() is None for p in workers.values()):
            now = time.monotonic()
            for kind, p in workers.items():
                used = peaks.sample(kind, p.pid) if p.poll() is None else None
                if used is not None and used > ceilings[kind] * GB:
                    over = f"{kind} worker at {memory.size_text(used)}, over its {ceilings[kind]:g} GB ceiling"
            if over:
                break
            if now - last_check >= RECORDING_CHECK_SECONDS:
                last_check = now
                if palaver_recording():
                    interrupted = "Palaver started recording"
                    break
            if stopped_at is None and not replayer.is_alive():
                stopped_at = now
            if stopped_at is not None and now - stopped_at > FINISH_TIMEOUT:
                over = "the live worker did not finish after the stop"
                break
            time.sleep(SAMPLE_SECONDS)
    finally:
        stop.set()
        _stop(workers)
        replayer.join(30)
    summary = {kind: {k: (round(v / GB, 2) if k != "samples" else v) for k, v in s.items()}
               for kind, s in peaks.summary().items()}
    report = {"minutes": minutes, "ceilings_gb": ceilings, "footprint_gb": summary,
              "live_finish_s": round(time.monotonic() - stopped_at, 1) if stopped_at else None,
              "exit": {k: p.returncode for k, p in workers.items()},
              "source": source or "synthetic voice, looped"}
    print("\nsoak:", json.dumps(report))
    if os.environ.get("PALAVER_SOAK_REPORT"):
        Path(os.environ["PALAVER_SOAK_REPORT"]).write_text(json.dumps(report, indent=2))
    if interrupted:
        pytest.skip(f"soak stopped: {interrupted}")
    tail = log.read_text()[-3000:] if log.exists() else ""
    assert over is None, f"{over}\n{json.dumps(report)}\n{tail}"
    assert replayed == ["done"], f"replay: {replayed}\n{tail}"
    assert report["exit"] == {"live": 0, "stream": 0}, tail
    for kind, ceiling in ceilings.items():
        assert peaks.peak(kind) <= ceiling * GB, report
