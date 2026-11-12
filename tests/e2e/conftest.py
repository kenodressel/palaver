"""Fixtures of the end-to-end tests: the app's server over synthetic
recordings, and a WebKit page (Playwright) that fails its test on any
console.error, page error or dialog.

The server is palaver-server (native/.build/e2e, `make e2e-server`: a debug build,
optimized; $PALAVER_E2E_SERVER_BIN names another), a
child process with fakes for what it talks to: the test model of palaver-lm
(its control folder, FakePython) and fake_app.py for the menu bar app
(daemon.json, app.sock). It starts no Python.

The stores (projects, glossary, people, settings) live in the temporary
XDG config the root conftest gives every test (a module's shared server has
its own).
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import selectors
import shutil
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

import pytest

from .recordings import A, LIVE, USER, build_recordings, live_part
from .stores import RecordingPaths, clear_failed

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
  // The page's open requests, for helpers.reload: WebKit reports a fetch a reload cuts off as a page error. Once
  // that reload is decided (__leaving) the page starts none until it goes (pagehide, where it saves what is typed).
  window.__requests = 0;
  window.__leaving = false;
  const fetch0 = window.fetch;
  window.fetch = function (...args) {
    if (window.__leaving) return new Promise(() => {});
    window.__requests += 1;
    const answer = fetch0.apply(window, args);
    const done = () => { window.__requests -= 1; };
    answer.then(done, done);
    return answer;
  };
  window.addEventListener("pagehide", () => { window.__leaving = false; });
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

        probe_dir = tmp_path_factory.mktemp("probe")
        srv, served = _serve(probe_dir / "Recordings", config_home=probe_dir / "config")
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

_REPO = Path(__file__).resolve().parents[2]
SERVER_BIN = Path(os.environ.get("PALAVER_E2E_SERVER_BIN")
                  or _REPO / "native" / ".build" / "e2e" / "debug" / "palaver-server")
STATIC = _REPO / "web"
# The language model's worker the server and the fake app start: the e2e build's palaver-lm, whose model is the test's
# ($PALAVER_TEST_LM: a control folder, see native/Sources/PalaverLM/ControlModel.swift).
LM_BIN = Path(os.environ.get("PALAVER_E2E_LM_BIN") or SERVER_BIN.with_name("palaver-lm"))
FAKE_CLAUDE = Path(__file__).with_name("fake_claude.py")


class FakeRecording:
    """The menu bar app's running recording, as the server sees it: the
    question whether to stop it (issue #52), and the answers given."""

    def __init__(self):
        self.asked: dict | None = None
        self.answers: list[tuple[str, str]] = []
        self.running = True
        self.live_coach: dict | None = None  # who talks and the nudge (#41), as the daemon says it
        self.transcribing: list[Path] = []  # Transcribe Again: the meetings the app was asked to transcribe
        self.recorded: list[tuple[str, str | None]] = []  # Start Recording / Stop in the window (#11)
        self.records_into: str | None = None  # the meeting a start records into: one the test has

    def question(self):
        return self.asked

    def coach(self):
        return self.live_coach

    def transcribe(self, folder: Path) -> bool:
        self.transcribing.append(folder)
        clear_failed(RecordingPaths(folder))  # as the daemon does: the page shows it transcribing
        return True

    def record(self, action: str, meeting: str | None = None) -> dict:
        self.recorded.append((action, meeting))
        return {"meeting": self.records_into} if action == "start" else {"stopped": meeting}

    def answer(self, choice: str, meeting: str) -> bool:
        self.answers.append((choice, meeting))
        if not self.running or self.asked is None or self.asked["meeting"] != meeting:
            return False
        self.asked = None
        return True


class _Api:
    """What a test asks the server itself."""

    url: str

    def api(self, path: str, body: dict | None = None):
        """A call to the app's API from the test (setting up a store, checking the files)."""
        import urllib.request

        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.url.rstrip("/") + path, data=data,
                                     headers={"Content-Type": "application/json"} if data else {})
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())

    def meeting_ids(self) -> list[str]:
        return [m["id"] for m in self.api("/api/meetings")]


# --- the server: palaver-server and its fakes -------------------------------------

