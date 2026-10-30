"""Tests for processing a recording while it is being made (no models)."""

import json
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest
import soundfile as sf

from palaver.capture_recorder import _wav_header
from palaver.diarizer import IncrementalDiarizer
from palaver.live import GrowingTrack, LiveProcessor, quietest_cut, run_live
from palaver.models import Segment, SpeakerTurn, Word
from palaver.paths import RecordingPaths

SR = 16_000


def _append(path: Path, samples: np.ndarray) -> None:
    """What the recorder does: placeholder header, then appended samples."""
    if not path.exists():
        path.write_bytes(_wav_header(0))
    with open(path, "ab") as fh:
        fh.write(samples.astype(np.int16).tobytes())


def _finalize(final: Path) -> None:
    part = Path(str(final) + ".part")
    data = part.read_bytes()[44:]
    final.write_bytes(_wav_header(len(data)) + data)
    part.unlink()


def test_growing_track_reads_part_then_final_and_pads_with_silence(tmp_path: Path):
    final = tmp_path / "system.wav"
    track = GrowingTrack(final)
    assert track.available() == 0
    _append(Path(str(final) + ".part"), np.arange(1, 101))
    assert track.available() == 100
    assert list(track.read(98, 103)) == [99, 100, 0, 0, 0]
    _finalize(final)
    assert track.available() == 100 and track.read(0, 3).tolist() == [1, 2, 3]


def test_quietest_cut_lands_in_the_pause():
    audio = np.full(10 * SR, 3000, dtype=np.int16)
    audio[7 * SR : 7 * SR + 4000] = 0
    cut = quietest_cut(audio, 5 * SR, 10 * SR)
    assert 7 * SR <= cut < 7 * SR + 4000


class _FakeTranscriber:
    """One segment per non-silent block, at the block's first loud sample."""

    last_language = None

    def __init__(self):
        self.blocks = []

    def transcribe(self, wav, language=None):
        audio, _ = sf.read(str(wav), dtype="int16")
        self.blocks.append(len(audio) / SR)
        loud = np.flatnonzero(np.abs(audio) > 1000)
        if not len(loud):
            return []
        t = loud[0] / SR
        return [Segment(t, t + 1, "hallo", None, [Word("hallo", t, t + 1)])]


class _FakeDiarizer:
    def __init__(self):
        self.available = []
        self.last_embeddings = {"SPEAKER_00": [1.0, 0.0]}
        self.finished_with = None

    def advance(self, read, available, max_chunks=120):
        self.available.append(available)
        return 0

    def provisional(self):
        return [SpeakerTurn("SPEAKER_00", 0.0, self.available[-1] / SR)] if self.available else []

    def finish(self, samples):
        self.finished_with = len(samples)
        return [SpeakerTurn("SPEAKER_00", 0.0, len(samples) / SR)]


class _IdentityAec:
    def process(self, mic, sysaudio):
        return mic.copy()


def _speech(seconds: float, *, pause_at: list[float] = ()) -> np.ndarray:
    audio = np.full(int(seconds * SR), 5000, dtype=np.int16)
    for t in pause_at:
        audio[int(t * SR) : int((t + 1) * SR)] = 0
    return audio


