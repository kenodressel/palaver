"""Cloud transcription as an option (#54): the system track to the provider
the user chose, the mic and diarization on this Mac (palaver/transcription.py
and its place in `process`)."""

import json
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from palaver import access_log, cli, cloud_asr, llm, providers, settings, transcription
from palaver.cloud_llm import CloudError
from palaver.cloud_asr import Heard
from palaver.models import Segment, SpeakerTurn, Word
from palaver.paths import RecordingPaths

from .test_cli import _fake_models, _ns

SR = 16_000
KEY = "aai-SECRET-abcdefghijklmnopqrstuvwxyz0123"


def tone_track(seconds: float, loud: list[tuple[float, float]]) -> np.ndarray:
    x = np.random.default_rng(1).normal(0, 0.0005, int(seconds * SR)).astype(np.float32)  # about -66 dBFS
    for start, end in loud:
        t = np.arange(int(start * SR), int(end * SR))
        x[t] = 0.3 * np.sin(2 * np.pi * 220 * t / SR)
    return x


def write_wav(path: Path, samples: np.ndarray) -> Path:
    sf.write(str(path), samples, SR, subtype="PCM_16")
    return path


def words(start: float, text: str, step: float = 0.5) -> list[Word]:
    return [Word(w, round(start + i * step, 3), round(start + i * step + step * 0.8, 3))
            for i, w in enumerate(text.split())]


# --- the registry and the choice ---------------------------------------------------------


def test_transcription_providers_are_registered_apart_from_the_language_models():
    asr = providers.for_feature("transcription")
    assert {"assemblyai", "soniox", "mistral", "openai-transcribe"} <= set(asr)
    assert not set(asr) & set(providers.language_models())
    assert providers.FEATURES["transcription"]["uses"] == providers.TRANSCRIPTION
    for pid in asr:
        p = providers.PROVIDERS[pid]
        assert p.privacy and p.sends_to
    assert providers.settings_of("assemblyai")["region"] == "eu"  # EU by default
    assert providers.settings_of("soniox")["region"] == "eu"


def test_local_is_the_default_and_a_choice_needs_a_provider_that_is_set_up():
    assert providers.choice("transcription", default=providers.LOCAL) == providers.LOCAL
    with pytest.raises(ValueError, match="Add the API key"):
        providers.choose("transcription", "assemblyai")
    providers.set_key("assemblyai", KEY)
    providers.choose("transcription", "assemblyai")
    assert providers.choice("transcription", default=providers.LOCAL) == "assemblyai"


def test_a_language_model_is_no_transcriber_and_the_other_way_round():
    providers.set_key("anthropic", "sk-ant-SECRET-abcdefghij")
    providers.set_key("assemblyai", KEY)
    with pytest.raises(ValueError):
        providers.choose("transcription", "anthropic")
    with pytest.raises(ValueError):
        providers.choose("notes", "assemblyai")
    # A saved value that is no transcriber reads as local, never as a cloud nobody picked.
    settings.update({"engines": {"transcription": "anthropic"}})
    assert providers.choice("transcription", default=providers.LOCAL) == providers.LOCAL


def test_region_is_checked():
    providers.configure("assemblyai", region="us")
    assert providers.settings_of("assemblyai")["region"] == "us"
    with pytest.raises(ValueError):
        providers.configure("assemblyai", region="mars")
    with pytest.raises(ValueError):
        providers.configure("anthropic", region="eu")


def test_cloud_choice_keeps_a_meeting_marked_keep_on_this_mac(tmp_path):
    providers.set_key("assemblyai", KEY)
    providers.choose("transcription", "assemblyai")
    assert transcription.cloud_choice(None, tmp_path) == "assemblyai"
    llm.set_local_only(tmp_path, True)
    assert transcription.cloud_choice(None, tmp_path) is None


def test_a_provider_no_longer_set_up_is_not_used():
    providers.set_key("assemblyai", KEY)
    providers.choose("transcription", "assemblyai")
    providers.remove_key("assemblyai")
    with pytest.raises(transcription.Unavailable, match="Add the API key"):
        transcription.ready_provider(None, "assemblyai")


# --- trimming silence, keeping the offsets ---------------------------------------------------


