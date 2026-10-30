"""A recording cut by a Palaver restart and its continuation, joined into
one meeting before it is processed (issue #47)."""

import json
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np
import soundfile as sf

from palaver import continuation
from palaver.paths import RecordingPaths

SR = 16_000
# Folder names are local wall time, so the start is too (CI runs in UTC).
T0 = datetime(2026, 10, 29, 12, 6, 10).astimezone()
VOICE = [1.0, 0.0, 0.0]


def _part(root: Path, start: datetime, seconds: int, *, live: bool, stop_reason: str = "restart") -> RecordingPaths:
    """A recorded part; ``live``: the live worker finished it (mic.wav,
    segments, turns, voices)."""
    paths = RecordingPaths(root / start.strftime("%Y-%m-%dT%H-%M-%S"))
    paths.folder.mkdir(parents=True)
    tone = np.full(seconds * SR, 7, np.int16)
    for track in (paths.mic_raw_wav, paths.system_wav):
        sf.write(str(track), tone, SR, subtype="PCM_16")
    paths.meta.write_text(json.dumps({
        "start_time": start.isoformat(), "end_time": (start + timedelta(seconds=seconds)).isoformat(),
        "duration_seconds": seconds, "trigger": "teams", "stop_reason": stop_reason}))
    if live:
        sf.write(str(paths.mic_wav), tone, SR, subtype="PCM_16")
        paths.system_segments.write_text(json.dumps([{"start": 1.0, "end": 3.0, "text": "Hallo.", "speaker": None}]))
        paths.mic_segments.write_text(json.dumps([{"start": 4.0, "end": 5.0, "text": "Ja.", "speaker": "Timo"}]))
        paths.system_turns.write_text(json.dumps([{"speaker": "SPEAKER_00", "start": 1.0, "end": 3.0}]))
        paths.speaker_embeddings.write_text(json.dumps({"SPEAKER_00": VOICE}))
    return paths


def test_parts_are_listed_on_the_first_part_in_order(tmp_path):
    a, b, c = tmp_path / "a", tmp_path / "b", tmp_path / "c"
    a.mkdir()
    assert continuation.parts(a) == []
    continuation.add_part(a, b)
    continuation.add_part(a, c)
    continuation.add_part(a, c)  # once
    assert continuation.parts(a) == [b, c]


def test_parts_the_live_worker_finished_are_joined_with_their_transcription(tmp_path):
    a = _part(tmp_path, T0, 30, live=True)
    b = _part(tmp_path, T0 + timedelta(seconds=39), 60, live=True, stop_reason="call_ended")
    continuation.add_part(a.folder, b.folder)

    assert continuation.join_parts(a) == 1
    assert not b.folder.exists() and not a.parts.exists()
    meta = json.loads(a.meta.read_text())
    assert meta["gaps"] == [{"start": 30.0, "end": 39.0, "why": "restart"}]
    assert meta["stop_reason"] == "call_ended" and meta["duration_seconds"] == 99
    assert sf.info(str(a.mic_wav)).duration == 99
    assert [s["start"] for s in json.loads(a.system_segments.read_text())] == [1.0, 40.0]
    assert [t["start"] for t in json.loads(a.system_turns.read_text())] == [1.0, 40.0]
    assert not a.transcript_json.exists()  # `process` merges it anew


def test_a_part_whose_live_worker_was_stopped_is_transcribed_whole(tmp_path):
    """The live worker of the cut part died with the app: nothing derived
    is kept, so `process` does all of it over the joined audio."""
    a = _part(tmp_path, T0, 30, live=False)
    b = _part(tmp_path, T0 + timedelta(seconds=39), 60, live=True, stop_reason="call_ended")
    continuation.add_part(a.folder, b.folder)

    continuation.join_parts(a)
    for derived in (a.mic_wav, a.mic_segments, a.system_segments, a.system_turns, a.speaker_embeddings,
                    a.transcript_json, a.speakers_merged):
        assert not derived.exists(), derived.name
    assert sf.info(str(a.mic_raw_wav)).duration == 99 and sf.info(str(a.system_wav)).duration == 99


