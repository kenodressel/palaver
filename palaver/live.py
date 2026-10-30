"""Process a meeting while it is being recorded.

`palaver live <folder>` runs next to the recorder (the daemon
starts it at low priority) and does the heavy work as audio arrives: echo
cancellation, transcription in ~1 min blocks cut at pauses, and the
expensive part of diarization (``IncrementalDiarizer``). When the recording
stops it finishes the last block and writes the same files `process`
writes — mic.wav, *_segments.json, system_turns.json,
speaker_embeddings.json — so the `run` that follows only merges and
uploads. If this worker dies, `process` does everything as before.
"""

from __future__ import annotations

import json
import logging
import os
import signal
import subprocess
import time
from pathlib import Path
from typing import Callable

import numpy as np
import soundfile as sf

from .models import Segment, Word
from .paths import RecordingPaths
from .session_log import stage

LOGGER = logging.getLogger(__name__)

SAMPLE_RATE = 16_000
HEADER_BYTES = 44
# Transcribe about this much audio at a time, cut at the quietest moment
# near the end so no sentence is split.
BLOCK_SECONDS = 60.0
CUT_SEARCH_SECONDS = 15.0
# Stay this far behind the newest written sample: the recorder writes a
# track only when audio arrives and zero-pads gaps afterwards, so anything
# older than a few seconds is final.
MARGIN_SECONDS = 3.0
POLL_SECONDS = 5.0
# .part files that stop growing without meta.json appearing: the recorder
# died. Leave the folder to `process`.
STALL_SECONDS = 120.0
# Shorter remainders hold no speech worth a model call.
MIN_BLOCK_SECONDS = 0.5
# Freed MLX memory kept for reuse. Replaying 8 min as it arrives: 512 MB
# cache 4.0 GB footprint, 128 MB 3.6 GB at the same speed; 0 cost a third
# more CPU.
MLX_CACHE_LIMIT = 128 * 1024**2


def mark_written(paths: RecordingPaths) -> None:
    """Say the system text is the live worker's: with a cloud service chosen
    for transcription (#54), `process` replaces it with the service's."""
    from .transcription import write_marker

    write_marker(paths, "system", engine="live")


def pid_path(folder: Path) -> Path:
    return folder / "live.pid"


def _command_line(pid: int) -> str | None:
    try:
        out = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout.strip() if out.returncode == 0 else ""


def worker_running(folder: Path) -> bool:
    """Whether a live worker is still processing ``folder``. A pid file left
    behind (the worker was killed, or its pid now belongs to another
    program) is removed; an exited worker that is our child is reaped — a
    zombie still answers ``kill(pid, 0)``."""
    path = pid_path(folder)
    try:
        pid = int(path.read_text())
    except (OSError, ValueError):
        return False
    try:
        if os.waitpid(pid, os.WNOHANG)[0] == pid:  # our child, and it has exited
            path.unlink(missing_ok=True)
            return False
    except ChildProcessError:
        pass  # not our child: ask the system
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        path.unlink(missing_ok=True)
        return False
    except PermissionError:
        return True  # alive, under another user
    command = _command_line(pid)
    if command is not None and not _works_on(command, folder):
        path.unlink(missing_ok=True)  # the pid was reused
        return False
    return True


def _works_on(command: str, folder: Path) -> bool:
    """Whether ``command`` is `palaver … live <folder>` for this folder."""
    if " live " not in command:
        return False
    try:
        return Path(command.rsplit(" live ", 1)[1].strip()).resolve() == folder.resolve()
    except (OSError, ValueError):
        return False


def stop_worker(folder: Path) -> None:
    try:
        os.kill(int(pid_path(folder).read_text()), signal.SIGTERM)
    except (OSError, ValueError):
        pass


