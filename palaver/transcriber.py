"""Transcription interface + mlx-whisper implementation."""

from __future__ import annotations

from contextlib import contextmanager
from pathlib import Path
from typing import Any, Protocol, runtime_checkable

from .dictionary import Dictionary
from .models import Segment, Word


@runtime_checkable
class Transcriber(Protocol):
    def transcribe(self, wav: Path, language: str | None = None) -> list[Segment]: ...


# Less audio than this holds no word; parakeet-mlx refuses under 10 ms.
MIN_AUDIO_SECONDS = 0.05


def holds_audio(wav: Path) -> bool:
    """Whether ``wav`` is worth a model call. A system track can be a bare
    header: the tap delivered nothing for a whole call, or nothing played.
    A file that can't be read is left to the model to complain about."""
    import soundfile as sf

    try:
        info = sf.info(str(wav))
    except Exception:
        return True
    return info.frames >= MIN_AUDIO_SECONDS * info.samplerate


class MlxWhisperTranscriber:
    """Whisper on Apple Silicon GPU via MLX.

    Word-level timestamps via DTW. Applies dictionary replacements on the
    transcribed text (but not on the initial_prompt, which is passed directly
    to Whisper).

    Decoding is tuned against silence hallucinations: the AEC'd mic track is
    near-silent whenever the user isn't talking, and Whisper's defaults fill
    that with phantom phrases ("Gracias.", looping words) carried forward by
    previous-text conditioning.
    """

    HALLUCINATION_SILENCE_THRESHOLD = 2.0

    def __init__(
        self,
        repo: str,
        dictionary: Dictionary,
        language: str = "auto",
    ):
        self._repo = repo
        self._dictionary = dictionary
        self._language = None if language == "auto" else language
        # Language Whisper used for the most recent transcribe() call.
        self.last_language: str | None = None

    def transcribe(self, wav: Path, language: str | None = None) -> list[Segment]:
        """Transcribe ``wav``. ``language`` overrides the configured one."""
        if not holds_audio(wav):
            self.last_language = None
            return []
        import mlx_whisper

        kwargs: dict[str, Any] = {
            "path_or_hf_repo": self._repo,
            "word_timestamps": True,
            "condition_on_previous_text": False,
            "hallucination_silence_threshold": self.HALLUCINATION_SILENCE_THRESHOLD,
        }
        language = language or self._language
        if language is not None:
            kwargs["language"] = language
        if self._dictionary.initial_prompt:
            kwargs["initial_prompt"] = self._dictionary.initial_prompt

        result = mlx_whisper.transcribe(read_mono(wav, 16_000), **kwargs)
        self.last_language = result.get("language")

        segments: list[Segment] = []
        for raw in result.get("segments", []):
            words = [
                Word(
                    text=self._dictionary.apply(w["word"]).strip(),
                    start=float(w["start"]),
                    end=float(w["end"]),
                )
                for w in raw.get("words", [])
            ]
            segments.append(
                Segment(
                    start=float(raw["start"]),
                    end=float(raw["end"]),
                    text=self._dictionary.apply(raw["text"]).strip(),
                    speaker=None,
                    words=words,
                )
            )
        return segments


DEFAULT_PARAKEET_REPO = "mlx-community/parakeet-tdt-0.6b-v3"


