"""Run parity scenarios: Python (in-process) and the Swift port (``palaver-parity``) run the same
operations on copies of the same folders, and every file either wrote is diffed.

    uv run --extra dev python tools/parity/run.py [--scenario NAME ...]
    uv run --extra dev python tools/parity/run.py --real DIR --out DIR [--anonymize] [--scenario NAME ...]

The first form runs on the corpus (corpus.py). The second copies the meeting folders in DIR into
two sides under ``--out`` (anonymized with ``--anonymize``), never writes to DIR, and prints only
paths and JSON key paths, never values. Exit 0: no differences; 1: differences; 2: misused.

A scenario (scenarios/<name>.json) is ``{"name", "steps": [{"op", "args", "error"?}], "compare":
[folders and files of the side, events.json among them], "result": true}``: with "result", every
op's JSON answer is compared too. A step that is meant to fail says ``"error": true``; a failure
anywhere else is a difference (diff.py).

A step ``{"http": {"method", "path", "body"?, ...}}`` asks the window's server instead (see
``http_request``): Python's ``make_server`` in this process on one side, the Swift
``palaver-server --port 0`` child on the other, both with the key ``WEB_KEY``; their answers
(status, the headers that matter, the body) are compared like an op's. ``"raw_file": PATH`` sends the side's file
at PATH (relative to the side) as the body, e.g. a zip an earlier op exported. A body's text
``"<undo:LABEL>"`` reads, on each side, the token of that side's newest undo snapshot with that
label (the tokens differ between the sides); ``"<project:NAME>"`` the id of that side's project called
NAME (new ids differ too), in the body and the path; ``<term:NAME>`` the same for a glossary term. ``"<event:TITLE>"`` in the path reads the key of the
first event of events.json with that title, quoted. ``"<mcp-cleared>"`` reads the token of the side's newest
cleared MCP access log; ``"volatile": [KEY, ...]`` compares those keys of the answers only for being null or not
(random on each side). With ``"calendar": true`` the scenario's servers ask
the side's fake calendar (events.json) as EventKit (``PALAVER_TEST_CALENDAR`` on the Swift side); else
they have none; the corpus is then built around the real time, the servers' clock, so its upcoming events
are still to come. ``"probe": {...}`` is the setup assistant's Mac on both sides (written to each side's probe.json):
``PALAVER_TEST_PROBE`` on the Swift side, ``ParityProbe`` (its Python twin) on Python's; the Swift server then runs
its Python helpers with this Python, and no Keychain is read on either side.

A step ``{"worker": {"python": [ARGS], "swift": [ARGS]}}`` runs a pipeline command as a process on each side:
``python -m palaver --config <side's config.toml> --no-notify ARGS`` and ``palaver-worker --config … --no-notify
ARGS`` (``WORKER_BIN``), ``<side>`` in an argument being the side's folder. Their exit codes and stdout (its last
line as JSON when it is, the side's path read as ``<side>``) are compared like an op's answer. ``"worker": [ARGS]``
gives both sides the same arguments. With ``"engine": {...}`` both hear the same speech engine: that JSON in the
side's ``engine.json`` as ``PALAVER_TEST_ENGINE``, which palaver-worker's ``FakeEngine`` (debug builds) answers from
and Python's side runs through ``worker_python.py`` (palaver-engine is ``fake_engine.py`` reading the same file; its
``"cloud"`` is what a chosen transcription service hears); palaver-worker's Python helpers go the same way
(``fake_python`` as its PALAVER_PYTHON).
A step ``{"remove": [PATHS]}`` deletes those files (relative to the side) on both sides first.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import http.client
import json
import os
import re
import threading
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:  # run as a script
    sys.path.insert(0, str(ROOT))

from tools.parity import anonymize, corpus, diff, ops  # noqa: E402

SCENARIOS = ROOT / "tools" / "parity" / "scenarios"
PARITY_BIN = ROOT / "native" / ".build" / "debug" / "palaver-parity"
SERVER_BIN = ROOT / "native" / ".build" / "debug" / "palaver-server"
WORKER_BIN = ROOT / "native" / ".build" / "debug" / "palaver-worker"
STATIC = ROOT / "palaver" / "webapp" / "static"
TIMEOUT = 600  # seconds for one Swift op
# The window's key on both sides of an http step: a fixed test value, not a secret.
WEB_KEY = "parity-web-key"
# The answer's headers an http step compares (Date and Server differ by design).
HTTP_HEADERS = ("Content-Type", "Location", "Set-Cookie", "Cache-Control", "Content-Length", "Content-Range",
                "Accept-Ranges")


def _clone_or_copy(src: str, dst: str) -> str:
    """``shutil.copy2`` through an APFS clone (``clonefile``) where it can: a copy that takes no space until
    one side writes it. Real mode copies the recordings twice per scenario (8.7 GB of audio on Keno's Mac,
    ×2 ×35 scenarios); as bytes that does not fit on the disk. Elsewhere (another volume, another file
    system) a plain copy."""
    try:
        if _LIBC.clonefile(os.fsencode(src), os.fsencode(dst), 0) == 0:
            return dst
    except AttributeError:  # no clonefile (not macOS)
        pass
    return shutil.copy2(src, dst)


_LIBC = ctypes.CDLL(None, use_errno=True)


def prepare(workdir: Path, *, now: datetime, real: Path | None = None, anonymized: bool = False) -> tuple[Path, Path]:
    """The two sides, ``workdir/python`` and ``workdir/swift``: the corpus, or the meetings in
    ``real`` (copied, as clones where the disk can; anonymized when asked) with empty stores."""
    py, sw = workdir / "python", workdir / "swift"
    if real is None:
        corpus.build(py, now=now)
    else:
        if anonymized:
            anonymize.copy(real, py / "Recordings")
        else:
            shutil.copytree(real, py / "Recordings", symlinks=True, copy_function=_clone_or_copy)
        corpus.base(py)
    shutil.copytree(py, sw, symlinks=True, copy_function=_clone_or_copy)
    corpus.write_config(sw)
    return py, sw


def swift(parity_bin: Path, op: str, side: Path, args: dict) -> Any:
    """``op`` on ``side`` through the Swift helper, as a JSON value."""
    env = {**os.environ, **ops.environment(side)}
    for k in ("HF_HOME", "HF_HUB_CACHE"):
        env.pop(k, None)
    why = ops.unsafe_environment(env)
    if why:
        return {"error": why, "kind": "bad_args"}
    proc = subprocess.run([str(parity_bin), op, "--side", str(side), "--args", json.dumps(args)],
                          env=env, capture_output=True, text=True, timeout=TIMEOUT)
    if proc.returncode not in (0, 1):  # a trap, a signal, fatalError
        return {"error": f"palaver-parity crashed (exit {proc.returncode})", "kind": "crash"}
    lines = proc.stdout.strip().splitlines()
    try:
        result = json.loads(lines[-1])
    except (IndexError, ValueError):
        return {"error": f"palaver-parity answered no JSON (exit {proc.returncode})", "kind": "no_json"}
    if proc.returncode == 1 and not (isinstance(result, dict) and set(result) == {"error", "kind"}):
        return {"error": "palaver-parity exited 1 without an error", "kind": "crash"}
    return result


def worker_step(step: dict, side: Path, *, swift_side: bool, worker_bin: Path = WORKER_BIN,
                engine: dict | None = None) -> dict:
    """A ``worker`` step on ``side``: the command's exit code and what it printed (see the module's text)."""
    env = {**os.environ, **ops.environment(side)}
    for k in ("HF_HOME", "HF_HUB_CACHE", "PALAVER_TEST_ENGINE", "PALAVER_ENGINE"):
        env.pop(k, None)
    why = ops.unsafe_environment(env)
    if why:
        return {"error": why, "kind": "bad_args"}
    args = [a.replace("<side>", str(side)) for a in step["swift" if swift_side else "python"]]
    head = [str(worker_bin)] if swift_side else [sys.executable, "-m", "palaver"]
    if engine is not None:  # the engine's answers, the same on both sides (worker_python.py, FakeEngine)
        spec = side / "engine.json"
        spec.write_text(json.dumps(engine, ensure_ascii=False))
        env["PALAVER_TEST_ENGINE"] = str(spec)
        if swift_side:  # its Python helpers (cloud-transcribe, notes) hear the same
            env["PALAVER_PYTHON"] = str(Path(__file__).with_name("fake_python"))
            env["PARITY_PYTHON"] = sys.executable
        else:
            head = [sys.executable, "-m", "tools.parity.worker_python"]
    config = side / "config" / "palaver" / "config.toml"
    try:
        proc = subprocess.run([*head, "--config", str(config), "--no-notify", *args], env=env, cwd=ROOT,
                              capture_output=True, text=True, timeout=TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"error": f"the worker step did not run: {exc}", "kind": "crash"}
    text = proc.stdout
    for prefix in sorted({str(side), str(side.resolve())}, key=len, reverse=True):
        text = text.replace(prefix, "<side>")
    lines = text.strip().splitlines()
    try:
        out: Any = json.loads(lines[-1]) if lines else None
    except ValueError:
        out = text
    return {"rc": proc.returncode, "stdout": out}


class ParityProbe:
    """The Python twin of palaver-server's ``TestProbe`` (DEBUG, ``PALAVER_TEST_PROBE``): the Mac the setup assistant
    sees comes from the JSON file ``file``, read at every look; its downloads "fetch" at once; autostart is the
    LaunchAgent under ``home``; the test recording and the calendar permission are the side's menu bar app's
    (``socket``), as in the window's server (webapp/process.py ``serve``)."""

    def __init__(self, file: Path, home: Path, socket: Path):
        from palaver import onboarding as ob
        from palaver.webapp.remote import RemoteCalendar, RemoteTest

        self.file, self.got = file, []
        self.agent = home / "Library" / "LaunchAgents" / "com.kenodressel.meeting-transcribe.plist"
        self.downloads = ob.Downloads(fetch=lambda m: self.got.append(m.id), progress=lambda repo: 0, done=lambda m: True)
        self.test = RemoteTest(socket)
        self.calendar = RemoteCalendar(socket)
        self.cfg = None

    def _read(self) -> dict:
        try:
            data = json.loads(self.file.read_text())
        except (OSError, ValueError):
            return {}
        return data if isinstance(data, dict) else {}

    def hardware(self):
        from palaver import onboarding as ob

        hw = self._read().get("hardware") or {}
        return ob.Hardware(hw.get("chip", "Apple M4 Pro"), round(hw.get("memory_gb", 48)), float(hw.get("free_disk_gb", 120)))

    def installed(self):
        from palaver import onboarding as ob

        i = self._read().get("installed")
        if i is None:
            return ob.Installed(teams=True, slack=False, claude_code=True)
        return ob.Installed(**{k: bool(i.get(k)) for k in ("teams", "slack", "claude_code", "claude_desktop")})

    def permissions(self, output_dir: Path) -> dict:
        given = self._read().get("permissions")
        return given if isinstance(given, dict) else {
            "microphone": {"state": "granted", "detail": "allowed"},
            "system_audio": {"state": "unverified", "detail": "not verified yet"},
            "calendar": {"state": "not_asked", "detail": "not connected"},
            "notifications": {"state": "unknown", "detail": "Palaver can't check this itself"},
        }

    def downloaded(self) -> frozenset[str]:
        return frozenset(self._read().get("downloaded", [])) | frozenset(self.got)

    def full_name(self) -> str:
        return self._read().get("full_name", "Timo Strauss")

    def repo_of(self, m) -> str:
        return m.repo

    def autostart(self) -> bool:
        return self.agent.exists()

    def set_autostart(self, on: bool) -> None:
        if on:
            self.agent.parent.mkdir(parents=True, exist_ok=True)
            self.agent.write_bytes(b"")
        elif self.agent.exists():
            self.agent.unlink()

    def events(self, start, end) -> list:
        """The calendar as EventKit answers it: the file's events that overlap the window."""
        from palaver.calendar_events import Event

        found = [Event.from_dict(d) for d in self._read().get("events", [])]
        return [e for e in found if e.start < end and e.end > start]


