"""Tests for the sliding-window engine (a scripted transcribe, no model)."""

import numpy as np

from palaver.dictionary import Dictionary
from palaver.models import Word
from palaver.stream_engine import WindowEngine

SR = 16_000


def _audio(seconds: float) -> np.ndarray:
    return np.zeros(int(seconds * SR), dtype=np.float32)


def _scripted(*passes):
    """A transcribe that returns the next preset word list per call."""
    calls = iter(passes)
    return lambda audio: list(next(calls))


def _texts(words):
    return [w.text for w in words]


def test_words_settle_when_two_passes_agree():
    engine = WindowEngine(
        _scripted(
            [Word("Wann", 0.0, 0.3), Word("ist", 0.4, 0.6)],
            [Word("Wann", 0.0, 0.3), Word("ist", 0.4, 0.6), Word("der", 0.7, 0.9)],
        )
    )
    settled, draft = engine.add(_audio(1.0))
    assert settled == [] and _texts(draft) == ["Wann", "ist"]
    settled, draft = engine.add(_audio(1.0))
    assert _texts(settled) == ["Wann", "ist"]
    assert _texts(draft) == ["der"]


def test_words_settle_by_age_without_agreement():
    engine = WindowEngine(
        _scripted(
            [Word("Hallo", 0.0, 0.3)],
            [Word("Hello", 0.0, 0.3)],
        )
    )
    engine.add(_audio(1.0))
    settled, draft = engine.add(_audio(3.5))  # fed 4.5: the word ended > 3 s ago
    assert _texts(settled) == ["Hello"] and draft == []


def test_words_leaving_the_window_are_not_lost():
    truth = [(i * 0.5, i * 0.5 + 0.4) for i in range(28)]
    calls = {"n": 0}

    def transcribe(audio):
        # the audio is a ramp, so its first sample says where the window begins
        calls["n"] += 1
        begin = round(float(audio[0]) * 100, 2)
        end = begin + len(audio) / SR
        # the text changes every pass, so no two passes ever agree
        return [
            Word(f"w{i}-{calls['n']}", s - begin, e - begin)
            for i, (s, e) in enumerate(truth)
            if s >= begin - 0.01 and e <= end
        ]

    engine = WindowEngine(transcribe)
    ramp = (np.arange(15 * SR) / SR / 100).astype(np.float32)
    settled = []
    for step in range(15):
        got, _ = engine.add(ramp[step * SR : (step + 1) * SR])
        settled += got
    starts = [w.start for w in settled]
    assert len(starts) == len(set(starts))
    assert starts == [s for s, e in truth if e <= 15.0 - 3.0]


def test_times_are_from_the_track_start():
    seen = {"calls": 0}

    def transcribe(audio):
        seen["seconds"] = len(audio) / SR
        seen["calls"] += 1
        return [Word(f"spät{seen['calls']}", 8.0, 8.4)]  # never agrees

    engine = WindowEngine(transcribe)
    for _ in range(20):
        _, draft = engine.add(_audio(1.0))
    assert seen["seconds"] == 10.0  # only the last window is transcribed
    assert draft == [Word("spät20", 18.0, 18.4)]  # begin 10.0 + 8.0


def test_dictionary_applies_to_words():
    engine = WindowEngine(
        _scripted([Word("Tini", 0.0, 0.3)]),
        dictionary=Dictionary(replacements={"Tini": "Zini"}),
    )
    _, draft = engine.add(_audio(1.0))
    assert _texts(draft) == ["Zini"]


def test_flush_settles_the_draft():
    engine = WindowEngine(_scripted([Word("Ende", 0.0, 0.3)]))
    engine.add(_audio(1.0))
    assert _texts(engine.flush()) == ["Ende"]
    assert engine.flush() == []


def test_fed_audio_stays_bounded():
    engine = WindowEngine(lambda audio: [])
    for _ in range(60):
        engine.add(_audio(1.0))
    assert len(engine._audio) <= int(11.0 * SR)


