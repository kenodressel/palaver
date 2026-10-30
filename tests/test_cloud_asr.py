"""Cloud transcription over HTTP (palaver/cloud_asr.py), through fake
transports and a server on 127.0.0.1: the requests each provider gets,
how its answer becomes words with timestamps, and its errors."""

import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

from palaver import cloud_asr, cloud_llm
from palaver.cloud_llm import CloudError, Request, Response

KEY = "aai-SECRET-abcdefghijklmnopqrstuvwxyz0123"
AUDIO = b"fLaC" + b"\x00" * 64


def ok(payload, status=200):
    return Response(status, {}, json.dumps(payload).encode())


class Route:
    """Answers by method and URL: each route's answers in turn (the last
    one again when they run out). Records the requests and the waits."""

    def __init__(self, routes):
        self.routes = {k: list(v) if isinstance(v, list) else [v] for k, v in routes.items()}
        self.requests: list[Request] = []
        self.waits: list[float] = []

    def __call__(self, request: Request) -> Response:
        self.requests.append(request)
        for (method, url), answers in self.routes.items():
            if request.method == method and request.url == url:
                answer = answers.pop(0) if len(answers) > 1 else answers[0]
                if isinstance(answer, BaseException):
                    raise answer
                return answer
        raise AssertionError(f"unexpected {request.method} {request.url}")

    def sleep(self, seconds):
        self.waits.append(seconds)

    def sent(self, method, url):
        return [r for r in self.requests if r.method == method and r.url == url]


def multipart_fields(request: Request) -> dict[str, list]:
    """The parts of a multipart/form-data body: name -> [value or (filename, content type, bytes)]."""
    ctype = request.headers["content-type"]
    assert ctype.startswith("multipart/form-data; boundary=")
    boundary = ctype.split("boundary=", 1)[1].encode()
    out: dict[str, list] = {}
    for part in request.body.split(b"--" + boundary)[1:]:
        if part.startswith(b"--"):
            break
        head, _, body = part.partition(b"\r\n\r\n")
        body = body[:-2]  # the CRLF before the next boundary
        headers = dict(line.split(": ", 1) for line in head.decode().strip().split("\r\n"))
        disposition = headers["Content-Disposition"]
        name = disposition.split('name="', 1)[1].split('"', 1)[0]
        if 'filename="' in disposition:
            filename = disposition.split('filename="', 1)[1].split('"', 1)[0]
            out.setdefault(name, []).append((filename, headers.get("Content-Type"), body))
        else:
            out.setdefault(name, []).append(body.decode())
    return out


# --- AssemblyAI -----------------------------------------------------------------------

AAI_EU = "https://api.eu.assemblyai.com"


def assemblyai_routes(status_answers, *, base=AAI_EU, transcript_id="t1"):
    return {
        ("POST", f"{base}/v2/upload"): ok({"upload_url": "https://cdn.assemblyai.test/upload/abc"}),
        ("POST", f"{base}/v2/transcript"): ok({"id": transcript_id, "status": "queued"}),
        ("GET", f"{base}/v2/transcript/{transcript_id}"): status_answers,
        ("DELETE", f"{base}/v2/transcript/{transcript_id}"): ok({"id": transcript_id}),
    }


AAI_DONE = ok({
    "id": "t1", "status": "completed", "language_code": "de", "audio_duration": 12,
    "words": [
        {"text": "Hallo", "start": 1200, "end": 1500, "confidence": 0.98, "speaker": None},
        {"text": "zusammen.", "start": 1550, "end": 2100, "confidence": 0.71, "speaker": None},
    ],
})


