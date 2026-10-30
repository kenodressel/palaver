"""Who read what through `palaver mcp` (issue #45): the access log, the
heartbeat files of running servers, and the window's view of both."""

import asyncio
import fcntl
import json
import threading
import os
import signal
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

import pytest

from palaver import cli, mcp_access, mcp_server
from palaver.webapp import api
from palaver.webapp.server import App, make_server

from .test_webapp import MEETING, _meeting, _post, _req, server  # noqa: F401  (server: a fixture)

ROOT = Path(__file__).resolve().parent.parent


def _call(srv, name, **args):
    return asyncio.run(srv.call_tool(name, args))


# --- the log ---------------------------------------------------------------------

def test_every_tool_call_is_logged_with_short_args_and_what_went_out(tmp_path: Path):
    _meeting(tmp_path)
    srv = mcp_server.build_server(tmp_path, "Timo")
    _call(srv, "search_meetings", query="salary")
    _call(srv, "get_meeting", meeting_id=MEETING, from_minute=0, to_minute=20)
    _call(srv, "list_people")

    people, meeting, search = mcp_access.read()
    assert search["tool"] == "search_meetings" and search["args"] == {"query": "salary"}  # defaults left out
    assert search["out"]["meetings"] == 1 and search["out"]["lines"] == 1 and search["out"]["chars"] > 50
    assert search["meetings"] == [MEETING]
    assert meeting["args"] == {"meeting_id": MEETING, "from_minute": 0, "to_minute": 20}
    assert meeting["out"]["meetings"] == 1 and meeting["out"]["lines"] == 3
    assert meeting["meetings"] == [MEETING]
    assert people["tool"] == "list_people" and people["args"] == {} and "meetings" not in people
    assert people["out"]["people"] == 0 and people["out"]["chars"] == 2  # nobody named yet: []
    for e in (people, meeting, search):
        assert e["pid"] == os.getpid() and isinstance(e["ms"], int) and "error" not in e
        assert datetime.fromisoformat(e["time"]).tzinfo is not None
        assert e["client"] is None  # no initialize handshake in-process


def test_only_meeting_ids_are_logged_as_meetings(tmp_path: Path):
    _meeting(tmp_path)
    api.set_meeting_project(tmp_path, MEETING, name="Hiring")
    srv = mcp_server.build_server(tmp_path, "Timo")
    _call(srv, "list_projects")
    _call(srv, "open_next_steps")
    steps, projects = mcp_access.read()
    assert projects["out"]["projects"] == 1 and "meetings" not in projects  # a project id is no meeting
    assert steps["meetings"] == [MEETING] and steps["out"]["next_steps"] == 1


def test_long_args_are_cut_short(tmp_path: Path):
    srv = mcp_server.build_server(tmp_path, "Timo")
    _call(srv, "search_meetings", query="word " * 100)
    [entry] = mcp_access.read()
    assert len(entry["args"]["query"]) <= 120 and entry["args"]["query"].endswith("…")


def test_a_failing_call_is_logged_with_its_error(tmp_path: Path):
    srv = mcp_server.build_server(tmp_path, "Timo")
    with pytest.raises(Exception):
        _call(srv, "get_project", project="Nope")
    [entry] = mcp_access.read()
    assert entry["tool"] == "get_project" and "no project 'Nope'" in entry["error"]
    assert entry["out"] == {}


def test_logging_never_breaks_a_tool_call(tmp_path: Path, monkeypatch):
    _meeting(tmp_path)
    srv = mcp_server.build_server(tmp_path, "Timo")
    blocker = tmp_path / "a-file"
    blocker.write_text("")
    monkeypatch.setattr(mcp_access, "LOG_PATH", blocker / "mcp-access.jsonl")  # its folder can't be made
    assert _call(srv, "list_meetings").structured_content["result"][0]["id"] == MEETING

    def broken(*args, **kwargs):
        raise RuntimeError("measuring failed")

    monkeypatch.setattr(mcp_server, "_measure", broken)
    assert _call(srv, "list_meetings").structured_content["result"][0]["id"] == MEETING


def test_wrapping_keeps_the_tools_schemas_and_descriptions(tmp_path: Path):
    tools = {t.name: t for t in asyncio.run(mcp_server.build_server(tmp_path, "Timo").list_tools())}
    get_meeting = tools["get_meeting"]
    assert get_meeting.description.startswith("One meeting")
    assert get_meeting.input_schema["required"] == ["meeting_id"]
    assert set(get_meeting.input_schema["properties"]) == {"meeting_id", "include_transcript", "from_minute",
                                                            "to_minute"}


