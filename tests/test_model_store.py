"""Tests for the models Palaver hosts itself, kept in Application Support (#60)."""

import dataclasses
import io
import json
import tarfile
from pathlib import Path

import pytest

from palaver import model_store

REPO = "northwind/voices-small"
NAME = "northwind-voices"



@pytest.fixture(autouse=True)
def local_release(monkeypatch, tmp_path):
    """Assets here are file:// URLs, which the downloader takes only with a local manifest.
    No release hosts a model now; the machinery is tested with one that does."""
    monkeypatch.setenv("PALAVER_MANIFEST_URL", (tmp_path / "manifest.json").as_uri())
    monkeypatch.setitem(model_store.HOSTED, REPO, NAME)


def test_no_release_hosts_a_model_any_more(monkeypatch):
    monkeypatch.undo()
    assert model_store.HOSTED == {}


def fake_model(root: Path, name=NAME, version="3533c8c", repo=REPO) -> Path:
    """A tiny model folder: what the release tool packs."""
    folder = root / name
    (folder / "segmentation").mkdir(parents=True)
    (folder / "config.yaml").write_text("pipeline:\n  name: x\n")
    (folder / "segmentation" / "pytorch_model.bin").write_bytes(b"weights")
    model_store.write_marker(folder, name=name, version=version, repo=repo)
    return folder


def pack(folder: Path, out: Path) -> Path:
    with tarfile.open(out, "w") as tar:
        tar.add(folder, arcname=folder.name)
    return out


def test_a_hosted_model_on_this_mac_is_used_instead_of_the_hugging_face_repo(tmp_path):
    fake_model(model_store.models_dir(tmp_path))
    assert model_store.resolve(REPO, home=tmp_path) == str(model_store.models_dir(tmp_path) / NAME)
    assert model_store.installed(home=tmp_path) == {NAME: "3533c8c"}


def test_without_a_local_copy_the_repo_is_used_as_before(tmp_path):
    assert model_store.resolve(REPO, home=tmp_path) == REPO
    assert model_store.resolve("mlx-community/parakeet-tdt-0.6b-v3", home=tmp_path) == "mlx-community/parakeet-tdt-0.6b-v3"


def test_a_copy_with_a_file_missing_is_not_used(tmp_path):
    folder = fake_model(model_store.models_dir(tmp_path))
    (folder / "segmentation" / "pytorch_model.bin").unlink()
    assert model_store.local_path(REPO, home=tmp_path) is None
    assert model_store.installed(home=tmp_path) == {}


def test_a_copy_of_another_repo_is_not_used_for_this_one(tmp_path):
    fake_model(model_store.models_dir(tmp_path), repo="northwind/voices-large")
    assert model_store.resolve(REPO, home=tmp_path) == REPO


def test_an_archive_is_installed_whole_and_replaces_the_old_version(tmp_path):
    build = tmp_path / "build"
    old = fake_model(model_store.models_dir(tmp_path / "home"), version="1111111")
    (old / "stale.bin").write_bytes(b"old")
    archive = pack(fake_model(build, version="3533c8c"), tmp_path / "m.tar")
    folder = model_store.install_archive(archive, name=NAME, version="3533c8c", home=tmp_path / "home")
    assert folder == model_store.models_dir(tmp_path / "home") / NAME
    assert not (folder / "stale.bin").exists()
    assert model_store.installed(home=tmp_path / "home") == {NAME: "3533c8c"}
    assert [p.name for p in model_store.models_dir(tmp_path / "home").iterdir()] == [NAME]  # nothing left over


def test_an_archive_of_another_model_or_version_leaves_the_old_one(tmp_path):
    home = tmp_path / "home"
    fake_model(model_store.models_dir(home), version="1111111")
    archive = pack(fake_model(tmp_path / "build", version="2222222"), tmp_path / "m.tar")
    with pytest.raises(model_store.ModelError, match="3533c8c"):
        model_store.install_archive(archive, name=NAME, version="3533c8c", home=home)
    assert model_store.installed(home=home) == {NAME: "1111111"}
    assert [p.name for p in model_store.models_dir(home).iterdir()] == [NAME]


def test_an_archive_reaching_outside_its_folder_is_refused(tmp_path):
    archive = tmp_path / "evil.tar"
    with tarfile.open(archive, "w") as tar:
        data = b"x"
        info = tarfile.TarInfo(f"{NAME}/../../escaped")
        info.size = len(data)
        tar.addfile(info, io.BytesIO(data))
    with pytest.raises(model_store.ModelError):
        model_store.install_archive(archive, name=NAME, version="3533c8c", home=tmp_path / "home")
    assert not (tmp_path / "escaped").exists()


def test_the_marker_lists_every_file_with_its_size(tmp_path):
    folder = fake_model(tmp_path)
    marker = json.loads((folder / model_store.MARKER).read_text())
    assert marker["files"] == {"config.yaml": 20, "segmentation/pytorch_model.bin": 7}
    assert marker["repo"] == REPO


def _hosted_manifest(archive: Path, sha: str | None = None):
    from palaver import release

    return release.Manifest(
        version="0.2.0", app=release.Asset("a.zip", "https://e/a.zip", 1, "a" * 64), runtime_id="rt",
        runtime=release.Asset("r.tar.gz", "https://e/r.tar.gz", 1, "b" * 64),
        models=(release.HostedModel(NAME, "3533c8c", REPO, release.Asset(
            archive.name, archive.as_uri(), archive.stat().st_size, sha or release.sha256_file(archive))),))


def test_the_setup_downloads_the_hosted_copy_from_the_release(tmp_path, monkeypatch):
    from palaver import onboarding

    home = tmp_path / "home"
    monkeypatch.setattr(model_store.Path, "home", classmethod(lambda cls: home))
    archive = pack(fake_model(tmp_path / "build"), tmp_path / "m.tar")
    assert onboarding.fetch_hosted(REPO, _hosted_manifest(archive)) is True
    assert model_store.resolve(REPO) == str(model_store.models_dir(home) / NAME)
    assert onboarding.model_here(dataclasses.replace(onboarding.RETIRED["pyannote"], hosted=True), REPO)
    assert [p.name for p in model_store.models_dir(home).iterdir()] == [NAME]  # no .part left


def test_a_damaged_hosted_download_installs_nothing(tmp_path, monkeypatch):
    from palaver import downloader, onboarding

    home = tmp_path / "home"
    monkeypatch.setattr(model_store.Path, "home", classmethod(lambda cls: home))
    archive = pack(fake_model(tmp_path / "build"), tmp_path / "m.tar")
    with pytest.raises(downloader.DownloadError, match="damaged"):
        onboarding.fetch_hosted(REPO, _hosted_manifest(archive, sha="0" * 64))
    assert model_store.resolve(REPO) == REPO
    assert list(model_store.models_dir(home).iterdir()) == []


def test_a_model_no_release_hosts_is_left_to_hugging_face(tmp_path):
    from palaver import onboarding

    assert onboarding.fetch_hosted("mlx-community/parakeet-tdt-0.6b-v3") is False
