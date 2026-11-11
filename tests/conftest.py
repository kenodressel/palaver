"""Shared pytest fixtures of the developer tooling's tests (the end-to-end tests, the release build)."""

import os
import time
from pathlib import Path

import pytest

# Meeting ids are local times and the fixtures are written in CET (+01:00):
# the suite runs in that zone everywhere, CI's UTC included.
os.environ["TZ"] = "Europe/Berlin"
time.tzset()


@pytest.fixture(autouse=True)
def isolated_config_home(monkeypatch, tmp_path_factory) -> Path:
    """Tests must never read or write the real ~/.config (voice bank!): the e2e server's
    stores are this test's temporary XDG config."""
    home = tmp_path_factory.mktemp("xdg-config")
    monkeypatch.setenv("XDG_CONFIG_HOME", str(home))
    return home


@pytest.fixture(autouse=True)
def no_release_identity(monkeypatch):
    """Tests sign ad hoc, never with the release certificate in the real Keychain, though the shell that runs
    `make test` before `make release` exports PALAVER_SIGN_IDENTITY."""
    monkeypatch.delenv("PALAVER_SIGN_IDENTITY", raising=False)


LOCAL_HOSTS = {"127.0.0.1", "localhost", "::1"}


@pytest.fixture(autouse=True)
def no_network(monkeypatch):
    """Tests never reach the internet from this process: any HTTP connection to a host other
    than this Mac fails (a test server on 127.0.0.1 is fine)."""
    import http.client
    import urllib.request
    from urllib.parse import urlsplit

    real_connect = http.client.HTTPConnection.connect

    def connect(self):
        if self.host not in LOCAL_HOSTS:
            raise AssertionError(f"test tried to reach the network: {self.host}")
        return real_connect(self)

    monkeypatch.setattr(http.client.HTTPConnection, "connect", connect)
    real_urlopen = urllib.request.urlopen

    def urlopen(url, *args, **kwargs):
        parts = urlsplit(url if isinstance(url, str) else url.full_url)
        host = parts.hostname
        if host not in LOCAL_HOSTS and parts.scheme != "file":  # file://: release assets on disk
            raise AssertionError(f"test tried to reach the network: {host}")
        return real_urlopen(url, *args, **kwargs)

    monkeypatch.setattr(urllib.request, "urlopen", urlopen)
