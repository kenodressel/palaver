"""The live stream's replay bench (#42).

`palaver bench-live <folder>... --out DIR` replays each recorded meeting
into ``DIR/<id>/rec`` the way the recorder writes it, chunk by chunk into
``.part`` files, while `palaver live` and `palaver stream` run on that folder
as they would during a call. It then compares what the stream settled with
the meeting's final transcript and writes ``DIR/report.md``: numbers only,
no transcript text, titles or names.

- latency: when a sentence showed in stream.json (a mic one after the
  echo wait) against when its last word was said (only at ``--speed 1``);
- disagreement: word edits between the live text and the final one, per
  final word; ``offline`` is the same for the model run offline on the
  replayed system track, the baseline the live stream can't beat;
- echo: the share of live mic sentences that are the other side heard
  through the speakers, judged against the final system words;
- load: the stream's CPU and memory, the machine's GPU, and how long the
  block worker took to finish after the stop.

A child process that passes ``MEMORY_CAP_MB`` is killed with the other and
the bench stops.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import signal
import subprocess
import threading
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Callable, Protocol

import numpy as np
import soundfile as sf

from .bench import tokens
from .capture_recorder import _IncrementalTrackWriter
from .cleanup import echoes_remote
from .live import _write_atomic
from .models import Segment
from .paths import RecordingPaths

SAMPLE_RATE = _IncrementalTrackWriter.SAMPLE_RATE
MEMORY_CAP_MB = 8000.0  # any child above this is killed and the bench stops (R2)
_GPU = re.compile(r'"Device Utilization %"\s*=\s*(\d+)')
_LANGUAGE = re.compile(r"^[a-z]{2,3}(?:[-_][A-Za-z0-9]+)?$")
_NONE = "—"


class BenchAborted(RuntimeError):
    """The bench stopped before it could measure."""


class Transcriber(Protocol):
    def transcribe(self, wav: Path) -> list[Segment]: ...


def replay(src: RecordingPaths, dest: Path, *, speed: float, chunk_seconds: float = 0.1,
           clock: Callable[[], float] = time.time, sleep: Callable[[float], None] = time.sleep,
           stop: threading.Event | None = None) -> float:
    """Write ``src``'s mic_raw.wav and system.wav into ``dest`` as the recorder
    would: chunk by chunk into ``.part`` files, each chunk once the audio it
    holds has been said, at ``speed`` times real time. Then finalize both and
    write meta.json. Returns the wall clock when the recording "started".
    Raises BenchAborted, leaving the ``.part`` files, once ``stop`` is set."""
    dest.mkdir(parents=True, exist_ok=True)
    out = RecordingPaths(dest)
    pairs = [(src.mic_raw_wav, out.mic_raw_wav), (src.system_wav, out.system_wav)]
    for path, _ in pairs:
        _check_wav(path)
    readers = [sf.SoundFile(str(path)) for path, _ in pairs]
    writers = [_IncrementalTrackWriter(path) for _, path in pairs]
    chunk = max(1, int(chunk_seconds * SAMPLE_RATE))
    start = clock()
    try:
        done = 0
        while True:
            blocks = [r.read(chunk, dtype="int16") for r in readers]
            if not any(len(b) for b in blocks):
                break
            done += chunk
            sleep(max(0.0, start + done / SAMPLE_RATE / speed - clock()))
            if stop is not None and stop.is_set():
                raise BenchAborted("replay stopped")
            for writer, block in zip(writers, blocks):
                writer.write_chunk_at_offset(writer.frames_written, block)
                writer.flush()
    except BaseException:
        for writer in writers:
            writer.abort()
        raise
    finally:
        for reader in readers:
            reader.close()
    seconds = max(w.frames_written for w in writers) / SAMPLE_RATE
    for writer in writers:
        writer.finalize_to(writer.frames_written)
    started = datetime.fromtimestamp(start).astimezone()
    _write_atomic(out.meta, json.dumps({
        "start_time": started.isoformat(),
        "end_time": (started + timedelta(seconds=seconds)).isoformat(),
        "duration_seconds": seconds,
        "trigger": "bench",
    }, indent=2))
    return start


def _check_wav(path: Path) -> None:
    info = sf.info(str(path))
    if info.samplerate != SAMPLE_RATE or info.channels != 1:
        raise ValueError(f"{path.name}: {info.samplerate} Hz, {info.channels} channels; "
                         f"the bench replays {SAMPLE_RATE} Hz mono")


def check_source(src: RecordingPaths) -> None:
    """Everything measuring a meeting reads from its folder, so a bad folder
    fails before anything is replayed, not after an hour of replay."""
    for path in (src.mic_raw_wav, src.system_wav, src.system_segments, src.transcript_json, src.meta):
        if not path.exists():
            raise FileNotFoundError(f"{src.folder.name}: {path.name} is missing; the bench needs a processed meeting")
    for path in (src.mic_raw_wav, src.system_wav):
        _check_wav(path)


def latency(segments: list[dict], start_wall: float, speed: float) -> dict[str, float]:
    """Seconds from when each sentence's last word was said to when it
    showed in stream.json (``published_at``: a mic sentence after the echo
    wait; ``settled_at`` in files from before it): p50, p90 and how many.
    Empty unless replayed in real time."""
    if speed != 1.0 or not segments:
        return {}
    lags = [s.get("published_at", s["settled_at"]) - (start_wall + s["end"] / speed) for s in segments]
    p50, p90 = np.percentile(lags, [50, 90])
    return {"p50": float(p50), "p90": float(p90), "n": len(lags)}


def disagreement(live: list[str], final: list[str]) -> float:
    """Word edits from ``final`` to ``live``, per final word."""
    from rapidfuzz.distance import Levenshtein

    a, b = tokens(" ".join(live)), tokens(" ".join(final))
    if not b:
        return 0.0 if not a else 1.0
    return Levenshtein.distance(a, b) / len(b)


def echo_share(live_mic: list[Segment], final_system: list[Segment]) -> float:
    """The share of live mic sentences that are remote speech by their words."""
    if not live_mic:
        return 0.0
    remote = [w for s in final_system for w in s.words]
    return sum(echoes_remote(s, remote) for s in live_mic) / len(live_mic)


def _output(cmd: list[str]) -> str:
    return subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=10).stdout


def _kill(pid: int) -> None:
    """The child and anything it started: each runs in its own session."""
    try:
        os.killpg(pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def measure_load(pids: list[int], stop: threading.Event, every: float = 1.0, *,
                 cap_mb: float = MEMORY_CAP_MB, run: Callable[[list[str]], str] = _output,
                 kill: Callable[[int], None] | None = None,
                 wait: Callable[[float], bool] | None = None) -> dict[str, Any]:
    """Sample CPU and RSS of ``pids`` and the GPU's utilization every
    ``every`` seconds until ``stop`` is set. CPU is summed over the pids per
    sample; ``per_pid`` holds each one's. If any pid passes ``cap_mb``, all
    are killed (``kill``, default: their process group), ``stop`` is set
    and ``killed`` names it."""
    wait = wait or stop.wait
    kill = kill or _kill
    cpu: dict[int, list[float]] = {pid: [] for pid in pids}
    rss: dict[int, float] = {pid: 0.0 for pid in pids}
    total: list[float] = []
    gpu: list[float] = []
    killed = None
    while not stop.is_set():
        now = 0.0
        seen = False
        for pid in pids:
            try:
                fields = run(["ps", "-o", "%cpu=,rss=", "-p", str(pid)]).split()
                # "12,3" under a German locale
                c, mb = float(fields[0].replace(",", ".")), float(fields[1]) / 1024
            except (subprocess.SubprocessError, OSError, IndexError, ValueError):
                continue  # exited
            if mb <= 0:
                continue  # finished but not yet reaped: ps shows "0.0 0"
            seen = True
            cpu[pid].append(c)
            rss[pid] = max(rss[pid], mb)
            now += c
            if mb > cap_mb and killed is None:
                killed = {"pid": pid, "rss_mb": mb}
        if killed is not None:
            for pid in pids:
                kill(pid)
            stop.set()
            break
        if seen:
            total.append(now)
        try:
            found = [float(g) for g in _GPU.findall(run(["ioreg", "-r", "-d", "1", "-w", "0", "-c", "IOAccelerator"]))]
            if found:
                gpu.append(max(found))
        except (subprocess.SubprocessError, OSError):
            pass
        if wait(every):
            break
    return {
        "cpu_mean": _mean(total), "cpu_peak": max(total, default=None),
        "rss_peak_mb": max(rss.values(), default=0.0) or None,
        "gpu_mean": _mean(gpu), "gpu_peak": max(gpu, default=None),
        "per_pid": {pid: {"cpu_mean": _mean(cpu[pid]), "cpu_peak": max(cpu[pid], default=None),
                          "rss_peak_mb": rss[pid] or None} for pid in pids},
        "killed": killed,
    }


def _mean(values: list[float]) -> float | None:
    return sum(values) / len(values) if values else None


def _last_event(log: Path, name: str) -> dict | None:
    """The last ``name`` event in a session.log."""
    found = None
    try:
        lines = log.read_text().splitlines()
    except OSError:
        return None
    for line in lines:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict) and row.get("event") == name:
            found = row
    return found


def _segments(path: Path) -> list[Segment]:
    return [Segment.from_dict(d) for d in json.loads(path.read_text())]


def _language(paths: RecordingPaths) -> str:
    """The detected language's code; anything else is not shown."""
    try:
        code = paths.language.read_text().strip()
    except OSError:
        return _NONE
    return code if _LANGUAGE.match(code) else _NONE


