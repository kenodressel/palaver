"""Tests for the MCP server's tools (#35)."""

import asyncio
import json
from pathlib import Path

from palaver import mcp_server
from palaver.webapp import api

from .test_webapp import MEETING, _meeting


def test_tools_answer_from_the_same_data_as_the_window(tmp_path: Path):
    paths = _meeting(tmp_path)
    paths.notes.write_text(json.dumps({**json.loads(paths.notes.read_text()), "summary": "SPEAKER_00 ran it."}))
    api.name_speaker(tmp_path, MEETING, "SPEAKER_00", "Rico")
    api.set_meeting_project(tmp_path, MEETING, name="Hiring")
    m = mcp_server.Meetings(tmp_path, "Timo")

    [brief] = m.list_meetings(project="hiring")
    assert brief["id"] == MEETING and brief["projects"] == ["Hiring"] and brief["summary"] == "SPEAKER_00 ran it."
    assert m.list_meetings(person="rico")[0]["id"] == MEETING
    assert m.list_meetings(since="2026-11-01") == []

    [hit] = m.search_meetings("salary")["meetings"]
    assert hit["lines"] == ["[0:13] Speaker 2: Thanks Rico, the salary band is fine."]
    assert hit["matched_by"] == "words"

    meeting = m.get_meeting(MEETING)
    assert meeting["notes"]["summary"] == "Rico ran it." and "transcript" not in meeting
    part = m.get_meeting(MEETING, from_minute=0, to_minute=0.01)  # the first 0.6 s
    assert part["transcript"] == ["[0:00] Timo: Hi Rico welcome."]

    [project] = m.list_projects()
    assert project["name"] == "Hiring" and project["meetings"] == 1
    assert m.get_project("Hiring")["next_steps"] == [
        {"meeting": MEETING, "title": "Hiring debrief", "start": "2026-10-27T16:03:07+01:00",
         "owner": "Speaker 2", "task": "Send the offer"}]
    assert m.open_next_steps(owner="rico") == []
    assert m.list_people()[0]["name"] == "Rico"


def test_the_server_lists_its_tools(tmp_path: Path):
    server = mcp_server.build_server(tmp_path, "Timo")
    names = {t.name for t in asyncio.run(server.list_tools())}
    assert names == {"list_meetings", "search_meetings", "get_meeting", "list_projects", "get_project",
                     "list_people", "open_next_steps"}


def test_install_adds_the_server_to_claude_code():
    assert mcp_server.install_command("/venv/bin/python", None) == [
        "claude", "mcp", "add", "--scope", "user", "meetings", "--", "/venv/bin/python", "-m", "palaver",
        "mcp"]


def test_search_reads_the_query_like_the_window(tmp_path: Path, monkeypatch):
    from palaver import semantic

    _meeting(tmp_path)
    api.name_speaker(tmp_path, MEETING, "SPEAKER_00", "Rico")
    api.set_meeting_project(tmp_path, MEETING, name="Hiring")
    m = mcp_server.Meetings(tmp_path, "Timo")

    found = m.search_meetings("what did we decide about the offer")
    assert found["understood"] == ["In decisions"]
    [hit] = found["meetings"]
    assert hit["notes"] == ["Decision: Make an offer"] and hit["lines"] == []
    assert m.search_meetings("offer", person="Rico", project="Hiring", since="2026-10-01")["meetings"]
    assert m.search_meetings("offer", person="Nobody")["meetings"] == []
    assert m.search_meetings("offer", until="2026-10-01")["meetings"] == []
    found = m.search_meetings("salary", organization="ACB")
    assert found["understood"] == ["ACB"] and found["meetings"] == []

    monkeypatch.setattr(semantic, "enabled", lambda: True)
    monkeypatch.setattr(api, "search_meaning", lambda output_dir, q, **kw: [
        {**api.list_meetings(tmp_path)[0], "meaning": [
            {"kind": "line", "speaker": "Rico", "start": 1.0, "text": "Welcome to the debrief.", "score": 0.83},
            {"kind": "decision", "text": "Make an offer", "score": 0.81}]}])
    [hit] = m.search_meetings("Gehalt")["meetings"]  # no word matches; by meaning
    assert hit["matched_by"] == "meaning"
    assert hit["lines"] == ["[0:01] Rico: Welcome to the debrief."] and hit["notes"] == ["Decision: Make an offer"]