def test_names_given_while_recording_come_along(tmp_path):
    a = _part(tmp_path, T0, 30, live=True)
    b = _part(tmp_path, T0 + timedelta(seconds=39), 60, live=True)
    a.speakers_live.write_text(json.dumps([{"name": "Anna", "embedding": VOICE}]))
    b.speakers_live.write_text(json.dumps([{"name": "Ben", "embedding": [0.0, 1.0, 0.0]}]))
    continuation.add_part(a.folder, b.folder)
    continuation.join_parts(a)
    assert [n["name"] for n in json.loads(a.speakers_live.read_text())] == ["Anna", "Ben"]


def _crashed_part(root: Path, start: datetime, seconds: int, *, minutes_ago: float = 0) -> RecordingPaths:
    """A part the app died recording: .part files, no meta.json; last
    written ``minutes_ago`` (0: still growing, as far as anyone can tell)."""
    import os
    import time

    paths = RecordingPaths(root / start.strftime("%Y-%m-%dT%H-%M-%S"))
    paths.folder.mkdir()
    tone = np.full(seconds * SR, 7, np.int16)
    for track in (paths.mic_raw_wav, paths.system_wav):
        sf.write(str(track) + ".part", tone, SR, subtype="PCM_16", format="WAV")
        if minutes_ago:
            then = time.time() - minutes_ago * 60
            os.utime(str(track) + ".part", (then, then))
    return paths


def test_a_part_that_never_finished_recording_is_recovered_and_joined(tmp_path):
    a = _part(tmp_path, T0, 30, live=False)
    crashed = _crashed_part(tmp_path, T0 + timedelta(seconds=39), 20)
    gone = tmp_path / "2026-10-29T12-30-00"  # moved to the trash meanwhile
    continuation.add_part(a.folder, crashed.folder)
    continuation.add_part(a.folder, gone)
    assert continuation.join_parts(a) == 1
    assert not crashed.folder.exists() and not a.parts.exists()
    assert json.loads(a.meta.read_text())["duration_seconds"] == 59
    assert sf.info(str(a.system_wav)).duration == 59


def test_a_part_that_cannot_be_read_stays_listed_to_recover_later(tmp_path):
    a = _part(tmp_path, T0, 30, live=False)
    b = _part(tmp_path, T0 + timedelta(seconds=39), 20, live=False)
    empty = RecordingPaths(tmp_path / "2026-10-29T12-07-30")
    empty.folder.mkdir()  # nothing was written before the app died
    continuation.add_part(a.folder, b.folder)
    continuation.add_part(a.folder, empty.folder)
    assert continuation.join_parts(a) == 1
    assert continuation.parts(a.folder) == [empty.folder] and empty.folder.exists()


def test_a_failed_join_leaves_the_first_part_as_it_was(tmp_path, monkeypatch):
    import pytest

    from palaver import cutting

    a = _part(tmp_path, T0, 30, live=True)
    b = _part(tmp_path, T0 + timedelta(seconds=39), 60, live=True)
    continuation.add_part(a.folder, b.folder)
    def content():  # parts.json notes what it decided; the recording itself stays as it was
        return {f.name: f.read_bytes() for f in a.folder.iterdir() if f.is_file() and f != a.parts}

    before = content()

    def broken(paths):
        raise OSError("disk full")

    monkeypatch.setattr(cutting, "_per_label_files", broken)
    with pytest.raises(OSError):
        continuation.join_parts(a)
    assert content() == before and not (a.folder / ".join-backup").exists()
    assert b.folder.exists() and continuation.parts(a.folder) == [b.folder]


def test_a_join_killed_half_way_is_undone_before_it_runs_again(tmp_path, monkeypatch):
    from palaver import cutting

    a = _part(tmp_path, T0, 30, live=True)
    b = _part(tmp_path, T0 + timedelta(seconds=39), 60, live=True)
    continuation.add_part(a.folder, b.folder)

    def killed(*args):  # SIGKILL: nothing runs after this, no restore either
        raise KeyboardInterrupt

    monkeypatch.setattr(cutting, "_restore", lambda backup, paths: None)
    monkeypatch.setattr(cutting, "_per_label_files", killed)
    try:
        continuation.join_parts(a)
    except KeyboardInterrupt:
        pass
    monkeypatch.undo()
    assert sf.info(str(a.system_wav)).duration == 99  # half-joined: the tracks are, the rest is not
    assert continuation.join_parts(a) == 1  # undone first, then joined once
    assert json.loads(a.meta.read_text())["duration_seconds"] == 99
    assert sf.info(str(a.system_wav)).duration == 99 and not b.folder.exists()


