"""Who transcribes the system track of a meeting: this Mac (Parakeet), or
the cloud service the user chose in Settings → Transcription (#54).

- Local is the default. The system track goes to a service only after
  the user chose one for transcription (providers.choose) and it is set
  up; a meeting marked "Keep on This Mac" is always transcribed here.
- Only the system track goes out: what the others said. The mic track is
  one clean voice and stays on Parakeet, and who spoke when is worked out
  here (pyannote): the service's word timestamps are lined up with the
  local speaker turns, so no voice characteristics leave the Mac.
- Long silences are cut out before the upload (fewer billed minutes), and
  the offsets kept, so the words come back on the recording's clock. A
  recording longer than the service takes at once goes in chunks that
  overlap; the words are stitched together where the chunks meet, each
  word once.
- When the service fails, the track is transcribed here and that is said
  (a notification, session.log, transcription.json). Never another cloud.
- Every upload is written to the access log: provider, host, seconds of
  audio, meeting, how it went. Never the audio, the words or a key.

It runs after the call, in `process`. The live worker and the realtime
stream stay on this Mac; the system text the live worker wrote is
replaced by the service's. A meeting transcribed before a service was
chosen is never sent when it is processed again.

transcription.json says, per track, who transcribed it ("local", "live",
a provider id, or "mixed" for a meeting joined from parts transcribed
differently), and for a service the model, the seconds sent and their
estimated cost. It is written before the segments: a meeting with segments
always says who made them. Live text kept on this Mac is marked "local",
so choosing a service later never sends an older meeting.

What a service could not delete yet (cloud_asr: a job that had not ended)
is kept in the meeting's cloud-pending.json and deleted at the start of
the next `process` (``sweep_pending``), until the service says it is gone.
"""

from __future__ import annotations

import io
import json
import logging
import re
import time
from bisect import bisect_right
from collections import Counter
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

import numpy as np

from . import access_log, cloud_asr, notify, providers
from .cloud_llm import CloudError, Transport, redact
from .llm import Unavailable, is_local_only
from .models import Segment, Word
from .paths import RecordingPaths
from .session_log import event, stage

LOGGER = logging.getLogger(__name__)

FEATURE = "transcription"
SAMPLE_RATE = 16_000
RAW_BYTES_PER_SECOND = SAMPLE_RATE * 2  # 16-bit mono: FLAC is never larger
# Silence: no 100 ms frame louder than the system track's near-silence gate
# (cleanup.SYSTEM_MIN_PEAK_DBFS) for this long. Each side keeps a little of it.
FRAME_SECONDS = 0.1
SILENCE_DBFS = -50.0
MIN_SILENCE_SECONDS = 2.0
KEEP_PAD_SECONDS = 0.5
# Chunks overlap this much; they are stitched in the middle of the overlap,
# far from where a chunk cuts a word.
OVERLAP_SECONDS = 10.0
SEAM_DUPLICATE_SECONDS = 0.5  # the same word this close on both sides of a seam is one word
SEAM_SHARED = 0.5  # two words sharing this much of the shorter one's time are one word
# Segments as Parakeet makes them: cut at a sentence end or a 1 s pause, at most 15 s.
PAUSE_SECONDS = 1.0
MAX_SEGMENT_SECONDS = 15.0
TEST_SECONDS = 2.0
SETTINGS_HINT = "Change it in Settings → Transcription."

# --- the choice ------------------------------------------------------------------------------


def cloud_choice(cfg, folder: Path) -> str | None:
    """The service the system track of ``folder`` goes to; None: this Mac."""
    chosen = providers.choice(FEATURE, default=providers.LOCAL)
    if chosen == providers.LOCAL or is_local_only(Path(folder)):
        return None
    return chosen


def ready_provider(cfg, pid: str) -> tuple[dict[str, Any], str | None]:
    """The provider's settings and key; Unavailable when it is not set up."""
    trouble = providers.problem(pid)
    if trouble:
        raise Unavailable(f"{providers.PROVIDERS[pid].label}: {trouble}")
    return providers.settings_of(pid), providers.api_key(pid)


