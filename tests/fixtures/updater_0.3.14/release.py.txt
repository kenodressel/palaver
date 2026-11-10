"""The release manifest (#60): what a release is made of, and what an
update has to download.

A release has three layers (see install_layout): the app, the runtime and
the hosted models. ``manifest.json`` lists each with its URL, size and
sha256; install.sh and the menu bar app's updater read it, ``make release``
writes it. An update downloads the app, the runtime only when its id
changed, and a model only when one the user has changed version: a model
never downloaded is the setup assistant's to offer, with the user's consent.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

SCHEMA = 1
REPO = "kenodressel/palaver"
RELEASES = f"https://github.com/{REPO}/releases"
LATEST_MANIFEST_URL = f"{RELEASES}/latest/download/manifest.json"
# Bumped when the way a runtime is built changes, so the same lock makes a new runtime.
RUNTIME_RECIPE = 1

_SHA256 = re.compile(r"[0-9a-f]{64}")
_SAFE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
_VERSION = re.compile(r"v?(\d+(?:\.\d+)*)(?:(a|b|rc)(\d+))?")


class ManifestError(ValueError):
    """The manifest can't be used; the message says why."""


@dataclass(frozen=True)
class Asset:
    name: str
    url: str
    size: int
    sha256: str


@dataclass(frozen=True)
class HostedModel:
    """A model Palaver hosts itself (pyannote's are gated on Hugging Face)."""
    name: str
    version: str
    repo: str  # the Hugging Face repo it is a copy of
    asset: Asset
    license: str = ""


@dataclass(frozen=True)
class Manifest:
    version: str
    app: Asset
    runtime_id: str
    runtime: Asset
    models: tuple[HostedModel, ...] = ()
    minimum_macos: str = "15.0"
    arch: str = "arm64"
    notes: str | None = None


@dataclass(frozen=True)
class Installed:
    """What this Mac has: the app's version, its runtime, the hosted models
    (name -> version) and every runtime on it (the one before is kept)."""
    version: str
    runtime_id: str | None
    models: dict[str, str]
    runtimes: frozenset[str] = frozenset()


@dataclass(frozen=True)
class Plan:
    """What an update downloads: always the app, the rest only when changed."""
    version: str
    app: Asset
    runtime_id: str
    runtime: Asset | None
    models: tuple[HostedModel, ...]
    notes: str | None = None

    @property
    def download_bytes(self) -> int:
        return self.app.size + (self.runtime.size if self.runtime else 0) + sum(m.asset.size for m in self.models)


def _asset(data: Any, what: str) -> Asset:
    if not isinstance(data, dict):
        raise ManifestError(f"{what}: missing")
    name, url, size, sha = data.get("name"), data.get("url"), data.get("size"), data.get("sha256")
    if not isinstance(name, str) or not _SAFE_NAME.fullmatch(name):
        raise ManifestError(f"{what}: bad file name {name!r}")
    if not isinstance(url, str) or not url.startswith(("https://", "file://")):
        raise ManifestError(f"{what}: bad url {url!r}")
    if not isinstance(size, int) or isinstance(size, bool) or size < 0:
        raise ManifestError(f"{what}: bad size {size!r}")
    if not isinstance(sha, str) or not _SHA256.fullmatch(sha):
        raise ManifestError(f"{what}: bad sha256")
    return Asset(name, url, size, sha)


def _text(data: dict, key: str, what: str) -> str:
    value = data.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ManifestError(f"{what}: no {key}")
    return value.strip()