class FakePython:
    """The control folder of palaver-lm's test model (notes, projects,
    the best next question): the calls they answered, what they hold and answer."""

    def __init__(self, folder: Path):
        self.folder = folder
        folder.mkdir(parents=True, exist_ok=True)

    def calls(self, kind: str) -> list[dict]:
        try:
            lines = (self.folder / "calls.jsonl").read_text().splitlines()
        except FileNotFoundError:
            return []
        return [c for c in map(json.loads, lines) if c["kind"] == kind]

    def hold(self, kind: str) -> None:
        (self.folder / f"hold-{kind}").touch()

    def release(self, kind: str) -> None:
        (self.folder / f"hold-{kind}").unlink(missing_ok=True)

    def held(self, kind: str) -> bool:
        return (self.folder / f"hold-{kind}").exists()

    def answer(self, kind: str, value) -> None:
        """What calls of ``kind`` answer from now on (None: the default)."""
        path = self.folder / f"answer-{kind}.json"
        if value is None:
            path.unlink(missing_ok=True)
        else:
            path.write_text(json.dumps(value))


class FakeNotesHelper:
    """The model behind `palaver-lm notes` (its test model): the meetings it wrote notes for, a failure, a hold. Its
    notes are the meeting's notes as they were."""

    def __init__(self, fake: FakePython):
        self._fake = fake
        self._ok = True

    @property
    def calls(self) -> list[str]:
        return [c["meeting"] for c in self._fake.calls("notes")]

    @property
    def ok(self) -> bool:
        return self._ok

    @ok.setter
    def ok(self, value: bool) -> None:
        self._ok = bool(value)
        self._fake.answer("notes", None if self._ok else {"error": "the notes were not written (the e2e model)"})

    def hold(self):
        self._fake.hold("notes")

    def release(self):
        self._fake.release("notes")

    def write(self, notes: dict) -> None:
        """What the model writes from now on (the model's JSON, before palaver-lm adds its hashes)."""
        self._ok = True
        self._fake.answer("notes", notes)


class _HoldGate:
    """threading.Event's clear/set/is_set over the test model's hold file of ``kind`` (its control folder)."""

    def __init__(self, fake: FakePython, kind: str):
        self._fake, self._kind = fake, kind

    def clear(self):
        self._fake.hold(self._kind)

    def set(self):
        self._fake.release(self._kind)

    def is_set(self) -> bool:
        return not self._fake.held(self._kind)


class FakeModelHelper:
    """The best next question's language model (#41) behind `palaver-lm next-question` (its test model): a preset
    answer, or an exception whose text is the model's error, after an optional hold; the prompts it was asked."""

    def __init__(self, fake: FakePython):
        self._fake = fake
        self._answer: dict | Exception = {"questions": [], "engine": "Fake model"}
        self.gate = _HoldGate(fake, "model")

    @property
    def asked(self) -> list[tuple[str, str]]:
        """(meeting, prompt) of each question asked."""
        return [(c["meeting"], c["prompt"]) for c in self._fake.calls("model")]

    @property
    def answer(self) -> dict | Exception:
        return self._answer

    @answer.setter
    def answer(self, value: dict | Exception) -> None:
        self._answer = value
        self._fake.answer("model", {"error": str(value)} if isinstance(value, Exception) else value)


class ProbeFile:
    """The Mac palaver-server's setup assistant sees (TestProbe): probe.json, changed
    with ``set``; ``fetched``, ``autostart_on``, ``calendar`` and
    ``recorder`` read from the server's files and the fake app."""

    def __init__(self, path: Path, home: Path, app):
        self.path, self._home, self._app = path, home, app
        self.set(downloaded=["speech"])

    def read(self) -> dict:
        try:
            return json.loads(self.path.read_text())
        except FileNotFoundError:
            return {}

    def set(self, **values) -> None:
        """Keys of TestProbe's file (hardware, installed, permissions, downloaded, fail_once, …)."""
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps({**self.read(), **values}))
        tmp.replace(self.path)

    @property
    def fetched(self) -> list[str]:
        try:
            return Path(f"{self.path}.fetched").read_text().splitlines()
        except FileNotFoundError:
            return []

    @property
    def autostart_on(self) -> bool:
        return (self._home / "Library" / "LaunchAgents" / "com.kenodressel.meeting-transcribe.plist").exists()

    @property
    def calendar(self):
        return self._app.calendar

    @property
    def recorder(self):
        return self._app.recorder


