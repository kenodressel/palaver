"""Cloud language models over HTTP (palaver/cloud_llm.py), through a fake
transport: the request each provider gets, its errors and the retries."""

import json

import pytest

from palaver import cloud_llm
from palaver.cloud_llm import CloudError, Request, Response

KEY = "sk-ant-api03-SECRET-abcdefghijklmnop"
SCHEMA = {
    "type": "object",
    "description": "Write in German.",
    "properties": {
        "title": {"type": "string"},
        "steps": {"type": "array", "items": {"type": "object", "properties": {"task": {"type": "string"}},
                                             "required": ["task"]}},
    },
    "required": ["title", "steps"],
}
ANSWER = {"title": "Rollout", "steps": [{"task": "Mail Anna"}]}


class Fake:
    """Answers each request with the next of ``answers``: a Response, or an
    exception to raise. Records the requests and the waits."""

    def __init__(self, *answers):
        self.answers = list(answers)
        self.requests: list[Request] = []
        self.waits: list[float] = []

    def __call__(self, request: Request) -> Response:
        self.requests.append(request)
        answer = self.answers.pop(0)
        if isinstance(answer, BaseException):
            raise answer
        return answer

    def sleep(self, seconds):
        self.waits.append(seconds)

    def body(self, i=0):
        return json.loads(self.requests[i].body)


def anthropic_ok(payload=ANSWER, stop="end_turn"):
    return Response(200, {}, json.dumps({
        "content": [{"type": "thinking", "thinking": ""}, {"type": "text", "text": json.dumps(payload)}],
        "stop_reason": stop,
    }).encode())


def openai_ok(payload=ANSWER, finish="stop"):
    return Response(200, {}, json.dumps({
        "choices": [{"message": {"role": "assistant", "content": json.dumps(payload)}, "finish_reason": finish}],
    }).encode())


def error(status, message="something broke", headers=None):
    return Response(status, headers or {}, json.dumps({"error": {"message": message}}).encode())


def anthropic(fake, endpoint="https://api.anthropic.com", **kw):
    return cloud_llm.anthropic_runner(endpoint, "claude-opus-5-5", KEY, transport=fake, sleep=fake.sleep, **kw)


def openai(fake, endpoint="https://api.openai.com/v1", key=KEY, **kw):
    return cloud_llm.openai_runner(endpoint, "gpt-x", key, transport=fake, sleep=fake.sleep, **kw)


# --- the requests ----------------------------------------------------------------


def test_anthropic_request():
    fake = Fake(anthropic_ok())
    assert anthropic(fake)("PROMPT", SCHEMA) == ANSWER
    (req,) = fake.requests
    assert req.method == "POST" and req.url == "https://api.anthropic.com/v1/messages"
    assert req.headers["x-api-key"] == KEY
    assert req.headers["anthropic-version"] == cloud_llm.ANTHROPIC_VERSION
    assert req.headers["content-type"] == "application/json"
    assert req.timeout == cloud_llm.TIMEOUT_SECONDS
    body = fake.body()
    assert body["model"] == "claude-opus-5-5" and body["max_tokens"] == cloud_llm.MAX_OUTPUT_TOKENS
    assert body["messages"] == [{"role": "user", "content": "PROMPT"}]
    assert body["system"].startswith("Write in German.")  # the notes' language, said first
    assert "temperature" not in body
    schema = body["output_config"]["format"]["schema"]
    assert body["output_config"]["format"]["type"] == "json_schema"
    # Structured outputs want every object closed; the language rule went to the system prompt.
    assert schema["additionalProperties"] is False and "description" not in schema
    assert schema["properties"]["steps"]["items"]["additionalProperties"] is False
    assert SCHEMA.get("additionalProperties") is None  # the caller's schema is left alone


@pytest.mark.parametrize("endpoint, url", [
    ("https://api.anthropic.com/", "https://api.anthropic.com/v1/messages"),
    ("https://gateway.example.com/anthropic", "https://gateway.example.com/anthropic/v1/messages"),
    ("https://gateway.example.com/anthropic/v1", "https://gateway.example.com/anthropic/v1/messages"),
    ("https://gateway.example.com/v1/messages", "https://gateway.example.com/v1/messages"),
])
def test_anthropic_endpoints(endpoint, url):
    fake = Fake(anthropic_ok())
    anthropic(fake, endpoint)("P", SCHEMA)
    assert fake.requests[0].url == url


