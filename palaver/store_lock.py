"""The cross-process lock every store writer takes (Swift: ``StoreLock``, same files, same ``flock``).

``<store>.lock`` beside a store (``voices.lock`` beside ``voices/``), ``<folder>/.speakers.lock`` per
meeting. A writer holds one lock only around reload, change, save: never two different locks at once
(no deadlocks) and never during a model run. A lock that cannot be opened or taken raises: a writer
never runs unlocked.
"""

from __future__ import annotations

import contextlib
import fcntl
import os
import threading
from pathlib import Path
from typing import Iterator

_local = threading.local()


@contextlib.contextmanager
def _hold(lock: Path) -> Iterator[None]:
    # Symlinks resolved on the folder, so two spellings of one lock are one key.
    key = str(lock.parent.resolve() / lock.name)
    held: set[str] = _local.__dict__.setdefault("held", set())
    if key in held:  # this thread has it already
        yield
        return
    assert not held, f"store_lock: {key} taken while this thread holds {sorted(held)}"
    with contextlib.suppress(OSError):
        lock.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_CLOEXEC, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)  # retries on EINTR by itself
        held.add(key)
        try:
            yield
        finally:
            held.discard(key)
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def locked(target: Path):
    """``with locked(store_path):`` holds ``<store_path>.lock``; taking it again in this thread is free."""
    target = Path(target)
    return _hold(target.parent / (target.name + ".lock"))


def meeting_lock(folder: Path):
    """The meeting's own lock: ``<folder>/.speakers.lock``."""
    return _hold(Path(folder) / ".speakers.lock")
