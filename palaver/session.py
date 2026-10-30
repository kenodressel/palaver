"""One recording from start to stop — shared by `record` and the daemon."""

from __future__ import annotations

import json
import sys
from contextlib import ExitStack
from datetime import datetime
from pathlib import Path
from typing import Callable

import soundfile as sf

from . import usage
from .paths import RecordingPaths, new_recording_folder
from .session_log import event, session_log


def _default_capture(paths: RecordingPaths):
    from .capture_recorder import CaptureRecorder

    return CaptureRecorder(mic_raw_path=paths.mic_raw_wav, system_path=paths.system_wav,
                           problems_path=paths.audio_problems)


class RecordingSession:
    """Creates the recording folder, captures until ``stop()``, writes
    meta.json, and keeps session.log attached for the whole recording."""

    def __init__(
        self,
        output_dir: Path,
        *,
        trigger: str = "manual",
        capture_factory: Callable[[RecordingPaths], object] = _default_capture,
        log: bool = True,
    ):
        self._output_dir = output_dir
        self._trigger = trigger
        self._capture_factory = capture_factory
        self._log = log  # False: no session.log (the setup assistant's test recording)
        self._stack: ExitStack | None = None
        self._recorder = None
        self.capture = None
        self.paths: RecordingPaths | None = None
        self.recording = False

    @property
    def system_source(self) -> str | None:
        return getattr(self.capture, "system_source", None)

    @property
    def mic_source(self) -> str | None:
        return getattr(self.capture, "mic_source", None)

    @property
    def mic_device(self) -> str | None:
        return getattr(self.capture, "mic_device", None)

    @property
    def mic_rate(self) -> float | None:
        """The microphone's own rate, before resampling to 16 kHz."""
        return getattr(self.capture, "mic_rate", None)

    @property
    def system_rate(self) -> float | None:
        return getattr(self.capture, "system_rate", None)

    @property
    def system_device(self) -> str | None:
        """The output system audio is recorded from, e.g. "AirPods Pro"."""
        return getattr(self.capture, "system_device", None)

    @property
    def problems(self) -> list[dict]:
        """Audio incidents so far (issue #50), see ``audio_health``."""
        return list(getattr(self.capture, "problems", []))

    @property
    def hints(self) -> list[dict]:
        """Soft hints about the audio now, e.g. a muted mic."""
        return list(getattr(self.capture, "hints", []))

    @property
    def missing(self) -> list[str]:
        """Tracks no source could record ("microphone", "system audio")."""
        return list(getattr(self.capture, "missing", []))

    def start(self) -> Path:
        from .recorder import Recorder

        folder = new_recording_folder(self._output_dir, datetime.now())
        self.paths = RecordingPaths(folder)
        self.capture = self._capture_factory(self.paths)
        self._recorder = Recorder(capture=self.capture, paths=self.paths)
        stack = ExitStack()
        if self._log:
            stack.enter_context(session_log(self.paths.session_log))
        try:
            self._recorder.start()
        except BaseException:
            stack.__exit__(*sys.exc_info())
            raise
        self._stack = stack
        self.recording = True
        event(
            "record_start",
            system_source=self.system_source,
            mic_source=self.mic_source,
            missing=self.missing,
            trigger=self._trigger,
        )
        usage.record("recording_start", trigger=self._trigger, system_source=self.system_source,
                     mic_source=self.mic_source, missing=self.missing)
        return folder

    def stop(self, reason: str | None = None) -> float:
        """Finalize the WAVs and meta.json; returns the duration in seconds.
        ``reason``: why it stopped (lifecycle.STOP_REASONS, "call_ended"),
        kept in meta.json."""
        assert self._recorder is not None and self.paths is not None
        self.recording = False
        try:
            self._recorder.stop()
            meta = json.loads(self.paths.meta.read_text())
            meta["trigger"] = self._trigger
            if reason:
                meta["stop_reason"] = reason
            problems = [{k: v for k, v in p.items() if k != "id"} for p in self.problems]
            if problems:  # the meeting page: "Audio problem at 12:14 (…)"
                meta["audio_problems"] = problems
            self.paths.meta.write_text(json.dumps(meta, indent=2))
            self.paths.audio_problems.unlink(missing_ok=True)  # folded in
            event("record_stop", reason=reason, **track_seconds(self.paths))
        finally:
            if self._stack is not None:
                self._stack.close()
                self._stack = None
        seconds = float(json.loads(self.paths.meta.read_text())["duration_seconds"])
        usage.record("recording_stop", trigger=self._trigger, reason=reason, seconds=seconds,
                     problems=len(self.problems))
        return seconds


def track_seconds(paths: RecordingPaths) -> dict[str, float]:
    out = {}
    for name, wav in (("mic_seconds", paths.mic_raw_wav), ("system_seconds", paths.system_wav)):
        try:
            info = sf.info(str(wav))
            out[name] = round(info.frames / info.samplerate, 1)
        except Exception:
            pass
    return out
