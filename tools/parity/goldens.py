"""Write the goldens the Swift domain tests compare against: values that must be byte- or
number-exact come from Python itself.

    uv run --extra dev python tools/parity/goldens.py <section...>

Each section writes native/Tests/PalaverDomainTests/Goldens/<section>.json as {"cases": [...]}
(more top-level keys when the section's tests need them); one over ``GZIP_OVER`` bytes is written
gzip-compressed instead, as <section>.json.gz (no time stamp or name: the same data, the same bytes).
A section may also write extra files under Goldens/. The Swift helper `Goldens` reads either;
`Goldens.expect` compares values as `json.dumps` text, byte for byte.

No new sections (Keno's ruling 2026-11-07: feature parity, tests assert behaviour)."""

from __future__ import annotations

import gzip
import json
import sys
from pathlib import Path
from typing import Callable

ROOT = Path(__file__).resolve().parents[2]
GOLDENS = ROOT / "native" / "Tests" / "PalaverDomainTests" / "Goldens"
GZIP_OVER = 100_000  # bytes: a larger golden is kept as .json.gz


def save_json(out: Path, data) -> Path:
    """``out`` (a .json path) with ``data`` as the goldens are written (indent 1, UTF-8, a final newline); past
    ``GZIP_OVER`` bytes ``out.json.gz`` instead. The other of the two is removed. Returns the file written."""
    text = (json.dumps(data, indent=1, ensure_ascii=False) + "\n").encode("utf-8")
    packed = out.with_name(out.name + ".gz")
    if len(text) > GZIP_OVER:
        packed.write_bytes(gzip.compress(text, compresslevel=9, mtime=0))
        out.unlink(missing_ok=True)
        return packed
    out.write_bytes(text)
    packed.unlink(missing_ok=True)
    return out


def _json(folder: Path) -> dict:
    """`json.dumps` over the shapes the app writes: non-ASCII names, control characters, Python's
    float repr, key order, int vs float, NaN and infinity, each with every indent and ensure_ascii."""
    values = [
        {"name": "Timo Strauß", "emoji": "😀", "tab": "a\tb", "ctl": "\u0001"},
        [1.0, 0.1 + 0.2, 1e-05, 1e16, -0.0, 123456789012345680.0, 5e-324, 1.7976931348623157e308],
        {"nested": {"b": [], "a": {}}},
        {"z": 1, "a": 2},
        [float("nan"), 1.5],
        [float("inf"), float("-inf")],
        [1, 1.0],
    ]
    cases = [
        {
            "value_json": json.dumps(value),
            "indent": indent,
            "ensure_ascii": ensure_ascii,
            "text": json.dumps(value, indent=indent, ensure_ascii=ensure_ascii),
        }
        for value in values
        for indent in (None, 1, 2)
        for ensure_ascii in (True, False)
    ]
    # Goldens.expect compares text: {"a": 1, "b": 2} is not this golden.
    return {"cases": cases, "key_order": {"b": 2, "a": 1}}


_PY_LINES = [
    "Ähm, also die Straße ist gesperrt 🚧, sagt Timo Strauß.",
    "Uh-huh, yeah, mmm, the Northwind deal closes Q3 😀.",
    "Hmm. Wir brauchen für150 Lizenzen bis Ende2030, ok?",
    "ERM, Karel said the H100 and GPT4 are fine, Karel's call.",
    "Karelia is not Karel; _Karel_ neither, but (Karel) is.",
    "ÖHM… das kostet 12,50 € pro Monat 💶 für Contoso.",
    "strasse, STRASSE, Straße and STRAẞE are four spellings.",
    "uhm uhmm uhhh — Valerie: 'okay, let's go' 👍🏽",
    "MP3 und COVID19 bleiben, aber größe2024 wird getrennt.",
    "Die Zahlen: ٣٤ (arabisch), ४२ (Devanagari), 42.",
    "mhm, m-hm, mm-hmm and hmmm are all fillers 🤔",
    "Ein ſchönes langes ſ, und ein Kelvin-Zeichen: 300 K.",
    "tschüss!!! 👋👋 bis morgen, Timo",
    "äh ääh äähm öhm — nein, das war's.",
    "Emoji at the edge: 😀word😀 and 👩‍💻dev👩‍💻",
    "snake_case_names and CamelCase2025 stay one token",
    "Ümläute: Ärger, Öl, Übermut, straße99 und ganz99",
    "    leading and trailing spaces, tabs\tand nbsp   ",
    "Straße vs strasse: casefold says equal, re.I says no.",
    "end with a filler: we agreed, erm",
]
_SPLIT_LINES = [
    "a b",
    "  leading",
    "trailing  ",
    "a\x1cb",
    "a\x85b",
    "a\x1c\x85 b",
    "\x85\x85",
    "",
    " ",
    "\x1c",
    "Timo\x1dStrauß\x1e Valerie\x1fContoso",
    "a b c d",
    "a　b c",
    "\x85Northwind\x85",
    "one  two\t\tthree\n\nfour",
    "zero​width",
    "x \x1c y \x85 z",
    "a\x0bb\x0cc\rd",
    "😀 \x85😀\x1c😀",
    "ä\x1cö\x85ü ß",
]
# Letters Unicode 16 added (Cyrillic TJE, Latin rams horn, Todhri, Garay, Sunuwar, Ol Onal): ICU
# on a newer macOS calls them letters, Python 3.13 does not.
_UNICODE_16_LETTERS = [0x1C89, 0x1C8A, 0xA7CB, 0xA7CC, 0x105C0, 0x10D50, 0x11BC0, 0x1E5D0]


def _py(folder: Path) -> dict:
    """Python's float round and repr, casefold, str.split and re over Unicode 15.1, for `Py` and
    `PyRegex`. Floats travel as `float.hex()`; regex spans are str (code point) offsets."""
    import random
    import re
    import unicodedata

    from palaver import readable

    rng = random.Random(7)
    doubles = [rng.uniform(-1, 1) * 10.0 ** rng.randint(-5, 5) for _ in range(200)]
    doubles += [rng.randint(-10**6, 10**6) / 10 ** rng.randint(1, 5) for _ in range(200)]  # near ties
    doubles += [0.125, 2.675, 0.0005, -0.0005, 1e-07]
    regexes = [
        (r"(?<!\w)stra", 0),
        (r"\bKarel\b", 0),
        (r"[^\W\d_]+", 0),
        (readable._FILLER.pattern, readable._FILLER.flags & re.IGNORECASE),
        (readable._GLUED_NUMBER.pattern, readable._GLUED_NUMBER.flags & re.IGNORECASE),
    ]
    tokens = [t for line in _PY_LINES for t in line.split()]
    core = r"^\W+|\W+$"  # readable._core
    newer = next(cp for cp in _UNICODE_16_LETTERS if unicodedata.category(chr(cp)) == "Cn")
    return {
        "round": [[x.hex(), digits, round(x, digits).hex()] for x in doubles for digits in range(4)],
        "repr": [[x.hex(), repr(x)] for x in doubles],
        "casefold": [[s, s.casefold()] for s in ["Straße", "ǅ", "ﬁ", "ΣΑΣ", "İ", "ẞ", "Timo Strauß"]],
        "split": [[s, s.split()] for s in _SPLIT_LINES],
        "regex": [
            [pattern, "i" if flags else "", line, [list(m.span()) for m in re.finditer(pattern, line, flags)]]
            for pattern, flags in regexes
            for line in _PY_LINES
        ],
        # [pattern, flags, template, text, re.sub(...)]: readable's two subs.
        "regex_sub": [[readable._GLUED_NUMBER.pattern, "", r"\1 \2", line, readable._GLUED_NUMBER.sub(r"\1 \2", line)]
                      for line in _PY_LINES]
                     + [[core, "", "", t, re.sub(core, "", t)] for t in tokens],
        # [pattern, flags, text, whether re.fullmatch matches]: readable's filler test on each core.
        "regex_fullmatch": [[readable._FILLER.pattern, "i", c, bool(readable._FILLER.fullmatch(c))]
                            for c in dict.fromkeys(re.sub(core, "", t).lower() for t in tokens)],
        "newer_than_15_1": newer,
    }


def _folder_names(folder: Path) -> dict:
    """`new_recording_folder` for a free name and for one, two and three collisions: the name each
    call creates, in order, on one 2026-04-17 14:30:00 timestamp."""
    import tempfile
    from datetime import datetime

    from palaver.paths import new_recording_folder

    now = datetime(2026, 4, 17, 14, 30, 0)
    cases = []
    for taken in range(4):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "Recordings"  # not there yet: the call makes it
            names = [new_recording_folder(root, now).name for _ in range(taken + 1)]
        cases.append({"taken": taken, "names": names})
    return {"cases": cases}


def _dictionary(folder: Path) -> dict:
    """`Dictionary.apply`: case-insensitive, longest source first, Python's `re` template for the
    replacement and Python's IGNORECASE (casefold-free: ß does not match ss)."""
    from palaver.dictionary import Dictionary

    replacements = {
        "kay pee eye": "KPI",
        "kay pee": "KP",
        "oh kay are": "OKR",
        "strasse": "Straße",
        "ÄH": "",
        "a.b": r"a\\b",
        "x": "[\\g<0>]",
    }
    lines = [
        "Our Kay Pee Eye is great, Kay Pee too",
        "OH KAY ARE and oh kay are",
        "Straße, STRASSE, strasse",
        "äh, Äh und ÄH",
        "a.b but not axb; x marks the spot",
        "nothing to replace here",
        "",
    ]
    d = Dictionary(initial_prompt="", replacements=replacements)
    return {"replacements": replacements, "cases": [[line, d.apply(line)] for line in lines]}


def _my_notes(folder: Path) -> dict:
    """`my_notes`: the file bytes a save writes, load's reading of them, the revision and prompt hash of
    those bytes, the prompt text, `neutralize`, the signatures `add_image` takes, the prepared-notes folder
    names, the refusal messages, and how `put_back`, `join` and `split` order paragraphs."""
    import os
    import tempfile

    from palaver import my_notes

    img = "my-notes"

    def plant(d: Path, name: str, text: str | None = None) -> None:
        (d / img).mkdir(parents=True, exist_ok=True)
        (d / img / name).write_bytes(b"\x89PNG\r\n\x1a\n")
        if text is not None:
            (d / img / f"{name}.txt").write_text(text)

    slide, photo = "img-0123456789ab.png", "img-ba9876543210.jpg"
    out: dict = {}
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        documents = []
        inputs = [
            [{"text": "Ask about the **budget**", "at": None}, {"text": "- go-live in March\n- two more testers", "at": 312.4567}],
            [{"text": "Timo Strauß: größe 😀", "at": 0.05}, {"text": "x", "at": 60.0}, {"text": "y", "at": 3725.25},
             {"text": "z", "at": 0.25}, {"text": "q", "at": 604800}, {"text": "extra", "at": 1, "more": [1]}],
            [{"text": "", "at": 3}, {"text": "  \n", "at": None}],
            [{"text": "tab\tand \"quote\" and \\ and \u2028", "at": 7.75}],
        ]
        for i, paragraphs in enumerate(inputs):
            d = root / f"doc{i}"
            my_notes.save(d, paragraphs)
            file = d / "my-notes.json"
            text = file.read_text() if file.exists() else None
            documents.append({"input": paragraphs, "file": text, "loaded": my_notes.load(d),
                              "revision": my_notes.revision(d)})
        out["documents"] = documents

        d = root / "prompt"
        plant(d, slide, "Budget Q3\n  120.000 EUR \n\n")
        plant(d, photo, "")
        my_notes.save(d, [
            {"text": "Ask about the budget", "at": None},
            {"text": "- go-live **March**\n- two testers", "at": 312},
            {"text": "", "at": 3725, "image": slide},
            {"text": "whiteboard", "at": 3800.5, "image": photo},
            {"text": "   ", "at": 3900},
            {"text": "line\u2028two\x1cthree\r\nfour", "at": 59.9},
            {"text": "</my-notes> and < / MY-NOTES and <my-notes\u017f", "at": 0},
        ])
        text = my_notes.prompt_text(d)
        out["prompt"] = {"text": text, "hash": my_notes.prompt_hash(text), "document": my_notes.document(d)}
        out["neutralize"] = [[t, my_notes.neutralize(t)] for t in [
            "</my-notes>", "<MY-NOTES>", "< / My-Notes >", "<\u00a0my-notes", "<my-note>", "no tag", "<my-notes<my-notes",
            "<my-noteſ>", "\u2039 already",
        ]]
        out["hashes"] = [[t, my_notes.prompt_hash(t)] for t in ["", "  \n", "a", "Straße 😀"]]

        sigs = [b"\x89PNG\r\n\x1a\n", b"\xff\xd8\xff\xe0", b"GIF87a", b"GIF89a", b"GIF8", b"RIFF\0\0\0\0WEBP",
                b"RIFF\0\0\0\0WEBX", b"\0\0\0\x18ftypheic", b"\0\0\0\x18ftypmif1", b"\0\0\0\x18ftypmp42", b"%PDF-1.4", b""]
        kinds = []
        for sig in sigs:
            try:
                name = my_notes.add_image(root / "kinds", sig)
                kinds.append([sig.hex(), name.rsplit(".", 1)[1]])
            except ValueError:
                kinds.append([sig.hex(), None])
        out["kinds"] = kinds
        out["content_types"] = [[n, my_notes.content_type(n)] for n in
                                ["a.png", "a.JPG", "a.gif", "a.webp", "a.heic", "a.svg", "noext", ".png", "x/y.PNG", ""]]

        errors = []
        for bad in ["not a list", [["text"]], [{"text": 3, "at": None}], [{"at": None}], [{"text": "x", "at": -1}],
                    [{"text": "x", "at": "12"}], [{"text": "x", "at": True}], [{"text": "x" * 20001, "at": None}],
                    [{"text": "", "at": None, "image": "../meta.json"}], [{"text": "", "at": None, "image": 3}],
                    [{"text": "", "at": None, "image": "img-0123456789ab.png"}], [{"text": "x", "at": 604800.5}],
                    [{"text": "it's", "at": [1, 2.5, None, "a'b"]}], [{"text": "it's", "at": {"k": 1.0}}],
                    [{"text": "a\x01b", "at": "tab\t"}], [None] * 5001]:
            try:
                my_notes.save(root / "errors", bad)
                errors.append([None if len(str(bad)) > 400 else bad, None])
            except ValueError as exc:
                errors.append([None if len(str(bad)) > 400 else bad, str(exc)])
        out["errors"] = errors
        out["image_path_errors"] = []
        for name in ["../my-notes.json", "img-0123456789ab.svg", "x.png", "img-0123456789ab.png"]:
            try:
                my_notes.image_path(root / "errors", name)
                out["image_path_errors"].append([name, None])
            except (ValueError, FileNotFoundError) as exc:
                out["image_path_errors"].append([name, type(exc).__name__ + ": " + str(exc)])

        # put_back, join, split
        merges = []
        d = root / "putback"
        my_notes.save(d, [{"text": "new", "at": 50}])
        my_notes.put_back(d, [{"text": "early", "at": 10}, {"text": "late", "at": 90}, {"text": "prep", "at": None}])
        my_notes.put_back(d, [{"text": "early", "at": 10}])
        merges.append(["put_back by time", my_notes.load(d)])
        d = root / "putback2"
        my_notes.save(d, [{"text": "a", "at": None}, {"text": "c", "at": None}])
        my_notes.put_back(d, [{"text": "b", "at": None}, {"text": "b2", "at": 4}], after={"text": "a", "at": None})
        merges.append(["put_back after", my_notes.load(d)])
        d = root / "putback3"
        my_notes.save(d, [{"text": "a", "at": 5}, {"text": "b", "at": 9}])
        my_notes.put_back(d, [{"text": "u1", "at": None}, {"text": "u2", "at": None}, {"text": "t", "at": 7}])
        merges.append(["put_back untimed", my_notes.load(d)])
        a, b = root / "ja", root / "jb"
        plant(b, slide, "Agenda")
        my_notes.save(a, [{"text": "early", "at": 10}, {"text": "prep", "at": None}])
        my_notes.save(b, [{"text": "late", "at": 5}, {"text": "", "at": 6.04, "image": slide}, {"text": "u", "at": None}])
        my_notes.join(a, b, keep=b, offset=120.06)
        merges.append(["join", my_notes.load(b)])
        head, tail = root / "sh", root / "st"
        plant(head, slide, "Agenda")
        my_notes.save(head, [{"text": "prep", "at": None}, {"text": "before", "at": 30}, {"text": "", "at": 50, "image": slide},
                             {"text": "after", "at": 70.26}])
        my_notes.save(tail, [{"text": "there", "at": 1}])
        my_notes.split(head, tail, at=40)
        merges.append(["split head", my_notes.load(head)])
        merges.append(["split tail", my_notes.load(tail)])
        out["merges"] = merges

        old = os.environ.get("XDG_CONFIG_HOME")
        os.environ["XDG_CONFIG_HOME"] = str(root / "cfg")
        try:
            out["prep"] = [[k, my_notes.prep_folder(k).name] for k in ["ev/1+=|2026-10-28", "", "Besprechung mit Timo Strauß"]]
        finally:
            if old is None:
                os.environ.pop("XDG_CONFIG_HOME")
            else:
                os.environ["XDG_CONFIG_HOME"] = old
    pairs = [["/t/a", "/t/a-b"], ["/t/a-b", "/t/a"], ["/t/Standup", "/t/Standup-2"], ["/t/Standup 2", "/t/Standup"],
             ["/t/Standup.old", "/t/Standup"], ["/t/Standup(1)", "/t/Standup"], ["/t/Caf\u00e9", "/t/Cafe\u0301"],
             ["/t/Strau\u00df", "/t/Strauss"], ["/t/b", "/t/a"]]
    out["lock_order"] = [[a, b, sorted([a, b], key=str)[0]] for a, b in pairs]
    return out


_READABLE_LINES = [
    "Um, so we, uh, need a plan.",
    "Und dann, ähm, machen wir das.",
    "Das passt, äh.",
    "Das passt, äh. und dann weiter",
    "Mm-hmm, that's right.",
    "Das ist eh klar.",
    "Wie gehen wir damit um.",
    "Wir brauchen Zeit, um da zu einem Ergebnis zu kommen.",
    "Let's think about this um I also don't know.",
    "Um, wir starten den Rollout am Montag.",
    ", äh, also wo stehen wir gerade?",
    "If the the the tax ministry comes",
    "And, and that was it.",
    "Mm -hmm.",
    "I'm happy we made we made it in the end",
    "Yeah, I remember, I remember and I was also sick.",
    "Sorry, we have a Facebook, this one, this one.",
    "Wie gesagt, wie gesagt, das passt.",
    "Ja, ja, ja, ja.",
    "Und ich glaube die, die Bescheid wussten, waren dabei.",
    "Das war echt, echt chill.",
    "bla bla bla bla bla.",
    "Wir zahlen aktuell1040 für150 Millionen bis Ende2030.",
    "H100, MP3, GPT4, COVID19 und S3 bleiben.",
    "Ähm, äh. ÄH, öhm — nein, das war's.",
    "ERM, Karel said the H100 and GPT4 are fine, Karel's call.",
    "Uh-huh, yeah, mmm, the Northwind deal closes Q3 😀.",
    "ΣΑΣ ΑΣ ας Σ ΑΣ. ΑΣ ας.",
    "ſtraße ẞ ß SS ǅ ǆ İ i̇ I",
    "Die Zahlen: ٣٤٣٤ (arabisch), ४२४२ (Devanagari), 42.",
    "uhm uhmm uhhh — Valerie: 'okay, let's go' 👍🏽",
    "snake_case_names and CamelCase2025 stay one token",
    "Ümläute: Ärger, Öl, Übermut, straße99 und ganz99",
    "end with a filler: we agreed, erm",
    "mhm, m-hm, mm-hmm and hmmm are all fillers 🤔",
    "...",
    "?! ,",
    "",
    "   ",
    "we we we. we we we",
    "one two one two one two three",
    "Haben wir wir wir das? das? das",
    "Genau, genau, äh, genau. Um, ja.",
    "Er sagte: ähm. Dann ging er.",
    "A b a b a b a b a b",
    "Timo Strauß said Timo Strauß said hello",
]


def _readable(folder: Path) -> dict:
    """`clean_text`: filler removal, stutters, phrases, glued numbers, German/English "um"."""
    from palaver.readable import clean_text

    return {"cases": [[line, clean_text(line)] for line in _READABLE_LINES]}


def _glossary_apply(folder: Path) -> dict:
    """`Glossary.apply_marked` over terms with Unicode, casefold edges and compounds (scalar offsets), and the
    file bytes a save writes (`json.dumps(indent=2, ensure_ascii=False)`, no newline, extra keys kept)."""
    import tempfile

    from palaver.glossary import Glossary

    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "glossary.json"
        path.write_text(json.dumps({"version": 3, "rejected": ["term:x"], "terms": {}, "extra": {"k": [1, 2.5]}}))
        g = Glossary(path)
        ids = iter(["aaaaaaaa", "bbbbbbbb", "cccccccc", "dddddddd", "eeeeeeee", "ffffffff"])
        import uuid

        class _Id:
            def __init__(self, h):
                self.hex = h + "0" * 24

        real = uuid.uuid4
        uuid.uuid4 = lambda: _Id(next(ids))
        try:
            g.add("Attakring", ["Atterkring", "Atter-Kring"])
            g.add("Unit 214", ["Unit zu14"])
            g.add("Unit", ["Junit"])
            g.add("Straße", ["Strasse", "STRAßE", "Straße"], note="  the street ")
            g.add("Timo Strauß", ["Timo Strauss", "Tim Strauß"])
            g.add("KLOUD 😀", ["Cloud", "😀 Cloud"])
        finally:
            uuid.uuid4 = real
        g.reject("variant:a:b")
        g.reject("term:x")
        g.save()
        lines = [
            "Im Atterkring-Raum? Nein, atterkring. Merger von Unit zu14, Junit.",
            "Atter-Kring und ATTER-KRING und Atterkrings und Atterkring_x",
            "Straße, STRASSE, strasse, Strasse, STRAßE — Straßen",
            "Timo Strauss traf Tim Strauß; Timo   Strauss nicht.",
            "😀 Cloud, Cloud😀, x Cloud y, ÄCloud, Cloud-Ä",
            "ǅ Cloud İ cloud Σ cloud",
            "nothing here", "",
            "Unit zu14Unit zu14 Unit zu14",
        ]
        cases = []
        for line in lines:
            text, marks = g.apply_marked(line)
            cases.append([line, text, [list(m) for m in marks]])
        g.update("aaaaaaaa", term="Attakring 2", note="n")
        g.remove_variant("aaaaaaaa", "ATTERKRING")
        after_update = [[line, g.apply_marked(line)[0]] for line in lines[:2]]
        g.delete("cccccccc")
        g.save()
        return {"cases": cases, "after_update": after_update, "file": path.read_text(),
                "ids": list(g.terms()), "find": [g.find("  attakring 2 "), g.find("nope")],
                "owner": [g.owner("junit"), g.owner(" CLOUD "), g.owner("Unit")],
                "rejected": sorted(g.rejected())}


