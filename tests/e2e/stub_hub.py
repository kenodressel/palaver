"""A stub Hugging Face hub on 127.0.0.1 for the e2e tests of the model downloads: the e5 repo at its pinned revision
with tiny files, as huggingface.co answers (the file list, HEAD with ETag and size, the LFS file redirected to a
"CDN": a second server, another origin, as Hugging Face's CDN hosts are; Range requests). The LFS file's transfer can be held part-way (``hold``), so a test
sees the Downloads page's progress. Nothing reaches the network."""

from __future__ import annotations

import hashlib
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

E5 = "intfloat/multilingual-e5-small"
E5_REVISION = "614241f622f53c4eeff9890bdc4f31cfecc418b3"
MIB = 1024 * 1024


class StubHub:
    def __init__(self):
        weights = bytes(range(256)) * (22 * MIB // 256)  # 22 MiB: "20 MB" on the page while held at 21 MiB
        self.files = {"config.json": b'{"model_type": "bert"}', "sentencepiece.bpe.model": b"pieces",
                      "model.safetensors": weights, "README.md": b"# not wanted"}
        self.lfs = {"model.safetensors": hashlib.sha256(weights).hexdigest()}
        self.requests: list[tuple[str, str, str | None]] = []  # (method, path, Authorization) at the hub
        self.cdn_requests: list[tuple[str, str, str | None]] = []  # … at the CDN
        self.hold_at: int | None = None
        self.released = threading.Event()
        self._lock = threading.Lock()
        hub = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):  # quiet
                pass

            def do_HEAD(self):
                hub._answer(self, head=True)

            def do_GET(self):
                hub._answer(self, head=False)

        self._servers = [ThreadingHTTPServer(("127.0.0.1", 0), Handler) for _ in range(2)]
        for server in self._servers:
            server.daemon_threads = True
            threading.Thread(target=server.serve_forever, name="stub-hub", daemon=True).start()
        self.url = f"http://127.0.0.1:{self._servers[0].server_address[1]}"
        self.cdn_url = f"http://127.0.0.1:{self._servers[1].server_address[1]}"
        self._cdn_port = self._servers[1].server_address[1]

    def hold(self, at: int) -> None:
        """The LFS file's transfer stops after ``at`` bytes until ``release``."""
        self.hold_at = at
        self.released.clear()

    def release(self) -> None:
        self.released.set()

    def close(self) -> None:
        self.released.set()
        for server in self._servers:
            server.shutdown()
            server.server_close()

    def _answer(self, h: BaseHTTPRequestHandler, *, head: bool) -> None:
        cdn = h.server.server_address[1] == self._cdn_port
        with self._lock:
            (self.cdn_requests if cdn else self.requests).append((h.command, h.path, h.headers.get("Authorization")))
        path = h.path.split("?")[0]
        if cdn:
            return self._answer_cdn(h, path, head)
        if path == f"/api/models/{E5}/revision/{E5_REVISION}":
            body = json.dumps({"id": E5, "sha": E5_REVISION,
                               "siblings": [{"rfilename": n} for n in self.files]}).encode()
            return self._send(h, 200, {"Content-Type": "application/json"}, body, head)
        prefix = f"/{E5}/resolve/{E5_REVISION}/"
        if path.startswith(prefix) and path[len(prefix):] in self.files:
            name = path[len(prefix):]
            data = self.files[name]
            if name in self.lfs:  # to the "CDN", as huggingface.co sends LFS files
                return self._send(h, 302, {"Location": f"{self.cdn_url}/cdn/{self.lfs[name]}?X-Amz-Signature=stub",
                                           "X-Linked-Etag": f'"{self.lfs[name]}"', "X-Linked-Size": str(len(data)),
                                           "X-Repo-Commit": E5_REVISION}, b"", head)
            etag = hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()
            return self._send(h, 200, {"ETag": f'"{etag}"', "X-Repo-Commit": E5_REVISION}, data, head)
        return self._send(h, 404, {}, b"", head)

    def _answer_cdn(self, h: BaseHTTPRequestHandler, path: str, head: bool) -> None:
        if path.startswith("/cdn/"):
            data = next(self.files[n] for n, sha in self.lfs.items() if sha == path[len("/cdn/"):])
            start = 0
            if (r := h.headers.get("Range", "")).startswith("bytes="):
                start = int(r[len("bytes="):].split("-")[0])
            headers = {"Content-Range": f"bytes {start}-{len(data) - 1}/{len(data)}"} if start else {}
            return self._send(h, 206 if start else 200, headers, data[start:], head, hold=True)
        return self._send(h, 404, {}, b"", head)

    def _send(self, h: BaseHTTPRequestHandler, status: int, headers: dict, body: bytes, head: bool,
              hold: bool = False) -> None:
        h.send_response(status)
        for k, v in headers.items():
            h.send_header(k, v)
        h.send_header("Content-Length", str(len(body)))
        h.send_header("Connection", "close")
        h.end_headers()
        if head:
            return
        at = self.hold_at if hold else None
        if at is not None:
            self.hold_at = None
            h.wfile.write(body[:at])
            h.wfile.flush()
            self.released.wait(60)
            body = body[at:]
        h.wfile.write(body)
