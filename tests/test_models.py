"""Tests for domain data models."""

from palaver.models import (
    Segment,
    SpeakerTurn,
    Utterance,
    Word,
)


def test_word_roundtrip():
    w = Word(text="hallo", start=1.0, end=1.5)
    assert Word.from_dict(w.to_dict()) == w


def test_segment_with_words_roundtrip():
    s = Segment(
        start=0.0,
        end=2.0,
        text="hallo welt",
        speaker="Timo",
        words=[
            Word("hallo", 0.1, 0.5),
            Word("welt", 0.6, 1.9),
        ],
    )
    assert Segment.from_dict(s.to_dict()) == s


def test_segment_without_words():
    s = Segment(start=0.0, end=2.0, text="hallo welt", speaker=None, words=[])
    assert Segment.from_dict(s.to_dict()) == s


def test_speaker_turn_roundtrip():
    t = SpeakerTurn(speaker="SPEAKER_01", start=3.0, end=5.5)
    assert SpeakerTurn.from_dict(t.to_dict()) == t


def test_utterance_roundtrip():
    u = Utterance(speaker="Timo", start=0.0, end=2.0, text="hallo welt")
    assert Utterance.from_dict(u.to_dict()) == u


def test_segment_speaker_is_mutable():
    # The merger/CLI assigns speaker to mic segments post-transcription.
    # Segment must stay non-frozen for this pattern to work.
    s = Segment(start=0.0, end=1.0, text="hi", speaker=None, words=[])
    s.speaker = "Timo"
    assert s.speaker == "Timo"