def test_assemblyai_uploads_the_audio_starts_a_job_polls_and_deletes_it():
    fake = Route(assemblyai_routes([ok({"id": "t1", "status": "processing"}), AAI_DONE]))
    a = cloud_asr.make("assemblyai", {"model": "universal-3-5-pro", "region": "eu"}, KEY,
                       transport=fake, sleep=fake.sleep)
    heard = a.transcribe(AUDIO, seconds=12.0, language=None, keyterms=["Attakring", "Karel Kralek"],
                         fallback_language="de")

    upload = fake.requests[0]
    assert upload.url == f"{AAI_EU}/v2/upload" and upload.body == AUDIO
    assert upload.headers["authorization"] == KEY
    assert upload.headers["content-type"] == "application/octet-stream"
    job = json.loads(fake.sent("POST", f"{AAI_EU}/v2/transcript")[0].body)
    assert job["audio_url"] == "https://cdn.assemblyai.test/upload/abc"
    assert job["speech_models"] == ["universal-3-5-pro"]
    assert job["language_detection"] is True
    options = job["language_detection_options"]
    assert options["code_switching"] is True
    # Music or noise without speech is an empty transcript, not a failed one.
    assert options["on_no_speech_detected"] == "fallback" and options["fallback_language"] == "de"
    assert "language_code" not in job
    assert job["keyterms_prompt"] == ["Attakring", "Karel Kralek"]
    assert job["speaker_labels"] is False  # speakers are told apart on this Mac
    assert len(fake.sent("GET", f"{AAI_EU}/v2/transcript/t1")) == 2 and fake.waits
    assert fake.sent("DELETE", f"{AAI_EU}/v2/transcript/t1")  # not kept there longer than needed

    assert [(w.text, w.start, w.end, w.confidence) for w in heard.words] == [
        ("Hallo", 1.2, 1.5, 0.98), ("zusammen.", 1.55, 2.1, 0.71)]
    assert heard.language == "de" and heard.billed_seconds == 12
    assert a.host == "api.eu.assemblyai.com"


def test_assemblyai_takes_the_language_when_one_is_set_and_the_us_servers():
    base = "https://api.assemblyai.com"
    fake = Route(assemblyai_routes([AAI_DONE], base=base))
    a = cloud_asr.make("assemblyai", {"model": "universal-3-5-pro", "region": "us"}, KEY,
                       transport=fake, sleep=fake.sleep)
    a.transcribe(AUDIO, seconds=12.0, language="de", keyterms=[])
    job = json.loads(fake.sent("POST", f"{base}/v2/transcript")[0].body)
    assert job["language_code"] == "de" and "language_detection" not in job
    assert "keyterms_prompt" not in job


def test_assemblyai_keyterms_are_capped_to_what_it_takes():
    fake = Route(assemblyai_routes([AAI_DONE]))
    a = cloud_asr.make("assemblyai", {"model": "universal-3-5-pro", "region": "eu"}, KEY,
                       transport=fake, sleep=fake.sleep)
    terms = [f"Term{i}" for i in range(1500)] + ["one two three four five six seven"]
    a.transcribe(AUDIO, seconds=12.0, language=None, keyterms=terms)
    job = json.loads(fake.sent("POST", f"{AAI_EU}/v2/transcript")[0].body)
    assert len(job["keyterms_prompt"]) == 1000
    assert all(len(t.split()) <= 6 for t in job["keyterms_prompt"])


def test_assemblyai_failed_job_is_an_error_without_the_key():
    fake = Route(assemblyai_routes([ok({"id": "t1", "status": "error", "error": f"bad audio {KEY}"})]))
    a = cloud_asr.make("assemblyai", {"model": "universal-3-5-pro", "region": "eu"}, KEY,
                       transport=fake, sleep=fake.sleep)
    with pytest.raises(CloudError) as err:
        a.transcribe(AUDIO, seconds=12.0, language=None, keyterms=[])
    assert "bad audio" in str(err.value) and KEY not in str(err.value)


