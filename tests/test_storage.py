"""#9: what the meetings and models take; a transcribed meeting's audio can go."""

import json
from datetime import datetime
from pathlib import Path

import pytest

from palaver import storage
from palaver.paths import RecordingPaths

NOW = datetime(2026, 11, 2, 12, 0)


def _meeting(root: Path, name: str, *, transcribed: bool = True, audio: int = 1000) -> RecordingPaths:
    p = RecordingPaths(root / name)
    p.folder.mkdir(parents=True)
    for f in (p.mic_raw_wav, p.mic_wav, p.system_wav):
        f.write_bytes(b"\0" * audio)
    if transcribed:
        p.transcript_json.write_text("[]")
    p.notes.write_text("{}")
    return p


def test_drop_audio_keeps_the_transcript_and_says_so(tmp_path):
    p = _meeting(tmp_path, "2026-10-01T10-00-00")
    assert storage.drop_audio(p) == 3000
    assert storage.audio_files(p) == [] and p.transcript_json.exists() and p.notes.exists()
    assert storage.deleted(p)["bytes"] == 3000
    assert not storage.can_drop(p)


def test_an_untranscribed_meeting_keeps_its_audio(tmp_path):
    p = _meeting(tmp_path, "2026-10-01T10-00-00", transcribed=False)
    with pytest.raises(ValueError):
        storage.drop_audio(p)
    assert len(storage.audio_files(p)) == 3


def test_a_meeting_still_being_written_keeps_its_audio(tmp_path):
    p = _meeting(tmp_path, "2026-10-01T10-00-00")
    Path(str(p.system_wav) + ".part").write_bytes(b"\0")
    assert not storage.can_drop(p)


def test_drop_old_audio_only_older_than_the_days(tmp_path):
    old = _meeting(tmp_path, "2026-10-01T10-00-00")
    new = _meeting(tmp_path, "2026-10-30T10-00-00")
    pending = _meeting(tmp_path, "2026-09-01T10-00-00", transcribed=False)
    assert storage.drop_old_audio(tmp_path, 14, NOW) == (1, 3000)
    assert storage.audio_files(old) == []
    assert len(storage.audio_files(new)) == 3 and len(storage.audio_files(pending)) == 3
    assert storage.drop_old_audio(tmp_path, 0, NOW) == (0, 0)  # 0: kept


def test_audio_days_are_saved_and_checked():
    assert storage.audio_days() == 0
    storage.set_audio_days(30)
    assert storage.audio_days() == 30
    for wrong in (5, True, "30", None):
        with pytest.raises(ValueError):
            storage.set_audio_days(wrong)


def test_summary_counts_meetings_audio_and_what_would_go(tmp_path, monkeypatch):
    monkeypatch.setattr(storage, "models", lambda cfg=None: [])
    _meeting(tmp_path, "2026-10-01T10-00-00")
    _meeting(tmp_path, "2026-10-30T10-00-00", audio=500)
    (tmp_path / "not-a-meeting").mkdir()
    s = storage.summary(tmp_path, now=NOW)
    assert s["meetings"] == 2 and s["audio_bytes"] == 4500 and s["audio_meetings"] == 2
    assert s["bytes"] > s["audio_bytes"]
    assert s["older"]["14"] == {"meetings": 1, "bytes": 3000}
    assert s["older"]["90"] == {"meetings": 0, "bytes": 0}


