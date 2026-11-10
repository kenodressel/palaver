"""`palaver provider <action> --json`: the Settings page's language-model and
transcription sections (api.py's #53, #54) for the Swift window server,
which keeps the Keychain and the cloud calls in Python until phase 4.

The request's body comes on stdin, so an API key is never on the command
line, in the environment or in a log. One JSON line goes out: the answer,
or ``{"error", "status"}`` with exit 1, the status being what the window's
Python server answers for it: 400 (``api.Refused``, ``KeyError``,
``ValueError`` as "bad request: …"), 502 (a Test button's
``notes.NotesError``), 500 (anything else, its text). No error text holds
the key that was given.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Callable

ACTIONS = ("language-model", "set-language-model", "set-key", "test", "transcription", "set-transcription",
           "set-transcription-key", "test-transcription", "registry", "mcp-install")
_TESTS = ("test", "test-transcription")


def registry(cfg) -> dict[str, Any]:
    """Every provider as the Settings page shows it (``providers.public``,
    never a key) with what it is for (``uses``), and each feature with its
    kind of provider, its choice (``default``: config.toml's, or local) and
    whether that choice can be used now (``ready``)."""
    from . import llm, providers

    claude_path = getattr(cfg, "claude_path", None)
    shown = {pid: {**providers.public(pid, claude_path=claude_path, defaults=llm.provider_defaults(cfg, pid)),
                   "uses": sorted(p.uses)}
             for pid, p in providers.PROVIDERS.items()}
    features = []
    for fid, info in providers.FEATURES.items():
        uses = info.get("uses", providers.LANGUAGE_MODEL)
        default = llm.default_choice(cfg, fid) if uses == providers.LANGUAGE_MODEL else providers.LOCAL
        chosen = providers.choice(fid, default=default)
        ready = chosen == providers.LOCAL or (chosen in shown and shown[chosen]["ready"])
        features.append({"id": fid, **info, "uses": uses, "own": bool(info.get("own")), "choice": chosen,
                         "default": default, "ready": ready})
    return {"features": features, "providers": list(shown.values())}


def run(action: str, cfg, body: Any, cli_options: list[str]) -> dict[str, Any]:
    """The answer to ``action``, as the window's Python server gives it."""
    from .webapp import api

    if action == "language-model":
        return api.language_model(cfg)
    if action == "set-language-model":
        return api.set_language_model(cfg, body)
    if action == "set-key":
        return api.set_provider_key(cfg, body)
    if action == "test":
        return api.test_provider(cfg, body)
    if action == "transcription":
        return api.transcription(cfg)
    if action == "set-transcription":
        return api.set_transcription(cfg, body)
    if action == "set-transcription-key":
        return api.set_transcription_key(cfg, body)
    if action == "test-transcription":
        return api.test_transcription(cfg, body)
    if action == "registry":
        return registry(cfg)
    if action == "mcp-install":
        return api.install_mcp(str(body.get("target") or "code"), cli_options)
    raise ValueError(f"no action {action!r}")


def _without_key(text: str, body: Any) -> str:
    key = body.get("key") if isinstance(body, dict) else None
    if isinstance(key, str):
        for given in {key, key.strip()} - {""}:
            text = text.replace(given, "…")
    return text


def answer(action: str, config: Callable[[], Any], body: Any, cli_options: list[str]) -> tuple[dict[str, Any], int]:
    """The JSON line and the exit code; ``config()`` reads config.toml (its failure is an error too)."""
    from .notes import NotesError
    from .webapp import api

    try:
        return run(action, config(), body, cli_options), 0
    except api.Refused as exc:
        status, text = 400, str(exc)
    except NotesError as exc:
        if action not in _TESTS:
            status, text = 500, str(exc)
        else:  # its message never holds the key (cloud_llm.redact)
            status, text = 502, str(exc)
    except (KeyError, ValueError) as exc:
        status, text = 400, f"bad request: {exc}"
    except Exception as exc:  # what the window's server answers 500 for
        status, text = 500, str(exc)
    return {"error": _without_key(text, body), "status": status}, 1


def command(args: argparse.Namespace) -> int:
    """`palaver provider <action> --json`: the body on stdin, one JSON line out."""
    from . import notify
    from .config import default_config_path, load_config

    notify.set_enabled(False)  # the window shows what went wrong; no notification
    try:
        body = json.loads(sys.stdin.read() or "{}")
    except ValueError as exc:
        out, code = {"error": f"bad request: {exc}", "status": 400}, 1
    else:
        options = []
        if args.action == "mcp-install":  # Claude starts `palaver mcp` with the server's options (--config)
            from .daemon import forwarded_cli_options

            options = forwarded_cli_options(args)
        # The tokens of config.toml are not needed here: no Keychain read for them.
        out, code = answer(args.action, lambda: load_config(Path(args.config) if args.config else default_config_path(),
                                                            secrets=False), body, options)
    print(json.dumps(out, ensure_ascii=False))
    return code
