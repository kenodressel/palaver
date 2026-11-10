"""Compare two sides of a parity run, file by file and value by value.

What may differ, and so is normalized before comparing:

- each side's own path (config.toml names its Recordings) reads ``<side>``;
- keys in ``VOLATILE`` (times) are compared only for presence;
- 32-hex undo tokens created during the scenario, also as folder names under ``.trash/.undo/``,
  read ``<token1>``, ``<token2>``, … in the order their folders were created on each side;
- 8-hex ids created during the scenario (projects, glossary terms) read ``<id1>``, ``<id2>``, …
  in order of first appearance on each side; one that is the start of a numbered token (what an
  undo's restore sets aside: ``.trash/undone-<8>``, ``<id>.undone-<8>``) reads ``<tokenN:8>``;
- tokens gone with their snapshot are numbered in the order the answers gave them, before the files'
  contents;
- tokens and ids the sides started with (the corpus') stay as they are;
- ``session.log``, ``*.lock``, ``*.tmp`` and ``.DS_Store`` are not compared.

Two files whose paths read the same once normalized are a difference ("collision"), never one
compared in place of the other.

A JSON file is compared value by value (key order, ints apart from floats, Python's float
repr) and by its format: the ``json.dumps`` indent, ``ensure_ascii`` and trailing newline that
reproduce it byte for byte; a ``.jsonl`` file line by line the same way, and its final newline.

The ops' answers are compared too. An error is ``{"error": message, "kind": kind}``: a harness
error (``HARNESS_ERRORS``: a crash, no JSON, an unknown op, bad args) is always a difference; a
domain error (``refused``, ``not_found``, ``gone``, ``changed``, ``bad_request``, ``other``) only
matches one of the same kind and message, and only on a step that declares ``"error": true``.

Other text is compared by line, the rest by bytes. ``rules`` maps a
glob of the relative path to a function ``(path, a_file, b_file) -> list[Difference]`` that
decides that file instead (Tasks 27 and 35 add tolerances there): ``pcm_within_2_lsb`` (Task 27) takes two
16-bit WAVs of the same rate, channels and length whose samples are at most 2 LSB apart; ``npy_within_1e_3``
(Task 35) two ``.npy`` files with the same header (dtype, order, shape) whose numbers are at most 1e-3 apart.
"""

from __future__ import annotations

import fnmatch
import hashlib
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable, Iterator

VOLATILE = frozenset({"at", "since", "reviewed", "computed_at", "uploaded_at", "generated_at", "imported_at",
                      "exported_at", "updated_at", "time", "started", "ended", "added", "dismissed"})
SKIPPED_NAMES = frozenset({"session.log", ".DS_Store"})
SKIPPED_SUFFIXES = (".lock", ".tmp")
BINARY_SUFFIXES = frozenset({".wav", ".part", ".npy", ".opus", ".flac", ".ogg", ".m4a", ".mp3", ".png", ".jpg",
                             ".jpeg", ".gif", ".heic", ".zip", ".palaver", ".icns", ".pdf"})
TOKEN = re.compile(r"(?<![0-9a-f])[0-9a-f]{32}(?![0-9a-f])")
ID = re.compile(r"(?<![0-9A-Za-z])[0-9a-f]{8}(?![0-9A-Za-z])")
FORMATS = [(indent, ensure_ascii) for indent in (None, 1, 2) for ensure_ascii in (False, True)]
PRESENT = "<present>"
HARNESS_ERRORS = frozenset({"crash", "no_json", "unknown_op", "bad_args"})
SHOWN = 200  # characters of a value shown in a difference

Rule = Callable[[str, Path, Path], list["Difference"]]
# Named tolerances a scenario can ask for ({"rules": {"<glob>": "<name>"}}); Tasks 27 and 35.
RULES: dict[str, Rule] = {}

PCM_TOLERANCE = 2  # LSB: an imported system track, decoded by libsndfile's libopus 1.4 or the vendored 1.5.2


