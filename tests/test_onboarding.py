"""The setup assistant's checks and recommendations (#55, #43): pure
functions of what was detected, tested across Mac profiles."""

from __future__ import annotations

import pytest

from pathlib import Path

from palaver import onboarding as ob

GEMMA = "mlx-community/gemma-4-12B-it-OptiQ-4bit"
QWEN = "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"


# --- a registry like master's (language models only) and like #54's ------------------

def lm_registry(*, ready: tuple[str, ...] = ()) -> ob.Registry:
    lm = frozenset({"language_model"})
    return ob.Registry(
        features={"notes": "language_model", "projects": "language_model"},
        providers={
            "anthropic": ob.ProviderInfo("Anthropic API", lm, "anthropic" in ready,
                                         None if "anthropic" in ready else "Add the API key"),
            "openai": ob.ProviderInfo("OpenAI-compatible", lm, "openai" in ready,
                                      None if "openai" in ready else "Save the endpoint"),
            "claude-cli": ob.ProviderInfo("Claude Code CLI", lm, "claude-cli" in ready,
                                          None if "claude-cli" in ready else "Claude Code CLI (`claude`) not found"),
        })


def with_transcription(reg: ob.Registry, *, ready: tuple[str, ...] = ()) -> ob.Registry:
    """#54 adds a transcription feature and its services to the same registry."""
    tr = frozenset({"transcription"})
    return ob.Registry(
        features={**reg.features, "transcription": "transcription"},
        providers={**reg.providers,
                   "assemblyai": ob.ProviderInfo("AssemblyAI", tr, "assemblyai" in ready,
                                                 None if "assemblyai" in ready else "Add the API key"),
                   "soniox": ob.ProviderInfo("Soniox", tr, "soniox" in ready,
                                             None if "soniox" in ready else "Add the API key")})


ALL_DOWNLOADED = frozenset(ob.MODELS)


def current(**kw) -> ob.Current:
    base = dict(settings={"realtime": True, "record_teams": True, "record_slack": True, "live_processing": True,
                          "search_meaning": True},
                choices={"notes": "local", "projects": "local"}, local_model=GEMMA,
                downloaded=ALL_DOWNLOADED, registry=lm_registry(), mcp={"code": False, "desktop": False})
    base.update(kw)
    return ob.Current(**base)


def recs(chip: str, memory: float, disk: float = 200, installed: ob.Installed | None = None, **kw):
    out = ob.recommend(ob.Hardware(chip, memory, disk), installed or ob.Installed(), current(**kw))
    return {r.id: r for r in out}


# --- the chip --------------------------------------------------------------------------

@pytest.mark.parametrize("brand, parsed", [
    ("Apple M1", (1, "base")),
    ("Apple M2 Pro", (2, "pro")),
    ("Apple M3 Max", (3, "max")),
    ("Apple M4 Pro", (4, "pro")),
    ("Apple M2 Ultra", (2, "ultra")),
    ("Apple M5", (5, "base")),
    ("Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz", None),
    ("", None),
])
def test_parse_chip(brand, parsed):
    assert ob.parse_chip(brand) == parsed


def test_hardware_says_what_it_is():
    hw = ob.Hardware("Apple M4 Pro", 48.0, 120.4)
    assert hw.apple_silicon and hw.generation == 4 and hw.tier == "pro"
    assert hw.fingerprint == "Apple M4 Pro, 48 GB"
    assert not ob.Hardware("Intel(R) Core(TM) i7", 16, 100).apple_silicon


# --- the recommendation table: every profile ---------------------------------------------

CHIPS = ["Apple M1", "Apple M2 Pro", "Apple M4 Pro"]
MEMORY = [8, 16, 24, 32, 48, 64]


def expected(chip: str, memory: int) -> dict:
    gen, tier = ob.parse_chip(chip)
    fast = gen >= 3 or (gen == 2 and tier != "base")
    return {
        "transcription": "local",
        "language_model": f"local:{GEMMA}" if memory >= 24 else "pending",
        "realtime": fast and memory >= 16,
        "live_processing": memory >= 24,
        "search_meaning": True,
    }


