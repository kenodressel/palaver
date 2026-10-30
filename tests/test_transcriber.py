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


class _Sent:
    def __init__(self, tokens):
        self.tokens = tokens
        self.text = "".join(t.text for t in tokens)
        self.start, self.end = tokens[0].start, tokens[-1].end


class _FakeParakeetModel:
    def __init__(self):
        self.calls = []

    def transcribe(self, path, **kwargs):
        self.calls.append(kwargs)

        class _Result:
            sentences = [
                _Sent([_Tok(" Hel", 0.0, 0.2), _Tok("lo", 0.2, 0.4), _Tok(" kay", 0.5, 0.7),
                       _Tok(" pee", 0.7, 0.8), _Tok(" eye", 0.8, 1.0), _Tok(".", 1.0, 1.05)]),
            ]

        return _Result()


def test_parakeet_builds_words_from_subword_tokens(tmp_path: Path):
    pytest.importorskip("parakeet_mlx")
    from palaver.transcriber import ParakeetMlxTranscriber

    model = _FakeParakeetModel()
    t = ParakeetMlxTranscriber(
        repo="r", dictionary=Dictionary(replacements={"kay pee eye": "KPI"}), model=model
    )
    segments = t.transcribe(tmp_path / "x.wav", language="en")

    assert len(segments) == 1
    seg = segments[0]
    assert seg.text == "Hello KPI."
    assert [(w.text, w.start, w.end) for w in seg.words] == [
        ("Hello", 0.0, 0.4), ("kay", 0.5, 0.7), ("pee", 0.7, 0.8), ("eye.", 0.8, 1.05)
    ]
    assert (seg.start, seg.end) == (0.0, 1.05)
    assert t.last_language is None  # Parakeet does not report a language
    sentence = model.calls[0]["decoding_config"].sentence
    assert sentence.max_duration == 15.0 and sentence.silence_gap == 1.0
    # Short chunks keep the language decision local (see CHUNK_SECONDS).
    assert model.calls[0]["chunk_duration"] == 15.0
    assert model.calls[0]["overlap_duration"] == 3.75


def test_make_transcriber_routes_by_config():
    from palaver.transcriber import (
        MlxWhisperTranscriber,
        ParakeetMlxTranscriber,
        make_transcriber,
    )

    whisper = make_transcriber("mlx-whisper", whisper_repo="w", dictionary=Dictionary(), language="auto")
    parakeet = make_transcriber("parakeet-mlx", whisper_repo="w", dictionary=Dictionary(), language="auto")
    assert isinstance(whisper, MlxWhisperTranscriber)
    assert isinstance(parakeet, ParakeetMlxTranscriber)
    with pytest.raises(ValueError, match="unknown transcriber"):
        make_transcriber("nope", whisper_repo="w", dictionary=Dictionary(), language="auto")


def test_parakeet_attaches_orphaned_punctuation_to_previous_segment(tmp_path: Path):
    """Splitting at pauses can leave the closing period as its own sentence."""
    pytest.importorskip("parakeet_mlx")
    from palaver.transcriber import ParakeetMlxTranscriber

    class _Model:
        def transcribe(self, path, **kwargs):
            class _R:
                sentences = [
                    _Sent([_Tok(" We", 0.0, 0.2), _Tok(" agree", 0.2, 0.6)]),
                    _Sent([_Tok(".", 2.0, 2.1)]),
                    _Sent([_Tok(" Next", 3.0, 3.4)]),
                ]
            return _R()

    segs = ParakeetMlxTranscriber(repo="r", dictionary=Dictionary(), model=_Model()).transcribe(
        tmp_path / "x.wav"
    )
    assert [(s.text, s.end) for s in segs] == [("We agree.", 0.6), ("Next", 3.4)]
    assert segs[0].words[-1].text == "agree."


def test_neither_backend_needs_ffmpeg(tmp_path: Path, monkeypatch):
    """Both libraries shell out to ffmpeg to decode paths; our WAVs are 16 kHz
    mono PCM, so they are decoded with soundfile instead."""
    pytest.importorskip("parakeet_mlx")
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

    import parakeet_mlx.parakeet as pk

    class _Model:
        def transcribe(self, path, **kw):
            seen["parakeet"] = pk.load_audio(path, 16_000, kw.get("dtype"))
            return type("R", (), {"sentences": []})()

    transcriber.ParakeetMlxTranscriber(repo="r", dictionary=Dictionary(), model=_Model()).transcribe(wav)
    assert seen["parakeet"].shape == (1_600,)
    import mlx.core as mx

    assert seen["parakeet"].dtype == mx.float32  # what get_logmel needs
    assert abs(float(seen["parakeet"].mean()) - 0.25) < 1e-2


def _header_only(path: Path) -> Path:
    from palaver.capture_recorder import _wav_header

    path.write_bytes(_wav_header(0))  # what the recorder leaves when a track got nothing
    return path


def test_a_track_that_holds_no_audio_is_transcribed_as_nothing_without_a_model_call(monkeypatch, tmp_path: Path):
    """The system tap can deliver nothing for a whole call; parakeet-mlx
    then raised "Audio must contain at least 160 decoded samples" and the
    meeting got no transcript, though its mic was fine."""
    pytest.importorskip("parakeet_mlx")
    from palaver.transcriber import ParakeetMlxTranscriber

    class _Refuses:
        def transcribe(self, path, **kwargs):
            raise ValueError("Audio must contain at least 160 decoded samples; got 0")

    wav = _header_only(tmp_path / "system.wav")
    parakeet = ParakeetMlxTranscriber(repo="r", dictionary=Dictionary(), model=_Refuses())
    assert parakeet.transcribe(wav) == [] and parakeet.last_language is None

    fake = _FakeMlxWhisper(language="de")
    _with_fake_whisper(monkeypatch, fake)
    whisper = MlxWhisperTranscriber(repo="r", dictionary=Dictionary(), language="auto")
    whisper.last_language = "de"
    assert whisper.transcribe(wav) == [] and whisper.last_language is None
    assert fake.calls == []