def test_openai_request():
    fake = Fake(openai_ok())
    assert openai(fake)("PROMPT", SCHEMA) == ANSWER
    (req,) = fake.requests
    assert req.url == "https://api.openai.com/v1/chat/completions"
    assert req.headers["authorization"] == f"Bearer {KEY}" and "api-key" not in req.headers
    body = fake.body()
    assert body["model"] == "gpt-x"
    assert body["messages"][0]["role"] == "system" and body["messages"][0]["content"].startswith("Write in German.")
    assert '"title"' in body["messages"][0]["content"]  # the schema, for gateways that ignore response_format
    assert body["messages"][1] == {"role": "user", "content": "PROMPT"}
    assert body["response_format"]["type"] == "json_schema"
    assert body["response_format"]["json_schema"]["schema"]["properties"] == SCHEMA["properties"]
    assert "temperature" not in body


@pytest.mark.parametrize("endpoint, url, header", [
    ("https://api.openai.com/v1/", "https://api.openai.com/v1/chat/completions", "authorization"),
    ("https://acme.openai.azure.com/openai/v1", "https://acme.openai.azure.com/openai/v1/chat/completions", "api-key"),
    ("https://acme.openai.azure.com/openai/deployments/gpt/?api-version=2024-10-21",
     "https://acme.openai.azure.com/openai/deployments/gpt/chat/completions?api-version=2024-10-21", "api-key"),
    ("https://acme.cognitiveservices.azure.com/openai/v1", "https://acme.cognitiveservices.azure.com/openai/v1/chat/completions",
     "api-key"),
    ("http://localhost:11434/v1", "http://localhost:11434/v1/chat/completions", "authorization"),
    ("https://llm.example.com/v1/chat/completions", "https://llm.example.com/v1/chat/completions", "authorization"),
])
def test_openai_compatible_endpoints(endpoint, url, header):
    fake = Fake(openai_ok())
    openai(fake, endpoint)("P", SCHEMA)
    req = fake.requests[0]
    assert req.url == url
    assert req.headers[header] in (KEY, f"Bearer {KEY}")
    (other,) = {"authorization", "api-key"} - {header}
    assert other not in req.headers  # the key goes in one header only


def test_openai_gateway_without_a_key():
    fake = Fake(openai_ok())
    openai(fake, "http://localhost:11434/v1", key=None)("P", SCHEMA)
    assert "authorization" not in fake.requests[0].headers and "api-key" not in fake.requests[0].headers


def test_openai_asks_again_without_response_format_when_the_gateway_rejects_it():
    fake = Fake(error(400, "Unrecognized request argument: response_format"), openai_ok())
    assert openai(fake)("P", SCHEMA) == ANSWER
    assert "response_format" in fake.body(0) and "response_format" not in fake.body(1)
    assert fake.waits == []


def test_the_key_never_shows_in_a_request_repr():
    fake = Fake(anthropic_ok(), openai_ok())
    anthropic(fake)("P", SCHEMA)
    openai(fake)("P", SCHEMA)
    for req in fake.requests:
        assert KEY not in repr(req) and KEY not in str(req) and KEY.encode() not in req.body


# --- answers -------------------------------------------------------------------


def test_parse_shapes_the_answer_and_a_broken_answer_is_asked_again():
    seen = []

    def parse(text):
        seen.append(text)
        if len(seen) == 1:
            raise ValueError("no JSON")
        return {"parsed": json.loads(text)}

    fake = Fake(anthropic_ok(), anthropic_ok())
    assert anthropic(fake, parse=parse)("P", SCHEMA) == {"parsed": ANSWER}
    assert len(fake.requests) == 2

    fake = Fake(openai_ok(), openai_ok())
    with pytest.raises(CloudError, match="did not return a valid answer"):
        openai(fake, parse=lambda text: (_ for _ in ()).throw(ValueError("garbage")))("P", SCHEMA)
    assert len(fake.requests) == 2


@pytest.mark.parametrize("runner, answer, problem", [
    (anthropic, anthropic_ok(stop="max_tokens"), "cut off"),
    (anthropic, anthropic_ok(stop="refusal"), "declined"),
    (openai, openai_ok(finish="length"), "cut off"),
    (openai, openai_ok(finish="content_filter"), "declined"),
])
def test_cut_off_or_declined_answers_are_said_so(runner, answer, problem):
    fake = Fake(answer)
    with pytest.raises(CloudError, match=problem):
        runner(fake)("P", SCHEMA)
    assert len(fake.requests) == 1


def test_an_answer_without_text_is_an_error():
    fake = Fake(Response(200, {}, b"<html>proxy login</html>"))
    with pytest.raises(CloudError, match="not JSON"):
        anthropic(fake)("P", SCHEMA)


