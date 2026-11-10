"""The setup assistant (#55): what this Mac can run locally (#43), and
the settings worth choosing up front, with a recommendation and its
reason for each.

- ``recommend(hardware, installed, current)`` is a pure function: the
  assistant shows it step by step, the Settings page shows the same as
  "Recommended for this Mac". It reads the provider registry generically
  (features x providers), so cloud transcription (#54) shows up here
  once its feature is in providers.FEATURES.
- Nothing here changes a setting by itself; api.apply_setup does, on the
  user's click.
- ``Probe`` looks at the Mac: the chip, memory and free disk, which apps
  are installed, and the permissions. It never asks for a permission
  (no prompt), and never downloads or records unless the user started it
  (``Downloads``, ``TestRecording``).

Measured on 2026-10-29: Gemma 4 12B 4-bit is an 8.3 GB download and uses
about 10 GB while writing, up to 12 GB (notes wait for 14 GB free);
Qwen3-30B-A3B needs 18-22 GB (20 GB free); the live worker about 3.6 GB,
the realtime stream 1.9-2.5 GB; the speech models (Parakeet v3 and the
diarizer, CoreML, through palaver-engine) 0.5 GB on disk and under 1 GB of
memory; multilingual-e5-small 470 MB.
"""

from __future__ import annotations

import contextlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import asdict, dataclass, field, replace
from pathlib import Path
from typing import Any, Callable, Iterable

from . import notes
from .doctor import Check, check_disk

LOCAL = "local"
PENDING = "pending"  # notes wait for a cloud model the user has not set up yet (providers.PENDING)
UNSUPPORTED = "Not supported on this Mac"
INTEL = ("Apple Silicon is required for local processing, and this Mac has {short}: Palaver doesn't support "
         "Intel Macs yet.")
LANGUAGE_MODEL = "language_model"
TRANSCRIPTION = "transcription"
GEMMA = notes.DEFAULT_LOCAL_MODEL
QWEN = "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"

# What a local model can't count on: macOS, Teams, a browser and an IDE.
# 24 GB leaves 14 GB, what Gemma 4 12B waits for.
OTHER_APPS_GB = 10.0
# Left free after downloads: recordings (about 250 MB per hour) and the system.
DISK_RESERVE_GB = 5.0
LIVE_WORKER_GB = 3.6
STREAM_GB = "1.9–2.5"
REALTIME_MIN_MEMORY_GB = 16
LIVE_MIN_MEMORY_GB = 24


@dataclass(frozen=True)
class Model:
    """A model the assistant may download."""
    id: str
    label: str
    purpose: str
    repo: str
    probe: str  # a file of the repo that is there once it is downloaded
    disk_gb: float
    memory: str  # what it uses, said plainly
    hosted: bool = False  # a release carries a copy (model_store)
    local_folder: str = ""  # a folder of Application Support/palaver/models that holds it (or an old copy of it)
    manual: bool = False  # retired, but never dropped at start: Settings → Storage offers to delete it
    transcriber: str = ""  # config.toml's transcriber that still uses it: kept while chosen


# The speech models are one download: palaver-engine's own (Parakeet v3 and the
# diarizer, CoreML, from Hugging Face without a token), in models/fluidaudio.
# ``probe`` is the diarizer's last file, the cheap check; see ``speech_here``.
SPEECH_FOLDER = "fluidaudio"
SPEECH_FILES = (
    "parakeet-tdt-0.6b-v3/Preprocessor.mlmodelc", "parakeet-tdt-0.6b-v3/Encoder.mlmodelc",
    "parakeet-tdt-0.6b-v3/Decoder.mlmodelc", "parakeet-tdt-0.6b-v3/JointDecisionv3.mlmodelc",
    "parakeet-tdt-0.6b-v3/parakeet_v3_vocab.json",
    "speaker-diarization/Segmentation.mlmodelc", "speaker-diarization/Embedding.mlmodelc",
    "speaker-diarization/FBank.mlmodelc", "speaker-diarization/PldaRho.mlmodelc",
    "speaker-diarization/plda-parameters.json",
)
MODELS: dict[str, Model] = {m.id: m for m in (
    Model("speech", "Speech models", "transcription and telling the speakers apart", "fluidaudio",
          "speaker-diarization/plda-parameters.json", 0.5, "under 1 GB while transcribing",
          local_folder=SPEECH_FOLDER),
    Model("gemma", "Gemma 4 12B", "notes and projects", GEMMA, "config.json", 8.3,
          "about 10 GB of memory while writing, up to 12 GB"),
    Model("e5", "multilingual-e5-small", "search by meaning", "intfloat/multilingual-e5-small", "config.json", 0.47,
          "little memory, in the background"),
)}
NOTES_MODELS = {GEMMA: "gemma"}  # local notes model (repo) -> its download
# No longer offered: Qwen3 30B A3B made more mistakes on German meetings than
# Gemma 4 12B, at twice the download and memory. Listed so Settings → Storage
# can delete a copy still here (#9); config.toml may still name it.
RETIRED: dict[str, Model] = {m.id: m for m in (
    Model("qwen", "Qwen3 30B A3B", "notes and projects (no longer offered)", QWEN, "config.json", 16.0,
          "18–22 GB of memory while writing"),
    # Replaced by the speech models (palaver-engine): the Parakeet MLX copy in the
    # Hugging Face cache and the pyannote copy. Never deleted by themselves.
    Model("parakeet", "Parakeet (MLX)", "transcription (replaced by the speech models)",
          "mlx-community/parakeet-tdt-0.6b-v3", "config.json", 2.3, "about 2.5 GB of memory while transcribing",
          manual=True),
    Model("pyannote", "pyannote", "telling the speakers apart (replaced by the speech models)",
          "pyannote/speaker-diarization-community-1", "config.yaml", 0.03, "about 1 GB of memory while it runs",
          local_folder="pyannote-community-1", manual=True),
    # The default transcriber until October 2026 (#8: 1.5 GB nobody saw);
    # still there for config.toml's transcriber = "mlx-whisper".
    Model("whisper", "Whisper (MLX)", "transcription (replaced by the speech models)",
          "mlx-community/whisper-large-v3-turbo", "config.json", 1.5, "used only with transcriber = mlx-whisper",
          manual=True, transcriber="mlx-whisper"),
)}


def download_size(ids: Iterable[str]) -> float:
    return sum(MODELS[i].disk_gb for i in ids)


def _gb(x: float) -> str:
    return f"{x:.1f} GB" if x < 10 and x != int(x) else f"{x:.0f} GB"


# --- what was detected ---------------------------------------------------------------------

_CHIP = re.compile(r"\bApple M(\d+)(?:\s+(Pro|Max|Ultra))?\b", re.I)


def parse_chip(brand: str) -> tuple[int, str] | None:
    """"Apple M4 Pro" -> (4, "pro"); None for an Intel Mac."""
    m = _CHIP.search(brand or "")
    return (int(m.group(1)), (m.group(2) or "base").lower()) if m else None


@dataclass(frozen=True)
class Hardware:
    chip: str  # the CPU's brand string: "Apple M4 Pro"
    memory_gb: float
    free_disk_gb: float

    @property
    def apple_silicon(self) -> bool:
        return parse_chip(self.chip) is not None

    @property
    def generation(self) -> int | None:
        parsed = parse_chip(self.chip)
        return parsed[0] if parsed else None

    @property
    def tier(self) -> str | None:
        parsed = parse_chip(self.chip)
        return parsed[1] if parsed else None

    @property
    def short(self) -> str:
        """"M4 Pro", or the brand string of an Intel Mac."""
        return self.chip.removeprefix("Apple ").strip() or "this Mac"

    @property
    def fingerprint(self) -> str:
        """What a change of Mac changes: the chip and the memory, not the free disk."""
        return f"{self.chip}, {self.memory_gb:.0f} GB"


