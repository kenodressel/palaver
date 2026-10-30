"""Cloud providers the user can choose (palaver/providers.py): their
settings, their keys, and which one each feature uses."""

import json

import pytest

from palaver import keychain, providers, settings

KEY = "sk-ant-api03-SECRET-abcdefghijklmnop"


def saved() -> dict:
    return json.loads(settings.path().read_text())


def test_defaults():
    a = providers.settings_of("anthropic")
    assert a["endpoint"] == "https://api.anthropic.com" and a["model"] == "claude-opus-5-5"
    o = providers.settings_of("openai")
    assert o["endpoint"] == "https://api.openai.com/v1" and o["model"] == ""
    assert providers.settings_of("claude-cli")["model"] == "sonnet"
    assert providers.settings_of("claude-cli", defaults={"model": "opus"})["model"] == "opus"
    for pid in providers.language_models():
        assert providers.settings_of(pid)["context_tokens"] > 0


def test_configure_saves_beside_the_other_settings():
    settings.update({"realtime": False})
    providers.configure("openai", endpoint=" https://acme.openai.azure.com/openai/v1 ", model=" gpt-x ",
                        context_tokens=200_000)
    assert providers.settings_of("openai") == {"endpoint": "https://acme.openai.azure.com/openai/v1",
                                               "model": "gpt-x", "context_tokens": 200_000, "auth": "auto"}
    providers.configure("openai", model="gpt-y")  # only what is given changes
    assert providers.settings_of("openai")["endpoint"] == "https://acme.openai.azure.com/openai/v1"
    assert saved()["realtime"] is False
    assert saved()["providers"]["openai"]["model"] == "gpt-y"


@pytest.mark.parametrize("endpoint", [
    "ftp://x.test", "javascript:alert(1)", "api.openai.com", "", "http://api.openai.com/v1",
    "https://user:secret@gateway.test/v1", "https://", "https://gw.test/v1#frag",
])
def test_configure_refuses_bad_endpoints(endpoint):
    with pytest.raises(ValueError):
        providers.configure("openai", endpoint=endpoint)


@pytest.mark.parametrize("endpoint", ["http://localhost:11434/v1", "http://127.0.0.1:8000/v1", "https://gw.test/v1?x=1"])
def test_configure_takes_local_http_gateways_and_queries(endpoint):
    providers.configure("openai", endpoint=endpoint)
    assert providers.settings_of("openai")["endpoint"] == endpoint


@pytest.mark.parametrize("changes", [
    {"model": ""}, {"model": "a\nb"}, {"model": "x" * 300}, {"model": 5},
    {"context_tokens": 10}, {"context_tokens": "lots"}, {"context_tokens": True}, {"context_tokens": 10 ** 9},
])
def test_configure_refuses_bad_values(changes):
    with pytest.raises(ValueError):
        providers.configure("anthropic", **changes)


def test_configure_unknown_provider_or_field():
    with pytest.raises(ValueError):
        providers.configure("nope", model="x")
    with pytest.raises(ValueError):
        providers.configure("claude-cli", endpoint="https://x.test")  # it has none


def test_keys_live_in_the_keychain_only(fake_keychain):
    providers.configure("anthropic", model="claude-sonnet-5-5")
    providers.set_key("anthropic", KEY)
    assert fake_keychain == {"anthropic.api_key": KEY}
    assert providers.has_key("anthropic") and providers.api_key("anthropic") == KEY
    assert KEY not in settings.path().read_text()
    view = providers.public("anthropic")
    assert view["key_set"] is True and KEY not in json.dumps(view)
    providers.remove_key("anthropic")
    assert fake_keychain == {} and providers.public("anthropic")["key_set"] is False


def test_no_key_for_the_cli():
    with pytest.raises(ValueError):
        providers.set_key("claude-cli", KEY)


def test_problem_says_what_is_missing(monkeypatch):
    assert "API key" in providers.problem("anthropic")
    keychain.set(providers.key_account("anthropic"), KEY)
    assert providers.problem("anthropic") is None
    assert "model" in providers.problem("openai")
    providers.configure("openai", model="gpt-x")
    assert "endpoint" in providers.problem("openai")  # the default endpoint is not a choice
    providers.configure("openai", endpoint="http://localhost:11434/v1")
    assert providers.problem("openai") is None  # a gateway on this Mac may need no key
    from palaver import notes

    monkeypatch.setattr(notes, "find_claude", lambda configured=None: None)
    assert "Claude Code" in providers.problem("claude-cli")
    monkeypatch.setattr(notes, "find_claude", lambda configured=None: "/bin/claude")
    assert providers.problem("claude-cli") is None