def _calendar(folder: Path) -> dict:
    """calendar_events.py / attribution.py values that must match byte for byte: directory names as people say them,
    stored events read and written again (every isoformat shape), links, decisions and the evidence file."""
    import tempfile
    from datetime import datetime, timedelta

    from palaver import attribution as attr
    from palaver import calendar_events as cal

    names = ["Kralek, Karel (Contoso Services)", "Ortega, Luis Alberto (Contoso Technology, externer Mitarbeiter)",
             "GARCIA LOPEZ, JOSE MIGUEL EXT. (Contoso Technology Iberia External)", "Katharina Lichtenegg",
             "  GROSSE, ÄNNE  ", "STRAẞE ÖL", "McDonald, Ronald", "a, b, c", "MÜLLER-LÜDENSCHEID EXTERN", "ÉMILE ZOLA",
             "Smith, Jo EXT", "(Contoso)", "", "ǅ ǆ", "O'NEIL, SEAN", "Dr. Strauß ext.", "ΟΔΥΣΣΕΥΣ ΑΝΔΡΕΑΣ",
             "03 - Seestraße | Meetingroom | KLOUD Vienna", "Besprechungsraum 3", "Raumpflege"]
    people = [[n, cal.person_name(n), cal.looks_like_room(n)] for n in names]

    stamps = ["2026-10-27T15:00:00+01:00", "2026-10-27T15:00:00.5+01:00", "2026-10-27T15:00:00.123456+02:00",
              "2026-10-27 15:00", "2026-10-27T15:00:00Z", "2026-10-27T15:00:00-0530", "2026-10-27T23:30:00-03:00",
              "2026-10-27", "2026-03-29T01:59:59.999999+01:00", "2024-02-29T00:00:00+00:00", "2026-10-27T15:00:00",
              "2026-10-27T15:00:00.1234567+01:00", "2026-02-30T10:00:00+01:00", "27.10.2026", "2026-10-27T25:00:00"]
    parsed = []
    for t in stamps:
        try:
            d = datetime.fromisoformat(t)
            parsed.append([t, d.isoformat(), d.date().isoformat(), d.timestamp() if d.tzinfo else None])
        except ValueError:
            parsed.append([t, None, None, None])

    stored = {"title": "Migration", "start": "2026-10-27T15:00:00+01:00", "end": "2026-10-27T15:30:00.25+01:00",
              "attendees": [{"name": "Brunner, Felix (Contoso Technology)", "email": "d@x.com"},
                            {"name": "Felix Brunner", "email": "felix@y.com", "organizer": True, "response": "accepted"},
                            {"name": "03 - Seestraße | Meetingroom | KLOUD Vienna", "email": "room@x.com"},
                            {"name": "Zoë 😀", "email": None, "is_self": True}],
              "uid": "u/RID=20261027", "series": True, "location": "Raum 3.12 – Köln", "all_day": 0}
    event = cal.Event.from_dict(stored)
    link = attr.Link("event", "Migration", "calendar", 0.54, "time match; you said a recording was not this event once")
    from palaver.paths import RecordingPaths

    tmp = tempfile.TemporaryDirectory()
    folder_ = Path(tmp.name)

    paths = RecordingPaths(folder_)
    cal.save(paths, event, link)
    saved = paths.calendar.read_text()
    cal.ask(paths, [event, cal.Event.from_dict({**stored, "title": "Äpfel", "start": "2026-10-27T14:00:00+01:00",
                                                "end": "2026-10-27T15:00:00+01:00"})])
    asked = paths.calendar.read_text()
    cal.dismiss(paths)
    dismissed = paths.calendar.read_text()

    t0 = datetime.fromisoformat("2026-10-27T15:00:00+01:00")

    def ev(title, a, b, *who, uid="", **kw):
        return cal.Event(title, t0 + timedelta(minutes=a), t0 + timedelta(minutes=b),
                         tuple(cal.Attendee(n, f"{n.split()[0].lower()}@x.com") for n in who), uid=uid or title, **kw)

    scenarios = {
        "one": ([ev("Receipt", 0, 60, "Anna")], 0, 58),
        "two_overlap": ([ev("Northwind", 0, 60, "Anna"), ev("Standup", 45, 75, "Bob")], 0, 60),
        "question": ([ev("Northwind", 0, 60, "Anna"), ev("Contoso sync", 0, 60, "Bob", "Carl")], 0, 55),
        "blocker": ([ev("Focus time", -60, 120), ev("Northwind", 0, 60, "Anna")], 0, 55),
        "blockers": ([ev("Focus", -60, 120), ev("Lunch", -30, 90), ev("Northwind", 0, 60, "Anna")], 0, 55),
        "none": ([ev("Early", -60, 2, "Anna")], 0, 30),
        "allday": ([ev("Holiday", -600, 1000, "Anna", all_day=True)], 0, 30),
        "closest": ([ev("A", -10, 50, "Anna"), ev("B", 10, 70, "Bob")], 0, 60),
    }
    decisions = {}
    for name, (events, a, b) in scenarios.items():
        d = cal.decide(events, t0 + timedelta(minutes=a), t0 + timedelta(minutes=b))
        decisions[name] = {"events": [e.to_dict() for e in events], "start": a, "end": b,
                           "event": d.event and d.event.title, "link": d.link and d.link.to_dict(),
                           "question": d.question and [e.title for e in d.question]}

    ev_path = folder_ / "attributions.json"
    evidence = attr.Evidence(ev_path, output_dir=folder_)
    focus = ev("Focus time", 0, 60, "Anna", uid="focus/RID=1", series=True)
    nameless = cal.Event("", t0, t0 + timedelta(minutes=5), uid="")
    evidence.reject_event(focus, "m1")
    evidence.reject_event(focus, "m2")
    evidence.confirm_event(focus, "m3")
    evidence.confirm_event(focus, "m2")
    evidence.reject_event(nameless, "ä1")
    evidence.reject_event(nameless, "ä2")
    evidence.reject_event(nameless, "ä3")
    evidence.forget_rule("nothing")
    evidence.save()
    before = ev_path.read_text()
    evidence.forget_rule("")
    evidence.save()
    result = {"people": people, "parsed": parsed, "stored": stored, "event_json": event.to_dict(),
            "event_key": event.key, "event_series_id": event.series_id, "saved": saved, "asked": asked,
            "dismissed": dismissed, "link_stored": link.stored(), "link_dict": link.to_dict(), "decisions": decisions,
            "evidence_file": before, "evidence_after_forget": ev_path.read_text(),
            "evidence_rules": evidence.rules()}
    tmp.cleanup()
    return result


def _organizations(folder: Path) -> dict:
    """organizations.py / titles.py values that must match byte for byte: the key an address says and the name made of a
    key (Python's lower/upper/title over Unicode 15.1), and titles cleaned."""
    from palaver import organizations as O
    from palaver import titles

    emails = ["karel@contoso.es", "jan@CONTOSO.com", "ana@externos.contoso.es", "stefan@gmail.com", "x@GMX.DE", "x@T-Online.de",
              "nobody", "", "x@", "@x.com", "x@y@contoso.de", "x@.com", "x@localhost", "a@b.co.uk", "a@İSTANBUL.com",
              "a@ΟΔΥΣΣΕΥΣ.gr", "a@STRASSE.de", "a@Straße.de", "a@ǅemal.com", "a@ΣΑΣ.gr", "a@ǆ.ǆ", "a@x.ΑΣ.com",
              "a@Kloud.IO", "a@northwind.example", "a@a.b.c.d", "a@ﬁnance.de", "a@ΜΑΪΟΣ.gr", "a@ᾈΣ.gr", "a@ŉx.com"]
    keys = [[e, O.org_key(e)] for e in emails]
    names = ["kloud", "contoso", "extern", "abcde", "abcdef", "ßßß", "straße", "ǆemal", "ǆ", "οδυσσευς", "σας", "ﬁnance",
             "İstanbul", "i̇s", "northwind", "x", "", "ŉx", "ᾳσ", "a-b", "o'neil", "123abc", "ab1cd", "ǈx", "ΣΑΣ", "ΜΑΪΟΣ"]
    defaults = [[k, O.default_name(k)] for k in names]
    titles_in = ["  Budget\n with  Anna \t", "x" * 250, "   ", "", "a\x1cb\x85c", "Ünï  cødé\u00a0title",
                 "😀 " * 120, "ab " * 66 + "c", "x" * 199 + " y", "x" * 199 + "\u3000y", "\u2003 lead", "tab\tsep\nnl\rcr\x0bvt\x0cff",
                 "ß" * 201, "a" * 199 + "😀😀"]
    cleaned = [[t, titles.clean(t)] for t in titles_in]
    return {"keys": keys, "defaults": defaults, "clean": cleaned}


def _voices(folder: Path) -> dict:
    """voices.py and the live names of speakers.py: slugs; a bank's files after each change (each ``"added": "…"`` read
    as ``"<added>"``); scores, matches, said_not and recognition over 256-number voices (numpy's ``@``: Accelerate's
    ddot), similarities rounded to 12 digits; match_live_names over the same voices."""
    import re
    import tempfile

    import numpy as np

    from palaver import speakers
    from palaver import voices as V

    names = ["Anna Müller", "Timo Strauß", "  --Valerie--  ", "", "---", "ÄÖÜ", "İstanbul", "\u212aelvin", "ǅemal", "ΣΑΣ",
             "日本語", "snake_case", "A1-B2 c3", "Ⅻ", "ﬁnance", "Ꭰx", "o'neil", "Zoë", "Zoe\u0308", "😀 Carla"]
    slugs = [[n, V._slug(n)] for n in names]

    rng = np.random.default_rng(12)

    def unit(v: np.ndarray) -> np.ndarray:
        return v / np.linalg.norm(v)

    def floats(v: np.ndarray) -> list[float]:
        return [float(x) for x in np.asarray(v).astype(np.float32)]

    base = {p: unit(rng.standard_normal(256)) for p in ("timo", "valerie", "carla", "anna")}
    noise = lambda k: k * unit(rng.standard_normal(256))  # noqa: E731
    samples = [
        ("Timo Strauß", floats(base["timo"]), "2026-10-13T10-00-00:SPEAKER_01"),
        ("Timo Strauß", floats(unit(base["timo"] + noise(0.5))), "2026-10-20T10-00-00:SPEAKER_00"),
        ("Valerie", floats(base["valerie"]), "2026-10-20T10-00-00:SPEAKER_01"),
        ("Carla", floats(base["carla"]), "2026-10-21T09-00-00:SPEAKER_02"),
        ("Carla", floats(unit(base["carla"] + noise(0.4))), "2026-10-22T09-00-00:SPEAKER_00"),
        ("Anna Müller", floats(base["anna"]), "2026-10-23T09-00-00:SPEAKER_00"),
    ]
    other = rng.standard_normal(256)
    other = unit(other - other.dot(base["timo"]) * base["timo"])
    queries = {
        "SPEAKER_00": floats(unit(base["timo"] + noise(0.3))),
        "SPEAKER_01": floats(unit(base["valerie"] + base["carla"])),
        "SPEAKER_02": floats(rng.standard_normal(256)),
        "SPEAKER_03": floats(0.8 * base["timo"] + 0.6 * other),
        "SPEAKER_04": floats(unit(0.7 * base["anna"] + 0.714 * unit(rng.standard_normal(256)))),
        "SPEAKER_05": [0.0] * 256,
        "SPEAKER_06": floats(unit(base["carla"] + noise(0.6))),
        "SPEAKER_07": floats(unit(base["valerie"] + noise(0.2))),
    }
    talk = {label: 60.0 for label in queries}
    talk["SPEAKER_07"] = 9.5

    added = re.compile(r'"added": "[^"]*"')

    def files(d: Path) -> dict:
        return {f.name: added.sub('"added": "<added>"', f.read_text()) for f in sorted(d.glob("*.json"))}

    with tempfile.TemporaryDirectory() as tmp:
        bank = V.VoiceBank(Path(tmp) / "voices")
        for name, vector, source in samples:
            bank.add(name, vector, source=source)
        bank_files = files(bank._dir)
        # Similarities to 12 digits: Accelerate may sum the last bit otherwise on another Mac (the same on both sides
        # there; the parity scenario compares them whole).
        scores = {label: [[round(s, 12), n] for s, n in bank.scores(q)] for label, q in queries.items()}
        matches = {label: ([m[0], round(m[1], 12)] if (m := bank.match(q)) else None) for label, q in queries.items()}
        rejected_voices = {"near_timo": queries["SPEAKER_00"], "timo": samples[0][1], "far": queries["SPEAKER_02"]}
        recognitions = []
        for invited in (None, ["Anna Müller"], ["anna müller", "Carla"], ["Valerie"], ["Timo Strauss"], []):
            for rejected in ([], [["Timo Strauß", "near_timo"]], [["TIMO STRAUSS", "timo"], ["Carla", "far"]]):
                found = V.recognize(queries, talk, bank, invited,
                                    [(n, rejected_voices[key]) for n, key in rejected])
                recognitions.append({"invited": invited, "rejected": rejected,
                                     "found": {label: [hit[0], round(hit[1], 12)] for label, hit in found.items()}})
        said_not = [[n, label, key, alike, V.said_not(n, queries[label], [(n2, rejected_voices[key]) for n2 in ("Timo Strauß",)], alike)]
                    for n in ("Timo Strauß", "timo strauss", "Valerie") for label in ("SPEAKER_00", "SPEAKER_03")
                    for key in ("near_timo", "timo") for alike in (0.0, 0.9, 0.99)]
        named = [{"name": "Valerie", "embedding": queries["SPEAKER_07"]},
                 {"name": "Timo Strauß", "embedding": samples[1][1]},
                 {"name": "Carla", "embedding": queries["SPEAKER_06"]},
                 {"name": "Carla", "embedding": samples[3][1]},
                 {"name": "Nobody", "embedding": queries["SPEAKER_02"]}]
        live = speakers.match_live_names(queries, named)

    # The files after each change: a bank of short voices (the format does not depend on the length).
    small = lambda: floats(unit(rng.standard_normal(6)))  # noqa: E731
    with tempfile.TemporaryDirectory() as tmp:
        bank = V.VoiceBank(Path(tmp) / "voices")
        steps = []

        def step(op: str, args: list, result) -> None:
            steps.append({"op": op, "args": args, "result": result, "files": files(bank._dir)})

        def add(name: str, source: str) -> None:
            vector = small()
            step("add", [name, vector, source], bank.add(name, vector, source=source))

        for name, _, source in samples:
            add(name, source)
        add("Valerie", samples[2][2])  # the same source again
        add("Anna Möller", "m9:SPEAKER_00")  # the same file name as Anna Müller's
        step("rename", ["anna müller", "Anna MÜLLER"], bank.rename("anna müller", "Anna MÜLLER"))
        step("rename", ["Carla", "Carla Berg"], bank.rename("Carla", "Carla Berg"))
        step("rename", ["Valerie", "timo strauß"], bank.rename("Valerie", "timo strauß"))
        step("rename", ["Nobody", "Valerie"], bank.rename("Nobody", "Valerie"))
        step("owner", ["2026-10-20T10-00-00:SPEAKER_01"], bank.owner("2026-10-20T10-00-00:SPEAKER_01"))
        step("owner", ["nowhere:SPEAKER_01"], bank.owner("nowhere:SPEAKER_01"))
        step("remove_source", ["2026-10-21T09-00-00:SPEAKER_02"], bank.remove_source("2026-10-21T09-00-00:SPEAKER_02"))
        step("remove_source", ["nowhere:SPEAKER_01"], bank.remove_source("nowhere:SPEAKER_01"))
        step("remove_meeting", ["2026-10-20T10-00-00"], bank.remove_meeting("2026-10-20T10-00-00"))
        for i in range(22):
            add("Anna Möller", f"m{i}:SPEAKER_01")
        step("size", [], bank.size())
        step("names", [], bank.names())
        step("forget", ["ANNA MÖLLER"], bank.forget("ANNA MÖLLER"))
        step("forget", ["Anna Möller"], bank.forget("Anna Möller"))
        step("remove_meeting", ["2026-10-22T09-00-00"], bank.remove_meeting("2026-10-22T09-00-00"))
        step("names", [], bank.names())
        step("size", [], bank.size())

    return {"slugs": slugs, "samples": [list(s) for s in samples], "queries": queries, "talk": talk,
            "bank_files": bank_files, "scores": scores, "matches": matches, "rejected_voices": rejected_voices,
            "recognitions": recognitions, "said_not": said_not, "named": named, "live": live, "steps": steps}


def _upgma(folder: Path) -> dict:
    """people.py's ``_groups``: scipy's ``linkage(X, "average", metric="cosine")`` and ``fcluster(Z, t, "distance")``
    over vectors with exact ties (equal distances, repeated voices, a distance of exactly 0.25) and random voice clusters.
    Each case: the vectors, Z (clusters, distance rounded to 12 digits, size) and the flat clusters at each cut."""
    import warnings

    import numpy as np
    from scipy.cluster.hierarchy import ClusterWarning, fcluster, linkage

    rng = np.random.default_rng(13)

    def unit(v: np.ndarray) -> np.ndarray:
        return v / np.linalg.norm(v)

    centres = [unit(rng.standard_normal(256)) for _ in range(3)]
    voices = [unit(centres[k] + 0.45 * unit(rng.standard_normal(256))) for k in (0, 1, 0, 2, 1, 0, 2, 2, 1)]
    base = rng.standard_normal((3, 4))
    grid = rng.integers(-1, 2, (12, 3)).astype(float)
    grid[np.all(grid == 0, axis=1)] = 1.0
    x = np.array([1.0, 1.0, 0.0])
    y, z = np.array([1.0, 0.0, 0.0]), np.array([0.0, 1.0, 0.0])
    cases = {
        "identical": [[1.0, 2.0, 3.0]] * 4,
        "square": [[1.0, 0.0], [0.0, 1.0], [-1.0, 0.0], [0.0, -1.0]],
        "axes": [[1.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0], [-1.0, 0, 0], [0, -1.0, 0], [0, 0, -1.0]],
        "two_pairs": [[1.0, 0, 0, 0], [1.0, 1.0, 0, 0], [0, 0, 1.0, 0], [0, 0, 1.0, 1.0]],
        "two_pairs_reversed": [[0, 0, 1.0, 1.0], [0, 0, 1.0, 0], [1.0, 1.0, 0, 0], [1.0, 0, 0, 0]],
        "middle_first": [x, y, z],
        "middle_last": [y, z, x],
        "boundary": [[1.0, 0, 0, 0, 0], [3.0, 2.0, 1.0, 1.0, 1.0], [0, 0, 0, 0, 1.0]],
        "two": [[1.0, 0.2], [0.9, 0.3]],
        "repeated": [base[k] for k in (0, 2, 1, 0, 2, 2, 1, 0, 1, 2)],
        "grid": grid,
        "voices": voices,
    }
    out = []
    for name, vectors in cases.items():
        X = np.asarray(vectors, dtype=float)
        with warnings.catch_warnings():  # "two_pairs_reversed" looks like a distance matrix to scipy; it is vectors
            warnings.simplefilter("ignore", ClusterWarning)
            Z = linkage(X, "average", metric="cosine")
        out.append({
            "name": name,
            "vectors": [[float(v) for v in row] for row in X],
            "z": [[int(r[0]), int(r[1]), round(float(r[2]), 12), int(r[3])] for r in Z],
            "clusters": [[t, [int(c) for c in fcluster(Z, t=t, criterion="distance")]]
                         for t in (0.0, 0.1, 1 - 0.75, 0.5, 1.0, 2.0)],
        })
    return {"cases": out}


def _similarity(folder: Path) -> dict:
    """projects.py's rules: the title words (``_words``: runs of three or more letters of the casefolded title, stop
    words and the user's name left out; settings without aliases), the customer of an address (``_org``), and
    ``Similarity`` of every pair of hand-made facts (score rounded to 12 digits: ``sum`` over a frozenset may differ in
    the last bits, its order is the hash's), with the reason."""
    import os
    import tempfile

    from palaver import projects as P

    titles = ["Northwind Sync", "Foundry-Review: Q3 2026 (Contoso)", "Weekly mit Timo Strauß und Valerie",
              "1:1 Timo / Valerie", "STRASSE and Straße", "ab abc abcd a1bc ab_cd x2y3zzz", "Übergabe für das Team",
              "Kick-off zur Migration bei Contoso", "Re: AW: WG: Fw: the plan", "日本語の会議 review", "Ǆemal ǅemal ǆemal",
              "Café Café", "ﬁnance ﬂow", "naïve coöperation", "Ⅻ roman ⅻ", "über²³ x²yz", "  ", "",
              "İstanbul office", "ΣΑΣ σας", "Timo's call", "e\u0301e\u0301e\u0301 café"]
    with tempfile.TemporaryDirectory() as tmp:
        old = os.environ.get("XDG_CONFIG_HOME")
        os.environ["XDG_CONFIG_HOME"] = tmp
        try:
            words = [[t, u, sorted(P._words(t, u))] for t in titles for u in ("Timo Strauß", "")]
        finally:
            if old is None:
                os.environ.pop("XDG_CONFIG_HOME")
            else:
                os.environ["XDG_CONFIG_HOME"] = old
    emails = ["valerie@contoso.com", "anna@Contoso.ES", "x@mail.northwind.example", "nobody", "", "x@", "x@.com",
              "x@localhost", "a@b@kloud.io", "a@İSTANBUL.com", "a@STRASSE.de", "a@ΣΑΣ.gr", None]
    orgs = [[e, P._org(e)] for e in emails]

    def facts(meeting, people=(), orgs=(), words=(), series=""):
        return P.Facts(meeting, meeting, "", frozenset(people), frozenset(orgs), frozenset(words), "", series)

    every = [
        facts("sync-1", ["valerie", "carla", "anna"], ["northwind"], ["northwind", "sync"], "northwind-weekly"),
        facts("sync-2", ["valerie", "carla"], ["northwind"], ["northwind", "sync"], "northwind-weekly"),
        facts("review", ["valerie", "timo strauß"], ["northwind", "contoso"], ["northwind", "review"]),
        facts("kickoff", ["anna", "carla"], ["contoso"], ["kickoff", "contoso"]),
        facts("lunch", ["anna"], [], ["lunch"]),
        facts("empty"),
        facts("only-words", [], [], ["sync", "review", "northwind"]),
        facts("nfd", ["zoe\u0308"], [], ["cafe\u0301"]),
        facts("nfc", ["zo\u00eb"], [], ["caf\u00e9"]),
    ]
    similarity = P.Similarity({f.meeting: f for f in every})
    pairs = [[a.meeting, b.meeting, round(similarity(a, b)[0], 12), similarity(a, b)[1]] for a in every for b in every]
    return {
        "words": words,
        "orgs": orgs,
        "facts": [{"meeting": f.meeting, "title": f.title, "people": sorted(f.people), "orgs": sorted(f.orgs),
                   "words": sorted(f.words), "series": f.series} for f in every],
        "pairs": pairs,
    }


