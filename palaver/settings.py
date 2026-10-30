"""Settings the app changes itself: realtime transcription and which calls
start a recording (#42). They live in settings.json, never in config.toml,
which holds the tokens and is never rewritten by the app."""

from __future__ import annotations

import json
from contextlib import contextmanager
from dataclasses import asdict, dataclass, fields
from pathlib import Path

from ._xdg import xdg_config_home


@dataclass(frozen=True)
class Settings:
    realtime: bool = True
    record_teams: bool = True
    record_slack: bool = True
    search_meaning: bool = True  # #46: index meetings, search by meaning
    # Transcribe during the call (#30); config.toml's [processing].live is the
    # default, the setup assistant (#55) turns it off on a small Mac.
    live_processing: bool = True
    # The live coach's nudges (#41), by kind.
    nudge_talk_share: bool = True
    nudge_monologue: bool = True
    nudge_quiet_invitee: bool = True
    # Experimental: off until calibrated against bench-live replays (the
    # stream's text drops hesitations and differs from the final transcript).
    nudge_pace: bool = False
    nudge_fillers: bool = False


def path() -> Path:
    return xdg_config_home() / "palaver" / "settings.json"


def load(defaults: Settings = Settings()) -> Settings:
    """The saved settings; a missing or broken file, a missing key or a
    value of the wrong type takes the value from ``defaults``."""
    try:
        data = json.loads(path().read_text())
    except (OSError, ValueError):
        return defaults
    if not isinstance(data, dict):
        return defaults
    values = asdict(defaults)
    for f in fields(Settings):
        if isinstance(data.get(f.name), bool):
            values[f.name] = data[f.name]
    return Settings(**values)


def read_raw() -> dict:
    """The whole file, also what other modules keep in it (providers.py);
    {} when it is missing or broken."""
    try:
        data = json.loads(path().read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def user_name() -> str | None:
    """The user's name as chosen in the app (#55), which wins over
    config.toml's [user].name; None when never chosen."""
    value = read_raw().get("user_name")
    return value.strip() if isinstance(value, str) and value.strip() else None


def current_user_name(default: str) -> str:
    """The name as it is now, for parts that run for long (the menu bar
    app, the MCP server): a change in the app applies without a restart."""
    return user_name() or default


def user_aliases() -> list[str]:
    """The user's earlier names (#55): earlier meetings show them, and they
    still mean the user."""
    value = read_raw().get("user_aliases")
    return [a.strip() for a in value if isinstance(a, str) and a.strip()] if isinstance(value, list) else []


def me(user_name: str) -> set[str]:
    """Every name of the user, casefolded: the current one and the aliases."""
    return {n.casefold() for n in (user_name, *user_aliases()) if n}


def save(s: Settings) -> None:
    with _locked():
        _write(asdict(s))


def update(changes: dict) -> None:
    """Merge ``changes`` into the file as it is, without filling in
    defaults: a key the user never changed stays out of it and keeps
    following the defaults (config.toml). Read, merged and written under a
    lock: the menu bar app and the window's server (#57) are two processes."""
    with _locked():
        _write({**read_raw(), **changes})


@contextmanager
def _locked():
    import fcntl

    lock = path().with_name(path().name + ".lock")
    lock.parent.mkdir(parents=True, exist_ok=True)
    with open(lock, "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def _write(data: dict) -> None:
    """Atomically: a reader sees the old file or the new one, never half."""
    import os
    import tempfile

    target = path()
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=target.parent, prefix=target.name + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(json.dumps(data, indent=2) + "\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, target)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


class Cached:
    """``load`` again only when the file changed (by its mtime), so a
    caller may ask on every check."""

    def __init__(self, defaults: Settings = Settings()):
        self._defaults = defaults
        self._key: tuple | None = None
        self._value = defaults

    def __call__(self) -> Settings:
        try:
            st = path().stat()
            key = (st.st_mtime_ns, st.st_size)
        except OSError:
            key = None
        if key != self._key or self._key is None:
            self._key, self._value = key, load(self._defaults)
        return self._value
