"""Tests for recording-folder path helpers."""

from datetime import datetime
from pathlib import Path

from palaver.paths import RecordingPaths, new_recording_folder


def test_new_recording_folder_uses_timestamp(tmp_path: Path):
    dt = datetime(2026, 4, 17, 14, 30, 0)
    folder = new_recording_folder(tmp_path, dt)
    assert folder.parent == tmp_path
    assert folder.name == "2026-04-17T14-30-00"
    assert folder.exists()


def test_new_recording_folder_appends_suffix_on_collision(tmp_path: Path):
    dt = datetime(2026, 4, 17, 14, 30, 0)
    first = new_recording_folder(tmp_path, dt)
    second = new_recording_folder(tmp_path, dt)
    assert first != second
    assert second.exists()


def test_recording_paths_surfaces_all_files(tmp_path: Path):
    r = RecordingPaths(tmp_path)
    assert r.mic_wav == tmp_path / "mic.wav"
    assert r.system_wav == tmp_path / "system.wav"
    assert r.meta == tmp_path / "meta.json"
    assert r.mic_segments == tmp_path / "mic_segments.json"
    assert r.system_segments == tmp_path / "system_segments.json"
    assert r.system_turns == tmp_path / "system_turns.json"
    assert r.transcript_json == tmp_path / "transcript.json"
    assert r.transcript_md == tmp_path / "transcript.md"
    assert r.notion_info == tmp_path / "notion.json"
    assert r.session_log == tmp_path / "session.log"


def test_mic_raw_wav_path():
    from pathlib import Path
    paths = RecordingPaths(Path("/tmp/x"))
    assert paths.mic_raw_wav == Path("/tmp/x/mic_raw.wav")


def test_is_recording_folder_name():
    from palaver.paths import is_recording_folder_name

    assert is_recording_folder_name("2026-10-20T14-35-17")
    assert is_recording_folder_name("2026-10-20T14-35-17-2")
    assert not is_recording_folder_name("notes")
    assert not is_recording_folder_name("2026-10-20T14-35-17.txt")
