"""An anonymized copy of real meeting folders, for the parity run on real data (a manual gate,
run locally; nothing here is ever printed).

- every word of the text becomes a stable pseudo-word: the same word, the same pseudo-word (from
  its sha256), with its length, case and the punctuation around it kept;
- names (calendar invitees, speakers, voices, who sent an import) become ``Person <n>``, emails
  ``p<n>@contoso.example``, numbered in order of first appearance; as values and as keys (a
  casefolded key stays casefolded);
- audio and other binary files are copied as they are; a JSON file keeps its format.
"""

from __future__ import annotations

import hashlib
import json
import re
import shutil
from pathlib import Path
from typing import Any

from tools.parity import diff

_LETTERS = re.compile(r"[^\W\d_]+")
_LABEL = re.compile(r"SPEAKER_\d+")
_ALPHABET = "abcdefghijklmnopqrstuvwxyz"
# Keys whose string value is a person's name.
NAME_KEYS = frozenset({"name", "speaker", "owner", "from", "by"})
EMAIL_KEYS = frozenset({"email"})
# Dicts keyed by people: organizations.json's "people" (casefolded name → organization), the
# invitee index's "emails" (address → count). Any key with an "@" is an address too.
PEOPLE_KEYED = frozenset({"people", "emails"})
# Keys under which every string is text people said or wrote.
TEXT_KEYS = frozenset({"text", "heard", "title", "summary", "heading", "points", "details", "task", "decisions",
                       "evidence", "why", "reason", "note", "description", "location", "file", "draft", "unsure",
                       "paragraphs", "questions", "chunks"})
# Values that look like names under those keys but are the app's own words.
KEPT = frozenset({"you", "auto", "model", "hand", "voice", "inferred", "exporter", "imported", "mic"})
# Files whose values (not keys) are all names, or all text.
NAME_FILES = frozenset({"speakers.json", "speakers_rejected.json"})
TEXT_FILES = frozenset({"speakers_shared.json", "title.json"})
KEPT_FILES = frozenset({"language.txt"})


def pseudo_word(word: str) -> str:
    h = hashlib.sha256(word.casefold().encode()).digest()
    out = []
    for i, ch in enumerate(word):
        c = _ALPHABET[h[i % len(h)] % len(_ALPHABET)]
        out.append(c.upper() if ch.isupper() else c)
    return "".join(out)


def pseudo_text(text: str) -> str:
    return _LETTERS.sub(lambda m: pseudo_word(m.group()), text)


class _People:
    def __init__(self) -> None:
        self.names: dict[str, str] = {}
        self.emails: dict[str, str] = {}

    def name(self, name: str) -> str:
        if _LABEL.fullmatch(name) or name in KEPT or not name.strip():
            return name
        return self.names.setdefault(name.strip().casefold(), f"Person {len(self.names) + 1}")

    def email(self, email: str) -> str:
        return self.emails.setdefault(email.strip().casefold(), f"p{len(self.emails) + 1}@contoso.example")


def _walk(v: Any, key: str | None, mode: str, people: _People) -> Any:
    """``mode``: "text" under a text key, "names" in a file of names, else ""."""
    if isinstance(v, dict):
        return {_key(k, key, people): _walk(x, k, "text" if mode != "names" and k in TEXT_KEYS else mode, people)
                for k, x in v.items()}
    if isinstance(v, list):
        return [_walk(x, key, mode, people) for x in v]
    if not isinstance(v, str):
        return v
    if key in EMAIL_KEYS:
        return people.email(v)
    if key in NAME_KEYS or mode == "names":
        return people.name(v)
    return pseudo_text(v) if mode == "text" else v


def _key(k: str, parent: str | None, people: _People) -> str:
    if "@" in k:
        return people.email(k)
    if parent in PEOPLE_KEYED:
        name = people.name(k)
        return name.casefold() if k == k.casefold() else name
    return k


def _json(v: Any, name: str, people: _People) -> Any:
    return _walk(v, None, "names" if name in NAME_FILES else "text" if name in TEXT_FILES else "", people)


def copy(src: Path, dst: Path) -> None:
    """The meeting folders in ``src``, anonymized, in ``dst`` (which must not exist yet)."""
    dst.mkdir(parents=True)
    people = _People()
    for f in sorted(src.rglob("*")):
        if f.is_symlink():
            continue
        out = dst / f.relative_to(src)
        if f.is_dir():
            out.mkdir(parents=True, exist_ok=True)
            continue
        text = None if f.name in KEPT_FILES else diff.read_text(f)
        if text is None:
            shutil.copy2(f, out)
            continue
        if f.suffix == ".json":
            try:
                value = json.loads(text)
            except ValueError:
                out.write_text(pseudo_text(text))
                continue
            indent, ensure_ascii, newline = (diff.json_formats(text, value) or [(2, False, False)])[0]
            out.write_text(json.dumps(_json(value, f.name, people), indent=indent, ensure_ascii=ensure_ascii)
                           + ("\n" if newline else ""))
        elif f.suffix == ".jsonl":
            lines = []
            for line in text.splitlines():
                try:
                    lines.append(json.dumps(_json(json.loads(line), f.name, people), ensure_ascii=False))
                except ValueError:
                    lines.append(pseudo_text(line))
            out.write_text("".join(line + "\n" for line in lines))
        else:
            out.write_text(pseudo_text(text))
        shutil.copystat(f, out)
