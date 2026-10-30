"""Who read what through `palaver mcp` (issue #45).

Each MCP client starts its own `palaver mcp` process over stdio. Every tool
call appends one JSON line to a shared log (LOG_PATH, never rotated: #59;
an old file rotated before is still read), and each process keeps a heartbeat file
``PROCESS_DIR/<pid>.json`` while it runs. The Meetings window reads both
(``/api/mcp``): which clients are connected, and what they read.

Logging never breaks a tool call: every write here swallows its errors.
The log stays on this Mac; it holds the user's own queries, and the window
can clear it.
"""

from __future__ import annotations

import fcntl
import json
import logging
import os
import secrets
import shutil
import subprocess
import threading
import time
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from typing import Any, Iterator

LOGGER = logging.getLogger(__name__)

SUPPORT_DIR = Path.home() / "Library" / "Application Support" / "palaver"
LOG_PATH = SUPPORT_DIR / "mcp-access.jsonl"
PROCESS_DIR = SUPPORT_DIR / "mcp"
CLAUDE_CONFIG = Path.home() / ".claude.json"  # where `claude mcp add --scope user` writes
DESKTOP_CONFIG = Path.home() / "Library" / "Application Support" / "Claude" / "claude_desktop_config.json"
DESKTOP_APP = Path("/Applications/Claude.app")

APPEND_WAIT_SECONDS = 0.2  # a call never waits longer for the log's lock; its line is dropped then
SHOWN = 200  # log entries the window gets
CLEARED_KEEP_SECONDS = 600  # a cleared log can be brought back (Undo) this long
BEAT_SECONDS = 30  # a running server touches its heartbeat file this often
FRESH_SECONDS = 120  # a heartbeat older than this: not shown as connected
FORGET_SECONDS = 3600  # ... and older than this, its file goes even if the pid lives (reused)


def now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


# --- the log ---------------------------------------------------------------------

def _old(path: Path) -> Path:
    return path.with_name(f"{path.stem}.1{path.suffix}")


@contextmanager
def _locked(wait: float = 2.0) -> Iterator[Path]:
    """The log, locked against the other `palaver mcp` processes and the
    window. Raises TimeoutError when the lock stays taken for ``wait`` s."""
    path = LOG_PATH
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path.with_suffix(".lock"), "a") as lock:
        deadline = time.monotonic() + wait
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("the MCP access log is locked") from None
                time.sleep(0.02)
        try:
            yield path
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def append(entry: dict[str, Any]) -> None:
    """One line for one call. Never raises, and never waits long: with the
    log locked, the line is dropped.
    Every write also deletes a cleared log whose undo time is over."""
    try:
        _forget_cleared()
        line = json.dumps(entry, ensure_ascii=False, default=str) + "\n"
        with _locked(APPEND_WAIT_SECONDS) as path:
            with open(path, "a", encoding="utf-8") as f:
                f.write(line)
    except Exception:
        LOGGER.debug("could not write the MCP access log", exc_info=True)


def _lines(path: Path) -> list[str]:
    try:
        return path.read_text(encoding="utf-8", errors="replace").splitlines()
    except FileNotFoundError:
        return []


def read(limit: int = SHOWN, meeting: str | None = None) -> list[dict[str, Any]]:
    """The newest ``limit`` entries, newest first; with ``meeting``, only the
    calls that sent that meeting out. Lines that are not JSON are skipped."""
    _forget_cleared()
    path = LOG_PATH
    out: list[dict[str, Any]] = []
    for line in reversed(_lines(_old(path)) + _lines(path)):
        if len(out) >= limit:
            break
        if meeting is not None and meeting not in line:
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if isinstance(entry, dict) and (meeting is None or meeting in (entry.get("meetings") or [])):
            out.append(entry)
    return out


def _cleared(token: str) -> Path:
    return LOG_PATH.with_name(f"{LOG_PATH.stem}.cleared-{token}{LOG_PATH.suffix}")


def _forget_cleared(keep: float = CLEARED_KEEP_SECONDS) -> None:
    try:
        for aside in LOG_PATH.parent.glob(f"{LOG_PATH.stem}.cleared-*{LOG_PATH.suffix}"):
            if time.time() - aside.stat().st_mtime > keep:
                aside.unlink(missing_ok=True)
    except OSError:
        pass


