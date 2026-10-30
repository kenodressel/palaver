"""What a log needs to be read later (#59): which Palaver wrote it (version,
git commit of the checkout, dirty or not), and the tracebacks of crashes.

``stamp`` fields go into every log a process opens (session_log). The crash
log, ``~/Library/Logs/palaver/crashes.log``, gets every uncaught exception
of the menu bar app, the window's server and the CLI, with its traceback,
also from threads, and a native crash's stack (faulthandler). It is never
rotated or cut: testing is internal, the maintainer wants all of it.
"""

from __future__ import annotations

import faulthandler
import functools
import os
import platform
import subprocess
import sys
import threading
import traceback
from datetime import datetime
from pathlib import Path

from . import __version__

LOG_DIR = Path.home() / "Library" / "Logs" / "palaver"
CRASH_LOG = LOG_DIR / "crashes.log"
REPO = Path(__file__).resolve().parent.parent


@functools.cache
def git_info(repo: Path = REPO) -> dict:
    """The checkout's commit and whether it has changes; {} when Palaver
    does not run from a git checkout (a release install)."""
    if not (repo / ".git").exists():
        return {}

    def git(*args: str) -> str:
        return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True,
                              timeout=5, check=True).stdout.strip()

    try:
        commit = git("rev-parse", "HEAD")
        dirty = bool(git("status", "--porcelain", "--untracked-files=no"))
        branch = git("rev-parse", "--abbrev-ref", "HEAD")
    except (OSError, subprocess.SubprocessError):
        return {}
    return {"commit": commit, "dirty": dirty, "branch": branch}


def stamp() -> dict:
    """Who writes: the version and commit, the process and its command."""
    info = git_info()
    return {"version": __version__, "commit": info.get("commit"), "dirty": info.get("dirty"),
            "pid": os.getpid(), "argv": sys.argv[1:], "python": platform.python_version()}


def version_text() -> str:
    """``0.1.0 (abc1234, dirty)``."""
    info = git_info()
    if not info:
        return __version__
    return f"{__version__} ({info['commit'][:7]}{', dirty' if info['dirty'] else ''})"


def write_crash(where: str, exc_type, exc, tb) -> None:
    """One crash into the crash log, with its traceback; never raises."""
    try:
        CRASH_LOG.parent.mkdir(parents=True, exist_ok=True)
        head = (f"=== {datetime.now().astimezone().isoformat(timespec='seconds')} {where} pid {os.getpid()} "
                f"palaver {version_text()} argv {sys.argv[1:]}\n")
        with open(CRASH_LOG, "a", encoding="utf-8") as f:
            f.write(head + "".join(traceback.format_exception(exc_type, exc, tb)) + "\n")
    except Exception:
        pass


class _PrintedToo:
    """A module's ``traceback``, whose print_exc also writes the crash log."""

    def __init__(self, where: str):
        self._where = where

    def __getattr__(self, name):
        return getattr(traceback, name)

    def print_exc(self, *args, **kwargs):
        write_crash(self._where, *sys.exc_info())
        traceback.print_exc(*args, **kwargs)


def log_printed_exceptions(module, where: str) -> None:
    """``module`` catches exceptions and prints them with traceback.print_exc
    (rumps' menu and timer callbacks, PyObjC's event loop): they go on, and
    into the crash log too."""
    module.traceback = _PrintedToo(where)


_installed = False
_fault_file = None


def install_crash_log(name: str) -> None:
    """Uncaught exceptions (main thread, other threads) and native crashes
    of this process go to the crash log, then on as before."""
    global _installed, _fault_file
    if _installed:
        return
    _installed = True
    previous_hook, previous_thread_hook = sys.excepthook, threading.excepthook

    def hook(exc_type, exc, tb):
        if not issubclass(exc_type, KeyboardInterrupt):
            write_crash(name, exc_type, exc, tb)
        previous_hook(exc_type, exc, tb)

    def thread_hook(args):
        if args.exc_type is not SystemExit:
            write_crash(f"{name} thread {getattr(args.thread, 'name', '?')}", args.exc_type, args.exc_value,
                        args.exc_traceback)
        previous_thread_hook(args)

    sys.excepthook = hook
    threading.excepthook = thread_hook
    try:
        CRASH_LOG.parent.mkdir(parents=True, exist_ok=True)
        _fault_file = open(CRASH_LOG, "a", encoding="utf-8")  # kept open: faulthandler writes on a signal
        faulthandler.enable(file=_fault_file, all_threads=True)
    except OSError:
        pass
