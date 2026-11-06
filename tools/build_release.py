"""Build Palaver's release assets on this Mac (#60); `make release` runs it.

    python tools/build_release.py runtime  --dist dist --python 3.13.18 --pbs-release 20261026
    python tools/build_release.py models   --dist dist
    python tools/build_release.py app      --dist dist
    python tools/build_release.py manifest --dist dist [--previous manifest.json]

- runtime: python-build-standalone (downloaded into the build folder, its
  sha256 checked against the release's SHA256SUMS) plus every locked
  dependency, made relocatable
  and checked: no Mach-O file may load anything from /Users, Homebrew or
  /usr/local. Built once per runtime id; an existing archive is kept.
- models: nothing; Palaver hosts no models (the engine downloads its own).
- app: Palaver.app, zipped: the Swift app as its executable, the wheel's code
  with its Python host (palaver-python), and the Swift engine.
- manifest: manifest.json over the assets, and upload.txt: the assets this
  release must upload. An asset the previous release already published
  (same file, same sha256) keeps its URL there and is not uploaded again.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from palaver import release  # noqa: E402

ARCH = "arm64"
FORBIDDEN_PREFIXES = ("/Users/", "/opt/homebrew", "/usr/local", "/private/", "/tmp/", "/install/")


def run(*argv, **kw):
    print("+", " ".join(str(a) for a in argv), flush=True)
    return subprocess.run([str(a) for a in argv], check=True, **kw)


def requirements(dist: Path) -> str:
    out = dist / "requirements.txt"
    run("uv", "export", "--frozen", "--no-dev", "--no-emit-project", "--no-hashes",
        "--format", "requirements-txt", "-o", out, cwd=ROOT, stdout=subprocess.DEVNULL)
    return out.read_text()


PBS = "https://github.com/astral-sh/python-build-standalone/releases/download"
PBS_RELEASE = "20261026"  # set by --pbs-release (the Makefile's PBS_RELEASE)


def runtime_id(dist: Path, python: str) -> str:
    return release.runtime_id(requirements(dist), python, ARCH, build=f"python-build-standalone {PBS_RELEASE}")


# --- runtime -------------------------------------------------------------------------------------

def _fetch(url: str, dest: Path) -> Path:
    import urllib.request

    print(f"+ download {url}", flush=True)
    with urllib.request.urlopen(url, timeout=60) as response, open(dest, "wb") as out:
        shutil.copyfileobj(response, out)
    return dest


def _install_python(build: Path, python: str) -> Path:
    """python-build-standalone ``python`` of release PBS_RELEASE, into the
    build folder only, its sha256 checked against the release's SHA256SUMS."""
    from urllib.parse import quote

    name = f"cpython-{python}+{PBS_RELEASE}-aarch64-apple-darwin-install_only.tar.gz"
    folder = build / "pbs" / PBS_RELEASE
    folder.mkdir(parents=True, exist_ok=True)
    archive = folder / name
    sums = folder / "SHA256SUMS"
    if not sums.exists():
        _fetch(f"{PBS}/{PBS_RELEASE}/SHA256SUMS", sums)
    expected = next((line.split()[0] for line in sums.read_text().splitlines()
                     if line.split()[1:] == [name]), None)
    if expected is None:
        raise SystemExit(f"python-build-standalone {PBS_RELEASE} has no {name}")
    if not archive.exists() or release.sha256_file(archive) != expected:
        _fetch(f"{PBS}/{PBS_RELEASE}/{quote(name)}", archive)
    if release.sha256_file(archive) != expected:
        archive.unlink()
        raise SystemExit(f"✗ {name}: sha256 does not match SHA256SUMS")
    print(f"✓ {name}: sha256 matches", flush=True)
    out = folder / python
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir()
    with tarfile.open(archive) as tar:
        tar.extractall(out, filter="tar")
    return out / "python"


def _macho_files(root: Path):
    for path in root.rglob("*"):
        if path.is_file() and not path.is_symlink():
            with open(path, "rb") as fh:
                head = fh.read(4)
            if head in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf"):
                yield path