class ParakeetMlxTranscriber:
    """NVIDIA Parakeet-TDT v3 on Apple Silicon via parakeet-mlx (default
    backend). No initial_prompt support — dictionary replacements still apply.

    ~5x faster than Whisper large-v3-turbo on a 24-min meeting and produced
    no text over silence. Multilingual with automatic language handling, so
    ``language`` is ignored and ``last_language`` stays None. Sentences are
    split at 1 s pauses and capped at 15 s — unsplit, they ran for minutes.
    """

    # Parakeet picks the language per chunk. With 120 s chunks a German
    # meeting full of English terms flipped into (wrong) English and lost
    # passages; 15 s chunks — dictation-sized, like sabbel's — kept it German
    # (79 % → 91 % of segments, on par with Whisper's 92 %) and recovered 9 %
    # more words on an English meeting, at about the same speed.
    CHUNK_SECONDS = 15.0
    OVERLAP_SECONDS = CHUNK_SECONDS / 4

    def __init__(self, repo: str, dictionary: Dictionary, model: Any = None):
        self._repo = repo
        self._dictionary = dictionary
        self._model = model
        self.last_language: str | None = None

    def transcribe(self, wav: Path, language: str | None = None) -> list[Segment]:
        if not holds_audio(wav):
            return []
        from parakeet_mlx import DecodingConfig, SentenceConfig

        if self._model is None:
            from parakeet_mlx import from_pretrained

            self._model = from_pretrained(self._repo)
        with _parakeet_reads_with_soundfile():
            result = self._model.transcribe(
                str(wav),
                decoding_config=DecodingConfig(
                    sentence=SentenceConfig(silence_gap=1.0, max_duration=15.0)
                ),
                chunk_duration=self.CHUNK_SECONDS,
                overlap_duration=self.OVERLAP_SECONDS,
            )
        segments: list[Segment] = []
        for sentence in result.sentences:
            words = _words_from_tokens(sentence.tokens)
            if not words:
                continue
            if segments and not any(ch.isalnum() for ch in sentence.text):
                # Orphaned punctuation split off at a pause: attach it to the
                # previous segment instead of making a timestamped segment.
                prev = segments[-1]
                prev.text += sentence.text.strip()
                if prev.words:
                    last = prev.words[-1]
                    prev.words[-1] = Word(last.text + sentence.text.strip(), last.start, last.end, last.confidence)
                continue
            segments.append(
                Segment(
                    start=float(sentence.start),
                    end=float(sentence.end),
                    text=self._dictionary.apply(sentence.text).strip(),
                    speaker=None,
                    words=[
                        Word(text=self._dictionary.apply(w.text), start=w.start, end=w.end, confidence=w.confidence)
                        for w in words
                    ],
                )
            )
        return segments


def _words_from_tokens(tokens) -> list[Word]:
    """Join SentencePiece tokens into words: a leading space starts a word,
    anything else (word pieces, punctuation) extends the previous one. A
    word is as sure as its least sure piece."""
    words: list[Word] = []
    for tok in tokens:
        confidence = getattr(tok, "confidence", None)
        confidence = None if confidence is None else round(float(confidence), 3)
        if tok.text.startswith(" ") or not words:
            if tok.text.strip():
                words.append(Word(text=tok.text.strip(), start=float(tok.start), end=float(tok.end),
                                  confidence=confidence))
        else:
            last = words[-1]
            least = (confidence if last.confidence is None else last.confidence if confidence is None
                     else min(last.confidence, confidence))
            words[-1] = Word(text=last.text + tok.text, start=last.start, end=float(tok.end), confidence=least)
    return words


def make_transcriber(
    name: str,
    *,
    whisper_repo: str,
    dictionary: Dictionary,
    language: str,
    parakeet_repo: str = DEFAULT_PARAKEET_REPO,
):
    """The ``[model].transcriber`` backend: "parakeet-mlx" (default) or "mlx-whisper"."""
    if name == "mlx-whisper":
        return MlxWhisperTranscriber(repo=whisper_repo, dictionary=dictionary, language=language)
    if name == "parakeet-mlx":
        return ParakeetMlxTranscriber(repo=parakeet_repo, dictionary=dictionary)
    raise ValueError(f'unknown transcriber "{name}" (use "mlx-whisper" or "parakeet-mlx")')


def read_mono(wav: Path, sample_rate: int):
    """Decode a WAV to float32 mono at ``sample_rate`` without ffmpeg.

    Both mlx-whisper and parakeet-mlx shell out to ffmpeg to decode file
    paths; our recordings are plain PCM WAVs, so soundfile suffices.
    """
    import numpy as np
    import soundfile as sf
    import soxr

    samples, sr = sf.read(str(wav), dtype="float32", always_2d=True)
    mono = samples.mean(axis=1).astype(np.float32)
    if sr != sample_rate:
        mono = soxr.resample(mono, sr, sample_rate).astype(np.float32)
    return mono


@contextmanager
def _parakeet_reads_with_soundfile():
    """Swap parakeet-mlx's ffmpeg-based ``load_audio`` for ``read_mono``
    while one transcription runs."""
    import mlx.core as mx
    import parakeet_mlx.parakeet as parakeet

    original = parakeet.load_audio

    def load_audio(filename, sampling_rate, dtype=mx.bfloat16):
        # Like the original: float32 regardless of ``dtype`` — the STFT in
        # get_logmel breaks on bfloat16 input.
        return mx.array(read_mono(Path(filename), sampling_rate), dtype=mx.float32)

    parakeet.load_audio = load_audio
    try:
        yield
    finally:
        parakeet.load_audio = original