def test_only_a_notes_model_not_in_use_can_be_deleted(tmp_path, monkeypatch):
    from palaver import llm, onboarding

    sizes = {onboarding.MODELS["gemma"].repo: 9, onboarding.RETIRED["qwen"].repo: 17,
             onboarding.RETIRED["parakeet"].repo: 2}
    monkeypatch.setattr(onboarding, "cached_bytes", lambda repo: sizes.get(repo, 0))
    monkeypatch.setattr(onboarding, "_hub_cache", lambda: tmp_path)
    monkeypatch.setattr(onboarding, "speech_here", lambda: True)
    monkeypatch.setattr(storage.Path, "home", classmethod(lambda cls: tmp_path / "home"))
    monkeypatch.setattr(llm, "local_model", lambda cfg: onboarding.MODELS["gemma"].repo)
    rows = {m["id"]: m for m in storage.models()}
    assert set(rows) == {"gemma", "qwen", "parakeet"}
    assert sorted(i for i, m in rows.items() if m["deletable"]) == ["qwen"]  # the old ones wait for the engine's proof
    from palaver import install_layout

    install_layout.engine_proven_marker().parent.mkdir(parents=True, exist_ok=True)
    install_layout.engine_proven_marker().write_text("1")
    rows = {m["id"]: m for m in storage.models()}
    assert sorted(i for i, m in rows.items() if m["deletable"]) == ["parakeet", "qwen"]
    qwen = onboarding._cache_dir(onboarding.RETIRED["qwen"].repo)
    qwen.mkdir(parents=True)
    assert storage.delete_model(None, "qwen") == 17 and not qwen.exists()
    for mid in ("gemma", "nope"):
        with pytest.raises(ValueError):
            storage.delete_model(None, mid)


def test_retired_models_listed_for_deletion(tmp_path, monkeypatch):
    """The Parakeet MLX cache and the pyannote copy (Palaver's own folder and the
    Hugging Face cache), with sizes; offered for deletion once the speech models
    are here, never deleted by themselves."""
    from palaver import install_layout, onboarding

    home = tmp_path / "home"
    monkeypatch.setattr(storage.Path, "home", classmethod(lambda cls: home))
    monkeypatch.setattr(onboarding, "_hub_cache", lambda: tmp_path / "hub")
    parakeet = onboarding._cache_dir(onboarding.RETIRED["parakeet"].repo)
    (parakeet / "blobs").mkdir(parents=True)
    (parakeet / "blobs" / "w").write_bytes(b"\0" * 2300)
    copy = install_layout.models_dir() / "pyannote-community-1"
    (copy / "segmentation").mkdir(parents=True)
    (copy / "segmentation" / "m.bin").write_bytes(b"\0" * 30)
    speech = install_layout.models_dir() / "fluidaudio" / "speaker-diarization"
    speech.mkdir(parents=True)
    (speech / "plda-parameters.json").write_bytes(b"\0" * 5)
    monkeypatch.setattr(onboarding, "speech_here", lambda: True)  # the models are here, but nothing ran with them yet
    rows = {m["id"]: m for m in storage.models()}
    assert (rows["parakeet"]["bytes"], rows["pyannote"]["bytes"], rows["speech"]["bytes"]) == (2300, 30, 5)
    assert not rows["parakeet"]["deletable"] and not rows["pyannote"]["deletable"] and not rows["speech"]["deletable"]
    assert storage.drop_retired(None) == 0 and parakeet.exists() and copy.exists()  # never by themselves
    install_layout.engine_proven_marker().write_text("1")  # a meeting transcribed with the engine
    rows = {m["id"]: m for m in storage.models()}
    assert rows["parakeet"]["deletable"] and rows["pyannote"]["deletable"] and not rows["speech"]["deletable"]
    assert storage.delete_model(None, "pyannote") == 30 and not copy.exists()
    assert storage.delete_model(None, "parakeet") == 2300 and not parakeet.exists()
    assert speech.exists()


def test_cleanup_runs_once_an_hour_and_only_when_asked(tmp_path, monkeypatch):
    runs = []
    monkeypatch.setattr(storage, "drop_old_audio", lambda root, days: runs.append(days))
    clock = [0.0]
    days = [0]
    c = storage.Cleanup(tmp_path, days=lambda: days[0], clock=lambda: clock[0])
    c.tick()
    days[0] = 30
    clock[0] = 10
    c.tick()  # not an hour yet
    clock[0] = 3601
    c.tick()
    c._thread.join()
    assert runs == [30]


def test_deleted_marker_survives_a_second_delete(tmp_path):
    p = _meeting(tmp_path, "2026-10-01T10-00-00")
    storage.drop_audio(p)
    p.mic_raw_wav.write_bytes(b"\0" * 10)  # e.g. put back by hand
    storage.drop_audio(p)
    assert json.loads((p.folder / storage.DELETED).read_text())["bytes"] == 3010


