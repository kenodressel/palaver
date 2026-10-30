"""Tests for the transcript merger."""

from palaver.merger import assign_speakers_to_words, merge
from palaver.models import Segment, SpeakerTurn, Utterance, Word


def _seg(start, end, text, speaker=None, words=None) -> Segment:
    return Segment(start=start, end=end, text=text, speaker=speaker, words=words or [])


def test_assign_speakers_single_turn():
    seg = _seg(0.0, 2.0, "hallo welt", words=[Word("hallo", 0.1, 0.5), Word("welt", 1.5, 1.9)])
    turns = [SpeakerTurn("SPEAKER_00", 0.0, 2.0)]
    assigned = assign_speakers_to_words([seg], turns)
    assert all(w_speaker == "SPEAKER_00" for _, _, _, w_speaker in assigned)


def test_assign_speakers_split_between_turns():
    seg = _seg(
        0.0,
        4.0,
        "hallo das bist du",
        words=[
            Word("hallo", 0.0, 0.5),  # within SPEAKER_00
            Word("das", 1.0, 1.5),    # within SPEAKER_00
            Word("bist", 2.5, 3.0),   # within SPEAKER_01
            Word("du", 3.2, 3.8),     # within SPEAKER_01
        ],
    )
    turns = [
        SpeakerTurn("SPEAKER_00", 0.0, 2.0),
        SpeakerTurn("SPEAKER_01", 2.0, 4.0),
    ]
    assigned = assign_speakers_to_words([seg], turns)
    speakers = [a[3] for a in assigned]
    assert speakers == ["SPEAKER_00", "SPEAKER_00", "SPEAKER_01", "SPEAKER_01"]


def test_assign_speakers_word_outside_any_turn_falls_back_to_nearest():
    seg = _seg(
        0.0,
        5.0,
        "x y z",
        words=[Word("x", 0.5, 0.8), Word("y", 2.5, 2.8), Word("z", 4.5, 4.8)],
    )
    turns = [
        SpeakerTurn("SPEAKER_00", 0.0, 1.0),
        SpeakerTurn("SPEAKER_01", 4.0, 5.0),
    ]
    assigned = assign_speakers_to_words([seg], turns)
    speakers = [a[3] for a in assigned]
    # y at 2.5 is between the two turns; closer edge is SPEAKER_00 (ends 1.0, delta 1.5)
    # vs SPEAKER_01 (starts 4.0, delta 1.5) — tie broken toward earlier turn.
    assert speakers == ["SPEAKER_00", "SPEAKER_00", "SPEAKER_01"]


def test_merge_single_track_mic_only():
    mic = [_seg(0.0, 2.0, "hallo", speaker="Timo")]
    utterances = merge(mic_segments=mic, system_segments=[], system_turns=[])
    assert utterances == [Utterance("Timo", 0.0, 2.0, "hallo")]


def test_merge_interleaves_by_start_time():
    mic = [
        _seg(0.0, 1.0, "hi", speaker="Timo"),
        _seg(5.0, 6.0, "bye", speaker="Timo"),
    ]
    sys_seg = _seg(
        2.0,
        3.5,
        "hallo",
        words=[Word("hallo", 2.0, 3.5)],
    )
    turns = [SpeakerTurn("SPEAKER_00", 2.0, 3.5)]
    utterances = merge(mic, [sys_seg], turns)
    assert [u.start for u in utterances] == [0.0, 2.0, 5.0]
    assert [u.speaker for u in utterances] == ["Timo", "SPEAKER_00", "Timo"]


def test_merge_groups_consecutive_same_speaker_words_into_one_utterance():
    """If a system segment crosses a turn boundary, it splits into 2 utterances."""
    sys_seg = _seg(
        0.0,
        4.0,
        "a b c d",
        words=[
            Word("a", 0.0, 0.5),
            Word("b", 1.0, 1.5),
            Word("c", 2.5, 3.0),
            Word("d", 3.5, 3.9),
        ],
    )
    turns = [
        SpeakerTurn("SPEAKER_00", 0.0, 2.0),
        SpeakerTurn("SPEAKER_01", 2.0, 4.0),
    ]
    utterances = merge(mic_segments=[], system_segments=[sys_seg], system_turns=turns)
    assert len(utterances) == 2
    assert utterances[0].speaker == "SPEAKER_00"
    assert utterances[0].text == "a b"
    assert utterances[0].start == 0.0
    assert utterances[0].end == 1.5
    assert utterances[1].speaker == "SPEAKER_01"
    assert utterances[1].text == "c d"
    assert utterances[1].start == 2.5
    assert utterances[1].end == 3.9


def test_merge_empty_inputs():
    assert merge([], [], []) == []


def test_merge_system_segment_without_words_uses_segment_level_overlap():
    """Fallback: if whisper produced no word timings, assign speaker by segment overlap."""
    sys_seg = _seg(5.0, 10.0, "hallo welt")  # no words
    turns = [SpeakerTurn("SPEAKER_00", 4.0, 9.0), SpeakerTurn("SPEAKER_01", 9.0, 12.0)]
    utterances = merge([], [sys_seg], turns)
    assert len(utterances) == 1
    assert utterances[0].speaker == "SPEAKER_00"  # 4s overlap vs 1s
    assert utterances[0].text == "hallo welt"


def test_merge_drops_empty_text_utterances():
    """Whisper emits empty segments on silence; they must not become blank
    speaker lines in the transcript."""
    mic = [_seg(0.0, 1.0, "", speaker="Timo"), _seg(2.0, 3.0, "Yeah.", speaker="Timo")]
    sys_ = [_seg(1.0, 2.0, "  ")]
    out = merge(mic, sys_, [SpeakerTurn("SPEAKER_00", 0.0, 5.0)])
    assert [u.text for u in out] == ["Yeah."]


def test_utterances_keep_the_words_the_transcriber_was_unsure_of():
    from palaver.models import Segment, SpeakerTurn, Word

    mic = [Segment(0.0, 1.0, "Wir lösen Tini ab", words=[
        Word("Wir", 0.0, 0.2, 0.99), Word("lösen", 0.2, 0.5, 0.97), Word("Tini", 0.5, 0.7, 0.41), Word("ab", 0.7, 1.0, 0.9)])]
    system = [Segment(2.0, 3.0, "Mit Zini?", words=[Word("Mit", 2.0, 2.3, 0.95), Word("Zini?", 2.3, 3.0, 0.62)])]
    [mine, theirs] = merge(mic, system, [SpeakerTurn("SPEAKER_00", 2.0, 3.0)])
    assert mine.unsure == ("Tini",) and theirs.unsure == ("Zini?",)
    assert Utterance.from_dict(mine.to_dict()) == mine
    assert "unsure" not in Utterance("A", 0, 1, "sure").to_dict()
