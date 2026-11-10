"""Manual speaker naming (issue #12).

``rename`` maps diarization labels (``SPEAKER_00``) to names, stored in
``speakers.json``. When diarization splits one person into several
speakers, ``merge_speakers`` folds one label into another
(``speakers_merged.json``): it shows and is named as the other from then on.
``process`` applies both, so names and merges survive reprocessing.

A single line diarization gave to the wrong voice ("Speaker 2" holds two
people) is said to be someone else's in ``speakers_lines.json``: a list of
``{"start", "end", "from", ...}`` where ``from`` is the voice it was heard
as (None: the user's microphone) and the rest says who said it: another
voice (``"label"``), a person without a voice of their own (``"name"``) or
the user (``"me": true`` and the user's name then). It is applied whenever
the transcript is shown, searched, summarized or exported, never written
into ``transcript.json``; a line is found by its time, so the correction
stays when the meeting is processed again. Kept as heard, so the voices
can later learn from it.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
from dataclasses import replace
from datetime import datetime
from pathlib import Path
from typing import Callable

import soundfile as sf

from .models import SpeakerTurn, Utterance
from .paths import RecordingPaths
from . import shared_mic
from .render import render_markdown
from .store_lock import meeting_lock
from .voices import MIN_TALK_SECONDS, VoiceBank

MAX_SAMPLE_SECONDS = 8.0


def load_speaker_names(paths: RecordingPaths) -> dict[str, str]:
    if not paths.speakers.exists():
        return {}
    return {str(k): str(v) for k, v in json.loads(paths.speakers.read_text()).items()}


def apply_speaker_names(
    utterances: list[Utterance], names: dict[str, str]
) -> list[Utterance]:
    out = []
    for u in utterances:
        label = u.label or u.speaker
        name = names.get(label)
        out.append(
            Utterance(name or label, u.start, u.end, u.text, label=label if name else None, heard=u.heard,
                      unsure=u.unsure, said_by=u.said_by, heard_as=u.heard_as)
        )
    return out


def load_merges(paths: RecordingPaths) -> dict[str, str]:
    """label → the label it was merged into."""
    try:
        return {str(k): str(v) for k, v in json.loads(paths.speakers_merged.read_text()).items()}
    except (OSError, ValueError):
        return {}


def follow_merges(names: dict[str, str], merges: dict[str, str]) -> dict[str, str]:
    """``names`` with each merged label named as the label it was merged
    into (or called by that label, while it has no name)."""
    out = {label: name for label, name in names.items() if label not in merges}
    for label, into in merges.items():
        out[label] = out.get(into, into)
    return out


def load_ignored(paths: RecordingPaths) -> set[str]:
    """Labels removed as noise; their lines are left out wherever the
    meeting is shown, searched or summarized (transcript.json keeps them)."""
    try:
        return set(json.loads(paths.speakers_ignored.read_text()))
    except (OSError, ValueError):
        return set()


def set_ignored(paths: RecordingPaths, label: str, ignored: bool = True) -> None:
    with meeting_lock(paths.folder):
        labels = load_ignored(paths)
        labels = labels | {label} if ignored else labels - {label}
        if labels:
            paths.speakers_ignored.write_text(json.dumps(sorted(labels)))
        else:
            paths.speakers_ignored.unlink(missing_ok=True)


def load_unknown(paths: RecordingPaths) -> set[str]:
    """Labels the user can't name ("Don't Know"): still unnamed lanes, but
    no to-do, so a voice nobody knows isn't asked about forever."""
    try:
        return {str(label) for label in json.loads(paths.speakers_unknown.read_text())}
    except (OSError, ValueError, TypeError):
        return set()


def set_unknown(paths: RecordingPaths, label: str, unknown: bool = True) -> None:
    with meeting_lock(paths.folder):
        labels = load_unknown(paths)
        labels = labels | {label} if unknown else labels - {label}
        if labels:
            paths.speakers_unknown.write_text(json.dumps(sorted(labels)))
        else:
            paths.speakers_unknown.unlink(missing_ok=True)


def without_ignored(paths: RecordingPaths, utterances: list[Utterance]) -> list[Utterance]:
    """``utterances`` as the user corrected them: single lines with the
    speaker they were said to be (speakers_lines.json), then without the
    lines of removed voices."""
    utterances = with_line_speakers(paths, utterances)
    ignored = load_ignored(paths)
    if not ignored:
        return utterances
    merges = load_merges(paths)
    return [u for u in utterances if merges.get(u.label or u.speaker, u.label or u.speaker) not in ignored]


