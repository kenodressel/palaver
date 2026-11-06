#!/usr/bin/env python3
"""A stand-in for palaver-engine that speaks its protocol with canned answers.

Tests point $PALAVER_ENGINE at this file and pick a behaviour with
$FAKE_ENGINE_MODE: ok (default), crash, error, models_missing, progress,
slow (answers after FAKE_ENGINE_DELAY seconds), diarize_crash (exits during diarize).
"""

import json
import os
import sys
import time

mode = os.environ.get("FAKE_ENGINE_MODE", "ok")
print("fake engine started", file=sys.stderr, flush=True)


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    try:
        req = json.loads(line)
    except ValueError:
        send({"id": -1, "ok": False, "error": "bad request: " + line.strip()})
        continue
    rid = req.get("id")
    if mode == "crash":
        print("fake engine: out of memory", file=sys.stderr, flush=True)
        sys.exit(3)
    if mode == "silent":
        time.sleep(600)
    elif mode == "foreign":
        end = time.time() + 0.6
        while time.time() < end:
            send({"id": 999, "progress": 0.1, "phase": "x"})
            time.sleep(0.05)
        time.sleep(600)
    elif mode == "badbytes":
        sys.stderr.buffer.write(b"bad \xff\xfe line\n")
        sys.stderr.buffer.write((b"x" * 99 + b"\n") * 20000)  # 2 MB: blocks if nobody drains
        sys.stderr.buffer.flush()
        sys.stdout.buffer.write(b'{"id": %d, "ok": true, "text": "caf\xff"}\n' % rid)
        sys.stdout.buffer.flush()
    elif mode == "badprogress":
        send({"id": rid, "progress": 0.5, "phase": "asr"})
        time.sleep(600)
    elif mode == "error":
        send({"id": rid, "ok": False, "error": "no such wav"})
    elif mode == "models_missing":
        send({"id": rid, "ok": False, "error": "models missing: asr"})
    elif mode == "progress":
        send({"id": rid, "progress": 0.5, "phase": "asr"})
        send({"id": rid, "progress": 1.0, "phase": "asr"})
        send({"id": rid, "ok": True})
    elif mode == "slow":
        time.sleep(float(os.environ.get("FAKE_ENGINE_DELAY", "0.5")))
        send({"id": rid, "ok": True, "pid": os.getpid()})
    elif req.get("cmd") == "transcribe":
        send({"id": rid, "ok": True, "segments": [
            {"start": 0.0, "end": 1.2, "text": "The cloud is up.", "words": [
                {"text": "The", "start": 0.0, "end": 0.2, "confidence": 0.99},
                {"text": "cloud", "start": 0.3, "end": 0.6, "confidence": 0.5},
                {"text": "is", "start": 0.7, "end": 0.9, "confidence": 0.97},
                {"text": "up.", "start": 0.9, "end": 1.2, "confidence": 0.92}]},
            {"start": 3.0, "end": 3.5, "text": "Yes.", "words": [
                {"text": "Yes.", "start": 3.0, "end": 3.5, "confidence": 0.88}]},
        ], "seen": {k: v for k, v in req.items() if k not in ("id", "cmd")}})
    elif req.get("cmd") == "diarize":
        if mode == "diarize_crash":
            print("fake engine: died while diarizing", file=sys.stderr, flush=True)
            sys.exit(3)
        import wave
        with wave.open(req["wav"]) as w:
            frames, rate = w.getnframes(), w.getframerate()
        send({"id": rid, "ok": True, "turns": [
            {"speaker": "SPEAKER_00", "start": 0.0, "end": 2.0},
            {"speaker": "SPEAKER_01", "start": 2.0, "end": 3.5}],
            "embeddings": {"SPEAKER_00": [0.5] * 256, "SPEAKER_01": [-0.5] * 256},
            "seconds": 0.1, "frames": frames, "rate": rate})
    elif req.get("cmd") == "transcribe_window":
        import base64
        n = len(base64.b64decode(req["pcm"])) // 4
        send({"id": rid, "ok": True, "words": [{"text": "cloud", "start": 0.0, "end": 0.1, "confidence": 0.9}],
              "samples": n})
    else:
        send({"id": rid, "ok": True, "fluidaudio": "0.18.2", "pid": os.getpid(), "cmd": req.get("cmd"), "args": sys.argv[1:]})
