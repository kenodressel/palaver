"""The glossary: how names and terms are really spelled (issues #23, #33).

The transcriber gets ordinary words right; it is names that come out
wrong, and differently each time: "CAREL" for Karel, "Atterkring" for
Attakring, "Wasti" and "Vasti" for the same person. The glossary maps
such variants to the right term. It is applied when a transcript is shown,
searched or summarized (readable.py); transcript.json keeps what was
heard, so every change can be undone.

Nobody writes a glossary by hand, so the app suggests entries; the user
accepts, corrects or rejects them a few at a time:

- variant: a rare word that looks or sounds like a name the app already
  knows — from the calendar, people, projects, or the glossary itself.
- cluster: rare words that sound alike across meetings ("Wasti", "Vasti"),
  for the user to say how it is spelled.
- term: a rare capitalized word that recurs ("Databricks"), worth keeping
  so later variants snap to it.

"Rare" means uncommon in German and English (wordfreq), so ordinary nouns
— capitalized in German — are not mistaken for names.
"""

from __future__ import annotations

import json
import math
import re
import uuid
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Mapping

from ._xdg import xdg_config_home
from .store_lock import locked

# How common a word may be (Zipf scale, in German or English) and still be
# a name or term: ~1 in 10 million words.
RARE_ZIPF = 2.0
# A known word this common is too ordinary to have variants ("Lead").
KNOWN_MAX_ZIPF = 4.5
# Spelling similarity (0-100) for a variant of a known name — higher for a
# lower-case one, which is more likely an ordinary word misheard — and
# among the alike-sounding spellings of a cluster.
VARIANT_SIMILARITY = 82
LOWERCASE_VARIANT_SIMILARITY = 88
SOUND_ALIKE_SIMILARITY = 70
CLUSTER_SIMILARITY = 60
EXAMPLES = 3

_WORD = re.compile(r"[^\W\d_](?:[\w'-]*[^\W\d_])?")


def _default_path() -> Path:
    return xdg_config_home() / "palaver" / "glossary.json"