def load_rejected_names(paths: RecordingPaths) -> dict[str, list[str]]:
    """label → names the user said this voice is not ("Not Tom", #48): no
    recognition or inference gives them to it again."""
    try:
        data = json.loads(paths.speakers_rejected.read_text())
        return {str(label): [str(n) for n in names] for label, names in data.items() if names}
    except (OSError, ValueError, AttributeError, TypeError):
        return {}


def _is_rejected(rejected: dict[str, list[str]], label: str, name: str) -> bool:
    return name.casefold() in {n.casefold() for n in rejected.get(label, [])}


def set_rejected_name(paths: RecordingPaths, label: str, name: str, rejected: bool = True) -> None:
    """"``label`` is not ``name``", or (``rejected=False``) it may be after all."""
    with meeting_lock(paths.folder):
        names = load_rejected_names(paths)
        kept = [n for n in names.get(label, []) if n.casefold() != name.casefold()]
        names[label] = kept + [name] if rejected else kept
        names = {k: v for k, v in names.items() if v}
        if names:
            paths.speakers_rejected.write_text(json.dumps(names, indent=2, ensure_ascii=False))
        else:
            paths.speakers_rejected.unlink(missing_ok=True)


def load_inferred_names(paths: RecordingPaths) -> dict[str, str]:
    """label → name inferred from the calendar and other meetings, but not
    one the user said the voice is not."""
    try:
        inferred = {label: i["name"] for label, i in json.loads(paths.speakers_inferred.read_text()).items()}
    except (OSError, ValueError, KeyError, TypeError):
        return {}
    rejected = load_rejected_names(paths)
    return {label: name for label, name in inferred.items() if not _is_rejected(rejected, label, name)}


def names_in_effect(paths: RecordingPaths) -> dict[str, str]:
    """label → name in effect: inferred, recognized by voice, given by hand
    (each overriding the one before); a merged label has the name of the
    label it was merged into."""
    names = load_inferred_names(paths)
    names.update({label: name for label, (name, _) in load_recognized_names(paths).items()})
    names.update(load_speaker_names(paths))
    merges = load_merges(paths)
    names = {label: name for label, name in names.items() if name != label and label not in merges}
    names.update({label: names[into] for label, into in merges.items() if into in names})
    shared = shared_mic.shared_labels(paths)  # several people: no one's name (#56)
    return {label: name for label, name in names.items() if label not in shared}


def merged_turns(turns: list[SpeakerTurn], merges: dict[str, str]) -> list[SpeakerTurn]:
    return [SpeakerTurn(merges.get(t.speaker, t.speaker), t.start, t.end) for t in turns]


def merge_speakers(
    paths: RecordingPaths, label: str, into: str | None, bank: VoiceBank | None = None
) -> None:
    """Fold ``label`` into ``into`` (one person the diarizer split in two);
    ``into=None`` splits it off again. A name given only to ``label`` moves
    to ``into``. Rewrites the transcript."""
    # The meeting's lock is let go before save_speaker_names: it takes the voice bank's (never two at once).
    with meeting_lock(paths.folder):
        merges = load_merges(paths)
        names = load_speaker_names(paths)
        if into is None:
            merges.pop(label, None)
        else:
            into = merges.get(into, into)
            if into == label:
                raise ValueError("a speaker cannot be merged into itself")
            merges = {k: (into if v == label else v) for k, v in merges.items()}
            merges[label] = into
            own = names.pop(label, None)
            if own and own != label and into not in names:
                names[into] = own
            # What the user said the merged voice is not, the person is not either.
            for name in load_rejected_names(paths).get(label, []):
                set_rejected_name(paths, into, name)
        if merges:
            paths.speakers_merged.write_text(json.dumps(merges, indent=2, ensure_ascii=False))
        else:
            paths.speakers_merged.unlink(missing_ok=True)
        shared_mic.follow_merges(paths)  # a room merged into a voice: the room wins (#56)
    save_speaker_names(paths, names, bank)


def load_recognized_names(paths: RecordingPaths) -> dict[str, tuple[str, float]]:
    """label → (name, similarity) recognized by voice, but not a name the
    user said the voice is not."""
    if not paths.speakers_auto.exists():
        return {}
    rejected = load_rejected_names(paths)
    return {
        label: (hit["name"], float(hit["similarity"]))
        for label, hit in json.loads(paths.speakers_auto.read_text()).items()
        if not _is_rejected(rejected, label, hit["name"])
    }


def talk_seconds(turns: list[SpeakerTurn]) -> dict[str, float]:
    totals: dict[str, float] = {}
    for t in turns:
        totals[t.speaker] = totals.get(t.speaker, 0.0) + (t.end - t.start)
    return totals