def _drop_later(aside: Path) -> None:
    """Delete ``aside`` when its undo time is over, also when nobody reads
    the log meanwhile (the window keeps running in the menu bar app). If
    the app quits first, the next read or write of the log deletes it."""
    def drop() -> None:
        try:
            aside.unlink(missing_ok=True)
        except OSError:
            pass

    timer = threading.Timer(CLEARED_KEEP_SECONDS, drop)
    timer.daemon = True
    timer.start()


def clear() -> str | None:
    """Empty the log (both files). The old lines are kept aside for
    CLEARED_KEEP_SECONDS so the window can undo, then deleted; returns the
    token for ``restore``, or None when there was nothing to clear."""
    with _locked() as path:
        text = "".join(f"{line}\n" for line in _lines(_old(path)) + _lines(path))
        _forget_cleared(keep=-1)  # an earlier clear can't be undone any more
        if not text:
            return None
        token = secrets.token_hex(6)
        aside = _cleared(token)
        aside.write_text(text, encoding="utf-8")
        _old(path).unlink(missing_ok=True)
        path.unlink(missing_ok=True)
    _drop_later(aside)
    return token


def restore(token: str) -> bool:
    """Undo ``clear``: the cleared lines come back before the ones written since."""
    if not token.isalnum():
        return False
    _forget_cleared()
    aside = _cleared(token)
    with _locked() as path:
        if not aside.exists():
            return False
        text = aside.read_text(encoding="utf-8") + "".join(
            f"{line}\n" for line in _lines(_old(path)) + _lines(path))
        tmp = path.with_suffix(".tmp")
        tmp.write_text(text, encoding="utf-8")
        _old(path).unlink(missing_ok=True)
        os.replace(tmp, path)
        aside.unlink()
    return True


# --- running servers -----------------------------------------------------------------

class Session:
    """One `palaver mcp` process: its client (from the initialize handshake),
    and, once ``start``ed, its heartbeat file."""

    def __init__(self) -> None:
        self.pid = os.getpid()
        self.started = now()
        self.client: dict[str, str] | None = None
        self.calls = 0
        self.last_call: str | None = None
        self.last_tool: str | None = None
        self.file: Path | None = None
        self._lock = threading.Lock()

    def _write(self) -> None:
        file = self.file
        if file is None:
            return
        try:
            file.parent.mkdir(parents=True, exist_ok=True)
            tmp = file.with_suffix(".tmp")
            tmp.write_text(json.dumps({
                "pid": self.pid, "started": self.started, "client": self.client, "calls": self.calls,
                "last_call": self.last_call, "last_tool": self.last_tool}))
            if self.file is None:  # stopped meanwhile
                tmp.unlink(missing_ok=True)
                return
            os.replace(tmp, file)
        except Exception:
            LOGGER.debug("could not write the MCP heartbeat", exc_info=True)

    def start(self) -> None:
        self.file = PROCESS_DIR / f"{self.pid}.json"
        self._write()

    def stop(self) -> None:
        """Remove the heartbeat. Takes no lock: a signal handler calls this,
        maybe while the main thread holds ``_lock``."""
        file, self.file = self.file, None
        if file is not None:
            try:
                file.unlink(missing_ok=True)
            except OSError:
                pass

    def beat(self) -> None:
        with self._lock:
            if self.file is not None:
                try:
                    os.utime(self.file)
                except OSError:
                    self._write()

    def set_client(self, info: Any) -> None:
        """From the initialize request's ``clientInfo`` (a dict or a model)."""
        try:
            if info is None:
                return
            get = info.get if isinstance(info, dict) else (lambda k: getattr(info, k, None))
            client = {k: str(get(k)) for k in ("name", "version") if get(k)}
            if client and client != self.client:
                with self._lock:
                    self.client = client
                    self._write()
        except Exception:
            LOGGER.debug("could not read the MCP client info", exc_info=True)

    def called(self, tool: str) -> None:
        with self._lock:
            self.calls += 1
            self.last_call = now()
            self.last_tool = tool
            self._write()

    def record(self, tool: str, *, args: dict[str, Any], out: dict[str, int], meetings: list[str],
               ms: int, error: str | None) -> None:
        """One call: into the log, and into the heartbeat file. Never raises."""
        try:
            entry: dict[str, Any] = {"time": now(), "pid": self.pid, "client": self.client, "tool": tool,
                                     "args": args, "out": out, "ms": ms}
            if meetings:
                entry["meetings"] = meetings
            if error:
                entry["error"] = error
            append(entry)
            self.called(tool)
        except Exception:
            LOGGER.debug("could not record an MCP call", exc_info=True)


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def clients() -> list[dict[str, Any]]:
    """The running `palaver mcp` processes, oldest first. Files of processes
    that are gone (or long silent: their pid is someone else's now) are removed."""
    out = []
    try:
        files = list(PROCESS_DIR.glob("*.json"))
    except OSError:
        return []
    for file in files:
        try:
            pid = int(file.stem)
            age = time.time() - file.stat().st_mtime
            if not _alive(pid) or age > FORGET_SECONDS:
                file.unlink(missing_ok=True)
                continue
            if age > FRESH_SECONDS:
                continue
            beat = json.loads(file.read_text())
        except (ValueError, OSError):
            continue
        if isinstance(beat, dict):
            out.append({**beat, "pid": pid})
    return sorted(out, key=lambda c: c.get("started") or "")