# --- errors and retries ----------------------------------------------------------


@pytest.mark.parametrize("status", [401, 403])
def test_a_refused_key_is_not_retried(status):
    fake = Fake(error(status, f"Incorrect API key provided: {KEY[:12]}***{KEY[-4:]} ({KEY})"))
    with pytest.raises(CloudError) as err:
        anthropic(fake)("P", SCHEMA)
    assert len(fake.requests) == 1 and fake.waits == []
    assert str(status) in str(err.value) and "key" in str(err.value)
    assert KEY not in str(err.value) and KEY[:12] not in str(err.value)


@pytest.mark.parametrize("status", [400, 404, 422])
def test_other_client_errors_are_not_retried_and_keep_the_providers_words(status):
    fake = Fake(error(status, f"model gpt-x not found for key {KEY}"))
    with pytest.raises(CloudError) as err:
        openai(fake)("P", SCHEMA)
    assert len(fake.requests) == 1
    assert "model gpt-x not found" in str(err.value) and KEY not in str(err.value)


def test_429_waits_as_long_as_the_provider_asks():
    fake = Fake(error(429, "slow down", {"retry-after": "7"}), anthropic_ok())
    assert anthropic(fake)("P", SCHEMA) == ANSWER
    assert fake.waits == [7.0]


def test_retry_after_is_capped():
    fake = Fake(error(429, headers={"retry-after": "3600"}), anthropic_ok())
    anthropic(fake)("P", SCHEMA)
    assert fake.waits == [cloud_llm.MAX_WAIT_SECONDS]


@pytest.mark.parametrize("status", [500, 502, 503, 504, 529])
def test_server_errors_are_retried_with_backoff_then_given_up(status):
    fake = Fake(*[error(status)] * cloud_llm.ATTEMPTS)
    with pytest.raises(CloudError) as err:
        anthropic(fake)("P", SCHEMA)
    assert len(fake.requests) == cloud_llm.ATTEMPTS
    assert fake.waits == list(cloud_llm.BACKOFF_SECONDS[: cloud_llm.ATTEMPTS - 1])
    assert str(status) in str(err.value) and f"{cloud_llm.ATTEMPTS} tries" in str(err.value)


def test_a_server_error_then_success():
    fake = Fake(error(503), openai_ok())
    assert openai(fake)("P", SCHEMA) == ANSWER
    assert fake.waits == [cloud_llm.BACKOFF_SECONDS[0]]


@pytest.mark.parametrize("problem, said", [
    (TimeoutError("timed out"), "timed out"),
    (ConnectionError(f"refused {KEY}"), "could not reach"),
])
def test_timeouts_and_unreachable_hosts_are_retried(problem, said):
    fake = Fake(*[problem] * cloud_llm.ATTEMPTS)
    with pytest.raises(CloudError) as err:
        openai(fake)("P", SCHEMA)
    assert len(fake.requests) == cloud_llm.ATTEMPTS
    assert said in str(err.value) and KEY not in str(err.value)
    assert "api.openai.com" in str(err.value)


def test_redact_hides_the_key_and_anything_like_one():
    text = f"bad key {KEY}; also sk-proj-ABCDEFGHIJKLMNOP1234 and sk-abc***wxyz"
    out = cloud_llm.redact(text, KEY)
    assert KEY not in out and "sk-proj-ABCDEFGHIJKLMNOP1234" not in out and "sk-abc" not in out
    assert "bad key" in out
    assert len(cloud_llm.redact("x" * 5000, KEY)) <= cloud_llm.MAX_ERROR_CHARS + 1


def test_the_default_transport_is_used_when_none_is_given(monkeypatch):
    used = []
    monkeypatch.setattr(cloud_llm, "default_transport", lambda req: used.append(req) or anthropic_ok())
    cloud_llm.anthropic_runner("https://api.anthropic.com", "m", KEY)("P", SCHEMA)
    assert len(used) == 1


def test_urllib_transport_turns_http_errors_into_responses(monkeypatch):
    import io
    import urllib.error
    import urllib.request

    def fake_open(req, timeout):
        assert timeout == 5 and req.get_method() == "POST" and req.get_header("X-api-key") == KEY
        raise urllib.error.HTTPError(req.full_url, 429, "Too Many", {"Retry-After": "2"}, io.BytesIO(b'{"e": 1}'))

    monkeypatch.setattr(cloud_llm, "_open", fake_open)
    resp = cloud_llm.urllib_transport(Request("POST", "https://x.test/v1", {"x-api-key": KEY}, b"{}", 5))
    assert resp.status == 429 and resp.headers["retry-after"] == "2" and resp.body == b'{"e": 1}'

    def unreachable(req, timeout):
        raise urllib.error.URLError("nodename nor servname provided")

    monkeypatch.setattr(cloud_llm, "_open", unreachable)
    with pytest.raises(ConnectionError):
        cloud_llm.urllib_transport(Request("POST", "https://x.test/v1", {}, b"{}", 5))


