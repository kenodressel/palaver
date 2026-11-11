"""The release manifest (#60): what a release is made of. tools/build_release.py
writes it (``make release``); install.sh and the app's updater read it.

``manifest.json`` lists the app, the runtime and the hosted models, each with its
URL, size and sha256. Since 0.6 the runtime is the placeholder ``no-python-1`` the
updaters of the releases before need (tools/build_release.py), and no models are
hosted; the schema stays, as every release before reads it.
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


def sha256_file(path: Path, chunk: int = 1 << 20) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        while block := fh.read(chunk):
            digest.update(block)
    return digest.hexdigest()
