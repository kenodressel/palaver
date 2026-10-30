"""Tests for the live stream's replay bench (no subprocesses, no model)."""

import json
import threading
import time
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from palaver import stream_bench
from palaver.models import Segment, Word
from palaver.paths import RecordingPaths

SR = 16_000
MEETING = "2026-10-21T16-29-29"
USER = "Timo Strauss"
# Every word, title and name in the fixture: none may reach the report.
SECRET = ["Attakring", "Databricks", "Quartalszahlen", "Migrationsplan", "Zwischenstand", "Timo", "Strauss",
          "Annegret", "Beispielfrau", "Geheimprojekt", "Lagebesprechung"]


@pytest.fixture(autouse=True)
def no_real_kill(monkeypatch):
    """Fake pids must never reach os.killpg."""
    def refuse(pid):
        raise AssertionError(f"real kill of pid {pid} in a test")

    monkeypatch.setattr(stream_bench, "_kill", refuse)


def _wav(path: Path, samples: np.ndarray) -> None:
    sf.write(str(path), samples, SR, subtype="PCM_16")


def _words(text: str, start: float, step: float = 0.3) -> list[Word]:
    return [Word(w, round(start + k * step, 2), round(start + k * step + 0.25, 2)) for k, w in enumerate(text.split())]


def _seg(text: str, start: float, **extra) -> dict:
    words = _words(text, start)
    return {**Segment(start, words[-1].end, text, words=words).to_dict(), **extra}


def _source(folder: Path, seconds: float = 3.0) -> RecordingPaths:
    folder.mkdir(parents=True)
    paths = RecordingPaths(folder)
    rng = np.random.default_rng(0)
    _wav(paths.mic_raw_wav, rng.integers(-3000, 3000, int(seconds * SR), dtype=np.int16))
    _wav(paths.system_wav, rng.integers(-3000, 3000, int((seconds - 0.5) * SR), dtype=np.int16))
    return paths


def test_replay_writes_like_the_recorder(tmp_path: Path):
    src = _source(tmp_path / "src")
    dest = tmp_path / "rec"
    seen_parts = []

    def sleep(seconds: float) -> None:
        seen_parts.append(sorted(p.name for p in dest.iterdir() if p.name.endswith(".part")))

    start = stream_bench.replay(src, dest, speed=1000, sleep=sleep)

    assert ["mic_raw.wav.part", "system.wav.part"] in seen_parts
    for name in ("mic_raw.wav", "system.wav"):
        ours, sr = sf.read(str(dest / name), dtype="int16")
        theirs, _ = sf.read(str(src.folder / name), dtype="int16")
        assert sr == SR
        assert np.array_equal(ours, theirs)
    assert not list(dest.glob("*.part"))
    meta = json.loads((dest / "meta.json").read_text())
    assert meta["trigger"] == "bench"
    assert meta["duration_seconds"] == pytest.approx(3.0)
    assert {"start_time", "end_time"} <= set(meta)
    assert isinstance(start, float)


def test_replay_paces_chunks_at_speed(tmp_path: Path):
    src = _source(tmp_path / "src", seconds=1.0)
    now = [100.0]
    waits = []

    def sleep(seconds: float) -> None:
        waits.append(seconds)
        now[0] += seconds

    start = stream_bench.replay(src, tmp_path / "rec", speed=2.0, chunk_seconds=0.25,
                                clock=lambda: now[0], sleep=sleep)
    assert start == 100.0
    assert now[0] == pytest.approx(100.5)  # 1 s of audio at twice the speed
    assert len(waits) == 4


def test_replay_stops_when_told(tmp_path: Path):
    src = _source(tmp_path / "src")
    stop = threading.Event()
    stop.set()
    with pytest.raises(stream_bench.BenchAborted):
        stream_bench.replay(src, tmp_path / "rec", speed=1000, sleep=lambda s: None, stop=stop)
    assert not (tmp_path / "rec" / "meta.json").exists()


def test_latency_percentiles():
    start = 1000.0
    segments = [{"end": 2.0, "settled_at": start + 3.0},  # 1 s
                {"end": 5.0, "settled_at": start + 7.0},  # 2 s
                {"end": 9.0, "settled_at": start + 13.0}]  # 4 s
    lat = stream_bench.latency(segments, start, 1.0)
    assert lat["n"] == 3
    assert lat["p50"] == pytest.approx(2.0)
    assert lat["p90"] == pytest.approx(3.6)
    assert stream_bench.latency(segments, start, 2.0) == {}
    assert stream_bench.latency([], start, 1.0) == {}