def test_public_view():
    view = providers.public("openai")
    assert view["id"] == "openai" and view["label"] and view["sends_to"]
    assert view["key"] == "optional" and view["key_set"] is False and view["ready"] is False
    assert view["problem"]
    assert providers.public("claude-cli")["key"] == "none"
    assert providers.public("anthropic")["key"] == "required"


def test_choice_defaults_to_what_config_toml_says():
    assert providers.choice("notes", default="local") == "local"
    assert providers.choice("notes", default="claude-cli") == "claude-cli"


def test_choose_needs_a_ready_provider():
    with pytest.raises(ValueError, match="API key"):
        providers.choose("notes", "anthropic")
    assert "engines" not in (saved() if settings.path().exists() else {})
    keychain.set(providers.key_account("anthropic"), KEY)
    providers.choose("notes", "anthropic")
    assert providers.choice("notes", default="local") == "anthropic"
    assert providers.choice("projects", default="local") == "local"  # each feature is chosen on its own
    providers.choose("notes", "local")
    assert providers.choice("notes", default="claude-cli") == "local"


@pytest.mark.parametrize("feature, value", [("notes", "nope"), ("weather", "local"), ("notes", 3)])
def test_choose_refuses_unknown_features_and_values(feature, value):
    with pytest.raises(ValueError):
        providers.choose(feature, value)


def test_a_garbled_choice_means_local():
    settings.update({"engines": {"notes": "evil-cloud", "projects": 7}})
    assert providers.choice("notes", default="claude-cli") == "local"
    assert providers.choice("projects", default="claude-cli") == "local"
    settings.update({"engines": "x"})
    assert providers.choice("notes", default="local") == "local"


def test_garbled_provider_settings_fall_back_to_the_defaults():
    settings.update({"providers": {"openai": {"endpoint": "ftp://x", "model": 3, "context_tokens": "x"}}})
    assert providers.settings_of("openai") == {"endpoint": "https://api.openai.com/v1", "model": "",
                                               "context_tokens": providers.PROVIDERS["openai"].context_tokens,
                                               "auth": "auto"}



# --- an OpenAI-compatible provider sends nothing until it is fully set up -------------


def test_scenario_a_a_remote_endpoint_without_a_key_is_not_ready():
    providers.configure("openai", endpoint="https://api.openai.com/v1", model="gpt-x")
    assert providers.problem("openai") == "Add the API key"
    with pytest.raises(ValueError, match="API key"):
        providers.choose("notes", "openai")
    providers.set_key("openai", "sk-proj-test-0123456789")
    assert providers.problem("openai") is None
    providers.choose("notes", "openai")


def test_a_key_and_a_model_without_a_saved_endpoint_is_not_ready():
    providers.set_key("openai", "sk-proj-test-0123456789")
    providers.configure("openai", model="gpt-x")
    assert "endpoint" in providers.problem("openai")
    with pytest.raises(ValueError, match="endpoint"):
        providers.choose("notes", "openai")


def test_scenario_b_an_azure_key_with_the_default_endpoint_is_not_ready():
    providers.set_key("openai", "0123456789abcdef0123456789abcdef")
    providers.configure("openai", model="gpt-4o-deployment", auth="api-key")  # "Azure" picked
    assert "Azure" in providers.problem("openai")
    providers.configure("openai", endpoint="https://api.openai.com/v1")  # saved, but not the tenant's
    assert "Azure" in providers.problem("openai")
    with pytest.raises(ValueError, match="Azure"):
        providers.choose("notes", "openai")
    providers.configure("openai", endpoint="https://acme.openai.azure.com/openai/v1")
    assert providers.problem("openai") is None


@pytest.mark.parametrize("endpoint", ["https://openai.azure.com/openai/v1", "https://.openai.azure.com/v1"])
def test_an_azure_endpoint_must_name_the_tenant(endpoint):
    providers.set_key("openai", "0123456789abcdef0123456789abcdef")
    providers.configure("openai", model="gpt-x")
    try:
        providers.configure("openai", endpoint=endpoint)
    except ValueError:
        return  # refused outright is fine too
    assert "Azure" in providers.problem("openai")


@pytest.mark.parametrize("endpoint", ["http://localhost:11434/v1", "https://127.0.0.1:8443/v1",
                                      "http://127.0.0.1:8000/v1"])
def test_the_key_is_optional_only_on_this_mac(endpoint):
    providers.configure("openai", endpoint=endpoint, model="llama")
    assert providers.problem("openai") is None


def test_the_auth_header_setting():
    assert providers.settings_of("openai")["auth"] == "auto"
    providers.configure("openai", auth="bearer")
    assert providers.settings_of("openai")["auth"] == "bearer"
    with pytest.raises(ValueError):
        providers.configure("openai", auth="cookie")
    with pytest.raises(ValueError):
        providers.configure("anthropic", auth="bearer")  # only the OpenAI-compatible one has it