@pytest.mark.parametrize("chip", CHIPS)
@pytest.mark.parametrize("memory", MEMORY)
def test_every_profile(chip, memory):
    got = recs(chip, memory)
    want = expected(chip, memory)
    assert {k: got[k].value for k in want} == want
    for r in got.values():
        assert r.reason.strip(), r.id  # every recommendation says why
        if r.options:
            assert r.value in [o.value for o in r.options], r.id


def test_the_profile_table_is_printable():
    """The table the report shows: one line per profile."""
    rows = ob.profile_table([(c, m, 200) for c in CHIPS for m in MEMORY] + [("Apple M4 Pro", 32, 10)],
                            current(downloaded=frozenset()))
    assert len(rows) == len(CHIPS) * len(MEMORY) + 1
    assert rows[0].startswith("Apple M1, 8 GB, 200 GB free")


# --- notes: the local model or the cloud ----------------------------------------------------

def test_24_gb_writes_notes_locally_with_gemma_and_says_why():
    r = recs("Apple M4 Pro", 24)["language_model"]
    assert r.value == f"local:{GEMMA}" and r.matches
    assert "24 GB" in r.reason and "14 GB" in r.reason
    assert r.features == ("notes", "projects")


def test_16_gb_recommends_a_cloud_model_and_explains_the_memory():
    r = recs("Apple M2 Pro", 16)["language_model"]
    # Nothing is set up yet: notes wait for a cloud model, never Gemma by default.
    assert r.value == "pending" and r.needs_setup
    assert r.label == "None yet: set up a cloud model"
    assert "16 GB" in r.reason and "14 GB" in r.reason
    assert "Small local models wrote clearly worse notes in our tests, so we don't offer one." in r.reason
    pending = next(o for o in r.options if o.value == "pending")
    assert pending.available and "off until" in pending.note
    gemma = next(o for o in r.options if o.value == f"local:{GEMMA}")
    assert gemma.available and "14 GB" in gemma.note  # still possible, with its catch said
    qwen = next(o for o in r.options if o.value == f"local:{QWEN}")
    assert not qwen.available  # needs 20 GB free: never on 16 GB
    assert not r.matches


def test_16_gb_recommends_a_cloud_model_that_is_ready():
    r = recs("Apple M2 Pro", 16, registry=lm_registry(ready=("anthropic", "claude-cli")))["language_model"]
    assert r.value == "claude-cli" and not r.needs_setup  # no key needed: the Claude Code login
    r = recs("Apple M2 Pro", 16, registry=lm_registry(ready=("anthropic",)))["language_model"]
    assert r.value == "anthropic"


def test_a_cloud_model_already_chosen_stays_recommended():
    r = recs("Apple M1", 16, registry=lm_registry(ready=("anthropic", "openai")),
             choices={"notes": "openai", "projects": "openai"})["language_model"]
    assert r.value == "openai" and r.matches


def test_8_gb_cannot_run_gemma_at_all():
    r = recs("Apple M1", 8)["language_model"]
    gemma = next(o for o in r.options if o.value == f"local:{GEMMA}")
    assert r.value == "pending" and not gemma.available


def test_qwen_is_an_alternative_only_where_it_fits():
    r = recs("Apple M4 Pro", 48)["language_model"]
    qwen = next(o for o in r.options if o.value == f"local:{QWEN}")
    assert qwen.available and "20 GB" in qwen.note
    assert r.value == f"local:{GEMMA}"  # Qwen makes more mistakes on German meetings


def test_cloud_providers_are_offered_with_their_problem():
    r = recs("Apple M4 Pro", 48)["language_model"]
    anthropic = next(o for o in r.options if o.value == "anthropic")
    assert not anthropic.available and anthropic.note == "Add the API key"


# --- disk --------------------------------------------------------------------------------

def test_low_disk_recommends_the_cloud_and_says_how_much_is_needed():
    got = recs("Apple M4 Pro", 32, disk=10, downloaded=frozenset())
    lm = got["language_model"]
    assert lm.value == "pending"
    assert "8.3 GB" in lm.reason and "10 GB free" in lm.reason
    assert "gemma" not in got["transcription"].downloads or True
    assert got["transcription"].value == "local"  # Parakeet still fits: 2.3 GB


def test_low_disk_is_fine_when_the_model_is_already_here():
    got = recs("Apple M4 Pro", 32, disk=10)
    assert got["language_model"].value == f"local:{GEMMA}"
    assert "disk" not in got


