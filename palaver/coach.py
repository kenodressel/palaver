"""Speaker coach (issue #41): how I talk in meetings.

Everything on the microphone is the user's, so their lines need no
diarization; the transcript keeps fillers verbatim, and the others'
lines carry their speaker. From that, per meeting:

- talk share, against a fair share (1 / people who spoke);
- monologues: stretches of mine without anyone else speaking;
- pace: words per minute of my speaking time, and the fastest stretch;
- filler words: verbal tics ("halt", "irgendwie", "quasi", …) per minute.
  Hesitations ("äh") are counted too, but the transcriber leaves most of
  them out, so they are shown as a lower bound;
- questions I asked (open or closed) and how long I let it be quiet after;
- interruptions: I start while someone is still talking, and the reverse;
- invitees who barely spoke.

Where several people shared one microphone (#56), the others' voices
aren't people: talk share, monologues and quiet invitees are left out, and
what is about the user's own track stays. When several people sat at the
user's microphone (in person), that track is not the user's alone either:
pace and filler words go too.

``baseline`` averages these over all meetings, separately for 1:1s and
groups, so a meeting is compared with what is usual for me.
"""

from __future__ import annotations

import json
import re
import threading
from pathlib import Path
from statistics import mean, median
from typing import Any

from .models import Utterance
from .paths import RecordingPaths, is_recording_folder_name

# My speech with gaps up to this long, and no one else speaking, is one stretch.
STRETCH_GAP = 3.0
MONOLOGUE_SECONDS = 90.0
# Others' speech shorter than this ("Mhm", "Ja") does not end a stretch or
# count as an interruption: it is a backchannel.
BACKCHANNEL_SECONDS = 1.5
INTERRUPT_OVERLAP = 1.0  # talking over someone for at least this long
INTERRUPT_MIN_SECONDS = 2.5  # ... with more than a quick word
CUT_OFF_SECONDS = 3.0  # ... and the one talking stops within this
PACE_WINDOW = 120.0
QUIET_INVITEE_SECONDS = 30.0

HESITATIONS = {"äh", "ähm", "öhm", "ehm", "uh", "uhm", "umm", "erm"}
TICS = ("irgendwie", "halt", "quasi", "sozusagen", "eigentlich", "genau", "basically", "actually",
        "you know", "kind of", "sort of")
_OPEN = re.compile(r"^(wer|wen|wem|was|wie|wieso|warum|weshalb|wo|wohin|woher|wann|welche[rsmn]?|wofür|womit|"
                   r"worauf|worüber|how|what|why|where|when|which|who|whom)\b", re.IGNORECASE)
_GERMAN = ("und", "ich", "das", "ist", "nicht", "wir", "aber", "auch")
_ENGLISH = ("and", "the", "is", "not", "we", "but", "also", "that")
_WORDS = re.compile(r"[^\W\d_]+(?:['’-][^\W\d_]+)*")


def _lanes(paths: RecordingPaths, user_name: str) -> tuple[list[Utterance], list[Utterance]]:
    """(my lines, the others' lines) — removed voices left out, merged
    labels as the label they joined."""
    from .speakers import load_merges, without_ignored

    from .settings import me

    raw = [Utterance.from_dict(d) for d in json.loads(paths.transcript_json.read_text())]
    raw = without_ignored(paths, raw)
    merges = load_merges(paths)
    names = me(user_name)  # an earlier name of the user still means the user (#55)
    mine, theirs = [], []
    for u in raw:
        if u.speaker.casefold() in names and not u.label:
            mine.append(u)
        else:
            label = u.label or u.speaker
            theirs.append(Utterance(merges.get(label, label), u.start, u.end, u.text, label=merges.get(label, label)))
    return mine, theirs


def _seconds(lines: list[Utterance]) -> float:
    return sum(max(0.0, u.end - u.start) for u in lines)


def _stretches(mine: list[Utterance], theirs: list[Utterance]) -> list[dict[str, float]]:
    """My speech joined across short gaps, broken by someone else speaking."""
    interjections = sorted((u.start, u.end) for u in theirs if u.end - u.start >= BACKCHANNEL_SECONDS)
    out: list[dict[str, float]] = []
    for u in sorted(mine, key=lambda u: u.start):
        if out and u.start - out[-1]["end"] <= STRETCH_GAP and not any(
                out[-1]["end"] - 0.2 < s < u.start for s, _ in interjections):
            out[-1]["end"] = max(out[-1]["end"], u.end)
            out[-1]["words"] += len(_WORDS.findall(u.text))
        else:
            out.append({"start": u.start, "end": u.end, "words": len(_WORDS.findall(u.text))})
    return out


