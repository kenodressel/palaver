"""Tests for projects: meetings grouped by customer or topic (issue #29)."""

import json
from pathlib import Path

import pytest

from palaver import calendar_events as cal
from palaver import projects as P
from palaver.paths import RecordingPaths


def _meeting(root: Path, name: str, title: str, *people: str, domain: str = "kloud.io",
             summary: str = "") -> RecordingPaths:
    paths = RecordingPaths(root / name)
    paths.folder.mkdir(parents=True)
    paths.meta.write_text(json.dumps({"start_time": "2026-10-27T10:00:00+01:00", "duration_seconds": 600}))
    paths.transcript_json.write_text("[]")
    attendees = [cal.Attendee("Timo Strauss", "timo@kloud.io", is_self=True)] + [
        cal.Attendee(p, f"{p.split()[0].lower()}@{domain}") for p in people]
    cal.save(paths, cal.Event(title, cal.datetime.fromisoformat("2026-10-27T10:00:00+01:00"),
                              cal.datetime.fromisoformat("2026-10-27T10:30:00+01:00"), tuple(attendees)))
    if summary:
        paths.notes.write_text(json.dumps({"title": title, "summary": summary}))
    return paths


@pytest.fixture
def store(tmp_path: Path) -> P.ProjectStore:
    return P.ProjectStore(tmp_path / "projects.json")


def test_store_keeps_projects_and_n_to_m_assignments(store, tmp_path):
    factory = store.create("Foundry", "Migration foundry for Contoso")
    hiring = store.create("Recruiting")
    assert store.create("foundry") == factory  # same name, same project
    store.assign("m1", factory)
    store.assign("m1", hiring)  # a 1:1 about two topics
    store.save()

    again = P.ProjectStore(tmp_path / "projects.json")
    assert set(again.of_meeting("m1")) == {factory, hiring}
    assert again.projects()[factory]["description"] == "Migration foundry for Contoso"
    with pytest.raises(ValueError):
        again.update(hiring, name="Foundry")


def test_removing_a_meeting_is_final_for_rules_and_model(store):
    pid = store.create("Foundry")
    assert store.assign("m1", pid, by="auto", why="title")
    store.unassign("m1", pid)
    assert not store.assign("m1", pid, by="model")
    assert not store.of_meeting("m1")
    assert store.assign("m1", pid)  # the user may change their mind
    assert store.rejected("m1") == []


def test_weaker_deciders_never_override_stronger_ones(store):
    pid = store.create("Foundry")
    store.assign("m1", pid, by="you")
    assert not store.assign("m1", pid, by="auto", why="title")
    assert store.of_meeting("m1")[pid]["by"] == "you"


def test_merging_projects_moves_their_meetings(store):
    a, b = store.create("Foundry", "Contoso migration"), store.create("Migration Foundry")
    store.assign("m1", a, by="auto", why="title")
    store.assign("m2", a)
    store.assign("m2", b, by="model")
    store.unassign("m3", a)
    store.merge(a, into=b)

    assert set(store.projects()) == {b}
    assert store.of_meeting("m1") == {b: {"by": "auto", "why": "title"}}
    assert store.of_meeting("m2")[b]["by"] == "you"  # the stronger one survives
    assert store.projects()[b]["description"] == "Contoso migration"  # it had none
    assert store.rejected("m3") == []
    with pytest.raises(ValueError):
        store.merge(b, into=b)


def test_deleting_a_project_frees_its_meetings(store):
    pid = store.create("Foundry")
    store.assign("m1", pid)
    store.delete(pid)
    assert store.of_meeting("m1") == {} and store.projects() == {}


def test_rules_place_meetings_like_the_ones_already_in_a_project(store, tmp_path):
    _meeting(tmp_path, "2026-10-20T10-00-00", "Foundry Sync", "Jannik Kessler")
    _meeting(tmp_path, "2026-10-21T10-00-00", "Foundry Sync", "Jannik Kessler")  # the series again
    _meeting(tmp_path, "2026-10-22T10-00-00", "Lunch", "Anna Huber")
    _meeting(tmp_path, "2026-10-23T10-00-00", "Recruiting Sync", "Leila Rahmani")
    pid = store.create("Foundry")
    store.assign("2026-10-20T10-00-00", pid)

    added = P.assign_by_rules(tmp_path, store, user_name="Timo")
    assert added == [("2026-10-21T10-00-00", pid)]
    assert store.of_meeting("2026-10-21T10-00-00")[pid]["by"] == "auto"
    assert "Foundry Sync" in store.of_meeting("2026-10-21T10-00-00")[pid]["why"]


def test_a_customer_domain_and_people_count(tmp_path):
    a = P.facts(_meeting(tmp_path, "2026-10-20T10-00-00", "Spain migration", "Karel Kralek", domain="contoso.es"),
                user_name="Timo")
    b = P.facts(_meeting(tmp_path, "2026-10-21T10-00-00", "Verticalization", "Karel Kralek", domain="contoso.com"),
                user_name="Timo")
    assert a.orgs == {"contoso"} and "timo strauss" not in a.people
    score, why = P.Similarity({a.meeting: a, b.meeting: b})(a, b)
    assert score >= P.ASSIGN_SCORE and why == "people"