def test_latency_counts_from_publication():
    """A mic sentence is published after the echo wait, not when it settled;
    older stream.json files have no published_at."""
    start = 1000.0
    segments = [{"end": 2.0, "settled_at": start + 3.0, "published_at": start + 5.0},  # 3 s
                {"end": 5.0, "settled_at": start + 6.0}]  # 1 s
    lat = stream_bench.latency(segments, start, 1.0)
    assert (lat["p50"], lat["n"]) == (pytest.approx(2.0), 2)
    assert lat["p90"] == pytest.approx(2.8)


def test_disagreement_is_word_level():
    assert stream_bench.disagreement(["wann ist der go-live"], ["wann ist der golive"]) == pytest.approx(0.25)
    assert stream_bench.disagreement(["Äh, Wann ist", "der Termin?"], ["wann ist der termin"]) == 0.0


def test_echo_share():
    system = [Segment(1.0, 2.5, "das ist der plan", words=_words("das ist der plan", 1.0))]
    echo = Segment(1.0, 2.5, "das ist der plan", words=_words("das ist der plan", 1.1))
    own = Segment(5.0, 6.5, "ich sehe das anders", words=_words("ich sehe das anders", 5.0))
    assert stream_bench.echo_share([echo, own], system) == 0.5
    assert stream_bench.echo_share([], system) == 0.0


_IOREG = '''+-o AGXAcceleratorG14X  <class AGXAcceleratorG14X>
    {
      "PerformanceStatistics" = {"In use system memory"=123,"Device Utilization %"=%d,"Renderer Utilization %"=3}
    }
'''


def test_measure_load_samples_cpu_rss_and_gpu():
    stop = threading.Event()
    outputs = ["12,0 102400\n", _IOREG.replace("%d", "20"), "30.0 204800\n", _IOREG.replace("%d", "40")]
    cmds = []

    def run(cmd: list[str]) -> str:
        cmds.append(cmd)
        return outputs.pop(0)

    waits = []

    def wait(seconds: float) -> bool:
        waits.append(seconds)
        if len(waits) == 2:
            stop.set()
        return stop.is_set()

    load = stream_bench.measure_load([42], stop, every=0.5, run=run, wait=wait)
    assert load["cpu_mean"] == pytest.approx(21.0)
    assert load["cpu_peak"] == pytest.approx(30.0)
    assert load["rss_peak_mb"] == pytest.approx(200.0)
    assert load["gpu_mean"] == pytest.approx(30.0)
    assert load["gpu_peak"] == pytest.approx(40.0)
    assert load["per_pid"][42]["cpu_peak"] == pytest.approx(30.0)
    assert waits == [0.5, 0.5]
    assert load["killed"] is None
    assert cmds[0] == ["ps", "-o", "%cpu=,rss=", "-p", "42"]
    assert cmds[1] == ["ioreg", "-r", "-d", "1", "-w", "0", "-c", "IOAccelerator"]


def test_measure_load_kills_every_child_above_the_cap():
    stop = threading.Event()
    rss = {1: 500 * 1024, 2: 8100 * 1024}
    killed = []

    def run(cmd: list[str]) -> str:
        if cmd[0] == "ps":
            return f"5.0 {rss[int(cmd[-1])]}\n"
        return ""

    load = stream_bench.measure_load([1, 2], stop, run=run, kill=killed.append, wait=lambda s: False)
    assert sorted(killed) == [1, 2]
    assert stop.is_set()
    assert load["killed"] == {"pid": 2, "rss_mb": pytest.approx(8100.0)}


def test_measure_load_kills_through_the_module_kill_by_default(monkeypatch):
    """The default kill is looked up when called, so a patched _kill (as in
    these tests) is the one used."""
    real = []
    monkeypatch.setattr(stream_bench.os, "killpg", lambda pid, sig: real.append(pid))
    monkeypatch.setattr(stream_bench.os, "kill", lambda pid, sig: real.append(pid))
    killed = []
    monkeypatch.setattr(stream_bench, "_kill", killed.append)
    run = lambda cmd: f"5.0 {8100 * 1024}\n" if cmd[0] == "ps" else ""
    stream_bench.measure_load([1], threading.Event(), run=run, wait=lambda s: False)
    assert killed == [1] and real == []


