"""Cloud providers the user can choose, and which one each feature uses.

Local stays the default for everything: a feature uses a provider only
after the user chose it for that feature (``choose``), and only a provider
that is set up (``problem`` is None). Nothing here sends anything; llm.py
builds the runners.

Where things live:
- each provider's endpoint, model and context window: settings.json
  ("providers"), written by the Settings page;
- which provider each feature uses: settings.json ("engines"); a feature
  never chosen there follows config.toml (``[notes].engine``);
- API keys: the login Keychain (keychain.py), account "<provider>.api_key".

The registry is shared: the language models (#53) and the transcription
services (#54, ``uses={"transcription"}``) have the same key storage,
consent and Settings card. A feature only takes providers of its kind
(``for_feature``).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any
from urllib.parse import urlsplit

from . import keychain, settings

LANGUAGE_MODEL = "language_model"
TRANSCRIPTION = "transcription"
LOCAL = "local"
# A language-model feature waiting for a cloud model the user has not set up
# yet (#55: a Mac too small for the local one): nothing runs until then.
PENDING = "pending"
REGIONS = ("eu", "us")
MAX_MODEL_CHARS = 200
CONTEXT_RANGE = (1_000, 10_000_000)


@dataclass(frozen=True)
class Provider:
    id: str
    label: str
    uses: frozenset[str]
    key: str  # "required", "optional" (only a gateway on this Mac may do without) or "none"
    endpoint: str | None  # the default; None: the provider has no endpoint to set
    model: str  # the default; "" when the user has to name one
    context_tokens: int  # the default context window (0: not a language model)
    sends_to: str  # who gets the data, said plainly
    privacy: str = ""  # how long it is kept there and whether it is trained on, said plainly
    usd_per_hour: float | None = None  # a transcription service's list price per hour of audio


PROVIDERS: dict[str, Provider] = {p.id: p for p in (
    Provider("anthropic", "Anthropic API", frozenset({LANGUAGE_MODEL}), "required", "https://api.anthropic.com",
             "claude-opus-5-5", 1_000_000, "Anthropic"),
    Provider("openai", "OpenAI-compatible", frozenset({LANGUAGE_MODEL}), "optional", "https://api.openai.com/v1",
             "", 128_000, "the endpoint you set: OpenAI, your Azure OpenAI tenant or your gateway"),
    Provider("claude-cli", "Claude Code CLI", frozenset({LANGUAGE_MODEL}), "none", None,
             "sonnet", 200_000, "Anthropic, through your Claude Code login"),
    # Transcription (#54), in the order of the research in #43. Prices are
    # list prices per hour of audio, October 2026.
    Provider("assemblyai", "AssemblyAI", frozenset({TRANSCRIPTION}), "required", None,
             "universal-3-5-pro", 0, "AssemblyAI, on its servers in the region you choose",
             "Palaver deletes the transcript there, and the audio with it, as soon as it has it (a job still "
             "running is deleted on the next try). Audio that never became a transcript AssemblyAI deletes "
             "within 48 hours. On the EU servers AssemblyAI never trains on it; on the US servers only if you "
             "opted out.",
             0.28),
    Provider("soniox", "Soniox", frozenset({TRANSCRIPTION}), "required", None,
             "stt-async-v5", 0, "Soniox, on its servers in the region you choose",
             "Soniox never trains on it. Palaver deletes the audio and the transcript there as soon as it has "
             "the transcript, or on the next try if Soniox refuses then (else Soniox keeps them 30 days). "
             "The EU region needs an EU project at Soniox: request it in the Soniox Console and use that "
             "project's key.",
             0.10),
    Provider("mistral", "Mistral Voxtral", frozenset({TRANSCRIPTION}), "required", None,
             "voxtral-mini-latest", 0, "Mistral AI, in the EU",
             "Mistral hosts it in the EU and does not train on API data; it keeps it as your Mistral account "
             "says (zero retention on request). Not measured on German meetings yet.",
             0.21),
    Provider("openai-transcribe", "OpenAI-compatible transcription", frozenset({TRANSCRIPTION}), "optional",
             "https://api.openai.com/v1", "whisper-1", 0,
             "the endpoint you set: OpenAI, your Azure OpenAI tenant or your gateway",
             "As the endpoint's terms say. OpenAI's API does not train on it unless you opt in.",
             None),
)}

# What each feature sends to a cloud provider, said plainly on the Settings
# page, and which kind of provider it takes.
FEATURES: dict[str, dict[str, str]] = {
    "notes": {"label": "Notes", "uses": LANGUAGE_MODEL,
              "sends": "the meeting's transcript with speaker names, and its calendar title and invitees"},
    "projects": {"label": "Projects", "uses": LANGUAGE_MODEL,
                 "sends": "the titles, summaries, people and email domains of the meetings to sort, "
                          "and your project names and descriptions"},
    # "own": chosen on its own, local until the user picks a model for it; never
    # config.toml's [notes].engine, never the setup assistant's choice for notes.
    "coach": {"label": "Best next question", "uses": LANGUAGE_MODEL, "own": True,
              "sends": "the last minutes of the live transcript with speaker names, the meeting's calendar title "
                       "and invitees, the last meeting's summary and open next steps, and your own notes on the "
                       "meeting; only when you ask"},
    "transcription": {"label": "Transcription", "uses": TRANSCRIPTION,
                      "sends": "the call's system track (what the others said), with long silences cut out, "
                               "and the meeting's keyterms (glossary terms and invitees' names)"},
}


def language_models() -> list[str]:
    return [pid for pid, p in PROVIDERS.items() if LANGUAGE_MODEL in p.uses]


def transcribers() -> list[str]:
    return [pid for pid, p in PROVIDERS.items() if TRANSCRIPTION in p.uses]


def for_feature(feature: str) -> list[str]:
    """The providers ``feature`` can use: language models or transcription services."""
    uses = FEATURES.get(feature, {}).get("uses", LANGUAGE_MODEL)
    return [pid for pid, p in PROVIDERS.items() if uses in p.uses]


def _provider(pid: str) -> Provider:
    if pid not in PROVIDERS:
        raise ValueError(f"no provider {pid!r}")
    return PROVIDERS[pid]


def _saved() -> dict[str, Any]:
    data = settings.read_raw()
    return data if isinstance(data, dict) else {}


def _check_endpoint(value: Any) -> str:
    if not isinstance(value, str):
        raise ValueError("the endpoint must be a URL")
    value = value.strip()
    parts = urlsplit(value)
    local = parts.hostname in ("localhost", "127.0.0.1", "::1")
    if not parts.hostname or parts.scheme not in ("https", "http") or (parts.scheme == "http" and not local):
        raise ValueError("the endpoint must be an https:// URL (http:// only for a gateway on this Mac)")
    if parts.username or parts.password:
        raise ValueError("put the key in the key field, not in the endpoint")
    if parts.fragment:
        raise ValueError("the endpoint must not have a #fragment")
    return value


def _check_model(value: Any) -> str:
    if not isinstance(value, str) or not value.strip() or len(value.strip()) > MAX_MODEL_CHARS \
            or any(c in value for c in "\r\n\0"):
        raise ValueError("the model name must be one line of text")
    return value.strip()


def _check_auth(value: Any) -> str:
    from .cloud_llm import AUTH_HEADERS

    if value not in AUTH_HEADERS:
        raise ValueError(f"the key header must be one of {', '.join(AUTH_HEADERS)}")
    return value


def _check_context(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not CONTEXT_RANGE[0] <= value <= CONTEXT_RANGE[1]:
        raise ValueError(f"the context window must be between {CONTEXT_RANGE[0]:,} and {CONTEXT_RANGE[1]:,} tokens")
    return value


def _check_region(value: Any) -> str:
    if value not in REGIONS:
        raise ValueError(f"the region must be one of {', '.join(REGIONS)}")
    return value


_CHECKS = {"endpoint": _check_endpoint, "model": _check_model, "context_tokens": _check_context, "auth": _check_auth,
           "region": _check_region}
# Settings only some providers have, with their defaults.
_EXTRA = {"openai": {"auth": "auto"}, "openai-transcribe": {"auth": "auto"},
          "assemblyai": {"region": "eu"}, "soniox": {"region": "eu"}}
ON_THIS_MAC = {"localhost", "127.0.0.1", "::1"}


def settings_of(pid: str, defaults: dict[str, Any] | None = None) -> dict[str, Any]:
    """The provider's endpoint, model and context window: as saved, else
    ``defaults``, else the provider's own. A saved value that doesn't pass
    the checks is ignored."""
    p = _provider(pid)
    out: dict[str, Any] = {"model": p.model, "context_tokens": p.context_tokens, **_EXTRA.get(pid, {})}
    if p.endpoint is not None:
        out["endpoint"] = p.endpoint
    out.update({k: v for k, v in (defaults or {}).items() if k in out})
    out.update({k: v for k, v in _stored(pid).items() if k in out})
    return out


def _stored(pid: str) -> dict[str, Any]:
    """What the user saved for ``pid``, the values that pass the checks."""
    every = _saved().get("providers")
    stored = every.get(pid) if isinstance(every, dict) else None
    out = {}
    for name, value in (stored if isinstance(stored, dict) else {}).items():
        if name in _CHECKS:
            try:
                out[name] = _CHECKS[name](value)
            except ValueError:
                pass
    return out


def configure(pid: str, **changes: Any) -> dict[str, Any]:
    """Save the provider's endpoint, model or context window; a value that
    is not one is a ValueError and nothing is saved."""
    p = _provider(pid)
    checked = {}
    for name, value in changes.items():
        if name not in _CHECKS or (name == "endpoint" and p.endpoint is None) or (
                name in ("auth", "region") and name not in _EXTRA.get(pid, {})) or (
                name == "context_tokens" and not p.context_tokens):
            raise ValueError(f"{p.label} has no setting {name!r}")
        checked[name] = _CHECKS[name](value)
    data = _saved()
    every = data.get("providers") if isinstance(data.get("providers"), dict) else {}
    mine = every.get(pid) if isinstance(every.get(pid), dict) else {}
    settings.update({"providers": {**every, pid: {**mine, **checked}}})
    return settings_of(pid)


def key_account(pid: str) -> str:
    return f"{pid}.api_key"


def set_key(pid: str, key: str) -> None:
    if _provider(pid).key == "none":
        raise ValueError(f"{PROVIDERS[pid].label} takes no API key")
    if not isinstance(key, str):
        raise ValueError("that is not an API key")
    keychain.set(key_account(pid), key)


def remove_key(pid: str) -> None:
    _provider(pid)
    keychain.delete(key_account(pid))


def has_key(pid: str) -> bool:
    return _provider(pid).key != "none" and keychain.has(key_account(pid))


def api_key(pid: str) -> str | None:
    """The key itself, for the request only: never shown, logged or returned to the page."""
    return keychain.get(key_account(pid)) if _provider(pid).key != "none" else None


def problem(pid: str, *, claude_path: str | None = None, defaults: dict[str, Any] | None = None) -> str | None:
    """What keeps the provider from being used, said to the user; None when it is ready."""
    p = _provider(pid)
    if pid == "claude-cli":
        from . import notes

        return None if notes.find_claude(claude_path) else "Claude Code CLI (`claude`) not found on this Mac"
    if not settings_of(pid, defaults)["model"]:
        return "Set the model name"
    if p.key == "optional":
        return _gateway_problem(pid)
    if p.key == "required" and not has_key(pid):
        return "Add the API key"
    return None


def _azure_tenant(host: str) -> bool:
    """``<resource>.openai.azure.com`` (or the other Azure AI hosts), with a resource name."""
    from .cloud_llm import AZURE_SUFFIXES

    return any(host.endswith(s) and len(host) > len(s) and not host.startswith(".") for s in AZURE_SUFFIXES)


def _gateway_problem(pid: str) -> str | None:
    """An OpenAI-compatible endpoint sends nothing until it is set up for
    real: the endpoint saved by the user (the default is no choice), a key
    unless the endpoint is on this Mac, and for Azure (by host, or the
    api-key header picked) the tenant's own endpoint."""
    from .cloud_llm import is_azure

    stored = _stored(pid)
    endpoint = stored.get("endpoint", "")
    host = (urlsplit(endpoint).hostname or "").lower()
    if stored.get("auth") == "api-key" or is_azure(endpoint) or host.endswith(".azure.com"):
        if not _azure_tenant(host):
            return "Set your Azure OpenAI endpoint (https://<resource>.openai.azure.com/…)"
    if not endpoint:
        return "Save the endpoint"
    if host not in ON_THIS_MAC and not has_key(pid):
        return "Add the API key"
    return None