def test_suggestions_skip_taken_and_rejected_projects(store, tmp_path):
    _meeting(tmp_path, "2026-10-20T10-00-00", "Foundry Sync", "Jannik Kessler")
    _meeting(tmp_path, "2026-10-21T10-00-00", "Foundry Review", "Jannik Kessler", "Lasse Brandt")
    pid = store.create("Foundry")
    store.assign("2026-10-20T10-00-00", pid)
    every = P.all_facts(tmp_path, user_name="Timo")
    [s] = P.suggestions("2026-10-21T10-00-00", store, every)
    assert s["id"] == pid and s["name"] == "Foundry"
    store.unassign("2026-10-21T10-00-00", pid)
    assert P.suggestions("2026-10-21T10-00-00", store, every) == []


def test_the_model_places_meetings_and_creates_projects(store, tmp_path):
    _meeting(tmp_path, "2026-10-20T10-00-00", "Kurzsync RTV", "Konrad Lenz", summary="RTV archive search.")
    _meeting(tmp_path, "2026-10-21T10-00-00", "Champion Checkin", "Sebastian Steinbauer")
    _meeting(tmp_path, "2026-10-22T10-00-00", "Foundry Sync", "Jannik Kessler")
    factory = store.create("Foundry")
    store.assign("2026-10-22T10-00-00", factory)
    seen = {}

    def run(prompt, schema):
        seen["prompt"] = prompt
        return {
            "new_projects": [{"key": "new1", "name": "RTV", "description": "Archive search for RTV."},
                             {"key": "new2", "name": "Unused", "description": "Nothing in it."}],
            "assignments": [{"meeting": "2026-10-20T10-00-00", "projects": ["new1"]},
                            {"meeting": "2026-10-21T10-00-00", "projects": [factory, "nonsense"]},
                            {"meeting": "2026-10-22T10-00-00", "projects": ["new1"]}],  # not asked
            "descriptions": [{"project": factory, "description": "The Contoso migration foundry."}],
        }

    store.save()  # the callers persist their changes themselves
    added = P.suggest_with_model(tmp_path, store, run, user_name="Timo")
    rtv = store.find("RTV")
    assert sorted(added) == [("2026-10-20T10-00-00", rtv), ("2026-10-21T10-00-00", factory)]
    assert store.find("Unused") is None  # proposed, but nothing in it
    assert store.projects()[rtv]["description"] == "Archive search for RTV."
    assert store.projects()[factory]["description"] == "The Contoso migration foundry."
    assert "RTV archive search." in seen["prompt"] and "2026-10-22T10-00-00" not in seen["prompt"].split(
        "Meetings to sort:")[1]


def test_the_model_never_rewrites_a_description_the_user_wrote(store, tmp_path):
    _meeting(tmp_path, "2026-10-20T10-00-00", "Kurzsync RTV", "Konrad Lenz")
    pid = store.create("RTV", "My words.")

    def run(prompt, schema):
        return {"new_projects": [], "assignments": [], "descriptions": [{"project": pid, "description": "Other."}]}

    store.save()  # the callers persist their changes themselves
    P.suggest_with_model(tmp_path, store, run, user_name="Timo")
    assert store.projects()[pid]["description"] == "My words."


def test_new_notes_sort_the_meeting_into_its_project(tmp_path):
    from palaver import cli

    _meeting(tmp_path, "2026-10-20T10-00-00", "Foundry Sync", "Jannik Kessler")
    new = _meeting(tmp_path, "2026-10-27T10-00-00", "Foundry Sync", "Jannik Kessler")
    store = P.ProjectStore()
    pid = store.create("Migration Foundry")
    store.assign("2026-10-20T10-00-00", pid)
    store.save()
    cfg = type("Cfg", (), {"user_name": "Timo", "notes_engine": "local", "notes_local_model": "repo/x"})()

    cli._sort_into_projects(cfg, new)  # rules suffice: the model (none in tests) is not asked
    assert P.ProjectStore().of_meeting("2026-10-27T10-00-00")[pid]["by"] == "auto"


def test_sorting_into_projects_never_fails_the_notes(tmp_path, capsys):
    from palaver import cli

    new = _meeting(tmp_path, "2026-10-27T10-00-00", "Kurzsync RTV", "Konrad Lenz")
    cfg = type("Cfg", (), {"user_name": "Timo", "notes_engine": "local", "notes_local_model": "repo/x"})()
    cli._sort_into_projects(cfg, new)  # the test model raises
    assert "sorting into projects failed" in capsys.readouterr().out