def test_long_silences_are_trimmed_and_times_map_back(tmp_path):
    wav = write_wav(tmp_path / "system.wav", tone_track(20, [(1, 3), (13, 15)]))
    spans = transcription.speech_spans(wav)
    pad = transcription.KEEP_PAD_SECONDS
    # The 1 s before the first word is kept; the 10 s pause and the 5 s at the end are not.
    assert spans == [(0.0, pytest.approx(3 + pad, abs=0.11)),
                     (pytest.approx(13 - pad, abs=0.11), pytest.approx(15 + pad, abs=0.11))]
    line = transcription.Timeline(spans)
    assert line.seconds == pytest.approx(3 + pad + 2 + 2 * pad, abs=0.2)
    first = spans[0][1]
    assert line.to_source(1.0) == pytest.approx(1.0)
    assert line.to_source(first + 1.0) == pytest.approx(spans[1][0] + 1.0)
    # A word that runs over a cut keeps to the part where it starts.
    w = line.word_to_source(Word("x", first - 0.2, first + 0.3))
    assert w.start == pytest.approx(first - 0.2) and w.end == pytest.approx(first)


def test_short_pauses_are_kept(tmp_path):
    wav = write_wav(tmp_path / "system.wav", tone_track(6, [(0.5, 2), (3, 5.5)]))
    assert transcription.speech_spans(wav) == [(0.0, 6.0)]


def test_a_silent_track_sends_nothing(tmp_path):
    wav = write_wav(tmp_path / "system.wav", tone_track(30, []))
    assert transcription.speech_spans(wav) == []


# --- chunks, and stitching them back together ----------------------------------------------


def test_chunks_overlap_and_cover_everything():
    assert transcription.plan_chunks(100, 40, overlap=10) == [(0, 40), (30, 70), (60, 100)]
    assert transcription.plan_chunks(30, 40, overlap=10) == [(0, 30)]
    chunks = transcription.plan_chunks(3600 * 3, 1200, overlap=30)
    assert chunks[0][0] == 0 and chunks[-1][1] == 3600 * 3
    assert all(b[0] < a[1] for a, b in zip(chunks, chunks[1:]))  # each overlaps the next


def test_stitch_keeps_each_word_once():
    # Chunk A heard 0-40 s, chunk B 30-70 s: both heard 30-40 s.
    a = words(26, "eins zwei drei vier fünf sechs sieben acht neun zehn elf zwölf dreizehn vierzehn fünfzehn sechzehn "
                  "siebzehn achtzehn neunzehn zwanzig elf zwölf dreizehn vierzehn fünfzehn sechzehn siebzehn achtzehn")
    a = [w for w in a if w.end <= 40]
    b = [Word(w.text, w.start + 0.05, w.end + 0.05) for w in a if w.start >= 30]  # B's timing differs a bit
    b += words(40.5, "und weiter geht es")
    stitched = transcription.stitch([(0, 40, a), (30, 70, b)])
    assert [w.text for w in stitched] == [w.text for w in a] + ["und", "weiter", "geht", "es"]
    assert all(x.start <= y.start for x, y in zip(stitched, stitched[1:]))


def test_stitch_drops_a_word_both_chunks_put_on_either_side_of_the_seam():
    a = [Word("vorher", 30.0, 30.5), Word("Grenze", 34.85, 34.99)]  # midpoint of 30-40 is 35
    b = [Word("Grenze", 35.01, 35.2), Word("danach", 36.0, 36.4)]
    assert [w.text for w in transcription.stitch([(0, 40, a), (30, 70, b)])] == ["vorher", "Grenze", "danach"]


def test_stitch_keeps_a_word_said_twice_on_purpose():
    a = [Word("ja", 33.0, 33.2), Word("ja", 34.5, 34.7)]
    b = [Word("ja", 33.05, 33.25), Word("ja", 34.55, 34.75), Word("ja", 37.0, 37.2)]
    assert [w.start for w in transcription.stitch([(0, 40, a), (30, 70, b)])] == [33.0, 34.5, 37.0]


def test_segments_are_cut_at_sentence_ends_and_pauses():
    ws = words(0, "Hallo zusammen. Wie geht's") + words(5, "Gut danke")
    segs = transcription.segments_from_words(ws)
    assert [s.text for s in segs] == ["Hallo zusammen.", "Wie geht's", "Gut danke"]
    assert segs[0].start == ws[0].start and segs[0].end == ws[1].end and segs[0].speaker is None
    long = words(0, " ".join(["wort"] * 60), step=0.4)  # 24 s without a pause
    assert all(s.end - s.start <= transcription.MAX_SEGMENT_SECONDS for s in transcription.segments_from_words(long))


# --- the system track through a provider -----------------------------------------------------