class SwiftServed(_Api):
    """The window's server a test drives, and what it talks to, backed by the fakes' files."""

    def __init__(self, *, root: Path, tmp: Path, process: subprocess.Popen, url: str, fake: FakePython, app,
                 probe: ProbeFile, live_worker: subprocess.Popen, socket_dir: Path | None):
        self.url = url
        self.root = root
        self.server = process
        self.recording = app.recording
        self.app = app
        self.probe = probe
        self.live_worker = live_worker
        self.notes = FakeNotesHelper(fake)
        self.model = FakeModelHelper(fake)
        self.home = tmp / "home"  # $PALAVER_HOME and $HOME
        self.notify_state = tmp / "notify-state"  # $PALAVER_NOTIFY_STATE: not there, as outside the app
        self._opened_file = tmp / "opened"
        self._revealed_file = tmp / "revealed"
        self._claude_calls = tmp / "claude-calls.jsonl"
        self.claude_desktop_app = tmp / "Applications" / "Claude.app"  # Claude Desktop counts as installed once made
        self._fake = fake
        self._free_gb_file = tmp / "free-gb"
        self._socket_dir = socket_dir
        self._on_model_run = None
        self._runs_done: set[str] = set()
        self._watcher: threading.Thread | None = None
        self._closed = threading.Event()
        if live_worker:  # the call is being recorded while the server runs, however long a module's tests take
            threading.Thread(target=self._keep_recording, name="live-part", daemon=True).start()

    # The server takes a .part file not written to for a minute (MeetingStatus.livePartSeconds) for a recording that
    # ended: the recorder writes to it every few hundred ms. Gone (the test ended the call): left gone.
    PART_EVERY_S = 5.0

    def _keep_recording(self) -> None:
        part = live_part(self.root / LIVE)
        while not self._closed.wait(self.PART_EVERY_S):
            try:
                os.utime(part)
            except FileNotFoundError:
                pass

    @property
    def model_runs(self) -> list[list[str]]:
        return [c["args"] for c in self._fake.calls("projects")]

    @property
    def keychain(self) -> dict:
        """The Keychain's API keys (account -> key): the server's file key store (PALAVER_TEST_KEYSTORE)."""
        try:
            return json.loads((self._fake.folder / "keychain.json").read_text())
        except FileNotFoundError:
            return {}

    @property
    def claude_calls(self) -> list[list[str]]:
        """The arguments of each call of the fake `claude` (fake_claude.py)."""
        try:
            return [json.loads(line) for line in self._claude_calls.read_text().splitlines()]
        except FileNotFoundError:
            return []

    @property
    def claude_desktop_config(self) -> Path:
        return self.home / "Library" / "Application Support" / "Claude" / "claude_desktop_config.json"

    @property
    def mcp_installs(self) -> list[str]:
        """Targets Palaver was added to: "code" per `claude mcp add`, "desktop" once Claude Desktop's config has it."""
        code = ["code" for args in self.claude_calls if args[:2] == ["mcp", "add"]]
        try:
            desktop = "palaver" in json.loads(self.claude_desktop_config.read_text()).get("mcpServers", {})
        except FileNotFoundError:
            desktop = False
        return code + (["desktop"] if desktop else [])

    @property
    def update_actions(self) -> list[str]:
        return self.app.update_actions

    @property
    def opened(self) -> list[str]:
        """URLs the server would have opened ($PALAVER_TEST_OPENED)."""
        try:
            return self._opened_file.read_text().splitlines()
        except FileNotFoundError:
            return []

    @property
    def revealed(self) -> list[Path]:
        """Report zips the server showed in Finder ($PALAVER_TEST_REVEALED)."""
        try:
            return [Path(line) for line in self._revealed_file.read_text().splitlines()]
        except FileNotFoundError:
            return []

    @property
    def free_gb(self) -> float:
        return float(self._free_gb_file.read_text())

    @free_gb.setter
    def free_gb(self, value: float) -> None:
        self._free_gb_file.write_text(repr(float(value)))

    @property
    def on_model_run(self):
        return self._on_model_run

    @on_model_run.setter
    def on_model_run(self, fn) -> None:
        """Called with the args of each `palaver projects` run, while it runs: what it changes."""
        self._on_model_run = fn
        marker = self._fake.folder / "on-model-run"
        if fn is None:
            marker.unlink(missing_ok=True)
            return
        marker.touch()
        if self._watcher is None:
            self._watcher = threading.Thread(target=self._watch_runs, name="on-model-run", daemon=True)
            self._watcher.start()

    def _watch_runs(self) -> None:
        while not self._closed.wait(0.02):
            for call in self._fake.calls("projects"):
                if call["token"] in self._runs_done:
                    continue
                self._runs_done.add(call["token"])
                try:
                    if self._on_model_run:
                        self._on_model_run(call["args"])
                finally:
                    (self._fake.folder / f"ran-{call['token']}").touch()

    def close(self):
        self._closed.set()
        self.notes.release()
        self.model.gate.set()
        self.server.terminate()
        try:
            self.server.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.server.kill()
            self.server.wait()
        self.app.close()
        if self.live_worker:
            self.live_worker.kill()
            self.live_worker.wait()
        if self._socket_dir:
            shutil.rmtree(self._socket_dir, ignore_errors=True)