def test_the_log_is_never_rotated_and_an_old_rotated_file_is_still_read():
    """Every line stays while testing is internal (#59)."""
    log = mcp_access.LOG_PATH
    log.parent.mkdir(parents=True, exist_ok=True)
    log.with_name("mcp-access.1.jsonl").write_text("".join(json.dumps({"n": n}) + "\n" for n in range(5)))
    for n in range(5, 60):
        mcp_access.append({"tool": "list_meetings", "n": n, "pad": "x" * 50})
    assert sorted(p.name for p in log.parent.glob("*.jsonl")) == ["mcp-access.1.jsonl", "mcp-access.jsonl"]
    with log.open("a") as f:
        f.write("not json\n")  # a torn line is skipped
    assert [e["n"] for e in mcp_access.read()] == list(range(59, -1, -1))  # newest first, none missing
    assert [e["n"] for e in mcp_access.read(limit=3)] == [59, 58, 57]


def test_a_held_lock_drops_the_line_instead_of_blocking_the_call():
    mcp_access.append({"n": 1})
    with open(mcp_access.LOG_PATH.with_suffix(".lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)  # another process stuck while writing
        t0 = time.monotonic()
        mcp_access.append({"n": 2})
        assert time.monotonic() - t0 < 1.0
        fcntl.flock(lock, fcntl.LOCK_UN)
    mcp_access.append({"n": 3})
    assert [e["n"] for e in mcp_access.read()] == [3, 1]


def test_reads_of_one_meeting(tmp_path: Path):
    mcp_access.append({"tool": "get_meeting", "meetings": [MEETING], "n": 1})
    mcp_access.append({"tool": "list_people", "n": 2})
    mcp_access.append({"tool": "search_meetings", "meetings": ["2026-10-26T09-00-00", MEETING], "n": 3})
    assert [e["n"] for e in mcp_access.read(meeting=MEETING)] == [3, 1]


def test_clearing_the_log_can_be_undone():
    mcp_access.append({"n": 1})
    mcp_access.append({"n": 2})
    token = mcp_access.clear()
    assert token and mcp_access.read() == [] and not mcp_access.LOG_PATH.exists()
    mcp_access.append({"n": 3})  # a call while the toast shows
    assert mcp_access.restore(token) is True
    assert [e["n"] for e in mcp_access.read()] == [3, 2, 1]
    assert mcp_access.restore(token) is False  # once
    assert mcp_access.clear() and mcp_access.clear() is None  # nothing left to clear


def test_a_cleared_log_is_gone_for_good_after_a_while():
    mcp_access.append({"n": 1})
    token = mcp_access.clear()
    [aside] = mcp_access.LOG_PATH.parent.glob("*cleared*")
    old = time.time() - mcp_access.CLEARED_KEEP_SECONDS - 5
    os.utime(aside, (old, old))
    assert mcp_access.read() == []
    assert not aside.exists() and mcp_access.restore(token) is False


def test_a_cleared_log_is_deleted_when_the_undo_window_ends_even_if_nobody_looks(monkeypatch):
    monkeypatch.setattr(mcp_access, "CLEARED_KEEP_SECONDS", 0.3)
    mcp_access.append({"n": 1})
    token = mcp_access.clear()
    assert mcp_access.restore(token) is True  # within the window
    token = mcp_access.clear()
    folder = mcp_access.LOG_PATH.parent
    assert list(folder.glob("*cleared*"))
    deadline = time.monotonic() + 3
    while list(folder.glob("*cleared*")) and time.monotonic() < deadline:
        time.sleep(0.05)
    assert not list(folder.glob("*cleared*"))  # no read() called meanwhile


def test_any_log_write_deletes_an_expired_cleared_log():
    mcp_access.append({"n": 1})
    mcp_access.clear()
    [aside] = mcp_access.LOG_PATH.parent.glob("*cleared*")
    old = time.time() - mcp_access.CLEARED_KEEP_SECONDS - 5
    os.utime(aside, (old, old))  # the window (and its timer) went away meanwhile
    mcp_access.append({"n": 2})  # a `palaver mcp` process writing
    assert not aside.exists()


# --- running servers -----------------------------------------------------------------

def _dead_pid() -> int:
    p = subprocess.Popen(["true"])
    p.wait()
    return p.pid


def test_heartbeat_files_show_the_live_clients_and_dead_ones_are_pruned():
    session = mcp_access.Session()
    session.start()
    session.set_client({"name": "claude-code", "version": "2.1.3"})
    session.called("get_meeting")

    folder = mcp_access.PROCESS_DIR
    dead = folder / f"{_dead_pid()}.json"
    dead.write_text(json.dumps({"pid": int(dead.stem)}))
    quiet = folder / f"{os.getppid()}.json"  # alive, but no heartbeat for 10 min: not shown, kept
    quiet.write_text(json.dumps({"pid": os.getppid()}))
    ten_min = time.time() - 600
    os.utime(quiet, (ten_min, ten_min))

    [client] = mcp_access.clients()
    assert client["pid"] == os.getpid() and client["client"] == {"name": "claude-code", "version": "2.1.3"}
    assert client["calls"] == 1 and client["last_tool"] == "get_meeting" and client["last_call"] and client["started"]
    assert not dead.exists() and quiet.exists()

    two_hours = time.time() - 7200  # a pid that lives on that long without a beat is someone else's now
    os.utime(quiet, (two_hours, two_hours))
    mcp_access.clients()
    assert not quiet.exists()

    session.stop()
    assert mcp_access.clients() == [] and not (folder / f"{os.getpid()}.json").exists()


def test_stopping_never_waits_for_the_session_lock():
    # SIGTERM's handler stops the session; the main thread may hold the lock then.
    session = mcp_access.Session()
    session.start()
    with session._lock:
        stopper = threading.Thread(target=session.stop)
        stopper.start()
        stopper.join(timeout=2)
        assert not stopper.is_alive()
    assert not (mcp_access.PROCESS_DIR / f"{os.getpid()}.json").exists()
    session.called("list_meetings")  # after stop: no file comes back
    assert not (mcp_access.PROCESS_DIR / f"{os.getpid()}.json").exists()


SERVE = """
import sys
from pathlib import Path
from palaver import cli, mcp_access, mcp_server
from palaver.webapp import api
from palaver.webapp.server import App, make_server
root = Path(sys.argv[1])
mcp_access.LOG_PATH = root / "mcp-access.jsonl"
mcp_access.PROCESS_DIR = root / "mcp"
mcp_server.serve(Path(sys.argv[2]), "Timo", orphan_check=0.2)
"""


def _send(proc, message):
    proc.stdin.write((json.dumps(message) + "\n").encode())
    proc.stdin.flush()


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def test_the_stdio_server_logs_its_client_and_exits_when_the_client_closes(tmp_path: Path, mcp_files_in_tmp: Path):
    _meeting(tmp_path / "rec")
    proc = subprocess.Popen([sys.executable, "-c", SERVE, str(mcp_files_in_tmp), str(tmp_path / "rec")],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=ROOT)
    heartbeat = mcp_files_in_tmp / "mcp" / f"{proc.pid}.json"
    try:
        _send(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "claude-code", "version": "2.1.3"}}})
        assert json.loads(proc.stdout.readline())["id"] == 1
        _send(proc, {"jsonrpc": "2.0", "method": "notifications/initialized"})
        _send(proc, {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                     "params": {"name": "list_meetings", "arguments": {}}})
        reply = json.loads(proc.stdout.readline())
        assert reply["id"] == 2 and not reply["result"].get("isError")

        beat = json.loads(heartbeat.read_text())
        assert beat["client"] == {"name": "claude-code", "version": "2.1.3"} and beat["calls"] == 1
        assert [c["pid"] for c in mcp_access.clients()] == [proc.pid]

        proc.stdin.close()  # the client is gone
        assert proc.wait(timeout=10) == 0
    finally:
        if proc.poll() is None:
            proc.kill()
    assert not heartbeat.exists()
    [entry] = mcp_access.read()
    assert entry["client"] == {"name": "claude-code", "version": "2.1.3"} and entry["pid"] == proc.pid
    assert entry["tool"] == "list_meetings" and entry["out"]["meetings"] == 1


