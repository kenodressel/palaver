"""Regenerate native/Sources/PalaverDomain/Resources/zipf.bin: wordfreq's German and English word
lists and the character classes its tokenizer needs, for the glossary's "rare word" test
(`PalaverDomain/Glossary/Zipf.swift`).

    uv run --extra dev python tools/make_zipf_table.py

The file is raw DEFLATE (zlib wbits=-15, what Compression's COMPRESSION_ZLIB inflates) of UTF-8 text:

    #lang <code>             wordfreq.get_frequency_list(code, wordlist="large"), one line per bucket:
    <centibels>\\t<word>\\t... the bucket's index (the frequency is 10 ** (-index / 100)), its words
    #set <name>              one line of hex code point ranges, "lo-hi,lo-hi,lone,...", of the characters
                             the `regex` module (as wordfreq's tokenizer uses it) puts in that class

Reproducible: the word lists come from the wordfreq version pinned in uv.lock (3.1.1), the classes from
the pinned `regex`. Surrogates are left out (Swift has no scalar for them).
"""

from __future__ import annotations

import sys
import unicodedata
import zlib
from pathlib import Path

import regex
import wordfreq
from wordfreq.tokens import SPACELESS_EXPR

OUT = Path(__file__).resolve().parents[1] / "native" / "Sources" / "PalaverDomain" / "Resources" / "zipf.bin"
LANGS = ("de", "en")

WB = [
    "CR", "LF", "Newline", "Extend", "ZWJ", "Regional_Indicator", "Format", "Katakana", "Hebrew_Letter",
    "ALetter", "Single_Quote", "Double_Quote", "MidNumLet", "MidLetter", "MidNum", "Numeric", "ExtendNumLet",
    "WSegSpace",
]
GCB = ["Control", "CR", "LF", "Extend", "ZWJ", "Regional_Indicator", "Prepend", "SpacingMark", "L", "V", "T", "LV", "LVT"]
SETS: dict[str, str] = {
    "w": r"\w",
    "d": r"\d",
    "so": r"\p{So}",
    "spaceless": "[" + SPACELESS_EXPR + "]",
    "extpict": r"\p{Extended_Pictographic}",
    **{f"wb:{n}": rf"\p{{WB={n}}}" for n in WB},
    **{f"gcb:{n}": rf"\p{{GCB={n}}}" for n in GCB},
}

ALL = "".join(chr(c) for c in range(0x110000) if not 0xD800 <= c <= 0xDFFF)


def ranges(pattern: str) -> str:
    rx = regex.compile(f"(?:{pattern})+", regex.V1)
    out = []
    for m in rx.finditer(ALL):
        # ALL skips the surrogate block, so map string offsets back to code points.
        lo, hi = _cp(m.start()), _cp(m.end() - 1)
        out.append(f"{lo:x}" if lo == hi else f"{lo:x}-{hi:x}")
    return ",".join(out)


def _cp(i: int) -> int:
    return i if i < 0xD800 else i + 0x800


def build() -> bytes:
    parts: list[str] = []
    for lang in LANGS:
        parts.append(f"#lang {lang}")
        for index, bucket in enumerate(wordfreq.get_frequency_list(lang, wordlist="large")):
            if not bucket:
                continue
            for word in bucket:
                assert "\t" not in word and "\n" not in word, repr(word)
            parts.append("\t".join([str(index), *bucket]))
    for name, pattern in SETS.items():
        parts.append(f"#set {name}")
        parts.append(ranges(pattern))
    # The digits: Swift reads a digit's value as its place in a run of ten, so check the runs are whole tens.
    for lo_hi in ranges(r"\d").split(","):
        lo, _, hi = lo_hi.partition("-")
        lo_n, hi_n = int(lo, 16), int(hi or lo, 16)
        assert (hi_n - lo_n + 1) % 10 == 0, lo_hi
        for c in range(lo_n, hi_n + 1):
            try:
                assert unicodedata.decimal(chr(c)) == (c - lo_n) % 10, hex(c)
            except ValueError:
                pass  # newer than unicodedata knows
    text = "\n".join(parts) + "\n"
    z = zlib.compressobj(9, zlib.DEFLATED, -15)
    return z.compress(text.encode("utf-8")) + z.flush()


def main() -> int:
    data = build()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(data)
    print(f"{OUT.relative_to(Path(__file__).resolve().parents[1])}: {len(data)} bytes (wordfreq {wordfreq.__version__ if hasattr(wordfreq, '__version__') else '3.1.1'}, regex {regex.__version__})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
