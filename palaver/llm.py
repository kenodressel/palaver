"""Which language model runs a feature (notes, projects): the local one
on this Mac, or the cloud provider the user chose for that feature in
Settings (providers.choose).

- Local is the default. config.toml's ``[notes].engine = "claude"`` keeps
  meaning the Claude Code CLI for users who set it there.
- A meeting marked "local only" (``set_local_only``) never goes to a cloud
  model: its notes are written locally whatever the feature's choice.
- When the chosen provider can't run (no key, no model name, no CLI),
  ``engine`` raises Unavailable and says why. It never falls back to
  another model, and certainly not to a cloud one.
- Each engine declares its context window; a prompt that would not fit is
  refused before it is sent (ContextTooLong), never cut short.
- Every cloud call is written to the access log (access_log.py).
"""

from __future__ import annotations

import json
import logging
import math
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable
from urllib.parse import urlsplit

from . import access_log, cloud_llm, notes, providers, settings
from .paths import RecordingPaths

LOGGER = logging.getLogger(__name__)

# The local models offered in Settings: what they need while writing and
# how much they read at once.
LOCAL_MODELS: dict[str, dict[str, Any]] = {
    "mlx-community/gemma-4-12B-it-OptiQ-4bit": {
        "label": "Gemma 4 12B", "memory_gb": notes.MODEL_MEMORY_GB["mlx-community/gemma-4-12B-it-OptiQ-4bit"],
        "context_tokens": 131_072, "running_gb": 10, "note": "The default: the most accurate on German meetings."},
}
LOCAL_CONTEXT_TOKENS = 131_072  # a local model not listed
# Characters per token, on the low side: German, names and timestamps take
# more tokens than English prose. Overestimating refuses a borderline
# meeting; underestimating would let it be cut off.
CHARS_PER_TOKEN = 3.0
SETTINGS_HINT = "Change it in Settings → Language model."

Runner = Callable[[str, dict], dict]


class Unavailable(notes.NotesError):
    """The chosen model can't run; the message says why."""


class ContextTooLong(notes.NotesError):
    """The prompt would not fit the model's context window."""


@dataclass(frozen=True)
class Engine:
    choice: str  # "local" or a provider id
    label: str
    model: str
    cloud: bool
    context_tokens: int
    run: Runner


def estimate_tokens(text: str) -> int:
    return math.ceil(len(text) / CHARS_PER_TOKEN)


# --- per meeting ---------------------------------------------------------------------


def is_local_only(folder: Path) -> bool:
    return RecordingPaths(Path(folder)).local_only.exists()


def local_only_meetings(output_dir: Path) -> set[str]:
    """The ids of the meetings kept on this Mac: never sent to a cloud
    model, never shown to Claude through MCP."""
    if not output_dir.is_dir():
        return set()
    return {f.name for f in output_dir.iterdir() if f.is_dir() and is_local_only(f)}


def set_local_only(folder: Path, on: bool) -> None:
    marker = RecordingPaths(Path(folder)).local_only
    if on:
        from datetime import datetime

        marker.write_text(json.dumps({"since": datetime.now().astimezone().isoformat(timespec="seconds")}))
    else:
        marker.unlink(missing_ok=True)


# --- choices ---------------------------------------------------------------------------


def default_choice(cfg, feature: str | None = None) -> str:
    """config.toml's choice, for a feature never chosen in Settings; local
    for a feature chosen on its own (the coach's best next question)."""
    if feature is not None and providers.FEATURES.get(feature, {}).get("own"):
        return providers.LOCAL
    return "claude-cli" if getattr(cfg, "notes_engine", "local") == "claude" else providers.LOCAL


def choice_for(cfg, feature: str, meetings: Iterable[Path] = ()) -> str:
    chosen = providers.choice(feature, default=default_choice(cfg, feature))
    if chosen == providers.PENDING:  # off until a cloud model is set up, also for a meeting kept here
        return chosen
    if chosen != providers.LOCAL and any(is_local_only(m) for m in meetings):
        return providers.LOCAL
    return chosen


def local_model(cfg) -> str:
    saved = settings.read_raw().get("local_model")
    return saved if saved in LOCAL_MODELS else getattr(cfg, "notes_local_model", notes.DEFAULT_LOCAL_MODEL)


def choose_local_model(repo: str) -> None:
    if repo not in LOCAL_MODELS:
        raise ValueError(f"no local model {repo!r}")
    settings.update({"local_model": repo})


def provider_defaults(cfg, pid: str) -> dict[str, Any] | None:
    """config.toml's model for the Claude Code CLI (``[notes].model``)."""
    return {"model": getattr(cfg, "notes_model", "sonnet")} if pid == "claude-cli" else None


def notes_memory_gb(cfg, folder: Path | None = None) -> float:
    """Free memory to wait for before writing the notes of ``folder``: the
    local model's need, none for a cloud model."""
    return memory_gb(cfg, "notes", folder)


def memory_gb(cfg, feature: str, folder: Path | None = None) -> float:
    """Free memory ``feature`` needs for ``folder``: the local model's (the
    notes' gate), none for a cloud model."""
    if choice_for(cfg, feature, [folder] if folder is not None else []) != providers.LOCAL:
        return 0.0
    return notes.notes_memory_gb(local_model(cfg))


# --- engines ------------------------------------------------------------------------------