def _pcm_within_2_lsb(path: str, fa: Path, fb: Path) -> list["Difference"]:
    """Two 16-bit WAVs (an import's system track, Task 27): the same rate, channels and length, and no sample apart
    by more than ``PCM_TOLERANCE``. Files soundfile can't read are compared by bytes."""
    import numpy as np
    import soundfile as sf

    try:
        a, ra = sf.read(str(fa), dtype="int16", always_2d=True)
        b, rb = sf.read(str(fb), dtype="int16", always_2d=True)
    except (RuntimeError, sf.LibsndfileError):
        da, db = fa.read_bytes(), fb.read_bytes()
        return [] if da == db else [Difference(path, "bytes", _bytes(da), _bytes(db))]
    if (ra, a.shape) != (rb, b.shape):
        return [Difference(path, "audio format", f"{ra} Hz, {a.shape[1]} ch, {a.shape[0]} frames",
                           f"{rb} Hz, {b.shape[1]} ch, {b.shape[0]} frames")]
    worst = int(np.abs(a.astype(np.int32) - b.astype(np.int32)).max()) if a.size else 0
    if worst > PCM_TOLERANCE:
        return [Difference(path, f"samples (more than {PCM_TOLERANCE} LSB apart)", "", f"{worst} LSB")]
    return []


RULES["pcm_within_2_lsb"] = _pcm_within_2_lsb

NPY_TOLERANCE = 1e-3  # a search index's float16 vectors: numpy's and the Swift encoder's last float32 bits differ


def _npy_within_1e_3(path: str, fa: Path, fb: Path) -> list["Difference"]:
    """Two ``.npy`` files (a search index, Task 35): the same header (format version, dtype, order, shape) and no
    number apart by more than ``NPY_TOLERANCE`` (NaN only against NaN). Files numpy can't read are compared by
    bytes."""
    import numpy as np

    da, db = fa.read_bytes(), fb.read_bytes()
    try:
        a, b = np.load(fa, allow_pickle=False), np.load(fb, allow_pickle=False)
    except (OSError, ValueError, EOFError):
        return [] if da == db else [Difference(path, "bytes", _bytes(da), _bytes(db))]
    head = lambda d: d[:d.index(b"\n") + 1] if b"\n" in d else d  # noqa: E731
    if head(da) != head(db):
        return [Difference(path, "npy header", head(da).decode("latin-1").strip(), head(db).decode("latin-1").strip())]
    if a.shape != b.shape or a.dtype != b.dtype:
        return [Difference(path, "npy shape", f"{a.dtype} {a.shape}", f"{b.dtype} {b.shape}")]
    x, y = a.astype(np.float64), b.astype(np.float64)
    if (np.isnan(x) != np.isnan(y)).any():
        return [Difference(path, "npy values (NaN)", "", "")]
    worst = float(np.nan_to_num(np.abs(x - y), nan=0.0).max()) if x.size else 0.0
    if worst > NPY_TOLERANCE:
        return [Difference(path, f"npy values (more than {NPY_TOLERANCE} apart)", "", f"{worst:.6g}")]
    return []


RULES["npy_within_1e_3"] = _npy_within_1e_3


class JsonRule:
    """A rule that compares a JSON file as usual, after ``transform`` changed each side's value (a copy)."""

    def __init__(self, transform: Callable[[Any], Any]):
        self.transform = transform

    def __call__(self, path: str, fa: Path, fb: Path) -> list["Difference"]:
        raise TypeError("a JsonRule is applied by _file")


def _undo_fingerprints(value: Any) -> Any:
    """An undo snapshot's manifest without its stores' fingerprints (Task 43): the hash of a store as it was, and a
    store that holds a project made during the scenario holds that side's random id, so its hash differs by design.
    Whether the stores were the same shows in the store files themselves and in what each undo answers."""
    for store in (value.get("stores") or []) if isinstance(value, dict) else []:
        if isinstance(store, dict) and isinstance(store.get("fingerprint"), str):
            store["fingerprint"] = PRESENT
    return value


RULES["undo_fingerprints"] = JsonRule(_undo_fingerprints)


def _undo_all_fingerprints(value: Any) -> Any:
    """``_undo_fingerprints``, and the meetings' fingerprints too (Task 45): an imported meeting's ``imported.json``
    holds the seconds each side exported and imported it, so the hash of the meeting (``meetings``) and of a meeting
    the change made (``created_fingerprints``) differs whenever the sides ran a second apart. The meetings' files, and
    their copies in the snapshot, are compared themselves."""
    value = _undo_fingerprints(value)
    if not isinstance(value, dict):
        return value
    for entry in (value.get("meetings") or {}).values() if isinstance(value.get("meetings"), dict) else []:
        if isinstance(entry, dict) and isinstance(entry.get("fingerprint"), str):
            entry["fingerprint"] = PRESENT
    created = value.get("created_fingerprints")
    if isinstance(created, dict):
        for key in created:
            if isinstance(created[key], str):
                created[key] = PRESENT
    return value