def _load_commands(path: Path) -> tuple[str | None, list[str], list[str]]:
    """(its own install name, the libraries it loads, its rpaths)."""
    out = subprocess.run(["otool", "-l", str(path)], capture_output=True, text=True).stdout
    own, libs, rpaths = None, [], []
    for m in re.finditer(r"cmd (LC_ID_DYLIB|LC_LOAD_DYLIB|LC_LOAD_WEAK_DYLIB|LC_REEXPORT_DYLIB|LC_RPATH)\n"
                         r"\s+cmdsize \d+\n\s+(?:name|path) (.+?) \(offset", out):
        kind, value = m.group(1), m.group(2)
        if kind == "LC_ID_DYLIB":
            own = value
        elif kind == "LC_RPATH":
            rpaths.append(value)
        else:
            libs.append(value)
    return own, sorted(set(libs)), sorted(set(rpaths))


def _scrub_links(root: Path) -> list[str]:
    """Make every Mach-O file independent of where it was built: an install
    name naming the build folder becomes @rpath/<name>, rpaths into
    Homebrew or /usr/local are dropped, so the runtime behaves the same on every Mac. Changed files
    are signed again (ad hoc, as arm64 requires). Returns what still
    points outside: libraries loaded from there."""
    bad = []
    for path in _macho_files(root):
        own, libs, rpaths = _load_commands(path)
        changes = []
        if own and own.startswith(FORBIDDEN_PREFIXES):
            changes += ["-id", f"@rpath/{Path(own).name}"]
        for rpath in rpaths:
            if rpath.startswith(FORBIDDEN_PREFIXES):
                changes += ["-delete_rpath", rpath]
        if changes:
            subprocess.run(["install_name_tool", *changes, str(path)], check=True, capture_output=True)
            subprocess.run(["codesign", "--force", "--sign", "-", str(path)], check=True, capture_output=True)
        bad += [f"{path.relative_to(root)} -> {lib}" for lib in libs if lib.startswith(FORBIDDEN_PREFIXES)]
    return bad


def _check_links(root: Path) -> list[str]:
    """Mach-O files that name anything outside the system by an absolute path."""
    bad = []
    for path in _macho_files(root):
        own, libs, rpaths = _load_commands(path)
        for value in ([own] if own else []) + libs + rpaths:
            if value.startswith(FORBIDDEN_PREFIXES):
                bad.append(f"{path.relative_to(root)}: {value}")
    return bad


_RELOCATABLE_SHEBANG = "#!/bin/sh\n'''exec' \"$(dirname -- \"$(realpath -- \"$0\")\")/python3\" \"$0\" \"$@\"\n' '''\n"


def _relocate_scripts(runtime: Path, build: Path) -> int:
    """Entry-point scripts start the build folder's python, by a #! line or
    uv's three-line sh header: they start the python next to them instead
    (the trick uv's relocatable venvs use)."""
    fixed = 0
    for script in (runtime / "bin").iterdir():
        if script.is_symlink() or not script.is_file():
            continue
        try:
            text = script.read_text()
        except UnicodeDecodeError:
            continue
        lines = text.split("\n")
        if lines[0].startswith("#!") and str(build) in lines[0]:
            body = lines[1:]
        elif lines[0] == "#!/bin/sh" and len(lines) > 2 and lines[1].startswith("'''exec'") \
                and str(build) in lines[1]:
            body = lines[3:]
        else:
            continue
        script.write_text(_RELOCATABLE_SHEBANG + "\n".join(body))
        fixed += 1
    return fixed


def _text_mentions(root: Path, needle: str) -> list[str]:
    """Small text files that still name the build folder (RECORD files and
    the like are harmless, but a script would not run elsewhere)."""
    hits = []
    for path in root.rglob("*"):
        if path.is_file() and not path.is_symlink() and path.suffix not in (".pyc", ".so", ".dylib") \
                and path.stat().st_size < 2_000_000:
            try:
                if needle in path.read_text(errors="strict"):
                    hits.append(str(path.relative_to(root)))
            except (UnicodeDecodeError, OSError):
                continue
    return hits


def check_no_apple_double(archive: Path) -> None:
    """An archive Palaver's updaters unpack must hold no AppleDouble "._*" entries."""
    with tarfile.open(archive) as tar:
        bad = [m.name for m in tar.getmembers() if Path(m.name).name.startswith("._")]
    if bad:
        raise SystemExit(f"✗ {archive.name} holds AppleDouble files: " + ", ".join(bad[:5]))


