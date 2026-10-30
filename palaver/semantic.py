"""Search by meaning (#46): "pricing" also finds "Kosten" and "Angebot".

Each meeting gets an index once it is processed: its notes, piece by piece
(summary, decisions, next steps, points), and its transcript in runs of one
speaker, each as a vector (``embeddings``). ``palaver index`` builds the
indexes of meetings without a current one; the daemon runs it in the
background, never while a call is recorded, and only with free memory. A
search embeds only its own words and compares them with the stored vectors.

The index is two files in the meeting's folder: ``search-index.npy`` (one
float16 row per piece) and ``search-index.json`` (the pieces). It is current
while it is newer than the transcript and the notes; an older one is not
used. Pieces keep speaker labels; names are put in when they are shown.
"""

from __future__ import annotations

import json
import logging
import threading
import time
from pathlib import Path
from typing import Any, Callable

import numpy as np

from . import embeddings, notes, settings
from .models import Utterance
from .paths import RecordingPaths, is_recording_folder_name
from .readable import readable

LOGGER = logging.getLogger(__name__)

INDEX_NPY = "search-index.npy"
INDEX_JSON = "search-index.json"
# Written last: which model, and the times of the files the index was made
# from, read when the indexing began. The index is current while they match.
INDEX_SIG = "search-index.sig"
# A meeting whose indexing failed: skipped until its files change.
INDEX_FAILED = "search-index.failed"
# A piece of the transcript: one speaker's lines, up to this many words; a
# run shorter than MIN_WORDS ("Ja, genau.") says too little to be found by.
CHUNK_WORDS = 80
MIN_WORDS = 8
# multilingual-e5 scores everything between ~0.7 and ~0.9, and how high
# depends on the query: on six real meetings (600 pieces) "Kosten" scored
# 0.80 against half of them, "holiday plans in Spain" 0.72. A hit has to
# stand out: MARGIN above the median of the pieces searched (0.06 kept the
# pieces about the query and none for "nothing like this"), never below
# MIN_SCORE. With fewer than MEDIAN_PIECES the median says little: SMALL_SCORE.
MIN_SCORE = 0.78
MARGIN = 0.06
MEDIAN_PIECES = 100
SMALL_SCORE = 0.80
HITS_PER_MEETING = 3
# The model goes after this long without a search.
IDLE_SECONDS = 300.0
# What ``palaver index`` needs free: its peak was ~240 MB footprint.
INDEX_MEMORY_GB = 1.0


def enabled() -> bool:
    return settings.load().search_meaning


def _sources(paths: RecordingPaths) -> list[Path]:
    return [paths.transcript_json, paths.notes, paths.speakers_ignored]


def _signature(paths: RecordingPaths) -> dict[str, int | None]:
    """The files an index is made from and their times; a missing one is None."""
    out: dict[str, int | None] = {}
    for f in _sources(paths):
        try:
            out[f.name] = f.stat().st_mtime_ns
        except OSError:
            out[f.name] = None
    return out


def _read(path: Path) -> dict | None:
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _indexable(paths: RecordingPaths) -> bool:
    from .live import worker_running

    return paths.transcript_json.exists() and not worker_running(paths.folder)


def is_current(paths: RecordingPaths) -> bool:
    sig = _read(paths.folder / INDEX_SIG)
    return bool(sig) and sig.get("model") == embeddings.MODEL and sig.get("sources") == _signature(paths)


def _failed(paths: RecordingPaths) -> bool:
    """Indexing failed on the files as they are now."""
    mark = _read(paths.folder / INDEX_FAILED)
    return bool(mark) and mark.get("sources") == _signature(paths)


def _meetings(output_dir: Path) -> list[RecordingPaths]:
    if not output_dir.is_dir():
        return []
    return [RecordingPaths(f) for f in sorted(output_dir.iterdir(), reverse=True)
            if f.is_dir() and is_recording_folder_name(f.name)]


def stale(output_dir: Path) -> list[RecordingPaths]:
    """Processed meetings without a current index, newest first. Only file
    times are read: cheap enough to ask every few minutes."""
    return [p for p in _meetings(output_dir) if _indexable(p) and not is_current(p) and not _failed(p)]


