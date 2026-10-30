"""Fixtures of the end-to-end tests: the app's server over synthetic
recordings, and a WebKit page (Playwright) that fails its test on any
console.error, page error or dialog.

The stores (projects, glossary, people, settings) live in the temporary
XDG config the root conftest gives every test.
"""

from __future__ import annotations

import importlib.util
import os
import re
import subprocess
import sys
import threading
from dataclasses import dataclass, field
from pathlib import Path

import pytest

from palaver.webapp.server import App, make_server

from tests.fake_probe import FakeProbe

from .recordings import A, USER, build_recordings

# Every page runs this first: media is muted (no test is ever heard), and the
# clipboard is a stand-in (no test touches the real pasteboard).
PAGE_SETUP = """
(() => {
  const play = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function () {
    this.muted = true;
    this.volume = 0;
    return play.call(this);
  };
  window.__copied = [];
  try {
    Object.defineProperty(navigator, "clipboard", { configurable: true,
      value: { writeText: async (text) => { window.__copied.push(String(text)); } } });
  } catch (e) { /* the page's fallback is execCommand("copy") */ }
})();
"""


# --- the browser ----------------------------------------------------------------

# In CI (or with PALAVER_E2E_REQUIRED) a missing Playwright or WebKit fails the
# run: a green run with every E2E test skipped would prove nothing.
REQUIRED = bool(os.environ.get("CI") or os.environ.get("PALAVER_E2E_REQUIRED"))
HAS_PLAYWRIGHT = importlib.util.find_spec("playwright") is not None

# Tests that drive the page (not the app's own window, which needs no Playwright).
_PLAYWRIGHT_TESTS = re.compile(r"test_(?!app_window).*\.py$")


def pytest_ignore_collect(collection_path, config):
    """Without Playwright the modules cannot even import it: skip them here (the
    one place that knows), unless the run requires them, where the import error shows."""
    if not HAS_PLAYWRIGHT and not REQUIRED and _PLAYWRIGHT_TESTS.fullmatch(collection_path.name) \
            and collection_path.parent == Path(__file__).parent:
        return True
    return None


def pytest_report_header(config):
    if not HAS_PLAYWRIGHT:
        return "e2e: Playwright is not installed (the dev extra has it): the browser tests are not collected"
    return None


def _unavailable(reason: str):
    """WebKit cannot run here: a failure where it is required, a skip elsewhere."""
    if REQUIRED:
        pytest.fail(reason, pytrace=False)
    pytest.skip(reason)


@pytest.fixture(scope="module")
def browser():
    """WebKit for one module's tests. Not for the whole session: while
    Playwright's sync API runs, asyncio.run() refuses to start (other tests use it)."""
    if not HAS_PLAYWRIGHT:
        _unavailable("Playwright is not installed (the dev extra has it)")
    from playwright.sync_api import Error, sync_playwright

    pw = sync_playwright().start()
    try:
        webkit = pw.webkit.launch()
    except Error as exc:
        pw.stop()
        _unavailable(f"Playwright's WebKit is not installed (python -m playwright install webkit): "
                     f"{str(exc).splitlines()[0]}")
    yield webkit
    webkit.close()
    pw.stop()


_audio_decodes: list[bool] = []  # the probe's answer, once per session


@pytest.fixture
def audio_decoding(browser, tmp_path_factory):
    """For a test that needs the audio to load and play: skipped where WebKit
    cannot decode the synthetic WAV (a headless CI runner may have no decoder).
    Probed once, with the module's browser."""
    if not _audio_decodes:
        from playwright.sync_api import Error

        srv, served = _serve(tmp_path_factory.mktemp("probe") / "Recordings")
        page = browser.new_page()
        try:
            src = f"{served.url.rstrip('/')}/api/meetings/{A}/audio?track=mix"
            page.set_content(f'<audio id="a" muted preload="auto" src="{src}"></audio>')
            try:
                page.wait_for_function("document.getElementById('a').readyState >= 1", timeout=5_000)
                _audio_decodes.append(True)
            except Error:
                _audio_decodes.append(False)
        finally:
            page.close()
            served.close()
    if not _audio_decodes[0]:
        pytest.skip("WebKit here cannot decode audio")


# --- the server -----------------------------------------------------------------

class FakeNotes:
    """write_notes for the server: answers at once, or waits while held."""

    def __init__(self):
        self.calls: list[str] = []
        self.ok = True
        self.gate = threading.Event()
        self.gate.set()

    def hold(self):
        self.gate.clear()

    def release(self):
        self.gate.set()

    def __call__(self, meeting_id: str) -> bool:
        self.gate.wait(30)
        self.calls.append(meeting_id)
        return self.ok


class FakeRecording:
    """The menu bar app's running recording, as the server sees it: the
    question whether to stop it (issue #52), and the answers given."""

    def __init__(self):
        self.asked: dict | None = None
        self.answers: list[tuple[str, str]] = []
        self.running = True
        self.live_coach: dict | None = None  # who talks and the nudge (#41), as the daemon says it

    def question(self):
        return self.asked

    def coach(self):
        return self.live_coach

    def answer(self, choice: str, meeting: str) -> bool:
        self.answers.append((choice, meeting))
        if not self.running or self.asked is None or self.asked["meeting"] != meeting:
            return False
        self.asked = None
        return True


