"""Downloads of release assets (#60): to a .part file, checked against the
manifest's sha256 before anything uses them. Only plain HTTPS GETs of
public release files: no account, no token, nothing sent about the Mac.

``PALAVER_MANIFEST_URL`` points at another manifest (a file:// one for
testing an update without a release).
"""

from __future__ import annotations

import hashlib
import os
import urllib.request
from pathlib import Path
from typing import Callable

from . import release

TIMEOUT = 30
CHUNK = 1 << 20


class DownloadError(RuntimeError):
    pass


class HTTPSOnlyRedirects(urllib.request.HTTPRedirectHandler):
    """GitHub redirects release downloads to its storage, over HTTPS; a
    redirect anywhere else is refused."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.startswith("https://"):
            raise DownloadError(f"refused a redirect away from https: {newurl}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_OPENER = urllib.request.build_opener(HTTPSOnlyRedirects)


def manifest_url() -> str:
    return os.environ.get("PALAVER_MANIFEST_URL") or release.LATEST_MANIFEST_URL


def _allowed(url: str) -> bool:
    """https only; file:// only while testing with a local manifest."""
    return url.startswith("https://") or (url.startswith("file://") and manifest_url().startswith("file://"))


def _open(url: str):
    if not _allowed(url):
        raise DownloadError(f"only https downloads are allowed, not {url}")
    if url.startswith("file://"):
        return urllib.request.urlopen(url, timeout=TIMEOUT)
    request = urllib.request.Request(url, headers={"User-Agent": "Palaver"})
    return _OPENER.open(request, timeout=TIMEOUT)


def fetch_manifest(url: str | None = None, opener: Callable = _open) -> release.Manifest:
    """The latest release's manifest. Raises DownloadError or ManifestError."""
    url = url or manifest_url()
    if not _allowed(url):
        raise DownloadError(f"only https downloads are allowed, not {url}")
    try:
        with opener(url) as response:
            body = response.read(1 << 20)
    except OSError as exc:
        raise DownloadError(f"can't reach {url}: {getattr(exc, 'reason', None) or exc}") from None
    return release.parse_manifest(body)


def download(asset: release.Asset, dest: Path, *, opener: Callable = _open,
             on_progress: Callable[[int], None] | None = None) -> Path:
    """``asset`` into ``dest``, its sha256 checked; a wrong or short file
    is deleted and raises DownloadError."""
    if not _allowed(asset.url):
        raise DownloadError(f"only https downloads are allowed, not {asset.url}")
    dest.parent.mkdir(parents=True, exist_ok=True)
    digest, got = hashlib.sha256(), 0
    try:
        with opener(asset.url) as response, open(dest, "wb") as out:
            while block := response.read(CHUNK):
                out.write(block)
                digest.update(block)
                got += len(block)
                if on_progress:
                    on_progress(got)
    except OSError as exc:
        dest.unlink(missing_ok=True)
        raise DownloadError(f"download of {asset.name} failed: {getattr(exc, 'reason', None) or exc}") from None
    if got != asset.size or digest.hexdigest() != asset.sha256:
        dest.unlink(missing_ok=True)
        raise DownloadError(f"{asset.name} arrived damaged (checksum mismatch); nothing was changed")
    return dest