@dataclass(frozen=True)
class Installed:
    teams: bool = False
    slack: bool = False
    claude_code: bool = False
    claude_desktop: bool = False


@dataclass(frozen=True)
class ProviderInfo:
    label: str
    uses: frozenset[str]
    ready: bool
    problem: str | None = None


@dataclass(frozen=True)
class Registry:
    """providers.FEATURES x providers.PROVIDERS, as the recommendations read them."""
    features: dict[str, str]  # feature -> the kind of provider it uses
    providers: dict[str, ProviderInfo]

    def features_of(self, kind: str) -> tuple[str, ...]:
        return tuple(f for f, k in self.features.items() if k == kind)

    def providers_of(self, kind: str) -> list[str]:
        return [pid for pid, p in self.providers.items() if kind in p.uses]

    def ready_of(self, kind: str) -> list[str]:
        return [pid for pid in self.providers_of(kind) if self.providers[pid].ready]


@dataclass(frozen=True)
class Current:
    """What is set now."""
    settings: dict[str, bool] = field(default_factory=dict)  # settings.json's switches
    choices: dict[str, str] = field(default_factory=dict)  # feature -> "local" or a provider id
    local_model: str = GEMMA
    downloaded: frozenset[str] = frozenset()  # MODELS on this Mac
    registry: Registry = field(default_factory=lambda: Registry({}, {}))
    mcp: dict[str, bool] = field(default_factory=dict)  # "code"/"desktop" -> starts Palaver's MCP server
    chosen: frozenset[str] = frozenset()  # recommendation ids the user set on purpose (settings.json, config.toml)


# --- recommendations -------------------------------------------------------------------------

@dataclass(frozen=True)
class Option:
    value: Any
    label: str
    note: str = ""
    available: bool = True  # False: can't run here, or not set up (the note says why)


@dataclass(frozen=True)
class Recommendation:
    id: str
    step: str  # the assistant's step it belongs to
    title: str
    value: Any  # recommended
    label: str
    reason: str
    current: Any
    options: tuple[Option, ...] = ()
    needs_setup: bool = False  # the recommended choice needs something set up first (a cloud model's key)
    downloads: tuple[str, ...] = ()  # MODELS the recommended choice needs that are not here yet
    features: tuple[str, ...] = ()  # the provider features this choice sets
    chosen: bool = False  # the current value was set on purpose: re-opening the assistant keeps it

    @property
    def matches(self) -> bool:
        return self.current == self.value

    def to_dict(self) -> dict[str, Any]:
        out = asdict(self)
        out["options"] = [asdict(o) for o in self.options]
        out["downloads"] = list(self.downloads)
        out["features"] = list(self.features)
        out["matches"] = self.matches
        return out


_ON_OFF = (Option(True, "On"), Option(False, "Off"))


def _pick_cloud(ready: list[str], current: Any) -> str | None:
    """The cloud provider to recommend: the one already chosen, else the
    Claude Code CLI (it needs no key), else the first one set up."""
    if current in ready:
        return current
    if "claude-cli" in ready:
        return "claude-cli"
    return ready[0] if ready else None


def _provider_options(reg: Registry, kind: str) -> list[Option]:
    return [Option(pid, reg.providers[pid].label, "Ready" if reg.providers[pid].ready else
                   (reg.providers[pid].problem or "Not set up"), reg.providers[pid].ready)
            for pid in reg.providers_of(kind)]


def _transcription(hw: Hardware, cur: Current) -> Recommendation:
    reg = cur.registry
    features = reg.features_of(TRANSCRIPTION)
    now = cur.choices.get(features[0], LOCAL) if features else LOCAL
    speech = MODELS["speech"]
    local = Option(LOCAL, "Parakeet on this Mac",
                   f"Nothing leaves the Mac. A {_gb(speech.disk_gb)} download." if hw.apple_silicon
                   else "Needs Apple Silicon.", hw.apple_silicon)
    options = (local, *_provider_options(reg, TRANSCRIPTION))
    needed = tuple(m for m in ("speech",) if m not in cur.downloaded) if hw.apple_silicon else ()
    if hw.apple_silicon:
        return Recommendation(
            "transcription", "models", "Transcription", LOCAL, local.label,
            "Parakeet runs on any Apple Silicon Mac (about a minute per hour of audio for each track on an "
            "M4 Pro), with under 1 GB of memory while it runs. The same download tells the speakers apart. "
            "Nothing leaves the Mac.",
            now, options, downloads=needed, features=features)
    return Recommendation("transcription", "models", "Transcription", now, UNSUPPORTED,
                          INTEL.format(short=hw.short), now, options, features=features)


def _local_option(hw: Hardware, repo: str, cur: Current) -> Option:
    from .llm import LOCAL_MODELS

    info = LOCAL_MODELS.get(repo, {})
    model = MODELS[NOTES_MODELS[repo]]
    free = notes.MODEL_MEMORY_GB.get(repo, notes.NOTES_MEMORY_GB)
    label = f"{info.get('label', model.label)} on this Mac"
    if not hw.apple_silicon:
        return Option(f"{LOCAL}:{repo}", label, "Needs Apple Silicon.", False)
    if hw.memory_gb < free:
        return Option(f"{LOCAL}:{repo}", label,
                      f"Needs {_gb(free)} of free memory; this Mac has {_gb(hw.memory_gb)} in all.", False)
    note = f"Uses {model.memory}; notes wait until {_gb(free)} are free."
    if hw.memory_gb - OTHER_APPS_GB < free:
        note += f" With {_gb(hw.memory_gb)}, that means closing most other apps."
    if model.id not in cur.downloaded:
        note += f" A {_gb(model.disk_gb)} download."
    if info.get("note"):
        note += f" {info['note']}"
    return Option(f"{LOCAL}:{repo}", label, note)


PENDING_LABEL = "None yet: set up a cloud model"


def download_note(mid: str, hw: Hardware) -> str:
    """The catch of a local notes model on a Mac too small for it."""
    repo = next((r for r, m in NOTES_MODELS.items() if m == mid), None)
    if repo is None:
        return ""
    free = notes.MODEL_MEMORY_GB.get(repo, notes.NOTES_MEMORY_GB)
    if hw.memory_gb - OTHER_APPS_GB >= free:
        return ""
    return f"needs {_gb(free)} free while writing; this Mac has {_gb(hw.memory_gb)}"


