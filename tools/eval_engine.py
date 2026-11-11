"""`make eval-engine`: the local quality gate for the Swift engine.

Runs the engine on the maintainer's own recordings and compares it with the
numbers the old stack (Parakeet-MLX, pyannote) produced. The recordings are
private, so this never runs in CI and writes NUMBERS ONLY: speakers are P0, P1…,
meetings appear by id, no text, name or embedding is printed or written.

Needs PALAVER_EVAL_DIR with a local eval.json (never committed):
  gold_dir, gold_clips (ids; <gold_dir>/<id>.wav + .txt, reference = non-# lines),
  baseline_gold_wer_mlx, asr_meetings (ids under ~/Meetings/Recordings),
  diar_baseline_pyannote ({id: {confusion_pct, clusters, people}}),
  voice_meetings (ids).
Writes $PALAVER_EVAL_DIR/engine-gate.md.

`--worker PATH` (or env PALAVER_EVAL_WORKER): the same gate through `PATH engine-serve`, palaver-worker's
in-process engine, with palaver-engine's reply shapes (`make eval-engine-worker`); it writes
engine-gate-worker.md, so both runs' numbers stay side by side.

Self-contained: it talks to the engine over its JSON-lines protocol itself (``Engine``) and reads the meetings'
files directly (``Meeting``).
"""
from __future__ import annotations

import collections
import difflib
import json
import os
import queue
import re
import stat
import subprocess
import sys
import tempfile
import threading
import unicodedata
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
RUN = 8  # a lost passage is a run of at least this many words
WER_SLACK = 1.0  # points over the MLX baseline
LOST_FACTOR = 1.2
CONFUSION_SLACK = 2.0  # points over pyannote
CLUSTER_SLACK = 1
COLLAR = 0.25
MIN_TALK = 10.0
MIN_CLUSTER_TALK = 2.0
OVERLAP_SHARE = 0.8
COSINE_MIN = 0.9
FRAME = 0.01


# --- text -------------------------------------------------------------------

def norm(text: str) -> list[str]:
    t = unicodedata.normalize("NFC", text.lower()).replace("ß", "ss")
    return re.sub(r"[^\w\s']", " ", t).split()


def edit_distance(a: list[str], b: list[str]) -> int:
    d = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        prev, d[0] = d[0], i
        for j, y in enumerate(b, 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (x != y))
    return d[-1]


def word_errors(reference: str, hypothesis: str) -> tuple[int, int]:
    """(edit distance, reference words) on normalised words."""
    ref = norm(reference)
    return edit_distance(ref, norm(hypothesis)), len(ref)


def lost_passages(stored: str, engine: str, run: int = RUN) -> tuple[int, int]:
    """(words only in stored, words only in engine), counting runs of at least
    ``run`` words that one side has and the other lacks."""
    a, b = norm(stored), norm(engine)
    only_a = only_b = 0
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if op in ("delete", "replace") and (i2 - i1) - (j2 - j1) >= run:
            only_a += (i2 - i1) - (j2 - j1)
        if op in ("insert", "replace") and (j2 - j1) - (i2 - i1) >= run:
            only_b += (j2 - j1) - (i2 - i1)
    return only_a, only_b


# --- diarization ------------------------------------------------------------

def _paint(segments, n: int, labels: dict[str, int]) -> np.ndarray:
    grid = np.full(n, -1, dtype=np.int32)
    for s, e, lab in segments:
        i, j = max(0, int(round(s / FRAME))), min(n, int(round(e / FRAME)))
        if j > i:
            grid[i:j] = labels.setdefault(lab, len(labels))
    return grid