class Job:
    """An AssemblyAI job that is processing until ``done`` is set: deleting
    it meanwhile is refused (409), afterwards it works, then it is gone (404)."""

    def __init__(self):
        self.done, self.deleted, self.requests = False, False, []

    def __call__(self, request: Request) -> Response:
        self.requests.append(request)
        url = request.url
        if url == f"{AAI_EU}/v2/upload":
            return ok({"upload_url": "https://cdn.assemblyai.test/upload/abc"})
        if request.method == "POST" and url == f"{AAI_EU}/v2/transcript":
            return ok({"id": "t1", "status": "queued"})
        if url == f"{AAI_EU}/v2/transcript/t1":
            if self.deleted:
                return ok({"error": "Transcript not found"}, status=404)
            if request.method == "DELETE":
                if not self.done:
                    return ok({"error": "Transcript is still processing"}, status=409)
                self.deleted = True
                return ok({"id": "t1", "status": "completed"})
            return ok({"id": "t1", "status": "completed" if self.done else "processing", "words": []})
        raise AssertionError(f"unexpected {request.method} {url}")

    def count(self, method, url):
        return sum(1 for r in self.requests if r.method == method and r.url == url)


def ticking(step=100):
    clock = iter(range(0, 10_000_000, step))
    return lambda: float(next(clock))


def test_a_job_that_takes_too_long_is_deleted_once_it_is_done_or_left_for_later():
    job = Job()
    a = cloud_asr.make("assemblyai", {"model": "universal-3-5-pro", "region": "eu"}, KEY,
                       transport=job, sleep=lambda s: None, clock=ticking())
    with pytest.raises(CloudError, match="did not finish"):
        a.transcribe(AUDIO, seconds=60.0, language=None, keyterms=[])
    assert job.count("POST", f"{AAI_EU}/v2/transcript") == 1
    # It waited a while longer for the job to end, then asked to delete it: refused while processing.
    assert job.count("DELETE", f"{AAI_EU}/v2/transcript/t1") == 1 and not job.deleted
    (left,) = a.pending
    assert left["url"] == f"{AAI_EU}/v2/transcript/t1" and left["provider"] == "assemblyai"
    assert KEY not in json.dumps(left)

    job.done = True  # later: the next `process` deletes it
    assert cloud_asr.delete_pending(left, KEY, transport=job) is True and job.deleted
    assert cloud_asr.delete_pending(left, KEY, transport=job) is True  # gone already (404): done too


def test_a_job_that_ends_while_waiting_to_delete_it_is_deleted_at_once():
    job = Job()
    polls = {"n": 0}

    def transport(request):
        if request.method == "GET":
            polls["n"] += 1
            if polls["n"] > 8:  # finishes after the deadline, within the extra wait
                job.done = True
        return job(request)

    a = cloud_asr.make("assemblyai", {"model": "universal-3-5-pro", "region": "eu"}, KEY,
                       transport=transport, sleep=lambda s: None, clock=ticking())
    with pytest.raises(CloudError, match="did not finish"):
        a.transcribe(AUDIO, seconds=60.0, language=None, keyterms=[])
    assert job.deleted and a.pending == []


def test_no_speech_in_a_chunk_is_an_empty_result():
    no_speech = ok({"id": "t1", "status": "error",
                    "error": "language_detection cannot be performed on files with no spoken audio."})
    fake = Route(assemblyai_routes([no_speech]))
    a = cloud_asr.make("assemblyai", {"model": "universal-3-5-pro", "region": "eu"}, KEY,
                       transport=fake, sleep=fake.sleep)
    heard = a.transcribe(AUDIO, seconds=12.0, language=None, keyterms=[], fallback_language="de")
    assert heard.words == [] and fake.sent("DELETE", f"{AAI_EU}/v2/transcript/t1")
    empty = ok({"id": "t1", "status": "completed", "text": "", "words": [], "language_code": "de"})
    fake = Route(assemblyai_routes([empty]))
    a = cloud_asr.make("assemblyai", {"model": "universal-3-5-pro", "region": "eu"}, KEY,
                       transport=fake, sleep=fake.sleep)
    assert a.transcribe(AUDIO, seconds=12.0, language=None, keyterms=[], fallback_language="de").words == []