def _launch_run(*args, **kwargs):
    from .daemon import launch_run

    return launch_run(*args, **kwargs)


def _measure_meeting(src: RecordingPaths, folder: Path, *, speed: float, user_name: str,
                     cli_options: list[str], launch: Callable, measure: Callable,
                     transcriber: Transcriber | None, sleep: Callable[[float], None],
                     kill: Callable[[int], None]) -> dict[str, Any]:
    rec = folder / "rec"
    if rec.exists():
        shutil.rmtree(rec)  # a fresh replay, not an earlier run's leftovers
    rec.mkdir(parents=True)
    log = folder / "bench.log"
    stop = threading.Event()
    replayed: dict[str, Any] = {}

    def do_replay() -> None:
        try:
            replayed["start"] = replay(src, rec, speed=speed, sleep=sleep, stop=stop)
        except BaseException as exc:  # re-raised below
            replayed["error"] = exc

    replayer = threading.Thread(target=do_replay, name="bench-replay", daemon=True)
    replayer.start()
    # The daemon starts both once the recorder has opened its files.
    rec_paths = RecordingPaths(rec)
    while replayer.is_alive() and not all(Path(str(p) + ".part").exists()
                                          for p in (rec_paths.mic_raw_wav, rec_paths.system_wav)):
        time.sleep(0.01)
    if "error" in replayed:
        raise replayed["error"]
    procs: list = []
    load: dict[str, Any] = {}
    measurer = threading.Thread(target=lambda: load.update(measure([p.pid for p in procs], stop)),
                                name="bench-load", daemon=True)
    try:
        procs.append(launch(rec, list(cli_options), log_path=log, cmd="live", qos="background"))
        procs.append(launch(rec, list(cli_options), log_path=log, cmd="stream", qos="utility"))
        live_proc, stream_proc = procs
        measurer.start()
        replayer.join()
        if "error" in replayed and not stop.is_set():
            raise replayed["error"]  # the children would only stall out
        rc = {"live": live_proc.wait(), "stream": stream_proc.wait()}
    except BaseException:
        # Ctrl-C, SIGTERM (see the CLI), a failed launch or replay: the
        # children run in their own sessions and would outlive the bench.
        stop.set()
        for proc in procs:
            if proc.poll() is None:  # a reaped child's pid may be someone else's by now
                kill(proc.pid)
        for proc in procs:
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                pass
        raise
    finally:
        stop.set()
        if measurer.is_alive():
            measurer.join()
        replayer.join(timeout=10)
    if load.get("killed"):
        raise BenchAborted(f"{src.folder.name}: a child passed {MEMORY_CAP_MB:.0f} MB RSS "
                           f"({load['killed']['rss_mb']:.0f} MB); killed both and stopped")
    if "error" in replayed:
        raise replayed["error"]

    stream = json.loads(rec_paths.stream.read_text()) if rec_paths.stream.exists() else None
    final_system = _segments(src.system_segments)
    utterances = json.loads(src.transcript_json.read_text())
    final_mic = [u["text"] for u in utterances if u.get("speaker") == user_name]
    finish = _last_event(rec_paths.session_log, "live_finish_done")
    merged = _last_event(src.session_log, "merge_done")
    stream_load = load.get("per_pid", {}).get(stream_proc.pid, {})
    meta = json.loads(src.meta.read_text())
    tracks: dict[str, dict[str, Any]] = {}
    for track in ("system", "mic"):
        live = (stream or {}).get(track)
        row: dict[str, Any] = {"latency": {}, "disagreement": None, "offline": None, "echo": None}
        if live is not None:
            row["latency"] = latency(live, replayed["start"], speed)
            final = [s.text for s in final_system] if track == "system" else final_mic
            row["disagreement"] = disagreement([s["text"] for s in live], final)
            if track == "mic":
                row["echo"] = echo_share([Segment.from_dict(s) for s in live], final_system)
        tracks[track] = row
    if transcriber is not None:
        offline = transcriber.transcribe(rec_paths.system_wav)
        tracks["system"]["offline"] = disagreement([s.text for s in offline], [s.text for s in final_system])
    return {
        "minutes": float(meta.get("duration_seconds", 0)) / 60,
        "language": _language(src),
        "speakers": len({u.get("speaker") for u in utterances}),
        "tracks": tracks,
        "cpu": (stream_load.get("cpu_mean"), stream_load.get("cpu_peak")),
        "gpu": (load.get("gpu_mean"), load.get("gpu_peak")),
        "rss_mb": stream_load.get("rss_peak_mb"),
        "live_finish": finish.get("seconds") if finish else None,
        "echo_dropped": merged.get("dropped_bleed_duplicates") if merged else None,
        "rc": rc,
    }