RULES["undo_all_fingerprints"] = JsonRule(_undo_all_fingerprints)


@dataclass(frozen=True)
class Difference:
    path: str            # relative to the side ("Recordings/<id>/notes.json"), or "result[i] <op>"
    where: str           # a JSON key path ("$.speakers[0].name"), "format", "bytes", "line N", "file", "dir"
    python: str | None   # what Python has there; None in real mode (values are never shown)
    swift: str | None

    def __str__(self) -> str:
        if self.python is None and self.swift is None:
            return f"{self.path}  {self.where}"
        return f"{self.path}  {self.where}\n    python: {self.python}\n    swift:  {self.swift}"


def json_formats(text: str, value: Any) -> list[tuple[int | None, bool, bool]]:
    """Every (indent, ensure_ascii, trailing newline) ``json.dumps`` writes ``text`` with."""
    newline = text.endswith("\n")
    body = text[:-1] if newline else text
    return [(indent, ascii_, newline) for indent, ascii_ in FORMATS
            if json.dumps(value, indent=indent, ensure_ascii=ascii_) == body]


def _format_text(formats: list[tuple[int | None, bool, bool]]) -> str:
    if not formats:
        return "not json.dumps"
    indent, ascii_, newline = formats[0]
    return f"indent={indent} ensure_ascii={ascii_}" + (" +newline" if newline else "")


def _skipped(name: str) -> bool:
    return name in SKIPPED_NAMES or name.endswith(SKIPPED_SUFFIXES)


def _walk(root: Path, roots: Iterable[str] | None) -> tuple[dict[str, Path], set[str]]:
    """Files (by path relative to ``root``) and empty folders under ``root``'s ``roots``."""
    files, empty = {}, set()
    starts = [root / r for r in roots] if roots is not None else [root]
    for start in starts:
        if start.is_file() and not _skipped(start.name):
            files[str(start.relative_to(root))] = start
            continue
        for p in sorted(start.rglob("*")) if start.is_dir() else []:
            if p.is_symlink() or _skipped(p.name):
                continue
            if p.is_file():
                files[str(p.relative_to(root))] = p
            elif p.is_dir() and not any(p.iterdir()):
                empty.add(str(p.relative_to(root)))
    return files, empty


def read_text(f: Path) -> str | None:
    if f.suffix in BINARY_SUFFIXES:
        return None
    try:
        return f.read_bytes().decode("utf-8")
    except (OSError, UnicodeDecodeError):
        return None


class _Side:
    """One side's normalization: its path, and the tokens and ids new on this side."""

    def __init__(self, root: Path):
        self.root = root
        self.prefixes = sorted({str(root), str(root.resolve())}, key=len, reverse=True)
        self.new: set[str] = set()
        self.numbers: dict[str, str] = {}

    def text(self, s: str) -> str:
        for prefix in self.prefixes:
            s = s.replace(prefix, "<side>")
        s = TOKEN.sub(lambda m: self._number(m.group(), "token"), s)
        return ID.sub(lambda m: self._short(m.group()), s)

    def _short(self, found: str) -> str:
        """An 8-hex id, or the start of a token numbered already (an undo's set-aside folder)."""
        if found in self.new:
            for token, number in self.numbers.items():
                if len(token) == 32 and token.startswith(found):
                    return number[:-1] + ":8>"
        return self._number(found, "id")

    def _number(self, found: str, kind: str) -> str:
        if found not in self.new:
            return found
        if found not in self.numbers:
            n = sum(1 for v in self.numbers.values() if v.startswith(f"<{kind}"))
            self.numbers[found] = f"<{kind}{n + 1}>"
        return self.numbers[found]

    def number_tokens(self, rels: Iterable[str]) -> None:
        """Number the new tokens that name folders (undo snapshots) in the order the folders
        were created; ties and the rest in order of first appearance."""
        born: dict[str, tuple[float, int]] = {}
        for order, rel in enumerate(rels):
            parts = Path(rel).parts
            for i, part in enumerate(parts):
                for m in TOKEN.finditer(part):
                    if m.group() in self.new:
                        st = (self.root / Path(*parts[:i + 1])).stat()
                        when = (getattr(st, "st_birthtime", None) or st.st_mtime, order)
                        born[m.group()] = min(born.get(m.group(), when), when)
        for token in sorted(born, key=born.__getitem__):
            self._number(token, "token")

    def number_set_asides(self, rels: Iterable[str]) -> None:
        """Number the ids of an undo's set-aside folders (``.trash/undone-<token[:8]>``) whose token was never shown
        (a change that failed and was rolled back) in the order the folders were created; the others read as the start
        of their token (``_short``). Call it once the tokens of the answers are numbered."""
        born: dict[str, tuple[float, int]] = {}
        for order, rel in enumerate(rels):
            parts = Path(rel).parts
            for i, part in enumerate(parts):
                m = re.fullmatch(r"undone-([0-9a-f]{8})", part)
                if not m or m.group(1) not in self.new:
                    continue
                if any(len(t) == 32 and t.startswith(m.group(1)) for t in self.numbers):
                    continue
                st = (self.root / Path(*parts[:i + 1])).stat()
                when = (getattr(st, "st_birthtime", None) or st.st_mtime, order)
                born[m.group(1)] = min(born.get(m.group(1), when), when)
        for found in sorted(born, key=born.__getitem__):
            self._number(found, "id")

    def value(self, v: Any) -> Any:
        if isinstance(v, str):
            return self.text(v)
        if isinstance(v, list):
            return [self.value(x) for x in v]
        if isinstance(v, dict):
            return {self.text(k): (PRESENT if k in VOLATILE else self.value(x)) for k, x in v.items()}
        return v