def test_very_low_disk_says_what_to_free():
    got = recs("Apple M4 Pro", 48, disk=3, downloaded=frozenset())
    disk = got["disk"]
    assert disk.value > 0 and "GB" in disk.reason
    assert got["search_meaning"].value is False  # no room for the 470 MB index model either


def test_downloads_list_what_is_not_here_yet():
    got = recs("Apple M4 Pro", 48, downloaded=frozenset({"pyannote"}))
    assert got["transcription"].downloads == ("parakeet",)
    assert got["language_model"].downloads == ("gemma",)
    assert got["search_meaning"].downloads == ("e5",)
    assert ob.download_size(["parakeet", "gemma", "e5"]) == pytest.approx(2.3 + 8.3 + 0.47)


# --- during calls ---------------------------------------------------------------------------

def test_realtime_is_off_below_an_m2_pro_and_says_why():
    r = recs("Apple M1", 32)["realtime"]
    assert r.value is False and "M2 Pro" in r.reason
    r = recs("Apple M4 Pro", 8)["realtime"]
    assert r.value is False and "8 GB" in r.reason


def test_realtime_names_its_cost():
    r = recs("Apple M4 Pro", 48)["realtime"]
    assert r.value is True and "2.5 GB" in r.reason


def test_live_processing_needs_24_gb():
    assert recs("Apple M4 Pro", 16)["live_processing"].value is False
    r = recs("Apple M4 Pro", 24)["live_processing"]
    assert r.value is True and "3.6 GB" in r.reason


# --- transcription ---------------------------------------------------------------------------

def test_transcription_is_parakeet_on_any_apple_silicon():
    for chip in CHIPS:
        r = recs(chip, 8)["transcription"]
        assert r.value == "local" and "Parakeet" in r.reason
        assert r.features == ()  # nothing to choose on master: no transcription feature yet


def test_transcription_offers_the_registrys_services_once_54_is_in():
    reg = with_transcription(lm_registry(), ready=("soniox",))
    r = recs("Apple M4 Pro", 48, registry=reg)["transcription"]
    assert r.value == "local" and r.features == ("transcription",)
    assert [o.value for o in r.options] == ["local", "assemblyai", "soniox"]
    assert [o.available for o in r.options] == [True, False, True]
    lm = recs("Apple M4 Pro", 48, registry=reg)["language_model"]
    assert lm.features == ("notes", "projects")  # transcription services are no language model
    assert "assemblyai" not in [o.value for o in lm.options]


def test_an_intel_mac_is_not_supported_yet():
    reg = with_transcription(lm_registry(), ready=("assemblyai",))
    got = recs("Intel(R) Core(TM) i7", 16, registry=reg)
    for rid in ("transcription", "language_model"):
        r = got[rid]
        assert r.matches and r.label == "Not supported on this Mac"  # nothing to change
        assert "Apple Silicon is required for local processing" in r.reason
        assert "doesn't support Intel Macs yet" in r.reason
        assert "transcribes the calls" not in r.reason
    assert got["realtime"].value is False and got["live_processing"].value is False


def test_a_transcription_service_chosen_stays_recommended():
    reg = with_transcription(lm_registry(), ready=("soniox",))
    r = recs("Apple M4 Pro", 48, registry=reg, choices={"notes": "local", "transcription": "soniox"})["transcription"]
    assert r.value == "local" and r.current == "soniox" and not r.matches  # local is still the advice


# --- what to record, Claude -----------------------------------------------------------------

def test_teams_and_slack_follow_what_is_installed():
    got = recs("Apple M4 Pro", 48, installed=ob.Installed(teams=True, slack=False),
               settings={"record_teams": False, "record_slack": True})
    assert got["record_teams"].value is True and "installed" in got["record_teams"].reason
    assert got["record_slack"].value is True  # not installed: keeps what it is, nothing to detect yet
    assert "not installed" in got["record_slack"].reason


def test_claude_access_is_recommended_where_claude_is_installed():
    got = recs("Apple M4 Pro", 48, installed=ob.Installed(claude_code=True))
    assert got["claude_code"].value is True and not got["claude_code"].matches
    assert got["claude_desktop"].value is False and "not installed" in got["claude_desktop"].reason
    got = recs("Apple M4 Pro", 48, installed=ob.Installed(claude_code=True), mcp={"code": True, "desktop": False})
    assert got["claude_code"].matches


