"""Recording-folder path layout."""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


@dataclass(frozen=True)
class RecordingPaths:
    folder: Path

    @property
    def mic_wav(self) -> Path:
        return self.folder / "mic.wav"

    @property
    def mic_raw_wav(self) -> Path:
        return self.folder / "mic_raw.wav"

    @property
    def system_wav(self) -> Path:
        return self.folder / "system.wav"

    @property
    def meta(self) -> Path:
        return self.folder / "meta.json"

    @property
    def mic_segments(self) -> Path:
        return self.folder / "mic_segments.json"

    @property
    def system_segments(self) -> Path:
        return self.folder / "system_segments.json"

    @property
    def language(self) -> Path:
        """Whisper language detected on the system track, reused for the mic."""
        return self.folder / "language.txt"

    @property
    def speaker_embeddings(self) -> Path:
        """Voice embedding per diarization label (label → vector)."""
        return self.folder / "speaker_embeddings.json"

    @property
    def speakers_auto(self) -> Path:
        """Names recognized from the voice bank (label → name, similarity)."""
        return self.folder / "speakers_auto.json"

    @property
    def speakers(self) -> Path:
        """Names given to diarization labels by `rename` (label → name)."""
        return self.folder / "speakers.json"

    @property
    def live(self) -> Path:
        """What the live worker has so far, while recording (#30)."""
        return self.folder / "live.json"

    @property
    def stream(self) -> Path:
        """The realtime stream's sentences, drafts and questions (#42)."""
        return self.folder / "stream.json"

    @property
    def stream_pid(self) -> Path:
        return self.folder / "stream.pid"

    @property
    def speakers_ignored(self) -> Path:
        """Voices removed as noise: a few words, a split-off fragment."""
        return self.folder / "speakers_ignored.json"

    @property
    def speakers_inferred(self) -> Path:
        """Names inferred from the calendar and other meetings (#38)."""
        return self.folder / "speakers_inferred.json"

    @property
    def speakers_rejected(self) -> Path:
        """Names the user said a voice is not (label → names), #48."""
        return self.folder / "speakers_rejected.json"

    @property
    def speakers_unknown(self) -> Path:
        """Voices the user can't name ("Don't Know"): unnamed, but not asked about."""
        return self.folder / "speakers_unknown.json"

    @property
    def speakers_live(self) -> Path:
        """Names given while recording, with the voice they were given to."""
        return self.folder / "speakers_live.json"

    @property
    def title(self) -> Path:
        """The title the user gave the meeting, over the event's and the notes' (titles.py)."""
        return self.folder / "title.json"

    @property
    def imported(self) -> Path:
        """Where an imported meeting came from, and the names and voices that
        came with it (exchange.py, #58)."""
        return self.folder / "imported.json"

    @property
    def imported_voices(self) -> Path:
        """Voices that came with an import, waiting for the user's yes: apart
        from speaker_embeddings.json, so nothing recognizes or learns them
        before it (#58)."""
        return self.folder / "imported_voices.json"

    @property
    def cut_dismissed(self) -> Path:
        """The user said no to the suggested cut (#40)."""
        return self.folder / "cut_dismissed.json"

    @property
    def silence_dismissed(self) -> Path:
        """The user said no to removing the silence at the start or end."""
        return self.folder / "silence_dismissed.json"

    @property
    def local_only(self) -> Path:
        """The user keeps this meeting on this Mac: no cloud model, not shown through MCP (#53)."""
        return self.folder / "local_only.json"

    @property
    def transcription(self) -> Path:
        """Who transcribed each track: this Mac, the live worker or a cloud service (#54)."""
        return self.folder / "transcription.json"

    @property
    def cloud_pending(self) -> Path:
        """What a transcription service still keeps of this meeting, to delete (#54)."""
        return self.folder / "cloud-pending.json"

    @property
    def parts(self) -> Path:
        """Recordings that continue this one after a Palaver restart (#47)."""
        return self.folder / "parts.json"

    @property
    def review(self) -> Path:
        """When the user went through the finished meeting (#32)."""
        return self.folder / "review.json"

    @property
    def speakers_merged(self) -> Path:
        """Labels merged into another: one person the diarizer split (label → label)."""
        return self.folder / "speakers_merged.json"

    @property
    def speakers_shared(self) -> Path:
        """Voices that can't be told apart: the whole meeting, or lanes that
        are a room of several people (#56)."""
        return self.folder / "speakers_shared.json"

    @property
    def system_turns(self) -> Path:
        return self.folder / "system_turns.json"

    @property
    def transcript_json(self) -> Path:
        return self.folder / "transcript.json"

    @property
    def transcript_md(self) -> Path:
        return self.folder / "transcript.md"

    @property
    def notes(self) -> Path:
        """Summary, topics, next steps and decisions (notes.py)."""
        return self.folder / "notes.json"

    @property
    def my_notes(self) -> Path:
        """The user's own notes on the meeting (my_notes.py, #44)."""
        return self.folder / "my-notes.json"

    @property
    def my_notes_images(self) -> Path:
        """Images pasted into the user's notes, and the text read from them."""
        return self.folder / "my-notes"

    @property
    def calendar(self) -> Path:
        """The calendar event the recording belongs to (calendar_events.py)."""
        return self.folder / "calendar.json"

    @property
    def notion_info(self) -> Path:
        return self.folder / "notion.json"

    @property
    def audio_problems(self) -> Path:
        """The recorder's audio incidents as they happen (issue #50), folded
        into meta.json at the stop, or by crash recovery."""
        return self.folder / "audio_problems.json"

    @property
    def session_log(self) -> Path:
        return self.folder / "session.log"


_FOLDER_NAME = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2})(-\d+)?$")


def is_recording_folder_name(name: str) -> bool:
    """True for names ``new_recording_folder`` creates."""
    return _FOLDER_NAME.match(name) is not None


def recording_folder_timestamp(name: str) -> str | None:
    """The ``YYYY-MM-DDTHH-MM-SS`` part of a recording folder name."""
    match = _FOLDER_NAME.match(name)
    return match.group(1) if match else None


def new_recording_folder(root: Path, now: datetime) -> Path:
    """Create a fresh recording folder under `root`, named by timestamp.

    If a folder with the same timestamp already exists, appends `-2`, `-3`, …
    """
    root.mkdir(parents=True, exist_ok=True)
    base = now.strftime("%Y-%m-%dT%H-%M-%S")
    candidate = root / base
    suffix = 2
    while candidate.exists():
        candidate = root / f"{base}-{suffix}"
        suffix += 1
    candidate.mkdir()
    return candidate