def chunks(paths: RecordingPaths) -> list[dict[str, Any]]:
    """The pieces of a meeting that get a vector each."""
    from .speakers import without_ignored

    out: list[dict[str, Any]] = []
    n = notes.load(paths) or {}
    if n.get("summary"):
        out.append({"kind": "summary", "text": n["summary"]})
    out += [{"kind": "decision", "text": d} for d in n.get("decisions") or [] if isinstance(d, str) and d]
    out += [{"kind": "step", "text": s["task"], "owner": s.get("owner") or ""}
            for s in n.get("next_steps") or [] if isinstance(s, dict) and s.get("task")]
    for section in n.get("sections") or []:
        for point in section.get("points") or []:
            text = " ".join([point.get("text") or "", *(point.get("details") or [])]).strip()
            if text:
                out.append({"kind": "point", "text": text, "heading": section.get("heading") or ""})
    try:
        utterances = [Utterance.from_dict(d) for d in json.loads(paths.transcript_json.read_text())]
    except (OSError, ValueError):
        utterances = []
    run: list[Utterance] = []

    def flush():
        text = " ".join(u.text for u in run).strip()
        if len(text.split()) >= MIN_WORDS:
            out.append({"kind": "line", "speaker": run[0].label or run[0].speaker, "start": round(run[0].start, 2),
                        "text": text})
        run.clear()

    for u in readable(without_ignored(paths, utterances)):
        who = u.label or u.speaker
        words = sum(len(x.text.split()) for x in run)
        if run and ((run[0].label or run[0].speaker) != who or words + len(u.text.split()) > CHUNK_WORDS):
            flush()
        run.append(u)
    if run:
        flush()
    return out


def _passage(chunk: dict[str, Any]) -> str:
    return ": ".join(x for x in (chunk.get("heading"), chunk["text"]) if x)


def index_meeting(paths: RecordingPaths, encoder) -> int:
    """Write the meeting's index; the number of pieces. It is current only
    if its files did not change while it was made."""
    sources = _signature(paths)
    pieces = chunks(paths)
    vectors = encoder.passages([_passage(c) for c in pieces]).astype(np.float16)
    npy, meta = paths.folder / INDEX_NPY, paths.folder / INDEX_JSON
    tmp_npy = paths.folder / (INDEX_NPY + ".tmp")
    with open(tmp_npy, "wb") as f:
        np.save(f, vectors)
    tmp_npy.replace(npy)
    tmp = paths.folder / (INDEX_JSON + ".tmp")
    tmp.write_text(json.dumps({"model": embeddings.MODEL, "chunks": pieces}, ensure_ascii=False))
    tmp.replace(meta)
    tmp = paths.folder / (INDEX_SIG + ".tmp")
    tmp.write_text(json.dumps({"model": embeddings.MODEL, "sources": sources, "count": len(pieces)}))
    tmp.replace(paths.folder / INDEX_SIG)  # last: says the index is whole and from which files
    (paths.folder / INDEX_FAILED).unlink(missing_ok=True)
    return len(pieces)


def default_encoder(*, download: bool) -> Any | None:
    folder = embeddings.model_folder(download=download)
    return embeddings.Encoder(folder) if folder is not None else None


def index_stale(output_dir: Path, encoder_factory: Callable[[], Any] | None = None,
                should_stop: Callable[[], bool] = lambda: False, only: list[RecordingPaths] | None = None) -> int:
    """Index the meetings without a current index (or ``only`` these); the
    model is loaded once, and only when there is something to index."""
    todo = only if only is not None else stale(output_dir)
    encoder = None
    done = 0
    for paths in todo:
        if should_stop():
            break
        if encoder is None:
            encoder = encoder_factory() if encoder_factory else default_encoder(download=True)
        started = time.monotonic()
        sources = _signature(paths)
        try:
            n = index_meeting(paths, encoder)
        except Exception:
            LOGGER.exception("indexing %s failed; trying again when its files change", paths.folder.name)
            try:
                (paths.folder / INDEX_FAILED).write_text(json.dumps({"sources": sources}))
            except OSError:
                pass
            continue
        LOGGER.info("indexed %s: %d pieces in %.1f s", paths.folder.name, n, time.monotonic() - started)
        done += 1
    return done


def ready(output_dir: Path) -> bool:
    """Whether a search by meaning can find anything: switched on, the model
    on this Mac, and at least one meeting indexed."""
    if not enabled():
        return False
    if not any(is_current(p) for p in _meetings(output_dir) if (p.folder / INDEX_SIG).exists()):
        return False
    return embeddings.model_folder(download=False) is not None


def floor(scores: np.ndarray) -> float:
    """The lowest score that counts as a hit among ``scores``."""
    if len(scores) < MEDIAN_PIECES:
        return SMALL_SCORE
    return max(MIN_SCORE, float(np.median(scores)) + MARGIN)