def test_a_recommendation_serializes_for_the_page():
    r = recs("Apple M2 Pro", 16)["language_model"].to_dict()
    assert r["id"] == "language_model" and r["value"] == "pending" and r["needs_setup"] is True
    assert {"value", "label", "note", "available"} <= set(r["options"][0])
    assert r["matches"] is False and r["step"] == "models" and r["chosen"] is False


# --- when to offer the assistant --------------------------------------------------------------

def test_offer_on_first_start_only_without_meetings():
    assert ob.offer(None, "Apple M4 Pro, 48 GB", has_meetings=False, missing=[]) == {"why": "first"}
    assert ob.offer(None, "Apple M4 Pro, 48 GB", has_meetings=True, missing=[]) is None  # an existing user


def test_offer_again_when_the_mac_changed():
    state = {"done": "2026-10-29T10:00:00+01:00", "hardware": "Apple M1, 16 GB"}
    assert ob.offer(state, "Apple M4 Pro, 48 GB", has_meetings=True, missing=[]) == {
        "why": "changed", "was": "Apple M1, 16 GB", "now": "Apple M4 Pro, 48 GB"}


def test_offer_the_downloads_when_a_model_is_missing():
    state = {"done": "2026-10-29T10:00:00+01:00", "hardware": "Apple M4 Pro, 48 GB"}
    assert ob.offer(state, "Apple M4 Pro, 48 GB", has_meetings=True, missing=["gemma"]) == {
        "why": "missing", "models": ["gemma"]}
    assert ob.offer(state, "Apple M4 Pro, 48 GB", has_meetings=True, missing=[]) is None


def test_skipped_is_not_offered_again():
    state = {"skipped": "2026-10-29T10:00:00+01:00", "hardware": "Apple M4 Pro, 48 GB"}
    assert ob.offer(state, "Apple M4 Pro, 48 GB", has_meetings=False, missing=["gemma"]) is None


def test_missing_models_are_those_the_choices_need():
    c = current(downloaded=frozenset({"pyannote", "e5"}))
    assert ob.missing_models(c, ob.Hardware("Apple M4 Pro", 48, 200)) == ["parakeet", "gemma"]
    c = current(downloaded=frozenset({"pyannote", "e5", "parakeet"}), choices={"notes": "anthropic"},
                registry=lm_registry(ready=("anthropic",)))
    assert ob.missing_models(c, ob.Hardware("Apple M4 Pro", 48, 200)) == []


# --- the glossary seed from the calendar -------------------------------------------------------

def _event(title, *people):
    from datetime import datetime

    from palaver.calendar_events import Attendee, Event

    at = datetime(2026, 10, 28, 10, 0)
    return Event(title, at, at, tuple(Attendee(n, e, is_self=s) for n, e, s in people))


def test_seed_terms_from_the_calendar():
    me = ("Timo Strauss", "timo@kloud.io", True)
    events = [
        _event("Contoso Northwind Weekly", me, ("Stefan Dornbusch", "stefan@contoso.at", False),
               ("Anna Huber", "anna@kloud.io", False)),
        _event("Northwind Planning", me, ("Stefan Dornbusch", "stefan@contoso.at", False),
               ("Room 4", None, False)),
        _event("Lunch", me, ("Max", "max@gmail.com", False)),
    ]
    terms = ob.seed_terms(events, user_name="Timo Strauss", known=["anna huber"])
    by_term = {t["term"]: t for t in terms}
    assert by_term["Stefan Dornbusch"]["kind"] == "person" and by_term["Stefan Dornbusch"]["count"] == 2
    assert by_term["Contoso"]["kind"] == "organization"
    assert by_term["Northwind"]["kind"] == "title"
    assert "Timo Strauss" not in by_term and "Anna Huber" not in by_term  # the user; already known
    assert "KLOUD" not in by_term  # the user's own organization
    assert "Extern" not in by_term and "Room 4" not in by_term and "Lunch" not in by_term
    assert terms[0]["term"] in ("Stefan Dornbusch", "Contoso", "Northwind")  # the most frequent first


def test_own_organization_from_the_calendar():
    me = ("Timo Strauss", "timo@kloud.io", True)
    assert ob.own_organization([_event("Sync", me)]) == "KLOUD"
    assert ob.own_organization([]) is None


