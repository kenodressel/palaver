"""Our transcripts against another transcriber's, e.g. Notion AI meeting
notes of the same call (issue #36).

There is no ground truth, so this measures where the two disagree and on
what: word-level agreement, passages only one side has, how each spells
the names the app knows (calendar attendees, projects, glossary), rare
words only one side has, and text in scripts nobody spoke (hallucinations).
The passages where they disagree most are listed with both versions, as
the clips to listen to for a gold standard.

`palaver bench DIR` reads ``DIR/notion/<meeting id>*.txt`` (one
or more transcripts per meeting) and writes ``DIR/report.md``.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .paths import RecordingPaths

# A passage only one side has: this many words in a row.
GAP_WORDS = 12
# The windows (of our timeline) with the most disagreement.
HOTSPOT_SECONDS = 120.0
HOTSPOTS_PER_MEETING = 2
_FILLERS = {"äh", "ähm", "öhm", "hm", "hmm", "mhm", "mm", "uh", "uhm", "erm"}  # not "um" or "eh": German words
_NOT_LATIN = re.compile(r"[Ѐ-ӿ֐-ۿ฀-๿぀-ヿ㐀-鿿가-힯]")


def tokens(text: str) -> list[str]:
    """Words to compare: lower case, no punctuation or fillers, "1.040" = "1040"."""
    text = re.sub(r"(?<=\d)[.,](?=\d{3}\b)", "", text.casefold())
    words = re.findall(r"[^\W_]+(?:['’-][^\W_]+)*", text)
    return [w for w in words if w not in _FILLERS]


@dataclass
class Side:
    words: list[str]
    times: list[float] = field(default_factory=list)  # ours only: when each word was said (approx.)


def _ours(lines: list[tuple[float, float, str, str]]) -> Side:
    """(start, end, speaker, text) → words with times spread over each line."""
    words, times = [], []
    for start, end, _speaker, text in lines:
        ws = tokens(text)
        for k, w in enumerate(ws):
            words.append(w)
            times.append(start + (end - start) * k / max(1, len(ws)))
    return Side(words, times)


def compare(lines: list[tuple[float, float, str, str]], other: str, *, known: list[str],
            minutes: float) -> dict[str, Any]:
    """Our readable lines against ``other``'s plain text."""
    from rapidfuzz.distance import Levenshtein

    from .glossary import is_rare

    ours, theirs = _ours(lines), Side(tokens(other))
    a, b = ours.words, theirs.words
    ops = Levenshtein.opcodes(a, b)
    edits = sum(max(o.src_end - o.src_start, o.dest_end - o.dest_start) for o in ops if o.tag != "equal")
    same = sum(o.src_end - o.src_start for o in ops if o.tag == "equal")

    def gaps(only: str) -> list[dict[str, Any]]:
        out = []
        for o in ops:
            n = (o.src_end - o.src_start) if only == "ours" else (o.dest_end - o.dest_start)
            if o.tag in ("delete", "replace") if only == "ours" else o.tag in ("insert", "replace"):
                if n >= GAP_WORDS and (o.tag != "replace" or n >= 3 * max(1, (o.dest_end - o.dest_start)
                                                                             if only == "ours" else (o.src_end - o.src_start))):
                    words = a[o.src_start:o.src_end] if only == "ours" else b[o.dest_start:o.dest_end]
                    at = ours.times[min(o.src_start, len(ours.times) - 1)] if ours.times else 0.0
                    out.append({"at": at, "words": len(words), "text": " ".join(words)})
        return sorted(out, key=lambda g: -g["words"])

    # Known spellings: how often each side writes them exactly.
    names = []
    for term in sorted({k for k in known if len(k) >= 3}, key=str.casefold):
        t = tokens(term)
        if not t:
            continue
        n_a, n_b = _count(a, t), _count(b, t)
        if n_a or n_b:
            names.append({"term": term, "ours": n_a, "notion": n_b})

    rare_a = {w for w in set(a) if len(w) >= 4 and is_rare(w)}
    rare_b = {w for w in set(b) if len(w) >= 4 and is_rare(w)}

    # Where our timeline disagrees most.
    bad = [0] * len(a)
    for o in ops:
        if o.tag in ("replace", "delete"):
            for i in range(o.src_start, o.src_end):
                bad[i] = 1
        elif o.tag == "insert" and o.src_start < len(bad):
            bad[o.src_start] += o.dest_end - o.dest_start
    hotspots = []
    if ours.times:
        end = ours.times[-1]
        t = 0.0
        while t < end:
            idx = [i for i, x in enumerate(ours.times) if t <= x < t + HOTSPOT_SECONDS]
            if len(idx) >= 40:
                rate = sum(bad[i] for i in idx) / len(idx)
                hotspots.append((rate, t, idx[0], idx[-1] + 1))
            t += HOTSPOT_SECONDS / 2
    hotspots.sort(reverse=True)
    picked = []
    for rate, t, i0, i1 in hotspots:
        if all(abs(t - p["at"]) >= HOTSPOT_SECONDS for p in picked):
            j0, j1 = _map(ops, i0), _map(ops, i1)
            picked.append({"at": t, "disagreement": round(rate, 2), "ours": " ".join(a[i0:i1]),
                           "notion": " ".join(b[j0:j1])})
        if len(picked) == HOTSPOTS_PER_MEETING:
            break

    only_a, only_b = gaps("ours"), gaps("notion")
    covered = max(len(a) - sum(g["words"] for g in only_a), len(b) - sum(g["words"] for g in only_b))
    return {
        "minutes": round(minutes, 1),
        "words": {"ours": len(a), "notion": len(b)},
        "per_minute": {"ours": round(len(a) / minutes) if minutes else None,
                       "notion": round(len(b) / minutes) if minutes else None},
        "agreement": round(same / max(1, max(len(a), len(b))), 3),
        # Leaving out what only one side recorded (a later start, a call that ran on).
        "agreement_shared": round(same / max(1, covered), 3),
        "edits_per_notion_word": round(edits / max(1, len(b)), 3),
        "only_ours": only_a, "only_notion": only_b,
        "names": names,
        "rare_only_ours": sorted(rare_a - rare_b), "rare_only_notion": sorted(rare_b - rare_a),
        "not_latin": {"ours": len(_NOT_LATIN.findall(" ".join(t for *_, t in lines))),
                      "notion": len(_NOT_LATIN.findall(other))},
        "hotspots": picked,
    }