class Searcher:
    """Embeds searches. The model is loaded at the first search and let go
    after ``idle_seconds`` without one; indexes are read once per change."""

    def __init__(self, encoder_factory: Callable[[], Any] | None = None, *, idle_seconds: float = IDLE_SECONDS,
                 clock: Callable[[], float] = time.monotonic,
                 timer: bool | Callable[[float, Callable[[], None]], Any] = True):
        self._factory = encoder_factory or (lambda: default_encoder(download=False))
        self._idle = idle_seconds
        self._clock = clock
        self._timer = timer
        self._encoder = None
        self._used = 0.0
        self._armed = False
        self._lock = threading.Lock()
        self._indexes: dict[str, tuple[int, list[dict], np.ndarray]] = {}
        self._queries: dict[str, np.ndarray] = {}

    @property
    def loaded(self) -> bool:
        return self._encoder is not None

    def release_if_idle(self) -> None:
        """Let the model and the indexes go when unused for ``idle_seconds``;
        used since: look again that long after the last use."""
        with self._lock:
            self._armed = False
            if self._encoder is None and not self._indexes:
                return
            left = self._idle - (self._clock() - self._used)
            if left > 0:
                self._arm(left)
                return
            self._encoder = None
            self._indexes.clear()
            self._queries.clear()
            LOGGER.info("search by meaning: model let go after %.0f s idle", self._idle)

    def _arm(self, delay: float) -> None:
        """One timer at a time (called with the lock held)."""
        if self._armed or not self._timer:
            return
        self._armed = True
        if callable(self._timer):
            self._timer(delay, self.release_if_idle)
            return
        t = threading.Timer(delay + 1.0, self.release_if_idle)
        t.daemon = True
        t.start()

    def _index(self, paths: RecordingPaths) -> tuple[list[dict], np.ndarray] | None:
        if not is_current(paths):
            return None
        meta = paths.folder / INDEX_JSON
        try:
            built = (paths.folder / INDEX_SIG).stat().st_mtime_ns
        except OSError:
            return None
        cached = self._indexes.get(str(paths.folder))
        if cached is None or cached[0] != built:
            try:
                data = json.loads(meta.read_text())
                matrix = np.load(paths.folder / INDEX_NPY).astype(np.float32)
            except (OSError, ValueError):
                return None
            if data.get("model") != embeddings.MODEL or len(data.get("chunks", [])) != len(matrix):
                return None
            cached = (built, data["chunks"], matrix)
            self._indexes[str(paths.folder)] = cached
        return cached[1], cached[2]

    def _query(self, text: str) -> np.ndarray | None:
        if self._encoder is None:
            self._encoder = self._factory()
            if self._encoder is None:
                return None
        self._used = self._clock()
        self._arm(self._idle)
        if text not in self._queries:
            if len(self._queries) > 64:
                self._queries.clear()
            self._queries[text] = self._encoder.query(text)
        return self._queries[text]

    def search(self, meetings: list[RecordingPaths], text: str, *, kinds: set[str] | None = None,
               speaker: Callable[[RecordingPaths, str], bool] | None = None) -> dict[str, list[dict[str, Any]]]:
        """Meeting id → its best pieces about ``text`` (scored over ``floor``),
        best first. ``kinds``: only these pieces; ``speaker(paths, label)``:
        only lines of the speakers it accepts."""
        text = text.strip()
        if not text:
            return {}
        with self._lock:
            indexes = [(p, ix) for p in meetings if (ix := self._index(p)) is not None]
            if not indexes:
                return {}
            vector = self._query(text)
            if vector is None:  # no model on this Mac: keep nothing
                self._indexes.clear()
                return {}
        out: dict[str, list[dict[str, Any]]] = {}
        scored = [(paths, pieces, matrix @ vector) for paths, (pieces, matrix) in indexes]
        lowest = floor(np.concatenate([s for _, _, s in scored]))
        for paths, pieces, scores in scored:
            hits = []
            for i in np.argsort(-scores):
                if scores[i] < lowest or len(hits) >= HITS_PER_MEETING:
                    break
                piece = pieces[i]
                if kinds is not None and piece["kind"] not in kinds:
                    continue
                if speaker is not None and (piece["kind"] != "line" or not speaker(paths, piece["speaker"])):
                    continue
                hits.append({**piece, "score": round(float(scores[i]), 3)})
            if hits:
                out[paths.folder.name] = hits
        return out