def longest_turns(turns: list[SpeakerTurn]) -> dict[str, SpeakerTurn]:
    best: dict[str, SpeakerTurn] = {}
    for t in turns:
        current = best.get(t.speaker)
        if current is None or t.end - t.start > current.end - current.start:
            best[t.speaker] = t
    return best


def play_clip(wav: Path, start: float, end: float) -> None:
    """Play ``wav[start:end]`` through the default output via afplay."""
    info = sf.info(str(wav))
    data, sr = sf.read(
        str(wav), start=int(start * info.samplerate), stop=int(end * info.samplerate)
    )
    with tempfile.NamedTemporaryFile(suffix=".wav") as clip:
        sf.write(clip.name, data, sr)
        subprocess.run(["afplay", clip.name], check=False)


def run_wizard(
    paths: RecordingPaths,
    *,
    ask: Callable[[str], str] = input,
    play: Callable[[Path, float, float], None] | None = play_clip,
    say: Callable[[str], None] = print,
    bank: VoiceBank | None = None,
) -> dict[str, str]:
    """Ask for a name per remote speaker, save speakers.json, rewrite the
    transcript, and remember named voices. Enter keeps the current name —
    for a name recognized by voice that confirms it — ``r`` replays."""
    turns = [SpeakerTurn.from_dict(d) for d in json.loads(paths.system_turns.read_text())]
    utterances = [Utterance.from_dict(d) for d in json.loads(paths.transcript_json.read_text())]
    names = load_speaker_names(paths)
    recognized = load_recognized_names(paths)

    for label, turn in sorted(longest_turns(turns).items()):
        own = [u for u in utterances if (u.label or u.speaker) == label]
        total = sum(u.end - u.start for u in own)
        say(f"\n{label} — {len(own)} utterances, {total / 60:.1f} min")
        for u in sorted(own, key=lambda u: u.start - u.end)[:2]:
            say(f'  "{u.text[:100]}"')
        end = min(turn.end, turn.start + MAX_SAMPLE_SECONDS)
        if label in names:
            current, hint = names[label], ""
        elif label in recognized:
            current = recognized[label][0]
            hint = f" — recognized by voice, {recognized[label][1]:.2f}"
        else:
            current, hint = label, ""
        while True:
            if play is not None:
                play(paths.system_wav, turn.start, end)
            answer = ask(f"Who is {label}? [{current}{hint}] (r = replay) ").strip()
            if answer.lower() != "r":
                break
        if answer:
            names[label] = answer
        elif current != label:
            names[label] = current

    enrolled = save_speaker_names(paths, names, bank)
    if enrolled:
        say(f"Remembered {enrolled} voice sample(s) for automatic recognition.")
    return names


def save_speaker_names(
    paths: RecordingPaths, names: dict[str, str], bank: VoiceBank | None = None, *, learn: bool = True
) -> int:
    """Store the names given to labels, re-learn their voices (unless
    ``learn`` is False: nothing about them changed), and rewrite the
    transcript. Names recognized by voice stay unless ``names`` overrides
    them; mapping a label to itself rejects a recognized name. Returns the
    number of voice samples added."""
    # Unchanged names keep their file as it is: an undo taken before still finds it unchanged.
    with meeting_lock(paths.folder):
        try:
            same = paths.speakers.exists() and load_speaker_names(paths) == names
        except (ValueError, AttributeError):
            same = False
        if not same:
            paths.speakers.write_text(json.dumps(names, indent=2, ensure_ascii=False))
    # Learning voices takes the voice bank's lock, so not under the meeting's: one lock at a time.
    turns = [SpeakerTurn.from_dict(d) for d in json.loads(paths.system_turns.read_text())]
    merges = load_merges(paths)
    ignored = load_ignored(paths)
    shared = shared_mic.display(paths)  # for who learns; the transcript reads it again under the lock
    # A merged-away label teaches no voice: it is often the odd part the
    # diarizer split off, not a good sample of the person. Nor does noise,
    # nor a room of several people (#56).
    enrolled = _remember_voices(paths, {label: n for label, n in names.items()
                                        if label not in merges and label not in ignored and label not in shared},
                                talk_seconds(turns), bank or VoiceBank()) if learn else 0
    with meeting_lock(paths.folder):
        effective = transcript_names(paths)  # as stored now (read again under the lock), not the caller's copy
        utterances = [Utterance.from_dict(d) for d in json.loads(paths.transcript_json.read_text())]
        renamed = apply_speaker_names(utterances, effective)
        paths.transcript_json.write_text(json.dumps([u.to_dict() for u in renamed], indent=2))
        meta = json.loads(paths.meta.read_text())
        paths.transcript_md.write_text(
            render_markdown(
                shared_mic.shown(paths, without_ignored(paths, renamed)),
                datetime.fromisoformat(meta["start_time"]),
                float(meta["duration_seconds"]),
                meta.get("gaps"),
            )
        )
    return enrolled


