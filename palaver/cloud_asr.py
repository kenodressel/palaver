"""Transcription services in the cloud, over HTTP (#54): AssemblyAI, Soniox,
Mistral Voxtral and OpenAI-compatible endpoints. An adapter takes one piece
of audio (FLAC, 16 kHz mono) and returns the words it heard, with
timestamps in seconds from the start of that piece, so they can be lined up
with the speaker turns worked out on this Mac.

Only transcription.py makes adapters, and only for the provider the user
chose (providers.choose); nothing here decides to send anything. Requests
go through cloud_llm.send: the same transport, retries, refused redirects
and redacted keys as the language models.

Speaker diarization is never asked for: who spoke when stays on this Mac.

What a service keeps is deleted there as soon as the words are back
(AssemblyAI: the transcript, and the upload with it; Soniox: the
transcription and the file). A job that has not ended yet can't be
deleted: it gets CLEANUP_WAIT_SECONDS more to end, and what still can't be
deleted is left in ``adapter.pending`` for the caller to keep and retry
(``delete_pending``) until the service says it is gone. An AssemblyAI
upload that never became a job can't be deleted by anyone but AssemblyAI
(within 48 hours); it is noted with that date.

Requests that create something (uploads, jobs) are never sent twice after
a timeout or a server error, only after a 429 (cloud_llm.send,
``idempotent=False``): a second job would be a second copy at the service.
"""

from __future__ import annotations

import json
import logging
import re
import secrets
import time
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Any, Callable
from urllib.parse import urlsplit, urlunsplit

from . import cloud_llm
from .cloud_llm import CloudError, Request, Transport, is_azure, redact
from .models import Word

LOGGER = logging.getLogger(__name__)

FILENAME = "audio.flac"
CONTENT_TYPE = "audio/flac"
POLL_SECONDS = (2.0, 3.0, 5.0, 10.0)  # waits between status checks; the last one repeats
MIN_WAIT_SECONDS = 600.0  # how long a job may take: this, or twice the audio
CLEANUP_WAIT_SECONDS = 300.0  # more time for a job given up on to end, so it can be deleted
UPLOAD_KEPT = timedelta(hours=48)  # AssemblyAI deletes an upload without a transcript within this
NO_SPEECH = "no spoken audio"  # AssemblyAI's error for a clip without speech
UPLOAD_BYTES_PER_SECOND = 250_000  # a slow uplink, for an upload's timeout
MIN_TIMEOUT_SECONDS = 120.0
REQUEST_TIMEOUT_SECONDS = 60.0
# Two-letter codes for the language names Whisper-style endpoints answer with.
LANGUAGE_NAMES = {"german": "de", "english": "en", "french": "fr", "spanish": "es", "italian": "it",
                  "dutch": "nl", "portuguese": "pt", "polish": "pl", "czech": "cs", "turkish": "tr"}


@dataclass(frozen=True)
class Heard:
    words: list[Word]
    language: str | None = None
    billed_seconds: float | None = None


def language_code(value: Any) -> str | None:
    """"de", "de_de", "German" -> "de"; None when it is no language."""
    if not isinstance(value, str) or not value.strip():
        return None
    v = value.strip().lower().replace("-", "_")
    if len(v) == 2 and v.isalpha():
        return v
    if len(v) > 2 and v[2] == "_" and v[:2].isalpha():
        return v[:2]
    return LANGUAGE_NAMES.get(v)


def multipart(fields: list[tuple[str, str]], files: list[tuple[str, str, str, bytes]]) -> tuple[str, bytes]:
    """A multipart/form-data body: its content type and its bytes."""
    boundary = f"palaver-{secrets.token_hex(16)}"
    out = bytearray()
    for name, value in fields:
        out += f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n'.encode()
        out += value.encode() + b"\r\n"
    for name, filename, ctype, data in files:
        out += (f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'
                f"Content-Type: {ctype}\r\n\r\n").encode()
        out += data + b"\r\n"
    out += f"--{boundary}--\r\n".encode()
    return f"multipart/form-data; boundary={boundary}", bytes(out)


