"""Tests for Notion API client (HTTP mocked)."""

import json
from datetime import datetime

from palaver.models import Utterance
from palaver.notion_client import (
    NotionClient,
    utterances_to_blocks,
)


def test_utterances_to_blocks_formats_one_block_per_utterance():
    utterances = [
        Utterance("Timo", 0.0, 2.0, "hallo"),
        Utterance("SPEAKER_00", 2.5, 4.0, "hi back"),
    ]
    blocks = utterances_to_blocks(
        utterances, session_start=datetime(2026, 4, 17, 14, 30)
    )
    assert len(blocks) == 2
    first = blocks[0]
    assert first["type"] == "paragraph"
    rich = first["paragraph"]["rich_text"]
    # speaker name is bold
    assert rich[0]["text"]["content"] == "Timo"
    assert rich[0]["annotations"] == {"bold": True}
    # timestamp block
    assert "[14:30:00]" in rich[1]["text"]["content"]
    # utterance text
    assert rich[2]["text"]["content"] == "  hallo"


def test_create_page_chunks_blocks_over_100(mocker):
    session = mocker.Mock()
    resp_post = mocker.Mock(status_code=200, json=lambda: {"id": "page-id", "url": "https://notion.so/x"})
    resp_patch = mocker.Mock(status_code=200, json=lambda: {})
    session.post.return_value = resp_post
    session.patch.return_value = resp_patch

    client = NotionClient(token="ntn_test", session=session)
    blocks = [
        {"object": "block", "type": "paragraph", "paragraph": {"rich_text": []}}
        for _ in range(250)
    ]

    url = client.create_page(parent_page_id="parent-xyz", title="test", blocks=blocks)
    assert url == "https://notion.so/x"

    # First POST contains 100 blocks; two PATCHes follow with 100 + 50.
    post_payload = session.post.call_args.kwargs["json"]
    assert len(post_payload["children"]) == 100

    patch_calls = session.patch.call_args_list
    assert len(patch_calls) == 2
    assert len(patch_calls[0].kwargs["json"]["children"]) == 100
    assert len(patch_calls[1].kwargs["json"]["children"]) == 50


def test_create_page_raises_on_post_error(mocker):
    session = mocker.Mock()
    session.post.return_value = mocker.Mock(
        status_code=400, text='{"message": "bad"}'
    )
    client = NotionClient(token="ntn_test", session=session)
    import pytest

    with pytest.raises(RuntimeError, match="Notion create_page failed"):
        client.create_page(parent_page_id="x", title="t", blocks=[])


def _resp(mocker, status, body=None, headers=None):
    return mocker.Mock(
        status_code=status,
        json=lambda: body or {},
        text=str(body),
        headers=headers or {},
    )


def test_create_page_retries_rate_limit_and_honours_retry_after(mocker):
    session = mocker.Mock()
    session.post.side_effect = [
        _resp(mocker, 429, headers={"Retry-After": "3"}),
        _resp(mocker, 503),
        _resp(mocker, 200, {"id": "p", "url": "https://notion.so/p"}),
    ]
    sleeps: list[float] = []
    client = NotionClient(token="t", session=session, sleep=sleeps.append)

    assert client.create_page(parent_page_id="x", title="t", blocks=[]) == "https://notion.so/p"
    assert session.post.call_count == 3
    assert sleeps[0] == 3.0
    assert 1.0 <= sleeps[1] < 1.5
    assert session.post.call_args.kwargs["timeout"] == 30


def _never_connected():
    import requests
    from urllib3.exceptions import MaxRetryError, NewConnectionError

    reason = NewConnectionError(None, "Failed to establish a new connection: [Errno 61]")
    return requests.ConnectionError(MaxRetryError(None, "/v1/pages", reason=reason))


def test_create_page_retries_when_the_request_never_left(mocker):
    import requests

    session = mocker.Mock()
    session.post.side_effect = [
        _never_connected(),
        requests.exceptions.ConnectTimeout("connect timed out"),
        _resp(mocker, 200, {"id": "p", "url": "u"}),
    ]
    client = NotionClient(token="t", session=session, sleep=lambda _s: None)
    assert client.create_page(parent_page_id="x", title="t", blocks=[]) == "u"


def test_create_page_does_not_retry_a_connection_dropped_after_sending(mocker):
    """Notion may have created the page before the connection dropped."""
    from http.client import RemoteDisconnected

    import pytest
    import requests
    from urllib3.exceptions import ProtocolError

    session = mocker.Mock()
    session.post.side_effect = requests.ConnectionError(
        ProtocolError("Connection aborted.", RemoteDisconnected("closed"))
    )
    client = NotionClient(token="t", session=session, sleep=lambda _s: None)
    with pytest.raises(requests.ConnectionError):
        client.create_page(parent_page_id="x", title="t", blocks=[])
    assert session.post.call_count == 1


