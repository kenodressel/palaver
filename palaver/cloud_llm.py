"""Language models in the cloud, over HTTP: the Anthropic API and
OpenAI-compatible endpoints (OpenAI, Azure OpenAI, a company or self-hosted
gateway). Each runner has the shape of ``notes.local_runner``: it takes the
prompt and a JSON schema and returns the parsed answer.

Only ``llm.engine`` builds these, and only for a provider the user chose
(providers.choose); nothing here decides to send anything.

Redirects are never followed: urllib would carry the key headers to
wherever a 3xx points, so a redirect is an error naming its target.

Errors: a refused key (401/403) and other client errors are raised at once;
rate limits (429), server errors and timeouts are tried again, up to
``ATTEMPTS`` times, waiting as long as the provider asks (``Retry-After``,
capped) or ``BACKOFF_SECONDS``. Error messages never contain the API key:
they are built here, and the provider's own words pass through ``redact``.
"""

from __future__ import annotations

import json
import re
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Callable
from urllib.parse import urljoin, urlsplit, urlunsplit

from .notes import NotesError

ANTHROPIC_VERSION = "2026-10-21"
TIMEOUT_SECONDS = 600.0  # one request: adaptive thinking plus the notes of a long meeting
# Room for the model's thinking and long German notes (Claude Opus 5.5 allows
# 128k; without streaming, 32k keeps one answer well inside the timeout).
MAX_OUTPUT_TOKENS = 32_000
ATTEMPTS = 3
BACKOFF_SECONDS = (2.0, 8.0)
MAX_WAIT_SECONDS = 60.0
MAX_ERROR_CHARS = 300
RETRY_STATUS = {408, 409, 429, 500, 502, 503, 504, 529}
_SECRET_HEADERS = {"x-api-key", "authorization", "api-key"}
AZURE_SUFFIXES = (".openai.azure.com", ".cognitiveservices.azure.com", ".services.ai.azure.com")
AUTH_HEADERS = ("auto", "bearer", "api-key")  # auto: api-key for Azure hosts, Bearer elsewhere
# Things that look like API keys, also half-masked ("sk-abc***wxyz").
_KEYISH = re.compile(r"\b(?:sk|pk|rk|key|api)[-_][\w*.-]{3,}|\b[A-Za-z0-9]{32,}\b", re.I)


class CloudError(NotesError):
    """A cloud model failed; the message is safe to show and to log."""


@dataclass(frozen=True)
class Request:
    method: str
    url: str
    headers: dict[str, str] = field(repr=False)
    body: bytes = field(repr=False)
    timeout: float = TIMEOUT_SECONDS

    def __repr__(self) -> str:  # headers carry the key
        shown = {k: ("…" if k in _SECRET_HEADERS else v) for k, v in self.headers.items()}
        return f"Request({self.method} {self.url}, headers={shown}, {len(self.body)} bytes)"

    __str__ = __repr__


@dataclass(frozen=True)
class Response:
    status: int
    headers: dict[str, str]  # lower-case names
    body: bytes


Transport = Callable[[Request], Response]


class _NoRedirects(urllib.request.HTTPRedirectHandler):
    """urllib follows 301/302/303 even for a POST and copies the headers
    along, the API key with them. Not here: the 3xx comes back as it is."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_OPENER = urllib.request.build_opener(_NoRedirects)


def _open(req: urllib.request.Request, timeout: float):
    return _OPENER.open(req, timeout=timeout)


def urllib_transport(request: Request) -> Response:
    """Send ``request``. An HTTP error status (a redirect too, never
    followed) is a Response like any other; a host that can't be reached
    raises ConnectionError, a timeout TimeoutError."""
    req = urllib.request.Request(request.url, data=request.body, method=request.method, headers=request.headers)
    try:
        with _open(req, request.timeout) as resp:
            return Response(resp.status, {k.lower(): v for k, v in resp.headers.items()}, resp.read())
    except urllib.error.HTTPError as exc:
        headers = {k.lower(): v for k, v in (exc.headers or {}).items()}
        return Response(exc.code, headers, exc.read() or b"")
    except urllib.error.URLError as exc:
        if isinstance(exc.reason, TimeoutError):
            raise TimeoutError("timed out") from None
        raise ConnectionError(str(exc.reason)) from None


default_transport: Transport = urllib_transport


def redact(text: str, key: str | None) -> str:
    """``text`` without the key, without anything that looks like a key,
    and short."""
    if key:
        text = text.replace(key, "…")
    text = _KEYISH.sub("…", text)
    return text[:MAX_ERROR_CHARS] + ("…" if len(text) > MAX_ERROR_CHARS else "")


def _provider_message(body: bytes) -> str:
    try:
        data = json.loads(body)
    except ValueError:
        return body.decode("utf-8", "replace").strip()
    err = data.get("error") if isinstance(data, dict) else None
    if isinstance(err, dict):
        return str(err.get("message") or err.get("type") or "")
    return str(err or data.get("message") or "") if isinstance(data, dict) else ""


def _wait(response: Response, attempt: int) -> float:
    try:
        asked = float(response.headers.get("retry-after", ""))
    except ValueError:
        asked = None
    if asked is not None and asked >= 0:
        return min(asked, MAX_WAIT_SECONDS)
    return BACKOFF_SECONDS[min(attempt, len(BACKOFF_SECONDS) - 1)]


class _Rejected(CloudError):
    """A client error, with the provider's (redacted) words."""

    def __init__(self, status: int, message: str):
        super().__init__(f"HTTP {status}: {message}" if message else f"HTTP {status}")
        self.status, self.provider_message = status, message