def terms(keyterms, *, limit: int, max_words: int) -> list[str]:
    """The keyterms a service takes: one line each, at most ``max_words``
    words, each once, the first ``limit``."""
    out, seen = [], set()
    for t in keyterms:
        t = " ".join(str(t).split())
        if not t or len(t.split()) > max_words or t.casefold() in seen:
            continue
        seen.add(t.casefold())
        out.append(t)
        if len(out) >= limit:
            break
    return out


def _upload_timeout(n_bytes: int) -> float:
    return max(MIN_TIMEOUT_SECONDS, n_bytes / UPLOAD_BYTES_PER_SECOND)


class JobFailed(CloudError):
    """The service ended the job with an error; ``reason`` is its (redacted) word."""

    def __init__(self, name: str, reason: str):
        super().__init__(f"{name} could not transcribe it: {reason}")
        self.reason = reason


@dataclass
class _Adapter:
    name: str
    model: str
    key: str | None = field(repr=False)
    transport: Transport | None = None
    sleep: Callable[[float], None] = time.sleep
    clock: Callable[[], float] = time.monotonic
    host: str = ""
    max_seconds: float = 0.0  # audio one request may carry
    max_bytes: int = 0
    pid: str = ""
    # What could not be deleted at the service: for the caller to keep and retry.
    pending: list[dict[str, Any]] = field(default_factory=list)

    def _send(self, method: str, url: str, headers: dict[str, str], body: bytes = b"", *,
              timeout: float = REQUEST_TIMEOUT_SECONDS, empty_ok: bool = False, attempts: int | None = None
              ) -> dict[str, Any]:
        return cloud_llm.send(Request(method, url, headers, body, timeout), name=self.name, key=self.key,
                              transport=self.transport, sleep=self.sleep, empty_ok=empty_ok,
                              idempotent=method != "POST", attempts=attempts or cloud_llm.ATTEMPTS)

    def _wait(self, fetch: Callable[[], dict], *, limit: float, failed: tuple[str, ...],
              message: str) -> dict[str, Any]:
        """Check the job until it is completed: a JobFailed when it ended
        with an error, a CloudError when it takes longer than ``limit``."""
        deadline = self.clock() + limit
        attempt = 0
        while True:
            data = fetch()
            status = data.get("status")
            if status == "completed":
                return data
            if status in failed:
                raise JobFailed(self.name, redact(str(data.get(message) or "no reason given"), self.key))
            if self.clock() > deadline:
                raise CloudError(f"{self.name} did not finish within {limit / 60:.0f} min")
            self.sleep(POLL_SECONDS[min(attempt, len(POLL_SECONDS) - 1)])
            attempt += 1

    def _job(self, fetch: Callable[[], dict], *, seconds: float, failed: tuple[str, ...], message: str,
             url: str, headers: dict[str, str], what: str) -> dict[str, Any]:
        """Wait for the job at ``url`` and delete it, however it ends: one
        given up on gets CLEANUP_WAIT_SECONDS more to end first."""
        ended = False
        try:
            data = self._wait(fetch, limit=max(MIN_WAIT_SECONDS, 2 * seconds), failed=failed, message=message)
            ended = True
            return data
        except JobFailed:
            ended = True
            raise
        finally:
            if not ended:
                try:
                    self._wait(fetch, limit=CLEANUP_WAIT_SECONDS, failed=failed, message=message)
                except Exception:
                    pass  # ended with an error, still running, or not reachable: the delete says
            self._forget(url, headers, what)

    def _forget(self, url: str, headers: dict[str, str], what: str) -> None:
        """Delete ``url`` at the service; what can't be deleted now goes to ``pending``."""
        try:
            self._send("DELETE", url, headers, empty_ok=True, attempts=1)
        except Exception as exc:
            if getattr(exc, "status", None) == 404:
                return  # gone already
            problem = redact(str(exc), self.key) if isinstance(exc, CloudError) else type(exc).__name__
            LOGGER.warning("could not delete the %s at %s (%s); trying again later", what, self.host, problem)
            self.pending.append({"provider": self.pid, "host": self.host, "what": what, "url": url,
                                 "since": _now(), "error": problem})