def _language_model(hw: Hardware, cur: Current, room_gb: float) -> Recommendation:
    reg = cur.registry
    features = reg.features_of(LANGUAGE_MODEL) or ("notes", "projects")
    chosen = cur.choices.get(features[0], LOCAL)
    now = f"{LOCAL}:{cur.local_model}" if chosen == LOCAL else chosen
    options = (*(_local_option(hw, repo, cur) for repo in NOTES_MODELS), *_provider_options(reg, LANGUAGE_MODEL),
               Option(PENDING, PENDING_LABEL, "Notes are off until you set up a cloud model in Settings."))
    gemma = MODELS["gemma"]
    free = notes.MODEL_MEMORY_GB[GEMMA]
    fits = hw.apple_silicon and hw.memory_gb - OTHER_APPS_GB >= free
    on_disk = "gemma" in cur.downloaded or room_gb >= gemma.disk_gb + DISK_RESERVE_GB
    if fits and on_disk:
        return Recommendation(
            LANGUAGE_MODEL, "models", "Notes and projects", f"{LOCAL}:{GEMMA}", "Gemma 4 12B on this Mac",
            f"With {_gb(hw.memory_gb)} of memory, Gemma 4 12B fits next to your other apps: it uses about "
            f"10 GB while writing (up to 12 GB), and notes are written after the call once {_gb(free)} are free. "
            "It was the most accurate model on German meetings, and nothing leaves the Mac.",
            now, options, downloads=() if "gemma" in cur.downloaded else ("gemma",), features=features)
    if not hw.apple_silicon:
        return Recommendation(LANGUAGE_MODEL, "models", "Notes and projects", now, UNSUPPORTED,
                              INTEL.format(short=hw.short), now, options, features=features)
    cloud = _pick_cloud(reg.ready_of(LANGUAGE_MODEL), chosen)
    if not fits:
        why = (f"Your Mac has {_gb(hw.memory_gb)} of memory. Gemma 4 12B uses about 10 GB while writing (up to "
               f"12 GB) and waits for {_gb(free)} free, so notes would wait for memory that rarely frees up next "
               "to your other apps. Small local models wrote clearly worse notes in our tests, so we don't offer "
               "one.")
    else:
        why = (f"Gemma 4 12B is an {_gb(gemma.disk_gb)} download, and this Mac has {hw.free_disk_gb:.0f} GB free "
               f"(Palaver keeps {_gb(DISK_RESERVE_GB)} for recordings). Free up space first, or use a cloud model.")
    then = (" A cloud model writes them right after the call; it gets the transcript, and a meeting you keep "
            "on this Mac never goes there.")
    label = reg.providers[cloud].label if cloud else PENDING_LABEL
    if not cloud:
        then += (" None is set up yet: until you set one up in Settings → Language model, notes are off "
                 "(no model on this Mac writes them).")
    return Recommendation(LANGUAGE_MODEL, "models", "Notes and projects", cloud or PENDING, label, why + then,
                          now, options, needs_setup=cloud is None, features=features)


def _fast(hw: Hardware) -> bool:
    gen, tier = hw.generation, hw.tier
    return gen is not None and (gen >= 3 or (gen == 2 and tier != "base"))


def _realtime(hw: Hardware, cur: Current) -> Recommendation:
    now = cur.settings.get("realtime", True)
    if not hw.apple_silicon:
        value, why = False, "Realtime transcription runs Parakeet on this Mac, which needs Apple Silicon."
    elif hw.memory_gb < REALTIME_MIN_MEMORY_GB:
        value, why = False, (f"Your Mac has {_gb(hw.memory_gb)} of memory: realtime transcription adds about "
                             f"{STREAM_GB} GB during calls, next to the call itself. Text then appears about a "
                             "minute after it is said instead of a few seconds.")
    elif not _fast(hw):
        value, why = False, (f"The {hw.short} is below an M2 Pro: realtime transcription keeps a CPU core busy "
                             "during calls and would compete with the call. Text then appears about a minute "
                             "after it is said instead of a few seconds.")
    else:
        value, why = True, (f"The {hw.short} with {_gb(hw.memory_gb)} has room for it: realtime transcription "
                            f"adds about {STREAM_GB} GB and a CPU core during calls, and text appears a few "
                            "seconds after it is said.")
    return Recommendation("realtime", "calls", "Realtime transcription", value, "On" if value else "Off", why,
                          now, _ON_OFF)


def _live(hw: Hardware, cur: Current) -> Recommendation:
    now = cur.settings.get("live_processing", True)
    if hw.apple_silicon and hw.memory_gb >= LIVE_MIN_MEMORY_GB:
        value, why = True, (f"Transcribes and tells speakers apart during the call, in the background (about "
                            f"{LIVE_WORKER_GB} GB), so a meeting is ready seconds after it ends instead of "
                            f"minutes. {_gb(hw.memory_gb)} has room for that.")
    else:
        value, why = False, (f"With {_gb(hw.memory_gb)} of memory, the {LIVE_WORKER_GB} GB it needs during a "
                             "call would compete with the call. Meetings are transcribed after the call "
                             "instead: about 6 minutes per hour of meeting.")
    return Recommendation("live_processing", "calls", "Processing during calls", value,
                          "During the call" if value else "After the call", why, now,
                          (Option(True, "During the call"), Option(False, "After the call")))


def _search(cur: Current, room_gb: float) -> Recommendation:
    now = cur.settings.get("search_meaning", True)
    e5 = MODELS["e5"]
    here = "e5" in cur.downloaded
    if here or room_gb >= e5.disk_gb + DISK_RESERVE_GB:
        return Recommendation(
            "search_meaning", "models", "Search by meaning", True, "On",
            "Finds meetings about what you search for in other words or another language. Meetings are "
            f"indexed in the background when no call is recorded{'' if here else '; its model is a 470 MB download'}.",
            now, _ON_OFF, downloads=() if here else ("e5",))
    return Recommendation("search_meaning", "models", "Search by meaning", False, "Off",
                          "There is not enough free disk for its 470 MB model; turn it on after freeing space.",
                          now, _ON_OFF)


_APPS = {"teams": "Microsoft Teams", "slack": "Slack"}


def _record(app: str, installed: bool, cur: Current) -> Recommendation:
    key = f"record_{app}"
    now = cur.settings.get(key, True)
    what = "calls" if app == "teams" else "huddles"
    if installed:
        value, why = True, (f"{_APPS[app]} is installed: Palaver starts recording when a {what[:-1]} starts and "
                            "stops when it ends. You can also start a recording yourself in the menu bar.")
    else:
        value, why = now, f"{_APPS[app]} is not installed on this Mac; this applies once it is."
    return Recommendation(key, "record", f"Record {_APPS[app]} {what} automatically", value,
                          "On" if value else "Off", why, now, _ON_OFF)


_CLAUDE = {"code": "Claude Code", "desktop": "Claude Desktop"}


def _claude(target: str, installed: bool, cur: Current) -> Recommendation:
    now = bool(cur.mcp.get(target))
    name = _CLAUDE[target]
    if installed:
        why = (f"{name} is installed. With Palaver added, Claude can search and read your meetings, notes and "
               "transcripts, except meetings kept on this Mac. Every read is in the access log in Settings.")
    else:
        why = f"{name} is not installed on this Mac."
    return Recommendation(f"claude_{target}", "claude", f"Add Palaver to {name}", installed or now,
                          "Add" if installed else "Not installed", why, now,
                          (Option(True, "Add", available=installed or now), Option(False, "Leave out")))


def recommend(hw: Hardware, installed: Installed, cur: Current) -> list[Recommendation]:
    """What to choose on this Mac, and why; one Recommendation per choice."""
    tr = _transcription(hw, cur)
    room = hw.free_disk_gb - download_size(tr.downloads)
    lm = _language_model(hw, cur, room)
    room -= download_size(lm.downloads)
    search = _search(cur, room)
    out = [tr, lm, search, _realtime(hw, cur), _live(hw, cur),
           _record("teams", installed.teams, cur), _record("slack", installed.slack, cur),
           _claude("code", installed.claude_code, cur), _claude("desktop", installed.claude_desktop, cur)]
    wanted = download_size({m for r in out for m in r.downloads}) + DISK_RESERVE_GB
    if hw.free_disk_gb < wanted:
        short = round(wanted - hw.free_disk_gb, 1)
        out.append(Recommendation(
            "disk", "models", "Free disk space", short, f"Free {_gb(short)}",
            f"The models above need {_gb(wanted - DISK_RESERVE_GB)} and Palaver keeps {_gb(DISK_RESERVE_GB)} "
            f"free for recordings; this Mac has {hw.free_disk_gb:.0f} GB free. Free up {_gb(short)}, e.g. with "
            "`palaver prune` or by emptying the Trash.", 0.0))
    return [replace(r, chosen=r.id in cur.chosen) for r in out]