def test_starting_a_job_is_never_sent_twice_after_a_timeout():
    routes = assemblyai_routes([AAI_DONE])
    routes[("POST", f"{AAI_EU}/v2/transcript")] = TimeoutError("timed out")
    fake = Route(routes)
    a = cloud_asr.make("assemblyai", {"model": "universal-3-5-pro", "region": "eu"}, KEY,
                       transport=fake, sleep=fake.sleep)
    with pytest.raises(CloudError, match="not sent again"):
        a.transcribe(AUDIO, seconds=12.0, language=None, keyterms=[])
    assert len(fake.sent("POST", f"{AAI_EU}/v2/transcript")) == 1
    # AssemblyAI can't delete an upload by itself: it is noted with when it expires.
    (left,) = a.pending
    assert left["what"] == "upload" and left["url"] is None and left["until"]


@pytest.mark.parametrize("status", [500, 503, 504, 409])
def test_starting_a_job_is_not_retried_on_an_unclear_error(status):
    routes = assemblyai_routes([AAI_DONE])
    routes[("POST", f"{AAI_EU}/v2/transcript")] = ok({"error": "oops"}, status=status)
    fake = Route(routes)
    a = cloud_asr.make("assemblyai", {"model": "universal-3-5-pro", "region": "eu"}, KEY,
                       transport=fake, sleep=fake.sleep)
    with pytest.raises(CloudError):
        a.transcribe(AUDIO, seconds=12.0, language=None, keyterms=[])
    assert len(fake.sent("POST", f"{AAI_EU}/v2/transcript")) == 1


def test_a_rate_limit_is_retried_it_created_nothing():
    routes = assemblyai_routes([AAI_DONE])
    routes[("POST", f"{AAI_EU}/v2/transcript")] = [ok({"error": "slow down"}, status=429),
                                                   ok({"id": "t1", "status": "queued"})]
    fake = Route(routes)
    a = cloud_asr.make("assemblyai", {"model": "universal-3-5-pro", "region": "eu"}, KEY,
                       transport=fake, sleep=fake.sleep)
    assert len(a.transcribe(AUDIO, seconds=12.0, language=None, keyterms=[]).words) == 2
    assert len(fake.sent("POST", f"{AAI_EU}/v2/transcript")) == 2


def test_an_upload_is_not_sent_twice_after_a_timeout():
    fake = Route({("POST", f"{AAI_EU}/v2/upload"): TimeoutError("timed out")})
    a = cloud_asr.make("assemblyai", {"model": "universal-3-5-pro", "region": "eu"}, KEY,
                       transport=fake, sleep=fake.sleep)
    with pytest.raises(CloudError):
        a.transcribe(AUDIO, seconds=12.0, language=None, keyterms=[])
    assert len(fake.requests) == 1


def test_a_pending_deletion_only_goes_to_the_service_s_own_hosts():
    sent = []
    entry = {"provider": "assemblyai", "what": "transcript", "url": "https://evil.test/v2/transcript/t1"}
    assert cloud_asr.delete_pending(entry, KEY, transport=lambda r: sent.append(r)) is True  # dropped
    assert sent == []


def test_a_refused_key_is_said_plainly():
    fake = Route({("POST", f"{AAI_EU}/v2/upload"): ok({"error": "Invalid API key"}, status=401)})
    a = cloud_asr.make("assemblyai", {"model": "universal-3-5-pro", "region": "eu"}, KEY,
                       transport=fake, sleep=fake.sleep)
    with pytest.raises(CloudError, match="refused the API key"):
        a.transcribe(AUDIO, seconds=12.0, language=None, keyterms=[])
    assert len(fake.requests) == 1


def test_a_redirect_is_not_followed():
    fake = Route({("POST", f"{AAI_EU}/v2/upload"): Response(302, {"location": "https://evil.test/x"}, b"")})
    a = cloud_asr.make("assemblyai", {"model": "universal-3-5-pro", "region": "eu"}, KEY,
                       transport=fake, sleep=fake.sleep)
    with pytest.raises(CloudError, match="redirect to evil.test"):
        a.transcribe(AUDIO, seconds=12.0, language=None, keyterms=[])
    assert len(fake.requests) == 1


# --- Soniox ---------------------------------------------------------------------------

SONIOX_EU = "https://api.eu.soniox.com"


