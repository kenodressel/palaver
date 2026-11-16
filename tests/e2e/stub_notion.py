"""A stub Notion API on 127.0.0.1 for the e2e tests of #34 (palaver-server's PALAVER_TEST_NOTION_API): the token's
workspace (GET /v1/users/me), the parent page uploads go to (GET /v1/pages/<id>), and new pages (POST /v1/pages, with
their blocks appended by PATCH). Fake ids, URLs and workspace only; nothing reaches the network."""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = "secret_notion_e2e_0123456789abcdefghijklmn"
PARENT = "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
OTHER = "1a2b3c4d-5e6f-4758-9a0b-1c2d3e4f5a6b"
WORKSPACE = "Contoso"
PARENT_URL = "https://www.notion.so/Contoso-Meetings-0f1e2d3c4b5a69788796a5b4c3d2e1f0"


class StubNotion:
    def __init__(self):
        self.created: list[dict] = []  # the bodies of POST /v1/pages
        self.requests: list[tuple[str, str, str | None]] = []  # (method, path, Authorization)
        self._lock = threading.Lock()
        stub = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):  # quiet
                pass

            def do_GET(self):
                stub._answer(self)

            def do_POST(self):
                stub._answer(self)

            def do_PATCH(self):
                stub._answer(self)

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._server.daemon_threads = True
        threading.Thread(target=self._server.serve_forever, kwargs={"poll_interval": 0.05}, name="stub-notion",
                         daemon=True).start()
        self.url = f"http://127.0.0.1:{self._server.server_address[1]}/v1"

    def page_url(self, n: int) -> str:
        return f"https://www.notion.so/Contoso-Team-standup-{n:032x}"

    def close(self) -> None:
        self._server.shutdown()
        self._server.server_close()

    def _answer(self, h: BaseHTTPRequestHandler) -> None:
        length = int(h.headers.get("Content-Length") or 0)
        body = json.loads(h.rfile.read(length) or b"{}") if length else {}
        with self._lock:
            self.requests.append((h.command, h.path, h.headers.get("Authorization")))
        if h.headers.get("Authorization") != f"Bearer {TOKEN}":
            return self._send(h, 401, {"message": "API token is invalid."})
        if h.command == "GET" and h.path == "/v1/users/me":
            return self._send(h, 200, {"object": "user", "type": "bot", "bot": {"workspace_name": WORKSPACE}})
        if h.command == "GET" and h.path == f"/v1/pages/{PARENT}":
            return self._send(h, 200, {"object": "page", "id": PARENT, "url": PARENT_URL, "properties": {
                "title": {"type": "title", "title": [{"plain_text": "Meetings"}]}}})
        if h.command == "POST" and h.path == "/v1/pages":
            with self._lock:
                self.created.append(body)
                n = len(self.created)
            return self._send(h, 200, {"object": "page", "id": f"{n:032x}", "url": self.page_url(n)})
        if h.command == "PATCH" and h.path.startswith("/v1/blocks/"):
            return self._send(h, 200, {"object": "list", "results": []})
        self._send(h, 404, {"message": f"Could not find {h.path}"})

    @staticmethod
    def _send(h: BaseHTTPRequestHandler, status: int, body: dict) -> None:
        data = json.dumps(body).encode()
        h.send_response(status)
        h.send_header("Content-Type", "application/json")
        h.send_header("Content-Length", str(len(data)))
        h.end_headers()
        h.wfile.write(data)
