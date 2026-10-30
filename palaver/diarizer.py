"""Speaker diarization via pyannote.audio on MPS."""

from __future__ import annotations

from pathlib import Path
from typing import Callable

import numpy as np

from .models import SpeakerTurn
from .transcriber import MIN_AUDIO_SECONDS

# The live worker's pyannote batches (windows, and voices per batch). With
# pyannote's 32, catching up on a backlog took 3–4 GB of GPU memory on top of
# the models; with 8, ~1 GB more, at about the same speed (#49).
LIVE_BATCH_SIZE = 8


class PyannoteDiarizer:
    def __init__(self, repo: str, hf_token: str | None):
        self._repo = repo
        self._hf_token = hf_token
        self._pipeline = None
        # Voice embedding per speaker label from the last diarize() call.
        self.last_embeddings: dict[str, list[float]] = {}

    def _ensure_pipeline(self):
        if self._pipeline is not None:
            return
        import warnings

        import torch

        with warnings.catch_warnings():
            # We pass waveforms in memory (see diarize), so pyannote's
            # torchcodec decoder is never used; its import-time warning
            # dumps one traceback per FFmpeg version it failed to load.
            warnings.filterwarnings("ignore", message=r"\s*torchcodec is not installed")
            from pyannote.audio import Pipeline

        if not self._hf_token:
            raise RuntimeError(
                "HF token required for pyannote gated models. "
                "Set HF_TOKEN env or [hf].token in config."
            )
        pipeline = Pipeline.from_pretrained(self._repo, token=self._hf_token)
        device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
        pipeline.to(device)
        self._pipeline = pipeline

    def diarize(self, wav: Path) -> list[SpeakerTurn]:
        # Pass the waveform in memory: pyannote 4.x decodes file paths via
        # torchcodec, which fails at runtime without matching FFmpeg dylibs.
        import soundfile as sf
        import torch

        samples, sample_rate = sf.read(str(wav), dtype="float32", always_2d=True)
        if len(samples) < MIN_AUDIO_SECONDS * sample_rate:
            self.last_embeddings = {}  # a track that got nothing: pyannote refuses it
            return []
        self._ensure_pipeline()
        waveform = torch.from_numpy(samples.T.copy())
        output = self._pipeline({"waveform": waveform, "sample_rate": sample_rate})
        return self._turns(output)

    def _turns(self, output) -> list[SpeakerTurn]:
        # pyannote 4.x returns a DiarizeOutput with two Annotations.
        # `exclusive_speaker_diarization` has no overlapping turns, which our
        # merger expects (the merger assigns each word to exactly one speaker
        # based on max overlap — ambiguous with overlapping turns).
        # Fall back to the non-exclusive variant for older API shapes.
        annotation = getattr(output, "exclusive_speaker_diarization", None) or getattr(
            output, "speaker_diarization", output
        )
        self.last_embeddings = {}
        embeddings = getattr(output, "speaker_embeddings", None)
        full = getattr(output, "speaker_diarization", None)
        if embeddings is not None and full is not None:
            # Rows follow speaker_diarization.labels() order.
            for label, row in zip(full.labels(), embeddings):
                self.last_embeddings[str(label)] = [float(v) for v in row]
        turns: list[SpeakerTurn] = []
        for segment, _, speaker in annotation.itertracks(yield_label=True):
            turns.append(
                SpeakerTurn(
                    speaker=str(speaker),
                    start=float(segment.start),
                    end=float(segment.end),
                )
            )
        turns.sort(key=lambda t: t.start)
        return turns