def _now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def _id(data: dict, what: str, name: str) -> str:
    value = data.get(what)
    if not isinstance(value, str) or not value or "/" in value:
        raise CloudError(f"{name} answered without a usable {what}")
    return value


def _ms(value: Any) -> float:
    return round(float(value) / 1000, 3)


def _confidence(value: Any) -> float | None:
    return None if value is None else round(float(value), 3)


# --- AssemblyAI ------------------------------------------------------------------------


class AssemblyAI(_Adapter):
    """Upload the audio, start a job, check it until it is done, delete it.
    https://www.assemblyai.com/docs/api-reference/transcripts/submit"""

    BASES = {"eu": "https://api.eu.assemblyai.com", "us": "https://api.assemblyai.com"}
    MAX_SECONDS = 5 * 3600.0  # it takes 10 h
    MAX_BYTES = 2_000_000_000  # an upload takes 2.2 GB

    def __init__(self, settings: dict, key: str | None, **kw):
        self.base = self.BASES.get(settings.get("region", "eu"), self.BASES["eu"])
        super().__init__("AssemblyAI", settings["model"], key, host=urlsplit(self.base).hostname,
                         max_seconds=self.MAX_SECONDS, max_bytes=self.MAX_BYTES, **kw)

    def transcribe(self, audio: bytes, *, seconds: float, language: str | None, keyterms,
                   fallback_language: str | None = None) -> Heard:
        auth = {"authorization": self.key or ""}
        uploaded = self._send("POST", f"{self.base}/v2/upload",
                              {**auth, "content-type": "application/octet-stream"}, audio,
                              timeout=_upload_timeout(len(audio)))
        upload_url = uploaded.get("upload_url")
        if not isinstance(upload_url, str) or not upload_url:
            raise CloudError(f"{self.name} answered the upload without an upload_url")
        job: dict[str, Any] = {"audio_url": upload_url, "speech_models": [self.model], "speaker_labels": False,
                               "punctuate": True, "format_text": True}
        if language:
            job["language_code"] = language
        else:  # German meetings switch to English and back
            job["language_detection"] = True
            # A clip of music or noise only: an empty transcript in that
            # language, instead of a failed job.
            job["language_detection_options"] = {"code_switching": True, "on_no_speech_detected": "fallback",
                                                 "fallback_language": fallback_language or "en"}
        chosen = terms(keyterms, limit=1000 if "3" in self.model else 200, max_words=6)
        if chosen:
            job["keyterms_prompt"] = chosen
        try:
            created = self._send("POST", f"{self.base}/v2/transcript",
                                 {**auth, "content-type": "application/json"}, json.dumps(job).encode())
            tid = _id(created, "id", self.name)
        except Exception:
            # Only deleting a transcript deletes its upload; this one has none.
            self.pending.append({"provider": self.pid, "host": self.host, "what": "upload", "url": None,
                                 "since": _now(),
                                 "until": (datetime.now().astimezone() + UPLOAD_KEPT).isoformat(timespec="seconds")})
            raise
        url = f"{self.base}/v2/transcript/{tid}"
        try:
            data = self._job(lambda: self._send("GET", url, auth), seconds=seconds, failed=("error",),
                             message="error", url=url, headers=auth, what="transcript")
        except JobFailed as exc:
            if NO_SPEECH in exc.reason.casefold():
                return Heard([], language or fallback_language, None)
            raise
        words = [Word(str(w["text"]).strip(), _ms(w["start"]), _ms(w["end"]), _confidence(w.get("confidence")))
                 for w in data.get("words") or [] if isinstance(w, dict) and str(w.get("text", "")).strip()]
        billed = data.get("audio_duration")
        return Heard(words, language_code(data.get("language_code")),
                     float(billed) if isinstance(billed, (int, float)) else None)


# --- Soniox ---------------------------------------------------------------------------------


