"""Reading a search (#46): what the user typed, as filters and words.

"Anna and Tom last month" is two people who both took part and a date range;
"what did we decide about the test phase" looks in decisions for "test
phase"; "where did Mara talk about pricing" looks in the lines Mara said.
Known people, projects and organizations become filters when their name is
typed; a name in quotes stays a word. Filters can be written out too:
``person:`` ``project:`` ``org:`` ``since:`` ``until:`` ``in:`` ``by:``
``is:reviewed`` ``has:steps``.

Rules, not a language model: a search answers while it is typed, during a
call, with no model in memory. Every filter knows the part of the text it
came from, so the page shows it as a chip the user can take out again.
"""

from __future__ import annotations

import calendar
import re
from dataclasses import dataclass, field
from datetime import date, timedelta

_TOKEN = re.compile(
    r'(?P<key>[A-Za-z]+):(?:"(?P<keyq>[^"]*)"?|(?P<keyv>[^\s"]+))'
    r'|"(?P<quoted>[^"]*)"?'
    r"|(?P<word>\w+(?:[-.']\w+)*)"
)
_WORD = re.compile(r"\w+(?:[-.']\w+)*")

QUESTION = {
    "what", "where", "when", "who", "which", "how", "why", "did", "do", "does", "show", "find", "list",
    "was", "wo", "wann", "wer", "welche", "welcher", "welches", "wie", "warum", "zeig", "zeige", "finde", "gab",
}
DECIDE = {
    "decide", "decided", "decides", "deciding", "decision", "decisions", "beschlossen", "beschließen",
    "entschieden", "entscheiden", "entscheidung", "entscheidungen", "beschluss", "beschlüsse",
}
STEPS = {("next", "steps"), ("next", "step"), ("action", "items"), ("action", "item"), ("todo",), ("todos",),
         ("to-dos",), ("to-do",), ("aufgaben",), ("nächste", "schritte"), ("next", "actions")}
SAID = {
    "said", "say", "says", "saying", "talk", "talked", "talks", "talking", "speak", "spoke", "speaks",
    "mention", "mentioned", "mentions", "sagte", "sagt", "gesagt", "sprach", "gesprochen", "erwähnt",
    "erwähnte", "meinte", "gemeint", "redet", "geredet", "redete",
}
# Little words: dropped once something was understood, or in a question.
LITTLE = QUESTION | SAID | {
    "a", "an", "the", "and", "or", "with", "about", "of", "in", "on", "at", "for", "to", "from", "by", "done",
    "we", "i", "you", "he", "she", "they", "it", "is", "are", "were", "be", "been", "will", "would", "shall",
    "should", "can", "could", "may", "might", "that", "this", "these", "those", "there", "here", "me", "my",
    "our", "us", "your", "their", "his", "her", "its", "any", "all", "some", "had", "has", "have", "get", "got",
    "meeting", "meetings", "call", "calls", "people", "person", "someone", "somebody", "anyone", "team",
    "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "und", "oder", "mit",
    "über", "von", "vom", "zu", "zum", "zur", "im", "am", "an", "auf", "für", "bei", "wir", "ich", "du", "er",
    "sie", "es", "ihr", "hat", "haben", "hatte", "hatten", "wurde", "wurden", "wird", "ist", "sind", "war",
    "waren", "mal", "noch", "auch", "nur", "ob", "dass", "leute", "besprechung", "besprechungen", "termin",
    "termine", "jemand", "uns",
}
ANY = {"or", "oder"}
# A first or last name alone is a person from this many letters ("Tom" of
# Tom Kraus stays a word; a person called just "Tom" is one).
MIN_PART = 4

MONTHS = {name: n for n, names in enumerate([
    ("january", "januar", "jänner"), ("february", "februar", "feber"), ("march", "märz"), ("april",),
    ("may", "mai"), ("june", "juni"), ("july", "juli"), ("august",), ("september",), ("october", "oktober"),
    ("november",), ("december", "dezember")], start=1) for name in names}