def _count(text: str, phrase: str) -> int:
    return len(re.findall(rf"(?<![\w-]){re.escape(phrase)}(?![\w-])", text, re.IGNORECASE))


def analyze(paths: RecordingPaths, *, user_name: str, invited: list[str] | None = None,
            names: dict[str, str] | None = None) -> dict[str, Any]:
    """The coach's numbers for one meeting. ``invited``: invitees as
    named in the meeting; ``names``: label → name of the others."""
    from .shared_mic import mic_room, shared_labels

    mine, theirs = _lanes(paths, user_name)
    names = names or {}
    at_mic = mic_room(paths) is not None and bool(mine)  # my track is several people's
    shared = bool(shared_labels(paths) & {u.speaker for u in theirs}) or at_mic
    me = _seconds(mine)
    by_speaker: dict[str, float] = {}
    for u in theirs:
        by_speaker[u.speaker] = by_speaker.get(u.speaker, 0.0) + max(0.0, u.end - u.start)
    others = sum(by_speaker.values())
    people = 1 + sum(1 for t in by_speaker.values() if t >= 10)
    minutes = me / 60

    stretches = _stretches(mine, theirs)
    monologues = sorted(({"start": round(s["start"], 1), "seconds": round(s["end"] - s["start"])}
                         for s in stretches if s["end"] - s["start"] >= MONOLOGUE_SECONDS),
                        key=lambda m: -m["seconds"])

    words = sum(len(_WORDS.findall(u.text)) for u in mine)
    fastest = None
    for s in stretches:
        span = s["end"] - s["start"]
        if span >= 30:
            wpm = s["words"] / span * 60
            if fastest is None or wpm > fastest["wpm"]:
                fastest = {"start": round(s["start"], 1), "wpm": round(wpm)}

    text = " ".join(u.text for u in mine)
    tics = sorted(((t, _count(text, t)) for t in TICS), key=lambda x: -x[1])
    hesitations = sum(1 for w in _WORDS.findall(text.casefold()) if w in HESITATIONS)

    questions = []
    everyone = sorted(mine + theirs, key=lambda u: u.start)
    my_lines = {id(u) for u in mine}
    for i, u in enumerate(everyone):
        if id(u) in my_lines and u.text.rstrip().endswith("?"):
            nxt = next((v for v in everyone[i + 1:] if v.start >= u.end - 0.1), None)
            mine_next = nxt is not None and id(nxt) in my_lines
            questions.append({"start": round(u.start, 1), "text": u.text.strip(),
                              "open": bool(_OPEN.match(u.text.strip().lstrip("„\"'"))),
                              # I went on talking myself, or how long I left it quiet for an answer.
                              "kept_talking": mine_next,
                              "wait": round(max(0.0, nxt.start - u.end), 1) if nxt and not mine_next else None})

    # An interruption: one starts while the other talks, and the other stops
    # soon after while the first goes on. Overlap alone is mostly
    # backchannels and timing noise.
    def cut_off(a: list[Utterance], b: list[Utterance]) -> list[dict[str, Any]]:
        from rapidfuzz import fuzz

        found = []
        for u in a:
            if u.end - u.start < INTERRUPT_MIN_SECONDS:
                continue
            for v in b:
                if (v.end - v.start >= BACKCHANNEL_SECONDS and v.start < u.start < v.end - INTERRUPT_OVERLAP
                        and v.end - u.start <= CUT_OFF_SECONDS and u.end > v.end + 1.0
                        and fuzz.partial_ratio(u.text.casefold(), v.text.casefold()) < 70):  # not an echo
                    found.append({"start": round(u.start, 1), "who": names.get(v.speaker, v.speaker)})
                    break
        return found

    by_me, of_me = cut_off(mine, theirs), cut_off(theirs, mine)

    spoke = {names.get(label, label).casefold(): t for label, t in by_speaker.items()}
    quiet = [{"name": n, "seconds": round(spoke.get(n.casefold(), 0.0))}
             for n in invited or [] if spoke.get(n.casefold(), 0.0) < QUIET_INVITEE_SECONDS]
    if shared:  # one voice is several people: who talked how much, and who didn't, is unknown
        monologues, quiet = [], []
    if at_mic:  # not my pace, not my filler words
        fastest, tics, hesitations = None, [], None

    return {
        "talk": {"me": round(me), "others": round(others),
                 "share": round(me / (me + others), 3) if me + others and not shared else None,
                 "fair": None if shared else round(1 / people, 3), "people": people, "shared": shared,
                 "at_mic": at_mic},
        "monologues": monologues,
        "pace": {"wpm": round(words / minutes) if minutes >= 1 and not at_mic else None, "fastest": fastest},
        "fillers": {"per_minute": round(sum(n for _, n in tics) / minutes, 2) if minutes >= 1 and not at_mic else None,
                    "top": [{"word": t, "count": n} for t, n in tics if n][:5],
                    "hesitations": hesitations},
        "questions": {"count": len(questions), "open": sum(q["open"] for q in questions),
                      "per_hour": round(len(questions) / ((me + others) / 3600), 1) if me + others >= 600 else None,
                      "wait": round(median([q["wait"] for q in questions if q["wait"] is not None]), 1)
                      if any(q["wait"] is not None for q in questions) else None,
                      "kept_talking": sum(q["kept_talking"] for q in questions),
                      "list": questions},
        "interruptions": {"by_me": len(by_me), "of_me": len(of_me), "by_me_at": by_me[:5],
                          "of_me_at": [{**x, "who": x["who"]} for x in of_me[:5]]},
        "language": "de" if sum(_count(text, w) for w in _GERMAN) >= sum(_count(text, w) for w in _ENGLISH) else "en",
        "quiet_invitees": quiet,
        "minutes_talked": round(minutes, 1),
    }