# The client dies but something else keeps the server's stdin open (the
# pipe was inherited): no EOF ever comes. The server notices it was orphaned.
MIDDLE = """
import subprocess, sys, time
from pathlib import Path
p = subprocess.Popen([sys.executable, "-c", *sys.argv[1:]])
print(p.pid, flush=True)
heartbeat = Path(sys.argv[2]) / "mcp" / f"{p.pid}.json"
deadline = time.monotonic() + 10
while not heartbeat.exists() and time.monotonic() < deadline:
    time.sleep(0.05)
sys.exit(0 if heartbeat.exists() else 3)  # 3: the server never came up
"""


def test_the_server_exits_when_its_client_dies_even_if_stdin_stays_open(tmp_path: Path, mcp_files_in_tmp: Path):
    read_end, write_end = os.pipe()
    middle = subprocess.Popen([sys.executable, "-c", MIDDLE, SERVE, str(mcp_files_in_tmp), str(tmp_path)],
                              stdin=read_end, stdout=subprocess.PIPE, cwd=ROOT)
    os.close(read_end)
    pid = int(middle.stdout.readline())
    middle.stdout.close()
    heartbeat = mcp_files_in_tmp / "mcp" / f"{pid}.json"
    try:
        assert middle.wait(timeout=15) == 0  # the server ran; its "client" is gone, the pipe still open
        deadline = time.monotonic() + 10
        while _alive(pid) and time.monotonic() < deadline:
            time.sleep(0.05)
        assert not _alive(pid), "the orphaned server kept running"
    finally:
        os.close(write_end)
        if _alive(pid):
            os.kill(pid, signal.SIGKILL)
    assert not heartbeat.exists()