def parse_manifest(data: dict | str | bytes) -> Manifest:
    """The manifest, checked: every name safe as a file name, every sha256
    well-formed. Raises ManifestError."""
    if isinstance(data, (str, bytes)):
        try:
            data = json.loads(data)
        except ValueError as exc:
            raise ManifestError(f"not JSON: {exc}") from None
    if not isinstance(data, dict):
        raise ManifestError("not a JSON object")
    if data.get("schema") != SCHEMA:
        raise ManifestError(f"unknown schema {data.get('schema')!r}: a newer installer is needed")
    version = _text(data, "version", "manifest")
    if not _VERSION.fullmatch(version):
        raise ManifestError(f"bad version {version!r}")
    runtime = data.get("runtime") if isinstance(data.get("runtime"), dict) else {}
    runtime_id = runtime.get("id")
    if not isinstance(runtime_id, str) or not _SAFE_NAME.fullmatch(runtime_id):
        raise ManifestError(f"bad runtime id {runtime_id!r}")
    models = []
    for raw in data.get("models") or []:
        if not isinstance(raw, dict):
            raise ManifestError("bad model entry")
        name = raw.get("name")
        if not isinstance(name, str) or not _SAFE_NAME.fullmatch(name):
            raise ManifestError(f"bad model name {name!r}")
        model_version = _text(raw, "version", f"model {name}")
        if not _SAFE_NAME.fullmatch(model_version):
            raise ManifestError(f"model {name}: bad version {model_version!r}")
        models.append(HostedModel(name, model_version, _text(raw, "repo", f"model {name}"),
                                  _asset(raw.get("asset"), f"model {name}"), str(raw.get("license") or "")))
    notes = data.get("notes")
    return Manifest(
        version=version,
        app=_asset(data.get("app"), "app"),
        runtime_id=runtime_id,
        runtime=_asset(runtime, "runtime"),
        models=tuple(models),
        minimum_macos=str(data.get("minimum_macos") or "15.0"),
        arch=str(data.get("arch") or "arm64"),
        notes=notes if isinstance(notes, str) and notes.strip() else None,
    )


def manifest_dict(m: Manifest) -> dict[str, Any]:
    out: dict[str, Any] = {
        "schema": SCHEMA,
        "version": m.version,
        "minimum_macos": m.minimum_macos,
        "arch": m.arch,
        "app": asdict(m.app),
        "runtime": {"id": m.runtime_id, **asdict(m.runtime)},
        "models": [{"name": x.name, "version": x.version, "repo": x.repo, "license": x.license,
                    "asset": asdict(x.asset)}
                   for x in m.models],
    }
    if m.notes:
        out["notes"] = m.notes
    return out


def manifest_json(m: Manifest) -> str:
    return json.dumps(manifest_dict(m), indent=2) + "\n"


def runtime_id(requirements: str, python_version: str, arch: str, build: str = "") -> str:
    """"3.13.2-arm64-1a2b3c4d5e6f": the Python, the arch, and a hash of the
    locked requirements (the dependency lines only: comments and order
    are what another uv version may write differently) and ``build``
    (the python-build-standalone release the Python comes from)."""
    pins = sorted({line.split("#", 1)[0].strip() for line in requirements.splitlines()} - {""})
    digest = hashlib.sha256("\n".join([f"recipe {RUNTIME_RECIPE}", python_version, arch, build, *pins]).encode())
    return f"{python_version}-{arch}-{digest.hexdigest()[:12]}"


def _version_key(version: str) -> tuple:
    m = _VERSION.fullmatch(version.strip())
    if not m:
        return ((0,), 0, 0)
    numbers = tuple(int(x) for x in m.group(1).split("."))
    numbers += (0,) * (4 - len(numbers))
    pre = {"a": 0, "b": 1, "rc": 2}.get(m.group(2) or "", 3)  # a final release after its candidates
    return numbers, pre, int(m.group(3) or 0)


def is_newer(candidate: str, current: str) -> bool:
    return _version_key(candidate) > _version_key(current)


def macos_ok(minimum: str, macos: str) -> bool:
    return _version_key(macos) >= _version_key(minimum)


def plan_update(installed: Installed, manifest: Manifest, *, macos: str | None = None) -> Plan | None:
    """What updating to ``manifest`` downloads; None when it is not newer.
    Raises ManifestError for a release this Mac can't run."""
    if not is_newer(manifest.version, installed.version):
        return None
    if macos is not None and not macos_ok(manifest.minimum_macos, macos):
        raise ManifestError(f"Palaver {manifest.version} needs macOS {manifest.minimum_macos} (this Mac has {macos})")
    models = tuple(m for m in manifest.models
                   if m.name in installed.models and installed.models[m.name] != m.version)
    here = manifest.runtime_id == installed.runtime_id or manifest.runtime_id in installed.runtimes
    runtime = None if here else manifest.runtime
    return Plan(manifest.version, manifest.app, manifest.runtime_id, runtime, models, manifest.notes)


def sha256_file(path: Path, chunk: int = 1 << 20) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        while block := fh.read(chunk):
            digest.update(block)
    return digest.hexdigest()
