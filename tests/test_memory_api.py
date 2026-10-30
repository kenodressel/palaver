"""What Palaver costs in memory, for the Meetings window's Settings (#49)."""

import json
from pathlib import Path

from tests.test_webapp import _Recording, _recording_server, _req


class _WithMemory(_Recording):
    def __init__(self, memory):
        super().__init__()
        self._memory = memory

    def memory(self):
        return self._memory


def _get(tmp_path: Path, recording):
    tmp_path.mkdir(exist_ok=True)
    srv = _recording_server(tmp_path, recording)
    try:
        status, _, body = _req(srv, "/api/memory")
        return status, json.loads(body)
    finally:
        srv.shutdown()
        srv.server_close()


def test_http_memory_from_the_menu_bar_app(tmp_path: Path):
    mem = {"total": 5 * 2**30, "app": 2**28, "workers": [], "budgets": {"live": 5.0}}
    assert _get(tmp_path, _WithMemory(mem)) == (200, {"memory": mem})


def test_http_no_memory_outside_the_menu_bar_app(tmp_path: Path):
    assert _get(tmp_path / "a", None) == (200, {"memory": None})
    assert _get(tmp_path / "b", _Recording()) == (200, {"memory": None})