def test_live_processing_matches_the_files_process_writes(tmp_path: Path):
    paths = RecordingPaths(tmp_path)
    transcriber, diarizer = _FakeTranscriber(), _FakeDiarizer()
    proc = LiveProcessor(paths, transcriber=transcriber, diarizer=diarizer, user_name="Timo",
                         aec_factory=_IdentityAec)
    mic_part, sys_part = (Path(str(p) + ".part") for p in (paths.mic_raw_wav, paths.system_wav))

    # 100 s recorded so far, a pause at 65 s: one block is transcribed, cut there.
    mic = _speech(100, pause_at=[65])
    _append(mic_part, mic)
    _append(sys_part, _speech(100, pause_at=[65]))
    while proc.step():
        pass
    assert transcriber.blocks == [pytest.approx(65.5, abs=0.6)] * 2
    assert diarizer.available[-1] == 97 * SR  # 3 s margin
    assert not paths.mic_wav.exists()  # still recording

    # What the window shows meanwhile: the text so far, provisional speakers.
    assert proc.snapshot() and not proc.snapshot()  # nothing new the second time
    live = json.loads(paths.live.read_text())
    assert live["until"] == pytest.approx(65.5, abs=0.6)
    assert [s["text"] for s in live["system"]] == ["hallo"] and live["mic"][0]["speaker"] == "Timo"
    assert live["turns"] == [{"speaker": "SPEAKER_00", "start": 0.0, "end": 97.0}]
    assert live["embeddings"] == {"SPEAKER_00": [1.0, 0.0]}

    # Recording continues; system goes quiet (the tap delivers nothing), stops.
    more = _speech(40)
    _append(mic_part, more)
    _finalize(paths.mic_raw_wav)
    _finalize(paths.system_wav)
    paths.meta.write_text("{}")
    assert run_live(proc, paths, sleep=lambda s: None)

    assert diarizer.finished_with == 100 * SR
    mic_out, _ = sf.read(str(paths.mic_wav), dtype="int16")
    assert np.array_equal(mic_out, np.concatenate([mic, more]))
    mic_segments = [Segment.from_dict(d) for d in json.loads(paths.mic_segments.read_text())]
    assert {s.speaker for s in mic_segments} == {"Timo"}
    assert [round(s.start) for s in mic_segments] == [0, 66, 125]  # absolute times
    assert json.loads(paths.system_turns.read_text())[0]["speaker"] == "SPEAKER_00"
    assert json.loads(paths.speaker_embeddings.read_text()) == {"SPEAKER_00": [1.0, 0.0]}
    assert len(json.loads(paths.system_segments.read_text())) == 2
    assert not paths.live.exists()  # the final files replace it


def test_live_gives_up_when_the_recorder_dies(tmp_path: Path):
    paths = RecordingPaths(tmp_path)
    proc = LiveProcessor(paths, transcriber=_FakeTranscriber(), diarizer=_FakeDiarizer(),
                         user_name="Timo", aec_factory=_IdentityAec)
    _append(Path(str(paths.mic_raw_wav) + ".part"), _speech(10))
    clock = [0.0]

    def _sleep(s):
        clock[0] += s

    assert not run_live(proc, paths, clock=lambda: clock[0], sleep=_sleep)
    assert not paths.mic_wav.exists() and not Path(str(paths.mic_wav) + ".part").exists()


class _FakePipeline:
    """pyannote's chunking (Inference.slide): full windows every step, plus a
    zero-padded last one when the audio does not end on the grid. Each
    window's "segmentation" is its sum, so any misalignment shows."""

    W, S = 10 * 100, 1 * 100  # 10 s windows, 1 s steps at 100 Hz

    def __init__(self):
        self._segmentation = SimpleNamespace(
            duration=10.0, step=1.0, model=SimpleNamespace(specifications=SimpleNamespace(powerset=True))
        )
        self.embedding_exclude_overlap = True

    def get_segmentations(self, file, hook=None):
        x = file["waveform"][0].numpy()
        if not len(x):  # as pyannote's validate_file
            raise ValueError("'waveform' must be provided as a (channel, time) torch Tensor.")
        chunks = [x[i : i + self.W] for i in range(0, len(x) - self.W + 1, self.S)] if len(x) >= self.W else []
        if len(x) < self.W or (len(x) - self.W) % self.S:
            last = x[len(chunks) * self.S :]
            chunks.append(np.pad(last, (0, self.W - len(last))))
        data = np.array([[[c.sum()]] for c in chunks])
        return SimpleNamespace(data=data, sliding_window=SimpleNamespace(duration=10.0, step=1.0))

    def get_embeddings(self, file, binarized, exclude_overlap=False, hook=None):
        return binarized.data[:, :, :1] * 2

    def __call__(self, file):
        seg = self.get_segmentations(file)
        return seg.data, self.get_embeddings(file, seg)