class FakeAdapter:
    """A provider that hears the tone bursts as numbered words and records
    what it was sent."""

    def __init__(self, *, max_seconds=3600.0, fail: Exception | None = None, model="universal-3-5-pro"):
        self.max_seconds, self.max_bytes = max_seconds, 100_000_000
        self.host, self.model, self.name = "api.eu.assemblyai.com", model, "AssemblyAI"
        self.calls: list[dict] = []
        self.fail = fail
        self.pending: list[dict] = []

    def transcribe(self, audio, *, seconds, language, keyterms, fallback_language=None):
        self.calls.append({"bytes": len(audio), "seconds": seconds, "language": language, "keyterms": keyterms,
                           "fallback_language": fallback_language})
        if self.fail:
            raise self.fail
        data, sr = sf.read(__import__("io").BytesIO(audio), dtype="float32")
        assert sr == SR and data.ndim == 1  # 16 kHz mono
        hop = sr // 100  # 10 ms
        n = len(data) // hop
        loud = np.sqrt((data[: n * hop].reshape(n, hop) ** 2).mean(axis=1)) > 0.1
        out, i = [], 0
        while i < n:
            if loud[i]:
                j = i
                while j < n and loud[j]:
                    j += 1
                out.append(Word(f"w{len(self.calls)}-{len(out)}", i * hop / sr, j * hop / sr, 0.9))
                i = j
            i += 1
        return Heard(out, "de", seconds)


@pytest.fixture
def chosen(monkeypatch):
    providers.set_key("assemblyai", KEY)
    providers.choose("transcription", "assemblyai")
    fake = FakeAdapter()
    made = []

    def make(pid, s, key, **kw):
        made.append((pid, s, key))
        return fake

    monkeypatch.setattr(cloud_asr, "make", make)
    fake.made = made
    return fake


def recording(tmp_path: Path, system: np.ndarray, mic: np.ndarray | None = None) -> RecordingPaths:
    folder = tmp_path / "2026-10-29T10-00-00"
    folder.mkdir(parents=True)
    paths = RecordingPaths(folder)
    write_wav(paths.system_wav, system)
    write_wav(paths.mic_wav, mic if mic is not None else tone_track(len(system) / SR, []))
    paths.meta.write_text(json.dumps({"start_time": "2026-10-29T10:00:00+01:00",
                                      "duration_seconds": len(system) / SR}))
    return paths


def test_the_system_track_goes_out_trimmed_and_comes_back_on_the_recording_s_clock(tmp_path, chosen):
    paths = recording(tmp_path, tone_track(40, [(2, 3), (25, 26)]))
    engine = transcription.system_track(None, paths, local=lambda: pytest.fail("no local run"))
    assert engine == "assemblyai"
    (call,) = chosen.calls
    assert call["seconds"] < 15  # 20 s of silence were not sent
    segs = [Segment.from_dict(d) for d in json.loads(paths.system_segments.read_text())]
    starts = [w.start for s in segs for w in s.words]
    assert starts == [pytest.approx(2, abs=0.05), pytest.approx(25, abs=0.05)]
    marker = transcription.read_marker(paths)["system"]
    assert marker["engine"] == "assemblyai" and marker["model"] == "universal-3-5-pro"
    assert marker["sent_seconds"] == pytest.approx(call["seconds"], abs=0.01)
    assert paths.language.read_text().strip() == "de"


def test_a_long_recording_is_sent_in_overlapping_chunks_and_stitched(tmp_path, chosen):
    chosen.max_seconds = 20.0
    bursts = [(t, t + 0.6) for t in range(1, 59, 2)]  # no long silence: nothing is trimmed
    paths = recording(tmp_path, tone_track(60, bursts))
    transcription.system_track(None, paths, local=lambda: pytest.fail("no local run"))
    assert len(chosen.calls) >= 4 and all(c["seconds"] <= 20.0 + 1e-6 for c in chosen.calls)
    segs = [Segment.from_dict(d) for d in json.loads(paths.system_segments.read_text())]
    starts = [round(w.start) for s in segs for w in s.words]
    assert starts == [t for t, _ in bursts]  # every burst once, none twice


def test_every_upload_is_in_the_access_log_without_content_or_key(tmp_path, chosen):
    chosen.max_seconds = 20.0
    paths = recording(tmp_path, tone_track(45, [(t, t + 0.6) for t in range(1, 44, 2)]))
    transcription.system_track(None, paths, local=lambda: pytest.fail("no local run"))
    entries = access_log.recent(50)
    assert len(entries) == len(chosen.calls)
    for e in entries:
        assert e["provider"] == "assemblyai" and e["host"] == "api.eu.assemblyai.com"
        assert e["feature"] == "transcription" and e["meetings"] == [paths.folder.name]
        assert e["track"] == "system" and e["ok"] is True and 0 < e["audio_seconds"] <= 20.0
    raw = access_log.path().read_text()
    assert KEY not in raw and "w1-0" not in raw


