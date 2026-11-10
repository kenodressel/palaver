"""The contract with every release before 0.6 (Keno's answer 3 of the phase 4 plan): they update in-app
through their own Python updater, frozen in them, so what tools/build_release.py makes for 0.6 and later
must pass its checks. Their code runs here as it shipped (tests/fixtures/updater_0.3.14 for 0.1.0-0.3.14,
updater_0.5.0rc6 for 0.5.0rc1-rc6): the manifest parses, the update downloads only the app and the
few-hundred-byte placeholder runtime, the placeholder unpacks, and the new app is accepted."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import types
from pathlib import Path

import pytest

from tools import build_release

FIXTURES = Path(__file__).parent / "fixtures"
OLD_RID = "3.13.18-arm64-227bfef1b0cc"  # 0.3.14's runtime
RC6_RID = "3.13.18-arm64-155fa76f8b4e"


def _module(name: str, path: Path) -> types.ModuleType:
    mod = types.ModuleType(name)
    mod.__file__ = str(path)
    sys.modules[name] = mod  # dataclasses look their module up
    exec(compile(path.read_text(), str(path), "exec"), mod.__dict__)
    return mod


@pytest.fixture(scope="module")
def old_release():
    return _module("palaver_0_3_14_release", FIXTURES / "updater_0.3.14" / "release.py.txt")


@pytest.fixture(scope="module")
def old_layout():
    return _module("palaver_0_3_14_install_layout", FIXTURES / "updater_0.3.14" / "install_layout.py.txt")


def _updater(version: str, release, layout) -> types.SimpleNamespace:
    """unpack_runtime and Installer._unpack_app of that release, with its own release and install_layout."""
    ns = {"release": release, "install_layout": layout, "Path": Path, "os": os, "shutil": shutil,
          "subprocess": subprocess, "tempfile": tempfile}
    source = "from __future__ import annotations\n" + (FIXTURES / f"updater_{version}" / "unpack.py.txt").read_text()
    exec(compile(source, f"updater_{version}/unpack.py.txt", "exec"), ns)
    return types.SimpleNamespace(unpack_runtime=ns["unpack_runtime"], unpack_app=ns["_unpack_app"])


def _app_zip(tmp: Path, version: str, runtime: str) -> Path:
    app = tmp / "build" / "Palaver.app"
    (app / "Contents" / "Resources").mkdir(parents=True)
    (app / "Contents" / "Resources" / "runtime.json").write_text(json.dumps({"version": version, "runtime": runtime}))
    archive = tmp / f"palaver-app-{version}.zip"
    subprocess.run(["/usr/bin/ditto", "-ck", "--keepParent", str(app), str(archive)], check=True)
    shutil.rmtree(tmp / "build")
    return archive


@pytest.fixture
def dist(tmp_path):
    """A 0.6 release's assets, as `make release` makes them: the app (runtime.json naming the
    placeholder), the placeholder runtime and the manifest over both."""
    d = tmp_path / "dist"
    d.mkdir()
    _app_zip(d, "0.6.0", build_release.COMPAT_RUNTIME_ID)
    build_release.build_compat_runtime(d)
    build_release.build_manifest(d, None, None, version="0.6.0", base_url=f"file://{d}")
    return d


def test_the_placeholder_is_tiny_and_the_same_on_every_build(tmp_path):
    a, b = tmp_path / "a", tmp_path / "b"
    a.mkdir()
    b.mkdir()
    first, second = build_release.build_compat_runtime(a), build_release.build_compat_runtime(b)
    assert first.read_bytes() == second.read_bytes()  # one upload, its URL kept by --previous
    assert first.stat().st_size < 1024


@pytest.mark.parametrize("version,installed_rid", [("0.3.14", OLD_RID), ("0.5.0rc6", RC6_RID)])
def test_an_old_release_updates_to_0_6_downloading_only_the_app_and_the_placeholder(
        dist, tmp_path, old_release, old_layout, version, installed_rid):
    manifest = old_release.parse_manifest((dist / "manifest.json").read_text())
    assert manifest.runtime_id == build_release.COMPAT_RUNTIME_ID
    here = old_release.Installed(version=version, runtime_id=installed_rid, models={},
                                 runtimes=frozenset({installed_rid}))
    plan = old_release.plan_update(here, manifest, macos="15.6")
    assert plan is not None and plan.version == "0.6.0"
    assert plan.runtime is not None and plan.runtime.size < 1024  # never the 500 MB runtime
    assert plan.download_bytes == plan.app.size + plan.runtime.size

    updater = _updater("0.3.14" if version.startswith("0.3") else "0.5.0rc6", old_release, old_layout)
    home = tmp_path / "home"
    archive = Path(plan.runtime.url.removeprefix("file://"))
    assert old_release.sha256_file(archive) == plan.runtime.sha256
    target = updater.unpack_runtime(archive, plan.runtime_id, home)
    assert target == old_layout.runtime_dir(build_release.COMPAT_RUNTIME_ID, home)
    assert os.access(target / "bin" / "python3", os.X_OK)

    work = tmp_path / "updates"
    work.mkdir()
    zipped = work / "app.zip"
    shutil.copy(Path(plan.app.url.removeprefix("file://")), zipped)
    app = updater.unpack_app(None, zipped, work, plan)
    assert old_layout.bundle_info(app) == {"version": "0.6.0", "runtime": build_release.COMPAT_RUNTIME_ID}


def test_an_old_release_refuses_an_app_whose_runtime_json_names_another_runtime(tmp_path, old_release, old_layout):
    """Why runtime.json must name the placeholder: the check is real."""
    plan = old_release.Plan("0.6.0", None, build_release.COMPAT_RUNTIME_ID, None, ())
    work = tmp_path / "updates"
    work.mkdir()
    zipped = _app_zip(work, "0.6.0", RC6_RID)
    with pytest.raises(old_release.ManifestError, match="not Palaver 0.6.0"):
        _updater("0.5.0rc6", old_release, old_layout).unpack_app(None, zipped, work, plan)


def test_an_old_release_refuses_a_manifest_without_a_runtime_block(dist, old_release):
    """Why 0.6's manifest keeps one: without it, no release before 0.6 can update."""
    data = json.loads((dist / "manifest.json").read_text())
    del data["runtime"]
    with pytest.raises(old_release.ManifestError, match="runtime"):
        old_release.parse_manifest(data)