class Glossary:
    """Terms and their variants, in one JSON file."""

    def __init__(self, path: Path | None = None):
        self.path = path or _default_path()
        self.reload()

    def reload(self) -> None:
        try:
            self._data = json.loads(self.path.read_text())
        except (OSError, ValueError):
            self._data = {}
        self._data.setdefault("terms", {})
        self._data.setdefault("rejected", [])
        self._pattern = None

    def save(self) -> None:
        with locked(self.path):
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".json.tmp")
            tmp.write_text(json.dumps(self._data, indent=2, ensure_ascii=False))
            tmp.replace(self.path)
            _CURRENT.clear()

    def terms(self) -> dict[str, dict[str, Any]]:
        """id → {"term", "variants": [...], "note"}."""
        return self._data["terms"]

    def find(self, term: str) -> str | None:
        for tid, t in self.terms().items():
            if t["term"].casefold() == term.strip().casefold():
                return tid
        return None

    def owner(self, variant: str) -> str | None:
        """The term a variant already maps to."""
        for tid, t in self.terms().items():
            if any(v.casefold() == variant.strip().casefold() for v in t["variants"]):
                return tid
        return None

    def add(self, term: str, variants: Iterable[str] = (), note: str = "") -> str:
        """Add a term, or variants to an existing one. A variant moves from
        any other term; the term's own spelling is never a variant."""
        term = term.strip()
        if not term:
            raise ValueError("a term is needed")
        tid = self.find(term)
        if tid is None:
            tid = uuid.uuid4().hex[:8]
            self.terms()[tid] = {"term": term, "variants": [], "note": note.strip()}
        for v in variants:
            v = v.strip()
            if not v or v.casefold() == term.casefold():
                continue
            other = self.owner(v)
            if other and other != tid:
                self.remove_variant(other, v)
            if not any(x.casefold() == v.casefold() for x in self.terms()[tid]["variants"]):
                self.terms()[tid]["variants"].append(v)
        if self.owner(term):  # the right spelling was listed as some term's variant
            self.remove_variant(self.owner(term), term)
        self._pattern = None
        return tid

    def update(self, tid: str, *, term: str | None = None, note: str | None = None) -> None:
        t = self._term(tid)
        if term is not None:
            term = term.strip()
            if not term:
                raise ValueError("a term is needed")
            other = self.find(term)
            if other and other != tid:
                raise ValueError(f"{term} is already in the glossary")
            t["term"] = term
            t["variants"] = [v for v in t["variants"] if v.casefold() != term.casefold()]
        if note is not None:
            t["note"] = note.strip()
        self._pattern = None

    def remove_variant(self, tid: str, variant: str) -> None:
        t = self._term(tid)
        t["variants"] = [v for v in t["variants"] if v.casefold() != variant.casefold()]
        self._pattern = None

    def delete(self, tid: str) -> None:
        self._term(tid)
        del self.terms()[tid]
        self._pattern = None

    def reject(self, key: str) -> None:
        """Never suggest this again (a suggestion's key)."""
        if key not in self._data["rejected"]:
            self._data["rejected"].append(key)

    def rejected(self) -> set[str]:
        return set(self._data["rejected"])

    def _term(self, tid: str) -> dict[str, Any]:
        try:
            return self.terms()[tid]
        except KeyError:
            raise LookupError(tid) from None

    # --- applying

    def _replacements(self) -> dict[str, str]:
        return {v.casefold(): t["term"] for t in self.terms().values() for v in t["variants"]}

    def apply(self, text: str) -> str:
        """``text`` with every variant written as its term."""
        return self.apply_marked(text)[0]

    def apply_marked(self, text: str) -> tuple[str, list[tuple[int, int, str]]]:
        """``apply``, and where it respelled: (start, end) of each term in
        the new text, with the variant that was heard there."""
        replacements = self._replacements()
        if not replacements:
            return text, []
        if self._pattern is None:
            alternatives = sorted(replacements, key=len, reverse=True)  # "Unit zu14" before "Unit"
            # A part of a compound is respelled too: "Atterkring-Raum".
            self._pattern = re.compile(
                r"(?<!\w)(" + "|".join(re.escape(v) for v in alternatives) + r")(?!\w)", re.IGNORECASE)
        parts, marks, last, length = [], [], 0, 0
        for m in self._pattern.finditer(text):
            term = replacements[m.group(1).casefold()]
            parts.append(text[last:m.start(1)])
            length += m.start(1) - last
            marks.append((length, length + len(term), m.group(1)))
            parts.append(term)
            length += len(term)
            last = m.end(1)
        parts.append(text[last:])
        return "".join(parts), marks

    def apply_to(self, value: Any) -> Any:
        """``apply`` on every text in ``value`` (notes: dicts and lists of texts)."""
        if isinstance(value, str):
            return self.apply(value)
        if isinstance(value, list):
            return [self.apply_to(v) for v in value]
        if isinstance(value, dict):
            return {k: self.apply_to(v) for k, v in value.items()}
        return value


_CURRENT: dict[str, tuple[float, Glossary]] = {}


def current() -> Glossary:
    """The user's glossary, read again when the file changes."""
    path = _default_path()
    try:
        mtime = path.stat().st_mtime
    except OSError:
        mtime = 0.0
    cached = _CURRENT.get(str(path))
    if cached is None or cached[0] != mtime:
        cached = (mtime, Glossary(path))
        _CURRENT.clear()
        _CURRENT[str(path)] = cached
    return cached[1]


# --- suggestions ----------------------------------------------------------------


