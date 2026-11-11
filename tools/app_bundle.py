"""Build the release ``Palaver.app`` (#60): the native app, no Python (0.6 and later).

Its executable ``Palaver`` is the Swift app, which records and runs the daemon; the
window's server ``palaver-server``, the pipeline's worker ``palaver-worker``, the
language model's worker ``palaver-lm`` and the speech engine ``palaver-engine`` sit
beside it in Contents/MacOS; the ``palaver`` command (built as ``palaver-cli``) is
Contents/Resources/bin/palaver, the window's page files Contents/Resources/web. Every
program is signed with one identity, as 0.5's were (no hardened runtime yet:
``HARDENED_RUNTIME``). macOS asks for the microphone and system audio under
"Palaver" with the usage texts below. The app was called "Meeting Transcribe"
before; the bundle id stays, so macOS keeps what was allowed.

tools/build_release.py builds it (``make app``).
"""

from __future__ import annotations

import json
import os
import plistlib
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_NAME = "Palaver"
ICON = ROOT / "native" / "Bundle" / "Palaver.icns"
BUNDLE_ID = "com.kenodressel.meeting-transcribe"
EXECUTABLE = "Palaver"  # the Swift app (native/.build/release/Palaver)
MENUBAR_ICON = ROOT / "native" / "Bundle" / "menubar.png"  # the Swift app's menu bar icon, in Contents/Resources


def checkout_version() -> str:
    """The version this checkout builds (VERSION, at the repository's root)."""
    return (ROOT / "VERSION").read_text().strip()


# Local-network names App Transport Security would hold to https (ModelChoice.LOCAL_SUFFIXES but .local, which it
# exempts itself).
LOCAL_NETWORK_DOMAINS = ("lan", "home.arpa")


def info_plist(version: str, executable: str = EXECUTABLE) -> dict:
    return {
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleName": APP_NAME,
        "CFBundleDisplayName": APP_NAME,
        "CFBundleExecutable": executable,
        "CFBundleIconFile": ICON.name,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": version,
        "LSMinimumSystemVersion": "15.0",
        "LSUIElement": True,  # menu bar only, no Dock icon
        "NSMicrophoneUsageDescription":
            "Palaver records your side of meetings to transcribe them locally.",
        "NSAudioCaptureUsageDescription":
            "Palaver records the other participants' audio to transcribe the meeting.",
        "NSCalendarsFullAccessUsageDescription":
            "Palaver reads a meeting's title and invitees from your calendar to name "
            "its speakers. Nothing is changed or sent anywhere.",
        "NSCalendarsUsageDescription":
            "Palaver reads a meeting's title and invitees from your calendar to name "
            "its speakers. Nothing is changed or sent anywhere.",
        # Plain http:// to a gateway on the local network (ModelChoice.isLocalNetwork; the programs in Contents/MacOS
        # read this plist too). Measured: .local names, IP addresses and unqualified names pass App Transport Security
        # anyway; .lan and .home.arpa names need the exception. Every other host stays https only.
        "NSAppTransportSecurity": {
            "NSAllowsLocalNetworking": True,
            "NSExceptionDomains": {domain: {"NSIncludesSubdomains": True, "NSExceptionAllowsInsecureHTTPLoads": True}
                                   for domain in LOCAL_NETWORK_DOMAINS},
        },
    }


ENGINE = "palaver-engine"  # in Contents/MacOS: the Swift speech engine
SERVER = "palaver-server"  # in Contents/MacOS: the window's server (phase 3), started by the app
WORKER = "palaver-worker"  # in Contents/MacOS: the pipeline's worker (phase 3), started by the app
LM = "palaver-lm"  # in Contents/MacOS: the language model's worker (phase 4), started by the app, server and worker
CLI_IN_BUNDLE = "bin/palaver"  # in Contents/Resources: the `palaver` command (built as palaver-cli); ~/.local/bin links here
MCP_SHIM = "bin/python"  # in Contents/Resources: for 0.6 only, starts `bin/palaver mcp` for Claude entries of before
WEB = "web"  # in Contents/Resources: the window's page files palaver-server serves (AppLocation.WEB_RESOURCES)
METALLIB = "mlx.metallib"  # in Contents/Resources: MLX's Metal shaders, which palaver-lm loads from there
LICENSES = "THIRD_PARTY_LICENSES.md"  # in Contents/Resources: the notices of what the programs link
# The id runtime.json names (tools/build_release.py COMPAT_RUNTIME_ID): the releases before 0.6 compare it with the
# manifest's runtime and unpack that placeholder; the app itself uses no runtime.
COMPAT_RUNTIME_ID = "no-python-1"
ENTITLEMENTS = ROOT / "native" / "Bundle" / "Palaver.entitlements"
# A release signs as 0.5 did, without the hardened runtime: under it the microphone, system audio, the calendar, the
# Keychain's access lists and library validation without a team ID were never tried on a real start. Notarization
# will turn it on, with ENTITLEMENTS (kept for that).
HARDENED_RUNTIME = False