def join_tokens(tokens: list[dict]) -> list[Word]:
    """Soniox's sub-word tokens as words: a leading space starts a word,
    anything else (word pieces, punctuation) extends the one before. A
    word is as sure as its least sure piece."""
    words: list[Word] = []
    for t in tokens:
        if not isinstance(t, dict) or not isinstance(t.get("text"), str):
            continue
        text, start, end = t["text"], _ms(t.get("start_ms", 0)), _ms(t.get("end_ms", 0))
        conf = _confidence(t.get("confidence"))
        if (text.startswith(" ") or not words) and text.strip():
            words.append(Word(text.strip(), start, end, conf))
        elif words and text.strip():
            last = words[-1]
            least = conf if last.confidence is None else last.confidence if conf is None else min(last.confidence, conf)
            words[-1] = Word(last.text + text.strip(), last.start, end, least)
    return words


class Soniox(_Adapter):
    """Upload the file, start a transcription, check it, read the tokens,
    delete both. https://soniox.com/docs/stt/async/async-transcription"""

    BASES = {"eu": "https://api.eu.soniox.com", "us": "https://api.soniox.com"}
    MAX_SECONDS = 4.5 * 3600  # it takes 300 min
    MAX_BYTES = 1_000_000_000

    def __init__(self, settings: dict, key: str | None, **kw):
        self.base = self.BASES.get(settings.get("region", "eu"), self.BASES["eu"])
        super().__init__("Soniox", settings["model"], key, host=urlsplit(self.base).hostname,
                         max_seconds=self.MAX_SECONDS, max_bytes=self.MAX_BYTES, **kw)

    def transcribe(self, audio: bytes, *, seconds: float, language: str | None, keyterms,
                   fallback_language: str | None = None) -> Heard:
        auth = {"authorization": f"Bearer {self.key or ''}"}
        ctype, body = multipart([], [("file", FILENAME, CONTENT_TYPE, audio)])
        uploaded = self._send("POST", f"{self.base}/v1/files", {**auth, "content-type": ctype}, body,
                              timeout=_upload_timeout(len(body)))
        fid = _id(uploaded, "id", self.name)
        try:
            job: dict[str, Any] = {"model": self.model, "file_id": fid, "enable_speaker_diarization": False,
                                   "enable_language_identification": True}
            if language:
                job["language_hints"] = [language]
            chosen = terms(keyterms, limit=500, max_words=10)
            if chosen:
                job["context"] = {"terms": chosen}
            created = self._send("POST", f"{self.base}/v1/transcriptions",
                                 {**auth, "content-type": "application/json"}, json.dumps(job).encode())
            tid = _id(created, "id", self.name)
            url = f"{self.base}/v1/transcriptions/{tid}"
            data = {}

            def fetch():
                status = self._send("GET", url, auth)
                if status.get("status") == "completed" and not data:
                    data.update(self._send("GET", f"{url}/transcript", auth))
                return status

            status = self._job(fetch, seconds=seconds, failed=("error", "failed"), message="error_message",
                               url=url, headers=auth, what="transcription")
        finally:
            self._forget(f"{self.base}/v1/files/{fid}", auth, "file")
        tokens = [t for t in data.get("tokens") or [] if isinstance(t, dict)]
        languages = Counter(language_code(t.get("language")) for t in tokens if t.get("language"))
        billed = status.get("audio_duration_ms")
        return Heard(join_tokens(tokens), languages.most_common(1)[0][0] if languages else None,
                     _ms(billed) if isinstance(billed, (int, float)) else None)


# --- OpenAI-compatible, and Mistral ---------------------------------------------------------


def transcription_url(endpoint: str) -> str:
    """``…/audio/transcriptions`` under the endpoint, keeping its query
    (Azure's ``?api-version=``)."""
    parts = urlsplit(endpoint.strip())
    path = parts.path.rstrip("/")
    if not path.endswith("/audio/transcriptions"):
        path += "/audio/transcriptions"
    return urlunsplit(parts._replace(path=path))


def _norm(text: str) -> str:
    return re.sub(r"\W", "", text.casefold())