def test_measure_load_skips_exited_processes():
    stop = threading.Event()

    def run(cmd: list[str]) -> str:
        raise stream_bench.subprocess.CalledProcessError(1, cmd)

    calls = []

    def wait(seconds: float) -> bool:
        calls.append(seconds)
        return True

    load = stream_bench.measure_load([7], stop, run=run, wait=wait)
    assert load["cpu_mean"] is None and load["gpu_mean"] is None and load["killed"] is None


class _FakeProc:
    def __init__(self, folder: Path, cmd: str, on_wait):
        self.pid = {"live": 101, "stream": 102}[cmd]
        self._on_wait = on_wait
        self.folder = folder
        self.returncode = None
        self.events = None  # a shared list of ("wait", pid) entries, if given

    def wait(self, timeout=None) -> int:
        if self.events is not None:
            self.events.append(("wait", self.pid))
        if self.returncode is None:
            self._on_wait(self.folder)
            self.returncode = 0
        return self.returncode

    def poll(self):
        return self.returncode


def _meeting(root: Path) -> Path:
    paths = _source(root / MEETING, seconds=2.0)
    folder = paths.folder
    paths.system_segments.write_text(json.dumps([_seg("Attakring Databricks Quartalszahlen", 0.2)]))
    paths.transcript_json.write_text(json.dumps([
        {"speaker": USER, "start": 1.0, "end": 1.6, "text": "Migrationsplan Zwischenstand"},
        {"speaker": "Annegret Beispielfrau", "start": 0.2, "end": 1.0, "text": "Attakring Databricks Quartalszahlen"},
    ]))
    paths.meta.write_text(json.dumps({"start_time": "2026-10-21T16:29:29+02:00", "end_time": "2026-10-21T16:29:31+02:00",
                                      "duration_seconds": 120.0}))
    paths.language.write_text("de\n")
    paths.calendar.write_text(json.dumps({"title": "Geheimprojekt Lagebesprechung"}))
    paths.session_log.write_text("\n".join(json.dumps(r) for r in [
        {"event": "merge_done", "utterances": 9, "dropped_silent": 1, "dropped_bleed_duplicates": 2},
        {"event": "merge_done", "utterances": 9, "dropped_silent": 1, "dropped_bleed_duplicates": 5},
        {"event": "live_finish_done", "seconds": 99.0},  # the original recording's, not the bench's
    ]) + "\n")
    return folder


def test_report_has_no_text(tmp_path: Path):
    folder = _meeting(tmp_path / "meetings")
    out = tmp_path / "bench"
    launches = []

    def stream_done(rec: Path) -> None:
        now = time.time()
        RecordingPaths(rec).stream.write_text(json.dumps({
            "until": 2.0,
            "system": [{k: v for k, v in _seg("Attakring Databricks Quartalszahlen", 0.2,
                                               settled_at=now + 2.0).items() if k != "words"}],
            "mic": [_seg("Migrationsplan Zwischenstand", 1.0, settled_at=now + 2.5)],
            "draft": {"system": "", "mic": ""}, "questions": [], "speaking": {"others": False, "me": False},
            "updated_at": now,
        }))

    def live_done(rec: Path) -> None:
        with open(RecordingPaths(rec).session_log, "a") as f:
            f.write(json.dumps({"event": "live_finish_done", "seconds": 12.5}) + "\n")

    def launch(folder, cli_options=(), log_path=None, cmd="run", qos="utility"):
        launches.append({"folder": Path(folder), "options": list(cli_options), "log": log_path, "cmd": cmd,
                         "qos": qos})
        return _FakeProc(Path(folder), cmd, {"stream": stream_done, "live": live_done}[cmd])

    measured = []

    def measure(pids, stop):
        measured.append(sorted(pids))
        stop.wait(5)
        return {"cpu_mean": 50.0, "cpu_peak": 80.0, "rss_peak_mb": 900.0, "gpu_mean": 10.0, "gpu_peak": 30.0,
                "per_pid": {102: {"cpu_mean": 40.0, "cpu_peak": 70.0, "rss_peak_mb": 600.0},
                            101: {"cpu_mean": 10.0, "cpu_peak": 10.0, "rss_peak_mb": 300.0}},
                "killed": None}

    class Offline:
        def transcribe(self, wav):
            assert Path(wav) == out / MEETING / "rec" / "system.wav"
            return [Segment(0.2, 1.0, "Attakring Databricks")]

    report_path = stream_bench.run([folder], out, speed=1000, user_name=USER, cli_options=["--no-notify"],
                                   launch=launch, measure=measure, transcriber=Offline(),
                                   sleep=lambda s: None, kill=lambda pid: None)

    assert report_path == out / "report.md"
    report = report_path.read_text()
    for word in SECRET:
        assert word.lower() not in report.lower(), word
    assert MEETING in report
    rows = [line for line in report.splitlines() if line.startswith(f"| {MEETING}")]
    assert len(rows) == 2
    system_row, mic_row = (next(r for r in rows if f"| {t} |" in r) for t in ("system", "mic"))
    cells = [c.strip() for c in system_row.strip("|").split("|")]
    assert cells[1:5] == ["2.0", "de", "2", "system"]
    assert "| 0 |" in system_row  # live system text = final
    assert "| 33 |" in system_row  # offline: 1 of 3 words missing
    assert "40 / 70" in system_row and "600" in system_row and "12.5" in system_row and "| 5 |" in system_row
    assert "| 0 |" in mic_row and "—" in mic_row  # mic: no offline column
    assert {(l["cmd"], l["qos"]) for l in launches} == {("live", "background"), ("stream", "utility")}
    assert all(l["log"] == out / MEETING / "bench.log" for l in launches)
    assert all(l["folder"] == out / MEETING / "rec" for l in launches)
    assert all(l["options"] == ["--no-notify"] for l in launches)
    assert measured == [[101, 102]]