def confusion(reference, hypothesis, ignored=(), collar: float = COLLAR, duration: float | None = None) -> dict:
    """DER components for exclusive (non-overlapping) turns, in seconds.

    ``reference``/``hypothesis``: (start, end, label). Scored: reference speech
    outside the collar (``collar``/2 either side of each reference boundary)
    and outside ``ignored`` (start, end) regions. Confusion: speech where both
    have a label but not the one the optimal one-to-one mapping pairs up.
    Also returns the speakers (labels with ≥ 2 s) on each side."""
    from scipy.optimize import linear_sum_assignment

    end = max([e for _, e, _ in reference] + [e for _, e, _ in hypothesis] + [duration or 0.0])
    n = int(np.ceil(end / FRAME)) + 1
    rl: dict[str, int] = {}
    hl: dict[str, int] = {}
    r, h = _paint(reference, n, rl), _paint(hypothesis, n, hl)
    keep = np.ones(n, dtype=bool)
    half = collar / 2
    for s, e, _ in reference:
        for t in (s, e):
            keep[max(0, int(round((t - half) / FRAME))): min(n, int(round((t + half) / FRAME)))] = False
    for s, e in ignored:
        keep[max(0, int(round(s / FRAME))): min(n, int(round(e / FRAME)))] = False
    scored = keep & (r >= 0)
    both = scored & (h >= 0)
    table = np.zeros((max(1, len(rl)), max(1, len(hl))))
    np.add.at(table, (r[both], h[both]), 1)
    matched = 0.0
    if table.sum():
        rows, cols = linear_sum_assignment(-table)
        matched = table[rows, cols].sum()
    total = scored.sum() * FRAME
    return {
        "total": total,
        "confusion": (both.sum() - matched) * FRAME,
        "missed": (scored & (h < 0)).sum() * FRAME,
        "false_alarm": (keep & (r < 0) & (h >= 0)).sum() * FRAME,
        "ref_speakers": int(sum(1 for i in range(len(rl)) if (r[keep] == i).sum() * FRAME >= MIN_CLUSTER_TALK)),
        "hyp_speakers": int(sum(1 for i in range(len(hl)) if (h[keep] == i).sum() * FRAME >= MIN_CLUSTER_TALK)),
    }


def confusion_pct(*args, **kwargs) -> float:
    c = confusion(*args, **kwargs)
    return 100 * c["confusion"] / c["total"] if c["total"] else 0.0


# --- the engine -------------------------------------------------------------

DEFAULT_ENGINE = ROOT / "native" / ".build" / "release" / "palaver-engine"  # make engine
MODELS = Path.home() / "Library" / "Application Support" / "palaver" / "models" / "fluidaudio"  # the app's
IDLE_TIMEOUT = 600.0  # seconds without a line from the engine before it counts as hung


class EngineError(RuntimeError):
    pass


class Engine:
    """palaver-engine's JSON-lines protocol: ``{"id": n, "cmd": …, …args}`` in, lines out until the one with
    that id and "ok" (progress lines in between are skipped). Started on the first call."""

    def __init__(self, path: Path | None = None, models: Path | None = None) -> None:
        self._path = Path(path or DEFAULT_ENGINE)
        self._models = Path(models or MODELS)
        self._proc: subprocess.Popen | None = None
        self._lines: queue.Queue = queue.Queue()
        self._next_id = 0

    def _start(self) -> subprocess.Popen:
        try:
            proc = subprocess.Popen([str(self._path), "--models", str(self._models), "--version", "eval"],
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                    text=True, encoding="utf-8", errors="replace", bufsize=1)
        except OSError as exc:
            raise EngineError(f"the speech engine could not start ({self._path}): {exc}") from exc

        def read(stream, lines):
            for raw in stream:
                lines.put(raw)
            lines.put(None)

        self._lines = queue.Queue()
        threading.Thread(target=read, args=(proc.stdout, self._lines), daemon=True).start()
        self._proc = proc
        return proc

    def call(self, cmd: str, /, **args) -> dict:
        proc = self._proc if self._proc is not None and self._proc.poll() is None else self._start()
        self._next_id += 1
        rid = self._next_id
        try:
            proc.stdin.write(json.dumps({**args, "id": rid, "cmd": cmd}) + "\n")
            proc.stdin.flush()
        except OSError as exc:
            raise EngineError(f"the speech engine stopped: {exc}") from None
        while True:
            try:
                raw = self._lines.get(timeout=IDLE_TIMEOUT)
            except queue.Empty:
                raise EngineError(f"the speech engine stopped answering ({IDLE_TIMEOUT:g} s without a line)") from None
            if raw is None:
                raise EngineError(f"the speech engine died (exit {proc.wait()})")
            try:
                msg = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(msg, dict) or msg.get("id") not in (rid, -1) or "ok" not in msg:
                continue
            if msg["ok"]:
                return msg
            raise EngineError(str(msg.get("error", "unknown error")))

    def close(self) -> None:
        proc, self._proc = self._proc, None
        if proc is None:
            return
        if proc.poll() is None:
            try:
                proc.stdin.close()
            except OSError:
                pass
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()