class FakeModel:
    """The best next question's language model (#41): a preset answer or
    error, after an optional hold; the inputs it was asked with."""

    def __init__(self):
        self.asked: list[tuple[str, dict]] = []
        self.answer: dict | Exception = {"questions": [], "engine": "Fake model"}
        self.gate = threading.Event()
        self.gate.set()

    def __call__(self, meeting_id: str, inputs: dict) -> dict:
        self.gate.wait(30)
        self.asked.append((meeting_id, inputs))
        if isinstance(self.answer, Exception):
            raise self.answer
        return self.answer


@dataclass
class Served:
    url: str
    root: Path
    notes: FakeNotes
    model_runs: list = field(default_factory=list)
    on_model_run: object = None  # called with the args of a fake `palaver projects` run: what it changes
    server: object = None  # the ThreadingHTTPServer, for server.url()
    recording: FakeRecording = field(default_factory=FakeRecording)
    live_worker: subprocess.Popen | None = None  # the running process live.pid names
    # This Mac as the setup assistant sees it (#55): given, never looked at;
    # its downloads and test recording are fakes (no network, no microphone).
    probe: FakeProbe = field(default_factory=FakeProbe)
    model: FakeModel = field(default_factory=FakeModel)
    free_gb: float = 64.0  # free memory, as the app sees it

    def close(self):
        self.notes.release()
        self.model.gate.set()
        self.server.shutdown()
        self.server.server_close()
        if self.live_worker:
            self.live_worker.kill()
            self.live_worker.wait()

    def api(self, path: str, body: dict | None = None):
        """A call to the app's API from the test (setting up a store, checking the files)."""
        import json
        import urllib.request

        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.url.rstrip("/") + path, data=data,
                                     headers={"Content-Type": "application/json"} if data else {})
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())

    def meeting_ids(self) -> list[str]:
        return [m["id"] for m in self.api("/api/meetings")]


def _model_run(served: Served, args: list[str]) -> bool:
    served.model_runs.append(args)
    if served.on_model_run:
        served.on_model_run(args)
    return True


def _serve(root: Path):
    worker = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(3600)"])
    build_recordings(root, live_pid=worker.pid)
    fake = FakeNotes()
    served = Served("", root, fake, live_worker=worker)
    app = App(root, USER, write_notes=fake,
              run_projects=lambda args: _model_run(served, args), recording=served.recording, probe=served.probe,
              ask_model=served.model, free_memory_gb=lambda: served.free_gb,
              downloads=root.parent / "Downloads")  # an export never lands in the real ~/Downloads
    srv = make_server(app, port=0)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    served.url = f"http://127.0.0.1:{srv.server_address[1]}/"
    served.server = srv
    return srv, served


@pytest.fixture
def app_server(tmp_path):
    """The app over fresh recordings, for a test that changes them."""
    srv, served = _serve(tmp_path / "Recordings")
    yield served
    served.close()


@pytest.fixture(scope="module")
def shared_server(tmp_path_factory):
    """One app for a module's tests that only look (nothing in the recordings changes)."""
    srv, served = _serve(tmp_path_factory.mktemp("e2e") / "Recordings")
    yield served
    served.close()


# --- the page -------------------------------------------------------------------

class Guard:
    """What the page reported that it should not have: console.error, an
    uncaught error or rejection, a dialog (the app asks nothing: it undoes)."""

    def __init__(self):
        self.problems: list[str] = []
        self.allowed: list[re.Pattern] = []

    def allow(self, pattern: str):
        """A console error the test causes on purpose (e.g. a server error it fakes)."""
        self.allowed.append(re.compile(pattern))

    def unexpected(self) -> list[str]:
        return [p for p in self.problems if not any(a.search(p) for a in self.allowed)]


@pytest.fixture
def page(browser, request):
    context = browser.new_context(viewport={"width": 1280, "height": 860})
    context.add_init_script(PAGE_SETUP)
    page = context.new_page()
    page.set_default_timeout(10_000)
    guard = Guard()

    def on_console(msg):
        if msg.type == "error":
            guard.problems.append(f"console.error: {msg.text}")

    def on_dialog(dialog):
        guard.problems.append(f"{dialog.type}() dialog: {dialog.message}")
        dialog.dismiss()

    page.on("console", on_console)
    page.on("pageerror", lambda exc: guard.problems.append(f"page error: {exc}"))
    page.on("dialog", on_dialog)
    page.guard = guard
    request.node._page_guard = guard
    request.node._page = page
    yield page
    context.close()


def _flush(page):
    """Let Playwright's event loop deliver what the page reported after the
    test's last call (its events arrive only while a call is being made)."""
    if page is None or page.is_closed():
        return
    try:
        page.evaluate("0")
        page.wait_for_timeout(50)
    except Exception:  # the page crashed or closed: what it reported so far stands
        pass


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_call(item):
    """A test whose page reported a problem fails, even when its asserts passed."""
    outcome = yield
    guard = getattr(item, "_page_guard", None)
    if guard is None:
        return
    _flush(getattr(item, "_page", None))
    found = guard.unexpected()
    if found and outcome.excinfo is not None:
        print("the page reported:\n  " + "\n  ".join(found))  # shown with the failure
    elif found:
        outcome.force_exception(AssertionError("the page reported:\n  " + "\n  ".join(found)))
