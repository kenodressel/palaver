"""Build Palaver's release assets on this Mac (#60); `make release` runs it.

    python tools/build_release.py app            --dist dist
    python tools/build_release.py compat-runtime --dist dist
    python tools/build_release.py manifest       --dist dist [--previous manifest.json]

Palaver 0.6 and later hold no Python: no runtime archive of their own, nothing of
the repository's Python code in the app.

- app: Palaver.app, zipped: the Swift app as its executable, the speech engine
  (palaver-engine), the window's server (palaver-server), the worker
  (palaver-worker), the language model's worker (palaver-lm, with MLX's
  shaders), the `palaver` command (palaver-cli, as Contents/Resources/bin/palaver),
  the one-release MCP shim (native/Bundle/bin/python), the window's page files
  (Contents/Resources/web), the domain's resources (zipf.bin) and the
  third-party notices; runtime.json names the placeholder runtime. The build
  refuses a bundle with anything of Python in it or a path of this Mac
  (`check_bundle`).
- compat-runtime: the placeholder runtime (COMPAT_RUNTIME_ID), a few hundred
  bytes: what the updaters of releases before 0.6 need to take the app. The
  release that first names it uploads it; later ones keep its URL (--previous).
- manifest: manifest.json over the assets (its runtime block: the placeholder),
  and upload.txt: the assets this release must upload. An asset the previous
  release already published (same file, same sha256) keeps its URL there and is
  not uploaded again.
- models: nothing; Palaver hosts no models (the engine downloads its own).

`--compat-runtime` (app, manifest) is accepted and changes nothing: it is the
only mode since 0.6.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from tools import app_bundle, release  # noqa: E402

ARCH = "arm64"


def run(*argv, **kw):
    print("+", " ".join(str(a) for a in argv), flush=True)
    return subprocess.run([str(a) for a in argv], check=True, **kw)


def check_no_apple_double(archive: Path) -> None:
    """An archive Palaver's updaters unpack must hold no AppleDouble "._*" entries."""
    with tarfile.open(archive) as tar:
        bad = [m.name for m in tar.getmembers() if Path(m.name).name.startswith("._")]
    if bad:
        raise SystemExit(f"✗ {archive.name} holds AppleDouble files: " + ", ".join(bad[:5]))


# --- the compat runtime (0.6 and later run without Python) ----------------------------------------

# Every release before 0.6 (0.1.0 to 0.5.0rcN) updates through its own Python updater, frozen in it:
# it refuses a manifest without a runtime block, downloads the runtime when its id is not on the Mac,
# unpacks it only when every member sits in `<id>/` and `<id>/bin/python3` exists (it never runs it),
# and takes the new app only when its runtime.json names that id
# (tests/fixtures/updater_0.3.14, tests/test_release_compat.py). This archive is all they need: the
# Swift app never uses it, and deletes the runtime folder after its first good start.
COMPAT_RUNTIME_ID = "no-python-1"
COMPAT_PYTHON3 = """#!/bin/sh
echo "Palaver 0.6 and later run without Python. This placeholder only let an older Palaver update; Palaver deletes it." >&2
exit 1
"""


def compat_runtime_archive(dist: Path) -> Path:
    return dist / f"palaver-runtime-{COMPAT_RUNTIME_ID}.tar.gz"


def app_runtime_id(archive: Path) -> str | None:
    """The runtime the zipped app's runtime.json names (what the updaters before 0.6 compare with the manifest)."""
    try:
        with zipfile.ZipFile(archive) as z:
            return json.loads(z.read("Palaver.app/Contents/Resources/runtime.json")).get("runtime")
    except (OSError, KeyError, ValueError, zipfile.BadZipFile):
        return None


