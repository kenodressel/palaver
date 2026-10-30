"""Dictionary loader: initial_prompt hint + post-transcription replacements."""

from __future__ import annotations

import re
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from ._xdg import xdg_config_home


@dataclass(frozen=True)
class Dictionary:
    initial_prompt: str = ""
    replacements: dict[str, str] = field(default_factory=dict)

    def apply(self, text: str) -> str:
        """Case-insensitive find-and-replace. Longest match first to avoid overlap."""
        if not self.replacements:
            return text
        for src in sorted(self.replacements, key=len, reverse=True):
            dst = self.replacements[src]
            text = re.sub(re.escape(src), dst, text, flags=re.IGNORECASE)
        return text


def default_dictionary_path() -> Path:
    return xdg_config_home() / "palaver" / "dictionary.toml"


def load_dictionary(path: Path | None = None) -> Dictionary:
    path = path or default_dictionary_path()
    if not path.exists():
        return Dictionary()

    with path.open("rb") as fh:
        data = tomllib.load(fh)

    initial = data.get("initial_prompt", {}).get("text", "")
    replacements = {str(k): str(v) for k, v in data.get("replacements", {}).items()}
    return Dictionary(initial_prompt=initial, replacements=replacements)