def watch_parent(session: Session, *, interval: float = 5.0, beat: float = BEAT_SECONDS) -> threading.Thread:
    """Keep the heartbeat fresh, and end the process when its client is gone.

    A client that closes the pipe gives the server EOF on stdin, and the
    server ends. But a client that dies while something else still holds
    the pipe (a child that inherited it) never sends EOF: the server is
    reparented to launchd and would wait forever. So: when the parent
    changes, remove the heartbeat and exit."""
    parent = os.getppid()

    def run() -> None:
        last_beat = time.monotonic()
        while True:
            time.sleep(interval)
            if os.getppid() != parent:
                session.stop()
                os._exit(0)
            if time.monotonic() - last_beat >= beat:
                session.beat()
                last_beat = time.monotonic()

    thread = threading.Thread(target=run, name="mcp-parent-watch", daemon=True)
    thread.start()
    return thread


# --- setup ----------------------------------------------------------------------------

_json_cache: dict[str, tuple[Any, Any]] = {}  # path -> (mtime and size, parsed JSON)


def _config(path: Path) -> Any:
    """``path`` parsed; cached until the file changes. FileNotFoundError when
    it does not exist, ValueError/OSError when it can't be read."""
    st = path.stat()
    key = (st.st_mtime_ns, st.st_size)
    cached = _json_cache.get(str(path))
    if cached and cached[0] == key:
        return cached[1]
    value = json.loads(path.read_text(encoding="utf-8"))
    _json_cache[str(path)] = (key, value)
    return value


def _is_palaver(server: Any) -> bool:
    if not isinstance(server, dict):
        return False
    words = [str(server.get("command") or ""), *map(str, server.get("args") or [])]
    return any("palaver" in w for w in words) and "mcp" in words


def _palaver_servers(servers: Any) -> list[str]:
    return [name for name, s in (servers or {}).items() if _is_palaver(s)] if isinstance(servers, dict) else []


# The installer before #60 put a venv here; the runtime replaced it.
OLD_VENVS = ("/Library/Application Support/palaver/venv/", "/Library/Application Support/meeting-transcribe/venv/")


def _stale(server: Any) -> bool:
    """An entry whose python was in the old installer's venv and is gone."""
    command = str((server or {}).get("command") or "")
    return any(v in command for v in OLD_VENVS) and not Path(command).exists()


