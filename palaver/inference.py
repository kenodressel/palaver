"""Speakers named by inference (issue #38).

With the calendar and enough meetings, many voices can be named without
anyone typing a name:

- calendar: a 1:1 — one other person invited, one other voice that talks.
- elimination: five invited, four of them named; the one voice left is the
  one person left.
- intersection: a voice that recurs in several meetings; the only invitee
  all of those meetings share.
- voice: a voice like one named by the rules above, in another meeting
  (among its invitees first, as for the voice bank).

Each inferred name records the rule, why, how sure it is, and which other
names it rests on. Inferences are recomputed from the facts every time —
names given by hand, voices the bank recognizes, calendars, the voices
themselves — so correcting or rejecting a name takes back everything that
was built on it without bookkeeping. Inferred voices never enter the voice
bank; confirming an inferred name (giving it by hand) does that.

Stored per meeting in ``speakers_inferred.json``; a name given or rejected
by hand, and a voice the bank recognizes, take precedence. A name the user
said a voice is not ("Not Tom", #48) is never inferred for it, nor for a
voice like it in another meeting.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

import numpy as np

from . import calendar_events, shared_mic, titles
from .paths import RecordingPaths, is_recording_folder_name
from .voices import MATCH_MARGIN, MATCH_THRESHOLD, MIN_TALK_SECONDS, VoiceBank, recognize, said_not

# A voice must talk this much to be inferred from the calendar: short
# stretches are often a split-off part of someone else.
INFER_MIN_TALK = 30.0
# Other unnamed voices may talk at most this share of the inferred one.
MINOR_SHARE = 0.2
# How sure each rule is on its own, and the least a chain may end with.
CONFIDENCE = {"calendar": 0.9, "elimination": 0.85, "intersection": 0.75}
VOICE_CONFIDENCE = {True: 0.9, False: 0.8}  # clear voice match, or only among the invitees
FACT_CONFIDENCE = {"you": 1.0, "voice": 0.95, "imported": 0.9}  # imported: a name the sender gave (#58)
MIN_CONFIDENCE = 0.5
ROUNDS = 6


@dataclass
class Inference:
    name: str
    rule: str
    why: str
    confidence: float
    depends: list[str] = field(default_factory=list)  # "meeting:label" of the names it rests on


@dataclass
class _Meeting:
    id: str
    title: str
    embeddings: dict[str, np.ndarray]  # unit length; merged-away labels left out
    talk: dict[str, float]
    candidates: list[str] | None  # invitees as named elsewhere; None: no event, or a room on it
    fixed: dict[str, tuple[str, str]]  # label → (name, "you" | "voice")
    blocked: set[str]  # labels whose recognized or inferred name the user rejected
    rejected: dict[str, set[str]] = field(default_factory=dict)  # label → casefolded names it is not


def _unit(v) -> np.ndarray:
    a = np.asarray(v, dtype=float)
    n = np.linalg.norm(a)
    return a / n if n else a


def _load(output_dir: Path, *, user_name: str, known: list[str]) -> list[_Meeting]:
    from .speakers import (
        load_ignored,
        load_merges,
        load_recognized_names,
        load_rejected_names,
        load_speaker_names,
        merged_turns,
        talk_seconds,
    )
    from .models import SpeakerTurn

    out = []
    if not output_dir.is_dir():
        return out
    for folder in sorted(output_dir.iterdir()):
        paths = RecordingPaths(folder)
        if not is_recording_folder_name(folder.name) or not paths.speaker_embeddings.exists():
            continue
        try:
            raw = json.loads(paths.speaker_embeddings.read_text())
            turns = [SpeakerTurn.from_dict(d) for d in json.loads(paths.system_turns.read_text())]
        except (OSError, ValueError):
            continue
        merges = load_merges(paths)
        manual = load_speaker_names(paths)
        blocked = {label for label, name in manual.items() if name == label}
        not_names = {label: {n.casefold() for n in names} for label, names in load_rejected_names(paths).items()}
        # Names an imported meeting came with (#58) are known here: no rule gives them to another voice.
        from . import exchange

        fixed = {label: (h["name"], "imported") for label, h in exchange.hints(paths).items()
                 if label not in blocked and label not in merges and h["name"].casefold() not in not_names.get(label, set())}
        fixed.update({label: (name, "voice") for label, (name, _) in load_recognized_names(paths).items()
                      if label not in blocked and label not in merges})
        fixed.update({label: (name, "you") for label, name in manual.items()
                      if name != label and label not in merges})
        event = calendar_events.load(paths)
        candidates = None
        # Several people on one voice (#56): any invitee may have been among them,
        # so who is left by elimination is not known.
        if event is not None and not any(a.is_room for a in event.attendees) and not shared_mic.marked(paths):
            candidates = [calendar_events.resolve(a.name, known) or a.name
                          for a in calendar_events.candidates(event, user_name=user_name)]
        # Noise: as if nobody spoke. Several people on one voice (#56): no one to infer.
        ignored = load_ignored(paths) | shared_mic.shared_labels(paths)
        embeddings = {label: _unit(v) for label, v in raw.items()
                      if label not in merges and label not in ignored and np.isfinite(v).all() and any(v)}
        talk = {label: t for label, t in talk_seconds(merged_turns(turns, merges)).items() if label not in ignored}
        fixed = {label: named for label, named in fixed.items() if label not in ignored}
        rejected = {label: {n.casefold() for n in names} for label, names in load_rejected_names(paths).items()}
        out.append(_Meeting(folder.name, titles.resolve(paths, event=event)[0] or folder.name, embeddings,
                            talk, candidates, fixed, blocked, rejected))
    return out


class _InferredVoices:
    """Voices named by inference, shaped like the voice bank for recognize()."""

    def __init__(self, samples: list[tuple[str, np.ndarray, str]]):
        self.samples = samples  # (name, unit embedding, "meeting:label")

    def best(self, embedding) -> dict[str, tuple[float, str]]:
        query = _unit(embedding)
        best: dict[str, tuple[float, str]] = {}
        for name, vector, key in self.samples:
            sim = float(vector @ query)
            if name not in best or sim > best[name][0]:
                best[name] = (sim, key)
        return best

    def scores(self, embedding) -> list[tuple[float, str]]:
        return sorted(((sim, name) for name, (sim, _) in self.best(embedding).items()), reverse=True)

    def match(self, embedding) -> tuple[str, float] | None:
        s = self.scores(embedding)
        if not s or s[0][0] < MATCH_THRESHOLD or (len(s) > 1 and s[0][0] - s[1][0] < MATCH_MARGIN):
            return None
        return s[0][1], s[0][0]


def infer(meetings: list[_Meeting]) -> dict[str, dict[str, Inference]]:
    """meeting id → label → Inference, from the facts in ``meetings``."""
    inferred: dict[str, dict[str, Inference]] = {m.id: {} for m in meetings}

    def named(m: _Meeting) -> dict[str, str]:
        return {**{label: name for label, (name, _) in m.fixed.items()},
                **{label: i.name for label, i in inferred[m.id].items()}}

    def confidence(key: str) -> float:
        mid, label = key.split(":", 1)
        m = by_id[mid]
        if label in m.fixed:
            return FACT_CONFIDENCE[m.fixed[label][1]]
        return inferred[mid][label].confidence

    def remaining(m: _Meeting) -> list[str]:
        used = {n.casefold() for n in named(m).values()}
        return [c for c in dict.fromkeys(m.candidates or []) if c.casefold() not in used]

    # Voices the user said are not someone: neither they nor voices like them get that name.
    said_no = [(name, m.embeddings[label]) for m in meetings for label, names in m.rejected.items()
               if label in m.embeddings for name in names]

    def add(m: _Meeting, label: str, inference: Inference, alike: float = 0.0) -> bool:
        """``alike``: how alike the voice is to the person's (the voice rule's
        similarity): a rejected voice must be more alike than that to block it."""
        if inference.confidence < MIN_CONFIDENCE or label in inferred[m.id]:
            return False
        if inference.name.casefold() in m.rejected.get(label, set()) or (
                label in m.embeddings and said_not(inference.name, m.embeddings[label], said_no, alike)):
            return False
        if inference.name.casefold() in {n.casefold() for n in named(m).values()}:
            return False
        inferred[m.id][label] = inference
        return True

    by_id = {m.id: m for m in meetings}
    for _ in range(ROUNDS):
        added = False
        for m in meetings:
            if m.candidates is None:
                continue
            names = named(m)
            talking = [label for label in sorted(m.talk) if m.talk[label] >= INFER_MIN_TALK]
            unnamed = [label for label in talking if label not in names and label not in m.blocked]
            left = remaining(m)
            if len(unnamed) != 1 or len(left) != 1 or len(talking) > len(set(m.candidates)):
                continue
            label = unnamed[0]
            minor = sum(t for other, t in m.talk.items()
                        if other != label and other not in names and MIN_TALK_SECONDS <= t < INFER_MIN_TALK)
            if minor > MINOR_SHARE * m.talk[label]:
                continue  # another voice might be the same person, or someone uninvited
            depends = sorted(f"{m.id}:{other}" for other, name in names.items()
                             if name.casefold() in {c.casefold() for c in m.candidates})
            if not depends:
                why = f"Only {left[0]} was invited besides you, and this is the only other voice ({round(m.talk[label] / 60)} min)."
                inference = Inference(left[0], "calendar", why, CONFIDENCE["calendar"])
            else:
                others = ", ".join(names[d.split(":", 1)[1]] for d in depends)
                why = f"{left[0]} is the one invitee left: {others} {'is' if len(depends) == 1 else 'are'} known here."
                conf = CONFIDENCE["elimination"] * min(confidence(d) for d in depends)
                inference = Inference(left[0], "elimination", why, round(conf, 3), depends)
            added |= add(m, label, inference)

        # Voices like an inferred one, in other meetings.
        samples = [(i.name, by_id[mid].embeddings[label], f"{mid}:{label}")
                   for mid, labels in inferred.items() for label, i in labels.items()
                   if label in by_id[mid].embeddings and by_id[mid].talk.get(label, 0) >= INFER_MIN_TALK]
        if samples:
            for m in meetings:
                names = named(m)
                pool = _InferredVoices([s for s in samples if not s[2].startswith(f"{m.id}:")])
                open_ = {label: v for label, v in m.embeddings.items() if label not in names and label not in m.blocked}
                for label, (name, sim) in recognize(open_, m.talk, pool, m.candidates, rejected=said_no).items():
                    key = pool.best(m.embeddings[label])[name][1]
                    source = by_id[key.split(":", 1)[0]]
                    conf = confidence(key) * VOICE_CONFIDENCE[sim >= MATCH_THRESHOLD]
                    why = f"Same voice as {name} in “{source.title}” ({sim:.2f})."
                    added |= add(m, label, Inference(name, "voice", why, round(conf, 3), [key]), alike=sim)

        # A recurring voice and the one invitee its meetings share.
        added |= _intersections(meetings, named, remaining, add)
        if not added:
            break
    return {mid: labels for mid, labels in inferred.items() if labels}


def _intersections(meetings, named, remaining, add) -> bool:
    from .people import GROUP_THRESHOLD, Voice, _groups

    voices = [Voice(m.id, label, m.talk[label], m.embeddings[label], None, None)
              for m in meetings if m.candidates is not None
              for label in m.embeddings
              if m.talk.get(label, 0) >= INFER_MIN_TALK and label not in named(m) and label not in m.blocked]
    by_id = {m.id: m for m in meetings}
    added = False
    for group in _groups(voices, GROUP_THRESHOLD):
        meeting_ids = {v.meeting for v in group}
        if len(meeting_ids) < 2 or len(group) != len(meeting_ids):
            continue  # one voice per meeting, in several meetings
        shared = None
        for mid in meeting_ids:
            left = {c.casefold(): c for c in remaining(by_id[mid])}
            shared = left if shared is None else {k: v for k, v in shared.items() if k in left}
        if not shared or len(shared) != 1:
            continue
        name = next(iter(shared.values()))
        why = f"A voice heard in {len(meeting_ids)} meetings; {name} is the only invitee they all share."
        for v in group:
            added |= add(by_id[v.meeting], v.label, Inference(name, "intersection", why, CONFIDENCE["intersection"]))
    return added


def load(paths: RecordingPaths) -> dict[str, dict[str, Any]]:
    """label → the inference (as stored) for one meeting."""
    try:
        return json.loads(paths.speakers_inferred.read_text())
    except (OSError, ValueError):
        return {}


def refresh(output_dir: Path, *, user_name: str = "", bank: VoiceBank | None = None) -> int:
    """Infer names in every meeting again; rewrite the transcripts whose
    inferred names changed. Returns how many changed."""
    from .speakers import load_speaker_names, save_speaker_names

    bank = bank or VoiceBank()
    meetings = _load(output_dir, user_name=user_name, known=list(bank.names()))
    known = sorted({name for m in meetings for name, _ in m.fixed.values()} | set(bank.names()))
    meetings = _load(output_dir, user_name=user_name, known=known)
    result = infer(meetings)
    changed = 0
    from . import exchange

    for m in meetings:
        paths = RecordingPaths(output_dir / m.id)
        new = {label: asdict(i) for label, i in sorted(result.get(m.id, {}).items())}
        # Names that came with an import (#58) are facts of the file, not of the rules: kept, unless a rule is surer.
        for label, hint in exchange.hints(paths).items():
            if label not in new or new[label]["confidence"] < hint["confidence"]:
                new[label] = hint
        new = dict(sorted(new.items()))
        if new == load(paths):
            continue
        if new:
            paths.speakers_inferred.write_text(json.dumps(new, indent=2, ensure_ascii=False))
        else:
            paths.speakers_inferred.unlink(missing_ok=True)
        if paths.transcript_json.exists() and paths.meta.exists():
            save_speaker_names(paths, load_speaker_names(paths), bank)
        changed += 1
    return changed
