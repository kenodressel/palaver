"""What left the Mac, where to and when: one line per call to a cloud
model (provider, host, model, feature, meetings, how many characters, how
it went) and per upload to a transcription service (#54: which track and
how many seconds of audio, instead of characters). Never the content and
never a key. Shown on the Settings page.

Meant to be shared: the MCP access log (#45) can write here too, with its
own ``feature``.
"""

from __future__ import annotations

import json
import os
from datetime import datetime
from pathlib import Path
from typing import Any

from ._xdg import xdg_config_home

# Never trimmed (#59): while testing is internal, every entry stays for a problem report.


def path() -> Path:
    return xdg_config_home() / "palaver" / "access-log.jsonl"


def record(*, provider: str, host: str, model: str, feature: str, meetings: list[str], chars: int, ok: bool,
           seconds: float, error: str | None = None, audio_seconds: float | None = None,
           track: str | None = None) -> None:
    """``seconds``: how long the call took; ``audio_seconds``: how much
    audio it sent, and ``track`` which one."""
    entry: dict[str, Any] = {
        "time": datetime.now().astimezone().isoformat(timespec="seconds"),
        "provider": provider, "host": host, "model": model, "feature": feature,
        "meetings": list(meetings), "chars": int(chars), "ok": bool(ok), "seconds": round(float(seconds), 1),
    }
    if audio_seconds is not None:
        entry["audio_seconds"] = round(float(audio_seconds), 1)
    if track:
        entry["track"] = track
    if error:
        entry["error"] = error
    target = path()
    target.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def recent(limit: int | None = 50) -> list[dict[str, Any]]:
    """The newest entries first; ``limit`` None: all of them."""
    try:
        lines = path().read_text().splitlines()
    except OSError:
        return []
    out = []
    for line in reversed(lines):
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if isinstance(entry, dict):
            out.append(entry)
            if limit is not None and len(out) >= limit:
                break
    return out