# --- the meetings -----------------------------------------------------------

class Meeting:
    """The files of one recording folder the gate reads."""

    def __init__(self, folder: Path) -> None:
        self.folder = Path(folder)
        self.system_wav = self.folder / "system.wav"
        self.mic_wav = self.folder / "mic.wav"
        self.system_segments = self.folder / "system_segments.json"
        self.mic_segments = self.folder / "mic_segments.json"
        self.system_turns = self.folder / "system_turns.json"
        self.speaker_embeddings = self.folder / "speaker_embeddings.json"

    def _json(self, name: str, default):
        try:
            return json.loads((self.folder / name).read_text())
        except (OSError, ValueError):
            return default

    def speaker_names(self) -> dict[str, str]:
        """speakers.json: label → the name given by hand."""
        return {str(k): str(v) for k, v in self._json("speakers.json", {}).items()}

    def merges(self) -> dict[str, str]:
        """speakers_merged.json: label → the label it was merged into."""
        return {str(k): str(v) for k, v in self._json("speakers_merged.json", {}).items()}

    def ignored(self) -> set[str]:
        """speakers_ignored.json: labels removed as noise."""
        return set(self._json("speakers_ignored.json", []))


def reference_for(paths: Meeting):
    """(segments with person ids, ignored regions, {label: person}, {person: name}) of a
    meeting from its stored turns, the hand names, merges and ignored voices.
    Names stay in memory: callers use the person ids (P0…)."""
    turns = json.loads(paths.system_turns.read_text())
    hand, merges = paths.speaker_names(), paths.merges()
    ignored_labels = paths.ignored()
    pid = {n: f"P{i}" for i, n in enumerate(sorted(set(hand.values())))}
    segs, ignored, person_of = [], [], {}
    for t in turns:
        lab = t["speaker"]
        root = merges.get(lab, lab)
        if lab in ignored_labels or root in ignored_labels:
            ignored.append((t["start"], t["end"]))
            continue
        name = hand.get(root) or hand.get(lab)
        person = pid[name] if name else f"X{root}"
        person_of[lab] = (person, bool(name))
        segs.append((t["start"], t["end"], person))
    return segs, ignored, person_of


def wmean(pairs):
    def unit(v):
        v = np.asarray(v, float)
        return v / np.linalg.norm(v)
    return unit(sum(unit(v) * w for v, w in pairs))


def voice_cosines(paths, reply: dict) -> tuple[list[float], int]:
    """Cosines between stored and engine embeddings of each named speaker with
    ≥ MIN_TALK s, and how many such speakers had no engine label to compare."""
    segs, _, person_of = reference_for(paths)
    emb = json.loads(paths.speaker_embeddings.read_text())
    talk: collections.Counter = collections.Counter()
    stored: dict[str, list] = collections.defaultdict(list)
    label_talk: collections.Counter = collections.Counter()
    for t in json.loads(paths.system_turns.read_text()):
        if t["speaker"] in person_of:
            label_talk[t["speaker"]] += t["end"] - t["start"]
    for lab, (person, is_named) in person_of.items():
        if is_named and lab in emb:
            stored[person].append((emb[lab], label_talk[lab]))
            talk[person] += label_talk[lab]
    named = {p for p, sec in talk.items() if sec >= MIN_TALK}
    overlap: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    for t in reply["turns"]:
        for s, e, person in segs:
            o = min(t["end"], e) - max(t["start"], s)
            if o > 0:
                overlap[t["speaker"]][person] += o
    engine: dict[str, list] = collections.defaultdict(list)
    for lab, c in overlap.items():
        person, o = c.most_common(1)[0]
        if o >= OVERLAP_SHARE * sum(c.values()) and lab in reply["embeddings"]:
            engine[person].append((reply["embeddings"][lab], o))
    cos, unmatched = [], 0
    for p in sorted(named):
        if sum(w for _, w in engine.get(p, [])) < MIN_TALK:
            unmatched += 1
            continue
        cos.append(float(wmean(stored[p]) @ wmean(engine[p])))
    return cos, unmatched