def run(folders: list[Path], out: Path, *, speed: float, user_name: str, cli_options: list[str] = (),
        launch: Callable = _launch_run, measure: Callable[[list[int], threading.Event], dict] = measure_load,
        transcriber: Transcriber | None = None, sleep: Callable[[float], None] = time.sleep,
        kill: Callable[[int], None] | None = None) -> Path:
    """Replay and measure each meeting folder; write ``out/report.md``,
    again after each meeting, so a later failure keeps the earlier rows.
    Every folder is checked before the first replay. On any error the
    children are killed (``kill``, default: their process group) before it
    propagates."""
    sources = [RecordingPaths(folder) for folder in folders]
    for src in sources:
        check_source(src)
    out.mkdir(parents=True, exist_ok=True)
    report = out / "report.md"
    results = {}
    for src in sources:
        print(f"{src.folder.name}: replaying at {speed:g}× real time…", flush=True)
        results[src.folder.name] = _measure_meeting(
            src, out / src.folder.name, speed=speed, user_name=user_name,
            cli_options=list(cli_options), launch=launch, measure=measure, transcriber=transcriber, sleep=sleep,
            kill=kill or _kill)
        report.write_text(render(results, speed))
    return report


def _num(value: float | None, digits: int = 0) -> str:
    if value is None:
        return _NONE
    return f"{value:.{digits}f}" if digits else str(round(value))