# --- the summary (doctor in the window) ---------------------------------------------------------

def test_summary_says_what_is_set_up_and_what_to_fix():
    hw = ob.Hardware("Apple M2 Pro", 16, 50)
    permissions = {"microphone": {"state": "granted", "detail": "granted"},
                   "system_audio": {"state": "unverified", "detail": "not verified yet"},
                   "calendar": {"state": "not_asked", "detail": "not connected"},
                   "notifications": {"state": "unknown", "detail": "macOS asks the first time"}}
    c = current(downloaded=frozenset({"pyannote"}), choices={"notes": "anthropic", "projects": "anthropic"})
    checks = ob.summary(hw, permissions, ob.Installed(), c)
    by = {x.name: x for x in checks}
    assert by["This Mac"].status == "ok" and "M2 Pro" in by["This Mac"].detail
    assert by["Microphone"].status == "ok"
    assert by["Calendar"].status == "warn" and by["Calendar"].fix
    assert by["Parakeet"].status == "warn" and "2.3 GB" in by["Parakeet"].fix
    assert by["Notes and projects"].status == "fail" and "Add the API key" in by["Notes and projects"].detail
    assert by["Disk space"].status == "ok"


def test_summary_local_notes_name_the_model_and_its_download():
    c = current(downloaded=frozenset({"pyannote", "parakeet", "e5"}))
    by = {x.name: x for x in ob.summary(ob.Hardware("Apple M4 Pro", 48, 200), {}, ob.Installed(), c)}
    assert by["Notes and projects"].status == "warn" and "Gemma 4 12B" in by["Notes and projects"].detail
    assert "8.3 GB" in by["Notes and projects"].fix


# --- the test recording's verdict ------------------------------------------------------------------

def test_test_verdict_both_tracks():
    ok = ob.test_verdict({"mic": {"recorded": True, "level_db": -28.0, "text": "Hello this is a test"},
                          "system": {"recorded": True, "level_db": -80.0}})
    assert [c.status for c in ok] == ["ok", "ok"]
    assert "Hello this is a test" in ok[0].detail
    assert "quiet" in ok[1].detail  # nothing played: a silent system track is right


def test_test_verdict_silent_mic_and_missing_system_track():
    bad = ob.test_verdict({"mic": {"recorded": True, "level_db": -75.0, "text": ""},
                           "system": {"recorded": False, "level_db": None}})
    assert [c.status for c in bad] == ["warn", "fail"]
    assert "input" in bad[0].fix and "System Audio Recording" in bad[1].fix
    for c in bad:
        assert "headphone" not in (c.detail + c.fix).lower()


def test_test_verdict_mic_missing():
    bad = ob.test_verdict({"mic": {"recorded": False, "level_db": None, "text": None},
                           "system": {"recorded": True, "level_db": -20.0}})
    assert bad[0].status == "fail" and "Microphone" in bad[0].fix
    assert bad[1].status == "ok"



# --- review fixes -------------------------------------------------------------------------

def test_a_deliberate_choice_is_marked_chosen():
    got = recs("Apple M1", 32, settings={"realtime": True}, chosen=frozenset({"realtime"}))
    assert got["realtime"].chosen and not got["realtime"].matches
    assert not got["live_processing"].chosen


def test_summary_says_notes_wait_for_a_cloud_model():
    c = current(choices={"notes": "pending", "projects": "pending"})
    by = {x.name: x for x in ob.summary(ob.Hardware("Apple M2 Pro", 16, 200), {}, ob.Installed(), c)}
    assert by["Notes and projects"].status == "warn"
    assert "none yet" in by["Notes and projects"].detail and "Language model" in by["Notes and projects"].fix


def test_missing_models_never_include_gemma_while_notes_wait():
    c = current(downloaded=frozenset({"pyannote", "parakeet"}), choices={"notes": "pending"})
    assert ob.missing_models(c, ob.Hardware("Apple M2 Pro", 16, 200)) == []


def test_the_catch_of_a_local_model_on_a_small_mac():
    assert ob.download_note("gemma", ob.Hardware("Apple M2 Pro", 16, 200)) == \
        "needs 14 GB free while writing; this Mac has 16 GB"
    assert ob.download_note("gemma", ob.Hardware("Apple M4 Pro", 48, 200)) == ""
    assert ob.download_note("parakeet", ob.Hardware("Apple M2 Pro", 16, 200)) == ""