# --- the gate ---------------------------------------------------------------

def check(name: str, ok: bool, detail: str) -> str:
    return f"| {name} | {'PASS' if ok else 'FAIL'} | {detail} |"


def segments_text(segments) -> str:
    return " ".join(s["text"] for s in segments)


def run_gate(cfg: dict, engine, meetings_root: Path, log=lambda *_: None) -> tuple[list[str], bool]:
    rows, passed = [], True
    gold = Path(cfg["gold_dir"]).expanduser()

    errors = words = 0
    per_clip = []
    for i, clip in enumerate(cfg["gold_clips"]):
        log(f"gold {i + 1}/{len(cfg['gold_clips'])}")
        reference = " ".join(l for l in (gold / f"{clip}.txt").read_text().splitlines() if not l.startswith("#"))
        hyp = segments_text(engine.call("transcribe", wav=str(gold / f"{clip}.wav"))["segments"])
        e, n = word_errors(reference, hyp)
        errors, words = errors + e, words + n
        per_clip.append(f"{100 * e / max(1, n):.1f}")
    wer = 100 * errors / max(1, words)
    base = float(cfg["baseline_gold_wer_mlx"])
    ok = wer <= base + WER_SLACK
    passed &= ok
    rows.append(check("gold WER", ok, f"engine {wer:.1f} % vs MLX {base:.1f} % (limit {base + WER_SLACK:.1f}), "
                                      f"{words} words, per clip {', '.join(per_clip)}"))

    lost_stored = lost_engine = 0
    for mid in cfg["asr_meetings"]:
        paths = Meeting(meetings_root / mid)
        for track, wav, seg in (("system", paths.system_wav, paths.system_segments),
                                ("mic", paths.mic_wav, paths.mic_segments)):
            log(f"asr {mid} {track}")
            stored = segments_text(json.loads(seg.read_text()))
            a, b = lost_passages(stored, segments_text(engine.call("transcribe", wav=str(wav))["segments"]))
            lost_stored, lost_engine = lost_stored + a, lost_engine + b
    ok = lost_stored <= LOST_FACTOR * lost_engine
    passed &= ok
    rows.append(check("lost passages", ok, f"words only in stored (engine lost) {lost_stored} vs only in engine "
                                           f"{lost_engine} (limit {LOST_FACTOR} x = {LOST_FACTOR * lost_engine:.0f}), "
                                           f"runs >= {RUN} words, {len(cfg['asr_meetings'])} meetings, both tracks"))

    replies: dict[str, dict] = {}

    def diarized(mid: str) -> dict:
        if mid not in replies:
            log(f"diarize {mid}")
            replies[mid] = engine.call("diarize", wav=str(Meeting(meetings_root / mid).system_wav))
        return replies[mid]

    for mid, base in cfg["diar_baseline_pyannote"].items():
        paths = Meeting(meetings_root / mid)
        segs, ignored, _ = reference_for(paths)
        hyp = [(t["start"], t["end"], t["speaker"]) for t in diarized(mid)["turns"]]
        c = confusion(segs, hyp, ignored)
        pct = 100 * c["confusion"] / c["total"]
        ok = pct <= base["confusion_pct"] + CONFUSION_SLACK
        passed &= ok
        rows.append(check(f"confusion {mid}", ok, f"engine {pct:.1f} % vs pyannote {base['confusion_pct']:.1f} % "
                                                  f"(limit {base['confusion_pct'] + CONFUSION_SLACK:.1f})"))
        if base["clusters"] == base["people"]:
            ok = abs(c["hyp_speakers"] - base["people"]) <= CLUSTER_SLACK
            passed &= ok
            rows.append(check(f"speakers {mid}", ok, f"engine {c['hyp_speakers']} vs {base['people']} people "
                                                     f"(pyannote exact, +/-{CLUSTER_SLACK})"))

    cosines, unmatched = [], 0
    for mid in cfg["voice_meetings"]:
        cos, miss = voice_cosines(Meeting(meetings_root / mid), diarized(mid))
        cosines += cos
        unmatched += miss
    below = sum(1 for c in cosines if c < COSINE_MIN)
    ok = below == 0 and bool(cosines)
    passed &= ok
    if cosines:
        detail = (f"min {min(cosines):.3f}, median {float(np.median(cosines)):.3f}, below {COSINE_MIN}: {below} of "
                  f"{len(cosines)} speakers in {len(cfg['voice_meetings'])} meetings; "
                  f"{unmatched} more had no engine speaker to compare (not gated)")
    else:
        detail = "no named speaker could be compared"
    rows.append(check("voice cosine", ok, detail))
    return rows, passed