def cologne(word: str) -> str:
    """Kölner Phonetik: German sound code; "Wasti" and "Vasti" → "382"."""
    w = word.upper().translate(str.maketrans({"Ä": "A", "Ö": "O", "Ü": "U", "ß": "S"}))
    w = "".join(c for c in w if "A" <= c <= "Z")
    codes = []
    for i, c in enumerate(w):
        prev = w[i - 1] if i else ""
        nxt = w[i + 1] if i + 1 < len(w) else ""
        if c in "AEIJOUY":
            code = "0"
        elif c == "H":
            code = ""
        elif c == "B":
            code = "1"
        elif c == "P":
            code = "3" if nxt == "H" else "1"
        elif c in "DT":
            code = "8" if nxt in ("C", "S", "Z") and nxt else "2"
        elif c in "FVW":
            code = "3"
        elif c in "GKQ":
            code = "4"
        elif c == "C":
            if i == 0:
                code = "4" if nxt in tuple("AHKLOQRUX") and nxt else "8"
            else:
                code = "4" if nxt in tuple("AHKOQUX") and nxt and prev not in ("S", "Z") else "8"
        elif c == "X":
            code = "8" if prev in ("C", "K", "Q") and prev else "48"
        elif c == "L":
            code = "5"
        elif c in "MN":
            code = "6"
        elif c == "R":
            code = "7"
        else:  # S, Z
            code = "8"
        codes.append(code)
    out = ""
    for code in "".join(codes):
        if not out or code != out[-1]:
            out += code
    return out[:1] + out[1:].replace("0", "") if out else ""


def zipf(word: str) -> float:
    """How common a word is in German or English, whichever is more."""
    from wordfreq import zipf_frequency

    w = word.casefold()
    return max(zipf_frequency(w, "de"), zipf_frequency(w, "en"))


def is_rare(word: str) -> bool:
    return zipf(word) < RARE_ZIPF


@dataclass
class Occurrences:
    count: int = 0
    meetings: set[str] = field(default_factory=set)
    examples: list[dict[str, Any]] = field(default_factory=list)
    rare: bool = True  # False: an ordinary word, here only because it was heard unsure


def occurrences(transcripts: dict[str, list[tuple[float, str]]],
                unsure: Iterable[str] | Mapping[str, int] = ()) -> dict[str, Occurrences]:
    """Rare words, and ordinary ones the transcriber was unsure of
    (casefolded in ``unsure``, with how often; a plain set counts as every
    time): meeting id → [(start, line)] in, word → where it occurs out. An
    ordinary word counts only capitalized and doubted at least half the
    times it was said: "Teil", said everywhere and doubted now and then,
    is no misheard "Theil"."""
    doubted = unsure if isinstance(unsure, Mapping) else dict.fromkeys(unsure, math.inf)
    found: dict[str, Occurrences] = defaultdict(Occurrences)
    rare_cache: dict[str, bool] = {}
    for meeting, lines in transcripts.items():
        for start, text in lines:
            for word in _WORD.findall(text):
                if len(word) < 3:
                    continue
                if word not in rare_cache:
                    rare_cache[word] = is_rare(word)
                if not rare_cache[word] and (word.casefold() not in doubted or not word[0].isupper()):
                    continue
                o = found[word]
                o.rare = rare_cache[word]
                o.count += 1
                o.meetings.add(meeting)
                if len(o.examples) < EXAMPLES and all(e["meeting"] != meeting for e in o.examples):
                    o.examples.append({"meeting": meeting, "start": start, "text": text})
    # All spellings of a word share its doubts ("Teil" and "teil" alike).
    said: dict[str, int] = defaultdict(int)
    for meeting_lines in transcripts.values():
        for _, text in meeting_lines:
            for word in _WORD.findall(text):
                if word.casefold() in doubted:
                    said[word.casefold()] += 1
    return defaultdict(Occurrences, {w: o for w, o in found.items()
                                     if o.rare or 2 * doubted[w.casefold()] >= said[w.casefold()]})


def _known_words(known: Iterable[str]) -> dict[str, str]:
    """casefolded word → spelling, from known names and terms; not ordinary
    words ("Lead", "Spain"), whose look-alikes are mostly other words."""
    out = {}
    for name in known:
        for word in _WORD.findall(name):
            if len(word) >= 3 and word.casefold() not in out and zipf(word) < KNOWN_MAX_ZIPF:
                out[word.casefold()] = word
    return out