def test_keyterms_come_from_the_glossary_and_the_invitees(tmp_path, chosen):
    from palaver import glossary

    g = glossary.Glossary()
    g.add("Attakring", ["Atterkring"])
    g.save()
    paths = recording(tmp_path, tone_track(10, [(2, 3)]))
    paths.calendar.write_text(json.dumps({
        "title": "Sync", "start": "2026-10-29T10:00:00+01:00", "end": "2026-10-29T11:00:00+01:00",
        "attendees": [{"name": "Karel Kralek"}, {"name": "Timo", "is_self": True}, {"name": "Room 4", "is_room": True}],
    }))

    class Cfg:
        user_name = "Timo"
        language = "auto"

    transcription.system_track(Cfg(), paths, local=lambda: pytest.fail("no local run"))
    assert chosen.calls[0]["keyterms"] == ["Attakring", "Karel Kralek"]
    assert chosen.calls[0]["language"] is None


def test_a_silent_system_track_sends_nothing(tmp_path, chosen):
    paths = recording(tmp_path, tone_track(30, []))
    assert transcription.system_track(None, paths, local=lambda: pytest.fail("no local run")) == "assemblyai"
    assert chosen.calls == [] and json.loads(paths.system_segments.read_text()) == []
    assert access_log.recent() == []


def test_a_failure_falls_back_to_this_mac_and_says_so(tmp_path, chosen, sent_notifications):
    chosen.fail = CloudError(f"AssemblyAI failed after 3 tries: HTTP 503")
    paths = recording(tmp_path, tone_track(10, [(2, 3)]))
    local = [Segment(2.0, 3.0, "lokal", None, [Word("lokal", 2.0, 3.0)])]
    engine = transcription.system_track(None, paths, local=lambda: (local, "de"))
    assert engine == "local"
    assert [s["text"] for s in json.loads(paths.system_segments.read_text())] == ["lokal"]
    marker = transcription.read_marker(paths)["system"]
    assert marker["engine"] == "local" and marker["fallback_from"] == "assemblyai" and "HTTP 503" in marker["error"]
    (title, message), = sent_notifications
    assert "on this Mac" in title + message and "AssemblyAI" in message
    (entry,) = access_log.recent()
    assert entry["ok"] is False and "HTTP 503" in entry["error"]
    assert len(chosen.made) == 1  # no other cloud was tried


def test_a_provider_no_longer_set_up_falls_back_to_this_mac(tmp_path, chosen, sent_notifications):
    providers.remove_key("assemblyai")
    paths = recording(tmp_path, tone_track(10, [(2, 3)]))
    assert transcription.system_track(None, paths, local=lambda: ([], None)) == "local"
    assert chosen.made == [] and access_log.recent() == []
    assert "Add the API key" in sent_notifications[0][1]


def test_keep_on_this_mac_is_transcribed_here(tmp_path, chosen):
    paths = recording(tmp_path, tone_track(10, [(2, 3)]))
    llm.set_local_only(paths.folder, True)
    assert transcription.system_track(None, paths, local=lambda: ([], None)) == "local"
    assert chosen.made == [] and chosen.calls == []
    assert transcription.read_marker(paths)["system"]["engine"] == "local"


def test_live_text_is_replaced_but_an_older_meeting_is_never_sent(tmp_path, chosen):
    live = recording(tmp_path / "a", tone_track(10, [(2, 3)]))
    live.system_segments.write_text(json.dumps([Segment(2, 3, "live", None, [Word("live", 2, 3)]).to_dict()]))
    transcription.write_marker(live, "system", engine="live")
    assert transcription.system_track(None, live, local=lambda: pytest.fail("no local run")) == "assemblyai"
    assert json.loads(live.system_segments.read_text())[0]["text"] != "live"

    old = recording(tmp_path / "b", tone_track(10, [(2, 3)]))
    old.system_segments.write_text("[]")  # transcribed before there was a choice: no marker
    assert transcription.system_track(None, old, local=lambda: pytest.fail("no local run")) is None
    assert len(chosen.calls) == 1