def test_a_late_engine_reports_times_from_the_track_start():
    seen = {}

    def transcribe(audio):
        seen["seconds"] = len(audio) / SR
        return [Word("spät", 8.0, 8.4)]

    engine = WindowEngine(transcribe)
    engine.start_at(50.0)
    _, draft = engine.add(_audio(10.0))
    assert seen["seconds"] == 10.0
    assert draft == [Word("spät", 58.0, 58.4)]


def test_a_draft_settles_once_when_a_jump_passes_the_window():
    """The .part files stop growing in silence: when audio resumes, one add
    gets the whole gap and its window begins after the old draft."""
    truth = [("Was", 2.0, 2.3), ("kostet", 2.4, 2.8), ("das?", 2.9, 3.3), ("Gut", 28.0, 28.4)]

    def transcribe(audio):
        begin = round(float(audio[0]) * 100, 3)  # a ramp: the first sample says where the pass begins
        end = begin + len(audio) / SR
        return [Word(t, s - begin, e - begin) for t, s, e in truth if s >= begin - 0.01 and e <= end]

    engine = WindowEngine(transcribe)
    ramp = (np.arange(40 * SR) / SR / 100).astype(np.float32)
    settled, pos = [], 0
    for n in (SR, SR, SR, SR // 2):
        got, draft = engine.add(ramp[pos:pos + n])
        settled += got
        pos += n
    assert "das?" in _texts(draft)  # not settled yet
    got, _ = engine.add(ramp[pos:pos + 26 * SR])  # 25 s of silence and "Gut" in one go
    settled += got
    pos += 26 * SR
    for _ in range(5):
        got, _ = engine.add(ramp[pos:pos + SR])
        settled += got
        pos += SR
    assert _texts(settled).count("das?") == 1
    assert _texts(settled)[:3] == ["Was", "kostet", "das?"]
    assert [w.start for w in settled] == sorted(w.start for w in settled)


def test_load_engines_caps_the_mlx_cache(monkeypatch):
    import mlx.core as mx
    import parakeet_mlx

    from palaver import stream_engine

    limits = []
    monkeypatch.setattr(mx, "set_cache_limit", lambda n: limits.append(n) or 0)
    monkeypatch.setattr(parakeet_mlx, "from_pretrained", lambda repo: object())  # no model
    system, mic = stream_engine.load_engines("repo/parakeet", Dictionary())
    assert isinstance(system, WindowEngine) and isinstance(mic, WindowEngine)
    assert limits == [512 * 1024**2]


def test_how_long_a_word_waits_depends_on_how_sure_the_model_is():
    """Measured on recorded meetings: unsure words (below 0.85) differ from
    the final transcript 50–100 % of the time, so they wait for more
    context; sure ones (0.95 and up) settle sooner."""
    sure, unsure = Word("Budget", 0.0, 0.3, confidence=0.98), Word("Tini", 0.0, 0.3, confidence=0.6)
    for word, settles_after in ((sure, 2.5), (unsure, 6.5)):
        engine = WindowEngine(_scripted(*([[Word(word.text + str(i), 0.0, 0.3, confidence=word.confidence)]
                                            for i in range(20)])))
        engine.add(_audio(1.0))
        fed, settled = 1.0, []
        while not settled:
            settled, _ = engine.add(_audio(0.5))
            fed += 0.5
        assert fed == settles_after, word.text


def test_word_confidence_is_its_least_sure_piece():
    from types import SimpleNamespace as T

    from palaver.transcriber import _words_from_tokens

    [word] = _words_from_tokens([T(text=" Bud", start=0.0, end=0.2, confidence=0.99),
                                 T(text="get", start=0.2, end=0.4, confidence=0.7)])
    assert word.text == "Budget" and word.confidence == 0.7
    assert Word.from_dict(word.to_dict()) == word
    assert "confidence" not in Word("x", 0, 1).to_dict()  # none known: not stored