NEEDS_YEAR = {"may", "march", "august"}  # words too: a month only with a year after them
THIS = {"this", "diese", "dieser", "diesen", "dieses"}
LAST = {"last", "previous", "letzte", "letzten", "letzter", "letztes", "vorige", "vorigen", "voriger"}
UNITS = {"week": "week", "woche": "week", "month": "month", "monat": "month", "year": "year", "jahr": "year"}
SINCE, AFTER, BEFORE, UNTIL = {"since", "seit", "ab"}, {"after", "nach"}, {"before"}, {"until", "till", "bis"}

SCOPES = {"decisions": "decisions", "decision": "decisions", "steps": "steps", "step": "steps",
          "next-steps": "steps", "todos": "steps", "notes": "notes", "title": "title", "titles": "title",
          "transcript": "transcript", "lines": "transcript"}
SCOPE_LABELS = {"decisions": ("In decisions", "Only decisions in the notes"),
                "steps": ("In next steps", "Only next steps in the notes"),
                "notes": ("In notes", "Only the notes"), "title": ("In titles", "Only titles"),
                "transcript": ("In transcripts", "Only the transcript")}
KEYS = {"person": "person", "with": "person", "org": "org", "organization": "org", "company": "org",
        "project": "project", "proj": "project", "since": "since", "after": "after", "from": "since",
        "until": "until", "before": "before", "date": "date", "on": "date", "in": "in", "by": "said",
        "said": "said", "is": "is", "has": "has"}


@dataclass
class Vocabulary:
    """What a typed name can be: people (named speakers, invitees, the
    voice bank), projects (id → name) and organizations."""
    people: list[str] = field(default_factory=list)
    projects: dict[str, str] = field(default_factory=dict)
    orgs: list[str] = field(default_factory=list)


@dataclass
class Filter:
    kind: str  # person, org, project, since, until, in, said, is, has
    value: str | None
    label: str
    span: tuple[int, int]
    written: bool = False  # person:… rather than a name in the text


@dataclass
class Query:
    text: str
    words: list[str]
    filters: list[Filter]
    any_person: bool = False

    def _values(self, kind: str) -> list:
        return [f.value for f in self.filters if f.kind == kind]

    @property
    def people(self) -> list[str]:
        return self._values("person")

    @property
    def orgs(self) -> list[str]:
        return self._values("org")

    @property
    def projects(self) -> list[str | None]:
        return self._values("project")

    @property
    def since(self) -> date | None:
        return max(map(date.fromisoformat, self._values("since")), default=None)

    @property
    def until(self) -> date | None:
        return min(map(date.fromisoformat, self._values("until")), default=None)

    @property
    def scope(self) -> str | None:
        return next(iter(self._values("in")), None)

    @property
    def said_by(self) -> str | None:
        return next(iter(self._values("said")), None)

    @property
    def reviewed(self) -> bool | None:
        values = self._values("is")
        return values[-1] == "reviewed" if values else None

    @property
    def has_steps(self) -> bool:
        return "steps" in self._values("has")

    @property
    def empty(self) -> bool:
        return not self.words and not self.filters

    def chips(self) -> list[dict]:
        """The filters as the page shows them, a date range as one chip."""
        out: list[dict] = []
        for f in self.filters:
            if f.kind in ("since", "until"):
                if out and out[-1]["kind"] == "date" and out[-1]["span"] == list(f.span):
                    continue
                out.append({"kind": "date", "label": f.label, "title": self._range(f.span), "span": list(f.span),
                            "text": self.text[f.span[0]:f.span[1]], "written": f.written})
                continue
            out.append({"kind": f.kind, "label": f.label, "title": self._title(f), "span": list(f.span),
                        "text": self.text[f.span[0]:f.span[1]], "written": f.written})
        return out

    def _range(self, span: tuple[int, int]) -> str:
        since = next((f.value for f in self.filters if f.kind == "since" and f.span == span), None)
        until = next((f.value for f in self.filters if f.kind == "until" and f.span == span), None)
        if since and until:
            return f"{since} to {until}"
        return f"From {since}" if since else f"Until {until}"

    def _title(self, f: Filter) -> str:
        if f.kind == "person":
            return ("Took part, any of them: named speaker or invited" if self.any_person
                    else "Took part: named speaker or invited")
        if f.kind == "said":
            return f"Only lines {f.value} said"
        if f.kind == "project":
            return "Project" if f.value else "No project has this name"
        if f.kind == "org":
            return f"Someone from {f.value} took part"
        if f.kind == "in":
            return SCOPE_LABELS[f.value][1]
        if f.kind == "is":
            return "Marked as reviewed" if f.value == "reviewed" else "Not marked as reviewed yet"
        return "The notes have next steps"