BASELINE_MEETINGS = 30  # what is usual: the last this many meetings, so it follows how the user talks now
TREND_WEEKS = 12


def _avg(values, digits: int = 3):
    values = [v for v in values if v is not None]
    return round(mean(values), digits) if values else None


def baseline(results: list[dict[str, Any]]) -> dict[str, Any]:
    """What is usual across the last BASELINE_MEETINGS meetings (``results``
    oldest first): 1:1s and groups apart for talk share."""
    results = results[-BASELINE_MEETINGS:]
    avg = _avg

    one = [r for r in results if r["talk"]["people"] == 2]
    group = [r for r in results if r["talk"]["people"] > 2]
    long = [r for r in results if r["minutes_talked"] >= 3]
    return {
        "meetings": len(results),
        "share_1on1": avg(r["talk"]["share"] for r in one),
        "share_group": avg(r["talk"]["share"] for r in group),
        "wpm": avg(r["pace"]["wpm"] for r in long),
        # Filler words depend on the language: compare German with German.
        "fillers_per_minute": {lang: avg(r["fillers"]["per_minute"] for r in long if r["language"] == lang)
                               for lang in ("de", "en")},
        "questions_per_hour": avg(r["questions"]["per_hour"] for r in long),
    }


def trends(rows: list[dict[str, Any]], weeks: int = TREND_WEEKS) -> dict[str, Any]:
    """Talk share, pace and filler words per week (the last ``weeks`` with
    meetings) and per kind of meeting, from ``history`` rows. Pace and
    fillers only from meetings where the user talked 3 minutes or more."""
    from datetime import date, datetime, timedelta

    def week_of(start: str) -> str:
        try:
            day = datetime.fromisoformat(start).date()
        except ValueError:
            day = date.fromisoformat(start[:10])
        return (day - timedelta(days=day.weekday())).isoformat()

    def numbers(group: list[dict[str, Any]]) -> dict[str, Any]:
        long = [r for r in group if r.get("minutes_talked", 0) >= 3]
        wpm = _avg((r["pace"]["wpm"] for r in long), 1)
        return {"meetings": len(group), "share": _avg(r["talk"]["share"] for r in group),
                "wpm": round(wpm) if wpm is not None else None,
                "fillers": _avg((r["fillers"]["per_minute"] for r in long), 2)}

    by_week: dict[str, list] = {}
    for r in rows:
        by_week.setdefault(week_of(r["start"]), []).append(r)
    by_kind: dict[str, list] = {}
    for r in rows:
        by_kind.setdefault(r["kind"], []).append(r)
    return {"weeks": [{"week": w, **numbers(by_week[w])} for w in sorted(by_week)[-weeks:]],
            "kinds": [{"kind": k, **numbers(by_kind[k])} for k in ("1:1", "group") if k in by_kind]}


def highlights(r: dict[str, Any], base: dict[str, Any]) -> list[str]:
    """The few things worth saying about one meeting, against the baseline."""
    out = []
    share = r["talk"]["share"]
    kind = "1:1s" if r["talk"]["people"] == 2 else "group meetings"
    usual = base["share_1on1"] if r["talk"]["people"] == 2 else base["share_group"]
    if share is not None and usual and share > usual + 0.15:
        out.append(f"You talked {round(100 * share)} % of the time; in {kind} you usually talk {round(100 * usual)} %.")
    elif share is not None and usual and share < usual - 0.2:
        out.append(f"You talked {round(100 * share)} % of the time — quieter than your usual {round(100 * usual)} %.")
    if r["monologues"]:
        m = r["monologues"][0]
        out.append(f"Longest stretch without anyone else: {m['seconds'] // 60}:{m['seconds'] % 60:02d}"
                   + (f" ({len(r['monologues'])} over 1:30)" if len(r["monologues"]) > 1 else "") + ".")
    fpm, usual_fpm = r["fillers"]["per_minute"], base["fillers_per_minute"].get(r["language"])
    if fpm and r["fillers"]["top"] and (not usual_fpm or fpm > usual_fpm * 1.25):
        top = r["fillers"]["top"][0]
        out.append(f"“{top['word']}” {top['count']}× — {fpm:.1f} filler words a minute"
                   + (f" (usual {usual_fpm:.1f})." if usual_fpm else "."))
    if r["interruptions"]["by_me"] >= 5:
        out.append(f"You started while someone was still talking {r['interruptions']['by_me']} times.")
    if r["quiet_invitees"]:
        names = ", ".join(q["name"] for q in r["quiet_invitees"][:3])
        out.append(f"Barely heard: {names}.")
    return out[:4]