def soniox_routes(base=SONIOX_EU):
    return {
        ("POST", f"{base}/v1/files"): ok({"id": "f1"}, status=201),
        ("POST", f"{base}/v1/transcriptions"): ok({"id": "tr1", "status": "queued"}, status=201),
        ("GET", f"{base}/v1/transcriptions/tr1"): [ok({"id": "tr1", "status": "transcribing"}),
                                                   ok({"id": "tr1", "status": "completed", "audio_duration_ms": 9000})],
        ("GET", f"{base}/v1/transcriptions/tr1/transcript"): ok({"id": "tr1", "text": "Hallo Karel.", "tokens": [
            {"text": "Hal", "start_ms": 100, "end_ms": 200, "confidence": 0.99, "language": "de"},
            {"text": "lo", "start_ms": 200, "end_ms": 400, "confidence": 0.8, "language": "de"},
            {"text": " Ka", "start_ms": 500, "end_ms": 600, "confidence": 0.95, "language": "de"},
            {"text": "rel", "start_ms": 600, "end_ms": 800, "confidence": 0.97, "language": "de"},
            {"text": ".", "start_ms": 800, "end_ms": 820, "confidence": 0.99, "language": "de"},
        ]}),
        ("DELETE", f"{base}/v1/transcriptions/tr1"): Response(204, {}, b""),
        ("DELETE", f"{base}/v1/files/f1"): Response(204, {}, b""),
    }


def test_soniox_uploads_transcribes_reads_the_tokens_and_deletes_both():
    fake = Route(soniox_routes())
    s = cloud_asr.make("soniox", {"model": "stt-async-v5", "region": "eu"}, KEY, transport=fake, sleep=fake.sleep)
    heard = s.transcribe(AUDIO, seconds=9.0, language="de", keyterms=["Karel"])

    upload = fake.sent("POST", f"{SONIOX_EU}/v1/files")[0]
    assert upload.headers["authorization"] == f"Bearer {KEY}"
    assert multipart_fields(upload)["file"][0][2] == AUDIO
    job = json.loads(fake.sent("POST", f"{SONIOX_EU}/v1/transcriptions")[0].body)
    assert job["model"] == "stt-async-v5" and job["file_id"] == "f1"
    assert job["enable_speaker_diarization"] is False
    assert job["language_hints"] == ["de"] and job["enable_language_identification"] is True
    assert job["context"] == {"terms": ["Karel"]}
    assert fake.sent("DELETE", f"{SONIOX_EU}/v1/transcriptions/tr1") and fake.sent("DELETE", f"{SONIOX_EU}/v1/files/f1")

    assert [(w.text, w.start, w.end, w.confidence) for w in heard.words] == [
        ("Hallo", 0.1, 0.4, 0.8), ("Karel.", 0.5, 0.82, 0.95)]
    assert heard.language == "de" and heard.billed_seconds == 9.0


def test_soniox_without_a_language_sends_no_hints():
    fake = Route(soniox_routes(base="https://api.soniox.com"))
    s = cloud_asr.make("soniox", {"model": "stt-async-v5", "region": "us"}, KEY, transport=fake, sleep=fake.sleep)
    s.transcribe(AUDIO, seconds=9.0, language=None, keyterms=[])
    job = json.loads(fake.sent("POST", "https://api.soniox.com/v1/transcriptions")[0].body)
    assert "language_hints" not in job and "context" not in job


def test_soniox_failed_transcription_is_an_error_and_the_upload_is_deleted():
    routes = soniox_routes()
    routes[("GET", f"{SONIOX_EU}/v1/transcriptions/tr1")] = ok({"id": "tr1", "status": "error",
                                                              "error_message": "audio could not be decoded"})
    fake = Route(routes)
    s = cloud_asr.make("soniox", {"model": "stt-async-v5", "region": "eu"}, KEY, transport=fake, sleep=fake.sleep)
    with pytest.raises(CloudError, match="audio could not be decoded"):
        s.transcribe(AUDIO, seconds=9.0, language=None, keyterms=[])
    assert fake.sent("DELETE", f"{SONIOX_EU}/v1/files/f1")


# --- OpenAI-compatible and Mistral ------------------------------------------------------

