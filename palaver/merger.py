"""Merge mic + diarized-system segments into a chronological utterance stream."""

from __future__ import annotations

from dataclasses import dataclass

from .models import UNSURE_CONFIDENCE, Segment, SpeakerTurn, Utterance, Word


def assign_speakers_to_words(
    system_segments: list[Segment],
    system_turns: list[SpeakerTurn],
) -> list[tuple[float, float, str, str]]:
    """Label every word with a speaker.

    Returns a flat list of (start, end, word_text, speaker).

    For each word, pick the turn with the largest overlap with the word
    interval. If no turn overlaps the word, fall back to the temporally
    nearest turn (earliest-starting on ties).
    """
    result: list[tuple[float, float, str, str]] = []
    for seg in system_segments:
        for w in seg.words:
            result.append(
                (w.start, w.end, w.text, _speaker_for_interval(w.start, w.end, system_turns))
            )
    return result


def _overlap(a_start: float, a_end: float, b_start: float, b_end: float) -> float:
    return max(0.0, min(a_end, b_end) - max(a_start, b_start))


def _distance_to_turn(point: float, turn: SpeakerTurn) -> float:
    if point < turn.start:
        return turn.start - point
    if point > turn.end:
        return point - turn.end
    return 0.0


def _speaker_for_interval(start: float, end: float, turns: list[SpeakerTurn]) -> str:
    if not turns:
        return "SPEAKER_00"
    best_overlap = 0.0
    best_turn: SpeakerTurn | None = None
    for t in turns:
        o = _overlap(start, end, t.start, t.end)
        # Tiebreak toward the earlier turn so results are deterministic
        # regardless of the input order of `turns`.
        if o > best_overlap or (
            o == best_overlap and best_turn is not None and t.start < best_turn.start
        ):
            best_overlap = o
            best_turn = t
    if best_turn is not None and best_overlap > 0.0:
        return best_turn.speaker
    # No overlap: choose the temporally nearest turn (ties → earlier start).
    nearest = min(
        turns,
        key=lambda t: (_distance_to_turn(start, t), t.start),
    )
    return nearest.speaker


@dataclass
class _Chunk:
    speaker: str
    start: float
    end: float
    words: list[Word]


def _unsure(words: list[Word]) -> tuple[str, ...]:
    return tuple(w.text for w in words if w.confidence is not None and w.confidence < UNSURE_CONFIDENCE)


def _system_segments_to_utterances(
    segments: list[Segment], turns: list[SpeakerTurn]
) -> list[Utterance]:
    utterances: list[Utterance] = []
    for seg in segments:
        if not seg.words:
            speaker = _speaker_for_interval(seg.start, seg.end, turns)
            utterances.append(Utterance(speaker, seg.start, seg.end, seg.text.strip()))
            continue
        chunks: list[_Chunk] = []
        for w in seg.words:
            speaker = _speaker_for_interval(w.start, w.end, turns)
            if chunks and chunks[-1].speaker == speaker:
                chunks[-1].end = w.end
                chunks[-1].words.append(w)
            else:
                chunks.append(_Chunk(speaker, w.start, w.end, [w]))
        for c in chunks:
            utterances.append(Utterance(c.speaker, c.start, c.end, " ".join(w.text for w in c.words).strip(),
                                        unsure=_unsure(c.words)))
    return utterances


def merge(
    mic_segments: list[Segment],
    system_segments: list[Segment],
    system_turns: list[SpeakerTurn],
) -> list[Utterance]:
    """Merge mic + system segments into one chronological utterance stream."""
    mic_utterances = [
        Utterance(s.speaker or "User", s.start, s.end, s.text.strip(), unsure=_unsure(s.words)) for s in mic_segments
    ]
    sys_utterances = _system_segments_to_utterances(system_segments, system_turns)
    combined = [u for u in mic_utterances + sys_utterances if u.text]
    combined.sort(key=lambda u: (u.start, u.end))
    return combined