def sign_identity() -> str:
    """Ad hoc ("-") unless $PALAVER_SIGN_IDENTITY names a certificate: with
    one kept for every release, macOS keeps the microphone and system audio
    permissions across updates (an ad hoc signature differs every build)."""
    return os.environ.get("PALAVER_SIGN_IDENTITY") or "-"


def _codesign(path: Path, entitlements: Path | None = None, hardened: bool = True) -> None:
    argv = ["codesign", "--force", "--sign", sign_identity()]
    if hardened:
        argv += ["--options", "runtime"] + (["--entitlements", str(entitlements)] if entitlements else [])
    subprocess.run(argv + [str(path)], check=True, capture_output=True)


def _sign(app: Path, entitlements: Path | None = None, hardened: bool = False) -> None:
    """Nested code first (every program in Contents/MacOS but the executable, and the command in
    Contents/Resources/bin), then the bundle. ``hardened``: the hardened runtime with ``entitlements``
    (once ``HARDENED_RUNTIME`` is on)."""
    executable = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())["CFBundleExecutable"]
    nested = [p for p in sorted((app / "Contents" / "MacOS").iterdir()) if p.name != executable]
    command = app / "Contents" / "Resources" / CLI_IN_BUNDLE
    for program in nested + ([command] if command.exists() else []):
        _codesign(program, entitlements, hardened)
    _codesign(app, entitlements, hardened)


def _bundle(dest_dir: Path, *, version: str, executable: str = EXECUTABLE) -> Path:
    app = dest_dir / f"{APP_NAME}.app"
    macos = app / "Contents" / "MacOS"
    macos.mkdir(parents=True, exist_ok=True)
    (app / "Contents" / "Resources").mkdir(exist_ok=True)
    shutil.copyfile(ICON, app / "Contents" / "Resources" / ICON.name)
    (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info_plist(version, executable)))
    return app


def _program(src: Path, dest: Path) -> None:
    """A program into the bundle without its debug map: the linker's stabs name every object file and source folder
    of the build (the builder's home folder and user name), which `strings` does not show but the file holds."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dest)
    dest.chmod(0o755)
    subprocess.run(["strip", "-S", str(dest)], check=True, capture_output=True)


def build_release_app(dest_dir: Path, *, app_binary: Path, engine: Path, server: Path, worker: Path, lm: Path,
                      cli: Path, mcp_shim: Path, web: Path, lm_resources: list[Path] | None = None,
                      domain_resources: Path | None = None, licenses: Path | None = None,
                      version: str | None = None, runtime_json_id: str = COMPAT_RUNTIME_ID,
                      entitlements: Path | None = ENTITLEMENTS) -> Path:
    """The app a release publishes (#60), without Python: the Swift app (``app_binary``, the built
    ``Palaver``) as the executable, ``engine``, ``server``, ``worker`` and ``lm`` (palaver-lm, built by
    xcodebuild) beside it in Contents/MacOS. In Contents/Resources: ``cli`` (palaver-cli) as
    ``bin/palaver``, ``mcp_shim`` (native/Bundle/bin/python) as ``bin/python``, ``web`` (the window's
    page files) as ``web/``, ``lm_resources`` (palaver-lm's Metal shaders, any ``*.metallib`` copied as
    ``mlx.metallib``, and the resource bundles it reads, folders copied whole), ``domain_resources``'
    files flat (``zipf.bin``), ``licenses`` as THIRD_PARTY_LICENSES.md, the icons and runtime.json
    (``version``, ``runtime_json_id``: what the updaters before 0.6 check). Every program is signed with
    the one identity, nested code before the bundle; with the hardened runtime and ``entitlements`` only
    once ``HARDENED_RUNTIME`` is on. ``version``: VERSION's when None."""
    version = version or checkout_version()
    app = _bundle(dest_dir, version=version)
    macos = app / "Contents" / "MacOS"
    resources = app / "Contents" / "Resources"
    _program(app_binary, macos / EXECUTABLE)
    for name, built in ((ENGINE, engine), (SERVER, server), (WORKER, worker), (LM, lm)):
        _program(built, macos / name)
    _program(cli, resources / CLI_IN_BUNDLE)
    shutil.copyfile(mcp_shim, resources / MCP_SHIM)  # a shell script
    (resources / MCP_SHIM).chmod(0o755)
    shutil.copytree(web, resources / WEB, ignore=shutil.ignore_patterns(".*", "__pycache__", "*.py", "*.pyc"))
    shutil.copyfile(MENUBAR_ICON, resources / MENUBAR_ICON.name)
    (resources / "runtime.json").write_text(json.dumps({"version": version, "runtime": runtime_json_id}) + "\n")
    for item in lm_resources or []:
        if item.is_dir():
            shutil.copytree(item, resources / item.name)
        else:
            shutil.copyfile(item, resources / (METALLIB if item.suffix == ".metallib" else item.name))
    if domain_resources is not None:
        for item in sorted(domain_resources.iterdir()):
            if item.is_file() and not item.name.startswith("."):
                shutil.copyfile(item, resources / item.name)
    if licenses is not None:
        shutil.copyfile(licenses, resources / LICENSES)
    _sign(app, entitlements, hardened=HARDENED_RUNTIME)
    return app