def test_a_cloud_failure_after_live_text_keeps_the_live_text(tmp_path, chosen):
    chosen.fail = CloudError("boom")
    paths = recording(tmp_path, tone_track(10, [(2, 3)]))
    paths.system_segments.write_text(json.dumps([Segment(2, 3, "live", None, [Word("live", 2, 3)]).to_dict()]))
    transcription.write_marker(paths, "system", engine="live")
    assert transcription.system_track(None, paths, local=lambda: pytest.fail("live text is enough")) == "live"
    assert json.loads(paths.system_segments.read_text())[0]["text"] == "live"
    assert transcription.read_marker(paths)["system"]["fallback_from"] == "assemblyai"


def test_live_marks_its_system_text_as_its_own(tmp_path):
    from palaver import live

    paths = RecordingPaths(tmp_path)
    live.mark_written(paths)
    assert transcription.read_marker(paths)["system"]["engine"] == "live"


# --- in `process` -------------------------------------------------------------------------------


def test_process_sends_the_system_track_and_keeps_the_mic_and_speakers_here(tmp_path, monkeypatch, chosen):
    paths = recording(tmp_path, tone_track(12, [(2, 3), (8, 9)]), mic=tone_track(12, [(5, 6)]))
    seen = _fake_models(monkeypatch, segments_for=lambda name: [Segment(5.0, 6.0, "ich", None, [Word("ich", 5, 6)])],
                        turns=[SpeakerTurn("SPEAKER_00", 1.5, 3.5), SpeakerTurn("SPEAKER_01", 7.5, 9.5)])
    assert cli._cmd_process(_ns(paths.folder)) == 0
    assert seen["calls"] == [("mic.wav", "de")]  # the mic on this Mac, in the language the cloud heard
    assert len(chosen.calls) == 1
    transcript = json.loads(paths.transcript_json.read_text())
    assert [(u["speaker"], round(u["start"])) for u in transcript] == [
        ("SPEAKER_00", 2), ("Timo", 5), ("SPEAKER_01", 8)]
    events = [json.loads(line) for line in paths.session_log.read_text().splitlines()]
    assert any(e.get("event") == "transcribe_done" and e.get("engine") == "assemblyai" for e in events)


def test_process_stays_local_by_default(tmp_path, monkeypatch):
    made = []
    monkeypatch.setattr(cloud_asr, "make", lambda *a, **kw: made.append(a))
    paths = recording(tmp_path, tone_track(5, [(1, 2)]))
    seen = _fake_models(monkeypatch)
    assert cli._cmd_process(_ns(paths.folder)) == 0
    assert made == [] and [c[0] for c in seen["calls"]] == ["system.wav", "mic.wav"]
    assert transcription.read_marker(paths)["system"]["engine"] == "local"
    assert access_log.recent() == []


# --- the Test button and the cost -----------------------------------------------------------------


def test_the_test_button_sends_a_tone_not_a_meeting(monkeypatch):
    providers.set_key("assemblyai", KEY)
    fake = FakeAdapter()
    monkeypatch.setattr(cloud_asr, "make", lambda pid, s, key, **kw: fake)
    result = transcription.test("assemblyai", None)
    assert result["model"] == "universal-3-5-pro" and result["seconds"] >= 0
    assert result["usd_per_hour"] == providers.PROVIDERS["assemblyai"].usd_per_hour
    assert fake.calls[0]["seconds"] <= 3 and fake.calls[0]["keyterms"] == []
    assert fake.calls[0]["fallback_language"]  # AssemblyAI needs one for a clip without speech
    (entry,) = access_log.recent()
    assert entry["feature"] == "test" and entry["meetings"] == []


def test_the_test_button_refuses_a_provider_not_set_up():
    with pytest.raises(transcription.Unavailable):
        transcription.test("assemblyai", None)
    with pytest.raises(ValueError):
        transcription.test("anthropic", None)


def test_cost_this_month_from_the_minutes_sent():
    from datetime import datetime

    now = datetime.now().astimezone()
    for seconds, ok in ((1800, True), (1800, True), (600, False)):
        access_log.record(provider="assemblyai", host="h", model="m", feature="transcription",
                          meetings=["2026-10-29T10-00-00"], chars=0, ok=ok, seconds=1, audio_seconds=seconds,
                          track="system")
    month = transcription.month(now)
    price = providers.PROVIDERS["assemblyai"].usd_per_hour
    assert month["seconds"] == 3600 and month["meetings"] == 1
    assert month["usd"] == pytest.approx(price)


# --- review fixes --------------------------------------------------------------------------


