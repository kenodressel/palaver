"""Basic CLI smoke tests — don't exercise heavy subcommands."""

import json
import signal
import time
from pathlib import Path

import numpy as np
import soundfile as sf

from palaver.cli import (
    _promote_part_files,
    _status,
    _synthesize_meta_from_audio,
    main,
)
from palaver.paths import RecordingPaths


def test_help_exits_cleanly(capsys):
    try:
        main(["--help"])
    except SystemExit as e:
        assert e.code == 0
    out = capsys.readouterr().out
    assert "record" in out
    assert "process" in out
    assert "sync" in out


def test_list_empty_output_dir(tmp_path, monkeypatch):
    cfg = tmp_path / "config.toml"
    cfg.write_text(
        f"""
        [user]
        name = "Timo"
        [notion]
        token = "ntn_test"
        parent_page_id = "p"
        [recording]
        output_dir = "{tmp_path / "recs"}"
        """
    )
    rc = main(["--config", str(cfg), "list"])
    assert rc == 0


def test_status_precedence(tmp_path: Path):
    # incomplete: no wavs
    paths = RecordingPaths(tmp_path)
    assert _status(paths) == "incomplete"

    # recorded: a V2 capture (pre-AEC mic + system) but no transcript
    paths.mic_raw_wav.write_bytes(b"RIFF...")
    paths.system_wav.write_bytes(b"RIFF...")
    assert _status(paths) == "recorded"

    # processed: transcript exists
    paths.transcript_json.write_text("[]")
    assert _status(paths) == "processed"

    # synced: notion info exists (highest precedence)
    paths.notion_info.write_text("{}")
    assert _status(paths) == "synced"


def test_status_synced_takes_precedence_even_if_transcript_missing(tmp_path: Path):
    # Degenerate case: notion_info exists but transcript doesn't. Should still
    # report synced because the canonical output lives in Notion.
    paths = RecordingPaths(tmp_path)
    paths.notion_info.write_text("{}")
    assert _status(paths) == "synced"


def test_status_crashed_when_part_files_remain(tmp_path: Path):
    paths = RecordingPaths(tmp_path)
    Path(str(paths.mic_raw_wav) + ".part").write_bytes(b"RIFF...")
    Path(str(paths.system_wav) + ".part").write_bytes(b"RIFF...")
    assert _status(paths, now=time.time() + 3600).startswith("crashed")


def test_status_recording_while_part_files_still_grow(tmp_path: Path):
    paths = RecordingPaths(tmp_path)
    Path(str(paths.mic_raw_wav) + ".part").write_bytes(b"RIFF...")
    assert _status(paths) == "recording"


def _write_silent_wav(path: Path, seconds: float, sr: int = 16_000) -> None:
    samples = np.zeros(int(sr * seconds), dtype=np.int16)
    # Explicit format so paths like `foo.wav.part` (where the extension would
    # otherwise resolve to `.part`) still get written as WAV.
    sf.write(str(path), samples, sr, subtype="PCM_16", format="WAV")


def test_promote_part_files_renames_orphans(tmp_path: Path):
    paths = RecordingPaths(tmp_path)
    mic_part = Path(str(paths.mic_raw_wav) + ".part")
    sys_part = Path(str(paths.system_wav) + ".part")
    _write_silent_wav(mic_part, 0.5)
    _write_silent_wav(sys_part, 0.5)

    _promote_part_files(paths)

    assert not mic_part.exists()
    assert not sys_part.exists()
    assert paths.mic_raw_wav.exists()
    assert paths.system_wav.exists()


def test_promote_part_files_skips_when_final_already_present(tmp_path: Path):
    """If a clean stop wrote the final file directly, we must not clobber
    it with a stale .part — drop the .part if it somehow exists."""
    paths = RecordingPaths(tmp_path)
    _write_silent_wav(paths.mic_raw_wav, 1.0)
    stale_part = Path(str(paths.mic_raw_wav) + ".part")
    stale_part.write_bytes(b"junk")
    # Final file is the source of truth.
    final_size_before = paths.mic_raw_wav.stat().st_size

    _promote_part_files(paths)

    assert paths.mic_raw_wav.stat().st_size == final_size_before
    # .part is left as-is for the user to investigate; we do NOT clobber the
    # final file. (If we wanted to delete the orphan, we would here, but
    # silently nuking files is worse than leaving the noise.)


