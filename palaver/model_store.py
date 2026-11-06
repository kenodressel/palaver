"""Models Palaver hosts itself (#60), kept in Application Support/palaver/models.

Nothing is hosted now (``HOSTED`` is empty): the speech engine's models come
from Hugging Face without a token. The machinery stays for a model that is
gated there: its license may allow passing it on, so a release carries a
copy, and the code looks here first: ``resolve(repo)`` is the local folder when a complete copy of
``repo`` is here, else the repo, downloaded into the Hugging Face cache as
before. The notes models are not gated and come from there.

Each copy is one folder with ``palaver-model.json``: its name, version, the
repo it copies and every file with its size, so a copy missing a file is
never used.
"""

from __future__ import annotations

import json
import os
import shutil
import tarfile
import tempfile
from pathlib import Path

from .install_layout import models_dir

MARKER = "palaver-model.json"
# Hugging Face repo -> the name of the copy a release hosts. Empty since the
# speech engine (its models come from Hugging Face without a token); the
# machinery stays for a model that needs a copy again.
HOSTED: dict[str, str] = {}


class ModelError(RuntimeError):
    pass


def _marker(folder: Path) -> dict | None:
    try:
        data = json.loads((folder / MARKER).read_text())
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _complete(folder: Path, data: dict) -> bool:
    files = data.get("files")
    if not isinstance(files, dict) or not files:
        return False
    for rel, size in files.items():
        try:
            if (folder / rel).stat().st_size != size:
                return False
        except OSError:
            return False
    return True


def write_marker(folder: Path, *, name: str, version: str, repo: str) -> dict:
    """The marker for a model folder as it is now (the release tool's)."""
    files = {p.relative_to(folder).as_posix(): p.stat().st_size
             for p in sorted(folder.rglob("*")) if p.is_file() and p.name != MARKER}
    data = {"name": name, "version": version, "repo": repo, "files": files}
    (folder / MARKER).write_text(json.dumps(data, indent=2) + "\n")
    return data


def installed(home: Path | None = None) -> dict[str, str]:
    """The complete hosted models here: name -> version."""
    out = {}
    try:
        folders = sorted(models_dir(home).iterdir())
    except OSError:
        return out
    for folder in folders:
        data = _marker(folder)
        if data and data.get("name") == folder.name and _complete(folder, data):
            out[folder.name] = str(data.get("version"))
    return out


def local_path(repo: str, home: Path | None = None) -> Path | None:
    """The complete local copy of ``repo``; None when there is none."""
    name = HOSTED.get(repo)
    if name is None:
        return None
    folder = models_dir(home) / name
    data = _marker(folder)
    if not data or data.get("repo") != repo or not _complete(folder, data):
        return None
    return folder


def resolve(repo: str, home: Path | None = None) -> str:
    """What to load ``repo`` from: the local copy, else the repo itself."""
    folder = local_path(repo, home)
    return str(folder) if folder is not None else repo


def partial_bytes(name: str, home: Path | None = None) -> int:
    """How much of a model's download is here (its .part file)."""
    try:
        return (models_dir(home) / f".{name}.tar.part").stat().st_size
    except OSError:
        return 0


def download_path(name: str, home: Path | None = None) -> Path:
    return models_dir(home) / f".{name}.tar.part"


def _safe_members(tar: tarfile.TarFile, name: str):
    for member in tar.getmembers():
        parts = Path(member.name).parts
        if not parts or parts[0] != name or ".." in parts or member.name.startswith("/"):
            raise ModelError(f"unexpected path in the archive: {member.name}")
        if member.issym() or member.islnk() or not (member.isfile() or member.isdir()):
            raise ModelError(f"unexpected entry in the archive: {member.name}")
        yield member


def install_archive(archive: Path, *, name: str, version: str, home: Path | None = None) -> Path:
    """Unpack a model's archive (one folder, ``name``) next to the models and
    swap it in whole: the old copy stays until the new one is checked."""
    root = models_dir(home)
    root.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{name}.", dir=root))
    try:
        try:
            with tarfile.open(archive) as tar:
                tar.extractall(staging, members=list(_safe_members(tar, name)), filter="data")
        except (tarfile.TarError, OSError) as exc:
            raise ModelError(f"the archive of {name} can't be unpacked: {exc}") from None
        new = staging / name
        data = _marker(new)
        if not data or data.get("name") != name or data.get("version") != version or not _complete(new, data):
            raise ModelError(f"the archive is not {name} {version}")
        target = root / name
        old = None
        if target.exists():
            old = root / f".{name}.old.{os.getpid()}"
            target.rename(old)
        new.rename(target)
        if old is not None:
            shutil.rmtree(old, ignore_errors=True)
        return target
    finally:
        shutil.rmtree(staging, ignore_errors=True)