def profile_table(profiles: Iterable[tuple[str, float, float]], cur: Current,
                  installed: Installed = Installed()) -> list[str]:
    """One line per (chip, memory GB, free disk GB): what is recommended."""
    rows = []
    for chip, memory, disk in profiles:
        r = {x.id: x for x in recommend(Hardware(chip, memory, disk), installed, cur)}
        lm = r[LANGUAGE_MODEL]
        notes_text = "Gemma local" if lm.value == f"{LOCAL}:{GEMMA}" else (
            "none yet: set up a cloud model" if lm.needs_setup else f"cloud: {lm.label}")
        parts = [f"transcription {'Parakeet local' if r['transcription'].value == LOCAL else r['transcription'].label}",
                 f"notes {notes_text}",
                 f"realtime {'on' if r['realtime'].value else 'off'}",
                 f"live processing {'on' if r['live_processing'].value else 'off'}",
                 f"search {'on' if r['search_meaning'].value else 'off'}"]
        if "disk" in r:
            parts.append(f"free {_gb(r['disk'].value)}")
        rows.append(f"{chip}, {memory:.0f} GB, {disk:.0f} GB free: " + " · ".join(parts))
    return rows


# --- when to offer the assistant ----------------------------------------------------------------

def offer(state: dict | None, fingerprint: str, *, has_meetings: bool, missing: list[str]) -> dict | None:
    """Whether the window opens the assistant: on the first start (no
    meetings yet: an existing user opens it from Settings), when this is
    another Mac than the one it was set up on, or when a model the choices
    need is missing. ``state``: settings.json's "setup"."""
    if not state:
        if not has_meetings:
            return {"why": "first"}
        # An existing user who never ran the assistant is not asked to; but their meetings
        # wait for the speech models, which they must be told about (the others stay as they were).
        speech = [m for m in missing if m == "speech"]
        return {"why": "missing", "models": speech} if speech else None
    if state.get("hardware") and state["hardware"] != fingerprint:
        return {"why": "changed", "was": state["hardware"], "now": fingerprint}
    if state.get("done") and missing:
        return {"why": "missing", "models": list(missing)}
    return None


def fetch_missing_speech(probe) -> bool:
    """Start downloading the speech models if they are not here. Every
    meeting waits for them and there is nothing to choose (0.5 GB), so a
    copy that is missing (an update from pyannote, a deleted folder) is
    fetched at once instead of waiting for someone to find it in Settings.
    True when a download was started."""
    if not probe.hardware().apple_silicon or "speech" in probe.downloaded():
        return False
    probe.downloads.start(["speech"])
    return True


def missing_models(cur: Current, hw: Hardware) -> list[str]:
    """The models the current choices need that are not downloaded (the
    search model downloads by itself)."""
    if not hw.apple_silicon:
        return []
    need = ["speech"]  # transcription and the speakers: with a cloud service, the speakers still
    lm = cur.registry.features_of(LANGUAGE_MODEL) or ("notes",)
    if cur.choices.get(lm[0], LOCAL) == LOCAL and cur.local_model in NOTES_MODELS:
        need.append(NOTES_MODELS[cur.local_model])
    return [m for m in need if m not in cur.downloaded]


# --- prefill from the calendar -----------------------------------------------------------------

# Words in meeting titles that are no names, however rare.
_TITLE_STOP = {"standup", "stand-up", "weekly", "daily", "sync", "jour", "fixe", "meeting", "call", "review",
               "planning", "retro", "kickoff", "kick-off", "intro", "onboarding", "workshop", "update", "lunch",
               "abstimmung", "besprechung", "termin", "teams"}
_TITLE_WORD = re.compile(r"\b[A-ZÄÖÜ][\wÄÖÜäöüß-]{3,}\b")
TITLE_ZIPF = 3.0  # a title word this rare is likely a name (a customer, a project)
MAX_SEED_TERMS = 30


def own_organization(events) -> str | None:
    """The user's organization, from their own address in the calendar."""
    from .organizations import default_name, org_key

    for e in events:
        for a in e.attendees:
            key = org_key(a.email) if a.is_self else None
            if key and key != "extern":
                return default_name(key)
    return None


def seed_terms(events, *, user_name: str, known: Iterable[str] = ()) -> list[dict[str, Any]]:
    """Glossary terms the calendar suggests, so names are spelled right
    from the first meeting: invitees, their organizations (from the email
    domain) and rare words in event titles (a customer, a project). The
    user, their own organization and terms already known are left out."""
    from .calendar_events import looks_like_room
    from .glossary import zipf
    from .organizations import default_name, org_key

    skip = {k.casefold() for k in known} | {user_name.casefold()}
    own = next((org_key(a.email) for e in events for a in e.attendees if a.is_self and a.email), None)
    found: dict[str, dict[str, Any]] = {}

    def add(term: str, kind: str, seen: set[str]):
        key = term.casefold()
        if key in skip or key in seen:
            return
        seen.add(key)
        entry = found.setdefault(key, {"term": term, "kind": kind, "count": 0})
        entry["count"] += 1

    for e in events:
        seen: set[str] = set()
        for a in e.attendees:
            if a.is_self or a.is_room or not a.email or looks_like_room(a.name):
                continue
            if len(a.name.split()) >= 2 and "@" not in a.name:
                add(a.name.strip(), "person", seen)
            key = org_key(a.email)
            if key and key not in ("extern", own):
                add(default_name(key), "organization", seen)
        for word in _TITLE_WORD.findall(e.title or ""):
            if word.casefold() not in _TITLE_STOP and word.casefold() not in found and zipf(word) < TITLE_ZIPF:
                add(word, "title", seen)
    order = {"person": 0, "organization": 1, "title": 2}
    return sorted(found.values(), key=lambda t: (-t["count"], order[t["kind"]], t["term"]))[:MAX_SEED_TERMS]


# --- the summary: `palaver doctor` in the window -----------------------------------------------------

_PERMISSIONS = [("Microphone", "microphone"), ("System audio", "system_audio"), ("Calendar", "calendar"),
                ("Notifications", "notifications")]
_PRIVACY = "System Settings → Privacy & Security → "
_FIXES = {
    "microphone": {"not_asked": "macOS asks on the first recording, or when you run the test recording",
                   "denied": _PRIVACY + "Microphone → allow Palaver"},
    "system_audio": {"unverified": "checked on the first recording, or run the test recording",
                     "denied": _PRIVACY + "Screen & System Audio Recording → under System Audio Recording Only, "
                                          "allow Palaver"},
    "calendar": {"not_asked": "Connect Calendar in Settings or in the setup assistant",
                 "denied": _PRIVACY + "Calendars → allow Palaver (full access)"},
    "notifications": {"unknown": "System Settings → Notifications → Palaver: allow notifications",
                      "not_asked": "macOS asks when Palaver starts; or System Settings → Notifications → Palaver",
                      "denied": "System Settings → Notifications → Palaver: allow notifications"},
}
_STATUS = {"granted": "ok", "denied": "fail", "fallback": "warn"}


def _model_check(m: Model, here: bool) -> Check:
    if here:
        return Check(m.label, "ok", f"downloaded ({m.purpose})")
    return Check(m.label, "warn", f"not downloaded yet ({m.purpose})",
                 f"download it in the setup assistant ({_gb(m.disk_gb)}), or it downloads when first needed")


def _provider_check(name: str, cur: Current, pid: str) -> Check:
    p = cur.registry.providers.get(pid)
    if p is None:
        return Check(name, "fail", f"{pid}: not a provider", "choose again in Settings")
    if p.ready:
        return Check(name, "ok", f"{p.label} (cloud)")
    return Check(name, "fail", f"{p.label}: {p.problem or 'not set up'}", "Settings → Language model")


