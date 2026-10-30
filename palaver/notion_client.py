"""Notion REST client — create page, append blocks."""

from __future__ import annotations

import random
import time
from datetime import datetime, timedelta
from typing import Any, Callable

import requests

from .models import Utterance

NOTION_VERSION = "2022-06-28"
BASE_URL = "https://api.notion.com/v1"
MAX_BLOCKS_PER_REQUEST = 100
REQUEST_TIMEOUT_SECONDS = 30
RETRY_DELAYS_SECONDS = (0.5, 1.0, 2.0)
MAX_RETRY_AFTER_SECONDS = 30.0
# Only statuses where Notion most likely did NOT apply the request: retrying
# a 500 or a timed-out create/append could duplicate the page or its blocks.
_RETRYABLE_STATUSES = {429, 502, 503, 504}


def utterances_to_blocks(
    utterances: list[Utterance],
    session_start: datetime,
) -> list[dict[str, Any]]:
    blocks: list[dict[str, Any]] = []
    for u in utterances:
        when = session_start + timedelta(seconds=u.start)
        wall = when.strftime("%H:%M:%S")
        blocks.append(
            {
                "object": "block",
                "type": "paragraph",
                "paragraph": {
                    "rich_text": [
                        {
                            "type": "text",
                            "text": {"content": u.speaker},
                            "annotations": {"bold": True},
                        },
                        {
                            "type": "text",
                            "text": {"content": f" [{wall}]"},
                        },
                        {
                            "type": "text",
                            "text": {"content": f"  {u.text}"},
                        },
                    ]
                },
            }
        )
    return blocks


# Database columns are matched by type plus a name keyword, so any schema
# works without configuration; columns that don't exist are skipped.
_COLUMN_KEYWORDS = {
    "date": ("date", "datum", "when", "start"),
    "duration": ("duration", "dauer", "minutes", "length"),
    "speakers": ("speaker", "sprecher", "participant", "teilnehmer"),
    "source": ("source", "quelle", "platform", "tool"),
}


def _column(schema: dict, kind: str, prop_type: str) -> str | None:
    for name, prop in schema.get("properties", {}).items():
        if prop.get("type") == prop_type and any(
            k in name.lower() for k in _COLUMN_KEYWORDS[kind]
        ):
            return name
    return None


def database_properties(
    schema: dict,
    *,
    title: str,
    start: datetime,
    duration_minutes: float,
    n_speakers: int,
    source: str,
) -> dict[str, Any]:
    """Page properties for a database row, limited to the schema's columns."""
    props: dict[str, Any] = {}
    for name, prop in schema.get("properties", {}).items():
        if prop.get("type") == "title":
            props[name] = {"title": [{"text": {"content": title}}]}
    if (col := _column(schema, "date", "date")) is not None:
        props[col] = {"date": {"start": start.isoformat()}}
    if (col := _column(schema, "duration", "number")) is not None:
        props[col] = {"number": round(duration_minutes, 1)}
    if (col := _column(schema, "speakers", "number")) is not None:
        props[col] = {"number": n_speakers}
    if (col := _column(schema, "source", "select")) is not None:
        props[col] = {"select": {"name": source}}
    return props


def _never_sent(exc: requests.ConnectionError) -> bool:
    """True when the request provably never reached Notion (connect timeout,
    DNS failure, connection refused). A connection dropped after sending may
    already have created the page or appended the blocks."""
    from urllib3.exceptions import NewConnectionError

    if isinstance(exc, requests.exceptions.ConnectTimeout):
        return True
    reason = getattr(exc.args[0], "reason", None) if exc.args else None
    return isinstance(reason, NewConnectionError)


class NotionClient:
    def __init__(
        self,
        token: str,
        session: requests.Session | None = None,
        sleep: Callable[[float], None] = time.sleep,
    ):
        self._session = session or requests.Session()
        self._sleep = sleep
        self._headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Notion-Version": NOTION_VERSION,
        }

    def create_page(
        self,
        parent_page_id: str,
        title: str,
        blocks: list[dict[str, Any]],
    ) -> str:
        """Create a page; returns the page URL."""
        return self._create(
            {"page_id": parent_page_id},
            {"title": {"title": [{"text": {"content": title}}]}},
            blocks,
        )

    def create_database_page(
        self,
        database_id: str,
        title: str,
        blocks: list[dict[str, Any]],
        *,
        start: datetime,
        duration_minutes: float,
        n_speakers: int,
        source: str,
    ) -> str:
        """Create a row in a database, filling the columns its schema has."""
        resp = self._request("get", f"{BASE_URL}/databases/{database_id}")
        if resp.status_code != 200:
            raise RuntimeError(
                f"Notion database lookup failed: {resp.status_code} {resp.text}"
            )
        properties = database_properties(
            resp.json(),
            title=title,
            start=start,
            duration_minutes=duration_minutes,
            n_speakers=n_speakers,
            source=source,
        )
        return self._create({"database_id": database_id}, properties, blocks)

    def _create(
        self, parent: dict[str, str], properties: dict[str, Any], blocks: list[dict[str, Any]]
    ) -> str:
        payload = {
            "parent": parent,
            "properties": properties,
            "children": blocks[:MAX_BLOCKS_PER_REQUEST],
        }
        resp = self._request("post", f"{BASE_URL}/pages", json=payload)
        if resp.status_code != 200:
            raise RuntimeError(
                f"Notion create_page failed: {resp.status_code} {resp.text}"
            )
        page = resp.json()
        page_id = page["id"]
        url = page.get("url", "")

        remaining = blocks[MAX_BLOCKS_PER_REQUEST:]
        for i in range(0, len(remaining), MAX_BLOCKS_PER_REQUEST):
            batch = remaining[i : i + MAX_BLOCKS_PER_REQUEST]
            patch_resp = self._request(
                "patch", f"{BASE_URL}/blocks/{page_id}/children", json={"children": batch}
            )
            if patch_resp.status_code != 200:
                raise RuntimeError(
                    f"Notion append blocks failed: {patch_resp.status_code} {patch_resp.text}"
                )
        return url

    def _request(self, method: str, url: str, **kwargs) -> requests.Response:
        """Send with retries on rate limits, gateway errors and connections
        that never reached Notion (0.5 s, 1 s, 2 s backoff with jitter;
        Retry-After wins)."""
        send = getattr(self._session, method)
        for attempt in range(len(RETRY_DELAYS_SECONDS) + 1):
            last_try = attempt == len(RETRY_DELAYS_SECONDS)
            try:
                resp = send(url, headers=self._headers, timeout=REQUEST_TIMEOUT_SECONDS, **kwargs)
            except requests.ConnectionError as exc:
                if last_try or not _never_sent(exc):
                    raise
                self._sleep(self._backoff(attempt))
                continue
            if resp.status_code not in _RETRYABLE_STATUSES or last_try:
                return resp
            self._sleep(self._retry_after(resp) or self._backoff(attempt))
        raise AssertionError("unreachable")

    @staticmethod
    def _backoff(attempt: int) -> float:
        return RETRY_DELAYS_SECONDS[attempt] * (1 + random.uniform(0, 0.25))

    @staticmethod
    def _retry_after(resp: requests.Response) -> float | None:
        try:
            value = float(resp.headers.get("Retry-After", ""))
        except (TypeError, ValueError):
            return None
        return min(max(value, 0.0), MAX_RETRY_AFTER_SECONDS)