OPENAI_ANSWER = {
    "language": "german", "duration": 6.5, "text": "Hallo, zusammen. Wie geht's?",
    "segments": [{"id": 0, "start": 0.4, "end": 2.0, "text": " Hallo, zusammen."},
                 {"id": 1, "start": 3.0, "end": 4.1, "text": " Wie geht's?"}],
    "words": [{"word": "Hallo", "start": 0.4, "end": 0.9}, {"word": "zusammen", "start": 1.0, "end": 2.0},
              {"word": "Wie", "start": 3.0, "end": 3.3}, {"word": "geht's", "start": 3.4, "end": 4.1}],
}


def test_openai_compatible_sends_multipart_with_word_timestamps():
    url = "https://api.openai.com/v1/audio/transcriptions"
    fake = Route({("POST", url): ok(OPENAI_ANSWER)})
    o = cloud_asr.make("openai-transcribe", {"endpoint": "https://api.openai.com/v1", "model": "whisper-1",
                                             "auth": "auto"}, KEY, transport=fake, sleep=fake.sleep)
    heard = o.transcribe(AUDIO, seconds=6.5, language="de", keyterms=["Attakring", "Karel"])

    (req,) = fake.requests
    assert req.headers["authorization"] == f"Bearer {KEY}"
    fields = multipart_fields(req)
    assert fields["model"] == ["whisper-1"] and fields["response_format"] == ["verbose_json"]
    assert sorted(fields["timestamp_granularities[]"]) == ["segment", "word"]
    assert fields["language"] == ["de"]
    assert "Attakring" in fields["prompt"][0] and "Karel" in fields["prompt"][0]
    filename, ctype, data = fields["file"][0]
    assert filename.endswith(".flac") and ctype == "audio/flac" and data == AUDIO
    # The segments' punctuation goes back onto the words.
    assert [w.text for w in heard.words] == ["Hallo,", "zusammen.", "Wie", "geht's?"]
    assert heard.words[0].start == 0.4 and heard.language == "de" and heard.billed_seconds == 6.5


def test_openai_compatible_on_azure_keeps_the_query_and_uses_the_api_key_header():
    endpoint = "https://acme.openai.azure.com/openai/deployments/whisper?api-version=2024-06-01"
    url = "https://acme.openai.azure.com/openai/deployments/whisper/audio/transcriptions?api-version=2024-06-01"
    fake = Route({("POST", url): ok(OPENAI_ANSWER)})
    o = cloud_asr.make("openai-transcribe", {"endpoint": endpoint, "model": "whisper", "auth": "auto"}, KEY,
                       transport=fake, sleep=fake.sleep)
    o.transcribe(AUDIO, seconds=6.5, language=None, keyterms=[])
    assert fake.requests[0].headers["api-key"] == KEY and "authorization" not in fake.requests[0].headers
    assert "language" not in multipart_fields(fake.requests[0])


def test_openai_compatible_without_timestamps_is_refused_not_guessed():
    url = "https://gw.test/v1/audio/transcriptions"
    fake = Route({("POST", url): ok({"text": "Hallo zusammen"})})
    o = cloud_asr.make("openai-transcribe", {"endpoint": "https://gw.test/v1", "model": "gpt-4o-transcribe",
                                             "auth": "auto"}, KEY, transport=fake, sleep=fake.sleep)
    with pytest.raises(CloudError, match="timestamps"):
        o.transcribe(AUDIO, seconds=3.0, language=None, keyterms=[])


def test_openai_compatible_segments_without_words_get_words_spread_over_them():
    url = "https://gw.test/v1/audio/transcriptions"
    fake = Route({("POST", url): ok({"segments": [{"start": 1.0, "end": 3.0, "text": "eins zwei drei vier"}]})})
    o = cloud_asr.make("openai-transcribe", {"endpoint": "https://gw.test/v1", "model": "m", "auth": "auto"},
                       None, transport=fake, sleep=fake.sleep)
    heard = o.transcribe(AUDIO, seconds=3.0, language=None, keyterms=[])
    assert [w.text for w in heard.words] == ["eins", "zwei", "drei", "vier"]
    assert heard.words[0].start == 1.0 and heard.words[-1].end == 3.0
    assert all(a.end <= b.start for a, b in zip(heard.words, heard.words[1:]))
    assert "authorization" not in fake.requests[0].headers  # no key: none sent


