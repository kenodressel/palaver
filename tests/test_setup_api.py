"""The setup assistant's API (#55): what the page shows, and the changes
it makes only when the user clicks. A fake Mac (tests/fake_probe.py):
nothing here looks at this Mac, downloads, records or plays a sound."""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

import pytest

from palaver import glossary, onboarding as ob, organizations, providers, settings
from palaver.calendar_events import Attendee, Event
from palaver.webapp import api
from palaver.webapp.server import App, make_server
from tests.fake_probe import FakeProbe

ME = Attendee("Timo Strauss", "timo@kloud.io", is_self=True)


def _calendar(start, end):
    at = datetime.now().astimezone() - timedelta(days=2)
    return [Event("Contoso Northwind Weekly", at, at + timedelta(hours=1),
                  (ME, Attendee("Stefan Dornbusch", "stefan@contoso.at"), Attendee("Anna Huber", "anna@kloud.io")))]


@pytest.fixture
def app(tmp_path: Path) -> App:
    out = tmp_path / "Recordings"
    out.mkdir()
    return App(out, "User", calendar=_calendar, probe=FakeProbe())


def wait_for(check, timeout=5.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        value = check()
        if value:
            return value
        time.sleep(0.02)
    raise AssertionError("timed out")


# --- what the page shows -------------------------------------------------------------------

def test_the_page_has_the_checks_and_the_recommendations(app):
    page = api.setup_page(app)
    assert page["hardware"]["chip"] == "Apple M4 Pro" and page["hardware"]["memory_gb"] == 48
    assert page["installed"] == {"teams": True, "slack": False, "claude_code": True, "claude_desktop": False}
    assert page["permissions"]["calendar"]["state"] == "not_asked"
    recs = {r["id"]: r for r in page["recommendations"]}
    assert recs["language_model"]["value"] == f"local:{ob.GEMMA}"
    assert recs["transcription"]["downloads"] == ["parakeet"]  # pyannote is already here
    assert page["offer"] == {"why": "first"}  # no meetings, never set up


def test_the_page_lists_the_downloads_with_their_sizes(app):
    d = api.setup_page(app)["downloads"]
    assert [m["id"] for m in d["needed"]] == ["parakeet", "gemma", "e5"]
    assert d["total_gb"] == pytest.approx(2.3 + 8.3 + 0.47)
    assert d["free_disk_gb"] == 120
    assert d["status"] == {"running": False, "models": []}  # nothing starts by itself


def test_the_profile_is_prefilled_from_macos_and_the_calendar(app):
    profile = api.setup_page(app)["profile"]
    assert profile["name"] == "Timo Strauss" and profile["name_from"] == "macOS"  # config.toml says "User"
    assert profile["organization"] == "KLOUD"  # from the user's own address in the calendar


def test_the_name_from_config_toml_is_kept(tmp_path):
    a = App(tmp_path, "Timo", probe=FakeProbe())
    assert api.setup_page(a)["profile"] == {**api.setup_page(a)["profile"], "name": "Timo", "name_from": "config"}


def test_connect_calendar_asks_macos_once_then_opens_system_settings(app):
    cal = app.probe.calendar
    assert api.setup_calendar(app, {"action": "connect"}) == {"state": "not_asked", "detail": "not connected",
                                                               "asked": True}
    assert cal.asked == 1 and api.setup_calendar(app, {})["state"] == "granted"
    assert api.setup_page(app)["permissions"]["calendar"]["state"] == "granted"
    assert "asked" not in api.setup_calendar(app, {"action": "connect"}) and cal.asked == 1  # connected: nothing
    app.probe._permissions["calendar"] = {"state": "denied", "detail": "not allowed"}
    assert api.setup_calendar(app, {"action": "connect"})["opened_settings"] is True
    assert cal.opened_settings == 1 and cal.asked == 1  # macOS asks no more once refused
    with pytest.raises(api.Refused):
        api.setup_calendar(app, {"action": "grant"})


def test_the_glossary_seed_comes_from_the_calendar(app):
    terms = {t["term"]: t["kind"] for t in api.setup_page(app)["glossary"]}
    assert terms == {"Stefan Dornbusch": "person", "Contoso": "organization", "Northwind": "title",
                     "Anna Huber": "person"}


def test_without_a_calendar_there_is_no_seed(tmp_path):
    a = App(tmp_path, "Timo", probe=FakeProbe())
    page = api.setup_page(a)
    assert page["glossary"] == [] and page["profile"]["organization"] is None


def test_the_summary_is_the_doctor_in_the_window(app):
    by = {c["name"]: c for c in api.setup_page(app)["summary"]}
    assert by["Microphone"]["status"] == "ok"
    assert by["Parakeet"]["status"] == "warn" and "2.3 GB" in by["Parakeet"]["fix"]
    assert by["Claude Code access"]["status"] == "warn"


def test_storage_and_privacy_say_where_things_are(app):
    s = api.setup_page(app)["storage"]
    assert s["recordings"] == str(app.output_dir)
    assert s["retention_days"] == 14 and s["autostart"] is False
    assert {c["feature"]: c["choice"] for c in s["cloud"]} == {"notes": "local", "projects": "local", "coach": "local",
                                                               "transcription": "local"}


def test_an_existing_user_is_not_offered_the_assistant(app):
    (app.output_dir / "2026-10-27T09-00-00").mkdir()
    assert api.setup_offer(app) is None
    assert app.probe.hardware_calls == 0  # nothing to look at: it would not be offered anyway


def test_recommendations_alone_for_the_settings_page(app):
    out = api.setup_recommendations(app)
    assert out["hardware"]["fingerprint"] == "Apple M4 Pro, 48 GB"
    assert {r["id"] for r in out["recommendations"]} >= {"realtime", "live_processing", "language_model"}


# --- applying: only what the user clicked ----------------------------------------------------

def test_looking_changes_nothing(app):
    api.setup_page(app)
    api.setup_recommendations(app)
    api.setup_offer(app)
    api.setup_downloads(app)
    api.setup_test(app, {})
    assert settings.read_raw() == {}
    assert app.probe.fetched == [] and app.probe.downloads.status() == {"running": False, "models": []}
    assert app.probe.recorder.started == [] and app.probe.autostart_on is False
    assert glossary.Glossary().terms() == {}


def test_apply_switches(app):
    api.apply_setup(app, {"changes": {"realtime": False, "live_processing": False, "record_slack": False}})
    s = settings.load()
    assert (s.realtime, s.live_processing, s.record_slack) == (False, False, False)
    with pytest.raises(api.Refused):
        api.apply_setup(app, {"changes": {"realtime": "yes"}})
    with pytest.raises(api.Refused):
        api.apply_setup(app, {"changes": {"no_such": True}})


def test_apply_the_local_model(app):
    api.apply_setup(app, {"changes": {"language_model": f"local:{ob.QWEN}"}})
    assert settings.read_raw()["local_model"] == ob.QWEN
    assert settings.read_raw()["engines"] == {"notes": "local", "projects": "local"}


def test_apply_a_cloud_model_only_when_it_is_set_up(app, fake_keychain):
    with pytest.raises(api.Refused, match="Add the API key"):
        api.apply_setup(app, {"changes": {"language_model": "anthropic"}})
    assert "engines" not in settings.read_raw()
    providers.set_key("anthropic", "sk-test")
    api.apply_setup(app, {"changes": {"language_model": "anthropic"}})
    assert settings.read_raw()["engines"] == {"notes": "anthropic", "projects": "anthropic"}
    with pytest.raises(api.Refused):
        api.apply_setup(app, {"changes": {"language_model": "cloud"}})  # "a cloud model" is no choice


def test_apply_transcription_takes_only_a_transcription_service(app, fake_keychain):
    api.apply_setup(app, {"changes": {"transcription": "local"}})
    assert settings.read_raw()["engines"]["transcription"] == "local"
    with pytest.raises(api.Refused):
        api.apply_setup(app, {"changes": {"transcription": "anthropic"}})  # a language model
    with pytest.raises(api.Refused, match="Add the API key"):
        api.apply_setup(app, {"changes": {"transcription": "soniox"}})
    providers.set_key("soniox", "key")
    api.apply_setup(app, {"changes": {"transcription": "soniox"}})
    assert settings.read_raw()["engines"]["transcription"] == "soniox"


def test_apply_claude_access(app, monkeypatch):
    added = []
    monkeypatch.setattr(api, "install_mcp", lambda target="code", cli_options=(): added.append(target) or {})
    api.apply_setup(app, {"changes": {"claude_code": True, "claude_desktop": False}})
    assert added == ["code"]


def test_apply_answers_with_the_new_recommendations(app):
    out = api.apply_setup(app, {"changes": {"realtime": False}})
    rec = next(r for r in out["recommendations"] if r["id"] == "realtime")
    assert rec["current"] is False and rec["matches"] is False


def test_profile_saves_the_name_and_the_organization(app):
    api.setup_profile(app, {"name": "Timo Strauß", "organization": "KLOUD"})
    assert settings.user_name() == "Timo Strauß" and app.user_name == "Timo Strauß"
    assert organizations.Organizations().person("Timo Strauß") == "KLOUD"
    with pytest.raises(api.Refused):
        api.setup_profile(app, {"name": "  "})


def test_glossary_seed_adds_the_terms_chosen_and_can_be_undone(app):
    out = api.seed_glossary(app, {"terms": ["Stefan Dornbusch", "Northwind", " "]})
    assert out["added"] == 2 and out["undo"]
    assert sorted(t["term"] for t in glossary.Glossary().terms().values()) == ["Northwind", "Stefan Dornbusch"]
    api.undo_change(app.output_dir, out["undo"], user_name="Timo")
    assert glossary.Glossary().terms() == {}


def test_autostart_only_on_a_click(app):
    api.setup_autostart(app, {"on": True})
    assert app.probe.autostart_on is True


def test_finish_and_skip_are_remembered(app):
    out = api.finish_setup(app, {"how": "done"})
    assert out["state"]["done"] and out["state"]["hardware"] == "Apple M4 Pro, 48 GB"
    assert api.setup_offer(app) is None or api.setup_offer(app)["why"] == "missing"
    api.finish_setup(app, {"how": "skipped"})
    assert settings.read_raw()["setup"]["skipped"]
    with pytest.raises(api.Refused):
        api.finish_setup(app, {"how": "later"})


def test_a_new_mac_offers_the_assistant_again(app):
    api.finish_setup(app, {"how": "done"})
    app.probe._hardware = ob.Hardware("Apple M5 Max", 64, 500)
    assert api.setup_offer(app)["why"] == "changed"


def test_a_missing_model_offers_the_downloads(app):
    for m in ("parakeet", "gemma"):
        app.probe._downloaded.add(m)
    api.finish_setup(app, {"how": "done"})
    assert api.setup_offer(app) is None
    app.probe._downloaded.discard("gemma")
    assert api.setup_offer(app) == {"why": "missing", "models": ["gemma"], "labels": {"gemma": "Gemma 4 12B"}}


# --- downloads and the test recording: started by the user -------------------------------------

def test_downloads_start_on_request_and_report_progress(app):
    app.probe.fetch_gate.clear()
    status = api.start_downloads(app, {"models": ["parakeet", "gemma"]})
    assert status["running"] and [m["id"] for m in status["models"]] == ["parakeet", "gemma"]
    app.probe.fetch_gate.set()
    wait_for(lambda: not api.setup_downloads(app)["running"])
    assert app.probe.fetched == ["parakeet", "gemma"]
    assert {m["state"] for m in api.setup_downloads(app)["models"]} == {"done"}
    with pytest.raises(api.Refused):
        api.start_downloads(app, {"models": ["not-a-model"]})


def test_the_test_recording_runs_only_when_started(app):
    assert api.setup_test(app, {})["state"] == "idle"  # a GET never starts it
    assert app.probe.recorder.started == []
    status = api.setup_test(app, {"action": "start"})
    assert status["state"] == "recording" and len(app.probe.recorder.started) == 1
    api.setup_test(app, {"action": "stop"})
    done = wait_for(lambda: (s := api.setup_test(app, {})) and s["state"] == "done" and s)
    assert [c["status"] for c in done["checks"]] == ["ok", "ok"]
    assert "This is my test sentence" in done["checks"][0]["detail"]
    assert not app.probe.recorder.started[0].exists()  # its audio is never kept


def test_no_test_recording_during_a_meeting(app):
    class Busy:
        def question(self):
            return None

        def busy(self):
            return True

    app.recording = Busy()
    with pytest.raises(api.Refused, match="being recorded"):
        api.setup_test(app, {"action": "start"})
    assert app.probe.recorder.started == []


def test_the_menubar_recording_path_decides_too(app):
    class Menubar:  # menubar.RecordingQuestion: recording() is None unless a meeting records
        now = None

        def question(self):
            return None

        def busy(self):
            return False  # processing an earlier meeting: no reason to refuse

        def recording(self):
            return self.now

    app.recording = Menubar()
    assert api.setup_test(app, {"action": "start"})["state"] == "recording"
    api.setup_test(app, {"action": "stop"})
    wait_for(lambda: api.setup_test(app, {})["state"] == "done")
    app.recording.now = {"meeting": "2026-10-30T09-00-00", "text": "Teams call"}
    with pytest.raises(api.Refused, match="being recorded"):
        api.setup_test(app, {"action": "start"})


def test_the_test_never_transcribes_with_a_download_or_the_cloud(app, fake_keychain):
    api.setup_test(app, {"action": "start"})
    api.setup_test(app, {"action": "stop"})
    wait_for(lambda: app.probe.recorder.modes)
    assert app.probe.recorder.modes[-1] == {"transcribe": "local", "repo": ob.MODELS["parakeet"].repo}
    providers.set_key("soniox", "key")
    api.apply_setup(app, {"changes": {"transcription": "soniox"}})
    api.setup_test(app, {"action": "start"})
    api.setup_test(app, {"action": "stop"})
    wait_for(lambda: len(app.probe.recorder.modes) == 2)
    assert app.probe.recorder.modes[-1] == {"transcribe": "cloud", "service": "Soniox"}


def test_transcription_stays_local_when_config_toml_sends_notes_to_claude(tmp_path):
    from types import SimpleNamespace

    cfg = SimpleNamespace(notes_engine="claude", claude_path=None, notes_model="sonnet", retention_days=14,
                          notes_local_model=ob.GEMMA, parakeet_repo=ob.MODELS["parakeet"].repo, hf_token=None)
    a = App(tmp_path, "Timo", probe=FakeProbe(), cfg=cfg)
    cloud = {c["feature"]: c["choice"] for c in api.setup_page(a)["storage"]["cloud"]}
    assert cloud == {"notes": "claude-cli", "projects": "claude-cli", "coach": "local", "transcription": "local"}
    recs = {r["id"]: r for r in api.setup_page(a)["recommendations"]}
    assert recs["transcription"]["current"] == "local" and recs["transcription"]["matches"]
    assert recs["language_model"]["chosen"] is True  # set in config.toml: deliberate


def test_use_recommended_on_16_gb_turns_notes_off_until_a_cloud_model(app):
    app.probe._hardware = ob.Hardware("Apple M2 Pro", 16, 200)
    rec = {r["id"]: r for r in api.setup_page(app)["recommendations"]}["language_model"]
    assert rec["value"] == "pending"
    api.apply_setup(app, {"changes": {"language_model": "pending"}})
    assert settings.read_raw()["engines"] == {"notes": "pending", "projects": "pending"}
    d = api.setup_page(app)["downloads"]
    assert "gemma" not in [m["id"] for m in d["needed"]]  # not chosen: not downloaded
    by = {c["name"]: c for c in api.setup_page(app)["summary"]}
    assert "none yet" in by["Notes and projects"]["detail"]


def test_gemma_chosen_on_16_gb_is_a_download_with_its_catch(app):
    app.probe._hardware = ob.Hardware("Apple M2 Pro", 16, 200)
    api.apply_setup(app, {"changes": {"language_model": f"local:{ob.GEMMA}"}})
    gemma = next(m for m in api.setup_page(app)["downloads"]["needed"] if m["id"] == "gemma")
    assert gemma["disk_gb"] == 8.3 and gemma["note"] == "needs 14 GB free while writing; this Mac has 16 GB"


def test_pyannote_needs_a_token_and_the_page_says_where_without_it(app):
    app.probe._downloaded.discard("pyannote")
    app.probe.hf_token = False
    d = api.setup_page(app)["downloads"]
    assert d["hf_token"] == {"set": False, "needed": True, "where": "[hf].token in ~/.config/palaver/config.toml, or HF_TOKEN",
                             "terms": "https://huggingface.co/pyannote/speaker-diarization-community-1"}
    app.probe.hf_token = True
    assert api.setup_page(app)["downloads"]["hf_token"]["set"] is True


def test_a_deliberate_switch_is_chosen(app):
    settings.update({"realtime": False})
    recs = {r["id"]: r for r in api.setup_page(app)["recommendations"]}
    assert recs["realtime"]["chosen"] is True and recs["live_processing"]["chosen"] is False


def test_a_new_name_keeps_the_old_one_as_an_alias(app):
    app.user_name = "Timo"
    api.setup_profile(app, {"name": "Timo Strauß", "organization": ""})
    assert settings.user_aliases() == ["Timo"]
    api.setup_profile(app, {"name": "Timo Strauß", "organization": ""})  # unchanged: nothing more
    api.setup_profile(app, {"name": "T. Strauß", "organization": ""})
    assert settings.user_aliases() == ["Timo", "Timo Strauß"]
    api.setup_profile(app, {"name": "Timo", "organization": ""})  # back: no longer an alias
    assert settings.user_aliases() == ["Timo Strauß", "T. Strauß"]


# --- over HTTP ---------------------------------------------------------------------------------

@pytest.fixture
def server(app):
    srv = make_server(app, port=0)
    import threading

    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{srv.server_address[1]}"
    srv.shutdown()
    srv.server_close()


def _req(base, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(base + path, data=data,
                                 headers={"Content-Type": "application/json"} if data is not None else {})
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read())


def test_http_setup_routes(server, app):
    status, page = _req(server, "/api/setup")
    assert status == 200 and page["offer"] == {"why": "first"}
    assert _req(server, "/api/setup/offer")[1] == {"offer": {"why": "first"}}
    assert _req(server, "/api/setup/recommendations")[0] == 200
    status, out = _req(server, "/api/setup/apply", {"changes": {"realtime": False}})
    assert status == 200 and settings.load().realtime is False
    assert _req(server, "/api/setup/apply", {"changes": {"realtime": 1}})[0] == 400
    assert _req(server, "/api/setup/profile", {"name": "Anna", "organization": ""})[0] == 200
    assert _req(server, "/api/setup/glossary", {"terms": ["Northwind"]})[1]["added"] == 1
    assert _req(server, "/api/setup/autostart", {"on": True})[0] == 200
    assert _req(server, "/api/setup/test")[1]["state"] == "idle"
    assert _req(server, "/api/setup/calendar")[1]["state"] == "not_asked"
    assert _req(server, "/api/setup/calendar", {"action": "connect"})[1]["asked"] is True
    assert _req(server, "/api/setup/calendar")[1]["state"] == "granted"
    assert _req(server, "/api/setup/downloads")[1] == {"running": False, "models": []}
    assert _req(server, "/api/setup/finish", {"how": "skipped"})[0] == 200
    assert _req(server, "/api/setup/offer")[1] == {"offer": None}