def _similar(a: str, b: str) -> float:
    from rapidfuzz import fuzz

    return fuzz.ratio(a.casefold(), b.casefold())


def suggest(transcripts: dict[str, list[tuple[float, str]]], known: Iterable[str],
            glossary: Glossary, *, unsure: Iterable[str] = ()) -> list[dict[str, Any]]:
    """Glossary suggestions, most worthwhile first. ``known``: names and
    terms spelled right (calendar, people, projects). ``unsure``: words the
    transcriber was unsure of; an ordinary one ("Cloud") may then be a
    known name misheard ("KLOUD"), though never a new term."""
    found = occurrences(transcripts, unsure)
    known_words = _known_words([*known, *(t["term"] for t in glossary.terms().values())])
    mapped = {v.casefold() for t in glossary.terms().values() for v in t["variants"]}
    in_glossary = {t["term"].casefold() for t in glossary.terms().values()}
    rejected = glossary.rejected()
    out: list[dict[str, Any]] = []
    placed: set[str] = set()

    def merge(words: list[str]) -> dict[str, Any]:
        meetings = set().union(*(found[w].meetings for w in words))
        examples = [e for w in words for e in found[w].examples][:EXAMPLES]
        return {"count": sum(found[w].count for w in words), "meetings": sorted(meetings), "examples": examples}

    # 1. Variants of a known spelling.
    by_term: dict[str, list[str]] = defaultdict(list)
    for word in found:
        key = word.casefold()
        if key in known_words or key in mapped or key in in_glossary:
            continue
        best, score = None, 0.0
        needed = VARIANT_SIMILARITY if word[0].isupper() else LOWERCASE_VARIANT_SIMILARITY
        for k, spelling in known_words.items():
            if abs(len(k) - len(key)) > 3:
                continue
            s = _similar(key, k)
            if s >= SOUND_ALIKE_SIMILARITY and cologne(word) == cologne(spelling):
                s = max(s, needed)
            if s >= needed and s > score:
                best, score = spelling, s
        if best is not None:
            by_term[best].append(word)
    # A name heard as two words: "Data Bricks", "Zabek Hollmer".
    joined_known = {k.replace("-", ""): spelling for k, spelling in known_words.items()}
    for meeting, lines in transcripts.items():
        for start, text in lines:
            words = _WORD.findall(text)
            for first, second in zip(words, words[1:]):
                term = joined_known.get((first + second).casefold())
                pair = f"{first} {second}"
                # Capitalized, as names are: "hand over" is a verb, not "Handover".
                if term is None or len(term) < 6 or not first[0].isupper() or pair.casefold() in mapped:
                    continue
                o = found[pair]
                o.count += 1
                o.meetings.add(meeting)
                if len(o.examples) < EXAMPLES and all(e["meeting"] != meeting for e in o.examples):
                    o.examples.append({"meeting": meeting, "start": start, "text": text})
                if pair not in by_term[term]:
                    by_term[term].append(pair)
    for term, words in by_term.items():
        words = [w for w in words if f"variant:{w.casefold()}:{term.casefold()}" not in rejected]
        if not words:
            continue
        placed.update(words)
        out.append({"kind": "variant", "key": f"variant:{words[0].casefold()}:{term.casefold()}",
                    "term": term, "variants": sorted(set(words)), **merge(words),
                    "unsure": any(not found[w].rare for w in words)})

    # 2. Clusters: rare capitalized spellings that sound alike, none known.
    candidates = [w for w in found if w not in placed and found[w].rare and w[0].isupper()
                  and w.casefold() not in mapped and w.casefold() not in in_glossary
                  and w.casefold() not in known_words]
    groups: dict[str, list[str]] = defaultdict(list)
    for w in candidates:
        groups[cologne(w)].append(w)
    for code, words in groups.items():
        spellings = {w.casefold(): w for w in words}
        if len(spellings) < 2 or len(code) < 2:
            continue
        words = sorted(words, key=lambda w: -found[w].count)
        if any(_similar(words[0], w) < CLUSTER_SIMILARITY for w in words[1:]):
            words = [words[0]] + [w for w in words[1:] if _similar(words[0], w) >= CLUSTER_SIMILARITY]
            if len({w.casefold() for w in words}) < 2:
                continue
        key = "cluster:" + ",".join(sorted({w.casefold() for w in words}))
        if key in rejected:
            continue
        placed.update(words)
        out.append({"kind": "cluster", "key": key, "term": words[0], "variants": words, **merge(words)})

    # 3. New terms: rare capitalized words that recur across meetings. A
    # plural ("Sidequests") counts as its singular.
    for w in candidates:
        if w in placed or (w.endswith("s") and w[:-1] in found):
            continue
        o = found[w]
        plural = found.get(w + "s")
        meetings = o.meetings | (plural.meetings if plural else set())
        if len(meetings) < 2 and o.count < 5:
            continue
        key = f"term:{w.casefold()}"
        if key in rejected:
            continue
        out.append({"kind": "term", "key": key, "term": w, "variants": [],
                    **merge([w, w + "s"] if plural else [w])})

    weight = {"variant": 3, "cluster": 2, "term": 1}
    out.sort(key=lambda s: (-weight[s["kind"]] * (s["count"] + 3 * len(s["meetings"])), s["term"].casefold()))
    return out


