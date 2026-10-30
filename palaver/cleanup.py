"""Transcript cleanup filters applied between transcription and merge."""

from __future__ import annotations

import difflib
import re
from pathlib import Path

import numpy as np
import soundfile as sf

from .models import Segment, Word

# Loudest-100 ms-frame gates. Real speech on the AEC'd mic peaks at -23 dBFS
# or louder (1st percentile over two real meetings); Whisper's hallucinations
# over near-silence ("Thank you.", "Yeah.") peak at -37 dBFS or lower.
MIC_MIN_PEAK_DBFS = -35.0
# The system track only gets a near-silence gate: remote speakers' levels vary
# far more than the local mic.
SYSTEM_MIN_PEAK_DBFS = -50.0

_FRAME_SECONDS = 0.1

# Speaker echo that survives AEC, transcribed on the mic. Its words land at the
# same moment as on the system track (the acoustic path is ~30 ms); 95 % of
# them within 0.5 s in real meetings. The user repeating or answering remote
# words does so seconds later.
_ECHO_ALIGN_SECONDS = 0.5
_ECHO_MIN_SHARE = 0.5
# From three such words on, text alone decides; a "Genau." both sides say at
# once also needs AEC to have found echo there.
_ECHO_MIN_WORDS = 3
_ECHO_SHORT_REMOVED_DB = 3.0
# AEC took this much out of what the mic heard: it heard the speakers, not the
# user. The user's own speech comes through AEC at -4 ... +10 dB.
_ECHO_REMOVED_DB = 10.0
# Word timings of short segments run up to ~0.3 s early; measure around them.
_ECHO_PAD_BEFORE, _ECHO_PAD_AFTER, _ECHO_MIN_SECONDS = 0.3, 0.5, 0.5


def drop_silent_segments(
    segments: list[Segment], wav: Path, min_peak_dbfs: float
) -> list[Segment]:
    """Drop segments whose loudest 100 ms frame is below ``min_peak_dbfs``."""
    audio, sr = sf.read(str(wav), dtype="float32", always_2d=True)
    audio = audio.mean(axis=1)
    frame = max(1, int(_FRAME_SECONDS * sr))
    threshold = 10 ** (min_peak_dbfs / 20)
    kept = []
    for seg in segments:
        clip = audio[int(seg.start * sr) : int(seg.end * sr)]
        if clip.size == 0:
            continue
        n = max(1, clip.size // frame)
        frames = clip[: n * frame].reshape(n, -1) if clip.size >= frame else clip[None, :]
        if np.sqrt((frames**2).mean(axis=1)).max() >= threshold:
            kept.append(seg)
    return kept


def _bigrams(text: str) -> set[tuple[str, str]]:
    words = re.findall(r"\w+", text.lower())
    return set(zip(words, words[1:]))


def drop_bleed_duplicates(
    mic_segments: list[Segment],
    system_segments: list[Segment],
    *,
    window: float = 2.0,
    min_words: int = 3,
    min_overlap: float = 0.6,
) -> list[Segment]:
    """Drop mic segments that repeat remote speech from the same moment.

    Safety net behind AEC: speaker bleed that survives cancellation gets
    transcribed on the mic too. A mic segment (>= ``min_words`` words) is a
    duplicate when at least ``min_overlap`` of its word pairs occur in the
    remote speech within ``window`` seconds — all system segments in that
    window together, since the two transcriptions split sentences
    differently. Word pairs rather than single words, so a sentence of your
    own that merely shares "und" / "das" / "the" with nearby remote speech is
    kept. Short acknowledgements are never dropped.
    """
    kept = []
    for mic in mic_segments:
        pairs = _bigrams(mic.text)
        if len(pairs) < min_words - 1:
            kept.append(mic)
            continue
        nearby: set[tuple[str, str]] = set()
        for s in system_segments:
            if s.start <= mic.end + window and s.end >= mic.start - window:
                nearby |= _bigrams(s.text)
        if len(pairs & nearby) / len(pairs) < min_overlap:
            kept.append(mic)
    return kept


def _norm(word: str) -> str:
    return re.sub(r"\W", "", word.lower())


def _aligned_words(mic: Segment, remote: list[Word]) -> tuple[int, int]:
    """(words of ``mic``, how many of them are remote words said at the same moment)."""
    words = [w for w in mic.words if _norm(w.text)]
    near = [w for w in remote if w.end > mic.start - 3 and w.start < mic.end + 3]
    matcher = difflib.SequenceMatcher(
        None, [_norm(w.text) for w in words], [_norm(w.text) for w in near], autojunk=False
    )
    aligned = sum(
        1
        for block in matcher.get_matching_blocks()
        for k in range(block.size)
        if abs(words[block.a + k].start - near[block.b + k].start) < _ECHO_ALIGN_SECONDS
    )
    return len(words), aligned


def echoes_remote(mic: Segment, remote: list[Word]) -> bool:
    """Whether ``mic`` is remote speech heard through the speakers, by its words alone.

    At least half its words are remote words said at the same moment, and at
    least three of them.
    """
    words, aligned = _aligned_words(mic, remote)
    return bool(words) and aligned / words >= _ECHO_MIN_SHARE and aligned >= _ECHO_MIN_WORDS


def _aec_removed_db(raw: np.ndarray | None, out: np.ndarray, sr: int, seg: Segment) -> float:
    """How much quieter the AEC'd mic is than the raw mic around ``seg``."""
    if raw is None:
        return 0.0
    start = max(0, int((seg.start - _ECHO_PAD_BEFORE) * sr))
    end = max(int((seg.end + _ECHO_PAD_AFTER) * sr), start + int(_ECHO_MIN_SECONDS * sr))
    if min(len(raw), len(out)) <= start:
        return 0.0
    power = [np.mean(x[start:end].astype(np.float64) ** 2) + 1e-12 for x in (raw, out)]
    return float(10 * np.log10(power[0] / power[1]))


def drop_echo(
    mic_segments: list[Segment],
    system_segments: list[Segment],
    mic_wav: Path,
    mic_raw_wav: Path,
) -> list[Segment]:
    """Drop mic segments that are remote speech heard through the speakers.

    Remote speech is never the user's. Echo AEC leaves behind is quiet, and
    the transcriber garbles it, so ``drop_bleed_duplicates`` misses it. A mic
    segment is echo when AEC removed most of what the mic heard around it, or
    when at least half its words are remote words said at the same moment —
    three or more, or fewer where AEC found some echo too. Without
    ``mic_raw_wav`` only the words decide.
    """
    out, sr = sf.read(str(mic_wav), dtype="int16")
    raw = None
    if mic_raw_wav.exists():
        raw, raw_sr = sf.read(str(mic_raw_wav), dtype="int16")
        if raw_sr != sr:
            raw = None
    remote = [w for s in system_segments for w in s.words if _norm(w.text)]
    kept = []
    for seg in mic_segments:
        removed = _aec_removed_db(raw, out, sr, seg)
        words, aligned = _aligned_words(seg, remote)
        if removed < _ECHO_SHORT_REMOVED_DB:
            echo_text = echoes_remote(seg, remote)
        else:  # AEC found some echo too, so a few aligned words are enough
            echo_text = words and aligned / words >= _ECHO_MIN_SHARE
        if removed < _ECHO_REMOVED_DB and not echo_text:
            kept.append(seg)
    return kept
