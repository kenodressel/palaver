"""Tests for release downloads (#60): HTTPS only, checked before use."""

import urllib.request

import pytest

from palaver import downloader, release


def test_a_redirect_to_plain_http_is_refused():
    handler = downloader.HTTPSOnlyRedirects()
    req = urllib.request.Request("https://github.com/x/releases/latest/download/manifest.json")
    with pytest.raises(downloader.DownloadError, match="https"):
        handler.redirect_request(req, None, 302, "Found", {}, "http://evil.test/manifest.json")
    assert handler.redirect_request(req, None, 302, "Found", {}, "https://objects.githubusercontent.com/x") is not None


@pytest.mark.parametrize("url", ["http://example.test/manifest.json", "ftp://example.test/x", "file:///etc/passwd"])
def test_only_https_is_fetched_from_a_real_release(url, monkeypatch):
    monkeypatch.delenv("PALAVER_MANIFEST_URL", raising=False)
    with pytest.raises(downloader.DownloadError, match="https"):
        downloader.fetch_manifest(url)


def test_file_urls_are_for_testing_with_a_local_manifest_only(tmp_path, monkeypatch):
    f = tmp_path / "a.zip"
    f.write_bytes(b"app")
    asset = release.Asset("a.zip", f.as_uri(), 3, release.sha256_file(f))
    monkeypatch.delenv("PALAVER_MANIFEST_URL", raising=False)
    with pytest.raises(downloader.DownloadError, match="https"):
        downloader.download(asset, tmp_path / "out.part")
    monkeypatch.setenv("PALAVER_MANIFEST_URL", (tmp_path / "manifest.json").as_uri())
    assert downloader.download(asset, tmp_path / "out.part").read_bytes() == b"app"
