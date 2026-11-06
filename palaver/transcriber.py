"""Transcription interface + mlx-whisper implementation."""

from __future__ import annotations

from pathlib import Path
from typing import Any, Protocol, runtime_checkable

from .dictionary import Dictionary
from .models import Segment, Word


@runtime_checkable
class Transcriber(Protocol):
    def transcribe(self, wav: Path, language: str | None = None) -> list[Segment]: ...


# Less audio than this holds no word; the engine refuses under 10 ms.
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


class EngineTranscriber:
    """Parakeet TDT v3 through palaver-engine (the Swift speech engine). The
    engine splits sentences (pauses of 1 s, at most 15 s) and joins pieces
    into words; this maps its answer to Segments and applies the dictionary.
    Like Parakeet always did: ``language`` is ignored, ``last_language`` is None.
    """

    def __init__(self, dictionary: Dictionary, engine: Any = None):
        self._dictionary = dictionary
        self._engine = engine
        self.last_language: str | None = None

    def transcribe(self, wav: Path, language: str | None = None) -> list[Segment]:
        if not holds_audio(wav):
            return []
        if self._engine is None:
            from .engine import Engine

            self._engine = Engine()
        reply = self._engine.call("transcribe", wav=str(wav))
        apply = self._dictionary.apply
        return [
            Segment(
                start=float(raw["start"]),
                end=float(raw["end"]),
                text=apply(raw["text"]).strip(),
                speaker=None,
                words=[
                    Word(text=apply(w["text"]), start=float(w["start"]), end=float(w["end"]),
                         confidence=w.get("confidence"))
                    for w in raw.get("words", [])
                ],
            )
            for raw in reply.get("segments", [])
        ]


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
):
    """The ``[model].transcriber`` backend: "parakeet" (default, the Swift
    engine), "parakeet-mlx" (the old name, now the same) or "mlx-whisper"."""
    if name == "mlx-whisper":
        return MlxWhisperTranscriber(repo=whisper_repo, dictionary=dictionary, language=language)
    if name == "parakeet-mlx":
        from . import session_log

        session_log.event("transcriber_mapped", configured="parakeet-mlx", used="parakeet")
        name = "parakeet"
    if name == "parakeet":
        return EngineTranscriber(dictionary)
    raise ValueError(f'unknown transcriber "{name}" (use "parakeet" or "mlx-whisper")')


def read_mono(wav: Path, sample_rate: int):
    """Decode a WAV to float32 mono at ``sample_rate`` without ffmpeg.

    mlx-whisper shells out to ffmpeg to decode file
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