def _incremental_diarizer(sample_rate: int = 100) -> IncrementalDiarizer:
    diarizer = SimpleNamespace(_pipeline=_FakePipeline(), _ensure_pipeline=lambda: None, _turns=lambda out: out,
                               last_embeddings={})
    return IncrementalDiarizer(diarizer, sample_rate=sample_rate)


def _incremental(samples: np.ndarray, steps: list[int]):
    inc = _incremental_diarizer()
    pipeline = inc._diarizer._pipeline
    def read(a, b):  # zero-filled past the end, like GrowingTrack
        out = np.zeros(b - a, dtype=np.float32)
        chunk = samples[a:b]
        out[: len(chunk)] = chunk
        return out

    for available in steps:
        inc.advance(read, available)
    return inc.finish(samples), pipeline(_file(samples))


def _file(samples):
    import torch

    return {"waveform": torch.from_numpy(samples[None].copy())}


@pytest.mark.parametrize("seconds", [5.0, 10.0, 25.0, 25.37, 61.0])
@pytest.mark.parametrize("steps", [[], [1500], [1200, 1300, 2400, 9000]])
def test_incremental_diarization_uses_the_same_windows_as_the_whole_file(seconds, steps):
    samples = np.random.default_rng(1).standard_normal(int(seconds * 100)).astype(np.float32)
    # Live, the track may have read longer (zero-filled) than it ended up.
    (seg, emb), (full_seg, full_emb) = _incremental(samples, steps)
    assert seg.shape == full_seg.shape
    np.testing.assert_allclose(seg, full_seg, rtol=1e-5)
    np.testing.assert_allclose(emb, full_emb, rtol=1e-5)


def test_clustering_the_windows_so_far_reads_no_audio():
    """A snapshot every few seconds copied the whole recording so far; macOS
    kept the freed copies, and a meeting's live worker grew past its budget
    in half an hour (#49). Clustering needs only the computed windows."""
    samples = np.random.default_rng(1).standard_normal(3000).astype(np.float32)
    clustered = []

    class _Recording(_FakePipeline):
        def __call__(self, file):
            clustered.append(file["waveform"].shape[-1])
            return super().__call__(file)

    pipeline = _Recording()
    diarizer = SimpleNamespace(_pipeline=pipeline, _ensure_pipeline=lambda: None, _turns=lambda out: out,
                               last_embeddings={})
    inc = IncrementalDiarizer(diarizer, sample_rate=100)
    reads = []

    def read(a, b):
        reads.append((a, b))
        return samples[a:b]

    inc.advance(read, len(samples))
    reads.clear()
    seg, emb = inc.provisional()
    assert reads == [] and clustered == [100]  # one second of silence stands in
    assert seg.shape[0] == emb.shape[0] == inc.chunks_done


def test_the_live_diarizer_computes_in_small_batches():
    """pyannote's batches of 32 windows took 3–4 GB of GPU memory on top of
    the models whenever the worker caught up (#49); batches of 8 take ~1."""
    pipeline = _FakePipeline()
    pipeline.embedding_batch_size = pipeline.segmentation_batch_size = 32
    diarizer = SimpleNamespace(_pipeline=pipeline, _ensure_pipeline=lambda: None, _turns=lambda out: out,
                               last_embeddings={})
    inc = IncrementalDiarizer(diarizer, sample_rate=100)
    inc.advance(lambda a, b: np.zeros(b - a, np.float32), 1500)
    assert pipeline.embedding_batch_size == pipeline.segmentation_batch_size == 8


