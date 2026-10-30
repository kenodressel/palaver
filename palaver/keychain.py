"""Secrets in the macOS login Keychain: the API keys of cloud providers,
under the same service as the other tokens ("palaver"), one account per
provider ("anthropic.api_key"). Never in config.toml or settings.json.

``backend`` does the storing (``keyring``, which uses the Security framework
on macOS); tests swap in a fake. Nothing here logs a key or puts one in an
error message.
"""

from __future__ import annotations

import logging

LOGGER = logging.getLogger(__name__)
MAX_LENGTH = 4096  # longer than any API key; a pasted file is not a key


class KeychainError(RuntimeError):
    pass


class Keyring:
    """The login Keychain through ``keyring``."""

    def get(self, account: str) -> str | None:
        import keyring

        from .config import KEYCHAIN_SERVICE

        return keyring.get_password(KEYCHAIN_SERVICE, account)

    def set(self, account: str, value: str) -> None:
        import keyring

        from .config import KEYCHAIN_SERVICE

        keyring.set_password(KEYCHAIN_SERVICE, account, value)

    def delete(self, account: str) -> None:
        import keyring
        from keyring.errors import PasswordDeleteError

        from .config import KEYCHAIN_SERVICE

        try:
            keyring.delete_password(KEYCHAIN_SERVICE, account)
        except PasswordDeleteError:  # there was none
            pass


backend = Keyring()


def get(account: str) -> str | None:
    try:
        return backend.get(account) or None
    except Exception:
        LOGGER.warning("could not read %s from the Keychain", account)
        return None


def has(account: str) -> bool:
    return get(account) is not None


def set(account: str, value: str) -> None:  # noqa: A001 (the module's verb)
    value = value.strip()
    if not value or len(value) > MAX_LENGTH or any(c in value for c in "\r\n\0"):
        raise ValueError("that is not an API key")
    if any(c.isspace() for c in value):
        raise ValueError("an API key has no spaces inside; copy it again without them")
    try:
        value.encode("latin-1")  # it goes into an HTTP header
    except UnicodeEncodeError:
        raise ValueError("the key has a character no API key has (copied with a dash or quote "
                         "that was changed?); copy it again") from None
    try:
        backend.set(account, value)
    except Exception:
        # The backend's own message may quote what it was given.
        raise KeychainError(f"could not save {account} in the Keychain") from None


def delete(account: str) -> None:
    try:
        backend.delete(account)
    except Exception:
        raise KeychainError(f"could not remove {account} from the Keychain") from None