@dataclass
class _Token:
    text: str
    start: int
    end: int
    quoted: bool = False

    @property
    def key(self) -> str:
        return self.text.casefold()


def _words(text: str) -> tuple[str, ...]:
    return tuple(w.casefold() for w in _WORD.findall(text))


def _month_range(year: int, month: int) -> tuple[date, date]:
    return date(year, month, 1), date(year, month, calendar.monthrange(year, month)[1])


def _date_at(tokens: list[_Token], i: int, today: date) -> tuple[int, date, date] | None:
    """A date phrase starting at ``tokens[i]``: how many tokens, first and last day."""
    word = tokens[i].key
    nxt = tokens[i + 1].key if i + 1 < len(tokens) and not tokens[i + 1].quoted else None
    if word in ("today", "heute"):
        return 1, today, today
    if word in ("yesterday", "gestern"):
        return 1, today - timedelta(days=1), today - timedelta(days=1)
    if (word in THIS or word in LAST) and nxt in UNITS:
        unit, back = UNITS[nxt], word in LAST
        if unit == "week":
            monday = today - timedelta(days=today.weekday())
            return (2, monday - timedelta(days=7), monday - timedelta(days=1)) if back else (2, monday, today)
        if unit == "month":
            if not back:
                return 2, today.replace(day=1), today
            last = today.replace(day=1) - timedelta(days=1)
            return (2, *_month_range(last.year, last.month))
        return (2, date(today.year - 1, 1, 1), date(today.year - 1, 12, 31)) if back else (2, date(today.year, 1, 1), today)
    if word in MONTHS:
        month = MONTHS[word]
        if nxt and re.fullmatch(r"(19|20)\d\d", nxt):
            return (2, *_month_range(int(nxt), month))
        if word in NEEDS_YEAR:
            return None
        year = today.year if month <= today.month else today.year - 1
        return (1, *_month_range(year, month))
    m = re.fullmatch(r"(\d{4})-(\d\d)(?:-(\d\d))?", word)
    if m:
        try:
            if m.group(3):
                day = date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
                return 1, day, day
            return (1, *_month_range(int(m.group(1)), int(m.group(2))))
        except ValueError:
            return None
    return None