def test_synthesize_meta_from_audio_recovers_from_folder_name(tmp_path: Path):
    folder = tmp_path / "2026-04-29T14-30-00"
    folder.mkdir()
    paths = RecordingPaths(folder)
    _write_silent_wav(paths.mic_raw_wav, 12.5)

    ok = _synthesize_meta_from_audio(folder, paths)
    assert ok is True
    assert paths.meta.exists()

    meta = json.loads(paths.meta.read_text())
    assert meta["duration_seconds"] == 12.5
    assert meta["start_time"].startswith("2026-04-29T14:30:00")
    assert meta["end_time"].startswith("2026-04-29T14:30:12")


def test_synthesize_meta_from_audio_returns_false_without_audio(tmp_path: Path):
    folder = tmp_path / "2026-04-29T14-30-00"
    folder.mkdir()
    paths = RecordingPaths(folder)
    ok = _synthesize_meta_from_audio(folder, paths)
    assert ok is False
    assert not paths.meta.exists()


def test_synthesize_meta_from_audio_returns_false_on_unparseable_folder(tmp_path: Path):
    folder = tmp_path / "not-a-timestamp"
    folder.mkdir()
    paths = RecordingPaths(folder)
    _write_silent_wav(paths.mic_raw_wav, 1.0)
    ok = _synthesize_meta_from_audio(folder, paths)
    assert ok is False
    assert not paths.meta.exists()


class _FakeCfg:
    user_name = "Timo"
    whisper_repo = "r"
    diarizer_repo = "d"
    hf_token = "t"
    language = "auto"
    notion_token = "ntn_test"
    notion_parent_page_id = "parent"
    notion_mode = "page"
    notion_database_id = None
    transcriber = "mlx-whisper"
    parakeet_repo = "p"
    notes_enabled = True
    notes_engine = "local"
    notes_local_model = "m"
    notes_model = "sonnet"
    claude_path = None


def _recording_folder(tmp_path: Path, seconds: float = 1.0) -> RecordingPaths:
    import numpy as np
    import soundfile as sf

    tmp_path.mkdir(parents=True, exist_ok=True)
    paths = RecordingPaths(tmp_path)
    for wav in (paths.mic_wav, paths.system_wav):
        sf.write(
            str(wav), np.zeros(int(seconds * 16_000), dtype=np.float32), 16_000, subtype="PCM_16"
        )
    paths.meta.write_text(
        f'{{"start_time": "2026-10-20T14:35:17+02:00", "duration_seconds": {seconds}}}'
    )
    return paths


def _fake_models(monkeypatch, *, segments_for=None, turns=None, embeddings=None) -> dict:
    """Patch Whisper/pyannote with fakes; returns a dict recording their use."""
    from palaver import cli
    from palaver.models import Segment

    seen: dict = {"calls": [], "dictionary": None}

    def _default_segments(wav):
        return [Segment(start=0.0, end=1.0, text="hallo", speaker=None, words=[])]

    class _FakeTranscriber:
        def __init__(self, *, dictionary, **_):
            seen["dictionary"] = dictionary
            self.last_language = None

        def transcribe(self, wav, language=None):
            seen["calls"].append((Path(wav).name, language))
            self.last_language = language or "de"
            return (segments_for or _default_segments)(Path(wav).name)

    class _FakeDiarizer:
        def __init__(self, **_):
            self.last_embeddings = dict(embeddings or {})

        def diarize(self, wav):
            return list(turns or [])

    monkeypatch.setattr("palaver.transcriber.MlxWhisperTranscriber", _FakeTranscriber)
    monkeypatch.setattr("palaver.diarizer.PyannoteDiarizer", _FakeDiarizer)
    monkeypatch.setattr(cli, "_load_cfg", lambda _args: _FakeCfg())
    return seen


def _ns(folder: Path, dictionary: Path | None = None):
    import argparse

    return argparse.Namespace(
        folder=str(folder), config=None, dictionary=str(dictionary) if dictionary else None
    )


def test_mic_language_follows_system_track_when_auto(tmp_path: Path, monkeypatch):
    """With language="auto", Whisper detects the mic track's language from its
    first 30 s, which after AEC is often near-silence (a real meeting came out
    as Spanish). The system track's detected language is reused instead."""
    from palaver import cli

    paths = _recording_folder(tmp_path)
    seen = _fake_models(monkeypatch)

    assert cli._cmd_process(_ns(tmp_path)) == 0
    assert seen["calls"] == [("system.wav", None), ("mic.wav", "de")]
    assert paths.language.read_text().strip() == "de"