# --- setup ----------------------------------------------------------------------------

def test_registered_reads_the_claude_code_config():
    assert mcp_access.registered() == {"registered": False}  # no Claude Code config at all
    config = mcp_access.CLAUDE_CONFIG
    config.write_text(json.dumps({"mcpServers": {
        "other": {"type": "stdio", "command": "npx", "args": ["x"]},
        "meetings": {"type": "stdio", "command": "/v/bin/python3", "args": ["-m", "palaver", "mcp"]}}}))
    assert mcp_access.registered() == {"registered": True, "name": "meetings", "scope": "user"}
    config.write_text(json.dumps({"projects": {"/x": {"mcpServers": {
        "notes": {"command": "/v/bin/palaver", "args": ["mcp"]}}}}}))
    assert mcp_access.registered() == {"registered": True, "name": "notes", "scope": "project"}
    config.write_text(json.dumps({"mcpServers": {}}))
    assert mcp_access.registered() == {"registered": False}
    config.write_text("{not json")
    assert mcp_access.registered() == {"registered": None}


def test_registered_reads_the_claude_desktop_config():
    assert mcp_access.desktop_registered() == {"installed": False, "registered": False}
    mcp_access.DESKTOP_APP.mkdir(parents=True)
    assert mcp_access.desktop_registered() == {"installed": True, "registered": False}
    config = mcp_access.DESKTOP_CONFIG
    config.parent.mkdir(parents=True)
    config.write_text(json.dumps({"mcpServers": {
        "meetings": {"command": "/v/bin/python3", "args": ["-m", "palaver", "mcp"]}}}))
    assert mcp_access.desktop_registered() == {"installed": True, "registered": True, "name": "meetings"}
    config.write_text("{not json")
    assert mcp_access.desktop_registered() == {"installed": True, "registered": None}


def test_install_desktop_merges_into_its_config_and_keeps_a_backup():
    config = mcp_access.DESKTOP_CONFIG
    config.parent.mkdir(parents=True)
    before = json.dumps({"globalShortcut": "Alt+Space", "mcpServers": {
        "other": {"command": "npx", "args": ["other"]},
        "meetings": {"command": "/old/python", "args": [], "env": {"A": "1"}}}}, indent=2)
    config.write_text(before)

    mcp_access.install_desktop("/v/bin/python3", ["--config", "/c/config.toml"])
    after = json.loads(config.read_text())
    assert after["globalShortcut"] == "Alt+Space" and after["mcpServers"]["other"] == {"command": "npx", "args": ["other"]}
    assert after["mcpServers"]["meetings"] == {"command": "/v/bin/python3", "env": {"A": "1"},
                                               "args": ["-m", "palaver", "--config", "/c/config.toml", "mcp"]}
    assert config.with_name(config.name + ".bak").read_text() == before
    assert sorted(p.name for p in config.parent.iterdir()) == [config.name, config.name + ".bak"]  # no temp file left
    assert mcp_access.desktop_registered()["registered"] is True