def test_stitch_gives_a_word_both_chunks_heard_differently_to_one_of_them():
    # A heard "Grenze" just before the seam (35), B heard "Grenzen" just after: one spoken word.
    a = [Word("vorher", 30.0, 30.5), Word("Grenze", 34.7, 35.2)]
    b = [Word("Grenzen", 34.9, 35.3), Word("danach", 36.0, 36.4)]
    assert [w.text for w in transcription.stitch([(0, 40, a), (30, 70, b)])] == ["vorher", "Grenze", "danach"]


def test_stitch_puts_a_word_exactly_on_the_seam_into_the_later_chunk_only():
    a = [Word("genau", 34.8, 35.2)]  # its middle is the seam
    b = [Word("genau", 34.8, 35.2), Word("so", 35.4, 35.6)]
    stitched = transcription.stitch([(0, 40, a), (30, 70, b)])
    assert [w.text for w in stitched] == ["genau", "so"]


def test_live_text_kept_locally_is_marked_local_so_a_later_cloud_never_sends_it(tmp_path, monkeypatch):
    paths = recording(tmp_path, tone_track(10, [(2, 3)]))
    paths.system_segments.write_text(json.dumps([Segment(2, 3, "live", None, [Word("live", 2, 3)]).to_dict()]))
    transcription.write_marker(paths, "system", engine="live")
    assert transcription.system_track(None, paths, local=lambda: pytest.fail("live text is enough")) is None
    assert transcription.read_marker(paths)["system"]["engine"] == "local"

    providers.set_key("assemblyai", KEY)
    providers.choose("transcription", "assemblyai")
    fake = FakeAdapter()
    monkeypatch.setattr(cloud_asr, "make", lambda *a, **kw: fake)
    assert transcription.system_track(None, paths, local=lambda: pytest.fail("no local run")) is None
    assert fake.calls == [] and access_log.recent() == []


def test_the_marker_is_written_before_the_segments(tmp_path, chosen, monkeypatch):
    paths = recording(tmp_path, tone_track(10, [(2, 3)]))
    seen = []
    real = transcription._save

    def save(path, text):
        if path == paths.system_segments:
            seen.append(transcription.read_marker(paths).get("system", {}).get("engine"))
        real(path, text)

    monkeypatch.setattr(transcription, "_save", save)
    transcription.system_track(None, paths, local=lambda: pytest.fail("no local run"))
    assert seen == ["assemblyai"]


def test_the_fallback_language_is_the_meeting_s(tmp_path, chosen):
    paths = recording(tmp_path, tone_track(10, [(2, 3)]))
    paths.language.write_text("de\n")  # the live worker heard German
    transcription.system_track(None, paths, local=lambda: pytest.fail("no local run"))
    assert chosen.calls[0]["fallback_language"] == "de" and chosen.calls[0]["language"] is None


def test_what_a_service_could_not_delete_is_kept_and_retried(tmp_path, chosen):
    from palaver.cloud_llm import Response

    paths = recording(tmp_path, tone_track(10, [(2, 3)]))
    url = "https://api.eu.assemblyai.com/v2/transcript/t9"
    chosen.pending.append({"provider": "assemblyai", "host": "api.eu.assemblyai.com", "what": "transcript",
                           "url": url})
    transcription.system_track(None, paths, local=lambda: pytest.fail("no local run"))
    left = json.loads(paths.cloud_pending.read_text())
    assert [e["url"] for e in left] == [url] and KEY not in paths.cloud_pending.read_text()

    answers = [Response(409, {}, b'{"error": "still processing"}'), Response(200, {}, b"{}")]
    sent = []

    def transport(request):
        sent.append(request)
        return answers.pop(0)

    assert transcription.sweep_pending(tmp_path, transport=transport) == 1  # refused: still there
    assert paths.cloud_pending.exists()
    assert transcription.sweep_pending(tmp_path, transport=transport) == 0
    assert not paths.cloud_pending.exists()
    assert [(r.method, r.url, r.headers["authorization"]) for r in sent] == [("DELETE", url, KEY)] * 2


def test_process_retries_pending_deletions_first(tmp_path, monkeypatch):
    swept = []
    monkeypatch.setattr(transcription, "sweep_pending", lambda root, **kw: swept.append(root) or 0)
    paths = recording(tmp_path, tone_track(5, [(1, 2)]))
    _fake_models(monkeypatch)
    assert cli._cmd_process(_ns(paths.folder)) == 0
    assert swept == [paths.folder.parent]