# --- from the recordings ------------------------------------------------------------


def unsure_words(output_dir: Path) -> Counter[str]:
    """Words the transcriber was unsure of in any recording (casefolded),
    with how often, except in lines the user rewrote."""
    from .paths import is_recording_folder_name

    out: Counter[str] = Counter()
    if output_dir.is_dir():
        for folder in output_dir.iterdir():
            f = folder / "transcript.json"
            if not (is_recording_folder_name(folder.name) and f.exists()):
                continue
            try:
                lines = json.loads(f.read_text())
            except (OSError, ValueError):
                continue
            for line in lines:
                if "heard" not in line:
                    out.update(w.strip(".,?!:;").casefold() for w in line.get("unsure", ()))
    return out


def corpus(output_dir: Path) -> dict[str, list[tuple[float, str]]]:
    """Every processed meeting's readable lines: id → [(start, text)]."""
    from .models import Utterance
    from .paths import RecordingPaths, is_recording_folder_name
    from .readable import readable
    from .speakers import without_ignored

    out = {}
    if output_dir.is_dir():
        for folder in sorted(output_dir.iterdir()):
            f = folder / "transcript.json"
            if is_recording_folder_name(folder.name) and f.exists():
                try:
                    utterances = without_ignored(RecordingPaths(folder),
                                                 [Utterance.from_dict(d) for d in json.loads(f.read_text())])
                except (OSError, ValueError):
                    continue
                out[folder.name] = [(round(u.start, 2), u.text) for u in readable(utterances)]
    return out


def known_spellings(output_dir: Path, *, user_name: str = "") -> set[str]:
    """Names spelled right: calendar titles and attendees (rooms too: their
    names are places people mention), people, projects."""
    from . import calendar_events, projects
    from .paths import RecordingPaths, is_recording_folder_name
    from .speakers import names_in_effect
    from .voices import VoiceBank

    known = {user_name} if user_name else set()
    known.update(VoiceBank().names())
    known.update(p["name"] for p in projects.ProjectStore().projects().values())
    if output_dir.is_dir():
        for folder in output_dir.iterdir():
            if not is_recording_folder_name(folder.name):
                continue
            paths = RecordingPaths(folder)
            event = calendar_events.load(paths)
            if event:
                known.add(event.title)
                known.update(a.name for a in event.attendees)
            known.update(names_in_effect(paths).values())
    return {k for k in known if k}