def public(pid: str, *, claude_path: str | None = None, defaults: dict[str, Any] | None = None) -> dict[str, Any]:
    """The provider as the Settings page shows it: never the key, only
    whether one is set."""
    p = _provider(pid)
    trouble = problem(pid, claude_path=claude_path, defaults=defaults)
    return {
        "id": pid, "label": p.label, "sends_to": p.sends_to, "key": p.key,
        "key_set": has_key(pid), "ready": trouble is None, "problem": trouble,
        "has_endpoint": p.endpoint is not None, "privacy": p.privacy, "usd_per_hour": p.usd_per_hour,
        **settings_of(pid, defaults),
    }


def choice(feature: str, *, default: str) -> str:
    """"local" or the provider the user chose for ``feature``; ``default``
    (from config.toml) when they never chose. A saved value that is no
    choice means local: never a cloud nobody picked."""
    engines = _saved().get("engines")
    if not isinstance(engines, dict) or feature not in engines:
        return default
    value = engines[feature]
    if value == PENDING and FEATURES.get(feature, {}).get("uses") == LANGUAGE_MODEL:
        return PENDING
    return value if value == LOCAL or value in for_feature(feature) else LOCAL


def choose(feature: str, value: Any, **context: Any) -> None:
    """Use ``value`` ("local" or a provider id) for ``feature``. A provider
    must be set up first. This is the user's consent: nothing else writes it."""
    if feature not in FEATURES:
        raise ValueError(f"no feature {feature!r}")
    if value == PENDING and FEATURES[feature]["uses"] == LANGUAGE_MODEL:
        pass  # off until a cloud model is set up: nothing to check
    elif value != LOCAL:
        if not isinstance(value, str) or value not in for_feature(feature):
            kind = "transcription service" if FEATURES[feature]["uses"] == TRANSCRIPTION else "language model"
            raise ValueError(f"no {kind} {value!r}")
        trouble = problem(value, **context)
        if trouble:
            raise ValueError(f"{PROVIDERS[value].label}: {trouble}")
    engines = _saved().get("engines")
    settings.update({"engines": {**(engines if isinstance(engines, dict) else {}), feature: value}})
