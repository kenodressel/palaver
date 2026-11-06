"""Tests for the engine diarizer wrappers."""

from pathlib import Path

import pytest

from palaver.models import SpeakerTurn


def _wav(path: Path, seconds: float, rate: int = 16_000) -> Path:
    import numpy as np
    import soundfile as sf

    sf.write(str(path), np.zeros(int(seconds * rate), dtype="float32"), rate, subtype="PCM_16")
    return path


@pytest.fixture
def fake_engine(monkeypatch):
    from palaver.engine import Engine

    monkeypatch.delenv("FAKE_ENGINE_MODE", raising=False)
    monkeypatch.setenv("PALAVER_ENGINE", str(Path(__file__).parent / "fake_engine.py"))
    engine = Engine()
    yield engine
    engine.close()


def test_engine_diarizer_turns_and_embeddings(tmp_path: Path, fake_engine):
    from palaver.diarizer import EngineDiarizer

    d = EngineDiarizer(engine=fake_engine)
    turns = d.diarize(_wav(tmp_path / "s.wav", 4.0))
    assert turns == [SpeakerTurn(speaker="SPEAKER_00", start=0.0, end=2.0),
                     SpeakerTurn(speaker="SPEAKER_01", start=2.0, end=3.5)]
    assert set(d.last_embeddings) == {"SPEAKER_00", "SPEAKER_01"}
    assert len(d.last_embeddings["SPEAKER_00"]) == 256


def test_engine_diarizer_short_track_needs_no_engine(tmp_path: Path):
    from palaver.diarizer import EngineDiarizer

    class Boom:
        def call(self, *a, **k):
            raise AssertionError("engine must not be started")

    d = EngineDiarizer(engine=Boom())
    d.last_embeddings = {"SPEAKER_00": [0.0]}
    assert d.diarize(_wav(tmp_path / "s.wav", 0.01)) == []
    assert d.last_embeddings == {}


def _live(tmp_path: Path, engine):
    import numpy as np

    from palaver.diarizer import LiveEngineDiarizer

    reads = []

    def read(start, end):
        reads.append((start, end))
        return np.zeros(end - start, dtype="float32")

    return LiveEngineDiarizer(tmp_path, engine=engine), read, reads


def test_live_diarizer_runs_every_two_minutes(tmp_path: Path, fake_engine):
    live, read, reads = _live(tmp_path, fake_engine)
    sr = 16_000
    assert [live.advance(read, s * sr) for s in (60, 130, 140, 260)] == [0, 1, 0, 1]
    assert live.chunks_done == 2
    assert reads == [(0, 130 * sr), (0, 260 * sr)]
    assert len(live.provisional()) == 2 and set(live.last_embeddings) == {"SPEAKER_00", "SPEAKER_01"}


def test_live_diarizer_finish_uses_all_samples(tmp_path: Path, fake_engine):
    import numpy as np

    live, _, _ = _live(tmp_path, fake_engine)
    calls = []
    real = fake_engine.call
    fake_engine.call = lambda cmd, /, **kw: calls.append(real(cmd, **kw)) or calls[-1]
    samples = np.zeros(16_000 * 3 + 123, dtype="float32")
    assert len(live.finish(samples)) == 2
    assert calls[0]["frames"] == len(samples) and calls[0]["rate"] == 16_000


def test_live_scratch_file_removed(tmp_path: Path, fake_engine):
    import numpy as np

    live, read, _ = _live(tmp_path, fake_engine)
    live.advance(read, 130 * 16_000)
    assert not (tmp_path / ".live-diarize.wav").exists()
    live.finish(np.zeros(16_000 * 3, dtype="float32"))
    assert not (tmp_path / ".live-diarize.wav").exists()


def test_live_scratch_file_removed_when_engine_dies(tmp_path: Path, monkeypatch):
    import numpy as np

    from palaver.engine import Engine, EngineError

    monkeypatch.setenv("PALAVER_ENGINE", str(Path(__file__).parent / "fake_engine.py"))
    monkeypatch.setenv("FAKE_ENGINE_MODE", "diarize_crash")
    engine = Engine()
    live, _, _ = _live(tmp_path, engine)
    with pytest.raises(EngineError):
        live.finish(np.zeros(16_000 * 3, dtype="float32"))
    assert not (tmp_path / ".live-diarize.wav").exists()
    engine.close()


def test_live_diarizer_removes_a_scratch_a_killed_worker_left(tmp_path: Path):
    stale = tmp_path / ".live-diarize.wav"
    stale.write_bytes(b"\0" * 100)
    _live(tmp_path, object())
    assert not stale.exists()