def meetings(output_dir: Path) -> list[RecordingPaths]:
    if not output_dir.is_dir():
        return []
    return [RecordingPaths(f) for f in sorted(output_dir.iterdir())
            if is_recording_folder_name(f.name) and (f / "transcript.json").exists()]


# --- every meeting, cached ------------------------------------------------------------------

_RESULTS: dict[str, tuple[tuple, dict[str, Any]]] = {}
_RESULTS_LOCK = threading.Lock()


def _signature(paths: RecordingPaths) -> tuple:
    files = (paths.meta, paths.transcript_json, paths.calendar, paths.speakers, paths.speakers_auto,
             paths.speakers_merged, paths.speakers_ignored, paths.speakers_inferred, paths.speakers_rejected,
             paths.speakers_shared)
    return tuple(f.stat().st_mtime_ns if f.exists() else 0 for f in files)


def result(paths: RecordingPaths, *, user_name: str) -> dict[str, Any]:
    """``analyze`` with the meeting's names and invitees, kept until one of
    its files changes (the window and the live coach share it)."""
    from .calendar_events import invited_names
    from .shared_mic import display
    from .speakers import names_in_effect
    from .voices import VoiceBank

    signature = _signature(paths)
    with _RESULTS_LOCK:
        cached = _RESULTS.get(str(paths.folder))
    if cached is not None and cached[0] == signature:
        return cached[1]
    names = names_in_effect(paths)
    invited = invited_names(paths, sorted(set(names.values()) | set(VoiceBank().names())), user_name=user_name) or []
    # Who was cut off: a room shows as the room, not as SPEAKER_xx (#56).
    r = analyze(paths, user_name=user_name, invited=invited, names={**names, **display(paths)})
    with _RESULTS_LOCK:
        _RESULTS[str(paths.folder)] = (signature, r)
    return r


def _start(paths: RecordingPaths) -> str:
    try:
        start = json.loads(paths.meta.read_text()).get("start_time")
    except (OSError, ValueError, AttributeError):
        start = None
    if isinstance(start, str) and start:
        return start
    from .paths import recording_folder_timestamp

    return recording_folder_timestamp(paths.folder.name) or paths.folder.name


def history(output_dir: Path, *, user_name: str, limit: int | None = None) -> list[dict[str, Any]]:
    """Every transcribed meeting's numbers (only the last ``limit``: no
    other is read), oldest first, with its start and kind ("1:1": one
    other person spoke, else "group")."""
    out = []
    found = meetings(output_dir)
    for paths in found[-limit:] if limit else found:
        try:
            r = result(paths, user_name=user_name)
        except Exception:  # one broken meeting must not cost the others
            continue
        out.append({"id": paths.folder.name, "start": _start(paths),
                    "kind": "1:1" if r["talk"]["people"] == 2 else "group", **r})
    return out


# --- the baseline on disk: computed after `process`, read by the live coach -------------------


def baseline_path() -> Path:
    from ._xdg import xdg_config_home

    return xdg_config_home() / "palaver" / "coach-baseline.json"


def refresh_baseline(output_dir: Path, *, user_name: str) -> dict[str, Any]:
    """What is usual over the last BASELINE_MEETINGS meetings, saved for the
    live coach: it runs after `process`, in that process, never during a call."""
    from datetime import datetime

    base = baseline(history(output_dir, user_name=user_name, limit=BASELINE_MEETINGS))
    path = baseline_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps({"computed_at": datetime.now().astimezone().isoformat(timespec="seconds"),
                               "baseline": base}, indent=2))
    tmp.replace(path)
    return base


def load_baseline() -> dict[str, Any] | None:
    """The saved baseline; None before the first `process` wrote one."""
    try:
        data = json.loads(baseline_path().read_text())
    except (OSError, ValueError):
        return None
    base = data.get("baseline") if isinstance(data, dict) else None
    return base if isinstance(base, dict) else None
