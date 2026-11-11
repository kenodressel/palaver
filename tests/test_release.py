"""Tests for the release manifest tools/build_release.py writes (#60)."""

import json

import pytest

from tools import release


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


def test_sha256_of_a_file_is_read_in_chunks(tmp_path):
    import hashlib

    f = tmp_path / "x"
    f.write_bytes(b"palaver" * 400_000)
    assert release.sha256_file(f) == hashlib.sha256(b"palaver" * 400_000).hexdigest()


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