def test_install_desktop_creates_the_config_and_never_overwrites_a_broken_one():
    config = mcp_access.DESKTOP_CONFIG
    mcp_access.install_desktop("/v/bin/python3", [])
    assert json.loads(config.read_text()) == {"mcpServers": {"meetings": {
        "command": "/v/bin/python3", "args": ["-m", "palaver", "mcp"]}}}
    config.write_text("{not json")
    with pytest.raises(RuntimeError):
        mcp_access.install_desktop("/v/bin/python3", [])
    assert config.read_text() == "{not json"


def test_cli_installs_into_claude_desktop(capsys):
    assert cli.main(["mcp", "--install", "--desktop"]) == 0
    entry = json.loads(mcp_access.DESKTOP_CONFIG.read_text())["mcpServers"]["meetings"]
    assert entry == {"command": sys.executable, "args": ["-m", "palaver", "mcp"]}
    assert "Quit and reopen Claude Desktop" in capsys.readouterr().out


# --- the window's API ---------------------------------------------------------------------

def test_http_mcp_shows_clients_log_and_setup(server):  # noqa: F811
    session = mcp_access.Session()
    session.start()
    session.set_client({"name": "claude-code", "version": "2.1.3"})
    try:
        mcp_access.append({"tool": "get_meeting", "meetings": [MEETING], "args": {"meeting_id": MEETING}})
        mcp_access.append({"tool": "list_people"})
        status, _, body = _req(server, "/api/mcp")
        d = json.loads(body)
        assert status == 200 and [c["pid"] for c in d["clients"]] == [os.getpid()]
        assert [e["tool"] for e in d["log"]] == ["list_people", "get_meeting"]
        assert d["registered"] == {"registered": False}
        assert d["desktop"] == {"installed": False, "registered": False}

        status, _, body = _req(server, f"/api/mcp?meeting={MEETING}")
        assert status == 200 and [e["tool"] for e in json.loads(body)["reads"]] == ["get_meeting"]

        status, answer = _post(server, "/api/mcp/clear")
        assert status == 200 and answer["log"] == [] and answer["undo"] and answer["cleared"] == 2
        status, back = _post(server, "/api/mcp/restore", {"token": answer["undo"]})
        assert status == 200 and [e["tool"] for e in back["log"]] == ["list_people", "get_meeting"]
        assert _post(server, "/api/mcp/restore", {"token": answer["undo"]})[0] == 404
    finally:
        session.stop()


def test_http_mcp_install_adds_palaver_to_claude_code(server, monkeypatch):  # noqa: F811
    status, answer = _post(server, "/api/mcp/install")
    assert status == 500 and "Claude Code" in answer["error"]  # no claude CLI in tests

    ran = []

    def run(cmd):
        ran.append(cmd)
        mcp_access.CLAUDE_CONFIG.write_text(json.dumps({"mcpServers": {
            "meetings": {"command": sys.executable, "args": ["-m", "palaver", "mcp"]}}}))
        return subprocess.CompletedProcess(cmd, 0, "", "")

    monkeypatch.setattr("palaver.notes.find_claude", lambda configured=None: "/opt/bin/claude")
    monkeypatch.setattr(mcp_access, "_run", run)
    status, answer = _post(server, "/api/mcp/install")
    assert status == 200 and answer["registered"] == {"registered": True, "name": "meetings", "scope": "user"}
    assert ran == [["/opt/bin/claude", "mcp", "add", "--scope", "user", "meetings", "--", sys.executable,
                    "-m", "palaver", "mcp"]]


def test_http_mcp_install_passes_the_apps_cli_options(tmp_path: Path, monkeypatch):
    ran = []
    monkeypatch.setattr("palaver.notes.find_claude", lambda configured=None: "/opt/bin/claude")
    monkeypatch.setattr(mcp_access, "_run", lambda cmd: ran.append(cmd) or subprocess.CompletedProcess(cmd, 0, "", ""))
    srv = make_server(App(tmp_path, "Timo", cli_options=["--config", "/c/config.toml"]), port=0)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        assert _post(srv, "/api/mcp/install")[0] == 200
        status, answer = _post(srv, "/api/mcp/install", {"target": "desktop"})
    finally:
        srv.shutdown()
        srv.server_close()
    assert ran[0][-5:] == ["-m", "palaver", "--config", "/c/config.toml", "mcp"]
    assert status == 200 and answer["desktop"]["registered"] is True
    assert json.loads(mcp_access.DESKTOP_CONFIG.read_text())["mcpServers"]["meetings"]["args"] == [
        "-m", "palaver", "--config", "/c/config.toml", "mcp"]


