#!/usr/bin/env python3
"""palaver-engine for the parity runs' worker steps: the answers of the JSON file ``$PALAVER_TEST_ENGINE``, the
same file palaver-worker's ``FakeEngine`` (debug builds) reads, so both sides hear the same engine:

    {"models_ready": true,
     "transcribe": {"system.wav": [segment, ...], "mic.wav": [...], "*": [...]},
     "diarize": {"system.wav": {"turns": [turn, ...], "embeddings": {"SPEAKER_00": [numbers]}}},
     "fail": {"transcribe": "message", "diarize": "models missing: diarizer"}}

A WAV is looked up by its file name, then "*"; anything not listed answers nothing.
"""

import json
import os
import sys
from pathlib import Path

spec = json.loads(Path(os.environ["PALAVER_TEST_ENGINE"]).read_text())


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def entry(cmd, wav):
    table = spec.get(cmd) or {}
    name = Path(wav).name
    return table[name] if name in table else table.get("*")


for line in sys.stdin:
    req = json.loads(line)
    rid, cmd = req.get("id"), req.get("cmd")
    failure = (spec.get("fail") or {}).get(cmd)
    if failure:
        send({"id": rid, "ok": False, "error": failure})
    elif cmd == "transcribe":
        send({"id": rid, "ok": True, "segments": entry("transcribe", req["wav"]) or []})
    elif cmd == "diarize":
        found = entry("diarize", req["wav"]) or {}
        send({"id": rid, "ok": True, "turns": found.get("turns", []), "embeddings": found.get("embeddings", {})})
    else:
        send({"id": rid, "ok": True})
