"""`palaver provider <action> --json`: the Settings page's language-model and
transcription sections for the Swift window server. The body comes on
stdin (an API key never on argv), one JSON line goes out."""

import io
import json
import sys

import pytest

from palaver import cli, mcp_access, provider_helper

KEY = "sk-ant-api03-SECRET-abcdefghijklmnop"
ASR_KEY = "aai-SECRET-abcdefghijklmnopqrstuvwxyz0123"


def _run(monkeypatch, capsys, action: str, body=None, *options: str) -> tuple[int, list[str], str]:
    """`palaver [options] provider <action> --json` with ``body`` on stdin: the
    exit code, the lines printed and what went to stderr."""
    monkeypatch.setattr(sys, "stdin", io.StringIO("" if body is None else json.dumps(body)))
    code = cli.main([*options, "provider", action, "--json"])
    out, err = capsys.readouterr()
    return code, out.splitlines(), err


def _answers(monkeypatch, *, status=200):
    """Anthropic and AssemblyAI behind a fake transport; refusing with the key quoted for ``status`` 401."""
    from palaver import cloud_llm

    def transport(request):
        if status != 200:
            return cloud_llm.Response(status, {}, json.dumps({"error": {"message": f"invalid x-api-key {KEY}"}}).encode())
        if "anthropic" in request.url:
            body = {"content": [{"type": "text", "text": json.dumps({"reply": "Hello there"})}], "stop_reason": "end_turn"}
        elif request.url.endswith("/v2/upload"):
            body = {"upload_url": "https://cdn.assemblyai.test/u/1"}
        elif request.method == "POST":
            body = {"id": "t1", "status": "queued"}
        else:
            body = {"id": "t1", "status": "completed", "words": [], "audio_duration": 2}
        return cloud_llm.Response(200, {}, json.dumps(body).encode())

    monkeypatch.setattr(cloud_llm, "default_transport", transport)


def test_every_action_answers_one_json_line(monkeypatch, capsys, fake_keychain, tmp_path):
    assert set(provider_helper.ACTIONS) == {
        "language-model", "set-language-model", "set-key", "test", "transcription", "set-transcription",
        "set-transcription-key", "test-transcription", "registry", "mcp-install"}
    _answers(monkeypatch)
    calls = [
        ("language-model", None),
        ("set-key", {"provider": "anthropic", "key": KEY}),
        ("set-language-model", {"use": {"notes": "anthropic"}}),
        ("test", {"provider": "anthropic"}),
        ("transcription", None),
        ("set-transcription-key", {"provider": "assemblyai", "key": ASR_KEY}),
        ("set-transcription", {"use": "assemblyai"}),
        ("test-transcription", {"provider": "assemblyai"}),
        ("registry", None),
        ("mcp-install", {"target": "desktop"}),
    ]
    out = {}
    for action, body in calls:
        code, lines, _ = _run(monkeypatch, capsys, action, body)
        assert code == 0 and len(lines) == 1, (action, lines)
        out[action] = json.loads(lines[0])
    assert out["language-model"]["features"][0]["choice"] == "local"
    assert out["set-language-model"]["features"][0]["choice"] == "anthropic"
    assert out["test"]["answer"] == "Hello there"
    assert out["transcription"]["month"]["seconds"] == 0  # what was sent this month comes with it
    assert out["set-transcription"]["feature"]["choice"] == "assemblyai"
    assert out["test-transcription"]["usd_per_hour"] > 0
    assert out["mcp-install"]["desktop"]["registered"] is True
    assert json.loads(mcp_access.DESKTOP_CONFIG.read_text())["mcpServers"]["meetings"]

    # The registry: every provider as the page shows it, with what it is for; each feature's choice and readiness.
    reg = out["registry"]
    providers = {p["id"]: p for p in reg["providers"]}
    assert list(providers) == ["anthropic", "openai", "claude-cli", "assemblyai", "soniox", "mistral",
                               "openai-transcribe"]
    assert providers["anthropic"]["ready"] is True and providers["anthropic"]["uses"] == ["language_model"]
    assert providers["soniox"]["ready"] is False and providers["soniox"]["problem"]
    assert providers["soniox"]["uses"] == ["transcription"]
    features = {f["id"]: f for f in reg["features"]}
    assert list(features) == ["notes", "projects", "coach", "transcription"]
    notes = features["notes"]
    assert (notes["choice"], notes["default"], notes["ready"], notes["own"], notes["uses"]) == (
        "anthropic", "local", True, False, "language_model")
    assert notes["label"] == "Notes" and notes["sends"]
    assert features["coach"]["own"] is True and features["coach"]["choice"] == "local" and features["coach"]["ready"]
    assert features["transcription"]["choice"] == "assemblyai" and features["transcription"]["ready"] is True
    assert KEY not in json.dumps(out) and ASR_KEY not in json.dumps(out)