def _punctuated(words: list[Word], segments: list[dict]) -> list[Word]:
    """Whisper's words come without punctuation, its segments with it: where
    a segment's text has the same words, its spelling goes onto them."""
    out = list(words)
    for seg in segments:
        try:
            start, end = float(seg["start"]), float(seg["end"])
        except (KeyError, TypeError, ValueError):
            continue
        idx = [i for i, w in enumerate(out) if start - 0.05 <= w.start <= end + 0.05]
        tokens = str(seg.get("text", "")).split()
        if idx and len(tokens) == len(idx) and all(_norm(t) == _norm(out[i].text) for t, i in zip(tokens, idx)):
            for t, i in zip(tokens, idx):
                out[i] = Word(t, out[i].start, out[i].end, out[i].confidence)
    return out


def _spread(segments: list[dict]) -> list[Word]:
    """Words over each segment's time, evenly: a service that times only
    its segments still lines up with the speaker turns about as well."""
    out: list[Word] = []
    for seg in segments:
        try:
            start, end = float(seg["start"]), float(seg["end"])
        except (KeyError, TypeError, ValueError):
            continue
        tokens = str(seg.get("text", "")).split()
        if not tokens or end < start:
            continue
        step = (end - start) / len(tokens)
        out += [Word(t, round(start + i * step, 3), round(start + (i + 1) * step, 3)) for i, t in enumerate(tokens)]
    return out


class OpenAICompatible(_Adapter):
    """``/audio/transcriptions`` with ``verbose_json`` and word timestamps:
    OpenAI (whisper-1), Azure OpenAI, a company or self-hosted gateway.
    https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create"""

    MAX_SECONDS = 10 * 60.0  # 16 kHz 16-bit audio: under 25 MB even uncompressed
    MAX_BYTES = 24 * 1024 * 1024  # OpenAI takes 25 MB

    def __init__(self, settings: dict, key: str | None, *, name: str = "OpenAI-compatible endpoint", **kw):
        self.url = transcription_url(settings["endpoint"])
        auth = settings.get("auth", "auto")
        self.headers: dict[str, str] = {}
        if key:
            as_api_key = auth == "api-key" or (auth == "auto" and is_azure(self.url))
            self.headers["api-key" if as_api_key else "authorization"] = key if as_api_key else f"Bearer {key}"
        super().__init__(name, settings["model"], key, host=urlsplit(self.url).hostname or "",
                         max_seconds=self.MAX_SECONDS, max_bytes=self.MAX_BYTES, **kw)

    def _fields(self, language: str | None, keyterms) -> list[tuple[str, str]]:
        fields = [("model", self.model), ("response_format", "verbose_json"),
                  ("timestamp_granularities[]", "word"), ("timestamp_granularities[]", "segment")]
        if language:
            fields.append(("language", language))
        chosen = terms(keyterms, limit=60, max_words=6)  # Whisper reads at most 224 tokens of prompt
        if chosen:
            fields.append(("prompt", "Glossary: " + ", ".join(chosen) + "."))
        return fields

    def transcribe(self, audio: bytes, *, seconds: float, language: str | None, keyterms,
                   fallback_language: str | None = None) -> Heard:
        ctype, body = multipart(self._fields(language, keyterms), [("file", FILENAME, CONTENT_TYPE, audio)])
        data = self._send("POST", self.url, {**self.headers, "content-type": ctype}, body,
                          timeout=max(_upload_timeout(len(body)), 4 * seconds))
        segments = [s for s in data.get("segments") or [] if isinstance(s, dict)]
        raw = data.get("words") or [w for s in segments for w in (s.get("words") or [])]
        words = []
        for w in raw:
            if not isinstance(w, dict):
                continue
            text = str(w.get("word", w.get("text", ""))).strip()
            try:
                if text:
                    words.append(Word(text, round(float(w["start"]), 3), round(float(w["end"]), 3)))
            except (KeyError, TypeError, ValueError):
                continue
        if words:
            words = _punctuated(words, segments)
        elif segments:
            words = _spread(segments)
        elif str(data.get("text") or "").strip():
            raise CloudError(f"{self.name} ({self.model}) answers without timestamps, so its text can't be lined "
                             "up with who spoke. Choose a model that gives them (OpenAI: whisper-1).")
        usage = data.get("usage") if isinstance(data.get("usage"), dict) else {}
        billed = data.get("duration", usage.get("seconds", usage.get("prompt_audio_seconds")))
        return Heard(words, language_code(data.get("language")),
                     float(billed) if isinstance(billed, (int, float)) else None)