class _Names:
    """Phrases (as casefolded word tuples) → (kind, value), longest first."""

    def __init__(self, vocab: Vocabulary):
        self.phrases: dict[tuple[str, ...], tuple[str, str]] = {}
        parts: dict[str, set[str]] = {}
        for name in vocab.people:
            words = _words(name)
            if len(words) == 1 and words[0] in LITTLE:
                continue
            self.phrases[words] = ("person", name)
            for w in words if len(words) > 1 else ():
                if len(w) >= MIN_PART and w not in LITTLE:
                    parts.setdefault(w, set()).add(name)
        for w, names in parts.items():
            if (w,) in self.phrases:
                continue
            if len(names) == 1:
                self.phrases[(w,)] = ("person", next(iter(names)))
            else:  # "Anna" for every Anna
                first = next(n for n in sorted(names) if w in _words(n))
                self.phrases[(w,)] = ("person", _WORD.findall(first)[_words(first).index(w)])
        # A project's or an organization's name wins over a person's.
        for kind, value, name in [*(("org", o, o) for o in vocab.orgs),
                                  *(("project", pid, n) for pid, n in vocab.projects.items())]:
            words = _words(name)
            if words and not (len(words) == 1 and words[0] in LITTLE):
                self.phrases[words] = (kind, value)
        self.longest = max((len(p) for p in self.phrases), default=0)

    def at(self, tokens: list[_Token], i: int) -> tuple[int, str, str] | None:
        for n in range(min(self.longest, len(tokens) - i), 0, -1):
            run = tokens[i:i + n]
            if any(t.quoted for t in run):
                continue
            hit = self.phrases.get(tuple(t.key for t in run))
            if hit:
                return n, *hit
        return None

    def person(self, typed: str) -> str:
        hit = self.phrases.get(_words(typed))
        return hit[1] if hit and hit[0] == "person" else typed.strip()


def _tokens(text: str) -> tuple[list[_Token], list[tuple[str, str, int, int]]]:
    """Words and quoted phrases; and written-out ``key:value`` filters."""
    tokens, keyed = [], []
    for m in _TOKEN.finditer(text):
        if m.group("key") is not None:
            key = KEYS.get(m.group("key").casefold())
            value = m.group("keyq") if m.group("keyq") is not None else m.group("keyv")
            if key:
                keyed.append((key, value, m.start(), m.end()))
                continue
            for w in _WORD.finditer(m.group(0)):
                tokens.append(_Token(w.group(0), m.start() + w.start(), m.start() + w.end()))
        elif m.group("quoted") is not None:
            if m.group("quoted").strip():
                tokens.append(_Token(m.group("quoted").strip(), m.start(), m.end(), quoted=True))
        else:
            tokens.append(_Token(m.group("word"), m.start(), m.end()))
    return tokens, keyed


def _label(text: str) -> str:
    return text[:1].upper() + text[1:]


def _written(key: str, value: str, span: tuple[int, int], vocab: Vocabulary, names: _Names,
             today: date) -> list[Filter]:
    value = value.strip()
    if key in ("person", "said"):
        person = names.person(value)
        return [Filter("person", person, person, span)] + ([Filter("said", person, f"Said by {person}", span)]
                                                           if key == "said" else [])
    if key == "project":
        pid = next((p for p, n in vocab.projects.items() if n.casefold() == value.casefold()), None)
        return [Filter("project", pid, vocab.projects.get(pid, value), span)]
    if key == "org":
        org = next((o for o in vocab.orgs if o.casefold() == value.casefold()), value)
        return [Filter("org", org, org, span)]
    if key == "in":
        scope = SCOPES.get(value.casefold())
        return [Filter("in", scope, SCOPE_LABELS[scope][0], span)] if scope else []
    if key == "is":
        v = value.casefold()
        if v in ("reviewed", "unreviewed", "not-reviewed"):
            done = v == "reviewed"
            return [Filter("is", "reviewed" if done else "unreviewed", "Reviewed" if done else "Not reviewed", span)]
        return []
    if key == "has":
        return [Filter("has", "steps", "Has next steps", span)] if value.casefold() in ("steps", "next-steps") else []
    found = _date_at([_Token(w, 0, 0) for w in _WORD.findall(value)], 0, today) if _WORD.findall(value) else None
    if not found:
        return []
    _, first, last = found
    label = f"{_label(key)} {value}" if key != "date" else value
    return _ranged(key, first, last, label, span)


def _ranged(how: str, first: date, last: date, label: str, span: tuple[int, int]) -> list[Filter]:
    if how == "since":
        return [Filter("since", first.isoformat(), label, span)]
    if how == "after":
        return [Filter("since", (last + timedelta(days=1)).isoformat(), label, span)]
    if how == "before":
        return [Filter("until", (first - timedelta(days=1)).isoformat(), label, span)]
    if how == "until":
        return [Filter("until", last.isoformat(), label, span)]
    return [Filter("since", first.isoformat(), label, span), Filter("until", last.isoformat(), label, span)]