def _count(words: list[str], phrase: list[str]) -> int:
    n = len(phrase)
    return sum(words[i:i + n] == phrase for i in range(len(words) - n + 1))


def _map(ops, i: int) -> int:
    """The position in the other text that our word ``i`` lines up with."""
    for o in ops:
        if o.src_start <= i < o.src_end or (o.src_start == o.src_end == i):
            if o.tag == "equal":
                return o.dest_start + (i - o.src_start)
            return o.dest_start
    return ops[-1].dest_end if ops else 0


def _clock(seconds: float) -> str:
    s = int(seconds)
    return f"{s // 60}:{s % 60:02d}"


def _lines(paths: RecordingPaths) -> list[tuple[float, float, str, str]]:
    from .models import Utterance
    from .readable import readable

    utterances = [Utterance.from_dict(d) for d in json.loads(paths.transcript_json.read_text())]
    return [(u.start, u.end, u.speaker, u.text) for u in readable(utterances)]


def _known(paths: RecordingPaths) -> list[str]:
    from . import calendar_events, glossary, projects

    known = [t["term"] for t in glossary.Glossary().terms().values()]
    known += [p["name"] for p in projects.ProjectStore().projects().values()]
    event = calendar_events.load(paths)
    if event:
        for a in event.attendees:
            if not a.is_room:
                known += [a.name, *a.name.split()]
    return known


def run(bench_dir: Path, output_dir: Path) -> str:
    """Compare every meeting with a transcript in ``bench_dir/notion``;
    write and return the report."""
    results = {}
    for f in sorted((bench_dir / "notion").glob("*.txt")):
        meeting = f.stem.split(".")[0]
        paths = RecordingPaths(output_dir / meeting)
        if not paths.transcript_json.exists():
            continue
        meta = json.loads(paths.meta.read_text())
        results[f.stem] = (meeting, compare(_lines(paths), f.read_text(), known=_known(paths),
                                            minutes=float(meta.get("duration_seconds", 0)) / 60))
    report = render(results, output_dir)
    (bench_dir / "report.md").write_text(report)
    (bench_dir / "results.json").write_text(json.dumps({k: v[1] for k, v in results.items()}, indent=2,
                                                       ensure_ascii=False))
    return report


def render(results: dict[str, tuple[str, dict[str, Any]]], output_dir: Path) -> str:
    from . import calendar_events

    def title(meeting: str) -> str:
        event = calendar_events.load(RecordingPaths(output_dir / meeting))
        return event.title if event else meeting

    out = ["# Our transcripts vs. Notion AI meeting notes", "",
           "Same calls, recorded by both. No ground truth: this is where they disagree.", "",
           "| Meeting | min | words ours / Notion | words/min | agree | agree where both | only ours | only Notion |"
           " names ours / Notion |",
           "|---|---|---|---|---|---|---|---|---|"]
    for key, (meeting, r) in results.items():
        hits_a = sum(n["ours"] for n in r["names"])
        hits_b = sum(n["notion"] for n in r["names"])
        out.append(f"| {title(meeting)} ({key}) | {r['minutes']} | {r['words']['ours']} / {r['words']['notion']} | "
                   f"{r['per_minute']['ours']} / {r['per_minute']['notion']} | {round(100 * r['agreement'])} % | "
                   f"{round(100 * r['agreement_shared'])} % | "
                   f"{sum(g['words'] for g in r['only_ours'])} | {sum(g['words'] for g in r['only_notion'])} | "
                   f"{hits_a} / {hits_b} |")
    out.append("")
    for key, (meeting, r) in results.items():
        out += [f"## {title(meeting)} ({key})", ""]
        if r["names"]:
            out += ["Known names and terms, exact spellings:", "", "| term | ours | Notion |", "|---|---|---|"]
            out += [f"| {n['term']} | {n['ours']} | {n['notion']} |" for n in r["names"]]
            out.append("")
        out.append(f"Rare words only in ours: {', '.join(r['rare_only_ours'][:25]) or '—'}")
        out.append("")
        out.append(f"Rare words only in Notion: {', '.join(r['rare_only_notion'][:25]) or '—'}")
        out.append("")
        if r["not_latin"]["ours"] or r["not_latin"]["notion"]:
            out += [f"Characters in other scripts (hallucinations): ours {r['not_latin']['ours']}, "
                    f"Notion {r['not_latin']['notion']}", ""]
        for side, label in (("only_ours", "Only in ours"), ("only_notion", "Only in Notion")):
            for g in r[side][:2]:
                out += [f"**{label}** (~{_clock(g['at'])}, {g['words']} words): {g['text'][:400]}", ""]
        for h in r["hotspots"]:
            out += [f"**Most disagreement** at {_clock(h['at'])}–{_clock(h['at'] + HOTSPOT_SECONDS)} "
                    f"({round(100 * h['disagreement'])} % of our words differ):", "",
                    f"- ours: {h['ours'][:600]}", f"- Notion: {h['notion'][:600]}", ""]
    return "\n".join(out).rstrip() + "\n"