def test_mistral_sends_context_bias_and_segment_timestamps():
    url = "https://api.mistral.ai/v1/audio/transcriptions"
    answer = {"model": "voxtral-mini-2507", "text": "Hallo Karel.", "language": "de",
              "segments": [{"text": "Hallo Karel.", "start": 0.5, "end": 1.5}],
              "usage": {"prompt_audio_seconds": 4}}
    fake = Route({("POST", url): ok(answer)})
    m = cloud_asr.make("mistral", {"model": "voxtral-mini-latest"}, KEY, transport=fake, sleep=fake.sleep)
    heard = m.transcribe(AUDIO, seconds=4.0, language="de", keyterms=["Karel Kralek", "Attakring"])
    fields = multipart_fields(fake.requests[0])
    assert fields["model"] == ["voxtral-mini-latest"]
    assert fields["context_bias"] == ["Karel_Kralek", "Attakring"]  # one token each: no spaces
    assert sorted(fields["timestamp_granularities"]) == ["segment", "word"]
    assert "language" not in fields  # Mistral: not together with timestamps
    assert fake.requests[0].headers["authorization"] == f"Bearer {KEY}"
    assert [w.text for w in heard.words] == ["Hallo", "Karel."] and heard.billed_seconds == 4  # spread over the segment


def test_mistral_word_timestamps_are_used_when_given():
    url = "https://api.mistral.ai/v1/audio/transcriptions"
    answer = {"text": "Hallo Karel.", "language": "de",
              "segments": [{"text": "Hallo Karel.", "start": 0.5, "end": 1.5}],
              "words": [{"word": "Hallo", "start": 0.5, "end": 0.8}, {"word": "Karel", "start": 1.1, "end": 1.5}]}
    fake = Route({("POST", url): ok(answer)})
    m = cloud_asr.make("mistral", {"model": "voxtral-mini-latest"}, KEY, transport=fake, sleep=fake.sleep)
    heard = m.transcribe(AUDIO, seconds=4.0, language=None, keyterms=[])
    assert [(w.text, w.start) for w in heard.words] == [("Hallo", 0.5), ("Karel.", 1.1)]


def test_every_adapter_says_how_much_one_request_may_carry():
    for pid in cloud_asr.ADAPTERS:
        a = cloud_asr.make(pid, {"model": "m", "region": "eu", "endpoint": "https://gw.test/v1", "auth": "auto"}, KEY)
        assert a.max_seconds > 60 and a.max_bytes > 1_000_000
    openai_like = cloud_asr.make("openai-transcribe", {"model": "m", "endpoint": "https://gw.test/v1", "auth": "auto"}, KEY)
    assert openai_like.max_bytes <= 25 * 1024 * 1024


# --- a real HTTP exchange, on this Mac ------------------------------------------------------


def test_openai_compatible_against_a_server_on_this_mac():
    got = {}

    class Endpoint(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers["Content-Length"])
            got["path"] = self.path
            got["auth"] = self.headers.get("Authorization")
            got["request"] = Request("POST", "http://x", {"content-type": self.headers["Content-Type"]},
                                     self.rfile.read(length))
            body = json.dumps(OPENAI_ANSWER).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = HTTPServer(("127.0.0.1", 0), Endpoint)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        o = cloud_asr.make("openai-transcribe", {"endpoint": f"http://127.0.0.1:{server.server_address[1]}/v1",
                                                 "model": "whisper-1", "auth": "auto"}, KEY,
                           transport=cloud_llm.urllib_transport)
        heard = o.transcribe(AUDIO, seconds=6.5, language=None, keyterms=[])
    finally:
        server.shutdown()
    assert got["path"] == "/v1/audio/transcriptions" and got["auth"] == f"Bearer {KEY}"
    assert multipart_fields(got["request"])["file"][0][2] == AUDIO
    assert len(heard.words) == 4