def test_config_toml_choices_reach_the_helper(monkeypatch, capsys, tmp_path):
    """The window's server passes its --config on: config.toml's choices show as the defaults."""
    config = tmp_path / "config.toml"
    config.write_text('[notes]\nengine = "claude"\nmodel = "opus"\n')
    code, lines, _ = _run(monkeypatch, capsys, "language-model", None, "--config", str(config))
    lm = json.loads(lines[0])
    assert code == 0 and [f["choice"] for f in lm["features"]] == ["claude-cli", "claude-cli", "local"]
    assert next(p for p in lm["providers"] if p["id"] == "claude-cli")["model"] == "opus"
    # Claude starts `palaver mcp` with them too.
    code, _, _ = _run(monkeypatch, capsys, "mcp-install", {"target": "desktop"}, "--config", str(config))
    args = json.loads(mcp_access.DESKTOP_CONFIG.read_text())["mcpServers"]["meetings"]["args"]
    assert code == 0 and args[args.index("--config") + 1] == str(config.resolve())


def test_a_key_is_read_from_stdin_and_never_echoed(monkeypatch, capsys, fake_keychain):
    parser = cli.build_parser()
    with pytest.raises(SystemExit):  # no way to give a key on the command line
        parser.parse_args(["provider", "set-key", "--key", KEY])
    capsys.readouterr()  # argparse's own complaint
    code, lines, err = _run(monkeypatch, capsys, "set-key", {"provider": "anthropic", "key": KEY})
    assert code == 0 and fake_keychain == {"anthropic.api_key": KEY}
    assert KEY not in lines[0] and KEY not in err
    assert next(p for p in json.loads(lines[0])["providers"] if p["id"] == "anthropic")["key_set"] is True

    # Refused keys: the answer says why, never what was given.
    for action, body in [("set-key", {"provider": "claude-cli", "key": KEY}),
                         ("set-key", {"provider": "openai", "key": "two\nlines " + KEY}),
                         ("set-transcription-key", {"provider": "anthropic", "key": KEY}),
                         ("set-transcription-key", {"provider": "soniox", "key": "\u2013" + KEY})]:
        code, lines, err = _run(monkeypatch, capsys, action, body)
        answer = json.loads(lines[0])
        assert code == 1 and answer["status"] == 400 and answer["error"], (action, answer)
        assert KEY not in lines[0] and KEY not in err
    assert fake_keychain == {"anthropic.api_key": KEY}

    code, lines, _ = _run(monkeypatch, capsys, "set-key", {"provider": "anthropic", "remove": True})
    assert code == 0 and fake_keychain == {}


def test_errors_carry_a_status(monkeypatch, capsys, fake_keychain):
    code, lines, _ = _run(monkeypatch, capsys, "set-language-model", {"use": {"notes": "anthropic"}})
    assert code == 1 and len(lines) == 1
    assert json.loads(lines[0]) == {"error": "Anthropic API: Add the API key", "status": 400}

    code, lines, _ = _run(monkeypatch, capsys, "set-transcription", {"provider": "assemblyai", "region": "moon"})
    assert code == 1 and json.loads(lines[0])["status"] == 400

    code, lines, _ = _run(monkeypatch, capsys, "test", {"provider": "nobody"})
    assert code == 1 and json.loads(lines[0]) == {"error": "no language model 'nobody'", "status": 400}

    # The provider refuses the key: 502 with why, the key it quoted left out (cloud_llm.redact).
    fake_keychain["anthropic.api_key"] = KEY
    fake_keychain["assemblyai.api_key"] = ASR_KEY
    _answers(monkeypatch, status=401)
    for action, provider in [("test", "anthropic"), ("test-transcription", "assemblyai")]:
        code, lines, err = _run(monkeypatch, capsys, action, {"provider": provider})
        answer = json.loads(lines[0])
        assert code == 1 and answer["status"] == 502 and ("401" in answer["error"] or "refused" in answer["error"])
        assert KEY not in lines[0] and ASR_KEY not in lines[0] and KEY not in err

    # What the window's server answers 500 for: its text, as the server shows it.
    code, lines, _ = _run(monkeypatch, capsys, "set-language-model", ["not", "an", "object"])
    assert code == 1 and json.loads(lines[0]) == {"error": "'list' object has no attribute 'get'", "status": 500}
    code, lines, _ = _run(monkeypatch, capsys, "language-model", None, "--config", "/nowhere/config.toml")
    assert code == 1 and json.loads(lines[0]) == {"error": "Config file not found: /nowhere/config.toml", "status": 500}
    code, lines, _ = _run(monkeypatch, capsys, "mcp-install", {"target": "code"})  # no claude command in tests
    assert code == 1 and json.loads(lines[0]) == {"error": "Claude Code (the claude command) was not found",
                                                  "status": 500}


def test_an_error_text_never_holds_the_key(monkeypatch, capsys, fake_keychain):
    """Whatever fails, the key given is not in the answer."""
    from palaver.webapp import api

    def boom(cfg, body):
        raise RuntimeError(f"could not use {body['key']}")

    monkeypatch.setattr(api, "set_provider_key", boom)
    code, lines, _ = _run(monkeypatch, capsys, "set-key", {"provider": "anthropic", "key": KEY})
    assert code == 1 and KEY not in lines[0] and json.loads(lines[0])["status"] == 500


def test_the_helper_never_notifies(monkeypatch, capsys, sent_notifications):
    code, _, _ = _run(monkeypatch, capsys, "set-language-model", {"use": {"notes": "anthropic"}})
    assert code == 1 and sent_notifications == []
