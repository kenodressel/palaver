"""How much speaker echo reaches the mic transcript (#25).

    python tools/echo_bench.py FOLDER... --out DIR [--variant NAME]...
        [--near CLEAN.wav --near-at S --near-gain DB] [--start S --seconds N]

Each FOLDER holds ``mic_raw.wav`` and ``system.wav`` (16 kHz). For every
variant of the echo canceller the bench runs it on the folder, transcribes
the result with the pipeline's transcriber and reports, per case:

- echo words: mic words before and after the pipeline's filters
  (``drop_silent_segments``, ``drop_bleed_duplicates``, ``drop_echo``); with
  ``--near`` only the words that are not the near-end speech;
- near-end recall: with ``--near``, a clean clip of the user's speech is
  mixed into ``mic_raw.wav`` at ``--near-at`` (double talk), and recall is
  the share of its words (as transcribed from the clip alone) that survive
  into the filtered mic transcript;
- residual echo per 10 s while the far end talks: the cancelled mic's level,
  how much quieter it is than the raw mic, and its correlation with the far
  end (the peak of the normalized cross-correlation over 0-100 ms of lag).

Numbers only: transcripts stay in ``DIR`` and never reach ``report.json``
or the output. The transcriber is cached per case and variant, so a rerun
only transcribes what changed.
"""

from __future__ import annotations

import argparse
import difflib
import json
import sys
import time
from pathlib import Path

import numpy as np
import soundfile as sf

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from palaver import aec  # noqa: E402
from palaver.bench import tokens  # noqa: E402
from palaver.cleanup import (  # noqa: E402
    MIC_MIN_PEAK_DBFS,
    _aligned_words,
    _norm,
    SYSTEM_MIN_PEAK_DBFS,
    drop_bleed_duplicates,
    drop_echo,
    drop_silent_segments,
)
from palaver.models import Segment  # noqa: E402

SR = aec.SAMPLE_RATE
WINDOW_SECONDS = 10.0
FAR_ACTIVE_DBFS = -50.0
MAX_LAG_MS = 100


def _variants() -> dict:
    """name -> (mic_raw, system) -> cancelled mic, all int16."""

    def plain(mic, far):
        return _run_aec(mic, far)

    out = {"aec": plain, "aec-nolead": lambda mic, far: _run_aec(mic, far, -aec.MIC_LEAD_MS)}
    for ms in (5, 10):
        out[f"aec-lead+{ms}"] = lambda mic, far, ms=ms: _run_aec(mic, far, ms)
    if hasattr(aec, "suppress_residual"):
        out["aec+gate"] = lambda mic, far: aec.suppress_residual(_run_aec(mic, far), far)
    return out


def _run_aec(mic: np.ndarray, far: np.ndarray, lead_ms: int = 0) -> np.ndarray:
    """``lead_ms``: delay the mic by this much more than ``aec.MIC_LEAD_MS``
    before the canceller (negative: less), and back after."""
    k, z = lead_ms * SR // 1000, np.zeros(abs(lead_ms) * SR // 1000, dtype=np.int16)
    if k:
        mic = np.concatenate([z, mic[:-k]]) if k > 0 else np.concatenate([mic[-k:], z])
    stream = aec.AecStream()
    try:
        out = stream.process(mic, far)
    finally:
        stream.close()
    out = np.concatenate([out, np.zeros(len(mic) - len(out), dtype=np.int16)])
    if k:
        out = np.concatenate([out[k:], z]) if k > 0 else np.concatenate([z, out[:k]])
    return out


def _read(path: Path) -> np.ndarray:
    data, sr = sf.read(str(path), dtype="int16", always_2d=True)
    if sr != SR:
        raise SystemExit(f"{path} is {sr} Hz, expected {SR}")
    return np.ascontiguousarray(data[:, 0])


def _db(x: np.ndarray) -> float:
    return float(10 * np.log10(np.mean((x.astype(np.float64) / 32768) ** 2) + 1e-12))