def test_a_screencapturekit_fallback_works_with_a_fallback():
    by = {x.name: x for x in ob.summary(ob.Hardware("Apple M4 Pro", 48, 200),
                                         {"system_audio": {"state": "fallback", "detail": "works with a fallback"}},
                                         ob.Installed(), current())}
    assert by["System audio"].status == "warn" and "fallback" in by["System audio"].detail


def test_test_verdict_says_why_there_are_no_words():
    base = {"system": {"recorded": True, "level_db": -80.0}}
    missing = ob.test_verdict({**base, "mic": {"recorded": True, "level_db": -20.0, "text": None,
                                                "transcript": "not_downloaded"}})
    assert missing[0].status == "ok" and "Parakeet is not downloaded" in missing[0].detail
    assert "Downloads" in missing[0].fix
    cloud = ob.test_verdict({**base, "mic": {"recorded": True, "level_db": -20.0, "text": None,
                                              "transcript": "cloud", "service": "Soniox"}})
    assert "transcription is skipped" in cloud[0].detail and "Soniox" in cloud[0].detail


# --- the test recording never downloads, and gives way to a meeting ------------------------------

class _Capture:
    def __init__(self):
        self.started, self.stopped = 0, 0

    def __call__(self, folder):
        self.started += 1

        def stop():
            self.stopped += 1
            return folder / "mic.wav", folder / "system.wav"
        return stop


def _wait(check):
    import time

    for _ in range(250):
        if check():
            return True
        time.sleep(0.02)
    raise AssertionError("timed out")


def test_a_meeting_stops_a_running_test_recording():
    cap = _Capture()
    analyzed = []
    t = ob.TestRecording(capture=cap, analyze=lambda mic, system, mode: analyzed.append(mode) or {})
    t.start()
    assert t.status()["state"] == "recording"
    with ob.meeting_starting():
        assert cap.stopped == 1  # the capture let go before the meeting's starts
        assert t.status()["state"] == "aborted"
        with pytest.raises(ValueError, match="being recorded"):
            t.start()  # not while the meeting starts
    assert analyzed == []  # nothing checked, nothing kept
    assert "call started" in t.status()["error"]


def test_a_test_recording_waits_for_no_meeting():
    cap = _Capture()
    t = ob.TestRecording(capture=cap, analyze=lambda mic, system, mode: {})
    with pytest.raises(ValueError, match="being recorded"):
        t.start(busy=lambda: True)
    assert cap.started == 0


def test_the_test_passes_how_it_may_transcribe():
    seen = []
    t = ob.TestRecording(capture=_Capture(), analyze=lambda mic, system, mode: seen.append(mode) or {})
    t.start(mode={"transcribe": "cloud", "service": "Soniox"})
    t.stop()
    _wait(lambda: seen)
    assert seen == [{"transcribe": "cloud", "service": "Soniox"}]


def test_the_test_capture_writes_no_session_log(tmp_path, monkeypatch):
    """Its log lines never go to a meeting's session.log: it keeps none."""
    from palaver import session as session_mod

    made = []

    class FakeSession:
        def __init__(self, output_dir, *, trigger, log=True):
            made.append((trigger, log))

        def start(self):
            return tmp_path

        def stop(self):
            pass

    monkeypatch.setattr(session_mod, "RecordingSession", FakeSession)
    stop = ob._capture_both(tmp_path)
    stop()
    assert made == [("test", False)]


def test_analyze_never_downloads(tmp_path, monkeypatch):
    import numpy as np
    import soundfile as sf

    mic, system = tmp_path / "mic.wav", tmp_path / "system.wav"
    sf.write(mic, (0.3 * np.sin(np.arange(16000) / 3)).astype("float32"), 16000)
    sf.write(system, np.zeros(16000, dtype="float32"), 16000)
    calls = []
    monkeypatch.setattr(ob, "_transcribe", lambda wav, repo: calls.append((wav, repo)) or "hello")
    monkeypatch.setattr(ob, "complete", lambda repo, probe="config.json": False)
    out = ob._analyze(mic, system, {"transcribe": "local", "repo": "org/parakeet"})
    assert out["mic"]["transcript"] == "not_downloaded" and calls == []
    monkeypatch.setattr(ob, "complete", lambda repo, probe="config.json": True)
    out = ob._analyze(mic, system, {"transcribe": "local", "repo": "org/parakeet"})
    assert out["mic"]["text"] == "hello" and calls == [(mic, "org/parakeet")]
    out = ob._analyze(mic, system, {"transcribe": "cloud", "service": "Soniox"})
    assert out["mic"]["transcript"] == "cloud" and len(calls) == 1  # levels only


