"""Why a recording has no transcript yet: `palaver process` failed on it, or
it waits for models still being downloaded (a call recorded right after
installing). Kept as failed.json in its folder until a run succeeds; the
window shows it, with Transcribe Again, and the menu bar app transcribes the
waiting ones once their models are here."""

from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path
from typing import Any

from .paths import RecordingPaths

FILE = "failed.json"
MODELS = "models"  # waits for its models: tried again once they are downloaded
ERROR = "error"  # failed: tried again only when the user asks
EXIT_MODELS = 4  # `palaver process` exits with this while its models are missing


def _file(paths: RecordingPaths) -> Path:
    return paths.folder / FILE


def read(paths: RecordingPaths) -> dict[str, Any] | None:
    """{"reason", "at", "missing" (model labels), "error"}; None when the last
    run did not fail (or none ran yet)."""
    try:
        data = json.loads(_file(paths).read_text())
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) and data.get("reason") in (MODELS, ERROR) else None


def mark(paths: RecordingPaths, reason: str, *, missing: list[str] = (), error: str | None = None) -> None:
    data = {"reason": reason, "at": datetime.now().astimezone().isoformat(timespec="seconds"),
            "missing": list(missing), "error": error}
    tmp = _file(paths).with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, indent=2))
    tmp.replace(_file(paths))


def clear(paths: RecordingPaths) -> None:
    _file(paths).unlink(missing_ok=True)


def missing_models(cfg, paths: RecordingPaths) -> list[str]:
    """The labels of the models `process` still needs for ``paths`` that are
    not on this Mac: Parakeet for a track not transcribed yet (the
    microphone's always runs here), pyannote's to tell the speakers apart."""
    from .onboarding import MODELS as ALL

    need = []
    transcribed = paths.mic_segments.exists() and paths.system_segments.exists()
    if getattr(cfg, "transcriber", "parakeet-mlx") == "parakeet-mlx" and not transcribed:
        need.append(ALL["parakeet"])
    if not (paths.system_turns.exists() and paths.speaker_embeddings.exists()):
        need.append(ALL["pyannote"])
    return [m.label for m in need if not _here(cfg, m)]


def _here(cfg, m) -> bool:
    from .onboarding import model_here, repo_for

    return model_here(m, repo_for(cfg, m))