class GrowingTrack:
    """A 16 kHz mono PCM_16 track the recorder may still be writing
    (``<name>.part``, whose header is only patched at the end) or has
    finished (``<name>``). Reads past the written end return silence."""

    def __init__(self, final: Path):
        self._final = final
        self._part = Path(str(final) + ".part")

    def _path(self) -> Path | None:
        for path in (self._part, self._final):
            if path.exists():
                return path
        return None

    def available(self) -> int:
        path = self._path()
        if path is None:
            return 0
        try:
            return max(0, (path.stat().st_size - HEADER_BYTES) // 2)
        except FileNotFoundError:  # renamed .part → final in between
            return self.available()

    def read(self, start: int, end: int) -> np.ndarray:
        out = np.zeros(max(0, end - start), dtype=np.int16)
        for path in (self._part, self._final):
            try:
                with open(path, "rb") as fh:
                    fh.seek(HEADER_BYTES + 2 * start)
                    data = np.frombuffer(fh.read(2 * len(out)), dtype=np.int16)
            except FileNotFoundError:
                continue
            out[: len(data)] = data[: len(out)]
            break
        return out


def quietest_cut(samples: np.ndarray, earliest: int, latest: int, frame: int = 800) -> int:
    """Index in [earliest, latest] at the centre of the quietest 50 ms frame."""
    if latest - earliest < frame:
        return latest
    region = samples[earliest:latest].astype(np.float32)
    frames = len(region) // frame
    energy = (region[: frames * frame].reshape(frames, frame) ** 2).mean(axis=1)
    return earliest + int(np.argmin(energy)) * frame + frame // 2


class TrackTranscriber:
    """Transcribes a growing track block by block; segments keep absolute
    times."""

    def __init__(self, name: str, transcriber, scratch: Path, speaker: str | None = None):
        self.name = name
        self._transcriber = transcriber
        self._scratch = scratch
        self._speaker = speaker
        self.done = 0
        self.segments: list[Segment] = []

    def advance(self, read: Callable[[int, int], np.ndarray], final_until: int, *, last: bool = False,
                language: str | None = None) -> bool:
        """Transcribe the next block if one is complete (or, with ``last``,
        everything up to ``final_until``). Returns whether it did."""
        block = int(BLOCK_SECONDS * SAMPLE_RATE)
        if last:
            end = final_until
        elif final_until - self.done >= block:
            search = int(CUT_SEARCH_SECONDS * SAMPLE_RATE)
            latest = min(final_until, self.done + block + search)
            audio = read(self.done, latest)
            end = self.done + quietest_cut(audio, latest - self.done - search, latest - self.done)
        else:
            return False
        if end - self.done < MIN_BLOCK_SECONDS * SAMPLE_RATE:
            self.done = max(self.done, end)
            return False
        audio = read(self.done, end)
        if np.any(audio):
            self.segments += self._transcribe(audio, self.done / SAMPLE_RATE, language)
        self.done = end
        return True

    def _transcribe(self, audio: np.ndarray, offset: float, language: str | None) -> list[Segment]:
        wav = self._scratch / f"live-{self.name}.wav"
        sf.write(str(wav), audio, SAMPLE_RATE, subtype="PCM_16")
        try:
            segments = self._transcriber.transcribe(wav, language=language)
        finally:
            wav.unlink(missing_ok=True)
        for s in segments:
            s.start += offset
            s.end += offset
            s.words = [Word(w.text, w.start + offset, w.end + offset) for w in s.words]
            if self._speaker is not None:
                s.speaker = self._speaker
        return segments


class LiveProcessor:
    """Echo cancellation, transcription and diarization of a recording in
    progress. ``step`` processes what is final so far; ``finish`` completes
    the stopped recording and writes the pipeline's output files."""

    def __init__(self, paths: RecordingPaths, *, transcriber, diarizer, user_name: str,
                 language: str = "auto", aec_factory: Callable | None = None):
        from .capture_recorder import _IncrementalTrackWriter

        if aec_factory is None:
            from .aec import AecStream as aec_factory
        self._paths = paths
        self._mic = GrowingTrack(paths.mic_raw_wav)
        self._system = GrowingTrack(paths.system_wav)
        self._aec = aec_factory()
        self._aec_in = 0  # raw mic samples fed to the AEC
        self._mic_out = _IncrementalTrackWriter(paths.mic_wav)
        self._aec_track = GrowingTrack(paths.mic_wav)
        self._language = language
        self._transcriber = transcriber
        self.system = TrackTranscriber("system", transcriber, paths.folder)
        self.mic = TrackTranscriber("mic", transcriber, paths.folder, speaker=user_name)
        self.diarizer = diarizer
        self._snapshot_key = None

    def final_until(self) -> int:
        """Samples that will not change any more on either track."""
        newest = max(self._mic.available(), self._system.available())
        return max(0, newest - int(MARGIN_SECONDS * SAMPLE_RATE))

    def step(self) -> bool:
        """Process one slice of what is final so far; False when caught up."""
        until = self.final_until()
        progressed = self._run_aec(until)
        progressed |= self.diarizer.advance(self._read_system_float, until) > 0
        progressed |= self.system.advance(self._system.read, until)
        progressed |= self.mic.advance(self._aec_track.read, self._aec_written(), language=self._mic_language())
        return progressed

    def finish(self) -> None:
        mic_end, system_end = self._mic.available(), self._system.available()
        self._run_aec(mic_end)
        self._mic_out.finalize_to(mic_end)
        self.system.segments = [s for s in self.system.segments if s.start < system_end / SAMPLE_RATE]
        while self.system.advance(self._system.read, system_end):
            pass
        self.system.advance(self._system.read, system_end, last=True)
        mic_language = self._mic_language()
        while self.mic.advance(self._aec_track.read, mic_end, language=mic_language):
            pass
        self.mic.advance(self._aec_track.read, mic_end, last=True, language=mic_language)
        turns = self.diarizer.finish(self._read_system_float(0, system_end))

        paths = self._paths
        if getattr(self._transcriber, "last_language", None):
            _write_atomic(paths.language, self._transcriber.last_language + "\n")
        _write_atomic(paths.system_segments, json.dumps([s.to_dict() for s in self.system.segments], indent=2))
        _write_atomic(paths.mic_segments, json.dumps([s.to_dict() for s in self.mic.segments], indent=2))
        _write_atomic(paths.speaker_embeddings, json.dumps(self.diarizer.last_embeddings))
        _write_atomic(paths.system_turns, json.dumps([t.to_dict() for t in turns], indent=2))
        mark_written(paths)
        paths.live.unlink(missing_ok=True)  # the files above say it all now

    def snapshot(self) -> bool:
        """Write live.json — the text so far and speakers clustered from the
        voices so far — when there is something new. Labels may change
        between snapshots; their voices (embeddings) say who is who."""
        key = (self.system.done, self.mic.done, getattr(self.diarizer, "chunks_done", 0))
        if key == self._snapshot_key:
            return False
        self._snapshot_key = key
        provisional = getattr(self.diarizer, "provisional", None)
        turns = provisional() if provisional else []
        _write_atomic(self._paths.live, json.dumps({
            "until": round(min(self.system.done, self.mic.done) / SAMPLE_RATE, 2),
            "system": [s.to_dict() for s in self.system.segments],
            "mic": [s.to_dict() for s in self.mic.segments],
            "turns": [t.to_dict() for t in turns],
            "embeddings": self.diarizer.last_embeddings if turns else {},
        }))
        return True

    def abort(self) -> None:
        self._mic_out.abort()
        Path(str(self._paths.mic_wav) + ".part").unlink(missing_ok=True)

    def _mic_language(self) -> str | None:
        if self._language != "auto":
            return self._language
        # As in `process`: Whisper's language from the system track.
        return getattr(self._transcriber, "last_language", None)

    def _run_aec(self, until: int) -> bool:
        if until <= self._aec_in:
            return False
        out = self._aec.process(self._mic.read(self._aec_in, until), self._system.read(self._aec_in, until))
        self._mic_out.write_chunk_at_offset(self._mic_out.frames_written, out)
        self._mic_out.flush()
        self._aec_in = until
        return True

    def _aec_written(self) -> int:
        return self._mic_out.frames_written

    def _read_system_float(self, start: int, end: int) -> np.ndarray:
        return self._system.read(start, end).astype(np.float32) / 32768.0


def _write_atomic(path: Path, text: str) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    tmp.replace(path)


def recording_finished(paths: RecordingPaths) -> bool:
    return paths.meta.exists() and not any(
        Path(str(p) + ".part").exists() for p in (paths.mic_raw_wav, paths.system_wav)
    )


def run_live(processor: LiveProcessor, paths: RecordingPaths, *, poll: float = POLL_SECONDS,
             stall: float = STALL_SECONDS, clock: Callable[[], float] = time.monotonic,
             sleep: Callable[[float], None] = time.sleep) -> bool:
    """Process until the recording stops, then finish. Returns False (and
    leaves everything to `process`) if the recorder stopped without
    finishing the recording."""
    last_size, last_growth = -1, clock()
    while not recording_finished(paths):
        if processor.step():
            continue
        try:
            processor.snapshot()
        except Exception:  # showing it live is extra; the recording goes on
            LOGGER.exception("live snapshot failed")
        size = processor.final_until()
        if size != last_size:
            last_size, last_growth = size, clock()
        elif clock() - last_growth > stall:
            LOGGER.warning("recording stopped growing without finishing; leaving it to `process`")
            processor.abort()
            return False
        sleep(poll)
    with stage("live_finish"):
        processor.finish()
    return True