def send(request: Request, *, name: str, key: str | None, transport: Transport | None = None,
         sleep: Callable[[float], None] = time.sleep, empty_ok: bool = False, idempotent: bool = True,
         attempts: int = ATTEMPTS) -> dict[str, Any]:
    """Send ``request`` with the retry policy; the answer's JSON. ``empty_ok``:
    an answer without a body (a DELETE's 204) is ``{}``.

    ``idempotent=False`` (a request that creates something: an upload, a
    job): sent again only after a 429, which says it was not taken. After a
    timeout, a lost connection or a server error it may have arrived, so it
    is not sent twice."""
    transport = transport or default_transport
    host = urlsplit(request.url).hostname or request.url
    problem = ""
    for attempt in range(attempts):
        if attempt:
            sleep(wait)
        try:
            response = transport(request)
        except TimeoutError:
            if not idempotent:
                raise CloudError(f"{name}: {host} timed out; not sent again, as it may have arrived") from None
            problem, wait = f"{host} timed out", BACKOFF_SECONDS[min(attempt, len(BACKOFF_SECONDS) - 1)]
            continue
        except (ConnectionError, OSError):
            if not idempotent:
                raise CloudError(f"{name}: the connection to {host} failed; not sent again, as it may have "
                                 "arrived") from None
            problem, wait = f"could not reach {host}", BACKOFF_SECONDS[min(attempt, len(BACKOFF_SECONDS) - 1)]
            continue
        if 200 <= response.status < 300:
            if empty_ok and not response.body.strip():
                return {}
            try:
                data = json.loads(response.body)
            except ValueError:
                raise CloudError(f"{name} answered with something that is not JSON") from None
            if not isinstance(data, dict):
                raise CloudError(f"{name} answered with something that is not JSON")
            return data
        if 300 <= response.status < 400:
            target = urljoin(request.url, response.headers.get("location", ""))
            where = urlsplit(target).hostname or "an address it did not give"
            raise CloudError(f"{name} answered with a redirect to {where} (HTTP {response.status}). Palaver "
                             "does not follow redirects, so nothing was sent there; check the endpoint in Settings.")
        if response.status in (401, 403):
            raise CloudError(f"{name} refused the API key (HTTP {response.status}); check or replace it in Settings")
        if response.status in RETRY_STATUS and (idempotent or response.status == 429):
            problem, wait = f"HTTP {response.status}", _wait(response, attempt)
            continue
        raise _Rejected(response.status, redact(_provider_message(response.body), key))
    raise CloudError(f"{name} failed after {attempts} tr{'y' if attempts == 1 else 'ies'}: {problem}")


def _closed(schema: Any) -> Any:
    """``schema`` with every object closed (``additionalProperties: false``),
    as Anthropic's structured outputs want it."""
    if isinstance(schema, list):
        return [_closed(s) for s in schema]
    if not isinstance(schema, dict):
        return schema
    out = {k: _closed(v) for k, v in schema.items()}
    if out.get("type") == "object":
        out["additionalProperties"] = False
    return out


def _system(schema: dict, *, with_schema: bool) -> tuple[str, dict]:
    """The system prompt (the schema's description — the notes' language —
    said first) and the schema without that description."""
    schema = dict(schema)
    description = schema.pop("description", None)
    system = "Answer with a single JSON object that follows the given JSON schema, and nothing else."
    if with_schema:
        system = "Answer with a single JSON object that follows this JSON schema, and nothing else:\n" + json.dumps(schema)
    return (f"{description}\n\n{system}" if description else system), schema


def _json_object(text: str) -> dict[str, Any]:
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end < start:
        raise ValueError("no JSON object in the answer")
    out = json.loads(text[start : end + 1], strict=False)
    if not isinstance(out, dict):
        raise ValueError("the answer is not a JSON object")
    return out


def _parsed(ask: Callable[[], str], parse: Callable[[str], dict], name: str) -> dict:
    """Parse the answer; ask once more when it doesn't parse."""
    problem = None
    for _ in range(2):
        try:
            return parse(ask())
        except ValueError as exc:
            problem = exc
    raise CloudError(f"{name} did not return a valid answer: {redact(str(problem), None)}")