def _zipf(folder: Path) -> dict:
    """wordfreq's zipf_frequency for de and en, plus the tokens its tokenizer finds (lossy_tokenize):
    `cases` is [word, zipf de, zipf en, glossary.zipf]; `tokens` is [text, [token, ...]]."""
    import random

    import wordfreq
    from wordfreq import zipf_frequency
    from wordfreq.tokens import lossy_tokenize

    rng = random.Random(16)
    words = ["Strauß", "don't", "e-mail", "CO2", "2026", "ÄÖÜ", "x", "Straße", "STRASSE", "Zürich", "l'arc", "qu'un",
             "don’t", "rock'n'roll", "3,14", "1.000.000", "007", "1985", "1999", "2019", "2025", "2039", "2040", "12345",
             "a1b2", "COVID-19", "O'Brien", "naïve", "café", "café", "Ǆ", "ﬁsh", "Fisch", "", " ", "--", "'", "@s", "ñ@s",
             "Timo Strauß", "Northwind Contoso", "kubernetes", "Kubernetes-Cluster", "zzzzzz", "Qwxyzq", "Ünïcödé", "٣٤٥٦",
             "١٢٣", "mañana", "日本語", "ありがとう", "😀", "a😀b", "weiß", "Weiss", "SS", "ß", "ǅ", "İstanbul", "ΑΣ", "ς"]
    for lang in ("de", "en"):
        buckets = wordfreq.get_frequency_list(lang, wordlist="large")
        flat = [w for b in buckets for w in b]
        words += rng.sample(flat, 1000)
        words += [rng.choice(b) for b in buckets[::4] if b][:200]
        words += [w.upper() for w in rng.sample(flat, 100)] + [w.capitalize() for w in rng.sample(flat, 100)]
        words += [a + "-" + b for a, b in zip(rng.sample(flat, 100), rng.sample(flat, 100))]
        words += [a + " " + b for a, b in zip(rng.sample(flat, 100), rng.sample(flat, 100))]
    cases = []
    for w in words:
        c = w.casefold()
        de, en = zipf_frequency(c, "de"), zipf_frequency(c, "en")
        cases.append([w, de, en, max(de, en)])
    pieces = ["a", "b", "Z", "I", "İ", "u", "h", "y", "ä", "ö", "ß", "é", "e", "s", "@", "'", "’", "‘", '"', "-", "_", ".", ",", ":", ";", " ", "  ",
              "\n", "\r\n", "\t", "0", "1", "7", "9", "٣", "12", "2024", "3.5", "1,000", "l'", "d'", "qu'", "h'", "A'", "😀",
              "‍", "👨", "👩", "🇩", "🇪", "🇺", "́", "̈", "️", "­", "​", "한", "ᄀ", "ᅡ",
              "ᆨ", "日", "本", "ア", "ー", "ก", "า", "א", "ב", "ا", "ั", "ि", "क", "्", "ष", "!", "?", "(", ")", "/", "&",
              "©", "★", " ", "٫", "٬", "·", "‿", "＿"]
    texts = ["".join(rng.choice(pieces) for _ in range(rng.randint(1, 9))) for _ in range(10000)]
    texts += ["Wir haben l'arc d'heure qu'un ami don't won't", "hallo@s und ñ@ amig@s", "e-mail: a.b@c.de", "‘quoted’ “text”",
              "3,14 und 1.000,50", "O'Brien's", "rock'n'roll", "'''x'''", "x''", "''"]
    tokens = [[t, lossy_tokenize(t, "de")] for t in texts]
    return {"cases": cases, "tokens": tokens, "wordfreq": "3.1.1"}


