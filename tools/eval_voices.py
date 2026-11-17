"""`make eval-voices`: how well the voice bank's ways of keeping and comparing voices work on your own recordings.

Re-embeds every speech turn of the local meetings with the engine (one vector per turn, `embed`), then answers,
from the meetings whose speakers you named:
  A. a person in two meetings vs two people: the diarizer's voice (speaker_embeddings.json) against voices built
     from the turns: all of them, only long ones, trimmed at speaker changes, outlier turns dropped;
  B. your own voice (the microphone, one person in many meetings): enrolled from N meetings, compared by the best
     sample (what the bank does) or by the samples' mean;
  C. keeping the newest samples or the most different ones, when only 5/10/20 may stay;
  D. the bank's rules replayed in time order at several thresholds: right, wrong, not recognized;
  E. two different names whose voices are at least MATCH_THRESHOLD alike (a mislabel, or two very alike voices),
     by meeting id and label, for you to look at.

The recordings are private, so this never runs in CI and prints NUMBERS ONLY: meetings by id, speakers by label, no
name, text or vector. Vectors stay in memory; nothing is written. Meetings with a shared room microphone
(speakers_shared.json) are left out.

  tools/memcap.sh 4 python3 tools/eval_voices.py [--recordings DIR] [--engine PATH]
"""
from __future__ import annotations

import argparse
import json
import os
import random
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

MATCH_THRESHOLD = 0.75  # Voices.MATCH_THRESHOLD
MATCH_MARGIN = 0.1  # Voices.MATCH_MARGIN
MIN_TALK_SECONDS = 10.0  # Voices.MIN_TALK_SECONDS
MIN_TURN = 0.8
TRIM = 0.25
MAX_MIC_TURNS = 80
CHUNK = 150
RESTART_RSS_KB = 2_000_000


def load(path: Path, default=None):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def unit(v):
    if v is None:
        return None
    v = np.asarray(v, float)
    n = np.linalg.norm(v)
    return v / n if n and np.all(np.isfinite(v)) else None


# ---------------------------------------------------------------- collecting

class Session:
    """One speaker in one meeting: the owner's microphone, or a diarized label of the system track."""

    def __init__(self, rec: str, track: str, label: str, name: str, stored):
        self.rec, self.track, self.label, self.name = rec, track, label, name
        self.stored = unit(stored)
        self.turns: list[tuple[float, np.ndarray]] = []  # (seconds, vector)
        self.trimmed: list[tuple[float, np.ndarray]] = []  # the same, 0.25 s cut off at both ends

    @property
    def talk(self) -> float:
        return sum(d for d, _ in self.turns)


def plan(recordings: Path):
    """(rec, track, wav, {key: [[start, end]]}) jobs, key → (session, seconds, trimmed), and the sessions."""
    jobs, keys, sessions = [], {}, {}
    rnd = random.Random(7)
    for folder in sorted(p for p in recordings.iterdir() if p.is_dir()):
        if (folder / "speakers_shared.json").exists():
            continue
        rec = folder.name
        turns = load(folder / "system_turns.json")
        if turns and (folder / "system.wav").exists():
            stored = load(folder / "speaker_embeddings.json", {}) or {}
            names = load(folder / "speakers.json", {}) or {}
            turns = sorted(turns, key=lambda t: t["start"])
            spans = {}
            for i, t in enumerate(turns):
                dur = t["end"] - t["start"]
                if dur < MIN_TURN:
                    continue
                label = t["speaker"]
                name = names.get(label)
                name = name.strip().casefold() if isinstance(name, str) else ""
                s = sessions.setdefault((rec, label), Session(rec, "system", label, name, stored.get(label)))
                key = f"{label}|{i}"
                spans[key] = [[t["start"], t["end"]]]
                keys[(rec, "s", key)] = (s, dur, False)
                if dur - 2 * TRIM >= MIN_TURN:
                    spans[key + "|t"] = [[t["start"] + TRIM, t["end"] - TRIM]]
                    keys[(rec, "s", key + "|t")] = (s, dur - 2 * TRIM, True)
            if spans:
                jobs.append((rec, "s", folder / "system.wav", spans))
        segs = load(folder / "mic_segments.json")
        if segs and (folder / "mic.wav").exists():
            cand = [x for x in segs if x["end"] - x["start"] >= MIN_TURN]
            rnd.shuffle(cand)
            s = sessions.setdefault((rec, "mic"), Session(rec, "mic", "mic", "@owner", None))
            spans = {}
            for i, x in enumerate(cand[:MAX_MIC_TURNS]):
                spans[f"m|{i}"] = [[x["start"], x["end"]]]
                keys[(rec, "m", f"m|{i}")] = (s, x["end"] - x["start"], False)
            if spans:
                jobs.append((rec, "m", folder / "mic.wav", spans))
    return jobs, keys, sessions