# --- transcription.json ------------------------------------------------------------------------


def read_marker(paths: RecordingPaths) -> dict[str, Any]:
    try:
        data = json.loads(paths.transcription.read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _save(path: Path, text: str) -> None:
    """Whole or not at all."""
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    tmp.replace(path)


def write_marker(paths: RecordingPaths, track: str, **info: Any) -> None:
    data = read_marker(paths)
    data[track] = {**info, "at": datetime.now().astimezone().isoformat(timespec="seconds")}
    _save(paths.transcription, json.dumps(data, indent=2, ensure_ascii=False))


def wants_cloud(paths: RecordingPaths) -> bool:
    """Whether the system track still needs the service: not transcribed
    yet, transcribed by the live worker during the call, or by this Mac
    after the service failed. A meeting transcribed before any of this
    (no transcription.json) is left as it is."""
    if not paths.system_segments.exists():
        return True
    system = read_marker(paths).get("system", {})
    return system.get("engine") == "live" or bool(system.get("fallback_from"))


# --- silence out, offsets kept -------------------------------------------------------------------


def _frame_levels(wav: Path) -> tuple[np.ndarray, float]:
    """The RMS of each 100 ms frame, read a block at a time; and the length."""
    import soundfile as sf

    with sf.SoundFile(str(wav)) as f:
        sr, total = f.samplerate, f.frames
        frame = max(1, int(round(FRAME_SECONDS * sr)))
        levels, rest = [], np.zeros(0, dtype=np.float32)
        for block in f.blocks(blocksize=frame * 600, dtype="float32", always_2d=True):
            mono = np.concatenate([rest, block.mean(axis=1)])
            n = len(mono) // frame
            if n:
                levels.append(np.sqrt((mono[: n * frame].reshape(n, frame) ** 2).mean(axis=1)))
            rest = mono[n * frame:]
        if len(rest):
            levels.append(np.sqrt(np.array([(rest ** 2).mean()])))
    return (np.concatenate(levels) if levels else np.zeros(0)), total / sr


def speech_spans(wav: Path) -> list[tuple[float, float]]:
    """The parts of ``wav`` to send, in seconds: all of it but silences of
    MIN_SILENCE_SECONDS or more, of which KEEP_PAD_SECONDS stay next to
    the speech (and none before the first word or after the last). Empty
    when nothing is louder than silence."""
    levels, total = _frame_levels(wav)
    loud = levels >= 10 ** (SILENCE_DBFS / 20)
    if not loud.any():
        return []
    n, pad = len(loud), round(KEEP_PAD_SECONDS / FRAME_SECONDS)
    shortest = round(MIN_SILENCE_SECONDS / FRAME_SECONDS)
    cuts, i = [], 0
    while i < n:
        if loud[i]:
            i += 1
            continue
        j = i
        while j < n and not loud[j]:
            j += 1
        if j - i >= shortest:
            a, b = i + (pad if i > 0 else 0), j - (pad if j < n else 0)
            if b > a:
                cuts.append((a, b))
        i = j

    def at(k: int) -> float:
        return round(total if k >= n else k * FRAME_SECONDS, 3)

    spans, start = [], 0
    for a, b in cuts:
        if a > start:
            spans.append((at(start), at(a)))
        start = b
    if start < n:
        spans.append((at(start), at(n)))
    return spans


class Timeline:
    """The trimmed audio's clock, and the way back to the recording's."""

    def __init__(self, spans: list[tuple[float, float]]):
        self.spans = list(spans)
        self.offsets, t = [], 0.0
        for a, b in self.spans:
            self.offsets.append(t)
            t += b - a
        self.seconds = t

    def _at(self, t: float) -> int:
        return max(0, min(len(self.spans) - 1, bisect_right(self.offsets, t) - 1))

    def to_source(self, t: float) -> float:
        i = self._at(t)
        a, b = self.spans[i]
        return a + min(max(t - self.offsets[i], 0.0), b - a)

    def word_to_source(self, w: Word) -> Word:
        """A word that runs over a cut ends where its part of the recording ends."""
        i = self._at(w.start)
        a, b = self.spans[i]
        start = a + min(max(w.start - self.offsets[i], 0.0), b - a)
        end = a + min(max(w.end - self.offsets[i], 0.0), b - a)
        return Word(w.text, round(start, 3), round(max(start, end), 3), w.confidence)

    def pieces(self, start: float, end: float) -> list[tuple[float, float]]:
        """The parts of the recording that make up ``start``–``end`` of the trimmed audio."""
        out = []
        for (a, b), off in zip(self.spans, self.offsets):
            lo, hi = max(start, off), min(end, off + (b - a))
            if hi > lo:
                out.append((a + lo - off, a + hi - off))
        return out


def _audio(wav: Path, line: Timeline, start: float, end: float) -> tuple[bytes, float]:
    """``start``–``end`` of the trimmed track as FLAC, 16 kHz mono; and its seconds."""
    import soundfile as sf

    chunks = []
    with sf.SoundFile(str(wav)) as f:
        sr = f.samplerate
        for a, b in line.pieces(start, end):
            f.seek(int(round(a * sr)))
            data = f.read(int(round((b - a) * sr)), dtype="float32", always_2d=True).mean(axis=1)
            if sr != SAMPLE_RATE:
                import soxr

                data = soxr.resample(data, sr, SAMPLE_RATE)
            chunks.append(data.astype(np.float32))
    samples = np.concatenate(chunks) if chunks else np.zeros(0, dtype=np.float32)
    buf = io.BytesIO()
    sf.write(buf, samples, SAMPLE_RATE, format="FLAC", subtype="PCM_16")
    return buf.getvalue(), len(samples) / SAMPLE_RATE


# --- chunks, and stitching them ----------------------------------------------------------------------


def plan_chunks(total: float, max_seconds: float, overlap: float = OVERLAP_SECONDS) -> list[tuple[float, float]]:
    """Pieces of at most ``max_seconds`` covering 0–``total``, each
    overlapping the next by ``overlap``."""
    if total <= max_seconds:
        return [(0, total)]
    overlap = min(overlap, max_seconds / 4)
    step = max_seconds - overlap
    out, start = [], 0
    while True:
        end = min(start + max_seconds, total)
        out.append((start, end))
        if end >= total:
            return out
        start += step


def _norm(text: str) -> str:
    return re.sub(r"\W", "", text.casefold())


def _same_word(a: Word, b: Word) -> bool:
    """Two chunks' versions of one spoken word: the same word close
    together, or any two that share most of their time."""
    if _norm(a.text) == _norm(b.text) and abs(a.start - b.start) <= SEAM_DUPLICATE_SECONDS:
        return True
    shared = min(a.end, b.end) - max(a.start, b.start)
    shorter = min(a.end - a.start, b.end - b.start)
    return shorter > 0 and shared >= SEAM_SHARED * shorter


def stitch(chunks: list[tuple[float, float, list[Word]]]) -> list[Word]:
    """The words of overlapping chunks (start, end, words on the shared
    clock), each once. Each word belongs to exactly one chunk: the one
    whose share of the overlap holds its middle, the middle of the overlap
    being the seam (a word whose middle is the seam goes to the later
    chunk). A word the later chunk heard as one the earlier chunk already
    kept (``_same_word``) is left out."""
    out: list[Word] = []
    for i, (start, end, words) in enumerate(chunks):
        lo = (start + chunks[i - 1][1]) / 2 if i else float("-inf")
        hi = (chunks[i + 1][0] + end) / 2 if i + 1 < len(chunks) else float("inf")
        kept = [w for w in sorted(words, key=lambda w: (w.start, w.end)) if lo <= (w.start + w.end) / 2 < hi]
        tail = out[-3:]
        while kept and any(_same_word(kept[0], o) for o in tail):
            kept.pop(0)
        out += kept
    return out


def segments_from_words(words: list[Word]) -> list[Segment]:
    """Sentences, as Parakeet cuts them: at a sentence end or a pause, at most MAX_SEGMENT_SECONDS."""
    segments: list[Segment] = []
    current: list[Word] = []

    def flush():
        if current:
            segments.append(Segment(current[0].start, current[-1].end, " ".join(w.text for w in current), None,
                                    list(current)))
            current.clear()

    for w in words:
        if current and (w.start - current[-1].end > PAUSE_SECONDS or current[-1].text.endswith((".", "?", "!"))
                        or w.end - current[0].start > MAX_SEGMENT_SECONDS):
            flush()
        current.append(w)
    flush()
    return segments


# --- what goes out --------------------------------------------------------------------------------------------


def keyterms(cfg, paths: RecordingPaths) -> list[str]:
    """The glossary's terms and the names of the meeting's invitees."""
    from . import calendar_events, glossary

    found = [t.get("term", "") for t in glossary.current().terms().values()]
    event_ = calendar_events.load(paths)
    if event_ is not None:
        found += [a.name for a in calendar_events.candidates(event_, user_name=getattr(cfg, "user_name", "") or "")]
    return cloud_asr.terms(found, limit=1000, max_words=6)


def _log(**entry: Any) -> None:
    try:
        access_log.record(**entry)
    except Exception as exc:
        LOGGER.warning("could not write the access log (%s): %s", entry.get("provider"), type(exc).__name__)


# --- what is left at a service ---------------------------------------------------------------------------


def _global_pending() -> Path:
    from ._xdg import xdg_config_home

    return xdg_config_home() / "palaver" / "cloud-pending.json"


def _read_pending(path: Path) -> list[dict]:
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return []
    return [e for e in data if isinstance(e, dict)] if isinstance(data, list) else []


def _write_pending(path: Path, entries: list[dict]) -> None:
    if entries:
        path.parent.mkdir(parents=True, exist_ok=True)
        _save(path, json.dumps(entries, indent=2))
    else:
        path.unlink(missing_ok=True)


def _keep_pending(adapter, path: Path) -> None:
    """What ``adapter`` could not delete, into ``path``: retried later."""
    left = list(getattr(adapter, "pending", None) or [])
    if left:
        adapter.pending.clear()
        _write_pending(path, _read_pending(path) + left)
        event("cloud_delete_pending", provider=left[0].get("provider"), count=len(left))


def retry_pending(path: Path, *, transport: Transport | None = None) -> int:
    """Delete what ``path`` lists; returns how many are still left."""
    entries = _read_pending(path)
    if not entries:
        return 0
    left = []
    for e in entries:
        pid = e.get("provider")
        key = providers.api_key(pid) if pid in providers.PROVIDERS else None
        try:
            done = cloud_asr.delete_pending(e, key, transport=transport)
        except Exception:
            done = False
        if not done:
            left.append({**e, "tries": int(e.get("tries", 0)) + 1})
    _write_pending(path, left)
    return len(left)


def sweep_pending(root: Path, *, transport: Transport | None = None) -> int:
    """Retry the pending deletions of every meeting in ``root``, and the
    Test button's; never fails. Returns how many are still left."""
    left = 0
    files = [_global_pending()]
    try:
        files += sorted(Path(root).glob(f"*/{RecordingPaths(Path(root)).cloud_pending.name}"))
    except OSError:
        pass
    for f in files:
        try:
            left += retry_pending(f, transport=transport)
        except Exception as exc:
            LOGGER.warning("could not retry the deletions in %s: %s", f.parent.name, type(exc).__name__)
    return left


def _send(adapter, pid: str, audio: bytes, seconds: float, *, meetings: list[str], feature: str,
          track: str | None, language: str | None, terms: list[str], key: str | None, pending: Path,
          fallback_language: str | None = None, clock: Callable[[], float] = time.monotonic) -> cloud_asr.Heard:
    """One upload, written to the access log however it goes; what the
    service could not delete goes to ``pending``."""
    entry = dict(provider=pid, host=adapter.host, model=adapter.model, feature=feature, meetings=meetings,
                 chars=0, audio_seconds=seconds, track=track)
    started = clock()
    try:
        heard = adapter.transcribe(audio, seconds=seconds, language=language, keyterms=terms,
                                   fallback_language=fallback_language)
    except Exception as exc:
        message = str(exc) if isinstance(exc, CloudError) else type(exc).__name__
        _log(**entry, ok=False, error=redact(message, key), seconds=clock() - started)
        raise
    finally:
        _keep_pending(adapter, pending)
    _log(**entry, ok=True, seconds=clock() - started)
    return heard


@dataclass
class Outcome:
    segments: list[Segment]
    language: str | None
    sent_seconds: float
    model: str


def _cloud(cfg, paths: RecordingPaths, pid: str, *, dictionary, transport: Transport | None,
           sleep: Callable[[float], None]) -> Outcome:
    settings, key = ready_provider(cfg, pid)
    adapter = cloud_asr.make(pid, settings, key, transport=transport, sleep=sleep)
    spans = speech_spans(paths.system_wav)
    if not spans:
        return Outcome([], None, 0.0, adapter.model)
    line = Timeline(spans)
    longest = min(adapter.max_seconds, adapter.max_bytes / RAW_BYTES_PER_SECOND)
    language = getattr(cfg, "language", "auto")
    language = None if not language or language == "auto" else language
    fallback = language or _meeting_language(paths) or "en"
    terms = keyterms(cfg, paths)
    heard_chunks, languages, sent = [], Counter(), 0.0
    for start, end in plan_chunks(line.seconds, longest):
        audio, seconds = _audio(paths.system_wav, line, start, end)
        heard = _send(adapter, pid, audio, seconds, meetings=[paths.folder.name], feature=FEATURE, track="system",
                      language=language, terms=terms, key=key, pending=paths.cloud_pending,
                      fallback_language=fallback)
        sent += seconds
        if heard.language:
            languages[heard.language] += len(heard.words) or 1
        heard_chunks.append((start, end, [Word(w.text, w.start + start, w.end + start, w.confidence)
                                          for w in heard.words]))
    words = [line.word_to_source(w) for w in stitch(heard_chunks)]
    if dictionary is not None:
        words = [Word(dictionary.apply(w.text), w.start, w.end, w.confidence) for w in words]
    words = [w for w in words if w.text.strip()]
    return Outcome(segments_from_words(words), languages.most_common(1)[0][0] if languages else language,
                   sent, adapter.model)


def _meeting_language(paths: RecordingPaths) -> str | None:
    try:
        return cloud_asr.language_code(paths.language.read_text())
    except OSError:
        return None


def _write(paths: RecordingPaths, segments: list[Segment], language: str | None, **marker: Any) -> None:
    """The language, then who transcribed it, then the segments: a kill
    never leaves segments nobody vouches for."""
    if language:
        paths.language.write_text(language + "\n")
    write_marker(paths, "system", **marker)
    _save(paths.system_segments, json.dumps([s.to_dict() for s in segments], indent=2))


def cost(pid: str, seconds: float) -> float | None:
    price = providers.PROVIDERS[pid].usd_per_hour if pid in providers.PROVIDERS else None
    return None if price is None else round(seconds / 3600 * price, 4)


def system_track(cfg, paths: RecordingPaths, *, local: Callable[[], tuple[list[Segment], str | None]],
                 dictionary=None, transport: Transport | None = None,
                 sleep: Callable[[float], None] = time.sleep) -> str | None:
    """Transcribe the system track of ``paths`` where it belongs and write
    system_segments.json; ``local`` transcribes it on this Mac (segments,
    language). Returns who did it ("local", "live" or the provider), or
    None when it was done already."""
    pid = cloud_choice(cfg, paths.folder)
    if pid is None:
        if paths.system_segments.exists():
            system = read_marker(paths).get("system", {})
            if system.get("engine") == "live" or system.get("fallback_from"):
                # Kept as this Mac made it: a service chosen later never sends it.
                write_marker(paths, "system", engine="local")
            return None
        segments, language = local()
        _write(paths, segments, language, engine="local")
        return "local"
    if not wants_cloud(paths):
        return None
    label = providers.PROVIDERS[pid].label
    previous = read_marker(paths).get("system", {})
    print(f"Transcribing system track with {label}…")
    try:
        with stage("transcribe", track="system", engine=pid) as info:
            out = _cloud(cfg, paths, pid, dictionary=dictionary, transport=transport, sleep=sleep)
            info.update(segments=len(out.segments), language=out.language, sent_seconds=round(out.sent_seconds, 1))
    except Exception as exc:
        message = str(exc) if isinstance(exc, (CloudError, Unavailable)) else type(exc).__name__
        if not isinstance(exc, (CloudError, Unavailable)):
            LOGGER.exception("cloud transcription failed")
        event("cloud_transcription_failed", provider=pid, error=message)
        print(f"{label} failed ({message}); transcribing on this Mac instead")
        if previous.get("engine") == "live" and paths.system_segments.exists():
            engine = "live"  # the live worker's text is this Mac's already
        else:
            segments, language = local()
            _write(paths, segments, language, engine="local", fallback_from=pid, error=message)
            engine = "local"
        if engine == "live":
            write_marker(paths, "system", engine=engine, fallback_from=pid, error=message)
        notify.notify("Transcribed on this Mac", f"{paths.folder.name}: {label} failed: {message}",
                      paths.folder.name)
        return engine
    _write(paths, out.segments, out.language, engine=pid, model=out.model,
           sent_seconds=round(out.sent_seconds, 1), usd=cost(pid, out.sent_seconds))
    return pid


# --- the Test button, and the cost ---------------------------------------------------------------------


def _tone(seconds: float) -> bytes:
    import soundfile as sf

    t = np.arange(int(seconds * SAMPLE_RATE)) / SAMPLE_RATE
    buf = io.BytesIO()
    sf.write(buf, (0.2 * np.sin(2 * np.pi * 440 * t)).astype(np.float32), SAMPLE_RATE, format="FLAC",
             subtype="PCM_16")
    return buf.getvalue()


def test(pid: str, cfg, *, transport: Transport | None = None,
         sleep: Callable[[float], None] = time.sleep) -> dict[str, Any]:
    """Send two seconds of a tone (no meeting) to ``pid``: how long it took
    and what an hour costs."""
    if pid not in providers.transcribers():
        raise ValueError(f"no transcription service {pid!r}")
    settings, key = ready_provider(cfg, pid)
    adapter = cloud_asr.make(pid, settings, key, transport=transport, sleep=sleep)
    started = time.monotonic()
    heard = _send(adapter, pid, _tone(TEST_SECONDS), TEST_SECONDS, meetings=[], feature="test", track=None,
                  language=None, terms=[], key=key, pending=_global_pending(), fallback_language="en")
    return {"seconds": round(time.monotonic() - started, 1), "model": adapter.model,
            "usd_per_hour": providers.PROVIDERS[pid].usd_per_hour,
            "heard": " ".join(w.text for w in heard.words)[:200]}


def month(now: datetime | None = None) -> dict[str, Any]:
    """What was sent for transcription this month: seconds of audio,
    meetings, and the estimated cost at list prices."""
    now = now or datetime.now().astimezone()
    since = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    seconds, usd, meetings = 0.0, 0.0, set()
    for e in access_log.recent(None):  # the whole log: it is never trimmed (#59)
        if e.get("feature") != FEATURE or not e.get("ok"):
            continue
        try:
            when = datetime.fromisoformat(e["time"])
        except (KeyError, TypeError, ValueError):
            continue
        if when < since:
            continue
        audio = float(e.get("audio_seconds") or 0)
        seconds += audio
        usd += cost(e.get("provider", ""), audio) or 0.0
        meetings.update(e.get("meetings") or [])
    return {"since": since.date().isoformat(), "seconds": round(seconds, 1), "usd": round(usd, 2),
            "meetings": len(meetings)}
