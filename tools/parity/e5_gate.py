"""The e5 gate (phase 3, Task 34): the Swift encoder (``palaver-parity e5-encode``) against palaver.embeddings on the
real multilingual-e5-small, on 200 texts: the parity corpus's (fictional) transcript texts and fixed sentences, never
real meeting text.

    tools/memcap.sh 2 uv run --extra dev python tools/parity/e5_gate.py [--release]

``--release`` runs ``native/.build/release/palaver-parity`` (``swift build -c release --product palaver-parity``)
instead of the debug build, to measure the encoder's speed as the app runs it.

Needs ``make parity-helper`` (or the release build) and the model in the Hugging Face cache at the pinned revision (read where it is, never
downloaded or copied). Prints how many texts' SentencePiece ids differ and the min, mean and max cosine between
Python's and Swift's vectors (passages and queries) — never a text or a vector.

Exit 0: passed (equal ids, min cosine >= 0.999); 1: missed; 2: not run (no model, no helper, a side failed).
"""

from __future__ import annotations

import json
import math
import os
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:  # run as a script
    sys.path.insert(0, str(ROOT))

from tools.parity import corpus, ops  # noqa: E402

PARITY_BIN = ROOT / "native" / ".build" / ("release" if "--release" in sys.argv[1:] else "debug") / "palaver-parity"
COUNT = 200
MIN_COSINE = 0.999
NOW = datetime(2026, 11, 4, 9, 0, tzinfo=ZoneInfo("Europe/Berlin"))

FIXED = [
    "", " ", "Kosten", "pricing", "Was kostet das Angebot für Contoso?", "What did we decide about the test phase?",
    "Timo Strauß stellt den Plan für den Northwind-Rollout vor.", "Valerie fragt nach dem Budget für das nächste Quartal.",
    "Wir müssen noch über die Kosten für das Angebot reden.", "Let's move the kickoff with Contoso to Monday.",
    "Ähm, also ÖNW-Projekt — 120.000 € inkl. Lizenzen!!  Doppelt  Leerzeichen\nneue Zeile",
    "Straße naïve café façade", "STRASSE strasse Straße STRAẞE", "日本語のテキスト", "emoji 🎉 test 👩‍💻 👍🏽",
    "Die Zahlen: ٣٤ (arabisch), ४२ (Devanagari), 42.", "ﬁnance ſtrauß ｆｕｌｌｗｉｄｔｈ", "tabs\tand nbsp　ideographic",
    "Uh-huh, yeah, mmm, the Northwind deal closes Q3.", "Nächste Schritte: Timo schickt das Angebot, Valerie prüft die Lizenzen.",
    "Das Release verschiebt sich auf März, weil die Freigabe fehlt.", "The migration to the new cluster is done; latency is down 30 %.",
    "Wer übernimmt das Protokoll für die Retrospektive?", "Can you share the slides after the call?",
    "Der Kunde möchte eine Demo der Suchfunktion sehen.", "We agreed to drop the old export format by the end of the year.",
    "Bitte bis Freitag Feedback zum Entwurf.", "Search by meaning should find 'Kosten' for 'pricing'.",
    "Contoso Ibérica und Northwind teilen sich den Vertrag.", "snake_case_names and CamelCase2025 stay one token",
    "a b c d e f g h", "Ünïcödé", "!!!???...", "https://contoso.example/path?x=1&y=2", "2026-10-30 16:00 Uhr",
    "😀😀😀", "x" * 300, "wort " * 700, "Hallo zusammen, kurze Runde zum Status.", "That's it from my side, thanks everyone.",
]


def texts(side: Path) -> list[str]:
    """``COUNT`` texts: the corpus's transcript texts (sorted), the fixed sentences, then pairs of corpus texts."""
    found: set[str] = set()

    def walk(value) -> None:
        if isinstance(value, dict):
            for key, v in value.items():
                if key == "text" and isinstance(v, str):
                    found.add(v)
                else:
                    walk(v)
        elif isinstance(value, list):
            for v in value:
                walk(v)

    for file in sorted((side / "Recordings").rglob("*.json")):
        try:
            walk(json.loads(file.read_text(encoding="utf-8")))
        except (OSError, ValueError):
            continue
    from_corpus = sorted(found)
    out = from_corpus + FIXED
    step = 3
    while len(out) < COUNT and from_corpus:
        for i, a in enumerate(from_corpus):
            if len(out) >= COUNT:
                break
            out.append(a + " " + from_corpus[(i * 7 + step) % len(from_corpus)])
        step += 1
    return out[:COUNT]


def swift(side: Path, args: dict) -> dict:
    env = {**os.environ, **ops.environment(side)}
    for k in ("HF_HOME", "HF_HUB_CACHE"):
        env.pop(k, None)
    proc = subprocess.run([str(PARITY_BIN), "e5-encode", "--side", str(side), "--args", json.dumps(args)],
                          env=env, capture_output=True, text=True, timeout=1800)
    try:
        answer = json.loads(proc.stdout.strip().splitlines()[-1])
    except (IndexError, ValueError):
        raise SystemExit(f"e5 gate: palaver-parity answered no JSON (exit {proc.returncode})")
    if proc.returncode != 0 or "error" in answer:
        raise SystemExit(f"e5 gate: palaver-parity failed (exit {proc.returncode}, kind {answer.get('kind')})")
    return answer


def cosine(a: list[float], b: list[float]) -> float:
    dot = math.fsum(x * y for x, y in zip(a, b))
    return dot / math.sqrt(math.fsum(x * x for x in a) * math.fsum(y * y for y in b))


def main() -> int:
    from palaver import embeddings

    folder = embeddings.model_folder(download=False)
    if folder is None:
        print(f"e5 gate: pending ({embeddings.MODEL} at {embeddings.REVISION} is not in the Hugging Face cache)")
        return 2
    if not PARITY_BIN.exists():
        print(f"e5 gate: not run ({PARITY_BIN.relative_to(ROOT)} is not built)")
        return 2
    with tempfile.TemporaryDirectory(prefix="e5-gate-") as tmp:
        side = Path(tmp) / "side"
        corpus.build(side, now=NOW)
        sample = texts(side)
        encoder = embeddings.Encoder(folder)
        results = {}
        for kind in ("passages", "query"):
            started = time.monotonic()
            prefix = encoder.prefix_query if kind == "query" else encoder.prefix_passage
            py_ids = [encoder._ids(prefix + t) for t in sample]
            py_vectors = [encoder.query(t) for t in sample] if kind == "query" else list(encoder.passages(sample))
            python_s = time.monotonic() - started
            started = time.monotonic()
            answer = swift(side, {"folder": str(folder), "texts": sample, "kind": kind})
            swift_s = time.monotonic() - started
            if len(answer["vectors"]) != len(sample):
                raise SystemExit("e5 gate: palaver-parity answered the wrong number of vectors")
            differing = sum(1 for a, b in zip(py_ids, answer["ids"]) if a != b)
            cosines = [cosine([float(x) for x in a], b) for a, b in zip(py_vectors, answer["vectors"])]
            results[kind] = (differing, min(cosines), math.fsum(cosines) / len(cosines), max(cosines))
            print(f"e5 gate {kind}: {len(sample)} texts, ids differ for {differing}, cosine min {min(cosines):.9f} "
                  f"mean {results[kind][2]:.9f} max {max(cosines):.9f} (python {python_s:.1f} s, swift {swift_s:.1f} s)")
    passed = all(d == 0 and low >= MIN_COSINE for d, low, _, _ in results.values())
    print(f"e5 gate: {'passed' if passed else 'missed'}")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