def test_process_removes_the_echo_cancelled_part_a_stopped_live_worker_left(tmp_path: Path, monkeypatch):
    """A live worker stopped or killed during the call leaves its unfinished
    mic.wav.part; once `process` has the final mic.wav, nothing reads it."""
    from palaver import cli

    paths = _recording_folder(tmp_path)
    stale = Path(str(paths.mic_wav) + ".part")
    stale.write_bytes(b"\0" * 1000)
    _fake_models(monkeypatch)

    assert cli._cmd_process(_ns(tmp_path)) == 0
    assert paths.mic_wav.exists() and not stale.exists()


def test_process_uses_dictionary_flag(tmp_path: Path, monkeypatch):
    from palaver import cli

    _recording_folder(tmp_path / "rec")
    seen = _fake_models(monkeypatch)
    vocab = tmp_path / "legal.toml"
    vocab.write_text('[replacements]\n"kay pee eye" = "KPI"\n')

    assert cli._cmd_process(_ns(tmp_path / "rec", dictionary=vocab)) == 0
    assert seen["dictionary"].replacements == {"kay pee eye": "KPI"}


def test_process_rejects_missing_explicit_dictionary(tmp_path: Path, monkeypatch, capsys):
    from palaver import cli

    _recording_folder(tmp_path / "rec")
    _fake_models(monkeypatch)

    rc = cli._cmd_process(_ns(tmp_path / "rec", dictionary=tmp_path / "nope.toml"))
    assert rc == 2
    assert "nope.toml" in capsys.readouterr().out


def test_dictionary_flag_is_parsed_before_subcommand(monkeypatch):
    from palaver import cli

    got = {}
    monkeypatch.setattr(cli, "_cmd_process", lambda args: got.update(vars(args)) or 0)
    assert cli.main(["--dictionary", "legal.toml", "process", "/x"]) == 0
    assert got["dictionary"] == "legal.toml"


def test_cli_has_stream_command(capsys):
    try:
        main(["stream", "--help"])
    except SystemExit as e:
        assert e.code == 0
    assert "folder" in capsys.readouterr().out


def test_bench_live_runs_the_replay_bench(tmp_path: Path, monkeypatch, capsys):
    from palaver import cli, stream_bench
    from palaver.transcriber import ParakeetMlxTranscriber

    class Cfg:
        user_name = "Me"
        parakeet_repo = "repo/parakeet"

    got = {}
    monkeypatch.setattr(cli, "_load_cfg", lambda _args: Cfg())
    monkeypatch.setattr("palaver.dictionary.load_dictionary", lambda path=None: "dictionary")
    def fake_run(folders, out, **kw):
        got.update(folders=folders, out=out, **kw)
        try:  # a guard's SIGTERM unwinds the bench, so its children get killed
            signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)
        except SystemExit:
            got["sigterm"] = "exits"
        return out / "report.md"

    monkeypatch.setattr(stream_bench, "run", fake_run)
    before = signal.getsignal(signal.SIGTERM)
    assert main(["--no-notify", "bench-live", "/m/a", "/m/b", "--speed", "2", "--out", str(tmp_path)]) == 0
    assert got["folders"] == [Path("/m/a"), Path("/m/b")]
    assert got["out"] == tmp_path
    assert got["speed"] == 2.0 and got["user_name"] == "Me" and got["cli_options"] == ["--no-notify"]
    assert isinstance(got["transcriber"], ParakeetMlxTranscriber)
    assert str(tmp_path / "report.md") in capsys.readouterr().out
    assert got["sigterm"] == "exits"
    assert signal.getsignal(signal.SIGTERM) == before


class _StreamCfg:
    parakeet_repo = "repo/parakeet"


def _fake_stream(monkeypatch, got: dict) -> None:
    from palaver import cli, stream, stream_engine

    monkeypatch.setattr(cli, "_load_cfg", lambda _args: _StreamCfg())
    monkeypatch.setattr(stream_engine, "load_engines", lambda repo, dictionary: got.setdefault("loaded", repo)
                        and (object(), object()))
    monkeypatch.setattr(stream_engine, "mlx_peak_mb", lambda: 1234)
    monkeypatch.setattr(stream, "RealtimeProcessor", lambda paths, **kw: "processor")

    def run_stream(processor, paths, **kw):
        got["memory"] = kw.get("memory")
        got["pid_during_run"] = paths.stream_pid.read_text()
        return True

    monkeypatch.setattr(stream, "run_stream", run_stream)


def _events(paths: RecordingPaths) -> list[dict]:
    return [json.loads(line) for line in paths.session_log.read_text().splitlines()]


