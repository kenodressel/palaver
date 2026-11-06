"""Where an installed Palaver keeps its three layers (#60).

- the app, ``~/Applications/Palaver.app``: the Swift app, Palaver's own
  code and its Python host, replaced on every release;
- the runtime, ``runtime/<id>/`` in Application Support: a standalone
  Python with every locked dependency, replaced only when the lock changes;
- the models, ``models/<name>/`` in Application Support: downloaded once,
  again only when a model changes.

The folder in Application Support stays lowercase "palaver", the name it
has had since the rename: on a case-sensitive volume "Palaver" would be a
second folder, and the settings, voices and logs are already in this one.
Nothing here touches the disk; the functions take ``home`` so tests (and
the smoke install) can point them anywhere.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

APP_NAME = "Palaver.app"
SUPPORT = Path("Library") / "Application Support" / "palaver"
RUNTIME_FILE = "runtime.json"  # in the app's Resources: the runtime it was built for, and its version


def support_dir(home: Path | None = None) -> Path:
    return (home or Path.home()) / SUPPORT


def runtimes_dir(home: Path | None = None) -> Path:
    return support_dir(home) / "runtime"


def runtime_dir(runtime_id: str, home: Path | None = None) -> Path:
    return runtimes_dir(home) / runtime_id


def models_dir(home: Path | None = None) -> Path:
    return support_dir(home) / "models"


def app_path(home: Path | None = None) -> Path:
    return (home or Path.home()) / "Applications" / APP_NAME


def cli_link(home: Path | None = None) -> Path:
    return (home or Path.home()) / ".local" / "bin" / "palaver"


def launch_agent(home: Path | None = None) -> Path:
    from .app_bundle import BUNDLE_ID

    return (home or Path.home()) / "Library" / "LaunchAgents" / f"{BUNDLE_ID}.plist"


def permissions_marker(home: Path | None = None) -> Path:
    """Set once the menu bar app asked macOS for its permissions; gone, it
    asks again at its next start (after an update: a new signature)."""
    return support_dir(home) / "permissions-requested"


def engine_proven_marker(home: Path | None = None) -> Path:
    """Set once a meeting was transcribed through the speech engine: from then
    on Settings → Storage offers to delete the models it replaced."""
    return support_dir(home) / "engine-transcribed"


def downloads_marker(home: Path | None = None) -> Path:
    """Holds the window server's pid while it downloads models (an update waits)."""
    return support_dir(home) / "downloading-models"


def previous_app_dir(home: Path | None = None) -> Path:
    """The app before an update, until the new one has started once."""
    return support_dir(home) / "previous-app"


def started_ok_path(home: Path | None = None) -> Path:
    """The version of the app that last started all the way (the menu bar
    app writes it); the swap waits for it before dropping the old app."""
    return support_dir(home) / "started-ok"


def update_state_path(home: Path | None = None) -> Path:
    """What the updater knows (update.json): written by the menu bar app,
    read by the window's server."""
    return support_dir(home) / "update.json"


def bundle() -> Path | None:
    """The Palaver.app this process runs from, when it is an installed
    release (the app, its Python host and the command set $PALAVER_APP); None when run
    from a checkout."""
    value = os.environ.get("PALAVER_APP")
    return Path(value) if value else None


def bundle_info(app: Path | None = None) -> dict:
    """{"version", "runtime"} of an installed app (its runtime.json); {}
    when it is not a release build or can't be read."""
    app = app or bundle()
    if app is None:
        return {}
    try:
        data = json.loads((app / "Contents" / "Resources" / RUNTIME_FILE).read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def clean_environment(environ: dict | None = None) -> None:
    """In an installed app, the host set PYTHONHOME and PYTHONPATH for its
    own Python; programs Palaver starts must not get them. Its own helpers
    are the host again (sys.executable), which sets them anew."""
    environ = os.environ if environ is None else environ
    if environ.get("PALAVER_APP"):
        environ.pop("PYTHONHOME", None)
        environ.pop("PYTHONPATH", None)


def stable_python() -> str:
    """The Python other programs (Claude Code, Claude Desktop) should start
    Palaver with. In an installed release that is the app's own wrapper,
    which survives a runtime update; the runtime's python would not."""
    app = bundle()
    if app is not None:
        wrapper = app / "Contents" / "Resources" / "bin" / "python"
        if wrapper.exists():
            return str(wrapper)
    return sys.executable