class IncrementalDiarizer:
    """pyannote diarization computed while the recording grows.

    pyannote slides a 10 s window in 1 s steps; per window it runs the
    segmentation model and one voice embedding per local speaker (~95 % of
    the work), then clusters all embeddings at once. Windows are
    independent, so ``advance`` computes them as audio arrives and
    ``finish`` adds the last few and clusters — the same windows, the same
    clustering, the same result as diarizing the finished file, in seconds
    instead of minutes.
    """

    def __init__(self, diarizer: PyannoteDiarizer, sample_rate: int = 16_000):
        self._diarizer = diarizer
        self._sr = sample_rate
        self._segmentations: list = []  # (chunks, frames, speakers) blocks
        self._embeddings: list = []  # (chunks, speakers, dim) blocks
        self._sliding_window = None
        self.chunks_done = 0

    @property
    def last_embeddings(self) -> dict[str, list[float]]:
        return self._diarizer.last_embeddings

    def _pipeline(self):
        self._diarizer._ensure_pipeline()
        pipeline = self._diarizer._pipeline
        pipeline.segmentation_batch_size = pipeline.embedding_batch_size = LIVE_BATCH_SIZE
        return pipeline

    def _geometry(self) -> tuple[int, int]:
        """(window, step) in samples."""
        inference = self._pipeline()._segmentation
        return round(inference.duration * self._sr), round(inference.step * self._sr)

    def advance(self, read: Callable[[int, int], np.ndarray], available: int, max_chunks: int = 120) -> int:
        """Compute the windows that fit in the first ``available`` samples;
        ``read(start, end)`` returns float32 mono samples. Returns how many
        windows were added."""
        window, step = self._geometry()
        complete = (available - window) // step + 1 if available >= window else 0
        count = min(complete - self.chunks_done, max_chunks)
        if count <= 0:
            return 0
        start = self.chunks_done * step
        # Exactly `count` full windows, so pyannote adds no padded last one.
        self._compute(read(start, start + (count - 1) * step + window))
        self.chunks_done += count
        return count

    def finish(self, samples: np.ndarray) -> list[SpeakerTurn]:
        """Diarize the finished recording (all of it, as float32 mono),
        reusing the windows computed so far."""
        if len(samples) < MIN_AUDIO_SECONDS * self._sr:
            # The tap delivered nothing: what was clustered live came from
            # zero-filled reads, and pyannote refuses an empty waveform.
            self._diarizer.last_embeddings = {}
            return []
        window, step = self._geometry()
        # The system track is finalized to its own length — shorter than
        # what was zero-filled live if it ended in silence. Keep only windows
        # the finished file has too, then compute the rest (with pyannote's
        # padded last window) from the file itself.
        n = len(samples)
        complete = (n - window) // step + 1 if n >= window else 0
        keep = min(complete, self.chunks_done)
        self._truncate(keep)
        # pyannote pads a last window when the file does not end on the
        # step grid; computing from `keep` reproduces exactly that.
        if keep < complete or n < window or (n - window) % step:
            self._compute(samples[keep * step:])
        return self._cluster()

    def provisional(self) -> list[SpeakerTurn]:
        """Speaker turns of the windows computed so far, clustered now — for
        showing a meeting while it is recorded. Labels may differ from one
        call to the next; ``last_embeddings`` hold each label's voice."""
        if not self.chunks_done:
            return []
        return self._cluster()

    def _cluster(self) -> list[SpeakerTurn]:
        """Cluster the computed windows into speakers. pyannote reads audio
        only to compute windows and voices, which are given here, so a second
        of silence stands in for the recording: a copy of it per live
        snapshot (every few seconds) left macOS holding GBs of freed copies
        (#49)."""
        import torch
        from pyannote.core import SlidingWindow, SlidingWindowFeature

        pipeline = self._pipeline()
        segmentations = SlidingWindowFeature(
            np.concatenate(self._segmentations),
            SlidingWindow(start=0.0, duration=self._sliding_window.duration, step=self._sliding_window.step),
        )
        embeddings = np.concatenate(self._embeddings)
        pipeline.get_segmentations = lambda file, hook=None: segmentations
        pipeline.get_embeddings = lambda *args, **kwargs: embeddings
        try:
            output = pipeline({"waveform": torch.zeros(1, self._sr), "sample_rate": self._sr})
        finally:
            del pipeline.get_segmentations, pipeline.get_embeddings
            _release_gpu_cache()
        return self._diarizer._turns(output)

    def _compute(self, samples: np.ndarray) -> None:
        import torch

        pipeline = self._pipeline()
        file = {"waveform": torch.from_numpy(samples[None].copy()), "sample_rate": self._sr, "uri": "live"}
        segmentations = pipeline.get_segmentations(file)
        if pipeline._segmentation.model.specifications.powerset:
            binarized = segmentations
        else:
            from pyannote.audio.utils.signal import binarize

            binarized = binarize(segmentations, onset=pipeline.segmentation.threshold, initial_state=False)
        embeddings = pipeline.get_embeddings(file, binarized, exclude_overlap=pipeline.embedding_exclude_overlap)
        self._sliding_window = segmentations.sliding_window
        self._segmentations.append(segmentations.data)
        self._embeddings.append(embeddings)
        _release_gpu_cache()

    def _truncate(self, chunks: int) -> None:
        if chunks >= self.chunks_done:
            return
        seg = np.concatenate(self._segmentations)[:chunks] if self._segmentations else None
        emb = np.concatenate(self._embeddings)[:chunks] if self._embeddings else None
        self._segmentations = [seg] if seg is not None else []
        self._embeddings = [emb] if emb is not None else []
        self.chunks_done = chunks


def _release_gpu_cache() -> None:
    """Give back what PyTorch keeps cached on the GPU between calls: in a
    meeting-long live worker it grew to ~6 GB while ~30 MB were in use."""
    import torch

    if torch.backends.mps.is_available():
        torch.mps.empty_cache()
