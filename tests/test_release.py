"""Tests for the release manifest, the runtime id and what an update downloads (#60)."""

import json

import pytest

from palaver import release


def asset(name, size=10, sha="a" * 64):
    return {"name": name, "url": f"https://example.test/{name}", "size": size, "sha256": sha}


def manifest(version="0.2.0", runtime_id="3.13.2-arm64-aaaaaaaaaaaa", models=None, **extra):
    data = {
        "schema": 1,
        "version": version,
        "minimum_macos": "15.0",
        "arch": "arm64",
        "app": asset(f"palaver-app-{version}.zip", 5_000_000),
        "runtime": {"id": runtime_id, **asset(f"palaver-runtime-{runtime_id}.tar.gz", 900_000_000)},
        "models": models if models is not None else [
            {"name": "northwind-voices", "version": "3533c8c",
             "repo": "northwind/voices-small", "license": "CC-BY-4.0",
             "asset": asset("palaver-models-northwind-voices-3533c8c.tar", 33_000_000)},
        ],
    }
    data.update(extra)
    return data


def test_a_manifest_is_read_with_every_layer():
    m = release.parse_manifest(manifest())
    assert m.version == "0.2.0"
    assert m.app.name == "palaver-app-0.2.0.zip" and m.app.size == 5_000_000
    assert m.runtime_id == "3.13.2-arm64-aaaaaaaaaaaa"
    assert m.runtime.url.endswith(".tar.gz")
    assert [(x.name, x.version, x.repo) for x in m.models] == [
        ("northwind-voices", "3533c8c", "northwind/voices-small")]
    assert m.minimum_macos == "15.0" and m.notes is None


def test_a_manifest_is_read_from_its_json_text_too():
    m = release.parse_manifest(json.dumps(manifest(notes="Faster notes.")))
    assert m.notes == "Faster notes."


@pytest.mark.parametrize("broken, why", [
    ({"schema": 2}, "schema"),
    ({"version": ""}, "version"),
    ({"version": "1.0; rm -rf ~"}, "version"),
    ({"version": "../../x"}, "version"),
    ({"app": {"name": "x.zip", "url": "https://e/x.zip", "size": 1, "sha256": "nothex"}}, "sha256"),
    ({"app": {"name": "x.zip", "url": "ftp://e/x.zip", "size": 1, "sha256": "a" * 64}}, "url"),
    ({"runtime": {"id": "../evil", **asset("r.tar.gz")}}, "runtime id"),
    ({"models": [{"name": "../x", "version": "1", "repo": "r/x", "asset": asset("m.tar")}]}, "model name"),
])
def test_a_broken_manifest_says_what_is_wrong(broken, why):
    data = {**manifest(), **broken}
    with pytest.raises(release.ManifestError, match=why):
        release.parse_manifest(data)


def test_a_manifest_that_is_no_json_is_refused():
    with pytest.raises(release.ManifestError):
        release.parse_manifest("<html>rate limited</html>")


def test_a_manifest_written_is_read_back_the_same():
    m = release.parse_manifest(manifest(notes="n"))
    assert release.parse_manifest(release.manifest_json(m)) == m


def test_the_runtime_id_depends_on_the_locked_set_the_python_and_the_arch():
    reqs = "numpy==2.3.1\n    # via palaver\ntorch==2.11.0\n"
    rid = release.runtime_id(reqs, "3.13.2", "arm64")
    assert rid.startswith("3.13.2-arm64-") and len(rid.rsplit("-", 1)[1]) == 12
    # comments and order (what another uv version writes differently) don't change it
    assert release.runtime_id("torch==2.11.0\n# via x\nnumpy==2.3.1\n", "3.13.2", "arm64") == rid
    assert release.runtime_id("numpy==2.3.2\ntorch==2.11.0\n", "3.13.2", "arm64") != rid
    assert release.runtime_id(reqs, "3.13.3", "arm64") != rid
    assert release.runtime_id(reqs, "3.13.2", "x86_64") != rid
    assert release.runtime_id(reqs, "3.13.2", "arm64", build="python-build-standalone 20261026") != rid