def test_create_page_does_not_retry_errors_that_may_have_been_applied(mocker):
    """A 500 or a timeout may mean Notion created the page anyway; retrying
    would duplicate it."""
    import pytest

    session = mocker.Mock()
    session.post.return_value = _resp(mocker, 500, {"message": "oops"})
    client = NotionClient(token="t", session=session, sleep=lambda _s: None)
    with pytest.raises(RuntimeError, match="500"):
        client.create_page(parent_page_id="x", title="t", blocks=[])
    assert session.post.call_count == 1


def test_create_page_gives_up_after_retries(mocker):
    import pytest

    session = mocker.Mock()
    session.post.return_value = _resp(mocker, 429)
    client = NotionClient(token="t", session=session, sleep=lambda _s: None)
    with pytest.raises(RuntimeError, match="429"):
        client.create_page(parent_page_id="x", title="t", blocks=[])
    assert session.post.call_count == 4


SCHEMA = {
    "properties": {
        "Name": {"id": "title", "type": "title"},
        "Date": {"id": "d", "type": "date"},
        "Duration (min)": {"id": "m", "type": "number"},
        "Speakers": {"id": "s", "type": "number"},
        "Source": {"id": "src", "type": "select"},
        "Notes": {"id": "n", "type": "rich_text"},
    }
}


def test_database_properties_map_to_existing_schema():
    from palaver.notion_client import database_properties

    props = database_properties(
        SCHEMA,
        title="2026-10-20 14:35 — Meeting (24 min, 4 speakers)",
        start=datetime(2026, 10, 20, 14, 35, 17),
        duration_minutes=24.1,
        n_speakers=4,
        source="Teams",
    )
    assert props == {
        "Name": {"title": [{"text": {"content": "2026-10-20 14:35 — Meeting (24 min, 4 speakers)"}}]},
        "Date": {"date": {"start": "2026-10-20T14:35:17"}},
        "Duration (min)": {"number": 24.1},
        "Speakers": {"number": 4},
        "Source": {"select": {"name": "Teams"}},
    }


def test_database_properties_skip_missing_or_mistyped_columns():
    from palaver.notion_client import database_properties

    schema = {"properties": {"Titel": {"type": "title"}, "Duration": {"type": "rich_text"}}}
    props = database_properties(
        schema, title="t", start=datetime(2026, 1, 1), duration_minutes=1.0, n_speakers=1, source="Teams"
    )
    assert props == {"Titel": {"title": [{"text": {"content": "t"}}]}}


def test_create_database_page_reads_schema_and_posts_into_database(mocker):
    session = mocker.Mock()
    session.get.return_value = _resp(mocker, 200, SCHEMA)
    session.post.return_value = _resp(mocker, 200, {"id": "p", "url": "https://notion.so/p"})
    client = NotionClient(token="t", session=session, sleep=lambda _s: None)

    url = client.create_database_page(
        database_id="db-1",
        title="T",
        blocks=[{"object": "block"}],
        start=datetime(2026, 10, 20, 14, 35),
        duration_minutes=24.0,
        n_speakers=4,
        source="Teams",
    )

    assert url == "https://notion.so/p"
    assert session.get.call_args.args[0].endswith("/databases/db-1")
    payload = session.post.call_args.kwargs["json"]
    assert payload["parent"] == {"database_id": "db-1"}
    assert payload["properties"]["Name"]["title"][0]["text"]["content"] == "T"
    assert payload["properties"]["Speakers"] == {"number": 4}
    assert payload["children"] == [{"object": "block"}]


def test_sync_reports_how_the_meeting_was_recorded(tmp_path, monkeypatch):
    import argparse

    from palaver import cli
    from palaver.paths import RecordingPaths

    from .test_cli import _FakeCfg

    paths = RecordingPaths(tmp_path)
    paths.transcript_json.write_text("[]")
    paths.meta.write_text(json.dumps({"start_time": "2026-10-20T14:35:17+02:00",
                                      "duration_seconds": 60, "trigger": "manual"}))
    cfg = _FakeCfg()
    cfg.notion_mode, cfg.notion_database_id = "database", "db"
    monkeypatch.setattr(cli, "_load_cfg", lambda _a: cfg)
    seen = {}
    monkeypatch.setattr(
        "palaver.notion_client.NotionClient.create_database_page",
        lambda self, **kw: seen.update(kw) or "u",
    )
    assert cli._cmd_sync(argparse.Namespace(folder=str(tmp_path), config=None, dictionary=None)) == 0
    assert seen["source"] == "Manual recording"