def rss_kb(pid: int) -> int:
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return int(out) if out else 0


class Engine:
    """palaver-engine over its JSON-lines protocol; restarted when it has grown (it keeps buffers per file)."""

    def __init__(self, path: str):
        self.path = path
        self.start()

    def start(self):
        self.p = subprocess.Popen([self.path], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True)
        self.n = 0

    def embed(self, wav: Path, spans: dict) -> dict:
        self.n += 1
        self.p.stdin.write(json.dumps({"id": self.n, "cmd": "embed", "wav": str(wav), "spans": spans}) + "\n")
        self.p.stdin.flush()
        while True:
            line = self.p.stdout.readline()
            if not line:
                raise SystemExit("the engine stopped (memory cap?)")
            reply = json.loads(line)
            if "progress" not in reply:
                break
        if rss_kb(self.p.pid) > RESTART_RSS_KB:
            self.close()
            self.start()
        if not reply.get("ok"):
            print(f"  embed failed: {str(reply.get('error'))[:100]}", file=sys.stderr)
            return {}
        return reply["embeddings"]

    def close(self):
        self.p.stdin.close()
        self.p.wait()


def collect(recordings: Path, engine_path: str):
    jobs, keys, sessions = plan(recordings)
    chunks = [(rec, tr, wav, dict(list(spans.items())[i:i + CHUNK]))
              for rec, tr, wav, spans in jobs for i in range(0, len(spans), CHUNK)]
    print(f"re-embedding {len(keys)} turns of {len({j[0] for j in jobs})} meetings ...", file=sys.stderr)
    engine, t0 = Engine(engine_path), time.time()
    for n, (rec, tr, wav, spans) in enumerate(chunks):
        for key, v in engine.embed(wav, spans).items():
            s, dur, trimmed = keys[(rec, tr, key)]
            v = np.asarray(v, float)
            if np.all(np.isfinite(v)):
                (s.trimmed if trimmed else s.turns).append((dur, v))
        if n % 50 == 49:
            print(f"  {n + 1}/{len(chunks)} {time.time() - t0:.0f}s", file=sys.stderr)
    engine.close()
    return [s for s in sessions.values() if s.talk >= MIN_TALK_SECONDS]


# ---------------------------------------------------------------- ways of building a voice

def wmean(items):
    if not items:
        return None
    w = np.array([d for d, _ in items])
    return unit((np.stack([v for _, v in items]) * w[:, None]).sum(0))


def robust(items, drop=0.2):
    m = wmean(items)
    if m is None or len(items) < 5:
        return m
    sims = np.array([unit(v) @ m for _, v in items])
    return wmean([it for it, x in zip(items, sims) if x >= np.quantile(sims, drop)])


VOICES = {
    "diarizer": lambda s: s.stored,
    "all turns": lambda s: wmean(s.turns),
    "turns>=2s": lambda s: wmean([t for t in s.turns if t[0] >= 2.0]),
    "trimmed": lambda s: wmean(s.trimmed) if s.track == "system" else wmean(s.turns),
    "no outliers": lambda s: robust(s.turns),
}