def _ids(texts: Iterable[str]) -> set[str]:
    """The 32-hex tokens and 8-hex ids in ``texts``."""
    out = set()
    for t in texts:
        out |= {m.group() for m in TOKEN.finditer(t)}
        out |= {m.group() for m in ID.finditer(TOKEN.sub("", t))}
    return out


def ids(side: Path, roots: Iterable[str] | None = None) -> set[str]:
    """The tokens and ids in a side's paths and files: before a scenario, the corpus'
    ``known_ids``."""
    files, empty = _walk(side, list(roots) if roots is not None else None)
    return _ids([*files, *empty, *(t for t in map(read_text, files.values()) if t)])


def _show(v: Any) -> str:
    s = v if isinstance(v, str) and v.startswith("<") else json.dumps(v, ensure_ascii=False)
    return s if len(s) <= SHOWN else s[:SHOWN] + "…"


def _key(k: str) -> str:
    return f".{k}" if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]*", k) else f"[{json.dumps(k, ensure_ascii=False)}]"


def _values(path: str, where: str, p: Any, s: Any) -> Iterator[Difference]:
    """Where two (normalized) JSON values differ, outermost first."""
    if isinstance(p, dict) and isinstance(s, dict):
        for k in p:
            if k not in s:
                yield Difference(path, where + _key(k), _show(p[k]), "missing")
        for k in s:
            if k not in p:
                yield Difference(path, where + _key(k), "missing", _show(s[k]))
        common = [k for k in p if k in s]
        if common != [k for k in s if k in p]:
            yield Difference(path, where + " (key order)", _show(common), _show([k for k in s if k in p]))
        for k in common:
            yield from _values(path, where + _key(k), p[k], s[k])
    elif isinstance(p, list) and isinstance(s, list):
        if len(p) != len(s):
            yield Difference(path, where + " (length)", str(len(p)), str(len(s)))
        for i, (x, y) in enumerate(zip(p, s)):
            yield from _values(path, f"{where}[{i}]", x, y)
    elif json.dumps(p) != json.dumps(s):  # 1 vs 1.0, True vs 1, Python's float repr
        yield Difference(path, where, _show(p), _show(s))


def _json(path: str, a: str, b: str, sa: _Side, sb: _Side,
          transform: Callable[[Any], Any] | None = None) -> list[Difference] | None:
    """None when either is no JSON. ``transform``: a JsonRule's, on each value before the comparison."""
    try:
        va, vb = json.loads(a), json.loads(b)
    except ValueError:
        return None
    ta, tb = (transform(json.loads(a)), transform(json.loads(b))) if transform else (va, vb)
    out = list(_values(path, "$", sa.value(ta), sb.value(tb)))
    fa, fb = json_formats(a, va), json_formats(b, vb)
    if ((fa or fb) and not set(fa) & set(fb)) or (not fa and not fb and sa.text(a) != sb.text(b)):
        out.append(Difference(path, "format", _format_text(fa), _format_text(fb)))
    return out