class Mistral(OpenAICompatible):
    """Voxtral through Mistral's ``/v1/audio/transcriptions``: word and
    segment timestamps (segments spread into words when no words come
    back) and ``context_bias``, one token per term (spaces become
    underscores); no ``language`` (Mistral takes it only without
    timestamps). https://docs.mistral.ai/api/endpoint/audio/transcriptions"""

    URL = "https://api.mistral.ai/v1"
    MAX_SECONDS = 30 * 60.0  # it takes up to 3 h; its upload limit is not documented

    def __init__(self, settings: dict, key: str | None, **kw):
        super().__init__({"endpoint": self.URL, "model": settings["model"], "auth": "bearer"}, key,
                         name="Mistral", **kw)

    def _fields(self, language: str | None, keyterms) -> list[tuple[str, str]]:
        return [("model", self.model), ("timestamp_granularities", "word"), ("timestamp_granularities", "segment"),
                *(("context_bias", t.replace(" ", "_")) for t in terms(keyterms, limit=100, max_words=6))]


ADAPTERS: dict[str, Callable[..., _Adapter]] = {
    "assemblyai": AssemblyAI,
    "soniox": Soniox,
    "mistral": Mistral,
    "openai-transcribe": lambda settings, key, **kw: OpenAICompatible(settings, key, name="OpenAI-compatible", **kw),
}


def make(pid: str, settings: dict, key: str | None, *, transport: Transport | None = None,
         sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.monotonic) -> _Adapter:
    """The adapter for provider ``pid`` with its ``settings`` (providers.settings_of)."""
    if pid not in ADAPTERS:
        raise ValueError(f"no transcription service {pid!r}")
    adapter = ADAPTERS[pid](settings, key, transport=transport, sleep=sleep, clock=clock)
    adapter.pid = pid
    return adapter


# Where a pending deletion may be sent, by service: its own hosts and paths
# only, so a changed file can't send a key anywhere else.
_DELETABLE = {
    "assemblyai": (tuple(AssemblyAI.BASES.values()), re.compile(r"/v2/transcript/[\w-]+")),
    "soniox": (tuple(Soniox.BASES.values()), re.compile(r"/v1/(transcriptions|files)/[\w-]+")),
}


def _auth(pid: str, key: str | None) -> dict[str, str]:
    return {"authorization": key or ""} if pid == "assemblyai" else {"authorization": f"Bearer {key or ''}"}


def delete_pending(entry: dict, key: str | None, *, transport: Transport | None = None,
                   now: datetime | None = None) -> bool:
    """Try once more to delete what ``entry`` (from ``adapter.pending``)
    names. True when it is done with: deleted, gone already, nothing to
    call that is past its date, or not a deletion Palaver would send;
    False to keep it and try again later."""
    url = entry.get("url")
    if not url:  # nothing to call: the service deletes it by itself
        try:
            return (now or datetime.now().astimezone()) >= datetime.fromisoformat(entry["until"])
        except (KeyError, TypeError, ValueError):
            return True
    pid = entry.get("provider")
    bases, path = _DELETABLE.get(pid, ((), None))
    parts = urlsplit(url)
    if path is None or f"{parts.scheme}://{parts.netloc}" not in bases or not path.fullmatch(parts.path) \
            or parts.query or parts.fragment:
        LOGGER.warning("dropped a pending deletion Palaver would not send: %s", parts.netloc)
        return True
    if not key:
        return False  # no key now: kept until there is one again
    try:
        cloud_llm.send(Request("DELETE", url, _auth(pid, key), b"", REQUEST_TIMEOUT_SECONDS), name=pid, key=key,
                       transport=transport, empty_ok=True, attempts=1)
    except Exception as exc:
        return getattr(exc, "status", None) == 404
    return True