def test_the_window_app_keeps_the_cli_options():
    from types import SimpleNamespace

    from palaver.webapp import build_app

    cfg = SimpleNamespace(output_dir=Path("/x"), user_name="Timo", notes_enabled=False)
    assert build_app(cfg, ["--config", "/c/config.toml"]).cli_options == ["--config", "/c/config.toml"]


def test_a_search_is_measured_from_its_understood_and_meetings():
    """search_meetings answers {understood, meetings} (#46): the log counts
    the meetings found by words and by meaning, and their lines."""
    result = {"understood": ["Rico"], "meetings": [
        {"id": MEETING, "matched_by": "words", "lines": ["[0:13] a", "[0:15] b"], "notes": []},
        {"id": "2026-10-26T09-00-00", "matched_by": "meaning", "lines": ["[1:00] c"], "notes": ["Decision: d"]}]}
    out, ids = mcp_server._measure("search_meetings", result)
    assert out["meetings"] == 2 and out["lines"] == 3 and out["chars"] > 50
    assert ids == [MEETING, "2026-10-26T09-00-00"]


# --- an install from before the runtime (#60) ----------------------------------------------

OLD_VENV_PYTHON = "/Users/someone/Library/Application Support/palaver/venv/bin/python"


def test_an_entry_into_the_old_installers_venv_counts_as_not_working():
    """The installer before #60 made a venv the runtime replaced: Claude's
    entry points at a python that is gone, and Settings offers the fix."""
    mcp_access.CLAUDE_CONFIG.write_text(json.dumps({"mcpServers": {
        "meetings": {"command": OLD_VENV_PYTHON, "args": ["-m", "palaver", "mcp"]}}}))
    assert mcp_access.registered() == {"registered": False, "stale": True, "name": "meetings", "scope": "user"}
    mcp_access.DESKTOP_APP.mkdir(parents=True)
    mcp_access.DESKTOP_CONFIG.parent.mkdir(parents=True)
    mcp_access.DESKTOP_CONFIG.write_text(json.dumps({"mcpServers": {
        "meetings": {"command": OLD_VENV_PYTHON, "args": ["-m", "palaver", "mcp"]}}}))
    assert mcp_access.desktop_registered() == {"installed": True, "registered": False, "stale": True,
                                               "name": "meetings"}


def test_a_release_moves_stale_entries_to_its_own_python_and_leaves_working_ones(monkeypatch):
    mcp_access.CLAUDE_CONFIG.write_text(json.dumps({"mcpServers": {
        "meetings": {"command": OLD_VENV_PYTHON, "args": ["-m", "palaver", "mcp"]}}}))
    mcp_access.DESKTOP_CONFIG.parent.mkdir(parents=True)
    mcp_access.DESKTOP_CONFIG.write_text(json.dumps({"mcpServers": {
        "meetings": {"command": OLD_VENV_PYTHON, "args": ["-m", "palaver", "mcp"]}}}))
    ran = []
    wrapper = "/Users/someone/Applications/Palaver.app/Contents/Resources/bin/python"

    def run(cmd):
        ran.append(cmd[1:4])
        if cmd[2] == "add":
            mcp_access.CLAUDE_CONFIG.write_text(json.dumps({"mcpServers": {
                "meetings": {"command": wrapper, "args": ["-m", "palaver", "mcp"]}}}))
        return subprocess.CompletedProcess(cmd, 0, "", "")

    monkeypatch.setattr("palaver.notes.find_claude", lambda configured=None: "/opt/bin/claude")
    monkeypatch.setattr(mcp_access, "_run", run)
    assert mcp_access.migrate(wrapper) == ["code", "desktop"]
    assert ran == [["mcp", "remove", "meetings"], ["mcp", "add", "--scope"]]
    assert json.loads(mcp_access.DESKTOP_CONFIG.read_text())["mcpServers"]["meetings"]["command"] == wrapper
    assert mcp_access.migrate(wrapper) == []  # nothing stale any more