def parse(text: str, vocab: Vocabulary, *, today: date | None = None) -> Query:
    today = today or date.today()
    names = _Names(vocab)
    tokens, keyed = _tokens(text)
    filters: list[Filter] = []
    for key, value, start, end in keyed:
        for f in _written(key, value, (start, end), vocab, names, today):
            f.written = True
            filters.append(f)

    used = [False] * len(tokens)
    persons: list[tuple[int, Filter]] = []
    one_word_projects: list[tuple[Filter, int]] = []
    said_at: list[int] = []
    any_person = False
    i = 0
    while i < len(tokens):
        t = tokens[i]
        if t.quoted:
            i += 1
            continue
        how = ("since" if t.key in SINCE else "after" if t.key in AFTER else "before" if t.key in BEFORE
               else "until" if t.key in UNTIL else None)
        found = _date_at(tokens, i + 1, today) if how and i + 1 < len(tokens) and not tokens[i + 1].quoted else None
        if found:
            n, first, last = found
            span = (t.start, tokens[i + n].end)
            filters += _ranged(how, first, last, _label(text[span[0]:span[1]]), span)
            used[i:i + n + 1] = [True] * (n + 1)
            i += n + 1
            continue
        found = _date_at(tokens, i, today)
        if found:
            n, first, last = found
            span = (t.start, tokens[i + n - 1].end)
            filters += _ranged("range", first, last, _label(text[span[0]:span[1]]), span)
            used[i:i + n] = [True] * n
            i += n
            continue
        step = next((len(p) for p in sorted(STEPS, key=len, reverse=True)
                     if tuple(x.key for x in tokens[i:i + len(p)] if not x.quoted) == p), 0)
        if step or t.key in DECIDE:
            n = step or 1
            scope = "steps" if step else "decisions"
            if not any(f.kind == "in" for f in filters):
                filters.append(Filter("in", scope, SCOPE_LABELS[scope][0], (t.start, tokens[i + n - 1].end)))
            used[i:i + n] = [True] * n
            i += n
            continue
        hit = names.at(tokens, i)
        if hit:
            n, kind, value = hit
            span = (t.start, tokens[i + n - 1].end)
            label = vocab.projects.get(value, value) if kind == "project" else value
            f = Filter(kind, value, label, span)
            filters.append(f)
            if kind == "project" and n == 1:
                one_word_projects.append((f, i))
            if kind == "person":
                if persons and any(x.key in ANY for x in tokens[persons[-1][0] + 1:i]):
                    any_person = True
                persons.append((i, f))
            used[i:i + n] = [True] * n
            i += n
            continue
        if t.key in SAID:
            said_at.append(i)
        i += 1

    if said_at and persons and not any(f.kind == "said" for f in filters):
        at = said_at[0]
        before = [p for p in persons if p[0] < at]
        who = (before[-1] if before else persons[0])[1]
        t = tokens[at]
        filters.append(Filter("said", who.value, f"Said by {who.value}", (t.start, t.end)))

    def words_left() -> list[str]:
        understood = bool(filters) or (tokens and not tokens[0].quoted and tokens[0].key in QUESTION)
        return [t.text for t, u in zip(tokens, used) if not u and (t.quoted or not (understood and t.key in LITTLE))]

    words = words_left()
    if words and one_word_projects:
        # "search ranking" is no search in the project "Search": a one-word
        # project name is a filter only when nothing else is searched for.
        for f, at in one_word_projects:
            filters.remove(f)
            used[at] = False
        words = words_left()
    filters.sort(key=lambda f: f.span[0])
    return Query(text=text, words=words, filters=filters, any_person=any_person)