def build_runtime(dist: Path, python: str, compression: str) -> Path:
    rid = runtime_id(dist, python)
    archive = dist / f"palaver-runtime-{rid}.tar.{compression}"
    if archive.exists():
        print(f"✓ {archive.name} exists (runtime {rid}): kept")
        return archive
    build = dist / "build"
    stage = build / "runtime"
    shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir(parents=True)
    runtime = stage / rid
    shutil.copytree(_install_python(build, python), runtime, symlinks=True)
    marker = runtime / "lib" / f"python{'.'.join(python.split('.')[:2])}" / "EXTERNALLY-MANAGED"
    marker.unlink(missing_ok=True)
    run("uv", "pip", "install", "--python", runtime / "bin" / "python3", "--no-config", "--compile-bytecode",
        "--link-mode", "copy", "-r", dist / "requirements.txt")
    marker.write_text("[externally-managed]\nError=This Python is Palaver's runtime; Palaver's installer manages it.\n")
    fixed = _relocate_scripts(runtime, build)
    print(f"✓ {fixed} entry-point scripts made relocatable")
    loads = _scrub_links(runtime)
    if loads:
        raise SystemExit("✗ runtime loads libraries from outside itself:\n  " + "\n  ".join(loads[:20]))
    bad = _check_links(runtime)
    if bad:
        raise SystemExit("✗ runtime names paths outside itself:\n  " + "\n  ".join(bad[:20]))
    print("✓ otool: no Mach-O file names anything in /Users, Homebrew or /usr/local")
    scripts = [h for h in _text_mentions(runtime / "bin", str(build)) if not h.endswith(".pyc")]
    if scripts:
        raise SystemExit("✗ scripts still name the build folder: " + ", ".join(scripts))
    run(runtime / "bin" / "python3", "-I", "-c", "import mlx.core, rumps, mlx_lm")
    tmp = archive.with_name(archive.name + ".tmp")
    flag = {"gz": "-czf", "xz": "-cJf"}[compression]
    # COPYFILE_DISABLE: macOS tar otherwise adds AppleDouble "._*" files, and an updater
    # before 0.5 refuses a runtime archive with "._<id>" at its top.
    env = {**os.environ, "XZ_OPT": "-T0 -6", "COPYFILE_DISABLE": "1"}
    run("tar", "--no-xattrs", "--no-mac-metadata", "-C", stage, flag, tmp, rid, env=env)
    check_no_apple_double(tmp)
    tmp.rename(archive)
    shutil.rmtree(stage)
    print(f"✓ {archive.name}: {archive.stat().st_size / 1e6:.0f} MB")
    return archive


# --- models --------------------------------------------------------------------------------------

def build_models(dist: Path) -> None:
    """Nothing: Palaver hosts no models any more. The speech models come from
    Hugging Face through palaver-engine (no account, no token). The step stays
    so scripts that call it keep working; it writes nothing."""
    print("(no hosted models: the speech engine downloads its own)")


# --- app -----------------------------------------------------------------------------------------

ENGINE_BIN = ROOT / "native" / ".build" / "release" / "palaver-engine"
APP_BIN = ROOT / "native" / ".build" / "release" / "Palaver"  # the Swift app (phase 2): the bundle's executable