def test_run_aborts_when_a_child_was_killed(tmp_path: Path):
    folder = _meeting(tmp_path / "meetings")

    def launch(folder, cli_options=(), log_path=None, cmd="run", qos="utility"):
        return _FakeProc(Path(folder), cmd, lambda rec: None)

    def measure(pids, stop):
        stop.set()
        return {"cpu_mean": None, "cpu_peak": None, "rss_peak_mb": None, "gpu_mean": None, "gpu_peak": None,
                "per_pid": {}, "killed": {"pid": 102, "rss_mb": 8123.0}}

    with pytest.raises(stream_bench.BenchAborted, match="8000 MB"):
        stream_bench.run([folder], tmp_path / "bench", speed=1000, user_name=USER, launch=launch,
                         measure=measure, transcriber=None, sleep=lambda s: None, kill=lambda pid: None)
    assert not (tmp_path / "bench" / "report.md").exists()


def test_run_launches_nothing_when_the_source_cannot_be_replayed(tmp_path: Path):
    folder = _meeting(tmp_path / "meetings")
    sf.write(str(RecordingPaths(folder).mic_raw_wav), np.zeros(48_000, np.int16), 48_000, subtype="PCM_16")
    launches = []

    def launch(*args, **kwargs):
        launches.append(kwargs)

    with pytest.raises(ValueError, match="48000 Hz"):
        stream_bench.run([folder], tmp_path / "bench", speed=1000, user_name=USER, launch=launch,
                         measure=lambda pids, stop: {}, sleep=lambda s: None)
    assert launches == []


def test_measure_load_ignores_finished_processes():
    """A finished but unreaped child shows as "0.0 0" in ps: not a sample."""
    stop = threading.Event()
    outputs = ["40.0 102400\n", "", "0.0 0\n", "", "0.0 0\n", ""]
    waits = []

    def wait(seconds: float) -> bool:
        waits.append(seconds)
        return len(waits) == 3

    load = stream_bench.measure_load([42], stop, run=lambda cmd: outputs.pop(0), wait=wait)
    assert load["per_pid"][42]["cpu_mean"] == pytest.approx(40.0)
    assert load["cpu_mean"] == pytest.approx(40.0)


def test_children_are_killed_when_a_launch_fails(tmp_path: Path):
    folder = _meeting(tmp_path / "meetings")
    events = []
    procs = []

    def launch(folder, cli_options=(), log_path=None, cmd="run", qos="utility"):
        if cmd == "stream":
            raise OSError("no such interpreter")
        proc = _FakeProc(Path(folder), cmd, lambda rec: None)
        proc.events = events
        procs.append(proc)
        return proc

    with pytest.raises(OSError, match="interpreter"):
        stream_bench.run([folder], tmp_path / "bench", speed=1000, user_name=USER, launch=launch,
                         measure=lambda pids, stop: {}, sleep=lambda s: None,
                         kill=lambda pid: events.append(("kill", pid)))
    assert events == [("kill", 101), ("wait", 101)]