def render(rows: list[str], passed: bool, title: str = "Engine gate") -> str:
    return "\n".join([f"# {title}", "", f"Result: {'PASS' if passed else 'FAIL'}", "",
                      "| check | result | numbers |", "|---|---|---|", *rows, ""])


def worker_engine(worker: Path, scratch: Path):
    """``Engine`` over ``worker engine-serve``: a one-line launcher in ``scratch`` stands in for the
    palaver-engine binary, so the same client (and its reply handling) talks to the worker."""
    launcher = scratch / "palaver-engine"
    launcher.write_text(f"#!/bin/sh\nexec {_sh_quote(str(worker))} engine-serve \"$@\"\n")
    launcher.chmod(launcher.stat().st_mode | stat.S_IXUSR)
    return Engine(path=launcher)


def _sh_quote(text: str) -> str:
    return "'" + text.replace("'", "'\\''") + "'"


def _worker_from(argv: list[str], env) -> Path | None:
    if "--worker" in argv:
        i = argv.index("--worker")
        if i + 1 < len(argv):
            return Path(argv[i + 1]).expanduser()
    return Path(env["PALAVER_EVAL_WORKER"]).expanduser() if env.get("PALAVER_EVAL_WORKER") else None


def main(argv: list[str] | None = None, env=None) -> int:
    env = os.environ if env is None else env
    folder = env.get("PALAVER_EVAL_DIR")
    cfg_path = Path(folder).expanduser() / "eval.json" if folder else None
    if cfg_path is None or not cfg_path.is_file():
        print("eval-engine needs PALAVER_EVAL_DIR: a folder with the local eval.json "
              "(gold clips, meeting ids, baselines). Not set up here.", file=sys.stderr)
        return 2
    worker = _worker_from(list(argv or []), env)
    if worker is not None and not worker.is_file():
        print(f"--worker {worker}: no such file (make eval-engine-worker builds it)", file=sys.stderr)
        return 2
    cfg = json.loads(cfg_path.read_text())
    with tempfile.TemporaryDirectory(prefix="eval-worker-") as scratch:
        engine = worker_engine(worker, Path(scratch)) if worker is not None else Engine()
        try:
            rows, passed = run_gate(cfg, engine, Path.home() / "Meetings" / "Recordings",
                                    log=lambda m: print(m, file=sys.stderr, flush=True))
        finally:
            engine.close()
    text = render(rows, passed, "Engine gate (palaver-worker engine-serve)" if worker is not None else "Engine gate")
    (cfg_path.parent / ("engine-gate-worker.md" if worker is not None else "engine-gate.md")).write_text(text)
    print(text)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