def eer(t, n) -> float:
    t, n = np.asarray(t), np.asarray(n)
    best = (2.0, 0.0)
    for x in np.unique(np.concatenate([t, n])):
        frr, far = (t < x).mean(), (n >= x).mean()
        best = min(best, (abs(frr - far), (frr + far) / 2))
    return best[1]


def pct(a, cond) -> str:
    return f"{np.mean(cond(np.asarray(a))):.0%}" if len(a) else "-"


# ---------------------------------------------------------------- the report

def report(sessions):
    rnd = random.Random(1)
    named = [s for s in sessions if s.track == "system" and s.name]
    system = [s for s in sessions if s.track == "system"]
    mine = sorted((s for s in sessions if s.track == "mic"), key=lambda s: s.rec)
    people = {s.name for s in named}
    repeat = sum(1 for p in people if len({s.rec for s in named if s.name == p}) > 1)
    print(f"named voices {len(named)} ({len(people)} people, {repeat} of them in more than one meeting); "
          f"unnamed {len(system) - len(named)}; your microphone in {len(mine)} meetings\n")

    print("A. One person in two meetings vs two people (similarity of the two voices)")
    print(f"   {'voice from':12} {'pairs':>5} {'same: median':>12} {'>=.75':>6} {'>=.65':>6} {'two people: 99%':>15} "
          f"{'EER':>6} | {'yours: median':>13} {'>=.75':>6} {'vs others 99%':>13} {'EER':>6}")
    for vname, f in VOICES.items():
        V = {id(s): f(s) for s in sessions}
        same, diff = [], []
        for i, a in enumerate(named):
            for b in named[i + 1:]:
                if a.rec != b.rec and V[id(a)] is not None and V[id(b)] is not None:
                    (same if a.name == b.name else diff).append(float(V[id(a)] @ V[id(b)]))
        mv = [V[id(s)] for s in mine if V[id(s)] is not None]
        ov = [V[id(s)] for s in system if V[id(s)] is not None]
        ms = [float(mv[i] @ mv[j]) for i in range(len(mv)) for j in range(i + 1, len(mv))]
        md = list((np.stack(mv) @ np.stack(ov).T).ravel()) if mv and ov else []
        left = (f"   {vname:12} {len(same):5} {np.median(same):12.2f} {pct(same, lambda a: a >= .75):>6} "
                f"{pct(same, lambda a: a >= .65):>6} {np.quantile(diff, .99):15.2f} {eer(same, diff):6.1%}"
                if same and diff else f"   {vname:12} {'-':>5}")
        right = (f" | {np.median(ms):13.2f} {pct(ms, lambda a: a >= .75):>6} {np.quantile(md, .99):13.2f} "
                 f"{eer(ms, md):6.1%}" if ms and md else " | -")
        print(left + right)

    mv = [v for v in (wmean(s.turns) for s in mine) if v is not None]
    ov = np.stack([v for v in (wmean(s.turns) for s in system) if v is not None]) if system else None
    if len(mv) >= 3 and ov is not None:
        print(f"\nB. Your voice enrolled from N meetings, tested on another ({len(ov)} other voices as impostors)")
        print(f"   {'N':>3} | {'best sample: median':>19} {'missed':>6} {'EER':>6} | {'mean: median':>12} {'missed':>6} {'EER':>6}"
              "   (missed: below MATCH_THRESHOLD)")
        for N in (1, 2, 3, 5, 10, 20, 40):
            if N + 1 > len(mv):
                break
            res = {"max": [[], []], "mean": [[], []]}
            for _ in range(150):
                idx = rnd.sample(range(len(mv)), N + 1)
                enr, test = np.stack([mv[i] for i in idx[:N]]), mv[idx[N]]
                imp = ov[rnd.sample(range(len(ov)), min(40, len(ov)))]
                res["max"][0].append(float((enr @ test).max()))
                res["max"][1] += list((imp @ enr.T).max(1))
                c = unit(enr.mean(0))
                res["mean"][0].append(float(c @ test))
                res["mean"][1] += list(imp @ c)
            row = f"   {N:3} |"
            for k in ("max", "mean"):
                t, n = res[k]
                row += f" {np.median(t):{19 if k == 'max' else 12}.2f} {pct(t, lambda a: a < MATCH_THRESHOLD):>6} {eer(t, n):6.1%} |"
            print(row)

        print("\nC. Only CAP of your meetings kept: the newest, or the most different (the most alike one goes); "
              "tested on the next 5")

        def diverse(pool, cap):
            keep = list(pool)
            while len(keep) > cap:
                G = np.stack(keep) @ np.stack(keep).T
                np.fill_diagonal(G, -1)
                i, j = np.unravel_index(np.argmax(G), G.shape)
                keep.pop(min(i, j))
            return keep

        for cap in (5, 10, 20):
            out = {"newest": [], "different": []}
            for start in range(cap + 5, len(mv) - 1):
                for pol, kept in (("newest", mv[:start][-cap:]), ("different", diverse(mv[:start], cap))):
                    E = np.stack(kept)
                    out[pol] += [float((E @ t).max()) for t in mv[start:start + 5]]
            if out["newest"]:
                print("   " + "   ".join(f"cap {cap:2} {pol}: median {np.median(v):.2f}, missed "
                                          f"{pct(v, lambda a: a < MATCH_THRESHOLD)}" for pol, v in out.items()))

    both = [s for s in named if s.stored is not None and wmean(s.turns) is not None]  # the same voices for both
    print(f"\nD. The bank's rules replayed in time order (best sample, margin 0.1, newest 20 kept; {len(both)} voices with both)")
    print("   right: named as who it was; wrong: named as someone else; missed: known, not named; "
          "new: first meeting with that person")
    for vname in ("diarizer", "all turns"):
        V = {id(s): VOICES[vname](s) for s in both}
        for thr in (0.75, 0.70, 0.65, 0.60):
            bank, out = {}, {"right": 0, "wrong": 0, "missed": 0, "new": 0}
            for rec in sorted({s.rec for s in both}):
                here = [s for s in both if s.rec == rec]
                for s in here:
                    known = s.name in bank
                    out["new"] += not known
                    if not bank:
                        continue
                    sc = sorted(((max(float(x @ V[id(s)]) for x in xs), n) for n, xs in bank.items()), reverse=True)
                    hit = sc[0][0] >= thr and (len(sc) == 1 or sc[0][0] - sc[1][0] >= MATCH_MARGIN)
                    if hit:
                        out["right" if sc[0][1] == s.name else "wrong"] += 1
                    elif known:
                        out["missed"] += 1
                for s in here:
                    bank[s.name] = (bank.get(s.name, []) + [V[id(s)]])[-20:]
            print(f"   {vname:10} threshold {thr:.2f}: " + ", ".join(f"{k} {v}" for k, v in out.items()))

    print(f"\nE. Different names, voices at least {MATCH_THRESHOLD} alike (all turns): a mislabel, or two very alike voices")
    V = {id(s): wmean(s.turns) for s in named}
    found = 0
    for i, a in enumerate(named):
        for b in named[i + 1:]:
            if a.name != b.name and V[id(a)] is not None and V[id(b)] is not None:
                x = float(V[id(a)] @ V[id(b)])
                if x >= MATCH_THRESHOLD:
                    found += 1
                    print(f"   {x:.2f}  {a.rec} {a.label}  ~  {b.rec} {b.label}")
    if not found:
        print("   none")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--recordings", default=os.path.expanduser("~/Meetings/Recordings"))
    ap.add_argument("--engine", default=os.environ.get(
        "PALAVER_ENGINE", os.path.expanduser("~/Applications/Palaver.app/Contents/MacOS/palaver-engine")))
    args = ap.parse_args()
    if not Path(args.engine).exists():
        sys.exit(f"no engine at {args.engine} (--engine PATH)")
    report(collect(Path(args.recordings), args.engine))


if __name__ == "__main__":
    main()