def build_compat_runtime(dist: Path) -> Path:
    """The same bytes on every build (fixed times and owners, no AppleDouble files): a release
    that publishes it once keeps its URL in every later manifest (``--previous``)."""
    import gzip
    import io

    archive = compat_runtime_archive(dist)
    tmp = archive.with_name(archive.name + ".tmp")
    with open(tmp, "wb") as raw, gzip.GzipFile(fileobj=raw, mode="wb", mtime=0, filename="") as gz, \
            tarfile.open(fileobj=gz, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        def add(name: str, mode: int, data: bytes | None = None) -> None:
            info = tarfile.TarInfo(name)
            info.mode, info.mtime, info.uid, info.gid, info.uname, info.gname = mode, 0, 0, 0, "", ""
            if data is None:
                info.type = tarfile.DIRTYPE
                tar.addfile(info)
            else:
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))

        add(COMPAT_RUNTIME_ID, 0o755)
        add(f"{COMPAT_RUNTIME_ID}/bin", 0o755)
        add(f"{COMPAT_RUNTIME_ID}/bin/python3", 0o755, COMPAT_PYTHON3.encode())
    check_no_apple_double(tmp)
    tmp.replace(archive)
    print(f"✓ {archive.name}: {archive.stat().st_size} bytes (runtime {COMPAT_RUNTIME_ID}, for updates from before 0.6)")
    return archive


# --- models --------------------------------------------------------------------------------------

def build_models(dist: Path) -> None:
    """Nothing: Palaver hosts no models any more. The speech models come from
    Hugging Face through palaver-engine (no account, no token). The step stays
    so scripts that call it keep working; it writes nothing."""
    print("(no hosted models: the speech engine downloads its own)")


# --- app -----------------------------------------------------------------------------------------

RELEASE_DIR = ROOT / "native" / ".build" / "release"
ENGINE_BIN = RELEASE_DIR / "palaver-engine"
APP_BIN = RELEASE_DIR / "Palaver"  # the Swift app (phase 2): the bundle's executable
SERVER_BIN = RELEASE_DIR / "palaver-server"  # the window's server (phase 3)
WORKER_BIN = RELEASE_DIR / "palaver-worker"  # the pipeline's worker (phase 3)
CLI_BIN = RELEASE_DIR / "palaver-cli"  # the `palaver` command (phase 4): Contents/Resources/bin/palaver
# The language model's worker (phase 4): built by xcodebuild (make lm), which compiles MLX's Metal shaders.
LM_PRODUCTS = ROOT / "native" / ".build" / "xcode" / "Build" / "Products" / "Release"
LM_BIN = LM_PRODUCTS / "palaver-lm"
# What palaver-lm reads besides itself: the shaders (Contents/Resources/mlx.metallib) and swift-transformers' resources.
LM_RESOURCES = (LM_PRODUCTS / "mlx-swift_Cmlx.bundle" / "Contents" / "Resources" / "default.metallib",
                LM_PRODUCTS / "swift-transformers_Hub.bundle")
MCP_SHIM = ROOT / "native" / "Bundle" / "bin" / "python"  # Contents/Resources/bin/python, for 0.6 only
WEB = ROOT / "web"  # the window's page files: Contents/Resources/web
DOMAIN_RESOURCES = ROOT / "native" / "Sources" / "PalaverDomain" / "Resources"  # zipf.bin
LICENSES = ROOT / "THIRD_PARTY_LICENSES.md"


def _is_macho(path: Path) -> bool:
    try:
        with open(path, "rb") as f:
            return f.read(4) in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf", b"\xbe\xba\xfe\xca")
    except OSError:
        return False