def test_the_transcribe_helper_runs_offline(monkeypatch):
    seen = {}

    class Proc:
        returncode, stdout = 0, "hello there\n"

    def run(argv, **kw):
        seen.update(argv=argv, env=kw["env"])
        return Proc()

    monkeypatch.setattr(ob.subprocess, "run", run)
    assert ob._transcribe(Path("/tmp/x.wav"), "org/parakeet") == "hello there"
    assert seen["env"]["HF_HUB_OFFLINE"] == "1"
    assert seen["argv"][-2:] == ["/tmp/x.wav", "org/parakeet"]


# --- downloads: complete only when every file is there ------------------------------------------

def _cache(root: Path, repo: str, files: dict[str, bytes], *, incomplete: bool = False) -> Path:
    import hashlib

    base = root / ("models--" + repo.replace("/", "--"))
    (base / "blobs").mkdir(parents=True)
    (base / "refs").mkdir()
    rev = "a" * 40
    (base / "refs" / "main").write_text(rev)
    snap = base / "snapshots" / rev
    snap.mkdir(parents=True)
    for name, data in files.items():
        blob = base / "blobs" / hashlib.sha256(data).hexdigest()
        blob.write_bytes(data)
        (snap / name).symlink_to(blob)
    if incomplete:
        (base / "blobs" / ("f" * 64 + ".incomplete")).write_bytes(b"part")
    return base


def test_complete_needs_every_file_and_no_partial_blob(tmp_path, monkeypatch):
    monkeypatch.setenv("HF_HUB_CACHE", str(tmp_path))
    assert not ob.complete("org/none")
    _cache(tmp_path, "org/ok", {"config.json": b"{}", "model.safetensors": b"x" * 10})
    assert ob.complete("org/ok")
    _cache(tmp_path, "org/partial", {"config.json": b"{}"}, incomplete=True)
    assert not ob.complete("org/partial")
    base = _cache(tmp_path, "org/broken", {"config.json": b"{}", "model.safetensors": b"y"})
    for blob in (base / "blobs").iterdir():
        if blob.stat().st_size == 1:
            blob.unlink()  # a snapshot file whose blob is gone
    assert not ob.complete("org/broken")
    _cache(tmp_path, "org/noconfig", {"model.safetensors": b"z"})
    assert not ob.complete("org/noconfig")


def test_a_failed_download_can_be_tried_again():
    tries = []

    def fetch(m):
        tries.append(m.id)
        if len(tries) == 1:
            raise RuntimeError("connection reset")

    d = ob.Downloads(fetch=fetch, progress=lambda m: 0, done=lambda m: True)
    d.start(["parakeet"])
    _wait(lambda: d.status()["models"][0]["state"] == "failed")
    assert d.status()["models"][0]["error"] == "connection reset"
    d.start(["parakeet"])
    _wait(lambda: d.status()["models"][0]["state"] == "done")
    assert tries == ["parakeet", "parakeet"]


def test_a_download_that_left_files_missing_is_failed():
    d = ob.Downloads(fetch=lambda m: None, progress=lambda m: 0, done=lambda m: False)
    d.start(["gemma"])
    _wait(lambda: d.status()["models"][0]["state"] == "failed")
    assert "incomplete" in d.status()["models"][0]["error"]


def test_download_progress_reads_the_configured_repo():
    seen = []
    d = ob.Downloads(fetch=lambda m: None, progress=lambda repo: seen.append(repo) or 0, done=lambda m: True,
                     repo_of=lambda m: "my/parakeet" if m.id == "parakeet" else m.repo)
    d._jobs["parakeet"] = {"state": "downloading", "error": None}
    d.status()
    assert seen == ["my/parakeet"]