def _line_formats(line: str, value: Any) -> set[bool]:
    """The ``ensure_ascii`` values ``json.dumps`` (no indent) writes ``line`` with."""
    return {a for a in (False, True) if json.dumps(value, ensure_ascii=a) == line}


def _jsonl(path: str, a: str, b: str, sa: _Side, sb: _Side) -> list[Difference] | None:
    la, lb = a.splitlines(), b.splitlines()
    try:
        va, vb = [json.loads(x) for x in la], [json.loads(x) for x in lb]
    except ValueError:
        return None
    out = [] if len(la) == len(lb) else [Difference(path, "lines", str(len(la)), str(len(lb)))]
    for i, (x, y) in enumerate(zip(va, vb)):
        out += _values(path, f"line {i + 1}: $", sa.value(x), sb.value(y))
        fx, fy = _line_formats(la[i], x), _line_formats(lb[i], y)
        if not fx & fy:
            show = lambda f: f"ensure_ascii={sorted(f)[0]}" if f else "not json.dumps"  # noqa: E731
            out.append(Difference(path, f"line {i + 1}: format", show(fx), show(fy)))
    if a.endswith("\n") != b.endswith("\n"):
        out.append(Difference(path, "final newline", str(a.endswith("\n")), str(b.endswith("\n"))))
    return out


def _text(path: str, a: str, b: str, sa: _Side, sb: _Side) -> list[Difference]:
    la, lb = sa.text(a).split("\n"), sb.text(b).split("\n")
    for i, (x, y) in enumerate(zip(la, lb)):
        if x != y:
            return [Difference(path, f"line {i + 1}", _show(x), _show(y))]
    return [] if len(la) == len(lb) else [Difference(path, "lines", str(len(la)), str(len(lb)))]


def _bytes(data: bytes) -> str:
    return f"{len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()[:12]}"


UNDO_MANIFEST = "*.trash/.undo/*/manifest.json"


def _folder_store_fingerprints(value: Any) -> Any:
    """An undo manifest's fingerprints of folder stores (``dir:…``, the voice bank) read ``<present>``, always: a
    folder's hash covers its files' ``added`` stamps (wall-clock seconds, in ``VOLATILE``), so it differs whenever the
    sides learned a voice a second apart (seen as a flake of server-people under load). The folder's copy in the
    snapshot (``stores/<n>/``) is compared file by file, its stamps for presence, and what each undo answers shows
    whether the folder was the same. A file store's fingerprint is still compared."""
    for store in (value.get("stores") or []) if isinstance(value, dict) else []:
        if isinstance(store, dict) and isinstance(store.get("fingerprint"), str) and store["fingerprint"].startswith("dir:"):
            store["fingerprint"] = PRESENT
    return value


def _file(path: str, fa: Path, fb: Path, sa: _Side, sb: _Side, rules: dict[str, Rule]) -> list[Difference]:
    transform = None
    for pattern, rule in rules.items():
        if fnmatch.fnmatch(path, pattern):
            if not isinstance(rule, JsonRule):
                return rule(path, fa, fb)
            transform = rule.transform
            break
    if fnmatch.fnmatch(path, UNDO_MANIFEST):
        given = transform
        transform = (lambda v: given(_folder_store_fingerprints(v))) if given else _folder_store_fingerprints
    a, b = read_text(fa), read_text(fb)
    if a is None or b is None:
        da, db = fa.read_bytes(), fb.read_bytes()
        return [] if da == db else [Difference(path, "bytes", _bytes(da), _bytes(db))]
    found = None
    if fa.suffix == ".json":
        found = _json(path, a, b, sa, sb, transform)
    elif fa.suffix == ".jsonl":
        found = _jsonl(path, a, b, sa, sb)
    return found if found is not None else _text(path, a, b, sa, sb)


Result = tuple[str, Any, Any, bool]  # (label, Python's answer, Swift's, an error expected)