def bundle_problems(app: Path, home: str | None = None, checkout: Path = ROOT) -> list[str]:
    """What must not be in a release bundle: anything of Python (palaver-python, Contents/Resources/python, a
    ``.py``/``.pyc`` file, an interpreter: any file named like python but the MCP shim, which must be a shell
    script), a runtime.json that does not name the placeholder runtime, or a path of the building Mac (its home
    folder, the checkout) in any file. Empty when the bundle is fine."""
    home_given = home
    home = home if home is not None else os.path.expanduser("~")
    shim = app / "Contents" / "Resources" / "bin" / "python"
    problems = []
    needles = [n.encode() for n in {home.rstrip("/") + "/", str(checkout).rstrip("/") + "/"} if len(n) > 2]
    # On GitHub Actions this build's own paths are the runner's (/Users/runner/…), which name nobody; a prebuilt
    # dependency carries such paths of its own build too (the Makefile's no-build-paths skips them there as well).
    # Paths a caller names (the tests) are always checked.
    if os.environ.get("GITHUB_ACTIONS") == "true" and home_given is None and checkout == ROOT:
        needles = []
    for path in sorted(app.rglob("*")):
        rel = path.relative_to(app.parent)
        name = path.name.lower()
        if path.suffix in (".py", ".pyc") or (path.is_dir() and name == "__pycache__"):
            problems.append(f"{rel}: Python code")
        elif "python" in name and path != shim:
            problems.append(f"{rel}: named like Python")
        if path.is_file() and not path.is_symlink():
            data = path.read_bytes()
            for needle in needles:
                if needle in data:
                    problems.append(f"{rel}: names {needle.decode()} (a path of this Mac)")
    if shim.exists():
        text = shim.read_bytes()
        if not text.startswith(b"#!/bin/sh\n") or _is_macho(shim) or len(text) > 4096:
            problems.append(f"{shim.relative_to(app.parent)}: not the shell shim (native/Bundle/bin/python)")
    try:
        runtime = json.loads((app / "Contents" / "Resources" / "runtime.json").read_text()).get("runtime")
    except (OSError, ValueError):
        runtime = None
    if runtime != COMPAT_RUNTIME_ID:
        problems.append(f"runtime.json names {runtime!r}, not {COMPAT_RUNTIME_ID} (no release before 0.6 could update)")
    return problems


def check_bundle(app: Path) -> None:
    problems = bundle_problems(app)
    if problems:
        raise SystemExit("✗ the bundle is no release without Python:\n  " + "\n  ".join(problems[:20]))
    print("✓ no Python in the bundle (only the MCP shim bin/python), no path of this Mac, runtime.json: "
          + COMPAT_RUNTIME_ID)


def build_app(dist: Path, version: str | None = None, engine: Path | None = None,
              app_binary: Path | None = None, server: Path | None = None, worker: Path | None = None,
              lm: Path | None = None, lm_resources: tuple[Path, ...] | None = None, cli: Path | None = None) -> Path:
    """``version``: another version than VERSION's (the smoke test's update). ``engine``,
    ``app_binary``, ``server``, ``worker``, ``cli``: the built palaver-engine, Swift app,
    palaver-server, palaver-worker and palaver-cli (default: all from native/.build/release);
    ``lm``, ``lm_resources``: palaver-lm and its shaders and resources (default: xcodebuild's
    products, LM_PRODUCTS)."""
    def built(given: Path | None, default: Path, target: str) -> Path:
        path = given or default
        if not path.is_file():
            raise SystemExit(f"✗ {path} is missing: run `make {target}` first (make app does)")
        return path

    engine = built(engine, ENGINE_BIN, "engine")
    app_binary = built(app_binary, APP_BIN, "app-swift")
    server = built(server, SERVER_BIN, "server")
    worker = built(worker, WORKER_BIN, "worker")
    lm = built(lm, LM_BIN, "lm")
    cli = built(cli, CLI_BIN, "cli")
    lm_resources = LM_RESOURCES if lm_resources is None else lm_resources
    for needed in lm_resources:
        if not needed.exists():
            raise SystemExit(f"✗ {needed} is missing: run `make lm` first (make app does)")
    version = version or app_bundle.checkout_version()
    out = dist / "app"
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    app = app_bundle.build_release_app(out, app_binary=app_binary, engine=engine, server=server, worker=worker, lm=lm,
                                       cli=cli, mcp_shim=MCP_SHIM, web=WEB, lm_resources=list(lm_resources),
                                       domain_resources=DOMAIN_RESOURCES, licenses=LICENSES, version=version,
                                       runtime_json_id=COMPAT_RUNTIME_ID)
    check_bundle(app)
    archive = dist / f"palaver-app-{version}.zip"
    archive.unlink(missing_ok=True)
    run("ditto", "-ck", "--keepParent", app, archive)
    print(f"✓ {archive.name}: {archive.stat().st_size / 1e6:.1f} MB (runtime.json: {COMPAT_RUNTIME_ID})")
    return archive


