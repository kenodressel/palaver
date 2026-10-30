"""API keys in the login Keychain (palaver/keychain.py), through a fake."""

import pytest

from palaver import keychain


def test_set_get_has_delete(fake_keychain):
    assert keychain.get("anthropic.api_key") is None and not keychain.has("anthropic.api_key")
    keychain.set("anthropic.api_key", "  sk-ant-secret-1234  \n")
    assert fake_keychain == {"anthropic.api_key": "sk-ant-secret-1234"}  # pasted whitespace dropped
    assert keychain.get("anthropic.api_key") == "sk-ant-secret-1234" and keychain.has("anthropic.api_key")
    keychain.delete("anthropic.api_key")
    keychain.delete("anthropic.api_key")  # already gone: no error
    assert fake_keychain == {}


@pytest.mark.parametrize("value", ["", "   ", "two\nlines", "x" * 5000])
def test_refuses_what_is_no_key(value, fake_keychain):
    with pytest.raises(ValueError) as err:
        keychain.set("anthropic.api_key", value)
    assert value.strip() == "" or value.strip() not in str(err.value)
    assert fake_keychain == {}


def test_a_failing_keychain_never_shows_the_key(monkeypatch):
    class Broken:
        def get(self, account):
            raise RuntimeError("keychain locked")

        def set(self, account, value):
            raise RuntimeError(f"could not store {value}")  # a backend that leaks the value

        def delete(self, account):
            raise RuntimeError("nope")

    monkeypatch.setattr(keychain, "backend", Broken())
    assert keychain.get("anthropic.api_key") is None
    with pytest.raises(keychain.KeychainError) as err:
        keychain.set("anthropic.api_key", "sk-ant-secret-1234")
    assert "sk-ant-secret-1234" not in str(err.value)
    assert err.value.__cause__ is None and err.value.__suppress_context__  # the leaky message isn't chained
    with pytest.raises(keychain.KeychainError):
        keychain.delete("anthropic.api_key")


def test_the_real_backend_uses_the_palaver_service(monkeypatch):
    import keyring

    from palaver.config import KEYCHAIN_SERVICE

    calls = []
    monkeypatch.setattr(keyring, "get_password", lambda service, account: calls.append((service, account)))
    keychain.Keyring().get("openai.api_key")
    assert calls == [(KEYCHAIN_SERVICE, "openai.api_key")]


@pytest.mark.parametrize("value", ["sk-ant-abc def", "sk-ant-abc\tdef", "sk-ant-ä€x", "sk-ant-—x"])
def test_refuses_keys_with_spaces_inside_or_odd_characters(value, fake_keychain):
    with pytest.raises(ValueError) as err:
        keychain.set("anthropic.api_key", value)
    assert value not in str(err.value) and fake_keychain == {}
    assert "space" in str(err.value) or "character" in str(err.value)
