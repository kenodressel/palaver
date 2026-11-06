"""Tests for Whisper transcriber wrapper.

Integration tests download and run a Whisper model (~80MB for tiny) — opt in with:
    uv run pytest -m integration
"""

from pathlib import Path

import pytest

from palaver.dictionary import Dictionary
from palaver.models import Segment
from palaver.transcriber import MlxWhisperTranscriber, Transcriber


def test_transcriber_is_callable_protocol():
    assert hasattr(Transcriber, "transcribe")


def test_mlx_transcriber_satisfies_protocol():
    t = MlxWhisperTranscriber(
        repo="any/repo", dictionary=Dictionary(), language="auto"
    )
    assert isinstance(t, Transcriber)


@pytest.mark.integration
def test_mlx_whisper_smoke(tiny_wav: Path):
    t = MlxWhisperTranscriber(
        repo="mlx-community/whisper-tiny",  # small for CI speed
        dictionary=Dictionary(),
        language="en",
    )
    segments = t.transcribe(tiny_wav)
    assert isinstance(segments, list)
    assert all(isinstance(s, Segment) for s in segments)
    # tiny.wav is 2s of tones; whisper may emit empty or a hallucination, both ok.
    for s in segments:
        assert s.end >= s.start
        assert s.end <= 3.0  # clip slightly longer than input tolerated


@pytest.mark.integration
def test_mlx_whisper_applies_dictionary_replacements(tiny_wav: Path):
    t = MlxWhisperTranscriber(
        repo="mlx-community/whisper-tiny",
        dictionary=Dictionary(replacements={"hello": "XYZZY"}),
        language="en",
    )
    segments = t.transcribe(tiny_wav)
    full_text = " ".join(s.text for s in segments).lower()
    assert "hello" not in full_text


class _FakeMlxWhisper:
    def __init__(self, language: str = "en"):
        self.calls: list[dict] = []
        self._language = language

    def transcribe(self, path, **kwargs):
        self.calls.append(kwargs)
        return {
            "language": kwargs.get("language") or self._language,
            "segments": [
                {
                    "start": 0.0,
                    "end": 1.0,
                    "text": " hello",
                    "words": [{"word": " hello", "start": 0.0, "end": 1.0}],
                }
            ],
        }


def _with_fake_whisper(monkeypatch, fake: _FakeMlxWhisper) -> None:
    import sys

    monkeypatch.setitem(sys.modules, "mlx_whisper", fake)


def _wav(path: Path) -> Path:
    import numpy as np
    import soundfile as sf

    sf.write(str(path), np.zeros(1_600, dtype=np.float32), 16_000, subtype="PCM_16")
    return path


def test_transcribe_suppresses_silence_hallucinations(monkeypatch, tmp_path: Path):
    """The AEC'd mic track is near-silent most of the time; Whisper's defaults
    hallucinate on that ("Gracias.", looping phrases)."""
    fake = _FakeMlxWhisper()
    _with_fake_whisper(monkeypatch, fake)
    t = MlxWhisperTranscriber(repo="r", dictionary=Dictionary(), language="auto")

    t.transcribe(_wav(tmp_path / "x.wav"))

    kwargs = fake.calls[0]
    assert kwargs["condition_on_previous_text"] is False
    assert kwargs["hallucination_silence_threshold"] == 2.0
    assert "language" not in kwargs


def test_transcribe_language_override_and_detection(monkeypatch, tmp_path: Path):
    fake = _FakeMlxWhisper(language="de")
    _with_fake_whisper(monkeypatch, fake)
    t = MlxWhisperTranscriber(repo="r", dictionary=Dictionary(), language="auto")

    t.transcribe(_wav(tmp_path / "system.wav"))
    assert t.last_language == "de"

    t.transcribe(_wav(tmp_path / "mic.wav"), language="en")
    assert fake.calls[-1]["language"] == "en"
    assert t.last_language == "en"


class _Tok:
    def __init__(self, text, start, end):
        self.text, self.start, self.end = text, start, end


def test_make_transcriber_routes_by_config():
    from palaver.transcriber import (
        EngineTranscriber,
        MlxWhisperTranscriber,
        make_transcriber,
    )

    whisper = make_transcriber("mlx-whisper", whisper_repo="w", dictionary=Dictionary(), language="auto")
    parakeet = make_transcriber("parakeet", whisper_repo="w", dictionary=Dictionary(), language="auto")
    assert isinstance(whisper, MlxWhisperTranscriber)
    assert isinstance(parakeet, EngineTranscriber)
    with pytest.raises(ValueError, match="unknown transcriber"):
        make_transcriber("nope", whisper_repo="w", dictionary=Dictionary(), language="auto")


