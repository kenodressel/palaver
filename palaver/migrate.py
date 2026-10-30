"""The app was called meeting-transcribe until October 2026. Its settings
(config, glossary, voices, projects), state and logs move to the folders
of the new name the first time Palaver runs; nothing is copied or lost.
"""

from __future__ import annotations

from pathlib import Path

from ._xdg import xdg_config_home

OLD = "meeting-transcribe"
NEW = "palaver"
# A release install's Python lives in Application Support; install.sh makes
# a new one, as a venv can't be moved.
LEFT_BEHIND = {"venv"}


def _folders(home: Path, config_home: Path) -> list[tuple[Path, Path]]:
    library = home / "Library"
    return [(config_home / OLD, config_home / NEW),
            (library / "Application Support" / OLD, library / "Application Support" / NEW),
            (library / "Logs" / OLD, library / "Logs" / NEW)]


def move(old: Path, new: Path) -> list[Path]:
    """Move what ``old`` holds into ``new``, except what ``new`` has already
    (the launcher may have started a log there) and LEFT_BEHIND; ``old`` goes
    when it is empty."""
    if not old.is_dir():
        return []
    new.mkdir(parents=True, exist_ok=True)
    moved = []
    for entry in sorted(old.iterdir()):
        target = new / entry.name
        if entry.name not in LEFT_BEHIND and not target.exists():
            entry.rename(target)
            moved.append(target)
    if not any(old.iterdir()):
        old.rmdir()
    return moved


def move_old_folders() -> list[Path]:
    """Everything still in the old name's folders, moved to the new ones."""
    return [p for old, new in _folders(Path.home(), xdg_config_home()) for p in move(old, new)]