def compare(a: Path, b: Path, *, real: bool = False, rules: dict[str, Rule] | None = None,
            roots: Iterable[str] | None = None, results: list[Result] | None = None,
            known_ids: set[str] | None = None) -> list[Difference]:
    """The differences between side ``a`` (Python's) and side ``b`` (Swift's), under ``roots``
    (folders and files of the sides; all of them when None), and between the ops' ``results``.
    ``known_ids``: the tokens and ids the sides started with (the corpus'); without it, one is
    new when only one side has it. ``real``: values are never kept, only where they differ."""
    roots = list(roots) if roots is not None else None
    files_a, empty_a = _walk(a, roots)
    files_b, empty_b = _walk(b, roots)
    texts_a = {rel: read_text(f) for rel, f in files_a.items()}
    texts_b = {rel: read_text(f) for rel, f in files_b.items()}
    results = results or []
    seen_a = [*files_a, *empty_a, *(t for t in texts_a.values() if t), *(json.dumps(r[1]) for r in results)]
    seen_b = [*files_b, *empty_b, *(t for t in texts_b.values() if t), *(json.dumps(r[2]) for r in results)]
    ids_a, ids_b = _ids(seen_a), _ids(seen_b)
    sa, sb = _Side(a), _Side(b)
    sa.new = ids_a - known_ids if known_ids is not None else ids_a - ids_b
    sb.new = ids_b - known_ids if known_ids is not None else ids_b - ids_a
    sa.number_tokens([*files_a, *sorted(empty_a)])
    sb.number_tokens([*files_b, *sorted(empty_b)])
    for r in results:  # tokens gone with their snapshot: in the order the answers gave them
        sa.text(json.dumps(r[1]))
        sb.text(json.dumps(r[2]))
    sa.number_set_asides([*files_a, *sorted(empty_a)])  # those of rolled-back changes: in the order they were made
    sb.number_set_asides([*files_b, *sorted(empty_b)])
    for t in seen_a:  # the rest numbered in order of first appearance: paths, contents, results
        sa.text(t)
    for t in seen_b:
        sb.text(t)

    out: list[Difference] = []
    by_a, by_b = _by_name(files_a, sa, "python", out), _by_name(files_b, sb, "swift", out)
    collided = {d.path for d in out}
    for rel in sorted((set(by_a) | set(by_b)) - collided):
        if rel not in by_b:
            out.append(Difference(rel, "file", "present", "missing"))
        elif rel not in by_a:
            out.append(Difference(rel, "file", "missing", "present"))
        else:
            out += _file(rel, files_a[by_a[rel]], files_b[by_b[rel]], sa, sb, rules or {})
    dirs_a, dirs_b = {sa.text(d) for d in empty_a}, {sb.text(d) for d in empty_b}
    for d in sorted(dirs_a ^ dirs_b):
        out.append(Difference(d + "/", "dir", "present" if d in dirs_a else "missing",
                              "present" if d in dirs_b else "missing"))
    for label, p, s, expected in results:
        out += _result(label, p, s, sa, sb, expected=expected)
    if real:
        out = [Difference(d.path, d.where, None, None) for d in out]
    return out


def _by_name(files: dict[str, Path], side: _Side, who: str, out: list[Difference]) -> dict[str, str]:
    """Normalized path → the file's path; files that read the same are a "collision" (in ``out``),
    and that path is compared no further."""
    groups: dict[str, list[str]] = {}
    for rel in files:
        groups.setdefault(side.text(rel), []).append(rel)
    for name, rels in groups.items():
        if len(rels) > 1:
            shown = ", ".join(rels)
            out.append(Difference(name, "collision", shown if who == "python" else "", shown if who == "swift" else ""))
    return {name: rels[0] for name, rels in groups.items() if len(rels) == 1}


def _error(v: Any, side: _Side) -> tuple[str, str] | None:
    """(kind, message) of an op's error answer, the message normalized."""
    if isinstance(v, dict) and set(v) == {"error", "kind"}:
        return str(v["kind"]), side.text(str(v["error"]))
    return None


def _result(label: str, p: Any, s: Any, sa: _Side, sb: _Side, *, expected: bool) -> list[Difference]:
    """Two ops' answers. A harness error is always a difference; domain errors match only on a
    step that expects one, with the same kind and message."""
    ep, es = _error(p, sa), _error(s, sb)
    show = lambda e: "answered" if e is None else f"{e[0]}: {e[1]}"  # noqa: E731
    if (ep and ep[0] in HARNESS_ERRORS) or (es and es[0] in HARNESS_ERRORS):
        return [Difference(label, "harness error", show(ep), show(es))]
    if ep is None and es is None:
        out = list(_values(label, "$", sa.value(p), sb.value(s)))
        return out + ([Difference(label, "error expected", "answered", "answered")] if expected else [])
    if not expected:
        return [Difference(label, "error", show(ep), show(es))]
    if ep is None or es is None or ep != es:
        return [Difference(label, "error", show(ep), show(es))]
    return []