def test_children_are_killed_at_once_when_the_replay_fails(tmp_path: Path):
    folder = _meeting(tmp_path / "meetings")
    events = []
    launched = threading.Event()

    def launch(folder, cli_options=(), log_path=None, cmd="run", qos="utility"):
        proc = _FakeProc(Path(folder), cmd, lambda rec: None)
        proc.events = events
        if cmd == "stream":
            launched.set()
        return proc

    def sleep(seconds: float) -> None:
        assert launched.wait(5)
        raise OSError("disk full")

    def measure(pids, stop):
        stop.wait(5)
        return {}

    started = time.monotonic()
    with pytest.raises(OSError, match="disk full"):
        stream_bench.run([folder], tmp_path / "bench", speed=1000, user_name=USER, launch=launch,
                         measure=measure, sleep=sleep, kill=lambda pid: events.append(("kill", pid)))
    assert time.monotonic() - started < 2
    # Killed before anything waited on them, then reaped.
    assert events[:2] == [("kill", 101), ("kill", 102)]
    assert sorted(events[2:]) == [("wait", 101), ("wait", 102)]


def _launch_until(fail_from: int):
    """A launch whose children finish at once, failing from the
    ``fail_from``-th meeting on (counted from 1)."""
    meetings = []

    def launch(folder, cli_options=(), log_path=None, cmd="run", qos="utility"):
        if cmd == "live":
            meetings.append(Path(folder).parent.name)
        if len(meetings) >= fail_from:
            raise OSError("no such interpreter")
        return _FakeProc(Path(folder), cmd, lambda rec: None)

    launch.meetings = meetings
    return launch


@pytest.mark.parametrize("missing", ["system_wav", "mic_raw_wav", "system_segments", "transcript_json", "meta"])
def test_run_checks_every_source_before_the_first_replay(tmp_path: Path, missing: str):
    import shutil

    first = _meeting(tmp_path / "meetings")
    second = tmp_path / "meetings" / "2026-10-22T10-00-00"
    shutil.copytree(first, second)
    gone = getattr(RecordingPaths(second), missing)
    gone.unlink()
    launch = _launch_until(99)
    with pytest.raises(FileNotFoundError, match=gone.name):
        stream_bench.run([first, second], tmp_path / "bench", speed=1000, user_name=USER, launch=launch,
                         measure=lambda pids, stop: {}, sleep=lambda s: None)
    assert launch.meetings == []
    assert not (tmp_path / "bench" / first.name).exists()  # nothing replayed


def test_run_checks_the_audio_format_before_the_first_replay(tmp_path: Path):
    import shutil

    first = _meeting(tmp_path / "meetings")
    second = tmp_path / "meetings" / "2026-10-22T10-00-00"
    shutil.copytree(first, second)
    sf.write(str(RecordingPaths(second).system_wav), np.zeros((800, 2), np.int16), SR, subtype="PCM_16")
    launch = _launch_until(99)
    with pytest.raises(ValueError, match="system.wav: 16000 Hz, 2 channels"):
        stream_bench.run([first, second], tmp_path / "bench", speed=1000, user_name=USER, launch=launch,
                         measure=lambda pids, stop: {}, sleep=lambda s: None)
    assert launch.meetings == []


def test_run_writes_the_report_after_each_meeting(tmp_path: Path):
    import shutil

    first = _meeting(tmp_path / "meetings")
    second = tmp_path / "meetings" / "2026-10-22T10-00-00"
    shutil.copytree(first, second)
    launch = _launch_until(2)
    with pytest.raises(OSError, match="interpreter"):
        stream_bench.run([first, second], tmp_path / "bench", speed=1000, user_name=USER, launch=launch,
                         measure=lambda pids, stop: {}, sleep=lambda s: None, kill=lambda pid: None)
    assert launch.meetings == [first.name, second.name]
    report = (tmp_path / "bench" / "report.md").read_text()
    assert f"| {first.name} |" in report and second.name not in report