def engine(cfg, feature: str, *, parse: Callable[[str], dict] | None = None,
           meetings: Iterable[Path] = ()) -> Engine:
    """The engine for ``feature`` (and the ``meetings`` it is about)."""
    meetings = list(meetings)
    chosen = choice_for(cfg, feature, meetings)
    if chosen == providers.PENDING:
        raise Unavailable("No model yet: set up a cloud model in Settings → Language model "
                          "(this Mac is too small for the local one).")
    if chosen == providers.LOCAL:
        repo = local_model(cfg)
        inner = notes.local_runner(repo, **({"parse": parse} if parse else {}))
        context = LOCAL_MODELS.get(repo, {}).get("context_tokens", LOCAL_CONTEXT_TOKENS)
        label = LOCAL_MODELS.get(repo, {}).get("label", repo)
        return Engine(chosen, f"{label} on this Mac", repo, False, context,
                      _checked(inner, label=label, model=repo, context=context, reserve=notes.LOCAL_MAX_TOKENS))
    return _cloud(cfg, chosen, feature=feature, parse=parse, meetings=[Path(m).name for m in meetings])


def _cloud(cfg, pid: str, *, feature: str, parse, meetings: list[str]) -> Engine:
    p = providers.PROVIDERS[pid]
    defaults = provider_defaults(cfg, pid)
    trouble = providers.problem(pid, claude_path=getattr(cfg, "claude_path", None), defaults=defaults)
    if trouble:
        raise Unavailable(f"{p.label}: {trouble}. {SETTINGS_HINT}")
    s = providers.settings_of(pid, defaults)
    key = None
    if pid == "claude-cli":
        claude = notes.find_claude(getattr(cfg, "claude_path", None))
        if claude is None:
            raise Unavailable(f"{p.label}: Claude Code CLI (`claude`) not found on this Mac. {SETTINGS_HINT}")
        inner, host = notes.claude_runner(claude, model=s["model"]), "claude CLI"
    elif pid == "anthropic":
        key = providers.api_key(pid)
        inner = cloud_llm.anthropic_runner(s["endpoint"], s["model"], key, parse=parse or notes.parse_notes,
                                           name=p.label)
        host = urlsplit(s["endpoint"]).hostname or s["endpoint"]
    elif pid == "openai":
        key = providers.api_key(pid)
        inner = cloud_llm.openai_runner(s["endpoint"], s["model"], key, parse=parse or notes.parse_notes,
                                        name=p.label, auth=s.get("auth", "auto"))
        host = urlsplit(s["endpoint"]).hostname or s["endpoint"]
    else:  # a provider for something else (transcription)
        raise Unavailable(f"{p.label} is not a language model")
    reserve = cloud_llm.MAX_OUTPUT_TOKENS if pid != "claude-cli" else 0

    def logged(prompt: str, schema: dict) -> dict:
        # Refused before anything is sent: not a call to log.
        _fits(prompt, schema, label=p.label, model=s["model"], context=s["context_tokens"], reserve=reserve)
        started = time.monotonic()
        entry = dict(provider=pid, host=host, model=s["model"], feature=feature, meetings=meetings,
                     chars=len(prompt) + len(json.dumps(schema)))
        try:
            out = inner(prompt, schema)
        except Exception as exc:
            message = str(exc) if isinstance(exc, notes.NotesError) else type(exc).__name__
            _log(**entry, ok=False, error=cloud_llm.redact(message, key), seconds=time.monotonic() - started)
            raise
        _log(**entry, ok=True, seconds=time.monotonic() - started)
        return out

    return Engine(pid, p.label, s["model"], True, s["context_tokens"], logged)


def _log(**entry: Any) -> None:
    """Into the access log; a log that can't be written costs a warning,
    never the answer the call brought back."""
    try:
        access_log.record(**entry)
    except Exception as exc:
        LOGGER.warning("could not write the access log (%s %s): %s", entry.get("provider"), entry.get("feature"),
                       type(exc).__name__)


def _fits(prompt: str, schema: dict, *, label: str, model: str, context: int, reserve: int) -> None:
    tokens = estimate_tokens(prompt) + estimate_tokens(json.dumps(schema))
    if tokens + reserve > context:
        raise ContextTooLong(
            f"This is about {tokens:,} tokens, and {label} ({model}) reads at most {context:,} "
            f"with room for its answer. Choose a model with a larger context window. {SETTINGS_HINT}")


def _checked(inner: Runner, *, label: str, model: str, context: int, reserve: int) -> Runner:
    def run(prompt: str, schema: dict) -> dict:
        _fits(prompt, schema, label=label, model=model, context=context, reserve=reserve)
        return inner(prompt, schema)

    return run


# --- the Test button ------------------------------------------------------------------------

TEST_PROMPT = 'Say hello in at most five words. Answer as {"reply": "..."}.'
TEST_SCHEMA = {"type": "object", "properties": {"reply": {"type": "string"}}, "required": ["reply"]}


def _any_json(text: str) -> dict:
    return cloud_llm._json_object(text)


def test(pid: str, cfg) -> dict[str, Any]:
    """Send a tiny prompt (no meeting content) to ``pid``: its answer and
    how long it took."""
    if pid not in providers.language_models():
        raise ValueError(f"no language model {pid!r}")
    eng = _cloud(cfg, pid, feature="test", parse=_any_json, meetings=[])
    started = time.monotonic()
    out = eng.run(TEST_PROMPT, TEST_SCHEMA)
    reply = out.get("reply") if isinstance(out.get("reply"), str) else json.dumps(out, ensure_ascii=False)
    return {"answer": reply[:200], "seconds": round(time.monotonic() - started, 1), "model": eng.model}