def test_a_join_killed_after_writing_is_finished_not_repeated(tmp_path, monkeypatch):
    from palaver import cutting

    a = _part(tmp_path, T0, 30, live=True)
    b = _part(tmp_path, T0 + timedelta(seconds=39), 60, live=True)
    continuation.add_part(a.folder, b.folder)

    def killed(*args):
        raise KeyboardInterrupt

    monkeypatch.setattr(cutting, "trash", killed)
    try:
        continuation.join_parts(a)
    except KeyboardInterrupt:
        pass
    monkeypatch.undo()
    assert b.folder.exists()  # everything was written, only the move to the trash is missing
    continuation.join_parts(a)
    assert json.loads(a.meta.read_text())["duration_seconds"] == 99  # not joined twice
    assert not b.folder.exists() and not a.parts.exists()


def test_process_refuses_while_a_part_is_still_recording(tmp_path, monkeypatch, capsys):
    from palaver import cli
    from tests.test_cli import _fake_models, _ns

    a = _part(tmp_path, T0, 3, live=False)
    b = _crashed_part(tmp_path, T0 + timedelta(seconds=5), 3)  # .part files written just now: recording
    continuation.add_part(a.folder, b.folder)
    _fake_models(monkeypatch)
    assert cli._cmd_process(_ns(a.folder)) == 3
    assert "still being recorded" in capsys.readouterr().out
    assert b.folder.exists() and continuation.parts(a.folder) == [b.folder]


def test_process_joins_the_parts_first_and_transcribes_the_whole_meeting(tmp_path, monkeypatch):
    from palaver import cli
    from palaver.models import Segment
    from tests.test_cli import _fake_models, _ns

    a = _part(tmp_path, T0, 3, live=False)
    b = _part(tmp_path, T0 + timedelta(seconds=5), 3, live=False, stop_reason="call_ended")
    continuation.add_part(a.folder, b.folder)
    lengths = []

    def segments(wav):
        lengths.append((wav, sf.info(str(a.folder / wav)).duration))
        if wav == "system.wav":
            return [Segment(start=0.5, end=1.5, text="Vorher.", speaker=None, words=[]),
                    Segment(start=6.0, end=7.0, text="Nachher.", speaker=None, words=[])]
        return []

    _fake_models(monkeypatch, segments_for=segments,
                 turns=[], embeddings={})
    monkeypatch.setattr("palaver.cleanup.drop_silent_segments", lambda segs, *a, **k: segs)

    assert cli._cmd_process(_ns(a.folder)) == 0
    assert lengths == [("system.wav", 8.0), ("mic.wav", 8.0)]  # the whole meeting, once
    md = a.transcript_md.read_text()
    assert md.index("Vorher.") < md.index("*Recording paused 12:06:13–12:06:15 (Palaver restarted)*") < md.index("Nachher.")
    assert not b.folder.exists()


# --- review round 3 ----------------------------------------------------------------


def test_a_first_part_the_app_died_recording_is_recovered_before_joining(tmp_path):
    """The reviewer's probe: the head crashed (held as a cut), then was continued."""
    a = _crashed_part(tmp_path, T0, 30, minutes_ago=5)
    b = _part(tmp_path, T0 + timedelta(seconds=39), 20, live=False, stop_reason="call_ended")
    continuation.add_part(a.folder, b.folder)
    assert continuation.join_parts(a) == 1
    meta = json.loads(a.meta.read_text())
    assert meta["start_time"] == T0.isoformat() and meta["duration_seconds"] == 59
    assert meta["gaps"] == [{"start": 30.0, "end": 39.0, "why": "restart"}]