def test_search_parameters_cannot_break_out_of_their_filter(tmp_path: Path):
    import pytest

    _meeting(tmp_path)
    api.name_speaker(tmp_path, MEETING, "SPEAKER_00", "Rico")
    m = mcp_server.Meetings(tmp_path, "Timo")
    found = m.search_meetings("salary", person='Rico" is:reviewed "x')
    assert found["understood"] == ['Rico is:reviewed x']  # one odd name, not a second filter
    found = m.search_meetings("salary", organization='"ACB"')
    assert found["understood"] == ["ACB"] and found["meetings"] == []
    assert m.search_meetings("salary", organization='"')["understood"] == []  # nothing left: no filter
    with pytest.raises(ValueError, match="since"):
        m.search_meetings("salary", since="last tuesday-ish")
    with pytest.raises(ValueError, match="until"):
        m.search_meetings("salary", until="2026-13-45")
    assert m.search_meetings("salary", since="2026-10-01", until="2026-10-31")["meetings"]


# --- meetings kept on this Mac (#53): not shared with Claude either -------------------

PRIVATE = "2026-10-26T09-00-00"
SECRET_WORDS = ("Confidential", "merger", "Mara")


def _with_a_private_meeting(tmp_path: Path) -> mcp_server.Meetings:
    _meeting(tmp_path)
    p = _meeting(tmp_path, PRIVATE)
    p.notes.write_text(json.dumps({**json.loads(p.notes.read_text()), "title": "Confidential merger",
                                   "summary": "Confidential merger talks.",
                                   "next_steps": [{"owner": "Mara Hidden", "task": "Sign the merger"}]}))
    api.name_speaker(tmp_path, PRIVATE, "SPEAKER_01", "Mara Hidden")
    api.set_meeting_project(tmp_path, MEETING, name="Hiring")
    api.set_meeting_project(tmp_path, PRIVATE, name="Hiring")
    api.set_meeting_project(tmp_path, PRIVATE, name="Secret deal")  # only the private meeting
    api.set_local_only(tmp_path, PRIVATE, True)
    return mcp_server.Meetings(tmp_path, "Timo")


def _no_secrets(answer):
    text = json.dumps(answer, ensure_ascii=False)
    assert not any(w in text for w in SECRET_WORDS), text
    assert PRIVATE not in text, text


def test_lists_and_search_leave_out_meetings_kept_on_this_mac(tmp_path: Path):
    m = _with_a_private_meeting(tmp_path)
    assert [x["id"] for x in m.list_meetings()] == [MEETING]
    assert [x["id"] for x in m.list_meetings(project="Hiring")] == [MEETING]
    assert [x["id"] for x in m.search_meetings("salary")["meetings"]] == [MEETING]  # both transcripts say it
    assert m.search_meetings("Confidential")["meetings"] == []
    for answer in (m.list_meetings(), m.search_meetings("salary"), m.search_meetings("merger"),
                   m.search_meetings("Mara"), m.search_meetings("secret deal")):
        _no_secrets(answer)  # not even as a name or project the query was read as


def test_search_by_meaning_leaves_out_meetings_kept_on_this_mac(tmp_path: Path, monkeypatch):
    m = _with_a_private_meeting(tmp_path)
    asked = []

    def meaning(output_dir, q, *, user_name, exclude=frozenset(), **kw):
        asked.append(set(exclude))
        return [{**e, "meaning": [{"kind": "decision", "text": "Confidential merger", "score": 0.9}]}
                for e in api.list_meetings(tmp_path) if e["id"] not in exclude]

    monkeypatch.setattr(api, "search_meaning", meaning)
    found = m.search_meetings("Übernahme")
    assert asked == [{PRIVATE}]  # not even searched
    assert [x["id"] for x in found["meetings"]] == [MEETING]
    monkeypatch.setattr(api, "search_meaning", lambda output_dir, q, **kw: [
        {**e, "meaning": [{"kind": "summary", "text": "x", "score": 0.9}]} for e in api.list_meetings(tmp_path)])
    assert [x["id"] for x in m.search_meetings("Übernahme")["meetings"]] == [MEETING]  # and dropped if it came


def test_the_window_still_finds_meetings_kept_on_this_mac(tmp_path: Path):
    _with_a_private_meeting(tmp_path)
    assert {r["id"] for r in api.search(tmp_path, "salary", user_name="Timo")} == {MEETING, PRIVATE}