def _first_line(process: subprocess.Popen, timeout: float = 30) -> str:
    """The server's first line ("Open http://127.0.0.1:PORT/…"), or "" when none came in time."""
    with selectors.DefaultSelector() as sel:
        sel.register(process.stdout, selectors.EVENT_READ)
        if not sel.select(timeout):
            return ""
    return process.stdout.readline()


def _serve_swift(root: Path, key: str | None, config_home: Path, *, recordings: bool = True, user: str = USER,
                 events: list | None = None, env: dict | None = None):
    if not SERVER_BIN.exists() or not LM_BIN.exists():
        pytest.fail(f"palaver-server or palaver-lm is not built ({SERVER_BIN.parent}): run `make e2e-server`", pytrace=False)
    if config_home.resolve() in {Path.home().resolve(), (Path.home() / ".config").resolve()}:
        pytest.fail(f"the e2e server's XDG_CONFIG_HOME is the real {config_home}", pytrace=False)
    tmp = root.parent
    home = tmp / "home"
    home.mkdir(parents=True, exist_ok=True)
    config = tmp / "config.toml"
    # The calendar is off, as the Python server's (calendar=None): EventKit would read this Mac's. [notes].claude names
    # a CLI that is not there, so this Mac's Claude Code is never found.
    config.write_text(f'[user]\nname = {json.dumps(user)}\n\n[recording]\noutput_dir = {json.dumps(str(root))}\n\n'
                      f'[notes]\nclaude = {json.dumps(str(tmp / "no-claude"))}\n\n'
                      "[calendar]\nenabled = false\n")
    worker = None
    if recordings:
        worker = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(3600)"])
        build_recordings(root, live_pid=worker.pid)
    else:
        root.mkdir(parents=True, exist_ok=True)
    fake = FakePython(tmp / "fake-python")
    (tmp / "free-gb").write_text("64.0")
    # A Unix socket's path has at most 104 bytes: a long temporary folder gets a short one beside it.
    socket_dir = None
    socket = tmp / "app.sock"
    if len(str(socket).encode()) > 100:
        socket_dir = Path(tempfile.mkdtemp(prefix="pv-e2e-", dir="/tmp"))
        socket = socket_dir / "app.sock"

    # The `claude` the server finds first: fake_claude.py, never the real Claude Code.
    fake_bin = tmp / "fake-bin"
    fake_bin.mkdir(exist_ok=True)
    (fake_bin / "claude").unlink(missing_ok=True)
    (fake_bin / "claude").symlink_to(FAKE_CLAUDE)

    extra = env or {}
    env = {k: v for k, v in os.environ.items()
           if k not in ("HF_HOME", "HF_HUB_CACHE", "HF_TOKEN", "HF_TOKEN_PATH", "HF_ENDPOINT", "PALAVER_WEB_KEY",
                        "PALAVER_NOTIFY", "PALAVER_TEST_CALENDAR", "CLAUDE_CONFIG_DIR")}
    env.update({
        # Model downloads never reach Hugging Face: nothing listens there (a test's stub hub replaces it).
        "HF_ENDPOINT": "http://127.0.0.1:9",
        "HOME": str(home), "PALAVER_HOME": str(home), "XDG_CONFIG_HOME": str(config_home),
        "PALAVER_TEST_PROBE": str(tmp / "probe.json"), "PALAVER_TEST_FREE_GB": str(tmp / "free-gb"),
        "PALAVER_NOTIFY_STATE": str(tmp / "notify-state"), "PALAVER_TEST_OPENED": str(tmp / "opened"),
        "PALAVER_TEST_REVEALED": str(tmp / "revealed"),  # report zips shown in Finder
        "PALAVER_ENGINE": str(tmp / "no-engine"),  # no speech engine: never this checkout's
        "PALAVER_LM_BIN": str(LM_BIN), "PALAVER_TEST_LM": str(fake.folder),  # palaver-lm with the test's model
        "PYTHON_KEYRING_BACKEND": "keyring.backends.null.Keyring",  # its helpers read no Keychain
        # The server's keys: a file, never this Mac's Keychain.
        "PALAVER_TEST_KEYSTORE": str(fake.folder / "keychain.json"),
        "PATH": f"{fake_bin}{os.pathsep}{os.environ.get('PATH', '/usr/bin:/bin')}",
        "PALAVER_E2E_FAKE_CLAUDE": str(tmp / "claude-calls.jsonl"),
        "PALAVER_TEST_CLAUDE_DESKTOP": str(tmp / "Applications" / "Claude.app"),  # installed once a test makes it
    })
    env.update(extra)
    if key:
        env["PALAVER_WEB_KEY"] = key
    else:
        env["PALAVER_TEST_NO_KEY"] = "1"  # as the Python server's key=None

    from .fake_app import FakeApp

    app = FakeApp(home=home, socket=socket, root=root, recording=FakeRecording(), probe_file=tmp / "probe.json",
                  helper_env=env, cli_options=["--config", str(config)], lm=LM_BIN)
    probe = ProbeFile(tmp / "probe.json", home, app)
    if events is not None:
        probe.set(events=events)
    with open(tmp / "server.log", "wb") as log:
        process = subprocess.Popen(
            [str(SERVER_BIN), "--port", "0", "--app-socket", str(socket),
             "--config", str(config), "--static", str(STATIC)],
            env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=log, text=True)
    line = _first_line(process)
    m = re.match(r"Open (http://127\.0\.0\.1:\d+/)", line)
    if not m:
        process.kill()
        process.wait()
        app.close()
        if worker:
            worker.kill()
            worker.wait()
        pytest.fail(f"palaver-server did not start (exit {process.poll()}): "
                    f"{(tmp / 'server.log').read_text()[-2000:]}", pytrace=False)
    # Nothing else is printed; drained anyway, so a line never blocks it.
    threading.Thread(target=process.stdout.read, name="server-stdout", daemon=True).start()
    served = SwiftServed(root=root, tmp=tmp, process=process, url=m.group(1), fake=fake, app=app, probe=probe,
                         live_worker=worker, socket_dir=socket_dir)
    return process, served