# --- review fixes ----------------------------------------------------------------------


@pytest.mark.parametrize("status", [301, 302, 303, 307, 308])
def test_a_redirect_is_never_followed_and_names_where_it_pointed(status):
    fake = Fake(Response(status, {"location": "https://collector.evil.example/steal"}, b""))
    with pytest.raises(CloudError) as err:
        anthropic(fake)("P", SCHEMA)
    assert len(fake.requests) == 1 and fake.waits == []
    assert "collector.evil.example" in str(err.value) and "redirect" in str(err.value)
    assert KEY not in str(err.value)


def test_the_real_transport_refuses_redirects_and_the_key_stays_home():
    """Two servers on this Mac: the endpoint answers 302 to the other one,
    which must never see a request (urllib copies the key headers along)."""
    import threading
    from http.server import BaseHTTPRequestHandler, HTTPServer

    reached = []

    class Target(BaseHTTPRequestHandler):
        def do_POST(self):
            reached.append(dict(self.headers))
            self.send_response(200)
            self.end_headers()

        def log_message(self, *a):
            pass

    target = HTTPServer(("127.0.0.1", 0), Target)

    class Endpoint(BaseHTTPRequestHandler):
        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length") or 0))
            self.send_response(302)
            self.send_header("Location", f"http://localhost:{target.server_address[1]}/steal")
            self.send_header("Content-Length", "0")
            self.end_headers()

        def log_message(self, *a):
            pass

    endpoint = HTTPServer(("127.0.0.1", 0), Endpoint)
    for srv in (target, endpoint):
        threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        runner = cloud_llm.anthropic_runner(f"http://127.0.0.1:{endpoint.server_address[1]}", "m", KEY,
                                            transport=cloud_llm.urllib_transport, sleep=lambda s: None)
        with pytest.raises(CloudError) as err:
            runner("P", SCHEMA)
        assert "localhost" in str(err.value) and "redirect" in str(err.value)
        assert reached == []
    finally:
        for srv in (target, endpoint):
            srv.shutdown()
            srv.server_close()


def test_tests_cannot_reach_the_internet():
    with pytest.raises(AssertionError, match="network"):
        cloud_llm.urllib_transport(Request("POST", "https://example.com/v1", {}, b"{}", 5))
    import urllib.request

    with pytest.raises(AssertionError, match="network"):
        urllib.request.urlopen("https://example.com/")


@pytest.mark.parametrize("auth, endpoint, header", [
    ("auto", "https://acme.openai.azure.com/openai/v1", "api-key"),
    ("auto", "https://gw.example.com/v1", "authorization"),
    ("api-key", "https://gw.example.com/v1", "api-key"),
    ("bearer", "https://acme.openai.azure.com/openai/v1", "authorization"),
])
def test_the_auth_header_can_be_chosen(auth, endpoint, header):
    fake = Fake(openai_ok())
    openai(fake, endpoint, auth=auth)("P", SCHEMA)
    req = fake.requests[0]
    (other,) = {"authorization", "api-key"} - {header}
    assert header in req.headers and other not in req.headers
    assert req.headers[header] == (f"Bearer {KEY}" if header == "authorization" else KEY)


@pytest.mark.parametrize("message", [
    "Unrecognized request argument: response_format",
    "json_schema is not supported for this model",
    "This model does not support structured outputs",
    "schema not supported",
    "Invalid parameter: 'response_format' of type 'json_schema' is not supported with this model.",
])
def test_the_structured_output_fallback_triggers_on_these_400s(message):
    fake = Fake(error(400, message), openai_ok())
    assert openai(fake)("P", SCHEMA) == ANSWER
    assert "response_format" not in fake.body(1)


def test_other_400s_do_not_trigger_the_fallback():
    fake = Fake(error(400, "messages: too many tokens"))
    with pytest.raises(CloudError, match="too many tokens"):
        openai(fake)("P", SCHEMA)
    assert len(fake.requests) == 1


def test_room_for_thinking_and_long_notes():
    assert cloud_llm.MAX_OUTPUT_TOKENS >= 32_000
    assert cloud_llm.TIMEOUT_SECONDS >= 600