def test_stream_runs_with_the_memory_cap(tmp_path: Path, monkeypatch):
    import os

    from palaver import cli, stream_engine

    got: dict = {}
    _fake_stream(monkeypatch, got)
    assert cli._cmd_stream(_ns(tmp_path)) == 0
    assert got["loaded"] == "repo/parakeet"
    assert got["memory"] is stream_engine.mlx_memory
    assert got["pid_during_run"] == str(os.getpid())
    paths = RecordingPaths(tmp_path)
    assert not paths.stream_pid.exists()
    done = [e for e in _events(paths) if e.get("event") == "stream_done"]
    assert done and done[0]["finished"] is True and done[0]["peak_mb"] == 1234


def test_stream_refuses_a_second_stream(tmp_path: Path, monkeypatch):
    import os

    from palaver import cli

    got: dict = {}
    _fake_stream(monkeypatch, got)
    paths = RecordingPaths(tmp_path)
    other = os.getppid()  # alive, and not this process
    paths.stream_pid.write_text(str(other))
    assert cli._cmd_stream(_ns(tmp_path)) == 0
    assert "loaded" not in got
    assert paths.stream_pid.read_text() == str(other)  # the running stream's pid file stays
    assert [e["pid"] for e in _events(paths) if e.get("event") == "stream_already_running"] == [other]


def test_process_can_leave_the_notes_for_later(tmp_path: Path, monkeypatch):
    """The app transcribes right away but writes notes when no call records."""
    from palaver import cli

    _recording_folder(tmp_path / "rec")
    _fake_models(monkeypatch)
    written = []
    monkeypatch.setattr(cli, "_write_notes", lambda *a, **kw: written.append(a))
    args = _ns(tmp_path / "rec")
    args.no_notes = True
    assert cli._cmd_process(args) == 0
    assert written == []
    args.no_notes = False
    assert cli._cmd_process(args) == 0
    assert len(written) == 1