def summary(hw: Hardware, permissions: dict[str, dict], installed: Installed, cur: Current) -> list[Check]:
    """What is set up, what is missing, and the fix for each."""
    out = []
    mac = f"{hw.short}, {_gb(hw.memory_gb)} of memory"
    if hw.apple_silicon:
        out.append(Check("This Mac", "ok", mac))
    else:
        out.append(Check("This Mac", "fail", mac, "local models need Apple Silicon; choose cloud services in Settings"))
    for name, key in _PERMISSIONS:
        p = permissions.get(key)
        if p is None:
            continue
        state = p.get("state", "unknown")
        out.append(Check(name, _STATUS.get(state, "warn"), p.get("detail") or state.replace("_", " "),
                         p.get("fix") or _FIXES.get(key, {}).get(state, "")))
    if hw.apple_silicon:
        tr = cur.registry.features_of(TRANSCRIPTION)
        chosen = cur.choices.get(tr[0], LOCAL) if tr else LOCAL
        if chosen != LOCAL:
            out.append(_provider_check("Transcription", cur, chosen))
        out.append(_model_check(MODELS["speech"], "speech" in cur.downloaded))
    lm = cur.registry.features_of(LANGUAGE_MODEL) or ("notes",)
    chosen = cur.choices.get(lm[0], LOCAL)
    if chosen == LOCAL:
        mid = NOTES_MODELS.get(cur.local_model)
        if mid is None:
            out.append(Check("Notes and projects", "ok", f"{cur.local_model} on this Mac (set in config.toml)"))
        else:
            m = MODELS[mid]
            if mid in cur.downloaded:
                out.append(Check("Notes and projects", "ok", f"{m.label} on this Mac"))
            else:
                out.append(Check("Notes and projects", "warn", f"{m.label} on this Mac, not downloaded yet",
                                 f"download it in the setup assistant ({_gb(m.disk_gb)})"))
    elif chosen == PENDING:
        out.append(Check("Notes and projects", "warn", "none yet: notes are off until a cloud model is set up",
                         "Settings → Language model"))
    else:
        out.append(_provider_check("Notes and projects", cur, chosen))
    for target, there in (("code", installed.claude_code), ("desktop", installed.claude_desktop)):
        if there:
            out.append(Check(f"{_CLAUDE[target]} access", "ok" if cur.mcp.get(target) else "warn",
                             "can read your meetings" if cur.mcp.get(target) else "Palaver is not added yet",
                             "" if cur.mcp.get(target) else "Settings → Claude access → Add"))
    out.append(check_disk(Path.home(), free_bytes=int(hw.free_disk_gb * 1024**3)))
    return out


# --- the test recording ------------------------------------------------------------------------------

SPEECH_DB = -50.0  # louder than this on the mic track: someone spoke
QUIET_DB = -60.0  # quieter than this on the system track: nothing played


def _heard(mic: dict) -> Check:
    text = (mic.get("text") or "").strip()
    how = mic.get("transcript")
    if text:
        return Check("Microphone", "ok", f"heard you: “{text}”")
    if how == "not_downloaded":
        return Check("Microphone", "ok", "heard you (levels only: the speech models are not downloaded yet, so no words)",
                     "download the speech models in the Downloads step to see the words next time")
    if how == "cloud":
        return Check("Microphone", "ok", f"heard you (levels only: {mic.get('service') or 'your transcription service'} "
                                         "transcribes your calls, and transcription is skipped in the test)")
    return Check("Microphone", "ok", "heard you")


def test_verdict(result: dict) -> list[Check]:
    """What the test recording found on each track."""
    mic, system = result.get("mic") or {}, result.get("system") or {}
    if not mic.get("recorded"):
        mic_check = Check("Microphone", "fail", "nothing was recorded", _FIXES["microphone"]["denied"])
    elif (mic.get("level_db") or -120.0) > SPEECH_DB or mic.get("text"):
        mic_check = _heard(mic)
    else:
        mic_check = Check("Microphone", "warn", "the microphone track is silent",
                          "check the input device in System Settings → Sound → Input, then try again")
    if not system.get("recorded"):
        sys_check = Check("System audio", "fail", "not recorded", _FIXES["system_audio"]["denied"])
    elif system.get("level_db") is None or system["level_db"] < QUIET_DB:
        sys_check = Check("System audio", "ok", "recorded; quiet, as nothing played")
    else:
        sys_check = Check("System audio", "ok", "recorded, with sound from other apps")
    return [mic_check, sys_check]


# A meeting goes first: the daemon holds this gate while it starts a
# recording; a running test recording is stopped (its audio discarded) and
# none starts until the meeting records. The menu bar app runs the daemon
# and the window in one process, so this is all it takes there.
_GATE = threading.Lock()
_ACTIVE: set["TestRecording"] = set()
_ACTIVE_LOCK = threading.Lock()
ABORTED = "A call started, so the test stopped; nothing was kept. Try again after the call."


@contextlib.contextmanager
def meeting_starting():
    """Held around a meeting recording's start (daemon._start)."""
    with _GATE:
        with _ACTIVE_LOCK:
            running = list(_ACTIVE)
        for test in running:
            test.abort()
        yield


class TestRecording:
    """The optional test recording: only ever started by the user's click,
    stopped by their click, after MAX_SECONDS or by a meeting starting;
    never while a meeting is recorded. ``capture(folder)`` starts recording
    both tracks into ``folder`` and returns a stop function that returns
    (mic WAV, system WAV); ``analyze(mic, system, mode)`` returns the result
    test_verdict reads; ``mode`` says whether and how it may transcribe
    (never with a download)."""

    __test__ = False  # not a pytest class
    MAX_SECONDS = 20.0

    def __init__(self, capture: Callable[[Path], Callable[[], tuple[Path | None, Path | None]]] | None = None,
                 analyze: Callable[[Path | None, Path | None, dict], dict] | None = None):
        self._capture = capture or _capture_both
        self._analyze = analyze or _analyze
        self._lock = threading.Lock()
        self._state = "idle"
        self._started = 0.0
        self._stop: Callable | None = None
        self._folder: Path | None = None
        self._mode: dict = {}
        self._result: dict | None = None
        self._error: str | None = None
        self._timer: threading.Timer | None = None

    def start(self, *, busy: Callable[[], bool] | bool = False, mode: dict | None = None) -> dict:
        if not _GATE.acquire(blocking=False):  # a meeting is starting right now
            raise ValueError("a meeting is being recorded; try the test after it")
        try:
            with self._lock:
                if busy() if callable(busy) else busy:
                    raise ValueError("a meeting is being recorded; try the test after it")
                if self._state in ("recording", "checking"):
                    return self._status()
                self._folder = Path(tempfile.mkdtemp(prefix="palaver-test-"))
                try:
                    self._stop = self._capture(self._folder)
                except Exception as exc:
                    shutil.rmtree(self._folder, ignore_errors=True)
                    self._state, self._error, self._result = "failed", f"could not start recording: {exc}", None
                    return self._status()
                self._state, self._started, self._result, self._error = "recording", time.monotonic(), None, None
                self._mode = dict(mode or {})
                with _ACTIVE_LOCK:
                    _ACTIVE.add(self)
                self._timer = threading.Timer(self.MAX_SECONDS, self.stop)
                self._timer.daemon = True
                self._timer.start()
                return self._status()
        finally:
            _GATE.release()

    def _take(self, state: str):
        """Leave "recording" for ``state``; the stop function and folder, or None."""
        with self._lock:
            if self._state != "recording":
                return None
            if self._timer:
                self._timer.cancel()
            self._state = state
            with _ACTIVE_LOCK:
                _ACTIVE.discard(self)
            return self._stop, self._folder

    def stop(self) -> dict:
        taken = self._take("checking")
        if taken:
            threading.Thread(target=self._finish, args=taken, daemon=True).start()
        return self.status()

    def abort(self) -> None:
        """A meeting starts: stop at once, check nothing, keep nothing."""
        taken = self._take("aborted")
        if not taken:
            return
        stop, folder = taken
        try:
            stop()
        except Exception:
            pass
        finally:
            shutil.rmtree(folder, ignore_errors=True)
        with self._lock:
            self._error = ABORTED

    def _finish(self, stop, folder: Path) -> None:
        try:
            mic, system = stop()
            result = self._analyze(mic, system, self._mode)
            error = None
        except Exception as exc:
            result, error = None, f"the test failed: {exc}"
        finally:
            shutil.rmtree(folder, ignore_errors=True)  # the test's audio is never kept
        with self._lock:
            self._state = "failed" if error else "done"
            self._result, self._error = result, error

    def _status(self) -> dict:
        out: dict[str, Any] = {"state": self._state, "max_seconds": self.MAX_SECONDS}
        if self._state == "recording":
            out["seconds"] = round(time.monotonic() - self._started, 1)
        if self._result is not None:
            out["checks"] = [asdict(c) for c in test_verdict(self._result)]
        if self._error:
            out["error"] = self._error
        return out

    def status(self) -> dict:
        with self._lock:
            return self._status()