def test_whisper_needs_no_ffmpeg(tmp_path: Path, monkeypatch):
    """mlx-whisper shells out to ffmpeg to decode paths; our WAVs are 16 kHz
    mono PCM, so they are decoded with soundfile instead."""
    import sys

    import numpy as np
    import soundfile as sf

    from palaver import transcriber

    wav = tmp_path / "x.wav"
    sf.write(str(wav), np.full(1_600, 0.25, dtype=np.float32), 16_000, subtype="PCM_16")
    monkeypatch.setenv("PATH", "")  # no ffmpeg anywhere

    seen = {}

    class _FakeWhisper:
        def transcribe(self, audio, **kw):
            seen["whisper"] = audio
            return {"segments": [], "language": "en"}

    monkeypatch.setitem(sys.modules, "mlx_whisper", _FakeWhisper())
    transcriber.MlxWhisperTranscriber(repo="r", dictionary=Dictionary()).transcribe(wav)
    assert isinstance(seen["whisper"], np.ndarray) and seen["whisper"].shape == (1_600,)


def _header_only(path: Path) -> Path:
    from palaver.capture_recorder import _wav_header

    path.write_bytes(_wav_header(0))  # what the recorder leaves when a track got nothing
    return path


def test_a_track_that_holds_no_audio_is_transcribed_as_nothing_without_a_model_call(monkeypatch, tmp_path: Path):
    """The system tap can deliver nothing for a whole call; a model refuses
    an empty track and the meeting got no transcript, though its mic was fine."""
    from palaver.transcriber import EngineTranscriber

    class _Refuses:
        def call(self, *args, **kwargs):
            raise AssertionError("no engine call for a header-only track")

    wav = _header_only(tmp_path / "system.wav")
    engine = EngineTranscriber(Dictionary(), engine=_Refuses())
    assert engine.transcribe(wav) == [] and engine.last_language is None

    fake = _FakeMlxWhisper(language="de")
    _with_fake_whisper(monkeypatch, fake)
    whisper = MlxWhisperTranscriber(repo="r", dictionary=Dictionary(), language="auto")
    whisper.last_language = "de"
    assert whisper.transcribe(wav) == [] and whisper.last_language is None
    assert fake.calls == []


@pytest.fixture
def fake_engine(monkeypatch):
    from palaver.engine import Engine

    monkeypatch.setenv("PALAVER_ENGINE", str(Path(__file__).parent / "fake_engine.py"))
    engine = Engine()
    yield engine
    engine.close()


def _secs_wav(path: Path, seconds: float) -> Path:
    import numpy as np
    import soundfile as sf

    sf.write(str(path), np.zeros(int(16_000 * seconds), dtype="float32"), 16_000, subtype="PCM_16")
    return path


def test_engine_transcriber_builds_segments(tmp_path: Path, fake_engine):
    from palaver.transcriber import EngineTranscriber

    t = EngineTranscriber(Dictionary(), engine=fake_engine)
    segs = t.transcribe(_secs_wav(tmp_path / "a.wav", 1.0), language="en")
    assert [(s.start, s.end, s.text, s.speaker) for s in segs] == [
        (0.0, 1.2, "The cloud is up.", None), (3.0, 3.5, "Yes.", None)]
    assert [(w.text, w.start, w.end, w.confidence) for w in segs[0].words] == [
        ("The", 0.0, 0.2, 0.99), ("cloud", 0.3, 0.6, 0.5), ("is", 0.7, 0.9, 0.97), ("up.", 0.9, 1.2, 0.92)]
    assert t.last_language is None
    assert isinstance(t, Transcriber)


def test_engine_transcriber_applies_dictionary(tmp_path: Path, fake_engine):
    from palaver.transcriber import EngineTranscriber

    t = EngineTranscriber(Dictionary(replacements={"cloud": "KLOUD"}), engine=fake_engine)
    [first, _] = t.transcribe(_secs_wav(tmp_path / "a.wav", 1.0))
    assert first.text == "The KLOUD is up."
    assert [w.text for w in first.words] == ["The", "KLOUD", "is", "up."]


def test_engine_transcriber_skips_empty_track(tmp_path: Path):
    from palaver.transcriber import EngineTranscriber

    class Boom:
        def call(self, *a, **k):
            raise AssertionError("no engine call for a header-only track")

    assert EngineTranscriber(Dictionary(), engine=Boom()).transcribe(_secs_wav(tmp_path / "e.wav", 0.0)) == []


def test_parakeet_mlx_config_maps_to_engine(tmp_path: Path, monkeypatch):
    from palaver import session_log
    from palaver.transcriber import EngineTranscriber, make_transcriber

    logged = []
    monkeypatch.setattr(session_log, "event", lambda name, **f: logged.append((name, f)))
    t = make_transcriber("parakeet-mlx", whisper_repo="w", dictionary=Dictionary(), language="auto")
    assert isinstance(t, EngineTranscriber)
    assert len(logged) == 1 and logged[0][0] == "transcriber_mapped"
    assert isinstance(make_transcriber("parakeet", whisper_repo="w", dictionary=Dictionary(), language="auto"),
                      EngineTranscriber)
