"""End-to-end: recording folder → process → sync, with fake models and a
mocked Notion HTTP session (issue #6).

Real WAVs, real cleanup filters, merge, rendering and on-disk JSON between
stages — so a field rename in one stage fails here instead of on hardware.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import soundfile as sf

from palaver import cli
from palaver.models import Segment, SpeakerTurn, Word
from palaver.paths import RecordingPaths

from .test_cli import _fake_models, _ns

SR = 16_000


def _track(seconds: float, loud: list[tuple[float, float]]) -> np.ndarray:
    # Noise floor around -60 dBFS, like an AEC'd mic between utterances.
    x = np.random.default_rng(0).normal(0, 0.001, int(seconds * SR)).astype(np.float32)
    for start, end in loud:
        t = np.arange(int(start * SR), int(end * SR))
        x[t] = 0.3 * np.sin(2 * np.pi * 220 * t / SR)
    return x


def _seg(start, end, text, words=None) -> Segment:
    return Segment(start=start, end=end, text=text, speaker=None, words=words or [])


def _words(start: float, text: str, step: float = 0.4) -> list[Word]:
    return [
        Word(text=w, start=start + i * step, end=start + (i + 1) * step)
        for i, w in enumerate(text.split())
    ]


SEGMENTS = {
    "mic.wav": [
        _seg(0.5, 2.0, "Let's start the review."),
        # Speaker bleed the AEC let through: repeats the remote sentence.
        _seg(3.0, 5.0, "the numbers look good this quarter"),
        # Whisper hallucination over silence.
        _seg(6.0, 6.5, "Thank you."),
    ],
    "system.wav": [
        _seg(3.0, 5.4, "The numbers look good this quarter.",
             _words(3.0, "The numbers look good this quarter.")),
        _seg(7.0, 8.2, "Agreed, ship it.", _words(7.0, "Agreed, ship it.")),
    ],
}
TURNS = [SpeakerTurn("SPEAKER_00", 2.8, 5.6), SpeakerTurn("SPEAKER_01", 6.8, 8.6)]


class _FakeResponse:
    def __init__(self, body):
        self.status_code = 200
        self._body = body
        self.headers = {}
        self.text = json.dumps(body)

    def json(self):
        return self._body


class _FakeSession:
    def __init__(self):
        self.posts: list[dict] = []
        self.patches: list[dict] = []

    def post(self, url, *, headers, timeout, json):
        self.posts.append(json)
        return _FakeResponse({"id": "page-1", "url": "https://notion.so/page-1"})

    def patch(self, url, *, headers, timeout, json):
        self.patches.append(json)
        return _FakeResponse({})


def test_process_then_sync_end_to_end(tmp_path: Path, monkeypatch):
    folder = tmp_path / "2026-10-20T14-35-17"
    folder.mkdir()
    paths = RecordingPaths(folder)
    sf.write(str(paths.mic_wav), _track(10, [(0.5, 2.0), (3.0, 5.0)]), SR, subtype="PCM_16")
    sf.write(str(paths.system_wav), _track(10, [(3.0, 5.4), (7.0, 8.2)]), SR, subtype="PCM_16")
    paths.meta.write_text(json.dumps({
        "start_time": "2026-10-20T14:35:17+02:00",
        "end_time": "2026-10-20T14:35:27+02:00",
        "duration_seconds": 10.0,
    }))
    _fake_models(monkeypatch, segments_for=lambda name: SEGMENTS[name], turns=TURNS)
    session = _FakeSession()
    monkeypatch.setattr("palaver.notion_client.requests.Session", lambda: session)

    assert cli._cmd_process(_ns(folder)) == 0
    assert cli._cmd_sync(_ns(folder)) == 0

    transcript = json.loads(paths.transcript_json.read_text())
    assert [(u["speaker"], u["text"]) for u in transcript] == [
        ("Timo", "Let's start the review."),
        ("SPEAKER_00", "The numbers look good this quarter."),
        ("SPEAKER_01", "Agreed, ship it."),
    ]

    md = paths.transcript_md.read_text()
    title = "2026-10-20 14:35 — Meeting (0 min, 3 speakers)"
    assert md.splitlines()[0] == f"# {title}"
    assert "**Timo** [14:35:17]  Let's start the review." in md
    assert "Thank you." not in md

    assert json.loads(paths.notion_info.read_text())["page_url"] == "https://notion.so/page-1"
    page = session.posts[0]
    assert page["parent"] == {"page_id": "parent"}
    assert page["properties"]["title"]["title"][0]["text"]["content"] == title
    rendered = [
        "".join(part["text"]["content"] for part in b["paragraph"]["rich_text"])
        for b in page["children"]
    ]
    assert rendered == [
        "Timo [14:35:17]  Let's start the review.",
        "SPEAKER_00 [14:35:20]  The numbers look good this quarter.",
        "SPEAKER_01 [14:35:24]  Agreed, ship it.",
    ]

    events = [json.loads(line).get("event") for line in paths.session_log.read_text().splitlines()]
    assert events[0] == "process_start"
    assert {"transcribe_done", "diarize_done", "merge_done", "process_done",
            "notion_upload_done"} <= set(events)


def test_a_call_whose_system_track_got_nothing_is_transcribed_from_the_mic(tmp_path: Path, monkeypatch):
    """The tap delivered nothing for a 6-minute Slack call: system.wav was a
    bare header, and a model's "Audio must contain at least 160 decoded
    samples" cost the whole transcript though the mic was fine."""
    from palaver.capture_recorder import _wav_header

    folder = tmp_path / "2026-10-30T12-46-50"
    folder.mkdir()
    paths = RecordingPaths(folder)
    sf.write(str(paths.mic_raw_wav), _track(10, [(0.5, 2.0)]), SR, subtype="PCM_16")
    paths.system_wav.write_bytes(_wav_header(0))
    paths.meta.write_text(json.dumps({
        "start_time": "2026-10-30T12:46:50+01:00",
        "end_time": "2026-10-30T12:47:00+01:00",
        "duration_seconds": 10.0,
    }))

    def _segments(name):
        if sf.info(str(folder / name)).frames < 160:  # as a model does
            raise ValueError(f"Audio must contain at least 160 decoded samples; got 0 from {name}")
        return [_seg(0.5, 2.0, "Let's start the review.")]

    _fake_models(monkeypatch, segments_for=_segments)

    class _Diarizer:
        last_embeddings: dict = {}

        def __init__(self, **_):
            pass

        def diarize(self, wav):
            if not sf.info(str(wav)).frames:
                raise ValueError("a model refuses an empty waveform")
            return []

    monkeypatch.setattr("palaver.diarizer.EngineDiarizer", _Diarizer)

    assert cli._cmd_process(_ns(folder)) == 0

    transcript = json.loads(paths.transcript_json.read_text())
    assert [(u["speaker"], u["text"]) for u in transcript] == [("Timo", "Let's start the review.")]
    assert json.loads(paths.system_segments.read_text()) == []
    assert json.loads(paths.system_turns.read_text()) == []
    mic, _ = sf.read(str(paths.mic_wav), dtype="int16")
    raw, _ = sf.read(str(paths.mic_raw_wav), dtype="int16")
    np.testing.assert_array_equal(mic, raw)  # no reference: nothing to cancel
    logged = [json.loads(line) for line in paths.session_log.read_text().splitlines()]
    assert any(e.get("event") == "system_track_empty" for e in logged)