def _capture_both(folder: Path):
    """Record both tracks into ``folder`` the way a meeting is recorded, but
    without a session.log: its lines never mix with a meeting's."""
    from . import session as session_mod
    from .paths import RecordingPaths

    rec = session_mod.RecordingSession(folder, trigger="test", log=False)
    recording = rec.start()

    def stop() -> tuple[Path | None, Path | None]:
        rec.stop()
        paths = RecordingPaths(recording)
        mic = paths.mic_raw_wav if paths.mic_raw_wav.exists() else None
        system = paths.system_wav if paths.system_wav.exists() else None
        return mic, system

    return stop


def level_db(wav: Path | None) -> float | None:
    """The track's loudness (RMS, dBFS); None when it has no audio."""
    if wav is None or not Path(wav).exists():
        return None
    import numpy as np
    import soundfile as sf

    data, _ = sf.read(str(wav), dtype="float32", always_2d=True)
    if not len(data):
        return None
    rms = float(np.sqrt(np.mean(np.square(data))))
    return round(20 * np.log10(max(rms, 1e-6)), 1)


def _analyze(mic: Path | None, system: Path | None, mode: dict) -> dict:
    """The levels of both tracks, and the mic track's words when Parakeet
    is on this Mac (never downloaded for the test). With a cloud
    transcription service chosen, levels only: the test sends nothing."""
    out_mic: dict[str, Any] = {"recorded": mic is not None, "level_db": level_db(mic), "text": None}
    if mic is not None and (out_mic["level_db"] or -120) > SPEECH_DB:
        if mode.get("transcribe") == "cloud":
            out_mic.update(transcript="cloud", service=mode.get("service"))
        else:
            if not speech_here():
                out_mic["transcript"] = "not_downloaded"
            else:
                out_mic["text"] = _transcribe(mic)
                out_mic["transcript"] = "done" if out_mic["text"] else "failed"
    return {"mic": out_mic, "system": {"recorded": system is not None, "level_db": level_db(system)}}


def _transcribe(wav: Path) -> str | None:
    """The mic track's words, through the speech engine (its own process, ended
    after): the models are there (``speech_here``), nothing is downloaded."""
    from .dictionary import Dictionary
    from .engine import Engine, EngineError
    from .transcriber import EngineTranscriber

    engine = Engine(idle_timeout=120)
    try:
        segments = EngineTranscriber(Dictionary(), engine=engine).transcribe(wav)
    except (EngineError, OSError):
        return None
    finally:
        engine.close()
    return " ".join(x.text.strip() for x in segments).strip() or None


# --- downloads ---------------------------------------------------------------------------------------

def _hub_cache() -> Path:
    hub = os.environ.get("HF_HUB_CACHE") or Path(os.environ.get("HF_HOME") or Path.home() / ".cache" / "huggingface") / "hub"
    return Path(hub)


def _cache_dir(repo: str) -> Path:
    return _hub_cache() / ("models--" + repo.replace("/", "--"))


def cached_bytes(repo: str) -> int:
    """What of ``repo`` is in the Hugging Face cache, partial files included."""
    blobs = _cache_dir(repo) / "blobs"
    try:
        return sum(f.stat().st_size for f in blobs.iterdir() if f.is_file())
    except OSError:
        return 0


def snapshot_complete(repo: str, revision: str) -> bool:
    """Whether the snapshot of ``repo`` at ``revision`` has every file an MLX
    model needs, read from disk only (offline): config.json, no file whose blob
    is gone, and every weights shard its index names (or one model*.safetensors
    without an index). A download cut short leaves a snapshot without them:
    huggingface_hub links a file into it only once the file is complete."""
    snap = _cache_dir(repo) / "snapshots" / revision
    try:
        if not (snap / "config.json").is_file() or any(f.is_symlink() and not f.exists() for f in snap.rglob("*")):
            return False
        index = snap / "model.safetensors.index.json"
        if index.exists():
            shards = set(json.loads(index.read_text()).get("weight_map", {}).values())
            return bool(shards) and all((snap / s).is_file() for s in shards)
        return any(f.is_file() for f in snap.glob("model*.safetensors"))
    except (OSError, ValueError, AttributeError):
        return False


def complete(repo: str, probe: str = "config.json") -> bool:
    """Whether ``repo`` is fully downloaded: no partial blob, and a snapshot
    (huggingface_hub's cache scan) with ``probe`` whose every file is there."""
    folder = _cache_dir(repo)
    blobs = folder / "blobs"
    try:
        if not blobs.is_dir() or any(b.name.endswith(".incomplete") for b in blobs.iterdir()):
            return False
        for snap in (folder / "snapshots").iterdir():  # a file whose blob is gone: not complete
            if any(f.is_symlink() and not f.exists() for f in snap.rglob("*")):
                return False
        from huggingface_hub import scan_cache_dir

        info = scan_cache_dir(_hub_cache())
    except Exception:
        return False
    for r in info.repos:
        if r.repo_id != repo or r.repo_type != "model":
            continue
        for rev in r.revisions:
            names = {f.file_name for f in rev.files}
            if probe in names and all(f.blob_path.exists() and f.size_on_disk > 0 for f in rev.files):
                return True
    return False


def speech_files_here() -> bool:
    """Every file of the speech models is on this Mac: the cheap check, a
    fallback for when the engine is not built."""
    from . import install_layout

    root = install_layout.models_dir() / SPEECH_FOLDER
    return all((root / f).exists() for f in SPEECH_FILES)


SPEECH_CACHE_SECONDS = 30.0
_speech_cache: dict[str, Any] = {}


def speech_here() -> bool:
    """Whether the speech models are ready. The files say no for certain; when
    they are all there, the engine (``hello``, its own ModelStore rule) has the
    last word. Without an engine binary the files decide; an engine that
    crashes on ``hello`` means not ready. Remembered for 30 s so the pages and
    the daemon's poll don't start an engine each (``speech_here.cache_clear()``)."""
    from . import install_layout

    key = str(install_layout.models_dir())
    now = time.monotonic()
    hit = _speech_cache.get(key)
    if hit is not None and now - hit[0] < SPEECH_CACHE_SECONDS:
        return hit[1]
    ready = _speech_ready()
    _speech_cache[key] = (now, ready)
    return ready


speech_here.cache_clear = _speech_cache.clear  # type: ignore[attr-defined]