def test_a_model_no_longer_offered_goes_at_start(tmp_path, monkeypatch):
    from types import SimpleNamespace

    from palaver import onboarding

    monkeypatch.setattr(onboarding, "_hub_cache", lambda: tmp_path)
    qwen = onboarding._cache_dir(onboarding.QWEN)
    (qwen / "blobs").mkdir(parents=True)
    (qwen / "blobs" / "abc").write_bytes(b"\0" * 100)
    storage.settings.update({"local_model": onboarding.QWEN})  # chosen before: ignored now
    assert storage.drop_retired(None) == 100 and not qwen.exists()
    assert storage.drop_retired(None) == 0
    (qwen / "blobs").mkdir(parents=True)
    named = SimpleNamespace(notes_local_model=onboarding.QWEN)  # config.toml still names it: kept
    assert storage.drop_retired(named) == 0 and qwen.exists()


def test_a_successful_engine_run_sets_the_marker_a_failed_one_does_not(tmp_path, monkeypatch):
    from palaver import cli, engine, install_layout

    marker = install_layout.engine_proven_marker()
    assert not marker.exists() and engine.SUCCEEDED == set()
    cli._note_engine_run(0)  # nothing went through the engine: no proof
    assert not marker.exists()
    engine.SUCCEEDED.add("diarize")  # Whisper or a cloud service transcribed; only the speakers used the engine
    cli._note_engine_run(0)
    assert not marker.exists()
    engine.SUCCEEDED.add("transcribe")
    cli._note_engine_run(2)  # failed
    assert not marker.exists()
    cli._note_engine_run(0)  # engine transcribe and diarize, exit 0
    assert marker.exists()


def test_a_whisper_run_with_engine_speakers_does_not_prove_the_engine(tmp_path, monkeypatch):
    """The real command: Whisper transcribes, the engine diarizes, exit 0: no marker."""
    from palaver import cli, install_layout
    from tests.test_cli import _fake_models, _ns, _recording_folder

    _recording_folder(tmp_path)
    _fake_models(monkeypatch, fake_diarizer=False)  # the real EngineDiarizer, the fake engine
    monkeypatch.setenv("PALAVER_ENGINE", str(Path(__file__).parent / "fake_engine.py"))
    assert cli._cmd_process(_ns(tmp_path)) == 0
    assert not install_layout.engine_proven_marker().exists()


def test_the_engine_for_both_stages_proves_the_engine(tmp_path, monkeypatch):
    from palaver import cli, install_layout, transcriber
    from tests.test_cli import _fake_models, _ns, _recording_folder

    _recording_folder(tmp_path)
    _fake_models(monkeypatch, fake_diarizer=False)
    monkeypatch.setattr(cli, "_make_transcriber", lambda cfg, d: transcriber.EngineTranscriber(
        __import__("palaver.dictionary", fromlist=["Dictionary"]).Dictionary()))
    monkeypatch.setenv("PALAVER_ENGINE", str(Path(__file__).parent / "fake_engine.py"))
    assert cli._cmd_process(_ns(tmp_path)) == 0
    assert install_layout.engine_proven_marker().exists()


def test_the_live_diarizers_scratch_counts_as_audio_and_is_deleted_with_it(tmp_path):
    p = _meeting(tmp_path, "2026-10-01T10-00-00")
    scratch = p.folder / ".live-diarize.wav"
    scratch.write_bytes(b"\0" * 500)
    assert scratch in storage.audio_files(p) and storage.audio_bytes(p) == 3500
    assert storage.drop_audio(p) == 3500
    assert not scratch.exists()


def test_retention_removes_the_live_diarizers_scratch(tmp_path):
    p = _meeting(tmp_path, "2026-10-01T10-00-00")
    scratch = p.folder / ".live-diarize.wav"
    scratch.write_bytes(b"\0" * 500)
    assert storage.drop_old_audio(tmp_path, 7, now=NOW) == (1, 3500)
    assert not scratch.exists()
