"""What was sent where and when (palaver/access_log.py)."""

import json

from palaver import access_log


def test_record_and_read_back_newest_first():
    access_log.record(provider="anthropic", host="api.anthropic.com", model="claude-opus-5-5", feature="notes",
                      meetings=["2026-10-27T16-03-07"], chars=12_345, ok=True, seconds=12.34)
    access_log.record(provider="openai", host="acme.openai.azure.com", model="gpt-x", feature="projects",
                      meetings=["a", "b"], chars=900, ok=False, error="HTTP 503", seconds=3)
    entries = access_log.recent()
    assert [e["provider"] for e in entries] == ["openai", "anthropic"]
    first = entries[1]
    assert first["host"] == "api.anthropic.com" and first["feature"] == "notes"
    assert first["meetings"] == ["2026-10-27T16-03-07"] and first["chars"] == 12_345
    assert first["ok"] is True and first["seconds"] == 12.3 and "error" not in first
    assert first["time"]  # ISO time with the offset
    assert entries[0]["error"] == "HTTP 503"


def test_broken_lines_are_skipped_and_the_limit_holds():
    for i in range(5):
        access_log.record(provider="anthropic", host="h", model="m", feature="notes", meetings=[], chars=i,
                          ok=True, seconds=1)
    with access_log.path().open("a") as f:
        f.write("{broken\n")
    assert [e["chars"] for e in access_log.recent(limit=3)] == [4, 3, 2]


def test_the_log_keeps_every_entry():
    """Never trimmed while testing is internal (#59): a report gets all of it."""
    for i in range(25):
        access_log.record(provider="p", host="h", model="m", feature="notes", meetings=[], chars=i, ok=True,
                          seconds=0)
    lines = access_log.path().read_text().splitlines()
    assert [json.loads(line)["chars"] for line in lines] == list(range(25))


def test_no_log_reads_as_empty():
    assert access_log.recent() == []


def test_the_file_is_private():
    import stat

    for i in range(2):
        access_log.record(provider="p", host="h", model="m", feature="notes", meetings=[], chars=i, ok=True,
                          seconds=0)
    assert stat.S_IMODE(access_log.path().stat().st_mode) == 0o600
