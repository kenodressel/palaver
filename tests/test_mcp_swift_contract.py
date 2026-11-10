"""Contract: Claude's tools from the Swift `palaver mcp` (native/Sources/PalaverServer/Mcp, phase 4 batch 6).

The official Python MCP client (the SDK Claude's own clients follow) talks to the built
``palaver-cli`` over stdio: the same server name, instructions and tool schemas as the
Python server (mcp_server.py), and the same answers as its ``Meetings`` on the same
recordings. While it runs and after, the Python reader of the access log and the
heartbeats (mcp_access.py, as the Python window read them) sees its calls and its client.
Build it with `make parity-helper` (``make test`` builds it too).
"""

import asyncio
import json
import os
import time
from pathlib import Path

import pytest

from palaver import mcp_access, mcp_server
from palaver.webapp import api

from .test_webapp import MEETING, _meeting

CLI = Path(__file__).resolve().parent.parent / "native" / ".build" / "debug" / "palaver-cli"

pytestmark = pytest.mark.skipif(not CLI.exists(), reason="palaver-cli not built: run `make parity-helper` (or `make test`)")


def _recordings(tmp_path: Path) -> tuple[Path, Path, Path]:
    """One meeting (Rico named, in "Hiring"), config.toml naming the user Timo, and the server's home."""
    out = tmp_path / "Meetings"
    _meeting(out)
    api.name_speaker(out, MEETING, "SPEAKER_00", "Rico")
    api.set_meeting_project(out, MEETING, name="Hiring")
    config = tmp_path / "config.toml"
    config.write_text(f'[user]\nname = "Timo"\n[recording]\noutput_dir = {json.dumps(str(out))}\n[calendar]\nenabled = false\n')
    return out, config, tmp_path / "home"


CALLS = [
    ("list_meetings", {}),
    ("search_meetings", {"query": "salary", "person": "Rico"}),
    ("get_meeting", {"meeting_id": MEETING, "include_transcript": True}),
    ("list_projects", {}),
    ("get_project", {"project": "hiring"}),
    ("list_people", {}),
    ("open_next_steps", {"owner": "speaker 2"}),
]


def test_the_python_sdk_client_gets_the_python_servers_tools_and_answers(tmp_path, monkeypatch):
    from mcp import ClientSession, StdioServerParameters, stdio_client
    from mcp.types import Implementation

    out, config, home = _recordings(tmp_path)
    support = home / "Library" / "Application Support" / "palaver"
    monkeypatch.setattr(mcp_access, "LOG_PATH", support / "mcp-access.jsonl")  # where the Swift server writes them
    monkeypatch.setattr(mcp_access, "PROCESS_DIR", support / "mcp")
    python_server = mcp_server.build_server(out, "Timo")
    python_tools = {t.name: t for t in asyncio.run(python_server.list_tools())}
    meetings = mcp_server.Meetings(out, "Timo")
    expected = {name: getattr(meetings, name)(**args) for name, args in CALLS}

    params = StdioServerParameters(command=str(CLI), args=["--config", str(config), "mcp"], env={
        "HOME": str(home), "PALAVER_HOME": str(home), "XDG_CONFIG_HOME": os.environ["XDG_CONFIG_HOME"],
        "PATH": "/usr/bin:/bin"})
    seen: dict = {}

    async def talk():
        async with stdio_client(params) as (read, write):
            async with ClientSession(read, write, client_info=Implementation(name="pytest-client", version="9.1")) as s:
                hello = await s.initialize()
                seen["hello"] = hello
                seen["tools"] = (await s.list_tools()).tools
                seen["answers"] = {name: await s.call_tool(name, args) for name, args in CALLS}
                seen["missing"] = await s.call_tool("get_project", {"project": "Nope"})
                seen["clients"] = mcp_access.clients()  # while it runs: its heartbeat

    asyncio.run(asyncio.wait_for(talk(), 60))

    hello = seen["hello"]
    assert hello.server_info.name == "meetings" and hello.instructions == mcp_server.INSTRUCTIONS
    assert {t.name for t in seen["tools"]} == set(python_tools)
    for tool in seen["tools"]:  # the parameters, defaults and descriptions Claude reads
        python = python_tools[tool.name]
        assert tool.input_schema == python.input_schema, tool.name
        assert tool.output_schema == python.output_schema, tool.name
        assert tool.description == python.description, tool.name
    for name, args in CALLS:
        answer = seen["answers"][name]
        assert not answer.is_error, (name, answer)
        want = expected[name]
        got = answer.structured_content
        assert (got["result"] if isinstance(want, list) else got) == json.loads(json.dumps(want)), name
        assert want, name  # the fixture answers something for every tool
    assert seen["missing"].is_error
    assert "no project 'Nope'; list_projects shows them" in seen["missing"].content[0].text

    [client] = seen["clients"]
    assert client["client"] == {"name": "pytest-client", "version": "9.1"} and client["calls"] == len(CALLS) + 1
    log = mcp_access.read()
    assert [e["tool"] for e in log] == ["get_project"] + [name for name, _ in reversed(CALLS)]
    assert log[0]["error"] == "no project 'Nope'; list_projects shows them"
    get = next(e for e in log if e["tool"] == "get_meeting")
    assert get["args"] == {"meeting_id": MEETING, "include_transcript": True} and get["meetings"] == [MEETING]
    assert get["out"]["lines"] == 3 and get["out"]["chars"] > 0 and get["client"] == {"name": "pytest-client", "version": "9.1"}
    assert [e["tool"] for e in mcp_access.read(meeting=MEETING)] == ["open_next_steps", "get_project", "get_meeting",
                                                                     "search_meetings", "list_meetings"]
    deadline = time.monotonic() + 5  # the client closed stdin: the heartbeat goes with the server
    while mcp_access.clients() and time.monotonic() < deadline:
        time.sleep(0.05)
    assert mcp_access.clients() == []