def _speech_ready() -> bool:
    if not speech_files_here():
        return False
    from .engine import Engine, EngineError, engine_path

    try:
        built = engine_path().exists()
    except EngineError:
        built = False
    if not built:  # no engine binary: the files decide
        return True
    engine = Engine(idle_timeout=30)
    try:
        models = engine.call("hello").get("models")
    except EngineError:
        return False
    finally:
        engine.close()
    return isinstance(models, dict) and bool(models) and all(models.values())


def repo_for(cfg, m: Model) -> str:
    """The model's repo. config.toml no longer overrides it (the old
    parakeet_repo and diarizer_repo are ignored); "speech" is not a Hugging
    Face repo, the engine knows where."""
    return m.repo


def model_here(model: Model, repo: str) -> bool:
    """Whether every file of ``model`` is on this Mac: the copy a release
    hosts (model_store), or the Hugging Face cache."""
    from . import model_store

    if model.id == "speech":
        return speech_here()
    if model.hosted and model_store.local_path(repo) is not None:
        return True
    return complete(repo, model.probe)


def download_progress(repo: str) -> int:
    """Bytes of ``repo`` here so far: its hosted copy's download, else the cache's."""
    from . import model_store

    name = model_store.HOSTED.get(repo)
    if name is not None and model_store.partial_bytes(name):
        return model_store.partial_bytes(name)
    return cached_bytes(repo)


def downloads_running(marker: Path) -> bool:
    """Whether the window's server downloads models now (its marker, with a live pid)."""
    try:
        pid = int(marker.read_text().strip())
        os.kill(pid, 0)
    except PermissionError:
        return True
    except (OSError, ValueError):
        return False
    return True


# The speech models' download as one progress: each model's share of it, and
# where each phase of a model's own progress falls in that model's share.
SPEECH_SHARE = (("asr", 0.95), ("diarizer", 0.05))
SPEECH_PHASES = {"downloading": (0.0, 0.8), "compiling": (0.8, 0.95), "loading": (0.95, 1.0)}


class Downloads:
    """Model downloads the user agreed to, one after the other, in the
    background. ``fetch(model)`` downloads one (raises on failure);
    ``done(model)`` says whether every file of it is there (else it
    failed: "incomplete"); ``progress(repo)`` how many bytes are there;
    ``repo_of(model)``: its repo, as config.toml may override it. A failed
    model is tried again by starting it again."""

    def __init__(self, fetch: Callable[[Model], None] | None = None,
                 progress: Callable[[str], int] | None = None,
                 done: Callable[[Model], bool] | None = None,
                 repo_of: Callable[[Model], str] | None = None, marker: Path | None = None,
                 engine: Callable[[], Any] | None = None):
        self._repo_of = repo_of or (lambda m: m.repo)
        self._engine = engine  # makes the speech engine (an Engine); None: the real one
        self._marker = marker  # while downloading: this process's pid, for the updater (#60)
        self._fetch = fetch or self._fetch_model
        self._progress = progress or download_progress
        self._done = done or (lambda m: model_here(m, self._repo_of(m)))
        self._lock = threading.Lock()
        self._jobs: dict[str, dict[str, Any]] = {}
        self._thread: threading.Thread | None = None

    def _fetch_model(self, model: Model) -> None:
        if model.id == "speech":
            self._fetch_speech(model)
        else:
            _fetch(model, self._repo_of(model))

    def _fetch_speech(self, model: Model) -> None:
        """The engine's ``prepare``, one model after the other so each one's
        progress is known: the speech model is nearly all of the bytes, the
        diarizer's few MB the rest. Within a model, downloading is most of the
        time, then compiling, then loading. What the page shows can't go back."""
        from .engine import Engine

        engine = self._engine() if self._engine else Engine()
        done = 0.0

        def report(weight: float, offset: float):
            def on_progress(fraction: float, phase: str) -> None:
                lo, hi = SPEECH_PHASES.get(phase, (0.0, 1.0))
                inside = lo + (hi - lo) * min(1.0, max(0.0, fraction))
                self._set_fraction(model.id, offset + weight * inside)
            return on_progress

        try:
            for name, weight in SPEECH_SHARE:
                engine.call("prepare", models=[name], progress=report(weight, done))
                done += weight
                self._set_fraction(model.id, done)
        finally:
            engine.close()
            speech_here.cache_clear()

    def _set_fraction(self, mid: str, fraction: float) -> None:
        with self._lock:
            job = self._jobs.get(mid)
            if job is not None:
                job["fraction"] = max(job.get("fraction", 0.0), min(1.0, fraction))

    def start(self, ids: Iterable[str]) -> dict:
        with self._lock:
            for mid in ids:
                if mid not in MODELS:
                    raise ValueError(f"no model {mid!r}")
                if self._jobs.get(mid, {}).get("state") not in ("queued", "downloading", "done"):
                    self._jobs[mid] = {"state": "queued", "error": None, "fraction": 0.0}
            if self._thread is None or not self._thread.is_alive():
                self._thread = threading.Thread(target=self._run, name="model-downloads", daemon=True)
                self._thread.start()
        return self.status()

    def _run(self) -> None:
        if self._marker is not None:
            with contextlib.suppress(OSError):
                self._marker.parent.mkdir(parents=True, exist_ok=True)
                self._marker.write_text(f"{os.getpid()}\n")
        try:
            self._download_queued()
        finally:
            if self._marker is not None:
                with contextlib.suppress(OSError):
                    self._marker.unlink()

    def _download_queued(self) -> None:
        while True:
            with self._lock:
                mid = next((m for m, j in self._jobs.items() if j["state"] == "queued"), None)
                if mid is None:
                    return
                self._jobs[mid]["state"] = "downloading"
            try:
                self._fetch(MODELS[mid])
                ok = self._done(MODELS[mid])
                state, error = ("done", None) if ok else ("failed", "incomplete: some files are missing")
            except Exception as exc:
                state, error = "failed", str(exc) or type(exc).__name__
            with self._lock:
                self._jobs[mid].update(state=state, error=error)

    def status(self) -> dict:
        with self._lock:
            jobs = {m: dict(j) for m, j in self._jobs.items()}
        out = []
        for mid, job in jobs.items():
            m = MODELS[mid]
            if job["state"] == "done":
                got = m.disk_gb
            elif m.id == "speech":  # not a repo in the cache: what prepare reported
                got = m.disk_gb * job.get("fraction", 0.0)
            else:
                got = min(m.disk_gb, self._progress(self._repo_of(m)) / 1024**3)  # disk_gb is GiB
            out.append({"id": mid, "label": m.label, "disk_gb": m.disk_gb, "state": job["state"],
                        "done_gb": round(got, 2), "error": job["error"]})
        return {"running": any(j["state"] in ("queued", "downloading") for j in jobs.values()), "models": out}


def fetch_hosted(repo: str, manifest=None) -> bool:
    """The copy of ``repo`` the latest release hosts (#60): downloaded,
    checked against the manifest's sha256 and unpacked into the models
    folder. False when no release hosts it (or none is reachable)."""
    from . import downloader, model_store

    name = model_store.HOSTED.get(repo)
    if name is None:
        return False
    try:
        manifest = manifest or downloader.fetch_manifest()
    except (downloader.DownloadError, ValueError):
        return False
    entry = next((m for m in manifest.models if m.name == name and m.repo == repo), None)
    if entry is None:
        return False
    part = model_store.download_path(name)
    try:
        downloader.download(entry.asset, part)
        model_store.install_archive(part, name=name, version=entry.version)
    finally:
        part.unlink(missing_ok=True)
    return True