def build_app(dist: Path, python: str, version: str | None = None, engine: Path | None = None,
              app_binary: Path | None = None) -> Path:
    """``version``: another version than the code's (the smoke test's update).
    ``engine``: the built palaver-engine, ``app_binary`` the built Swift app
    (default: both from native/.build/release)."""
    from palaver import __version__, app_bundle

    engine = engine or ENGINE_BIN
    if not engine.is_file():
        raise SystemExit(f"✗ {engine} is missing: run `make engine` first (make app does)")
    app_binary = app_binary or APP_BIN
    if not app_binary.is_file():
        raise SystemExit(f"✗ {app_binary} is missing: run `make app-swift` first (make app does)")

    rid = runtime_id(dist, python)
    wheels = sorted(dist.glob(f"palaver-{__version__}-*.whl"))
    if not wheels:
        raise SystemExit(f"no wheel of palaver {__version__} in {dist}: run `make wheel` first")
    with zipfile.ZipFile(wheels[-1]) as wheel:
        if "palaver/_vendored/webrtc_aec/libraven_aec.dylib" not in wheel.namelist():
            raise SystemExit(f"✗ {wheels[-1].name} lacks the AEC library")
        code = Path(tempfile.mkdtemp(dir=dist))
        wheel.extractall(code)
    if version and version != __version__:
        init = code / "palaver" / "__init__.py"
        init.write_text(init.read_text().replace(f'__version__ = "{__version__}"', f'__version__ = "{version}"'))
    __version__ = version or __version__
    out = dist / "app"
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir()
    try:
        # Bytecode for the runtime's Python (same minor version as the build's).
        same = f"{sys.version_info.major}.{sys.version_info.minor}" == python.rsplit(".", 1)[0]
        app = app_bundle.build_release_app(out, runtime_id=rid, code=code, app_binary=app_binary, version=__version__,
                                           compile_with=sys.executable if same else None, engine=engine)
    finally:
        shutil.rmtree(code, ignore_errors=True)
    archive = dist / f"palaver-app-{__version__}.zip"
    archive.unlink(missing_ok=True)
    run("ditto", "-ck", "--keepParent", app, archive)
    print(f"✓ {archive.name}: {archive.stat().st_size / 1e6:.1f} MB (runtime {rid})")
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


def build_manifest(dist: Path, python: str, previous: str | None, notes: str | None,
                   version: str | None = None, base_url: str | None = None) -> Path:
    """``base_url``: where the assets are instead of this release on GitHub
    (a file:// folder, to test an update from inside the app)."""
    from palaver import __version__

    __version__ = version or __version__
    rid = runtime_id(dist, python)
    tag = f"v{__version__}"
    old = _previous(previous)
    runtime = next(iter(sorted(dist.glob(f"palaver-runtime-{rid}.tar.*"))), None)
    if runtime is None:
        raise SystemExit(f"no runtime archive for {rid} in {dist}")
    uploads = []

    def asset(path: Path) -> release.Asset:
        a, upload = _asset(path, tag, old)
        if base_url:
            a = release.Asset(a.name, f"{base_url.rstrip('/')}/{a.name}", a.size, a.sha256)
        if upload:
            uploads.append(path.name)
        return a

    manifest = release.Manifest(
        version=__version__, app=asset(dist / f"palaver-app-{__version__}.zip"), runtime_id=rid,
        runtime=asset(runtime), models=(), minimum_macos="15.0", arch=ARCH,
        notes=Path(notes).read_text().strip() if notes and Path(notes).exists() else None)
    out = dist / "manifest.json"
    out.write_text(release.manifest_json(manifest))
    (dist / "upload.txt").write_text("\n".join([*uploads, "manifest.json", "install.sh"]) + "\n")
    print(f"✓ manifest.json for {tag}; to upload: {', '.join(uploads) or 'nothing new'} + manifest.json, install.sh")
    return out


def main(argv: list[str]) -> int:
    global PBS_RELEASE
    parser = argparse.ArgumentParser(prog="build_release")
    parser.add_argument("what", choices=["runtime-id", "runtime", "models", "app", "manifest"])
    parser.add_argument("--dist", default="dist")
    parser.add_argument("--python", default="3.13.18")
    parser.add_argument("--pbs-release", default=PBS_RELEASE, help="the python-build-standalone release")
    parser.add_argument("--compression", choices=["gz", "xz"], default="gz")
    parser.add_argument("--previous", help="the previous release's manifest.json")
    parser.add_argument("--notes", help="a file with this release's notes")
    parser.add_argument("--version", help="build as this version (testing an update)")
    parser.add_argument("--base-url", help="the assets' location instead of the GitHub release")
    args = parser.parse_args(argv)
    if platform.machine() != ARCH or sys.platform != "darwin":
        raise SystemExit("release assets are built on an Apple Silicon Mac")
    PBS_RELEASE = args.pbs_release
    dist = Path(args.dist).resolve()
    dist.mkdir(parents=True, exist_ok=True)
    if args.what == "runtime-id":
        print(runtime_id(dist, args.python))
    elif args.what == "runtime":
        build_runtime(dist, args.python, args.compression)
    elif args.what == "models":
        build_models(dist)
    elif args.what == "app":
        build_app(dist, args.python, args.version)
    else:
        build_manifest(dist, args.python, args.previous, args.notes, args.version, args.base_url)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