def test_get_meeting_says_it_is_kept_on_this_mac(tmp_path: Path):
    m = _with_a_private_meeting(tmp_path)
    expected = {"id": PRIVATE, "kept_on_this_mac": True,
                "message": "This meeting is kept on this Mac; it is not shared with Claude."}
    assert m.get_meeting(PRIVATE) == expected
    assert m.get_meeting(PRIVATE, include_transcript=True) == expected
    assert m.get_meeting(PRIVATE, from_minute=0, to_minute=5) == expected


def test_projects_people_and_next_steps_leave_them_out(tmp_path: Path):
    m = _with_a_private_meeting(tmp_path)
    projects = m.list_projects()
    assert [p["name"] for p in projects] == ["Hiring"]  # "Secret deal" has only the private meeting
    assert projects[0]["meetings"] == 1
    hiring = m.get_project("Hiring")
    assert [x["id"] for x in hiring["meetings"]] == [MEETING]
    assert {s["meeting"] for s in hiring["next_steps"]} == {MEETING}
    # A project of private meetings only answers like one that doesn't exist.
    for name in ("Secret deal", "No such project"):
        try:
            m.get_project(name)
        except ValueError as exc:
            assert str(exc) == f"no project {name!r}; list_projects shows them"
        else:
            raise AssertionError(f"{name} was shown")
    try:
        m.list_meetings(project="Secret deal")
    except ValueError:
        pass
    else:
        raise AssertionError("filtering by a hidden project told it exists")
    assert {s["meeting"] for s in m.open_next_steps()} == {MEETING}
    assert m.open_next_steps(owner="Mara") == []
    assert "Mara Hidden" not in [p["name"] for p in m.list_people()]
    for answer in (projects, hiring, m.open_next_steps(), m.list_people()):
        _no_secrets(answer)


def test_the_served_tools_keep_them_out_too(tmp_path: Path):
    _with_a_private_meeting(tmp_path)
    server = mcp_server.build_server(tmp_path, "Timo")

    async def call(name, args):
        return await server.call_tool(name, args)

    answer = asyncio.run(call("get_meeting", {"meeting_id": PRIVATE, "include_transcript": True}))
    text = json.dumps(answer, default=str)
    assert "kept on this Mac" in text and "salary" not in text and "Confidential" not in text


def test_get_meeting_has_the_users_own_notes_unless_kept_on_this_mac(tmp_path: Path):
    from palaver import my_notes

    m = _with_a_private_meeting(tmp_path)
    my_notes.save(tmp_path / MEETING, [{"text": "Ask about the salary band", "at": None},
                                       {"text": "They said **yes**", "at": 14}])
    my_notes.save(tmp_path / PRIVATE, [{"text": "Confidential merger price", "at": 3}])
    assert m.get_meeting(MEETING)["my_notes"] == "Ask about the salary band\n[00:14] They said **yes**"
    private = m.get_meeting(PRIVATE)
    assert private["kept_on_this_mac"] and "my_notes" not in private and "merger price" not in json.dumps(private)
    _meeting(tmp_path, "2026-10-25T09-00-00")
    assert "my_notes" not in m.get_meeting("2026-10-25T09-00-00")


def test_get_meeting_keeps_which_decisions_came_from_the_users_notes(tmp_path: Path):
    paths = _meeting(tmp_path)
    paths.notes.write_text(json.dumps({**json.loads(paths.notes.read_text()), "decisions_mine": [0]}))
    assert mcp_server.Meetings(tmp_path, "Timo").get_meeting(MEETING)["notes"]["decisions_mine"] == [0]


def test_a_meeting_is_called_what_the_user_renamed_it_to(tmp_path: Path):
    _meeting(tmp_path)
    m = mcp_server.Meetings(tmp_path, "Timo")
    api.set_title(tmp_path, MEETING, "Offer for Rico")
    assert m.list_meetings()[0]["title"] == "Offer for Rico"
    assert m.get_meeting(MEETING)["title"] == "Offer for Rico"
    assert m.search_meetings("salary")["meetings"][0]["title"] == "Offer for Rico"


def test_a_meeting_without_any_title_is_called_by_its_time(tmp_path: Path):
    from palaver import titles

    paths = _meeting(tmp_path)
    paths.notes.unlink()
    m = mcp_server.Meetings(tmp_path, "Timo")
    expected = titles.fallback("2026-10-27T16:03:07+01:00")
    assert m.list_meetings()[0]["title"] == expected and m.get_meeting(MEETING)["title"] == expected