def xcorr_peak(a: np.ndarray, b: np.ndarray, max_lag: int) -> tuple[float, int]:
    """(peak |normalized cross-correlation|, its lag in samples), lag > 0: ``a`` lags ``b``."""
    a = a.astype(np.float64) - a.mean()
    b = b.astype(np.float64) - b.mean()
    norm = np.sqrt((a**2).sum() * (b**2).sum())
    if norm == 0:
        return 0.0, 0
    n = 1 << int(np.ceil(np.log2(len(a) + len(b))))
    c = np.fft.irfft(np.fft.rfft(a, n) * np.conj(np.fft.rfft(b, n)), n)
    lags = np.r_[np.arange(0, max_lag + 1), np.arange(-max_lag // 5, 0)]
    vals = np.abs(c[lags]) / norm
    k = int(np.argmax(vals))
    return float(vals[k]), int(lags[k])


def residual(raw: np.ndarray, out: np.ndarray, far: np.ndarray, t0: float = 0.0) -> list[dict]:
    """Per window where the far end talks: levels, reduction and correlation with the far end."""
    win, frame = int(WINDOW_SECONDS * SR), SR // 50
    rows = []
    for s in range(0, min(len(raw), len(out), len(far)) - win + 1, win):
        f = far[s : s + win]
        n = win // frame
        active = np.array([_db(f[k * frame : (k + 1) * frame]) > FAR_ACTIVE_DBFS for k in range(n)])
        if active.mean() < 0.3:
            continue
        mask = np.repeat(active, frame)
        r, o = raw[s : s + win][mask], out[s : s + win][mask]
        corr_out, _ = xcorr_peak(out[s : s + win], f, MAX_LAG_MS * SR // 1000)
        corr_raw, lag = xcorr_peak(raw[s : s + win], f, MAX_LAG_MS * SR // 1000)
        rows.append({
            "t": round(t0 + s / SR, 1),
            "far_active": round(float(active.mean()), 2),
            "raw_dbfs": round(_db(r), 1),
            "out_dbfs": round(_db(o), 1),
            "removed_db": round(_db(r) - _db(o), 1),
            "corr_raw": round(corr_raw, 3),
            "corr_out": round(corr_out, 3),
            "delay_ms": round(lag * 1000 / SR, 2),
        })
    return rows


def _transcriber():
    import mlx.core as mx

    from palaver.dictionary import Dictionary
    from palaver.live import MLX_CACHE_LIMIT
    from palaver.transcriber import make_transcriber

    mx.set_cache_limit(MLX_CACHE_LIMIT)
    return make_transcriber("parakeet-mlx", whisper_repo="", dictionary=Dictionary(), language="auto")


class Cache:
    """Transcripts by wav, so reruns only transcribe changed audio."""

    def __init__(self):
        self._t = None

    def segments(self, wav: Path) -> list[Segment]:
        cached = wav.with_suffix(".segments.json")
        if cached.exists() and cached.stat().st_mtime >= wav.stat().st_mtime:
            return [Segment.from_dict(d) for d in json.loads(cached.read_text())]
        if self._t is None:
            self._t = _transcriber()
        segs = [s for s in self._t.transcribe(wav) if s.text.strip()]
        cached.write_text(json.dumps([s.to_dict() for s in segs]))
        return segs


def _write_if_changed(path: Path, audio: np.ndarray) -> None:
    if path.exists() and np.array_equal(_read(path), audio):
        return
    sf.write(str(path), audio, SR, subtype="PCM_16")


def _words(segs: list[Segment], lo: float = -1e9, hi: float = 1e9) -> list[str]:
    return [t for s in segs for w in s.words if lo <= w.start < hi for t in tokens(w.text)]


def matched(ref: list[str], hyp: list[str]) -> int:
    """Reference words found, in order, in ``hyp``."""
    m = difflib.SequenceMatcher(None, ref, hyp, autojunk=False)
    return sum(b.size for b in m.get_matching_blocks())


def run_case(folder: Path, near: str | None, out: Path, args, cache: Cache, variants: dict) -> dict:
    tag = f"+{Path(near).stem}@{args.near_at:g}{args.near_gain:+g}dB" if near else ""
    case = out / (folder.name + tag)
    case.mkdir(parents=True, exist_ok=True)
    mic, far = _read(folder / "mic_raw.wav"), _read(folder / "system.wav")
    n = min(len(mic), len(far))
    a = int(args.start * SR)
    b = n if args.seconds is None else min(n, a + int(args.seconds * SR))
    mic, far = mic[a:b].copy(), far[a:b]
    near_span = None
    if near:
        clean = _read(Path(near)).astype(np.float64) * 10 ** (args.near_gain / 20)
        at = int(args.near_at * SR)
        clean = clean[: max(0, len(mic) - at)]
        mic = np.clip(mic.astype(np.float64) + np.pad(clean, (at, len(mic) - at - len(clean))),
                      -32768, 32767).astype(np.int16)
        near_span = (args.near_at, args.near_at + len(clean) / SR)
    _write_if_changed(case / "mic_raw.wav", mic)
    _write_if_changed(case / "system.wav", far)
    sys_segs = drop_silent_segments(cache.segments(case / "system.wav"), case / "system.wav",
                                    SYSTEM_MIN_PEAK_DBFS)
    remote = [w for s in sys_segs for w in s.words if _norm(w.text)]
    ref = None
    if near:
        ref_wav = out / ("near-" + Path(near).stem + ".wav")
        _write_if_changed(ref_wav, _read(Path(near)))
        ref = _words(cache.segments(ref_wav))

    result = {"case": case.name, "seconds": round(len(mic) / SR, 1), "variants": {}}
    for name, fn in variants.items():
        vdir = case / name
        vdir.mkdir(exist_ok=True)
        t = time.monotonic()
        cancelled = fn(mic, far)
        took = time.monotonic() - t
        _write_if_changed(vdir / "mic.wav", cancelled)
        segs = cache.segments(vdir / "mic.wav")
        kept = drop_silent_segments(segs, vdir / "mic.wav", MIC_MIN_PEAK_DBFS)
        kept = drop_bleed_duplicates(kept, sys_segs)
        kept = drop_echo(kept, sys_segs, vdir / "mic.wav", case / "mic_raw.wav")
        rows = residual(mic, cancelled, far, args.start)
        v = {
            "process_s": round(took, 1),
            "mic_words": len(_words(segs)),
            "mic_segments": len(segs),
            "kept_words": len(_words(kept)),
            "kept_segments": len(kept),
            # Mic words that are remote words said at the same moment: echo
            # by its words, the measure for calls without ground truth.
            "aligned_words": sum(_aligned_words(s, remote)[1] for s in segs),
            "aligned_words_kept": sum(_aligned_words(s, remote)[1] for s in kept),
            "residual": _summary(rows),
        }
        if ref is not None:
            lo, hi = near_span[0] - 1, near_span[1] + 1
            found, found_all = matched(ref, _words(kept, lo, hi)), matched(ref, _words(segs, lo, hi))
            v.update({
                "near_words": len(ref),
                "near_recall_before_filter": round(found_all / max(1, len(ref)), 3),
                "near_recall": round(found / max(1, len(ref)), 3),
                # Everything on the mic that is not the user's clip.
                "echo_words": v["mic_words"] - found_all,
                "echo_words_kept": v["kept_words"] - found,
            })
        else:
            v.update({"echo_words": v["mic_words"], "echo_words_kept": v["kept_words"]})
        (vdir / "residual.json").write_text(json.dumps(rows, indent=1))
        result["variants"][name] = v
    return result


def _summary(rows: list[dict]) -> dict:
    if not rows:
        return {}
    col = lambda k: np.array([r[k] for r in rows])  # noqa: E731
    return {
        "windows": len(rows),
        "out_dbfs_median": round(float(np.median(col("out_dbfs"))), 1),
        "removed_db_median": round(float(np.median(col("removed_db"))), 1),
        "removed_db_p10": round(float(np.percentile(col("removed_db"), 10)), 1),
        "corr_out_median": round(float(np.median(col("corr_out"))), 3),
        "corr_out_max": round(float(col("corr_out").max()), 3),
        "delay_ms_range": [float(col("delay_ms").min()), float(col("delay_ms").max())],
    }


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("folders", nargs="+", type=Path)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--variant", action="append", help="default: all")
    p.add_argument("--near", action="append",
                   help="clean near-end speech (16 kHz WAV) to mix in, one case each")
    p.add_argument("--near-at", type=float, default=0.0, help="seconds into the (sliced) case")
    p.add_argument("--near-gain", type=float, default=0.0, help="dB")
    p.add_argument("--extra", type=Path,
                   help="a Python file whose VARIANTS dict (name -> fn(mic_raw, system, run_aec)) adds variants")
    p.add_argument("--start", type=float, default=0.0)
    p.add_argument("--seconds", type=float)
    args = p.parse_args(argv)
    variants = _variants()
    if args.extra:
        import runpy

        for name, fn in runpy.run_path(str(args.extra))["VARIANTS"].items():
            variants[name] = lambda mic, far, fn=fn: fn(mic, far, _run_aec)
    if args.variant:
        variants = {k: variants[k] for k in args.variant}
    args.out.mkdir(parents=True, exist_ok=True)
    cache = Cache()
    results = [run_case(f.expanduser(), near, args.out, args, cache, variants)
               for f in args.folders for near in (args.near or [None])]
    report = args.out / "report.json"
    old = json.loads(report.read_text()) if report.exists() else {}
    old.update({r["case"]: r for r in results})
    report.write_text(json.dumps(old, indent=1))
    for r in results:
        for name, v in r["variants"].items():
            res = v["residual"]
            line = (f"{r['case']:<44} {name:<10} echo words {v['echo_words']:>4} -> {v['echo_words_kept']:>4} "
                    f"aligned {v['aligned_words']:>4} -> {v['aligned_words_kept']:>3} "
                    f"| removed {res.get('removed_db_median', '-')} dB (p10 {res.get('removed_db_p10', '-')}) "
                    f"corr {res.get('corr_out_median', '-')}/{res.get('corr_out_max', '-')}")
            if "near_recall" in v:
                line += f" | near recall {v['near_recall_before_filter']} -> {v['near_recall']} of {v['near_words']}"
            print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