def _fetch(model: Model, repo: str) -> None:
    """Download a hosted model from the release; any other (or a hosted one
    no release has) in a helper process from Hugging Face (the token from
    config.toml goes in its environment, never on its command line)."""
    if model.hosted and fetch_hosted(repo):
        return
    env = dict(os.environ)
    # hf_xet can keep a chunk cache of up to 10 GB next to the models (#8).
    env.setdefault("HF_XET_CHUNK_CACHE_SIZE_BYTES", "0")
    try:
        from .config import load_config

        token = load_config().hf_token
        if token:
            env["HF_TOKEN"] = token
    except (OSError, ValueError):
        pass
    proc = subprocess.run([sys.executable, "-m", "palaver.onboarding", "download", model.id, repo],
                          capture_output=True, text=True, env=env)
    if proc.returncode != 0:
        lines = [x for x in (proc.stderr or "").strip().splitlines() if "hf_" not in x]  # never a token
        raise RuntimeError(lines[-1][:200] if lines else f"exit {proc.returncode}")


# --- looking at the Mac ------------------------------------------------------------------------------

APP_DIRS = (Path("/Applications"), Path.home() / "Applications")
TEAMS_APPS = ("Microsoft Teams.app", "Microsoft Teams (work or school).app", "Microsoft Teams classic.app")
SLACK_APPS = ("Slack.app",)


def _sysctl(name: str) -> str:
    try:
        return subprocess.run(["/usr/sbin/sysctl", "-n", name], capture_output=True, text=True,
                              timeout=5).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


class Probe:
    """The Mac as it is. Read-only: it never asks for a permission. Its
    downloads and test recording run only when the user starts them."""

    def __init__(self, cfg=None):
        self.cfg = cfg
        from . import install_layout

        self.downloads = Downloads(repo_of=self.repo_of, marker=install_layout.downloads_marker())
        self.test = TestRecording()
        self.calendar = Calendar()

    def repo_of(self, m: Model) -> str:
        return repo_for(self.cfg, m)

    def hardware(self) -> Hardware:
        try:
            memory = int(_sysctl("hw.memsize") or 0) / 1024**3
        except ValueError:
            memory = 0.0
        try:
            free = shutil.disk_usage(Path.home()).free / 1024**3
        except OSError:
            free = 0.0
        return Hardware(_sysctl("machdep.cpu.brand_string") or "unknown", round(memory), free)

    def installed(self) -> Installed:
        from . import mcp_access

        def app(names):
            return any((d / n).exists() for d in APP_DIRS for n in names)

        return Installed(teams=app(TEAMS_APPS), slack=app(SLACK_APPS),
                         claude_code=notes.find_claude(getattr(self.cfg, "claude_path", None)) is not None,
                         claude_desktop=mcp_access.DESKTOP_APP.exists())

    def permissions(self, output_dir: Path) -> dict[str, dict]:
        from .doctor import check_system_audio

        out = {"microphone": _microphone(), "calendar": self.calendar.status()}
        system = check_system_audio(output_dir)
        if system.status == "ok":
            out["system_audio"] = {"state": "granted", "detail": system.detail}
        elif "fell back" in system.detail:  # it recorded, through ScreenCaptureKit
            out["system_audio"] = {"state": "fallback", "detail": f"works with a fallback ({system.detail})",
                                   "fix": system.fix}
        else:
            out["system_audio"] = {"state": "unverified", "detail": system.detail, "fix": system.fix}
        out["notifications"] = notifications_permission()
        return out

    def downloaded(self) -> frozenset[str]:
        """The models whose every file is on this Mac (a partial download is not)."""
        out = set()
        for m in MODELS.values():
            try:
                here = model_here(m, self.repo_of(m))
                if m.id == "e5" and here:  # pinned to a revision: that one must be there
                    from . import embeddings

                    here = embeddings.model_folder(download=False) is not None
            except Exception:
                here = False
            if here:
                out.add(m.id)
        return frozenset(out)

    def full_name(self) -> str:
        import pwd

        try:
            return pwd.getpwuid(os.getuid()).pw_gecos.split(",")[0].strip()
        except (KeyError, OSError):
            return ""

    def autostart(self) -> bool:
        from . import app_bundle

        return app_bundle.LAUNCH_AGENT.exists()

    def set_autostart(self, on: bool) -> None:
        from . import app_bundle

        app_bundle.set_autostart(on)


def notifications_permission() -> dict:
    from . import notify

    return {"allowed": {"state": "granted", "detail": "allowed"},
            "denied": {"state": "denied", "detail": "not allowed"},
            "not_asked": {"state": "not_asked", "detail": "not asked yet"}}.get(
        notify.permission() or "", {"state": "unknown", "detail": "Palaver can't check this itself"})


def _microphone() -> dict:
    try:
        import AVFoundation

        status = AVFoundation.AVCaptureDevice.authorizationStatusForMediaType_(AVFoundation.AVMediaTypeAudio)
    except Exception:
        return {"state": "unknown", "detail": "could not check"}
    return {0: {"state": "not_asked", "detail": "not asked yet"}, 3: {"state": "granted", "detail": "allowed"}}.get(
        status, {"state": "denied", "detail": "not allowed"})


def calendar_permission() -> dict:
    try:
        import EventKit

        status = EventKit.EKEventStore.authorizationStatusForEntityType_(EventKit.EKEntityTypeEvent)
    except Exception:
        return {"state": "unknown", "detail": "could not check"}
    if status == 0:
        return {"state": "not_asked", "detail": "not connected"}
    if status == 3:
        return {"state": "granted", "detail": "connected (read only)"}
    if status == 4:
        return {"state": "denied", "detail": "write-only access: Palaver can't read events"}
    return {"state": "denied", "detail": "not allowed"}



CALENDAR_SETTINGS = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"


def _ask_calendar() -> None:
    from .calendar_eventkit import request_access

    request_access(lambda granted: None)  # the page sees the answer on its next look


class Calendar:
    """The calendar permission for the setup assistant's button: asked for
    by the app (``ask``, macOS shows its dialog once); once refused, macOS
    asks no more, so the button opens System Settings at Calendars."""

    def __init__(self, ask: Callable[[], None] | None = None, open_settings: Callable[[], None] | None = None):
        self._ask = ask or _ask_calendar
        self._open_settings = open_settings or (lambda: subprocess.run(["open", CALENDAR_SETTINGS], check=False))

    def status(self) -> dict:
        return calendar_permission()

    def connect(self) -> dict:
        now = self.status()
        if now["state"] == "not_asked":
            self._ask()
            return {**now, "asked": True}
        if now["state"] == "denied":
            self._open_settings()
            return {**now, "opened_settings": True}
        return now

# --- the helper process: `python -m palaver.onboarding download|transcribe` ---------------------------

def _main(argv: list[str]) -> int:
    """`python -m palaver.onboarding download <id> [repo]`: a model from Hugging Face
    (the notes models, search). The speech models come from the engine instead.
    `fetch <id> <repo>`: one model as Downloads fetches it (`_fetch`), for the Swift
    window server; a failure is one line on stderr, which the page shows."""
    what, arg = argv[0], argv[1]
    repo = argv[2] if len(argv) > 2 else (MODELS[arg].repo if arg in MODELS else "")
    if what == "fetch":
        try:
            _fetch(MODELS[arg], repo)
        except Exception as exc:
            print(" ".join(str(exc).split()) or type(exc).__name__, file=sys.stderr)
            return 1
        return 0
    if what == "download":
        if arg == "e5":
            from . import embeddings

            return 0 if embeddings.model_folder(download=True) else 1
        from huggingface_hub import snapshot_download

        # Only what mlx_lm loads, at the revision it loads (#8).
        snapshot_download(repo, revision=notes.MODEL_REVISIONS.get(repo), allow_patterns=list(notes.MODEL_FILES),
                          token=os.environ.get("HF_TOKEN"))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
