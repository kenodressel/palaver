"""Uninstall Palaver… (#60): what goes, decided here, and a small script that
removes it once Palaver has quit (the app can't delete itself while it runs).

Always: the app, its runtime, the login item, the `palaver` command (only
when the link is Palaver's) and a pending update. On request: the models.
Recordings stay unless the user ticks to delete them too; then only what
Palaver made goes (a recordings folder may hold the user's own files):
the meeting folders, those in its trash, its jobs, and Palaver's data:
voices, glossary, settings, logs. The models stay unless ticked.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

from . import install_layout
from ._xdg import xdg_config_home
from .paths import is_recording_folder_name


def _palavers_link(link: Path, home: Path) -> bool:
    try:
        target = str(link.readlink())
    except OSError:
        return False
    return target.startswith((str(install_layout.app_path(home)), str(install_layout.support_dir(home))))


def plan(home: Path, *, output_dir: Path, models: bool = False, recordings: bool = False,
         config_home: Path | None = None) -> list[Path]:
    """The paths to remove (only those that exist)."""
    support = install_layout.support_dir(home)
    out = [install_layout.app_path(home), install_layout.runtimes_dir(home), install_layout.launch_agent(home),
           support / "updates", install_layout.update_state_path(home)]
    link = install_layout.cli_link(home)
    if link.is_symlink() and _palavers_link(link, home):
        out.append(link)
    if models:
        out.append(install_layout.models_dir(home))
    if recordings:
        if models:
            out.append(support)
        elif support.is_dir():
            out += [p for p in sorted(support.iterdir()) if p.name != "models"]
        out += [(config_home or xdg_config_home()) / "palaver", home / "Library" / "Logs" / "palaver"]
        output_dir = _recordings_dir(home, output_dir)
        if output_dir is not None:
            out += _meetings_in(output_dir) + _meetings_in(output_dir / TRASH) + [output_dir / JOBS]
    seen, result = set(), []
    for p in out:
        if p not in seen and (p.exists() or p.is_symlink()):
            seen.add(p)
            result.append(p)
    return result


TRASH, JOBS = ".trash", ".jobs"


def _recordings_dir(home: Path, output_dir: Path) -> Path | None:
    """The recordings folder; None when it is the home folder or holds it
    (a recordings folder set to ~ or /): nothing is taken from there."""
    output_dir = output_dir.expanduser()
    if output_dir.resolve() in (home.resolve(), *home.resolve().parents) or not output_dir.is_dir():
        return None
    return output_dir


def _meetings_in(folder: Path) -> list[Path]:
    try:
        return [p for p in sorted(folder.iterdir()) if p.is_dir() and is_recording_folder_name(p.name)]
    except OSError:
        return []


def emptied(home: Path, *, output_dir: Path) -> list[Path]:
    """Folders to remove after the plan when nothing else is left in them."""
    out = [install_layout.support_dir(home)]
    rec = _recordings_dir(home, output_dir)
    if rec is not None:
        out += [rec / TRASH, rec]
    return out


def _sh(value) -> str:
    return "'" + str(value).replace("'", "'\\''") + "'"


def script(paths: list[Path], *, wait_for: list[int], then_if_empty: list[Path] = ()) -> str:
    lines = ["#!/bin/sh", "# Palaver's uninstall: once Palaver has quit, remove what the user chose."]
    for pid in wait_for:
        lines.append(f"while kill -0 {int(pid)} 2>/dev/null; do sleep 0.2; done")
    lines += [f"rm -rf {_sh(p)}" for p in paths]
    lines += [f"rmdir {_sh(p)} 2>/dev/null || :" for p in then_if_empty]  # only when empty
    return "\n".join(lines) + "\n"


def start(paths: list[Path], *, wait_for: list[int], work: Path, then_if_empty: list[Path] = ()) -> Path:
    """Write the script outside what it removes and run it on its own, so
    it outlives the app."""
    work.mkdir(parents=True, exist_ok=True)
    path = work / "palaver-uninstall.sh"
    path.write_text(script(paths, wait_for=wait_for, then_if_empty=then_if_empty) + f"rm -f {_sh(path)}\n")
    subprocess.Popen(["/bin/sh", str(path)], start_new_session=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return path