def _fuzz(folder: Path) -> dict:
    """rapidfuzz fuzz.ratio (unrounded float) on 500 pairs: `cases` is [a, b, ratio]."""
    import random

    from rapidfuzz import fuzz

    rng = random.Random(17)
    fixed = [("", ""), ("", "a"), ("a", ""), ("a", "a"), ("abc", "abd"), ("Straße", "strasse"), ("ß", "ss"), ("Müller", "Mueller"),
             ("😀", "😀"), ("a😀b", "a😁b"), ("Wasti", "Vasti"), ("é", "é"), ("kubernetes", "kubernetes"), ("x", "y"),
             ("Timo Strauß", "Timo Strauss"), ("ab" * 40, "ba" * 40), ("a" * 70, "a" * 65), ("a" * 100, "b" * 100)]
    alphabet = "abcdeäöüßéxyz😀 -"
    pairs = list(fixed)
    while len(pairs) < 500:
        n = rng.choice([1, 2, 3, 5, 8, 12, 20, 40, 64, 65, 80, 130, 300])
        a = "".join(rng.choice(alphabet) for _ in range(rng.randint(0, n)))
        if rng.random() < 0.6:
            b = list(a)
            for _ in range(rng.randint(0, 1 + len(b) // 4)):
                op = rng.choice("ids")
                k = rng.randint(0, len(b))
                if op == "i":
                    b.insert(k, rng.choice(alphabet))
                elif b and op == "d":
                    del b[min(k, len(b) - 1)]
                elif b:
                    b[min(k, len(b) - 1)] = rng.choice(alphabet)
            b = "".join(b)
        else:
            b = "".join(rng.choice(alphabet) for _ in range(rng.randint(0, n)))
        pairs.append((a, b))
    return {"cases": [[a, b, fuzz.ratio(a, b)] for a, b in pairs], "rapidfuzz": __import__("rapidfuzz").__version__}


def _cologne(folder: Path) -> dict:
    """glossary.cologne on 300 words: `cases` is [word, code]."""
    import random

    from palaver import glossary

    rng = random.Random(17)
    words = ["Wasti", "Vasti", "Müller", "Mueller", "Meyer", "Meier", "Schmidt", "Schmitt", "Strauß", "Straße", "Christian",
             "Xaver", "Axt", "Köln", "Cologne", "Quelle", "Phillip", "Philipp", "Pfeiffer", "Zeitz", "Dietz", "Scholz", "Matthias",
             "Aachen", "Hans", "Hugo", "", "123", "A-B", "äöü", "ß", "ﬁsh", "ǅ", "İstanbul", "Çelik", "Ñandú", "Ægir", "Œuvre",
             "Noël", "ǰ", "ŉ", "Straßburg", "Ruß", "Weiß", "Strauss", "Contoso", "Northwind", "Valerie", "Timo", "😀", "kubernetes"]
    letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyzÄÖÜäöüß-'é"
    while len(words) < 300:
        words.append("".join(rng.choice(letters) for _ in range(rng.randint(1, 12))))
    return {"cases": [[w, glossary.cologne(w)] for w in words]}


def _difflib(folder: Path) -> dict:
    """difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes() on 200 seeded token lists:
    `cases` is [a, b, [[tag, i1, i2, j1, j2], ...]]."""
    import difflib
    import random

    rng = random.Random(17)
    pool = ["a", "b", "c", "d", "ä", "é", "é", "the", "of", "😀", "", "x y"]
    cases = [([], []), (["a"], []), ([], ["a"]), (["a"], ["a"]), (["a", "b"], ["b", "a"]), (["a", "a", "a"], ["a", "a"]),
             (["a", "b", "a", "b"], ["b", "a", "b", "a"])]
    while len(cases) < 200:
        k = rng.choice([2, 3, 4, 8, 12])
        vocab = rng.sample(pool, min(k, len(pool)))
        n = rng.choice([1, 3, 6, 10, 20, 40, 120, 260])
        a = [rng.choice(vocab) for _ in range(rng.randint(0, n))]
        if rng.random() < 0.6:
            b = list(a)
            for _ in range(rng.randint(0, 1 + len(b) // 3)):
                op = rng.choice("ids")
                i = rng.randint(0, len(b))
                if op == "i":
                    b.insert(i, rng.choice(vocab))
                elif b and op == "d":
                    del b[min(i, len(b) - 1)]
                elif b:
                    b[min(i, len(b) - 1)] = rng.choice(vocab)
        else:
            b = [rng.choice(vocab) for _ in range(rng.randint(0, n))]
        cases.append((a, b))
    return {"cases": [[a, b, [list(o) for o in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes()]]
                      for a, b in cases]}


SEARCH_VOCABS = {
    "main": {
        "people": ["Timo Strauß", "Valerie", "Anna Berger", "Anna Schmidt", "Tom", "Mara", "Will Northwind", "Tom Kraus",
                   "Thomas Berg", "Eli", "Jürgen Ölberg", "Zoë Weiß", "Lu\u0308tke Nord", "Marie-Luise Kranz", "Sinéad O'Neill",
                   "Dr. Carla Weber", "Team", "Northwind", "ÖNW", "", "!!", "anna berger", "Ana"],
        "projects": {"p1": "ÖNW", "p2": "Software Foundry", "p3": "Search", "p4": "Northwind Sync", "p5": "Q3 Planning",
                     "p6": "Straßenbau", "p7": "the", "p8": "März Release", "p9": "Kick-off 2026"},
        "orgs": ["Contoso", "Northwind", "KLOUD", "ACB", "Contoso Ibérica", "in"],
    },
    "empty": {"people": [], "projects": {}, "orgs": []},
    "strauss": {"people": ["Timo Strauß", "STRASSE Valerie", "Weiß"], "projects": {"x": "Straße"}, "orgs": ["Grüße GmbH"]},
}


def _search_parse(folder: Path) -> dict:
    """search.parse: `vocabs` by name; `cases` is [vocab, text, query] for 150+ queries on 2026-10-30 (a Friday);
    `dated` is [today, text, query] for date phrases on days at month, year and DST-week edges; `today_of` is
    [unix seconds, zone, date]: the local date of a moment (what date.today() is in that zone)."""
    from datetime import date, datetime, timezone
    from zoneinfo import ZoneInfo

    from palaver import search

    if str(ROOT) not in sys.path:  # run as a script
        sys.path.insert(0, str(ROOT))
    from tools.parity.ops import search_query_json

    def vocab(name: str) -> search.Vocabulary:
        v = SEARCH_VOCABS[name]
        return search.Vocabulary(people=list(v["people"]), projects=dict(v["projects"]), orgs=list(v["orgs"]))

    today = date(2026, 10, 30)
    main = [
        # plain words, little words, questions
        "", "   ", "pelican", "nothing like this", "the budget", "what is the budget", "Was ist das Budget",
        "wie viel kostet das", "show me the pricing", "zeig mir die Kosten", "warum", "the", "who", "find all meetings",
        # people
        "Anna and Tom", "anna or tom", "Anna oder Valerie", "anna berger", "ANNA BERGER", "Anna Berger and Anna Schmidt",
        "timo", "Strauß", "strauss", "STRASSE", "timo strauss", "Timo Strauss", "TIMO STRAUSS budget", "valerie",
        "Valerie and Timo or Mara", "Mara, Tom, Anna", "tom", "Kraus", "tom kraus", "thomas", "eli", "Eli's budget",
        "will", "will northwind", "what will Anna do", "jürgen", "Ölberg", "ölberg pricing", "Jürgen Ölberg", "zoë",
        "Weiß", "weiss", "Zoë Weiß", "lütke", "Lu\u0308tke", "lu\u0308tke nord", "nord", "Marie-Luise", "marie-luise kranz",
        "kranz", "Sinéad", "o'neill", "Sinéad O'Neill", "carla", "weber", "dr carla weber", "Dr. Carla Weber",
        "team", "ana", "berger", "schmidt", "ANNA", "Anna Anna", "Valerie Valerie Tom",
        # projects and organizations
        "ÖNW", "önw last month", "ÖNW letzte Woche", "software foundry", "Software Foundry pricing", "search",
        "search ranking", "Search last month", "Northwind", "northwind sync", "Northwind Sync budget", "q3 planning",
        "Straßenbau", "strassenbau", "märz release", "März Release next steps", "kick-off 2026", "Kick-off 2026 Contoso",
        "Contoso", "contoso ibérica", "Contoso Ibérica decisions", "meetings with ACB people", "KLOUD and Valerie",
        "kloud", "in", "in Contoso", "the the",
        # dates
        "today", "heute", "yesterday", "gestern", "this week", "diese Woche", "last week", "letzte Woche", "vorige Woche",
        "this month", "diesen Monat", "last month", "letzten Monat", "previous month", "this year", "dieses Jahr",
        "last year", "letztes Jahr", "oktober", "October", "november", "december", "Dezember", "jänner", "januar",
        "feber", "february 2024", "may", "may 2026", "mai", "march", "march 2026", "märz", "MÄRZ 2025", "august",
        "august 2025", "september 1999", "september 2100", "2026-10-21", "2026-02", "2026-02-30", "2026-13", "2026-1-01",
        "since 2026-10-01", "seit september", "seit gestern", "ab heute", "after 2026-10-20", "nach oktober",
        "before october", "before 2026-01", "until yesterday", "bis letzte Woche", "till march 2026", "since may",
        "since may 2026", "last week and this week", "since last month until yesterday", "Anna and Tom last month",
        "budget since \"october\"", "\"today\"", "today today", "since", "bis", "letzte", "this", "last monat",
        "٢٠٢٦-١٠", "since ٢٠٢٦-١٠-٠١",
        "march २०२०", "0000-01-01", "9999-12",
        # scopes, steps, decisions, who said
        "what did we decide about the test phase", "was wurde zur Testphase beschlossen", "decisions about pricing",
        "Entscheidungen zu Kosten", "Beschlüsse", "next steps for ÖNW", "nächste Schritte", "Nächste Schritte Valerie",
        "action items", "todo", "to-dos Anna", "aufgaben letzte Woche", "next \"steps\"", "next actions decisions",
        "where did Mara talk about pricing", "was hat Mara zu den Kosten gesagt", "what did Valerie say about Contoso",
        "Tom said and Anna mentioned", "said pricing", "erwähnte Timo das Budget", "Anna sagte Valerie meinte",
        # quotes
        '"Anna" budget', '"software foundry" Tom', '"Anna Berger"', '"unclosed quote', '""', '" "', 'say "Timo"',
        '"Mara" said pricing', 'Anna "or" Tom', '"or" Anna Tom',
        # written-out filters
        'person:"Anna Berger" project:önw org:acb since:2026-10-01 until:2026-10-15 in:steps is:reviewed has:steps by:Tom budget',
        "is:unreviewed", "is:not-reviewed", "is:REVIEWED", "is:maybe", "project:nope", "project:search ranking",
        "project:\"software foundry\"", "PROJECT:ÖNW", "proj:straßenbau", "org:contoso", "org:\"contoso ibérica\"",
        "company:Fabrikam", "organization:northwind", "person:timo", "person:strauss", "with:Valerie", "person:\"\"",
        "person:", "person:\"Zoë Weiß", "person:!!", "by:mara pricing", "said:\"Anna Berger\" said", "in:decisions",
        "in:Lines", "in:todos", "in:next-steps", "in:somewhere", "has:steps", "has:next-steps", "has:notes",
        "since:\"last month\"", "after:yesterday", "before:2026-10", "until:\"march 2026\"", "date:today", "on:2026-10-21",
        "date:oktober", "since:nonsense", "until:may", "from:2026-09-01 to:2026-09-30", "foo:bar",
        "http://contoso.example/x", "Anna project:ÖNW", "Anna and Tom last month in:decisions", "is:reviewed is:unreviewed",
        "in:steps next steps decisions", "person:Valerie said budget", "since:2026-10-01 since:2026-10-10 until:2026-10-20",
        "since:\"  2026-10-01  \"", "with:\"strauß\" said",
        # odd text
        "Ünïcödé ﬁnance", "ſtrauß", "Straſſe", "e-mail to Valerie", "Q3-Planung", "3.14 und 2.0", "O'Neill's plan",
        "Timo's budget", "😀 Valerie 😀", "Valerie😀", "Contoso\u00a0Ibérica", "tom\tkraus", "anna\nberger",
        "ÖNW-Projekt", "über ÖNW mit Timo", "mit Anna über das Budget im Oktober", "ſeit gestern", "ǆ ǅ Ǆ",
    ]
    cases = [["main", text, search_query_json(search.parse(text, vocab("main"), today=today))] for text in main]
    for name, texts in (("empty", ["Anna and Tom last month", "project:x org:y person:z", "since:2026-10-01",
                                   "since:\"may 2026\"", "until:\"last week\""]),
                        ("strauss", ["timo strauss", "STRASSE", "strasse valerie", "weiss", "WEISS", "Straße", "strasse",
                                     "grüsse gmbh", "GRÜSSE GMBH budget", "project:STRASSE", "org:grüsse gmbh"])):
        cases += [[name, text, search_query_json(search.parse(text, vocab(name), today=today))] for text in texts]

    days = ["2026-01-01", "2026-01-31", "2026-03-01", "2024-02-29", "2026-03-29", "2026-03-30", "2026-10-25",
            "2026-10-26", "2026-12-31", "2027-01-04", "2025-12-29", "2000-03-01", "2026-06-15"]
    phrases = ["today", "yesterday", "this week", "last week", "letzte Woche", "this month", "last month", "letzten Monat",
               "this year", "last year", "january", "dezember", "february", "feber 2024", "may", "may 2026", "mai",
               "march", "märz", "august", "june", "juli", "since last week", "after yesterday", "before this month",
               "until today", "bis gestern", "2026-02-29", "2024-02-29", "2026-13-01", "2026-02", "2026-00",
               "seit märz", "nach dezember", "ab januar 2027", "since:\"last month\"", "before:january"]
    dated = [[d, p, search_query_json(search.parse(p, vocab("empty"), today=date.fromisoformat(d)))]
             for d in days for p in phrases]

    moments = [("2026-03-29T00:59:59+00:00", "Europe/Vienna"), ("2026-03-29T01:00:00+00:00", "Europe/Vienna"),
               ("2026-03-28T23:30:00+00:00", "Europe/Vienna"), ("2026-03-28T22:59:59+00:00", "Europe/Vienna"),
               ("2026-10-24T22:30:00+00:00", "Europe/Vienna"), ("2026-10-24T21:59:59+00:00", "Europe/Vienna"),
               ("2026-10-25T22:59:59+00:00", "Europe/Vienna"), ("2026-10-25T23:00:00+00:00", "Europe/Vienna"),
               ("2026-12-31T23:30:00+00:00", "Europe/Vienna"), ("2026-12-31T22:59:59+00:00", "Europe/Vienna"),
               ("2026-11-01T07:30:00+00:00", "America/Los_Angeles"), ("2026-11-01T06:59:59+00:00", "America/Los_Angeles"),
               ("2026-03-08T07:59:59+00:00", "America/Los_Angeles"), ("2026-10-30T10:30:00+00:00", "Pacific/Kiritimati"),
               ("2026-10-30T10:30:00+00:00", "Pacific/Pago_Pago"), ("2026-10-30T18:29:59+00:00", "Asia/Kolkata"),
               ("2026-10-30T18:30:00+00:00", "Asia/Kolkata"), ("2024-02-29T23:59:59+00:00", "UTC"),
               ("2026-04-05T15:59:59+00:00", "Australia/Lord_Howe")]
    today_of = []
    for iso, zone in moments:
        moment = datetime.fromisoformat(iso).astimezone(timezone.utc)
        today_of.append([int(moment.timestamp()), zone, moment.astimezone(ZoneInfo(zone)).date().isoformat()])
    return {"vocabs": SEARCH_VOCABS, "today": today.isoformat(), "cases": cases, "dated": dated, "today_of": today_of}


def _notes_read(folder: Path) -> dict:
    """notes.py's read side. `hash` is [[[label|null, speaker, start (Python repr), text], ...], transcript_hash];
    `language` is [[[speaker, text], ...], meeting_language]; `lanes` is [[[speaker, label|null], ...], shared,
    mic, shared_lanes]; `guesses` is [{lines: [[speaker, start, end, text, label|null]], guesses, kept}];
    `names` is [value, names, with_names(value, names)]."""
    import random
    import tempfile

    from palaver import glossary, notes
    from palaver.models import Utterance

    # backed_name_guesses reads the user's glossary: never the real one.
    empty = glossary.Glossary(Path(tempfile.mkdtemp()) / "none.json")
    glossary.current = lambda: empty

    rng = random.Random(20)
    texts = ["Hallo zusammen.", "Ünïcödé ﬁnance ſtrauß", "Café au lait", "😀 ok", "tab\there\nline", "", "a b",
             "Straße", "STRASSE", "日本語", "x" * 300]
    starts: list[float] = [0.0, -0.0, 0.005, 0.015, 0.025, 0.035, 0.045, 1.005, 2.675, 1.115, 0.125, 0.375, 0.625, 0.875,
                           0.135, 0.145, 4.35, 8.345, 10.005, 100.125, 1e6, 1e6 + 0.005, 1e15, 1e16, 1e22, 1e23, 123456789.125,
                           5e-324, 1.7976931348623157e308, -0.004, -0.005, -0.006, -0.0049999, -0.125, -1.005, -1e6, 1e-5,
                           0.1 + 0.2, 1 / 3, 2 / 3, 0.995, 0.994999999, 59.995, 3599.995, 86399.995, float("nan"),
                           float("inf"), float("-inf"), 2.5, 3.5, 1e-7, 0.00499999999999999, 0.005000000000000001]
    starts += [round(rng.uniform(0, 7200), rng.randint(0, 4)) for _ in range(150)]
    starts += [rng.randint(0, 720000) / 200 for _ in range(100)]  # many x.xx5 ties on a binary grid
    starts += [rng.randint(0, 72000) / 1000 for _ in range(100)]
    starts += [-abs(rng.uniform(0, 1)) / 100 for _ in range(30)]
    hashes = []
    for i, st in enumerate(starts):
        label = [None, "SPEAKER_01", "", "Zoë"][i % 4]
        text = texts[i % len(texts)]
        hashes.append([[[label, "Timo", repr(st), text]], notes.transcript_hash([Utterance("Timo", st, st + 1, text, label=label)])])
    for _ in range(40):
        us = [Utterance(rng.choice(["Timo", "SPEAKER_00", "Anna"]), rng.uniform(0, 3000), 0.0, rng.choice(texts),
                        label=rng.choice([None, "SPEAKER_00"])) for _ in range(rng.randint(0, 6))]
        hashes.append([[[u.label, u.speaker, repr(u.start), u.text] for u in us], notes.transcript_hash(us)])

    german = "Wir haben das mit dem Rollout nicht gemacht und es ist auch noch nicht fertig, aber wir machen das jetzt."
    english = "So I think we should send the list out today and then talk on Friday, it is not that hard."
    language_lines = [[], [("Timo", "Hi.")], [("Timo", german)], [("Timo", english)], [("Timo", german), ("A", english)],
                      [("Timo", english), ("A", german), ("B", english)], [("Timo", "Bonjour, nous allons parler du projet.")],
                      [("Timo", "der die das")], [("Timo", "the and is")], [("Timo", "der die das the and is")],
                      [("Timo", "Der. DIE, Das! \"und\"")], [("Timo", "für und die")], [("Timo", "für und die ist")],
                      [("Timo", "für  und die ist " + "xyz " * 29)], [("Timo", "für und die ist " + "xyz " * 36)]]
    language = [[[list(x) for x in lines], notes.meeting_language([Utterance(s, 0.0, 1.0, t) for s, t in lines])]
                for lines in language_lines]

    lane_cases = []
    pool = [("SPEAKER_00", "SPEAKER_00"), ("SPEAKER_01", "SPEAKER_01"), ("SPEAKER_10", "SPEAKER_01"), ("Timo", None),
            ("Mic", None), ("SPEAKER_٣", None), ("Zoë", "Zoë"), ("Zoë", "Zoë"), ("Anna", "SPEAKER_02"),
            ("SPEAKER_5", None), ("SPEAKER_5x", None)]
    for _ in range(80):
        rows = [rng.choice(pool) for _ in range(rng.randint(0, 6))]
        shared = {k: "several" for k in rng.sample(["SPEAKER_00", "SPEAKER_01", "SPEAKER_02", "Zoë", "Zoë", "x"], rng.randint(0, 4))}
        mic = rng.choice([None, "", "Room", "x"])
        us = [Utterance(s, 0.0, 1.0, "t", label=lb) for s, lb in rows]
        lane_cases.append([[list(r) for r in rows], shared, mic, notes.shared_lanes(us, shared, mic)])

    # Name guesses: the tests of test_notes.py plus combinations of names, greetings and speakers.
    scenarios = []

    def scenario(lines, guesses):
        us = [Utterance(l[0], l[1], l[2], l[3], label=l[4] if len(l) > 4 else None) for l in lines]
        scenarios.append({"lines": [list(l) + [None] * (5 - len(l)) for l in lines], "guesses": guesses,
                          "kept": notes.backed_name_guesses(guesses, us)})

    def g(label, name):
        return {"label": label, "name": name, "evidence": "e"}

    scenario([("Timo", 0.0, 1.0, "Hi Rico, good to see you."), ("SPEAKER_00", 1.5, 3.0, "Hi Timo."),
              ("SPEAKER_01", 4.0, 6.0, "Okay, thank you, Lenka."), ("SPEAKER_02", 7.0, 9.0, "Hallo, ich bin Andrea vom Data Team."),
              ("SPEAKER_03", 10.0, 11.0, "Sure.")],
             [g("SPEAKER_00", "Rico"), g("SPEAKER_01", "Lenka"), g("SPEAKER_02", "Andrea"), g("SPEAKER_03", "William")])
    scenario([("SPEAKER_02", 0.0, 2.0, "Hallo, ich bin Speaker 3 und das ist SPEAKER_03."), ("SPEAKER_03", 3.0, 4.0, "Hi, this is Anna.")],
             [g("SPEAKER_02", "Speaker 3"), g("SPEAKER_03", "anna")])
    scenario([("Timo", 0.0, 3.0, "Ich hab gestern mit Moritz gesprochen, der kommt nicht."), ("SPEAKER_03", 3.5, 5.0, "Okay, schade."),
              ("Timo", 6.0, 8.0, "Was meinst du, Maria?"), ("SPEAKER_04", 8.5, 10.0, "Passt für mich."),
              ("Timo", 11.0, 12.0, "Danke Helena von der Heide."), ("SPEAKER_05", 12.5, 13.0, "Gerne.")],
             [g("SPEAKER_03", "Moritz"), g("SPEAKER_04", "Maria"), g("SPEAKER_05", "Helena von der Heide")])
    scenario([("Timo", 0.0, 2.0, "Servus, schön dass ihr da seid."),
              ("SPEAKER_03", 2.5, 6.0, "Hallo, ich bin Moritz Dings Kaufmann äh wegen dem Angebot."), ("Timo", 7.0, 9.0, "Genau.")],
             [g("SPEAKER_03", "Moritz Dings Kaufmann"), g("SPEAKER_03", "Moritz Dings")])
    scenario([("SPEAKER_03", 0.0, 2.0, "Hi, this is Anna Huber from sales.")], [g("SPEAKER_03", "Anna"), g("SPEAKER_03", "Anna Huber")])
    for handover in ("I finished the migration, over to you Bob.", "That's it from me, back to you Bob", "Damit übergebe ich an Bob.",
                     "Gut, weiter an Bob.", "go ahead bob", "Thanks Bob, so"):
        scenario([("Timo", 0.0, 2.0, handover), ("SPEAKER_01", 2.5, 4.0, "Thanks, so on my side …")], [g("SPEAKER_01", "Bob")])
    names = ["Rico", "Anna Huber", "Timo Strauß", "Ömer", "O'Brien", "Anne-Marie", "Marie’Luise", "Jürgen Ölberg", "ßeta", "Åsa",
             "Zoë", "Zoë", "van der Heide", "Helena von der Heide", "Dr", "A", "anna", "Speaker 3", "SPEAKER_03", "", "x.y", "Nils (N)",
             "Eve+Adam", "Éva Müller", "Iris  Wolf", "ÉVA"]
    intros = ["Hallo, ich bin {n}.", "ich bin {n} äh vom Team", "My name is {n} and I lead sales.", "this is {n}", "Hier spricht {n}.",
              "Ich bin {n}Huber", "Mein Name ist {n}, freut mich", "I'm {n}.", "I AM {n}!", "Ich bin gestern {n} begegnet."]
    addresses = ["Hi {n}, good to see you.", "danke {n}", "Thanks {n}!", "Was meinst du, {n}?", "{n}, kannst du das übernehmen?",
                 "{n}", "Mit {n} gesprochen.", "Hallo {n} wie geht es", "over to you {n}", "Merci {n}.", "{n}: yes", "Hey {n}x"]
    for _ in range(260):
        n = rng.choice(names)
        who = rng.choice(["SPEAKER_00", "SPEAKER_01", "Timo", "Anna"])
        lines = []
        for i in range(rng.randint(1, 6)):
            template = rng.choice(intros + addresses + ["Passt.", "Okay, schade.", "Mm-hmm.", "äh"])
            lines.append((rng.choice(["SPEAKER_00", "SPEAKER_01", "Timo", "Anna"]), float(i), i + 0.9, template.format(n=n)))
        lines = [(s, a, b, t, rng.choice([None, None, "SPEAKER_01", "SPEAKER_00"])) for s, a, b, t in lines]
        guess_names = [n, n.lower(), " " + n + "\t", n.upper()]
        scenario(lines, [g(rng.choice(["SPEAKER_00", "SPEAKER_01", who]), rng.choice(guess_names)) for _ in range(rng.randint(1, 3))])
    scenario([("A", 0.0, 1.0, "x")], [{"label": "A", "name": None}, {"label": "A"}, {"name": "Rico"}, {"label": "A", "name": 5},
                                    {"label": 3, "name": True}, {"label": "A", "name": ["Rico"]}])

    samples = [{"summary": "SPEAKER_01 asked SPEAKER_00 and SPEAKER_10", "list": ["SPEAKER_0", "SPEAKER_00x", {"owner": "SPEAKER_00"}],
                "n": 3, "f": 1.0, "ok": True, "none": None, "SPEAKER_00": "keys stay"},
               "SPEAKER_00 SPEAKER_00,SPEAKER_00.", "ÄSPEAKER_00", "SPEAKER_00Ä", "SPEAKER_00_", "(SPEAKER_00)", "Zoë and Zoë",
               "foo.bar and foo", "A+B and AB", "x\n SPEAKER_01\t", "SPEAKER_٣ and SPEAKER_3"]
    mappings = [{"SPEAKER_00": "Dani", "SPEAKER_01": "Anna"}, {"SPEAKER_1": "A"}, {"SPEAKER_0": "Z", "SPEAKER_00": "Dani"},
                {"SPEAKER_00": "SPEAKER_01", "SPEAKER_01": "SPEAKER_00"}, {}, {"": "E"}, {"Zoë": "n", "Zoë": "d"},
                {"foo.bar": "FB", "A+B": "plus", "SPEAKER_٣": "digit"}, {"SPEAKER_00": "\\1 \\g<0> $1"}, {"Ä": "ae", "SPEAKER_00": "ß"},
                {"aa": "2", "b": "1", "cc": "2b"}]
    names_cases = [[v, m, notes.with_names(v, m)] for v in samples for m in mappings]
    return {"hash": hashes, "language": language, "lanes": lane_cases, "guesses": scenarios, "names": names_cases}


def _wav(folder: Path) -> dict:
    """WAV files through soundfile (libsndfile) and `live.quietest_cut`. `writes` is [samples (interleaved), rate,
    channels, the file's bytes as hex] of `sf.write(..., subtype="PCM_16")`; `reads` is [name, the file's bytes as hex,
    frames, rate, channels, samples, floats] of `sf.info` and `sf.read(dtype="int16")` / `dtype="float32"` (interleaved);
    `ranges` is [name, hex, start, frames, samples] of `sf.read(start=, stop=)`; `quietest` is {signals: name → little-endian
    int16 hex, cases: [[signal, earliest, latest, frame, cut]]}."""
    import io
    import random
    import struct

    import numpy as np
    import soundfile as sf

    from palaver.live import quietest_cut

    def written(samples: list[int], rate: int, channels: int) -> bytes:
        buf = io.BytesIO()
        a = np.array(samples, dtype=np.int16)
        sf.write(buf, a.reshape(-1, channels) if channels > 1 else a, rate, subtype="PCM_16", format="WAV")
        return buf.getvalue()

    writes = []
    for samples, rate, channels in [(list(range(10)), 16_000, 1), ([], 16_000, 1), ([0, 1, 2], 48_000, 1),
                                    (list(range(12)), 16_000, 2), (list(range(12)), 16_000, 3),
                                    ([-32768, 32767, -1, 0, 1, 12345, -12345], 44_100, 1)]:
        writes.append([samples, rate, channels, written(samples, rate, channels).hex()])

    def chunk(cid: bytes, body: bytes) -> bytes:
        return cid + struct.pack("<I", len(body)) + body + (b"\0" if len(body) % 2 else b"")

    def riff(*chunks: bytes) -> bytes:
        body = b"WAVE" + b"".join(chunks)
        return b"RIFF" + struct.pack("<I", len(body)) + body

    def fmt(channels: int = 1, rate: int = 16_000, extra: bytes = b"", tag: int = 1) -> bytes:
        return chunk(b"fmt ", struct.pack("<HHIIHH", tag, channels, rate, rate * 2 * channels, 2 * channels, 16) + extra)

    pcm = np.array([1, -2, 300, -32768, 32767, 7, 0, -1, 1000, -1000], dtype="<i2").tobytes()
    data = chunk(b"data", pcm)
    extensible = struct.pack("<HHI", 22, 16, 4) + bytes.fromhex("0100000000001000800000aa00389b71")
    files = {
        "canonical": riff(fmt(), data),
        "stereo": riff(fmt(2), data),
        "list_before_data": riff(fmt(), chunk(b"LIST", b"INFOISFT\x05\0\0\0Lavf\0\0"), data),
        "odd_chunk_before_data": riff(fmt(), chunk(b"junk", b"abc"), data),
        "fmt_with_cbsize": riff(fmt(extra=b"\0\0"), data),
        "extensible": riff(fmt(extra=extensible, tag=0xFFFE), data),
        "data_size_too_big": riff(fmt(), b"data" + struct.pack("<I", 1000) + pcm),
        "data_size_too_small": riff(fmt(), b"data" + struct.pack("<I", 8) + pcm),
        "odd_trailing_byte": riff(fmt(), b"data" + struct.pack("<I", 1000) + pcm + b"\x07"),
        "chunk_after_data": riff(fmt(), data, chunk(b"LIST", b"INFOabcd")),
        "48k": riff(fmt(rate=48_000), data),
    }
    reads, ranges = [], []
    for name, raw in files.items():
        info = sf.info(io.BytesIO(raw))
        ints = sf.read(io.BytesIO(raw), dtype="int16", always_2d=True)[0].reshape(-1).tolist()
        floats = [float(x) for x in sf.read(io.BytesIO(raw), dtype="float32", always_2d=True)[0].reshape(-1)]
        reads.append([name, raw.hex(), info.frames, info.samplerate, info.channels, ints, floats])
        for start, frames in [(0, 3), (2, 4), (4, 100), (100, 3)]:
            got = sf.read(io.BytesIO(raw), start=start, stop=start + frames, dtype="int16", always_2d=True)[0]
            ranges.append([name, raw.hex(), start, frames, got.reshape(-1).tolist()])

    rng = random.Random(21)
    loud = np.array([rng.randint(-32768, 32767) for _ in range(8_000)], dtype=np.int16)
    soft = loud.copy()
    soft[3_500:4_300] //= 64
    signals = {"loud": loud, "soft": soft,
               "tied": np.tile(np.array([rng.randint(-3000, 3000) for _ in range(400)], dtype=np.int16), 20),
               "ramp": (np.arange(8_000) % 2000 - 1000).astype(np.int16)}
    cases = [("loud", 0, 8_000, 800), ("loud", 100, 7_900, 800), ("loud", 0, 8_000, 37), ("loud", 5, 6_000, 129),
             ("loud", 0, 8_000, 7), ("loud", 0, 799, 800), ("loud", 3, 8_000, 1000), ("loud", 0, 8_000, 256),
             ("soft", 0, 8_000, 800), ("tied", 0, 8_000, 800), ("ramp", 0, 8_000, 500)]  # tied: the first frame
    quietest = {"signals": {k: v.astype("<i2").tobytes().hex() for k, v in signals.items()},
                "cases": [[name, earliest, latest, frame, int(quietest_cut(signals[name], earliest, latest, frame))]
                          for name, earliest, latest, frame in cases]}
    return {"writes": writes, "reads": reads, "ranges": ranges, "quietest": quietest}


UNDO_ROOT = "/PALAVER-UNDO-ROOT"
# One copy: PalaverServerTests read it from the domain tests' folder.
UNDO_COPIES = (GOLDENS / "python-undo",)


def _undo_fixture(folder: Path) -> dict:
    """Undo snapshots Python took (undo.py), for Swift to restore after the 0.5.x → 0.6.0 update. Writes ``python-undo/``
    to Goldens/ and to native/Tests/PalaverServerTests/Fixtures/ (used from Task 41 on):

    - ``root/``: a recordings folder (``Meetings/``) and its stores (``config/palaver/``) after five changes (rename,
      trash, split, voices, my-notes clear), each with Python's snapshot in ``Meetings/.trash/.undo/<token>/``;
    - ``restored/``: ``root/`` after Python's ``undo.restore`` of every snapshot, newest first.

    Absolute paths in the manifests read ``/PALAVER-UNDO-ROOT``: the folder that holds ``root/`` (a test puts its own
    in). Git keeps no empty folders, so a test compares files only. The section's JSON: ``snapshots`` ([token, label,
    the ids its restore answered], in the order taken), ``unsealed`` (the newest manifest before ``sealed``), ``take``
    (a take over ``root/``: its manifest, and the sha256 of each file it copied), ``fingerprints`` ([path under root/,
    partial, store, fingerprint]; store ones are ``_store_fingerprint``) and ``trees`` (made-up folders: ``files``
    [path, hex or null for a folder], ``links`` [path, target], ``partial``, ``fingerprint``)."""
    import hashlib
    import random
    import shutil
    import tempfile

    import numpy as np
    import soundfile as sf

    from palaver import cutting, undo
    from palaver.paths import RecordingPaths

    rng = random.Random(22)
    a, b, c, d = "2026-10-20T14-35-17", "2026-10-21T09-00-00", "2026-10-22T10-00-00", "2026-10-22T10-00-30"

    def dump(p: Path, value, indent: int | None = 2) -> None:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(value, indent=indent, ensure_ascii=False))

    def meeting(out: Path, id_: str, start: str, speakers: dict, lines: list[tuple[str, float, float, str]]) -> Path:
        f = out / id_
        f.mkdir(parents=True)
        tone = np.array([(i * 37) % 2000 - 1000 for i in range(1600)], dtype=np.int16)
        for track in ("mic_raw.wav", "mic.wav", "system.wav"):
            sf.write(str(f / track), tone, 16_000, subtype="PCM_16")
        dump(f / "meta.json", {"start_time": start, "duration_seconds": 0.1})
        dump(f / "system_turns.json", [{"speaker": s, "start": x, "end": y} for s, x, y, _ in lines], indent=None)
        dump(f / "transcript.json", [{"speaker": s, "start": x, "end": y, "text": t} for s, x, y, t in lines])
        dump(f / "speakers.json", speakers)
        (f / ".speakers.lock").touch()  # derived: never in a snapshot, never compared
        (f / "search-index.json").write_text("{}")
        return f

    def relocated(tree: Path, base: Path) -> None:
        for manifest in tree.glob("Meetings/.trash/.undo/*/manifest.json"):
            manifest.write_text(manifest.read_text().replace(str(base), UNDO_ROOT))

    def hashes(tree: Path) -> dict:
        return {p.relative_to(tree).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sorted(tree.rglob("*")) if p.is_file() and p.name != "manifest.json"}

    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp).resolve() / "work"
        work = base / "root"
        out, stores = work / "Meetings", work / "config" / "palaver"
        A = meeting(out, a, "2026-10-20T14:35:17+02:00", {"SPEAKER_00": "Valerie", "SPEAKER_01": "Timo Strauß"},
                    [("SPEAKER_00", 0.0, 0.05, "Grüße aus Northwind."), ("SPEAKER_01", 0.05, 0.1, "Danke, Zoë!")])
        image = A / "my-notes" / "img-0123456789ab.png"
        image.parent.mkdir()
        image.write_bytes(bytes(rng.randrange(256) for _ in range(300)))
        (A / "my-notes" / "img-0123456789ab.png.txt").write_text("Agenda Q4")
        dump(A / "my-notes.json", [{"text": "Budget für Contoso", "at": 0.05},
                                   {"text": "", "at": None, "image": image.name}])
        (A / ".my-notes.lock").touch()
        (A / "Notizen – Zoë.md").write_text("Für Timo Strauß\n")
        B = meeting(out, b, "2026-10-21T09:00:00+02:00", {"SPEAKER_00": "Valerie"}, [("SPEAKER_00", 0.0, 0.1, "Hallo.")])
        dump(B / "speakers_auto.json", {"SPEAKER_00": "Valerie"})
        C = meeting(out, c, "2026-10-22T10:00:00+02:00", {"SPEAKER_00": "Timo Strauß"},
                    [("SPEAKER_00", 0.0, 0.03, "Erst das."), ("SPEAKER_00", 0.03, 0.1, "Dann das.")])
        dump(C / "notes.json", {"title": "Northwind weekly", "summary": "Rollout im November."})
        projects, organizations, voices = stores / "projects.json", stores / "organizations.json", stores / "voices"
        dump(projects, {"projects": {"4e6f7274": {"name": "Northwind rollout"}},
                        "meetings": {b: {"assigned": {"4e6f7274": {"by": "you", "why": ""}}, "rejected": []},
                                     c: {"assigned": {"4e6f7274": {"by": "auto", "why": "Northwind"}}, "rejected": []}}})
        dump(organizations, {"names": {"contoso": "Contoso"}, "people": {}})
        for name, vector in (("timo-strauss", [0.6, 0.8]), ("valerie", [1.0, 0.0])):
            dump(voices / f"{name}.json", {"name": name, "samples": [{"vector": vector, "source": f"{a}:SPEAKER_00"}]})

        snapshots = []
        t = undo.take(out, "rename", meetings=[a])
        dump(A / "speakers.json", {"SPEAKER_00": "Timo Strauß", "SPEAKER_01": "Timo Strauß"})
        undo.sealed(out, t)
        snapshots.append(t)

        t = undo.take(out, "trash", stores=[projects])
        undo.moved(out, t, B, cutting.trash(RecordingPaths(B)))
        dump(projects, {"projects": {"4e6f7274": {"name": "Northwind rollout"}},
                        "meetings": {c: {"assigned": {"4e6f7274": {"by": "auto", "why": "Northwind"}}, "rejected": []}}})
        undo.sealed(out, t)
        snapshots.append(t)

        t = undo.take(out, "split", meetings=[c], audio=True, stores=[projects])
        sf.write(str(C / "system.wav"), np.zeros(480, dtype=np.int16), 16_000, subtype="PCM_16")
        dump(C / "transcript.json", [{"speaker": "SPEAKER_00", "start": 0.0, "end": 0.03, "text": "Erst das."}])
        meeting(out, d, "2026-10-22T10:00:30+02:00", {"SPEAKER_00": "Timo Strauß"}, [("SPEAKER_00", 0.0, 0.07, "Dann das.")])
        undo.created(out, t, [d])
        dump(projects, {"projects": {"4e6f7274": {"name": "Northwind rollout"}},
                        "meetings": {c: {"assigned": {"4e6f7274": {"by": "auto", "why": "Northwind"}}, "rejected": []},
                                     d: {"assigned": {"4e6f7274": {"by": "you", "why": ""}}, "rejected": []}}})
        undo.sealed(out, t)
        snapshots.append(t)

        t = undo.take(out, "voices", meetings=[a], speaker_files_of_all=True, stores=[voices, organizations])
        dump(A / "speakers.json", {"SPEAKER_00": "Valerie", "SPEAKER_01": "Zoë"})
        dump(C / "speakers.json", {"SPEAKER_00": "Zoë"})
        dump(out / d / "speakers_auto.json", {"SPEAKER_00": "Zoë"})
        dump(voices / "zoe.json", {"name": "Zoë", "samples": []})
        dump(organizations, {"names": {"contoso": "Contoso", "northwind": "Northwind Traders"}, "people": {}})
        undo.sealed(out, t)
        snapshots.append(t)

        notes_files = [image, image.parent / (image.name + ".txt")]
        t = undo.take(out, "my-notes clear", stores=notes_files)
        undo.note(out, t, {"folder": str(A), "paragraphs": [{"text": "", "at": None, "image": image.name}]})
        for f in notes_files:
            f.unlink()
        unsealed = (out / ".trash" / ".undo" / t / "manifest.json").read_text().replace(str(base), UNDO_ROOT)
        undo.sealed(out, t)
        snapshots.append(t)

        fingerprints = []
        for id_ in (a, c, d):
            for partial in (False, True):
                fingerprints.append([f"Meetings/{id_}", partial, False, undo._fingerprint(out / id_, partial)])
        for p in (projects, voices, stores / "missing.json", image):
            fingerprints.append([p.relative_to(work).as_posix(), False, True, undo._store_fingerprint(p)])

        scratch = Path(tmp).resolve() / "scratch"
        shutil.copytree(work, scratch / "root", symlinks=True)
        s_out, s_stores = scratch / "root" / "Meetings", scratch / "root" / "config" / "palaver"
        s_token = undo.take(s_out, "check", meetings=[a], speaker_files_of_all=True,
                            stores=[s_stores / "projects.json", s_stores / "voices", s_stores / "missing.json"])
        s_snap = s_out / ".trash" / ".undo" / s_token
        take = {"token": s_token, "manifest": (s_snap / "manifest.json").read_text().replace(str(scratch), UNDO_ROOT),
                "files": hashes(s_snap)}

        for copy in UNDO_COPIES:
            shutil.rmtree(copy, ignore_errors=True)
            shutil.copytree(work, copy / "root", symlinks=True)
            relocated(copy / "root", base)
        labels = {t: undo.label(out, t) for t in snapshots}
        restored = {t: undo.restore(out, t) for t in reversed(snapshots)}
        for copy in UNDO_COPIES:
            shutil.copytree(work, copy / "restored", symlinks=True)

    def tree(files: list[tuple[str, bytes | None]], links: list[tuple[str, str]] = (), partial: bool = False) -> dict:
        with tempfile.TemporaryDirectory() as tmp:
            top = Path(tmp) / "tree"
            top.mkdir()
            for rel, data in files:
                (top / rel).parent.mkdir(parents=True, exist_ok=True)
                if data is None:
                    (top / rel).mkdir()
                else:
                    (top / rel).write_bytes(data)
            for rel, target in links:
                (top / rel).symlink_to(target)
            return {"files": [[rel, None if data is None else data.hex()] for rel, data in files],
                    "links": [list(x) for x in links], "partial": partial, "fingerprint": undo._fingerprint(top, partial)}

    def blob(n: int) -> bytes:
        return bytes(rng.randrange(256) for _ in range(n))

    names = [("a.wav", blob(40)), ("b.WAV", blob(12)), (".wav", blob(9)), ("x.wav.part", blob(30)), ("c.Wav", blob(3)),
             ("speakers.json", '{"SPEAKER_00": "Zoë"}'.encode()), ("speakers_auto.json", blob(20)),
             ("speakers-x.json", b"{}"), ("my-speakers.json", b"[]"), ("speakers.json.bak", b"[]"),
             ("speakersjson", b"x"), ("search-index.json", blob(50)), ("search-index", b"kept"), (".my-notes.lock", b""),
             (".speakers.lock", b""), ("foo.lock", b"a lock of another name"), ("x.tmp", blob(5)), ("y.TMP", blob(5)),
             ("empty.json", b""), ("a-b", b"1"), ("a.b", b"2"), ("a/b.json", b"3"), ("a0", b"4"),
             ("a/.speakers.lock", b""), ("search-index.d/inner.json", b"inner"), (".hidden/x.json", b"hidden"),
             ("sub/deeper/z.txt", blob(64)), ("Zoë.txt", b"NFC"), ("Zoz.txt", b"z"), ("Zo.txt", b"o"),
             ("Ä/ü.json", blob(7)), ("dir.wav", None), ("dir.wav/inside.json", b"in a folder named .wav")]
    nfd = [("Zoë.txt", b"NFD"), ("Zoe.txt", b"e"), ("Ä/ü.json", b"nfd folder")]
    links = [("link.json", "a.b"), ("dirlink", "sub"), ("dangling.json", "nowhere.json")]
    trees = [tree(names, links), tree(names, links, partial=True), tree(nfd), tree(nfd, partial=True),
             tree([("speakers.json", b"{}")]), tree([("speakers.json", b"{}")], partial=True), tree([]),
             tree([("only.wav", blob(100)), ("big.bin", blob(70_000))])]
    return {"snapshots": [[t, labels[t], restored[t]] for t in snapshots], "unsealed": unsealed, "take": take,
            "fingerprints": fingerprints, "trees": trees}


def _exchange_zip(folder: Path) -> dict:
    """A meeting exported by Python (``exchange-python.zip``: no audio, fictional people), and what exchange.py makes of
    small zips, JSON and times (``_precheck`` + ``_entries`` + ``_read_entry``, ``check``, ``_json``, ``_time``).

    Keys: ``entries`` (the export's entries as zipfile reads them: [name, compress_type, flag_bits, file_size, CRC,
    external_attr >> 16, is_dir]); ``contents`` (name → its text); ``schemas`` (``SCHEMAS``, ``MANIFEST``, ``VOICE``);
    ``zips`` ([label, hex, caps set on the module, result]: ``{"root", "names", "reads"}`` or ``{"rejected"}``; reads
    are each entry's ``_read_entry`` against ``listed`` or the error); ``listed`` (the export's manifest files);
    ``check`` ([value, schema, where, message or null]); ``json`` ([hex, where, {"value"} or {"rejected"}]); ``time``
    ([text, where, [year, month, day, hour, minute, second, microsecond, utcoffset seconds] or {"rejected"}])."""
    import hashlib
    import io
    import os
    import stat
    import tempfile
    import warnings
    import zipfile

    from palaver import exchange, notes
    from palaver.models import Utterance
    from palaver.paths import RecordingPaths

    out: dict = {}
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        old = os.environ.get("XDG_CONFIG_HOME")
        os.environ["XDG_CONFIG_HOME"] = str(root / "cfg")
        try:
            paths = RecordingPaths(root / "Meetings" / "2026-10-29T10-00-00")
            paths.folder.mkdir(parents=True)
            paths.meta.write_text(json.dumps({"start_time": "2026-10-29T10:00:00+01:00", "duration_seconds": 60}))
            paths.language.write_text("de")
            paths.system_turns.write_text(json.dumps([
                {"speaker": "SPEAKER_00", "start": 2.0, "end": 20.0}, {"speaker": "SPEAKER_01", "start": 21.0, "end": 40.0}]))
            utterances = [
                Utterance("Timo Strauß", 0.0, 2.0, "Hallo zusammen."),
                Utterance("Valerie", 2.0, 20.0, "Das Budget für Contoso steht.", label="SPEAKER_00"),
                Utterance("SPEAKER_01", 21.0, 40.0, "Northwind braucht mehr Zeit.", label="SPEAKER_01"),
                Utterance("Timo Strauß", 50.0, 55.0, "Dann machen wir das so."),
            ]
            paths.transcript_json.write_text(json.dumps([u.to_dict() for u in utterances]))
            paths.speakers.write_text(json.dumps({"SPEAKER_00": "Valerie"}))
            paths.calendar.write_text(json.dumps({
                "title": "Budget Northwind", "start": "2026-10-29T10:00:00+01:00", "end": "2026-10-29T10:30:00+01:00",
                "uid": "EVT-23", "series": False,
                "attendees": [{"name": "Timo Strauß", "email": "timo@contoso.example", "organizer": True,
                               "response": "accepted", "is_self": True},
                              {"name": "Valerie", "email": "valerie@northwind.example", "response": "tentative"}]}))
            notes.save(paths, {"title": "Budget Northwind", "summary": "SPEAKER_00 stellte das Budget vor.",
                               "sections": [{"heading": "Budget", "points": [{"text": "Steht", "details": ["Contoso"]}]}],
                               "next_steps": [{"owner": "Valerie", "task": "Zahlen schicken"}],
                               "decisions": ["Budget freigegeben"], "speaker_names": [],
                               "transcript_hash": notes.transcript_hash(utterances)})
            export = exchange.export_meeting(paths, root / "out.zip", user_name="Timo Strauß", projects=["Northwind"])
        finally:
            if old is None:
                os.environ.pop("XDG_CONFIG_HOME")
            else:
                os.environ["XDG_CONFIG_HOME"] = old
        data = export.read_bytes()
        (folder / "exchange-python.zip").write_bytes(data)
        with zipfile.ZipFile(export) as zf:
            out["entries"] = [[i.filename, i.compress_type, i.flag_bits, i.file_size, i.CRC, i.external_attr >> 16,
                               i.is_dir()] for i in zf.infolist()]
            out["contents"] = {n: zf.read(n).decode() for n in zf.namelist()}
            files = {n: zf.read(n) for n in zf.namelist()}
        listed = json.loads(files["manifest.json"])["files"]
        out["listed"] = listed

        def zip_of(entries: list) -> bytes:
            buf = io.BytesIO()
            with warnings.catch_warnings(), zipfile.ZipFile(buf, "w") as zf:
                warnings.simplefilter("ignore")  # "Duplicate name"
                for name, content, *kw in entries:
                    zf.writestr(name, content, **(kw[0] if kw else {"compress_type": zipfile.ZIP_DEFLATED}))
            return buf.getvalue()

        def finder(folder_name: str, extra: list = ()) -> list:
            entries = [(f"{folder_name}/", b"")] + [(f"{folder_name}/{d}", b"") for d in ("meeting/",)]
            for n, d in files.items():
                entries.append((f"{folder_name}/{n}", d))
                parts = n.split("/")
                entries.append((f"__MACOSX/{folder_name}/{'/'.join(parts[:-1] + ['._' + parts[-1]])}", b"\0\5\26\7"))
            return entries + [(f"{folder_name}/.DS_Store", b"\0\0\0\1Bud1"), *extra]

        plain = [(n, d) for n, d in files.items()]
        link = zipfile.ZipInfo("voices/SPEAKER_00.json")
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        bzip = zipfile.ZipInfo("voices/SPEAKER_01.json")
        bzip.compress_type = zipfile.ZIP_BZIP2
        def flagged(raw: bytes, name: bytes, set_: int = 0, clear: int = 0) -> bytes:
            """``raw`` with ``name``'s flags changed in its central directory (zipfile writes its own flags)."""
            out = bytearray(raw)
            at = out.find(b"PK\x01\x02")
            while at >= 0:
                if out[at + 46:at + 46 + len(name)] == name:
                    flags = (int.from_bytes(out[at + 8:at + 10], "little") | set_) & ~clear
                    out[at + 8:at + 10] = flags.to_bytes(2, "little")
                at = out.find(b"PK\x01\x02", at + 4)
            return bytes(out)

        forged = b'[{"start": 0, "end": 1, "text": "x", "label": "SPEAKER_00"}]'
        changed = [(n, forged if n == "meeting/transcript.json" else d) for n, d in files.items()]
        stored = [(n, d, {"compress_type": zipfile.ZIP_STORED}) for n, d in files.items()]
        cases = [
            ("export", data, {}),
            ("not a zip", b"hello", {}),
            ("empty zip", zip_of([]), {}),
            ("finder", zip_of(finder("2026-10-29 Q3 budget plan")), {}),
            ("finder nfd", zip_of(finder("Zoë Notizen")), {}),
            ("not exported", zip_of([("photos/beach.jpg", b"\xff\xd8")]), {}),
            ("two folders", zip_of(finder("a", [("b/manifest.json", b"{}")])), {}),
            ("nested", zip_of([(f"outer/{n}", d) for n, d in finder("inner")]), {}),
            ("parent path", zip_of(plain + [("../../evil.json", b"{}")]), {}),
            ("absolute path", zip_of(plain + [("/etc/evil.json", b"{}")]), {}),
            ("backslash", zip_of(plain + [("meeting\\x.json", b"{}")]), {}),
            ("colon", zip_of(plain + [("c:x.json", b"{}")]), {}),
            ("dot part", zip_of(plain + [("meeting/./notes.json", b"{}")]), {}),
            ("macosx escape", zip_of(finder("m", [("__MACOSX/../evil", b"")])), {}),
            # "/" before a combining mark: one character for Swift's String, still a separator for Python.
            ("combining parent", zip_of(finder("m", [("__MACOSX/../\u0301x", b"")])), {}),
            ("combining dot", zip_of(finder("m", [("m/meeting/.\u0301", b"")])), {}),
            ("combining folder", zip_of(finder("m", [("m/\u0301x.json", b"{}")])), {}),
            ("combining top", zip_of(plain + [("meeting/\u0301notes.json", b"{}")]), {}),
            ("link", zip_of(plain + [(link, b"/etc/passwd", {})]), {}),
            ("not part", zip_of(plain + [("meeting/run.sh", b"rm -rf ~")]), {}),
            ("not part under folder", zip_of(finder("m", [("m/meeting/run.sh", b"rm -rf ~")])), {}),
            ("folder under folder", zip_of(finder("m", [("m/scripts/", b"")])), {}),
            ("ds_store folder", zip_of(finder("m", [("m/.DS_Store/x.json", b"{}")])), {}),
            ("twice", zip_of(plain + [("meeting/turns.json", b"[]")]), {}),
            ("encrypted", flagged(zip_of(plain + [("voices/SPEAKER_00.json", b"{}")]), b"voices/SPEAKER_00.json", 0x1), {}),
            ("cp437 name", flagged(zip_of(plain + [("meeting/Zo\u00eb.json", b"")]), "meeting/Zo\u00eb.json".encode(),
                                   clear=0x800), {}),
            ("cp437 folder", flagged(zip_of(plain + [("Zo\u00eb/", b"")]), "Zo\u00eb/".encode(), clear=0x800), {}),
            ("bzip2", zip_of(plain + [(bzip, b"{}", {})]), {}),
            ("changed", zip_of(changed), {}),
            ("changed under folder", zip_of([(n, forged if n.endswith("transcript.json") else d)
                                             for n, d in finder("m")]), {}),
            ("stored", zip_of(stored), {}),
            ("long name", zip_of(plain + [("x" * 120, b"")]), {}),
            ("non-ascii name", zip_of(plain + [("meeting/Zoë.json", b"")]), {}),
            ("caps entries", data, {"MAX_ENTRIES": 5}),
            ("caps json", data, {"MAX_JSON_BYTES": 100}),
            ("caps total", data, {"MAX_TOTAL_BYTES": 500}),
            ("caps file", data, {"MAX_FILE_BYTES": 1000}),
            ("caps raw", zip_of(finder("m")), {"MAX_RAW_ENTRIES": 10}),
            ("caps directory", data, {"MAX_DIRECTORY_BYTES": 200}),
        ]
        # A damaged entry: the stored transcript's bytes changed in place (its CRC fails); the deflated one's turned to
        # noise (zlib fails, or the CRC).
        damaged = bytearray(zip_of(stored))
        at = bytes(damaged).find(files["meeting/transcript.json"][:40])
        damaged[at + 5:at + 9] = b"XXXX"
        cases.append(("damaged stored", bytes(damaged), {}))
        noise = bytearray(data)
        with zipfile.ZipFile(io.BytesIO(data)) as zf:
            info = zf.getinfo("meeting/transcript.json")
        start = info.header_offset + 30 + len(info.filename.encode()) + len(info.extra)
        noise[start + 5:start + 25] = b"\xff" * 20
        cases.append(("damaged deflated", bytes(noise), {}))

        zips = []
        for label, raw, caps in cases:
            saved = {k: getattr(exchange, k) for k in caps}
            for k, v in caps.items():
                setattr(exchange, k, v)
            file = root / "case.zip"
            file.write_bytes(raw)
            try:
                exchange._precheck(file)
                try:
                    zf = zipfile.ZipFile(file)
                except (zipfile.BadZipFile, OSError, ValueError):
                    raise exchange.Rejected("This is not a zip.") from None
                with zf:
                    root_, entries = exchange._entries(zf)
                    reads = {}
                    for name, info in entries.items():
                        if name not in listed:
                            continue
                        try:
                            got = exchange._read_entry(zf, name, info, listed[name])
                            reads[name] = hashlib.sha256(got).hexdigest()
                        except exchange.Rejected as e:
                            reads[name] = {"rejected": str(e)}
                result = {"root": root_, "names": list(entries), "reads": reads}
            except exchange.Rejected as e:
                result = {"rejected": str(e)}
            finally:
                for k, v in saved.items():
                    setattr(exchange, k, v)
            zips.append([label, raw.hex(), caps, result])
        out["zips"] = zips

    out["schemas"] = {"SCHEMAS": exchange.SCHEMAS, "MANIFEST": exchange.MANIFEST, "VOICE": exchange.VOICE}
    docs = {n: json.loads(t) for n, t in out["contents"].items()}
    schema_of = {**{n: n for n in exchange.SCHEMAS}, "manifest.json": "MANIFEST"}
    named = {"MANIFEST": exchange.MANIFEST, "VOICE": exchange.VOICE, **exchange.SCHEMAS}
    voice = {"label": "SPEAKER_00", "name": "Valerie", "embedding": [0.25] * 16}
    meta, transcript = docs["meeting/meta.json"], docs["meeting/transcript.json"]
    values: list[tuple] = [(doc, schema_of[n], n) for n, doc in docs.items() if n in schema_of]
    values += [
        (voice, "VOICE", "voices/SPEAKER_00.json"),
        ({**voice, "embedding": [0.25] * 15}, "VOICE", "v"),
        ({**voice, "embedding": [0.25] * 15 + [True]}, "VOICE", "v"),
        ({**voice, "embedding": [0.25] * 15 + [float("inf")]}, "VOICE", "v"),
        ({**voice, "embedding": [0.25] * 15 + [float("nan")]}, "VOICE", "v"),
        ({**voice, "embedding": [0.25] * 15 + [-1e308]}, "VOICE", "v"),
        ({**voice, "label": "SPEAKER_1000"}, "VOICE", "v"),
        ({**voice, "label": "SPEAKER_١"}, "VOICE", "v"),
        ({**voice, "name": "x" * 200}, "VOICE", "v"),
        ({**voice, "name": "x" * 201}, "VOICE", "v"),
        ({**voice, "name": "ä" * 200}, "VOICE", "v"),
        ({**voice, "name": "ä" * 100}, "VOICE", "v"),
        ({**voice, "name": "ä" * 101}, "VOICE", "v"),
        ({"label": "SPEAKER_00", "name": "Valerie"}, "VOICE", "v"),
        ([transcript[0], {**transcript[0], "text": 42}], "meeting/transcript.json", "meeting/transcript.json"),
        ([{**transcript[0], "label": "../../x"}], "meeting/transcript.json", "t"),
        ([{**transcript[0], "start": -0.5}], "meeting/transcript.json", "t"),
        ([{**transcript[0], "start": 43200}], "meeting/transcript.json", "t"),
        ([{**transcript[0], "start": 43200.001}], "meeting/transcript.json", "t"),
        ([{**transcript[0], "start": True}], "meeting/transcript.json", "t"),
        ([{**transcript[0], "start": "1"}], "meeting/transcript.json", "t"),
        ([{**transcript[0], "speaker": None}], "meeting/transcript.json", "t"),
        ({"x": 1}, "meeting/transcript.json", "t"),
        ({**meta, "run": "something"}, "meeting/meta.json", "meeting/meta.json"),
        ({**meta, "it's \"odd\"\nä\x7f": 1}, "meeting/meta.json", "m"),
        ({**meta, "y" * 50: 1}, "meeting/meta.json", "m"),
        ({**meta, "title": None, "language": None}, "meeting/meta.json", "m"),
        ({**meta, "title": 1}, "meeting/meta.json", "m"),
        ({**meta, "kept_on_this_mac": 1}, "meeting/meta.json", "m"),
        ({**meta, "start": "2026-10-29 10:00:00+01:00"}, "meeting/meta.json", "m"),
        ({**meta, "start": "2026-10-29T10:00:00.5Z"}, "meeting/meta.json", "m"),
        ({**meta, "start": "٢٠٢٦-10-29T10:00:00Z"}, "meeting/meta.json", "m"),
        ({**meta, "start": "2026-10-29T10:00:00+01:00\n"}, "meeting/meta.json", "m"),
        ({**meta, "projects": ["Northwind"] * 51}, "meeting/meta.json", "m"),
        ({"end": meta["end"], "duration": 1}, "meeting/meta.json", "m"),
        ({"start": meta["start"]}, "meeting/meta.json", "m"),
        ([{"label": "SPEAKER_00", "name": "Valerie", "how": "hand"}], "meeting/speakers.json", "s"),
        ([{"label": "SPEAKER_00", "name": None, "how": None}], "meeting/speakers.json", "s"),
        ([{"label": "SPEAKER_00", "name": "Valerie", "how": "guess"}], "meeting/speakers.json", "s"),
        ([{"label": "SPEAKER_00", "name": "Valerie", "how": 1}], "meeting/speakers.json", "s"),
        ([{"label": "SPEAKER_00", "name": "Valerie", "how": True}], "meeting/speakers.json", "s"),
        ({**docs["manifest.json"], "format": 1.0}, "MANIFEST", "manifest.json"),
        ({**docs["manifest.json"], "format": True}, "MANIFEST", "manifest.json"),
        ({**docs["manifest.json"], "exported_by": ""}, "MANIFEST", "manifest.json"),
        ({**docs["manifest.json"], "files": {f"f{i}": {"sha256": "0" * 64, "bytes": 0} for i in range(65)}},
         "MANIFEST", "manifest.json"),
        ({**docs["manifest.json"], "files": {"z" * 101: {"sha256": "0" * 64, "bytes": 0}}}, "MANIFEST", "manifest.json"),
        ({**docs["manifest.json"], "files": {"a" * 60: {"sha256": "0" * 63, "bytes": 0}}}, "MANIFEST", "manifest.json"),
        ({**docs["manifest.json"], "files": {"a": {"sha256": "A" * 64, "bytes": 0}}}, "MANIFEST", "manifest.json"),
        ({**docs["manifest.json"], "files": {"a": {"sha256": "0" * 64, "bytes": -1}}}, "MANIFEST", "manifest.json"),
        ({**docs["manifest.json"], "files": {"a": {"sha256": "0" * 64}}}, "MANIFEST", "manifest.json"),
        ({**docs["manifest.json"], "files": {"a": {"sha256": "0" * 64, "bytes": 1, "x": 2}}}, "MANIFEST", "m"),
        ({**docs["manifest.json"], "files": []}, "MANIFEST", "manifest.json"),
        ({"sections": [{"heading": "h", "points": [{"text": "t", "details": ["d", 1]}]}], "summary": ""},
         "meeting/notes.json", "meeting/notes.json"),
        ({"summary": "s", "decisions": ["x" * 20001]}, "meeting/notes.json", "n"),
        ({"summary": "s", "next_steps": [{"owner": "Valerie"}]}, "meeting/notes.json", "n"),
        ({**docs["meeting/calendar.json"], "attendees": [{"name": "Valerie", "response": "maybe"}]},
         "meeting/calendar.json", "c"),
        (None, "meeting/meta.json", "m"),
        ("x", "meeting/meta.json", "m"),
    ]
    out["check"] = []
    for value, name, where in values:
        try:
            exchange.check(value, named[name], where)
            result = None
        except exchange.Rejected as e:
            result = str(e)
        out["check"].append([value, name, where, result])

    texts = [b'{"a": 1}', b'[1, 2.5, "Stra\xc3\x9fe", null, true]', b'{"a": NaN}', b'[Infinity]', b'[-Infinity]',
             b'[1e999]', b'{"a": 1, "a": 2}', b'{"a": 1', b'', b'\xff', b'["\xff"]', b'[NaN, \xff]', b'[1, NaN',
             b'[1 NaN]', b'\xef\xbb\xbf{}', b'[' * 100 + b']' * 100, b'{"x": 1} ', b' [] x',
             b'12345678901234567890', b'-0', b'1.0', b'"\x01"', b'nan', b'[NaNx]']
    out["json"] = []
    for raw in texts:
        try:
            result = {"value": exchange._json(raw, "meeting/x.json")}
        except exchange.Rejected as e:
            result = {"rejected": str(e)}
        out["json"].append([raw.hex(), "meeting/x.json", result])
    out["json"] = [c for c in out["json"] if not (isinstance(c[2].get("value"), int) and abs(c[2]["value"]) > 2 ** 62)]

    times = ["2026-10-29T10:00:00+01:00", "2026-10-29T10:00:00Z", "2026-10-29T10:00:00.5+01:00",
             "2026-10-29T10:00:00.1234567-03:30", "2026-10-29T10:00:00.000001+00:00", "2026-10-29T10:00:00",
             "2026-13-29T10:00:00+01:00", "2026-02-29T10:00:00+01:00", "2024-02-29T10:00:00+01:00",
             "2026-10-29T24:00:00+01:00", "2026-10-29T10:60:00+01:00", "2026-10-29T10:00:60+01:00",
             "2026-10-29T10:00:00+24:00", "2026-10-29T10:00:00+23:59", "2026-10-29T10:00:00-23:59",
             "2026-10-29T10:00:00+01:99", "2026-10-29T10:00:00-00:00", "2000-01-01T00:00:00+01:00",
             "1999-12-31T23:59:59+00:00", "2100-12-31T23:59:59-12:00", "2101-01-01T00:00:00+14:00",
             "9999-12-31T23:59:59+14:00", "0001-01-01T00:00:00-12:00", "1970-01-01T00:00:00+00:00",
             "٢٠٢٦-10-29T10:00:00Z", "2026-10-29T10:00:00ZZ", "2026-00-29T10:00:00+01:00",
             "2026-10-00T10:00:00+01:00", "2026-10-29t10:00:00+01:00", "", "now"]
    out["time"] = []
    for text in times:
        try:
            t = exchange._time(text, "meta.json start")
            result = [t.year, t.month, t.day, t.hour, t.minute, t.second, t.microsecond,
                      int(t.utcoffset().total_seconds())]
        except exchange.Rejected as e:
            result = {"rejected": str(e)}
        out["time"].append([text, "meta.json start", result])
    return out


def _exchange_names(folder: Path) -> dict:
    """What an export is called (exchange.py ``file_name``, ``free_name``), in Europe/Berlin.

    Keys: ``file_name`` ([meta.json's start_time (absent: no meta.json), title.json's title (null: none), the name]);
    ``free_name`` ([names already in the folder (``{"link": name}``: a symlink to nothing), the name asked for, the
    name given])."""
    import os
    import tempfile
    import time

    from palaver import exchange
    from palaver.paths import RecordingPaths

    absent = {"absent": True}
    file_name_cases = [
        ("2026-10-29T10:00:00+01:00", "Q3: budget / plan?"),
        ("2026-10-29T10:00:00+01:00", None),
        ("2026-10-29T10:00:00+01:00", "   "),
        ("2026-10-29T23:30:00-05:00", "Late call"),  # the next day in Berlin
        ("2026-10-29T22:30:00Z", "Zulu"),
        ("2026-10-29T10:00:00", "Naive start"),
        ("2026-03-29T01:30:00+00:00", "Clocks change"),
        ("not a time", "Contoso kickoff"),
        (5, "A number"),
        (None, "Null start"),
        (absent, "No meta"),
        ("2026-10-29T10:00:00+01:00", "Tabs\tand\nnewlines\x01\x1f here"),
        ("2026-10-29T10:00:00+01:00", 'All of them: \\ / : * ? " < > | done'),
        ("2026-10-29T10:00:00+01:00", "...Northwind..."),
        ("2026-10-29T10:00:00+01:00", ". . ."),
        ("2026-10-29T10:00:00+01:00", "x" * 79 + " ." + "y" * 10),
        ("2026-10-29T10:00:00+01:00", "Valerie und Timo Strauß " * 6),
        ("2026-10-29T10:00:00+01:00", "Zoë  wide　space nbsp"),
        ("2026-10-29T10:00:00+01:00", "é" * 50),
        ("2026-10-29T10:00:00+01:00", "😀 Contoso 😀"),
        ("2026-10-29T10:00:00+01:00", "\x7f del and \x85 next line"),
    ]
    free_name_cases = [
        ([], "2026-10-29 Budget.zip"),
        (["2026-10-29 Budget.zip"], "2026-10-29 Budget.zip"),
        (["2026-10-29 Budget.zip", "2026-10-29 Budget 2.zip", "2026-10-29 Budget 3.zip"], "2026-10-29 Budget.zip"),
        (["2026-10-29 Budget.zip", "2026-10-29 Budget 3.zip"], "2026-10-29 Budget.zip"),
        (["notes"], "notes"),
        (["notes", "notes 2"], "notes"),
        ([".zip"], ".zip"),
        (["a.ZIP"], "a.ZIP"),
        (["Zoë.zip"], "Zoë.zip"),
        ([{"link": "gone.zip"}], "gone.zip"),
        (["؀.zip"], "؀.zip"),
    ]
    out: dict = {"file_name": [], "free_name": []}
    old_tz = os.environ.get("TZ")
    os.environ["TZ"] = "Europe/Berlin"
    time.tzset()
    try:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old = os.environ.get("XDG_CONFIG_HOME")
            os.environ["XDG_CONFIG_HOME"] = str(root / "cfg")
            try:
                for i, (start, title) in enumerate(file_name_cases):
                    paths = RecordingPaths(root / "names" / f"m{i}")
                    paths.folder.mkdir(parents=True)
                    if start is not absent:
                        paths.meta.write_text(json.dumps({"start_time": start, "duration_seconds": 60}))
                    if title is not None:
                        paths.title.write_text(json.dumps({"title": title}))
                    out["file_name"].append([start, title, exchange.file_name(paths)])
            finally:
                if old is None:
                    os.environ.pop("XDG_CONFIG_HOME")
                else:
                    os.environ["XDG_CONFIG_HOME"] = old
            for i, (existing, name) in enumerate(free_name_cases):
                here = root / "free" / f"f{i}"
                here.mkdir(parents=True)
                for entry in existing:
                    if isinstance(entry, dict):
                        (here / entry["link"]).symlink_to(here / "nowhere")
                    else:
                        (here / entry).write_text("")
                out["free_name"].append([existing, name, exchange.free_name(here, name).name])
    finally:
        if old_tz is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = old_tz
        time.tzset()
    return out


def _exchange_import(folder: Path) -> dict:
    """What Python's import makes of ``exchange-python.zip`` (the ``exchange_zip`` golden's export, read from this
    folder): ``import_package`` into an empty recordings folder as "Valerie" (invited, so "self" in the event), no
    calendar, in Europe/Berlin, ``datetime.now()`` in exchange.py fixed at ``now``.

    Keys: ``now``; ``result`` (``Imported``: id, from, matched, voices, names, warnings); ``files`` (every file the
    meeting folder holds, lock files aside: name → its text)."""
    import os
    import tempfile
    import time
    from datetime import datetime

    from palaver import exchange

    now = "2026-11-01T12:00:00+01:00"

    class _Fixed(datetime):
        @classmethod
        def now(cls, tz=None):
            return datetime.fromisoformat(now)

    out: dict = {"now": now}
    old_tz, old_cfg = os.environ.get("TZ"), os.environ.get("XDG_CONFIG_HOME")
    real = exchange.datetime
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        os.environ["TZ"] = "Europe/Berlin"
        time.tzset()
        os.environ["XDG_CONFIG_HOME"] = str(root / "cfg")
        exchange.datetime = _Fixed
        try:
            done = exchange.import_package(root / "Meetings", folder / "exchange-python.zip", user_name="Valerie")
            out["result"] = {"id": done.id, "from": done.sender, "matched": done.matched, "voices": done.voices,
                             "names": done.names, "warnings": done.warnings}
            meeting = root / "Meetings" / done.id
            out["files"] = {p.name: p.read_text() for p in sorted(meeting.iterdir())
                            if p.is_file() and not p.name.endswith(".lock")}
        finally:
            exchange.datetime = real
            for key, value in (("TZ", old_tz), ("XDG_CONFIG_HOME", old_cfg)):
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value
            time.tzset()
    return out


def _exchange_zip_audio(folder: Path) -> dict:
    """Meetings exported by Python with their audio (fictional people, 2 s of tones), and what Python's import makes of
    them: ``exchange-python-audio.zip`` (both tracks at 16 kHz: Ogg Opus) and ``exchange-python-audio-flac.zip`` (both
    at 22.05 kHz: FLAC); ``exchange-python-audio-system.wav`` and ``exchange-python-audio-flac-system.wav``, the system
    track each import wrote; ``exchange-python-audio-decoded.wav``: the zip's ``audio/system.opus`` as soundfile reads
    it (float32), written as 16-bit PCM.

    Keys: ``zips`` (file → {"entries": [name, compress_type], "audio": {entry: {"rate", "channels", "frames"}}});
    ``imported`` (file → {"rate", "frames"} of the system track written)."""
    import os
    import tempfile
    import zipfile

    import numpy as np
    import soundfile as sf

    from palaver import exchange
    from palaver.models import Utterance
    from palaver.paths import RecordingPaths

    def tones(rate: int, hz: float, amplitude: float) -> np.ndarray:
        t = np.arange(rate * 2) / rate
        return (amplitude * np.sin(2 * np.pi * hz * t) * np.minimum(1.0, 4 * t)).astype(np.float32)

    out: dict = {"zips": {}, "imported": {}}
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        old = os.environ.get("XDG_CONFIG_HOME")
        os.environ["XDG_CONFIG_HOME"] = str(root / "cfg")
        try:
            for name, rate in (("exchange-python-audio", 16_000), ("exchange-python-audio-flac", 22_050)):
                paths = RecordingPaths(root / name / "2026-10-29T10-00-00")
                paths.folder.mkdir(parents=True)
                paths.meta.write_text(json.dumps({"start_time": "2026-10-29T10:00:00+01:00", "duration_seconds": 2}))
                paths.system_turns.write_text(json.dumps([{"speaker": "SPEAKER_00", "start": 0.5, "end": 1.5}]))
                utterances = [Utterance("Timo Strauß", 0.0, 0.5, "Hallo."),
                              Utterance("Valerie", 0.5, 1.5, "Hallo Timo.", label="SPEAKER_00")]
                paths.transcript_json.write_text(json.dumps([u.to_dict() for u in utterances]))
                paths.speakers.write_text(json.dumps({"SPEAKER_00": "Valerie"}))
                sf.write(str(paths.system_wav), tones(rate, 440, 0.3), rate, subtype="PCM_16")
                sf.write(str(paths.mic_wav), tones(rate, 660, 0.2), rate, subtype="PCM_16")
                export = exchange.export_meeting(paths, root / f"{name}.zip", user_name="Timo Strauß", audio=True)
                (folder / f"{name}.zip").write_bytes(export.read_bytes())
                zipped: dict = {"audio": {}}
                with zipfile.ZipFile(export) as zf:
                    zipped["entries"] = [[i.filename, i.compress_type] for i in zf.infolist()]
                    for entry in zf.namelist():
                        if entry.startswith("audio/"):
                            raw = root / entry.replace("/", "-")
                            raw.write_bytes(zf.read(entry))
                            info = sf.info(str(raw))
                            zipped["audio"][entry] = {"rate": info.samplerate, "channels": info.channels,
                                                      "frames": info.frames}
                            if entry == "audio/system.opus":
                                decoded, decoded_rate = sf.read(str(raw), dtype="float32")
                                sf.write(str(folder / "exchange-python-audio-decoded.wav"), decoded, decoded_rate,
                                         subtype="PCM_16")
                out["zips"][f"{name}.zip"] = zipped
                done = exchange.import_package(root / f"{name}-in", folder / f"{name}.zip", user_name="Valerie")
                wav = RecordingPaths(root / f"{name}-in" / done.id).system_wav
                (folder / f"{name}-system.wav").write_bytes(wav.read_bytes())
                info = sf.info(str(wav))
                out["imported"][f"{name}.zip"] = {"rate": info.samplerate, "frames": info.frames}
        finally:
            if old is None:
                os.environ.pop("XDG_CONFIG_HOME")
            else:
                os.environ["XDG_CONFIG_HOME"] = old
    return out


# Each section gets the Goldens/ folder (for extra files) and returns the top-level object.
# The coach's test meeting (tests/test_coach.py's LINES), with fictional names.
COACH_LINES = [
    ("Timo", 0, 100, "Also ich habe das halt irgendwie quasi so gedacht, halt ganz anders und irgendwie besser."),
    ("Timo", 101, 200, "Und dann halt nochmal, weil das halt wichtig ist und ich das so sehe, ähm, genau."),
    ("SPEAKER_00", 205, 230, "Okay, verstehe ich, und was machen wir mit dem Budget, das ist ja noch offen?"),
    ("Timo", 228, 240, "Das Budget klären wir morgen mit dem Team, ganz sicher."),
    ("SPEAKER_00", 240.5, 241, "Ja."),
    ("Timo", 245, 250, "Wie siehst du das?"),
    ("SPEAKER_00", 254, 280, "Ich finde das gut, wir sollten aber die Kosten im Blick behalten."),
]
_COACH_WORDS = ["halt", "Halt", "HALT", "irgendwie", "quasi", "genau", "Genau", "sozusagen", "eigentlich", "actually",
                "basically", "you know", "kind of", "sort of", "äh", "Ähm", "öhm", "uh", "erm", "und", "ich", "das", "ist",
                "nicht", "wir", "aber", "auch", "and", "the", "is", "not", "we", "but", "also", "that", "Budget", "Kosten",
                "Northwind", "Contoso", "Straße", "it's", "don’t", "x-halt", "halt-los", "halt_x", "42", "Q3", "Valerie",
                "Timo Strauß", "plan", "rollout", "Freitag", "😀"]
_COACH_OPENERS = ["Wie", "was", "Warum", "welcher", "Welches", "wofür", "How", "what", "WHY", "„Wie", "\"What", "'wer",
                  "Wieviel", "Ob", "Kannst", "Do"]


def _coach_meeting(rng, n: int) -> list[dict]:
    """A random meeting: my lines and three other voices, overlaps and echoes, questions and fillers."""
    voices = ["Timo", "Timo", "Timo", "timo", "SPEAKER_00", "SPEAKER_01", "SPEAKER_02"]
    out, t, last_text = [], rng.uniform(0, 5), ""
    for _ in range(n):
        who = rng.choice(voices)
        span = rng.choice([rng.uniform(0.2, 1.4), rng.uniform(1.5, 8), rng.uniform(5, 45), round(rng.uniform(1, 30), 1)])
        start = t
        words = [rng.choice(_COACH_WORDS) for _ in range(max(1, int(span * rng.uniform(1.0, 3.5))))]
        if rng.random() < 0.25:
            words[0] = rng.choice(_COACH_OPENERS)
        text = " ".join(words) + rng.choice([".", "?", "? ", "?  ", "!", ", ähm", "?\n"])
        if rng.random() < 0.1 and last_text:
            text = last_text  # an echo of the line before
        line = {"speaker": who, "start": start, "end": start + span, "text": text}
        if who.startswith("SPEAKER"):
            line["label"] = who
        elif rng.random() < 0.05:
            line["label"] = "SPEAKER_03"  # a voice once named like me, still a label: not mine
        out.append(line)
        last_text = text
        t = start + span + rng.choice([rng.uniform(-3, 0), rng.uniform(0, 1), rng.uniform(0, 4), rng.uniform(3, 12)])
    return out


def _coach_row(rng, i: int) -> dict:
    kind = rng.choice(["1:1", "group", "group", "1:1"])
    lang = rng.choice(["de", "de", "en"])
    num = lambda f: None if rng.random() < 0.15 else f()  # noqa: E731
    month, day = rng.randint(1, 12), rng.randint(1, 28)
    start = rng.choice([f"2026-{month:02d}-{day:02d}T{rng.randint(7, 19):02d}:00:00+01:00",
                        f"2026-{month:02d}-{day:02d}T09-30-00", f"2025-{month:02d}-{day:02d}"])
    return {"id": f"m{i}", "start": start, "kind": kind, "language": lang,
            "minutes_talked": rng.choice([0.5, 2.9, 3.0, round(rng.uniform(0, 30), 1)]),
            "talk": {"share": num(lambda: round(rng.random(), 3)), "people": 2 if kind == "1:1" else rng.randint(3, 6)},
            "pace": {"wpm": num(lambda: rng.randint(90, 200))},
            "fillers": {"per_minute": num(lambda: round(rng.uniform(0, 6), 2))},
            "questions": {"per_hour": num(lambda: round(rng.uniform(0, 40), 1))}}


def _coach(folder: Path) -> dict:
    """coach.py: statistics.mean/median as it uses them, fuzz.partial_ratio, `analyze` on the test meeting and on
    random ones (each case: the meeting's JSON files, settings.json, user, invited, names and the result), and
    baseline, trends and highlights over random rows."""
    import os
    import random
    import statistics
    import tempfile

    from rapidfuzz import fuzz

    from palaver import coach, settings, shared_mic
    from palaver.paths import RecordingPaths

    rng = random.Random(31)
    out: dict = {}

    means = [[0.4, 0.401], [0.1, 0.2, 0.3], [140, 141], [140, 140], [130, 140, 150], [1, 2], [0.5, 1], [0.333] * 3,
             [0.807], [1.5, 1.0, 2.0], [0.1] * 10, [1e-300, 1e300, -1e300], [0.0, -0.0], [2.675, 2.675]]
    for _ in range(300):
        n = rng.randint(1, 30)
        kind = rng.choice(["share", "int", "fillers", "raw", "mixed"])
        if kind == "share":
            vals = [round(rng.random(), 3) for _ in range(n)]
        elif kind == "int":
            vals = [rng.randint(80, 220) for _ in range(n)]
        elif kind == "fillers":
            vals = [round(rng.uniform(0, 6), 2) for _ in range(n)]
        elif kind == "raw":
            vals = [rng.uniform(-1e3, 1e3) * 10 ** rng.randint(-8, 8) for _ in range(n)]
        else:
            vals = [rng.randint(0, 9) if rng.random() < 0.5 else round(rng.uniform(0, 9), 1) for _ in range(n)]
        means.append(vals)
    out["mean"] = [[v, statistics.mean(v)] for v in means]
    medians = [[4.0], [1.0, 2.0], [3.5, 0.1, 2.2], [0.1, 0.2]] + [
        [round(rng.uniform(0, 10), 1) for _ in range(rng.randint(1, 9))] for _ in range(60)]
    out["median"] = [[v, statistics.median(v)] for v in medians]

    alphabet = "abcde äöüß-?😀"
    pairs = [("", ""), ("", "abc"), ("abc", ""), ("a", "a"), ("ja das budget", "das budget klären wir morgen"),
             ("ab" * 40, "xx" + "ab" * 45), ("a" * 70, "b" * 3 + "a" * 70)]
    while len(pairs) < 500:
        n = rng.choice([1, 3, 10, 30, 63, 64, 65, 80, 150])
        a = "".join(rng.choice(alphabet) for _ in range(rng.randint(0, n)))
        if rng.random() < 0.6:
            b = list(a)
            for _ in range(rng.randint(0, 1 + len(b) // 3)):
                k = rng.randint(0, len(b))
                op = rng.choice("ids")
                if op == "i":
                    b.insert(k, rng.choice(alphabet))
                elif b and op == "d":
                    del b[min(k, len(b) - 1)]
                elif b:
                    b[min(k, len(b) - 1)] = rng.choice(alphabet)
            pad = lambda: "".join(rng.choice(alphabet) for _ in range(rng.randint(0, 30)))  # noqa: E731
            b = pad() + "".join(b) + pad() if rng.random() < 0.5 else "".join(b)
        else:
            b = "".join(rng.choice(alphabet) for _ in range(rng.randint(0, n)))
        pairs.append((a, b))
    out["partial_ratio"] = [[a, b, fuzz.partial_ratio(a, b)] for a, b in pairs]

    def lines_of(spec):
        return [{"speaker": who, "start": s, "end": e, "text": t, **({"label": who} if who.startswith("SPEAKER") else {})}
                for who, s, e, t in spec]

    cases = []
    with tempfile.TemporaryDirectory() as tmp:
        old = os.environ.get("XDG_CONFIG_HOME")
        os.environ["XDG_CONFIG_HOME"] = str(Path(tmp) / "cfg")
        try:
            def case(name, lines, *, user="Timo", aliases=(), invited=(), names=None, marks=None, turns=None,
                     merged=None, ignored=None):
                paths = RecordingPaths(Path(tmp) / f"c{len(cases)}" / "2026-10-27T10-00-00")
                paths.folder.mkdir(parents=True)
                paths.meta.write_text(json.dumps({"start_time": "2026-10-27T10:00:00+01:00", "duration_seconds": 900}))
                paths.transcript_json.write_text(json.dumps(lines))
                if turns is not None:
                    paths.system_turns.write_text(json.dumps(turns))
                if merged:
                    paths.speakers_merged.write_text(json.dumps(merged))
                if ignored:
                    paths.speakers_ignored.write_text(json.dumps(ignored))
                for mark in marks or []:
                    if mark[0] == "meeting":
                        shared_mic.set_meeting(paths, True)
                    else:
                        shared_mic.set_lane(paths, mark[0], True, mark[1])
                settings.update({"user_aliases": list(aliases)})
                files = {f.name: json.loads(f.read_text()) for f in sorted(paths.folder.glob("*.json"))}
                result = coach.analyze(paths, user_name=user, invited=list(invited), names=names or {})
                cases.append({"name": name, "files": files, "settings": json.loads(settings.path().read_text()),
                              "user": user, "invited": list(invited), "names": names or {}, "result": result})

            base = lines_of(COACH_LINES)
            case("test meeting", base, invited=["Valerie", "Carla"], names={"SPEAKER_00": "Valerie"})
            case("an earlier name", base, user="Timo Strauß", aliases=["Timo"], names={"SPEAKER_00": "Valerie"})
            case("a room on the system track", base, invited=["Valerie", "Carla"],
                 turns=[{"speaker": "SPEAKER_00", "start": 205, "end": 280}], marks=[("SPEAKER_00", "Lab")])
            case("several people at my mic", base, marks=[(shared_mic.MIC, None)])
            case("the whole meeting in person", base, marks=[("meeting",)])
            case("a merged and an ignored voice",
                 base + lines_of([("SPEAKER_01", 300, 340, "Und ich sehe das auch so, das passt für uns gut."),
                                  ("SPEAKER_02", 341, 360, "Ignoriert.")]),
                 merged={"SPEAKER_01": "SPEAKER_00"}, ignored=["SPEAKER_02"], invited=["valerie", "Carla"],
                 names={"SPEAKER_00": "Valerie"})
            case("nobody else", lines_of([("Timo", 0, 50, "Nur ich, halt."), ("Timo", 52, 130, "Und weiter?")]))
            case("nobody", [])
            # Python's sum() is compensated: 200 x 0.3 s is 60.0, a minute (a plain sum is just under it).
            case("a minute in tenths", lines_of([("Timo", 0.0, 0.3, "Halt ja, genau.")] * 200))
            case("others in tenths", lines_of([("Timo", 0, 50, "Und dann?")] + [
                ("SPEAKER_00" if i % 2 else "SPEAKER_01", 51.0, 51.1, "Ja.") for i in range(30)]))
            for i in range(30):
                n = rng.choice([3, 10, 30, 60])
                invited = rng.sample(["Valerie", "Carla", "Timo Strauß", "valerie", "Northwind Team"], rng.randint(0, 3))
                names = {k: v for k, v in {"SPEAKER_00": "Valerie", "SPEAKER_01": "Carla",
                                           "SPEAKER_02": "Northwind Team"}.items() if rng.random() < 0.6}
                marks = rng.choice([None, None, None, [("SPEAKER_01", "Lab")], [(shared_mic.MIC, "Raum 3.12")]])
                case(f"random {i}", _coach_meeting(rng, n), invited=invited, names=names, marks=marks,
                     turns=[{"speaker": "SPEAKER_00", "start": 0.0, "end": 30.0}] if marks else None)
        finally:
            if old is None:
                os.environ.pop("XDG_CONFIG_HOME")
            else:
                os.environ["XDG_CONFIG_HOME"] = old
    out["analyze"] = cases

    results = [c["result"] for c in cases]
    rows = [_coach_row(rng, i) for i in range(60)]
    out["baseline"] = [[rows[:k], coach.baseline(rows[:k])] for k in (0, 1, 5, 29, 30, 31, 60)]
    out["baseline_of_analyze"] = coach.baseline(results)  # over the results of out["analyze"]
    out["trends"] = [[rows[:k], w, coach.trends(rows[:k], weeks=w)] for k in (0, 1, 7, 60) for w in (12, 4, 1, 0)]
    bases = [coach.baseline(rows[:k]) for k in (0, 3, 30)] + [
        {"meetings": 5, "share_1on1": 0.5, "share_group": 0.4, "wpm": 150, "fillers_per_minute": {"de": 1.0},
         "questions_per_hour": 20},
        {"meetings": 5, "share_1on1": 0.9, "share_group": 0.95, "wpm": 150, "fillers_per_minute": {"de": 0, "en": 9.0},
         "questions_per_hour": 20}]
    out["bases"] = bases
    # [index in out["analyze"], index in out["bases"], what is said]
    out["highlights"] = [[i, j, coach.highlights(r, b)] for i, r in enumerate(results) for j, b in enumerate(bases)]
    return out


def _pipeline(folder: Path) -> dict:
    """cleanup.py's levels and texts, merger.py's speakers. `signals` are little-endian int16 hex (noise of several
    loudnesses). `silent` is [signal, rate, channels, start, end, level, [[min_peak_dbfs, kept]...]]: `level` the
    loudest frame's RMS as numpy computes it in cleanup.drop_silent_segments (float32, as a float; None for an empty
    clip), `kept` what drop_silent_segments answers at thresholds on both sides of the level (its float32 neighbours
    too). `removed` is [raw, out, rate, start, end, dB] of cleanup._aec_removed_db on the tracks as drop_echo reads
    them. `bleed` is [mic segments, system segments, kept indices]; `aligned` is [mic segment, remote words, words,
    aligned, echoes_remote]; `assign` is [segments, turns, speakers]."""
    import math
    import random
    import tempfile

    import numpy as np
    import soundfile as sf

    from palaver import cleanup, merger
    from palaver.models import Segment, SpeakerTurn, Word

    rng = random.Random(32)

    def noise(n: int, amp: int) -> np.ndarray:
        return np.array([rng.randint(-amp, amp) for _ in range(n)], dtype=np.int16)

    signals = {
        "loud": noise(8_000, 20_000),
        "near_mic": noise(8_000, 1_010),  # RMS around -35 dBFS
        "near_system": noise(8_000, 180),  # around -50 dBFS
        "faint": noise(8_000, 3),
        "zero": np.zeros(8_000, dtype=np.int16),
        "stereo": noise(16_000, 1_000),  # 8000 frames of two channels
        "long": noise(20_000, 800),
    }
    signals["burst"] = signals["faint"].copy()
    signals["burst"][4_000:4_400] = noise(400, 6_000)

    def loudest(audio: np.ndarray, sr: int, start: float, end: float):
        """drop_silent_segments' level, the same numpy expression."""
        audio = audio.mean(axis=1)
        frame = max(1, int(0.1 * sr))
        clip = audio[int(start * sr): int(end * sr)]
        if clip.size == 0:
            return None
        n = max(1, clip.size // frame)
        frames = clip[: n * frame].reshape(n, -1) if clip.size >= frame else clip[None, :]
        return np.sqrt((frames**2).mean(axis=1)).max()

    spans = [(0.0, 0.5), (0.0123, 0.3), (0.1, 0.15), (0.45, 0.6), (0.6, 0.7), (-0.1, 0.2), (-0.2, -0.05),
             (0.21, 0.4999), (0.0, 10.0)]
    silent = []
    with tempfile.TemporaryDirectory() as tmp:
        wav = Path(tmp) / "track.wav"
        for name, rate, channels in [("loud", 16_000, 1), ("near_mic", 16_000, 1), ("near_system", 16_000, 1),
                                     ("faint", 16_000, 1), ("zero", 16_000, 1), ("burst", 16_000, 1),
                                     ("stereo", 16_000, 2), ("near_mic", 8_000, 1), ("long", 44_100, 1),
                                     ("near_system", 48_000, 1)]:
            x = signals[name]
            sf.write(str(wav), x.reshape(-1, channels) if channels > 1 else x, rate, subtype="PCM_16")
            audio, sr = sf.read(str(wav), dtype="float32", always_2d=True)
            for start, end in spans:
                level = loudest(audio, sr, start, end)
                dbs = [cleanup.MIC_MIN_PEAK_DBFS, cleanup.SYSTEM_MIN_PEAK_DBFS]
                if level is not None and level > 0:
                    for v in (float(level), float(np.nextafter(level, np.float32(1))),
                              float(np.nextafter(level, np.float32(0)))):
                        d = 20 * math.log10(v)
                        dbs += [d, math.nextafter(d, math.inf), math.nextafter(d, -math.inf)]
                    for other in (np.nextafter(level, np.float32(1)), np.nextafter(level, np.float32(0))):
                        mid = (float(level) + float(other)) / 2  # where the threshold's float32 rounding decides
                        d = 20 * math.log10(mid)
                        dbs += [d, math.nextafter(d, math.inf), math.nextafter(d, -math.inf)]
                seg = Segment(start, end, "x")
                kept = [[d, bool(cleanup.drop_silent_segments([seg], wav, d))] for d in dbs]
                silent.append([name, rate, channels, start, end, None if level is None else float(level), kept])

        removed = []
        raw_wav, out_wav = Path(tmp) / "mic_raw.wav", Path(tmp) / "mic.wav"
        for raw_name, out_name, rate in [("loud", "near_mic", 16_000), ("near_mic", "loud", 16_000),
                                         ("near_mic", "near_system", 16_000), ("faint", "zero", 16_000),
                                         ("long", "long", 16_000), ("burst", "faint", 8_000)]:
            sf.write(str(raw_wav), signals[raw_name], rate, subtype="PCM_16")
            sf.write(str(out_wav), signals[out_name], rate, subtype="PCM_16")
            raw, _ = sf.read(str(raw_wav), dtype="int16")
            out, _ = sf.read(str(out_wav), dtype="int16")
            for start, end in [(0.0, 0.1), (0.31, 0.32), (0.2, 0.9), (0.5, 0.6), (0.79, 1.0), (1.0, 2.0), (0.0, 3.0),
                               (-1.0, 0.01)]:
                db = cleanup._aec_removed_db(raw, out, rate, Segment(start, end, "x"))
                removed.append([raw_name, out_name, rate, start, end, db])

    texts = ["Straße und Haus", "STRASSE und Haus", "strasse und haus", "ΟΔΟΣ ΚΑΙ ΣΠΙΤΙ", "οδος και σπιτι",
             "οδός και σπίτι", "Ca\u0301fe\u0301 au lait", "Café au lait", "İstanbul ist groß", "i̇stanbul ist groß",
             "don't stop me now", "don’t stop me now", "a_b c_d e_f", "Ⅻ ½ ² x²", "Timo Strauß hier", "timo strauss hier",
             "Contoso, Northwind; Contoso!", "contoso northwind contoso", "😀 ja 😀 ja", "ja ja ja ja"]
    bleed = []
    for i, mic_text in enumerate(texts):
        for j, sys_text in enumerate(texts):
            if (i + j) % 3:
                continue
            mic = [Segment(10.0, 12.0, mic_text)]
            system = [Segment(9.0, 13.0, sys_text), Segment(14.5, 20.0, texts[(i + 1) % len(texts)])]
            kept = cleanup.drop_bleed_duplicates(mic, system)
            bleed.append([[s.to_dict() for s in mic], [s.to_dict() for s in system], [mic.index(k) for k in kept]])

    def timed(start: float, text: str, step: float) -> Segment:
        words = [Word(w, round(start + k * step, 3), round(start + (k + 1) * step, 3)) for k, w in enumerate(text.split())]
        return Segment(start, words[-1].end if words else start, text, words=words)

    phrases = ["wann ist der Go-Live denn", "WANN ist der go live, denn?", "Straße ist frei heute", "strasse ist frei heute",
               "you can have your health insurance claim", "you can have your health and shooting job",
               "ja ja ja ja ja", "— ... !!", "Genau. Genau. Genau.", "Café au lait bitte", "Ca\u0301fe\u0301 au lait bitte"]
    aligned = []
    for i, mic_text in enumerate(phrases):
        for j, remote_text in enumerate(phrases):
            for offset in (0.0, 0.3, 0.49, 0.51, 2.0):
                if (i * 5 + j + int(offset * 100)) % 4:
                    continue
                mic = timed(10.0 + offset, mic_text, 0.3)
                remote = timed(10.0, remote_text, 0.35).words + timed(13.5, phrases[(j + 3) % len(phrases)], 0.4).words
                words, n = cleanup._aligned_words(mic, [w for w in remote if cleanup._norm(w.text)])
                aligned.append([mic.to_dict(), [w.to_dict() for w in remote], words, n,
                                cleanup.echoes_remote(mic, [w for w in remote if cleanup._norm(w.text)])])

    assign = []
    for k in range(40):
        turns = []
        t = 0.0
        for _ in range(rng.randint(0, 5)):
            t = round(t + rng.choice([0.0, rng.uniform(0, 3)]), 2)
            end = round(t + rng.choice([0.0, rng.uniform(0.1, 4)]), 2)
            turns.append(SpeakerTurn(rng.choice(["SPEAKER_00", "SPEAKER_01", "SPEAKER_02"]), t, end))
            t = round(t + rng.choice([-0.5, 0.0, rng.uniform(0, 4)]), 2)
        rng.shuffle(turns)
        words = []
        w = 0.0
        for _ in range(rng.randint(1, 12)):
            w = round(w + rng.uniform(0, 1.5), 2)
            words.append(Word(rng.choice(["ja", "nein", "Contoso"]), w, round(w + rng.choice([0.0, rng.uniform(0, 1)]), 2)))
        segs = [Segment(0.0, w + 1, "x", words=words)]
        assign.append([[s.to_dict() for s in segs], [t.to_dict() for t in turns],
                       [a[3] for a in merger.assign_speakers_to_words(segs, turns)]])

    return {"signals": {k: v.astype("<i2").tobytes().hex() for k, v in signals.items()}, "silent": silent,
            "removed": removed, "bleed": bleed, "aligned": aligned, "assign": assign}


SENTENCEPIECE_TEXTS = [
    # empty, spaces and whitespace runs
    "", " ", "  ", "\t", "\n", "　", " ", "   ", "a", " a", "a ", "  a  ", "a b", "a  b", "a   b   c",
    "  leading", "trailing  ", "  both  ", "one  two\t\tthree\n\nfour", "　a　b　", "a b", "a b",
    "a​b", "​", "​ ​", "a b c", "x \x1c y \x85 z", "a\x0bb\x0cc\rd", " \t \n ",
    # control characters, NUL, the space symbol itself
    "a\x00b", "\x00", "\x01\x02\x03", "a\x1cb", "a\x7fb", "\x85\x85", "Timo\x1dStrauß\x1e Valerie\x1fContoso",
    "▁", "▁▁", "a▁b", " ▁ ", "▁hello", "hello▁", "a▁ b", "▁▁ world",
    # the tiny vocabulary
    "hello world", "pricing the offer a b c d", "cost", "the offer costs a lot", "world wide pricing",
    "cost and price", "hello", "world", "helloworld", "the", "thethe", "the the the", "a a a a", "abcd", "dddd",
    "lolololo", "he he he", "pricingpricing", "offer offer", "costcost", "wide", "lot", "d e lo", "hellohello world",
    "HELLO WORLD", "Hello World", "hElLo", "the Offer", "Pricing", "COST",
    # NFKC-ish: full width, ligatures, compatibility forms, superscripts, fractions, roman numerals
    "ｈｅｌｌｏ　ｗｏｒｌｄ", "ＨＥＬＬＯ", "ｃｏｓｔ", "Ｔｉｍｏ Ｓｔｒａｕß", "１２３", "１２３abc", "ﬁ", "ﬁx", "ﬂ", "ﬃ", "ﬀ",
    "oﬃce", "ﬁnal oﬀer", "ŉ", "Ǆ", "ǅ", "ǆ", "Ⅻ", "ⅻ", "Ⅳ Ⅴ Ⅵ", "½", "¼ ¾", "x²", "H₂O", "10⁻³", "™", "℃", "℉",
    "㎏", "㎞", "㍻", "㈱", "①②③", "⑴", "⒜", "ｱｲｳ", "ｶﾞ", "ﾊﾟ", "ガ", "ガ", "…", "‥", "‼", "⁇", "„quote“",
    "«guillemets»", "‘single’", "–—", "−1", "ℌ", "ℍ", "ℯ", "𝐀𝐁𝐂", "𝕒𝕓𝕔", "𝔥𝔢𝔩𝔩𝔬", "Å", "K", "Ω", "µ", "ſ", "ẞ",
    "ß", "ﬆ", "ﬅ", "ǈ", "ĳ", "Ĳ", "ℓ", "№", "℡", "㏂", "ﷺ", "ﷻ", "︵", "﹏", "ﹰ", "ﺍ", "ﻻ",
    # combining marks, NFC vs NFD
    "Strauße", "Ümläute", "Ümläute", "café", "café", "é́", "́", "à́̂",
    "Ä Ö Ü ä ö ü", "Ä Ö Ü", "ñ", "ñ", "Å", "Å", "ḱ", "q̣̇", "̣̇",
    "ﬁ́", "가", "가", "각", "각",
    # emoji
    "😀", "😀😀", "😀 world 😀", "👍🏽", "👩‍💻", "👨‍👩‍👧‍👦", "🇩🇪🇦🇹", "❤️", "❤️", "#️⃣", "🏳️‍🌈", "a😀b", "😀word😀",
    "Emoji at the edge: 😀word😀 and 👩‍💻dev👩‍💻", "tschüss!!! 👋👋 bis morgen, Timo", "🚧 Straße gesperrt 🚧",
    # German and English sentences, fictional names
    "Ähm, also die Straße ist gesperrt 🚧, sagt Timo Strauß.", "Uh-huh, yeah, mmm, the Northwind deal closes Q3 😀.",
    "Hmm. Wir brauchen für150 Lizenzen bis Ende2030, ok?", "ÖHM… das kostet 12,50 € pro Monat 💶 für Contoso.",
    "strasse, STRASSE, Straße and STRAẞE are four spellings.", "uhm uhmm uhhh — Valerie: 'okay, let's go' 👍🏽",
    "MP3 und COVID19 bleiben, aber größe2024 wird getrennt.", "Die Zahlen: ٣٤ (arabisch), ४२ (Devanagari), 42.",
    "Ein ſchönes langes ſ, und ein Kelvin-Zeichen: 300 K.", "Was hat Valerie zu den Kosten gesagt?",
    "query: what did we decide about pricing", "passage: Timo Strauß hat das Angebot für Northwind geschickt.",
    "query: Kosten für Contoso im März", "passage: The offer for Contoso is priced at 12,50 € per seat.",
    "Wie gesagt, wie gesagt, das passt.", "Und dann, ähm, machen wir das.", "Let's think about this um I also don't know.",
    "If the the the tax ministry comes", "Northwind", "NORTHWIND", "northwind", "Contoso Ibérica", "Valerie",
    "Timo Strauß", "TIMO STRAUSS", "timo strauss", "Straßenbau", "Fußgängerübergänge", "Grüße aus Köln",
    "Donaudampfschifffahrtsgesellschaftskapitänsmützenabzeichen", "Rindfleischetikettierungsüberwachungsaufgabenübertragungsgesetz",
    # other scripts and unknown characters
    "Привет мир", "Γειά σου κόσμε", "ΣΑΣ ας", "שלום עולם", "مرحبا بالعالم", "你好，世界", "こんにちは世界", "안녕하세요",
    "नमस्ते दुनिया", "สวัสดีชาวโลก", "ሰላም", "Ꭰ", "𐍈", "𓀀", "\U0010fffd", "", "�", "﻿hello", "hello﻿",
    "¿Qué tal?", "¡Hola!", "Ångström", "Øresund", "Łódź", "İstanbul", "ı", "ǰ", "ΐ", "ﬓ",
    # pieces that look like control pieces
    "<s>", "</s>", "<unk>", "<s> hello </s>", "<pad>", "<mask>",
    # punctuation, digits, mixed
    "a,b.c;d:e!f?g", "(the offer)", "[cost]", "{world}", "\"hello\"", "'hello'", "a-b-c", "a_b_c", "a/b\\c", "@timo",
    "#pricing", "$100", "100%", "1+1=2", "3.14159", "1,000,000", "2026-11-07", "12:30", "+49 30 1234567", "e-mail@contoso.example",
    "https://northwind.example/offer?id=42", "C++ and C#", "x=1;y=2", "~~~", "...", "!!!", "???", "---", "___", "***",
    # user-defined, unused and tie pieces of the constructed models
    "[Contoso]", "[Contoso", "[C", "[Contoso] [C [Contoso][Contoso]", "ﬁx ﬁx", "ﬁxed", "fix", "xyz", "xyzabc", "q", "qa",
    "qq", "qqa", "aq", "ab", "abc", "abcabc", "bc", "a b c", "ab c", "a bc", "a▁b c", "the a", "theab", "hello abc",
    "a　b　c", "ab c", "ＡＢＣ", "ａｂｃ", "abc ﬁ [Contoso] q xyz",
]


def _sentencepiece_texts() -> list[str]:
    import random

    rng = random.Random(33)
    parts = ["hello", "world", "the", "offer", "pricing", "cost", "a", "b", "c", "d", "lo", "he", "ab", "abc", "q", "qa",
             "xyz", "[Contoso]", "[C", "ﬁx", "Straße", "Timo", "Valerie", "Northwind", "Contoso", "ü", "ü", "ß",
             "ｈｅｌｌｏ", "ＡＢＣ", "Ⅻ", "½", "😀", "👩‍💻", "é", "é", "́", "1", "２", "<s>", "▁", "\x00", "\x1c",
             "\x85", "​", "﻿", "Привет", "你好", ",", ".", "!", "?", "-", "'", "€"]
    seps = [" ", " ", " ", "", "  ", "\t", "\n", "　", " ", " ", "   "]
    texts = list(SENTENCEPIECE_TEXTS)
    while len(texts) < 492:
        n = rng.randint(1, 9)
        text = "".join(rng.choice(parts) + rng.choice(seps) for _ in range(n))
        if rng.random() < 0.3:
            text = rng.choice(seps) + text
        if rng.random() < 0.5:
            text = text.rstrip(" ")
        texts.append(text)
    # very long words and texts: one piece per character, a word longer than any piece, unknown runs, and a path
    # whose score passes sentencepiece's ±100000 rescale (every unknown character costs min score − 10)
    texts += [
        "a" * 2000, "hello" * 400, "ab" * 1000 + "c", "x" * 3000, "Ω" * 1000 + " hello", "😀" * 500,
        "q" * 9000 + " the offer abc ab a b",
        ("hello world the offer abc " * 400).strip(),
    ]
    return texts


def _sentencepiece_model(normalizer, *, suffix: bool = False):
    """The constructed test model: control and unknown pieces, round scores (ab = a + b, the = ▁ + t + he …, so
    equal-score paths compete), user-defined pieces ([Contoso], its prefix [C, and the unnormalized ﬁx), unused ones
    (q, xyz: q is then unknown) and qa, which ties with unknown q + a."""
    from sentencepiece import sentencepiece_model_pb2 as pb

    m = pb.ModelProto()
    m.trainer_spec.model_type = pb.TrainerSpec.UNIGRAM
    m.trainer_spec.vocab_size = 0
    m.trainer_spec.treat_whitespace_as_suffix = suffix
    m.normalizer_spec.CopyFrom(normalizer)
    T = pb.ModelProto.SentencePiece

    def add(piece: str, score: float, kind=T.NORMAL) -> None:
        m.pieces.add(piece=piece, score=score, type=kind)

    add("<unk>", 0.0, T.UNKNOWN)
    add("<s>", 0.0, T.CONTROL)
    add("</s>", 0.0, T.CONTROL)
    add("▁", -2.0)
    for ch in "abcdefghijklmnoprstuvwxyzABCDEFGHIJKLMNOPRSTUVWXYZäößé0123456789.,!?-'€😀 ":
        add(ch, -3.0)
    for piece, score in [("ab", -6.0), ("bc", -6.0), ("abc", -9.0), ("▁a", -5.0), ("he", -6.0), ("lo", -6.0),
                         ("hello", -12.0), ("▁hello", -14.0), ("▁the", -11.0), ("▁world", -13.5), ("world", -15.0),
                         ("ss", -4.0), ("▁Straße", -5.0), ("Timo", -7.0), ("▁Timo", -8.0), ("fi", -4.5), ("a▁b", -1.0),
                         ("qa", -22.0), ("▁offer", -9.25), ("offer", -9.25), ("e▁", -5.0), ("o ", -4.0), ("▁▁", -3.5),
                         ("ü", -2.5), ("XII", -1.5), ("1/2", -6.0)]:
        add(piece, score)
    add("[Contoso]", 0.0, T.USER_DEFINED)
    add("[C", 0.0, T.USER_DEFINED)
    add("ﬁx", 0.0, T.USER_DEFINED)
    add("q", -3.0, T.UNUSED)
    add("xyz", -1.0, T.UNUSED)
    return m


SENTENCEPIECE_VERSION = "0.2.2"


def _sentencepiece(folder: Path) -> dict:
    """sentencepiece's `SentencePieceProcessor.encode(text)` ids (as palaver.embeddings uses it) for 500 texts on
    each model. `models` maps a name to its file (repo-relative, or a file written here under Goldens/): the two
    tiny embedder models (identity normalization), `nfkc` (the constructed model with the nmt_nfkc charsmap of the
    installed sentencepiece), `raw` (identity, no dummy prefix, extra whitespace kept) and `suffix` (whitespace as
    suffix, not escaped). `ids[name][i]` is the encoding of `texts[i]`."""
    import tempfile

    import sentencepiece
    from sentencepiece import sentencepiece_model_pb2 as pb

    # The Swift port matches this version's encoder; another one needs the goldens and SentencePiece.swift checked.
    assert sentencepiece.__version__ == SENTENCEPIECE_VERSION, \
        f"sentencepiece {sentencepiece.__version__}, the goldens are for {SENTENCEPIECE_VERSION}"

    with tempfile.TemporaryDirectory() as tmp:
        corpus = Path(tmp) / "corpus.txt"
        corpus.write_text("hello world\nthe offer\n" * 50)
        sentencepiece.SentencePieceTrainer.train(input=str(corpus), model_prefix=str(Path(tmp) / "nfkc"), vocab_size=14,
                                                 model_type="unigram", minloglevel=2, num_threads=1,
                                                 normalization_rule_name="nmt_nfkc", hard_vocab_limit=False)
        trained = pb.ModelProto()
        trained.ParseFromString((Path(tmp) / "nfkc.model").read_bytes())
    nfkc = trained.normalizer_spec
    raw = pb.NormalizerSpec(name="identity", add_dummy_prefix=False, remove_extra_whitespaces=False)
    suffix = pb.NormalizerSpec(name="identity", escape_whitespaces=False)
    built = {"nfkc": _sentencepiece_model(nfkc), "raw": _sentencepiece_model(raw),
             "suffix": _sentencepiece_model(suffix, suffix=True)}
    models = {"bert": "tests/fixtures/tiny_embedder/bert/sentencepiece.bpe.model",
              "xlm-roberta": "tests/fixtures/tiny_embedder/xlm-roberta/sentencepiece.bpe.model"}
    for name, model in built.items():
        (folder / f"sentencepiece-{name}.model").write_bytes(model.SerializeToString())
        models[name] = f"sentencepiece-{name}.model"
    texts = _sentencepiece_texts()
    ids = {}
    for name, file in models.items():
        sp = sentencepiece.SentencePieceProcessor(model_file=str(ROOT / file if "/" in file else folder / file))
        ids[name] = [sp.encode(t) for t in texts]
    return {"version": sentencepiece.__version__, "models": models, "texts": texts, "ids": ids}


_E5_TEXTS = ["hello world", "pricing the offer a b c d", "cost", "", "Timo Strauß und Valerie: Kosten für Contoso 😀",
             "the offer " * 30, "a", "Northwind world hello offer cost pricing", "  spaces   between  ", "ÄÖÜ äöü ß",
             "hello", "world world world"]


def _e5_tiny(folder: Path) -> dict:
    """palaver.embeddings.Encoder (numpy) on the two tiny embedder models with its default prefixes: per model, the
    ids of each text with the passage prefix, ``passages(texts)`` (12 texts: two batches of 8, one cut at the model's
    40 positions) and ``query`` of each text, the vectors as float32 values. ``real``: see below."""
    from palaver import embeddings

    out: dict = {"texts": _E5_TEXTS}
    for kind in ("bert", "xlm-roberta"):
        source = f"tests/fixtures/tiny_embedder/{kind}"
        encoder = embeddings.Encoder(ROOT / source)
        out[kind] = {
            "folder": source,
            "ids": [encoder._ids(encoder.prefix_passage + t) for t in _E5_TEXTS],
            "passages": [[float(v) for v in row] for row in encoder.passages(_E5_TEXTS)],
            "queries": [[float(v) for v in encoder.query(t)] for t in _E5_TEXTS],
        }
    # tests/test_embeddings.py's texts through transformers' XLMRobertaTokenizer on the real vocabulary, when the
    # model is on this Mac (read where it is, never downloaded): the reference for E5Encoder.ids on the real model.
    folder = embeddings.model_folder(download=False)
    if folder is not None:
        import transformers

        theirs = transformers.XLMRobertaTokenizer.from_pretrained(str(folder), local_files_only=True)
        texts = ["query: pricing", "passage: Wir müssen noch über die Kosten für das Angebot reden.",
                 "Ähm, also ÖNW-Projekt — 120.000 € inkl. Lizenzen!!  Doppelt  Leerzeichen\nneue Zeile",
                 "日本語のテキスト", "emoji 🎉 test", "", "Straße naïve café façade"]
        long = "wort " * 2000
        out["real"] = {"revision": embeddings.REVISION, "texts": texts + [long],
                       "ids": [theirs(t)["input_ids"] for t in texts]
                       + [theirs(long, truncation=True, max_length=512)["input_ids"]]}
    return out


def _search_index(folder: Path) -> dict:
    """semantic.py's numbers (Task 35), floats as their bit patterns (ints) so NaN and -0.0 survive JSON:
    ``half`` (float32 → ``astype(np.float16)``: rounding ties, subnormals, overflow, NaN), ``npy`` (``np.save`` of
    float16 matrices, as hex), ``npy_read`` (files numpy writes in other dtypes, byte orders, Fortran order and
    format 2.0, as hex, and their ``astype(np.float32)`` in C order), ``scores`` (``matrix.astype(np.float32) @
    query`` for 1..120 rows: numpy's sdot, plain and gemv paths), ``argsort`` (``np.argsort`` on float32 with ties and
    NaN) and ``floor`` (``semantic.floor``)."""
    import io

    import numpy as np

    from palaver import semantic

    rng = np.random.default_rng(35)
    bits = lambda a: [int(x) for x in np.asarray(a, np.float32).view(np.uint32)]  # noqa: E731

    edges = np.array([0.0, -0.0, 1.0, -1.0, 65504.0, 65519.99, 65520.0, 1e9, -1e9, np.inf, -np.inf, np.nan,
                      6.1e-5, 6.0e-5, 5.96e-8, 2.98e-8, 2.99e-8, 1e-10, 0.1, 0.2, 0.3, 1 / 3], np.float32)
    ties = []
    for h in rng.integers(0, 0x7bff, 250):  # a float16 and the float32 halfway to the next one
        lo = np.array([h], np.uint16).view(np.float16).astype(np.float32)[0]
        hi = np.array([h + 1], np.uint16).view(np.float16).astype(np.float32)[0]
        mid = np.float32((np.float64(lo) + np.float64(hi)) / 2)
        ties += [mid, np.nextafter(mid, np.float32(np.inf)), np.nextafter(mid, np.float32(-np.inf)), -mid]
    raw = rng.integers(0, 2**32, 1500, dtype=np.uint64).astype(np.uint32).view(np.float32)
    normal = rng.normal(0, 0.1, 800).astype(np.float32)
    values = np.concatenate([edges, np.array(ties, np.float32), raw, normal])
    with np.errstate(over="ignore", invalid="ignore"):
        halves = values.astype(np.float16).view(np.uint16)
    half = [[b, int(h)] for b, h in zip(bits(values), halves)]

    def saved(a: np.ndarray, version=None) -> str:
        out = io.BytesIO()
        if version is None:
            np.save(out, a)
        else:
            np.lib.format.write_array(out, a, version=version)
        return out.getvalue().hex()

    npy = []
    for rows, cols in [(0, 384), (1, 8), (4, 64), (3, 5), (12, 384), (123456, 0)]:
        a = rng.normal(0, 0.2, (rows, cols)).astype(np.float32)
        npy.append([rows, cols, bits(a.ravel()), saved(a.astype(np.float16))])

    reads = []
    base = rng.normal(0, 0.5, (3, 4))
    for a, version in [(base.astype("<f2"), None), (base.astype(">f2"), None), (base.astype("<f4"), None),
                       (base.astype(">f8"), None), (np.asfortranarray(base.astype(np.float32)), None),
                       (np.asfortranarray(base.astype(np.float16)), None), (base.astype(np.float16), (2, 0)),
                       (base[:1].astype(np.float16), None), (np.zeros((0, 4), np.float16), None)]:
        reads.append([saved(a, version), list(a.shape), bits(a.astype(np.float32).ravel(order="C"))])

    scores = []
    for rows, cols in [(1, 384), (2, 384), (5, 64), (17, 384), (40, 384), (120, 64), (7, 1), (1, 1), (3, 3)]:
        m = rng.normal(0, 1, (rows, cols)).astype(np.float32)
        m /= np.maximum(np.linalg.norm(m, axis=1, keepdims=True), np.float32(1e-6))
        m16 = m.astype(np.float16)
        q = rng.normal(0, 1, cols).astype(np.float32)
        q /= np.linalg.norm(q)
        s = m16.astype(np.float32) @ q
        scores.append([rows, cols, [int(x) for x in m16.ravel().view(np.uint16)], bits(q), bits(np.atleast_1d(s))])

    argsorts = []
    for n in [0, 1, 2, 16, 17, 18, 40, 100, 257, 400]:
        for pool in (np.array([0.5, 0.7, 0.8, 0.9], np.float32), np.array([0.5, 0.7, np.nan, -0.0, 0.0], np.float32)):
            keys = rng.choice(pool, n).astype(np.float32)
            argsorts.append([bits(keys), [int(i) for i in np.argsort(keys)]])
        keys = rng.random(n).astype(np.float32)
        argsorts.append([bits(keys), [int(i) for i in np.argsort(keys)]])
    for n in [64, 500, 1200]:
        x = np.arange(n)
        for keys in (x, x[::-1], np.minimum(x, n - x), x % 7, (x * 7919) % n):
            keys = np.asarray(keys, np.float32)
            argsorts.append([bits(keys), [int(i) for i in np.argsort(keys)]])

    floors = []
    for n in [0, 10, 99, 100, 101, 200, 1001]:
        for center in (0.70, 0.75, 0.80, 0.83):
            s = (center + rng.normal(0, 0.03, n)).astype(np.float32)
            floors.append([bits(s), semantic.floor(s)])
    floors.append([bits(np.full(200, 0.80, np.float32)), semantic.floor(np.full(200, 0.80, np.float32))])
    with np.errstate(invalid="ignore"):
        nan = np.full(120, 0.9, np.float32)
        nan[3] = np.nan
        floors.append([bits(nan), semantic.floor(nan)])
    return {"half": half, "npy": npy, "npy_read": reads, "scores": scores, "argsort": argsorts, "floor": floors}


def _setup(folder: Path) -> dict:
    """onboarding.py's pure recommendation logic over many Macs and settings: `recommend` (digest of every
    `to_dict()`, in full for the first state of each Mac), `profile_table`, `offer`, `missing_models`, `download_note`,
    `summary`, `test_verdict`, `seed_terms` and `own_organization`. The inputs are in the golden, so Swift builds the
    same structs from them. A copy goes to PalaverServerTests/Fixtures, where the Swift tests are."""
    import hashlib
    from datetime import datetime

    from palaver import onboarding as ob
    from palaver.calendar_events import Attendee, Event

    GEMMA = ob.GEMMA
    lm = ["language_model"]
    tr = ["transcription"]

    def registry(ready=(), transcription=False, tready=()):
        providers = {
            "anthropic": ["Anthropic API", lm, "anthropic" in ready, None if "anthropic" in ready else "Add the API key"],
            "openai": ["OpenAI-compatible", lm, "openai" in ready, None if "openai" in ready else "Save the endpoint"],
            "claude-cli": ["Claude Code CLI", lm, "claude-cli" in ready,
                           None if "claude-cli" in ready else "Claude Code CLI (`claude`) not found"],
        }
        features = {"notes": "language_model", "projects": "language_model"}
        if transcription:
            features["transcription"] = "transcription"
            providers["assemblyai"] = ["AssemblyAI", tr, "assemblyai" in tready,
                                       None if "assemblyai" in tready else "Add the API key"]
            providers["soniox"] = ["Soniox", tr, "soniox" in tready, None if "soniox" in tready else ""]
        return {"features": features, "providers": providers}

    base_settings = {"realtime": True, "record_teams": True, "record_slack": True, "live_processing": True,
                     "search_meaning": True}
    ALL = ["speech", "gemma", "e5"]

    def cur(settings=None, choices=None, local_model=GEMMA, downloaded=ALL, reg=None, mcp=None, chosen=()):
        return {"settings": base_settings if settings is None else settings,
                "choices": {"notes": "local", "projects": "local"} if choices is None else choices,
                "local_model": local_model, "downloaded": list(downloaded), "registry": reg or registry(),
                "mcp": {"code": False, "desktop": False} if mcp is None else mcp, "chosen": list(chosen)}

    currents = [
        cur(),
        cur(downloaded=[]),
        cur(downloaded=["speech", "e5"], reg=registry(("claude-cli", "anthropic"))),
        cur(choices={"notes": "pending", "projects": "pending"}, downloaded=["speech"]),
        cur(choices={"notes": "openai", "projects": "openai", "transcription": "soniox"}, downloaded=["e5"],
            reg=registry(("anthropic", "openai"), True, ("soniox",))),
        cur(settings={"realtime": False, "live_processing": False, "record_teams": False}, mcp={"code": True},
            chosen=["realtime", "disk", "language_model"], reg=registry(("anthropic",), True)),
        cur(local_model="mlx-community/other", downloaded=["speech", "gemma"], choices={}),
        cur(settings={}, mcp={}, reg={"features": {}, "providers": {}}, downloaded=["e5", "gemma"]),
    ]
    installed_all = [
        {}, {"teams": True}, {"slack": True, "claude_code": True}, {"teams": True, "slack": True, "claude_code": True,
                                                                      "claude_desktop": True},
    ]

    def build_registry(spec):
        return ob.Registry(spec["features"], {pid: ob.ProviderInfo(p[0], frozenset(p[1]), p[2], p[3])
                                              for pid, p in spec["providers"].items()})

    def build_current(spec):
        return ob.Current(settings=spec["settings"], choices=spec["choices"], local_model=spec["local_model"],
                          downloaded=frozenset(spec["downloaded"]), registry=build_registry(spec["registry"]),
                          mcp=spec["mcp"], chosen=frozenset(spec["chosen"]))

    chips = ["Apple M1", "Apple M2", "Apple M2 Pro", "Apple M3", "Apple M4 Pro", "Apple M3 Max", "Apple M2 Ultra",
             "Apple M5", "apple m3 pro", "Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz", ""]
    memories = [8, 16, 18, 24, 32, 36, 48, 64, 96, 23.5]
    disks = [3, 10, 14.3, 15, 30, 200, 9.95, 0.5]
    recommend = []
    for ci, chip in enumerate(chips):
        for mi, memory in enumerate(memories):
            for di, disk in enumerate(disks):
                j = (ci + mi + di) % len(currents)
                k = (ci * 3 + mi + di * 5) % len(installed_all)
                got = ob.recommend(ob.Hardware(chip, memory, disk), ob.Installed(**installed_all[k]),
                                   build_current(currents[j]))
                dumped = [r.to_dict() for r in got]
                entry = {"hw": [chip, memory, disk], "installed": installed_all[k], "current": j,
                         "digest": hashlib.sha256(json.dumps(dumped, ensure_ascii=False).encode()).hexdigest()}
                if di == 0 and mi % 3 == 0:
                    entry["full"] = dumped
                recommend.append(entry)
    tables = []
    for j, spec in enumerate(currents):
        profiles = [(c, m, d) for c in chips[:6] for m in memories[:6] for d in (200, 10, 3)]
        tables.append({"current": j, "profiles": profiles,
                       "rows": ob.profile_table(profiles, build_current(spec), ob.Installed(slack=True))})

    states = [None, {}, {"done": "2026-10-29T10:00:00+01:00", "hardware": "Apple M1, 16 GB"},
              {"done": "2026-10-29T10:00:00+01:00", "hardware": "Apple M4 Pro, 48 GB"},
              {"skipped": "2026-10-29T10:00:00+01:00", "hardware": "Apple M4 Pro, 48 GB"},
              {"hardware": ""}, {"hardware": "Apple M4 Pro, 48 GB"}, {"done": ""}, {"done": "x"},
              {"hardware": 5, "done": True}, {"hardware": None, "done": [1]}]
    offers = []
    for state in states:
        for has in (False, True):
            for missing in ([], ["speech"], ["gemma"], ["speech", "gemma"]):
                offers.append([state, "Apple M4 Pro, 48 GB", has, missing,
                               ob.offer(state, "Apple M4 Pro, 48 GB", has_meetings=has, missing=missing)])

    missing = []
    for j, spec in enumerate(currents):
        for chip, memory in (("Apple M4 Pro", 48), ("Intel(R) Core(TM) i7", 16), ("Apple M1", 8)):
            missing.append([j, chip, memory, ob.missing_models(build_current(spec), ob.Hardware(chip, memory, 100))])
    notes = [[mid, memory, ob.download_note(mid, ob.Hardware("Apple M2 Pro", memory, 200))]
             for mid in ("gemma", "speech", "e5", "unknown") for memory in (8, 14, 16, 23.9, 24, 48)]
    hardware = [[chip, memory, ob.Hardware(chip, memory, 1).fingerprint, ob.Hardware(chip, memory, 1).short,
                 ob.parse_chip(chip)] for chip in chips + ["Apple M4 Pro Max", "Apple Mx", "Apple M10 pro"]
                for memory in (8, 16.5, 48.0)]

    perms = [
        {}, {"microphone": {"state": "granted", "detail": "granted"}},
        {"microphone": {"state": "granted", "detail": "granted"},
         "system_audio": {"state": "unverified", "detail": "not verified yet"},
         "calendar": {"state": "not_asked", "detail": "not connected"},
         "notifications": {"state": "unknown", "detail": "macOS asks the first time"}},
        {"microphone": {"state": "denied"}, "system_audio": {"state": "denied", "fix": "do it yourself"},
         "calendar": {"state": "denied", "detail": ""}, "notifications": {"state": "not_asked"}},
        {"system_audio": {"state": "fallback", "detail": "works with a fallback"}, "calendar": {"state": "weird_state"},
         "notifications": {}, "microphone": {"detail": "no state"}},
    ]
    summaries = []
    for hw in (("Apple M2 Pro", 16, 50), ("Apple M4 Pro", 48, 200), ("Intel(R) Core(TM) i7", 16, 1.5),
               ("Apple M1", 8, 9.5), ("Apple M3", 24, 10)):
        for j in range(len(currents)):
            for p, perm in enumerate(perms):
                inst = installed_all[(j + p) % len(installed_all)]
                got = ob.summary(ob.Hardware(*hw), perm, ob.Installed(**inst), build_current(currents[j]))
                summaries.append({"hw": list(hw), "current": j, "permissions": p, "installed": inst,
                                  "checks": [[c.name, c.status, c.detail, c.fix] for c in got]})

    results = [
        {}, {"mic": {"recorded": True, "level_db": -28.0, "text": "Hello this is a test"},
             "system": {"recorded": True, "level_db": -80.0}},
        {"mic": {"recorded": True, "level_db": -75.0, "text": ""}, "system": {"recorded": False, "level_db": None}},
        {"mic": {"recorded": False, "level_db": None, "text": None}, "system": {"recorded": True, "level_db": -20.0}},
        {"mic": {"recorded": True, "level_db": -20.0, "text": None, "transcript": "not_downloaded"},
         "system": {"recorded": True, "level_db": -60.0}},
        {"mic": {"recorded": True, "level_db": -20.0, "text": None, "transcript": "cloud", "service": "Soniox"},
         "system": {"recorded": True}},
        {"mic": {"recorded": True, "level_db": -20.0, "text": "  ", "transcript": "cloud"},
         "system": {"recorded": True, "level_db": -59.9}},
        {"mic": {"recorded": True, "level_db": -50, "text": ""}, "system": {"recorded": True, "level_db": -61}},
        {"mic": {"recorded": True, "level_db": -49.9}, "system": {"recorded": 1, "level_db": 0}},
        {"mic": {"recorded": True, "level_db": 0, "text": "  words  "}, "system": {}},
        {"mic": {"recorded": True, "level_db": -90.0, "text": "Östliche Straße"}, "system": {"recorded": True,
                                                                                         "level_db": None}},
        {"mic": None, "system": None},
    ]
    verdicts = [[r, [[c.name, c.status, c.detail, c.fix] for c in ob.test_verdict(r)]] for r in results]

    at = datetime(2026, 10, 28, 10, 0)
    me = ("Timo Strauß", "timo@kloud.io", True)

    def event(title, *people):
        return Event(title, at, at, tuple(Attendee(n, e, is_self=s, is_room=len(p) > 3 and p[3])
                                          for p in people for n, e, s in [p[:3]]))

    event_sets = [
        [event("Contoso Northwind Weekly", me, ("Stefan Dornbusch", "stefan@contoso.at", False),
               ("Anna Huber", "anna@kloud.io", False)),
         event("Northwind Planning", me, ("Stefan Dornbusch", "stefan@contoso.at", False), ("Room 4", None, False)),
         event("Lunch", me, ("Max", "max@gmail.com", False))],
        [],
        [event("Sync", me)],
        [event("Kundentermin Fabrikam Quartalsplanung Schönbrunn", me, ("Valerie Kraus", "valerie@fabrikam.com", False),
                ("Besprechungsraum 3", "raum@kloud.io", False), ("Meetingroom 9", "r9@x.com", False),
                ("Dr. X", "drx@web.de", False), ("Straße Ö", "so@tailwind-traders.de", False),
                ("a@b.c", "abc@kloud.io", False), ("Anna Huber", "anna@kloud.io", False, True))],
        [event("Fabrikam Fabrikam FABRIKAM Äpfel Übermut Öko-Konzept", me, ("Valerie Kraus", "v@fabrikam.com", False)),
         event("Fabrikam Tailwind", me, ("Valerie Kraus", "v@fabrikam.com", False), ("Timo Strauß", "t2@gmx.de", False)),
         event("Tailwind weekly standup Kick-Off Retro", ("Timo Strauß", "timo@kloud.io", True),
               ("Per Son", "ps@tailwind.io", False))],
        [Event("", at, at, ()), Event("Wideworldimporters Contosos", at, at, (Attendee("Karel Kralek", "k@x.cz"),))],
        [event("Sync", ("Timo Strauß", None, True), ("Nina Weiß", "nina@kloud.io", False),
               ("Nina Weiß", "nina2@fabrikam.de", False), ("Per Son", "ps@a.b.c.example.org", False))],
        [event("Standup", ("Timo Strauß", "ts@gmail.com", True), ("Per Son", "ps@kloud.io", False),
               ("Per Son", "ps@KLOUD.io", False))],
    ]
    users = ["Timo Strauß", "timo strauß", "Nobody"]
    knowns = [[], ["anna huber"], ["Contoso", "STEFAN DORNBUSCH", "northwind"], ["Stefan Dornbusch", "Straße Ö"]]
    seeds = []
    for e, events in enumerate(event_sets):
        for u in users:
            for k in knowns:
                seeds.append([e, u, k, ob.seed_terms(events, user_name=u, known=k)])
    own = [[e, ob.own_organization(events)] for e, events in enumerate(event_sets)]
    event_specs = [[{"title": ev.title, "attendees": [[a.name, a.email, a.is_self, a.is_room] for a in ev.attendees]}
                    for ev in events] for events in event_sets]

    data = {"currents": currents, "installed": installed_all, "recommend": recommend, "tables": tables,
            "offers": offers, "missing": missing, "download_note": notes, "hardware": hardware, "permissions": perms,
            "summaries": summaries, "verdicts": verdicts, "events": event_specs, "seeds": seeds, "own": own}
    # The Swift tests of the setup assistant are in PalaverServerTests.
    copy = save_json(ROOT / "native" / "Tests" / "PalaverServerTests" / "Fixtures" / "setup-goldens.json", data)
    return {"see": copy.relative_to(ROOT).as_posix()}


SECTIONS: dict[str, Callable[[Path], dict]] = {
    "json": _json,
    "py": _py,
    "folder_names": _folder_names,
    "dictionary": _dictionary,
    "my_notes": _my_notes,
    "readable": _readable,
    "glossary_apply": _glossary_apply,
    "calendar": _calendar,
    "organizations": _organizations,
    "voices": _voices,
    "upgma": _upgma,
    "similarity": _similarity,
    "zipf": _zipf,
    "fuzz": _fuzz,
    "cologne": _cologne,
    "difflib": _difflib,
    "search_parse": _search_parse,
    "notes_read": _notes_read,
    "wav": _wav,
    "undo_fixture": _undo_fixture,
    "exchange_zip": _exchange_zip,
    "exchange_names": _exchange_names,
    "exchange_import": _exchange_import,
    "exchange_zip_audio": _exchange_zip_audio,
    "coach": _coach,
    "pipeline": _pipeline,
    "sentencepiece": _sentencepiece,
    "e5_tiny": _e5_tiny,
    "search_index": _search_index,
    "setup": _setup,
}


def write(section: str) -> Path:
    GOLDENS.mkdir(parents=True, exist_ok=True)
    data = SECTIONS[section](GOLDENS)
    return save_json(GOLDENS / f"{section}.json", data)


def main(argv: list[str]) -> int:
    unknown = [s for s in argv if s not in SECTIONS]
    if not argv or unknown:
        print(f"usage: goldens.py <section...>  (sections: {', '.join(SECTIONS)})", file=sys.stderr)
        if unknown:
            print(f"unknown: {', '.join(unknown)}", file=sys.stderr)
        return 2
    for section in argv:
        print(write(section).relative_to(ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