def anthropic_url(endpoint: str) -> str:
    parts = urlsplit(endpoint.strip())
    path = parts.path.rstrip("/")
    if not path.endswith("/messages"):
        path += "/messages" if path.endswith("/v1") else "/v1/messages"
    return urlunsplit(parts._replace(path=path))


def anthropic_runner(endpoint: str, model: str, api_key: str, *, parse: Callable[[str], dict] = _json_object,
                     transport: Transport | None = None, sleep: Callable[[float], None] = time.sleep,
                     timeout: float = TIMEOUT_SECONDS, max_tokens: int = MAX_OUTPUT_TOKENS,
                     name: str = "Anthropic API"):
    """The Messages API, with structured output (``output_config.format``)."""
    url = anthropic_url(endpoint)

    def run(prompt: str, schema: dict) -> dict:
        system, schema = _system(schema, with_schema=False)
        body = json.dumps({
            "model": model,
            "max_tokens": max_tokens,
            "system": system,
            "messages": [{"role": "user", "content": prompt}],
            "output_config": {"format": {"type": "json_schema", "schema": _closed(schema)}},
        }).encode()
        request = Request("POST", url, {"content-type": "application/json", "x-api-key": api_key,
                                        "anthropic-version": ANTHROPIC_VERSION}, body, timeout)

        def ask() -> str:
            data = send(request, name=name, key=api_key, transport=transport, sleep=sleep)
            stop = data.get("stop_reason")
            if stop == "max_tokens":
                raise CloudError(f"{name}: the answer was cut off at {max_tokens:,} tokens (thinking included); "
                                 "nothing was saved. Try again, or choose another model in Settings.")
            if stop == "refusal":
                raise CloudError(f"{name} declined to answer")
            blocks = data.get("content") if isinstance(data.get("content"), list) else []
            return "".join(b.get("text", "") for b in blocks if isinstance(b, dict) and b.get("type") == "text")

        return _parsed(ask, parse, name)

    return run


def chat_url(endpoint: str) -> str:
    """``…/chat/completions`` under the endpoint, keeping its query
    (Azure's ``?api-version=``)."""
    parts = urlsplit(endpoint.strip())
    path = parts.path.rstrip("/")
    if not path.endswith("/chat/completions"):
        path += "/chat/completions"
    return urlunsplit(parts._replace(path=path))


def is_azure(url: str) -> bool:
    host = urlsplit(url).hostname or ""
    return host.endswith(AZURE_SUFFIXES)


def _structured_unsupported(message: str) -> bool:
    """A 400 saying the endpoint can't do ``response_format`` / JSON schema."""
    m = message.casefold()
    if "response_format" in m or "json_schema" in m:
        return True
    return ("structured" in m or "schema" in m) and any(
        w in m for w in ("not supported", "unsupported", "does not support", "not support"))


def openai_runner(endpoint: str, model: str, api_key: str | None, *, parse: Callable[[str], dict] = _json_object,
                  transport: Transport | None = None, sleep: Callable[[float], None] = time.sleep,
                  timeout: float = TIMEOUT_SECONDS, name: str = "OpenAI-compatible endpoint",
                  auth: str = "auto"):
    """Chat Completions. The schema goes in the system prompt too, for
    gateways that ignore ``response_format``; one that rejects it is asked
    again without it. ``auth``: the key in an ``api-key`` header (Azure),
    as ``Authorization: Bearer``, or "auto" by the host."""
    url = chat_url(endpoint)
    headers = {"content-type": "application/json"}
    if auth not in AUTH_HEADERS:
        raise ValueError(f"auth must be one of {AUTH_HEADERS}")
    if api_key:
        as_api_key = auth == "api-key" or (auth == "auto" and is_azure(url))
        headers["api-key" if as_api_key else "authorization"] = api_key if as_api_key else f"Bearer {api_key}"

    def run(prompt: str, schema: dict) -> dict:
        system, plain = _system(schema, with_schema=True)
        payload: dict[str, Any] = {
            "model": model,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": prompt}],
            "response_format": {"type": "json_schema",
                                "json_schema": {"name": "answer", "schema": plain, "strict": False}},
        }

        def ask() -> str:
            request = Request("POST", url, headers, json.dumps(payload).encode(), timeout)
            try:
                data = send(request, name=name, key=api_key, transport=transport, sleep=sleep)
            except _Rejected as exc:
                if exc.status != 400 or "response_format" not in payload or not _structured_unsupported(
                        exc.provider_message):
                    raise
                del payload["response_format"]
                return ask()
            choices = data.get("choices") if isinstance(data.get("choices"), list) else []
            choice = choices[0] if choices and isinstance(choices[0], dict) else {}
            if choice.get("finish_reason") == "length":
                raise CloudError(f"{name}: the answer was cut off")
            if choice.get("finish_reason") == "content_filter":
                raise CloudError(f"{name} declined to answer (content filter)")
            message = choice.get("message") if isinstance(choice.get("message"), dict) else {}
            return str(message.get("content") or "")

        return _parsed(ask, parse, name)

    return run