def _pct(value: float | None) -> str:
    return _NONE if value is None else str(round(100 * value))


def _pair(values: tuple[float | None, float | None]) -> str:
    return f"{_num(values[0])} / {_num(values[1])}"


def render(results: dict[str, dict[str, Any]], speed: float) -> str:
    """The report: one row per meeting and track, numbers only."""
    out = ["# Live stream bench", "",
           f"Replayed at {speed:g}× real time. Latency: when a sentence showed minus when its last word was "
           "said (real time only). Disagreement: word edits per final word, live text against the final "
           "transcript; offline: the same model run offline on the replayed system track. Echo: live mic "
           "sentences that are the other side. CPU and RSS: the stream process; GPU: the whole machine. "
           "live_finish: the block worker's finish after the stop. Echo dropped: mic segments the final "
           "transcript dropped as bleed or echo.", "",
           "| meeting | min | lang | speakers | track | latency p50 / p90 s | disagreement % | offline % | echo % "
           "| stream CPU % mean / peak | GPU % mean / peak | RSS MB | live_finish s | echo dropped |",
           "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    notes = []
    for meeting, r in results.items():
        for track, t in r["tracks"].items():
            lat = t["latency"]
            out.append(" | ".join([
                f"| {meeting}", _num(r["minutes"], 1), r["language"], str(r["speakers"]), track,
                f"{_num(lat['p50'], 1)} / {_num(lat['p90'], 1)}" if lat else _NONE,
                _pct(t["disagreement"]), _pct(t["offline"]), _pct(t["echo"]) if track == "mic" else _NONE,
                _pair(r["cpu"]), _pair(r["gpu"]), _num(r["rss_mb"]), _num(r["live_finish"], 1),
                _num(r["echo_dropped"]),
            ]) + " |")
        if any(r["rc"].values()):
            notes.append(f"- {meeting}: live exited {r['rc']['live']}, stream exited {r['rc']['stream']}")
    if notes:
        out += ["", *notes]
    return "\n".join(out) + "\n"
