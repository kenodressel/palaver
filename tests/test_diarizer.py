"""Tests for pyannote diarizer wrapper."""

import os
from pathlib import Path

import pytest

from palaver.diarizer import PyannoteDiarizer
from palaver.models import SpeakerTurn


def test_diarizer_class_is_constructible():
    d = PyannoteDiarizer(
        repo="pyannote/speaker-diarization-community-1",
        hf_token="fake_for_construction",
    )
    assert d is not None


@pytest.mark.integration
def test_pyannote_smoke(tiny_wav: Path):
    token = os.environ.get("HF_TOKEN")
    if not token:
        pytest.skip("HF_TOKEN not set")
    d = PyannoteDiarizer(
        repo="pyannote/speaker-diarization-community-1",
        hf_token=token,
    )
    turns = d.diarize(tiny_wav)
    assert isinstance(turns, list)
    assert all(isinstance(t, SpeakerTurn) for t in turns)
    for t in turns:
        assert t.end > t.start


def test_diarize_passes_waveform_in_memory(tmp_path: Path):
    """pyannote 4.x decodes file paths via torchcodec, which needs FFmpeg
    dylibs at runtime. Our WAVs are always 16 kHz mono PCM, so they are
    loaded here and handed over as a waveform instead."""
    import numpy as np
    import soundfile as sf
    import torch

    wav = tmp_path / "system.wav"
    sf.write(str(wav), np.full(1_600, 0.25, dtype=np.float32), 16_000, subtype="PCM_16")

    class _Segment:
        start, end = 0.5, 1.5

    class _Annotation:
        def itertracks(self, yield_label):
            return [(_Segment(), None, "SPEAKER_00")]

    received = {}

    def _pipeline(file):
        received.update(file)
        return _Annotation()

    d = PyannoteDiarizer(repo="unused", hf_token="unused")
    d._pipeline = _pipeline

    turns = d.diarize(wav)

    assert turns == [SpeakerTurn(speaker="SPEAKER_00", start=0.5, end=1.5)]
    assert received["sample_rate"] == 16_000
    waveform = received["waveform"]
    assert isinstance(waveform, torch.Tensor)
    assert tuple(waveform.shape) == (1, 1_600)
    assert waveform.dtype == torch.float32
    assert abs(float(waveform.mean()) - 0.25) < 1e-3


def test_diarize_keeps_one_voice_embedding_per_speaker(tmp_path: Path):
    """pyannote 4.x returns a centroid embedding per speaker, ordered like
    speaker_diarization.labels(); they feed voice recognition (#13)."""
    import numpy as np
    import soundfile as sf

    wav = tmp_path / "system.wav"
    sf.write(str(wav), np.zeros(1_600, dtype=np.float32), 16_000, subtype="PCM_16")

    class _Segment:
        def __init__(self, start, end):
            self.start, self.end = start, end

    class _Annotation:
        def __init__(self, tracks):
            self._tracks = tracks

        def itertracks(self, yield_label):
            return [(_Segment(s, e), None, label) for s, e, label in self._tracks]

        def labels(self):
            return sorted({label for _, _, label in self._tracks})

    class _Output:
        speaker_diarization = _Annotation([(0, 1, "SPEAKER_01"), (1, 2, "SPEAKER_00")])
        exclusive_speaker_diarization = speaker_diarization
        speaker_embeddings = np.array([[1.0, 0.0], [0.0, 1.0]])

    d = PyannoteDiarizer(repo="unused", hf_token="unused")
    d._pipeline = lambda _file: _Output()

    d.diarize(wav)

    assert d.last_embeddings == {"SPEAKER_00": [1.0, 0.0], "SPEAKER_01": [0.0, 1.0]}


def test_a_track_that_holds_no_audio_has_no_speakers_and_needs_no_model(tmp_path: Path):
    """A system track the tap delivered nothing to is only its header;
    pyannote refuses an empty waveform."""
    from palaver.capture_recorder import _wav_header

    wav = tmp_path / "system.wav"
    wav.write_bytes(_wav_header(0))
    d = PyannoteDiarizer(repo="unused", hf_token=None)  # no token: loading the model would fail
    d.last_embeddings = {"SPEAKER_00": [1.0]}

    assert d.diarize(wav) == []
    assert d.last_embeddings == {}