class _NoKeychain:
    """No API key anywhere: a scenario never reads the real Keychain."""

    def get(self, account: str) -> None:
        return None

    def set(self, account: str, value: str) -> None:
        raise RuntimeError("no Keychain in a parity run")

    def delete(self, account: str) -> None:
        pass


class Servers:
    """The window's server on each side, started at the first http step: Python's in this process,
    the Swift one as a child; both stopped by ``close``."""

    def __init__(self, py: Path, sw: Path, server_bin: Path, *, calendar: bool = False, probe: bool = False):
        self.py, self.sw, self.server_bin, self.calendar, self.probe = py, sw, server_bin, calendar, probe
        self._keychain = self._find_claude = None
        self._python = None
        self._swift: subprocess.Popen | None = None
        self.swift_port = 0

    def python_port(self) -> int:
        if self._python is None:
            from palaver.webapp.remote import RemoteRecording
            from palaver.webapp.server import App, make_server

            why = ops.unsafe_side(self.py)
            if why:
                raise RuntimeError(why)
            with ops.patched(self.py):
                here = ops.side(self.py)
                # The menu bar app of the side's home, as palaver-server's: never the real one's paths.
                support = here.home / "Library" / "Application Support" / "palaver"
                recording = RemoteRecording(state_path=support / "daemon.json", socket_path=support / "app.sock")
                calendar = ops._provider(here) if self.calendar else None
                probe = None
                if self.probe:
                    from palaver import keychain, notes

                    probe = ParityProbe(self.py / "probe.json", here.home, support / "app.sock")
                    calendar = probe.events
                    self._keychain, keychain.backend = keychain.backend, _NoKeychain()
                    self._find_claude, notes.find_claude = notes.find_claude, lambda configured=None: None
                server = make_server(App(here.recordings, here.user_name, calendar=calendar, recording=recording,
                                         probe=probe), port=0, key=WEB_KEY)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            self._python = server
        return self._python.server_address[1]

    def swift(self) -> int:
        if self._swift is None:
            env = {**os.environ, **ops.environment(self.sw), "PALAVER_WEB_KEY": WEB_KEY}
            # No speech engine: whether the speech models are here is the files' answer (a checkout's built engine
            # would judge planted files), as Python's side counts them here (the root conftest's `models_here`).
            env["PALAVER_ENGINE"] = str(self.sw / "no-engine")
            # Its keys in a file of its own (empty, as Python's _NoKeychain): never this Mac's Keychain.
            env["PALAVER_TEST_KEYSTORE"] = str(self.sw / "keychain.json")
            if self.calendar:
                env["PALAVER_TEST_CALENDAR"] = str(self.sw / "events.json")
            more = []
            if self.probe:
                env["PALAVER_TEST_PROBE"] = str(self.sw / "probe.json")
                # No Keychain for anything it starts.
                env["PYTHON_KEYRING_BACKEND"] = "keyring.backends.null.Keyring"
            for k in ("HF_HOME", "HF_HUB_CACHE"):
                env.pop(k, None)
            why = ops.unsafe_environment(env) or ops.unsafe_side(self.sw)
            if why:
                raise RuntimeError(why)
            config = self.sw / "config" / "palaver" / "config.toml"
            self._swift = subprocess.Popen(
                [str(self.server_bin), "--config", str(config), "--no-notify", "--port", "0", "--static", str(STATIC), *more],
                env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            line = self._swift.stdout.readline()  # "Open http://127.0.0.1:PORT/?key=…"
            try:
                self.swift_port = int(line.split("127.0.0.1:", 1)[1].split("/", 1)[0])
            except (IndexError, ValueError):
                raise RuntimeError(f"palaver-server did not start (exit {self._swift.poll()})") from None
        return self.swift_port

    def close(self) -> None:
        if self._python is not None:
            self._python.shutdown()
            self._python.server_close()
        if self._keychain is not None:
            from palaver import keychain, notes

            keychain.backend, notes.find_claude = self._keychain, self._find_claude
        if self._swift is not None:
            self._swift.terminate()
            try:
                self._swift.wait(timeout=70)
            except subprocess.TimeoutExpired:
                self._swift.kill()
                self._swift.wait()


def http_request(port: int, req: dict, side: Path | None = None) -> Any:
    """One request to the server on ``port``, its answer normalized: ``{"status", "headers", "body"}``.

    ``req``: ``method`` (GET), ``path`` (``{key}`` stands for the key), ``body`` (JSON), ``raw`` (text) or ``data``
    (bytes: a step's ``raw_file``, the side's file of that relative path, read by ``with_tokens``),
    ``content_type`` (application/json with a body), ``content_length`` (sent instead of the body's own,
    with only the body after it), ``host`` (``self``, ``localhost``, ``other`` or ``none``), ``cookie``
    (``key``, ``wrong``, ``other-port`` or ``none``) and ``headers`` (more, e.g. ``{"Range": "bytes=0-99"}``). The port and the key read ``<port>`` and ``<key>``.
    A JSON body is compared as JSON, any other by its length and SHA-256. ``side``: the side's own path (and its
    resolved one) in a JSON body counts as ``<side>`` in its Content-Length, as diff.py reads it in the body: the
    sides' paths differ in length (Settings → Storage names the recordings folder)."""
    path = req.get("path", "/").replace("{key}", WEB_KEY)
    body = (req["data"] if "data" in req else req.get("raw", "").encode() if "raw" in req
            else json.dumps(req["body"]).encode() if "body" in req else None)
    host = {"self": f"127.0.0.1:{port}", "localhost": f"localhost:{port}", "other": "evil.example:8765",
            "none": None}[req.get("host", "self")]
    cookie = {"key": f"palaver_key_{port}={WEB_KEY}", "wrong": f"palaver_key_{port}=wrong",
              "other-port": f"palaver_key_{port + 1}={WEB_KEY}", "none": None}[req.get("cookie", "key")]
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    try:
        conn.putrequest(req.get("method", "GET"), path, skip_host=True, skip_accept_encoding=True)
        if host is not None:
            conn.putheader("Host", host)
        if cookie is not None:
            conn.putheader("Cookie", cookie)
        for name, value in req.get("headers", {}).items():
            conn.putheader(name, value)
        if body is not None or "content_type" in req:
            conn.putheader("Content-Type", req.get("content_type", "application/json"))
        if body is not None or "content_length" in req:
            conn.putheader("Content-Length", str(req.get("content_length", len(body or b""))))
        conn.endheaders()
        if body:
            conn.send(body)
        resp = conn.getresponse()
        data = resp.read()
        status, headers = resp.status, resp.headers
    except (ConnectionError, http.client.HTTPException, TimeoutError) as exc:  # a difference, not the run's end
        return {"status": None, "error": type(exc).__name__, "body": None}
    finally:
        conn.close()

    def norm(v: str) -> str:
        return v.replace(WEB_KEY, "<key>").replace(str(port), "<port>")

    out_headers = {k: norm(headers[k]) for k in HTTP_HEADERS if headers.get(k) is not None}
    if (headers.get("Content-Type") or "").startswith("application/json") and data:
        shown: Any = json.loads(data)
        if side is not None and "Content-Length" in out_headers:
            normalized = data
            for prefix in sorted({str(side), str(side.resolve())}, key=len, reverse=True):
                normalized = normalized.replace(prefix.encode(), b"<side>")
            if normalized != data:
                out_headers["Content-Length"] = f"{len(normalized)} (<side> for the side's path)"
    else:
        shown = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    return {"status": status, "headers": out_headers, "body": shown}


def with_tokens(req: dict, side: Path) -> dict:
    """``req`` with each ``"<undo:LABEL>"`` of its body made the token of ``side``'s newest snapshot labelled so,
    each ``"<project:NAME>"`` (``"<term:NAME>"``) of its body and path the id of the project (glossary term) called so, and each ``<event:TITLE>`` of its
    path the key of that event of events.json (each left as it is when there is none); a ``raw_file`` becomes the bytes
    of that file of ``side`` (``data``); ``"<mcp-cleared>"`` reads the token of the side's newest cleared MCP access
    log."""
    root = side / "Recordings" / ".trash" / ".undo"

    def token(label: str) -> str | None:
        found = []
        for snap in root.iterdir() if root.is_dir() else []:
            try:
                manifest = json.loads((snap / "manifest.json").read_text())
            except (OSError, ValueError):
                continue
            if manifest.get("label") == label:
                found.append((datetime.fromisoformat(manifest["time"]), snap.name))
        return max(found)[1] if found else None

    def project(name: str) -> str | None:
        try:
            named = json.loads((side / "config" / "palaver" / "projects.json").read_text())["projects"]
        except (OSError, ValueError, KeyError):
            return None
        return next((pid for pid, p in named.items() if p.get("name") == name), None)

    def term(name: str) -> str | None:
        try:
            terms = json.loads((side / "config" / "palaver" / "glossary.json").read_text())["terms"]
        except (OSError, ValueError, KeyError):
            return None
        return next((tid for tid, t in terms.items() if t.get("term") == name), None)

    def mcp_cleared() -> str | None:
        """The token of the side's newest cleared MCP access log (mcp_access.clear's)."""
        support = side / "home" / "Library" / "Application Support" / "palaver"
        found = sorted(support.glob("mcp-access.cleared-*.jsonl"), key=lambda p: p.stat().st_mtime) if support.is_dir() else []
        return found[-1].name[len("mcp-access.cleared-"):-len(".jsonl")] if found else None

    def resolve(v: Any) -> Any:
        if v == "<mcp-cleared>":
            return mcp_cleared() or v
        if isinstance(v, str) and v.startswith("<undo:") and v.endswith(">"):
            return token(v[len("<undo:"):-1]) or v
        if isinstance(v, str) and v.startswith("<project:") and v.endswith(">"):
            return project(v[len("<project:"):-1]) or v
        if isinstance(v, str) and v.startswith("<term:") and v.endswith(">"):
            return term(v[len("<term:"):-1]) or v
        if isinstance(v, list):
            return [resolve(x) for x in v]
        if isinstance(v, dict):
            return {k: resolve(x) for k, x in v.items()}
        return v

    def path(p: str) -> str:
        from urllib.parse import quote

        from palaver.calendar_events import Event

        def event(m: re.Match) -> str:
            events = json.loads((side / "events.json").read_text())
            found = next((Event.from_dict(d) for d in events if d.get("title") == m.group(1)), None)
            return quote(found.key, safe="") if found else m.group(0)

        p = re.sub(r"<project:([^>]*)>", lambda m: project(m.group(1)) or m.group(0), p)
        p = re.sub(r"<term:([^>]*)>", lambda m: term(m.group(1)) or m.group(0), p)
        return re.sub(r"<event:([^>]*)>", event, p)

    out = {**req, "path": path(req.get("path", "/"))}
    if "raw_file" in req:  # an exported meeting's zip, as each side wrote it
        # A side that wrote none (in real mode the export's meeting is the corpus', not there) sends an empty
        # body: the export's own answer already shows whether the sides differ.
        f = side / req["raw_file"]
        out["data"] = f.read_bytes() if f.is_file() else b""
    return {**out, "body": resolve(req["body"])} if "body" in req else out


def run_scenario(scenario: dict, workdir: Path, *, parity_bin: Path, now: datetime, real: Path | None = None,
                 anonymized: bool = False, server_bin: Path = SERVER_BIN,
                 worker_bin: Path = WORKER_BIN) -> list[diff.Difference]:
    """Both sides through the scenario's steps; the differences in their files and answers."""
    if scenario.get("calendar"):  # the servers ask their fake calendar on their own clock: upcoming is from now on
        now = datetime.now(now.tzinfo).replace(microsecond=0)
    py, sw = prepare(workdir, now=now, real=real, anonymized=anonymized)
    if scenario.get("probe") is not None:  # the setup assistant's Mac, the same on both sides
        for side in (py, sw):
            (side / "probe.json").write_text(json.dumps(scenario["probe"], ensure_ascii=False))
            # No Claude Code CLI on either side (the root conftest's `no_notes_models` on Python's): the provider
            # helper the Swift server asks would find this Mac's.
            config = side / "config" / "palaver" / "config.toml"
            config.write_text(config.read_text() + f"claude = {json.dumps(str(side / 'no-claude'))}\n")
    roots = scenario.get("compare")
    known = diff.ids(py, roots)  # the corpus': ids beyond these are new
    results = []
    servers = Servers(py, sw, server_bin, calendar=bool(scenario.get("calendar")), probe=scenario.get("probe") is not None)
    try:
        for i, step in enumerate(scenario["steps"]):
            if "http" in step:
                req = step["http"]
                label = f"result[{i}] http {req.get('method', 'GET')} {req.get('path', '/')}"
                port = servers.python_port()  # never inside patched(): it patches by itself
                with ops.patched(py):
                    answer = http_request(port, with_tokens(req, py), py)
                theirs = http_request(servers.swift(), with_tokens(req, sw), sw)
                for body in (answer["body"], theirs["body"]):  # random on each side (an MCP log's undo token)
                    for key in req.get("volatile", []):
                        if isinstance(body, dict) and body.get(key) is not None:
                            body[key] = "<volatile>"
                results.append((label, answer, theirs, False))
                continue
            if "remove" in step:  # files of the corpus a step should not find, on both sides
                for side in (py, sw):
                    for rel in step["remove"]:
                        (side / rel).unlink(missing_ok=True)
                continue
            if "worker" in step:
                cmd = step["worker"]
                if isinstance(cmd, list):  # the same arguments on both sides
                    cmd = {"python": cmd, "swift": cmd}
                label = f"result[{i}] worker {' '.join(cmd['swift'])}"
                engine = step.get("engine")
                results.append((label, worker_step(cmd, py, swift_side=False, engine=engine),
                                worker_step(cmd, sw, swift_side=True, worker_bin=worker_bin, engine=engine),
                                bool(step.get("error"))))
                continue
            op = step["op"]
            args = ops.args_for(op, step.get("args", {}))
            results.append((f"result[{i}] {op}", ops.run(op, py, args), swift(parity_bin, op, sw, args),
                            bool(step.get("error"))))
    finally:
        servers.close()
    rules = {pattern: diff.RULES[name] for pattern, name in scenario.get("rules", {}).items()}
    return diff.compare(py, sw, real=real is not None, rules=rules, roots=roots,
                        results=results if scenario.get("result", True) else None, known_ids=known)


def _inside(a: Path, b: Path) -> bool:
    return a == b or b in a.parents


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Python and Swift on the same folders, every file diffed.")
    p.add_argument("--scenario", action="append", help="a scenario's name (all of them when left out)")
    p.add_argument("--real", type=Path, help="a folder of real meetings, copied, never written to")
    p.add_argument("--out", type=Path, help="where the sides go (real mode; kept for a look)")
    p.add_argument("--anonymize", action="store_true", help="anonymize the real meetings' copies")
    p.add_argument("--parity-bin", type=Path, default=PARITY_BIN, help="the Swift helper (make parity-helper)")
    p.add_argument("--server-bin", type=Path, default=SERVER_BIN, help="the Swift server (make parity-helper)")
    args = p.parse_args(argv)
    if (args.real is None) != (args.out is None):
        p.error("--real and --out go together")
    if args.anonymize and args.real is None:
        p.error("--anonymize needs --real")
    if args.real is not None:
        real, out = args.real.resolve(), args.out.resolve()
        if not real.is_dir():
            p.error("--real must be a folder")
        if _inside(out, real) or _inside(real, out):
            p.error("--out must be outside --real")
        if out.exists() and any(out.iterdir()):
            p.error("--out must be a new or empty folder")
    if not args.parity_bin.exists():
        print(f"{args.parity_bin} is missing: make parity-helper", file=sys.stderr)
        return 2
    names = args.scenario or sorted(f.stem for f in SCENARIOS.glob("*.json"))
    os.environ["TZ"] = "Europe/Berlin"
    time.tzset()
    now = datetime.now().astimezone().replace(microsecond=0)
    failed = False
    with tempfile.TemporaryDirectory(prefix="parity-") as tmp:
        for name in names:
            scenario = json.loads((SCENARIOS / f"{name}.json").read_text())
            workdir = (out if args.real is not None else Path(tmp)) / name
            found = run_scenario(scenario, workdir, parity_bin=args.parity_bin, now=now,
                                 real=real if args.real is not None else None, anonymized=args.anonymize,
                                 server_bin=args.server_bin)
            failed = failed or bool(found)
            print(f"{name}: {'no differences' if not found else f'{len(found)} differences'}")
            for d in found:
                print(f"  {d.path}  {d.where}" if args.real is not None else "  " + str(d).replace("\n", "\n  "))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