def registered() -> dict[str, Any]:
    """Whether Claude Code starts this server: read from its config file
    (cheap, cached until the file changes; `claude mcp list` would start
    every server to check it). ``registered`` is None when that can't be told."""
    try:
        config = _config(CLAUDE_CONFIG)
        user = config.get("mcpServers") or {}
        found = [(name, "user", user[name]) for name in _palaver_servers(user)]
        for project in (config.get("projects") or {}).values():
            servers = (project or {}).get("mcpServers") or {}
            found += [(name, "project", servers[name]) for name in _palaver_servers(servers)]
    except FileNotFoundError:
        return {"registered": False}
    except (ValueError, OSError, AttributeError):
        return {"registered": None}
    working = [f for f in found if not _stale(f[2])]
    if working:
        return {"registered": True, "name": working[0][0], "scope": working[0][1]}
    if found:  # it starts a python that is gone: not working, Settings offers the fix
        return {"registered": False, "stale": True, "name": found[0][0], "scope": found[0][1]}
    return {"registered": False}


def desktop_registered() -> dict[str, Any]:
    """Whether Claude Desktop is installed and starts this server (its
    claude_desktop_config.json). ``registered`` None: the file can't be read."""
    out: dict[str, Any] = {"installed": DESKTOP_APP.exists()}
    try:
        servers = _config(DESKTOP_CONFIG).get("mcpServers") or {}
        found = _palaver_servers(servers)
    except FileNotFoundError:
        return {**out, "registered": False}
    except (ValueError, OSError, AttributeError):
        return {**out, "registered": None}
    working = [name for name in found if not _stale(servers[name])]
    if working:
        return {**out, "registered": True, "name": working[0]}
    if found:
        return {**out, "registered": False, "stale": True, "name": found[0]}
    return {**out, "registered": False}


def _run(cmd: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=60)


def install(executable: str, options: list[str] = ()) -> dict[str, Any]:
    """Add this server to Claude Code (`claude mcp add --scope user`), as
    `palaver mcp --install` does; ``options``: global CLI options such as
    --config. Raises RuntimeError when that fails."""
    from . import mcp_server, notes

    claude = notes.find_claude()
    if not claude:
        raise RuntimeError("Claude Code (the claude command) was not found")
    old = registered()
    if old.get("stale"):  # the entry of the installer before: replaced, `mcp add` refuses a taken name
        _run([claude, "mcp", "remove", old["name"], "--scope", old["scope"]])
    cmd = mcp_server.install_command(executable, options=options)
    proc = _run([claude, *cmd[1:]])
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout or "").strip() or f"claude mcp add failed ({proc.returncode})")
    return registered()


def install_desktop(executable: str, options: list[str] = ()) -> dict[str, Any]:
    """Add this server to Claude Desktop as "meetings": merged into its
    config file, every other key and server kept (and the entry's own other
    keys, like env); written atomically, the previous file kept as .bak.
    Claude Desktop reads it when it starts. Raises RuntimeError when the
    file is there but no JSON object (it is left alone then)."""
    from . import mcp_server

    path = DESKTOP_CONFIG
    try:
        before = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        before = None
    try:
        config = json.loads(before) if before is not None else {}
    except ValueError as exc:
        raise RuntimeError(f"{path} is not valid JSON; not changed") from exc
    if not isinstance(config, dict) or not isinstance(config.get("mcpServers", {}), dict):
        raise RuntimeError(f"{path} is not a Claude Desktop config; not changed")
    servers = config.setdefault("mcpServers", {})
    old = servers.get("meetings") if isinstance(servers.get("meetings"), dict) else {}
    servers["meetings"] = {**old, "command": executable, "args": mcp_server.server_args(options=options)}

    path.parent.mkdir(parents=True, exist_ok=True)
    if before is not None:
        shutil.copy2(path, path.with_name(path.name + ".bak"))
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        tmp.write_text(json.dumps(config, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)
    return desktop_registered()


def migrate(executable: str) -> list[str]:
    """Entries the installer before #60 left pointing into its venv, moved
    to ``executable`` (the app's own python wrapper); working ones are left
    alone. Returns which were moved ("code", "desktop")."""
    moved = []
    if registered().get("stale"):
        try:
            install(executable)
            moved.append("code")
        except RuntimeError:
            pass  # no Claude Code here: Settings offers it again
    if desktop_registered().get("stale"):
        try:
            install_desktop(executable)
            moved.append("desktop")
        except RuntimeError:
            pass
    return moved