def test_projects_no_wait_exits_at_once_while_the_model_is_in_use(notes_lock_in_tmp, monkeypatch):
    import fcntl
    import time

    from palaver import cli

    monkeypatch.setattr(cli, "_load_cfg", lambda args: None)
    with open(notes_lock_in_tmp, "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        assert not cli.notes_lock_free()
        start = time.monotonic()
        assert cli.main(["projects", "suggest", "--no-wait"]) == cli.EXIT_MODEL_BUSY
        assert time.monotonic() - start < 2
    assert cli.notes_lock_free()


def test_a_crashed_recordings_audio_problems_reach_meta(tmp_path: Path):
    """Issue #50: the recorder keeps its incidents beside the audio as they
    open and end, so a crash before stop() does not lose them."""
    folder = tmp_path / "2026-04-29T14-30-00"
    folder.mkdir()
    paths = RecordingPaths(folder)
    _write_silent_wav(paths.mic_raw_wav, 12.5)
    paths.audio_problems.write_text(json.dumps([
        {"kind": "speed", "track": "system", "start": 2.0, "end": 4.0, "at": "2026-04-29T14:30:02+02:00"},
        {"kind": "stalled", "track": "mic", "start": 9.0, "end": None, "at": "2026-04-29T14:30:09+02:00"}]))

    assert _synthesize_meta_from_audio(folder, paths)
    meta = json.loads(paths.meta.read_text())
    assert [(p["kind"], p["start"], p["end"]) for p in meta["audio_problems"]] == [
        ("speed", 2.0, 4.0), ("stalled", 9.0, 12.5)]  # still open when it crashed: to the end
    assert not paths.audio_problems.exists()


def test_segments_are_saved_whole_or_not_at_all(tmp_path, monkeypatch):
    """`process` skips a track whose segments file exists: a kill while it is
    written must not leave half of one (#49)."""
    from pathlib import Path

    from palaver import cli
    from palaver.models import Segment

    target = tmp_path / "system_segments.json"
    segments = [Segment(0.0, 1.0, "hallo"), Segment(1.0, 2.0, "welt")]

    def killed(self, other):
        raise KeyboardInterrupt

    real_replace = Path.replace
    monkeypatch.setattr(Path, "replace", killed)
    try:
        cli._save_segments(target, segments)
    except KeyboardInterrupt:
        pass
    assert not target.exists()
    monkeypatch.setattr(Path, "replace", real_replace)
    cli._save_segments(target, segments)
    import json

    assert [s["text"] for s in json.loads(target.read_text())] == ["hallo", "welt"]


def _index_config(tmp_path: Path) -> Path:
    cfg = tmp_path / "config.toml"
    cfg.write_text(f'[user]\nname = "Timo"\n[notion]\ntoken = "ntn_test"\nparent_page_id = "p"\n'
                   f'[recording]\noutput_dir = "{tmp_path / "recs"}"\n')
    return cfg


def test_index_builds_the_search_index_of_stale_meetings(tmp_path: Path, monkeypatch):
    from palaver import semantic, settings

    calls = []
    monkeypatch.setattr(semantic, "index_stale", lambda output_dir, **kw: calls.append(output_dir) or 2)
    cfg = _index_config(tmp_path)
    assert main(["--config", str(cfg), "index"]) == 0
    assert calls == [tmp_path / "recs"]
    settings.update({"search_meaning": False})
    assert main(["--config", str(cfg), "index"]) == 0
    assert calls == [tmp_path / "recs"]  # switched off: nothing indexed, nothing downloaded


def test_audio_problems_left_beside_a_finished_meta_are_folded_in(tmp_path: Path):
    """A crash between meta.json and folding the incidents in: recovery
    finishes the job (issue #50)."""
    from palaver import continuation

    folder = tmp_path / "2026-04-29T14-30-00"
    folder.mkdir()
    paths = RecordingPaths(folder)
    _write_silent_wav(paths.mic_raw_wav, 12.5)
    paths.meta.write_text(json.dumps({"start_time": "2026-04-29T14:30:00+02:00", "duration_seconds": 12.5}))
    paths.audio_problems.write_text(json.dumps([
        {"kind": "stalled", "track": "mic", "start": 9.0, "end": None, "at": "2026-04-29T14:30:09+02:00"}]))

    assert continuation._recover(paths)
    meta = json.loads(paths.meta.read_text())
    assert [(p["kind"], p["start"], p["end"]) for p in meta["audio_problems"]] == [("stalled", 9.0, 12.5)]
    assert meta["duration_seconds"] == 12.5
    assert not paths.audio_problems.exists()


def test_folding_audio_problems_keeps_those_meta_already_has(tmp_path: Path):
    from palaver.cli import _fold_audio_problems

    folder = tmp_path / "2026-04-29T14-30-00"
    folder.mkdir()
    paths = RecordingPaths(folder)
    kept = [{"kind": "speed", "track": "system", "start": 2.0, "end": 4.0}]
    paths.meta.write_text(json.dumps({"duration_seconds": 12.5, "audio_problems": kept}))
    paths.audio_problems.write_text(json.dumps(kept))
    _fold_audio_problems(paths)
    assert json.loads(paths.meta.read_text())["audio_problems"] == kept
    assert not paths.audio_problems.exists()


def test_app_restart_web_restarts_only_the_server(monkeypatch, capsys):
    from palaver import appctl

    calls = []
    monkeypatch.setattr(appctl, "call", lambda name, args=None, **kw: calls.append((name, kw)) or {"pid": 4321})
    assert main(["app", "restart-web"]) == 0
    assert calls[0][0] == "restart_web" and calls[0][1]["timeout"] >= 10
    assert "4321" in capsys.readouterr().out


def test_app_restart_web_without_a_running_app(monkeypatch, capsys):
    from palaver import appctl

    def gone(name, args=None, **kw):
        raise appctl.CallFailed("no socket")

    monkeypatch.setattr(appctl, "call", gone)
    assert main(["app", "restart-web"]) == 1
    assert "not running" in capsys.readouterr().out


def test_notes_are_written_knowing_the_title_the_user_gave_the_meeting(tmp_path: Path, monkeypatch):
    from datetime import datetime
    from types import SimpleNamespace

    from palaver import cli, llm, titles
    from palaver.models import Utterance

    paths = RecordingPaths(tmp_path / "2026-10-27T12-04-00")
    paths.folder.mkdir()
    titles.save(paths, "Budget with Anna")
    seen = {}

    def run(prompt, schema):
        seen["prompt"] = prompt
        return {"title": "Budget", "summary": "", "sections": [], "next_steps": [], "decisions": [],
                "speaker_names": []}

    monkeypatch.setattr(llm, "engine", lambda *a, **kw: llm.Engine("local", "Test", "test", False, 8000, run))
    monkeypatch.setattr(cli, "_sort_into_projects", lambda cfg, paths: None)
    start = datetime(2026, 10, 27, 12, 4).astimezone()
    assert cli._write_notes_now(SimpleNamespace(user_name="Timo"), paths, [Utterance("Timo", 0, 1, "Hallo.")], start)
    assert 'The user calls the meeting "Budget with Anna".' in seen["prompt"]
