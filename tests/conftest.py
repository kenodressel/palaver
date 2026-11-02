"""Shared pytest fixtures."""

import os
import time
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

# Meeting ids are local times and the fixtures are written in CET (+01:00):
# the suite runs in that zone everywhere, CI's UTC included.
os.environ["TZ"] = "Europe/Berlin"
time.tzset()


@pytest.fixture
def tiny_wav(tmp_path: Path) -> Path:
    """A 2-second 16kHz mono WAV with two tones: sine at 400Hz then 800Hz."""
    sr = 16_000
    t = np.linspace(0, 1.0, sr, endpoint=False)
    first = 0.3 * np.sin(2 * np.pi * 400 * t).astype(np.float32)
    second = 0.3 * np.sin(2 * np.pi * 800 * t).astype(np.float32)
    samples = np.concatenate([first, second])
    out = tmp_path / "tiny.wav"
    sf.write(out, samples, sr, subtype="PCM_16")
    return out


@pytest.fixture(autouse=True)
def sent_notifications(monkeypatch) -> list[tuple[str, str]]:
    """Never pop real macOS notifications from tests; record them instead."""
    sent: list[tuple[str, str]] = []
    monkeypatch.setattr(
        "palaver.notify._send", lambda title, message, meeting=None: sent.append((title, message))
    )
    monkeypatch.setattr("palaver.notify._enabled", True)
    return sent


@pytest.fixture(autouse=True)
def no_notes_models(monkeypatch):
    """Tests must never load the local notes model or call the Claude Code CLI."""
    from palaver import notes

    def no_model(*args, **kwargs):
        def run(prompt, schema):
            raise notes.NotesError("no language models in tests")
        return run

    monkeypatch.setattr(notes, "find_claude", lambda configured=None: None)
    monkeypatch.setattr(notes, "local_runner", no_model)


@pytest.fixture(autouse=True)
def models_here(monkeypatch):
    """The transcription models count as downloaded: tests transcribe with fakes."""
    monkeypatch.setattr("palaver.process_state._here", lambda cfg, m: True)


@pytest.fixture(autouse=True)
def isolated_config_home(monkeypatch, tmp_path_factory) -> Path:
    """Tests must never read or write the real ~/.config (voice bank!)."""
    home = tmp_path_factory.mktemp("xdg-config")
    monkeypatch.setenv("XDG_CONFIG_HOME", str(home))
    return home


@pytest.fixture(autouse=True)
def no_folder_moves(monkeypatch):
    """Tests must never move the real ~/Library folders of the old name."""
    monkeypatch.setattr("palaver.migrate.move_old_folders", lambda: [])


@pytest.fixture(autouse=True)
def no_real_keychain(monkeypatch):
    """Tests must never read or write the real login Keychain."""
    import keyring

    def _refuse(*_args):
        raise AssertionError("test tried to write the real Keychain")

    monkeypatch.setattr(keyring, "get_password", lambda *_: None)
    monkeypatch.setattr(keyring, "set_password", _refuse)
    monkeypatch.setattr(keyring, "delete_password", _refuse)


class FakeKeychain(dict):
    """The login Keychain in tests: account -> secret, in memory."""

    def get(self, account):
        return super().get(account)

    def set(self, account, value):
        self[account] = value

    def delete(self, account):
        self.pop(account, None)


@pytest.fixture(autouse=True)
def fake_keychain(monkeypatch) -> FakeKeychain:
    """API keys go to this fake, never to the real Keychain."""
    from palaver import keychain

    fake = FakeKeychain()
    monkeypatch.setattr(keychain, "backend", fake)
    return fake


LOCAL_HOSTS = {"127.0.0.1", "localhost", "::1"}


@pytest.fixture(autouse=True)
def no_network(monkeypatch):
    """Tests never reach the internet: a runner without a fake transport
    fails, and so does any HTTP connection to a host other than this Mac
    (a test server on 127.0.0.1 is fine)."""
    import http.client
    import urllib.request
    from urllib.parse import urlsplit

    from palaver import cloud_llm

    def refuse(request):
        raise AssertionError(f"test tried to reach the network: {request.url}")

    monkeypatch.setattr(cloud_llm, "default_transport", refuse)

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


@pytest.fixture(autouse=True)
def notes_lock_in_tmp(monkeypatch, tmp_path_factory) -> Path:
    """Tests must never lock the real ~/Library/Application Support/palaver/notes.lock."""
    path = tmp_path_factory.mktemp("notes-lock") / "notes.lock"
    monkeypatch.setattr("palaver.cli.NOTES_LOCK", path)
    return path


@pytest.fixture(autouse=True)
def mcp_files_in_tmp(monkeypatch, tmp_path_factory) -> Path:
    """Tests must never write the real MCP access log or heartbeat files, nor
    read or write the real Claude Code (~/.claude.json) or Claude Desktop config."""
    from palaver import mcp_access

    root = tmp_path_factory.mktemp("mcp-support")
    monkeypatch.setattr(mcp_access, "LOG_PATH", root / "mcp-access.jsonl")
    monkeypatch.setattr(mcp_access, "PROCESS_DIR", root / "mcp")
    monkeypatch.setattr(mcp_access, "CLAUDE_CONFIG", root / "claude.json")
    monkeypatch.setattr(mcp_access, "DESKTOP_CONFIG", root / "Claude" / "claude_desktop_config.json")
    monkeypatch.setattr(mcp_access, "DESKTOP_APP", root / "Applications" / "Claude.app")  # not installed
    return root


@pytest.fixture(autouse=True)
def isolated_daemon_state(monkeypatch, tmp_path_factory) -> Path:
    """Tests must never read or write the real daemon.json: the running app's."""
    path = tmp_path_factory.mktemp("daemon-state") / "daemon.json"
    monkeypatch.setattr("palaver.daemon.STATE_PATH", path)
    return path


class ReportHome:
    """Where a problem report (#59) reads and writes in tests: a fake home with
    its Desktop, logs and crash reports; ``revealed`` the zips shown in Finder."""

    def __init__(self, root: Path):
        self.root = root
        self.desktop = root / "Desktop"
        self.logs = root / "Library" / "Logs" / "palaver"
        self.crashes = root / "Library" / "Logs" / "DiagnosticReports"
        self.support = root / "Library" / "Application Support" / "palaver"
        self.revealed: list[Path] = []


@pytest.fixture(autouse=True)
def report_home(monkeypatch, tmp_path_factory) -> ReportHome:
    """Tests must never write the real usage log, crash log or Desktop, nor read
    the real logs and crash reports into a report, nor open Finder."""
    from palaver import report, runlog, usage

    home = ReportHome(tmp_path_factory.mktemp("home"))
    monkeypatch.setattr(usage, "PATH", home.support / "usage.jsonl")
    monkeypatch.setattr(usage, "CATALOG_PATH", home.support / "usage-features.json")
    monkeypatch.setattr(runlog, "CRASH_LOG", home.logs / "crashes.log")
    monkeypatch.setattr(runlog, "install_crash_log", lambda name: None)  # pytest keeps its own hooks
    monkeypatch.setattr(report, "DESKTOP", home.desktop)
    monkeypatch.setattr(report, "LOG_DIR", home.logs)
    monkeypatch.setattr(report, "CRASH_DIR", home.crashes)
    monkeypatch.setattr(report, "reveal", home.revealed.append)
    monkeypatch.setattr(report, "Probe", report.QuietProbe)  # no system_profiler, doctor or git in tests
    return home