def test_a_first_part_without_audio_hands_the_meeting_to_the_next(tmp_path):
    a = RecordingPaths(tmp_path / T0.strftime("%Y-%m-%dT%H-%M-%S"))
    a.folder.mkdir()  # the app died before it wrote anything
    b = _part(tmp_path, T0 + timedelta(seconds=39), 20, live=False)
    c = _part(tmp_path, T0 + timedelta(seconds=70), 20, live=False, stop_reason="call_ended")
    continuation.add_part(a.folder, b.folder)
    continuation.add_part(a.folder, c.folder)
    head = continuation.recover_head(a)
    assert head.folder == b.folder and continuation.parts(b.folder) == [c.folder]
    assert not a.parts.exists() and a.folder.exists()  # left as it is: visible, can be trashed
    assert continuation.join_parts(head) == 1


def test_process_transcribes_a_meeting_whose_first_part_crashed(tmp_path, monkeypatch):
    from palaver import cli
    from tests.test_cli import _fake_models, _ns

    a = _crashed_part(tmp_path, T0, 3, minutes_ago=5)
    b = _part(tmp_path, T0 + timedelta(seconds=5), 3, live=False, stop_reason="call_ended")
    continuation.add_part(a.folder, b.folder)
    _fake_models(monkeypatch)
    assert cli._cmd_process(_ns(a.folder)) == 0
    assert a.transcript_md.exists() and not b.folder.exists()


def test_process_refuses_while_the_first_part_is_still_being_recorded(tmp_path, monkeypatch, capsys):
    import palaver.daemon as daemon
    from palaver import cli
    from tests.test_cli import _fake_models, _ns

    _fake_models(monkeypatch)
    growing = _crashed_part(tmp_path, T0, 3)  # .part files written just now
    assert cli._cmd_process(_ns(growing.folder)) == 3
    assert "still being recorded" in capsys.readouterr().out

    import subprocess
    import sys

    finished = _part(tmp_path, T0 + timedelta(minutes=5), 3, live=False)
    state = tmp_path / "daemon.json"
    monkeypatch.setattr(daemon, "STATE_PATH", state)
    running = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", "palaver", "menubar"])
    try:
        state.write_text(json.dumps({"state": "recording", "folder": str(finished.folder), "pid": running.pid}))
        assert cli._cmd_process(_ns(finished.folder)) == 3  # a running daemon records into it
    finally:
        running.kill()
        running.wait()
    state.write_text(json.dumps({"state": "recording", "folder": str(finished.folder), "pid": 999_999_999}))
    assert cli._cmd_process(_ns(finished.folder)) == 0  # that daemon is gone


def test_names_given_while_recording_are_not_doubled_by_a_join_run_again(tmp_path, monkeypatch):
    from palaver import cutting

    a = _part(tmp_path, T0, 30, live=True)
    b = _part(tmp_path, T0 + timedelta(seconds=39), 60, live=True)
    a.speakers_live.write_text(json.dumps([{"name": "Anna", "embedding": VOICE}]))
    b.speakers_live.write_text(json.dumps([{"name": "Ben", "embedding": [0.0, 1.0, 0.0]}]))
    continuation.add_part(a.folder, b.folder)

    def killed(*args):
        raise KeyboardInterrupt

    monkeypatch.setattr(cutting, "_per_label_files", killed)
    try:
        continuation.join_parts(a)
    except KeyboardInterrupt:
        pass
    monkeypatch.undo()
    continuation.join_parts(a)
    assert [n["name"] for n in json.loads(a.speakers_live.read_text())] == ["Anna", "Ben"]


def test_the_join_backup_links_the_audio_and_copies_the_rest(tmp_path, monkeypatch):
    import os

    from palaver import cutting

    a = _part(tmp_path, T0, 30, live=True)
    b = _part(tmp_path, T0 + timedelta(seconds=39), 60, live=True)
    backup = cutting._backup(a, b)
    assert (backup / "system.wav").stat().st_ino == a.system_wav.stat().st_ino  # no 100 MB copies
    assert (backup / "meta.json").stat().st_ino != a.meta.stat().st_ino  # rewritten in place: a copy
    cutting._restore(backup, a)

    def no_links(src, dst):
        raise OSError("cross-device link")

    monkeypatch.setattr(os, "link", no_links)
    backup = cutting._backup(a, b)
    assert (backup / "system.wav").stat().st_ino != a.system_wav.stat().st_ino
    assert (backup / "system.wav").read_bytes() == a.system_wav.read_bytes()