@pytest.mark.parametrize("a, b, newer", [
    ("0.2.0", "0.1.9", True),
    ("0.10.0", "0.9.0", True),
    ("0.2.0", "0.2.0", False),
    ("v0.2.1", "0.2.0", True),
    ("0.2.0", "0.2.0rc1", True),
    ("0.2.0rc2", "0.2.0rc1", True),
])
def test_versions_compare_as_numbers(a, b, newer):
    assert release.is_newer(a, b) is newer


def installed(version="0.1.0", runtime="3.13.2-arm64-aaaaaaaaaaaa", models=None):
    return release.Installed(version=version, runtime_id=runtime,
                             models=models if models is not None else {"northwind-voices": "3533c8c"})


def test_an_update_with_the_same_runtime_downloads_only_the_app():
    plan = release.plan_update(installed(), release.parse_manifest(manifest()))
    assert plan.version == "0.2.0"
    assert plan.app.name == "palaver-app-0.2.0.zip"
    assert plan.runtime is None and plan.models == ()
    assert plan.download_bytes == 5_000_000


def test_a_changed_lock_downloads_the_runtime_too():
    plan = release.plan_update(installed(), release.parse_manifest(manifest(runtime_id="3.13.2-arm64-bbbbbbbbbbbb")))
    assert plan.runtime is not None and plan.runtime_id == "3.13.2-arm64-bbbbbbbbbbbb"
    assert plan.download_bytes == 905_000_000


def test_a_changed_model_is_downloaded_again_but_one_never_installed_is_left_to_the_setup():
    models = [
        {"name": "northwind-voices", "version": "4444444", "repo": "northwind/voices-small",
         "asset": asset("palaver-models-northwind-voices-4444444.tar", 34_000_000)},
        {"name": "other", "version": "1", "repo": "x/other", "asset": asset("palaver-models-other-1.tar", 1)},
    ]
    plan = release.plan_update(installed(), release.parse_manifest(manifest(models=models)))
    assert [m.name for m in plan.models] == ["northwind-voices"]


def test_no_update_when_the_release_is_not_newer():
    assert release.plan_update(installed(version="0.2.0"), release.parse_manifest(manifest())) is None


def test_a_release_for_a_newer_macos_is_no_update_here():
    m = release.parse_manifest(manifest(minimum_macos="27.0"))
    with pytest.raises(release.ManifestError, match="macOS 27.0"):
        release.plan_update(installed(), m, macos="26.1")


def test_sha256_of_a_file_is_read_in_chunks(tmp_path):
    import hashlib

    f = tmp_path / "x"
    f.write_bytes(b"palaver" * 400_000)
    assert release.sha256_file(f) == hashlib.sha256(b"palaver" * 400_000).hexdigest()


def test_a_runtime_already_on_this_mac_is_not_downloaded_again():
    """Going back to an earlier version, or forward again: its runtime is
    the one kept before (#60)."""
    here = release.Installed(version="0.1.0", runtime_id="3.13.2-arm64-aaaaaaaaaaaa", models={},
                             runtimes=frozenset({"3.13.2-arm64-bbbbbbbbbbbb"}))
    plan = release.plan_update(here, release.parse_manifest(manifest(runtime_id="3.13.2-arm64-bbbbbbbbbbbb")))
    assert plan.runtime is None and plan.runtime_id == "3.13.2-arm64-bbbbbbbbbbbb"


def test_a_runtime_archive_with_apple_double_files_is_refused(tmp_path):
    import io
    import tarfile

    import pytest

    from tools.build_release import check_no_apple_double

    def archive(names):
        path = tmp_path / f"r{len(names)}.tar.gz"
        with tarfile.open(path, "w:gz") as tar:
            for name in names:
                info = tarfile.TarInfo(name)
                info.size = 1
                tar.addfile(info, io.BytesIO(b"x"))
        return path

    check_no_apple_double(archive(["rid/bin/python3"]))
    with pytest.raises(SystemExit, match="AppleDouble"):
        check_no_apple_double(archive(["._rid", "rid/bin/python3"]))
