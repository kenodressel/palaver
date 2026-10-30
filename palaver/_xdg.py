"""XDG base-directory lookup shared by the user-config loaders."""

from __future__ import annotations

import os
from pathlib import Path


def xdg_config_home() -> Path:
    """``$XDG_CONFIG_HOME``, or ``~/.config`` when unset or empty."""
    return Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