def _serve(root: Path, key: str | None = None, config_home: Path | None = None, *, recordings: bool = True,
           user: str = USER, events: list | None = None, env: dict | None = None):
    """The window's server over fresh recordings in ``root`` (none: ``recordings`` False);
    ``config_home``: its XDG_CONFIG_HOME (the test's own when it is None); ``user``:
    config.toml's name; ``events``: the calendar's (Event.to_dict), the calendar is off without; ``env``: more of the
    server's environment (a stub hub's HF_ENDPOINT).
    Its home (Application Support, Downloads, Desktop) is ``root.parent / "home"``: never
    this Mac's, so no installed Palaver's update.json or models show."""
    if config_home is None:
        config_home = Path(os.environ["XDG_CONFIG_HOME"])  # the root conftest's, for this test
    return _serve_swift(root, key, config_home, recordings=recordings, user=user, events=events, env=env)


@pytest.fixture
def app_server(tmp_path):
    """The app over fresh recordings, for a test that changes them."""
    srv, served = _serve(tmp_path / "Recordings")
    yield served
    served.close()


@pytest.fixture
def keyed_server(tmp_path):
    """The app as the menu bar runs it: answering only with its key."""
    srv, served = _serve(tmp_path / "Recordings", key="the-apps-key")
    served.key = "the-apps-key"
    yield served
    served.close()


@pytest.fixture(scope="module")
def shared_server(tmp_path_factory):
    """One app for a module's tests that only look (nothing in the recordings changes)."""
    tmp = tmp_path_factory.mktemp("e2e")
    srv, served = _serve(tmp / "Recordings", config_home=tmp / "config")  # before the test's own
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