def test_a_system_track_that_got_nothing_has_no_speakers():
    """Live, the empty system track was read zero-filled up to the mic's
    length; finished, it holds nothing, which pyannote refuses."""
    inc = _incremental_diarizer()
    inc._diarizer.last_embeddings = {"SPEAKER_00": [1.0]}  # clustered from the zero-filled windows
    inc.advance(lambda a, b: np.zeros(b - a, dtype=np.float32), 3000)
    assert inc.finish(np.zeros(0, dtype=np.float32)) == []
    assert inc.last_embeddings == {}


def test_live_finishes_a_meeting_whose_system_track_got_nothing(tmp_path: Path):
    """The tap delivered nothing for a whole Slack call: the live worker
    must still write the mic's transcript, with no remote speakers."""
    paths = RecordingPaths(tmp_path)
    transcriber = _FakeTranscriber()
    proc = LiveProcessor(paths, transcriber=transcriber, diarizer=_incremental_diarizer(SR), user_name="Timo",
                         aec_factory=_IdentityAec)
    mic = _speech(20)
    _append(Path(str(paths.mic_raw_wav) + ".part"), mic)
    _finalize(paths.mic_raw_wav)
    paths.system_wav.write_bytes(_wav_header(0))
    paths.meta.write_text("{}")

    assert run_live(proc, paths, sleep=lambda s: None)

    assert transcriber.blocks == [20.0]  # the mic only
    assert [s["speaker"] for s in json.loads(paths.mic_segments.read_text())] == ["Timo"]
    assert json.loads(paths.system_segments.read_text()) == []
    assert json.loads(paths.system_turns.read_text()) == []
    assert json.loads(paths.speaker_embeddings.read_text()) == {}
    mic_out, _ = sf.read(str(paths.mic_wav), dtype="int16")
    assert np.array_equal(mic_out, mic)


# --- a worker that is gone is not "running" (review of #47) ---------------------


def test_a_stale_pid_file_is_no_running_worker_and_is_removed(tmp_path):
    import subprocess

    from palaver import live

    done = subprocess.Popen(["true"])
    done.wait()
    live.pid_path(tmp_path).write_text(str(done.pid))  # exited and reaped: nobody has this pid now
    assert not live.worker_running(tmp_path)
    assert not live.pid_path(tmp_path).exists()


def test_an_exited_child_worker_is_reaped_not_counted(tmp_path):
    import os
    import subprocess
    import time

    from palaver import live

    child = subprocess.Popen(["true"])
    time.sleep(0.3)  # exited, not waited for: a zombie, and os.kill(pid, 0) still succeeds
    live.pid_path(tmp_path).write_text(str(child.pid))
    os.kill(child.pid, 0)
    assert not live.worker_running(tmp_path)
    child.returncode = 0  # reaped above; keep Popen from waiting on it


def test_a_pid_now_used_by_another_program_is_no_worker(tmp_path):
    import os

    from palaver import live

    live.pid_path(tmp_path).write_text(str(os.getppid()))  # alive, but not `palaver live <this folder>`
    assert not live.worker_running(tmp_path)


def test_a_live_worker_for_this_folder_is_running(tmp_path):
    import subprocess
    import sys

    from palaver import live

    worker = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", "palaver", "live", str(tmp_path)])
    try:
        live.pid_path(tmp_path).write_text(str(worker.pid))
        assert live.worker_running(tmp_path)
    finally:
        worker.kill()
        worker.wait()


def test_a_worker_for_a_folder_with_a_similar_name_is_not_this_ones(tmp_path):
    import subprocess
    import sys

    from palaver import live

    mine, other = tmp_path / "2026-10-29T12-06-10", tmp_path / "2026-10-29T12-06-10-2"
    mine.mkdir(), other.mkdir()
    worker = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", "palaver", "live", str(other)])
    try:
        live.pid_path(mine).write_text(str(worker.pid))
        assert not live.worker_running(mine)
    finally:
        worker.kill()
        worker.wait()
