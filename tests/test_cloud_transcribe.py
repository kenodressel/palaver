"""`palaver cloud-transcribe <folder>`: the system track through the chosen service, as palaver-worker's child
(palaver/cloud_transcribe.py). Fake service and fake engine only."""

import json

from palaver import cli, cloud_transcribe, transcription
from palaver.cloud_llm import CloudError
from palaver.engine import ModelsMissing

from .test_transcription import chosen, recording, tone_track  # noqa: F401 - the fixture is used by name


class FakeEngine:
    """palaver-engine's client for the fallback: answers, or raises what it is given."""

    def __init__(self, fail: Exception | None = None):
        self.fail, self.calls = fail, []

    def call(self, cmd, **args):
        self.calls.append((cmd, args))
        if self.fail:
            raise self.fail
        return {"segments": [{"start": 2.0, "end": 3.0, "text": " lokal ", "words": [
            {"text": "lokal", "start": 2.0, "end": 3.0, "confidence": 0.9}]}]}


def _names(folder):
    return sorted(p.name for p in folder.iterdir())


def test_cloud_transcribe_writes_only_the_system_track(tmp_path, chosen):  # noqa: F811
    paths = recording(tmp_path, tone_track(12, [(2, 3), (8, 9)]))
    before = set(_names(paths.folder))
    engine = FakeEngine()
    assert cloud_transcribe.run(None, paths.folder, engine=engine) == 0
    assert set(_names(paths.folder)) - before == {"system_segments.json", "transcription.json", "language.txt",
                                                  "session.log"}
    assert len(chosen.calls) == 1 and engine.calls == []
    assert transcription.read_marker(paths)["system"]["engine"] == "assemblyai"
    events = [json.loads(line) for line in paths.session_log.read_text().splitlines()]
    assert any(e.get("event") == "transcribe_done" and e.get("engine") == "assemblyai" for e in events)
    # Done already: the service is not asked again.
    assert cloud_transcribe.run(None, paths.folder, engine=engine) == 0
    assert len(chosen.calls) == 1


def test_a_failed_service_falls_back_to_the_engine_and_says_so(tmp_path, chosen, sent_notifications):  # noqa: F811
    chosen.fail = CloudError("AssemblyAI failed after 3 tries: HTTP 503")
    paths = recording(tmp_path, tone_track(10, [(2, 3)]))
    engine = FakeEngine()
    assert cloud_transcribe.run(None, paths.folder, engine=engine) == 0
    assert [c[0] for c in engine.calls] == ["transcribe"]
    assert [s["text"] for s in json.loads(paths.system_segments.read_text())] == ["lokal"]
    marker = transcription.read_marker(paths)["system"]
    assert marker["engine"] == "local" and marker["fallback_from"] == "assemblyai"
    (title, _), = sent_notifications
    assert title == "Transcribed on this Mac"


def test_exit_3_when_the_fallback_has_no_models(tmp_path, chosen, capsys):  # noqa: F811
    chosen.fail = CloudError("AssemblyAI failed after 3 tries: HTTP 503")
    paths = recording(tmp_path, tone_track(10, [(2, 3)]))
    rc = cloud_transcribe.run(None, paths.folder, engine=FakeEngine(ModelsMissing("models missing: asr")))
    assert rc == cloud_transcribe.EXIT_MODELS == 3
    assert capsys.readouterr().err.strip().splitlines()[-1] == "models missing: asr"
    assert not paths.system_segments.exists()


def test_exit_4_on_an_error(tmp_path, chosen, capsys):  # noqa: F811
    chosen.fail = CloudError("AssemblyAI failed after 3 tries: HTTP 503")
    paths = recording(tmp_path, tone_track(10, [(2, 3)]))
    rc = cloud_transcribe.run(None, paths.folder, engine=FakeEngine(RuntimeError("the engine crashed\nexit 6")))
    assert rc == cloud_transcribe.EXIT_ERROR == 4
    assert capsys.readouterr().err.strip().splitlines()[-1] == "exit 6"
    assert not paths.system_segments.exists()
    assert cloud_transcribe.run(None, tmp_path / "gone") == 4


def test_no_cloud_choice_does_nothing_and_exits_0(tmp_path):
    paths = recording(tmp_path, tone_track(5, [(1, 2)]))
    before = set(_names(paths.folder))
    engine = FakeEngine()
    assert cloud_transcribe.run(None, paths.folder, engine=engine) == 0
    assert set(_names(paths.folder)) - before <= {"session.log"}
    assert engine.calls == []


def test_the_cli_routes_cloud_transcribe(tmp_path, monkeypatch):
    seen = {}

    def fake_run(cfg, folder, dictionary_path):
        seen.update(folder=folder, dictionary=dictionary_path)
        return 3

    monkeypatch.setattr(cloud_transcribe, "run", fake_run)
    words = tmp_path / "words.toml"
    words.write_text("")
    assert cli.main(["--dictionary", str(words), "cloud-transcribe", str(tmp_path)]) == 3
    assert seen == {"folder": tmp_path, "dictionary": words}