# --- manifest ------------------------------------------------------------------------------------

def _asset(path: Path, tag: str, previous: dict[str, release.Asset]) -> tuple[release.Asset, bool]:
    """The asset, and whether this release has to upload it."""
    sha, size = release.sha256_file(path), path.stat().st_size
    old = previous.get(path.name)
    if old is not None and old.sha256 == sha and old.size == size:
        return old, False
    return release.Asset(path.name, f"{release.RELEASES}/download/{tag}/{path.name}", size, sha), True


def _previous(path: str | None) -> dict[str, release.Asset]:
    if not path:
        return {}
    try:
        m = release.parse_manifest(Path(path).read_text())
    except (OSError, ValueError) as exc:
        print(f"(previous manifest not used: {exc})")
        return {}
    return {a.name: a for a in (m.app, m.runtime, *(x.asset for x in m.models))}


def build_manifest(dist: Path, previous: str | None, notes: str | None,
                   version: str | None = None, base_url: str | None = None) -> Path:
    """``base_url``: where the assets are instead of this release on GitHub
    (a file:// folder, to test an update from inside the app). The runtime block names the
    placeholder (`compat-runtime`): the updaters of releases before 0.6 need one."""
    version = version or app_bundle.checkout_version()
    rid = COMPAT_RUNTIME_ID
    tag = f"v{version}"
    old = _previous(previous)
    runtime = next(iter(sorted(dist.glob(f"palaver-runtime-{rid}.tar.*"))), None)
    if runtime is None:
        raise SystemExit(f"no placeholder runtime for {rid} in {dist}: run `build_release.py compat-runtime` first")
    uploads = []

    def asset(path: Path) -> release.Asset:
        a, upload = _asset(path, tag, old)
        if base_url:
            a = release.Asset(a.name, f"{base_url.rstrip('/')}/{a.name}", a.size, a.sha256)
        if upload:
            uploads.append(path.name)
        return a

    app_zip = dist / f"palaver-app-{version}.zip"
    if app_runtime_id(app_zip) != rid:  # the updaters before 0.6 would refuse the app
        raise SystemExit(f"✗ {app_zip.name}'s runtime.json names {app_runtime_id(app_zip)}, the manifest {rid}")
    manifest = release.Manifest(
        version=version, app=asset(app_zip), runtime_id=rid,
        runtime=asset(runtime), models=(), minimum_macos="15.0", arch=ARCH,
        notes=Path(notes).read_text().strip() if notes and Path(notes).exists() else None)
    out = dist / "manifest.json"
    out.write_text(release.manifest_json(manifest))
    (dist / "upload.txt").write_text("\n".join([*uploads, "manifest.json", "install.sh"]) + "\n")
    print(f"✓ manifest.json for {tag}; to upload: {', '.join(uploads) or 'nothing new'} + manifest.json, install.sh")
    return out


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="build_release")
    parser.add_argument("what", choices=["app", "manifest", "compat-runtime", "models"])
    parser.add_argument("--dist", default="dist")
    parser.add_argument("--previous", help="the previous release's manifest.json")
    parser.add_argument("--notes", help="a file with this release's notes")
    parser.add_argument("--version", help="build as this version (testing an update)")
    parser.add_argument("--base-url", help="the assets' location instead of the GitHub release")
    parser.add_argument("--compat-runtime", action="store_true",
                        help="accepted for scripts of 0.5: the placeholder runtime is the only one since 0.6")
    args = parser.parse_args(argv)
    if platform.machine() != ARCH or sys.platform != "darwin":
        raise SystemExit("release assets are built on an Apple Silicon Mac")
    dist = Path(args.dist).resolve()
    dist.mkdir(parents=True, exist_ok=True)
    if args.what == "app":
        build_app(dist, args.version)
    elif args.what == "compat-runtime":
        build_compat_runtime(dist)
    elif args.what == "models":
        build_models(dist)
    else:
        build_manifest(dist, args.previous, args.notes, args.version, args.base_url)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