def transcript_names(paths: RecordingPaths, names: dict[str, str] | None = None) -> dict[str, str]:
    """label → the name transcript.json gives its lines: inferred, recognized
    by voice, given by hand (``names``, else speakers.json), merged labels
    as their person, rooms as the room (#56)."""
    effective = load_inferred_names(paths)
    effective.update({label: name for label, (name, _) in load_recognized_names(paths).items()})
    effective.update(load_speaker_names(paths) if names is None else names)
    effective = follow_merges(effective, load_merges(paths))
    effective.update(shared_mic.display(paths))
    return effective


def _remember_voices(
    paths: RecordingPaths, names: dict[str, str], talk: dict[str, float], bank: VoiceBank
) -> int:
    if not paths.speaker_embeddings.exists():
        return 0
    embeddings = json.loads(paths.speaker_embeddings.read_text())
    added = 0
    for label in embeddings:
        source = f"{paths.folder.name}:{label}"
        name = names.get(label)
        owner = bank.owner(source)
        if owner is not None and owner != name:
            bank.remove_source(source)  # renamed: the voice was someone else's
        if name is None or name == label or talk.get(label, 0.0) < MIN_TALK_SECONDS:
            continue
        added += bank.add(name, embeddings[label], source=source)
    return added


# --- names given while recording (#30) ------------------------------------------

# A voice named while recording is the same as a speaker's voice this alike.
# Provisional labels change between snapshots; voices don't.
LIVE_MATCH = 0.7


def _unit(v) -> "np.ndarray":
    import numpy as np

    a = np.asarray(v, dtype=float)
    n = np.linalg.norm(a)
    return a / n if n else a


def load_live_names(paths: RecordingPaths) -> list[dict]:
    try:
        return json.loads(paths.speakers_live.read_text())
    except (OSError, ValueError):
        return []


def match_live_names(embeddings: dict[str, list[float]], named: list[dict]) -> dict[str, str]:
    """label → name, pairing each named voice with its most alike label
    (each at most once)."""
    pairs = sorted(
        ((float(_unit(v) @ _unit(n["embedding"])), label, n["name"])
         for label, v in embeddings.items() for n in named),
        reverse=True)
    out: dict[str, str] = {}
    taken: set[str] = set()
    for sim, label, name in pairs:
        if sim < LIVE_MATCH or label in out or name in taken:
            continue
        out[label] = name
        taken.add(name)
    return out


def name_live_speaker(paths: RecordingPaths, label: str, name: str) -> None:
    """Name the voice behind a provisional label; an empty name forgets it."""
    live = json.loads(paths.live.read_text())
    voice = live.get("embeddings", {}).get(label)
    if voice is None:
        raise LookupError(label)
    with meeting_lock(paths.folder):
        current = match_live_names({label: voice}, load_live_names(paths)).get(label)
        named = [n for n in load_live_names(paths) if n["name"] != current and n["name"] != name.strip()]
        if name.strip():
            named.append({"name": name.strip(), "embedding": voice})
        paths.speakers_live.write_text(json.dumps(named, ensure_ascii=False))


def adopt_live_names(paths: RecordingPaths) -> dict[str, str]:
    """Names given while recording, onto the final speakers (as if given
    afterwards); a name given afterwards wins. Returns what was adopted."""
    with meeting_lock(paths.folder):
        named = load_live_names(paths)
        if not named or not paths.speaker_embeddings.exists():
            return {}
        found = match_live_names(json.loads(paths.speaker_embeddings.read_text()), named)
        names = load_speaker_names(paths)
        adopted = {label: name for label, name in found.items() if label not in names}
        if adopted:
            paths.speakers.write_text(json.dumps({**names, **adopted}, indent=2, ensure_ascii=False))
        paths.speakers_live.unlink(missing_ok=True)
        return adopted


# --- the speaker of single lines (#12) ------------------------------------------

_DIARIZED = re.compile(r"SPEAKER_\d+")
# A correction is a line's when it covers at least this much of it.
LINE_COVERED = 0.5


