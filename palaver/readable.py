"""Clean verbatim: the transcript as it is read, without filler words and stutters.

``transcript.json`` stays word for word; the Markdown file and the Notion page
show this version.
"""

from __future__ import annotations

import re
from dataclasses import replace

from .models import Utterance

# Hesitations in German and English. Not "eh": in Austrian German it means
# "anyway". Not "er": German for "he".
_FILLER = re.compile(r"(?:m{2,}|u+h+|u+h*m+|e+r+m+|ä+h*m*|ö+h*m*|h+m+|m*h+m+|m+-?h+m+|uh-huh)", re.I)

# Doubled on purpose, not stutters ("Ja, ja", "ciao ciao", "sehr sehr gut").
_KEEP_REPEATED = {
    "ja", "jaja", "nein", "nee", "no", "yes", "yeah", "okay", "ok", "genau", "passt",
    "gut", "sehr", "very", "ciao", "bye", "tschüss", "hallo", "hello", "hi", "danke",
    "thanks", "bla", "absolut",
}

# German "um" is a word ("um zu", "damit um"); only English "um" is a filler,
# and German "Um," opening a sentence.
# German "die, die" ("those who") and "echt, echt" are no stutters either.
# Which language a turn is in: whichever has more of these common words.
_GERMAN = {
    "der", "die", "das", "und", "ist", "ich", "wir", "nicht", "ein", "eine", "zu", "mit",
    "auf", "für", "dass", "es", "sie", "aber", "auch", "dann", "noch", "jetzt", "haben",
    "wird", "man", "halt", "schon", "genau", "ja", "oder", "wenn", "damit", "da", "einem",
}
_ENGLISH = {
    "the", "and", "is", "i", "we", "not", "a", "to", "with", "on", "for", "that", "it",
    "you", "but", "of", "this", "so", "they", "have", "be", "what", "like", "yeah",
}

_SENTENCE_END = ".?!"


# The transcriber glues numbers to the word before ("für150", "Ende2030"):
# a word of two or more letters, ending in lower case, then two or more
# digits. Leaves "H100", "MP3", "GPT4", "COVID19" alone.
_GLUED_NUMBER = re.compile(r"\b([^\W\d_]*[a-zäöüß]{2})(\d{2,})")


def _core(token: str) -> str:
    return re.sub(r"^\W+|\W+$", "", token).lower()


def _trailing(token: str) -> str:
    return token[len(token.rstrip(",.?!;:")):]


def _capitalize(token: str) -> str:
    return token[:1].upper() + token[1:]


def _collapse_phrases(tokens: list[str], longest: int = 4) -> list[str]:
    """ "we made we made it" → "we made it": a phrase said twice in a row
    keeps its first copy, with the punctuation the second one ended on."""
    cores = [_core(t) for t in tokens]
    i = 0
    while i < len(tokens):
        for n in range(min(longest, (len(tokens) - i) // 2), 1, -1):
            phrase = cores[i : i + n]
            if (
                all(phrase)
                and phrase == cores[i + n : i + 2 * n]
                and not set(phrase) <= _KEEP_REPEATED  # "Ja, ja, ja, ja."
            ):
                last = tokens[i + n - 1]
                tokens[i + n - 1] = last[: len(last) - len(_trailing(last))] + _trailing(tokens[i + 2 * n - 1])
                del tokens[i + n : i + 2 * n], cores[i + n : i + 2 * n]
                break
        else:
            i += 1
    return tokens


def clean_text(text: str) -> str:
    """Drop filler words and collapse stutters ("the the the" → "the",
    "we made we made" → "we made"), and put a space before numbers glued
    to a word ("für150" → "für 150")."""
    text = _GLUED_NUMBER.sub(r"\1 \2", text)
    cores = [_core(t) for t in text.split()]
    german = sum(c in _GERMAN for c in cores) > sum(c in _ENGLISH for c in cores)
    tokens: list[str] = []
    shifted = False  # a removal moved the next token to where a sentence starts
    for token in text.split():
        core = _core(token)
        opens_sentence = not tokens or tokens[-1][-1] in _SENTENCE_END
        german_word = german and core == "um" and not (opens_sentence and token.endswith(","))
        if core and _FILLER.fullmatch(core) and not german_word:
            end = _trailing(token)
            if tokens and end:
                # Commas around a filler are the filler's; its full stop is the sentence's.
                stop = "".join(c for c in end if c in _SENTENCE_END)
                if last := tokens[-1].rstrip(",") + stop:
                    tokens[-1] = last
                else:
                    tokens.pop()  # a lone comma before it (", äh, …")
            shifted = not tokens or tokens[-1][-1] in _SENTENCE_END  # the filler's "." moved over
            continue
        if (
            tokens
            and core
            and core == _core(tokens[-1])
            and core not in _KEEP_REPEATED
            and not (german and tokens[-1].endswith(","))
        ):
            tokens[-1] = tokens[-1][: len(tokens[-1]) - len(_trailing(tokens[-1]))] + _trailing(token)
            continue
        tokens.append(_capitalize(token) if shifted else token)
        shifted = False
    return " ".join(_collapse_phrases(tokens))


def readable(utterances: list[Utterance], glossary=None) -> list[Utterance]:
    """Cleaned copies with names spelled as the glossary says (the user's,
    unless ``glossary`` is given); turns that were nothing but filler
    ("Mm-hmm.") are dropped."""
    from .glossary import current

    glossary = glossary if glossary is not None else current()
    out = []
    for u in utterances:
        # Words the user wrote stay as written: no filler removal.
        text, glossed = glossary.apply_marked(u.text if u.heard is not None else clean_text(u.text))
        if _core(text):
            out.append(replace(u, text=text, glossed=tuple(glossed)))
    return out