def test_meetings_kept_private_are_never_in_the_prompt(store, tmp_path):
    _meeting(tmp_path, "2026-10-20T10-00-00", "Kurzsync RTV", "Konrad Lenz", summary="RTV archive search.")
    _meeting(tmp_path, "2026-10-21T10-00-00", "Secret merger", "Mara Hidden", summary="Confidential deal.")
    _meeting(tmp_path, "2026-10-22T10-00-00", "Secret follow-up", "Mara Hidden", summary="More of the deal.")
    pid = store.create("Deal")
    store.assign("2026-10-22T10-00-00", pid)
    prompts = []

    def run(prompt, schema):
        prompts.append(prompt)
        return {"new_projects": [], "assignments": [], "descriptions": []}

    private = {"2026-10-21T10-00-00", "2026-10-22T10-00-00"}
    store.save()  # the callers persist their changes themselves
    P.suggest_with_model(tmp_path, store, run, user_name="Timo", private=private)
    assert "Kurzsync RTV" in prompts[0]
    # The project's name may show; its private meetings, their people and summaries don't.
    assert not any(w in prompts[0] for w in ("Secret", "Mara", "Confidential", "More of the deal"))
    # Only private meetings: nothing to send, nothing asked.
    assert P.describe_with_model(tmp_path, store, pid, run, user_name="Timo", private=private) == ""
    assert P.suggest_with_model(tmp_path, store, run, user_name="Timo",
                                meetings=["2026-10-21T10-00-00"], private=private) == []
    assert len(prompts) == 1
    store.assign("2026-10-20T10-00-00", pid)
    P.describe_with_model(tmp_path, store, pid, run, user_name="Timo", private=private)
    assert "Kurzsync RTV" in prompts[1] and "Secret" not in prompts[1] and "Confidential" not in prompts[1]


def test_a_cloud_model_sorts_without_the_meetings_kept_on_this_mac(tmp_path, monkeypatch):
    from palaver import cli, cloud_llm, keychain, llm, providers

    _meeting(tmp_path, "2026-10-20T10-00-00", "Kurzsync RTV", "Konrad Lenz", summary="RTV archive search.")
    secret = _meeting(tmp_path, "2026-10-21T10-00-00", "Secret merger", "Mara Hidden", summary="Confidential.")
    llm.set_local_only(secret.folder, True)
    keychain.set(providers.key_account("anthropic"), "sk-ant-test-key-0123456789")
    providers.choose("projects", "anthropic")
    sent = []

    def transport(request):
        sent.append(json.loads(request.body)["messages"][0]["content"])
        return cloud_llm.Response(200, {}, json.dumps({"content": [{"type": "text", "text": json.dumps(
            {"new_projects": [], "assignments": []})}], "stop_reason": "end_turn"}).encode())

    monkeypatch.setattr(cloud_llm, "default_transport", transport)
    cfg = type("Cfg", (), {"user_name": "Timo", "notes_engine": "local", "notes_local_model": "repo/x",
                           "output_dir": tmp_path})()
    args = type("Args", (), {"action": "suggest", "target": None, "no_wait": False})()
    assert cli._projects_with_model(cfg, args) == 0
    assert len(sent) == 1 and "Kurzsync RTV" in sent[0] and "Secret" not in sent[0]

    sent.clear()
    cli._sort_into_projects(cfg, secret)  # its notes are new: the cloud is not asked about it
    assert sent == []


def test_a_project_of_private_meetings_only_is_never_shown_or_rewritten(store, tmp_path):
    _meeting(tmp_path, "2026-10-20T10-00-00", "Kurzsync RTV", "Konrad Lenz", summary="RTV archive search.")
    _meeting(tmp_path, "2026-10-21T10-00-00", "Secret merger", "Mara Hidden", summary="Confidential deal.")
    secret = store.create("Project Nightjar", "Merger with Acme, led by Mara.")
    store.assign("2026-10-21T10-00-00", secret)
    open_pid = store.create("RTV")
    prompts = []

    def run(prompt, schema):
        prompts.append(prompt)
        return {"new_projects": [],
                "assignments": [{"meeting": "2026-10-20T10-00-00", "projects": [secret]}],
                "descriptions": [{"project": secret, "description": "Rewritten by the cloud."}]}

    store.save()  # the callers persist their changes themselves
    P.suggest_with_model(tmp_path, store, run, user_name="Timo", private={"2026-10-21T10-00-00"})
    assert "Nightjar" not in prompts[0] and "Acme" not in prompts[0] and secret not in prompts[0]
    assert open_pid in prompts[0]
    assert store.projects()[secret]["description"] == "Merger with Acme, led by Mara."
    assert "2026-10-20T10-00-00" not in store.meetings_of(secret)  # nor filled by a guessed id


def test_an_earlier_name_of_the_user_is_no_participant(tmp_path):
    """#55: after a name change, the old name (an alias) is still the user."""
    from palaver import settings

    paths = _meeting(tmp_path, "2026-10-20T10-00-00", "Foundry Sync", "Jannik Kessler", "Timo")
    settings.update({"user_name": "Timo Strauß", "user_aliases": ["Timo"]})
    f = P.facts(paths, user_name="Timo Strauß")
    assert f.people == {"jannik kessler"}
    assert "timo" not in P._words("Timo Foundry", "Timo Strauß")