def is_mic_line(u: Utterance) -> bool:
    """A line of the user's microphone, as transcript.json has it: no
    diarization label, named or not, and not a line said to be a person's (#12)."""
    return u.label is None and u.said_by is None and not _DIARIZED.fullmatch(u.speaker)


def load_line_speakers(paths: RecordingPaths) -> list[dict]:
    """The corrections of single lines, by time."""
    try:
        data = json.loads(paths.speakers_lines.read_text())
    except (OSError, ValueError):
        return []
    if not isinstance(data, list):
        return []
    number = (int, float)
    return [d for d in data if isinstance(d, dict) and isinstance(d.get("start"), number)
            and isinstance(d.get("end"), number) and not isinstance(d.get("start"), bool)]


def _save_line_speakers(paths: RecordingPaths, fixes: list[dict]) -> None:
    if not fixes:
        paths.speakers_lines.unlink(missing_ok=True)
        return
    tmp = paths.speakers_lines.with_name(paths.speakers_lines.name + ".tmp")
    tmp.write_text(json.dumps(sorted(fixes, key=lambda d: (d["start"], d["end"])), indent=2, ensure_ascii=False))
    os.replace(tmp, paths.speakers_lines)


def line_track(u: Utterance) -> str:
    """"mic" or "others": the track a line of transcript.json is on."""
    return "mic" if is_mic_line(u) else "others"


def line_fix(u: Utterance, fixes: list[dict]) -> dict | None:
    """The correction of line ``u``: one of its track (the microphone, or the
    others) covering most of it; transcribed again, a line's times move a
    little and its voice may get another label."""
    mic = is_mic_line(u)
    length = max(u.end - u.start, 0.0)
    best, covered = None, 0.0
    for f in fixes:
        if (f.get("from") is None) != mic:
            continue
        if abs(f["start"] - u.start) < 0.01 and abs(f["end"] - u.end) < 0.01:
            return f
        overlap = min(u.end, f["end"]) - max(u.start, f["start"])
        if length == 0.0:
            overlap = 1.0 if f["start"] <= u.start <= f["end"] else 0.0
            length = 1.0
        if overlap >= LINE_COVERED * length and overlap > covered:
            best, covered = f, overlap
    return best


def _said_by(u: Utterance, fix: dict, names: dict[str, str], me: str | None) -> Utterance:
    if fix.get("me"):
        return replace(u, speaker=me or str(fix.get("name") or "Me"), label=None)
    label = fix.get("label")
    if isinstance(label, str):
        name = names.get(label)
        return replace(u, speaker=name, label=label) if name else replace(u, speaker=label, label=None)
    name = str(fix.get("name") or "").strip()
    return replace(u, speaker=name, label=None, said_by=name) if name else u


def corrected_lines(utterances: list[Utterance], fixes: list[dict], names: dict[str, str],
                    me: str | None = None) -> list[Utterance]:
    """``utterances`` (as transcript.json has them) with each corrected line
    said by whom the user said: a voice as its name in ``names`` (label →
    name), a person by name, the user as ``me`` (by default the name on the
    microphone's lines)."""
    if not fixes:
        return utterances
    if me is None:
        me = next((u.speaker for u in utterances if is_mic_line(u)), None)
    out = []
    for u in utterances:
        fix = line_fix(u, fixes)
        if fix is None:
            out.append(u)
        else:
            heard_as = ("mic", None) if is_mic_line(u) else ("others", u.label or u.speaker)
            out.append(replace(_said_by(u, fix, names, me), heard_as=heard_as))
    return out


def with_line_speakers(paths: RecordingPaths, utterances: list[Utterance]) -> list[Utterance]:
    """``utterances`` with the corrections of speakers_lines.json."""
    fixes = load_line_speakers(paths)
    if not fixes:
        return utterances
    return corrected_lines(utterances, fixes, transcript_names(paths))


def set_line_speaker(paths: RecordingPaths, line: Utterance, to: dict | None) -> None:
    """Say who said ``line`` (as transcript.json has it): ``{"label": …}``,
    ``{"name": …}`` or ``{"me": True, "name": …}``; None: the voice it was
    heard as. One correction per line: a new one replaces the old."""
    with meeting_lock(paths.folder):  # a speaker file of the meeting: the same lock as the others (and Swift)
        fixes = load_line_speakers(paths)
        current = line_fix(line, fixes)
        fixes = [f for f in fixes if f is not current]
        if to is not None:
            fixes.append({"start": round(line.start, 3), "end": round(line.end, 3),
                          "from": None if is_mic_line(line) else (line.label or line.speaker), **to})
        _save_line_speakers(paths, fixes)