def test_the_build_refuses_a_bundle_with_python_or_the_real_runtime(tmp_path):
    """No tester build from a hybrid state: a bundle that still carries Python, or whose runtime.json names a real
    runtime, is no 0.6 release (check_bundle; tests/test_app_bundle.py covers each kind)."""
    app = tmp_path / "Palaver.app"
    (app / "Contents" / "MacOS").mkdir(parents=True)
    (app / "Contents" / "Resources").mkdir()
    (app / "Contents" / "MacOS" / "palaver-python").write_text("")
    (app / "Contents" / "Resources" / "runtime.json").write_text(json.dumps({"version": "0.6.0", "runtime": RC6_RID}))
    with pytest.raises(SystemExit, match="no release without Python"):
        build_release.check_bundle(app)
    (app / "Contents" / "MacOS" / "palaver-python").unlink()
    (app / "Contents" / "Resources" / "runtime.json").write_text(
        json.dumps({"version": "0.6.0", "runtime": build_release.COMPAT_RUNTIME_ID}))
    build_release.check_bundle(app)


def test_the_manifest_refuses_an_app_whose_runtime_json_names_another_runtime(tmp_path):
    d = tmp_path / "dist"
    d.mkdir()
    _app_zip(d, "0.6.0", RC6_RID)
    build_release.build_compat_runtime(d)
    with pytest.raises(SystemExit, match="runtime.json names"):
        build_release.build_manifest(d, None, None, version="0.6.0")
